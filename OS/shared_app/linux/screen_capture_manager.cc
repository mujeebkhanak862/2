// screen_capture_manager.cc
#include "screen_capture_manager.h"
#include "screen_capture_wayland_portal.h"
#include "screen_capture_x11.h"

#include <glib.h>

namespace {
constexpr char kMethodChannel[] = "device_agent/screen_capture";
constexpr char kEventChannel[] = "device_agent/screen_live_stream";

FlEventChannel* g_event_channel = nullptr;
gboolean g_streaming = FALSE;
guint g_stream_timer_id = 0;
// P1-03 fix — kaunsa live-stream path abhi active hai, taaki
// OnEventCancel sahi cleanup kare (X11 timer band karo, ya Wayland
// PipeWire stream band karo — dono ek saath kabhi nahi chalte).
gboolean g_using_wayland_stream = FALSE;

std::string Base64Encode(const std::vector<unsigned char>& bytes) {
  gchar* encoded = g_base64_encode(bytes.data(), bytes.size());
  std::string result(encoded);
  g_free(encoded);
  return result;
}

// X11-only path — XGetImage synchronous/pull-based hai, is liye timer
// polling se chalta hai. Wayland ka apna push-based (PipeWire callback)
// path hai neeche `OnEventListen` mein, isko is function se koi lena-
// dena nahi (P1-03 se pehle yahan ek confusing comment tha jo keh raha
// tha Wayland "alag jagah handle hoti hai" lekin who jagah kahin bhi
// actually call nahi hoti thi — is function ke bahar Wayland ka wiring
// kabhi hua hi nahi tha).
gboolean OnStreamTick(gpointer user_data) {
  if (!g_streaming || g_event_channel == nullptr) {
    g_stream_timer_id = 0;  // item 83: stale source-id par baad mein g_source_remove na ho
    return G_SOURCE_REMOVE;
  }

  std::vector<unsigned char> jpeg = ScreenCaptureX11::CaptureFrameAsJpeg();

  if (!jpeg.empty()) {
    g_autoptr(FlValue) value = fl_value_new_string(Base64Encode(jpeg).c_str());
    fl_event_channel_send(g_event_channel, value, nullptr, nullptr);
  }
  if (!g_streaming) {
    g_stream_timer_id = 0;
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "requestPermission") == 0) {
    if (ScreenCaptureX11::IsAvailable()) {
      // X11 mein alag consent dialog nahi hota (Section: X11 file ka
      // top comment) — session hi already authorized context hai.
      g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    } else {
      // Wayland — asal consent yahan maanga jaata hai. Sync response ke
      // liye hum synchronous wrapper use kar rahe (production mein yeh
      // async hona chahiye taaki UI thread block na ho).
      bool granted = false;
      GMainLoop* loop = g_main_loop_new(nullptr, FALSE);
      // Item 83: portal jawab hi na de to nested loop hamesha ke liye latak
      // jata tha (UI freeze). 60s timeout.
      guint timeout_id = g_timeout_add_seconds(60, [](gpointer data) -> gboolean {
        g_main_loop_quit(static_cast<GMainLoop*>(data));
        return G_SOURCE_REMOVE;
      }, loop);
      bool finished = false;
      ScreenCaptureWaylandPortal::RequestSession([&](bool g) {
        granted = g;
        finished = true;
        g_main_loop_quit(loop);
      });
      g_main_loop_run(loop);
      if (finished) g_source_remove(timeout_id);
      g_main_loop_unref(loop);
      g_autoptr(FlValue) result = fl_value_new_bool(granted);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (g_strcmp0(method, "captureScreenshot") == 0) {
    std::vector<unsigned char> jpeg;
    if (ScreenCaptureX11::IsAvailable()) {
      jpeg = ScreenCaptureX11::CaptureFrameAsJpeg();
    }
    if (jpeg.empty() && !ScreenCaptureX11::IsAvailable()) {
      // Item 83: Wayland par one-shot screenshot implement nahi hai (sirf
      // portal live stream hai) — NOT_READY (retry) nahi, saaf "unavailable".
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "CAPABILITY_UNAVAILABLE",
          "Wayland par screenshot abhi supported nahi hai — live stream "
          "(screen.watch_live) use karein", nullptr));
    } else if (jpeg.empty()) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "NOT_READY", "Screenshot capture nahi ho saki", nullptr));
    } else {
      g_autoptr(FlValue) result =
          fl_value_new_string(Base64Encode(jpeg).c_str());
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else if (g_strcmp0(method, "stopStream") == 0) {
    g_streaming = FALSE;
    ScreenCaptureWaylandPortal::StopStream();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Screen capture response failed: %s", error->message);
  }
}

