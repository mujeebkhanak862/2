import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/agent_connection.dart';
import 'package:shared_app/protocol/command_envelope.dart';

CommandEnvelope _envelope(String action, Map<String, dynamic> params) => CommandEnvelope(
      protocolVersion: CommandEnvelope.currentProtocolVersion,
      requestId: 'req_1',
      apiKeyId: 'key_1',
      capability: 'control',
      action: action,
      params: params,
    );

/// Audit fix (Section 8 / Section 13 #2): "control.resume does not
/// visibly transmit a checkpoint to the device." — `control.resume` now
/// carries the server's authoritative `lastCheckpoint` as
/// `params.server_checkpoint`; the device adopts it only when it moves
/// the local checkpoint *forward* (fresh/reset local state), never
/// backward.
void main() {
  group('CommandDispatcher control.resume — server checkpoint adoption', () {
    test('with no server_checkpoint, resume just echoes the local (fresh) checkpoint', () async {
      final dispatcher = CommandDispatcher();
      final result =
          await dispatcher.dispatch(_envelope('control.resume', {'session_id': 's1'}));
      expect(result['checkpoint'], {'completed_steps': 0});
    });

    test(
        'a server_checkpoint AHEAD of local state (e.g. after an app restart) is adopted',
        () async {
      final dispatcher = CommandDispatcher();
      final result = await dispatcher.dispatch(_envelope('control.resume', {
        'session_id': 's1',
        'server_checkpoint': {'completed_steps': 12, 'last_action': 'files.write'},
      }));
      expect(result['checkpoint'], {'completed_steps': 12, 'last_action': 'files.write'});
    });

    test('a server_checkpoint BEHIND local progress never moves the device backward', () async {
      final dispatcher = CommandDispatcher();
      // Advance local progress with a couple of real (non-control)
      // actions. `background.keepalive` is used deliberately — it's a
      // pure in-memory action (no native platform channel call), so it
      // works in this widget test without mocking any platform channel.
      final keepalive = CommandEnvelope(
        protocolVersion: CommandEnvelope.currentProtocolVersion,
        requestId: 'r1',
        apiKeyId: 'key_1',
        capability: 'background',
        action: 'background.keepalive',
        params: {'session_id': 's1'},
      );
      await dispatcher.dispatch(keepalive);
      await dispatcher.dispatch(keepalive);
      expect(dispatcher.currentStepFor('s1'), 2);

      // Server's view is stale (e.g. its last task_progress event hasn't
      // arrived/processed yet) — must NOT roll the device back to step 1.
      final result = await dispatcher.dispatch(_envelope('control.resume', {
        'session_id': 's1',
        'server_checkpoint': {'completed_steps': 1},
      }));
      expect(result['checkpoint'], {'completed_steps': 2});
    });

    test('resume sets local status back to RUNNING so subsequent actions are not gated', () async {
      final dispatcher = CommandDispatcher();
      await dispatcher.dispatch(_envelope('control.pause', {'session_id': 's1'}));
      expect(() => dispatcher.checkTaskGate('s1'), throwsA(isA<TaskPausedException>()));

      await dispatcher.dispatch(_envelope('control.resume', {'session_id': 's1'}));
      expect(() => dispatcher.checkTaskGate('s1'), returnsNormally);
    });
  });
}
