import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/models/task.dart';
import 'package:control_api/routes/commands.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/websocket/handlers.dart';

/// Stage 9 follow-ups: device-reported task result, screen-idle signal, aur
/// `/commands` route-level lifecycle (pause/resume, rollback, timeout, scope).
/// Real sockets nahi — fake WebSocketChannel; route seedha Router.call se.

class _Sink implements WebSocketSink {
  final List<String> sent = [];
  void Function(Map<String, dynamic> msg)? onCommand;
  @override
  void add(dynamic data) {
    final s = data as String;
    sent.add(s);
    final m = jsonDecode(s) as Map<String, dynamic>;
    if (m['kind'] == 'command') onCommand?.call(m);
  }

  @override
  Future close([int? code, String? reason]) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ws implements WebSocketChannel {
  @override
  final _Sink sink = _Sink();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Device _device(String id) => Device(
      id: id,
      name: 'dev-$id',
      bearerTokenHash: 'h-$id',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

ApiKeyRecord _key({bool touchInput = true}) => ApiKeyRecord(
      keyId: 'key_1',
      deviceId: 'dev_1',
      label: 'k',
      scope: ApiKeyScope(touchInput: touchInput),
      createdAt: DateTime.now().toUtc(),
      secretHash: 'h',
    );

AppState _stateWithRunningTask() {
  final state = AppState();
  state.devices['dev_1'] = _device('dev_1');
  state.sessionToDevice['t1'] = 'dev_1';
  state.tasks['t1'] = TaskRecord(
    taskId: 't1',
    deviceId: 'dev_1',
    originatingCapability: 'input',
    state: TaskState.running,
  );
  return state;
}

Future<Response> _post(AppState state, ApiKeyRecord key, String action,
    {String requestId = 'r1', int? timeoutMs}) {
  final router = commandRoutes(state);
  return Future.sync(() => router.call(Request(
        'POST',
        Uri.parse('http://localhost/commands'),
        headers: {'content-type': 'application/json'},
        context: {'apiKey': key},
        body: jsonEncode({
          'protocol_version': '1.0',
          'request_id': requestId,
          'api_key_id': key.keyId,
          'capability': 'control',
          'action': action,
          'params': {'session_id': 't1'},
          if (timeoutMs != null) 'timeout_ms': timeoutMs,
        }),
      )));
}

/// Device jo har command ka turant OK deta hai.
_Ws _ackingDevice(AppState state) {
  final ws = _Ws();
  ws.sink.onCommand = (m) {
    final id = m['request_id'] as String;
    scheduleMicrotask(() => state.pendingCommands[id]?.complete({'ok': true}));
  };
  state.deviceConnections['dev_1'] = ws;
  return ws;
}

void main() {
  group('device-reported task result (task_result event)', () {
    Map<String, dynamic> ev(String st, {String? reason}) => {
          'kind': 'event',
          'type': 'task_result',
          'session_id': 't1',
          'state': st,
          if (reason != null) 'reason': reason,
        };

    test('owning device can complete a RUNNING task', () {
      final s = _stateWithRunningTask();
      handleAgentMessage(s, 'dev_1', ev('completed'));
      expect(s.tasks['t1']!.state, TaskState.completed);
    });

    test('owning device can fail a task with a reason', () {
      final s = _stateWithRunningTask();
      handleAgentMessage(s, 'dev_1', ev('failed', reason: 'tap target missing'));
      expect(s.tasks['t1']!.state, TaskState.failed);
      expect(s.tasks['t1']!.terminalReason, 'tap target missing');
    });

    test('another device cannot end the task', () {
      final s = _stateWithRunningTask();
      handleAgentMessage(s, 'dev_2', ev('completed'));
      expect(s.tasks['t1']!.state, TaskState.running);
    });

    test('unknown state value is ignored', () {
      final s = _stateWithRunningTask();
      handleAgentMessage(s, 'dev_1', ev('exploded'));
      expect(s.tasks['t1']!.state, TaskState.running);
    });

    test('an already-terminal task is not changed again', () {
      final s = _stateWithRunningTask();
      s.tasks['t1']!.state = TaskState.stopped;
      handleAgentMessage(s, 'dev_1', ev('completed'));
      expect(s.tasks['t1']!.state, TaskState.stopped);
    });
  });

  group('screen idle signal (last viewer leaves)', () {
    AppState setup(_Ws device, _Ws viewer) {
      final s = AppState()..screenIdleGrace = const Duration(milliseconds: 20);
      s.sessionToDevice['t1'] = 'dev_1';
      s.deviceConnections['dev_1'] = device;
      s.screenListeners['t1'] = {viewer};
      return s;
    }

    test('device gets screen_idle after the grace period', () async {
      final device = _Ws(), viewer = _Ws();
      final s = setup(device, viewer);
      s.unregisterListener(viewer);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(device.sink.sent.any((m) => m.contains('"screen_idle"')), isTrue);
    });

    test('a viewer re-attaching within the grace cancels the signal', () async {
      final device = _Ws(), viewer = _Ws();
      final s = setup(device, viewer);
      s.unregisterListener(viewer);
      s.screenViewerAttached('t1');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(device.sink.sent, isEmpty);
    });
  });

  group('POST /commands task lifecycle (route-level, fake device)', () {
    test('control.pause with an acking device => 200 and task PAUSED', () async {
      final s = _stateWithRunningTask();
      _ackingDevice(s);
      final res = await _post(s, _key(), 'control.pause');
      expect(res.statusCode, 200);
      expect(s.tasks['t1']!.state, TaskState.paused);
    });

    test('invalid transition (resume a RUNNING task) is rejected, nothing sent to device',
        () async {
      final s = _stateWithRunningTask();
      final ws = _ackingDevice(s);
      final res = await _post(s, _key(), 'control.resume');
      expect(res.statusCode, 400);
      expect(ws.sink.sent, isEmpty);
      expect(s.tasks['t1']!.state, TaskState.running);
    });

    test('device OFFLINE: transition is rolled back to RUNNING', () async {
      final s = _stateWithRunningTask(); // no deviceConnections entry
      final res = await _post(s, _key(), 'control.pause');
      expect(res.statusCode, isNot(200));
      expect(s.tasks['t1']!.state, TaskState.running);
    });

    test('key without the originating capability scope => 403, state untouched',
        () async {
      final s = _stateWithRunningTask();
      _ackingDevice(s);
      final res = await _post(s, _key(touchInput: false), 'control.pause');
      expect(res.statusCode, 403);
      expect(s.tasks['t1']!.state, TaskState.running);
    });

    test('control.complete is server-only: task COMPLETED, nothing sent to device',
        () async {
      final s = _stateWithRunningTask();
      final ws = _ackingDevice(s);
      final res = await _post(s, _key(), 'control.complete');
      expect(res.statusCode, 200);
      expect(s.tasks['t1']!.state, TaskState.completed);
      expect(ws.sink.sent.any((m) => m.contains('"kind":"command"')), isFalse);
    });

    test('TIMEOUT keeps the transition (outcome unknown) and re-syncs the device',
        () async {
      final s = _stateWithRunningTask();
      final ws = _Ws(); // command lega par kabhi jawab nahi dega
      s.deviceConnections['dev_1'] = ws;
      final res = await _post(s, _key(), 'control.pause', timeoutMs: 1000);
      expect(res.statusCode, isNot(200));
      expect(s.tasks['t1']!.state, TaskState.paused);
      expect(ws.sink.sent.any((m) => m.contains('"task_state"')), isTrue);
    });
  });
}
