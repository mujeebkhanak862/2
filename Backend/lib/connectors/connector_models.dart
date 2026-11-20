/// P0-07 — connector-related data models.
library;

/// `POST /connectors/<name>/auth` call hone ke baad, jab tak callback
/// nahi aata, is waqt ka in-flight state. `state` token hi is record ki
/// key hai (`AppState.pendingConnectorAuths`).
class PendingConnectorAuth {
  final String state;
  final String codeVerifier;
  final String deviceId;
  final String connectorName;
  final DateTime createdAt;

  PendingConnectorAuth({
    required this.state,
    required this.codeVerifier,
    required this.deviceId,
    required this.connectorName,
    required this.createdAt,
  });

  /// 10 minute se purani pending authorization ab kaam nahi karni
  /// chahiye — OAuth flows ka realistic user-facing window itna hi hota
  /// hai (browser mein login karke wapas aana).
  bool get isExpired =>
      DateTime.now().toUtc().difference(createdAt) > const Duration(minutes: 10);
}

/// Ek connected connector ka stored, **encrypted** credential.
/// `encryptedAccessToken`/`encryptedRefreshToken` `credential_
/// encryption.dart`'s `encryptSecret()` output hain — kabhi bhi
/// plaintext yahan store nahi hoti.
class ConnectorCredential {
  final String deviceId;
  final String connectorName;
  String encryptedAccessToken;
  String? encryptedRefreshToken;
  DateTime accessTokenExpiresAt;
  List<String> grantedScopes;
  final DateTime connectedAt;

  ConnectorCredential({
    required this.deviceId,
    required this.connectorName,
    required this.encryptedAccessToken,
    required this.encryptedRefreshToken,
    required this.accessTokenExpiresAt,
    required this.grantedScopes,
    required this.connectedAt,
  });

  /// 60-second safety margin — refresh thodi jaldi kar lete hain taaki
  /// ek in-flight API call ke beech mein hi token expire na ho jaaye.
  bool get isAccessTokenExpiredOrExpiringSoon => DateTime.now()
      .toUtc()
      .isAfter(accessTokenExpiresAt.subtract(const Duration(seconds: 60)));

  Map<String, dynamic> toStatusJson() => {
        'connector': connectorName,
        'connected': true,
        'granted_scopes': grantedScopes,
        'connected_at': connectedAt.toIso8601String(),
        'access_token_expires_at': accessTokenExpiresAt.toIso8601String(),
      };
}
