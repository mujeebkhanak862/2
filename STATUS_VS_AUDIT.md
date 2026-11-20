# Audit documents ke mutabik: kya hua, kya baki hai

Legend: ✅ code mein ho gaya (par **unverified** — kuch bhi compile/run nahi hua) · 🧪 aapko run/test karna hai · ⛔ nahi kiya (kyun, likha hai)

## Stage 9 (is session) — corrections aur naya kaam
> Sab kuch **source-read + blind edit** hai. Is sandbox mein Dart/Flutter/Gradle/MSVC/GCC nahi tha: **kuch bhi compile ya run nahi hua**. Details: `STAGE9_CHANGES.md`. Native cells ka evidence: `NATIVE_AUDIT_STAGE9.md`.

**Purane doc ke galat "done" claims (source padhne par mile) aur ab kya hua:**
| Pehle likha tha | Asal mein | Stage 9 |
|---|---|---|
| "stale tasks prune (59 — Stage 9 mein asal mein implement hua, pehle exist nahi karta tha)" | Prune function exist hi nahi karta tha | `AppState.sweepTasks()` + hourly timer (RUNNING>24h / PAUSED>7d => FAILED, terminal>7d hata do) |
| "stale sweeper/ping (43 — Stage 9 mein schedule hua, pehle kabhi call nahi hota tha)" | `sweepStaleDevices()` likha tha par kahin schedule nahi hota tha | 30s timer (server.dart) |
| WebSocket auth "done" | Auth sirf handshake par; key revoke/expire/token rotate par khule sockets chalte rehte the | `revalidateListeners()`: close(4004) |
| Live stream "started" | Consent/service na ho to bhi `started:true` (native chup) | Native `PERMISSION_REQUIRED`, device pehle frame/error ka wait, viewer error par connect nahi |
| Headless on swipe-away | `startForegroundService` background se (Android 12+ blocked, exception nigli) | in-process `HeadlessAgent.start()` |
| Messaging `UNSUPPORTED_TARGET` | Kotlin kabhi throw nahi karta tha | Ab throw => `CAPABILITY_UNAVAILABLE` |
| Messaging event id | 32-bit hash collision => galat recipient ka risk | SHA-256 64-bit |
| "Lock-state native code missing" (matrix) | Teeno platform par hai | Doc theek kiya |
| Android notifications "Not supported" (matrix) | Implemented | Doc theek kiya |
| Windows/Linux contacts "OS limitation" | Implemented, Partial | Doc theek kiya |
| Release signing "root .gitignore" | `.gitignore` repo mein tha hi nahi | Added |
| Android `versionCode` | Hardcoded 1 | pubspec se |
| Connector status | `connected:true` bhi jab token decrypt nahi ho sakta | `reconnect_required` |

**Stage 9 items (handoff order):**
| # | Item | Status |
|---|---|---|
| 1 | WebSocket security | ✅ code + tests (blind) — real-socket integration test baki |
| 2 | Task lifecycle / checkpoint | ✅ code + tests (blind) — route-level integration test baki |
| 3 | Build / static analysis | 🧪 config updated (AGP 8.9.1, Kotlin 2.2.20, Gradle 8.12, CI relaxed); **koi build chala nahi** |
| 4 | Live screen end-to-end | ✅ code (blind) — 🧪 device test |
| 5 | Android background/headless | ✅ code (blind) — 🧪 device matrix (reboot auto-start NAHI hai) |
| 6 | Notifications / messaging | ✅ code (blind) — 🧪 real apps |
| 7 | Native audit Android/Windows/Linux | ✅ doc: `NATIVE_AUDIT_STAGE9.md` (kuch bhi "Supported" nahi — kuch run nahi hua) |
| 8 | Connectors / deployment | ✅ code (blind) — 🧪 real Google/Dropbox OAuth + Railway volume |
| 9 | Release packaging / signing | ✅ `release.yml` etc. (blind) — 🧪 keystore + secrets aapke |
| 10 | Docs cleanup | ✅ yeh update |
| F | Follow-ups (boot receiver, viewer auto-reconnect, device task_result, timeout semantics, screen_idle, per-app notification filter, Windows VC++/signing, route-level tests) | ✅ code (blind) — dekhein `STAGE9_CHANGES.md` "Follow-ups"; Linux tray / ChromeOS = owner decision |

