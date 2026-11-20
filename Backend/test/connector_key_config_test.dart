import 'dart:io' show Platform;

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

import 'package:control_api/connectors/credential_encryption.dart';

/// Handoff P1 #8 — connector encryption key configuration rules.
void main() {
  tearDown(ConnectorEncryptionKey.resetForTesting);

  final envKeySet =
      (Platform.environment['CONNECTOR_ENCRYPTION_KEY'] ?? '').isNotEmpty;

  test('an injected (configured) key counts as configured', () {
    ConnectorEncryptionKey.setForTesting(SecretKey(List<int>.filled(32, 7)));
    expect(ConnectorEncryptionKey.isConfigured, isTrue);
  });

  test('without the env var, load() falls back to an EPHEMERAL key => not configured',
      () async {
    ConnectorEncryptionKey.resetForTesting();
    await ConnectorEncryptionKey.load();
    expect(ConnectorEncryptionKey.isConfigured, isFalse);
  }, skip: envKeySet ? 'CONNECTOR_ENCRYPTION_KEY is set in this environment' : false);

  test('encrypt/decrypt round-trips with an injected key', () async {
    ConnectorEncryptionKey.setForTesting(SecretKey(List<int>.filled(32, 9)));
    final packed = await encryptSecret('refresh-token-123');
    expect(packed, isNot(contains('refresh-token-123')));
    expect(await decryptSecret(packed), 'refresh-token-123');
  });

  test('a different key cannot decrypt (key change => reconnect required)', () async {
    ConnectorEncryptionKey.setForTesting(SecretKey(List<int>.filled(32, 1)));
    final packed = await encryptSecret('abc');
    ConnectorEncryptionKey.setForTesting(SecretKey(List<int>.filled(32, 2)));
    expect(() => decryptSecret(packed), throwsA(anything));
  });
}
