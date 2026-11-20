// screen_capture_wayland_portal.cc
#include "screen_capture_wayland_portal.h"
#include "wayland_portal_session.h"

#include <spa/param/format-utils.h>
#include <spa/param/video/format.h>
#include <spa/param/video/raw.h>
#include <spa/pod/builder.h>
#include <spa/utils/result.h>

#include <glib.h>
#include <turbojpeg.h>
#include <unistd.h>

#include <cstring>

// ---- static member storage -------------------------------------------

struct pw_thread_loop* ScreenCaptureWaylandPortal::pw_loop_ = nullptr;
struct pw_context* ScreenCaptureWaylandPortal::pw_context_ = nullptr;
struct pw_core* ScreenCaptureWaylandPortal::pw_core_ = nullptr;
struct pw_stream* ScreenCaptureWaylandPortal::pw_stream_ = nullptr;
struct spa_hook ScreenCaptureWaylandPortal::pw_stream_listener_ = {};

std::function<void(std::vector<unsigned char>)>
    ScreenCaptureWaylandPortal::frame_callback_;
int ScreenCaptureWaylandPortal::frame_width_ = 0;
int ScreenCaptureWaylandPortal::frame_height_ = 0;
uint32_t ScreenCaptureWaylandPortal::frame_format_ = SPA_VIDEO_FORMAT_UNKNOWN;

namespace {

// SPA video format -> libjpeg-turbo pixel format. PipeWire screen-cast
// streams commonly negotiate BGRx/RGBx/BGRA/RGBA.
int SpaFormatToTjpf(uint32_t spa_format) {
  switch (spa_format) {
    case SPA_VIDEO_FORMAT_BGRx:
      return TJPF_BGRX;
    case SPA_VIDEO_FORMAT_RGBx:
      return TJPF_RGBX;
    case SPA_VIDEO_FORMAT_BGRA:
      return TJPF_BGRA;
    case SPA_VIDEO_FORMAT_RGBA:
      return TJPF_RGBA;
    default:
      return TJPF_BGRX;  // reasonable fallback
  }
}

std::vector<unsigned char> EncodeRawFrameAsJpeg(const uint8_t* data,
                                                 int width, int height,
                                                 int stride,
                                                 uint32_t spa_format) {
  tjhandle compressor = tjInitCompress();
  unsigned char* jpeg_buf = nullptr;
  unsigned long jpeg_size = 0;

  tjCompress2(compressor, data, width, stride, height,
              SpaFormatToTjpf(spa_format), &jpeg_buf, &jpeg_size, TJSAMP_420,
              60, TJFLAG_FASTDCT);

  std::vector<unsigned char> result(jpeg_buf, jpeg_buf + jpeg_size);
  tjFree(jpeg_buf);
  tjDestroy(compressor);
  return result;
}

}  // namespace

bool ScreenCaptureWaylandPortal::IsAvailable() {
  const char* session_type = g_getenv("XDG_SESSION_TYPE");
  return session_type != nullptr && std::string(session_type) == "wayland";
}

void ScreenCaptureWaylandPortal::RequestSession(
    std::function<void(bool)> on_result) {
  // `need_remote_desktop = true`: hum hamesha input bhi saath mein maang
  // lete hain (ek hi consent dialog mein) taaki baad mein Input capability
  // use hone par dobara session/dialog na banana pade. Agar user sirf
  // screen dekhna chahta hai, RemoteDesktop permission granted rehti hai
  // bas use nahi hoti — koi extra risk nahi, kyunki input sirf Scoped API
  // Key ki authorization ke through hi actually trigger hota hai
  // (Section 3 ka permission model).
  bool ok = WaylandPortalSession::EnsureReady(
      /*need_screencast=*/true, /*need_remote_desktop=*/true);
  on_result(ok);
}

// ---- PipeWire stream ------------------------------------------------------

void ScreenCaptureWaylandPortal::OnPipeWireParamChanged(
    void* user_data, uint32_t id, const struct spa_pod* param) {
  if (param == nullptr || id != SPA_PARAM_Format) return;

  struct spa_video_info_raw raw_info;
  spa_zero(raw_info);
  if (spa_format_video_raw_parse(param, &raw_info) < 0) return;

  frame_width_ = raw_info.size.width;
  frame_height_ = raw_info.size.height;
  frame_format_ = raw_info.format;
}

void ScreenCaptureWaylandPortal::OnPipeWireProcess(void* user_data) {
  struct pw_buffer* b = pw_stream_dequeue_buffer(pw_stream_);
  if (b == nullptr) return;

  struct spa_buffer* buf = b->buffer;
  if (buf->datas[0].data != nullptr && frame_width_ > 0 &&
      frame_height_ > 0 && frame_callback_) {
    int stride = buf->datas[0].chunk->stride;
    if (stride <= 0) stride = frame_width_ * 4;
    auto jpeg = EncodeRawFrameAsJpeg(
        static_cast<const uint8_t*>(buf->datas[0].data), frame_width_,
        frame_height_, stride, frame_format_);
    if (!jpeg.empty()) frame_callback_(std::move(jpeg));
  }

  pw_stream_queue_buffer(pw_stream_, b);
}

