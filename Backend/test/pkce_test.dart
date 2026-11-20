import 'package:control_api/connectors/pkce.dart';
import 'package:test/test.dart';

void main() {
  group('PKCE (P0-07)', () {
    test('code_challenge matches RFC 7636 Appendix B official test vector', () {
      // https://www.rfc-editor.org/rfc/rfc7636#appendix-B — official
      // published example, isse hum apni S256 implementation ko exactly
      // spec ke against verify kar sakte hain (koi guesswork nahi).
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expectedChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
      expect(codeChallengeFromVerifier(verifier), expectedChallenge);
    });

    test('generateCodeVerifier produces RFC-compliant length (43-128 chars)', () {
      final verifier = generateCodeVerifier();
      expect(verifier.length, greaterThanOrEqualTo(43));
      expect(verifier.length, lessThanOrEqualTo(128));
    });

    test('generateCodeVerifier only uses unreserved characters', () {
      final verifier = generateCodeVerifier();
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(verifier), isTrue);
    });

    test('generateCodeVerifier produces different values each call', () {
      final a = generateCodeVerifier();
      final b = generateCodeVerifier();
      expect(a, isNot(equals(b)));
    });

    test('generateStateToken produces different values each call (CSRF protection)', () {
      final a = generateStateToken();
      final b = generateStateToken();
      expect(a, isNot(equals(b)));
      expect(a.length, greaterThan(16));
    });

    test('codeChallengeFromVerifier is deterministic for the same input', () {
      const verifier = 'some-fixed-test-verifier-value-1234567890abc';
      expect(codeChallengeFromVerifier(verifier), codeChallengeFromVerifier(verifier));
    });
  });
}
