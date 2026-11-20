/// P0-07 — Real Connector OAuth + Token Lifecycle.
///
/// Pehle `POST /connectors/{name}/auth` ek explicit stub tha
/// (`{"status": "not_implemented"}`). Ab yeh poora, real flow hai:
///   1. `POST /connectors/<name>/auth` — PKCE + state generate karta
///      hai, authorization URL deta hai.
///   2. `GET /connectors/<name>/callback` — provider redirect yahan
///      aata hai, code ko tokens se exchange karta hai, **encrypted**
///      store karta hai.
///   3. `GET /connectors` — is device ke saare connectors ka status;
///      **connected na ho to koi actions expose nahi hote** (audit:
///      "Connector capability tabhi expose ho jab authentication
///      successful ho").
///   4. `POST /connectors/<name>/disconnect` — provider-side revoke +
///      local delete.
///   5. `GET /connectors/google_drive/files` — ek real, end-to-end
///      action (audit: "first implement a clean adapter interface,
///      then one provider end-to-end").
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/device_auth.dart';
import '../connectors/connector_models.dart';
import '../connectors/connector_provider.dart';
import '../connectors/connector_registry.dart';
import '../connectors/credential_encryption.dart';
import '../connectors/dropbox_provider.dart';
import '../connectors/google_drive_provider.dart';
import '../connectors/pkce.dart';
import '../models/activity.dart';
import '../models/api_key.dart';
import '../models/device.dart';
import '../models/errors.dart';
import '../storage/app_state.dart';
import '../util/http_utils.dart';

