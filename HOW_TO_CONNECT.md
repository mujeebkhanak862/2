# HOW TO CONNECT — App ko Backend se jodna (step by step)

Yeh guide teen cheezon ke through le jaayegi:
1. Backend (`control_api`) ko Railway par deploy karna
2. Railway se URL lena
3. Woh URL app (`shared_app`) ke andar **ek jagah** paste karna

Bas itna karna hai — iske baad app aur backend khud connect ho jaayenge
jab bhi app khulega.

---

## Step 1 — Railway par Backend Deploy Karna

1. [railway.app](https://railway.app) par jao, account banao (GitHub se
   sign-in kar sakte ho, asaan hai).
2. **"New Project"** → **"Deploy from GitHub repo"** ya **"Empty Project"**
   choose karo.
   - Agar GitHub use kar rahe ho: `control_api/` folder ko ek naye GitHub
     repo mein upload karo, phir Railway ko woh repo connect karo.
   - Agar seedha upload karna hai: Railway ka CLI use kar sakte ho
     (`npm i -g @railway/cli`, phir `railway up` `control_api/` folder
     ke andar se).
3. Railway khud `control_api/Dockerfile` ko dhoond lega aur uska use
   karke build karega — **koi extra setting nahi karni** (Dockerfile
   aur `railway.json` pehle se maujood hain isi zip mein).
4. **Zaroori: ek Volume attach karo** (taaki data server-restart mein na
   kho) — Railway project ke **"Settings" → "Volumes" → "New Volume"**
   par jao, mount path `/data` do. Bas itna karna hai — code already
   isi path par apna data (devices, API keys, activity history) save
   karta hai.
5. Deploy poora hone ke baad, Railway project ke **"Settings" →
   "Networking" → "Generate Domain"** par click karo. Yeh tumhe ek URL
   dega, kuch aisa:
   ```
   https://control-api-production-xxxx.up.railway.app
   ```
6. **Is poore URL ko copy kar lo** — agla step isi ke liye hai.

---

## Step 2 — App ko apna Railway URL batana (build/run ke waqt)

**P0-03 update:** URL ab source code mein edit nahi karna — ek
`--dart-define` flag se pass hota hai, taaki URL kabhi source control
mein commit na ho aur ek hi command se dev/production switch ho sake.

Development (apne computer par `control_api` local chala kar test
karna) — kuch bhi extra pass karne ki zaroorat nahi, default hi
`http://localhost:8080` hai:

```bash
cd shared_app
flutter run -d windows   # ya -d linux, ya Android device connect karke
```

Production (Railway wale URL se connect karna) — apna URL
`--dart-define=CONTROL_API_URL=...` ke saath pass karo:

```bash
flutter run --dart-define=CONTROL_API_URL=https://control-api-production-xxxx.up.railway.app
```

> **Zaroori:** yahan hamesha `https://` (http nahi) use karna — agar
> koi non-localhost URL plaintext `http://` ke saath diya jaaye to
> **release build khud startup par fail ho jaayega** (jaan-bujh kar,
> taaki galti se credentials/commands plaintext internet par na
> jaayein). Localhost par dev ke liye http chalta hai.

---

## Step 3 — App build karna (release ke liye)

`shared_app/README.md` mein poori detail hai, lekin short version — build
karte waqt bhi wahi `--dart-define` flag chahiye:

```bash
cd shared_app
flutter create .        # sirf pehli baar, missing tooling files fill karta hai
flutter pub get
flutter build windows --dart-define=CONTROL_API_URL=https://control-api-production-xxxx.up.railway.app
# ya: flutter build apk --dart-define=CONTROL_API_URL=https://...
# ya: flutter build linux --dart-define=CONTROL_API_URL=https://...
```

---

## Ab automatically kya hoga (koi extra kaam nahi)

Jaise hi app khulegi:

1. **Pairing screen** dikhegi — ek code generate hoga (device ke andar
   hi, offline).
2. "Continue" dabate hi, app **khud** tumhare Railway backend ko call
   karegi (`POST /devices/pair`) — kyunki URL already Step 2 mein
   hardcode ho chuka hai, tumhe kuch type nahi karna.
3. Backend se ek "pehchaan token" milega — app ise apne paas save kar
   legi (memory mein, is session ke liye).
