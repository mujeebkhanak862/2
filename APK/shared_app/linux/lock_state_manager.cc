// lock_state_manager.cc
#include "lock_state_manager.h"

#include <gio/gio.h>

#include <string>

namespace {
constexpr char kMethodChannel[] = "device_agent/lock_state";
constexpr char kEventChannel[] = "device_agent/lock_state_events";
constexpr char kScreenSaverService[] = "org.freedesktop.ScreenSaver";
constexpr char kScreenSaverPath[] = "/org/freedesktop/ScreenSaver";
constexpr char kScreenSaverInterface[] = "org.freedesktop.ScreenSaver";

FlEventChannel* g_event_channel = nullptr;
GDBusConnection* g_dbus_connection = nullptr;
guint g_signal_subscription_id = 0;
guint g_signal_subscription_id_gnome = 0;

// `org.freedesktop.ScreenSaver.GetActive()` se poochta hai. Service bus
// par mil hi na paaye (koi locker registered nahi — dekhein header
// comment) ya call fail ho jaaye, to optimistic default `false`
// (ONLINE_UNLOCKED) rakhte hain — kabhi bhi galti se "LOCKED" guess
// nahi karte jab humein pata hi nahi.
// Item 83: pehle sirf `org.freedesktop.ScreenSaver` poochha jata tha. GNOME
// (sabse common desktop) par woh service nahi hoti, to `GetActive` fail
// hota tha aur humesha "ONLINE_UNLOCKED" report hota tha — locked screen
// par bhi. Ab GNOME ka apna interface bhi try hota hai; dono fail hon to
// bhi honest default (unlocked) hi rehta hai.
struct ScreenSaverEndpoint {
  const char* service;
  const char* path;
  const char* interface;
};
const ScreenSaverEndpoint kEndpoints[] = {
    {kScreenSaverService, kScreenSaverPath, kScreenSaverInterface},
    {"org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver"},
};

bool QueryScreenSaverActive(GDBusConnection* connection) {
  if (connection == nullptr) return false;
  for (const auto& ep : kEndpoints) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(
        connection, ep.service, ep.path, ep.interface, "GetActive", nullptr,
        G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 500 /* ms timeout */,
        nullptr, &error);
    if (result == nullptr) continue;  // agla endpoint try karo
    gboolean active = FALSE;
    g_variant_get(result, "(b)", &active);
    return active == TRUE;
  }
  return false;
}

std::string ComputeState(GDBusConnection* connection) {
  return QueryScreenSaverActive(connection) ? "ONLINE_LOCKED" : "ONLINE_UNLOCKED";
}

void OnActiveChangedSignal(GDBusConnection* connection, const gchar* sender_name,
                            const gchar* object_path, const gchar* interface_name,
                            const gchar* signal_name, GVariant* parameters,
                            gpointer user_data) {
  if (g_event_channel == nullptr) return;
  gboolean active = FALSE;
  g_variant_get(parameters, "(b)", &active);
  const std::string state = active ? "ONLINE_LOCKED" : "ONLINE_UNLOCKED";
  g_autoptr(FlValue) value = fl_value_new_string(state.c_str());
  fl_event_channel_send(g_event_channel, value, nullptr, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "currentState") == 0) {
    const std::string state = ComputeState(g_dbus_connection);
    g_autoptr(FlValue) result = fl_value_new_string(state.c_str());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Lock-state channel response failed: %s", error->message);
  }
}

static FlMethodErrorResponse* OnEventListen(FlEventChannel* channel,
                                             FlValue* args,
                                             gpointer user_data) {
  // Listener attach hote hi turant current value (Android/Windows ke
  // jaisa hi contract), phir future changes ke liye D-Bus signal
  // subscribe karte hain — koi poll nahi, GLib main loop khud deliver
  // karega jab bhi `ActiveChanged` fire ho.
  const std::string state = ComputeState(g_dbus_connection);
  g_autoptr(FlValue) value = fl_value_new_string(state.c_str());
  fl_event_channel_send(g_event_channel, value, nullptr, nullptr);

  if (g_dbus_connection != nullptr && g_signal_subscription_id == 0) {
    g_signal_subscription_id = g_dbus_connection_signal_subscribe(
        g_dbus_connection, kScreenSaverService, kScreenSaverInterface,
        "ActiveChanged", kScreenSaverPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        OnActiveChangedSignal, nullptr, nullptr);
    g_signal_subscription_id_gnome = g_dbus_connection_signal_subscribe(
        g_dbus_connection, "org.gnome.ScreenSaver", "org.gnome.ScreenSaver",
        "ActiveChanged", "/org/gnome/ScreenSaver", nullptr,
        G_DBUS_SIGNAL_FLAGS_NONE, OnActiveChangedSignal, nullptr, nullptr);
  }
  return nullptr;
}

static FlMethodErrorResponse* OnEventCancel(FlEventChannel* channel,
                                             FlValue* args,
                                             gpointer user_data) {
  if (g_dbus_connection != nullptr && g_signal_subscription_id != 0) {
    g_dbus_connection_signal_unsubscribe(g_dbus_connection, g_signal_subscription_id);
    g_signal_subscription_id = 0;
    if (g_signal_subscription_id_gnome != 0) {
      g_dbus_connection_signal_unsubscribe(g_dbus_connection,
                                           g_signal_subscription_id_gnome);
      g_signal_subscription_id_gnome = 0;
    }
  }
  return nullptr;
}
}  // namespace

void lock_state_manager_register(FlEngine* engine) {
  g_autoptr(GError) error = nullptr;
  // Session bus se connect ek hi baar karte hain aur poore process
  // lifetime ke liye rakhte hain (deliberately leaked — same pattern
  // baaki managers ke static/global handles ka hai).
  g_dbus_connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (g_dbus_connection == nullptr) {
    g_warning("Lock-state: session D-Bus connect nahi ho saka: %s",
              error ? error->message : "unknown error");
  }

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);

  FlMethodChannel* method_channel = fl_method_channel_new(
      messenger, kMethodChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(method_channel, method_call_cb,
                                             nullptr, nullptr);

  g_event_channel = fl_event_channel_new(messenger, kEventChannel,
                                          FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_event_channel, OnEventListen,
                                        OnEventCancel, nullptr, nullptr);
}
