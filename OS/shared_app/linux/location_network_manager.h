// location_network_manager.h
#ifndef DEVICE_AGENT_LOCATION_NETWORK_MANAGER_H_
#define DEVICE_AGENT_LOCATION_NETWORK_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.locationNetwork` for Linux —
// `org.freedesktop.GeoClue2` (DBus) for location — jo khud ek consent
// dialog dikhata hai (agentless clients ke liye polkit-based prompt) —
// aur `org.freedesktop.NetworkManager` (DBus) for SSID/connection type.
void location_network_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_LOCATION_NETWORK_MANAGER_H_
