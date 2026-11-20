// wayland_portal_session.cc
#include "wayland_portal_session.h"

#include <functional>
#include <random>
#include <sstream>

std::string WaylandPortalSession::session_handle_;
uint32_t WaylandPortalSession::pipewire_node_id_ = 0;
int WaylandPortalSession::pipewire_fd_ = -1;
bool WaylandPortalSession::screencast_enabled_ = false;
bool WaylandPortalSession::remote_desktop_enabled_ = false;
bool WaylandPortalSession::started_ = false;

namespace {
constexpr char kPortalBusName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalObjectPath[] = "/org/freedesktop/portal/desktop";
constexpr char kScreenCastIface[] = "org.freedesktop.portal.ScreenCast";
constexpr char kRemoteDesktopIface[] = "org.freedesktop.portal.RemoteDesktop";
constexpr char kRequestIface[] = "org.freedesktop.portal.Request";

std::string RandomToken() {
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<int> dist(0, 15);
  std::stringstream ss;
  ss << "device_agent_session_";
  const char* hex = "0123456789abcdef";
  for (int i = 0; i < 16; i++) ss << hex[dist(gen)];
  return ss.str();
}

// xdg-desktop-portal spec ke mutabik Request object ka path deterministic
// hota hai: caller ki apni unique bus name (leading ':' hataake, baaki
// '.' ko '_' se replace karke) + caller ne jo `handle_token` diya tha.
std::string PredictRequestPath(GDBusConnection* bus, const std::string& handle_token) {
  const gchar* unique_name = g_dbus_connection_get_unique_name(bus);
  std::string sender = (unique_name != nullptr && unique_name[0] == ':')
                            ? (unique_name + 1)
                            : (unique_name ? unique_name : "");
  for (auto& c : sender) {
    if (c == '.') c = '_';
  }
  return "/org/freedesktop/portal/desktop/request/" + sender + "/" + handle_token;
}

/**
 * **Real bug jo yahan tha**: pehle yeh function `g_dbus_connection_call_sync`
 * (jo portal method call karta hai aur ek Request object path return karta
 * hai) call karta tha, aur **uske baad** us path ke "Response" signal ko
 * subscribe karta tha. Yeh ek classic race condition hai: agar portal
 * (khaaskar jab user pehle se permission de chuka ho, ya kisi fast/no-UI
 * portal backend ke saath) bahut jaldi respond kar de — subscribe se
 * *pehle* hi Response signal fire ho sakta hai. Aisi situation mein signal
 * hamesha ke liye miss ho jaata, aur `g_main_loop_run(ctx.loop)` kabhi
 * `quit` na hone ki wajah se **hang ho jaata** — poora screen-capture/
 * input-control flow Wayland par silently freeze ho jaata, kisi error ke
 * bina.
 *
 * Fix: xdg-desktop-portal spec khud batata hai ke Request object ka path
 * deterministic hota hai (caller ki bus identity + caller ka diya hua
 * `handle_token` se predictable) — is liye hum subscribe PEHLE karte hain
 * (predicted path par), method call BAAD mein. Ab race hi possible nahi.
 */
void CallPortalMethod(GDBusConnection* bus, const std::string& iface,
                       const std::string& method_name,
                       const std::string& handle_token, GVariant* params,
                       std::function<void(guint32, GVariant*)> on_response) {
  std::string request_path = PredictRequestPath(bus, handle_token);

  struct WaitCtx {
    GMainLoop* loop;
    guint32 code;
    GVariant* results;
  } ctx{g_main_loop_new(nullptr, FALSE), 1, nullptr};

  auto on_signal = [](GDBusConnection*, const gchar*, const gchar*,
                       const gchar*, const gchar*, GVariant* parameters,
                       gpointer user_data) {
    auto* c = static_cast<WaitCtx*>(user_data);
    guint32 code = 1;
    GVariant* results = nullptr;
    g_variant_get(parameters, "(u@a{sv})", &code, &results);
    c->code = code;
    c->results = results;
    g_main_loop_quit(c->loop);
  };

  guint sub_id = g_dbus_connection_signal_subscribe(
      bus, kPortalBusName, kRequestIface, "Response", request_path.c_str(),
      nullptr, G_DBUS_SIGNAL_FLAGS_NONE, on_signal, &ctx, nullptr);

  GError* error = nullptr;
  GVariant* result = g_dbus_connection_call_sync(
      bus, kPortalBusName, kPortalObjectPath, iface.c_str(),
      method_name.c_str(), params, G_VARIANT_TYPE("(o)"),
      G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (result == nullptr) {
    g_warning("Portal %s.%s failed: %s", iface.c_str(), method_name.c_str(),
              error ? error->message : "unknown");
    if (error) g_error_free(error);
    g_dbus_connection_signal_unsubscribe(bus, sub_id);
    g_main_loop_unref(ctx.loop);
    on_response(1, nullptr);
    return;
  }

  // Defense-in-depth: spec ke mutabik yeh hamesha predicted path se match
  // karna chahiye. Agar kisi wajah se na kare (koi non-compliant portal
  // backend), sirf warn karte hain — hang nahi hoga (worst case, thoda der
  // extra wait, real Response signal jab bhi aaye woh already-subscribed
  // path par hi match hoga agar prediction sahi thi, jo spec-guaranteed
  // hai).
  const gchar* actual_path = nullptr;
  g_variant_get(result, "(&o)", &actual_path);
  if (actual_path != nullptr && request_path != actual_path) {
    g_warning("Portal request path mismatch (predicted=%s actual=%s) — "
              "non-compliant portal backend?",
              request_path.c_str(), actual_path);
  }
  g_variant_unref(result);

  g_main_loop_run(ctx.loop);
  g_dbus_connection_signal_unsubscribe(bus, sub_id);
  g_main_loop_unref(ctx.loop);

  on_response(ctx.code, ctx.results);
  if (ctx.results) g_variant_unref(ctx.results);
}
}  // namespace

GDBusConnection* WaylandPortalSession::GetBus() {
  static GDBusConnection* bus = nullptr;
  if (bus == nullptr) {
    GError* error = nullptr;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (error) g_error_free(error);
  }
  return bus;
}

bool WaylandPortalSession::EnsureReady(bool need_screencast,
                                        bool need_remote_desktop) {
  // Already started aur jo chahiye tha woh already enabled hai — kuch
  // karne ki zaroorat nahi.
  if (started_ &&
      (!need_screencast || screencast_enabled_) &&
      (!need_remote_desktop || remote_desktop_enabled_)) {
    return true;
  }

  // Ek baar Start ho jaaye to session finalize ho jaata hai — agar naya
  // capability chahiye jo pehle select nahi hui thi, to poora session
  // dobara banana padega (naya consent dialog). Yeh sirf tab hota hai
  // jab app pehle sirf screen ya sirf input use kar rahi thi aur baad
  // mein doosri capability chahiye — dashboard/task_monitor flow mein
  // dono generally saath maangi jaati hain, isliye practically rare hai.
  if (started_) {
    Close();
  }

  GDBusConnection* bus = GetBus();
  if (bus == nullptr) return false;

  // ---- CreateSession — RemoteDesktop interface se, kyunki combined
  // session banane ka standard convention yahi hai (ScreenCast +
  // RemoteDesktop dono isi ek Session object ko refer kar sakte hain). ---
  std::string create_token = RandomToken();
  std::string session_token = RandomToken();
  GVariantBuilder create_opts;
  g_variant_builder_init(&create_opts, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&create_opts, "{sv}", "handle_token",
                         g_variant_new_string(create_token.c_str()));
  g_variant_builder_add(&create_opts, "{sv}", "session_handle_token",
                         g_variant_new_string(session_token.c_str()));

  bool create_ok = false;
  CallPortalMethod(
      bus, kRemoteDesktopIface, "CreateSession", create_token,
      g_variant_new("(a{sv})", &create_opts),
      [&](guint32 code, GVariant* results) {
        if (code != 0 || results == nullptr) return;
        const gchar* handle = nullptr;
        if (g_variant_lookup(results, "session_handle", "&s", &handle)) {
          session_handle_ = handle;
          create_ok = true;
        }
      });
  if (!create_ok || session_handle_.empty()) return false;

  // ---- SelectSources (ScreenCast) ----------------------------------------
  if (need_screencast) {
    std::string token = RandomToken();
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "handle_token",
                           g_variant_new_string(token.c_str()));
    g_variant_builder_add(&opts, "{sv}", "types",
                           g_variant_new_uint32(1));  // 1 = MONITOR
    g_variant_builder_add(&opts, "{sv}", "multiple", g_variant_new_boolean(FALSE));

    bool ok = false;
    CallPortalMethod(
        bus, kScreenCastIface, "SelectSources", token,
        g_variant_new("(oa{sv})", session_handle_.c_str(), &opts),
        [&](guint32 code, GVariant*) { ok = (code == 0); });
    if (!ok) {
      Close();
      return false;
    }
    screencast_enabled_ = true;
  }

