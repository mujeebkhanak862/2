import 'package:test/test.dart';

import 'package:control_api/models/task.dart';
import 'package:control_api/storage/app_state.dart';

/// Handoff P1 #4 — server-side live screen rules (FPS cap, replay of the
/// last frame for static screens). Real socket end-to-end: NOT covered.
void main() {
  final t0 = DateTime.utc(2026, 10, 20, 12);

  test('frames faster than ~15 fps are dropped, spaced frames pass', () {
    final s = AppState();
    expect(s.allowScreenFrame('s1', now: t0), isTrue);
    expect(s.allowScreenFrame('s1', now: t0.add(const Duration(milliseconds: 20))), isFalse);
    expect(s.allowScreenFrame('s1', now: t0.add(const Duration(milliseconds: 80))), isTrue);
  });

  test('fps cap is per session', () {
    final s = AppState();
    expect(s.allowScreenFrame('s1', now: t0), isTrue);
    expect(s.allowScreenFrame('s2', now: t0), isTrue);
  });

  test('last frame is replayed to a new viewer while fresh', () {
    final s = AppState();
    s.broadcastToScreen('s1', 'FRAME');
    expect(s.replayableScreenFrame('s1'), 'FRAME');
  });

  test('a stale frame (>30s) is NOT replayed', () {
    final s = AppState();
    s.broadcastToScreen('s1', 'FRAME');
    final later = DateTime.now().toUtc().add(const Duration(seconds: 31));
    expect(s.replayableScreenFrame('s1', now: later), isNull);
  });

  test('no replay once the task is no longer RUNNING', () {
    final s = AppState();
    s.tasks['s1'] = TaskRecord(
        taskId: 's1',
        deviceId: 'dev_1',
        originatingCapability: 'screen',
        state: TaskState.stopped);
    s.broadcastToScreen('s1', 'FRAME');
    expect(s.replayableScreenFrame('s1'), isNull);
  });
}
