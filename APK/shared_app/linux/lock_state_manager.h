// lock_state_manager.h
//
// Audit fix (P1-05, Section 13 #6, last of the three platforms): real
// lock-state detection for Linux/ChromeOS. Native side of
// `ChannelNames.lockState` / `ChannelNames.lockStateEvents`.
//
// **Detection technique**: the `org.freedesktop.ScreenSaver` D-Bus
// interface (session bus) — `GetActive()` for a one-shot query and the
// `ActiveChanged(bool)` signal for **push** updates (no polling needed,
// unlike the Windows implementation — GDBus signal delivery runs on the
// same GLib main loop the GTK app already uses). This interface is
// implemented by GNOME Shell, KDE Plasma (kscreenlocker), and XFCE
// (via light-locker/xfce4-screensaver) — i.e. the desktop environments
// this Flutter Linux target actually ships on.
//
// **Honest gap**: minimal/tiling window-manager setups with no screen
// locker registered on `org.freedesktop.ScreenSaver` (bare i3/sway
// without a compatible locker, headless kiosk setups, etc.) won't have
// this service on the bus at all. In that case `GetActive()`/the signal
// subscription simply never fire — same "no fake success" philosophy as
// `ContactsBridge`'s Evolution Data Server caveat: we don't guess, we
// just never emit a lock event, and the device keeps reporting whatever
// state it last knew (or the server's own optimistic connect-time
// default if nothing was ever reported).
#ifndef DEVICE_AGENT_LOCK_STATE_MANAGER_H_
#define DEVICE_AGENT_LOCK_STATE_MANAGER_H_

#include <flutter_linux/flutter_linux.h>

// Native side of `ChannelNames.lockState` / `ChannelNames.lockStateEvents`.
void lock_state_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_LOCK_STATE_MANAGER_H_
