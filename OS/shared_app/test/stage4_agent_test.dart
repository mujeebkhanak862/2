// Stage 4: AgentConnection robustness (items 53-60).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/agent_connection.dart';
import 'package:shared_app/protocol/command_envelope.dart';

CommandEnvelope _env(String action, Map<String, dynamic> params,
        {String capability = 'control'}) =>
    CommandEnvelope(
      requestId: 'r',
      apiKeyId: 'k',
      capability: capability,
      action: action,
      params: params,
    );

void main() {
  group('fatalReasonForCloseCode (item 53)', () {
    test('deliberate server closes stop reconnecting', () {
      expect(fatalReasonForCloseCode(4000), 'replaced');
      expect(fatalReasonForCloseCode(4001), 'unpaired');
      expect(fatalReasonForCloseCode(4002), 'token_rotated');
    });
    test('heartbeat timeout and ordinary drops reconnect normally', () {
      expect(fatalReasonForCloseCode(4003), isNull);
      expect(fatalReasonForCloseCode(1006), isNull);
      expect(fatalReasonForCloseCode(null), isNull);
    });
  });

  group('isAuthFailure (item 53)', () {
    test('detects 401/403 in a WebSocketException', () {
      expect(isAuthFailure(const WebSocketException('not upgraded, HTTP status code: 401')), isTrue);
      expect(isAuthFailure(const WebSocketException('... 403 ...')), isTrue);
    });
    test('other errors are not auth failures', () {
      expect(isAuthFailure(const WebSocketException('connection refused')), isFalse);
      expect(isAuthFailure(const SocketException('x')), isFalse);
      expect(isAuthFailure(StateError('401')), isFalse);
    });
  });

  group('FrameThrottle (item 57)', () {
    test('drops frames faster than the FPS cap and passes spaced ones', () {
      final t = FrameThrottle(maxFps: 5); // 200ms
      final t0 = DateTime(2026, 1, 1, 12);
      expect(t.shouldSend(t0), isTrue);
      expect(t.shouldSend(t0.add(const Duration(milliseconds: 50))), isFalse);
      expect(t.shouldSend(t0.add(const Duration(milliseconds: 199))), isFalse);
      expect(t.shouldSend(t0.add(const Duration(milliseconds: 200))), isTrue);
      expect(t.shouldSend(t0.add(const Duration(milliseconds: 250))), isFalse);
    });
    test('default cap is a sane low fps', () {
      expect(liveStreamMaxFps, inInclusiveRange(2, liveStreamHardMaxFps));
    });
  });

  group('CommandDispatcher server task state (item 56)', () {
    test('COMPLETED/FAILED/STOPPED make the device reject further actions', () {
      for (final s in ['COMPLETED', 'FAILED', 'STOPPED']) {
        final d = CommandDispatcher();
        d.applyServerTaskState('s1', s);
        expect(() => d.checkTaskGate('s1'), throwsA(isA<TaskStoppedException>()), reason: s);
      }
    });
    test('PAUSED pauses, RUNNING resumes', () {
      final d = CommandDispatcher();
      d.applyServerTaskState('s1', 'PAUSED');
      expect(() => d.checkTaskGate('s1'), throwsA(isA<TaskPausedException>()));
      d.applyServerTaskState('s1', 'RUNNING');
      d.checkTaskGate('s1'); // no throw
    });
    test('unknown states are ignored', () {
      final d = CommandDispatcher();
      d.applyServerTaskState('s1', 'WHATEVER');
      d.checkTaskGate('s1');
    });
  });

  group('CommandDispatcher task map pruning (item 59)', () {
    test('old stopped tasks are pruned, active ones are never dropped', () async {
      final d = CommandDispatcher();
      d.applyServerTaskState('keep_running', 'RUNNING');
      d.applyServerTaskState('keep_paused', 'PAUSED');
      for (var i = 0; i < CommandDispatcher.maxTrackedTasks + 50; i++) {
        await d.dispatch(_env('control.stop', {'session_id': 'old_$i'}));
      }
      expect(d.trackedTaskCount, lessThanOrEqualTo(CommandDispatcher.maxTrackedTasks + 1));
      expect(() => d.checkTaskGate('keep_paused'), throwsA(isA<TaskPausedException>()));
      d.checkTaskGate('keep_running');
    });
  });

  group('AgentConnection.reportStatus before connect (item 60)', () {
    test('does not throw while the socket is null', () {
      final c = AgentConnection(
        wsBaseUrl: Uri.parse('ws://localhost:1'),
        deviceId: 'd',
        bearerToken: 't',
      );
      c.reportStatus(state: 'ONLINE_LOCKED', batteryPercent: 50);
      c.reportStatus(batteryPercent: 49, backgroundActive: true);
      c.disconnect();
    });
  });
}
