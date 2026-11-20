/// Core Protocol — Scoped API Key model
///
/// Har key apni khud ki capability-scope ke saath banti hai (Architecture
/// v4, Section 3). Dashboard ka Key Manager isi model par list/create/
/// revoke UI banata hai.
library;

/// Permission Wizard ke toggles (Section 3.2 — originally 8, phir
/// "Contacts", phir "Location"+"Background" add hue — audit P0-02 ne
/// mana kiya ke `location.refresh`/`background.keepalive` jaisi actions
/// ka koi dedicated scope-owner nahi tha, isliye yeh do naye toggles
/// add kiye gaye). Server-side `control_api/lib/models/api_key.dart`
/// se **exactly** match karta hai.
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

  /// `messaging.send_reply` ke liye alag toggle — `background` se
  /// jaan-bujh kar separate (server ke `api_key.dart` mein poori wajah
  /// likhi hai: audit ka SCOPE-02 test read vs reply ko alag scope
  /// maangta hai).
  final bool messagingReply;

  /// Audit fix (P1-02) — server ke `models/api_key.dart` se match
  /// karta hai. Custom (P1-01) capabilities ke naam, jo yeh key use kar
  /// sakti hai.
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

  /// Section 3.5 — high-risk combination check, taaki dashboard ek extra
  /// "Are you sure?" confirmation dikha sake before creating the key.
  bool get isHighRisk => touchInput && files && dataTransfer;

  /// Item 29: device-local policy check. Server ke `allowsCapability`
  /// jaisa mapping; `control` hamesha allowed (kisi bhi chalti
  /// automation ko rokna hamesha ho sakna chahiye). Custom capabilities
  /// sirf tab jab explicitly policy mein hon.
  bool allowsCapability(String capability) {
    switch (capability) {
      case 'control':
        return true;
      case 'screen':
        return screenView;
      case 'input':
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
      case 'notifications':
      case 'messaging':
        return background || messagingReply;
      default:
        return customCapabilities.contains(capability);
    }
  }

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
}

class ApiKey {
  final String keyId;
  final String label; // e.g. "Backup Uploader", "Full Automation Agent"
  final ApiKeyScope scope;
  final DateTime createdAt;
  final bool enabled;

  /// Item 89: server `last_used_at` / `expires_at` pehle se bhejta hai.
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;

  /// Sirf key creation response mein aata hai (ek hi baar dikhta hai) —
  /// baad mein list se dobara kabhi wapas nahi milta.
  final String? secret;

  const ApiKey({
    required this.keyId,
    required this.label,
    required this.scope,
    required this.createdAt,
    this.enabled = true,
    this.lastUsedAt,
    this.expiresAt,
    this.secret,
  });

  factory ApiKey.fromJson(Map<String, dynamic> json) => ApiKey(
        keyId: json['key_id'] as String,
        label: json['label'] as String? ?? '',
        scope: ApiKeyScope.fromJson(
            (json['scope'] as Map<String, dynamic>?) ?? const {}),
        createdAt: DateTime.parse(json['created_at'] as String),
        enabled: json['enabled'] as bool? ?? true,
        lastUsedAt: json['last_used_at'] != null
            ? DateTime.tryParse(json['last_used_at'] as String)
            : null,
        expiresAt: json['expires_at'] != null
            ? DateTime.tryParse(json['expires_at'] as String)
            : null,
        secret: json['secret'] as String?,
      );

  bool get isExpired =>
      expiresAt != null && !DateTime.now().toUtc().isBefore(expiresAt!);
}

/// Item 89 (audit: "clearer risk levels, per-scope descriptions").
enum RiskLevel { none, low, medium, high }

extension RiskLevelLabel on RiskLevel {
  String get label => switch (this) {
        RiskLevel.none => 'No access',
        RiskLevel.low => 'Low risk',
        RiskLevel.medium => 'Medium risk',
        RiskLevel.high => 'High risk',
      };
}

/// Ek scope toggle ka insaan-padhne-layak vivaran + risk weight.
class ScopeInfo {
  final String name;
  final String description;
  final int weight; // 1 (kam) .. 3 (zyada)
  const ScopeInfo(this.name, this.description, this.weight);
}

extension ApiKeyScopeRisk on ApiKeyScope {
  /// Sirf enabled scopes (naam + vivaran), risk-weight ke saath.
  List<ScopeInfo> get enabledScopes => [
        if (screenView)
          const ScopeInfo('Screen', 'Device ki screen live/snapshot dekh sakti hai', 1),
        if (touchInput)
          const ScopeInfo('Touch input', 'Tap/swipe/scroll karke device chala sakti hai', 3),
        if (keyboardText)
          const ScopeInfo('Keyboard', 'Device par text type kar sakti hai (passwords bhi type ho sakte hain)', 3),
        if (files)
          const ScopeInfo('Files', 'Picked folder ki files list/read/write/delete kar sakti hai', 2),
        if (apps)
          const ScopeInfo('Apps', 'Installed apps list kar sakti hai aur launch kar sakti hai', 2),
        if (browser)
          const ScopeInfo('Browser', 'Browser kholkar pages navigate/control kar sakti hai', 2),
        if (clipboard)
          const ScopeInfo('Clipboard', 'Clipboard padh/likh sakti hai (copy kiye passwords dikh sakte hain)', 2),
        if (dataTransfer)
          const ScopeInfo('Data transfer', 'Files cloud connectors (Drive/Dropbox) se laa sakti hai', 2),
        if (contacts)
          const ScopeInfo('Contacts', 'Contacts search/read kar sakti hai', 2),
        if (location)
          const ScopeInfo('Location', 'Device ki location dekh/refresh kar sakti hai', 1),
        if (background)
          const ScopeInfo('Background', 'Locked/screen-off state mein keepalive aur notifications', 1),
        if (messagingReply)
          const ScopeInfo('Messaging reply', 'Aapki taraf se messages ka jawab bhej sakti hai', 3),
        for (final c in customCapabilities)
          ScopeInfo('Custom: $c', 'Custom capability "$c" chala sakti hai', 1),
      ];

  RiskLevel get riskLevel {
    final scopes = enabledScopes;
    if (scopes.isEmpty) return RiskLevel.none;
    if (isHighRisk) return RiskLevel.high;
    final score = scopes.fold<int>(0, (a, s) => a + s.weight);
    if (score >= 7) return RiskLevel.high;
    if (score >= 3) return RiskLevel.medium;
    return RiskLevel.low;
  }
}
