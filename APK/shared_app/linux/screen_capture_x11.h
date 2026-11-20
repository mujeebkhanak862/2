// screen_capture_x11.h
#ifndef DEVICE_AGENT_SCREEN_CAPTURE_X11_H_
#define DEVICE_AGENT_SCREEN_CAPTURE_X11_H_

#include <vector>

// XGetImage-based capture — sirf X11 sessions ke liye
// (screen_capture_manager.cc yeh decide karta hai session X11 hai ya
// Wayland, aur us hisaab se is file ya Wayland portal wali file ko use
// karta hai).
class ScreenCaptureX11 {
 public:
  static bool IsAvailable();
  static std::vector<unsigned char> CaptureFrameAsJpeg();
};

#endif  // DEVICE_AGENT_SCREEN_CAPTURE_X11_H_
