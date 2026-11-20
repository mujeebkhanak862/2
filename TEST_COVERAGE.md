# Automated Test Coverage (TEST-01)

Ab repo mein **49 test files** hain (`control_api/test/` mein 33, `shared_app/test/` mein 16; ~450 `test()` cases — ginti grep se, **ek bhi execute nahi hui**).
Stage 9 mein nayi: `websocket_revalidation_test`, `task_lifecycle_paths_test`, `screen_stream_test`, `connector_key_config_test`; `websocket_auth_test` update hui.
Ek GitHub Actions workflow (`.github/workflows/ci.yml`) inhe push par chalata hai (pehle yeh workflows
repo mein thi hi nahi — ab hain). Yeh file audit ke acceptance-test
categories (AUTH/SCOPE/TASK/LIVE/BG/MSG/DATA/SEC/CONN/LOC/NET) se map
karti hai, honestly — jo cover hota hai wo bhi, jo nahi hota wo bhi.

**Zaroori:** in mein se koi bhi test is session mein actually **chalaya
nahi gaya** — is sandbox mein Dart/Flutter SDK available nahi thi.
Pehli baar CI chalne ke baad Actions tab mein result dekhein; agar
kuch fail ho, wo mujhe bata dein.

**Ye tests kahan chalti hain — backend ya app?** Sab tests **backend
(`control_api`) aur app ke shared Dart logic (`shared_app`)** ke liye
hain. Koi bhi test Android/Windows/Linux native (Kotlin/C++) code ko
test nahi karti — wo yahan ban hi nahi sakti thi (koi native build
environment nahi tha). Poora backend-vs-native breakdown
`TEST_CAPABILITY_MATRIX.md` mein hai.

## Coverage by category