  // ---- SelectDevices (RemoteDesktop) -------------------------------------
  if (need_remote_desktop) {
    std::string token = RandomToken();
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "handle_token",
                           g_variant_new_string(token.c_str()));
    g_variant_builder_add(&opts, "{sv}", "types",
                           g_variant_new_uint32(1 | 2));  // KEYBOARD | POINTER

    bool ok = false;
    CallPortalMethod(
        bus, kRemoteDesktopIface, "SelectDevices", token,
        g_variant_new("(oa{sv})", session_handle_.c_str(), &opts),
        [&](guint32 code, GVariant*) { ok = (code == 0); });
    if (!ok) {
      Close();
      return false;
    }
    remote_desktop_enabled_ = true;
  }

  // ---- Start — ek hi consent dialog, dono capabilities ke liye ----------
  // (SelectSources/SelectDevices khud koi dialog nahi dikhate; asal
  // combined-permission dialog Start se pehle ya Start ke dauran aata
  // hai, portal implementation ke hisaab se.)
  {
    std::string token = RandomToken();
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "handle_token",
                           g_variant_new_string(token.c_str()));

    const char* start_iface =
        need_remote_desktop ? kRemoteDesktopIface : kScreenCastIface;

    bool ok = false;
    CallPortalMethod(
        bus, start_iface, "Start", token,
        g_variant_new("(osa{sv})", session_handle_.c_str(), "", &opts),
        [&](guint32 code, GVariant* results) {
          if (code != 0) return;
          ok = true;
          if (results == nullptr || !need_screencast) return;
          GVariant* streams = g_variant_lookup_value(
              results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
          if (streams == nullptr) return;
          GVariantIter iter;
          g_variant_iter_init(&iter, streams);
          guint32 node_id;
          GVariant* stream_props;
          if (g_variant_iter_next(&iter, "(u@a{sv})", &node_id,
                                   &stream_props)) {
            pipewire_node_id_ = node_id;
            g_variant_unref(stream_props);
          }
          g_variant_unref(streams);
        });
    if (!ok) {
      Close();
      return false;
    }
    started_ = true;
  }

  // ---- OpenPipeWireRemote — sirf agar screen capture bhi chahiye --------
  if (need_screencast) {
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));

    GError* error = nullptr;
    GUnixFDList* fd_list = nullptr;
    GVariant* fd_result = g_dbus_connection_call_with_unix_fd_list_sync(
        bus, kPortalBusName, kPortalObjectPath, kScreenCastIface,
        "OpenPipeWireRemote",
        g_variant_new("(oa{sv})", session_handle_.c_str(), &opts),
        G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &fd_list,
        nullptr, &error);

    if (fd_result == nullptr || fd_list == nullptr) {
      if (error) g_error_free(error);
      Close();
      return false;
    }

    gint32 handle_index = 0;
    g_variant_get(fd_result, "(h)", &handle_index);
    pipewire_fd_ = g_unix_fd_list_get(fd_list, handle_index, &error);
    g_variant_unref(fd_result);
    g_object_unref(fd_list);

    if (pipewire_fd_ < 0) {
      Close();
      return false;
    }
  }

  return true;
}

std::string WaylandPortalSession::SessionHandle() { return session_handle_; }
uint32_t WaylandPortalSession::PipeWireNodeId() { return pipewire_node_id_; }
int WaylandPortalSession::PipeWireFd() { return pipewire_fd_; }
bool WaylandPortalSession::IsReady() { return started_; }

void WaylandPortalSession::Close() {
  GDBusConnection* bus = GetBus();
  if (bus != nullptr && !session_handle_.empty()) {
    g_dbus_connection_call(
        bus, kPortalBusName, session_handle_.c_str(),
        "org.freedesktop.portal.Session", "Close", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr, nullptr);
  }
  session_handle_.clear();
  pipewire_node_id_ = 0;
  pipewire_fd_ = -1;
  screencast_enabled_ = false;
  remote_desktop_enabled_ = false;
  started_ = false;
}
