// wayland_portal_session.h
#ifndef DEVICE_AGENT_WAYLAND_PORTAL_SESSION_H_
#define DEVICE_AGENT_WAYLAND_PORTAL_SESSION_H_

#include <gio/gio.h>

#include <cstdint>
#include <string>

// Ek hi shared `org.freedesktop.portal.Session` — Screen Capture
// (ScreenCast interface) aur Input (RemoteDesktop interface) dono isi ek
// session ko use karte hain, jaisa real xdg-desktop-portal apps
// (OBS Studio, GNOME Remote Desktop, waghera) karte hain.
//
// Yeh combine karna zaroori hai kyunki:
//  1. User ko sirf EK consent dialog dikhta hai (do alag dialogs ki jagah).
//  2. `RemoteDesktop.NotifyPointerMotionAbsolute` ka `stream` parameter
//     asal mein woh PipeWire node id hai jo `ScreenCast.Start` deta hai —
//     agar RemoteDesktop apna independent session banaye jisme
//     SelectSources kabhi hui hi nahi, to koi valid node id exist hi nahi
//     karta is se pehle. Combined session mein yeh sahi se milta hai.
//
// Thread-safety note: portal calls (CallPortalMethod) blocking hain
// (nested GMainLoop), isliye yeh class single-threaded UI/DBus context se
// hi use honi chahiye — jo yahan MethodChannel handlers ka hi context hai.
class WaylandPortalSession {
 public:
  // Idempotent — pehli successful call ke baad session already ready hai,
  // dobara consent dialog nahi maangta. `need_screencast` /
  // `need_remote_desktop` dono flags batate hain kaunsi capability chahiye
  // — pehli baar jo bhi combination maanga jaaye, session usi se banta
  // hai (dono ek saath select ho jaate hain taaki baad mein doosri
  // capability add karne ke liye session dobara banana na pade).
  static bool EnsureReady(bool need_screencast, bool need_remote_desktop);

  static std::string SessionHandle();
  static uint32_t PipeWireNodeId();
  static int PipeWireFd();
  static bool IsReady();

  // Session poori tarah band — agla EnsureReady() naya consent dialog
  // maangega.
  static void Close();

 private:
  static GDBusConnection* GetBus();

  static std::string session_handle_;
  static uint32_t pipewire_node_id_;
  static int pipewire_fd_;
  static bool screencast_enabled_;
  static bool remote_desktop_enabled_;
  static bool started_;
};

#endif  // DEVICE_AGENT_WAYLAND_PORTAL_SESSION_H_
