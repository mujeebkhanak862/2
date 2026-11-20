import 'package:control_api/util/tls_bind_policy.dart';
import 'package:test/test.dart';

/// Audit fix (P0-03, Section 13): "Direct server still listens plaintext
/// when TLS env vars are absent, so deployment must be configured
/// correctly." — koi TLS signal na ho to ab localhost-only bind hota
/// hai (secure by default), sab-interfaces bind sirf explicit opt-in se.
void main() {
  group('shouldBindAllInterfaces', () {
    test('no TLS signal at all => localhost-only (safe default)', () {
      expect(
          shouldBindAllInterfaces(hasDirectTls: false, behindTlsProxy: false),
          isFalse);
    });

    test('direct TLS cert/key present => all interfaces', () {
      expect(
          shouldBindAllInterfaces(hasDirectTls: true, behindTlsProxy: false),
          isTrue);
    });

    test('explicit BEHIND_TLS_PROXY opt-in => all interfaces', () {
      expect(
          shouldBindAllInterfaces(hasDirectTls: false, behindTlsProxy: true),
          isTrue);
    });

    test('both signals present => still all interfaces (no conflict)', () {
      expect(
          shouldBindAllInterfaces(hasDirectTls: true, behindTlsProxy: true),
          isTrue);
    });
  });

  group('parseBehindTlsProxy', () {
    test('null (unset env var) => false', () {
      expect(parseBehindTlsProxy(null), isFalse);
    });

    test('"true" (any case) => true', () {
      expect(parseBehindTlsProxy('true'), isTrue);
      expect(parseBehindTlsProxy('TRUE'), isTrue);
      expect(parseBehindTlsProxy('True'), isTrue);
    });

    test('loose/typo values are NOT accepted — deliberately strict', () {
      expect(parseBehindTlsProxy('1'), isFalse);
      expect(parseBehindTlsProxy('yes'), isFalse);
      expect(parseBehindTlsProxy(''), isFalse);
      expect(parseBehindTlsProxy('ture'), isFalse); // common typo
    });
  });
}
