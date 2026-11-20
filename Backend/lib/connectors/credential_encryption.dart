/// P0-07 — Connector credential encryption-at-rest.
///
/// `control_api/lib/util/crypto_utils.dart` mein jo hashing hai woh
/// **one-way** hai (API key secrets, device tokens — hum unhe kabhi
/// wapas plaintext mein nahi chahiye, sirf compare karna hota hai).
/// Connector OAuth tokens (access_token/refresh_token) is se alag hain
/// — inhe actually **use** karna padta hai (provider APIs call karne ke
/// liye), is liye reversible encryption chahiye, hashing nahi. Isi liye
/// yeh alag module hai, `package:cryptography`'s AES-GCM-256 use karke.
library;

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final _algorithm = AesGcm.with256bits();
final _secureRandom = Random.secure();

/// Master encryption key. `CONNECTOR_ENCRYPTION_KEY` env var se aata
/// hai — base64-encoded 32 bytes (`openssl rand -base64 32` se
/// generate kiya ja sakta hai).
///
/// **Agar env var set nahi hai:** process start hote hi ek random
/// ephemeral key generate hoti hai — server crash nahi hota, lekin
/// **restart par saare stored connector credentials unusable ho
/// jaate hain** (purani key se encrypt hua data naye random key se
/// decrypt nahi ho sakta) — matlab users ko dobara connect karna
/// padega. Yeh ek acceptable degraded-but-safe default hai (kabhi
/// bhi plaintext store nahi karte, chahe key mismanage ho jaaye) —
/// **production mein `CONNECTOR_ENCRYPTION_KEY` set karna strongly
/// recommended hai**, taaki restart par credentials survive karein.
class ConnectorEncryptionKey {
  static SecretKey? _cached;
  static bool warnedEphemeral = false;

  /// Kya production-grade (persistent) key configured hai? `false` => random
  /// ephemeral key use hogi aur restart par saare credentials bekaar.
  /// (Test mein `setForTesting` se inject ki gayi key bhi configured maani jati hai.)
  static bool get isConfigured {
    if (_cached != null && !_ephemeral) return true;
    final v = Platform.environment['CONNECTOR_ENCRYPTION_KEY'];
    return v != null && v.isNotEmpty;
  }

  static bool _ephemeral = false;

  static Future<SecretKey> load() async {
    if (_cached != null) return _cached!;
    final envValue = Platform.environment['CONNECTOR_ENCRYPTION_KEY'];
    if (envValue != null && envValue.isNotEmpty) {
      final List<int> bytes;
      try {
        bytes = base64.decode(envValue);
      } on FormatException {
        // Pehle raw FormatException nikalta tha (callback mein 500).
        throw StateError('CONNECTOR_ENCRYPTION_KEY valid base64 nahi hai — '
            '`openssl rand -base64 32` se generate karein');
      }
      if (bytes.length != 32) {
        throw StateError(
            'CONNECTOR_ENCRYPTION_KEY 32 bytes (base64-encoded) honi chahiye, '
            'mili ${bytes.length} bytes — `openssl rand -base64 32` se generate karein');
      }
      _cached = SecretKey(bytes);
      return _cached!;
    }
    if (!warnedEphemeral) {
      // ignore: avoid_print
      print('WARNING: CONNECTOR_ENCRYPTION_KEY set nahi hai — ek ephemeral '
          'random key use ho rahi hai. Restart par saare connector '
          'credentials invalidate ho jaayenge. Production ke liye is env '
          'var ko set karein (`openssl rand -base64 32`).');
      warnedEphemeral = true;
    }
    final randomBytes = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
    _cached = SecretKey(randomBytes);
    _ephemeral = true;
    return _cached!;
  }

  /// Sirf tests ke liye — deterministic key inject karne ke liye
  /// (varna har test run mein random key alag hoti, jo fine hai par
  /// explicit control zyada readable tests deta hai). Test isolation
  /// ke liye bhi zaroori — ek test dusre ke cached key par depend na
  /// kare.
  static void setForTesting(SecretKey key) {
    _cached = key;
  }

  static void resetForTesting() {
    _cached = null;
    _ephemeral = false;
    warnedEphemeral = false;
  }
}

/// Plaintext string ko encrypt karke ek single, self-contained base64
/// string return karta hai (`nonce || mac || ciphertext` packed) — is
/// se `ConnectorCredential` mein sirf ek field store karni padti hai
/// per secret, nonce alag se track nahi karna padta.
Future<String> encryptSecret(String plaintext) async {
  final key = await ConnectorEncryptionKey.load();
  final nonce = _algorithm.newNonce();
  final secretBox = await _algorithm.encrypt(
    utf8.encode(plaintext),
    secretKey: key,
    nonce: nonce,
  );
  final packed = Uint8List(
      nonce.length + secretBox.mac.bytes.length + secretBox.cipherText.length);
  packed.setRange(0, nonce.length, nonce);
  packed.setRange(
      nonce.length, nonce.length + secretBox.mac.bytes.length, secretBox.mac.bytes);
  packed.setRange(
      nonce.length + secretBox.mac.bytes.length, packed.length, secretBox.cipherText);
  return base64.encode(packed);
}

/// [encryptSecret] ka reverse. Corrupt/tampered data par (galat MAC)
/// `SecretBoxAuthenticationError` throw karta hai — kabhi silently
/// corrupt plaintext nahi deta.
Future<String> decryptSecret(String packedBase64) async {
  final key = await ConnectorEncryptionKey.load();
  final packed = base64.decode(packedBase64);
  const nonceLength = 12; // AES-GCM standard nonce size
  const macLength = 16; // AES-GCM standard tag size
  final nonce = packed.sublist(0, nonceLength);
  final mac = Mac(packed.sublist(nonceLength, nonceLength + macLength));
  final cipherText = packed.sublist(nonceLength + macLength);
  final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
  final clearBytes = await _algorithm.decrypt(secretBox, secretKey: key);
  return utf8.decode(clearBytes);
}
