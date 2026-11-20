import 'package:control_api/middleware/safe_logging.dart';
import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/util/crypto_utils.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('Device bearer token is hashed at rest (P0-06)', () {
    test('Device only exposes bearerTokenHash, never the plaintext token', () {
      const plaintextToken = 'super-secret-device-token-12345';
      final device = Device(
        id: 'device_1',
        name: 'Test Device',
        bearerTokenHash: hashSecretUtil(plaintextToken),
        pairedAt: DateTime.now().toUtc(),
        lastSeenAt: DateTime.now().toUtc(),
      );
      // Hash kabhi bhi plaintext ke barabar nahi honi chahiye, aur
      // plaintext kahin bhi field ke tor par store nahi honi chahiye
      // (compile-time hi guarantee hai — Device class mein koi
      // `bearerToken` field hai hi nahi ab).
      expect(device.bearerTokenHash, isNot(equals(plaintextToken)));
      expect(device.bearerTokenHash, hashSecretUtil(plaintextToken));
    });

    test('deviceByToken finds device via hash comparison, not plaintext', () {
      final state = AppState();
      const plaintextToken = 'device-token-xyz';
      state.devices['device_1'] = Device(
        id: 'device_1',
        name: 'Test Device',
        bearerTokenHash: hashSecretUtil(plaintextToken),
        pairedAt: DateTime.now().toUtc(),
        lastSeenAt: DateTime.now().toUtc(),
      );

      expect(state.deviceByToken(plaintextToken)?.id, 'device_1');
      expect(state.deviceByToken('wrong-token'), isNull);
      // Hash khud bhej kar authenticate nahi ho sakte — sirf original
      // plaintext token kaam karta hai (jaisa hona chahiye).
      expect(state.deviceByToken(hashSecretUtil(plaintextToken)), isNull);
    });

    test('ApiKeyRecord and Device use the same underlying hash function', () {
      // Regression guard: dono alag-alag hashing implementation use na
      // karne lagein kabhi (consistency check).
      const secret = 'shared-test-value';
      expect(ApiKeyRecord.hashSecret(secret), hashSecretUtil(secret));
    });
  });

  group('safeRequestLogging never logs headers/body (P0-06)', () {
    test('Authorization header value never appears in log output', () async {
      final logs = <String>[];
      final middleware = safeRequestLogging(logSink: logs.add);
      final handler = middleware((request) async => Response.ok('ok'));

      const secretToken = 'sk_verySecretApiKeyValue123456';
      final request = Request(
        'POST',
        Uri.parse('http://localhost/commands'),
        headers: {'authorization': 'Bearer $secretToken'},
        body: '{"some": "sensitive body content", "secret": "$secretToken"}',
      );

      await handler(request);

      expect(logs, isNotEmpty);
      for (final line in logs) {
        expect(line.contains(secretToken), isFalse,
            reason: 'Log line leaked the secret token: $line');
        expect(line.toLowerCase().contains('authorization'), isFalse);
        expect(line.toLowerCase().contains('bearer'), isFalse);
        expect(line.contains('sensitive body content'), isFalse);
      }
    });

    test('log line contains method, path, and status (useful, non-sensitive info)', () async {
      final logs = <String>[];
      final middleware = safeRequestLogging(logSink: logs.add);
      final handler = middleware((request) async => Response.ok('ok'));

      final request = Request('GET', Uri.parse('http://localhost/healthz'));
      await handler(request);

      expect(logs.single, contains('GET'));
      expect(logs.single, contains('/healthz'));
      expect(logs.single, contains('200'));
    });

    test('errors are logged without leaking full exception payloads', () async {
      final logs = <String>[];
      final middleware = safeRequestLogging(logSink: logs.add);
      final handler = middleware((request) async =>
          throw StateError(List.filled(500, 'x').join())); // artificially huge error message

      final request = Request('GET', Uri.parse('http://localhost/boom'));
      await expectLater(handler(request), throwsA(isA<StateError>()));

      expect(logs.single, contains('ERROR'));
      expect(logs.single.length, lessThan(400)); // truncated, not the full 500 chars
    });
  });
}
