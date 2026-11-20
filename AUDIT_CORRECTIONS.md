# Audit documents mein jo statements ab galat/overstated hain (item 93)

Yeh original audit ke "🟢 Code present" jaise claims par **source review ke baad** corrections hain.

| Audit claim | Asli haal (review mein mila) | Ab |
|---|---|---|
| WebSocket authorization 🟢 | Server par tha, lekin Flutter `WebSocketChannel.connect(uri)` Authorization header bhejta hi nahi tha — live monitoring kabhi connect nahi hoti | Fix (26) |
| Dashboard Pause/Stop/Watch Live/Locate/Keepalive | Sab 401: dashboard device token bhejta, `/commands` sirf API key leta | `/owner/*` endpoints (25) |
| Desktop browser CDP 🟢 | Browser-level endpoint (`/json/version`) se connect — `Page.*` commands real Chrome par fail; fake server ne bug chhupaya | Page target (76); fake server real jaisa banaya |
| Android screen capture | `resultCode != -1` check — `RESULT_OK == -1`, yani granted hone par bhi projection start nahi hota tha; Android 14 callback missing | Fix (61, 62) |
| Windows screenshot | `StartCapture` sirf stream mein; GPU texture par seedha Map; base64 padding/trailing bytes galat — screenshot kabhi sahi nahi nikalta | Fix (83) |
| Windows clipboard.read | Text `*out` mein copy hi nahi hota tha (hamesha khaali) | Fix (83) |
| Custom capabilities 🟢 | Un tasks par control.pause/stop kaam nahi karta tha; manifests global the | Fix (45, 15) |
| AI tool registry | `control.*` tools kabhi dikhte hi nahi the | Fix (46) |
| Connectors | Sirf list_files; sirf device token | + download, API key access (86) |
| Linux/Windows `app_launcher.launch` | Arbitrary command execution | Allowlist (12) |
| "Persistent agent" | Activity/process marne par agent band | Foreground service + back→background (85); poora background isolate ⛔ |
| TEST_COVERAGE.md "25 files / 21 tests" + "2 workflows" | Asal mein 30 files thi aur workflows repo mein thi hi nahi | 40 files, 1 CI workflow (ab sach) |
| Location/Battery/Network "implemented" | Server tak kabhi pahunchte nahi the | `StatusReporter` (32) |

**Rule jo ab follow karein:** kisi feature ko "Complete" tab likhna jab (code + security check + test + real-device evidence) sab ho — abhi sirf code stage tak hai.

## Stage 9 corrections to earlier claims
Dekhein `STATUS_VS_AUDIT.md` ki "Stage 9" table: stale-task prune (59) aur stale-sweeper (43) pehle sirf docs mein "done" the; lock-state/notifications/contacts ke matrix claims purane the; release signing ka `.gitignore` exist nahi karta tha.
