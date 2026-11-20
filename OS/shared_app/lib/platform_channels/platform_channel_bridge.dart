/// Platform Channel Bridge (Section 6.5 & 6.7)
///
/// Yeh file **sirf ek baar banti hai** aur teeno native sides
/// (android_native/, windows_native/, linux_native/) isi mein declared
/// channel-names se sunte hain. Naya capability aane par bas yahan ek naya
/// channel-name add hota hai — is file ke baaki hissa ko chhedne ki zaroorat
/// nahi padti.
///
/// - MethodChannel  → one-shot request/response (e.g. "screenshot lo aur do")
/// - EventChannel   → continuous streaming data (e.g. live screen frames)
library;

import 'package:flutter/services.dart';

/// Sab channel names ek jagah, taaki Dart aur native (Kotlin/C++/C#) dono
/// side hardcoded strings mein typo se mismatch na karein.
abstract final class ChannelNames {
  // Screen capability (Android: MediaProjection, Windows: Graphics Capture
  // API, Linux: X11/Wayland via xdg-desktop-portal).
  static const screenCapture = 'device_agent/screen_capture';
  // Item 85 (headless): headless engine ka Dart -> native control channel
  // (sirf headless engine mein registered; UI engine mein nahi).
  static const headless = 'device_agent/headless';
  static const screenLiveStream = 'device_agent/screen_live_stream'; // EventChannel
  static const audioLiveStream = 'device_agent/audio_stream'; // EventChannel

  // Input capability (Android: AccessibilityService, Windows: SendInput,
  // Linux: XTest).
  static const input = 'device_agent/input';

  // Files capability (scoped storage / allowed-root file operations).
  static const files = 'device_agent/files';

  // Apps capability (Android Intents / process launch on desktop).
  static const appLauncher = 'device_agent/app_launcher';

  // Browser automation.
  static const browser = 'device_agent/browser';

  // Clipboard read/write.
  static const clipboard = 'device_agent/clipboard';

  // Device identity + pairing (QR pairing per Section 6.7).
  static const pairing = 'device_agent/pairing';

  // Item 84/85 (Android): notification listener + background agent service.
  static const notifications = 'device_agent/notifications';
  static const background = 'device_agent/background';

  // Location & Network status (Section 11).
  static const locationNetwork = 'device_agent/location_network';

  // Contacts capability — read-only, permission-gated (Section 3 scope
  // model, "Contacts" ek naya toggle banega Permission Wizard mein).
  static const contacts = 'device_agent/contacts';

  // Audit fix (P1-05, Section 13 #6) — real OS lock/sleep/screen-off
  // state (Android KeyguardManager+PowerManager, Windows
  // OpenInputDesktop-based secure-desktop check). MethodChannel = one-
  // shot query, EventChannel = push on every OS-reported change.
  static const lockState = 'device_agent/lock_state';
  static const lockStateEvents = 'device_agent/lock_state_events'; // EventChannel
}

/// Thin, capability-scoped wrapper over a MethodChannel. Har capability
/// handler class isi ko extend/compose karta hai — taaki har jagah error
/// handling alag se na likhni pade.
class NativeCapabilityChannel {
  final MethodChannel _channel;
  NativeCapabilityChannel(String name) : _channel = MethodChannel(name);

  Future<T?> invoke<T>(String method, [Map<String, dynamic>? args]) {
    return _channel.invokeMethod<T>(method, args);
  }
}

/// Screen capability — one-shot capture (MethodChannel) aur continuous
/// live-stream (EventChannel) dono expose karta hai.
class ScreenCaptureBridge {
  final _captureChannel = NativeCapabilityChannel(ChannelNames.screenCapture);
  final _liveStreamChannel =
      const EventChannel(ChannelNames.screenLiveStream);

  /// Android/Windows/Linux teeno mein mandatory OS-level consent dialog
  /// isi call se trigger hota hai — bypass nahi kiya ja sakta (Section 6.6
  /// item 2). UI (task_monitor) isse "Watch Live" dabane se pehle call
  /// kare taaki user ko pata rahe ke consent maanga ja raha hai.
  Future<bool> requestPermission() async {
    final granted =
        await _captureChannel.invoke<bool>('requestPermission');
    return granted ?? false;
  }

