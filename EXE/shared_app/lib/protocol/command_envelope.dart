/// Core Protocol — Command Envelope
///
/// Yeh woh **fixed shape** hai jo har command (chahe capability koi bhi ho —
/// screen, input, files, browser, data, control/switch, ya future plugin)
/// follow karta hai. Core protocol isi envelope ko samajhta hai; naye
/// capability aane par sirf `capability` / `action` / `params` badalte hain,
/// envelope khud kabhi nahi badalta (Architecture v4, Section 1.1 & 1.5).
///
/// Reference examples jo isi shape se match karte hain (doc se):
///   { "capability": "screen", "action": "screen.watch_live",
///     "params": { "session_id": "..." } }
///
///   { "request_id": "...", "api_key_id": "key_003", "capability": "data",
///     "action": "data.upload", "params": { "target_path": "..." },
///     "payload": "<base64 image bytes>", "timeout_ms": 8000 }
///
///   { "capability": "control", "action": "control.switch",
///     "params": { "switch_type": "device", "value": "device_042" } }
library;

class CommandEnvelope {
  /// PROTOCOL_V1.md (frozen spec, root of repo) — is client ka current
  /// protocol version. Server sirf major version match hone par accept
  /// karta hai; naye optional fields future minor versions mein add ho
  /// sakte hain bina isko badle.
  static const String currentProtocolVersion = '1.0';

  final String protocolVersion;

  /// Unique id for this request — response/event correlation ke liye.
  final String requestId;

  /// Kaunsi scoped API key yeh command bhej rahi hai. Policy Engine isi se
  /// scope check karta hai (Section 3.5 — safety rule).
  final String apiKeyId;

  /// Plugin/capability ka naam — "screen", "input", "files", "browser",
  /// "clipboard", "data", "control", ya koi future/external connector.
  final String capability;

  /// Us capability ke andar specific action — jaise "input.tap",
  /// "data.upload", "control.switch". Naming convention: "<capability>.<verb>".
  final String action;

  /// Action-specific parameters — capability manifest ke params_schema se
  /// validate hote hain (Section 1.2).
  final Map<String, dynamic> params;

  /// Optional binary payload (base64) — sirf Data Channel actions
  /// (data.upload, media.send) mein use hota hai (Section 3.4).
  final String? payload;

  /// Optional timeout — na diya jaye to Control API ka default lagta hai.
  final int? timeoutMs;

  const CommandEnvelope({
    this.protocolVersion = currentProtocolVersion,
    required this.requestId,
    required this.apiKeyId,
    required this.capability,
    required this.action,
    this.params = const {},
    this.payload,
    this.timeoutMs,
  });

  Map<String, dynamic> toJson() => {
        'protocol_version': protocolVersion,
        'request_id': requestId,
        'api_key_id': apiKeyId,
        'capability': capability,
        'action': action,
        'params': params,
        if (payload != null) 'payload': payload,
        if (timeoutMs != null) 'timeout_ms': timeoutMs,
      };

  factory CommandEnvelope.fromJson(Map<String, dynamic> json) {
    return CommandEnvelope(
      // Purane/malformed messages mein na ho to bhi crash na ho — default
      // current version maan lete hain (forward-compat, PROTOCOL_V1.md
      // ki spirit: naye fields hamesha optional/tolerant hone chahiye
      // jab parse kiye jaa rahe hon, chahe likhte waqt hum khud hamesha
      // include karte hon).
      protocolVersion:
          json['protocol_version'] as String? ?? currentProtocolVersion,
      requestId: json['request_id'] as String,
      apiKeyId: json['api_key_id'] as String,
      capability: json['capability'] as String,
      action: json['action'] as String,
      params: (json['params'] as Map<String, dynamic>?) ?? const {},
      payload: json['payload'] as String?,
      timeoutMs: json['timeout_ms'] as int?,
    );
  }

  /// Convenience: har naye request ke liye ek fresh envelope + generated id.
  /// (id generation ke liye Uuid caller/api_client se pass hoga, taaki yeh
  /// file khud kisi package par depend na kare.)
  CommandEnvelope copyWith({
    String? protocolVersion,
    String? requestId,
    String? apiKeyId,
    String? capability,
    String? action,
    Map<String, dynamic>? params,
    String? payload,
    int? timeoutMs,
  }) {
    return CommandEnvelope(
      protocolVersion: protocolVersion ?? this.protocolVersion,
      requestId: requestId ?? this.requestId,
      apiKeyId: apiKeyId ?? this.apiKeyId,
      capability: capability ?? this.capability,
      action: action ?? this.action,
      params: params ?? this.params,
      payload: payload ?? this.payload,
      timeoutMs: timeoutMs ?? this.timeoutMs,
    );
  }
}

/// Standard command well-known switch_type values (Section 4.1) — capability
/// "control", action "control.switch" ke `params.switch_type` mein use hote
/// hain. Enum rakhne se typo-prone strings dashboard/AI dono jagah se hat
/// jaate hain.
enum SwitchType { device, viewingMode, apiKey, capabilityTarget }

extension SwitchTypeWire on SwitchType {
  String get wireValue => switch (this) {
        SwitchType.device => 'device',
        SwitchType.viewingMode => 'viewing_mode',
        SwitchType.apiKey => 'api_key',
        SwitchType.capabilityTarget => 'capability_target',
      };
}
