// Stage 3 backend correctness tests (items 39-51).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:control_api/ai_tools/ai_tool_registry.dart';
import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/models/task.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/storage/persistence.dart';
import 'package:control_api/util/crypto_utils.dart';
import 'package:control_api/validation/schema_validator.dart';
import 'package:control_api/websocket/handlers.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeSink implements WebSocketSink {
  final List<dynamic> added = [];
  bool closed = false;
  @override
  void add(dynamic event) => added.add(event);
  @override
  Future<void> close([int? closeCode, String? closeReason]) async => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWs implements WebSocketChannel {
  @override
  final _FakeSink sink = _FakeSink();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Device _device(String id, {DateTime? lastSeen, String state = 'ONLINE_UNLOCKED'}) => Device(
      id: id,
      name: id,
      bearerTokenHash: hashSecretUtil('t_$id'),
      platform: 'android',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: lastSeen ?? DateTime.now().toUtc(),
      state: state,
    );

void main() {
  group('Persistence robustness (items 40-43)', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('uda_persist_');
      file = File('${dir.path}/state.json');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    AppState populated() {
      final s = AppState();
      s.devices['A'] = _device('A');
      s.devices['B'] = _device('B');
      s.tasks['t1'] = TaskRecord(
          taskId: 't1', deviceId: 'A', originatingCapability: 'files');
      return s;
    }

    test('one bad record is skipped, the rest load, original is backed up', () async {
      await Persistence(populated(), fileOverride: file).save();
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      (json['devices'] as List)[1].remove('paired_at'); // device B corrupt
      file.writeAsStringSync(jsonEncode(json));

      final s2 = AppState();
      await Persistence(s2, fileOverride: file).load();

      expect(s2.devices.keys, ['A']);
      expect(s2.tasks.containsKey('t1'), isTrue);
      final backups = dir.listSync().whereType<File>().where((f) => f.path.contains('.partial-'));
      expect(backups, isNotEmpty);
    });

    test('sessionToDevice is rebuilt from tasks and devices start OFFLINE', () async {
      await Persistence(populated(), fileOverride: file).save();
      final s2 = AppState();
      await Persistence(s2, fileOverride: file).load();
      expect(s2.sessionToDevice['t1'], 'A');
      expect(s2.devices.values.every((d) => d.state == 'OFFLINE'), isTrue);
    });

    test('wholly corrupt file is backed up and does not crash; save still works', () async {
      file.writeAsStringSync('this is not json');
      final s = AppState();
      final p = Persistence(s, fileOverride: file);
      await p.load();
      expect(p.loadFailed, isTrue);
      expect(p.saveBlocked, isFalse);
      expect(dir.listSync().whereType<File>().any((f) => f.path.contains('.corrupt-')), isTrue);
      s.devices['A'] = _device('A');
      await p.save();
      expect(jsonDecode(file.readAsStringSync()), isA<Map>());
    });

    test('many concurrent saves coalesce, file stays valid, no tmp leftovers', () async {
      final s = populated();
      final p = Persistence(s, fileOverride: file);
      await Future.wait(List.generate(25, (_) => p.save()));
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((decoded['devices'] as List).length, 2);
      expect(dir.listSync().whereType<File>().where((f) => f.path.contains('.tmp.')), isEmpty);
    });

    test('latest mutation is always persisted by a following save()', () async {
      final s = populated();
      final p = Persistence(s, fileOverride: file);
      final first = p.save();
      s.devices['C'] = _device('C');
      await Future.wait([first, p.save()]);
      final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((decoded['devices'] as List).length, 3);
    });
  });

  group('stale device sweeper (item 43)', () {
    test('silent connected devices are closed and marked OFFLINE', () {
      final s = AppState();
      final now = DateTime.now().toUtc();
      s.devices['fresh'] = _device('fresh', lastSeen: now);
      s.devices['stale'] = _device('stale', lastSeen: now.subtract(const Duration(minutes: 5)));
      final freshWs = _FakeWs();
      final staleWs = _FakeWs();
      s.deviceConnections['fresh'] = freshWs;
      s.deviceConnections['stale'] = staleWs;

      final swept = s.sweepStaleDevices(now: now);

      expect(swept, ['stale']);
      expect(staleWs.sink.closed, isTrue);
      expect(s.devices['stale']!.state, 'OFFLINE');
      expect(s.deviceConnections.containsKey('stale'), isFalse);
      expect(freshWs.sink.closed, isFalse);
      expect(s.devices['fresh']!.state, 'ONLINE_UNLOCKED');
    });
  });

  group('sendCommandToDevice (items 44, 49)', () {
    late AppState s;
    late _FakeWs ws;
    setUp(() {
      s = AppState();
      ws = _FakeWs();
      s.devices['A'] = _device('A');
      s.deviceConnections['A'] = ws;
    });

    Map<String, dynamic> env(String id) => {'request_id': id, 'action': 'x'};

    test('duplicate in-flight request_id is rejected; first still completes', () async {
      final first = s.sendCommandToDevice('A', env('r1'), timeout: const Duration(seconds: 2));
      await expectLater(
        s.sendCommandToDevice('A', env('r1')),
        throwsA(isA<DuplicateRequestException>()),
      );
      handleAgentMessage(s, 'A', {
        'kind': 'command_result',
        'request_id': 'r1',
        'result': {'ok': true},
      });
      expect(await first, {'ok': true});
      expect(s.pendingCommands, isEmpty);
      expect(s.pendingCommandDevice, isEmpty);
    });

    test('real timeouts surface as TimeoutException and clean up', () async {
      await expectLater(
        s.sendCommandToDevice('A', env('r2'), timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      expect(s.pendingCommands, isEmpty);
    });

    test('offline device -> StateError (not a timeout)', () async {
      s.deviceConnections.clear();
      await expectLater(s.sendCommandToDevice('A', env('r3')), throwsA(isA<StateError>()));
    });
  });

  group('AI tool registry exposes control tools (item 46)', () {
    final device = _device('A');

    test('keys with a task capability see pause/resume/stop/complete/fail but not switch', () {
      final tools = buildAiTools(
          device: device, scope: const ApiKeyScope(files: true), customManifests: const []);
      final names = tools.map((t) => t.name).toSet();
      for (final n in ['control.pause', 'control.resume', 'control.stop', 'control.complete', 'control.fail']) {
        expect(names, contains(n));
      }
      expect(names, isNot(contains('control.switch')));
    });

    test('an empty scope still sees nothing', () {
      final tools = buildAiTools(
          device: device, scope: const ApiKeyScope(), customManifests: const []);
      expect(tools, isEmpty);
    });
  });

  group('upload body limit (item 39)', () {
    String envelopeJson(String action, String capability, int payloadChars) => jsonEncode({
          'protocol_version': '1.0',
          'request_id': 'r',
          'api_key_id': 'k',
          'capability': capability,
          'action': action,
          'params': {'path': '/sdcard/a.txt'},
          'payload': 'A' * payloadChars,
        });

    test('files.write may exceed 2 MiB (up to the upload ceiling)', () {
      final body = envelopeJson('files.write', 'files', 3 * 1024 * 1024);
      final r = validateRawBody(body, utf8.encode(body).length);
      expect(r.error?.kind, isNot('PAYLOAD_TOO_LARGE'));
    });

    test('non-upload actions are still capped at 2 MiB', () {
      final body = envelopeJson('files.list', 'files', 3 * 1024 * 1024);
      final r = validateRawBody(body, utf8.encode(body).length);
      expect(r.isValid, isFalse);
      expect(r.error!.kind, 'PAYLOAD_TOO_LARGE');
    });

    test('anything above the upload ceiling is rejected', () {
      final r = validateRawBody('{"action":"files.write"}', maxUploadRequestBodyBytes + 1);
      expect(r.error!.kind, 'PAYLOAD_TOO_LARGE');
    });
  });
}
