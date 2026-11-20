import '../util/crypto_utils.dart';

/// Ek paired device — `POST /devices/pair` ke through banta hai.
/// Bearer token isi device ki saari future requests (key creation,
/// status, waghera) authenticate karta hai — Dart client ka
/// `DeviceAgentApiClient.setBearerToken()` isi ke liye already defined
/// tha, bas server side kabhi banaya nahi gaya tha.
///
/// **P0-06 fix:** pehle `bearerToken` yahan **plaintext** store hota
/// tha (memory + disk, `storage/persistence.dart`) — `ApiKeyRecord` ke
/// secret se bilkul alag treatment, jabke security-wise dono equally
/// sensitive hain. Ab sirf `bearerTokenHash` store hota hai
/// (`util/crypto_utils.dart`'s `hashSecretUtil`, wahi jo `ApiKeyRecord`
/// use karta hai) — plaintext token sirf `POST /devices/pair` ke
/// response mein, ek hi baar, wapas jaata hai.
class Device {
  final String id;
  String name;
  /// Item 21: token rotation ke liye ab final nahi hai.
  String bearerTokenHash;

  /// P1-02 — device ka OS platform: `android` | `windows` | `linux`.
  /// Pairing ke waqt client khud batata hai (`POST /devices/pair`'s
  /// `platform` field). AI Tool Registry (`ai_tools/ai_tool_registry.dart`)
  /// isi se decide karta hai ke kaunsi capabilities is device par
  /// support hi nahi hain (jaise `contacts` sirf Android par).
  ///
  /// Purane (P1-02 se pehle) paired devices ke paas yeh field disk par
  /// nahi hogi — load karte waqt `'unknown'` fallback hota hai
  /// (`storage/persistence.dart`), jisko AI Tool Registry "platform
  /// filter skip karo" ki tarah treat karta hai (permissive fallback —
  /// purane devices ke liye tools achanak gayab nahi ho jaate, bas
  /// platform-specific narrowing nahi milti jab tak woh dobara pair na
  /// karein).
  final String platform;

  final DateTime pairedAt;
  DateTime lastSeenAt;

  // Section 9.2 state machine — background agent isko update karta rahega.
  String state; // ONLINE_UNLOCKED | ONLINE_LOCKED | SCREEN_OFF | SLEEPING | OFFLINE | POWERED_OFF
  bool backgroundActive;
  int? batteryPercent;

  Map<String, dynamic>? lastLocation; // {latitude, longitude, accuracy_m, timestamp, source}
  Map<String, dynamic>? lastNetwork; // {connected, ssid, connection_type, timestamp}

  Device({
    required this.id,
    required this.name,
    required this.bearerTokenHash,
    this.platform = 'unknown',
    required this.pairedAt,
    required this.lastSeenAt,
    this.state = 'OFFLINE',
    this.backgroundActive = false,
    this.batteryPercent,
    this.lastLocation,
    this.lastNetwork,
  });

  Map<String, dynamic> toStatusJson() => {
        'device_id': id,
        'state': state,
        'platform': platform,
        'background_active': backgroundActive,
        'battery_percent': batteryPercent,
        if (lastLocation != null) 'location': lastLocation,
        if (lastNetwork != null) 'network': lastNetwork,
      };

  /// Item 19: 128-bit random id (pehle sirf 32-bit tha — collision par
  /// purana device overwrite ho sakta tha).
  static String generateId() => 'device_${randomHex(16)}';

  static String generateToken() => randomHex(16);
}
