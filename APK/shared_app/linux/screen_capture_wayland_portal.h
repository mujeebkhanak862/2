// screen_capture_wayland_portal.h
#ifndef DEVICE_AGENT_SCREEN_CAPTURE_WAYLAND_PORTAL_H_
#define DEVICE_AGENT_SCREEN_CAPTURE_WAYLAND_PORTAL_H_

#include <functional>
#include <string>
#include <vector>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

// Wayland compositors X11-jaisi direct screen access allow nahi karte —
// security model ki wajah se sirf `org.freedesktop.portal.ScreenCast`
// (xdg-desktop-portal) ke through, jo khud ek **mandatory OS consent
// dialog** dikhata hai.
//
// Session/consent handshake ab `WaylandPortalSession` (shared file) mein
// hai — ScreenCast aur Input(RemoteDesktop) dono isi ek session ko share
// karte hain (ek hi consent dialog + Input ko ScreenCast ka asli PipeWire
// node id milta hai, jo `NotifyPointerMotionAbsolute` ke `stream`
// parameter ke liye zaroori hai). Yeh class sirf PipeWire stream
// consumption (actual frame-pulling) ka kaam karti hai.
class ScreenCaptureWaylandPortal {
 public:
  static bool IsAvailable();

  // Shared WaylandPortalSession ke through session ready karta hai
  // (screencast capability ke saath — agar input bhi already/baad mein
  // chahiye ho to woh apni taraf se remote_desktop bhi maang legi).
  static void RequestSession(std::function<void(bool granted)> on_result);

  static void StartStream(
      std::function<void(std::vector<unsigned char> jpeg)> on_frame);
  static void StopStream();

 private:
  static void OnPipeWireProcess(void* user_data);
  static void OnPipeWireParamChanged(void* user_data, uint32_t id,
                                      const struct spa_pod* param);

  static struct pw_thread_loop* pw_loop_;
  static struct pw_context* pw_context_;
  static struct pw_core* pw_core_;
  static struct pw_stream* pw_stream_;
  static struct spa_hook pw_stream_listener_;

  static std::function<void(std::vector<unsigned char>)> frame_callback_;
  static int frame_width_;
  static int frame_height_;
  static uint32_t frame_format_;  // spa_video_format
};

#endif  // DEVICE_AGENT_SCREEN_CAPTURE_WAYLAND_PORTAL_H_
