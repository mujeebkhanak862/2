// lock_state_manager.h
//
// Audit fix (P1-05, Section 13 #6): "Real lock-state detection — no
// Windows session-lock API integration found." Native side of
// `ChannelNames.lockState` / `ChannelNames.lockStateEvents` for Windows.
//
// **Detection technique**: `OpenInputDesktop()`. Windows switches to a
// separate, non-interactive "secure desktop" (Winlogon) whenever the
// workstation is locked (Win+L, idle-lock, Ctrl+Alt+Del screen) — while
// that secure desktop is active, `OpenInputDesktop(0, FALSE,
// DESKTOP_SWITCHDESKTOP)` from a normal user-session process fails with
// `ERROR_ACCESS_DENIED`. This is the same technique Windows service/
// session-monitoring tools commonly use and needs no extra permission or
// admin rights — just a normal desktop-session process. It's a *poll*
// (see `kPollIntervalMs`), not a true push notification (the more
// "proper" mechanism, `WTSRegisterSessionNotification` + intercepting
// `WM_WTSSESSION_CHANGE` in the window's message loop, would need
// wiring into `FlutterWindow::MessageHandler`, which this pass keeps
// out of scope) — a short poll interval (2s) makes this an acceptable,
// low-overhead stand-in that still gives near-real-time updates.
//
// **Honest gap**: this reliably detects LOCKED vs UNLOCKED. It does NOT
// distinguish "monitor physically off" or OS sleep/hibernate as a
// separate state from "unlocked" — Windows desktops don't expose a
// simple, permission-free "is the monitor currently powered" API the
// way Android's `PowerManager.isInteractive()` does. `SCREEN_OFF`/
// `SLEEPING` are therefore not emitted from this manager; only
// `ONLINE_LOCKED` and `ONLINE_UNLOCKED` are (server's `OFFLINE`/
// `POWERED_OFF` come from connection status, handled server-side).
#ifndef DEVICE_AGENT_LOCK_STATE_MANAGER_H_
#define DEVICE_AGENT_LOCK_STATE_MANAGER_H_

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <windows.h>

#include <memory>
#include <string>

class LockStateManager {
 public:
  static void Register(flutter::FlutterEngine* engine);
  ~LockStateManager();

 private:
  explicit LockStateManager(flutter::FlutterEngine* engine);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static std::string ComputeState();

  void StartPolling();
  void StopPolling();
  static void CALLBACK TimerProc(HWND hwnd, UINT message, UINT_PTR timer_id,
                                  DWORD elapsed_ms);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  UINT_PTR timer_id_ = 0;
  std::string last_state_;

  static constexpr UINT kPollIntervalMs = 2000;

  // `TimerProc` static hone ki wajah se current instance tak wapas aane
  // ke liye — is scale (ek hi LockStateManager, poore app lifetime mein)
  // ke liye ek static back-pointer kaafi hai, extra registry/map ki
  // zaroorat nahi.
  static LockStateManager* active_instance_;
};

#endif  // DEVICE_AGENT_LOCK_STATE_MANAGER_H_
