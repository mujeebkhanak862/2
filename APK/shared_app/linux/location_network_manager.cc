// location_network_manager.cc
#include "location_network_manager.h"

#include <gio/gio.h>
#include <dirent.h>

#include <fstream>

#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace {
constexpr char kChannel[] = "device_agent/location_network";

std::string IsoTimestampNow() {
  auto now = std::chrono::system_clock::now();
  std::time_t t = std::chrono::system_clock::to_time_t(now);
  std::tm tm_utc;
  gmtime_r(&t, &tm_utc);
  std::ostringstream ss;
  ss << std::put_time(&tm_utc, "%Y-%m-%dT%H:%M:%SZ");
  return ss.str();
}

GDBusConnection* GetBus() {
  static GDBusConnection* bus = nullptr;
  if (bus == nullptr) {
    GError* error = nullptr;
    bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &error);
    // GeoClue2 aur NetworkManager dono **system** bus par hain — Wayland
    // portals (session bus) se alag, is baat ka dhyaan rakhna zaroori
    // hai warna calls silently fail hote hain.
    if (error) g_error_free(error);
  }
  return bus;
}

double GetDoubleProperty(GDBusConnection* bus, const char* bus_name,
                          const char* path, const char* iface,
                          const char* prop) {
  GError* error = nullptr;
  GVariant* result = g_dbus_connection_call_sync(
      bus, bus_name, path, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", iface, prop), G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (result == nullptr) {
    if (error) g_error_free(error);
    return 0.0;
  }
  GVariant* variant = nullptr;
  g_variant_get(result, "(v)", &variant);
  double value = g_variant_get_double(variant);
  g_variant_unref(variant);
  g_variant_unref(result);
  return value;
}

