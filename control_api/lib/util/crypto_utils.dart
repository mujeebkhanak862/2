/// P0-06 — Secret Handling: ek hi, shared hashing implementation.
///
/// Pehle `ApiKeyRecord` apna secret SHA-256 se hash karke store karta
/// tha (sahi tha), lekin `Device.bearerToken` — jo security-wise
/// bilkul utni hi sensitive cheez hai (isi se device authenticate hota
/// hai, API keys banti hain) — **plaintext** store hota tha, dono
/// memory mein aur disk par (`persistence.dart`). Yeh asymmetry hi is
/// item ka sabse bada gap tha. Ab dono ek hi shared function use karte
/// hain, taaki security-critical hashing logic sirf **ek** jagah ho.
library;

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// SHA-256 hash, hex string ke tor par — secrets/tokens ko "at rest"
/// (memory + disk) store karne ke liye. Plaintext value kabhi bhi is
/// function ke bahar persist nahi hona chahiye.
///
/// (Naam jaan-bujh kar `hashSecretUtil` hai, `hashSecret` nahi —
/// `ApiKeyRecord.hashSecret` bhi ek static method hai usi naam se; agar
/// yahan bhi wahi naam hota to us class ke andar se call karna khud
/// ke upar hi recurse kar jaata.)
String hashSecretUtil(String secret) =>
    sha256.convert(utf8.encode(secret)).toString();

/// Item 22: constant-time string comparison — secret hashes ko compare
/// karte waqt early-exit (`==`) timing leak de sakta hai. Yeh function
/// hamesha poori length tak chalta hai.
bool constantTimeEquals(String a, String b) {
  final aUnits = a.codeUnits;
  final bUnits = b.codeUnits;
  var diff = aUnits.length ^ bUnits.length;
  final len = aUnits.length < bUnits.length ? aUnits.length : bUnits.length;
  for (var i = 0; i < len; i++) {
    diff |= aUnits[i] ^ bUnits[i];
  }
  return diff == 0;
}

/// Item 19: cryptographically-secure random hex string, `bytes` bytes
/// (yani `2 * bytes` hex chars). 16 bytes = 128-bit.
String randomHex(int bytes) {
  final rand = Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    sb.write(rand.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
