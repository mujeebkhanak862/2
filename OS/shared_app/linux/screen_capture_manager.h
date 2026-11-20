// screen_capture_manager.h
#ifndef DEVICE_AGENT_SCREEN_CAPTURE_MANAGER_H_
#define DEVICE_AGENT_SCREEN_CAPTURE_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.screenCapture` + `ChannelNames.screenLiveStream`
// for Linux/ChromeOS. Session type (X11 vs Wayland) detect karke
// ScreenCaptureX11 ya ScreenCaptureWaylandPortal ko delegate karta hai —
// Dart side ko farq pata nahi chalta, contract dono platforms jaisa hi hai
// (requestPermission / captureScreenshot / stopStream + JPEG frame stream).
void screen_capture_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_SCREEN_CAPTURE_MANAGER_H_
