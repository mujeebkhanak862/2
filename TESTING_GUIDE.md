# Universal Device Agent — Final Testing Guide

Is session mein humne yeh sab implement/fix kiya:

1. **WebSocket security (P0)** — `/devices/{id}/agent`, `/sessions/{id}`, `/screen/{id}` ab auth-checked hain
2. **Task lifecycle** — `control.complete`/`control.fail`, real checkpoint reporting, `control.resume` server-checkpoint adoption, task state persistence
3. **Real lock-state detection** — Android, Windows, Linux teeno (`reportStatus()` se wire)
4. **Android release signing** — proper keystore support + warning agar nahi hai
5. **Repo-wide `.gitignore`** (pehle kahin nahi tha)
6. **Linux branding/packaging** — `.desktop` entry + icon
7. **TLS bind-address safe default (P0-03)** — ⚠️ **niche "BREAKING CHANGE" section zaroor padhein agar aapne pehle se Railway/koi server deploy kiya hua hai**

Yeh guide un sab ko test karne ke exact steps deti hai, priority order mein.

---

## ⚠️ BREAKING CHANGE agar aapka server pehle se live hai

Pehle, agar `SSL_CERT_PATH`/`SSL_KEY_PATH` set nahi the, server **sab interfaces** par plaintext bind ho jaata tha (Railway jaisi services ke liye yehi chalta tha, kyunki Railway khud edge par HTTPS terminate karta hai). Ab yeh **secure-by-default** hai: koi TLS signal na ho to server sirf `localhost` par bind hoga.

**Agar aap Railway (ya kisi reverse-proxy-based service) par pehle se deployed hain**, to naye code se redeploy karne ke baad server **unreachable ho jayega** jab tak aap ek naya environment variable set nahi karte:

```
BEHIND_TLS_PROXY=true
```

Railway dashboard → apni service → Variables → yeh add karein, phir redeploy. Local development (apne laptop par test karte waqt) mein kuch karne ki zaroorat nahi.

---

## 0. Prerequisites (apne machine par)

| Tool | Kyun chahiye |
|---|---|
| Dart SDK (Flutter ke saath aata hai) | `control_api` tests |
| Flutter SDK | `shared_app` tests + Android/Windows/Linux build |
| Android Studio + SDK/NDK | Android build |
| Visual Studio 2022 (Desktop C++ workload) | Windows build |
| `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libpipewire-0.3-dev`, `libx11-dev`, `libxtst-dev`, `libturbojpeg0-dev`, `libebook1.2-dev` | Linux build |

```bash
flutter doctor -v   # sab green hona chahiye jis platform ke liye build karna hai
```

---

## 1. Backend tests — `control_api` (SABSE PEHLE yeh chalayein)

```bash
cd universal_device_agent/control_api
dart pub get
dart test
```

**Expect karein:** sab tests pass, khaaskar yeh naye/changed wale:
- `test/websocket_auth_test.dart` — 11 cases (missing token, wrong device, wrong scope, revoked key, unknown session)
- `test/task_lifecycle_completion_test.dart` — control.complete/fail transitions + persistence round-trip
- `test/task_test.dart` — poora TaskRecord state machine
- Baaki pehle se maujood tests (scope, schema validation, rate limiting, activity audit, etc.)

Agar koi test fail ho, **command output paste kar dijiye** — main fix kar dunga.

---

## 2. Shared app (Dart/Flutter logic) tests

```bash
cd universal_device_agent/shared_app
flutter pub get
flutter test
```

**Expect karein:** naye `resume_checkpoint_test.dart` (4 cases) + baaki existing tests (`task_progress_description_test.dart`, `messaging_unavailable_test.dart`, `event_envelope_test.dart`, `app_config_test.dart`).

---

## 3. Manual server smoke test (backend live chala kar)

```bash
cd universal_device_agent/control_api
export DATA_DIR=/tmp/uda_test_data   # ya jahan bhi likhna chahte ho
dart run bin/server.dart
```

Doosri terminal se:
```bash
curl http://localhost:8080/health   # ya jo bhi port config mein hai
```

**Check karne wali cheez:** server bina crash hue start hota hai, `DATA_DIR` mein `state.json` ban jaata hai (empty state se).

---

## 4. Android — build + install

```bash
cd universal_device_agent/shared_app
flutter build apk --debug          # pehle debug se try karein
```

Agar yeh clean build ho jaaye:
```bash
flutter install                    # connected device/emulator par
```