## A. Audit ke "Exact priority order" (Section 13) ka status
| # | Audit ka step | Status |
|---|---|---|
| 1 | WebSocket authenticate + authorize | ✅ Server par pehle se tha; **client header nahi bhejta tha → fix (item 26)**; cross-device session/event/frame injection band (6–7) |
| 2 | Task checkpoint/resume/complete/fail | ✅ Pehle se mostly tha; ab server-side complete/fail device ko `task_state` se bhi pahunchta hai (56), stale tasks prune (59 — Stage 9 mein asal mein implement hua, pehle exist nahi karta tha) |
| 3 | Dart/Flutter tests chalana | 🧪 **Aap**: `dart test` / `flutter test`. Ab 49 test files hain (control_api 33 + shared_app 16), ek bhi chali nahi |
| 4 | Android debug APK + real device tests | 🧪 **Aap** (`scripts/bootstrap_platforms.sh` pehle) |
| 5 | Android lock-state + background agent | ✅ Lock-state intent-based (71); foreground service + back-press→background + battery exemption (85); **headless engine** (Stage 8: Activity ke bina agent chalta hai, `ANDROID_HEADLESS_DESIGN.md`) — 🧪 real device (matrix H1–H6) |
| 6 | Windows build + capability matrix | 🧪 **Aap** (Windows screen capture/clipboard/input mein asli bugs mile aur fix kiye — item 83) |
| 7 | Linux X11 + Wayland test | 🧪 **Aap** |
| 8 | Notification/messaging adapters | ✅ Android notifications (84) + messaging adapters (Stage 8: `MessagingStore.kt` — supported apps, notification inline-reply; baaki apps/desktop par honest `CAPABILITY_UNAVAILABLE`) — 🧪 real device |
| 9 | Signing, branding, deployment | ✅ Release keystore ke bina build fail karne ka opt-in (`-PrequireReleaseKeystore=true`); Railway/env warnings; **icons/splash/installers/CI builds (Stage 8)**. Logo: **Control Hub logo lag gaya** (`brand/control_hub_logo.jpg` -> `python3 brand/make_icons_from_logo.py`). 🧪 Aapka decision: release keystore |
| 10 | Matrix dobara + "Complete" tab likhna jab evidence ho | 🧪 `REAL_DEVICE_TEST_MATRIX.md` |

## B. Roadmap items (Section 3)
| ID | Audit verdict | Ab |
|---|---|---|
| P0-01 Task lifecycle | 🟡 | ✅ + custom-capability tasks ab pause/stop ho sakte hain (45) |
| P0-02 Scope enforcement | 🟡 | ✅ + owner endpoints (25), ownership (6) |
| P0-03 HTTPS/WSS | 🟡 | ✅ Railway auto-detect (4); direct TLS wahi |
| P0-04 Schema validation | 🟡 | ✅ + body-size, URL scheme, file-type hardening (13, 14, 16, 39) |
| P0-05 Rate limiting | 🟡 | ✅ proxy-aware IP, pairing bucket (17). Multi-instance (Redis): document mein required nahi — single-instance documented limitation |
| P0-06 Secrets/log redaction | 🟡 | ✅ constant-time compare, 128-bit ids, key expiry (19, 21, 22) |
| P0-07 Connector OAuth | 🟡 | ✅ refresh race/invalid_grant (47), **download (Drive+Dropbox)**, API key (dataTransfer scope) access (86). Upload document mein required nahi (write scopes = zyada privilege; deliberate) |
| P1-01 Capability registry | 🟡 | ✅ per-device ownership + caps (15) |
| P1-02 AI tool registry | 🟡 | ✅ control.* tools ab dikhte hain (46). ⛔ AI engine is repo ka hissa nahi (boundary) |
| P1-03 Live monitoring | 🟠 | ✅ auth+retry (26–27), FPS cap/throttle (57, 63), snapshot (34), Windows screen capture ke real bugs (83). 🧪 end-to-end test |
| P1-04 Progress metadata | 🟡 | unchanged |
| P1-05 Device state | 🟠 | ✅ reconnect par full status (33), stale sweeper/ping (43 — Stage 9 mein schedule hua, pehle kabhi call nahi hota tha), Android + Linux(GNOME) lock-state (71, 83) |
| P1-06 Notifications+messaging | 🔴 | ✅ notifications (Android) + **messaging adapters** (Android, supported apps, notification inline-reply) — code-complete, 🧪 real device |
| P1-07 Location/network | 🟡 | ✅ ab server tak pahunchta hai (32), battery (32), Android fallbacks (69) |
| P1-08 File/data hardening | 🟡 | ✅ Android picked-tree check (67), desktop non-throwing/size caps/persisted roots (81–82) |
| P1-09 Audit history | 🟡 | unchanged |
| DEP-01 Deployment | 🟡 | ✅ + persistence race/corruption safe (40–42) |

