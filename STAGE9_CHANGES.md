# Stage 9 — index (handoff order)
1 WebSocket security · 2 Task lifecycle · 3 Build readiness · 4 Live screen · 5 Android headless · 6 Notifications/messaging · 7 Native audit · 8 Connectors/deployment · 9 Release packaging · 10 Docs cleanup (STATUS_VS_AUDIT, TEST_COVERAGE, TEST_CAPABILITY_MATRIX, CONNECTORS, ANDROID_HEADLESS_DESIGN, PROTOCOL_V1, REAL_DEVICE_TEST_MATRIX, HOW_TO_CONNECT, TESTING_GUIDE, AUDIT_CORRECTIONS, control_api/README).
**Everything below is UNVERIFIED: nothing was compiled or executed.**

# Stage 9 changes (handoff P0 #1: WebSocket security) — UNVERIFIED (not compiled/run)

| File | Change | Verify with |
|---|---|---|
| control_api/lib/storage/app_state.dart | `WsListenerOwner`, `registerListener/unregisterListener/revalidateListeners`; `removeDevice` revalidates | `dart test test/websocket_revalidation_test.dart` |
| control_api/lib/websocket/handlers.dart | session/screen handlers register owner; no-credentials => 401 before 404; 8 MiB frame cap; `screen_frame.data` must be String | `dart test test/websocket_auth_test.dart test/websocket_revalidation_test.dart` |
| control_api/bin/server.dart | pass owner to handlers; NEW 30s timer: `sweepStaleDevices()` (was never called) + `revalidateListeners()` | manual: stop device heartbeat, expect OFFLINE <=~2 min |
| control_api/lib/routes/api_keys.dart | revalidate after disable / delete | manual: open /screen WS with key, DELETE key, expect close 4004 |
| control_api/lib/routes/devices.dart | revalidate after token rotate | manual |
| control_api/test/websocket_auth_test.dart | updated 404/403 cases to new 401 rule | `dart test` |
| control_api/test/websocket_revalidation_test.dart | NEW: disable/delete/expire/rotate/unpair closes sockets; frame validation | `dart test` |

Still NOT covered: full real-socket integration test (handshake through real middleware), duplicate-connection replacement test.

# Handoff P0 #2: Task lifecycle / checkpoint-resume — UNVERIFIED

| File | Change | Verify with |
|---|---|---|
| control_api/lib/storage/app_state.dart | NEW `sweepTasks()` (stale RUNNING>24h / PAUSED>7d => FAILED; terminal >7d removed) — status doc item 59 claimed this but it did not exist; NEW `rollbackTask()` guarded rollback | `dart test test/task_lifecycle_paths_test.dart` |
| control_api/lib/models/task.dart | `touch()` | same |
| control_api/lib/routes/commands.dart | 3 blind `tasks[id]!.state = rollback` replaced by `rollbackTask` (no crash if task pruned, no overwrite after concurrent change); `touch()` on dispatch; persist after successful transition | route-level: needs integration test (NOT written) |
| control_api/bin/server.dart | hourly `sweepTasks()` timer | manual |
| control_api/test/task_lifecycle_paths_test.dart | NEW: device->server checkpoint (owner / non-owner / bad step), sweeper, rollback guard | `dart test` |

Known, NOT changed (design decisions to confirm with owner):
- Device never reports COMPLETED/FAILED itself; only an API caller's `control.complete/fail` (or the new stale sweeper) ends a task.
- On command TIMEOUT the server still rolls the transition back, though the device may have applied it (outcome unknown).
- Route-level pause/resume/stop + checkpoint forward (`params.server_checkpoint`) has no integration test; device side is covered by shared_app/test/resume_checkpoint_test.dart.

# Handoff P1 #3: Build / static-analysis readiness — UNVERIFIED (no Dart/Flutter/Gradle in this sandbox)

