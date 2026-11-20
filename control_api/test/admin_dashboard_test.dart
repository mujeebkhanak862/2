import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:control_api/models/device.dart';
import 'package:control_api/models/task.dart';
import 'package:control_api/routes/admin.dart';
import 'package:control_api/routes/commands.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/websocket/handlers.dart';

/// Web dashboard backend: admin token, device list, command forwarding,
/// browser WebSocket tickets, CORS. (Fake WebSocket devices; no real sockets.)

const _token = 'a' * 40;

class _Sink implements WebSocketSink {
  final List<String> sent = [];
  void Function(Map<String, dynamic>)? onCommand;
  @override
  void add(dynamic data) {
    sent.add(data as String);
    final m = jsonDecode(data) as Map<String, dynamic>;
    if (m['kind'] == 'command') onCommand?.call(m);
  }

  @override
  Future close([int? code, String? reason]) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Ws implements WebSocketChannel {
  @override
  final _Sink sink = _Sink();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Device _device(String id, String name) => Device(
      id: id,
      name: name,
      bearerTokenHash: 'h-$id',
      platform: 'android',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

Handler _handler(AppState s) => adminRoutes(s, commandRoutes(s).call).call;

Request _req(String method, String path, {String? token, String? body}) => Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: body ?? '',
    );

void main() {
  tearDown(() => debugAdminTokenOverride = null);

  group('admin auth', () {
    test('admin API is disabled (404) when no ADMIN_TOKEN is configured', () async {
      debugAdminTokenOverride = null;
      final res = await _handler(AppState())(_req('GET', '/admin/devices', token: _token));
      expect(res.statusCode, 404);
    });

    test('a too-short ADMIN_TOKEN counts as not configured', () async {
      debugAdminTokenOverride = 'short';
      final res = await _handler(AppState())(_req('GET', '/admin/devices', token: 'short'));
      expect(res.statusCode, 404);
    });

    test('wrong / missing token => 401', () async {
      debugAdminTokenOverride = _token;
      final h = _handler(AppState());
      expect((await h(_req('GET', '/admin/devices', token: 'b' * 40))).statusCode, 401);
      expect((await h(_req('GET', '/admin/devices'))).statusCode, 401);
    });
  });

  group('device list', () {
    test('lists every paired device with connection + active task info', () async {
      debugAdminTokenOverride = _token;
      final s = AppState();
      s.devices['d1'] = _device('d1', 'Phone A');
      s.devices['d2'] = _device('d2', 'PC B');
      s.deviceConnections['d1'] = _Ws();
      s.tasks['t1'] = TaskRecord(
          taskId: 't1', deviceId: 'd1', originatingCapability: 'screen', state: TaskState.running);
      final res = await _handler(s)(_req('GET', '/admin/devices', token: _token));
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      final list = (body['devices'] as List).cast<Map<String, dynamic>>();
      expect(list.length, 2);
      expect(list.first['id'], 'd1'); // connected pehle
      expect(list.first['connected'], true);
      expect(list.first['active_task_count'], 1);
      expect(list.last['connected'], false);
    });
  });

  group('commands via admin', () {
    test('forwards a command to the chosen device and returns its result', () async {
      debugAdminTokenOverride = _token;
      final s = AppState();
      s.devices['d1'] = _device('d1', 'Phone A');
      final ws = _Ws();
      ws.sink.onCommand = (m) {
        final id = m['request_id'] as String;
        scheduleMicrotask(() => s.pendingCommands[id]?.complete({'ok': true}));
      };
      s.deviceConnections['d1'] = ws;
      final res = await _handler(s)(_req('POST', '/admin/devices/d1/commands',
          token: _token,
          body: jsonEncode({
            'protocol_version': '1.0',
            'request_id': 'r1',
            'api_key_id': 'x',
            'capability': 'clipboard',
            'action': 'clipboard.write',
            'params': {'text': 'hello'},
          })));
      expect(res.statusCode, 200);
      expect(ws.sink.sent.any((m) => m.contains('clipboard.write')), isTrue);
    });

    test('unknown device => 404; no token => 401', () async {
      debugAdminTokenOverride = _token;
      final h = _handler(AppState());
      expect((await h(_req('POST', '/admin/devices/nope/commands', token: _token, body: '{}'))).statusCode, 404);
      expect((await h(_req('POST', '/admin/devices/nope/commands', body: '{}'))).statusCode, 401);
    });
  });

  group('browser WebSocket tickets', () {
    test('ticket is single-use', () {
      final s = AppState();
      final t = s.issueWsTicket();
      expect(s.consumeWsTicket(t), isTrue);
      expect(s.consumeWsTicket(t), isFalse);
    });

    test('unknown ticket is rejected', () {
      expect(AppState().consumeWsTicket('nope'), isFalse);
    });

    test('POST /admin/ws-ticket needs the admin token', () async {
      debugAdminTokenOverride = _token;
      final h = _handler(AppState());
      expect((await h(_req('POST', '/admin/ws-ticket'))).statusCode, 401);
      final ok = await h(_req('POST', '/admin/ws-ticket', token: _token));
      expect(ok.statusCode, 200);
      expect(jsonDecode(await ok.readAsString())['ticket'], isA<String>());
    });

    test('a valid ticket lets /screen authorize a known session; unknown session is 404', () {
      final s = AppState();
      s.sessionToDevice['sess_1'] = 'd1';
      final req = applyWsTicket(
          Request('GET', Uri.parse('http://x/screen/sess_1?ticket=${s.issueWsTicket()}')), s);
      expect(authorizeSessionConnection(req, s, 'sess_1'), isNull);
      final req2 = applyWsTicket(
          Request('GET', Uri.parse('http://x/screen/zzz?ticket=${s.issueWsTicket()}')), s);
      expect(authorizeSessionConnection(req2, s, 'zzz')!.statusCode, 404);
    });

    test('no ticket and no credentials => 401', () {
      final s = AppState();
      s.sessionToDevice['sess_1'] = 'd1';
      final req = applyWsTicket(Request('GET', Uri.parse('http://x/screen/sess_1')), s);
      expect(authorizeSessionConnection(req, s, 'sess_1')!.statusCode, 401);
    });
  });

  group('CORS', () {
    final h = corsMiddleware({'https://site.example'})(
        (Request r) => Response.ok('x'));

    test('allowed origin gets CORS headers', () async {
      final res = await h(Request('GET', Uri.parse('http://x/a'),
          headers: {'origin': 'https://site.example'}));
      expect(res.headers['access-control-allow-origin'], 'https://site.example');
    });

    test('preflight from an allowed origin => 204', () async {
      final res = await h(Request('OPTIONS', Uri.parse('http://x/a'),
          headers: {'origin': 'https://site.example'}));
      expect(res.statusCode, 204);
    });

    test('other origins get no CORS header and preflight is refused', () async {
      final res = await h(Request('GET', Uri.parse('http://x/a'),
          headers: {'origin': 'https://evil.example'}));
      expect(res.headers.containsKey('access-control-allow-origin'), isFalse);
      final pre = await h(Request('OPTIONS', Uri.parse('http://x/a'),
          headers: {'origin': 'https://evil.example'}));
      expect(pre.statusCode, 403);
    });
  });
}
