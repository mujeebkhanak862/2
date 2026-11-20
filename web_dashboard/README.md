# Pulse — Device Control Center (web dashboard)

Single-file website (`index.html`): branded UI (logo + dark theme), saare paired
devices ki list (online/offline, active tasks), smooth live screen, click = tap,
drag = swipe, Back/Home/Recents, text type, clipboard bhejna/padhna, aur ek live
"signal" (ping) meter.

## Stage 9.1 — speed changes (server + app + website)
Sab kuch ek saath fast karne ke liye:
- **Fast control channel (`/admin/control`):** website ab tap/swipe/key/type/
  clipboard ke liye har baar naya HTTP request nahi banati (TLS+auth+response
  overhead). Ek WebSocket khulta hai, commands usi par pipeline hote hain —
  interactive latency kaafi kam.
- **Binary screen frames:** device ab live-stream frame base64-encoded JSON
  text ke bajaye raw JPEG bytes (binary WebSocket frame) bhejta hai. Na
  base64 ka ~33% size overhead, na JSON parse — na device par, na browser
  mein. Browser `createImageBitmap()` se frame decode karta hai (hardware
  path, UI thread block nahi hoti jaisi `data:` URL/`<img>` se hoti thi).
- **Admin rate-limit bucket:** `ADMIN_TOKEN` se aane wali requests ko alag,
  bada bucket mila (pehle 120/min general limit se interactive clicking par
  429 aa sakta tha).
- **Android gesture:** tap/swipe ka internal delay 50ms se 20ms.
- **Signal meter:** header mein ek ping pill — control-channel ka
  browser<->server round-trip dikhata hai (device tak nahi jaata), taaki
  pata chale connection kaisa hai.

## Server (Railway) env vars
| Var | Matlab |
|---|---|
| `ADMIN_TOKEN` | >= 32 chars (`openssl rand -hex 32`). Iske bina `/admin/*` band rehta hai. **Isse saare devices ka poora control milta hai — kisi se share na karein.** |
| `CORS_ALLOWED_ORIGINS` | Website ka origin, jaise `https://meri-site.netlify.app` (comma se kai). Local test: `http://localhost:8000` |

## Deploy
1. `index.html` ko Netlify par drop karein (ya `python3 -m http.server 8000` se local).
2. Page kholein → Server URL (https://… Railway) + Admin token → Connect.
3. Device chuniye → **Watch Live**.

## Stage 9.2 — system audio
🔊 button (Watch Live ke saath) device ki playback audio (video/music/game)
website par bajati hai. Sirf Android 10+; DRM-protected apps (kai streaming
apps) khamoshi dengi — Android ka rule hai. Windows/Linux abhi supported
nahi (`CAPABILITY_UNAVAILABLE`).

## Phone par pehle ek baar (user karta hai)
- Screen capture consent (app → Permission Center → Screen capture).
- Touch/Back/Home/typing ke liye Accessibility service ON.
- Background mein chalane ke liye "background mode" ON (battery optimization off).

## Limits (honest)
- Frames JPEG hain (video codec nahi): 20–30 fps tak chal sakta hai, par asli video jaisa nahi; fast game mein thoda jhatka.
- Static screen par Android naya frame nahi deta (bug nahi).
- DRM/banking apps ki screen black aati hai (Android rule).
- Click→touch mapping Android par exact (device screen size result mein aata hai); Windows/Linux par frame size ko screen size maana jata hai (unverified).
- Awaaz (audio) abhi nahi — future step.
- Sab kuch abhi **blind-likha/unverified** hai: deploy ke baad real device par test karein.