| Category | Kya cover hai | Test files |
|---|---|---|
| **AUTH** | Device bearer token hashing (plaintext kabhi store nahi), hash-based lookup, revoke immediacy (`enabled` flag check, `device_auth.dart` mein already tha) | `secret_handling_test.dart` |
| **SCOPE** | Task-bound capability authorization (control.pause/resume/stop/switch), unrelated-capability-bypass prevention, **Permission Wizard UI ab custom capabilities ke liye real toggle deta hai** (pehle sirf data-loss se bachata tha, koi UI nahi thi) — `GET /capabilities` ab `is_custom` marker deta hai taaki client built-in vs custom distinguish kar sake | `scope_capability_test.dart`, `device_state_gate_test.dart`, `permission_wizard_custom_capabilities_test.dart` (shared_app) |
| **TASK** | Poora TaskRecord state machine (pause/resume/stop, idempotency, invalid transitions), explicit `control.complete`/`control.fail` transitions, real checkpoint reporting (`recordCheckpoint`), `control.resume` server-checkpoint adoption (forward-only, never regresses device state), tasks surviving a persistence save/load round-trip | `task_test.dart`, `task_lifecycle_completion_test.dart`, `resume_checkpoint_test.dart` (shared_app) |
| **WS-AUTH** | WebSocket endpoint authorization (`/devices/{id}/agent`, `/sessions/{id}`, `/screen/{id}`) — missing token, wrong device token, wrong device's session, wrong/missing scope, revoked key, unknown session (404 vs 401 vs 403) | `websocket_auth_test.dart` |
| **LIVE** | `task_state` event parsing (client-side), duration/step metadata | `event_envelope_test.dart`, `task_progress_description_test.dart` — **native screen-capture code (Android/Windows/Linux) khud test nahi ho saka**, koi build/emulator environment nahi tha. **Code review mein ek real bug mila aur fix kiya**: Android ka `ImageReader` row-stride padding ke liye bitmap wider banata tha lekin kabhi crop nahi karta tha — har real device par (jahan padding ho) screenshot/live-frame corrupted/skewed aata. Windows/Linux is se affected nahi the (dono apne platform API ka stride parameter sahi use karte hain). |
| **BG** | `background.keepalive` (regression guard), audit category inference | `messaging_unavailable_test.dart`, `activity_audit_test.dart` |
| **BROWSER** (naya) | **⚠️ Bade functional gap ka fix**: `CdpClient` (poora Chrome DevTools Protocol client) kahin bhi actually use hi nahi hota tha — Windows/Linux par `browser.navigate`/`click`/`type_text`/`read` sab silently fail hote the (`NotImplemented`, sirf `launchDesktopBrowser` kaam karta tha). Ab dispatcher platform-aware hai: Android apna existing accessibility-tree path use karta hai, Windows/Linux ab genuinely `CdpClient` se connect ho kar navigate/click-by-text/type-by-label/read karte hain (naye `clickByText`/`typeByLabel` methods, text/label-based — Android ke contract se match karne ke liye) | `cdp_client_test.dart` — **real local fake CDP server** (`HttpServer`+`WebSocketTransformer`) ke against, asal network code exercise karta hai, sirf JS-string unit test nahi |
| **WAYLAND** (naya) | **⚠️ Race-condition bug fix**: Linux Wayland portal code (`wayland_portal_session.cc`, ScreenCast/RemoteDesktop dono ke liye shared) xdg-desktop-portal ke Request/Response signal ko method-call ke **baad** subscribe karta tha — agar portal jaldi respond kar deta (khaaskar jab user pehle hi permission de chuka ho), Response signal miss ho sakta tha aur poora flow **hamesha ke liye hang** ho jaata. Fix: portal spec ke deterministic request-path formula (`sender + handle_token`) se path predict karke, subscribe pehle karte hain, method call baad mein — race hi possible nahi ab | **Koi automated test nahi** — asal D-Bus session + xdg-desktop-portal daemon chahiye, is sandbox mein possible nahi. Real Wayland session par manually verify karna zaroori hai. |
| **MSG** | Structured `CAPABILITY_UNAVAILABLE` (fake-success prevention), AI Tool Registry se exclusion, **P1-02: custom capability policy gating** (registered custom capabilities ab per-key explicit grant maangti hain — pehle koi bhi key kisi bhi registered custom capability ko use kar sakti thi, dono AI tool registry mein aur asal `/commands` dispatch endpoint par), **aur ek gehra related bug**: schema validator khud custom capability actions ko "Unknown action" reject kar deta tha (authorization tak pahunchne se pehle hi) kyunki uska action-index sirf built-ins se, module-load par ek baar bana ke cache ho jaata tha | `messaging_unavailable_test.dart`, `ai_tool_registry_test.dart` (ek purana test jo insecure behavior ko "expected" maanta tha, fix kiya gaya), `custom_capability_policy_test.dart`, `schema_validator_custom_capability_test.dart` |
| **DATA** | Path traversal rejection, oversized-upload rejection, dangerous file-type blocking (server-side, pattern-level layer) | `data_channel_security_test.dart` — **⚠️ CRITICAL: ek real path-traversal bug mila aur fix kiya, teeno platforms (Android, Windows, Linux) mein, na ki server-side.** Native sandbox-boundary check bare string-prefix matching use kar raha tha (`target.path.startsWith(root.path)`), separator-boundary check ke bina — matlab koi bhi SIBLING folder jiska naam bhi sandbox-root ke prefix se shuru ho (jaise `.../files` ke bagal mein `.../files_other`) galti se "andar" maan liya jaata, aur uske andar arbitrary read/write ho sakta tha. Fix: teeno platforms mein target ya to root ke exact barabar ho, ya root+separator se shuru ho — yeh check add kiya. **Native code hone ki wajah se automated test nahi likha ja saka is sandbox mein** — real device/build environment par manually verify karna zaroori hai. |
| **SEC** | Rate limiting, credential encryption (AES-GCM round-trip + tamper detection), PKCE (RFC 7636 test vector), capability manifest validation, request schema validation, **P0-03: TLS bind-address safe-default** (koi TLS signal na ho to localhost-only, explicit opt-in par hi sab-interfaces) | `rate_limiter_test.dart`, `credential_encryption_test.dart`, `pkce_test.dart`, `custom_capability_test.dart`, `schema_validator_test.dart`, `tls_bind_policy_test.dart` |
| **CONN** | Google **aur ab Dropbox** OAuth token exchange/refresh/revoke (mocked HTTP, no real API calls), token storage + auto-refresh, persistence round-trip. Dropbox add karna P0-07's stated scope ("pehle ek clean adapter interface, phir ek provider end-to-end") ko genuinely extend karta hai — proves interface generic hai, sirf Google-specific nahi (revoke mechanism jaan-bujh kar alag hai: Bearer header vs body param) | `google_drive_provider_test.dart`, `dropbox_provider_test.dart`, `connector_token_refresh_test.dart`, `connector_persistence_test.dart` |
| **LOC** | Device-state-aware dispatch gating (locked/asleep device restrictions) covers location indirectly (location is a "background-capable" category) | `device_state_gate_test.dart` — **koi dedicated location-specific test nahi hai; native location code khud test nahi ho saka** |
| **LOCK-STATE** (P1-05) | Real OS lock/screen-off detection — Android (`KeyguardManager`+`PowerManager`, broadcast-driven), Windows (`OpenInputDesktop`, poll-driven) aur Linux (`org.freedesktop.ScreenSaver` D-Bus, signal-driven) teeno native bridges ab likhi ja chuki hain aur `reportStatus()` se wire hain | **Koi automated test nahi** — teeno native implementations hain, is sandbox mein compile/run nahi ho saktin (koi Android emulator/Windows build environment/GTK+D-Bus session nahi). Real-device verification abhi baaki hai. |
| **NET** | — | **Koi automated test nahi.** Network-status handling zyada tar native code + simple client passthrough hai; koi complex server-side logic nahi jo unit-test-worthy ho |

