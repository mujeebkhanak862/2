// browser_manager.h
#ifndef DEVICE_AGENT_BROWSER_MANAGER_H_
#define DEVICE_AGENT_BROWSER_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.browser` for Linux — sirf
// Chrome/Chromium ko `--remote-debugging-port` ke saath launch karta
// hai. Asal control Dart ke `CdpClient` se hoti hai (Windows jaisa hi).
void browser_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_BROWSER_MANAGER_H_
