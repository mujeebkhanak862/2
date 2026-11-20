// app_launcher_manager.cc
#include "app_launcher_manager.h"

#include <gio/gdesktopappinfo.h>
#include <gio/gio.h>

namespace {
constexpr char kChannel[] = "device_agent/app_launcher";

std::string GetStringArg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return "";
  return fl_value_get_string(v);
}

// Item 12 (security fix): pehle yahan agar identifier koi desktop-file ID
// na ho, to `g_shell_parse_argv` + `g_spawn_async` se **koi bhi command**
// (`bash -c ...`) chal jaati thi — yani `apps` scope = remote code
// execution. Ab sirf woh identifiers launch hote hain jo
// `listInstalledApps` (installed, user-visible desktop apps) mein hain.
// Koi free-form command ya path nahi.
bool IsKnownDesktopId(const std::string& identifier) {
  if (identifier.empty()) return false;
  bool found = false;
  GList* all_apps = g_app_info_get_all();
  for (GList* l = all_apps; l != nullptr; l = l->next) {
    GAppInfo* app = G_APP_INFO(l->data);
    if (!g_app_info_should_show(app)) continue;
    const char* id = g_app_info_get_id(app);
    if (id != nullptr && identifier == id) {
      found = true;
      break;
    }
  }
  g_list_free_full(all_apps, g_object_unref);
  return found;
}

bool LaunchByIdentifier(const std::string& identifier) {
  if (!IsKnownDesktopId(identifier)) return false;
  g_autoptr(GDesktopAppInfo) desktop_info =
      g_desktop_app_info_new(identifier.c_str());
  if (desktop_info == nullptr) return false;
  g_autoptr(GError) error = nullptr;
  return g_app_info_launch(G_APP_INFO(desktop_info), nullptr, nullptr, &error);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "launchApp") == 0) {
    std::string identifier = GetStringArg(args, "identifier");
    bool ok = LaunchByIdentifier(identifier);
    if (ok) {
      g_autoptr(FlValue) result = fl_value_new_bool(true);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "LAUNCH_FAILED", "App launch nahi ho saki", nullptr));
    }

  } else if (g_strcmp0(method, "isAppInstalled") == 0) {
    std::string identifier = GetStringArg(args, "identifier");
    // Item 12: arbitrary executable path ko "installed" nahi maante.
    bool installed = IsKnownDesktopId(identifier);
    g_autoptr(FlValue) result = fl_value_new_bool(installed);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));

  } else if (g_strcmp0(method, "listInstalledApps") == 0) {
    g_autoptr(FlValue) list = fl_value_new_list();
    GList* all_apps = g_app_info_get_all();
    for (GList* l = all_apps; l != nullptr; l = l->next) {
      GAppInfo* app = G_APP_INFO(l->data);
      if (!g_app_info_should_show(app)) continue;
      g_autoptr(FlValue) m = fl_value_new_map();
      fl_value_set_string_take(m, "identifier",
                                fl_value_new_string(g_app_info_get_id(app)));
      fl_value_set_string_take(
          m, "name", fl_value_new_string(g_app_info_get_display_name(app)));
      fl_value_append(list, m);
    }
    g_list_free_full(all_apps, g_object_unref);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));

  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("App launcher response failed: %s", error->message);
  }
}
}  // namespace

void app_launcher_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                             nullptr);
}
