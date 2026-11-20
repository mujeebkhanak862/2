// input_x11.cc
#include "input_x11.h"

#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>

#include <cstdint>
#include <thread>
#include <chrono>
#include <vector>

namespace {

// UTF-8 -> Unicode codepoints (simple, no error-recovery beyond skipping
// malformed bytes — typed text ke liye kaafi hai).
std::vector<uint32_t> Utf8Decode(const std::string& s) {
  std::vector<uint32_t> out;
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = s[i];
    uint32_t cp = 0;
    int extra = 0;
    if ((c & 0x80) == 0) {
      cp = c;
      extra = 0;
    } else if ((c & 0xE0) == 0xC0) {
      cp = c & 0x1F;
      extra = 1;
    } else if ((c & 0xF0) == 0xE0) {
      cp = c & 0x0F;
      extra = 2;
    } else if ((c & 0xF8) == 0xF0) {
      cp = c & 0x07;
      extra = 3;
    } else {
      i++;
      continue;  // invalid leading byte, skip
    }
    i++;
    bool valid = true;
    for (int k = 0; k < extra && i < s.size(); k++, i++) {
      unsigned char cc = s[i];
      if ((cc & 0xC0) != 0x80) {
        valid = false;
        break;
      }
      cp = (cp << 6) | (cc & 0x3F);
    }
    if (valid) out.push_back(cp);
  }
  return out;
}

// Latin-1 range mein X11 KeySym value Unicode codepoint jaisa hi hota hai;
// uske aage "Unicode keysym" convention (0x01000000 + codepoint) modern
// X servers/XKB support karte hain — xdotool jaise tools isi tarike se
// arbitrary Unicode type karte hain.
unsigned long CodepointToKeysym(uint32_t cp) {
  if (cp <= 0xFF) return static_cast<unsigned long>(cp);
  return 0x01000000UL + cp;
}

}  // namespace

bool InputX11::IsAvailable() {
  Display* display = XOpenDisplay(nullptr);
  if (display == nullptr) return false;
  int event_base, error_base, major, minor;
  bool has_xtest =
      XTestQueryExtension(display, &event_base, &error_base, &major, &minor);
  XCloseDisplay(display);
  return has_xtest;
}

bool InputX11::Tap(double x, double y) {
  Display* display = XOpenDisplay(nullptr);
  if (display == nullptr) return false;

  XTestFakeMotionEvent(display, -1, static_cast<int>(x), static_cast<int>(y), 0);
  XSync(display, False);
  XTestFakeButtonEvent(display, Button1, True, 0);
  XSync(display, False);
  XTestFakeButtonEvent(display, Button1, False, 0);
  XSync(display, False);

  XCloseDisplay(display);
  return true;
}

bool InputX11::Swipe(double x1, double y1, double x2, double y2, int duration_ms) {
  Display* display = XOpenDisplay(nullptr);
  if (display == nullptr) return false;

  // Item 83: yeh platform thread par sleep karta hai — lamba duration
  // poori UI freeze kar sakta tha, isliye cap.
  if (duration_ms > 2000) duration_ms = 2000;

  XTestFakeMotionEvent(display, -1, static_cast<int>(x1), static_cast<int>(y1), 0);
  XSync(display, False);
  XTestFakeButtonEvent(display, Button1, True, 0);
  XSync(display, False);

  const int steps = 20;
  for (int i = 1; i <= steps; i++) {
    double t = static_cast<double>(i) / steps;
    int x = static_cast<int>(x1 + (x2 - x1) * t);
    int y = static_cast<int>(y1 + (y2 - y1) * t);
    XTestFakeMotionEvent(display, -1, x, y, 0);
    XSync(display, False);
    std::this_thread::sleep_for(
        std::chrono::milliseconds(duration_ms > 0 ? duration_ms / steps : 5));
  }

  XTestFakeButtonEvent(display, Button1, False, 0);
  XSync(display, False);

  XCloseDisplay(display);
  return true;
}

bool InputX11::TypeText(const std::string& utf8_text) {
  Display* display = XOpenDisplay(nullptr);
  if (display == nullptr) return false;

  int min_keycode = 0, max_keycode = 0;
  XDisplayKeycodes(display, &min_keycode, &max_keycode);
  // Highest keycode slot ko "scratch" ke tor par use karte hain — xdotool
  // jaisi tools ka standard technique, taaki kisi Unicode character ko
  // type karne ke liye layout badalne ki zaroorat na pade.
  KeyCode scratch_keycode = static_cast<KeyCode>(max_keycode);

  auto codepoints = Utf8Decode(utf8_text);
  for (uint32_t cp : codepoints) {
    KeySym keysym = static_cast<KeySym>(CodepointToKeysym(cp));
    XChangeKeyboardMapping(display, scratch_keycode, 1, &keysym, 1);
    XSync(display, False);

    XTestFakeKeyEvent(display, scratch_keycode, True, 0);
    XSync(display, False);
    XTestFakeKeyEvent(display, scratch_keycode, False, 0);
    XSync(display, False);

    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  // Item 83: scratch keycode ka temporary mapping wapas khaali karo —
  // pehle yeh badli hui keymap process ke end tak (aur doosre apps ke
  // liye bhi) chhod di jati thi.
  KeySym none = NoSymbol;
  XChangeKeyboardMapping(display, scratch_keycode, 1, &none, 1);
  XSync(display, False);

  XCloseDisplay(display);
  return true;
}
