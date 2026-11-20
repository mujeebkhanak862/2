import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/event_envelope.dart';

void main() {
  group('DeviceAgentEvent.fromJson — task_state (P1-03)', () {
    test('parses a task_state event into a TaskStateEvent', () {
      final event = DeviceAgentEvent.fromJson({
        'protocol_version': '1.0',
        'type': 'task_state',
        'session_id': 'sess_1',
        'task_id': 'sess_1',
        'state': 'PAUSED',
        'timestamp': '2026-01-01T00:00:00Z',
      });
      expect(event, isA<TaskStateEvent>());
      final taskState = event as TaskStateEvent;
      expect(taskState.taskId, 'sess_1');
      expect(taskState.state, 'PAUSED');
    });

    test('RUNNING/STOPPED/COMPLETED/FAILED all parse correctly', () {
      for (final state in ['RUNNING', 'PAUSED', 'STOPPED', 'COMPLETED', 'FAILED']) {
        final event = DeviceAgentEvent.fromJson({
          'type': 'task_state',
          'task_id': 't1',
          'state': state,
          'timestamp': '2026-01-01T00:00:00Z',
        }) as TaskStateEvent;
        expect(event.state, state);
      }
    });

    test('an unknown event type still falls back to UnknownEvent, not a crash', () {
      final event = DeviceAgentEvent.fromJson({
        'type': 'some_future_event_type',
        'timestamp': '2026-01-01T00:00:00Z',
        'extra_field': 'whatever',
      });
      expect(event, isA<UnknownEvent>());
    });

    test('task_progress events still parse correctly (regression guard)', () {
      final event = DeviceAgentEvent.fromJson({
        'type': 'task_progress',
        'step': 3,
        'action': 'input.tap',
        'description': 'Tapped the login button',
        'result': 'success',
        'timestamp': '2026-01-01T00:00:00Z',
      });
      expect(event, isA<TaskProgressEvent>());
      final progress = event as TaskProgressEvent;
      expect(progress.step, 3);
      expect(progress.action, 'input.tap');
    });
  });
}
