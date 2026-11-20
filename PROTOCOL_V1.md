# Protocol v1 — FROZEN

Yeh spec **frozen** hai (audit ka P0 item #1 — Developer Implementation
Order, step 1: "Freeze protocol_v1 and define canonical command/event/
error envelopes"). Frozen ka matlab: in teeno envelope shapes ke
**required fields kabhi remove/rename nahi honge** — naye fields sirf
**add** ho sakte hain (aur unhe optional rakhna hoga, taaki purana client
naye server ke saath aur naya client purane server ke saath bhi chal
sake — backward/forward compatible).

Dono taraf (client aur server) isi document ko source-of-truth maante
hain:
- Client: `shared_app/lib/protocol/command_envelope.dart`,
  `event_envelope.dart`
- Server: `control_api/lib/models/errors.dart`, `routes/commands.dart`

Har envelope mein `protocol_version` field hai — agar kabhi breaking
change karni pade (field remove/rename), to version `"2.0"` banega, aur
server dono versions ko kuch waqt tak support karega (migration
window), is se pehle purana version deprecate nahi hoga.

---

## 1. Command Envelope

Client → Server → Device. Field order yahan documentation ke liye hai,
JSON mein order matter nahi karta.

```json
{
  "protocol_version": "1.0",
  "request_id": "b3f1c2a4-...",
  "api_key_id": "key_8f2a91c0",
  "capability": "screen",
  "action": "screen.capture",
  "params": { },
  "payload": null,
  "timeout_ms": 8000
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `protocol_version` | string | **haan** | `"1.0"` — major.minor. Server sirf supported major version accept karta hai. |
| `request_id` | string (UUID) | **haan** | Response/event correlation ke liye. |
| `api_key_id` | string | **haan** | Scoped key ka ID — is se `Authorization: Bearer <secret>` verify hota hai. |
| `capability` | string | **haan** | e.g. `"screen"`, `"input"`, `"files"`. |
| `action` | string | **haan** | `"<capability>.<verb>"` convention. |
| `params` | object | nahi (default `{}`) | Action-specific. |
| `payload` | string (base64) ya null | nahi | Sirf Data Channel actions ke liye. |
| `timeout_ms` | number | nahi | Default server-side. |

**Coordinate contract (`input.tap`/`input.swipe`)** — jaan-bujh kar yahan
explicit likha hai, kyunki koi bhi caller (AI orchestrator ho ya koi
aur client) is envelope se seedha reverse-engineer nahi kar sakta:
`x`/`y` (aur `x1,y1,x2,y2`) hamesha **absolute pixel coordinates** hain
(origin `0,0` top-left), us device ke real screen resolution ke against
— bilkul wahi resolution jo sabse recent `screen.capture`/
`screen.watch_live` frame ki image dimensions mein milta hai. Yeh
normalized (0.0–1.0) fractions **nahi** hain, aur teeno platforms
(Android/Windows/Linux) is contract ko consistently follow karte hain
(native implementations verify kiye gaye).

## 2. Event Envelope

Device → Server → Client (WebSocket `/sessions/{id}`).

```json
{
  "protocol_version": "1.0",
  "type": "task_progress",
  "session_id": "sess_...",
  "timestamp": "2026-09-16T10:30:00Z",
  "step": 4,
  "action": "input.tap",
  "description": "Clicking 'Submit' button",
  "result": "success",
  "screenshot_url": null
}
```

`type` ke known values: `task_progress`, `switch_event`, `task_state`
(naya — P0-01 task lifecycle ke liye). Unknown `type` client-side
`UnknownEvent` mein fall-through hota hai (forward-compatible — naya
event type add karna kabhi bhi purane client ko crash nahi karega).

**`task_state` (naya, P0-01):** jab bhi server ka `TaskRecord`
state-machine ek transition apply karta hai (`control.pause` /
`control.resume` / `control.stop` se), yeh event us session ke saare
listeners ko broadcast hota hai:

```json
{
  "protocol_version": "1.0",
  "type": "task_state",
  "session_id": "sess_...",
  "task_id": "sess_...",
  "state": "PAUSED",
  "timestamp": "2026-09-18T10:30:00Z"
}
```

`task_id` abhi `session_id` ke barabar hai (P0-01 ne yeh conscious
decision liya — envelope ka `params.session_id` hi task correlation id
ke tor par use ho raha hai, taaki koi naya required field add na karna
pade; dono fields is liye duplicate hain — future minor version mein
`session_id` chhod kar sirf `task_id` rakha ja sakta hai). `state` ka
enum: `RUNNING`, `PAUSED`, `STOPPED`, `COMPLETED`, `FAILED`.

| Field | Type | Required |
|---|---|---|
| `protocol_version` | string | **haan** |
| `type` | string | **haan** |
| `session_id` | string | **haan** (device-side se — server isko WS-multiplexing ke through fill karta hai) |
| `timestamp` | string (ISO 8601) | **haan** |
| ...type-specific fields | — | type ke hisaab se |

## 3. Error Envelope — canonical, HAR error response isi shape mein

Pehle server ka har route apna alag ad-hoc `{"error": "..."}` string
bhejta tha — ab **sab jagah** yeh exact shape hai:

```json
{
  "error": {
    "code": "SCOPE_DENIED",
    "message": "Yeh key \"input\" capability ke liye authorized nahi hai",
    "request_id": "b3f1c2a4-..."
  }
}
```

| Field | Type | Required |
|---|---|---|
| `code` | string (enum, neeche list) | **haan** — machine-readable, client isi par switch kare, `message` par nahi (message badal sakta hai, `code` kabhi nahi) |
| `message` | string | **haan** — human-readable, sirf display ke liye |
| `request_id` | string ya null | jab applicable ho |

### Canonical error codes (frozen enum — naye codes add ho sakte hain, purane kabhi remove nahi honge)

| Code | HTTP status | Kab |
|---|---|---|
| `UNAUTHORIZED` | 401 | Bearer token invalid/missing |
| `SCOPE_DENIED` | 403 | Valid key, lekin is capability/action ki ijazat nahi |
| `FORBIDDEN` | 403 | Auth theek, lekin resource kisi aur ka hai (e.g. doosre device ki key) |
| `NOT_FOUND` | 404 | Device/key/session nahi mila |
| `INVALID_REQUEST` | 400 | Schema validation fail (P0-04) |
| `UNSUPPORTED_PROTOCOL_VERSION` | 400 | `protocol_version` major mismatch |
| `PAYLOAD_TOO_LARGE` | 413 | Size limit cross (P1-08) |
| `RATE_LIMITED` | 429 | P0-05 |
| `DEVICE_OFFLINE` | 503 | Command bheji, device connected nahi hai |
| `TIMEOUT` | 504 | Device ne timeout ke andar respond nahi kiya |
| `CAPABILITY_UNAVAILABLE` | 200 (result body mein, error nahi) | OS/platform is action ko support nahi karta — **yeh HTTP error nahi hai**, `messaging.*` jaisi cases ke liye (P1-06, "capability-unavailable result, not pretend success") |
| `INTERNAL` | 500 | Unexpected server error |

**`CAPABILITY_UNAVAILABLE` alag hai** — yeh HTTP-level error nahi, balke
command **result** ke andar aata hai (`{"result": {"error_code":
"CAPABILITY_UNAVAILABLE", ...}}`), kyunki request khud valid thi, bas
device/OS us action ko support nahi karta. Is distinction ko audit ka
MSG-01 test specifically maangta hai ("capability reports unavailable;
no false success").


## Messaging adapters (P1-06, Android) — `background` capability

Provider-specific, **notification inline-reply** based (koi private API / UI scraping nahi). Sirf supported apps: WhatsApp, WhatsApp Business, Telegram, Signal, Messenger, Google Messages, Samsung Messages. Baaki apps/platforms => `CAPABILITY_UNAVAILABLE`.

| Action | Params | Result | Scope |
|---|---|---|---|
| `messaging.get_event` | `limit` (1–50), `since_ms`, `package` (optional) | `{events: [{event_id, package, app, sender, text, posted_at_ms, can_reply}]}` | `background` |
| `messaging.prepare_reply` | `event_id`, `text` (<=1000) | `{draft_id, event_id, package, app, to, text, expires_in_seconds}` — **bhejta nahi** | `background` |
| `messaging.send_reply` | `draft_id` (sirf — free-text override nahi) | `{sent: true, delivery: "handed_to_app", event_id, package}` | `messagingReply` (alag, high-risk toggle) |

Rules / limits:
- Do-step: pehle `prepare_reply`, phir `send_reply(draft_id)`. Draft **single-use**, 5 minute TTL.
- Reply tabhi ho sakti hai jab us app ki notification abhi dismiss na hui ho (`can_reply: true`); warna error `NOT_FOUND`. Notification mein inline reply na ho => `CAPABILITY_UNAVAILABLE`.
- `sent` ka matlab app ko handoff hai — **delivery confirm nahi hoti**.
- Rate limit: 5 replies/minute (device-side `RATE_LIMITED`). Text max 1000 chars (`TOO_LONG`).
- Events/drafts sirf RAM mein (max 50 events); disk par kuch nahi. Notification access (Settings) ON honi chahiye, warna `CAPABILITY_UNAVAILABLE`.

## Stage 9 additions (blind, unverified)
- **WebSocket close codes:** `4001` device unpaired, `4004` credential revoked/expired/rotated ya session ab available nahi (session/screen listeners; server har 30 s + har revoke/rotate/unpair par dobara validate karta hai).
- **`/sessions/{id}`, `/screen/{id}` handshake order:** credentials ke bina **401** (session exist kare ya na kare); valid credentials + unknown session => 404; valid credentials + access nahi => 403.
- **Device -> server `screen_frame`:** `data` String hona chahiye aur <= 8 MiB; server har session par ~15 fps se tez frames drop karta hai. Naye `/screen/{id}` viewer ko aakhri frame (<= 30 s purana, task RUNNING) replay hota hai.
- **`screen.watch_live` result:** `{started:true, first_frame_received:bool}` ya `{error_code: PERMISSION_REQUIRED|STREAM_FAILED, message}`. HTTP 200 ke andar bhi `error_code` ho sakta hai — client ko check karna hoga. Android par static screen par pehla frame der se aa sakta hai (`first_frame_received:false` error nahi hai).
- **Messaging:** unsupported `package` => `UNSUPPORTED_TARGET` (Dart ise `CAPABILITY_UNAVAILABLE` mein map karta hai); event ids ab SHA-256 ke 64-bit prefix (`msg_<16 hex>`).
- **Device -> server `task_result` event:** `{kind:"event", type:"task_result", session_id, state:"completed"|"failed", reason?}` — sirf owning device se, sirf RUNNING/PAUSED task par; baaki ignore.
- **Server -> device `screen_idle`:** `{kind:"screen_idle", session_id}` — aakhri `/screen` viewer ke 15 s (grace) baad; device us session ka live stream band karta hai.
- **Command TIMEOUT semantics:** control (`pause/resume/stop`) par timeout ho to server transition **rakhta hai** (outcome unknown) aur device ko `task_state` dubara bhejta hai; error message mein yeh likha hota hai. Pehle rollback hota tha.
- **`GET /connectors`:** naye fields `reconnect_required`; `connected` ab sach hai (decryptable credential). **`GET /readyz`** (persistence writable?) alag hai `GET /healthz` se.

## Web dashboard additions (blind, unverified)
- **Admin API** (env `ADMIN_TOKEN` >= 32 chars; otherwise 404): `GET /admin/devices`, `GET /admin/devices/{id}/tasks[?active=true]`, `POST /admin/devices/{id}/commands` (normal Command Envelope), `POST /admin/ws-ticket` -> `{ticket, expires_in}`.
- **Browser WebSocket:** `wss://…/screen/{session}?ticket=<ticket>` (ticket single-use, 60 s). Frames = base64 JPEG text messages.
- **`screen.watch_live` params:** optional `fps` (1..30, default 20), `quality` (`low|medium|high|ultra`, default `high`); result adds `screen:{width,height}`, `fps`, `quality`.
- **`input.key`:** `{key: back|home|recents|notifications}` — Android only (others => CAPABILITY_UNAVAILABLE); scope `touch_input`.
- **CORS:** only origins listed in `CORS_ALLOWED_ORIGINS`.

## Stage 9.1 — speed additions (blind, unverified)
- **Binary `screen_frame` (device -> server):** raw bytes `[0x01][idLen:1][sessionId utf8][JPEG bytes]` as a WebSocket binary message — replaces (in addition to) the JSON `{kind:"screen_frame",...}` text form, which still works (Windows/Linux fallback).
- **`WS /admin/control?ticket=`:** `{id, device_id, capability, action, params, timeout_ms?}` -> `{id, ok:true, result}` or `{id, ok:false, status, error, error_code?}`. `capability:"__ping"` gets an immediate `{ok:true, result:{pong:true}}` with no device round-trip (latency meter).

## Stage 9.2 — system audio (blind, unverified)
- **Binary frame `type` byte:** `[type][idLen][sessionId][payload]` — `0x01` = screen JPEG (unchanged), `0x02` = audio PCM16LE mono 16kHz chunk (NEW). Same envelope both ways.
- **`audio.watch_live` / `audio.stop_live`:** same shape as `screen.watch_live`/`screen.stop_live` (`{session_id}`); gated by the `screen_view` scope (not a new scope). Android 10+ only — other platforms/versions => `CAPABILITY_UNAVAILABLE`.
- **`WS /audio/{session_id}?ticket=`:** binary PCM16 chunks, same ticket-auth as `/screen/{id}`. No "last chunk replay" (unlike screen) — a new listener just hears silence until the next chunk.
