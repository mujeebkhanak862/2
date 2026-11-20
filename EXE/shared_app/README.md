# Universal Device Agent — shared_app

> **Protocol contract:** `../PROTOCOL_V1.md` (root of this zip) — command/
> event/error envelope ka **frozen, canonical spec**. Yeh app aur
> `control_api` dono isi ek document ko source-of-truth maante hain.

Yeh ek **poora, compile-ready Flutter project** hai jo Android, Windows,
aur Linux teeno platforms ko ek hi codebase se serve karta hai
(Architecture v4). Isme do hisse hain:

1. **Dart/Flutter shared layer** (`lib/`) — protocol, dashboard UI,
   task monitor — teeno OS mein hubahu same chalta hai.
2. **Native platform code** (`android/`, `windows/`, `linux/`) — har OS
   ki apni capability implementations (screen capture, input, files,
   waghera), jo `lib/platform_channels/platform_channel_bridge.dart` ke
   fixed contract se Dart side se baat karti hain.

## Project structure

```
shared_app/
  pubspec.yaml
  lib/
    protocol/            # command/event envelope, API client, WebSocket client,
                          # device status, activity event, API key model
    platform_channels/   # Dart<->native fixed contract (ChannelNames)
    dashboard/            # pairing, permission wizard, key manager,
                          # device status, activity history, home nav
    task_monitor/         # live preview, step timeline, pause/stop, background tasks
    browser/               # CdpClient — Chrome DevTools Protocol (Windows/Linux browser control)
    main.dart               # full app shell: Pairing -> Setup Wizard -> Home Dashboard
  android/                 # Gradle project + Kotlin native code (12 files)
  windows/                 # CMake project + C++ native code (win32 runner + 9 managers)
  linux/                   # CMake project + C++ native code (GTK app + 9 managers)
```

## Key Manager — QR code se key share karna

`dashboard/key_manager_screen.dart` mein naya key banate waqt ab secret
ke saath ek **QR code** bhi dikhta hai (`qr_flutter` package se) — is
QR mein `{api_url, key_id, secret}` encoded hai. Koi doosra device/tool
(jaise ek AI agent setup screen) isko **scan** karke seedha key le
sakta hai, lambi secret string haath se type kiye bina. QR sirf dialog
mein dikhta hai (ek hi baar), kahin save/log nahi hota.

## Control API integration — device-side loop ab band hai

`lib/protocol/agent_connection.dart` (naya) — device ka background
listener jo `control_api/` (backend, alag project — is repo ke bahar)
se **incoming commands sunta hai** aur unhe already-bani capabilities
tak dispatch karta hai:

- `AgentConnection` — persistent WS (`WS /devices/{id}/agent`),
  auto-reconnect, heartbeat.
- `CommandDispatcher` — `CommandEnvelope` ko asal `ScreenCaptureBridge`/
  `InputBridge`/`FilesBridge`/waghera calls mein convert karta hai.

`main.dart` ab poora flow karta hai: Pairing → `api.pairDevice()` (naya
method, `POST /devices/pair`) → bearer token milta hai → `AgentConnection`
start hoti hai → Setup Wizard → Home Dashboard.

Pehle yeh loop **adhoora** tha — sirf commands **bhejne** ka client code
tha (`api_client.dart`), **sunne** wala side kahin nahi tha. Ab dono
directions complete hain.

## 9 capabilities — teeno platforms mein

Pairing, Screen Capture, Input, Files, App Launcher, Clipboard, Browser,
Location & Network, Contacts — sab ban chuki hain. Har ek ka native
implementation alag hai per-OS (jaisa har OS kaam karta hai), lekin Dart
side se same fixed contract (`ChannelNames`) use hota hai.

| Capability | Android | Windows | Linux |
|---|---|---|---|
| Pairing | ✅ | ✅ | ✅ |
| Screen Capture | ✅ | ✅ | ✅ |
| Input (tap/swipe/type) | ✅ | ✅ | ✅ |
| Files | ✅ | ✅ | ✅ |
| App Launcher | ✅ | ✅ | ✅ |
| Clipboard | ✅ | ✅ | ✅ |
| Browser | ✅ (semantic tree) | ✅ (CDP) | ✅ (CDP) |
| Location & Network | ✅ | ✅ | ✅ |
| Contacts | ✅ | ✅ (caveat) | ✅ (caveat) |

