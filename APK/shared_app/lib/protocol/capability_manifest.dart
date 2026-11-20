/// Core Protocol — Capability Manifest
///
/// `GET /capabilities` se yeh manifests aati hain. Dashboard ka Permission
/// Wizard aur AI Tool Registry dono inhi manifests se apna UI/tools
/// dynamically generate karte hain — koi bhi capability hardcode nahi hoti
/// (Architecture v4, Section 1.2 & 1.3).
library;

enum RiskLevel { low, medium, high }

RiskLevel _riskFromString(String value) => switch (value) {
      'low' => RiskLevel.low,
      'medium' => RiskLevel.medium,
      'high' => RiskLevel.high,
      _ => RiskLevel.medium, // unknown -> fail safe towards "ask"
    };

class CapabilityAction {
  final String name; // e.g. "calendar.create_event"
  final Map<String, dynamic> paramsSchema;
  final RiskLevel riskLevel;

  const CapabilityAction({
    required this.name,
    required this.paramsSchema,
    required this.riskLevel,
  });

  factory CapabilityAction.fromJson(Map<String, dynamic> json) {
    return CapabilityAction(
      name: json['name'] as String,
      paramsSchema:
          (json['params_schema'] as Map<String, dynamic>?) ?? const {},
      riskLevel: _riskFromString(json['risk_level'] as String? ?? 'medium'),
    );
  }
}

/// Ek poori capability plugin ka manifest — jaise "screen", "input", ya
/// koi future/external connector (calendar, email, custom API).
class CapabilityManifest {
  final String capability; // e.g. "calendar"
  final String version; // e.g. "1.0.0"
  final List<CapabilityAction> actions;
  final String requiredPermission; // e.g. "calendar.access"

  /// "ask" (default) | "always_allow" | "always_deny" — Policy Engine ka
  /// starting point us capability ke liye, Permission Wizard mein.
  final String defaultPolicy;

  /// Follow-up fix (P1-02 se related) — `GET /capabilities` ab built-in
  /// aur custom (P1-01) manifests ko is marker se distinguish karta hai.
  /// Permission Wizard isi se decide karta hai ke kaunse capabilities
  /// "Custom Capabilities" section mein (per-key explicit grant ke
  /// saath) dikhani hain — built-in capabilities ke apne fixed toggles
  /// already hain, unhe yahan dobara nahi dikhate.
  final bool isCustom;

  const CapabilityManifest({
    required this.capability,
    required this.version,
    required this.actions,
    required this.requiredPermission,
    required this.defaultPolicy,
    this.isCustom = false,
  });

  factory CapabilityManifest.fromJson(Map<String, dynamic> json) {
    return CapabilityManifest(
      capability: json['capability'] as String,
      version: json['version'] as String,
      actions: (json['actions'] as List<dynamic>? ?? const [])
          .map((a) => CapabilityAction.fromJson(a as Map<String, dynamic>))
          .toList(),
      requiredPermission: json['required_permission'] as String? ?? '',
      defaultPolicy: json['default_policy'] as String? ?? 'ask',
      isCustom: json['is_custom'] as bool? ?? false,
    );
  }
}
