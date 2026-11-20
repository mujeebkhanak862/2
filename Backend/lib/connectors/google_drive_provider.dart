/// P0-07 — Google Drive connector provider. Audit ka "first implement a
/// clean adapter interface, then one provider end-to-end with tests" —
/// yeh woh ek provider hai. Standard Google OAuth 2.0 Authorization
/// Code flow + PKCE (Google dono support karta hai).
///
/// Credentials: `GOOGLE_OAUTH_CLIENT_ID` + `GOOGLE_OAUTH_CLIENT_SECRET`
/// env vars — Google Cloud Console ke "OAuth 2.0 Client IDs" se milte
/// hain (Web application type, authorized redirect URI = is server ka
/// `{CONNECTOR_REDIRECT_BASE_URL}/connectors/google_drive/callback`).
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'connector_provider.dart';

class GoogleDriveConnectorProvider implements ConnectorProvider {
  @override
  String get name => 'google_drive';

  @override
  String get displayName => 'Google Drive';

  @override
  List<String> get scopes => const ['https://www.googleapis.com/auth/drive.readonly'];

  static const _authorizationEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const _revokeEndpoint = 'https://oauth2.googleapis.com/revoke';

  // `Platform.environment` seedha constructor mein read karne se yeh
  // class tests mein un-overridable ho jaati (env vars runtime par set
  // karna awkward hai). Is liye optional constructor params — na diye
  // jaayein to hi env var fallback hota hai (production behavior same
  // rehta hai), tests explicit values pass kar sakte hain.
  final String? _clientIdOverride;
  final String? _clientSecretOverride;

  String get _clientId {
    final id = _clientIdOverride ?? Platform.environment['GOOGLE_OAUTH_CLIENT_ID'];
    if (id == null || id.isEmpty) {
      throw StateError(
          'GOOGLE_OAUTH_CLIENT_ID env var set nahi hai — Google Cloud Console '
          'se OAuth client bana kar yeh set karein');
    }
    return id;
  }

  String get _clientSecret {
    final secret =
        _clientSecretOverride ?? Platform.environment['GOOGLE_OAUTH_CLIENT_SECRET'];
    if (secret == null || secret.isEmpty) {
      throw StateError('GOOGLE_OAUTH_CLIENT_SECRET env var set nahi hai');
    }
    return secret;
  }

  final http.Client _httpClient;

  /// `httpClient` inject-able hai — tests isme ek fake/mock client de
  /// sakte hain, taaki real Google servers ko hit kiye bina poora
  /// exchange/refresh/revoke flow test ho sake. `clientId`/`clientSecret`
  /// bhi inject-able hain (isi wajah se, testability).
  GoogleDriveConnectorProvider({
    http.Client? httpClient,
    String? clientId,
    String? clientSecret,
  })  : _httpClient = httpClient ?? http.Client(),
        _clientIdOverride = clientId,
        _clientSecretOverride = clientSecret;

  @override
  Uri buildAuthorizationUrl({
    required String state,
    required String codeChallenge,
    required String redirectUri,
  }) {
    return Uri.parse(_authorizationEndpoint).replace(queryParameters: {
      'client_id': _clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': scopes.join(' '),
      'access_type': 'offline', // refresh_token chahiye
      'prompt': 'consent', // har baar refresh_token guaranteed milta hai
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'state': state,
    });
  }

