import 'dart:math';

import '../util/crypto_utils.dart';

/// Section 3 — Scoped API Key. `scope` ke fields Dart client ke
/// `ApiKeyScope` (shared_app/lib/protocol/api_key.dart) se **exactly**
/// match karte hain — koi bhi naya toggle dono jagah ek saath add hona
/// chahiye.
///
/// **Audit fix (P0-02, Order #2):** pehle `allows(capability)` sirf
/// broad capability-level check karta tha, aur `control`/`location`/
/// `background` ke liye ek vague "koi bhi ek scope granted ho to chalega"
/// fallback tha — audit ne explicitly mana kiya hai ("Do not authorize
/// only by broad capability"). Ab:
///  1. Do naye toggles add kiye — `location` aur `background` — taaki
///     un actions ka bhi ek real, dedicated owner ho (pehle inka koi
///     scope field hi nahi tha).
///  2. `allowsAction(action)` — har **action** (capability nahi) ko
///     explicit map karta hai. Koi unknown/unmapped action **fail-closed**
///     deny hota hai (default `false`), allow nahi.
class ApiKeyScope {
  final bool screenView;
  final bool touchInput;
  final bool keyboardText;
  final bool files;
  final bool apps;
  final bool browser;
  final bool clipboard;
  final bool dataTransfer;
  final bool contacts;
  final bool location;
  final bool background;

  /// `messaging.send_reply` ke liye **alag, dedicated** toggle —
  /// `background` se jaan-bujh kar separate rakha hai kyunki audit ka
  /// SCOPE-02 acceptance test specifically yeh maangta hai: "Key has
  /// messaging.read but not messaging.reply -> Read may work; reply
  /// rejected." Ek hi toggle se yeh distinction possible nahi thi — reply
  /// bhejna (kisi ki taraf se message compose karke send karna) generically
  /// read/keepalive se zyada high-risk hai, isliye alag gate hona chahiye.
  final bool messagingReply;

  /// Audit fix (P1-02, Section 13): pehle custom (P1-01 se registered)
  /// capabilities ke liye **koi** per-key policy gating nahi thi — na
  /// AI tool registry mein, na (zyada important) asal `POST /commands`
  /// dispatch endpoint par. Matlab: `allowsAction()` custom actions ke
  /// liye hamesha `false` deta (fail-closed default, kyunki woh built-in
  /// switch mein hi nahi hain), is liye ek custom capability register
  /// karne ke baad uske actions **kisi bhi API key se kabhi call hi
  /// nahi ho sakte the** — feature khud hi apne aap ko bekaar kar deta
  /// tha. Ab: caller registration ke waqt explicitly bata sakta hai ke
  /// yeh key konsi custom capabilities use kar sakti hai (capability
  /// *name* se — manifest ke `capability` field se match hota hai).
  /// Default empty — naya toggle bhi fail-closed hi rehta hai jab tak
  /// explicitly na diya jaaye.
  final Set<String> customCapabilities;

  const ApiKeyScope({
    this.screenView = false,
    this.touchInput = false,
    this.keyboardText = false,
    this.files = false,
    this.apps = false,
    this.browser = false,
    this.clipboard = false,
    this.dataTransfer = false,
    this.contacts = false,
    this.location = false,
    this.background = false,
    this.messagingReply = false,
    this.customCapabilities = const {},
  });

  factory ApiKeyScope.fromJson(Map<String, dynamic> json) => ApiKeyScope(
        screenView: json['screen_view'] as bool? ?? false,
        touchInput: json['touch_input'] as bool? ?? false,
        keyboardText: json['keyboard_text'] as bool? ?? false,
        files: json['files'] as bool? ?? false,
        apps: json['apps'] as bool? ?? false,
        browser: json['browser'] as bool? ?? false,
        clipboard: json['clipboard'] as bool? ?? false,
        dataTransfer: json['data_transfer'] as bool? ?? false,
        contacts: json['contacts'] as bool? ?? false,
        location: json['location'] as bool? ?? false,
        background: json['background'] as bool? ?? false,
        messagingReply: json['messaging_reply'] as bool? ?? false,
        customCapabilities:
            (json['custom_capabilities'] as List<dynamic>?)?.map((e) => e as String).toSet() ??
                const {},
      );