## C. Jo abhi baki hai (honest list)
**Documents ke hisaab se implement karne ko kuch nahi bacha** — sab code mein hai, lekin **kuch bhi compile/run nahi hua**, isliye "Complete" nahi, sirf "code-complete / unverified".

**Aapko karna hai (main nahi kar sakta):**
1. GitHub par push -> Actions (`.github/workflows/ci.yml`): `dart analyze/test`, `flutter analyze/test`, Android APK, Linux, Windows builds. **Fail logs mujhe bhejo, main batch mein fix karunga.** (Compile errors milna *expected* hai: ~100 files blind likhi/badli gayi — sabse risky: Android handlers ka `HandlerHost` refactor, Windows/Linux native C++.)
2. Real device matrix (`REAL_DEVICE_TEST_MATRIX.md`: Android, Windows, Linux X11/Wayland, ChromeOS) — "Complete" tabhi likhna jab evidence ho.
3. Railway env vars (`HOW_TO_CONNECT.md`), release keystore.

**Document ke bahar (kabhi maange nahi gaye):** connector upload, Redis multi-instance, AI engine (is repo ka hissa nahi).

**Known limitations jo dhyan mein rakhein:**
- Chrome pehle se bina debug-port ke chal raha ho to Chrome naya `--remote-debugging-port` accept nahi karta — browser band karke dobara try karna padega (78).
- WebSocket auth-failure detection `WebSocketException` ke message mein 401/403 dhundhta hai; Dart version ke hisaab se message alag ho sakta hai (53) — REST 401 handler backup hai.
- Windows `Graphics.Capture` ka PostMessage/subclass approach compile/run nahi hua (83).
- Messaging: sirf Android + supported apps; `sent` = app ko handoff (delivery confirm nahi). Headless mode mein screen-capture consent/permission dialogs `NEEDS_UI`.
- Linux par tray nahi.

