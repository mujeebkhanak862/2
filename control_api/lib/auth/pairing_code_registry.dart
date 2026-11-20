/// Item 10: server-issued, short-lived, **one-time** pairing codes.
///
/// Flow: owner (ADMIN_SECRET ya pehle se paired device) `POST /pairing-codes`
/// se code leta hai -> naya device `POST /devices/pair` mein wahi code
/// bhejta hai -> code *consume* ho jaata hai (dobara use nahi ho sakta).
///
/// Security notes:
///  * Code sirf SHA-256 hash ke tor par memory mein rehta hai.
///  * 8 chars x 32-symbol alphabet = 40 bit; pairing endpoint par strict
///    per-IP rate limit hai, is liye brute-force practical nahi.
///  * Codes **persist nahi hote** — restart par sab invalid (jaan-bujh kar:
///    TTL chhota hai, disk par code rakhne ka koi fayda nahi).
///  * Active codes par cap hai (flood se bachav).
library;

import 'dart:math';

import '../util/crypto_utils.dart';

/// Confusing characters (0/O, 1/I/L) nikaal diye gaye hain.
const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const pairingCodeLength = 8;

class IssuedPairingCode {
  /// Display form, e.g. `ABCD-EFGH`.
  final String code;
  final DateTime expiresAt;
  const IssuedPairingCode(this.code, this.expiresAt);
}

class _Entry {
  final DateTime expiresAt;
  final String issuedBy;
  _Entry(this.expiresAt, this.issuedBy);
}

class PairingCodeRegistry {
  final Duration ttl;
  final int maxActive;
  final Random _rand;
  final Map<String, _Entry> _byHash = {};

  PairingCodeRegistry({
    this.ttl = const Duration(minutes: 5),
    this.maxActive = 20,
    Random? random,
  }) : _rand = random ?? Random.secure();

  /// User input ko canonical form mein laata hai (`abcd-efgh ` -> `ABCDEFGH`).
  static String normalize(String input) =>
      input.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');

  static bool looksLikeCode(String input) {
    final n = normalize(input);
    if (n.length != pairingCodeLength) return false;
    return n.split('').every(_alphabet.contains);
  }

  int get activeCount {
    _prune(DateTime.now().toUtc());
    return _byHash.length;
  }

  /// Naya code issue karta hai. Active-cap par `null`.
  IssuedPairingCode? issue({required String issuedBy, DateTime? now}) {
    final t = (now ?? DateTime.now().toUtc());
    _prune(t);
    if (_byHash.length >= maxActive) return null;
    String raw;
    String hash;
    do {
      raw = List.generate(
          pairingCodeLength, (_) => _alphabet[_rand.nextInt(_alphabet.length)]).join();
      hash = hashSecretUtil(raw);
    } while (_byHash.containsKey(hash));
    final expiresAt = t.add(ttl);
    _byHash[hash] = _Entry(expiresAt, issuedBy);
    return IssuedPairingCode('${raw.substring(0, 4)}-${raw.substring(4)}', expiresAt);
  }

  /// Read-only check (consume nahi karta).
  bool isValid(String input, {DateTime? now}) {
    final e = _byHash[hashSecretUtil(normalize(input))];
    if (e == null) return false;
    return (now ?? DateTime.now().toUtc()).isBefore(e.expiresAt);
  }

  /// Valid code ko **atomically** consume karta hai. Ek hi baar `true`.
  bool consume(String input, {DateTime? now}) {
    final t = (now ?? DateTime.now().toUtc());
    final hash = hashSecretUtil(normalize(input));
    final e = _byHash.remove(hash);
    if (e == null) return false;
    return t.isBefore(e.expiresAt);
  }

  int _prune(DateTime now) {
    final before = _byHash.length;
    _byHash.removeWhere((_, e) => !now.isBefore(e.expiresAt));
    return before - _byHash.length;
  }
}
