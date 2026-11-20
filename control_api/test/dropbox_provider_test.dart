import 'dart:convert';

import 'package:control_api/connectors/dropbox_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// P0-07 extension — Dropbox as a second connector provider, proving
/// the `ConnectorProvider` adapter interface generalizes beyond Google
/// Drive (including a provider whose revoke mechanism is genuinely
/// different — Bearer header instead of a body param).
void main() {
  group('DropboxConnectorProvider (P0-07 second provider)', () {
    test('buildAuthorizationUrl includes PKCE + state + correct client_id', () {
      final provider =
          DropboxConnectorProvider(appKey: 'test-app-key', appSecret: 'test-secret');

      final url = provider.buildAuthorizationUrl(
        state: 'my-state-token',
        codeChallenge: 'my-code-challenge',
        redirectUri: 'https://example.com/connectors/dropbox/callback',
      );

      expect(url.host, 'www.dropbox.com');
      final q = url.queryParameters;
      expect(q['client_id'], 'test-app-key');
      expect(q['state'], 'my-state-token');
      expect(q['code_challenge'], 'my-code-challenge');
      expect(q['code_challenge_method'], 'S256');
      expect(q['response_type'], 'code');
      expect(q['token_access_type'], 'offline');
      expect(q['redirect_uri'], 'https://example.com/connectors/dropbox/callback');
    });

    test('buildAuthorizationUrl throws a clear error when app key missing', () {
      final provider = DropboxConnectorProvider(appSecret: 'secret-only');
      expect(
        () => provider.buildAuthorizationUrl(
            state: 's', codeChallenge: 'c', redirectUri: 'https://example.com/cb'),
        throwsA(isA<StateError>()),
      );
    });

    test('exchangeCode parses access_token + refresh_token from a successful response', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.toString(), 'https://api.dropboxapi.com/oauth2/token');
        final body = Uri(query: request.body).queryParameters;
        expect(body['code'], 'auth-code-123');
        expect(body['grant_type'], 'authorization_code');
        expect(body['code_verifier'], 'verifier-abc');
        return http.Response(
          jsonEncode({
            'access_token': 'access-token-xyz',
            'refresh_token': 'refresh-token-xyz',
            'expires_in': 14400,
            'scope': 'files.metadata.read files.content.read',
            'token_type': 'bearer',
          }),
          200,
        );
      });
      final provider =
          DropboxConnectorProvider(httpClient: mockClient, appKey: 'id', appSecret: 'secret');

      final tokens = await provider.exchangeCode(
        code: 'auth-code-123',
        codeVerifier: 'verifier-abc',
        redirectUri: 'https://example.com/cb',
      );

      expect(tokens.accessToken, 'access-token-xyz');
      expect(tokens.refreshToken, 'refresh-token-xyz');
      expect(tokens.grantedScopes, ['files.metadata.read', 'files.content.read']);
    });

    test('exchangeCode throws clearly when Dropbox omits refresh_token', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'access_token': 'access-only', 'expires_in': 14400}),
          200,
        );
      });
      final provider =
          DropboxConnectorProvider(httpClient: mockClient, appKey: 'id', appSecret: 'secret');

      expect(
        () => provider.exchangeCode(
            code: 'c', codeVerifier: 'v', redirectUri: 'https://example.com/cb'),
        throwsA(isA<StateError>()),
      );
    });

    test('exchangeCode throws on a non-200 response', () async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({'error_description': 'invalid_grant'}), 400);
      });
      final provider =
          DropboxConnectorProvider(httpClient: mockClient, appKey: 'id', appSecret: 'secret');

      expect(
        () => provider.exchangeCode(
            code: 'bad-code', codeVerifier: 'v', redirectUri: 'https://example.com/cb'),
        throwsA(isA<StateError>()),
      );
    });

    test('refresh does not require a refresh_token in the response (Dropbox omits it too)',
        () async {
      final mockClient = MockClient((request) async {
        final body = Uri(query: request.body).queryParameters;
        expect(body['grant_type'], 'refresh_token');
        expect(body['refresh_token'], 'my-refresh-token');
        return http.Response(
          jsonEncode({'access_token': 'new-access-token', 'expires_in': 14400}),
          200,
        );
      });
      final provider =
          DropboxConnectorProvider(httpClient: mockClient, appKey: 'id', appSecret: 'secret');

      final tokens = await provider.refresh(refreshToken: 'my-refresh-token');
      expect(tokens.accessToken, 'new-access-token');
      expect(tokens.refreshToken, isNull);
    });

    test('revoke sends the token as a Bearer header (NOT a body param — different from Google)',
        () async {
      var called = false;
      final mockClient = MockClient((request) async {
        called = true;
        expect(request.url.toString(), 'https://api.dropboxapi.com/2/auth/token/revoke');
        expect(request.headers['Authorization'], 'Bearer token-to-revoke');
        return http.Response('', 200);
      });
      final provider =
          DropboxConnectorProvider(httpClient: mockClient, appKey: 'id', appSecret: 'secret');

      await provider.revoke(token: 'token-to-revoke');
      expect(called, isTrue);
    });

    test('revoke throws on a non-200 response', () async {
      final mockClient = MockClient((request) async => http.Response('bad', 400));
      final provider =
          DropboxConnectorProvider(httpClient: mockClient, appKey: 'id', appSecret: 'secret');

      expect(() => provider.revoke(token: 'x'), throwsA(isA<StateError>()));
    });

    test('listFiles sends the bearer token + JSON body and parses entries', () async {
      final mockClient = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer my-access-token');
        expect(request.url.host, 'api.dropboxapi.com');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['path'], '');
        return http.Response(
          jsonEncode({
            'entries': [
              {'.tag': 'file', 'id': 'id:1', 'name': 'doc.pdf', 'path_display': '/doc.pdf'},
              {'.tag': 'folder', 'id': 'id:2', 'name': 'Photos', 'path_display': '/Photos'},
            ]
          }),
          200,
        );
      });
      final provider =
          DropboxConnectorProvider(httpClient: mockClient, appKey: 'id', appSecret: 'secret');

      final files = await provider.listFiles('my-access-token');
      expect(files.length, 2);
      expect(files.first['name'], 'doc.pdf');
      expect(files.first['tag'], 'file');
      expect(files.last['tag'], 'folder');
    });
  });
}
