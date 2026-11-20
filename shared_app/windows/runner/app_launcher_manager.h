// app_launcher_manager.h
#ifndef DEVICE_AGENT_APP_LAUNCHER_MANAGER_H_
#define DEVICE_AGENT_APP_LAUNCHER_MANAGER_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Native side of `ChannelNames.appLauncher` for Windows — `ShellExecute`
// se launch (exe path, .lnk shortcut, ya URL/protocol), aur Start Menu
// shortcuts enumerate karke "installed apps" list deta hai.
class AppLauncherManager {
 public:
  static void Register(flutter::FlutterEngine* engine);
};

#endif  // DEVICE_AGENT_APP_LAUNCHER_MANAGER_H_
