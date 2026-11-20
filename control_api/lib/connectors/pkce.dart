/// P0-07 — PKCE (Proof Key for Code Exchange, RFC 7636) helpers.
///
/// OAuth "Authorization Code" flow akela CSRF/code-interception attacks
/// se vulnerable hota hai; PKCE (`code_verifier` + `code_challenge`) is
/// ka standard, provider-agnostic fix hai — Google, Microsoft, GitHub,
/// Slack sab isko support karte hain. `state` alag se CSRF ke liye hai
/// (callback ka request asli hamare hi shuru kiye gaye flow se aaya,
/// koi forged redirect nahi).
library;

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

final _secureRandom = Random.secure();

/// RFC 7636, Section 4.1 — `code_verifier`: 43-128 characters, sirf
/// `[A-Z] [a-z] [0-9] - . _ ~`. 32 random bytes ko base64url (no
/// padding) encode karke banate hain — 43 characters milte hain,
/// spec-compliant.
String generateCodeVerifier() {
  final bytes = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// RFC 7636, Section 4.2 — `code_challenge` = BASE64URL-ENCODE(SHA256(
/// ASCII(code_verifier))), method `S256` (plain method jaan-bujh kar
/// support nahi kiya — S256 hi safe hai, spec bhi isi ko recommend
/// karta hai jab server-side support ho).
String codeChallengeFromVerifier(String verifier) {
  final digest = sha256.convert(ascii.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// CSRF `state` parameter — callback isi se verify karta hai ke yeh
/// response humare hi shuru kiye flow ka hai.
String generateStateToken() {
  final bytes = List<int>.generate(24, (_) => _secureRandom.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