static FlMethodErrorResponse* OnEventListen(FlEventChannel* channel,
                                             FlValue* args,
                                             gpointer user_data) {
  // P1-03 fix — pehle yahan hamesha timer-poll (X11-only) path start ho
  // jaata tha, chahe X11 available ho ya na ho — agar na ho (pure
  // Wayland session, XWayland bhi nahi) to timer chalti rehti thi lekin
  // `CaptureFrameAsJpeg()` hamesha khaali deta, is liye koi frame kabhi
  // na jaata aur Dart side "waiting for first frame" mein hamesha ke
  // liye atka rehta — na fake stream, na koi error, bas silent hang.
  // Ab teen honest outcomes hain: X11 → timer-poll; Wayland-only →
  // real PipeWire stream; dono na ho → explicit CAPABILITY_UNAVAILABLE
  // error (koi listen hi register nahi hoti).
  if (ScreenCaptureX11::IsAvailable()) {
    g_streaming = TRUE;
    g_using_wayland_stream = FALSE;
    // ~15 FPS polling — X11 XGetImage ke liye simple aur reliable;
    // Section 2.1 "adaptive FPS" wali fine-tuning baad mein.
    // Item 83: pehle 66ms (~15fps) par XGetImage + JPEG encode main loop par
    // chalta tha (UI jank). ~7fps kaafi hai; duplicate listen par purana
    // timer hata kar naya lagta hai (timer leak nahi).
    if (g_stream_timer_id != 0) g_source_remove(g_stream_timer_id);
    g_stream_timer_id = g_timeout_add(150, OnStreamTick, nullptr);
    return nullptr;
  }

  if (ScreenCaptureWaylandPortal::IsAvailable()) {
    g_streaming = TRUE;
    g_using_wayland_stream = TRUE;
    ScreenCaptureWaylandPortal::StartStream(
        [](std::vector<unsigned char> jpeg) {
          if (!g_streaming || g_event_channel == nullptr || jpeg.empty()) return;
          g_autoptr(FlValue) value =
              fl_value_new_string(Base64Encode(jpeg).c_str());
          fl_event_channel_send(g_event_channel, value, nullptr, nullptr);
        });
    return nullptr;
  }

  // Na X11, na Wayland portal — is session par screen capture is waqt
  // genuinely possible nahi (jaise portal session abhi tak "ready" nahi
  // hai — user ne consent dialog complete nahi kiya, ya koi supported
  // display server hi nahi mila). Explicit, structured unavailable —
  // koi listen registered nahi hoti, Dart side ko turant error milta hai.
  g_streaming = FALSE;
  return fl_method_error_response_new(
      "CAPABILITY_UNAVAILABLE",
      "Screen capture is Linux session par available nahi hai (na X11, na "
      "ek ready Wayland portal session mila)",
      nullptr);
}

static FlMethodErrorResponse* OnEventCancel(FlEventChannel* channel,
                                             FlValue* args,
                                             gpointer user_data) {
  g_streaming = FALSE;
  if (g_using_wayland_stream) {
    ScreenCaptureWaylandPortal::StopStream();
    g_using_wayland_stream = FALSE;
  }
  if (g_stream_timer_id != 0) {
    g_source_remove(g_stream_timer_id);
    g_stream_timer_id = 0;
  }
  return nullptr;
}
}  // namespace

void screen_capture_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);

  FlMethodChannel* method_channel = fl_method_channel_new(
      messenger, kMethodChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(method_channel, method_call_cb,
                                             nullptr, nullptr);

  g_event_channel = fl_event_channel_new(messenger, kEventChannel,
                                          FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_event_channel, OnEventListen,
                                        OnEventCancel, nullptr, nullptr);
}
