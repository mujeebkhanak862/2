// pairing_manager.cpp
#include "pairing_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <random>
#include <sstream>
#include <string>

namespace {
constexpr char kChannel[] = "device_agent/pairing";

// Machine GUID Windows registry se — reinstall ke baad bhi stable rehta hai
// (Android ke ANDROID_ID jaisa stable per-machine identity).
std::string GetDeviceId() {
  HKEY hKey;
  std::string result = "unknown-device";
  if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,
                     "SOFTWARE\\Microsoft\\Cryptography", 0,
                     KEY_READ | KEY_WOW64_64KEY, &hKey) == ERROR_SUCCESS) {
    char buffer[64];
    DWORD bufferSize = sizeof(buffer);
    if (RegQueryValueExA(hKey, "MachineGuid", nullptr, nullptr,
                          reinterpret_cast<LPBYTE>(buffer),
                          &bufferSize) == ERROR_SUCCESS) {
      result = std::string(buffer, bufferSize - 1);
    }
    RegCloseKey(hKey);
  }
  return result;
}

// 6-digit human-typeable code — Android side ke equivalent.
std::string GenerateCode() {
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<int> dist(100000, 999999);
  return std::to_string(dist(gen));
}
}  // namespace

void PairingManager::Register(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "generatePairingCode") {
          result->Success(flutter::EncodableValue(GenerateCode()));
        } else if (call.method_name() == "getDeviceId") {
          result->Success(flutter::EncodableValue(GetDeviceId()));
        } else {
          result->NotImplemented();
        }
      });
}
