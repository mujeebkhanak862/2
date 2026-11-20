import 'package:control_api/models/task.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:test/test.dart';

void main() {
  group('TaskRecord state machine (P0-01)', () {
    late TaskRecord task;

    setUp(() {
      task = TaskRecord(taskId: 'sess_1', deviceId: 'dev_1', originatingCapability: 'screen');
    });

    test('starts RUNNING', () {
      expect(task.state, TaskState.running);
    });

    // ---- TASK-01: pause => no new action + PAUSED ------------------------
    test('TASK-01: pause from RUNNING => PAUSED', () {
      final result = task.applyAction('control.pause');
      expect(result.allowed, isTrue);
      expect(result.isNoop, isFalse);
      expect(task.state, TaskState.paused);
    });

    test('TASK-01: repeated pause is idempotent (no-op, still allowed)', () {
      task.applyAction('control.pause');
      final second = task.applyAction('control.pause');
      expect(second.allowed, isTrue);
      expect(second.isNoop, isTrue);
      expect(task.state, TaskState.paused);
    });

    // ---- TASK-02: resume => valid checkpoint se continue ------------------
    test('TASK-02: resume from PAUSED => RUNNING', () {
      task.applyAction('control.pause');
      final result = task.applyAction('control.resume');
      expect(result.allowed, isTrue);
      expect(result.isNoop, isFalse);
      expect(task.state, TaskState.running);
    });

    test('TASK-02: resume on already-RUNNING is idempotent no-op', () {
      final result = task.applyAction('control.resume');
      expect(result.allowed, isTrue);
      expect(result.isNoop, isTrue);
      expect(task.state, TaskState.running);
    });

    test('TASK-02: resume on a STOPPED task is rejected (terminal)', () {
      task.applyAction('control.stop');
      final result = task.applyAction('control.resume');
      expect(result.allowed, isFalse);
      expect(result.reason, isNotNull);
      expect(task.state, TaskState.stopped); // unchanged
    });

    // ---- TASK-03: stop => supported cancellation + STOPPED -----------------
    test('TASK-03: stop from RUNNING => STOPPED', () {
      final result = task.applyAction('control.stop');
      expect(result.allowed, isTrue);
      expect(task.state, TaskState.stopped);
    });

    test('TASK-03: stop from PAUSED => STOPPED', () {
      task.applyAction('control.pause');
      final result = task.applyAction('control.stop');
      expect(result.allowed, isTrue);
      expect(task.state, TaskState.stopped);
    });

    test('TASK-03: repeated stop is idempotent (no-op, still allowed)', () {
      task.applyAction('control.stop');
      final second = task.applyAction('control.stop');
      expect(second.allowed, isTrue);
      expect(second.isNoop, isTrue);
      expect(task.state, TaskState.stopped);
    });

    test('stop on a COMPLETED task is rejected (already terminal via another path)', () {
      task.state = TaskState.completed; // simulates task finishing normally
      final result = task.applyAction('control.stop');
      expect(result.allowed, isFalse);
      expect(task.state, TaskState.completed); // unchanged
    });

    test('pause on a terminal FAILED task is rejected', () {
      task.state = TaskState.failed;
      final result = task.applyAction('control.pause');
      expect(result.allowed, isFalse);
      expect(task.state, TaskState.failed); // unchanged
    });

    test('unknown control action is rejected', () {
      final result = task.applyAction('control.teleport');
      expect(result.allowed, isFalse);
    });
  });

  group('AppState task tracking (P0-01)', () {
    test('getOrCreateRunningTask creates a RUNNING task once', () {
      final state = AppState();
      final t1 = state.getOrCreateRunningTask('sess_a', 'dev_1', 'screen');
      expect(t1.state, TaskState.running);
      expect(state.tasks.containsKey('sess_a'), isTrue);

      // Second call for the same id returns the *same* record, does not
      // reset an already-transitioned task back to RUNNING.
      t1.state = TaskState.paused;
      final t2 = state.getOrCreateRunningTask('sess_a', 'dev_1', 'screen');
      expect(identical(t1, t2), isTrue);
      expect(t2.state, TaskState.paused);
    });

    test('broadcastTaskState does not throw with no listeners', () {
      final state = AppState();
      final task = state.getOrCreateRunningTask('sess_b', 'dev_1', 'input');
      expect(() => state.broadcastTaskState(task), returnsNormally);
    });
  });
}
