/// Matches Dart client's `ActivityEvent.fromJson`
/// (shared_app/lib/protocol/activity_event.dart, Section 9.6).
///
/// **P1-09**: `category` aur `key_id` fields add kiye — audit: "task/
/// background/location/network/security events, actor/key_id". In dono
/// ko **auto-infer** kiya jaata hai `eventType`/`actor` se (agar
/// explicitly na diye jaayein) — is se 20+ existing `logActivity(...)`
/// call sites (`routes/commands.dart`, `routes/connectors.dart`, etc.)
/// ko chhedna nahi pada, sab automatically sahi structured output dete
/// hain bina kisi call-site edit ke (galti ki gunjaish kam).
///
/// **Sensitive-payload guarantee (jaan-bujh kar, invariant)**: yeh class
/// **kabhi** raw request params, file content, message text, ya koi
/// bhi user data field nahi rakhti — sirf metadata (kaun, kya action,
/// kab, kamyaab hua ya nahi). `GET /devices/{id}/activity` seedha
/// `toJson()` return karta hai, is liye yeh guarantee endpoint tak
/// automatically propagate hoti hai. Agar kabhi is class mein koi naya
/// field add karna ho, pehle confirm karein ke woh field sensitive
/// content nahi hai.
class ActivityEvent {
  final String eventType;
  final String deviceId;
  final String? source;
  final String? taskId;
  final DateTime timestamp;
  final String status; // success | fail | pending
  final String actor; // e.g. "personal_ai_agent" | "user" | "api_key:<id>"

  /// P1-09 — explicit override; na diya jaaye to `eventType` se infer
  /// hota hai (`effectiveCategory`).
  final String? category;

  ActivityEvent({
    required this.eventType,
    required this.deviceId,
    this.source,
    this.taskId,
    required this.timestamp,
    required this.status,
    required this.actor,
    this.category,
  });

  /// P1-09 — structured audit category: `task` | `security` | `location`
  /// | `background` | `connector` | `capability` | `device` | `other`.
  String get effectiveCategory {
    if (category != null) return category!;
    if (eventType.startsWith('connector.')) return 'connector';
    if (eventType.startsWith('capabilities.') || eventType == 'capability_registered') {
      return 'capability';
    }
    if (eventType == 'location.refresh' || eventType.startsWith('location.')) return 'location';
    if (eventType == 'background.keepalive') return 'background';
    if (eventType.startsWith('device.') || eventType == 'switch_event') return 'device';
    if (eventType.startsWith('control.') ||
        eventType.startsWith('screen.') ||
        eventType.startsWith('input.') ||
        eventType.startsWith('files.') ||
        eventType.startsWith('browser.') ||
        eventType.startsWith('clipboard.') ||
        eventType.startsWith('data.') ||
        eventType.startsWith('app_launcher.') ||
        eventType.startsWith('contacts.')) {
      return 'task';
    }
    return 'other';
  }

  /// P1-09 — `actor` string se `key_id` nikalta hai (convention:
  /// `"api_key:<id>"`, jo `routes/commands.dart` waghera already use
  /// karte hain) — ek separate, queryable field ke tor par.
  String? get keyId {
    const prefix = 'api_key:';
    return actor.startsWith(prefix) ? actor.substring(prefix.length) : null;
  }

  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        'device_id': deviceId,
        if (source != null) 'source': source,
        if (taskId != null) 'task_id': taskId,
        'timestamp': timestamp.toIso8601String(),
        'status': status,
        'actor': actor,
        'category': effectiveCategory,
        if (keyId != null) 'key_id': keyId,
      };
}