  /// Asli screen size (px) — website ke click ko device coordinates mein badalne
  /// ke liye. Native method na ho (Windows/Linux) to `null`.
  Future<({int width, int height})?> screenSize() async {
    try {
      final raw = await _captureChannel.invoke<Map<dynamic, dynamic>>('getScreenSize');
      final w = (raw?['width'] as num?)?.toInt();
      final h = (raw?['height'] as num?)?.toInt();
      if (w == null || h == null || w <= 0 || h <= 0) return null;
      return (width: w, height: h);
    } catch (_) {
      return null;
    }
  }

  /// `screen.capture` — current screenshot as base64, native side se.
  Future<String?> captureScreenshot() =>
      _captureChannel.invoke<String>('captureScreenshot');

  /// `screen.watch_live` shuru hone par native side is stream par continuous
  /// frames bhejna shuru karta hai; `screen.stop_live` par khud band ho jaata
  /// hai (Section 2.4 & 2.5).
  /// `fps` (1..30), `maxWidth` (px), `quality` (JPEG 20..95) sirf Android native
  /// capture par asar karte hain; Windows/Linux sirf Dart-side fps throttle se.
  Stream<dynamic> liveFrames({int fps = 20, int maxWidth = 1080, int quality = 70}) =>
      _liveStreamChannel.receiveBroadcastStream(
          {'fps': fps, 'max_width': maxWidth, 'quality': quality});

  /// Section 2.5 — explicit stop, taaki EventChannel cancel na ho tab bhi
  /// native foreground service/capture session turant ruk jaaye.
  Future<void> stopLiveStream() => _captureChannel.invoke('stopStream');

  // ---- System audio (Stage 9.2) — Android-only abhi (AudioPlaybackCapture) ----
  final _audioStreamChannel = const EventChannel(ChannelNames.audioLiveStream);

  /// Raw PCM chunks (16kHz, mono, 16-bit) — screen jaisi hi MediaProjection
  /// consent se. Windows/Linux par native method nahi, to yeh stream turant
  /// error deta hai (`agent_connection.dart` ise `CAPABILITY_UNAVAILABLE` banata hai).
  Stream<dynamic> audioFrames() => _audioStreamChannel.receiveBroadcastStream();
}

/// Input capability — tap / swipe / type actions.
class InputBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.input);

  // Item 65: native side `false` deta hai jab gesture cancel hui ya
  // focused field nahi mila. Pehle `Future<void>` result ignore karta tha,
  // isliye failure bhi "success" ban jata tha. Ab `false` => exception
  // (`null`/`true` => success; desktop natives `true` dete hain).
  Future<void> tap(double x, double y) async {
    final ok = await _channel.invoke<bool>('tap', {'x': x, 'y': y});
    if (ok == false) {
      throw PlatformException(
          code: 'GESTURE_FAILED', message: 'Tap complete nahi hua (cancel/blocked)');
    }
  }

  Future<void> swipe(double x1, double y1, double x2, double y2,
      {int durationMs = 200}) async {
    final ok = await _channel.invoke<bool>('swipe',
        {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'duration_ms': durationMs});
    if (ok == false) {
      throw PlatformException(
          code: 'GESTURE_FAILED', message: 'Swipe complete nahi hua (cancel/blocked)');
    }
  }

  /// Android: Back/Home/Recents/Notifications. Desktop par native method nahi.
  Future<void> pressKey(String key) async {
    final ok = await _channel.invoke<bool>('pressKey', {'key': key});
    if (ok == false) {
      throw PlatformException(code: 'KEY_FAILED', message: '"$key" key dabane mein fail');
    }
  }

  /// `append: true` => maujooda text ke baad jodo (Android). Default:
  /// replace (purana behaviour).
  Future<void> typeText(String text, {bool append = false}) async {
    final ok = await _channel.invoke<bool>('typeText', {'text': text, 'append': append});
    if (ok == false) {
      throw PlatformException(
          code: 'NO_FOCUSED_FIELD',
          message: 'Text type nahi hua — koi focused input field nahi mila');
    }
  }

  /// Android par yeh false aa sakta hai jab tak user ne
  /// Settings > Accessibility mein service enable na ki ho — Windows/Linux
  /// par hamesha true hota hai (koi separate toggle nahi).
  Future<bool> isEnabled() async {
    final enabled = await _channel.invoke<bool>('isEnabled');
    return enabled ?? false;
  }

  /// Android-only helper — Accessibility settings screen open karta hai
  /// taaki user manually enable kar sake. Doosre platforms par no-op.
  Future<void> openPlatformInputSettings() =>
      _channel.invoke('openAccessibilitySettings');
}

