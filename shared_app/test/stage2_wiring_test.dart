// Stage 2 app-side tests: credential store, API client owner endpoints,
// status reporter, local policy, reconnect backoff, task summary,
// permission center.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_app/config/credential_store.dart';
import 'package:shared_app/dashboard/permission_center.dart';
import 'package:shared_app/protocol/api_client.dart';
import 'package:shared_app/protocol/api_key.dart';
import 'package:shared_app/protocol/command_envelope.dart';
import 'package:shared_app/protocol/status_reporter.dart';
import 'package:shared_app/protocol/task_summary.dart';
import 'package:shared_app/protocol/websocket_client.dart';

DeviceAgentApiClient _client(MockClientHandler handler) => DeviceAgentApiClient(
      baseUrl: Uri.parse('http://localhost:8080'),
      activeApiKeyId: 'owner',
      httpClient: MockClient(handler),
    );

void main() {
  group('InMemoryCredentialStore (item 24)', () {
    test('save / load / clear round trip', () async {
      final store = InMemoryCredentialStore();
      expect(await store.loadCredentials(), isNull);
      await store.saveCredentials(
          const StoredCredentials(deviceId: 'd1', bearerToken: 't1'));
      await store.savePolicy(const ApiKeyScope(files: true));
      final c = await store.loadCredentials();
      expect(c!.deviceId, 'd1');
      expect(c.bearerToken, 't1');
      expect((await store.loadPolicy())!.files, isTrue);
      await store.clear();
      expect(await store.loadCredentials(), isNull);
      expect(await store.loadPolicy(), isNull);
    });
  });

  group('API client owner endpoints (items 25, 30)', () {
    test('sendCommand posts to /owner/commands with the device bearer token', () async {
      late http.Request seen;
      final api = _client((req) async {
        seen = req;
        return http.Response(jsonEncode({'ok': true}), 200);
      });
      api.setBearerToken('tok');
      final r = await api.sendCommand(capability: 'location', action: 'location.refresh');
      expect(r['ok'], isTrue);
      expect(seen.url.path, '/owner/commands');
      expect(seen.headers['Authorization'], 'Bearer tok');
    });

    test('switchSession posts to /owner/sessions/{id}/switch', () async {
      late http.Request seen;
      final api = _client((req) async {
        seen = req;
        return http.Response('', 204);
      });
      api.setBearerToken('tok');
      await api.switchSession(
          sessionId: 's1', switchType: SwitchType.viewingMode, value: 'live');
      expect(seen.url.path, '/owner/sessions/s1/switch');
    });

    test('getTasks parses /tasks and passes the active filter', () async {
      late http.Request seen;
      final api = _client((req) async {
        seen = req;
        return http.Response(
            jsonEncode([
              {
                'task_id': 't1',
                'state': 'PAUSED',
                'capability': 'files',
                'created_at': '2026-09-30T10:00:00Z',
                'updated_at': '2026-09-30T10:05:00Z',
              }
            ]),
            200);
      });
      final tasks = await api.getTasks(activeOnly: true);
      expect(seen.url.toString(), contains('/tasks?active=true'));
      expect(tasks.single.taskId, 't1');
      expect(tasks.single.isActive, isTrue);
    });

    test('401 triggers onUnauthorized', () async {
      var called = 0;
      final api = _client((req) async => http.Response('{}', 401));
      api.onUnauthorized = () => called++;
      await expectLater(api.getTasks(), throwsA(isA<ApiException>()));
      expect(called, 1);
    });

    test('reportNetwork / unpairDevice / rotateToken hit the right endpoints', () async {
      final paths = <String>[];
      final api = _client((req) async {
        paths.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('rotate-token')) {
          return http.Response(jsonEncode({'bearer_token': 'new'}), 200);
        }
        return http.Response('', 204);
      });
      await api.reportNetwork('d1', {'connected': true});
      await api.unpairDevice('d1');
      expect(await api.rotateToken('d1'), 'new');
      expect(paths, [
        'POST /devices/d1/network',
        'DELETE /devices/d1',
        'POST /devices/d1/rotate-token',
      ]);
    });
  });

  group('TaskSummary', () {
    test('accepts server TaskRecord JSON', () {
      final t = TaskSummary.fromJson({
        'task_id': 'x',
        'state': 'COMPLETED',
        'capability': 'screen',
        'created_at': '2026-09-30T10:00:00Z',
        'updated_at': 'bad-date',
      });
      expect(t.isActive, isFalse);
      expect(t.capability, 'screen');
    });
  });

  group('ApiKeyScope.allowsCapability (item 29 local policy)', () {
    test('maps capabilities to scope flags', () {
      const s = ApiKeyScope(screenView: true, keyboardText: true, apps: true);
      expect(s.allowsCapability('screen'), isTrue);
      expect(s.allowsCapability('input'), isTrue);
      expect(s.allowsCapability('app_launcher'), isTrue);
      expect(s.allowsCapability('files'), isFalse);
      expect(s.allowsCapability('location'), isFalse);
      expect(s.allowsCapability('control'), isTrue); // rokna hamesha allowed
      expect(s.allowsCapability('weird_custom'), isFalse);
      expect(const ApiKeyScope(customCapabilities: {'weird_custom'})
          .allowsCapability('weird_custom'), isTrue);
    });
  });

  group('StatusReporter (items 32, 33)', () {
    Map<String, dynamic>? sent;
    StatusReporter make({
      bool allowLocation = true,
      Future<Map<String, dynamic>?> Function()? readLocation,
      Future<int?> Function()? readBattery,
    }) {
      sent = null;
      return StatusReporter(
        send: ({state, batteryPercent, backgroundActive, network, location}) {
          sent = {
            'state': state,
            'battery': batteryPercent,
            'bg': backgroundActive,
            'network': network,
            'location': location,
          };
        },
        readLockState: () async => 'ONLINE_UNLOCKED',
        readBattery: readBattery ?? () async => 64,
        readNetwork: () async => {'connected': true},
        readLocation: readLocation ?? () async => {'latitude': 1.0, 'longitude': 2.0},
        locationAllowed: () => allowLocation,
      );
    }

    test('reportNow sends the full snapshot incl. location when allowed', () async {
      await make().reportNow(includeLocation: true);
      expect(sent!['state'], 'ONLINE_UNLOCKED');
      expect(sent!['battery'], 64);
      expect(sent!['bg'], isTrue);
      expect(sent!['network'], {'connected': true});
      expect(sent!['location'], isNotNull);
    });

    test('location is NOT sent when local policy disallows it', () async {
      await make(allowLocation: false).reportNow(includeLocation: true);
      expect(sent!['location'], isNull);
      expect(sent!['battery'], 64);
    });

    test('one failing reader does not block the others', () async {
      await make(
        readBattery: () async => throw Exception('no battery'),
        readLocation: () async => throw Exception('denied'),
      ).reportNow(includeLocation: true);
      expect(sent!['battery'], isNull);
      expect(sent!['location'], isNull);
      expect(sent!['state'], 'ONLINE_UNLOCKED');
      expect(sent!['network'], isNotNull);
    });
  });

  group('reconnectDelay (items 26/27)', () {
    test('grows exponentially and is capped at ~30s', () {
      final r = Random(1);
      final d0 = reconnectDelay(0, random: r);
      final d3 = reconnectDelay(3, random: r);
      final d20 = reconnectDelay(20, random: r);
      expect(d0.inSeconds, 1);
      expect(d3.inSeconds, 8);
      expect(d20.inSeconds, lessThanOrEqualTo(30));
      expect(d20.inSeconds, greaterThanOrEqualTo(30));
    });
  });

  group('PermissionCenterScreen (item 28)', () {
    testWidgets('shows status and runs the request flow', (tester) async {
      var requested = 0;
      await tester.pumpWidget(MaterialApp(
        home: PermissionCenterScreen(items: [
          PermissionItem(
            title: 'Contacts',
            description: 'desc',
            check: () async => false,
            request: () async {
              requested++;
              return true;
            },
          ),
        ]),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Contacts'), findsOneWidget);
      expect(find.text('Grant'), findsOneWidget);

      await tester.tap(find.text('Grant'));
      await tester.pumpAndSettle();
      expect(requested, 1);
      expect(find.text('Granted'), findsOneWidget);
    });
  });
}