  Map<String, dynamic> toJson() => {
        'screen_view': screenView,
        'touch_input': touchInput,
        'keyboard_text': keyboardText,
        'files': files,
        'apps': apps,
        'browser': browser,
        'clipboard': clipboard,
        'data_transfer': dataTransfer,
        'contacts': contacts,
        'location': location,
        'background': background,
        'messaging_reply': messagingReply,
        'custom_capabilities': customCapabilities.toList(),
      };

  /// Section 3.5 — high-risk combination. Server bhi isko check karta hai
  /// (Dart dashboard ke client-side check ke ilawa — client-side checks
  /// kabhi bhi bypass ho sakte hain, isliye authoritative check yahan
  /// honi chahiye).
  /// Item 18: malformed/galat-type scope JSON par `TypeError` (HTTP 500)
  /// ke bajaye `null` return karta hai — caller 400 de sakta hai.
  static ApiKeyScope? tryParse(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    try {
      return ApiKeyScope.fromJson(raw);
    } on TypeError {
      return null;
    }
  }

  bool get isHighRisk => touchInput && files && dataTransfer;

  /// **P0-02 — task/session capability-bound authorization.** `control.*`
  /// actions (pause/resume/stop/switch) khud kisi capability ke "owner"
  /// nahi hain — woh jis task/session par operate kar rahe hain, us task
  /// ko originally kis capability ki command ne shuru kiya tha, wahi
  /// asal authorization boundary hai. Yeh method wahi check karta hai:
  /// "is scope ke paas is capability ka access hai?" — `routes/
  /// commands.dart` isko `TaskRecord.originatingCapability` ke against
  /// call karta hai, `allowsAction(action)` ki jagah (jo control.* ke
  /// liye ab fail-closed hai, neeche dekhein).
  bool allowsCapability(String capability) {
    switch (capability) {
      case 'screen':
      case 'audio': // audio capture usi MediaProjection consent se chalti hai jaisi screen
        return screenView;
      case 'input':
        // Task ki capability sirf "input" hoti hai, tap/swipe aur
        // type_text mein farq nahi karti (woh farq action-level par
        // `allowsAction` mein hai) — is liye yahan dono mein se koi bhi
        // ek granted ho to kaafi hai control.* ke liye.
        return touchInput || keyboardText;
      case 'files':
        return files;
      case 'app_launcher':
        return apps;
      case 'browser':
        return browser;
      case 'clipboard':
        return clipboard;
      case 'data':
        return dataTransfer;
      case 'contacts':
        return contacts;
      case 'location':
        return location;
      case 'background':
        return background || messagingReply;
      default:
        return false; // fail-closed — unknown capability
    }
  }