/// Files capability (Section 3.4 — Data Channel: upload/download/
/// screenshot/file-get). Har operation ek **sandboxed allowed-root** ke
/// andar hoti hai — path traversal (`..`) native side par reject hota
/// hai. Do modes:
///  - App-sandbox root (default, koi extra permission nahi chahiye)
///  - User-picked directory (Android: SAF tree; Windows/Linux: folder
///    picker) — `pickDirectory()` se, broader access ke liye.
class FilesBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.files);

  Future<List<Map<String, dynamic>>> listDirectory(String path) async {
    final result = await _channel.invoke<List<dynamic>>('listDirectory', {
      'path': path,
    });
    return (result ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Base64-encoded file content — `data.upload`/`data.download` (Section
  /// 3.4) isi ke upar layer karte hain.
  Future<String?> readFile(String path) =>
      _channel.invoke<String>('readFile', {'path': path});

  Future<bool> writeFile(String path, String base64Data) async {
    final ok = await _channel
        .invoke<bool>('writeFile', {'path': path, 'data': base64Data});
    return ok ?? false;
  }

  Future<bool> deleteFile(String path) async {
    final ok = await _channel.invoke<bool>('deleteFile', {'path': path});
    return ok ?? false;
  }

  Future<String?> getAllowedRoot() =>
      _channel.invoke<String>('getAllowedRoot');

  /// User ko ek folder/SAF-tree pick karne deta hai taaki allowed-root
  /// se bahar bhi (uske chune hue folder tak) access mil sake. Sab
  /// platforms par supported — Android SAF, Windows/Linux native folder
  /// dialog.
  Future<String?> pickDirectory() =>
      _channel.invoke<String>('pickDirectory');
}

/// App Launcher capability — kisi installed app ko open/launch karna,
/// ya installed apps ki list dikhana ("open Spotify" jaisi AI-driven
/// automation ke liye).
class AppLauncherBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.appLauncher);

  /// `identifier`: Android par package name, Windows par exe/shortcut
  /// path, Linux par `.desktop` file id ya executable path.
  Future<bool> launchApp(String identifier) async {
    final ok = await _channel.invoke<bool>('launchApp', {'identifier': identifier});
    return ok ?? false;
  }

  Future<bool> isAppInstalled(String identifier) async {
    final ok = await _channel.invoke<bool>('isAppInstalled', {'identifier': identifier});
    return ok ?? false;
  }

  /// Har entry: `{identifier, name}` — AI agent isi list se user ke
  /// "open X" jaise casual naam ko sahi identifier se match kar sakta hai.
  Future<List<Map<String, dynamic>>> listInstalledApps() async {
    final result = await _channel.invoke<List<dynamic>>('listInstalledApps');
    return (result ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}

/// Clipboard capability. **Android-specific note:** Android 10+ background
/// apps ko clipboard read karne se rokta hai jab tak app khud focused na ho
/// — `readText()` us case mein `null` de sakta hai, yeh koi bug nahi,
/// Android ka apna privacy control hai (Section 6.6 jaisi hi philosophy).
class ClipboardBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.clipboard);

  Future<String?> readText() => _channel.invoke<String>('readText');

  Future<bool> writeText(String text) async {
    final ok = await _channel.invoke<bool>('writeText', {'text': text});
    return ok ?? false;
  }
}