Detail har capability ke liye neeche hai.

## Kya bana (Screen Capture)

| Platform | Consent mechanism | Capture method | Notes |
|---|---|---|---|
| Android | System `MediaProjection` dialog (mandatory, `MainActivity.onActivityResult`) | Foreground Service + `ImageReader` on a `VirtualDisplay` | Persistent notification jab tak share ho rahi ho (OS-mandated) |
| Windows | OS khud yellow capture border/indicator dikhata hai | `Windows.Graphics.Capture` + `Direct3D11CaptureFramePool`, WIC se JPEG encode | Requires Win10 1903+ |
| Linux (X11) | Koi separate dialog nahi (session-level trust) | `XGetImage` + libjpeg-turbo | Simple, fast, ~15 FPS polling |
| Linux (Wayland) | `xdg-desktop-portal` **mandatory** consent dialog | Session/consent handshake ab shared `WaylandPortalSession` mein (Input ke saath common) — is file mein sirf PipeWire stream consumption (`pw_stream`, format negotiation, JPEG encode) | ✅ complete — syntax-verified via `g++ -fsyntax-only` against real `libpipewire-0.3-dev`/`libspa-0.2-dev` headers |

Teeno platforms same contract expose karte hain — `requestPermission`,
`captureScreenshot`, continuous JPEG-frame EventChannel, `stopStream` —
jo `ScreenCaptureBridge` (Dart) already consume karta hai
(`shared_app/lib/platform_channels/platform_channel_bridge.dart` mein
`requestPermission()` aur `stopLiveStream()` is capability ke liye add
kiye gaye).

**Known gap:** ab koi gap nahi — Wayland bhi X11 jitna hi complete hai.
Dono real headers ke against compile-check ho chuke hain (source-only
verification; actual runtime test ek Wayland session par hi possible
hai jahan xdg-desktop-portal aur PipeWire daemon chal rahe hon).

## Kya bana (Input)

| Platform | Consent mechanism | Method | Notes |
|---|---|---|---|
| Android | Settings > Accessibility, manually enable (OS-mandated, bypass nahi) | `AccessibilityService.dispatchGesture` (tap/swipe) + `ACTION_SET_TEXT` (type) | Focused field mein hi text set hota hai |
| Windows | Koi alag dialog nahi — app apne session mein trusted hai | `SendInput` (absolute mouse coords, `KEYEVENTF_UNICODE` for typing) | Multi-monitor virtual-desktop coords use kiye |
| Linux (X11) | Koi alag dialog nahi | `XTestFakeMotionEvent`/`FakeButtonEvent`/`FakeKeyEvent` | Unicode typing ke liye scratch-keycode remap technique (xdotool jaisi) |
| Linux (Wayland) | `xdg-desktop-portal` RemoteDesktop **mandatory** consent dialog | DBus `CreateSession`→`SelectDevices`→`Start`, phir `NotifyPointerMotionAbsolute`/`NotifyPointerButton`/`NotifyKeyboardKeysym` | ✅ syntax-verified; **known limitation** neeche dekhein |

Teeno platforms same contract — `tap`, `swipe`, `typeText`, `isEnabled`,
`openAccessibilitySettings` (Android-only, no-op elsewhere) — jo Dart
`InputBridge` mein already add kiya gaya hai.