  /// **Action-level Policy Engine** — `POST /commands` ka core check.
  /// Har known action ka ek explicit, dedicated scope-field hai. Koi bhi
  /// action jo is map mein nahi hai, **automatically deny** hoti hai
  /// (fail-closed) — naya action add karte waqt yahan bhi entry
  /// zaroori hai, warna woh silently block ho jaayega (jo galat action
  /// allow hone se zyada safe hai).
  bool allowsAction(String action) {
    switch (action) {
      // ---- screen ---------------------------------------------------
      case 'screen.capture':
      case 'screen.watch_live':
      case 'screen.stop_live':
      case 'audio.watch_live':
      case 'audio.stop_live':
        return screenView;

      // ---- input — tap/swipe alag scope se, type_text alag ------------
      // (keyboardText se sirf typing allowed ho sakti hai bina
      // touch-control diye, aur vice versa — pehle dono ek hi
      // "touchInput || keyboardText" OR mein the, jo bahut loose tha.)
      case 'input.tap':
      case 'input.swipe':
      case 'input.key':
        return touchInput;
      case 'input.type_text':
        return keyboardText;

      // ---- files ------------------------------------------------------
      case 'files.list':
      case 'files.read':
      case 'files.write':
      case 'files.delete':
        return files;

      // ---- app_launcher -------------------------------------------------
      case 'app_launcher.launch':
      case 'app_launcher.list':
        return apps;

      // ---- browser ------------------------------------------------------
      case 'browser.navigate':
      case 'browser.click':
      case 'browser.type_text':
      case 'browser.read':
        return browser;

      // ---- clipboard ----------------------------------------------------
      case 'clipboard.read':
      case 'clipboard.write':
        return clipboard;

      // ---- data (upload/download) ---------------------------------------
      case 'data.upload':
      case 'data.download':
        return dataTransfer;

      // ---- contacts -----------------------------------------------------
      case 'contacts.list':
        return contacts;

      // ---- location (naya toggle) ----------------------------------------
      case 'location.refresh':
        return location;

      // ---- background (naya toggle) — read/keepalive lower-risk --------
      case 'background.keepalive':
      case 'notifications.read_event':
      case 'messaging.get_event':
      case 'messaging.prepare_reply':
        return background;

      // ---- messaging reply — alag, higher-risk toggle (SCOPE-02 fix) ----
      case 'messaging.send_reply':
        return messagingReply;

      // ---- control (Universal Switch API + task control) ------------------
      // **P0-02 fix**: pehle yahan interim policy thi — "kam-se-kam EK
      // capability granted honi chahiye" (koi bhi ek, unrelated bhi) —
      // audit ne explicitly disallow kiya ("Do not authorize only by
      // broad capability"). Ab `control.*` ke liye yeh function hamesha
      // `false` deta hai — asal authorization route-level par hoti hai
      // (`routes/commands.dart`), jahan `TaskRecord.originatingCapability`
      // pata hota hai aur `allowsCapability(capability)` se real,
      // task-bound check lagta hai. Yeh method (generic action-name-only
      // check) us context tak access nahi rakhta, is liye fail-closed —
      // route handler explicitly control.* ko is check se bypass karke
      // apna dedicated capability-bound check karta hai.
      case 'control.switch':
      case 'control.pause':
      case 'control.resume':
      case 'control.stop':
      case 'control.complete':
      case 'control.fail':
        return false;

      default:
        // Fail-closed — naya/unknown action bhi automatically deny.
        // (Custom-capability actions bhi yahan aate hain — unke liye
        // `allowsCustomCapability()` use hota hai, is method se nahi;
        // dekhein `routes/commands.dart` aur `ai_tools/
        // ai_tool_registry.dart`.)
        return false;
    }
  }

  /// Audit fix (P1-02) — custom (P1-01) capabilities ke liye policy
  /// gate. `allowsAction()` custom actions ke liye jaan-bujh kar hamesha
  /// `false` deta hai (woh sirf built-in, fixed action set jaanta hai) —
  /// custom capabilities ka authorization *capability naam* ki granularity
  /// par hota hai (action-level nahi, kyunki custom manifests ke actions
  /// dynamically registered hote hain, koi fixed compile-time list nahi).
  bool allowsCustomCapability(String capability) =>
      customCapabilities.contains(capability);
}

class ApiKeyRecord {
  final String keyId;
  final String deviceId;
  final String label;
  final ApiKeyScope scope;
  final DateTime createdAt;
  bool enabled;
  final String secretHash; // sirf hash store hota hai, plaintext kabhi nahi

  /// Item 21: optional expiry — `null` matlab kabhi expire nahi.
  final DateTime? expiresAt;

  /// Item 21: last successful authenticated use (in-memory update,
  /// periodic save se persist hota hai).
  DateTime? lastUsedAt;

  bool get isExpired =>
      expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!.toUtc());

  ApiKeyRecord({
    required this.keyId,
    required this.deviceId,
    required this.label,
    required this.scope,
    required this.createdAt,
    required this.secretHash,
    this.enabled = true,
    this.expiresAt,
    this.lastUsedAt,
  });

  Map<String, dynamic> toJson({String? plaintextSecretOnce}) => {
        'key_id': keyId,
        'label': label,
        'scope': scope.toJson(),
        'created_at': createdAt.toIso8601String(),
        'enabled': enabled,
        if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
        if (lastUsedAt != null) 'last_used_at': lastUsedAt!.toUtc().toIso8601String(),
        if (plaintextSecretOnce != null) 'secret': plaintextSecretOnce,
      };

  static String generateSecret() {
    final rand = Random.secure();
    return 'sk_${List.generate(40, (_) => rand.nextInt(36).toRadixString(36)).join()}';
  }

  static String hashSecret(String secret) => hashSecretUtil(secret);
}