| File | Change | Why / verify with |
|---|---|---|
| shared_app/android/settings.gradle | AGP 8.4.0 -> 8.9.1, Kotlin 1.9.23 -> 2.2.20 | Current Flutter/plugins need newer AGP/Kotlin (compileSdk 36, Kotlin >= 2.0). CI `android_debug_apk` |
| shared_app/android/gradle/wrapper/gradle-wrapper.properties | Gradle 8.6 -> 8.12 | AGP 8.9.1 needs Gradle >= 8.11.1 |
| shared_app/android/app/build.gradle | `kotlinOptions{}` -> `kotlin { compilerOptions { jvmTarget } }` | `kotlinOptions` is removed/deprecated on Kotlin 2.x |
| .github/workflows/ci.yml | `dart analyze` / `flutter analyze --no-fatal-infos` (lint infos no longer fatal on first run); build jobs no longer `needs: shared_app`; delete duplicate `*.gradle.kts` after `flutter create` | get ALL logs (analyze, tests, APK, Linux, Windows) in one run. Re-enable `--fatal-infos` after first green run |

Static checks done offline: all Dart imports (control_api 66 files, shared_app 49 files) resolve to existing files; all 5 AndroidManifest components have a matching .kt file; edited files bracket-balanced.
NOT verified: any compile (Dart, Kotlin, C++), any test run, whether AGP/Kotlin/Gradle versions above match the Flutter version CI picks (flutter-action `stable`), Linux `-Wall -Werror` warnings.

# Handoff P1 #4: Live screen monitoring — UNVERIFIED (no end-to-end run)

| File | Change | Verify with |
|---|---|---|
| shared_app/android/.../ScreenCaptureHandler.kt | EventChannel `onListen` with no active capture service used to do NOTHING (silent); now `events.error("PERMISSION_REQUIRED")` + endOfStream | real Android device: start watch_live WITHOUT granting consent, expect error not "started" |
| shared_app/lib/protocol/agent_connection.dart | `_startLiveStream` waits (4s) for first frame/error; returns `PERMISSION_REQUIRED` / `STREAM_FAILED`, or `started:true, first_frame_received` honestly (static Android screens emit no frame) | `flutter analyze`; device matrix |
| shared_app/lib/task_monitor/task_monitor_screen.dart | `_watchLive` no longer connects the viewer when the device result carries `error_code` / `started != true` (ApiClient does not throw on HTTP-200 device errors) | device matrix |
| shared_app/lib/protocol/websocket_client.dart | `LiveScreenChannel` handshake failure (`ready`) no longer an unhandled async error | manual: bad token |
| control_api/lib/storage/app_state.dart | server-side 15 fps cap; last-frame replay (<=30s, RUNNING task only) so a static screen is not blank for a new viewer | `dart test test/screen_stream_test.dart` |
| control_api/lib/websocket/handlers.dart | uses cap + replay | same |

Known, NOT changed: LiveScreenChannel has no auto-reconnect (UI shows "stream closed", user presses Watch Live again); no server->device "0 viewers, stop capturing" signal; slow-viewer send buffer is unbounded; no automated end-to-end test (capture -> WS -> render).

# Handoff P1 #5: Android background / headless agent — UNVERIFIED (Kotlin never compiled or run on a device)

| File | Change | Verify on a real device |
|---|---|---|
| shared_app/android/.../AgentForegroundService.kt | `requestHeadless()` no longer calls `startForegroundService(ACTION_HEADLESS)` (blocked from background on Android 12+, exception was swallowed => headless never started after swipe-away); it now calls `HeadlessAgent.start()` in-process. Notification no longer says "connected" (engine state != server connection) | enable background mode, swipe app from recents, within ~10s `GET /devices/{id}` must show agent connected again |
| shared_app/android/.../HeadlessAgent.kt | start() race guard (UI engine reattached); `stopSelf` (no creds / unpaired / replaced) now also persists agent_mode=false and stops the service so START_STICKY does not loop | unpair device from server while headless: notification disappears, no restart loop |

