// browser_manager.cc
#include "browser_manager.h"

#include <glib.h>

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace {
constexpr char kChannel[] = "device_agent/browser";

std::string FindBrowserExecutable() {
  for (const char* name : {"google-chrome-stable", "google-chrome",
                            "chromium-browser", "chromium"}) {
    g_autofree gchar* path = g_find_program_in_path(name);
    if (path != nullptr) return std::string(path);
  }
  return "";
}

fs::path BrowserProfileDir() {
  fs::path root =
      fs::path(g_get_user_data_dir()) / "device-agent" / "browser-profile";
  std::error_code ec;
  fs::create_directories(root, ec);
  return root;
}

bool LaunchBrowserWithDebugPort(int port) {
  std::string exe = FindBrowserExecutable();
  if (exe.empty()) return false;

  std::string port_arg = "--remote-debugging-port=" + std::to_string(port);
  std::string profile_arg =
      "--user-data-dir=" + BrowserProfileDir().string();

  gchar* argv[] = {
      const_cast<gchar*>(exe.c_str()),
      const_cast<gchar*>(port_arg.c_str()),
      const_cast<gchar*>(profile_arg.c_str()),
      const_cast<gchar*>("--no-first-run"),
      nullptr,
  };

  GError* error = nullptr;
  bool ok = g_spawn_async(nullptr, argv, nullptr, G_SPAWN_SEARCH_PATH,
                           nullptr, nullptr, nullptr, &error);
  if (error) g_error_free(error);
  return ok;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "launchDesktopBrowser") == 0) {
    // 9333 — Dart ke `BrowserBridge.desktopDebugPort` se match hona
    // chahiye.
    if (LaunchBrowserWithDebugPort(9333)) {
      g_autoptr(FlValue) result = fl_value_new_bool(true);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "LAUNCH_FAILED", "Chrome/Chromium nahi mila ya launch nahi ho saka",
          nullptr));
    }
  } else {
    // findAndClick/findAndType/getVisibleText/openUrl — Android-only
    // semantic methods, Linux/Windows par CdpClient use hota hai.
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Browser channel response failed: %s", error->message);
  }
}
}  // namespace

void browser_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                             nullptr);
}
