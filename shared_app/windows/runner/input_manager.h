// input_manager.h
#ifndef DEVICE_AGENT_INPUT_MANAGER_H_
#define DEVICE_AGENT_INPUT_MANAGER_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Native side of `ChannelNames.input` for Windows — uses the Win32
// `SendInput` API. No special consent dialog exists at the OS level for
// this (unlike screen capture) since a desktop app running under the
// user's own session is already trusted to control its own input.
class InputManager {
 public:
  static void Register(flutter::FlutterEngine* engine, HWND window_handle);
};

#endif  // DEVICE_AGENT_INPUT_MANAGER_H_