Router connectorRoutes(AppState state) {
  final router = Router();

  // GET /connectors — is device ke liye har registered connector ka
  // status. **Yahi woh jagah hai jahan gating hoti hai**: `connected:
  // false` wale connector ke liye `available_actions` khaali hoti hai —
  // client ko pata chal jaata hai ke abhi kuch call-able nahi hai bina
  // pehle authenticate kiye.
  router.get('/connectors', (Request request) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');
    final deviceId = (device as dynamic).id as String;

    final result = <Map<String, dynamic>>[];
    for (final provider in allConnectorProviders()) {
      final credential = state.connectorCredentialFor(deviceId, provider.name);
      // Credential store mein hai lekin decrypt nahi ho sakta (encryption key
      // badli/ephemeral key restart ke baad) => actions kaam nahi karenge, to
      // "connected" bolna jhooth hoga. Status sach batao + reconnect flag.
      var usable = credential != null;
      if (credential != null) {
        try {
          await decryptSecret(credential.encryptedAccessToken);
        } catch (_) {
          usable = false;
        }
      }
      result.add({
        'connector': provider.name,
        'display_name': provider.displayName,
        if (credential != null) ...(credential.toStatusJson()..remove('connector')),
        'connected': usable,
        'reconnect_required': credential != null && !usable,
        'available_actions': usable ? _actionsFor(provider.name) : <String>[],
      });
    }
    return Response.ok(jsonEncode(result), headers: {'content-type': 'application/json'});
  });

  // POST /connectors/<name>/auth — OAuth flow shuru karta hai.
  router.post('/connectors/<name>/auth', (Request request, String name) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');
    final deviceId = (device as dynamic).id as String;

    final provider = connectorProviderByName(name);
    if (provider == null) {
      return ApiError.notFound('Unknown connector "$name"');
    }

    final redirectBase = Platform.environment['CONNECTOR_REDIRECT_BASE_URL'];
    if (redirectBase == null || redirectBase.isEmpty) {
      return ApiError.internal(
          'Server misconfigured: CONNECTOR_REDIRECT_BASE_URL env var set nahi '
          'hai (isi se provider ko sahi callback URL bataya jaata hai)');
    }

    // Bina persistent key ke OAuth poora karwana bekaar hai: restart par token
    // decrypt nahi hoga aur user ko dobara connect karna padega.
    if (!ConnectorEncryptionKey.isConfigured) {
      return ApiError.internal(
          'Server misconfigured: CONNECTOR_ENCRYPTION_KEY set nahi hai '
          '(`openssl rand -base64 32`) — bina iske connector credentials '
          'restart par kho jate hain.');
    }

    String clientErrorMessage;
    try {
      // Client credentials abhi hi verify kar lete hain (fail-fast) —
      // taaki user ko poore OAuth round-trip ke baad jaakar pata na
      // chale ke server hi misconfigured tha.
      provider.buildAuthorizationUrl(
        state: 'preflight-check',
        codeChallenge: 'preflight-check',
        redirectUri: '$redirectBase/connectors/$name/callback',
      );
      clientErrorMessage = '';
    } on StateError catch (e) {
      clientErrorMessage = e.message;
    }
    if (clientErrorMessage.isNotEmpty) {
      return ApiError.internal('Server misconfigured: $clientErrorMessage');
    }

    final stateToken = generateStateToken();
    final codeVerifier = generateCodeVerifier();
    final codeChallenge = codeChallengeFromVerifier(codeVerifier);

    state.pendingConnectorAuths[stateToken] = PendingConnectorAuth(
      state: stateToken,
      codeVerifier: codeVerifier,
      deviceId: deviceId,
      connectorName: name,
      createdAt: DateTime.now().toUtc(),
    );
    // Purani expired pending auths yahin cleanup kar dete hain (chhota,
    // periodic-timer se zyada simple hai — har naye auth request par
    // sweep ho jaata hai).
    state.pendingConnectorAuths.removeWhere((_, p) => p.isExpired);

    final authorizationUrl = provider.buildAuthorizationUrl(
      state: stateToken,
      codeChallenge: codeChallenge,
      redirectUri: '$redirectBase/connectors/$name/callback',
    );

    return Response.ok(
      jsonEncode({'authorization_url': authorizationUrl.toString(), 'state': stateToken}),
      headers: {'content-type': 'application/json'},
    );
  });

  // GET /connectors/<name>/callback — provider (browser redirect) yahan
  // aata hai. **Koi Authorization header nahi hoti** (browser navigation
  // hai, API call nahi) — sirf `state` token se hi request verify hoti
  // hai (CSRF protection, PKCE ke saath combined).
  router.get('/connectors/<name>/callback', (Request request, String name) async {
    final query = request.requestedUri.queryParameters;

    if (query['error'] != null) {
      return _htmlResponse(
          'Connection cancel ho gayi: ${query['error']}. Yeh window band kar dein.');
    }

    final stateToken = query['state'];
    final code = query['code'];
    if (stateToken == null || code == null) {
      return _htmlResponse('Invalid callback — "code" ya "state" missing hai.',
          statusCode: 400);
    }

    final pending = state.pendingConnectorAuths[stateToken];
    if (pending == null) {
      return _htmlResponse(
          'Yeh authorization request expire ho chuki hai ya invalid hai. '
          'Dobara "Connect" try karein.',
          statusCode: 400);
    }
    state.pendingConnectorAuths.remove(stateToken); // ek-baar-istemal, replay na ho
    if (pending.isExpired) {
      return _htmlResponse(
          'Yeh authorization request expire ho chuki hai. Dobara "Connect" try karein.',
          statusCode: 400);
    }
    if (pending.connectorName != name) {
      return _htmlResponse('State token is connector se match nahi karta.',
          statusCode: 400);
    }

    final provider = connectorProviderByName(name);
    if (provider == null) {
      return _htmlResponse('Unknown connector "$name".', statusCode: 404);
    }

    final redirectBase = Platform.environment['CONNECTOR_REDIRECT_BASE_URL'] ?? '';

    try {
      final tokens = await provider.exchangeCode(
        code: code,
        codeVerifier: pending.codeVerifier,
        redirectUri: '$redirectBase/connectors/$name/callback',
      );

      state.storeConnectorCredential(ConnectorCredential(
        deviceId: pending.deviceId,
        connectorName: name,
        encryptedAccessToken: await encryptSecret(tokens.accessToken),
        encryptedRefreshToken:
            tokens.refreshToken != null ? await encryptSecret(tokens.refreshToken!) : null,
        accessTokenExpiresAt: tokens.accessTokenExpiresAt,
        grantedScopes: tokens.grantedScopes,
        connectedAt: DateTime.now().toUtc(),
      ));
      state.logActivity(ActivityEvent(
        eventType: 'connector.connected',
        deviceId: pending.deviceId,
        source: name,
        timestamp: DateTime.now().toUtc(),
        status: 'success',
        actor: 'device_agent',
      ));
      await state.persist();

      return _htmlResponse('"${provider.displayName}" connect ho gaya! '
          'Yeh window band kar dein aur app mein wapas jaayein.');
    } catch (e) {
      state.logActivity(ActivityEvent(
        eventType: 'connector.connect_failed',
        deviceId: pending.deviceId,
        source: name,
        timestamp: DateTime.now().toUtc(),
        status: 'fail',
        actor: 'device_agent',
      ));
      // `e.toString()` yahan user ko dikhta hai — provider errors
      // (StateError messages upar) jaan-bujh kar kabhi token/secret
      // values apne message mein nahi daalte (dekhein google_drive_
      // provider.dart), is liye yeh safe hai.
      return _htmlResponse('Connect nahi ho saka: $e', statusCode: 502);
    }
  });

  // POST /connectors/<name>/disconnect — provider-side revoke + local delete.
  router.post('/connectors/<name>/disconnect', (Request request, String name) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');
    final deviceId = (device as dynamic).id as String;

    final credential = state.connectorCredentialFor(deviceId, name);
    if (credential == null) {
      return ApiError.notFound('Connector "$name" is device ke liye connected nahi hai');
    }
    final provider = connectorProviderByName(name);

    // Best-effort provider-side revoke — fail ho jaaye (network issue,
    // token already invalid) to bhi local delete zaroor hoti hai
    // (audit: "revoke removes access" — is server se access turant
    // jaana chahiye, provider-side cleanup best-effort hai).
    if (provider != null) {
      try {
        final tokenToRevoke = await decryptSecret(
            credential.encryptedRefreshToken ?? credential.encryptedAccessToken);
        await provider.revoke(token: tokenToRevoke);
      } catch (_) {
        // Ignore — local delete neeche phir bhi hogi.
      }
    }

    state.removeConnectorCredential(deviceId, name);
    state.logActivity(ActivityEvent(
      eventType: 'connector.disconnected',
      deviceId: deviceId,
      source: name,
      timestamp: DateTime.now().toUtc(),
      status: 'success',
      actor: 'device_agent',
    ));
    await state.persist();

    return Response.ok(jsonEncode({'connector': name, 'connected': false}),
        headers: {'content-type': 'application/json'});
  });

  // GET /connectors/{google_drive,dropbox}/files — **end-to-end proof
  // action**, dono registered providers ke liye. Connected na ho to
  // yahan pahunchte hi turant 403 (koi capability "leak" nahi hoti) —
  // expired ho to automatically refresh hoke chalti hai (audit: "expired
  // token refreshes").
  router.get('/connectors/google_drive/files', (Request request) async {
    final deviceId = _connectorCallerDeviceId(request);
    if (deviceId == null) {
      return unauthorized('Device token ya `data_transfer` scope wali API key required');
    }

    final provider = connectorProviderByName('google_drive') as GoogleDriveConnectorProvider;
    final String? accessToken;
    try {
      accessToken = await state.getValidAccessToken(deviceId, 'google_drive', provider);
    } on StateError catch (e) {
      // Item 47: token refresh fail (network/provider) — 500 crash nahi.
      return ApiError.internal('Google Drive token refresh fail hua: ${e.message}');
    }
    if (accessToken == null) {
      return ApiError.forbidden(
          '"google_drive" is device ke liye connected nahi hai — pehle '
          'POST /connectors/google_drive/auth call karein');
    }

    try {
      final files = await provider.listFiles(accessToken);
      return Response.ok(jsonEncode({'files': files}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return ApiError.internal('Google Drive API call fail hui: $e');
    }
  });

  // P0-07 extension — Dropbox ke liye bhi wahi end-to-end proof action.
  // Yeh route (aur `_actionsFor` mein iski entry) na hoti, to Dropbox
  // technically "connect" ho jaati (auth/callback/disconnect sab kaam
  // karte) lekin koi bhi asal action kabhi expose/call nahi hoti — bilkul
  // wahi shape ka gap jo P1-02 mein custom capabilities ke saath mila tha.
  router.get('/connectors/dropbox/files', (Request request) async {
    final deviceId = _connectorCallerDeviceId(request);
    if (deviceId == null) {
      return unauthorized('Device token ya `data_transfer` scope wali API key required');
    }

    final provider = connectorProviderByName('dropbox') as DropboxConnectorProvider;
    final String? accessToken;
    try {
      accessToken = await state.getValidAccessToken(deviceId, 'dropbox', provider);
    } on StateError catch (e) {
      // Item 47: token refresh fail (network/provider) — 500 crash nahi.
      return ApiError.internal('Dropbox token refresh fail hua: ${e.message}');
    }
    if (accessToken == null) {
      return ApiError.forbidden(
          '"dropbox" is device ke liye connected nahi hai — pehle '
          'POST /connectors/dropbox/auth call karein');
    }

    try {
      final files = await provider.listFiles(accessToken);
      return Response.ok(jsonEncode({'files': files}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return ApiError.internal('Dropbox API call fail hui: $e');
    }
  });

  // Item 86: file download — dono providers, ek hi helper.
  Future<Response> download(Request request, String connectorName, String ref) async {
    final deviceId = _connectorCallerDeviceId(request);
    if (deviceId == null) {
      return unauthorized('Device token ya `data_transfer` scope wali API key required');
    }
    final provider = connectorProviderByName(connectorName);
    final String? accessToken;
    try {
      accessToken = await state.getValidAccessToken(deviceId, connectorName, provider);
    } on StateError catch (e) {
      return ApiError.internal('$connectorName token refresh fail hua: ${e.message}');
    }
    if (accessToken == null) {
      return ApiError.forbidden('"$connectorName" is device ke liye connected nahi hai');
    }
    try {
      final ConnectorFileContent file;
      if (provider is GoogleDriveConnectorProvider) {
        file = await provider.downloadFile(accessToken, ref);
      } else {
        file = await (provider as DropboxConnectorProvider).downloadFile(accessToken, ref);
      }
      state.logActivity(ActivityEvent(
        eventType: '$connectorName.download_file',
        deviceId: deviceId,
        timestamp: DateTime.now().toUtc(),
        status: 'success',
        actor: _connectorActor(request),
      ));
      return Response.ok(
        jsonEncode({
          'name': file.name,
          'mime_type': file.mimeType,
          'size': file.bytes.length,
          'data_base64': base64Encode(file.bytes),
        }),
        headers: {'content-type': 'application/json'},
      );
    } on ConnectorFileTooLarge catch (e) {
      return ApiError.payloadTooLarge('File ${e.maxBytes} bytes se badi hai');
    } on ArgumentError catch (e) {
      return ApiError.invalidRequest('${e.message}');
    } catch (e) {
      return ApiError.internal('$connectorName download fail hua: $e');
    }
  }

  router.get('/connectors/google_drive/files/<fileId>',
      (Request request, String fileId) => download(request, 'google_drive', fileId));
  // Dropbox paths mein '/' hota hai, isliye query parameter: ?path=/a/b.txt
  router.get('/connectors/dropbox/download', (Request request) {
    final path = request.url.queryParameters['path'] ?? '';
    return download(request, 'dropbox', path);
  });

  return router;
}

/// Item 86: connector read routes ab device token YA `dataTransfer` scope
/// wali API key (apne device ke liye) accept karte hain — pehle sirf
/// device token tha, to koi AI/API key connector use hi nahi kar sakti thi.
String? _connectorCallerDeviceId(Request request) {
  final device = request.context['device'];
  if (device is Device) return device.id;
  final key = request.context['apiKey'];
  if (key is ApiKeyRecord && key.scope.dataTransfer) return key.deviceId;
  return null;
}

String _connectorActor(Request request) {
  final key = request.context['apiKey'];
  if (key is ApiKeyRecord) return 'api_key:${key.keyId}';
  return 'device_owner';
}

List<String> _actionsFor(String connectorName) {
  switch (connectorName) {
    case 'google_drive':
      return ['google_drive.list_files', 'google_drive.download_file'];
    case 'dropbox':
      return ['dropbox.list_files', 'dropbox.download_file'];
    default:
      return const [];
  }
}

/// Item 11: callback page. `message` mein query params (`error`) aur
/// exception text aa sakta hai — untrusted, isliye **hamesha HTML-escape**
/// hota hai, aur strict CSP header (koi script/remote resource nahi)
/// defense-in-depth ke liye lagta hai.
Response connectorHtmlResponse(String message, {int statusCode = 200}) => Response(
      statusCode,
      body: '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
          '<body style="font-family: sans-serif; padding: 2rem;">'
          '<p>${escapeHtml(message)}</p></body></html>',
      headers: {
        'content-type': 'text/html; charset=utf-8',
        'content-security-policy':
            "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; "
                "form-action 'none'; frame-ancestors 'none'",
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'cache-control': 'no-store',
      },
    );

Response _htmlResponse(String message, {int statusCode = 200}) =>
    connectorHtmlResponse(message, statusCode: statusCode);
