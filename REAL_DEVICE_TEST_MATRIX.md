# Real-device test matrix (item 94) — pass/fail yahan likhein

Pehle: `dart test` + `flutter test` green hon. Phir har row ko actual device par chalao.

| # | Test | Android | Windows | Linux X11 | Linux Wayland |
|---|---|---|---|---|---|
| 1 | Pair → restart app → **naya device nahi bana** (item 24) | | | | |
| 2 | Dashboard "Locate"/"Keepalive" (owner endpoints, 401 nahi) | | | | |
| 3 | Permission Center: screen capture / input / files / contacts / location | | n/a | n/a | n/a |
| 4 | `screen.capture` — image kholne par sahi dikhe (static screen par bhi) | | | | ⛔ unsupported |
| 5 | `screen.watch_live` ~6–8 fps, stop par ruk jaye, complete/fail par ruk jaye | | | | |
| 6 | `input.tap/swipe/type_text` (+ append); elevated window par saaf error | | | | |
| 7 | `files.list/read/write` sandbox + picked folder; 10 MiB upload end-to-end | | | | |
| 8 | `browser.navigate` http ok, `file://` reject; `browser.read/click` real Chrome par | | | | |
| 9 | `app_launcher.launch` listed app ok; random command reject | | | | |
| 10 | `clipboard.read/write` (Android: background mein saaf error) | | | | |
| 11 | Lock/unlock ka status dashboard par badle (GNOME, Windows lock) | | | | |
| 12 | Battery/network/location Device Status mein dikhe | | | | |
| 13 | Wi-Fi band/on → agent auto-reconnect (backoff), dashboard "online/offline" | | | | |
| 14 | Server restart → sessions/tasks wapas, devices OFFLINE → reconnect par ONLINE | | | | |
| 15 | Android: notification access ON → `notifications.read_event` | | n/a | n/a | n/a |
| H1 | Android: agent mode ON, app recents se swipe-away → notification "running in background mode" aur server par device online rahe | | n/a | n/a | n/a |
| H2 | Android headless: `device.status`/location/`apps.list` commands kaam karein | | n/a | n/a | n/a |
| H3 | Android headless: `screen.*` / permission dialog wale actions → `NEEDS_UI` (crash nahi) | | n/a | n/a | n/a |
| H4 | Android: swipe-away ke baad app dobara kholo → sirf ek connection (headless band), commands chalein | | n/a | n/a | n/a |
| H5 | Android: process kill (adb shell am kill) → service sticky restart → headless dobara connect | | n/a | n/a | n/a |
| H6 | Android: unpair/token rotate → headless engine khud band, notification "NOT running" | | n/a | n/a | n/a |
| 15a | Android: WhatsApp/Telegram message aaye → `messaging.get_event` mein dikhe, `can_reply: true` | | n/a | n/a | n/a |
| 15b | Android: `prepare_reply` → draft (kuch bheja nahi) → `send_reply(draft_id)` → app mein reply gayi | | n/a | n/a | n/a |
| 15c | Android: notification dismiss ke baad `send_reply` → `NOT_FOUND`; draft dobara use → `NOT_FOUND` | | n/a | n/a | n/a |
| 15d | Android: unsupported app / desktop par `messaging.*` → `CAPABILITY_UNAVAILABLE` | | n/a | n/a | n/a |
| 15e | Android: 6th reply 1 minute mein → `RATE_LIMITED` | | n/a | n/a | n/a |
| 16 | Android: back press → app background, agent online rehta hai; battery exemption | | n/a | n/a | n/a |
| 17 | Google Drive/Dropbox OAuth + list + **download** (Docs export) | | | | |
| 18 | Railway deploy: `/healthz`, Volume `/data` persistence, `CONFIG WARNING` logs | | | | |
| 19 | Unpair (dashboard) → server se device/keys gayab, app pairing par wapas | | | | |
| 20 | Release APK: keystore ke saath sign (`-PrequireReleaseKeystore=true`) | | n/a | n/a | n/a |

