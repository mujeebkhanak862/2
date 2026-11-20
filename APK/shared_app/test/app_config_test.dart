import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/config/app_config.dart';

void main() {
  group('AppConfig.resolve (P0-03)', () {
    test('debug mode + localhost http => allowed, ws derived', () {
      final config =
          AppConfig.resolve('http://localhost:8080', debugMode: true);
      expect(config.controlApiBaseUrl.scheme, 'http');
      expect(config.controlApiWsBaseUrl.scheme, 'ws');
      expect(config.controlApiWsBaseUrl.host, 'localhost');
    });

    test('release mode + localhost http => still allowed (dev-on-device testing)', () {
      final config =
          AppConfig.resolve('http://127.0.0.1:8080', debugMode: false);
      expect(config.controlApiBaseUrl.scheme, 'http');
      expect(config.controlApiWsBaseUrl.scheme, 'ws');
    });

    test('release mode + non-localhost https => allowed, wss derived', () {
      final config = AppConfig.resolve(
        'https://control-api-production-xxxx.up.railway.app',
        debugMode: false,
      );
      expect(config.controlApiBaseUrl.scheme, 'https');
      expect(config.controlApiWsBaseUrl.scheme, 'wss');
      expect(config.controlApiWsBaseUrl.host,
          'control-api-production-xxxx.up.railway.app');
    });

    test(
        'release mode + non-localhost http => rejected '
        '("Production build plaintext HTTP/WS reject kare")', () {
      expect(
        () => AppConfig.resolve(
          'http://control-api-production-xxxx.up.railway.app',
          debugMode: false,
        ),
        throwsA(isA<InsecureTransportConfigError>()),
      );
    });

    test('debug mode + non-localhost http => allowed (dev convenience, e.g. LAN IP)', () {
      // Debug/dev builds intentionally more permissive — a developer
      // testing against a LAN-hosted dev backend shouldn't be blocked.
      final config =
          AppConfig.resolve('http://192.168.1.50:8080', debugMode: true);
      expect(config.controlApiBaseUrl.scheme, 'http');
    });

    test('ws base URL preserves path when replacing scheme', () {
      final config = AppConfig.resolve(
        'https://example.com/api',
        debugMode: false,
      );
      expect(config.controlApiWsBaseUrl.toString(), 'wss://example.com/api');
    });
  });
}
