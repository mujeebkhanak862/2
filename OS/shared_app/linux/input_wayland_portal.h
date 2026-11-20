// input_wayland_portal.h
#ifndef DEVICE_AGENT_INPUT_WAYLAND_PORTAL_H_
#define DEVICE_AGENT_INPUT_WAYLAND_PORTAL_H_

#include <string>

// `org.freedesktop.portal.RemoteDesktop` — Wayland ka input-injection
// equivalent. Session/consent handshake ab `WaylandPortalSession`
// (shared file) mein hai, jise Screen Capture ke saath share kiya jaata
// hai — is se do fayde: (1) user ko ek hi consent dialog dikhta hai, aur
// (2) `NotifyPointerMotionAbsolute` ke `stream` parameter ke liye asal
// PipeWire node id milta hai (jo sirf tab exist karta hai jab isi session
// mein ScreenCast.SelectSources bhi hui ho) — pehle yeh independent
// session ke saath hardcoded 0 tha, jo kuch compositors reject kar
// saktay the.
class InputWaylandPortal {
 public:
  static bool IsAvailable();

  // Shared session ready karta hai (remote_desktop capability ke saath).
  static bool EnsureSessionReady();

  static bool Tap(double x, double y);
  static bool Swipe(double x1, double y1, double x2, double y2, int duration_ms);
  static bool TypeText(const std::string& utf8_text);
};

#endif  // DEVICE_AGENT_INPUT_WAYLAND_PORTAL_H_
