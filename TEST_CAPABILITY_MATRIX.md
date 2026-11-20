> **STALE WARNING (Stage 9):** is file ki capability table purani hai — jaise
> lock-state (ab teeno platform par native code hai), Android notifications
> aur messaging (ab implemented), aur Windows/Linux contacts (OS limitation
> nahi, Partial). **Naya aur authoritative audit: `NATIVE_AUDIT_STAGE9.md`.**
> Stale rows neeche theek kar di gayi hain; native cells ka evidence `NATIVE_AUDIT_STAGE9.md` mein hai.

# Platform Capability Matrix (TEST-02)

Is matrix ka rule (audit se): **koi bhi cell "Supported" tab tak nahi
likha jaata jab tak (a) koi automated test usay execute karke pass na
kare, ya (b) main khud code padh kar directly verify na kar loon.**
Sirf "file exist karti hai is liye kaam karti hogi" — yeh kabhi kaafi
nahi hai.

Chhathi category bhi hai jo audit ki original 5 (`Supported` /
`Partial` / `Permission required` / `OS limitation` / `Not supported`)
mein nahi thi, lekin honest hone ke liye zaroori hai:

**`Unverified`** — code is session mein maujood hai (ya likha gaya),
lekin na koi automated test isay execute karta hai, na maine khud
directly line-by-line padh kar confirm kiya. Native Kotlin/C++ ke liye
yeh bohot common hai — is sandbox mein koi Android/Windows/Linux
build/emulator environment nahi tha, is liye compile karna hi mumkin
nahi tha.

## Roadmap item ke hisaab se — kahan kaam hua (Backend vs Native)

Yeh section upar ki capability-matrix se alag cheez batati hai: har
roadmap item (P0-01 se TEST-02 tak) **kis layer mein** implement hua —
Backend (`control_api`, pure Dart server), shared Dart/Flutter code
(`shared_app/lib` — ek hi jagah likha jaata hai, Android/Windows/Linux
teeno build mein automatically chalta hai), ya native platform-specific
code (`shared_app/android/*.kt`, `shared_app/windows/*.cpp`,
`shared_app/linux/*.cc` — teeno alag-alag, alag language mein).

| # | Roadmap item | Backend | Shared Dart (sab par lagu) | Android native | Windows native | Linux native |
|---|---|---|---|---|---|---|
| P0-01 | Task pause/resume/stop | ✅ | ✅ | — | — | — |
| P0-02 | Scope enforcement | ✅ | — | N/A | N/A | N/A |
| P0-03 | HTTPS/WSS | ✅ | ✅ | — | — | — |
| P0-04 | Request validation | ✅ | — | N/A | N/A | N/A |
| P0-05 | Rate limiting | ✅ | — | N/A | N/A | N/A |
| P0-06 | Secret hashing/log redaction | ✅ | — | N/A | N/A | N/A |
| P0-07 | Connector OAuth | ✅ | — | N/A | N/A | N/A |
| P1-01 | Capability registry | ✅ | — | N/A | N/A | N/A |
| P1-02 | AI tool registry | ✅ | ✅ (pairing se platform bhejna) | — | — | — |
| P1-03 | Live monitoring | ✅ | ✅ (dashboard preview) | ❌ nahi chhua | ❌ nahi chhua | 🟡 sirf yahan (Wayland wiring, untested) |
| P1-04 | Task progress events | — | ✅ | — | — | — |
| P1-05 | Device lock/sleep state | ✅ (pipe) | ✅ (pipe) | 🟡 Android native detection hai (KeyguardManager+PowerManager), unverified | 🟡 `OpenInputDesktop` poll, LOCKED/UNLOCKED only, unverified | 🟡 D-Bus ScreenSaver (freedesktop+GNOME), LOCKED/UNLOCKED only, unverified |
| P1-06 | Messaging/notifications | — | ✅ Android notifications + messaging adapters (supported apps, inline-reply) code-complete, **unverified** | 🧪 real device chahiye | N/A (unavailable) | N/A (unavailable) |
| P1-07 | Location/network errors | — | ✅ (error-passthrough fix) | ❌ nahi chhua (already thik tha) | ❌ nahi chhua | ❌ nahi chhua |
| P1-08 | File upload/download security | ✅ | — | ❌ nahi chhua | ❌ nahi chhua | ❌ nahi chhua |
| P1-09 | Audit history | ✅ | — | N/A | N/A | N/A |
| DEP-01 | Deployment durability | ✅ | — | N/A | N/A | N/A |
| TEST-01 | Automated test suite | ✅ (tests + CI) | ✅ (tests) | ❌ (native tests ban hi nahi sakte yahan) | ❌ | ❌ |
| TEST-02 | Capability matrix | 📄 documentation | 📄 documentation | 📄 documentation | 📄 documentation | 📄 documentation |

**Legend:** ✅ = is session mein likha/theek kiya · — = is layer mein
zaroorat hi nahi thi (item ka scope wahan aata hi nahi) · ❌ = zaroorat
thi lekin nahi kiya (native code, is sandbox mein likh kar test nahi
ho sakta tha) · 🟡 = chhua, lekin unverified · N/A = applicable nahi.

**Sabse zaroori nichod:** 19 mein se 19 items **backend/shared-Dart
layer mein poori tarah ban gaye** (jahan bhi unka scope tha). Native
Android (`.kt`) code is poori session mein **bilkul nahi chua** — na
naya likha, na purana verify kiya. Native Windows/Linux (`.cpp`/`.cc`)
mein sirf **ek jagah** (Linux Wayland screen-share wiring) chua gaya,
wo bhi compile/test nahi ho saka.