## Honest gaps (yeh automated nahi hain)

- **Saara native code** (Kotlin `.kt`, C++ `.cc`/`.cpp`) — is sandbox
  mein Android/Windows/Linux build environment nahi tha. Yeh
  `TEST-02`'s capability matrix mein document hoga (manual verification
  chahiye hogi, real devices/emulators par).
- **Full HTTP route-level integration tests** (poori `/commands`
  request → response, ek fake WebSocketChannel ke saath) — jaan-bujh
  kar nahi likhe. Ek fake `WebSocketChannel` sahi se implement karna
  bina SDK/compilation ke bohot risky tha (galat ho to test khud hi
  galat pass/fail deta, jo test likhne se bhi bura hai). Iski jagah har
  route ka **core logic** (validation, gating, state machine) seedha,
  bina HTTP ke test kiya gaya hai — thoda kam end-to-end confidence,
  lekin bohot zyada reliable.
- **Flutter widget tests** (`task_monitor_screen.dart` ka UI khud) —
  widget testing ke liye `flutter test`'s widget-testing harness chahiye
  hoti, jo yahan verify nahi ho saki. Sirf underlying logic
  (`describeActionSafely`, event parsing) test hua hai.

## Local run karne ke commands

```bash
cd control_api && dart pub get && dart analyze && dart test
cd shared_app && flutter pub get && flutter analyze && flutter test
```

## Stage 9 additions (sab blind — kuch chala nahi)
| Category | Cover hota hai | Test file |
|---|---|---|
| WS-AUTH (revalidation) | key disable/delete/expire, device token rotate, unpair => khule sockets band; frame type/size/owner validation | `websocket_revalidation_test.dart` |
| WS-AUTH (ordering) | credentials ke bina 401 (unknown aur known session dono), valid creds + unknown session = 404 | `websocket_auth_test.dart` |
| TASK | device->server checkpoint (owner/non-owner/bad step), `sweepTasks`, guarded `rollbackTask` | `task_lifecycle_paths_test.dart` |
| LIVE | server FPS cap, last-frame replay (fresh/stale/not-running) | `screen_stream_test.dart` |
| CONN | persistent vs ephemeral key, round-trip, wrong key | `connector_key_config_test.dart` |

| TASK/ROUTE | device `task_result`; `screen_idle` signal; `/commands` route-level (pause ack, invalid transition, offline rollback, scope 403, complete server-only, timeout keeps state) — fake WebSocket devices | `stage9_followups_test.dart` |

**Abhi bhi cover NAHI:** real WebSocket handshake through middleware, duplicate-connection replacement, koi bhi Kotlin/C++ native code, `/connectors` route harness, release workflow.