Device test matrix to run (not run here): Android 12, 13, 14, 15; swipe from recents; force-stop (agent expected to stop — documented limit); reboot (NO boot receiver exists => agent does NOT auto-start after reboot until app is opened — known limitation, not fixed); battery-optimization on/off; Doze overnight; Xiaomi/Huawei/Samsung battery managers.

Known, NOT changed: partial wake lock is held indefinitely while the service runs (battery cost by design); `HeadlessAgentRunner.run()` does `await conn.connect()` without try/catch (verify connect() never throws, else headless engine could idle with a "running" notification); no `RECEIVE_BOOT_COMPLETED` receiver; UI-only actions return `NEEDS_UI` in headless (by design).

# Handoff P1 #6: Notifications / messaging adapters — UNVERIFIED (Kotlin never compiled; needs a real Android device)

| File | Change | Verify on a real device |
|---|---|---|
| shared_app/android/.../MessagingStore.kt | event id was a 32-bit `key.hashCode()`: a collision let one conversation overwrite another and `sendReply` could go to the WRONG recipient. Now SHA-256 (64-bit prefix). `getEvents(package=<unsupported>)` returned a silent empty list; now `UNSUPPORTED_TARGET` (Dart maps it to CAPABILITY_UNAVAILABLE — that code path previously could never fire) | send WhatsApp/Telegram msg, `messaging.get_event` then `prepare_reply` + `send_reply`; call `get_event` with package `com.example.nope` => CAPABILITY_UNAVAILABLE |
| shared_app/android/.../DeviceNotificationListener.kt | notifications with `VISIBILITY_SECRET` are skipped entirely (not buffered, not in messaging store); `onListenerDisconnected` calls `requestRebind` so events resume after OS/OEM unbinds the listener | enable Notification access, kill app from OEM manager, post a notification, expect it to arrive |

Verified by reading only: permission flow (Dart + native both check `isEnabled` => PERMISSION_DENIED / CAPABILITY_UNAVAILABLE), reply is a two-step (prepare -> send, 5 min TTL, single-use draft, 5 replies/min), result says `delivery: handed_to_app` (never claims delivered), notifications kept in memory only, own-app and ongoing notifications ignored.

Known, NOT changed: a reply needs the source notification still in the shade (else NOT_FOUND) and an inline-reply action (else REPLY_UNSUPPORTED); `notifications.read_event` returns title/text of ALL non-secret apps once access is granted (scope-gated server side by the `notifications` API-key scope, not per-app); `listener enabled` in Settings does not prove the listener is currently bound; no Kotlin unit tests for MessagingStore (needs Robolectric/instrumented tests); SMS apps (Google/Samsung Messages) are supported only via notification inline-reply, never via SmsManager.

# Handoff P1 #7: Native audit — DOC + BUILD CONFIG ONLY (no behavior change in native code)

| File | Change |
|---|---|
| NATIVE_AUDIT_STAGE9.md | NEW: per-capability status for Android/Windows/Linux with evidence; nothing marked Supported (nothing executed) |
| TEST_CAPABILITY_MATRIX.md | stale-warning banner pointing to the new audit (full reconcile is the docs item) |
| shared_app/linux/CMakeLists.txt, shared_app/windows/CMakeLists.txt | warnings-as-errors now opt-in (`DEVICE_AGENT_WERROR`, default OFF) |

Stale claims found in old docs: lock-state "native code missing" (it exists on all 3 platforms); Android notifications "Not supported" (implemented); Windows/Linux contacts "OS limitation" (implemented, Partial).

# Handoff P1 #8: Connectors / deployment — UNVERIFIED (no Dart run, no real OAuth, no Railway deploy)

Read & judged OK: OAuth Authorization Code + PKCE(S256) + CSRF `state` (single-use, expiring, bound to connector+device), AES-GCM-256 token encryption (nonce||mac||ct, tamper => error), refresh de-duplication, `invalid_grant` => credential removed, provider-side revoke best-effort + local delete, callback HTML is escaped + strict CSP, Drive `fileId` regex-validated, download size cap, Dockerfile/railway.json, startup config warnings, DATA_DIR writability check.