## Legend (neeche wali capability-by-capability table ke liye)
- Supported — verified: ya to automated test se, ya maine khud code padh kar (evidence note mein bataya gaya hai kaunsa)
- Partial — kaam karta hai, lekin koi jaani-pehchani limitation hai (evidence ke saath)
- Permission required — OS-level permission chahiye, code usay sahi se handle karta hai (structured denied-state)
- OS limitation — is platform par fundamentally possible nahi (OS architecture ki wajah se)
- Not supported — implement nahi hua
- Unverified — code maujood hai, execution/direct-review evidence nahi

| Capability | Android | Windows | Linux/ChromeOS |
|---|---|---|---|
| **Screen — snapshot** | Unverified (audit: "code present") | Unverified (audit: "code present") | Supported (X11 — maine `screen_capture_x11`/`screen_capture_manager.cc` khud padha) |
| **Screen — live stream** | Unverified | Unverified | Supported (X11, poll-based); Partial (Wayland — PipeWire code already tha, maine `screen_capture_manager.cc` mein isay is session mein wire kiya, lekin **compile/run karke verify nahi kar saka** — is liye poori tarah "Supported" nahi keh sakta) |
| **Input — tap/swipe** | Unverified | Unverified | Unverified (dispatcher `agent_connection.dart` mein hai, native Linux input-injection file khud nahi padhi) |
| **Input — type_text** | Unverified | Unverified | Unverified |
| **Files (list/read/write/delete)** | Unverified (native path-traversal protection audit ke mutabiq maujood) | Unverified | Unverified — **server-side defense-in-depth (P1-08) is session mein add hui aur test hui** (traversal/size/type checks, `data_channel_security_test.dart`), native-side khud unverified |
| **App launcher** | Unverified | Unverified | Unverified |
| **Browser automation** | Unverified | Unverified | Unverified |
| **Clipboard** | Unverified | Unverified | Unverified |
| **Data upload/download** | Unverified (native) | Unverified | Unverified — server-side hardening (P1-08) verified |
| **Contacts** | Permission required — READ_CONTACTS (`PERMISSION_DENIED`); unverified | Partial — WinRT Contacts, non-MSIX apps par unreliable (code comment); unverified | Partial — Evolution Data Server, `EDS_UNAVAILABLE` agar na ho; unverified |
| **Location** | Permission required — verified: maine `LocationNetworkHandler.kt` khud padha, `PERMISSION_DENIED`/`LOCATION_DISABLED` structured errors sahi se throw hote hain | Permission required — verified: `location_network_manager.cpp` padha, `LOCATION_UNAVAILABLE` error (Android jitna granular nahi — permission-denied aur service-unavailable ek hi code share karte hain) | Permission required — verified: `location_network_manager.cc` padha (GeoClue2), same `LOCATION_UNAVAILABLE` pattern |
| **Network metadata** | Supported — verified: `connected`/`ssid`/`connection_type` hi return hote hain, **Wi-Fi password kahin nahi hai** (khud check kiya) | Supported — same verification | Supported — same verification |
| **Background keepalive** | Supported — `background.keepalive` trivial hai, direct code review | Supported | Supported |
| **Device state reporting (locked/asleep/etc.)** | Unverified — KeyguardManager + PowerManager + screen broadcasts (`SCREEN_OFF` bhi) | Partial — `OpenInputDesktop` poll (2 s), sirf LOCKED/UNLOCKED, no sleep state | Partial — D-Bus ScreenSaver (freedesktop + GNOME), sirf LOCKED/UNLOCKED; desktop par service ho tabhi |
| **Notifications (read)** | Permission required — NotificationListener access; secret-visibility notifications skip; memory only; unverified | Not supported | Not supported |
| **Messaging (read/reply)** | Partial — 7 supported apps par notification inline-reply (get_event -> prepare_reply -> send_reply), baaki `UNSUPPORTED_TARGET`/`CAPABILITY_UNAVAILABLE`; `delivery: handed_to_app`; unverified | Not supported | Not supported |
| **Live monitoring UI (dashboard preview)** | Supported — is session mein `task_monitor_screen.dart` fix hui (pehle hardcoded placeholder thi, ab real base64 frame decode + render, `event_envelope_test.dart` se parsing verified) | Supported (same client code, platform-agnostic) | Supported (same) |
| **Connector OAuth (Google Drive)** | N/A (server-side feature, device-agnostic) | | |

## Kya karna baaki hai (honest, is matrix ka hi result)

1. **Sabse zaroori**: is poori codebase ko ek asal Android/Windows/Linux
   build environment mein compile + run karna — bohot saari
   `Unverified` cells "Supported" ban sakti hain (agar code sahi
   nikla) ya real bugs samne aa sakte hain jo yahan text-review se nahi
   pakde ja sakte.
2. ~~Native lock-state detection likhna~~ — teeno platform par likha ja chuka hai (Stage 8); ab real device par verify karna baki.
3. Android/Windows/Linux native input/browser/clipboard/files code ko
   line-by-line review karna (is session mein sirf jo files directly
   kaam se related thi wahi padhi gayi — screen capture, location/
   network — baaki sab audit ke "present hai" claim par bharosa kiya
   gaya, khud verify nahi kiya).
4. ~~Android `NotificationListenerService` likhna~~ — likha gaya (notifications + messaging adapters); ab real device par verify karna baki.
