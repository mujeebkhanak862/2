// clipboard_manager.h
#ifndef DEVICE_AGENT_CLIPBOARD_MANAGER_H_
#define DEVICE_AGENT_CLIPBOARD_MANAGER_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Native side of `ChannelNames.clipboard` for Windows — Win32 clipboard
// API (`CF_UNICODETEXT`).
class ClipboardManagerNative {
 public:
  static void Register(flutter::FlutterEngine* engine, HWND window_handle);
};

#endif  // DEVICE_AGENT_CLIPBOARD_MANAGER_H_
