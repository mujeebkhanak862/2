/// P0-07 — Connector provider adapter interface.
///
/// Har external service (Google Drive, Slack, waghera) is interface ko
/// implement karta hai. Naya connector add karna matlab sirf ek nayi
/// class likhna aur `connector_registry.dart` mein register karna —
/// baaki poora OAuth/PKCE/encryption/refresh flow (`routes/
/// connectors.dart`) already generic hai, kisi bhi provider ke liye
/// same rehta hai.
library;

/// Ek successful token exchange/refresh ka result — provider-agnostic
/// shape.
/// Item 86: connector se download hui file (bytes + metadata). Chhoti files
/// ke liye hi (`maxBytes`), kyunki base64 mein poori memory mein aati hain.
class ConnectorFileContent {
  final String name;
  final String? mimeType;
  final List<int> bytes;
  const ConnectorFileContent({required this.name, required this.mimeType, required this.bytes});
}

/// File `maxBytes` se badi hai.
class ConnectorFileTooLarge implements Exception {
  final int maxBytes;
  const ConnectorFileTooLarge(this.maxBytes);
  @override
  String toString() => 'File $maxBytes bytes se badi hai';
}

/// Connector download limit (5 MiB) — response + base64 memory mein banta hai.
const connectorMaxDownloadBytes = 5 * 1024 * 1024;

class OAuthTokenSet {
  final String accessToken;
  final String? refreshToken; // kuch providers refresh par naya refresh_token nahi dete
  final DateTime accessTokenExpiresAt;
  final List<String> grantedScopes;

  OAuthTokenSet({
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiresAt,
    required this.grantedScopes,
  });
}

abstract class ConnectorProvider {
  /// URL-safe identifier — `/connectors/<name>/...` routes mein use hota hai.
  String get name;

  /// Human-readable label (dashboard UI ke liye).
  String get displayName;

  List<String> get scopes;

  /// Authorization URL banata hai jahan user ko redirect karna hai
  /// (browser mein). `state` aur `codeChallenge` already generate ho
  /// chuke hote hain (`pkce.dart`) — yeh method sirf provider-specific
  /// URL format banata hai.
  Uri buildAuthorizationUrl({
    required String state,
    required String codeChallenge,
    required String redirectUri,
  });

  /// Callback se mile `code` ko access/refresh tokens se exchange karta
  /// hai. Network call yahan hoti hai — provider ke token endpoint ko.
  Future<OAuthTokenSet> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  });

  /// Expired access token ko refresh karta hai. Kuch providers naya
  /// `refresh_token` nahi dete (purana hi reuse hota hai) — is liye
  /// `OAuthTokenSet.refreshToken` nullable hai, caller ko purana wala
  /// hi rakhna chahiye agar naya na mile.
  Future<OAuthTokenSet> refresh({required String refreshToken});

  /// Token revoke karta hai provider ki taraf se bhi (sirf local delete
  /// kaafi nahi — audit: "revoke removes access"). Best-effort hai —
  /// agar provider ka revoke endpoint fail ho (network issue, ya token
  /// already expired), local credential phir bhi delete hoti hai
  /// (`routes/connectors.dart` mein) taaki user ka access kam-se-kam
  /// is server se turant chala jaaye.
  Future<void> revoke({required String token});
}
