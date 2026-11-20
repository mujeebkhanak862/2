// Stage 1 security fixes (items 6-22) ke tests.
import 'dart:async';
import 'dart:convert';

import 'package:control_api/auth/device_auth.dart';
import 'package:control_api/middleware/rate_limiter.dart';
import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/models/task.dart';
import 'package:control_api/routes/connectors.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/util/crypto_utils.dart';
import 'package:control_api/util/http_utils.dart';
import 'package:control_api/validation/data_channel_security.dart';
import 'package:control_api/websocket/handlers.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

Device _device(String id, {String token = 'tok'}) => Device(
      id: id,
      name: id,
      bearerTokenHash: hashSecretUtil(token),
      platform: 'android',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

ApiKeyRecord _key(String id, String deviceId,
        {String secret = 'sk_x',
        bool enabled = true,
        DateTime? expiresAt}) =>
    ApiKeyRecord(
      keyId: id,
      deviceId: deviceId,
      label: 'k',
      scope: const ApiKeyScope(files: true),
      createdAt: DateTime.now().toUtc(),
      secretHash: hashSecretUtil(secret),
      enabled: enabled,
      expiresAt: expiresAt,
    );

Request _req(String method, {Object? body, Map<String, Object>? context, Map<String, String>? headers}) =>
    Request(method, Uri.parse('http://localhost/x'),
        body: body, context: context ?? const {}, headers: headers);

void main() {
  group('session ownership (item 6)', () {
    test('unclaimed session can be claimed; owner keeps it', () {
      final s = AppState();
      expect(s.claimSession('s1', 'A'), isTrue);
      expect(s.sessionOwner('s1'), 'A');
      expect(s.claimSession('s1', 'A'), isTrue);
    });

    test('another device cannot claim or overwrite an owned session', () {
      final s = AppState();
      s.claimSession('s1', 'A');
      expect(s.claimSession('s1', 'B'), isFalse);
      expect(s.sessionOwner('s1'), 'A');
      expect(s.sessionBelongsTo('s1', 'B'), isFalse);
    });

    test('ownership is also derived from an existing task record', () {
      final s = AppState();
      s.tasks['t1'] = TaskRecord(
          taskId: 't1', deviceId: 'A', originatingCapability: 'files');
      expect(s.sessionOwner('t1'), 'A');
      expect(s.claimSession('t1', 'B'), isFalse);
    });
  });

  group('device->server message ownership (item 7)', () {
    test('task_progress from a non-owner is ignored', () {
      final s = AppState();
      s.claimSession('s1', 'A');
      s.tasks['s1'] = TaskRecord(
          taskId: 's1', deviceId: 'A', originatingCapability: 'files');
      handleAgentMessage(s, 'B', {
        'kind': 'event',
        'session_id': 's1',
        'type': 'task_progress',
        'step': 5,
      });
      expect(s.tasks['s1']!.lastCheckpoint, isNull);

      handleAgentMessage(s, 'A', {
        'kind': 'event',
        'session_id': 's1',
        'type': 'task_progress',
        'step': 2,
      });
      expect(s.tasks['s1']!.lastCheckpoint, isNotNull);
    });

    test('command_result from the wrong device does not complete the command', () {
      final s = AppState();
      final c = Completer<Map<String, dynamic>>();
      s.pendingCommands['r1'] = c;
      s.pendingCommandDevice['r1'] = 'A';

      handleAgentMessage(s, 'B', {
        'kind': 'command_result',
        'request_id': 'r1',
        'result': {'evil': true},
      });
      expect(c.isCompleted, isFalse);

      handleAgentMessage(s, 'A', {
        'kind': 'command_result',
        'request_id': 'r1',
        'result': {'ok': true},
      });
      expect(c.isCompleted, isTrue);
    });
  });

  group('authorizeForDevice (items 8/9)', () {
    test('no auth -> 401', () {
      expect(authorizeForDevice(_req('GET'), 'A')!.statusCode, 401);
    });
    test('own device token OK, other device 403', () {
      expect(authorizeForDevice(_req('GET', context: {'device': _device('A')}), 'A'), isNull);
      expect(authorizeForDevice(_req('GET', context: {'device': _device('B')}), 'A')!.statusCode, 403);
    });
    test('api key only for its own device; can be disallowed', () {
      final k = _key('k1', 'A');
      expect(authorizeForDevice(_req('GET', context: {'apiKey': k}), 'A'), isNull);
      expect(authorizeForDevice(_req('GET', context: {'apiKey': k}), 'B')!.statusCode, 403);
      expect(authorizeForDevice(_req('GET', context: {'apiKey': k}), 'A', allowApiKey: false)!.statusCode, 401);
    });
  });

  group('API keys (items 18/21/22)', () {
    test('apiKeyBySecret rejects disabled and expired keys', () {
      final s = AppState();
      s.apiKeys['ok'] = _key('ok', 'A', secret: 'sk_ok');
      s.apiKeys['off'] = _key('off', 'A', secret: 'sk_off', enabled: false);
      s.apiKeys['old'] = _key('old', 'A',
          secret: 'sk_old',
          expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 1)));
      expect(s.apiKeyBySecret('sk_ok')?.keyId, 'ok');
      expect(s.apiKeyBySecret('sk_off'), isNull);
      expect(s.apiKeyBySecret('sk_old'), isNull);
      expect(s.apiKeyBySecret('nope'), isNull);
    });

    test('ApiKeyScope.tryParse returns null on wrong types instead of throwing', () {
      expect(ApiKeyScope.tryParse({'files': 'yes'}), isNull);
      expect(ApiKeyScope.tryParse({'custom_capabilities': [1, 2]}), isNull);
      expect(ApiKeyScope.tryParse('not a map'), isNull);
      expect(ApiKeyScope.tryParse({'files': true})!.files, isTrue);
    });

    test('toJson exposes expiry fields only when set', () {
      final k = _key('k', 'A', expiresAt: DateTime.utc(2030, 1, 1));
      expect(k.toJson().containsKey('expires_at'), isTrue);
      expect(_key('k2', 'A').toJson().containsKey('expires_at'), isFalse);
    });

    test('constantTimeEquals', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  group('ids (item 19)', () {
    test('device id has 128 bits of randomness and is unique', () {
      final ids = {for (var i = 0; i < 200; i++) Device.generateId()};
      expect(ids.length, 200);
      expect(RegExp(r'^device_[0-9a-f]{32}$').hasMatch(ids.first), isTrue);
    });
  });

  group('removeDevice (item 21)', () {
    test('removes device and all its owned data', () async {
      final s = AppState();
      s.devices['A'] = _device('A');
      s.devices['B'] = _device('B');
      s.apiKeys['ka'] = _key('ka', 'A');
      s.apiKeys['kb'] = _key('kb', 'B', secret: 'sk_b');
      s.claimSession('sa', 'A');
      s.tasks['sa'] = TaskRecord(
          taskId: 'sa', deviceId: 'A', originatingCapability: 'files');
      s.customCapabilityManifests.add({'capability': 'x', 'registered_by': 'A'});
      s.customCapabilityManifests.add({'capability': 'y', 'registered_by': 'B'});

      expect(await s.removeDevice('A'), isTrue);
      expect(s.devices.containsKey('A'), isFalse);
      expect(s.devices.containsKey('B'), isTrue);
      expect(s.apiKeys.keys, ['kb']);
      expect(s.tasks.containsKey('sa'), isFalse);
      expect(s.sessionToDevice.containsKey('sa'), isFalse);
      expect(s.customCapabilityManifests.map((m) => m['capability']), ['y']);
      expect(await s.removeDevice('A'), isFalse);
    });
  });

  group('browser URL policy (item 13)', () {
    test('http/https allowed', () {
      expect(validateBrowserUrl('https://example.com/a?b=1').isValid, isTrue);
      expect(validateBrowserUrl('http://example.com').isValid, isTrue);
    });
    test('dangerous schemes and malformed urls rejected', () {
      for (final u in [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'data:text/html,hi',
        'intent://x#Intent;end',
        'content://contacts',
        'tel:123',
        'example.com',
        '',
        'https://',
      ]) {
        expect(validateBrowserUrl(u).isValid, isFalse, reason: u);
      }
      expect(validateBrowserUrl(null).isValid, isFalse);
    });
  });

  group('upload file type policy (item 14)', () {
    test('new script/launcher types are blocked', () {
      for (final f in [
        'a.ps1', 'a.vbs', 'a.js', 'a.hta', 'a.lnk', 'a.reg', 'a.py',
        'a.desktop', 'a.AppImage', 'a.msix', 'a.cpl',
      ]) {
        expect(validateUploadFileType('/tmp/$f').isValid, isFalse, reason: f);
      }
    });
    test('Windows trailing dot/space and ADS bypasses are blocked', () {
      expect(validateUploadFileType(r'C:\x\payload.exe.').isValid, isFalse);
      expect(validateUploadFileType(r'C:\x\payload.exe ').isValid, isFalse);
      expect(validateUploadFileType(r'C:\x\a.txt:evil.exe').isValid, isFalse);
      expect(validateUploadFileType(r'C:\x\payload.exe:hidden.txt').isValid, isFalse);
    });
    test('normal files still allowed', () {
      expect(validateUploadFileType('/sdcard/report.pdf').isValid, isTrue);
      expect(validateUploadFileType(r'C:\Users\me\notes.txt').isValid, isTrue);
    });
    test('"a..b.txt" is a legal name, but real traversal is still blocked', () {
      expect(validateFilePath('/sdcard/a..b.txt').isValid, isTrue);
      expect(validateFilePath('/sdcard/../etc/passwd').isValid, isFalse);
      expect(validateFilePath(r'..\Windows').isValid, isFalse);
    });
  });

  group('HTML escaping (item 11)', () {
    test('escapeHtml neutralises tags and quotes', () {
      final out = escapeHtml('<script>alert("x")</script>&\'');
      expect(out.contains('<'), isFalse);
      expect(out.contains('>'), isFalse);
      expect(out.contains('"'), isFalse);
      expect(out.contains("'"), isFalse);
    });

    test('connector callback page escapes message and sets CSP', () async {
      final res = connectorHtmlResponse('<img src=x onerror=alert(1)>');
      final body = await res.readAsString();
      expect(body.contains('<img'), isFalse);
      expect(res.headers['content-security-policy'], contains("default-src 'none'"));
      expect(res.headers['x-content-type-options'], 'nosniff');
    });
  });

  group('safe JSON body parsing (item 18)', () {
    test('malformed JSON -> 400, not an exception', () async {
      final r = await readJsonObject(_req('POST', body: '{not json'));
      expect(r.isOk, isFalse);
      expect(r.error!.statusCode, 400);
    });
    test('non-object JSON -> 400', () async {
      final r = await readJsonObject(_req('POST', body: '[1,2]'));
      expect(r.error!.statusCode, 400);
    });
    test('oversized body -> 413', () async {
      final r = await readJsonObject(_req('POST', body: '{"a":"${'x' * 200}"}'),
          maxBytes: 50);
      expect(r.error!.statusCode, 413);
    });
    test('valid object parses', () async {
      final r = await readJsonObject(_req('POST', body: '{"a":1}'));
      expect(r.body, {'a': 1});
    });
  });

  group('sanitizeLocation (item 18)', () {
    test('keeps only whitelisted fields and validates ranges', () {
      final out = sanitizeLocation({
        'latitude': 24.86,
        'longitude': 67.0,
        'accuracy_m': 12.5,
        'source': 'gps',
        'evil': '<script>',
      })!;
      expect(out.containsKey('evil'), isFalse);
      expect(out['latitude'], 24.86);
      expect(out.containsKey('timestamp'), isTrue);
    });
    test('rejects out-of-range, non-numeric and missing values', () {
      expect(sanitizeLocation({'latitude': 91, 'longitude': 0}), isNull);
      expect(sanitizeLocation({'latitude': 0, 'longitude': 181}), isNull);
      expect(sanitizeLocation({'latitude': 'x', 'longitude': 0}), isNull);
      expect(sanitizeLocation({'latitude': 0}), isNull);
    });
  });

  group('body size limit middleware (item 16)', () {
    Handler wrap() => const Pipeline()
        .addMiddleware(bodySizeLimitMiddleware(10))
        .addHandler((req) async => Response.ok(await req.readAsString()));

    test('small body passes', () async {
      final res = await wrap()(_req('POST', body: 'hello'));
      expect(res.statusCode, 200);
    });
    test('content-length over the limit -> 413 without reading', () async {
      final res = await wrap()(_req('POST', body: 'x' * 100));
      expect(res.statusCode, 413);
    });
    test('streamed (unknown length) body over the limit -> 413', () async {
      final stream = Stream<List<int>>.fromIterable([
        utf8.encode('x' * 8),
        utf8.encode('x' * 8),
      ]);
      final res = await wrap()(_req('POST', body: stream));
      expect(res.statusCode, 413);
    });
  });

  group('client IP / proxy trust (item 17)', () {
    test('X-Forwarded-For ignored unless proxy is trusted', () {
      final r = _req('GET', headers: {'x-forwarded-for': '1.2.3.4, 5.6.7.8'});
      expect(clientIp(r), 'unknown');
      expect(clientIp(r, trustProxy: true), '1.2.3.4');
    });
    test('identityFor uses forwarded ip for anonymous callers when trusted', () {
      final r = _req('POST', headers: {'x-forwarded-for': '9.9.9.9'});
      expect(identityFor(r, trustProxy: true), 'ip:9.9.9.9');
    });
  });
}
