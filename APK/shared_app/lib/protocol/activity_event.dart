/// Unified Activity History event model (Architecture v4, Section 9.6).
/// Har background operation, location update, network change, switch,
/// aur task action isi stream mein record hota hai.
library;

class ActivityEvent {
  final String eventType; // e.g. "message_reply", "location_updated"
  final String deviceId;
  final String? source; // e.g. "notification"
  final String? taskId;
  final DateTime timestamp;
  final String status; // "success" | "fail" | "pending"
  final String actor; // e.g. "personal_ai_agent" | "user"

  const ActivityEvent({
    required this.eventType,
    required this.deviceId,
    this.source,
    this.taskId,
    required this.timestamp,
    required this.status,
    required this.actor,
  });

  factory ActivityEvent.fromJson(Map<String, dynamic> json) => ActivityEvent(
        eventType: json['event_type'] as String,
        deviceId: json['device_id'] as String,
        source: json['source'] as String?,
        taskId: json['task_id'] as String?,
        timestamp: DateTime.parse(json['timestamp'] as String),
        status: json['status'] as String,
        actor: json['actor'] as String,
      );

  bool get succeeded => status == 'success';
}
