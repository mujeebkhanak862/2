// location_network_manager.cpp
#include "location_network_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Devices.Geolocation.h>
#include <winrt/Windows.Foundation.h>

#include <wininet.h>
#include <windows.h>
#include <wlanapi.h>

#include <chrono>
#include <ctime>
#include <iomanip>
#include <memory>
#include <sstream>
#include <string>

#pragma comment(lib, "wlanapi.lib")
#pragma comment(lib, "wininet.lib")

using namespace winrt::Windows::Devices::Geolocation;

namespace {
constexpr char kChannel[] = "device_agent/location_network";

std::string IsoTimestampNow() {
  auto now = std::chrono::system_clock::now();
  std::time_t t = std::chrono::system_clock::to_time_t(now);
  std::tm tm_utc;
  gmtime_s(&tm_utc, &t);
  std::ostringstream ss;
  ss << std::put_time(&tm_utc, "%Y-%m-%dT%H:%M:%SZ");
  return ss.str();
}

// `RequestAccessAsync` unpackaged (non-MSIX) Win32 apps ke liye bhi kaam
// karta hai Windows 10+ par, bashart-e OS Settings > Privacy > Location
// mein "Desktop apps" ko access di gayi ho — yeh Windows ka apna consent
// surface hai (Section 6.6 jaisi hi philosophy, bas UI Settings app mein
// hai na ke in-app dialog).
bool TryGetLocation(double* lat, double* lon, double* accuracy_m) {
  try {
    auto access = Geolocator::RequestAccessAsync().get();
    if (access != GeolocationAccessStatus::Allowed) return false;

    Geolocator geolocator;
    Geoposition pos = geolocator.GetGeopositionAsync().get();
    auto coord = pos.Coordinate();
    *lat = coord.Latitude();
    *lon = coord.Longitude();
    *accuracy_m = coord.Accuracy();
    return true;
  } catch (...) {
    return false;
  }
}

// WLAN API se connected SSID — agar koi WLAN interface connected nahi hai
// to empty string (caller isse "not WIFI" treat karega).
std::string GetConnectedSsid(bool* is_wifi_connected) {
  *is_wifi_connected = false;
  HANDLE client = nullptr;
  DWORD negotiated_version = 0;
  if (WlanOpenHandle(2, nullptr, &negotiated_version, &client) != ERROR_SUCCESS) {
    return "";
  }

  std::string ssid;
  PWLAN_INTERFACE_INFO_LIST if_list = nullptr;
  if (WlanEnumInterfaces(client, nullptr, &if_list) == ERROR_SUCCESS) {
    for (DWORD i = 0; i < if_list->dwNumberOfItems; i++) {
      const WLAN_INTERFACE_INFO& info = if_list->InterfaceInfo[i];
      if (info.isState != wlan_interface_state_connected) continue;

      PWLAN_CONNECTION_ATTRIBUTES conn_attrs = nullptr;
      DWORD size = 0;
      WLAN_OPCODE_VALUE_TYPE opcode;
      if (WlanQueryInterface(client, &info.InterfaceGuid,
                              wlan_intf_opcode_current_connection, nullptr,
                              &size, reinterpret_cast<PVOID*>(&conn_attrs),
                              &opcode) == ERROR_SUCCESS) {
        const DOT11_SSID& dot11_ssid =
            conn_attrs->wlanAssociationAttributes.dot11Ssid;
        ssid.assign(reinterpret_cast<const char*>(dot11_ssid.ucSSID),
                     dot11_ssid.uSSIDLength);
        *is_wifi_connected = true;
        WlanFreeMemory(conn_attrs);
        break;
      }
    }
    WlanFreeMemory(if_list);
  }
  WlanCloseHandle(client, nullptr);
  return ssid;
}
}  // namespace

void LocationNetworkManager::Register(flutter::FlutterEngine* engine) {
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel](const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "requestPermission") {
          double lat, lon, acc;
          // Access status check karne ka sabse seedha tareeka khud
          // location lena try karna hai — agar access denied hai to
          // false aayega.
          bool ok = TryGetLocation(&lat, &lon, &acc);
          result->Success(flutter::EncodableValue(ok));

        } else if (call.method_name() == "getLocation") {
          double lat, lon, acc;
          if (TryGetLocation(&lat, &lon, &acc)) {
            flutter::EncodableMap m;
            m[flutter::EncodableValue("latitude")] = flutter::EncodableValue(lat);
            m[flutter::EncodableValue("longitude")] = flutter::EncodableValue(lon);
            m[flutter::EncodableValue("accuracy_m")] = flutter::EncodableValue(acc);
            m[flutter::EncodableValue("timestamp")] =
                flutter::EncodableValue(IsoTimestampNow());
            m[flutter::EncodableValue("source")] =
                flutter::EncodableValue(std::string("windows_geolocator"));
            result->Success(flutter::EncodableValue(m));
          } else {
            result->Error("LOCATION_UNAVAILABLE",
                           "Location access denied ya provider unavailable hai");
          }

        } else if (call.method_name() == "getBattery") {
          // Item 32: desktop par battery na ho to null.
          SYSTEM_POWER_STATUS sps;
          if (GetSystemPowerStatus(&sps) && sps.BatteryLifePercent <= 100) {
            result->Success(flutter::EncodableValue(
                static_cast<int>(sps.BatteryLifePercent)));
          } else {
            result->Success();
          }

        } else if (call.method_name() == "getNetworkStatus") {
          bool is_wifi = false;
          std::string ssid = GetConnectedSsid(&is_wifi);

          DWORD flags = 0;
          bool internet_connected = InternetGetConnectedState(&flags, 0);

          std::string connection_type = "NONE";
          if (is_wifi) {
            connection_type = "WIFI";
          } else if (internet_connected) {
            // WLAN connected nahi hai lekin internet available hai — Win32
            // ke paas generic "which adapter" API asaani se nahi hai
            // (NetworkListManager COM chahiye us detail ke liye), isliye
            // yahan simplified "ETHERNET" fallback assume karte hain.
            connection_type = "ETHERNET";
          }

          flutter::EncodableMap m;
          m[flutter::EncodableValue("connected")] =
              flutter::EncodableValue(is_wifi || internet_connected);
          m[flutter::EncodableValue("ssid")] =
              ssid.empty() ? flutter::EncodableValue()
                            : flutter::EncodableValue(ssid);
          m[flutter::EncodableValue("connection_type")] =
              flutter::EncodableValue(connection_type);
          m[flutter::EncodableValue("timestamp")] =
              flutter::EncodableValue(IsoTimestampNow());
          result->Success(flutter::EncodableValue(m));

        } else {
          result->NotImplemented();
        }
      });
}