### Android-specific cheezein test karein:
- [ ] Pairing flow (QR ya code se) kaam karta hai
- [ ] Permission Wizard sahi permissions maangta hai
- [ ] Screen capture / live view kaam karta hai
- [ ] Input (tap/swipe/type via Accessibility Service) kaam karta hai
- [ ] **Naya:** Device ko lock karein (power button) — Dashboard/Control API logs mein device state `ONLINE_LOCKED` show hona chahiye (agar aap `/sessions/{id}` ya activity log dekh rahe hain). Unlock karein → `ONLINE_UNLOCKED` wapas aana chahiye.
- [ ] Ek task pause karein, app ko **force-stop karke dobara kholein** (real restart, sirf background nahi), phir resume karein — checkpoint sahi jagah se continue hona chahiye (yeh exactly woh scenario hai jo `server_checkpoint` fix cover karta hai).

### Release build (signing test):
```bash
flutter build apk --release
```
- Agar `android/app/key.properties` nahi banaya, to build output mein **WARNING banner** dikhna chahiye (loud, missable nahi).
- Real keystore banane ke liye: `android/app/key.properties.example` dekhein, `keytool` command wahan hai.
- Keystore bana kar `key.properties` fill karne ke baad dobara `flutter build apk --release` chalayein — warning gayab honi chahiye, aur `apkanalyzer` ya `jarsigner -verify` se confirm kar sakte hain ke real key se signed hai:
  ```bash
  jarsigner -verify -verbose -certs build/app/outputs/flutter-apk/app-release.apk
  ```

---

## 5. Windows — build

```powershell
cd universal_device_agent\shared_app
flutter build windows
```

### Windows-specific:
- [ ] App launch hoti hai, capabilities register hoti hain (crash na ho)
- [ ] **Naya:** Win+L se workstation lock karein — 2 second ke andar device state `ONLINE_LOCKED` report hona chahiye (Control API logs ya dashboard check karein). Unlock karein → `ONLINE_UNLOCKED`.

---

## 6. Linux — build

```bash
cd universal_device_agent/shared_app
flutter build linux
```

### Linux-specific:
- [ ] App app-menu mein sahi naam + icon ke saath dikhti hai (naya `.desktop` fix) — iske liye bundle ko standard location par install karna padega (`~/.local/share/applications/` mein `.desktop` file copy + icon `~/.local/share/icons/hicolor/256x256/apps/` mein, ya poori `install()` target chalayein: `cmake --install build`)
- [ ] Screen ko lock karein (GNOME: Super+L, ya jo bhi aapka screen locker hai) — device state `ONLINE_LOCKED` aana chahiye. **Agar aapka window manager minimal hai (i3/sway bina locker ke), yeh kaam nahi karega — yeh known/documented gap hai, bug nahi.**
- [ ] X11 aur Wayland dono session mein screen capture test karein (dono alag code paths hain)

---

## 7. End-to-end security test (sabse zaroori)

Yeh confirm karta hai ke P0 WebSocket fix real duniya mein kaam karta hai:

1. Ek device pair karein, ek task/session start karein (kisi capability se, jaise screen).
2. `wscat` ya `websocat` se seedha connect karne ki koshish karein **bina** valid token ke:
   ```bash
   websocat ws://localhost:8080/screen/<session_id>
   ```
   → **401/403 milna chahiye, connection accept nahi honi chahiye.**
3. Ab sahi API key ke saath (Authorization header) try karein → connect hona chahiye.
4. Ek doosri (galat) device ka token le kar `/devices/<real_device_id>/agent` par connect karne ki koshish karein → reject hona chahiye.

---

## Agar kuch fail ho

Command output (poora stack trace/error) mujhe paste kar dijiye — main us specific file ko dekh kar fix karunga. Ek baar mein sab kuch test karne ki koshish mat kijiye; upar wale order mein ek-ek step follow karein, kyunki backend tests (Step 1-2) sabse zyada cheezein catch karenge bina kisi hardware/emulator ki zaroorat ke.

## Stage 9 note
Pehla CI run: `dart analyze` / `flutter analyze --no-fatal-infos` (lint infos fatal nahi), aur build jobs analyze/test fail hone par bhi chalte hain — taaki ek hi run mein saare logs milein. Pehla green run aane ke baad `--fatal-infos` aur C++ `-DDEVICE_AGENT_WERROR=ON` wapas lagayein. Nayi device checks: `REAL_DEVICE_TEST_MATRIX.md` ke S9-* rows.
