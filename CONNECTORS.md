# Connectors (Google Drive, aur aage aur bhi) — Setup

P0-07 ne `/connectors/*` ko ek real, kaam karne wale OAuth flow mein badal
diya hai (pehle sirf ek stub tha). Isko use karne ke liye kuch environment
variables set karni hongi Railway (ya jahan bhi `control_api` chal raha ho)
par.

## Zaroori environment variables

| Variable | Kya hai | Example |
|---|---|---|
| `CONNECTOR_REDIRECT_BASE_URL` | Aapke Control API ka public URL (jahan Google callback bhejega) | `https://control-api-production-xxxx.up.railway.app` |
| `CONNECTOR_ENCRYPTION_KEY` | 32-byte base64 key — connector tokens isi se encrypt hoke store hote hain | `openssl rand -base64 32` se generate karein |
| `GOOGLE_OAUTH_CLIENT_ID` | Google Cloud Console se | (sirf agar Google Drive connector use karna hai) |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google Cloud Console se | (sirf agar Google Drive connector use karna hai) |

**`CONNECTOR_ENCRYPTION_KEY` ab connector connect karne ke liye zaroori hai (Stage 9):** key na ho to
`POST /connectors/<n>/auth` server-misconfigured error deta hai (pehle user poora OAuth karke restart par sab kho deta tha).
Server start phir bhi crash nahi karta (sirf warning), aur dev mein ephemeral key sirf tests/local ke liye bachi hai — matlab **restart par saare connected
connectors disconnect ho jaayenge** (dobara "Connect" karna padega). Production
ke liye is key ko set karna aur safely rakhna (jaise ek password manager mein)
zaroori hai.

## Google Drive connector banane ke steps (Google Cloud Console)

1. https://console.cloud.google.com par ek project banayein (ya existing use karein)
2. "APIs & Services" → "Credentials" → "Create Credentials" → "OAuth client ID"
3. Application type: **Web application**
4. Authorized redirect URI mein exactly yeh daalein (apna URL use karke):
   `https://control-api-production-xxxx.up.railway.app/connectors/google_drive/callback`
5. Client ID aur Client Secret Railway environment variables mein daal dein
   (`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`)
6. "OAuth consent screen" mein `drive.readonly` scope add karein

## Flow kaise kaam karta hai

1. App `POST /connectors/google_drive/auth` call karti hai (device bearer
   token ke saath) → server ek `authorization_url` deta hai
2. App us URL ko browser/webview mein khol deti hai — user Google mein login
   karta hai aur permission deta hai
3. Google `GET /connectors/google_drive/callback` par redirect karta hai —
   server yahan tokens exchange karke **encrypted** store kar leta hai
4. Ab `GET /connectors` call karke dekha ja sakta hai ke connector "connected"
   hai, aur `GET /connectors/google_drive/files` se real files list milti hai
5. Access token expire ho jaaye to agli call par **automatically** refresh ho
   jaata hai — kuch extra karne ki zaroorat nahi
6. `POST /connectors/google_drive/disconnect` se access hamesha ke liye
   revoke ho jaata hai (Google ki taraf se bhi, aur is server se bhi)

## Naya connector add karna (future)

1. `control_api/lib/connectors/connector_provider.dart` ka `ConnectorProvider`
   interface implement karke ek nayi class banayein (jaisa `google_drive_
   provider.dart`)
2. `control_api/lib/connectors/connector_registry.dart` mein register karein
3. Bas — poora OAuth/PKCE/encryption/refresh flow already generic hai,
   dobara likhne ki zaroorat nahi

## Abhi ka scope (P0-07) — kya included hai, kya nahi

- ✅ OAuth 2.0 Authorization Code + PKCE flow
- ✅ Encrypted credential storage (AES-GCM-256)
- ✅ Automatic token refresh
- ✅ Revoke/disconnect (provider-side + local)
- ✅ Ek real, end-to-end test action (`google_drive.list_files`)
- ⏳ **Nahi included:** connector actions abhi generic `/commands` envelope
  (jo screen/input/files jaise device capabilities use karta hai) se
  integrate nahi hain — connectors device par nahi, is server par hi
  provider ki API ko seedha call karte hain. AI tool registry mein inko
  device capabilities ki tarah expose karna **P1-02**'s scope hai.

## Stage 9 notes
- `GET /connectors` mein ab `reconnect_required: true` aata hai agar stored credential decrypt nahi ho sakta (key badli ya restart ke baad ephemeral key) — tab `connected:false` aur `available_actions: []`. Dobara `POST /connectors/<n>/auth` karein.
- Deployment: `GET /healthz` hamesha 200 (Railway process-alive check). `GET /readyz` 503 deta hai agar `DATA_DIR` likhne layak nahi (Volume `/data` mount nahi).
- Real Google/Dropbox OAuth round-trip abhi tak kisi ne chalaya nahi — 🧪 aapko apne client IDs se test karna hai.
