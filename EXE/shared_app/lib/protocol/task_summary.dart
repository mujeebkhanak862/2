/// Item 30/87: `GET /tasks` ka ek row.
library;

class TaskSummary {
  final String taskId;
  final String state; // RUNNING | PAUSED | STOPPED | COMPLETED | FAILED
  final String capability;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TaskSummary({
    required this.taskId,
    required this.state,
    required this.capability,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isActive => state == 'RUNNING' || state == 'PAUSED';

  factory TaskSummary.fromJson(Map<String, dynamic> json) => TaskSummary(
        taskId: (json['task_id'] ?? json['session_id']) as String,
        state: json['state'] as String? ?? 'RUNNING',
        capability: (json['originating_capability'] ??
                json['capability'] ??
                'unknown') as String,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}
