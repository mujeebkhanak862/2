import 'package:test/test.dart';

import 'package:control_api/models/task.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/websocket/handlers.dart';

/// Handoff P0 #2 — task lifecycle ke woh paths jo pehle sirf enum/model
/// level par tested the: device->server checkpoint reporting
/// (`handleAgentMessage`), stale sweeper (`sweepTasks`), aur safe rollback.
/// NOTE: POST /commands route-level (pause/resume/stop + forward) abhi bhi
/// real HTTP/WS integration test maangta hai — yahan cover nahi.
AppState _stateWithTask({TaskState st = TaskState.running, DateTime? updatedAt}) {
  final state = AppState();
  state.tasks['t1'] = TaskRecord(
    taskId: 't1',
    deviceId: 'dev_1',
    originatingCapability: 'input',
    state: st,
    updatedAt: updatedAt,
  );
  state.sessionToDevice['t1'] = 'dev_1';
  return state;
}

void main() {
  group('device -> server checkpoint reporting', () {
    test('task_progress from the owning device records lastCheckpoint', () {
      final state = _stateWithTask();
      handleAgentMessage(state, 'dev_1', {
        'kind': 'event',
        'session_id': 't1',
        'type': 'task_progress',
        'step': 3,
        'action': 'input.tap',
      });
      expect(state.tasks['t1']!.lastCheckpoint,
          {'completed_steps': 3, 'last_action': 'input.tap'});
    });

    test('task_progress from a different device does NOT touch the checkpoint', () {
      final state = _stateWithTask();
      handleAgentMessage(state, 'dev_2', {
        'kind': 'event',
        'session_id': 't1',
        'type': 'task_progress',
        'step': 9,
      });
      expect(state.tasks['t1']!.lastCheckpoint, isNull);
    });

    test('a non-int step is ignored', () {
      final state = _stateWithTask();
      handleAgentMessage(state, 'dev_1', {
        'kind': 'event',
        'session_id': 't1',
        'type': 'task_progress',
        'step': 'three',
      });
      expect(state.tasks['t1']!.lastCheckpoint, isNull);
    });
  });

  group('sweepTasks (stale cleanup)', () {
    final now = DateTime.utc(2026, 10, 20, 12);

    test('a RUNNING task idle > 24h becomes FAILED with a stale reason', () {
      final state = _stateWithTask(updatedAt: now.subtract(const Duration(hours: 30)));
      final r = state.sweepTasks(now: now);
      expect(r.failed, ['t1']);
      expect(state.tasks['t1']!.state, TaskState.failed);
      expect(state.tasks['t1']!.terminalReason, startsWith('stale:'));
    });

    test('a recently active RUNNING task is left alone', () {
      final state = _stateWithTask(updatedAt: now.subtract(const Duration(hours: 2)));
      final r = state.sweepTasks(now: now);
      expect(r.failed, isEmpty);
      expect(state.tasks['t1']!.state, TaskState.running);
    });

    test('a PAUSED task idle 2 days is NOT failed (7-day window)', () {
      final state = _stateWithTask(
          st: TaskState.paused, updatedAt: now.subtract(const Duration(days: 2)));
      expect(state.sweepTasks(now: now).failed, isEmpty);
      expect(state.tasks['t1']!.state, TaskState.paused);
    });

    test('an old terminal task is removed along with its session mapping', () {
      final state = _stateWithTask(
          st: TaskState.completed, updatedAt: now.subtract(const Duration(days: 8)));
      final r = state.sweepTasks(now: now);
      expect(r.removed, ['t1']);
      expect(state.tasks.containsKey('t1'), isFalse);
      expect(state.sessionToDevice.containsKey('t1'), isFalse);
    });

    test('a fresh terminal task is kept', () {
      final state = _stateWithTask(
          st: TaskState.stopped, updatedAt: now.subtract(const Duration(days: 1)));
      expect(state.sweepTasks(now: now).removed, isEmpty);
      expect(state.tasks.containsKey('t1'), isTrue);
    });
  });

  group('rollbackTask guard', () {
    test('rolls back when the task is still in the state this request set', () {
      final state = _stateWithTask(st: TaskState.paused);
      expect(state.rollbackTask('t1', TaskState.running, TaskState.paused), isTrue);
      expect(state.tasks['t1']!.state, TaskState.running);
    });

    test('does NOT roll back if another request already changed the state', () {
      final state = _stateWithTask(st: TaskState.stopped);
      expect(state.rollbackTask('t1', TaskState.running, TaskState.paused), isFalse);
      expect(state.tasks['t1']!.state, TaskState.stopped);
    });

    test('does not crash when the task was removed meanwhile', () {
      final state = AppState();
      expect(state.rollbackTask('gone', TaskState.running, TaskState.paused), isFalse);
    });
  });
}