/// Browser capability. **Windows/Linux**: sirf launcher hai — asal control
/// `browser/cdp_client.dart` (Chrome DevTools Protocol, WebSocket) karta
/// hai, is se poora navigate/click/type/read/JS-eval milta hai.
/// **Android**: koi CDP nahi (root/adb ke bina possible nahi) — is bridge
/// ke semantic-tree methods seedhe use hote hain, jo **asli** khule hue
/// browser (uski real login sessions ke saath) ko Accessibility API ke
/// zariye control karte hain, coordinates guess kiye bina.
class BrowserBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.browser);

  /// Windows/Linux — Chrome/Edge/Chromium ko debug-port ke saath launch
  /// karta hai. Success par [CdpClient.connect] use karo control ke liye.
  Future<bool> launchDesktopBrowser() async {
    final ok = await _channel.invoke<bool>('launchDesktopBrowser');
    return ok ?? false;
  }

  /// Fixed debug port jo native launcher use karta hai — CDP client isi
  /// port par `http://localhost:<port>/json/version` se WebSocket URL
  /// nikaalta hai.
  static const int desktopDebugPort = 9333;

  /// Android — kisi bhi default/system browser mein URL kholta hai
  /// (`Intent.ACTION_VIEW`). Windows/Linux par yeh `launchDesktopBrowser`
  /// ke jaisa hi hai lekin seedha ek URL ke saath.
  Future<bool> openUrl(String url) async {
    final ok = await _channel.invoke<bool>('openUrl', {'url': url});
    return ok ?? false;
  }

  /// Android-only — currently-visible browser window mein us text/label
  /// wala clickable element dhoond kar click karta hai (Accessibility
  /// tree se, coordinates nahi).
  Future<bool> findAndClick(String text) async {
    final ok = await _channel.invoke<bool>('findAndClick', {'text': text});
    return ok ?? false;
  }

  /// Android-only — us label/hint wale input field mein text set karta hai.
  Future<bool> findAndType(String fieldLabel, String text) async {
    final ok = await _channel
        .invoke<bool>('findAndType', {'fieldLabel': fieldLabel, 'text': text});
    return ok ?? false;
  }

  /// Android-only — poore visible page ka text (accessibility tree se
  /// walk karke) — AI agent isse page samajh sakta hai.
  Future<String?> getVisibleText() => _channel.invoke<String>('getVisibleText');
}

