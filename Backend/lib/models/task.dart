/// P0-01 — Real Task Lifecycle: TaskRecord state machine.
///
/// PROTOCOL_V1.md abhi koi dedicated `task_id` field envelope mein nahi
/// deta (frozen envelope — naye required field add nahi kiye ja sakte).
/// Command envelope mein jo `params.session_id` already forward-routing
/// ke liye use ho raha hai (`AppState.sessionToDevice`), usi ko is task
/// ke correlation id (`taskId`) ki tarah treat karte hain — yeh ek
/// jaan-bujh kar liya gaya, documented decision hai taaki envelope shape
/// na todni pade. Naya optional `task_id` field future minor version
/// (1.x) mein add ho sakta hai bina breaking change ke.
library;

/// Valid states — audit ke P0-01 acceptance criteria (TASK-01/02/03) ke
/// mutabiq.
enum TaskState { running, paused, stopped, completed, failed }

extension TaskStateWire on TaskState {
  String get wireValue => switch (this) {
        TaskState.running => 'RUNNING',
        TaskState.paused => 'PAUSED',
        TaskState.stopped => 'STOPPED',
        TaskState.completed => 'COMPLETED',
        TaskState.failed => 'FAILED',
      };

  /// Terminal states — in se koi aage transition allowed nahi (sirf
  /// idempotent repeat, woh bhi sirf same-state ke liye).
  bool get isTerminal =>
      this == TaskState.stopped ||
      this == TaskState.completed ||
      this == TaskState.failed;
}

TaskState? taskStateFromWire(String? value) {
  switch (value) {
    case 'RUNNING':
      return TaskState.running;
    case 'PAUSED':
      return TaskState.paused;
    case 'STOPPED':
      return TaskState.stopped;
    case 'COMPLETED':
      return TaskState.completed;
    case 'FAILED':
      return TaskState.failed;
    default:
      return null;
  }
}

/// Result of attempting a transition — reject karne ka reason bhi carry
/// karta hai taaki caller ko `INVALID_REQUEST` mein wajah bataayi ja sake.
class TaskTransitionResult {
  final bool allowed;
  final bool isNoop; // idempotent repeat — allowed hai lekin state nahi badli
  final String? reason;

  const TaskTransitionResult._(this.allowed, this.isNoop, this.reason);

  factory TaskTransitionResult.applied() =>
      const TaskTransitionResult._(true, false, null);
  factory TaskTransitionResult.noop() =>
      const TaskTransitionResult._(true, true, null);
  factory TaskTransitionResult.rejected(String reason) =>
      TaskTransitionResult._(false, false, reason);
}

class TaskRecord {
  final String taskId; // == session_id (see note above)
  final String deviceId;
  TaskState state;
  final DateTime createdAt;
  DateTime updatedAt;

  /// P0-02 — is task ko kis capability wali command ne shuru kiya tha
  /// (e.g. "screen", "input", "files"). `control.pause/resume/stop` ki
  /// authorization isi se hoti hai: jis key ke paas is capability ka
  /// scope nahi hai, woh is task ko pause/resume/stop nahi kar sakti,
  /// chahe uske paas koi aur (unrelated) scope kyun na ho. Pehle yahan
  /// interim "koi bhi ek scope granted ho to chalega" policy thi —
  /// audit ne explicitly disallow kiya, ab yeh field wahi real binding
  /// provide karta hai (`ApiKeyScope.allowsCapability`, routes/commands.dart).
  final String originatingCapability;

  /// Last successfully completed step's checkpoint — device-reported,
  /// resume isi se continue karta hai (`control.resume` device ko yeh
  /// wapas bhejta hai).
  Map<String, dynamic>? lastCheckpoint;

  /// Audit fix (Section 8 / Section 13 #2) — `control.complete`/
  /// `control.fail` ke saath diya gaya optional reason (jaise failure ki
  /// wajah). COMPLETED ke liye aam taur par null rehta hai.
  String? terminalReason;

