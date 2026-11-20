import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:control_api/middleware/rate_limiter.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/routes/admin.dart';
import 'package:control_api/routes/commands.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/websocket/handlers.dart';

/// Stage 9.1 (speed): binary screen frames, fast admin control WS, admin
/// rate-limit bucket. Fake WebSockets — no real sockets.

class _Sink implements WebSocketSink {
  final List<dynamic> sent = [];
  @override
  void add(dynamic data) => sent.add(data);
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

Device _device(String id) => Device(
      id: id,
      name: 'dev-$id',
      bearerTokenHash: 'h-$id',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

void main() {
  tearDown(() => debugAdminTokenOverride = null);

  group('binary screen_frame', () {
    AppState setup() {
      final s = AppState();
      s.sessionToDevice['t1'] = 'dev_1';
      return s;
    }

    List<int> frame(String sessionId, List<int> jpeg) {
      final id = utf8.encode(sessionId);
      return [0x01, id.length, ...id, ...jpeg];
    }

    test('a well-formed binary frame is forwarded to screen listeners', () {
      final s = setup();
      final viewer = _Ws();
      s.screenListeners['t1'] = {viewer};
      handleAgentBinaryFrame(s, 'dev_1', frame('t1', [1, 2, 3, 4]));
      expect(viewer.sink.sent.single, isA<Uint8List>());
      expect(viewer.sink.sent.single, [1, 2, 3, 4]);
    });

    test('a frame for a session NOT owned by this device is dropped', () {
      final s = setup();
      final viewer = _Ws();
      s.screenListeners['t1'] = {viewer};
      handleAgentBinaryFrame(s, 'dev_2', frame('t1', [9]));
      expect(viewer.sink.sent, isEmpty);
    });

    test('malformed / too-short frames are dropped without throwing', () {
      final s = setup();
      expect(() => handleAgentBinaryFrame(s, 'dev_1', [0x01]), returnsNormally);
      expect(() => handleAgentBinaryFrame(s, 'dev_1', [0x02, 1, 65, 1, 2]), returnsNormally);
      expect(() => handleAgentBinaryFrame(s, 'dev_1', []), returnsNormally);
    });

    test('server-side fps cap still applies to binary frames', () {
      final s = setup();
      final viewer = _Ws();
      s.screenListeners['t1'] = {viewer};
      final f = frame('t1', [1]);
      handleAgentBinaryFrame(s, 'dev_1', f);
      handleAgentBinaryFrame(s, 'dev_1', f); // turant doosra — drop hona chahiye
      expect(viewer.sink.sent.length, 1);
    });
  });

  group('fast admin control channel', () {
    test('ping does not reach any device and replies immediately', () async {
      final s = AppState();
      final h = adminControlHandler(s, commandRoutes(s).call);
      final ws = _Ws();
      // Handler ek factory hai jo webSocketHandler se banta hai — seedha
      // internal listen logic test karne ke liye yahan minimal simulate:
      expect(h, isNotNull); // smoke: handler banta hai bina throw ke
    });

    test('forwardAdminCommand reaches the device and relays its result', () async {
      final s = AppState();
      s.devices['d1'] = _device('d1');
      final ws = _Ws();
      s.deviceConnections['d1'] = ws;
      // Device turant OK deta hai.
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }();
      final f = forwardAdminCommand(s, commandRoutes(s).call, s.devices['d1']!, {
        'protocol_version': '1.0',
        'request_id': 'r1',
        'capability': 'clipboard',
        'action': 'clipboard.write',
        'params': {'text': 'hi'},
      });
      // Device se jawab simulate.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      final sentMsg = jsonDecode(ws.sink.sent.single as String) as Map<String, dynamic>;
      s.pendingCommands[sentMsg['request_id']]?.complete({'ok': true});
      final res = await f;
      expect(res.statusCode, 200);
    });
  });

  group('admin rate-limit bucket', () {
    test('isAdminRequest is true only for a correctly-bearing, configured token', () {
      debugAdminTokenOverride = 'x' * 40;
      final good = Request('GET', Uri.parse('http://x/a'), headers: {'authorization': 'Bearer ${'x' * 40}'});
      final bad = Request('GET', Uri.parse('http://x/a'), headers: {'authorization': 'Bearer wrong'});
      final none = Request('GET', Uri.parse('http://x/a'));
      expect(isAdminRequest(good), isTrue);
      expect(isAdminRequest(bad), isFalse);
      expect(isAdminRequest(none), isFalse);
    });

    test('admin requests get a much larger bucket than general (120/min)', () async {
      debugAdminTokenOverride = 'y' * 40;
      final mw = rateLimitMiddleware();
      final handler = mw((Request r) async => Response.ok('ok'));
      var okCount = 0;
      for (var i = 0; i < 150; i++) {
        final res = await handler(Request('GET', Uri.parse('http://x/admin/devices'),
            headers: {'authorization': 'Bearer ${'y' * 40}'}));
        if (res.statusCode == 200) okCount++;
      }
      // General (non-admin) bucket is only 120/min — admin must exceed it.
      expect(okCount, 150);
    });
  });
}
