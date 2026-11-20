/// P0-07 — Dropbox connector provider. Google Drive `ConnectorProvider`
/// implementation ke saath, yeh doosra provider dikhata hai ke adapter
/// interface (`connector_provider.dart`) generic hai — koi bhi naya
/// provider add karna sirf yeh ek file likhna hai, `routes/
/// connectors.dart`, encryption, refresh-scheduling, sab kuch already
/// generic/reusable hai (dobara nahi likha).
///
/// Standard OAuth 2.0 Authorization Code flow + PKCE (Dropbox dono
/// support karta hai). Google se ek jagah alag hai (jaan-bujh kar yahan
/// document kiya, taaki adapter interface ki generality clearly dikhe):
/// **token revocation** — Google token ko POST body mein leta hai,
/// Dropbox token ko `Authorization: Bearer` header mein maangta hai. Yeh
/// difference `ConnectorProvider.revoke()` ke andar hi encapsulated
/// rehta hai — caller (`connector_store.dart`) ko iska pata hi nahi
/// chalta, exactly jaisa ek clean adapter boundary hona chahiye.
///
/// Credentials: `DROPBOX_APP_KEY` + `DROPBOX_APP_SECRET` env vars —
/// Dropbox App Console se milte hain (redirect URI = is server ka
/// `{CONNECTOR_REDIRECT_BASE_URL}/connectors/dropbox/callback`).
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'connector_provider.dart';

class DropboxConnectorProvider implements ConnectorProvider {
  @override
  String get name => 'dropbox';

  @override
  String get displayName => 'Dropbox';

  // `files.metadata.read` — sirf list/read, koi write/delete scope nahi
  // (Google Drive provider ke `drive.readonly` jaisa hi, least-privilege).
  @override
  List<String> get scopes => const ['files.metadata.read', 'files.content.read'];

  static const _authorizationEndpoint = 'https://www.dropbox.com/oauth2/authorize';
  static const _tokenEndpoint = 'https://api.dropboxapi.com/oauth2/token';
  static const _revokeEndpoint = 'https://api.dropboxapi.com/2/auth/token/revoke';
  static const _listFolderEndpoint = 'https://api.dropboxapi.com/2/files/list_folder';

  final String? _appKeyOverride;
  final String? _appSecretOverride;

  String get _appKey {
    final key = _appKeyOverride ?? Platform.environment['DROPBOX_APP_KEY'];
    if (key == null || key.isEmpty) {
      throw StateError(
          'DROPBOX_APP_KEY env var set nahi hai — Dropbox App Console se app '
          'bana kar yeh set karein');
    }
    return key;
  }

  String get _appSecret {
    final secret = _appSecretOverride ?? Platform.environment['DROPBOX_APP_SECRET'];
    if (secret == null || secret.isEmpty) {
      throw StateError('DROPBOX_APP_SECRET env var set nahi hai');
    }
    return secret;
  }

  final http.Client _httpClient;

  /// Google Drive provider jaisa hi pattern — `httpClient`/`appKey`/
  /// `appSecret` sab inject-able hain, taaki tests real Dropbox servers
  /// hit kiye bina poora flow (auth URL build, exchange, refresh, revoke,
  /// list) verify kar sakein.
  DropboxConnectorProvider({
    http.Client? httpClient,
    String? appKey,
    String? appSecret,
  })  : _httpClient = httpClient ?? http.Client(),
        _appKeyOverride = appKey,
        _appSecretOverride = appSecret;

  @override
  Uri buildAuthorizationUrl({
    required String state,
    required String codeChallenge,
    required String redirectUri,
  }) {
    return Uri.parse(_authorizationEndpoint).replace(queryParameters: {
      'client_id': _appKey,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'token_access_type': 'offline', // refresh_token chahiye
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'state': state,
      // Dropbox scopes ko authorize-URL par bhejna optional hai (app ki
      // apni console-configured "permissions" bhi apply hoti hain), lekin
      // explicit rehna behtar — jo bhi extra ho woh clearly declared hai.
      'scope': scopes.join(' '),
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
        'client_id': _appKey,
        'client_secret': _appSecret,
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
        'client_id': _appKey,
        'client_secret': _appSecret,
        'grant_type': 'refresh_token',
      },
    );
    // Dropbox bhi refresh response mein naya refresh_token nahi deta
    // (Google jaisa hi) — purana hi caller ko wapas bata dete hain.
    return _parseTokenResponse(response, requireRefreshToken: false);
  }

