// app_launcher_manager.h
#ifndef DEVICE_AGENT_APP_LAUNCHER_MANAGER_H_
#define DEVICE_AGENT_APP_LAUNCHER_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.appLauncher` for Linux — GIO's
// `GAppInfo`/`.desktop` file registry se launch aur list dono.
// `identifier` yahan `.desktop` file id hai (jaise
// "org.gnome.Nautilus.desktop") ya seedha ek executable path.
void app_launcher_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_APP_LAUNCHER_MANAGER_H_
