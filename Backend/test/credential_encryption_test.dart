import 'package:cryptography/cryptography.dart';
import 'package:control_api/connectors/credential_encryption.dart';
import 'package:test/test.dart';

void main() {
  group('Credential encryption at rest (P0-07)', () {
    setUp(() async {
      // Deterministic key har test ke liye — reproducible, aur ek test
      // ki state doosre test mein leak nahi hoti.
      final key = SecretKey(List<int>.filled(32, 7));
      ConnectorEncryptionKey.setForTesting(key);
    });

    tearDown(() {
      ConnectorEncryptionKey.resetForTesting();
    });

    test('encrypt then decrypt round-trips to the original plaintext', () async {
      const plaintext = 'ya29.a0AfH6SMC_very_secret_access_token_value';
      final encrypted = await encryptSecret(plaintext);
      final decrypted = await decryptSecret(encrypted);
      expect(decrypted, plaintext);
    });

    test('encrypted value never contains the plaintext as a substring', () async {
      const plaintext = 'super-secret-refresh-token-xyz-123';
      final encrypted = await encryptSecret(plaintext);
      expect(encrypted.contains(plaintext), isFalse);
    });

    test('same plaintext encrypted twice produces different ciphertexts (random nonce)', () async {
      const plaintext = 'same-secret-value';
      final a = await encryptSecret(plaintext);
      final b = await encryptSecret(plaintext);
      expect(a, isNot(equals(b)));
      // Dono phir bhi sahi se decrypt hone chahiye.
      expect(await decryptSecret(a), plaintext);
      expect(await decryptSecret(b), plaintext);
    });

    test('tampered ciphertext fails to decrypt (authentication check)', () async {
      const plaintext = 'a-token-that-should-be-protected';
      final encrypted = await encryptSecret(plaintext);
      // Ek character flip karke "tamper" simulate karte hain.
      final tampered = encrypted.substring(0, encrypted.length - 4) +
          (encrypted[encrypted.length - 4] == 'A' ? 'B' : 'A') +
          encrypted.substring(encrypted.length - 3);

      expect(() => decryptSecret(tampered), throwsA(anything));
    });

    test('decrypting with the wrong key fails', () async {
      const plaintext = 'secret-under-key-1';
      final encrypted = await encryptSecret(plaintext);

      ConnectorEncryptionKey.setForTesting(SecretKey(List<int>.filled(32, 99)));
      expect(() => decryptSecret(encrypted), throwsA(anything));
    });
  });
}
