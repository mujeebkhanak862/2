import 'dart:convert';

import 'package:control_api/connectors/google_drive_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleDriveConnectorProvider (P0-07)', () {
    test('buildAuthorizationUrl includes PKCE + state + correct client_id', () {
      final provider = GoogleDriveConnectorProvider(
          clientId: 'test-client-id', clientSecret: 'test-secret');

      final url = provider.buildAuthorizationUrl(
        state: 'my-state-token',
        codeChallenge: 'my-code-challenge',
        redirectUri: 'https://example.com/connectors/google_drive/callback',
      );

      expect(url.host, 'accounts.google.com');
      final q = url.queryParameters;
      expect(q['client_id'], 'test-client-id');
      expect(q['state'], 'my-state-token');
      expect(q['code_challenge'], 'my-code-challenge');
      expect(q['code_challenge_method'], 'S256');
      expect(q['response_type'], 'code');
      expect(q['access_type'], 'offline'); // refresh_token ke liye zaroori
      expect(q['redirect_uri'], 'https://example.com/connectors/google_drive/callback');
    });

    test('buildAuthorizationUrl throws a clear error when client_id missing', () {
      final provider = GoogleDriveConnectorProvider(clientSecret: 'secret-only');
      expect(
        () => provider.buildAuthorizationUrl(
            state: 's', codeChallenge: 'c', redirectUri: 'https://example.com/cb'),
        throwsA(isA<StateError>()),
      );
    });

    test('exchangeCode parses access_token + refresh_token from a successful response', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.toString(), 'https://oauth2.googleapis.com/token');
        final body = Uri(query: request.body).queryParameters;
        expect(body['code'], 'auth-code-123');
        expect(body['grant_type'], 'authorization_code');
        expect(body['code_verifier'], 'verifier-abc');
        return http.Response(
          jsonEncode({
            'access_token': 'access-token-xyz',
            'refresh_token': 'refresh-token-xyz',
            'expires_in': 3600,
            'scope': 'https://www.googleapis.com/auth/drive.readonly',
            'token_type': 'Bearer',
          }),
          200,
        );
      });
      final provider = GoogleDriveConnectorProvider(
          httpClient: mockClient, clientId: 'id', clientSecret: 'secret');

      final tokens = await provider.exchangeCode(
        code: 'auth-code-123',
        codeVerifier: 'verifier-abc',
        redirectUri: 'https://example.com/cb',
      );

      expect(tokens.accessToken, 'access-token-xyz');
      expect(tokens.refreshToken, 'refresh-token-xyz');
      expect(tokens.grantedScopes, ['https://www.googleapis.com/auth/drive.readonly']);
      expect(tokens.accessTokenExpiresAt.isAfter(DateTime.now().toUtc()), isTrue);
    });

    test('exchangeCode throws clearly when Google omits refresh_token', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'access_token': 'access-only', 'expires_in': 3600}),
          200,
        );
      });
      final provider = GoogleDriveConnectorProvider(
          httpClient: mockClient, clientId: 'id', clientSecret: 'secret');

      expect(
        () => provider.exchangeCode(
            code: 'c', codeVerifier: 'v', redirectUri: 'https://example.com/cb'),
        throwsA(isA<StateError>()),
      );
    });

    test('exchangeCode throws on a non-200 response, without leaking to a generic error', () async {
      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
      });
      final provider = GoogleDriveConnectorProvider(
          httpClient: mockClient, clientId: 'id', clientSecret: 'secret');

      expect(
        () => provider.exchangeCode(
            code: 'bad-code', codeVerifier: 'v', redirectUri: 'https://example.com/cb'),
        throwsA(isA<StateError>()),
      );
    });

    test('refresh does not require a refresh_token in the response (Google usually omits it)',
        () async {
      final mockClient = MockClient((request) async {
        final body = Uri(query: request.body).queryParameters;
        expect(body['grant_type'], 'refresh_token');
        expect(body['refresh_token'], 'my-refresh-token');
        return http.Response(
          jsonEncode({
            'access_token': 'new-access-token',
            'expires_in': 3600,
            'scope': 'https://www.googleapis.com/auth/drive.readonly',
          }),
          200,
        );
      });
      final provider = GoogleDriveConnectorProvider(
          httpClient: mockClient, clientId: 'id', clientSecret: 'secret');

      final tokens = await provider.refresh(refreshToken: 'my-refresh-token');
      expect(tokens.accessToken, 'new-access-token');
      expect(tokens.refreshToken, isNull); // no re-throw just because it's absent
    });

    test('revoke posts the token and succeeds on 200', () async {
      var called = false;
      final mockClient = MockClient((request) async {
        called = true;
        expect(request.url.toString(), 'https://oauth2.googleapis.com/revoke');
        final body = Uri(query: request.body).queryParameters;
        expect(body['token'], 'token-to-revoke');
        return http.Response('', 200);
      });
      final provider = GoogleDriveConnectorProvider(
          httpClient: mockClient, clientId: 'id', clientSecret: 'secret');

      await provider.revoke(token: 'token-to-revoke');
      expect(called, isTrue);
    });

    test('revoke throws on a non-200 response', () async {
      final mockClient = MockClient((request) async => http.Response('bad', 400));
      final provider = GoogleDriveConnectorProvider(
          httpClient: mockClient, clientId: 'id', clientSecret: 'secret');

      expect(() => provider.revoke(token: 'x'), throwsA(isA<StateError>()));
    });

    test('listFiles sends the bearer token and parses file list', () async {
      final mockClient = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer my-access-token');
        expect(request.url.host, 'www.googleapis.com');
        return http.Response(
          jsonEncode({
            'files': [
              {'id': '1', 'name': 'doc.pdf', 'mimeType': 'application/pdf'},
              {'id': '2', 'name': 'sheet.xlsx', 'mimeType': 'application/vnd.ms-excel'},
            ]
          }),
          200,
        );
      });
      final provider = GoogleDriveConnectorProvider(
          httpClient: mockClient, clientId: 'id', clientSecret: 'secret');

      final files = await provider.listFiles('my-access-token');
      expect(files.length, 2);
      expect(files.first['name'], 'doc.pdf');
    });
  });
}
