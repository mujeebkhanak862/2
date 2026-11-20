# Native capability audit — Stage 9 (Android Kotlin / Windows C++ / Linux C++)

**Method:** source read (grep + targeted reading of each handler). **Nothing was compiled or executed** (no Dart/Flutter/Gradle/MSVC/GCC in the audit sandbox), so no native cell is "Supported". Labels: **Supported** (executed test passed — none yet) · **Partial** (code present, known limitation) · **Permission required** (OS grant needed; code returns a structured error) · **Not supported** · **Unverified** (code present, never executed).

| Capability | Android (Kotlin) | Windows (C++/WinRT) | Linux (C++/GTK) |
|---|---|---|---|
| Screen snapshot | Unverified — MediaProjection foreground service; needs user consent via UI (headless => `NEEDS_UI`; no service => `PERMISSION_REQUIRED` after Stage 9) | Unverified — Windows.Graphics.Capture (needs Win10 1903+; `IsSupported()` checked; `NOT_READY` if no frame in 1.5 s) | X11: Unverified (`XGetImage`). Wayland: Permission required (portal consent dialog) + Unverified (PipeWire path) |
| Screen live stream | Partial — frames only when screen content changes; honest `first_frame_received` flag | Unverified | X11 Unverified (poll); Wayland Unverified |
| Input tap/swipe/type | Permission required — AccessibilityService; `SERVICE_DISABLED` when off; `dispatchGesture` result reported | Partial — `SendInput`; UIPI blocks injection into elevated windows (returns false) | X11 Unverified (XTest; type via scratch keycode). Wayland: Permission required (RemoteDesktop portal) + Unverified |
| Files | Unverified — app sandbox root or user-picked SAF tree (persisted permission) | Unverified (603 lines, never run) | Unverified (561 lines, never run). Server-side traversal/size/type hardening IS unit-tested |
| App launcher | Unverified — `<queries>` LAUNCHER intent present (Android 11+ visibility OK); `NOT_FOUND` if absent | Unverified — hardened `ShellExecuteW` (no arbitrary path/URL) | Unverified — launches by desktop-file id via GAppInfo, no arbitrary command |
| Browser automation | Partial — `openUrl` http/https only; findAndClick/Type/getVisibleText need the AccessibilityService | Unverified — launches Chrome via `CreateProcessW` | Unverified — spawns chrome/chromium (`LAUNCH_FAILED` if missing) |
| Clipboard | Partial — Android 10+ blocks background clipboard reads (code returns an error, not fake text) | Unverified (CF_UNICODETEXT) | Unverified (GTK blocking call) |
| Contacts | Permission required — READ_CONTACTS (`PERMISSION_DENIED`) | Partial — WinRT Contacts API; code comment says unreliable for non-MSIX apps. (Old matrix said "OS limitation" — wrong) | Partial — Evolution Data Server; `EDS_UNAVAILABLE` if not installed. (Old matrix: wrong) |
| Location | Permission required — `PERMISSION_DENIED` / `LOCATION_DISABLED` | Permission required — single `LOCATION_UNAVAILABLE` code (denied vs unavailable not distinguished) | Partial — GeoClue2 over D-Bus |
| Network metadata | Unverified (no Wi-Fi password exposed — read-checked earlier) | Unverified (WLAN API; no password) | Unverified (NetworkManager) |
| Lock / sleep state | Unverified — KeyguardManager + PowerManager + screen broadcasts; states incl. `SCREEN_OFF` | Partial — `OpenInputDesktop` poll every 2 s; only LOCKED/UNLOCKED (no sleep/screen-off) | Partial — D-Bus ScreenSaver (freedesktop + GNOME); LOCKED/UNLOCKED only; depends on the desktop providing the service |
| Notifications read | Permission required — NotificationListener access; secret notifications skipped; memory only | Not supported | Not supported |
| Messaging read/reply | Partial — per-app filter (local UI) + 7 supported apps via inline-reply; others `UNSUPPORTED_TARGET`; `delivery: handed_to_app` | Not supported | Not supported |
| Background / persistence | Partial — foreground service + headless engine; reboot auto-start via `BootReceiver` (unverified; OEM may block); force-stop kills it | Unverified — tray icon present; no verified autostart/service | Unverified |
| Pairing / device id | Unverified (SecureRandom code) | Unverified | Unverified |

## Build-risk notes (not verifiable here)
- Linux CMake deps (gtk, glib, pipewire, x11/xtst, turbojpeg, libebook) match the apt packages in `.github/workflows/ci.yml`.
- Stage 9: `-Werror` (Linux) and `/WX` (Windows) are now **opt-in** (`-DDEVICE_AGENT_WERROR=ON`) so one warning in blind-written C++ does not fail the whole build. Turn it back on after the first clean build.
- Windows needs C++/WinRT + Windows SDK on the CI image; Android needs the Gradle versions bumped in Stage 9 to match the Flutter the CI picks.

## What turns Unverified into Supported
Run `REAL_DEVICE_TEST_MATRIX.md` on a real Android 12–15 phone, a Windows 10/11 PC and a Linux X11 + Wayland machine, and record pass/fail per cell.
