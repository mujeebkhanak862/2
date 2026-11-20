// input_wayland_portal.cc
#include "input_wayland_portal.h"
#include "wayland_portal_session.h"

#include <gio/gio.h>

#include <chrono>
#include <cstdint>
#include <sstream>
#include <thread>
#include <vector>

namespace {
constexpr char kPortalBusName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalObjectPath[] = "/org/freedesktop/portal/desktop";
constexpr char kRemoteDesktopIface[] = "org.freedesktop.portal.RemoteDesktop";

GDBusConnection* GetBus() {
  static GDBusConnection* bus = nullptr;
  if (bus == nullptr) {
    GError* error = nullptr;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (error) g_error_free(error);
  }
  return bus;
}

// X11 file jaisa hi convention — Latin-1 range mein keysym == codepoint,
// uske aage Unicode-keysym convention.
long CodepointToKeysym(uint32_t cp) {
  if (cp <= 0xFF) return static_cast<long>(cp);
  return 0x01000000L + static_cast<long>(cp);
}

std::vector<uint32_t> Utf8Decode(const std::string& s) {
  std::vector<uint32_t> out;
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = s[i];
    uint32_t cp = 0;
    int extra = 0;
    if ((c & 0x80) == 0) { cp = c; extra = 0; }
    else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; extra = 1; }
    else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; extra = 2; }
    else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; extra = 3; }
    else { i++; continue; }
    i++;
    bool valid = true;
    for (int k = 0; k < extra && i < s.size(); k++, i++) {
      unsigned char cc = s[i];
      if ((cc & 0xC0) != 0x80) { valid = false; break; }
      cp = (cp << 6) | (cc & 0x3F);
    }
    if (valid) out.push_back(cp);
  }
  return out;
}

// `stream` parameter ke liye ab asal PipeWire node id use hota hai —
// shared WaylandPortalSession se aata hai (0 nahi, jaisa pehle tha).
guint32 CurrentStreamId() {
  return static_cast<guint32>(WaylandPortalSession::PipeWireNodeId());
}
}  // namespace

bool InputWaylandPortal::IsAvailable() {
  const char* session_type = g_getenv("XDG_SESSION_TYPE");
  return session_type != nullptr && std::string(session_type) == "wayland";
}

bool InputWaylandPortal::EnsureSessionReady() {
  // Screen Capture ke saath hamesha combine karte hain (shared session) —
  // taaki NotifyPointerMotionAbsolute ko valid node id mile. Agar sirf
  // Input hi pehli baar use ho raha ho (Screen Capture kabhi trigger na
  // hui ho), tab bhi yeh dono capabilities ek saath select kar leta hai,
  // taaki baad mein Screen Capture use hone par dobara consent dialog na
  // maanga jaaye.
  return WaylandPortalSession::EnsureReady(/*need_screencast=*/true,
                                            /*need_remote_desktop=*/true);
}

bool InputWaylandPortal::Tap(double x, double y) {
  if (!EnsureSessionReady()) return false;
  GDBusConnection* bus = GetBus();
  const std::string& session_handle = WaylandPortalSession::SessionHandle();
  guint32 stream = CurrentStreamId();

  GVariantBuilder opts;
  g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
  g_dbus_connection_call_sync(
      bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
      "NotifyPointerMotionAbsolute",
      g_variant_new("(oa{sv}udd)", session_handle.c_str(), &opts, stream, x, y),
      nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);

  GVariantBuilder opts2;
  g_variant_builder_init(&opts2, G_VARIANT_TYPE("a{sv}"));
  // BTN_LEFT = 0x110 (Linux input-event-codes), state 1 = pressed.
  g_dbus_connection_call_sync(
      bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
      "NotifyPointerButton",
      g_variant_new("(oa{sv}iu)", session_handle.c_str(), &opts2, 0x110,
                     static_cast<guint32>(1)),
      nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);

  GVariantBuilder opts3;
  g_variant_builder_init(&opts3, G_VARIANT_TYPE("a{sv}"));
  g_dbus_connection_call_sync(
      bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
      "NotifyPointerButton",
      g_variant_new("(oa{sv}iu)", session_handle.c_str(), &opts3, 0x110,
                     static_cast<guint32>(0)),
      nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);

  return true;
}

bool InputWaylandPortal::Swipe(double x1, double y1, double x2, double y2,
                                int duration_ms) {
  if (!EnsureSessionReady()) return false;
  GDBusConnection* bus = GetBus();
  const std::string& session_handle = WaylandPortalSession::SessionHandle();
  guint32 stream = CurrentStreamId();

  {
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_dbus_connection_call_sync(
        bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
        "NotifyPointerMotionAbsolute",
        g_variant_new("(oa{sv}udd)", session_handle.c_str(), &opts, stream,
                       x1, y1),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
  }
  {
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_dbus_connection_call_sync(
        bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
        "NotifyPointerButton",
        g_variant_new("(oa{sv}iu)", session_handle.c_str(), &opts, 0x110,
                       static_cast<guint32>(1)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
  }

  const int steps = 20;
  for (int i = 1; i <= steps; i++) {
    double t = static_cast<double>(i) / steps;
    double x = x1 + (x2 - x1) * t;
    double y = y1 + (y2 - y1) * t;
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_dbus_connection_call_sync(
        bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
        "NotifyPointerMotionAbsolute",
        g_variant_new("(oa{sv}udd)", session_handle.c_str(), &opts, stream,
                       x, y),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
    std::this_thread::sleep_for(
        std::chrono::milliseconds(duration_ms > 0 ? duration_ms / steps : 5));
  }

  {
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_dbus_connection_call_sync(
        bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
        "NotifyPointerButton",
        g_variant_new("(oa{sv}iu)", session_handle.c_str(), &opts, 0x110,
                       static_cast<guint32>(0)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
  }

  return true;
}

bool InputWaylandPortal::TypeText(const std::string& utf8_text) {
  if (!EnsureSessionReady()) return false;
  GDBusConnection* bus = GetBus();
  const std::string& session_handle = WaylandPortalSession::SessionHandle();

  for (uint32_t cp : Utf8Decode(utf8_text)) {
    long keysym = CodepointToKeysym(cp);

    GVariantBuilder opts_down;
    g_variant_builder_init(&opts_down, G_VARIANT_TYPE("a{sv}"));
    g_dbus_connection_call_sync(
        bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
        "NotifyKeyboardKeysym",
        g_variant_new("(oa{sv}iu)", session_handle.c_str(), &opts_down,
                       static_cast<gint32>(keysym), static_cast<guint32>(1)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);

    GVariantBuilder opts_up;
    g_variant_builder_init(&opts_up, G_VARIANT_TYPE("a{sv}"));
    g_dbus_connection_call_sync(
        bus, kPortalBusName, kPortalObjectPath, kRemoteDesktopIface,
        "NotifyKeyboardKeysym",
        g_variant_new("(oa{sv}iu)", session_handle.c_str(), &opts_up,
                       static_cast<gint32>(keysym), static_cast<guint32>(0)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);

    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  return true;
}