| File | Change |
|---|---|
| control_api/lib/connectors/credential_encryption.dart | `ConnectorEncryptionKey.isConfigured`; invalid-base64 key => clear StateError (was raw FormatException => 500) |
| control_api/lib/routes/connectors.dart | `POST /connectors/<n>/auth` refuses (server misconfigured) when no persistent `CONNECTOR_ENCRYPTION_KEY` — otherwise user completes OAuth and loses it on restart; `GET /connectors` no longer says `connected:true` for a credential that cannot be decrypted (`reconnect_required:true`, no actions) |
| control_api/bin/server.dart | NEW `GET /readyz` (503 when DATA_DIR not writable) — `/healthz` stays always-200 for Railway; `import dart:convert` |
| control_api/test/connector_key_config_test.dart | NEW: configured vs ephemeral key, round-trip, wrong key cannot decrypt |

NOT done / needs you: real Google + Dropbox OAuth round-trip with your client IDs; confirm Railway volume is mounted at /data (check `/readyz`); Dockerfile runs as root by design (Railway volume ownership).

# Handoff P2 #9: Release packaging / signing — UNVERIFIED (workflows never run)

| File | Change |
|---|---|
| .gitignore (NEW — repo had none; docs claimed one) | excludes key.properties, *.jks/keystores, .env, build output, local.properties |
| shared_app/android/app/build.gradle + pubspec.yaml | `versionCode`/`versionName` were hardcoded 1/"0.1.0" (every release identical => no updates, Play rejects); now from `flutter.versionCode/versionName`, pubspec `0.1.0+1` |
| .github/workflows/release.yml (NEW) | tag `v*`/manual; preflight (valid x.y.z, `CONTROL_API_URL` must be https — CI default is http://localhost); Android signed APK+AAB with `REQUIRE_RELEASE_KEYSTORE=true` and keystore from secrets (removed after); Linux .deb; Windows Inno installer; SHA-256 sums; draft GitHub Release |
| scripts/package_linux_deb.sh | `Depends` now lists pipewire/x11/xtst/turbojpeg/libebook (was only gtk+glib => app would not start on a clean machine) |
| installers/windows/universal_device_agent.iss | `AppVersion` overridable via `/DAppVersion=` |
| .github/workflows/ci.yml | `.kts` cleanup loop no longer fails the step when a file is absent |

NOT done / needs you: create the upload keystore (`keytool …`) and add the 4 secrets + `CONTROL_API_URL` variable; Windows installer does not bundle the VC++ runtime (clean Windows machines may need vc_redist); no code signing for Windows (SmartScreen warning); `libebook-1.2-N` alternatives for Debian/Ubuntu releases unverified; docs `android/key.properties` vs real path `android/app/key.properties` inconsistency (docs cleanup item).

# Follow-ups (everything left except RUNNING builds/tests) — UNVERIFIED

| Item | Change | Files |
|---|---|---|
| Android reboot auto-start | `BootReceiver` (BOOT_COMPLETED + MY_PACKAGE_REPLACED) starts the foreground service with `ACTION_HEADLESS` if agent mode was ON; `RECEIVE_BOOT_COMPLETED` permission + receiver in manifest | `BootReceiver.kt`, `AndroidManifest.xml` |
| Viewer auto-reconnect | `LiveScreenChannel` reconnects with backoff (1,2,4,8,15 s, max 8 consecutive failures, counter resets on handshake success); `frames` stays one stream across reconnects | `websocket_client.dart` |
| Headless connect | `conn.connect()` throwing no longer leaves a "running" engine doing nothing: retry with backoff 2..60 s until connected or stopped | `headless_agent.dart` |
| Device-reported task result | device can send `{kind:event,type:task_result,state:completed|failed,reason}`; server applies it only from the owning device on RUNNING/PAUSED tasks; `AgentConnection.reportTaskResult()` | `handlers.dart`, `agent_connection.dart` |
| Command-timeout semantics | on TIMEOUT the control transition is KEPT (outcome unknown) and the device is re-synced via `task_state`; response message says so (was: rollback => possible server/device mismatch) | `commands.dart` |
| Stop capture with no viewers | when the last `/screen` viewer leaves, after 15 s grace the server sends `screen_idle`; device cancels the live stream | `app_state.dart`, `handlers.dart`, `agent_connection.dart` |
| Per-app notification filter | local-only (NOT settable via remote API): blocked packages are skipped by the listener, purged from buffers/messaging store, filtered from reads; UI screen `Notification apps` in Permission Center | `NotificationFilter.kt`, `DeviceNotificationListener.kt`, `MessagingStore.kt`, `NotificationsHandler.kt`, `notification_filter_screen.dart`, `permission_center.dart` |
| Windows installer | bundles + runs VC++ x64 runtime when missing; release workflow downloads it; optional Authenticode signing when `WINDOWS_CERT_BASE64`/`WINDOWS_CERT_PASSWORD` secrets exist | `universal_device_agent.iss`, `release.yml` |
| Tests | `stage9_followups_test.dart`: task_result, screen_idle, and `/commands` route-level (pause ack, invalid transition, offline rollback, scope 403, complete server-only, timeout keeps state) with fake WebSocket devices | `control_api/test/` |

Still NOT done (needs a decision or is physically impossible here): Linux system tray (decision), ChromeOS target (decision), slow-viewer send-buffer bound (no flush API on WebSocketSink), real-socket handshake test, all builds/tests/device runs.

# Web dashboard (Control Center) — UNVERIFIED (nothing deployed or run)

User ask: ek website jo server se judi ho, saare connected devices + unka kaam dikhaye, **live screen smoothly** dikhaye, click/touch real-time device par chale, copy/paste aur typing ho (audio baad mein).

| Piece | What | Files |
|---|---|---|
| Admin API | `ADMIN_TOKEN` (>=32 chars; absent => `/admin/*` 404). `GET /admin/devices` (all paired devices, online flag, active tasks), `GET /admin/devices/{id}/tasks`, `POST /admin/devices/{id}/commands` (full-scope owner key for that device), `POST /admin/ws-ticket` | `control_api/lib/routes/admin.dart`, `bin/server.dart` |
| Browser WebSocket auth | browsers cannot set `Authorization` on WebSocket => 60 s single-use `?ticket=`; `/screen/{id}` and `/sessions/{id}` accept it (admin may watch any known session) | `app_state.dart`, `handlers.dart`, `admin.dart` |
| CORS | `CORS_ALLOWED_ORIGINS` exact-origin allowlist, preflight answered before auth | `admin.dart`, `server.dart` |
| Smoother stream | device default 6 -> 20 fps (hard cap 30), native Android default 1080 px / JPEG 70 (was 8 fps / 720 px / q50), per-stream `fps` + `quality` (low/medium/high/ultra) in `screen.watch_live`; server cap 15 -> 30 fps; result now carries real `screen.{width,height}` for click mapping | `ScreenCaptureService.kt`, `ScreenCaptureHandler.kt`, `agent_connection.dart`, `platform_channel_bridge.dart`, `capabilities.dart`, `app_state.dart` |
| Navigation keys | new `input.key` (back/home/recents/notifications) — Android AccessibilityService global actions; wired through scope (`touchInput`), AI registry, Dart dispatcher | `capabilities.dart`, `api_key.dart`, `ai_tool_registry.dart`, `InputAccessibilityService.kt`, `InputHandler.kt`, `agent_connection.dart` |
| Website | single file: login, device list (4 s refresh), live canvas (latest-frame-only decode, reconnect with fresh ticket), click=tap / drag=swipe, key buttons, text type, paste-to-device clipboard, read device clipboard, fps/quality selectors, fps/KB/s meter | `web_dashboard/index.html`, `README.md` |
| Tests | admin auth/disabled, device list, command forward, tickets (single-use), WS authorize via ticket, CORS | `control_api/test/admin_dashboard_test.dart` |

Not in this step (by agreement): audio streaming (future). Known: JPEG frames, not video codec; Windows/Linux click->pixel mapping assumes frame size == screen size; Windows/Linux native capture rate not changed (only Dart-side fps cap applies); `ADMIN_TOKEN` is one all-powerful secret (no per-user accounts/roles).

# Stage 9.1 — redesign + speed (website branding/logo, server/app/site latency) — UNVERIFIED

User ask: website ko bhi zip mein daalo, ek achha design + logo do, aur poori chain fast karo (server
ka jawab, phone ka control, website ka "signal"/live-view speed) — sab ek saath.

| Piece | What | Files |
|---|---|---|
| Website redesign | branded "Pulse" logo (inline SVG, gradient), dark theme, nicer cards/buttons/toasts, live signal (ping) pill in header | `web_dashboard/index.html` |
| Binary screen frames | device sends raw JPEG as a binary WS frame (`[0x01][idLen][sessionId][jpeg]`) instead of base64-in-JSON — no base64 (~33% smaller) or JSON parse, on device or browser | `websocket/handlers.dart` (`handleAgentBinaryFrame`), `agent_connection.dart` (`_sendBinaryFrame`), `task_monitor_screen.dart` (accepts `Uint8List` too) |
| Fast browser decode | website uses `createImageBitmap()` (hardware-accelerated, off-main-thread-ish) instead of `data:` URI + `<img>`/base64 decode | `web_dashboard/index.html` |
| Fast control channel | new `WS /admin/control` (ticket-authed): website pipelines tap/swipe/key/type/clipboard over ONE WebSocket instead of one HTTP request per click (saves TLS+HTTP overhead each time); HTTP `POST /admin/devices/{id}/commands` kept as fallback/non-interactive path | `control_api/lib/routes/admin.dart` (`adminControlHandler`, `forwardAdminCommand`), `bin/server.dart` |
| Admin rate bucket | `ADMIN_TOKEN` requests get a 6000/min bucket (was capped at the general 120/min — interactive clicking could 429) | `middleware/rate_limiter.dart` |
| Android gesture speed | tap/swipe internal gesture duration 50ms -> 20ms | `InputAccessibilityService.kt` |
| Tests | binary frame forward/owner-check/size-drop/fps-cap, admin-token check, admin bucket > general bucket, forwardAdminCommand round-trip | `control_api/test/admin_speed_test.dart` |

Still JPEG-over-WebSocket (not a real video codec/WebRTC) — that remains the ceiling on "video-like"
smoothness; this step only removes avoidable overhead (encoding waste + per-click HTTP). Windows/Linux
native capture still sends text frames (fallback path in the code handles both); only Android device
capture + server + browser got the binary fast path this round.

# Stage 9.2 — system audio streaming (device, server, website) — UNVERIFIED

User ask: screen ke saath device ki awaaz bhi website par sunai de (jaise phone par video chalayein, uski awaaz website se sune).

| Piece | What | Files |
|---|---|---|
| Android capture | `AudioCaptureManager.kt` (NEW): `AudioPlaybackCaptureConfiguration` (Android 10+, API 29), same `MediaProjection` session jo screen capture use karti hai (ek hi consent dialog). Raw PCM16, 16kHz, mono, 20ms chunks (640 bytes) — koi codec encode/decode nahi, taaki latency kam rahe aur OEM-version quirks se bacha ja sake | `AudioCaptureManager.kt`, `ScreenCaptureService.kt` (`startAudioStreaming`/`stopAudioStreaming`), `ScreenCaptureHandler.kt` (naya EventChannel `device_agent/audio_stream`), `MainActivity.kt` (request code), `AndroidManifest.xml` (`RECORD_AUDIO`) |
| Dart device | `audio.watch_live`/`audio.stop_live` command handling (screen ke pattern jaisa — task pause/stop/complete aur `screen_idle` par bhi audio band hoti hai); binary frame protocol extend (`type` byte: `0x01`=screen, `0x02`=audio) | `agent_connection.dart`, `platform_channel_bridge.dart` |
| Server | `audio` capability (scope `screen_view` reuse — jo screen dekh sakta hai wahi sun sakta hai), `WS /audio/{id}` (ticket-auth, 5 listeners/session cap jaisa screen), `AppState.audioListeners`/`broadcastToAudio`, binary-frame router dono type handle karta hai (audio par koi fps cap nahi — chunks already thode hain) | `capabilities.dart`, `api_key.dart`, `ai_tool_registry.dart`, `app_state.dart`, `websocket/handlers.dart`, `bin/server.dart` |
| Website | 🔊 Audio toggle (Watch Live ke saath), volume slider; Web Audio `ScriptProcessorNode` se PCM16 chunks bajata hai (jitter-buffer queue — khaali ho to chup, bhar jaaye to purana drop); agar `AudioContext` 16kHz par na khule to linear-interpolation resample; WS reconnect audio ke liye bhi (screen jaisa) | `web_dashboard/index.html` |
| Tests | binary frame type routing (audio vs screen listeners), no fps-cap on audio, owner check, unknown type dropped, listener cleanup, scope gating | `control_api/test/audio_stream_test.dart` |

**Known limits (by design, not bugs):**
- DRM-protected / `ALLOW_CAPTURE_BY_NONE` apps (many streaming apps) => silence, not an error — Android itself blocks this, cannot be worked around.
- Mic / calls are NOT captured — only device playback (media/game audio), matching what the user asked ("film/video ki awaaz").
- Windows/Linux: NOT implemented this round — `audio.watch_live` on those platforms returns `CAPABILITY_UNAVAILABLE` (no native method exists there yet). Same wire protocol is ready; adding native capture (WASAPI loopback / PipeWire) is a follow-up if needed.
- Audio and screen are independent streams/sockets (not muxed) — small relative delay (not frame-accurate lip sync) is expected; this was not asked to be frame-synced and is far simpler/more reliable this way.
- `ScriptProcessorNode` is deprecated-but-supported (kept to avoid loading an AudioWorklet module, which would need a CSP change); fine for this use.

# Stage 9.3 — real user-simulation test + env-vars file + deliverables index

User ask: website ko "ek user ki tarah" test karo, backend ke env variables alag file mein, aur jo kuch diya hai uska ek index file.

| Piece | What | Files |
|---|---|---|
| Real browser test | Playwright (asli headless Chromium) se `web_dashboard/index.html` ko ek user ki tarah chalaya: wrong login, correct login, device list, select, Watch Live, tap (coordinate math verify), swipe, Back key, type text, clipboard send/read, audio toggle, ping meter, stop, offline-device disabled state, logout — console errors ke saath. Backend mock kiya (Dart yahan chal nahi sakta), website ka asli code hi chala. **38/38 pass**, 2 real bugs mile aur fix hue (chhoti test-JPEG se galat swipe-test, aur wrong-password step ka apna 401 console-error check ko confuse kar raha tha) | `qa/user_test.mjs`, `qa/USER_TEST_REPORT.md`, `qa/screenshot_live_view.png` |
| Env vars + deliverables | User ne baad mein kaha dono ek hi file mein chahiye — `ENV_VARS.md` aur `DELIVERABLES.md` ko merge karke ek file bana di | `START_HERE.md` (replaces both) |

Important: yeh test SIRF website (frontend JS) ko verify karta hai, ek asli browser mein, ek mock backend ke against — Dart server, Android/Windows/Linux app, aur in sabke saath ka real end-to-end abhi bhi unverified hai. `qa/USER_TEST_REPORT.md` mein yeh honestly likha hai.
