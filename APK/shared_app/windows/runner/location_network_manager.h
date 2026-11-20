// location_network_manager.h
#ifndef DEVICE_AGENT_LOCATION_NETWORK_MANAGER_H_
#define DEVICE_AGENT_LOCATION_NETWORK_MANAGER_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Native side of `ChannelNames.locationNetwork` for Windows —
// `Windows.Devices.Geolocation.Geolocator` (WinRT) for location,
// WLAN API (`wlanapi.h`) for connected Wi-Fi SSID.
class LocationNetworkManager {
 public:
  static void Register(flutter::FlutterEngine* engine);
};

#endif  // DEVICE_AGENT_LOCATION_NETWORK_MANAGER_H_
