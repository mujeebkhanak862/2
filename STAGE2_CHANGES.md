# Stage 2 changes (items 24-37, plus 52 & 87 jo raste mein ban gaye)

**Verification:** compile/run nahi hua (SDK nahi). Sab changed `.dart` files tree-sitter se parse hui (0 syntax errors). Tests aakhir mein aap chalayenge.

| # | Status | Kya hua |
|---|---|---|
| 24 | Done | `config/credential_store.dart` (flutter_secure_storage). `main.dart` start par saved credentials se reconnect. 401 par credentials clear + dobara pair. **pubspec mein naya dependency: `flutter_secure_storage`.** |
| 25 | Done (naya design) | Server par `POST /owner/commands` + `POST /owner/sessions/{id}/switch` (`routes/owner.dart`): device token se authenticate, in-memory owner key ke saath wahi `/commands` pipeline. Dashboard ko ab alag API key nahi chahiye. |
| 26 | Done | `SessionEventChannel`/`LiveScreenChannel` ab `Authorization` header bhejte hain (`IOWebSocketChannel`). |
| 27 | Done | Session channel auto-reconnect (exponential backoff + jitter), `onError` handled. |
| 28 | Done (Dart) | `dashboard/permission_center.dart`: screen capture, accessibility, files folder, contacts, location. Home se reachable. **Notifications permission (POST_NOTIFICATIONS) abhi nahi** — uska native bridge hai hi nahi (Stage 7 ke saath). |
| 29 | Done | Wizard ka scope ab device-local **policy ceiling** hai: secure storage mein save, aur `AgentConnection` har command par check karta hai (`POLICY_DENIED`). `control.*` hamesha allowed. |
| 30 | Done | `task_monitor/active_tasks_screen.dart` + `GET /tasks[?active=true]`. |
| 31 | Done | `_stopLive` ab `session_id` bhejta hai + try/catch. |
| 32 | Done | `StatusReporter`: battery (naya native `getBattery` Android/Linux/Windows), network, location (sirf agar local policy Location allow kare) `status_update` mein; `POST /devices/{id}/network`; `location.refresh` ka result server par save. |
| 33 | Done | `AgentConnection.onConnected` -> har reconnect par full status. |
| 34 | Done | Snapshot mode ab `screen.capture` se asli screenshot dikhata hai (Take/Refresh snapshot). |
| 35 | Done | Asli QR (`qr_flutter`) + device name input. |
| 36 | Done | Keepalive/status screens mein error handling + `mounted` checks (Locate/Refresh mein pehle se tha). |
| 37 | Done | Pairing double-tap guard; credentials connect se pehle save; `_startAgent` purana connection band karta hai (leak nahi). |
| 52 | Done | `status_update.background_active` ab report hota hai (connected = true). `background.keepalive` abhi bhi sirf `{alive:true}` deta hai. |
| 87 | Done | `GET /tasks`. |

## Naye/badle files
- Server: `routes/owner.dart` (naya), `routes/devices.dart` (+network), `routes/commands.dart` (location.refresh persist), `websocket/handlers.dart` (status_update extras), `util/http_utils.dart` (+sanitizeNetwork), `bin/server.dart` (mount).
- App: `config/credential_store.dart`, `protocol/status_reporter.dart`, `protocol/task_summary.dart`, `dashboard/permission_center.dart`, `task_monitor/active_tasks_screen.dart` (sab naye); `main.dart`, `pairing_screen.dart`, `home_dashboard.dart`, `task_monitor_screen.dart`, `websocket_client.dart`, `api_client.dart`, `agent_connection.dart`, `api_key.dart`, `platform_channel_bridge.dart`, native `LocationNetworkHandler.kt`, `location_network_manager.cc/.cpp` (battery).
- Tests: `control_api/test/stage2_owner_test.dart`, `shared_app/test/stage2_wiring_test.dart`.

## Jaan-bujh kar nahi kiya
- Dashboard ke liye alag scoped API key nahi bani (owner endpoints behtar tha).
- `GET /tasks` sirf last 200.