void ScreenCaptureWaylandPortal::StartStream(
    std::function<void(std::vector<unsigned char>)> on_frame) {
  if (!WaylandPortalSession::IsReady() ||
      WaylandPortalSession::PipeWireFd() < 0 ||
      WaylandPortalSession::PipeWireNodeId() == 0) {
    g_warning("StartStream: portal session not ready");
    return;
  }
  frame_callback_ = std::move(on_frame);

  static bool pw_initialized = false;
  if (!pw_initialized) {
    pw_init(nullptr, nullptr);
    pw_initialized = true;
  }

  pw_loop_ = pw_thread_loop_new("device-agent-screencast", nullptr);
  pw_thread_loop_lock(pw_loop_);

  pw_context_ = pw_context_new(pw_thread_loop_get_loop(pw_loop_), nullptr, 0);
  pw_thread_loop_start(pw_loop_);

  // pw_context_connect_fd fd par ownership le leta hai — dup() zaroori
  // hai taaki shared WaylandPortalSession wala fd hum khud manage kar
  // sakein (aur Close() hone tak zinda rahe).
  pw_core_ = pw_context_connect_fd(
      pw_context_, dup(WaylandPortalSession::PipeWireFd()), nullptr, 0);

  struct pw_properties* props = pw_properties_new(
      PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
      PW_KEY_MEDIA_ROLE, "Screen", nullptr);

  pw_stream_ = pw_stream_new(pw_core_, "device-agent-screen-capture", props);

  static const struct pw_stream_events stream_events = {
      .version = PW_VERSION_STREAM_EVENTS,
      .param_changed = OnPipeWireParamChanged,
      .process = OnPipeWireProcess,
  };
  pw_stream_add_listener(pw_stream_, &pw_stream_listener_, &stream_events,
                          nullptr);

  // Format negotiation — BGRx/RGBx/BGRA/RGBA mein se koi bhi accept karte
  // hain, compositor jo bhi de. Size aur framerate range flexible rakhi
  // hai taaki compositor apni native resolution use kare.
  uint8_t buffer[1024];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  struct spa_pod_frame f;

  spa_pod_builder_push_object(&b, &f, SPA_TYPE_OBJECT_Format,
                               SPA_PARAM_EnumFormat);
  struct spa_rectangle rect_default = SPA_RECTANGLE(1920, 1080);
  struct spa_rectangle rect_min = SPA_RECTANGLE(1, 1);
  struct spa_rectangle rect_max = SPA_RECTANGLE(8192, 4320);
  struct spa_fraction fps_default = SPA_FRACTION(30, 1);
  struct spa_fraction fps_min = SPA_FRACTION(0, 1);
  struct spa_fraction fps_max = SPA_FRACTION(60, 1);
  spa_pod_builder_add(
      &b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
      SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
      SPA_FORMAT_VIDEO_format,
      SPA_POD_CHOICE_ENUM_Id(5, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
                              SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_BGRA,
                              SPA_VIDEO_FORMAT_RGBA),
      SPA_FORMAT_VIDEO_size,
      SPA_POD_CHOICE_RANGE_Rectangle(&rect_default, &rect_min, &rect_max),
      SPA_FORMAT_VIDEO_framerate,
      SPA_POD_CHOICE_RANGE_Fraction(&fps_default, &fps_min, &fps_max),
      0);
  const struct spa_pod* params[1];
  params[0] = static_cast<const struct spa_pod*>(spa_pod_builder_pop(&b, &f));

  pw_stream_connect(
      pw_stream_, PW_DIRECTION_INPUT, WaylandPortalSession::PipeWireNodeId(),
      static_cast<enum pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT |
                                         PW_STREAM_FLAG_MAP_BUFFERS),
      params, 1);

  pw_thread_loop_unlock(pw_loop_);
}

void ScreenCaptureWaylandPortal::StopStream() {
  if (pw_loop_ == nullptr) return;

  pw_thread_loop_lock(pw_loop_);
  if (pw_stream_) {
    pw_stream_disconnect(pw_stream_);
    pw_stream_destroy(pw_stream_);
    pw_stream_ = nullptr;
  }
  if (pw_core_) {
    pw_core_disconnect(pw_core_);
    pw_core_ = nullptr;
  }
  if (pw_context_) {
    pw_context_destroy(pw_context_);
    pw_context_ = nullptr;
  }
  pw_thread_loop_unlock(pw_loop_);

  pw_thread_loop_stop(pw_loop_);
  pw_thread_loop_destroy(pw_loop_);
  pw_loop_ = nullptr;

  frame_callback_ = nullptr;
  frame_width_ = frame_height_ = 0;

  // NOTE: WaylandPortalSession::Close() yahan deliberately nahi bulaya —
  // session Input capability ke liye bhi shared hai, isliye sirf stream
  // (PipeWire side) band karte hain. Poori session close karna
  // screen_capture_manager.cc ke explicit "disconnect device" flow ka
  // kaam hai, is method ka nahi.
}