  TaskRecord({
    required this.taskId,
    required this.deviceId,
    required this.originatingCapability,
    this.state = TaskState.running,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastCheckpoint,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  /// Core state machine — audit TASK-01/02/03 ke transitions.
  ///
  /// Allowed:
  ///   RUNNING --pause--> PAUSED
  ///   PAUSED  --resume-> RUNNING
  ///   RUNNING --stop---> STOPPED
  ///   PAUSED  --stop---> STOPPED
  /// Idempotent (no-op, still success):
  ///   RUNNING --pause (already paused via race)  -> stays as-is per case below
  ///   PAUSED  --pause--> PAUSED (no-op)
  ///   RUNNING --resume--> RUNNING (no-op)
  ///   STOPPED --stop--> STOPPED (no-op)
  /// Rejected (terminal, INVALID_REQUEST):
  ///   STOPPED/COMPLETED/FAILED --pause/resume--> reject
  ///   COMPLETED/FAILED --stop--> reject
  TaskTransitionResult applyAction(String controlAction) {
    switch (controlAction) {
      case 'control.pause':
        if (state == TaskState.paused) return TaskTransitionResult.noop();
        if (state == TaskState.running) {
          state = TaskState.paused;
          updatedAt = DateTime.now().toUtc();
          return TaskTransitionResult.applied();
        }
        return TaskTransitionResult.rejected(
            'Task "$taskId" state "${state.wireValue}" se pause nahi ho sakta');

      case 'control.resume':
        if (state == TaskState.running) return TaskTransitionResult.noop();
        if (state == TaskState.paused) {
          state = TaskState.running;
          updatedAt = DateTime.now().toUtc();
          return TaskTransitionResult.applied();
        }
        return TaskTransitionResult.rejected(
            'Task "$taskId" state "${state.wireValue}" se resume nahi ho sakta');

      case 'control.stop':
        if (state == TaskState.stopped) return TaskTransitionResult.noop();
        if (state == TaskState.running || state == TaskState.paused) {
          state = TaskState.stopped;
          updatedAt = DateTime.now().toUtc();
          return TaskTransitionResult.applied();
        }
        return TaskTransitionResult.rejected(
            'Task "$taskId" state "${state.wireValue}" se stop nahi ho sakta '
            '(already terminal)');

      // ---- Audit fix (Section 8 / Section 13 #2): explicit completion/
      // failure transitions ----------------------------------------------
      // Pehle COMPLETED/FAILED sirf enum states the — inme jaane ka koi
      // normal code path nahi tha (koi bhi task hamesha RUNNING/PAUSED/
      // STOPPED hi rehta). Yeh do naye control actions caller (AI/
      // orchestrator, jo apne multi-step kaam ka "khatam ho gaya" ya
      // "fail ho gaya" judgment sabse behtar jaanta hai) ko explicitly
      // yeh transition karne dete hain — bilkul waisi hi request/response
      // shape se jaisi control.pause/resume/stop already hai
      // (POST /commands, action-level scope se authorized).
      case 'control.complete':
        if (state == TaskState.completed) return TaskTransitionResult.noop();
        if (state == TaskState.running || state == TaskState.paused) {
          state = TaskState.completed;
          updatedAt = DateTime.now().toUtc();
          return TaskTransitionResult.applied();
        }
        return TaskTransitionResult.rejected(
            'Task "$taskId" state "${state.wireValue}" se complete nahi ho sakta '
            '(already terminal)');

      case 'control.fail':
        if (state == TaskState.failed) return TaskTransitionResult.noop();
        if (state == TaskState.running || state == TaskState.paused) {
          state = TaskState.failed;
          updatedAt = DateTime.now().toUtc();
          return TaskTransitionResult.applied();
        }
        return TaskTransitionResult.rejected(
            'Task "$taskId" state "${state.wireValue}" se fail nahi ho sakta '
            '(already terminal)');

      default:
        return TaskTransitionResult.rejected(
            'Unknown control action "$controlAction"');
    }
  }

  /// Audit fix (Section 8) — device-to-server checkpoint reporting. Har
  /// `task_progress` event (device se aane wala har completed step) se
  /// server ka `lastCheckpoint` yahan se refresh hota hai
  /// (`websocket/handlers.dart`'s `_handleAgentMessage`), taaki
  /// `control.resume` ek stale/empty checkpoint ki jagah server ka
  /// authoritative-latest checkpoint device ko wapas bhej sake — khaaskar
  /// us case mein jab device process khud restart ho chuki ho aur apna
  /// in-memory local checkpoint kho chuki ho.
  /// Task par koi activity hui (naya command dispatch) — stale-sweeper
  /// (`AppState.sweepTasks`) ke liye `updatedAt` refresh.
  void touch([DateTime? now]) {
    updatedAt = (now ?? DateTime.now()).toUtc();
  }

  void recordCheckpoint(Map<String, dynamic> checkpoint) {
    lastCheckpoint = checkpoint;
    updatedAt = DateTime.now().toUtc();
  }

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'device_id': deviceId,
        'state': state.wireValue,
        'capability': originatingCapability,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        if (lastCheckpoint != null) 'checkpoint': lastCheckpoint,
        if (terminalReason != null) 'reason': terminalReason,
      };
}