**Known limitation (Wayland only):** ab fix ho gaya — RemoteDesktop aur
ScreenCast ab ek shared `WaylandPortalSession` (`wayland_portal_session.h/.cc`)
use karte hain. `EnsureReady()` dono capabilities ek saath select karta hai
(`SelectSources` + `SelectDevices`), phir ek hi `Start` call se dono ke
liye consent milta hai — user ko **ek hi dialog** dikhta hai (do ke
bajaye), aur `NotifyPointerMotionAbsolute` ka `stream` parameter ab asal
PipeWire node id use karta hai (jo `Start`'s `streams` array se aata hai),
hardcoded `0` nahi. Teeno files (`wayland_portal_session.cc`,
`screen_capture_wayland_portal.cc`, `input_wayland_portal.cc`) individually
aur saath compile-check ho chuke hain.

## Complete file listing (native code)

```
android/app/src/main/kotlin/com/deviceagent/app/
  MainActivity.kt, ChannelNames.kt, PairingManager.kt,
  ScreenCaptureHandler.kt, ScreenCaptureService.kt,
  InputAccessibilityService.kt, InputHandler.kt, FilesHandler.kt,
  AppLauncherHandler.kt, ClipboardHandler.kt, BrowserHandler.kt,
  LocationNetworkHandler.kt, ContactsHandler.kt
android/app/src/main/res/
  xml/accessibility_service_config.xml, values/strings.xml,
  values/styles.xml, drawable/launch_background.xml, mipmap-*/ic_launcher.png

windows/runner/
  main.cpp, win32_window.{h,cpp}, flutter_window.{h,cpp}, utils.{h,cpp},
  Runner.rc, runner.exe.manifest, resource.h, resources/app_icon.ico,
  pairing_manager.{h,cpp}, screen_capture_manager.{h,cpp},
  input_manager.{h,cpp}, files_manager.{h,cpp},
  app_launcher_manager.{h,cpp}, clipboard_manager.{h,cpp},
  browser_manager.{h,cpp}, location_network_manager.{h,cpp},
  contacts_manager.{h,cpp}

linux/
  main.cc, my_application.{cc,h}, pairing_manager.{h,cc},
  wayland_portal_session.{h,cc},
  screen_capture_manager.{h,cc}, screen_capture_x11.{h,cc},
  screen_capture_wayland_portal.{h,cc}, input_manager.{h,cc},
  input_x11.{h,cc}, input_wayland_portal.{h,cc}, files_manager.{h,cc},
  app_launcher_manager.{h,cc}, clipboard_manager.{h,cc},
  browser_manager.{h,cc}, location_network_manager.{h,cc},
  contacts_manager.{h,cc}
```

**Windows note:** doc ne "C++/C#" suggest kiya tha, lekin Flutter ka real
Windows desktop embedder sirf C++ (native Win32 runner) support karta hai —
C# ka koi supported method-channel host nahi hai. Isliye implementation
pure C++ mein hai.

**Pairing note:** code sirf locally generate hota hai (offline). Control
API registration (`POST /devices/pair` jaisa endpoint) baad mein
`api_client.dart` mein add hoga jab backend contract finalize ho.

## Kya bana (Files)

| Platform | Sandbox root (default) | Broader access | Notes |
|---|---|---|---|
| Android | `getExternalFilesDir()` — koi extra permission nahi | SAF folder picker (`ACTION_OPEN_DOCUMENT_TREE`), `content://` URIs `DocumentFile` se | Requires `androidx.documentfile:documentfile` Gradle dependency (project mein abhi koi `build.gradle` nahi hai — jab Gradle setup banega tab add karna) |
| Windows | `%LOCALAPPDATA%\DeviceAgent\sandbox` | `IFileDialog` (FOS_PICKFOLDERS) native folder picker | Base64 via `Crypt32` (`CryptBinaryToStringA`/`CryptStringToBinaryA`) — extra dependency nahi |
| Linux | `$XDG_DATA_HOME/device-agent/sandbox` | `GtkFileChooserDialog` | Base64 via glib (`g_base64_encode`/`decode`) |

Sab teeno platforms same contract — `listDirectory`, `readFile`,
`writeFile`, `deleteFile`, `getAllowedRoot`, `pickDirectory` — jo Dart
`FilesBridge` mein already add kiya gaya hai. **Path traversal (`..`)
teeno jagah explicitly reject hota hai** — resolved canonical path sandbox
root ke andar hi honi chahiye, warna `FORBIDDEN`/`NOT_FOUND` error.

**Compile-check:** Linux ka pure logic hissa (filesystem + glib base64 +
GtkFileChooserDialog, flutter_linux wiring ke bina) real `libgtk-3-dev`
headers ke against clean compile hua. Windows/Android files is sandbox
mein compile-test nahi ho sakti (Win32/Android SDK headers available nahi
hain), lekin standard, well-documented APIs use kiye gaye hain
(`std::filesystem`, `IFileDialog`, `DocumentFile`).

## Kya bana (App Launcher)

| Platform | Mechanism | `identifier` format |
|---|---|---|
| Android | `PackageManager.getLaunchIntentForPackage` | package name (e.g. `com.spotify.music`) |
| Windows | `ShellExecute` (exe/.lnk/URL sab handle karta hai) + Start Menu `.lnk` enumeration | file path ya `.lnk` shortcut path |
| Linux | `GDesktopAppInfo`/`GAppInfo` registry, executable-path fallback | `.desktop` file id (e.g. `org.gnome.Nautilus.desktop`) ya executable path |

Teeno jagah same 3 methods: `launchApp`, `isAppInstalled`,
`listInstalledApps` (`{identifier, name}` pairs) — Dart `AppLauncherBridge`
mein already add kiya gaya.

**Compile-check:** Linux ka pure GIO logic (`GDesktopAppInfo`/`GAppInfo`,
flutter_linux wiring ke bina) compile hua — lekin iske liye
`gdesktopappinfo.h` header ko **`gio-unix-2.0`** pkg-config module chahiye
hota hai, akela `gio-2.0` kaafi nahi hai. Jab CMakeLists.txt banega, isko
`pkg_check_modules` mein add karna zaroori hoga.

## Kya bana (Clipboard)

| Platform | Mechanism | Note |
|---|---|---|
| Android | `ClipboardManager` | **Android 10+ limitation:** background apps clipboard read nahi kar saktay, sirf foreground/focused app — `readText()` un cases mein `null` deta hai, yeh bug nahi hai |
| Windows | Win32 `OpenClipboard`/`GetClipboardData`/`SetClipboardData` (`CF_UNICODETEXT`) | Standard, extra dependency nahi |
| Linux | GTK `gtk_clipboard_wait_for_text`/`set_text`/`store` | `store()` call zaroori hai taaki app band hone ke baad bhi clipboard content zinda rahe |

Sab jagah same 2 methods: `readText`, `writeText` — Dart `ClipboardBridge`
mein add kar diya (Android limitation bhi doc-comment mein note ki hai).

**Compile-check:** Linux ka pure GTK logic real `libgtk-3-dev` headers ke
against clean compile hua.

## Kya bana (Browser) — do bilkul alag approach, platform ke hisaab se

**Windows/Linux — Chrome DevTools Protocol (CDP):**
Native code jaan-bujh kar chhota rakha (sirf launcher) — asal control
poori tarah Dart mein hai (`shared_app/lib/browser/cdp_client.dart`),
kyunki CDP khud hi ek cross-platform WebSocket/JSON protocol hai:
1. `browser_manager.{cpp,cc}` — Chrome/Edge/Chromium ko registry (Windows
   "App Paths") ya `PATH` (Linux) se dhoond kar
   `--remote-debugging-port=9333` ke saath launch karta hai, apni sandbox
   profile directory mein (user ke default Chrome profile se alag).
2. `CdpClient.connect()` — `http://localhost:9333/json/version` se
   WebSocket URL leta hai, phir `navigate`, `click`, `typeText`,
   `getVisibleText`, `evaluateJavaScript`, `captureScreenshot` — sab
   isi client ke methods hain.

**Trade-off jo pehle discuss hui:** yeh browser ki apni **alag profile**
use karta hai (user ke already-khule Chrome se alag), isliye pehli baar
kisi site par login karna padega — us profile mein persist ho jaata hai
(sandbox directory mein), dobara-dobara login nahi karna padega.

**Android — semantic Accessibility-tree control (no root/adb possible):**
`InputAccessibilityService` ko extend kiya —
- `findAndClick(text)` / `findAndType(label, text)` — poore node-tree
  mein text/content-description se element dhoondh kar seedha
  `ACTION_CLICK`/`ACTION_SET_TEXT` (coordinates guess nahi karte)
- `getVisibleText()` — poore tree ka text walk karke
- `openUrl()` — `Intent.ACTION_VIEW` se **user ke asli, already-logged-in
  browser** mein URL kholta hai (Chrome/Firefox/jo bhi default ho)

Yeh **asli browser session** use karta hai, koi alag automation-profile
nahi — bilkul jaisa discuss hua tha. Limitation (already bataya gaya):
canvas-rendered content (games, kuch custom-drawn web-apps) accessibility
tree mein expose nahi hota, un par yeh kaam nahi karega — yeh koi bug
nahi, non-root Android automation ki fundamental limit hai (TalkBack ki
bhi yahi limit hai).

**Compile-check:** Windows/Linux ka pure launcher-logic (registry lookup/
`PATH` search + process spawn) dono clean compile hue jahan headers
available thay. Dart `cdp_client.dart` ko Dart SDK na hone ki wajah se
`dart analyze` se verify nahi kar saka — carefully likha hai, lekin jab
Flutter project setup ho tab ek baar `flutter analyze` chala lena.

## Kya bana (Location & Network) — sab 8 capabilities ab complete 🎉

| Platform | Location | Network status |
|---|---|---|
| Android | `LocationManager` (one-shot `requestLocationUpdates` + `removeUpdates`, 10s timeout + last-known fallback) | `ConnectivityManager` (type) + `WifiManager` (SSID) |
| Windows | `Windows.Devices.Geolocation.Geolocator` (WinRT), `RequestAccessAsync()` | WLAN API (`wlanapi.h`) for SSID, `InternetGetConnectedState` fallback |
| Linux | `org.freedesktop.GeoClue2` (DBus, **system bus** — polkit consent dialog) | `org.freedesktop.NetworkManager` (DBus, **system bus** — primary connection type + SSID) |

Sab jagah `getLocation()`/`getNetworkStatus()` **exactly** woh keys return
karte hain jo `device_status.dart`'s `DeviceLocation.fromJson`/
`DeviceNetwork.fromJson` expect karte hain (`latitude`, `longitude`,
`accuracy_m`, `timestamp`, `source` | `connected`, `ssid`,
`connection_type`, `timestamp`) — taaki yeh data seedha
`api_client.dart`'s `reportLocation()` ko forward ho sake bina kisi
extra mapping ke.

**Important Linux note:** GeoClue2 aur NetworkManager dono **system bus**
par hain — Wayland portals (screen/input, jo session bus par hain) se
alag. Yeh galti se session bus use karna sabse common bug hoti is tarah
ke code mein, isliye explicitly likh diya.

**Compile-check pakड़ा ek real bug:** pehle draft mein `Stop()` DBus call
mein ek extra `nullptr` argument tha (12 args diye, function 11 leta hai)
— `g++` ne turant pakad liya. Fix karne ke baad poora GeoClue2 +
NetworkManager logic (flutter_linux wiring ke bina) clean compile hua.

Windows/Android files compile-test nahi ho saki (SDK headers available
nahi is sandbox mein), standard documented APIs use kiye hain.

**Ek Windows caveat:** unpackaged (non-MSIX) desktop apps ke liye
`Geolocator::RequestAccessAsync()` kaam karta hai bashart-e user ne
Windows Settings > Privacy > Location mein "Desktop apps" ko access di
ho — yeh ek OS-level toggle hai, in-app dialog nahi (jaisa MSIX-packaged
apps mein hota).

## Full project — compile-ready (build scaffolding included)

`shared_app/` ek **poora Flutter project** hai — Dart code (`lib/`) aur
teeno platforms ka native code (`android/`, `windows/`, `linux/`) sab
ek hi jagah, jaisa Flutter khud expect karta hai:

```
shared_app/
  pubspec.yaml
  lib/                    # (jaisa pehle tha)
  android/                # Gradle project + Kotlin native code
  windows/                # CMake project + C++ native code
  linux/                  # CMake project + C++ native code
```

## Build karne ke liye — exact steps

1. **`flutter create .`** poore `shared_app/` folder ke andar chala do
   **ek baar**. Yeh sirf woh files fill karega jo hamesha Flutter
   tooling khud generate/manage karta hai aur jo abhi missing hain
   (`android/gradlew`, `android/gradlew.bat`, gradle-wrapper `.jar`,
   `windows/flutter/`, `linux/flutter/` — yeh saari "ephemeral"/
   generated files hain, hum inhe hand-write nahi karte kyunki yeh
   Flutter SDK version ke saath tightly coupled hoti hain). Humara
   custom code (`android/app/...`, `windows/runner/...`, `linux/*.cc`)
   already maujood hai, isliye `flutter create .` unhe **overwrite nahi
   karega** (sirf missing files add karta hai, existing ko chhedta
   nahi — jab tak `--overwrite` flag na do).

2. `android/local.properties.example` ko copy karke `local.properties`
   banao, apne SDK paths daal do (file ke andar instructions hain).

3. `flutter pub get`

4. Platform ke hisaab se:
   - `flutter run -d windows`
   - `flutter run -d linux`
   - `flutter run` (Android device/emulator connected hone par)

## Kya maine khud banaya vs kya `flutter create .` banayega

| Maine banaya (custom, capability-aware) | `flutter create .` banayega (generic tooling glue) |
|---|---|
| `android/app/build.gradle`, `settings.gradle`, `build.gradle`, `gradle.properties` | `android/gradlew`, `gradlew.bat`, gradle-wrapper `.jar` |
| `android/app/src/main/kotlin/...` (saare 12 handler files) | — |
| `android/app/src/main/res/` (icons, styles, accessibility config) | — |
| `windows/CMakeLists.txt`, `windows/runner/CMakeLists.txt` | `windows/flutter/CMakeLists.txt`, `generated_plugins.cmake`, `generated_plugin_registrant.cc/h`, `ephemeral/` |
| `windows/runner/*.{cpp,h}` (win32_window, flutter_window, main, utils, saare 9 capability managers) | — |
| `linux/CMakeLists.txt` (pkg-config dependencies sab add ki: gtk, gio, gio-unix, pipewire, x11/xtst, turbojpeg, ebook) | `linux/flutter/CMakeLists.txt`, `generated_plugins.cmake`, `generated_plugin_registrant.cc/h`, `ephemeral/` |
| `linux/main.cc`, `my_application.{cc,h}`, saare 9 capability managers | — |
| Placeholder app icons (Android mipmaps, Windows `.ico`) — koi real branding nahi, sirf isliye taaki build fail na ho `@mipmap/ic_launcher` na milne se | — |

## Honest gaps jo abhi bhi hain

- **Gradle wrapper `.jar`** aur **`gradlew`/`gradlew.bat`** scripts hand-
  write nahi kiye (yeh binary/generated files hain) — `flutter create .`
  se aayenge.
- **Windows/Linux `flutter/` subfolder** (ephemeral, SDK-version-specific
  CMake glue) bhi isi tarah `flutter create .` se aana chahiye —
  hand-likhna version-fragile hota, isliye jaan-bujh kar nahi likha.
- Maine `windows/runner/*.{h,cpp}` (win32_window, flutter_window, main,
  utils) standard Flutter template se **memory se** likhe hain (real
  Windows SDK is sandbox mein available nahi thi compile-test karne ke
  liye) — yeh well-known, stable template hai, lekin agar Flutter SDK
  ne kal koi field/method rename kiya ho to ek chhota sa mismatch ho
  sakta hai. Linux/Android wale hissay jahan tak ho saka waha maine
  real headers se compile-verify kiya (jaisa pichle rounds mein dikhaya).
- Koi actual app icon/branding nahi hai — sirf placeholder circles
  (indigo color, jo app theme se match karta hai) taaki build fail na
  ho. Jab chaho real icon daal sakte ho.