  @override
  Future<void> revoke({required String token}) async {
    // Google se alag: Dropbox jis token ko revoke karna hai USE HI
    // `Authorization: Bearer` header mein maangta hai (body mein nahi) —
    // is provider ke andar hi yeh difference handle ho jaata hai, caller
    // ko iska pata nahi chalta (dekhein file-level doc comment).
    final response = await _httpClient.post(
      Uri.parse(_revokeEndpoint),
      headers: {'Authorization': 'Bearer $token'},
    );
    // Dropbox revoke success par khaali body ke saath 200 deta hai.
    if (response.statusCode != 200) {
      throw StateError(
          'Dropbox revoke endpoint ne ${response.statusCode} diya: ${response.body}');
    }
  }

  /// **End-to-end proof action** (Google Drive provider ke `listFiles`
  /// jaisa hi role) — Dropbox API v2 `files/list_folder`, root folder
  /// (`path: ""`), sirf naam/id/path (minimal fields).
  /// Item 86: file download (`files.content.read` scope pehle se hai).
  /// `path` Dropbox path (`/folder/file.txt`) ya `id:...`.
  Future<ConnectorFileContent> downloadFile(String accessToken, String path,
      {int maxBytes = connectorMaxDownloadBytes}) async {
    if (path.isEmpty || path.length > 1024 || path.contains('\u0000')) {
      throw ArgumentError('path invalid hai');
    }
    final res = await _httpClient.post(
      Uri.parse('https://content.dropboxapi.com/2/files/download'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        // Dropbox path header mein JSON hota hai; non-ASCII ke liye escape.
        'Dropbox-API-Arg': jsonEncode({'path': path}).replaceAllMapped(
            RegExp(r'[\u0080-\uffff]'),
            (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}'),
      },
    );
    if (res.statusCode != 200) {
      throw StateError('Dropbox files/download ne ${res.statusCode} diya: ${res.body}');
    }
    if (res.bodyBytes.length > maxBytes) throw ConnectorFileTooLarge(maxBytes);
    String name = path.split('/').last;
    final apiResult = res.headers['dropbox-api-result'];
    if (apiResult != null) {
      try {
        final meta = jsonDecode(apiResult) as Map<String, dynamic>;
        name = (meta['name'] as String?) ?? name;
      } catch (_) {}
    }
    return ConnectorFileContent(
        name: name, mimeType: res.headers['content-type'], bytes: res.bodyBytes);
  }

  Future<List<Map<String, dynamic>>> listFiles(String accessToken,
      {int pageSize = 20}) async {
    final response = await _httpClient.post(
      Uri.parse(_listFolderEndpoint),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'path': '',
        'limit': pageSize,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError(
          'Dropbox files/list_folder ne ${response.statusCode} diya: ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final entries = (json['entries'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    return entries
        .map((e) => {
              'id': e['id'],
              'name': e['name'],
              'path': e['path_display'],
              'tag': e['.tag'], // "file" ya "folder"
            })
        .toList();
  }

  OAuthTokenSet _parseTokenResponse(http.Response response,
      {required bool requireRefreshToken}) {
    if (response.statusCode != 200) {
      throw StateError(
          'Dropbox token endpoint ne ${response.statusCode} diya: ${response.body}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final accessToken = json['access_token'] as String?;
    if (accessToken == null) {
      throw StateError('Dropbox token response mein "access_token" missing hai');
    }
    final refreshToken = json['refresh_token'] as String?;
    if (requireRefreshToken && refreshToken == null) {
      throw StateError(
          'Dropbox ne "refresh_token" nahi diya — authorization request mein '
          '"token_access_type=offline" check karein');
    }
    final expiresInSeconds = (json['expires_in'] as num?)?.toInt() ?? 14400; // Dropbox default ~4h
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
