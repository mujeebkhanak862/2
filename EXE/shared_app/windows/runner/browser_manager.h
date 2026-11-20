// browser_manager.h
#ifndef DEVICE_AGENT_BROWSER_MANAGER_H_
#define DEVICE_AGENT_BROWSER_MANAGER_H_

#include <flutter/flutter_engine.h>

// Native side of `ChannelNames.browser` for Windows — sirf Chrome/Edge ko
// `--remote-debugging-port` ke saath launch karta hai. Asal control
// (navigate/click/type/read) Dart ke `CdpClient` (WebSocket, CDP) se hoti
// hai — is capability ka native hissa jaan-bujh kar chhota rakha gaya hai.
class BrowserManager {
 public:
  static void Register(flutter::FlutterEngine* engine);
};

#endif  // DEVICE_AGENT_BROWSER_MANAGER_H_