/// Location & Network bridge (Section 11) — dono read-only, non-secret
/// metadata; Wi-Fi password jaisi credentials iske through kabhi nahi aatin
/// (Section 11.3 — credential boundary yahin native side par bhi enforce
/// honi chahiye, Dart layer sirf yeh contract expose karta hai).
class LocationNetworkBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.locationNetwork);

  /// Item 28: OS location permission maango (Android runtime dialog;
  /// desktop par provider access check).
  Future<bool> requestPermission() async {
    final granted = await _channel.invoke<bool>('requestPermission');
    return granted ?? false;
  }

  /// Item 32: battery percent (0-100) ya `null` (desktop par battery
  /// na ho / native side implement na ho).
  Future<int?> getBatteryPercent() async {
    try {
      final v = await _channel.invoke<int>('getBattery');
      return (v != null && v >= 0 && v <= 100) ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLocation() async {
    final result = await _channel.invoke<Map<dynamic, dynamic>>('getLocation');
    return result?.cast<String, dynamic>();
  }

  Future<Map<String, dynamic>?> getNetworkStatus() async {
    final result =
        await _channel.invoke<Map<dynamic, dynamic>>('getNetworkStatus');
    return result?.cast<String, dynamic>();
  }
}

/// One contact entry — read-only.
class ContactEntry {
  final String id;
  final String name;
  final List<String> phoneNumbers;
  final List<String> emails;

  const ContactEntry({
    required this.id,
    required this.name,
    this.phoneNumbers = const [],
    this.emails = const [],
  });

  factory ContactEntry.fromMap(Map<String, dynamic> m) => ContactEntry(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        phoneNumbers: (m['phoneNumbers'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        emails: (m['emails'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// Contacts capability — **read-only**, koi write/delete operation
/// support nahi karta (permission-scope minimal rakhne ke liye — Section
/// 3.5 ki "high-risk combination" spirit).
///
/// Platform notes (honest caveats):
/// - **Android**: poori tarah supported — `ContactsContract` se full
///   list milti hai, runtime permission ke baad.
/// - **Windows**: sirf `Windows.ApplicationModel.Contacts` (WinRT
///   `ContactStore`) ke zariye jo contacts store mein hain — yeh
///   typically Windows "People" app / Outlook-linked accounts se aate
///   hain. Agar user ne kabhi Windows mein koi account connect nahi
///   kiya, list khaali aa sakti hai — yeh bug nahi hai.
/// - **Linux**: sirf tab kaam karta hai jab **Evolution Data Server**
///   (EDS) chal raha ho aur configured ho — GNOME/Evolution/Thunderbird
///   ecosystem mein common hai, lekin universal nahi (KDE, minimal
///   window-manager setups, ya server distros par EDS na ho to
///   `isAvailable()` false dega).
class ContactsBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.contacts);

  Future<bool> isAvailable() async {
    final ok = await _channel.invoke<bool>('isAvailable');
    return ok ?? false;
  }

  Future<bool> requestPermission() async {
    final ok = await _channel.invoke<bool>('requestPermission');
    return ok ?? false;
  }

  Future<List<ContactEntry>> listContacts() async {
    final result = await _channel.invoke<List<dynamic>>('listContacts');
    return (result ?? const [])
        .map((e) => ContactEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}

/// Audit fix (P1-05 / Section 13 #6) — real, native-reported lock/sleep/
/// screen-off state. Pehle server ko sirf ek connect-time optimistic
/// guess (`ONLINE_UNLOCKED`) milta tha, kyunki koi native bridge nahi
/// tha (dekhein `protocol/agent_connection.dart`'s `reportStatus()` —
/// woh method already tha, bas kabhi call nahi hota tha). Yeh bridge
/// usi pipe ko asal data se bharta hai:
///   - `currentState()` — one-shot query (app start hote hi ek baar).
///   - `stateChanges` — OS se turant push hota hai jab bhi lock/screen
///     state badle (native side ek broadcast receiver / session
///     notification listener rakhta hai — polling nahi).
/// Value hamesha in 6 (server ke fixed vocabulary) mein se ek hoti hai:
/// `ONLINE_UNLOCKED`, `ONLINE_LOCKED`, `SCREEN_OFF`, `SLEEPING`,
/// `OFFLINE`, `POWERED_OFF`. Dono platforms (Android/Windows) sirf
/// pehle 3 hi khud report kar sakte hain (`OFFLINE`/`POWERED_OFF` server
/// khud connection status se decide karta hai; `SLEEPING` desktop
/// OS-suspend ke liye reserved hai — abhi native side se distinctly
/// detect nahi hota, `SCREEN_OFF` se cover ho jaata hai).
class LockStateBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.lockState);
  final _eventsChannel = const EventChannel(ChannelNames.lockStateEvents);

  Future<String?> currentState() => _channel.invoke<String>('currentState');

  Stream<String> stateChanges() =>
      _eventsChannel.receiveBroadcastStream().map((e) => e as String);
}

/// Item 84: Android notification access (read-only recent notifications).
class NotificationsBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.notifications);

  Future<bool> isEnabled() async => (await _channel.invoke<bool>('isEnabled')) ?? false;

  Future<void> openSettings() => _channel.invoke('openSettings');

  Future<List<Map<String, dynamic>>> getRecent({int limit = 20, int sinceMs = 0}) async {
    final raw = await _channel.invoke<List<dynamic>>(
        'getRecent', {'limit': limit, 'since_ms': sinceMs});
    return (raw ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // ---- Per-app notification filter (local-only; remote API se nahi) ------
  Future<List<String>> getBlockedPackages() async {
    final raw = await _channel.invoke<List<dynamic>>('getBlockedPackages');
    return (raw ?? const []).map((e) => e.toString()).toList();
  }

  Future<void> setBlockedPackages(List<String> packages) =>
      _channel.invoke('setBlockedPackages', {'packages': packages});

  // ---- P1-06 messaging adapters (notification inline-reply) -------------

  Future<List<Map<String, dynamic>>> getMessagingEvents(
      {int limit = 20, int sinceMs = 0, String? package}) async {
    final raw = await _channel.invoke<List<dynamic>>('getMessagingEvents', {
      'limit': limit,
      'since_ms': sinceMs,
      if (package != null) 'package': package,
    });
    return (raw ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> prepareReply(String eventId, String text) async {
    final raw = await _channel.invoke<Map<dynamic, dynamic>>(
        'prepareReply', {'event_id': eventId, 'text': text});
    return Map<String, dynamic>.from(raw ?? const {});
  }

  Future<Map<String, dynamic>> sendReply(String draftId) async {
    final raw = await _channel
        .invoke<Map<dynamic, dynamic>>('sendReply', {'draft_id': draftId});
    return Map<String, dynamic>.from(raw ?? const {});
  }
}

/// Item 85: Android foreground service (agent ko background mein zinda
/// rakhna) + battery-optimization exemption.
class BackgroundBridge {
  final _channel = NativeCapabilityChannel(ChannelNames.background);

  Future<bool> startService() async => (await _channel.invoke<bool>('startService')) ?? false;
  Future<void> stopService() => _channel.invoke('stopService');
  Future<bool> isRunning() async => (await _channel.invoke<bool>('isRunning')) ?? false;
  Future<bool> isIgnoringBatteryOptimizations() async =>
      (await _channel.invoke<bool>('isIgnoringBatteryOptimizations')) ?? false;
  Future<void> requestIgnoreBatteryOptimizations() =>
      _channel.invoke('requestIgnoreBatteryOptimizations');
}
