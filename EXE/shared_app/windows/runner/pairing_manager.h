// pairing_manager.h
#ifndef DEVICE_AGENT_PAIRING_MANAGER_H_
#define DEVICE_AGENT_PAIRING_MANAGER_H_

#include <flutter/flutter_engine.h>

// Native side of `ChannelNames.pairing` ("device_agent/pairing") for
// Windows. Same contract as Android's PairingManager.kt: handles
// "generatePairingCode" and "getDeviceId".
class PairingManager {
 public:
  static void Register(flutter::FlutterEngine* engine);
};

#endif  // DEVICE_AGENT_PAIRING_MANAGER_H_
