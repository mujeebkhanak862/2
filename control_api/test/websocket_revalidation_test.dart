import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/websocket/handlers.dart';

/// Fake WebSocket: sirf wahi cheezein record karta hai jo yahan chahiye
/// (close code/reason aur add() kiye gaye frames). Real socket/network
/// nahi — isliye yeh sirf AppState ki revalidation logic test karta hai.
class _FakeSink implements WebSocketSink {
  int? closeCode;
  String? closeReason;
  final List<dynamic> added = [];
  @override
  void add(dynamic data) => added.add(data);
  @override
  Future close([int? code, String? reason]) async {
    closeCode = code;
    closeReason = reason;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWs implements WebSocketChannel {
  @override
  final _FakeSink sink = _FakeSink();
  bool get closed => sink.closeCode != null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Device _device(String id, String hash) => Device(
      id: id,
      name: 'dev-$id',
      bearerTokenHash: hash,
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

ApiKeyRecord _key(String keyId, String deviceId,
        {bool enabled = true, DateTime? expiresAt}) =>
    ApiKeyRecord(
      keyId: keyId,
      deviceId: deviceId,
      label: 'k',
      scope: const ApiKeyScope(screenView: true),
      createdAt: DateTime.now().toUtc(),
      secretHash: 'h-$keyId',
      enabled: enabled,
      expiresAt: expiresAt,
    );

/// state + dev_1 + sess_1(owned by dev_1) + ek API-key listener.
({AppState state, _FakeWs ws, ApiKeyRecord key}) _setupKeyListener() {
  final state = AppState();
  state.devices['dev_1'] = _device('dev_1', 'hash1');
  state.sessionToDevice['sess_1'] = 'dev_1';
  final key = _key('key_1', 'dev_1');
  state.apiKeys['key_1'] = key;
  final ws = _FakeWs();
  state.registerListener(
      ws, const WsListenerOwner(sessionId: 'sess_1', sessionDeviceId: 'dev_1', apiKeyId: 'key_1'));
  state.sessionListeners['sess_1'] = {ws};
  return (state: state, ws: ws, key: key);
}

void main() {
  group('open WS listeners are re-validated after connect', () {
    test('a still-valid API key listener stays open', () {
      final s = _setupKeyListener();
      expect(s.state.revalidateListeners(), 0);
      expect(s.ws.closed, isFalse);
    });

    test('disabling the API key closes its open socket', () {
      final s = _setupKeyListener();
      s.key.enabled = false;
      expect(s.state.revalidateListeners(), 1);
      expect(s.ws.closed, isTrue);
      expect(s.state.sessionListeners['sess_1'], isEmpty);
      expect(s.state.listenerOwners, isEmpty);
    });

    test('deleting (revoking) the API key closes its open socket', () {
      final s = _setupKeyListener();
      s.state.apiKeys.remove('key_1');
      expect(s.state.revalidateListeners(), 1);
      expect(s.ws.closed, isTrue);
    });

    test('an API key that expires while connected is closed', () {
      final state = AppState();
      state.devices['dev_1'] = _device('dev_1', 'hash1');
      state.sessionToDevice['sess_1'] = 'dev_1';
      state.apiKeys['key_1'] =
          _key('key_1', 'dev_1', expiresAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)));
      final ws = _FakeWs();
      state.registerListener(ws,
          const WsListenerOwner(sessionId: 'sess_1', sessionDeviceId: 'dev_1', apiKeyId: 'key_1'));
      state.screenListeners['sess_1'] = {ws};
      expect(state.revalidateListeners(), 1);
      expect(ws.closed, isTrue);
      expect(state.screenListeners['sess_1'], isEmpty);
    });

    test('rotating the device token closes a socket authenticated with the old token', () {
      final state = AppState();
      final d = _device('dev_1', 'hash1');
      state.devices['dev_1'] = d;
      state.sessionToDevice['sess_1'] = 'dev_1';
      final ws = _FakeWs();
      state.registerListener(
          ws,
          const WsListenerOwner(
              sessionId: 'sess_1',
              sessionDeviceId: 'dev_1',
              principalDeviceId: 'dev_1',
              principalTokenHash: 'hash1'));
      expect(state.revalidateListeners(), 0);
      d.bearerTokenHash = 'hash2'; // rotate
      expect(state.revalidateListeners(), 1);
      expect(ws.closed, isTrue);
    });

    test('unpairing the device closes its sessions\' listeners', () async {
      final s = _setupKeyListener();
      await s.state.removeDevice('dev_1');
      expect(s.ws.closed, isTrue);
    });
  });

  group('device -> server frame validation', () {
    AppState withScreenListener(_FakeWs ws) {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      state.screenListeners['sess_1'] = {ws};
      return state;
    }

    test('a normal string frame from the owning device is forwarded', () {
      final ws = _FakeWs();
      final state = withScreenListener(ws);
      handleAgentMessage(state, 'dev_1', {'kind': 'screen_frame', 'session_id': 'sess_1', 'data': 'AAAA'});
      expect(ws.sink.added, ['AAAA']);
    });

    test('a non-string frame is dropped', () {
      final ws = _FakeWs();
      final state = withScreenListener(ws);
      handleAgentMessage(state, 'dev_1', {'kind': 'screen_frame', 'session_id': 'sess_1', 'data': {'x': 1}});
      expect(ws.sink.added, isEmpty);
    });

    test('an oversized frame is dropped', () {
      final ws = _FakeWs();
      final state = withScreenListener(ws);
      handleAgentMessage(state, 'dev_1', {
        'kind': 'screen_frame',
        'session_id': 'sess_1',
        'data': 'A' * (maxAgentMessageChars + 1),
      });
      expect(ws.sink.added, isEmpty);
    });

    test('a frame from a device that does NOT own the session is dropped', () {
      final ws = _FakeWs();
      final state = withScreenListener(ws);
      handleAgentMessage(state, 'dev_2', {'kind': 'screen_frame', 'session_id': 'sess_1', 'data': 'AAAA'});
      expect(ws.sink.added, isEmpty);
    });
  });
}
