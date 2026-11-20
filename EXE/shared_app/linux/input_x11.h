// input_x11.h
#ifndef DEVICE_AGENT_INPUT_X11_H_
#define DEVICE_AGENT_INPUT_X11_H_

#include <string>

// XTest extension based input synthesis — X11 sessions ke liye. Koi
// separate consent dialog nahi hota (screen_capture_x11.h ki tarah,
// session-level trust already assumed hai poore architecture doc mein).
class InputX11 {
 public:
  static bool IsAvailable();
  static bool Tap(double x, double y);
  static bool Swipe(double x1, double y1, double x2, double y2, int duration_ms);
  static bool TypeText(const std::string& utf8_text);
};

#endif  // DEVICE_AGENT_INPUT_X11_H_
