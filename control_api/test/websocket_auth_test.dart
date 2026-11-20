import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/websocket/handlers.dart';

/// P0 SECURITY FIX tests (audit Section 7 / Section 13 #1):
/// `/devices/{id}/agent`, `/sessions/{id}` aur `/screen/{id}` — WS
/// handshake se pehle in helper functions se authorization guzarni
/// chahiye. Yahan `webSocketHandler` ko actually invoke nahi karte
/// (usko real socket chahiye) — sirf woh authorization logic test karte
/// hain jo router.get callbacks mein handshake se PEHLE chalta hai
/// (`authorizeDeviceAgentConnection` / `authorizeSessionConnection`),
/// kyunki yehi woh jagah hai jahan pehle koi check tha hi nahi.
Request _req({Map<String, Object> context = const {}}) =>
    Request('GET', Uri.parse('http://localhost/x'), context: context);

Device _device(String id, {String token = 'tok'}) => Device(
      id: id,
      name: 'dev-$id',
      bearerTokenHash: 'irrelevant-for-these-tests',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

ApiKeyRecord _apiKey(String deviceId,
        {ApiKeyScope scope = const ApiKeyScope(screenView: true), bool enabled = true}) =>
    ApiKeyRecord(
      keyId: 'key_1',
      deviceId: deviceId,
      label: 'test key',
      scope: scope,
      createdAt: DateTime.now().toUtc(),
      secretHash: 'irrelevant',
      enabled: enabled,
    );

void main() {
  group('/devices/{id}/agent authorization (P0 fix)', () {
    test('missing token (no context at all) is rejected', () {
      final state = AppState();
      final result = authorizeDeviceAgentConnection(_req(), state, 'dev_1');
      expect(result, isNotNull);
      expect(result!.statusCode, 401);
    });

    test('an API key (not a device token) is rejected — this is a device-only channel', () {
      final state = AppState();
      final key = _apiKey('dev_1');
      final result = authorizeDeviceAgentConnection(
          _req(context: {'apiKey': key}), state, 'dev_1');
      expect(result, isNotNull);
      expect(result!.statusCode, 401);
    });

    test('a valid device token for a DIFFERENT device id is rejected (wrong device token)', () {
      final state = AppState();
      final device = _device('dev_1');
      final result = authorizeDeviceAgentConnection(
          _req(context: {'device': device}), state, 'dev_2');
      expect(result, isNotNull);
      expect(result!.statusCode, 401);
    });

    test('the matching device\'s own token is authorized', () {
      final state = AppState();
      final device = _device('dev_1');
      final result = authorizeDeviceAgentConnection(
          _req(context: {'device': device}), state, 'dev_1');
      expect(result, isNull);
    });
  });

  group('/sessions/{id} and /screen/{id} authorization (P0 fix)', () {
    test('unknown session id WITH valid credentials is 404', () {
      final state = AppState();
      final device = _device('dev_1');
      final result = authorizeSessionConnection(
          _req(context: {'device': device}), state, 'no_such_session');
      expect(result, isNotNull);
      expect(result!.statusCode, 404);
    });

    test('no credentials is 401 for BOTH unknown and known sessions (no existence leak)', () {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      final unknown = authorizeSessionConnection(_req(), state, 'no_such_session');
      final known = authorizeSessionConnection(_req(), state, 'sess_1');
      expect(unknown!.statusCode, 401);
      expect(known!.statusCode, 401);
    });

    test('the owning device\'s own token is authorized', () {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      final device = _device('dev_1');
      final result = authorizeSessionConnection(
          _req(context: {'device': device}), state, 'sess_1');
      expect(result, isNull);
    });

    test('a device token for a DIFFERENT (non-owning) device is rejected', () {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      final otherDevice = _device('dev_2');
      final result = authorizeSessionConnection(
          _req(context: {'device': otherDevice}), state, 'sess_1');
      expect(result, isNotNull);
      expect(result!.statusCode, 403);
    });

    test('an API key scoped to the owning device WITH screen_view is authorized', () {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      final key = _apiKey('dev_1', scope: const ApiKeyScope(screenView: true));
      final result = authorizeSessionConnection(
          _req(context: {'apiKey': key}), state, 'sess_1');
      expect(result, isNull);
    });

    test('an API key scoped to the owning device WITHOUT screen_view is rejected (wrong scope)', () {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      final key = _apiKey('dev_1', scope: const ApiKeyScope(touchInput: true));
      final result = authorizeSessionConnection(
          _req(context: {'apiKey': key}), state, 'sess_1');
      expect(result, isNotNull);
      expect(result!.statusCode, 403);
    });

    test('an API key scoped to a DIFFERENT device is rejected even with screen_view', () {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      final key = _apiKey('dev_2', scope: const ApiKeyScope(screenView: true));
      final result = authorizeSessionConnection(
          _req(context: {'apiKey': key}), state, 'sess_1');
      expect(result, isNotNull);
      expect(result!.statusCode, 403);
    });

    test('a revoked (disabled) API key is rejected even with the right device + scope', () {
      final state = AppState();
      state.sessionToDevice['sess_1'] = 'dev_1';
      final key = _apiKey('dev_1', scope: const ApiKeyScope(screenView: true), enabled: false);
      final result = authorizeSessionConnection(
          _req(context: {'apiKey': key}), state, 'sess_1');
      expect(result, isNotNull);
      expect(result!.statusCode, 403);
    });
  });

  // NOTE: full duplicate-connection replacement (old socket actually
  // getting a close(4000, ...) frame, deviceConnections[id] pointing at
  // the newer socket, and the old socket's onDone NOT wiping out the
  // newer entry) needs a real WebSocketChannel pair and is exercised as
  // part of the platform/device test matrix (Section 13 #4/#6/#7), not
  // as a pure Dart unit test — `deviceAgentHandler` in
  // `lib/websocket/handlers.dart` is where that logic lives
  // (`identical(previous, webSocket)` guard on close, and
  // `identical(state.deviceConnections[deviceId], webSocket)` guard on
  // both onDone/onError).
}
