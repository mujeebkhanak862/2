# Android headless agent (Item 85) — IMPLEMENTED (blind, unverified)

## Implemented design (Stage 8) — kya hua
Pehle ek *service-hosted second engine* chuna (Application-cached engine nahi), kyunki UI engine ka lifecycle bilkul nahi badalta — regression risk kam.

* **Ownership rule:** ek waqt mein sirf ek engine agent chalata hai. Activity band/swipe-away (agent mode ON) => `MainActivity.onDestroy` -> `AgentForegroundService.requestHeadless()` -> service `HeadlessAgent.start()`. Activity dobara khulti hai => `MainActivity.onCreate` -> `HeadlessAgent.stopNow()` (UI engine maalik).
* **Headless engine:** `HeadlessAgent.kt` ek alag `FlutterEngine` banata hai, saare capability handlers `ChannelRegistrar` se register karta hai (UI engine jaise hi), aur Dart entrypoint `agentMain` (`lib/protocol/headless_agent.dart`) chalata hai — AgentConnection + StatusReporter + lock-state stream, UI ke bina.
* **Handlers Activity se alag:** `HandlerHost : ContextWrapper` — pehle har handler `MainActivity` leta tha. Ab handlers `HandlerHost` lete hain; Activity-only cheezein (`runOnUiThread`, `startActivityForResult`, permission dialogs) safe: headless mein `NEEDS_UI` error (screen-capture consent, runtime permission dialogs, folder picker). Baaki (location/status, apps, notifications + messaging, accessibility input, files on already-granted tree) headless mein bhi chalte hain.
* **Process-kill:** agent mode flag SharedPreferences mein (`AgentRuntime`); service ka sticky restart (intent == null) headless engine shuru karta hai.
* **Cleanup:** `ChannelRegistrar.dispose()` (lock-state receiver, live stream) engine destroy se pehle.
* **Dart -> native:** channel `device_agent/headless` (`stopSelf`) — credentials nahi / server ne unpair kiya / `replaced` => headless engine khud band.
* **Notification (Stage 9 wording):** UI engine => "Agent is running (app open)"; headless => "running in background mode — open the app for screen capture or permission prompts"; koi engine nahi => "NOT running". Yeh sirf *engine/process* ka haal hai, **server connection ka nahi** (offline hone par bhi engine chalta rehta hai).

### Known risks / jo real device par dekhna hai
* Do engines ka handoff: UI engine ka connection aate hi server purana (headless) connection `replaced` se band karta hai — `REAL_DEVICE_TEST_MATRIX.md` row H1–H6.
* Android 12+ par background se foreground-service/engine start restrictions OEM-wise alag; Samsung/Xiaomi battery managers service maar sakte hain (battery exemption zaroori).
* `MediaProjection` token headless mein tabhi reuse hota hai jab service pehle se zinda ho; warna `NEEDS_UI`.

## Stage 9 corrections (blind, unverified)
* **Swipe-away start path badla:** pehle `MainActivity.onDestroy` -> `startForegroundService(ACTION_HEADLESS)` — Android 12+ par background se yeh `ForegroundServiceStartNotAllowedException` deta hai aur exception nigal li jati thi (headless kabhi shuru nahi hota). Ab `AgentForegroundService.requestHeadless()` seedha same-process `HeadlessAgent.start()` call karta hai (service pehle se foreground mein hai). `ACTION_HEADLESS` intent path sticky restart ke liye bacha hai.
* **Race guard:** headless start post hone ke beech user app dobara khol de to UI engine maalik rehta hai.
* **`stopSelf`** (credentials nahi / unpaired / replaced): ab agent mode persist `false` + service stop — warna START_STICKY baar-baar bekaar engine banata.
* **Reboot auto-start (follow-up):** `BootReceiver` (`BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`) agent mode ON hone par service ko `ACTION_HEADLESS` se start karta hai. Unverified: kuch OEMs boot-time start rokte hain ("autostart" permission). `HeadlessAgentRunner` ab connect fail par backoff ke saath retry karta hai.
* **Known limits (nahi badle):** partial wake lock service ke chalne tak; force-stop agent ko maarta hai; OEM battery managers (Xiaomi/Huawei/Samsung) ke liye "unrestricted battery"; `HeadlessAgentRunner.run()` mein `conn.connect()` bina try/catch — device par verify karein ke yeh kabhi throw nahi karta.
* Test: `REAL_DEVICE_TEST_MATRIX.md` mein Stage 9 rows.

## Step 0 (DONE, blind): truthful status
Foreground-service notification ab engine ki asli state batati hai
(`AgentForegroundService.engineAttached`): Activity close/swipe-away par
(`MainActivity.onDestroy`, rotation chhodkar) notification badal kar kehti hai
**"Agent is NOT running — tap to reopen and reconnect"**; process-kill ke baad
START_STICKY restart par bhi yahi sach dikhta hai. Pehle yeh hamesha
"connected and running" kehti thi, jo galat tha. Tap karne par app khulti hai
aur agent dobara connect hota hai. Yeh headless engine ka *substitute nahi* hai.

## Problem (original — ab upar wale design se solve)
Agent ka Dart code (`AgentConnection`, status reporter, command dispatcher)
`MainActivity` ke FlutterEngine mein chalta hai. `AgentForegroundService`
process ko zinda rakhti hai, lekin Activity destroy hone par (swipe-away,
memory pressure) engine bhi mar jaata hai => WebSocket/command loop band.

## Proposed architecture
1. **Application-owned cached FlutterEngine**: `AgentApplication.onCreate()`
   mein engine banao, `FlutterEngineCache` mein `"agent_engine"` naam se rakho;
   `MainActivity` `provideFlutterEngine()` se wahi engine use kare
   (`CachedEngineId`) => UI band ho to bhi engine zinda.
2. **Headless Dart entrypoint**: `@pragma('vm:entry-point') void agentMain()`
   — bina `runApp` ke connection + dispatcher chalaye (UI-free).
   `AgentForegroundService.onStartCommand` engine ko is entrypoint se start kare
   agar Activity nahi hai.
3. **Channel handlers engine-level par register**: abhi handlers
   `MainActivity.configureFlutterEngine` mein hain. Unhe
   `ChannelRegistrar.register(engine, context)` mein nikaalna hoga taaki
   Application/Service bhi register kar sake. Jo handlers Activity maangte hain
   (MediaProjection consent, SAF folder picker, runtime permission dialogs)
   unko "needs UI" error dena hoga jab Activity nahi hai (ya notification se
   user ko Activity kholne ko kehna).
4. **Single instance**: Activity attach hone par engine same rehta hai, isliye
   do connection nahi banenge. Dart side par `AgentRuntime` singleton chahiye
   jo `main()` aur `agentMain()` dono share karein.
5. **Boot/restart** `BootReceiver` implement hua (follow-up, unverified); service `START_STICKY` process-kill par kaam karta hai.

## Risks (isi liye blind nahi kiya)
* Engine ownership badalna poori app ka lifecycle badalta hai; compile/run
  ke bina regression ka risk high.
* Screen capture (MediaProjection) aur Accessibility Activity-bound flows ka
  behaviour device/OEM par alag hota hai.
* Android 14+ foreground-service-type restrictions.

## Pehle kya chahiye
Android Studio build + ek real device par `flutter run`; phir step 1 (cached
engine) alag se test karke aage badhna.
