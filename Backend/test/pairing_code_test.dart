import 'dart:convert';

import 'package:control_api/auth/device_auth.dart';
import 'package:control_api/auth/pairing_code_registry.dart';
import 'package:control_api/models/device.dart';
import 'package:control_api/routes/devices.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/util/crypto_utils.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _admin = 'admin-secret-1234567890';

Handler _handler(AppState s, Map<String, String> env) =>
    const Pipeline()
        .addMiddleware(deviceAuthMiddleware(s))
        .addHandler(deviceRoutes(s, env: env).call);

Future<Response> _post(Handler h, String path, Map<String, dynamic> body,
        {String? bearer}) =>
    Future.sync(() => h(Request('POST', Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {
          'content-type': 'application/json',
          if (bearer != null) 'authorization': 'Bearer $bearer',
        })));

Map<String, dynamic> _j(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('PairingCodeRegistry', () {
    test('issue -> consume works exactly once', () {
      final r = PairingCodeRegistry();
      final c = r.issue(issuedBy: 'admin')!;
      expect(c.code, matches(RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$')));
      expect(r.isValid(c.code), isTrue);
      expect(r.consume(c.code), isTrue);
      expect(r.consume(c.code), isFalse);
      expect(r.isValid(c.code), isFalse);
    });

    test('input normalisation: lowercase, spaces, dash optional', () {
      final r = PairingCodeRegistry();
      final c = r.issue(issuedBy: 'admin')!;
      final loose = ' ${c.code.toLowerCase().replaceAll('-', ' ')} ';
      expect(r.isValid(loose), isTrue);
      expect(r.consume(loose), isTrue);
    });

    test('expires after ttl', () {
      final r = PairingCodeRegistry(ttl: const Duration(seconds: 60));
      final t0 = DateTime.utc(2026, 10, 5, 12);
      final c = r.issue(issuedBy: 'admin', now: t0)!;
      expect(r.isValid(c.code, now: t0.add(const Duration(seconds: 59))), isTrue);
      expect(r.isValid(c.code, now: t0.add(const Duration(seconds: 60))), isFalse);
      expect(r.consume(c.code, now: t0.add(const Duration(seconds: 61))), isFalse);
    });

    test('active cap enforced, expired codes free the slots', () {
      final r = PairingCodeRegistry(maxActive: 2, ttl: const Duration(seconds: 60));
      final t0 = DateTime.utc(2026, 10, 5, 12);
      expect(r.issue(issuedBy: 'a', now: t0), isNotNull);
      expect(r.issue(issuedBy: 'a', now: t0), isNotNull);
      expect(r.issue(issuedBy: 'a', now: t0), isNull);
      expect(r.issue(issuedBy: 'a', now: t0.add(const Duration(seconds: 61))), isNotNull);
    });

    test('looksLikeCode rejects wrong shapes', () {
      expect(PairingCodeRegistry.looksLikeCode('ABCD-EFGH'), isTrue);
      expect(PairingCodeRegistry.looksLikeCode('ABC'), isFalse);
      expect(PairingCodeRegistry.looksLikeCode('ABCD-EFG0'), isFalse); // 0 alphabet mein nahi
    });
  });

  group('POST /pairing-codes', () {
    test('rejects without auth and with wrong/short admin secret', () async {
      final s = AppState();
      final h = _handler(s, {'ADMIN_SECRET': _admin});
      expect((await _post(h, '/pairing-codes', {})).statusCode, 401);
      expect((await _post(h, '/pairing-codes', {}, bearer: 'nope')).statusCode, 401);

      final weak = _handler(s, {'ADMIN_SECRET': 'short'});
      expect((await _post(weak, '/pairing-codes', {}, bearer: 'short')).statusCode, 401);
    });

    test('admin secret issues a code', () async {
      final s = AppState();
      final h = _handler(s, {'ADMIN_SECRET': _admin});
      final res = await _post(h, '/pairing-codes', {}, bearer: _admin);
      expect(res.statusCode, 200);
      final body = _j(await res.readAsString());
      expect(body['single_use'], true);
      expect(s.pairingCodes.isValid(body['pairing_code'] as String), isTrue);
    });

    test('paired device token can issue a code', () async {
      final s = AppState();
      s.devices['d1'] = Device(
        id: 'd1',
        name: 'd1',
        bearerTokenHash: hashSecretUtil('tok'),
        platform: 'android',
        pairedAt: DateTime.now().toUtc(),
        lastSeenAt: DateTime.now().toUtc(),
      );
      final h = _handler(s, {});
      final res = await _post(h, '/pairing-codes', {}, bearer: 'tok');
      expect(res.statusCode, 200);
    });
  });

  group('POST /devices/pair with codes', () {
    Map<String, dynamic> pairBody(String code) =>
        {'pairing_code': code, 'device_name': 'Phone', 'platform': 'android'};

    test('REQUIRE_PAIRING_CODE: no/invalid code -> 401', () async {
      final s = AppState();
      final h = _handler(s, {'REQUIRE_PAIRING_CODE': 'true'});
      expect((await _post(h, '/devices/pair', pairBody('random-client-code'))).statusCode, 401);
      expect((await _post(h, '/devices/pair', pairBody('ABCD-EFGH'))).statusCode, 401);
      expect(s.devices, isEmpty);
    });

    test('valid code pairs once; reuse fails', () async {
      final s = AppState();
      final h = _handler(s, {'REQUIRE_PAIRING_CODE': 'true'});
      final code = s.pairingCodes.issue(issuedBy: 'admin')!.code;

      final ok = await _post(h, '/devices/pair', pairBody(code));
      expect(ok.statusCode, 200);
      expect(_j(await ok.readAsString()).containsKey('bearer_token'), isTrue);
      expect(s.devices.length, 1);

      final again = await _post(h, '/devices/pair', pairBody(code));
      expect(again.statusCode, 401);
      expect(s.devices.length, 1);
    });

    test('valid code replaces PAIRING_SECRET requirement', () async {
      final s = AppState();
      final h = _handler(s, {'PAIRING_SECRET': 'legacy-secret'});
      final code = s.pairingCodes.issue(issuedBy: 'admin')!.code;
      expect((await _post(h, '/devices/pair', pairBody(code))).statusCode, 200);
    });

    test('legacy mode (no REQUIRE_PAIRING_CODE) still needs PAIRING_SECRET', () async {
      final s = AppState();
      final h = _handler(s, {'PAIRING_SECRET': 'legacy-secret'});
      expect((await _post(h, '/devices/pair', pairBody('whatever'))).statusCode, 401);
      final ok = await _post(h, '/devices/pair',
          {...pairBody('whatever'), 'pairing_secret': 'legacy-secret'});
      expect(ok.statusCode, 200);
    });

    test('invalid request (bad platform) does NOT burn the code', () async {
      final s = AppState();
      final h = _handler(s, {'REQUIRE_PAIRING_CODE': 'true'});
      final code = s.pairingCodes.issue(issuedBy: 'admin')!.code;
      final bad = await _post(h, '/devices/pair',
          {'pairing_code': code, 'device_name': 'X', 'platform': 'palm-os'});
      expect(bad.statusCode, 400);
      expect(s.pairingCodes.isValid(code), isTrue);
      expect((await _post(h, '/devices/pair', pairBody(code))).statusCode, 200);
    });
  });
}