## D. Is session mein kya hua (Stage 8)
- ✅ **Item 22 done (blind, unverified):** `deviceByToken` / `apiKeyBySecret` ab hash-index se O(1) chalte hain (`lib/util/versioned_map.dart` + `app_state.dart`). Har hit current record ke against constant-time re-verify hota hai; token rotation par `state.devices.touch()`. Naya test: `control_api/test/hash_index_lookup_test.dart`. 🧪 `dart test` chalana baki.
- ✅ **Item 14 done (blind, unverified):** `writeFile` par ab teesri, native check hai — Android (`FilesHandler.kt`), Windows (`files_manager.cpp`), Linux (`files_manager.cc`); blocked type par error code `FORBIDDEN_TYPE`. Extension list server + Dart + teeno native mein identical (script se verify). C++ check standalone compile karke test kiya (case, trailing dot/space, NTFS ADS, path separators). Android Kotlin + poora native build 🧪 aapko chalana hai. Note: extension-based hai, content sniffing nahi.
- ✅ **Item 10 done (blind, unverified):** server-issued one-time pairing codes. `POST /pairing-codes` (ADMIN_SECRET ya paired device se) -> 8-char code, 5 min TTL (`PAIRING_CODE_TTL_SECONDS`), single-use, sirf hash memory mein, active cap 20, issuing par bhi 10/hr/IP rate limit. `POST /devices/pair` ab valid code accept karta hai (code `PAIRING_SECRET` ki jagah le leta hai); `REQUIRE_PAIRING_CODE=true` par code ke bina pairing band. Galat input par code burn nahi hota. Pairing screen mein naya "Server pairing code" field. Purana `PAIRING_SECRET` flow default mein chalta rehta hai. Naya test: `control_api/test/pairing_code_test.dart`. 🧪 `dart test` / `flutter analyze` aapko chalana hai. Limitation: codes restart par chale jaate hain (jaan-bujh kar).
- ✅ **Item 81 done (blind, partially verified):** Windows + Linux par `listDirectory` / `readFile` / `writeFile` / `deleteFile` ka asli file I/O ab **worker thread** par chalta hai; sandbox resolve + policy checks UI thread par rehte hain (GrantedRoots wahin badalte hain). Result sirf UI thread se wapas jaata hai: Windows mein custom window message (`FilesManager::kMainThreadMessage` -> `FlutterWindow::MessageHandler` -> `DrainMainThreadTasks()`), Linux mein `g_idle_add`. Ek waqt mein ek hi file op (mutex), max 16 in-flight, uske upar `BUSY` error. Linux CMake mein `Threads::Threads` link. Platform-neutral I/O core (`BEGIN/END IO CORE`) dono files mein byte-for-byte identical (script se check) aur standalone g++ harness mein real filesystem + 16 parallel threads par test hua (roundtrip, NOT_FOUND, TOO_LARGE, INVALID_DATA, delete). 🧪 **Abhi bhi unverified:** Windows message-loop wiring aur Linux `g_idle_add`/FlMethodCall code — compile nahi hua, Windows/Linux par build + chala ke dekhna hai. Android pehle se alag `runIo` executor use karta hai.
- ✅ **Item 85 (desktop hissa) done (blind, unverified):** (1) **Windows tray** — `tray_icon.{h,cpp}` (Shell_NotifyIcon): close = tray mein chhupo, menu Open/Quit, Explorer restart par icon dobara, logoff par rukawat nahi; autostart ab `--background` ke saath => window chhupi (agar tray add fail ho to window dikhti hai). (2) **Linux systemd user service** (`Restart=on-failure`, graphical-session) — `AutostartService.enable(linuxKind: systemd)`, XDG ke saath mutually exclusive, enable fail par adhura unit nahi bachta; Permission Center mein naya item. Naye tests `stage7_autostart_test.dart` mein. (3) Android headless engine: sirf design doc. 🧪 Windows build (tray/WM_CLOSE flow), `flutter test`, aur real systemd session par check aapko karna hai. Limit: Linux par tray nahi; systemd service boot-time nahi, login-session wali hai.
- ✅ **Item 88 done (generated assets, blind wiring):** original brand mark (monitor + cursor + signal, indigo→violet) generate hua — Android legacy + round + **adaptive** (foreground/monochrome/background colour) mipmaps, splash (legacy `launch_background` + Android 12+ `values-v31`), `roundIcon` manifest mein, **Windows `app_icon.ico`** (7 sizes), **Linux hicolor 16–512** (pehle `256x256/apps/` khaali tha — CMake install fail hota; ab fix + poora set install), in-app `assets/brand/logo.png`. **Installers:** `installers/windows/universal_device_agent.iss` (Inno Setup, per-user, optional autostart `--background`), `scripts/package_linux_deb.sh` (.deb). Product name/version: `lib/config/app_info.dart`. 🧪 Aap: `iscc`/`dpkg-deb` chalana, icons ko apni pasand se replace karna ho to `brand/make_icons.py` ke jaisa script/assets badal dein. Note: yeh mera banaya original icon hai — final logo aapka decision.
- ✅ **Item 89 done (blind, unverified) — audit Section 11 table ke hisaab se:** (1) **Visual system** `lib/theme/app_theme.dart`: spacing/radius tokens, typography scale, light+dark themes (system), semantic colours (success/warning/danger), `StatusChip`, `SectionHeader`; SDK constraint ab Flutter >=3.27. (2) **Home**: device header card (platform badge, state/battery/network chips) + quick actions. (3) **Task Monitor**: live connection indicator ("Live · updated Ns ago" / quiet / connection problem), stream state + **FPS**, stream stalled/closed, Stop par confirmation, theme-aware banners. Latency jaan-bujh kar nahi (frames par timestamp nahi). `LiveScreenChannel.frames` ab broadcast. (4) **API Keys**: risk level chips, per-scope descriptions (detail sheet), last-used, expired/disabled chips, revoke confirm mein risk+scopes+last-used, secret-handling warning. (5) **Device Status**: status chips, *agent connected vs device state* alag, location/network cards with 'Unavailable' reasons. (6) **Background Tasks**: messaging ab clearly *Unavailable · no messaging adapter installed*, notifications *Android only*. (7) **Activity History**: filters (result/category/task id) + redacted detail sheet. (8) **Release UX**: onboarding card (pairing screen), **Diagnostics screen** (build mode, CONTROL_API_URL set?, HTTPS/WSS, /healthz round-trip, token, capabilities). Naya test: `shared_app/test/stage8_ui_test.dart`. 🧪 `flutter analyze/test` aur dekhne mein kaisa lagta hai (screenshots) aapko.
- ✅ **Item 85 Android, Step 0 done (blind):** foreground notification ab sach batati hai — Activity band/swipe-away ya process-kill ke baad "Agent is NOT running — tap to reopen" (pehle hamesha "connected" kehti thi). `AgentForegroundService.engineAttached` + `refreshNotification()`, `MainActivity.configureFlutterEngine/onDestroy`. Headless engine abhi bhi baki (device chahiye).
- ✅ **CI ab poora build+test chalata hai (`.github/workflows/ci.yml`):** control_api (analyze `--fatal-infos` + test), shared_app (analyze + test), **Android debug APK**, **Linux build + .deb**, **Windows build + Inno Setup installer** — artifacts upload hote hain. Local Flutter ki zaroorat nahi: repo GitHub par push karo, Actions tab ka log mujhe bhejo. Optional repo variable `CONTROL_API_URL` set karein. Note: Linux CMake `-Wall -Werror` hai, isliye native C++ mein koi bhi warning build tod degi — CI log mein dikhega.
- ✅ **P1-06 messaging adapters (Android) code-complete (blind):** `MessagingStore.kt` — supported apps allow-list (WhatsApp/WA Business/Telegram/Signal/Messenger/Google+Samsung Messages), notification inline-reply (RemoteInput), do-step `prepare_reply` (draft, 5 min, single-use) → `send_reply(draft_id)`, 5 replies/min, 1000 chars, RAM-only (max 50 events), `onNotificationRemoved` => reply `NOT_FOUND`, listener disconnect => clear. Dart dispatcher + `NotificationsBridge`; server manifest `implemented: true` + strict schemas (send_reply sirf `draft_id` — free-text bypass nahi), AI tool registry ab Android par messaging tools dikhata hai. Tests: `schema_validator_test` (3 naye), `ai_tool_registry_test`. Limit: delivery confirm nahi hoti; Kotlin logic ka unit test nahi (Android classes chahiye) — real device matrix rows 15a–15e.
- ✅ **UI leftovers (Section 11) done (blind):** Device Status par **permission indicators** (Granted / Not granted / Asked on use, `defaultPermissionItems()` ke checks se); Task Monitor **timeline grouping** (`StepTimeline.group`, collapsible groups with count/total duration/failures, failed steps highlighted) + test `step_timeline_grouping_test.dart`. Activity History category filter ab chips (deprecated dropdown API se bachne ke liye).
- ✅ **Item 85 Android headless engine implemented (blind, unverified):** `HandlerHost` (ContextWrapper — handlers ab Activity par depend nahi), `ChannelRegistrar` (UI + headless dono engines mein same handlers), `HeadlessAgent.kt` (service-hosted second FlutterEngine, Dart entrypoint `agentMain` in `lib/protocol/headless_agent.dart`), `AgentRuntime` (process-wide state + sticky-restart flag), service `ACTION_HEADLESS`, ownership handoff (Activity create => headless stop). UI-only actions headless mein `NEEDS_UI`. Design + risks: `ANDROID_HEADLESS_DESIGN.md`; test rows H1–H6. Tests: `headless_agent_test.dart`. 🧪 Yeh sabse risky blind change hai — Android build pehle yahin fail ho sakta hai (Kotlin compile) — CI `android_debug_apk` job dekhein.
- ✅ **Logo: Control Hub logo laga diya:** sirf emblem (robot + magnifier + gear + box + conveyor; text nahi) — Android legacy/round/adaptive (safed background) + monochrome (themed icons) + splash, Windows `app_icon.ico`, Linux hicolor 16–512, in-app `assets/brand/logo.png`. Regenerate: `python3 brand/make_icons_from_logo.py` (source `brand/control_hub_logo.jpg`, `brand/emblem.png`). App ka naam abhi bhi "Universal Device Agent" hai (logo ke text "Control Hub" se alag) — rename chahiye to bolo. Note: yeh design ek stock "AI Quality Control" template jaisa hai; commercial/public release se pehle usi ka license/originality confirm kar lein.