// GeoClue2: CreateClient -> DesktopId set -> Start -> LocationUpdated
// signal ka wait (yahi step OS-level consent dialog trigger karta hai,
// polkit ke through) -> Location object se lat/lon/accuracy.
bool TryGetLocationGeoClue(double* lat, double* lon, double* accuracy_m) {
  GDBusConnection* bus = GetBus();
  if (bus == nullptr) return false;

  GError* error = nullptr;
  GVariant* client_result = g_dbus_connection_call_sync(
      bus, "org.freedesktop.GeoClue2", "/org/freedesktop/GeoClue2/Manager",
      "org.freedesktop.GeoClue2.Manager", "CreateClient", nullptr,
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (client_result == nullptr) {
    if (error) g_error_free(error);
    return false;
  }
  const gchar* client_path = nullptr;
  g_variant_get(client_result, "(&o)", &client_path);

  // DesktopId set karna GeoClue2 ke liye required hai (identify karta hai
  // kaun sa app location maang raha hai — consent dialog mein bhi
  // dikhta hai).
  g_dbus_connection_call_sync(
      bus, "org.freedesktop.GeoClue2", client_path,
      "org.freedesktop.DBus.Properties", "Set",
      g_variant_new("(ssv)", "org.freedesktop.GeoClue2.Client", "DesktopId",
                    g_variant_new_string("device-agent")),
      nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);

  // LocationUpdated signal ka wait shuru karne se **pehle** subscribe
  // karna zaroori hai (race-condition se bachne ke liye), phir Start().
  struct WaitCtx {
    GMainLoop* loop;
    std::string location_path;
    bool got_update = false;
  } ctx{g_main_loop_new(nullptr, FALSE), "", false};

  guint sub_id = g_dbus_connection_signal_subscribe(
      bus, "org.freedesktop.GeoClue2", "org.freedesktop.GeoClue2.Client",
      "LocationUpdated", client_path, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      [](GDBusConnection*, const gchar*, const gchar*, const gchar*,
         const gchar*, GVariant* parameters, gpointer user_data) {
        auto* c = static_cast<WaitCtx*>(user_data);
        const gchar* old_path = nullptr;
        const gchar* new_path = nullptr;
        g_variant_get(parameters, "(&o&o)", &old_path, &new_path);
        c->location_path = new_path;
        c->got_update = true;
        g_main_loop_quit(c->loop);
      },
      &ctx, nullptr);

  g_dbus_connection_call_sync(
      bus, "org.freedesktop.GeoClue2", client_path,
      "org.freedesktop.GeoClue2.Client", "Start", nullptr, nullptr,
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (error) {
    g_error_free(error);
    g_dbus_connection_signal_unsubscribe(bus, sub_id);
    g_main_loop_unref(ctx.loop);
    return false;
  }

  // 15 second timeout — GPS/Wi-Fi-based location fix mein waqt lag sakta
  // hai, aur consent dialog ke liye user-interaction time bhi.
  guint timeout_id = g_timeout_add(15000, [](gpointer user_data) -> gboolean {
    auto* c = static_cast<WaitCtx*>(user_data);
    g_main_loop_quit(c->loop);
    return G_SOURCE_REMOVE;
  }, &ctx);

  g_main_loop_run(ctx.loop);

  g_source_remove(timeout_id);
  g_dbus_connection_signal_unsubscribe(bus, sub_id);
  g_main_loop_unref(ctx.loop);

  // Client ko stop karna chahiye (background mein na chalta rahe).
  g_dbus_connection_call_sync(
      bus, "org.freedesktop.GeoClue2", client_path,
      "org.freedesktop.GeoClue2.Client", "Stop", nullptr, nullptr,
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);

  if (!ctx.got_update || ctx.location_path.empty()) return false;

  *lat = GetDoubleProperty(bus, "org.freedesktop.GeoClue2",
                            ctx.location_path.c_str(),
                            "org.freedesktop.GeoClue2.Location", "Latitude");
  *lon = GetDoubleProperty(bus, "org.freedesktop.GeoClue2",
                            ctx.location_path.c_str(),
                            "org.freedesktop.GeoClue2.Location", "Longitude");
  *accuracy_m = GetDoubleProperty(
      bus, "org.freedesktop.GeoClue2", ctx.location_path.c_str(),
      "org.freedesktop.GeoClue2.Location", "Accuracy");
  return true;
}

// NetworkManager: primary connection type + (agar WIFI hai to) connected
// access point ka SSID.
void GetNetworkStatusNM(bool* connected, std::string* connection_type,
                         std::string* ssid) {
  *connected = false;
  *connection_type = "NONE";
  ssid->clear();

  GDBusConnection* bus = GetBus();
  if (bus == nullptr) return;

  GError* error = nullptr;
  GVariant* result = g_dbus_connection_call_sync(
      bus, "org.freedesktop.NetworkManager",
      "/org/freedesktop/NetworkManager", "org.freedesktop.DBus.Properties",
      "Get",
      g_variant_new("(ss)", "org.freedesktop.NetworkManager",
                    "PrimaryConnectionType"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (result == nullptr) {
    if (error) g_error_free(error);
    return;
  }
  GVariant* variant = nullptr;
  g_variant_get(result, "(v)", &variant);
  std::string nm_type = g_variant_get_string(variant, nullptr);
  g_variant_unref(variant);
  g_variant_unref(result);

  if (nm_type.empty()) return;  // koi primary connection nahi
  *connected = true;

  if (nm_type == "802-11-wireless") {
    *connection_type = "WIFI";
  } else if (nm_type == "802-3-ethernet") {
    *connection_type = "ETHERNET";
  } else if (nm_type.find("gsm") != std::string::npos ||
             nm_type.find("cdma") != std::string::npos) {
    *connection_type = "CELLULAR";
  } else {
    *connection_type = "OTHER";
  }

  if (*connection_type != "WIFI") return;

  // SSID: saare devices enumerate karke wireless device ki
  // ActiveAccessPoint dhoondhte hain.
  GVariant* devices_result = g_dbus_connection_call_sync(
      bus, "org.freedesktop.NetworkManager",
      "/org/freedesktop/NetworkManager", "org.freedesktop.NetworkManager",
      "GetDevices", nullptr, G_VARIANT_TYPE("(ao)"), G_DBUS_CALL_FLAGS_NONE,
      -1, nullptr, nullptr);
  if (devices_result == nullptr) return;

  GVariantIter iter;
  g_variant_iter_init(&iter, g_variant_get_child_value(devices_result, 0));
  const gchar* device_path = nullptr;
  while (g_variant_iter_next(&iter, "&o", &device_path)) {
    GVariant* dtype_result = g_dbus_connection_call_sync(
        bus, "org.freedesktop.NetworkManager", device_path,
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.freedesktop.NetworkManager.Device",
                      "DeviceType"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
    if (dtype_result == nullptr) continue;
    GVariant* dtype_variant = nullptr;
    g_variant_get(dtype_result, "(v)", &dtype_variant);
    guint32 device_type = g_variant_get_uint32(dtype_variant);
    g_variant_unref(dtype_variant);
    g_variant_unref(dtype_result);

    constexpr guint32 kNmDeviceTypeWifi = 2;
    if (device_type != kNmDeviceTypeWifi) continue;

    GVariant* ap_result = g_dbus_connection_call_sync(
        bus, "org.freedesktop.NetworkManager", device_path,
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.freedesktop.NetworkManager.Device.Wireless",
                      "ActiveAccessPoint"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
    if (ap_result == nullptr) continue;
    GVariant* ap_variant = nullptr;
    g_variant_get(ap_result, "(v)", &ap_variant);
    const gchar* ap_path = g_variant_get_string(ap_variant, nullptr);

    if (ap_path != nullptr && g_strcmp0(ap_path, "/") != 0) {
      GVariant* ssid_result = g_dbus_connection_call_sync(
          bus, "org.freedesktop.NetworkManager", ap_path,
          "org.freedesktop.DBus.Properties", "Get",
          g_variant_new("(ss)", "org.freedesktop.NetworkManager.AccessPoint",
                        "Ssid"),
          G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
      if (ssid_result != nullptr) {
        GVariant* ssid_variant = nullptr;
        g_variant_get(ssid_result, "(v)", &ssid_variant);
        gsize len = 0;
        const guchar* bytes = static_cast<const guchar*>(
            g_variant_get_fixed_array(ssid_variant, &len, sizeof(guchar)));
        ssid->assign(reinterpret_cast<const char*>(bytes), len);
        g_variant_unref(ssid_variant);
        g_variant_unref(ssid_result);
      }
    }
    g_variant_unref(ap_variant);
    g_variant_unref(ap_result);
    break;
  }
  g_variant_unref(devices_result);
}

std::string GetStringArg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return "";
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return "";
  return fl_value_get_string(v);
}

// Item 32: battery % — /sys/class/power_supply/BAT*/capacity. Desktop
// (no battery) par -1 (Dart side null maanta hai).
static int ReadBatteryPercent() {
  DIR* dir = opendir("/sys/class/power_supply");
  if (dir == nullptr) return -1;
  int result = -1;
  while (dirent* entry = readdir(dir)) {
    std::string name = entry->d_name;
    if (name.rfind("BAT", 0) != 0) continue;
    std::ifstream f("/sys/class/power_supply/" + name + "/capacity");
    int pct = -1;
    if (f >> pct && pct >= 0 && pct <= 100) {
      result = pct;
      break;
    }
  }
  closedir(dir);
  return result;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "requestPermission") == 0) {
    double lat, lon, acc;
    bool ok = TryGetLocationGeoClue(&lat, &lon, &acc);
    g_autoptr(FlValue) result = fl_value_new_bool(ok);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));

  } else if (g_strcmp0(method, "getLocation") == 0) {
    double lat, lon, acc;
    if (TryGetLocationGeoClue(&lat, &lon, &acc)) {
      g_autoptr(FlValue) m = fl_value_new_map();
      fl_value_set_string_take(m, "latitude", fl_value_new_float(lat));
      fl_value_set_string_take(m, "longitude", fl_value_new_float(lon));
      fl_value_set_string_take(m, "accuracy_m", fl_value_new_float(acc));
      fl_value_set_string_take(m, "timestamp",
                                fl_value_new_string(IsoTimestampNow().c_str()));
      fl_value_set_string_take(m, "source", fl_value_new_string("geoclue2"));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(m));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "LOCATION_UNAVAILABLE",
          "GeoClue2 se location nahi mili (denied ya service unavailable)",
          nullptr));
    }

  } else if (g_strcmp0(method, "getBattery") == 0) {
    int pct = ReadBatteryPercent();
    g_autoptr(FlValue) v = pct >= 0 ? fl_value_new_int(pct) : fl_value_new_null();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(v));

  } else if (g_strcmp0(method, "getNetworkStatus") == 0) {
    bool connected = false;
    std::string connection_type, ssid;
    GetNetworkStatusNM(&connected, &connection_type, &ssid);

    g_autoptr(FlValue) m = fl_value_new_map();
    fl_value_set_string_take(m, "connected", fl_value_new_bool(connected));
    fl_value_set_string_take(
        m, "ssid", ssid.empty() ? fl_value_new_null() : fl_value_new_string(ssid.c_str()));
    fl_value_set_string_take(m, "connection_type",
                              fl_value_new_string(connection_type.c_str()));
    fl_value_set_string_take(m, "timestamp",
                              fl_value_new_string(IsoTimestampNow().c_str()));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(m));

  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Location/network channel response failed: %s", error->message);
  }
}
}  // namespace

void location_network_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                             nullptr);
}