4. App **khud** backend ke saath ek permanent connection khol degi
   (background mein) — ab backend jab bhi koi command bheje ("screenshot
   lo", "click karo" waghera), device turant sun lega aur kar dega.
5. Dashboard khulega, jahan se tum **API Keys** bana sakte ho — yeh
   woh keys hain jo kisi bhi external AI/tool ko is device ko control
   karne ke liye chahiye hongi.

**Yaani:** ek baar Step 1-2-3 karne ke baad, tumhe kabhi dobara koi URL
type nahi karna — app khud sab kuch backend se connect kar legi jab bhi
khulegi.

---

## Ek important cheez samajh lo

Backend (Railway par) **hamesha chalta rehna chahiye** taaki app kabhi
bhi connect ho sake — Railway isko apne aap chalaye rakhta hai
(free tier mein kuch usage-limits hoti hain, paid plan unlimited
uptime deta hai). Agar backend down ho jaaye (Railway maintenance,
free-tier sleep, waghera), app tab tak commands nahi bhej/receive kar
payegi jab tak backend wapas na chale.

---

## Agar kabhi URL badalna pade

1. Naya `--dart-define=CONTROL_API_URL=...` flag ke saath **rebuild**
   karo (`flutter build apk --dart-define=CONTROL_API_URL=...` /
   `flutter build windows --dart-define=CONTROL_API_URL=...` /
   `flutter build linux --dart-define=CONTROL_API_URL=...`)
2. Naya build sab devices par phir se install karna hoga (purana build
   purane URL ko hi yaad rakhega, kyunki yeh build-time constant hai)

---

## Self-hosting bina Railway ke (advanced, optional)

Agar Railway ki jagah apna server/VPS use kar rahe ho **bina kisi
reverse proxy ke** (Railway khud HTTPS terminate karta hai, ek apna
VPS shayad nahi karega), to `control_api` khud bhi seedha HTTPS/WSS par
listen kar sakta hai — server start karte waqt yeh do environment
variables set karo:

```
SSL_CERT_PATH=/path/to/fullchain.pem
SSL_KEY_PATH=/path/to/privkey.pem
```

(Optional: `SSL_KEY_PASSWORD` agar private key encrypted hai.)

**Agar Railway (ya koi aur reverse-proxy-based PaaS) use kar rahe ho:**
in `SSL_*` vars ki zaroorat nahi (woh khud edge par HTTPS terminate
karte hain) — lekin ab (audit fix P0-03) sirf inhe na set karna kaafi
nahi hai. Ek naya env var bhi set karna hoga:

```
BEHIND_TLS_PROXY=true
```

**Yeh kyun zaroori hai:** pehle, agar `SSL_CERT_PATH`/`SSL_KEY_PATH`
set nahi the, server chup-chap plaintext par **sab interfaces**
(`0.0.0.0`) par bind ho jaata — agar deployment mein reverse proxy
lagana koi bhool jaata, device tokens/API keys plaintext internet par
expose ho sakte the, bina kisi warning ke. Ab **safe default**: koi bhi
TLS signal na ho (na direct certs, na `BEHIND_TLS_PROXY=true`), to
server sirf `127.0.0.1` (localhost) par bind hota hai — bahar se koi
connect hi nahi kar sakta. Railway jaisi services par `BEHIND_TLS_PROXY=true`
set karna is liye zaroori hai, taaki Railway ka internal network se
container tak ka (already-private) HTTP hop kaam kar sake.

**Local development mein** (apne laptop par `dart run bin/server.dart`)
kuch set karne ki zaroorat nahi — localhost-only default hi bilkul sahi
hai, aur app khud bhi localhost se hi connect kar rahi hogi.

---

## Deployment durability (DEP-01) — Volume, health check, scaling limits

### Data survive karne ke liye Volume zaroori hai

`control_api` apna poora state (devices, API keys, activity log,
connector credentials, capability registrations) ek JSON file mein
rakhta hai — path `DATA_DIR` env var se aata hai (Dockerfile mein
already `/data` set hai). **Railway par is path ko ek Volume se mount
karna zaroori hai**, warna restart par (deploy, crash-recovery, Railway
maintenance) sab kuch khatam ho jaata hai:

1. Railway dashboard → apni service → "Volumes" tab
2. "New Volume" → mount path `/data` do
3. Redeploy karo

Server har startup par ek clear log line print karta hai: agar
`DATA_DIR` likhne-ke-laayak nahi hai to ek loud warning; agar likhne-
ke-laayak hai lekin 0 devices load hui, to ek reminder ke Volume check
kar lo (ho sakta hai yeh sirf fresh deployment ho, ya ho sakta hai
Volume attach nahi hai).

### Health check

`GET /healthz` hamesha `200 ok` deta hai jab tak process chal raha hai
— Railway (aur `railway.json` mein already configured) isko use karke
decide karta hai ke deployment healthy hai ya restart chahiye.

### Multi-instance / scaling — ek zaroori limitation

Yeh poora system **single-process, in-memory-plus-JSON-file** design
par bana hai — jaan-bujh kar, is project ke scale (ek user ki devices)
ke liye sabse simple, reliable choice. Iska matlab:

- **Ek se zyada Railway replica/instance chalana currently support nahi
  hai.** Har instance ki apni alag memory hogi (devices, rate-limit
  counters, pending OAuth states, waghera) — ek instance par pair kiya
  gaya device doosre instance ko dikhega hi nahi.
- Agar kabhi genuinely multiple instances chalane ki zaroorat pade
  (bahut saare concurrent users, geographic distribution, waghera), to
  yeh poora `AppState`/`Persistence` layer ek shared database (Postgres/
  Redis) par migrate karna hoga — abhi ke scope se bahar hai, lekin
  architecture isko rok nahi raha (`AppState` ek single class hai jahan
  saara state hai — ek clean migration point).
- Railway ka "Restart Policy: ON_FAILURE" (already `railway.json` mein)
  single-instance ke liye theek hai — crash hone par automatically
  restart hoga, Volume se state wapas load ho jayegi.

---

## Stage 1 security update (env vars)

| Variable | Zaroori? | Matlab |
|---|---|---|
| `CONNECTOR_ENCRYPTION_KEY` | Production mein haan | Connector credentials ki encryption |
| `CONNECTOR_REDIRECT_BASE_URL` | Connectors ke liye haan | OAuth callback base URL |
| `PAIRING_SECRET` | Recommended | Set ho to `/devices/pair` mein same `pairing_secret` chahiye (app: `--dart-define=PAIRING_SECRET=...`) |
| `ADMIN_SECRET` | Optional (min 16 chars) | Owner ke liye: `POST /pairing-codes` ko `Authorization: Bearer <ADMIN_SECRET>` se call karke ek-baar-use pairing code milta hai |
| `REQUIRE_PAIRING_CODE` | Optional (`true`) | `true` ho to `/devices/pair` sirf server-issued valid code se chalta hai (`PAIRING_SECRET` ignore). Pehle `ADMIN_SECRET` set karein, warna pehla device pair nahi hoga |
| `PAIRING_CODE_TTL_SECONDS` | Optional (default 300) | Code ki validity, 60–3600 ke beech |
| `MAX_DEVICES` | Optional (500) | Total paired devices ki limit |
| `DATA_DIR` | Haan (`/data`) | Railway Volume mount path |

Railway par `RAILWAY_ENVIRONMENT*` automatically detect hoti hai, isliye alag se `BEHIND_TLS_PROXY` zaroori nahi.
Detail ke liye `STAGE1_CHANGES.md` dekhein.


## Pairing code se naya device jodna (Item 10)
1. Code lo: `curl -X POST https://<server>/pairing-codes -H "Authorization: Bearer $ADMIN_SECRET"` (ya pehle se paired device ke bearer token se). Response mein `pairing_code` (jaise `ABCD-EFGH`) aata hai — 5 minute valid, sirf ek baar use ho sakta hai.
2. Naye device ki app mein **Server pairing code** field mein wo code daalo, device name likho, Continue dabao.
3. Code use ho gaya ya expire ho gaya to naya lena padega. Server restart par saare pending codes invalid ho jaate hain.


## Background mein chalana (Item 85)
* **Windows:** window band (X) karne par agent tray mein chala jaata hai (quit nahi hota). Tray icon par right-click -> **Open** / **Quit**. "Start at login" ab `--background` ke saath register hota hai => login par window chhupi, sirf tray icon. (Agar login ke waqt tray tayyar na ho to window dikh jaati hai — jaan-bujh kar, taaki agent unreachable na rahe.)
* **Linux:** Permission Center mein do option (ek waqt mein ek): **Start at login** (XDG autostart) ya **Auto-restart on crash (systemd)** — user service `~/.config/systemd/user/universal-device-agent.service`, `Restart=on-failure`. Yeh *graphical session* ke andar chalti hai (screen/input capture ko display chahiye), boot-time system service nahi. Manual: `systemctl --user status universal-device-agent`. Tray Linux par abhi nahi (GTK mein standard tray nahi; AppIndicator extra dependency hai).
* **Android:** foreground service + **headless engine** — app swipe-away ke baad bhi agent chalta rahe (agent mode ON ho). Notification batati hai ki agent "connected" hai ya "background mode" mein. Screen-capture consent aur permission dialogs ke liye app kholni padti hai (`NEEDS_UI`). Details: `ANDROID_HEADLESS_DESIGN.md`.

## Stage 9 — release builds aur deployment checks
1. **Railway:** `/data` par Volume mount karein aur `DATA_DIR=/data` set karein; phir `GET /readyz` 200 dena chahiye (503 => Volume nahi). `CONNECTOR_ENCRYPTION_KEY` (`openssl rand -base64 32`) connectors ke liye zaroori hai.
2. **Android release signing:** keystore `android/app/key.properties` (repo-relative `shared_app/android/app/key.properties`) + `release.jks` — dono `.gitignore` mein hain. Local: `keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`. Keystore kho gaya to future updates upload nahi ho paenge.
3. **GitHub release:** repo Variables mein `CONTROL_API_URL` (https) aur Secrets mein `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`; phir tag `vX.Y.Z` push karein (`.github/workflows/release.yml`) — draft release banega. Version pubspec/`--build-name`, `versionCode` = run number.
4. **Windows:** installer VC++ runtime bundle karta hai. Code signing optional: Secrets `WINDOWS_CERT_BASE64` (pfx base64) + `WINDOWS_CERT_PASSWORD` daalein, warna binary unsigned (SmartScreen warning). Android reboot auto-start `BootReceiver` se hai (OEM autostart permission chahiye ho sakti hai).

## Web dashboard (Control Center)
Railway env: `ADMIN_TOKEN` (`openssl rand -hex 32`), `CORS_ALLOWED_ORIGINS` (website origin). Website: `web_dashboard/index.html` (Netlify). Details: `web_dashboard/README.md`.
