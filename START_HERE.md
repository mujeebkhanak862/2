# Start Here — sab kuch ek file mein

Yeh ek hi file hai: kya-kya diya gaya hai, Railway mein kaunse variable
daalne hain (copy-paste karne layak), aur kya karna baaki hai. Sab kuch
abhi **blind-likha / unverified** hai jab tak "✅ tested" na likha ho.

---

## 1. Railway mein daalne wale variables (copy-paste)

Railway → project → Variables mein yeh 4 daalein (zaroori):

```
ADMIN_TOKEN=<yahan openssl rand -hex 32 ka output daalein>
CORS_ALLOWED_ORIGINS=https://meri-site.netlify.app
CONNECTOR_ENCRYPTION_KEY=<yahan openssl rand -base64 32 ka output daalein>
DATA_DIR=/data
```

`ADMIN_TOKEN` aur `CONNECTOR_ENCRYPTION_KEY` khud generate karne ke liye
apne computer ke terminal mein (ya https://www.random.org jaisi jagah se):
```
openssl rand -hex 32        # ADMIN_TOKEN ke liye
openssl rand -base64 32     # CONNECTOR_ENCRYPTION_KEY ke liye
```
`DATA_DIR=/data` ke saath Railway mein ek **Volume** bhi `/data` par mount
karna hoga (warna restart par sab data kho jayega) — Railway dashboard mein
"Volumes" section se.
`CORS_ALLOWED_ORIGINS` mein apni website ka asli address daalein (jahan
`web_dashboard/index.html` host karenge, jaise Netlify ka URL).

Deploy ke baad check karein: `https://aapka-server.up.railway.app/readyz`
khola to `{"persistence_writable": true}` aana chahiye.

### Baaki, optional variables (feature chahiye tabhi)

| Variable | Kiske liye | Na ho to kya hoga |
|---|---|---|
| `GOOGLE_OAUTH_CLIENT_ID` + `GOOGLE_OAUTH_CLIENT_SECRET` | Google Drive connector | connector band rehta hai |
| `DROPBOX_APP_KEY` + `DROPBOX_APP_SECRET` | Dropbox connector | connector band rehta hai |
| `CONNECTOR_REDIRECT_BASE_URL` | OAuth ke liye apka public server URL | connector OAuth kaam nahi karega |
| `WINDOWS_CERT_BASE64` + `WINDOWS_CERT_PASSWORD` | (GitHub Secrets mein, Railway mein nahi) Windows installer sign karna | installer unsigned rahega (SmartScreen warning) |
| `ANDROID_KEYSTORE_BASE64` + `ANDROID_KEYSTORE_PASSWORD` + `ANDROID_KEY_ALIAS` + `ANDROID_KEY_PASSWORD` | (GitHub Secrets mein) signed Android release | release build nahi banegi |
| `PORT` | Server port | default `8080` |
| `SSL_CERT_PATH` + `SSL_KEY_PATH` (+ `SSL_KEY_PASSWORD`) | Khud TLS karna (Railway ke bina proxy ke) | default: plain HTTP (TLS proxy ke peeche chalayein) |
| `BEHIND_TLS_PROXY` | `true` agar Railway jaisa proxy HTTPS kar raha hai | default `false` |
| `MAX_DEVICES` | Kitne devices pair ho sakte hain | default `500` |
| `PAIRING_CODE_TTL_SECONDS` | Pairing code kitni der valid | default `300` |
| `AUDIT_RETENTION_DAYS` | Audit log kitne din rakhein | default `90` |

---

## 2. Kya-kya diya gaya hai, kahan hai

| Hissa | Kahan | Status |
|---|---|---|
| **Backend server** | `control_api/` (Dart) — pairing, commands, live screen/audio, connectors, admin API | ❌ kabhi compile/run nahi hua is sandbox mein — CI chalakar confirm karna baaki |
| **Phone/PC app** | `shared_app/` (Flutter — Android/Windows/Linux) | ❌ kisi real device par nahi chala |
| **Website** | `web_dashboard/index.html` — ek hi file: login, device list, live screen (click=tap, drag=swipe), Back/Home/Recents, text type, clipboard, live audio 🔊, signal meter | ✅ real Chromium browser mein, user jaisa use karke, **38/38 test pass** (neeche #3) — asli Dart server ke saath abhi nahi |
| **Test proof** | `qa/user_test.mjs`, `qa/USER_TEST_REPORT.md`, `qa/screenshot_live_view.png` | ✅ (backend mock ke saath — niche likha hai kya saabit karta hai) |
| **Protocol/docs** | `PROTOCOL_V1.md`, `HOW_TO_CONNECT.md`, `STAGE9_CHANGES.md`, `NATIVE_AUDIT_STAGE9.md`, `TEST_CAPABILITY_MATRIX.md`, `REAL_DEVICE_TEST_MATRIX.md`, `STATUS_VS_AUDIT.md` | reference documents |

---

## 3. Website test — kya hua

Asli Chromium browser (Playwright) mein website kholi aur ek user ki tarah
chalaya: galat password, sahi login, device list, device select, Watch Live,
screen par tap/swipe, Back/Home/Recents, text type, clipboard send/read,
audio ON, signal meter, Stop, offline-device disabled check, Logout — poore
session mein console errors bhi check kiye.

**Natija: 38/38 pass.** Isne 2 asli bugs pakde (dono fix ho gaye): ek test
ki apni chhoti JPEG ki wajah se swipe galat test ho raha tha, aur console-
error check galti se intentional wrong-password ke 401 ko pakad raha tha.

**Yeh SAABIT karta hai:** website ka JavaScript — login, device list, tap
coordinate math (real device size ke hisaab se), swipe, keys, typing,
clipboard, audio, sab — asli browser mein bina crash ke sahi chalta hai,
agar server protocol ke hisaab se jawab de.

**Yeh SAABIT NAHI karta:** asli Dart server waisa hi jawab dega ya nahi (server
khud kabhi chala nahi), asli Android phone par capture/touch sahi hoga ya
nahi (real device chahiye), real network ki speed (yahan sab turant tha,
mock hone ki wajah se).

Dobara chalane ke liye:
```
cd qa && node user_test.mjs
```

---

## 4. Ab aapko kya karna hai

1. Upar wale 4 variable Railway mein daalein, Volume `/data` par mount karein.
2. `web_dashboard/index.html` ko Netlify (ya kisi static host) par daalein —
   uska URL hi `CORS_ALLOWED_ORIGINS` mein jayega.
3. Poora zip GitHub par push karein, Actions (CI) chalayein — jo bhi fail
   ho uska log yahan bhejein.
4. Phone par app install karke ek baar screen-capture consent aur
   Accessibility ON karein, phir website se connect karke dekhein.
