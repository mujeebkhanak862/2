/// Audit fix (P0-03, Section 13): "Direct server still listens plaintext
/// when TLS env vars are absent, so deployment must be configured
/// correctly." — is file mein woh decision logic hai jo pehle purely
/// `bin/server.dart`'s `main()` ke andar thi (isliye test hi nahi ho
/// sakti thi). Ab ek pure function hai, testable.
library;

/// Kya server `0.0.0.0` (sab interfaces) par bind ho, ya sirf
/// `127.0.0.1` (localhost, safe default)?
///
/// **Secure by default**: agar koi bhi TLS signal nahi hai (na direct
/// cert/key, na explicit "haan mere saamne proxy hai" opt-in), to
/// localhost-only — koi bhi bahar se galti se plaintext par connect
/// nahi kar sakta, chahe operator deployment config mein kuch bhool hi
/// kyun na gaya ho.
bool shouldBindAllInterfaces({
  required bool hasDirectTls,
  required bool behindTlsProxy,
}) =>
    hasDirectTls || behindTlsProxy;

/// `BEHIND_TLS_PROXY` env var ki value ko boolean mein parse karta hai.
/// Sirf case-insensitive `"true"` hi opt-in count hota hai — koi bhi
/// aur value (`"1"`, `"yes"`, typo, empty, missing) safe default
/// (`false`) maani jaati hai. Yeh jaan-bujh kar strict hai: production
/// exposure jaisa consequential flag "1"/"yes" jaisi loose matching se
/// accidentally trigger nahi hona chahiye.
bool parseBehindTlsProxy(String? value) => value?.toLowerCase() == 'true';
