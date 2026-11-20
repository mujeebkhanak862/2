// input_manager.h
#ifndef DEVICE_AGENT_INPUT_MANAGER_H_
#define DEVICE_AGENT_INPUT_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.input` for Linux/ChromeOS. Session type
// (X11 vs Wayland) detect karke InputX11 ya InputWaylandPortal ko
// delegate karta hai — same dispatcher pattern jo
// screen_capture_manager.cc mein hai.
void input_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_INPUT_MANAGER_H_