  @override
  Future<OAuthTokenSet> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final response = await _httpClient.post(
      Uri.parse(_tokenEndpoint),
      body: {
        'code': code,
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        'code_verifier': codeVerifier,
      },
    );
    return _parseTokenResponse(response, requireRefreshToken: true);
  }

  @override
  Future<OAuthTokenSet> refresh({required String refreshToken}) async {
    final response = await _httpClient.post(
      Uri.parse(_tokenEndpoint),
      body: {
        'refresh_token': refreshToken,
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'grant_type': 'refresh_token',
      },
    );
    // Google refresh response mein naya refresh_token usually NAHI
    // deta — purana hi wapas caller ko bata dete hain taaki woh use
    // rakh sake (caller, `connector_store.dart`, isko null se
    // overwrite nahi karta — dekhein `refreshIfNeeded`).
    return _parseTokenResponse(response, requireRefreshToken: false);
  }

  @override
  Future<void> revoke({required String token}) async {
    // Google ka revoke endpoint access_token ya refresh_token, dono
    // accept karta hai — jo bhi diya jaaye use revoke kar deta hai (aur
    // agar refresh_token diya jaaye to us se derive hui saari access
    // tokens bhi implicitly invalid ho jaati hain).
    final response = await _httpClient.post(
      Uri.parse(_revokeEndpoint),
      body: {'token': token},
    );
    if (response.statusCode != 200) {
      throw StateError(
          'Google revoke endpoint ne ${response.statusCode} diya: ${response.body}');
    }
  }

  /// **End-to-end proof action** — audit: "first implement a clean
  /// adapter interface, then one provider end-to-end with tests." Yeh
  /// wahi ek real action hai jo dikhata hai ke poora OAuth flow
  /// (auth -> callback -> encrypted storage -> yeh call -> refresh
  /// agar zaroorat pade) waqai kaam karta hai, sirf token store karke
  /// nahi ruk jaata.
  ///
  /// Google Drive API v3 `files.list` — sirf naam + id (minimal, koi
  /// extra scope/permission ki zaroorat nahi jo already grant nahi hui).
  /// Item 86: file download (read-only scope `drive.readonly` kaafi hai).
  /// Google-native files (Docs/Sheets/Slides) `alt=media` se nahi aati —
  /// unko text/CSV/PDF mein export karte hain.
  Future<ConnectorFileContent> downloadFile(String accessToken, String fileId,
      {int maxBytes = connectorMaxDownloadBytes}) async {
    // fileId sirf Drive-id characters (path injection nahi).
    if (!RegExp(r'^[A-Za-z0-9_\-]{5,128}$').hasMatch(fileId)) {
      throw ArgumentError('fileId invalid hai');
    }
    final headers = {'Authorization': 'Bearer $accessToken'};
    final metaRes = await _httpClient.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId')
          .replace(queryParameters: {'fields': 'id,name,mimeType,size'}),
      headers: headers,
    );
    if (metaRes.statusCode != 200) {
      throw StateError(
          'Google Drive files.get ne ${metaRes.statusCode} diya: ${metaRes.body}');
    }
    final meta = jsonDecode(metaRes.body) as Map<String, dynamic>;
    final mime = meta['mimeType'] as String?;
    final name = (meta['name'] as String?) ?? fileId;
    final declaredSize = int.tryParse('${meta['size'] ?? ''}');
    if (declaredSize != null && declaredSize > maxBytes) {
      throw ConnectorFileTooLarge(maxBytes);
    }

    Uri uri;
    String? outMime = mime;
    if (mime != null && mime.startsWith('application/vnd.google-apps.')) {
      const exports = {
        'application/vnd.google-apps.document': 'text/plain',
        'application/vnd.google-apps.spreadsheet': 'text/csv',
        'application/vnd.google-apps.presentation': 'application/pdf',
      };
      final target = exports[mime];
      if (target == null) {
        throw StateError('Is Google-native file type ($mime) ka export supported nahi');
      }
      outMime = target;
      uri = Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId/export')
          .replace(queryParameters: {'mimeType': target});
    } else {
      uri = Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId')
          .replace(queryParameters: {'alt': 'media'});
    }
    final res = await _httpClient.get(uri, headers: headers);
    if (res.statusCode != 200) {
      throw StateError('Google Drive download ne ${res.statusCode} diya: ${res.body}');
    }
    if (res.bodyBytes.length > maxBytes) throw ConnectorFileTooLarge(maxBytes);
    return ConnectorFileContent(name: name, mimeType: outMime, bytes: res.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> listFiles(String accessToken,
      {int pageSize = 20}) async {
    final response = await _httpClient.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files').replace(
        queryParameters: {
          'pageSize': '$pageSize',
          'fields': 'files(id,name,mimeType,modifiedTime)',
        },
      ),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) {
      throw StateError(
          'Google Drive files.list ne ${response.statusCode} diya: ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['files'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  OAuthTokenSet _parseTokenResponse(http.Response response,
      {required bool requireRefreshToken}) {
    if (response.statusCode != 200) {
      throw StateError(
          'Google token endpoint ne ${response.statusCode} diya: ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = json['access_token'] as String?;
    if (accessToken == null) {
      throw StateError('Google token response mein "access_token" missing hai');
    }
    final refreshToken = json['refresh_token'] as String?;
    if (requireRefreshToken && refreshToken == null) {
      // Yeh ho sakta hai agar `access_type=offline`/`prompt=consent`
      // sahi se nahi bheja gaya — clear error taaki debug karna aasan ho.
      throw StateError(
          'Google ne "refresh_token" nahi diya — authorization request mein '
          '"access_type=offline" aur "prompt=consent" check karein');
    }
    final expiresInSeconds = (json['expires_in'] as num?)?.toInt() ?? 3600;
    final scopeString = json['scope'] as String? ?? '';
    return OAuthTokenSet(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpiresAt:
          DateTime.now().toUtc().add(Duration(seconds: expiresInSeconds)),
      grantedScopes: scopeString.isEmpty ? const [] : scopeString.split(' '),
    );
  }
}
