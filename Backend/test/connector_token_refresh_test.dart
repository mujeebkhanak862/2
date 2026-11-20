import 'package:cryptography/cryptography.dart';
import 'package:control_api/connectors/connector_models.dart';
import 'package:control_api/connectors/connector_provider.dart';
import 'package:control_api/connectors/credential_encryption.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:test/test.dart';

/// Real Google/network ko touch kiye bina `AppState`'s refresh-orchestration
/// logic test karne ke liye ek chhota fake provider.
class _FakeProvider implements ConnectorProvider {
  int refreshCallCount = 0;
  OAuthTokenSet? nextRefreshResult;

  @override
  String get name => 'fake_connector';
  @override
  String get displayName => 'Fake Connector';
  @override
  List<String> get scopes => const ['fake.scope'];

  @override
  Uri buildAuthorizationUrl(
          {required String state, required String codeChallenge, required String redirectUri}) =>
      Uri.parse('https://fake.example.com/auth');

  @override
  Future<OAuthTokenSet> exchangeCode(
          {required String code, required String codeVerifier, required String redirectUri}) =>
      throw UnimplementedError('not needed for these tests');

  @override
  Future<OAuthTokenSet> refresh({required String refreshToken}) async {
    refreshCallCount += 1;
    if (nextRefreshResult != null) return nextRefreshResult!;
    return OAuthTokenSet(
      accessToken: 'refreshed-access-token',
      refreshToken: null, // Google-like: purana refresh_token hi reuse hota hai
      accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      grantedScopes: const ['fake.scope'],
    );
  }

  @override
  Future<void> revoke({required String token}) async {}
}

void main() {
  setUp(() {
    ConnectorEncryptionKey.setForTesting(SecretKey(List<int>.filled(32, 3)));
  });
  tearDown(() {
    ConnectorEncryptionKey.resetForTesting();
  });

  group('AppState connector credential storage (P0-07)', () {
    test('connectorCredentialFor returns null when not connected '
        '("Unauthenticated connector actions hidden/unavailable")', () {
      final state = AppState();
      expect(state.connectorCredentialFor('device_1', 'fake_connector'), isNull);
    });

    test('getValidAccessToken returns null when connector not connected', () async {
      final state = AppState();
      final provider = _FakeProvider();
      final token = await state.getValidAccessToken('device_1', 'fake_connector', provider);
      expect(token, isNull);
    });

    test('storeConnectorCredential makes it discoverable and getValidAccessToken '
        'returns the decrypted token when not expired '
        '("auth success exposes actions")', () async {
      final state = AppState();
      state.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_1',
        connectorName: 'fake_connector',
        encryptedAccessToken: await encryptSecret('valid-access-token'),
        encryptedRefreshToken: await encryptSecret('some-refresh-token'),
        accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        grantedScopes: const ['fake.scope'],
        connectedAt: DateTime.now().toUtc(),
      ));

      expect(state.connectorCredentialFor('device_1', 'fake_connector'), isNotNull);

      final provider = _FakeProvider();
      final token = await state.getValidAccessToken('device_1', 'fake_connector', provider);
      expect(token, 'valid-access-token');
      expect(provider.refreshCallCount, 0); // not expired, refresh na ho
    });

    test('getValidAccessToken auto-refreshes an expired token '
        '("expired token refreshes")', () async {
      final state = AppState();
      state.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_1',
        connectorName: 'fake_connector',
        encryptedAccessToken: await encryptSecret('stale-access-token'),
        encryptedRefreshToken: await encryptSecret('refresh-token-abc'),
        // Already expired.
        accessTokenExpiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        grantedScopes: const ['fake.scope'],
        connectedAt: DateTime.now().toUtc(),
      ));

      final provider = _FakeProvider();
      final token = await state.getValidAccessToken('device_1', 'fake_connector', provider);

      expect(token, 'refreshed-access-token');
      expect(provider.refreshCallCount, 1);

      // Stored credential bhi update ho gayi hogi (agli call refresh
      // dobara na kare jab tak yeh bhi expire na ho).
      final stored = state.connectorCredentialFor('device_1', 'fake_connector')!;
      expect(await decryptSecretForTest(stored.encryptedAccessToken), 'refreshed-access-token');
    });

    test('getValidAccessToken keeps the old refresh_token when the provider '
        'does not return a new one', () async {
      final state = AppState();
      state.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_1',
        connectorName: 'fake_connector',
        encryptedAccessToken: await encryptSecret('stale'),
        encryptedRefreshToken: await encryptSecret('original-refresh-token'),
        accessTokenExpiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        grantedScopes: const ['fake.scope'],
        connectedAt: DateTime.now().toUtc(),
      ));

      final provider = _FakeProvider(); // refresh() returns refreshToken: null
      await state.getValidAccessToken('device_1', 'fake_connector', provider);

      final stored = state.connectorCredentialFor('device_1', 'fake_connector')!;
      expect(await decryptSecretForTest(stored.encryptedRefreshToken!), 'original-refresh-token');
    });

    test('getValidAccessToken returns null when no refresh_token is available to refresh with',
        () async {
      final state = AppState();
      state.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_1',
        connectorName: 'fake_connector',
        encryptedAccessToken: await encryptSecret('stale'),
        encryptedRefreshToken: null,
        accessTokenExpiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        grantedScopes: const ['fake.scope'],
        connectedAt: DateTime.now().toUtc(),
      ));

      final provider = _FakeProvider();
      final token = await state.getValidAccessToken('device_1', 'fake_connector', provider);
      expect(token, isNull);
      expect(provider.refreshCallCount, 0);
    });

    test('removeConnectorCredential removes access ("revoke removes access")', () async {
      final state = AppState();
      state.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_1',
        connectorName: 'fake_connector',
        encryptedAccessToken: await encryptSecret('token'),
        encryptedRefreshToken: null,
        accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        grantedScopes: const ['fake.scope'],
        connectedAt: DateTime.now().toUtc(),
      ));
      expect(state.connectorCredentialFor('device_1', 'fake_connector'), isNotNull);

      state.removeConnectorCredential('device_1', 'fake_connector');
      expect(state.connectorCredentialFor('device_1', 'fake_connector'), isNull);

      final provider = _FakeProvider();
      expect(await state.getValidAccessToken('device_1', 'fake_connector', provider), isNull);
    });

    test('credentials for different devices are isolated from each other', () async {
      final state = AppState();
      state.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_A',
        connectorName: 'fake_connector',
        encryptedAccessToken: await encryptSecret('token-for-A'),
        encryptedRefreshToken: null,
        accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        grantedScopes: const ['fake.scope'],
        connectedAt: DateTime.now().toUtc(),
      ));

      expect(state.connectorCredentialFor('device_B', 'fake_connector'), isNull);
      final provider = _FakeProvider();
      expect(await state.getValidAccessToken('device_B', 'fake_connector', provider), isNull);
    });
  });
}

/// Test helper — production code kabhi decrypted value ko ApiKeyRecord
/// jaisi kisi jagah expose nahi karta, sirf yahan test-assertion ke
/// liye seedha `decryptSecret` use kar rahe hain.
Future<String> decryptSecretForTest(String encrypted) => decryptSecret(encrypted);
