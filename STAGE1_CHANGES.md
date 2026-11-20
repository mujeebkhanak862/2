# Stage 0 + Stage 1 changes (items 1-23)

**Verification status:** Dart/Flutter SDK is sandbox mein install nahi ho saka, isliye
**kuch bhi compile/run nahi hua**. Sirf yeh hua: (a) saari changed `.dart` files tree-sitter
se parse hui (0 syntax errors), (b) code manually review hua. Pehla kaam aapka:

```
cd control_api && dart pub get && dart analyze && dart test
cd shared_app  && flutter pub get && flutter analyze && flutter test
```
Jo bhi analyzer error / failing test aaye woh mujhe bhej do.

## Breaking behaviour changes (clients ko pata hona chahiye)
- `GET /devices/{id}/status`, `/activity`, `GET /capabilities`, `/capabilities/{name}/schema` ab **auth maangte hain** (device token ya us device ki API key).
- `GET /devices/{id}/ai-tools`: key sirf apne device ke liye.
- `control.*` commands ko ab `params.session_id` **required**.
- Dusre device ki `session_id` use karne par 404.
- `browser.navigate` sirf http/https. `app_launcher.launch` (Linux/Windows) sirf listed apps.
- Naye env vars: `PAIRING_SECRET` (optional, app mein `--dart-define=PAIRING_SECRET=...`), `MAX_DEVICES` (default 500).
- Railway: `RAILWAY_ENVIRONMENT*` env detect hoti hai => `BEHIND_TLS_PROXY` ke bina bhi 0.0.0.0 par bind.

## Item-wise
| # | Status | Kya hua |
|---|---|---|
| 1 | NOT DONE | Tools yahan chal hi nahi sakte. Upar ke commands aap chalao. |
| 2 | Script | `scripts/bootstrap_platforms.sh` (flutter create, non-destructive). Mene chalaya nahi. |
| 3 | Done | `.github/workflows/ci.yml` |
| 4 | Done | Railway auto-detect + startup `CONFIG WARNING`s (missing env vars). |
| 5 | Partial | Dockerfile `DART_VERSION` ARG, `.dockerignore` test/. `pubspec.lock` aap `pub get` ke baad commit karo. Non-root jaan-bujh kar NAHI (Railway volume root-owned). |
| 6 | Done | `claimSession/sessionBelongsTo` (app_state), commands.dart + switch endpoint. |
| 7 | Done | `handleAgentMessage` ownership + `pendingCommandDevice`. |
| 8 | Done | `authorizeForDevice` on status/activity. |
| 9 | Done | ai-tools key.deviceId check. |
| 10 | Partial | rate limit (10/hr/IP), `MAX_DEVICES`, optional `PAIRING_SECRET`, validation. **Server-issued one-time pairing-code registry nahi bana** (UX decision chahiye). |
| 11 | Done | `escapeHtml` + CSP headers on connector callback. |
| 12 | Done (native, unbuilt) | Linux: sirf `g_app_info_get_all` mein listed IDs. Windows: sirf Start Menu .lnk allowlist. |
| 13 | Done | Server validator + Dart dispatcher + CDP client + Android Kotlin. |
| 14 | Done | Extended blocklist, trailing dot/space/ADS normalization; server + device dispatcher (`device_policy.dart`). Native layers par alag check nahi. |
| 15 | Done | `registered_by` ownership, count/size caps; sirf owner device ki keys call kar sakti hain. |
| 16 | Done | `bodySizeLimitMiddleware` (global). |
| 17 | Done | `X-Forwarded-For` sirf proxy mode mein; pair ka alag bucket. `input` 40/min limit unchanged. |
| 18 | Done | `readJsonObject`, `ApiKeyScope.tryParse`, `sanitizeLocation`. |
| 19 | Done | 128-bit device id, 96-bit key id, exists-check. |
| 20 | Done | envelope `api_key_id` server override. |
| 21 | Done (server) | `DELETE /devices/{id}`, `POST /devices/{id}/rotate-token`, API key `expires_in_days` + `last_used_at`. App mein iska UI/client method abhi nahi. |
| 22 | Partial | Constant-time compares done; O(n) hash-index nahi. |
| 23 | Done | /capabilities auth + per-device custom manifests, `registered_by` bahar nahi jaata. |

## Bonus (Stage 3 ke items jo raste mein theek ho gaye)
- #38 `timeout_ms` ab honor hota hai (1s-120s clamp).
- #45 Custom-capability tasks ab pause/stop ho sakte hain.
- #48 Broadcast loops exception-safe.
- #51 `a..b.txt` ab block nahi; sirf asli `..` segment.

## Tests
- `control_api/test/stage1_security_test.dart` (naya)
- `shared_app/test/device_policy_test.dart` (naya)