## Stage 9 additional rows (fill pass/fail + date + device)
| ID | Test | Expected | Result |
|---|---|---|---|
| S9-1 | Dashboard `/screen` socket open, API key DELETE/disable | socket closes (4004) within ~30 s or immediately | |
| S9-2 | Device token rotate while a viewer is connected with the old token | viewer socket closed | |
| S9-3 | `screen.watch_live` without screen-capture consent (Android) | `PERMISSION_REQUIRED` error, viewer does not connect | |
| S9-4 | Live view of a static screen, viewer joins late | last frame shows within 30 s window; `first_frame_received` flag honest | |
| S9-5 | Stop the device heartbeat (kill network) | device shows OFFLINE within ~2 min (sweeper) | |
| S9-6 | Task idle >24 h (set `updatedAt` manually) | task becomes FAILED `stale:`; terminal tasks >7 d removed | |
| S9-7 | Android 12–15: enable background mode, swipe app from recents | agent reconnects headless within ~10 s | |
| S9-8 | Unpair device while headless | notification disappears, no restart loop | |
| S9-9 | Reboot phone with background mode on | agent reconnects headless after boot (BootReceiver); on OEMs with autostart restrictions may need the autostart permission | |
| S9-10 | Messaging: WhatsApp/Telegram/Signal get_event -> prepare_reply -> send_reply; unsupported package | reply handed to app; unsupported => CAPABILITY_UNAVAILABLE | |
| S9-11 | Notification with hidden/secret content | not visible via API | |
| S9-12 | Kill app via OEM manager, then post a notification | events resume (requestRebind) | |
| S9-13 | Connector connect with `CONNECTOR_ENCRYPTION_KEY` unset | `/auth` refuses (misconfigured) | |
| S9-14 | Restart server with a different key | `/connectors` shows `reconnect_required:true` | |
| S9-15 | Railway without /data volume | `/readyz` = 503 | |
| S9-16 | Release workflow dry run (tag `v0.1.0`) with secrets | signed APK/AAB, .deb, Setup.exe, draft release | |
| S9-17 | Install release APK twice (build N then N+1) | upgrade succeeds (versionCode increases) | |
| S9-18 | Install .deb on a clean Ubuntu | app starts (all shared libs resolved) | |
| S9-19 | Block an app in Permission Center > Notification apps, post a notification from it | not returned by `notifications.read_event`/`messaging.get_event`; previously buffered ones are gone | |
| S9-20 | Open a live view, then close the dashboard | after ~15 s device stops capturing (notification/recording indicator gone) | |
| S9-21 | Live view: toggle server/network off for ~10 s | viewer reconnects by itself and frames resume | |
| S9-22 | `control.pause` with the device network cut (timeout) | error says outcome unknown; task stays PAUSED on server; device gets `task_state` after reconnect | |
| S9-23 | Windows clean VM: run the installer | VC++ runtime installed if missing, app starts | |
| S9-24 | Website: login with ADMIN_TOKEN, device list shows online/offline + active tasks | matches reality; wrong token => 401 | |
| S9-25 | Website: Watch Live at 20 fps / high | smooth enough for UI use; fps meter ~15-20 | |
| S9-26 | Website: click = tap, drag = swipe on a phone with a different resolution | touch lands where clicked (Android) | |
| S9-27 | Website: Back / Home / Recents / Notifications buttons | phone navigates | |
| S9-28 | Website: text box -> focused field; clipboard send | text appears / clipboard set | |
| S9-29 | Website hosted on another domain (Netlify) with `CORS_ALLOWED_ORIGINS` set | works; without it browser blocks | |
| S9-30 | Website: ping pill after connecting | shows a stable ms value, lower than a full HTTP round trip | |
| S9-31 | Website: rapid taps on live view | each tap registers in order, no 429s, visibly snappier than before | |
| S9-32 | Live view at 20-30 fps | CPU/battery on device acceptable; browser doesn't stutter (createImageBitmap path) | |
| S9-33 | Website: Watch Live, then tap 🔊 Audio on a device playing music/video | audio audible within ~1-2s, roughly in sync with video | |
| S9-34 | Audio on a DRM-protected app (e.g. a streaming app) | silence, no crash, no error shown as "failure" | |
| S9-35 | Audio on Windows/Linux device | `CAPABILITY_UNAVAILABLE` (expected — not implemented this round) | |
| S9-36 | Toggle audio off/on repeatedly, change volume slider | no crackling/leftover sound; volume changes live | |
