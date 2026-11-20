import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:control_api/connectors/connector_models.dart';
import 'package:control_api/connectors/credential_encryption.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/storage/persistence.dart';
import 'package:test/test.dart';

void main() {
  group('Connector credential persistence (P0-07)', () {
    late Directory tempDir;
    late File stateFile;

    setUp(() {
      ConnectorEncryptionKey.setForTesting(SecretKey(List<int>.filled(32, 5)));
      tempDir = Directory.systemTemp.createTempSync('connector_persistence_test');
      stateFile = File('${tempDir.path}/state.json');
    });

    tearDown(() {
      ConnectorEncryptionKey.resetForTesting();
      tempDir.deleteSync(recursive: true);
    });

    test('connector credential survives a save + load round-trip', () async {
      final writerState = AppState();
      writerState.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_1',
        connectorName: 'google_drive',
        encryptedAccessToken: await encryptSecret('access-token-value'),
        encryptedRefreshToken: await encryptSecret('refresh-token-value'),
        accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        grantedScopes: const ['https://www.googleapis.com/auth/drive.readonly'],
        connectedAt: DateTime.now().toUtc(),
      ));
      await Persistence(writerState, fileOverride: stateFile).save();

      // Raw file par plaintext token kabhi nahi honi chahiye.
      final rawFileContent = await stateFile.readAsString();
      expect(rawFileContent.contains('access-token-value'), isFalse);
      expect(rawFileContent.contains('refresh-token-value'), isFalse);

      final readerState = AppState();
      await Persistence(readerState, fileOverride: stateFile).load();

      final loaded = readerState.connectorCredentialFor('device_1', 'google_drive');
      expect(loaded, isNotNull);
      expect(await decryptSecret(loaded!.encryptedAccessToken), 'access-token-value');
      expect(await decryptSecret(loaded.encryptedRefreshToken!), 'refresh-token-value');
      expect(loaded.grantedScopes, ['https://www.googleapis.com/auth/drive.readonly']);
    });

    test('missing file loads cleanly with no connector credentials', () async {
      final state = AppState();
      await Persistence(state, fileOverride: stateFile).load(); // file doesn't exist yet
      expect(state.connectorCredentials, isEmpty);
    });

    test('credential with a null refresh token round-trips correctly', () async {
      final writerState = AppState();
      writerState.storeConnectorCredential(ConnectorCredential(
        deviceId: 'device_2',
        connectorName: 'google_drive',
        encryptedAccessToken: await encryptSecret('access-only'),
        encryptedRefreshToken: null,
        accessTokenExpiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        grantedScopes: const [],
        connectedAt: DateTime.now().toUtc(),
      ));
      await Persistence(writerState, fileOverride: stateFile).save();

      final readerState = AppState();
      await Persistence(readerState, fileOverride: stateFile).load();
      final loaded = readerState.connectorCredentialFor('device_2', 'google_drive');
      expect(loaded!.encryptedRefreshToken, isNull);
    });
  });
}
