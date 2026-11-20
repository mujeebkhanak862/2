// pairing_manager.cc
#include "pairing_manager.h"

#include <fstream>
#include <random>
#include <sstream>
#include <string>

namespace {
constexpr char kChannel[] = "device_agent/pairing";

// systemd machine-id — Linux ka stable per-install identity, Android ke
// ANDROID_ID / Windows ke MachineGuid jaisa.
std::string GetDeviceId() {
  for (const char* path : {"/etc/machine-id", "/var/lib/dbus/machine-id"}) {
    std::ifstream f(path);
    if (f.is_open()) {
      std::string id;
      std::getline(f, id);
      if (!id.empty()) return id;
    }
  }
  return "unknown-device";
}

// 6-digit human-typeable code — Android/Windows side ke equivalent.
std::string GenerateCode() {
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<int> dist(100000, 999999);
  return std::to_string(dist(gen));
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "generatePairingCode") == 0) {
    g_autoptr(FlValue) result = fl_value_new_string(GenerateCode().c_str());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "getDeviceId") == 0) {
    g_autoptr(FlValue) result = fl_value_new_string(GetDeviceId().c_str());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Pairing channel response failed: %s", error->message);
  }
}
}  // namespace

void pairing_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                             nullptr);
}
