// Stage 2 server-side tests: owner routes, status_update extras, network.
import 'dart:convert';

import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/models/task.dart';
import 'package:control_api/routes/owner.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/util/crypto_utils.dart';
import 'package:control_api/util/http_utils.dart';
import 'package:control_api/websocket/handlers.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

Device _device(String id) => Device(
      id: id,
      name: id,
      bearerTokenHash: hashSecretUtil('t_$id'),
      platform: 'android',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

void main() {
  group('ownerKeyFor', () {
    test('grants every built-in scope + only this device\'s custom capabilities', () {
      final s = AppState();
      s.customCapabilityManifests.addAll([
        {'capability': 'mine', 'registered_by': 'A'},
        {'capability': 'theirs', 'registered_by': 'B'},
        {'capability': 'legacy'}, // registered_by nahi => sabke liye
      ]);
      final key = ownerKeyFor(s, _device('A'));
      expect(key.deviceId, 'A');
      expect(key.keyId, 'owner_A');
      expect(key.scope.screenView && key.scope.files && key.scope.location, isTrue);
      expect(key.scope.allowsCustomCapability('mine'), isTrue);
      expect(key.scope.allowsCustomCapability('legacy'), isTrue);
      expect(key.scope.allowsCustomCapability('theirs'), isFalse);
    });
  });

  group('POST /owner/commands', () {
    late AppState state;
    Request? captured;
    late Handler routes;

    setUp(() {
      state = AppState();
      captured = null;
      routes = ownerRoutes(state, (req) async {
        captured = req;
        return Response.ok(await req.readAsString());
      }).call;
    });

    test('without device token -> 401', () async {
      final res = await routes(Request('POST', Uri.parse('http://x/owner/commands'),
          body: '{}'));
      expect(res.statusCode, 401);
      expect(captured, isNull);
    });

    test('forwards to the command pipeline with the owner key and api_key_id', () async {
      final dev = _device('A');
      final res = await routes(Request('POST', Uri.parse('http://x/owner/commands'),
          body: jsonEncode({'capability': 'location', 'action': 'location.refresh'}),
          context: {'device': dev}));
      expect(res.statusCode, 200);
      expect(captured, isNotNull);
      expect(captured!.url.path, 'commands');
      final key = captured!.context['apiKey'] as ApiKeyRecord;
      expect(key.deviceId, 'A');
      final forwarded = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(forwarded['api_key_id'], 'owner_A');
      expect(forwarded['action'], 'location.refresh');
    });

    test('malformed JSON -> 400, nothing forwarded', () async {
      final res = await routes(Request('POST', Uri.parse('http://x/owner/commands'),
          body: '{oops', context: {'device': _device('A')}));
      expect(res.statusCode, 400);
      expect(captured, isNull);
    });
  });

  group('POST /owner/sessions/{id}/switch', () {
    test('forwards to /sessions/{id}/switch with owner key', () async {
      final state = AppState();
      Request? captured;
      final routes = ownerRoutes(state, (req) async {
        captured = req;
        return Response(204);
      });
      final res = await routes.call(Request(
          'POST', Uri.parse('http://x/owner/sessions/s1/switch'),
          body: jsonEncode({'switch_type': 'viewing_mode', 'value': 'live'}),
          context: {'device': _device('A')}));
      expect(res.statusCode, 204);
      expect(captured!.url.path, 'sessions/s1/switch');
      expect((captured!.context['apiKey'] as ApiKeyRecord).keyId, 'owner_A');
    });
  });

  group('GET /tasks', () {
    test('lists only the caller\'s tasks, newest first, with active filter', () async {
      final state = AppState();
      state.tasks['t1'] = TaskRecord(
          taskId: 't1', deviceId: 'A', originatingCapability: 'files');
      state.tasks['t2'] = TaskRecord(
          taskId: 't2',
          deviceId: 'A',
          originatingCapability: 'screen',
          state: TaskState.completed);
      state.tasks['t3'] = TaskRecord(
          taskId: 't3', deviceId: 'B', originatingCapability: 'files');
      final routes = ownerRoutes(state, (_) async => Response(500));

      Future<List<dynamic>> list(String q) async {
        final res = await routes.call(Request('GET', Uri.parse('http://x/tasks$q'),
            context: {'device': _device('A')}));
        expect(res.statusCode, 200);
        return jsonDecode(await res.readAsString()) as List<dynamic>;
      }

      final all = await list('');
      expect(all.map((t) => t['task_id']).toSet(), {'t1', 't2'});
      final active = await list('?active=true');
      expect(active.map((t) => t['task_id']), ['t1']);
    });

    test('no token -> 401', () async {
      final routes = ownerRoutes(AppState(), (_) async => Response(500));
      final res = await routes.call(Request('GET', Uri.parse('http://x/tasks')));
      expect(res.statusCode, 401);
    });
  });

  group('status_update carries battery/network/location/background (items 32, 52)', () {
    test('valid fields are stored, invalid ones ignored', () {
      final s = AppState();
      s.devices['A'] = _device('A');
      handleAgentMessage(s, 'A', {
        'kind': 'status_update',
        'state': 'ONLINE_LOCKED',
        'battery_percent': 77,
        'background_active': true,
        'network': {'connected': true, 'ssid': 'home', 'connection_type': 'WIFI'},
        'location': {'latitude': 24.86, 'longitude': 67.0, 'accuracy_m': 10},
      });
      final d = s.devices['A']!;
      expect(d.state, 'ONLINE_LOCKED');
      expect(d.batteryPercent, 77);
      expect(d.backgroundActive, isTrue);
      expect(d.lastNetwork!['ssid'], 'home');
      expect(d.lastLocation!['latitude'], 24.86);

      handleAgentMessage(s, 'A', {
        'kind': 'status_update',
        'battery_percent': 500,
        'network': {'connected': 'yes'},
        'location': {'latitude': 999, 'longitude': 0},
      });
      expect(d.batteryPercent, 77);
      expect(d.lastNetwork!['ssid'], 'home');
      expect(d.lastLocation!['latitude'], 24.86);
    });
  });

  group('sanitizeNetwork', () {
    test('requires boolean connected and drops unknown fields', () {
      expect(sanitizeNetwork({'connected': 1}), isNull);
      final out = sanitizeNetwork({'connected': false, 'evil': 'x'})!;
      expect(out.containsKey('evil'), isFalse);
      expect(out['connected'], isFalse);
    });
  });
}
