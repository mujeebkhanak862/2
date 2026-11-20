// files_manager.h
#ifndef DEVICE_AGENT_FILES_MANAGER_H_
#define DEVICE_AGENT_FILES_MANAGER_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Native side of `ChannelNames.files` for Windows — sandboxed
// std::filesystem operations within an allowed root, plus a native
// folder-picker (IFileDialog) for broader user-granted access.
class FilesManager {
 public:
  static void Register(flutter::FlutterEngine* engine, HWND window_handle);

  // Item 81: file I/O worker thread par chalta hai; result UI thread par
  // is custom window message ke zariye wapas aata hai.
  static constexpr UINT kMainThreadMessage = WM_APP + 0x51;
  // `FlutterWindow::MessageHandler` se `kMainThreadMessage` par call karein.
  static void DrainMainThreadTasks();
};

#endif  // DEVICE_AGENT_FILES_MANAGER_H_
