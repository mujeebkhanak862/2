/// Core Protocol — Event Envelope
///
/// Control API se WebSocket ke zariye Dashboard aur AI Verifier dono ko
/// yeh events push hote hain (Architecture v4, Section 2.3 — Data Flow,
/// Section 4.3 — Switch Event). Command Envelope ki tarah, yeh shape bhi
/// fixed rehta hai; sirf `type` aur us type ke fields badalte hain.
///
/// Do known event types jo doc mein diye gaye hain:
///
///   task_progress:
///   { "type": "task_progress", "step": 4, "action": "input.tap",
///     "description": "Clicking 'Submit' button", "result": "success",
///     "screenshot_url": "...", "timestamp": "..." }
///
///   switch_event:
///   { "type": "switch_event", "switch_type": "viewing_mode",
///     "new_value": "live", "timestamp": "..." }
library;

/// Base sealed class — sab event types isi se derive hote hain, taaki
/// dashboard/task_monitor mein switch-case exhaustive rahe.
sealed class DeviceAgentEvent {
  final DateTime timestamp;
  const DeviceAgentEvent(this.timestamp);

  /// Raw JSON se sahi subtype uthata hai. Unknown/future event types ke liye
  /// [UnknownEvent] fallback deta hai — taaki naya event-type aane par bhi
  /// app crash na ho (forward-compatible, Section 1.5 ki spirit).
  factory DeviceAgentEvent.fromJson(Map<String, dynamic> json) {
    final ts = DateTime.tryParse(json['timestamp'] as String? ?? '') ??
        DateTime.now();
    switch (json['type'] as String?) {
      case 'task_progress':
        return TaskProgressEvent(
          timestamp: ts,
          step: json['step'] as int,
          action: json['action'] as String,
          description: json['description'] as String,
          result: json['result'] as String,
          screenshotUrl: json['screenshot_url'] as String?,
          durationMs: json['duration_ms'] as int?,
        );
      case 'switch_event':
        return SwitchEvent(
          timestamp: ts,
          switchType: json['switch_type'] as String,
          newValue: json['new_value'] as String,
        );
      case 'task_state':
        // Server ka authoritative TaskRecord state machine (P0-01/P0-02)
        // — dashboard ko is se sync rehna chahiye, apne optimistic
        // client-side `_paused` bool par purely bharosa nahi karna
        // chahiye (jo pehle P1-03 se pehle hota tha).
        return TaskStateEvent(
          timestamp: ts,
          taskId: json['task_id'] as String,
          state: json['state'] as String,
        );
      default:
        return UnknownEvent(timestamp: ts, raw: json);
    }
  }
}

/// Task Monitor Dashboard iska direct consumer hai — step timeline,
/// current-action label, aur screenshot preview isi event se aate hain
/// (Section 2.2).
final class TaskProgressEvent extends DeviceAgentEvent {
  final int step;
  final String action; // e.g. "input.tap"
  final String description; // e.g. "Clicking 'Submit' button"
  final String result; // "success" | "fail"
  final String? screenshotUrl;
  /// P1-04 — is action ko dispatch hone mein kitne milliseconds lage.
  /// Purane/legacy events (is field ke bina) ke liye `null`.
  final int? durationMs;

  TaskProgressEvent({
    required DateTime timestamp,
    required this.step,
    required this.action,
    required this.description,
    required this.result,
    this.screenshotUrl,
    this.durationMs,
  }) : super(timestamp);

  bool get succeeded => result == 'success';
}

/// Jab bhi `control.switch` command execute hota hai, yeh event turant fire
/// hota hai taaki dashboard aur AI dono ka context turant sync rahe
/// (Section 4.3).
final class SwitchEvent extends DeviceAgentEvent {
  final String switchType; // "device" | "viewing_mode" | "api_key" | "capability_target"
  final String newValue;

  SwitchEvent({
    required DateTime timestamp,
    required this.switchType,
    required this.newValue,
  }) : super(timestamp);
}

/// P0-01/P0-02 ke server-side `TaskRecord` state machine se — jab bhi
/// pause/resume/stop apply hota hai, yeh event broadcast hota hai.
/// `state` ka enum: `RUNNING`, `PAUSED`, `STOPPED`, `COMPLETED`, `FAILED`.
final class TaskStateEvent extends DeviceAgentEvent {
  final String taskId;
  final String state;

  TaskStateEvent({
    required DateTime timestamp,
    required this.taskId,
    required this.state,
  }) : super(timestamp);
}

/// Forward-compat fallback — koi naya event type jo abhi is client ko pata
/// nahi, yahan land karta hai bajaye crash hone ke.
final class UnknownEvent extends DeviceAgentEvent {
  final Map<String, dynamic> raw;
  UnknownEvent({required DateTime timestamp, required this.raw})
      : super(timestamp);
}
