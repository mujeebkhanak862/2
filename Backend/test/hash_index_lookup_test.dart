import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/util/crypto_utils.dart';
import 'package:test/test.dart';

Device _device(String id, String token) => Device(
      id: id,
      name: 'Dev $id',
      bearerTokenHash: hashSecretUtil(token),
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

ApiKeyRecord _key(String id, String secret,
        {bool enabled = true, DateTime? expiresAt}) =>
    ApiKeyRecord(
      keyId: id,
      deviceId: 'device_1',
      label: 'k',
      scope: const ApiKeyScope(),
      createdAt: DateTime.now().toUtc(),
      secretHash: ApiKeyRecord.hashSecret(secret),
      enabled: enabled,
      expiresAt: expiresAt,
    );

void main() {
  group('Item 22 — hash-indexed lookups', () {
    test('deviceByToken: add, find, remove', () {
      final s = AppState();
      s.devices['d1'] = _device('d1', 't1');
      s.devices['d2'] = _device('d2', 't2');
      expect(s.deviceByToken('t1')?.id, 'd1');
      expect(s.deviceByToken('t2')?.id, 'd2');
      expect(s.deviceByToken('nope'), isNull);

      s.devices.remove('d1');
      expect(s.deviceByToken('t1'), isNull);
      expect(s.deviceByToken('t2')?.id, 'd2');
    });

    test('deviceByToken: in-place token rotation + touch()', () {
      final s = AppState();
      s.devices['d1'] = _device('d1', 'old');
      expect(s.deviceByToken('old')?.id, 'd1');

      s.devices['d1']!.bearerTokenHash = hashSecretUtil('new');
      s.devices.touch();
      expect(s.deviceByToken('old'), isNull);
      expect(s.deviceByToken('new')?.id, 'd1');
    });

    test('deviceByToken: stale index entry is re-verified (no touch)', () {
      final s = AppState();
      s.devices['d1'] = _device('d1', 'old');
      expect(s.deviceByToken('old')?.id, 'd1');
      // touch() bhoola — purana token phir bhi accept nahi hona chahiye.
      s.devices['d1']!.bearerTokenHash = hashSecretUtil('new');
      expect(s.deviceByToken('old'), isNull);
    });

    test('apiKeyBySecret: finds enabled key, rejects disabled/expired', () {
      final s = AppState();
      s.apiKeys['k1'] = _key('k1', 'sk_one');
      s.apiKeys['k2'] = _key('k2', 'sk_two', enabled: false);
      s.apiKeys['k3'] = _key('k3', 'sk_three',
          expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 1)));

      expect(s.apiKeyBySecret('sk_one')?.keyId, 'k1');
      expect(s.apiKeyBySecret('sk_two'), isNull);
      expect(s.apiKeyBySecret('sk_three'), isNull);
      expect(s.apiKeyBySecret('sk_missing'), isNull);
    });

    test('apiKeyBySecret: enable toggle in-place + revoke', () {
      final s = AppState();
      s.apiKeys['k1'] = _key('k1', 'sk_one');
      expect(s.apiKeyBySecret('sk_one'), isNotNull);

      s.apiKeys['k1']!.enabled = false;
      expect(s.apiKeyBySecret('sk_one'), isNull);

      s.apiKeys['k1']!.enabled = true;
      expect(s.apiKeyBySecret('sk_one'), isNotNull);

      s.apiKeys.remove('k1');
      expect(s.apiKeyBySecret('sk_one'), isNull);
    });

    test('removeWhere / clear keep index consistent', () {
      final s = AppState();
      s.apiKeys['k1'] = _key('k1', 'sk_one');
      s.apiKeys['k2'] = _key('k2', 'sk_two');
      expect(s.apiKeyBySecret('sk_one'), isNotNull);
      s.apiKeys.removeWhere((_, k) => k.keyId == 'k1');
      expect(s.apiKeyBySecret('sk_one'), isNull);
      expect(s.apiKeyBySecret('sk_two'), isNotNull);
      s.apiKeys.clear();
      expect(s.apiKeyBySecret('sk_two'), isNull);
    });

    test('1000 keys: lookup still correct', () {
      final s = AppState();
      for (var i = 0; i < 1000; i++) {
        s.apiKeys['k$i'] = _key('k$i', 'sk_$i');
      }
      expect(s.apiKeyBySecret('sk_999')?.keyId, 'k999');
      expect(s.apiKeyBySecret('sk_0')?.keyId, 'k0');
      expect(s.apiKeyBySecret('sk_1000'), isNull);
    });
  });
}
