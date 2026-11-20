// pairing_manager.h
#ifndef DEVICE_AGENT_PAIRING_MANAGER_H_
#define DEVICE_AGENT_PAIRING_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.pairing` ("device_agent/pairing") for
// Linux/ChromeOS. Same contract as Android/Windows: "generatePairingCode"
// and "getDeviceId".
void pairing_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_PAIRING_MANAGER_H_
