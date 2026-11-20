import 'dart:io';

import 'package:control_api/models/task.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/storage/persistence.dart';
import 'package:test/test.dart';

/// Audit fix (Section 8 / Section 13 #2): "COMPLETED/FAILED are enum
/// states only; no normal completion/failure path was found. Checkpoint
/// is stored as a field but no real checkpoint reporting/resume
/// mechanism was found." — these tests exercise the new
/// `control.complete`/`control.fail` transitions, `recordCheckpoint()`,
/// and the fact that task state (incl. checkpoint) now survives a
/// persistence round-trip.
void main() {
  group('TaskRecord.applyAction — control.complete / control.fail', () {
    late TaskRecord task;

    setUp(() {
      task = TaskRecord(taskId: 'sess_1', deviceId: 'dev_1', originatingCapability: 'screen');
    });

    test('control.complete from RUNNING => COMPLETED', () {
      final result = task.applyAction('control.complete');
      expect(result.allowed, isTrue);
      expect(result.isNoop, isFalse);
      expect(task.state, TaskState.completed);
    });

    test('control.complete from PAUSED => COMPLETED', () {
      task.applyAction('control.pause');
      final result = task.applyAction('control.complete');
      expect(result.allowed, isTrue);
      expect(task.state, TaskState.completed);
    });

    test('repeated control.complete is idempotent (no-op)', () {
      task.applyAction('control.complete');
      final second = task.applyAction('control.complete');
      expect(second.allowed, isTrue);
      expect(second.isNoop, isTrue);
      expect(task.state, TaskState.completed);
    });

    test('control.complete on an already-FAILED task is rejected (cannot flip terminal state)', () {
      task.applyAction('control.fail');
      final result = task.applyAction('control.complete');
      expect(result.allowed, isFalse);
      expect(task.state, TaskState.failed); // unchanged
    });

    test('control.fail from RUNNING => FAILED', () {
      final result = task.applyAction('control.fail');
      expect(result.allowed, isTrue);
      expect(task.state, TaskState.failed);
    });

    test('control.fail on a STOPPED task is rejected (already terminal)', () {
      task.applyAction('control.stop');
      final result = task.applyAction('control.fail');
      expect(result.allowed, isFalse);
      expect(task.state, TaskState.stopped); // unchanged
    });

    test('control.pause/resume/stop on a COMPLETED task are all rejected', () {
      task.applyAction('control.complete');
      expect(task.applyAction('control.pause').allowed, isFalse);
      expect(task.applyAction('control.resume').allowed, isFalse);
      expect(task.applyAction('control.stop').allowed, isFalse);
      expect(task.state, TaskState.completed);
    });
  });

  group('TaskRecord.recordCheckpoint', () {
    test('sets lastCheckpoint and bumps updatedAt', () async {
      final task = TaskRecord(taskId: 't1', deviceId: 'd1', originatingCapability: 'input');
      final before = task.updatedAt;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      task.recordCheckpoint({'completed_steps': 3, 'last_action': 'input.tap'});
      expect(task.lastCheckpoint, {'completed_steps': 3, 'last_action': 'input.tap'});
      expect(task.updatedAt.isAfter(before), isTrue);
    });

    test('toJson exposes the checkpoint once set, omits it when null', () {
      final task = TaskRecord(taskId: 't1', deviceId: 'd1', originatingCapability: 'input');
      expect(task.toJson().containsKey('checkpoint'), isFalse);
      task.recordCheckpoint({'completed_steps': 1});
      expect(task.toJson()['checkpoint'], {'completed_steps': 1});
    });
  });

  group('Persistence round-trip — tasks (audit fix)', () {
    test('a RUNNING task with a checkpoint survives save() + load()', () async {
      final dir = await Directory.systemTemp.createTemp('uda_task_persist_test_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');

      final state1 = AppState();
      final persistence1 = Persistence(state1, fileOverride: file);
      final task = state1.getOrCreateRunningTask('sess_x', 'dev_1', 'screen');
      task.applyAction('control.pause');
      task.recordCheckpoint({'completed_steps': 7, 'last_action': 'screen.capture'});
      await persistence1.save();

      final state2 = AppState();
      final persistence2 = Persistence(state2, fileOverride: file);
      await persistence2.load();

      expect(state2.tasks.containsKey('sess_x'), isTrue);
      final reloaded = state2.tasks['sess_x']!;
      expect(reloaded.state, TaskState.paused);
      expect(reloaded.deviceId, 'dev_1');
      expect(reloaded.originatingCapability, 'screen');
      expect(reloaded.lastCheckpoint, {'completed_steps': 7, 'last_action': 'screen.capture'});
    });

    test('a FAILED task with a reason survives save() + load()', () async {
      final dir = await Directory.systemTemp.createTemp('uda_task_persist_test_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');

      final state1 = AppState();
      final persistence1 = Persistence(state1, fileOverride: file);
      final task = state1.getOrCreateRunningTask('sess_y', 'dev_1', 'files');
      task.applyAction('control.fail');
      task.terminalReason = 'device reported unrecoverable error';
      await persistence1.save();

      final state2 = AppState();
      final persistence2 = Persistence(state2, fileOverride: file);
      await persistence2.load();

      final reloaded = state2.tasks['sess_y']!;
      expect(reloaded.state, TaskState.failed);
      expect(reloaded.terminalReason, 'device reported unrecoverable error');
    });
  });
}
