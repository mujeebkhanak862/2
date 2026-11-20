import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../ai_tools/ai_tool_registry.dart';
import '../auth/device_auth.dart';
import '../auth/pairing_code_registry.dart';
import '../models/activity.dart';
import '../models/api_key.dart';
import '../models/errors.dart';
import '../models/device.dart';
import '../storage/app_state.dart';
import '../util/crypto_utils.dart';
import '../util/http_utils.dart';

/// Item 10: server par total paired devices ki upper limit (fake-device
/// flood se bachav). `MAX_DEVICES` env var se override ho sakta hai.
int _maxDevices() =>
    int.tryParse(Platform.environment['MAX_DEVICES'] ?? '') ?? 500;

/// Item 10: `ADMIN_SECRET` kam-se-kam itna lamba ho, warna feature off.
const _minAdminSecretLength = 16;

Router deviceRoutes(AppState state, {Map<String, String>? env}) {
  final router = Router();
  final environment = env ?? Platform.environment;
  bool requireCode() =>
      (environment['REQUIRE_PAIRING_CODE'] ?? '').toLowerCase() == 'true';

  // POST /pairing-codes — owner ek-baar-use, chhota-umr pairing code
  // issue karta hai. Auth: (a) pehle se paired device ka bearer token, ya
  // (b) `Authorization: Bearer <ADMIN_SECRET>` (pehla device bootstrap
  // karne ke liye). Response mein code sirf isi baar milta hai.
  router.post('/pairing-codes', (Request request) async {
    String? issuedBy;
    final device = request.context['device'];
    if (device is Device) {
      issuedBy = 'device:${device.id}';
    } else {
      final adminSecret = environment['ADMIN_SECRET'] ?? '';
      final header = request.headers['authorization'] ?? '';
      if (adminSecret.length >= _minAdminSecretLength &&
          header.startsWith('Bearer ') &&
          constantTimeEquals(header.substring('Bearer '.length), adminSecret)) {
        issuedBy = 'admin';
      }
    }
    if (issuedBy == null) {
      return unauthorized(
          'Paired device token ya ADMIN_SECRET (min $_minAdminSecretLength chars) chahiye');
    }
    final issued = state.pairingCodes.issue(issuedBy: issuedBy);
    if (issued == null) {
      return ApiError.rateLimited(
          'Bahut zyada active pairing codes hain — kuch der baad try karein',
          retryAfterSeconds: state.pairingCodes.ttl.inSeconds);
    }
    return Response.ok(
      jsonEncode({
        'pairing_code': issued.code,
        'expires_at': issued.expiresAt.toIso8601String(),
        'expires_in_seconds': state.pairingCodes.ttl.inSeconds,
        'single_use': true,
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // POST /devices/pair {pairing_code, device_name, platform, [pairing_secret]}
  //
  // Item 10 hardening: pehle yeh endpoint bilkul open tha. Ab:
  //  * strict per-IP rate limit (`middleware/rate_limiter.dart`),
  //  * total device cap (`MAX_DEVICES`, default 500),
  //  * agar server par `PAIRING_SECRET` env set hai to body mein wahi
  //    `pairing_secret` chahiye (constant-time compare),
  //  * input validation (name length, pairing_code shape).
  //
  // Item 10 (Stage 8): server-issued one-time code registry ab hai
  // (`POST /pairing-codes`, TTL 5 min default, single-use). Purana
  // `PAIRING_SECRET` fallback bana hua hai jab tak `REQUIRE_PAIRING_CODE`
  // on na ho.
  router.post('/devices/pair', (Request request) async {
    final parsed = await readJsonObject(request);
    if (!parsed.isOk) return parsed.error!;
    final body = parsed.body!;

    // Item 10: server-issued code (valid) PAIRING_SECRET ki jagah le leta
    // hai. `REQUIRE_PAIRING_CODE=true` par code ke bina pairing band.
    // Code yahan sirf *check* hota hai; consume neeche, validation ke
    // baad aur device banane se theek pehle hota hai (galat input par
    // code waste na ho).
    final suppliedCode = body['pairing_code'];
    final codeOk = suppliedCode is String &&
        PairingCodeRegistry.looksLikeCode(suppliedCode) &&
        state.pairingCodes.isValid(suppliedCode);
    if (requireCode() && !codeOk) {
      return unauthorized('Valid, unexpired server pairing code chahiye');
    }
    final requiredSecret = environment['PAIRING_SECRET'];
    if (!codeOk && requiredSecret != null && requiredSecret.isNotEmpty) {
      final given = body['pairing_secret'];
      if (given is! String || !constantTimeEquals(given, requiredSecret)) {
        return unauthorized('Pairing secret galat ya missing hai');
      }
    }

    if (state.devices.length >= _maxDevices()) {
      return ApiError.forbidden(
          'Server par maximum devices (${_maxDevices()}) paired hain');
    }

    final rawName = body['device_name'];
    if (rawName != null && rawName is! String) {
      return ApiError.invalidRequest('"device_name" ek string honi chahiye');
    }
    final deviceName = ((rawName as String?) ?? 'Unnamed Device').trim();
    if (deviceName.isEmpty || deviceName.length > 100) {
      return ApiError.invalidRequest(
          '"device_name" 1 se 100 characters ke beech honi chahiye');
    }

    final pairingCode = body['pairing_code'];
    if (pairingCode != null &&
        (pairingCode is! String || pairingCode.length > 64)) {
      return ApiError.invalidRequest(
          '"pairing_code" ek string (max 64 chars) honi chahiye');
    }

    // P1-02 — platform batana required hai (AI Tool Registry isi se
    // device-specific capability filtering karta hai).
    final platform = body['platform'];
    const validPlatforms = {'android', 'windows', 'linux'};
    if (platform is! String || !validPlatforms.contains(platform)) {
      return ApiError.invalidRequest(
          '"platform" required hai aur in mein se ek honi chahiye: '
          '${validPlatforms.join(", ")}');
    }

    // Item 10: code ab consume karo (sync — check aur consume ke beech
    // koi await nahi, is liye ek code se do device nahi ban sakte).
    if (codeOk && !state.pairingCodes.consume(suppliedCode as String)) {
      return unauthorized('Pairing code ab valid nahi raha');
    }

    // Item 19: 128-bit id + exists-check (collision par purana device
    // kabhi overwrite nahi hota).
    var id = Device.generateId();
    while (state.devices.containsKey(id)) {
      id = Device.generateId();
    }
    final token = Device.generateToken();
    final now = DateTime.now().toUtc();
    state.devices[id] = Device(
      id: id,
      name: deviceName,
      bearerTokenHash: hashSecretUtil(token),
      platform: platform,
      pairedAt: now,
      lastSeenAt: now,
    );
    await state.persist();
    // Plaintext token sirf isi response mein, ek hi baar (P0-06).
    return Response.ok(
      jsonEncode({'device_id': id, 'bearer_token': token}),
      headers: {'content-type': 'application/json'},
    );
  });

  // DELETE /devices/{id} — Item 21: device khud ko unpair karta hai.
  // Uski API keys, connector credentials, tasks, custom capabilities
  // aur activity log sab hat jaate hain, aur live connection close hoti
  // hai. Sirf device ka apna token (API key se nahi).
  router.delete('/devices/<id>', (Request request, String id) async {
    final authError = authorizeForDevice(request, id, allowApiKey: false);
    if (authError != null) return authError;
    final removed = await state.removeDevice(id);
    if (!removed) return ApiError.notFound('Device not found');
    return Response(204);
  });

  // POST /devices/{id}/rotate-token — Item 21: naya bearer token; purana
  // turant invalid. Naya token sirf isi response mein ek baar.
  router.post('/devices/<id>/rotate-token', (Request request, String id) async {
    final authError = authorizeForDevice(request, id, allowApiKey: false);
    if (authError != null) return authError;
    final device = state.devices[id];
    if (device == null) return ApiError.notFound('Device not found');
    final token = Device.generateToken();
    device.bearerTokenHash = hashSecretUtil(token);
    state.devices.touch(); // Item 22: token-index invalidate
    state.revalidateListeners(); // purane token se khule WS band
    await state.persist();
    // Purani (ab invalid token wali) live connection band karo; client
    // naye token se reconnect karega.
    final conn = state.deviceConnections.remove(id);
    try {
      await conn?.sink.close(4002, 'token rotated');
    } catch (_) {}
    return Response.ok(
      jsonEncode({'device_id': id, 'bearer_token': token}),
      headers: {'content-type': 'application/json'},
    );
  });

  // GET /devices/{id}/status — Item 8: ab authenticated (device ka apna
  // token ya us device ki API key). Pehle koi bhi device id jaan kar
  // location/battery padh sakta tha.
  router.get('/devices/<id>/status', (Request request, String id) async {
    final authError = authorizeForDevice(request, id);
    if (authError != null) return authError;
    final device = state.devices[id];
    if (device == null) {
      return ApiError.notFound('Device not found');
    }
    // P1-05 — `agent_connected` `device.state` se independent hai.
    return Response.ok(
      jsonEncode({
        ...device.toStatusJson(),
        'agent_connected': state.deviceConnections.containsKey(id),
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // POST /devices/{id}/location — device apni location report karta hai.
  router.post('/devices/<id>/location', (Request request, String id) async {
    final unauth = _requireDeviceMatching(request, id);
    if (unauth != null) return unauth;

    final device = state.devices[id];
    if (device == null) {
      return ApiError.notFound('Device not found');
    }
    final parsed = await readJsonObject(request);
    if (!parsed.isOk) return parsed.error!;
    // Item 18: shape/range validation + sirf whitelisted fields store.
    final location = sanitizeLocation(parsed.body!);
    if (location == null) {
      return ApiError.invalidRequest(
          '"latitude" (-90..90) aur "longitude" (-180..180) numbers chahiye');
    }
    device.lastLocation = location;
    state.logActivity(ActivityEvent(
      eventType: 'location_updated',
      deviceId: id,
      timestamp: DateTime.now().toUtc(),
      status: 'success',
      actor: 'device_agent',
    ));
    await state.persist();
    return Response(204);
  });

  // POST /devices/{id}/network — Item 32: device apna network status
  // report karta hai (`connected`, optional `ssid`, `connection_type`).
  router.post('/devices/<id>/network', (Request request, String id) async {
    final unauth = _requireDeviceMatching(request, id);
    if (unauth != null) return unauth;
    final device = state.devices[id];
    if (device == null) return ApiError.notFound('Device not found');
    final parsed = await readJsonObject(request);
    if (!parsed.isOk) return parsed.error!;
    final network = sanitizeNetwork(parsed.body!);
    if (network == null) {
      return ApiError.invalidRequest('"connected" (bool) required hai');
    }
    device.lastNetwork = network;
    await state.persist();
    return Response(204);
  });

  // GET /devices/{id}/activity?limit=N — Item 8: authenticated.
  router.get('/devices/<id>/activity', (Request request, String id) async {
    final authError = authorizeForDevice(request, id);
    if (authError != null) return authError;
    final limitParam = request.url.queryParameters['limit'];
    final limit = (int.tryParse(limitParam ?? '') ?? 50).clamp(1, 500).toInt();
    final events = state.activityLog
        .where((e) => e.deviceId == id)
        .toList()
        .reversed
        .take(limit)
        .map((e) => e.toJson())
        .toList();
    return Response.ok(jsonEncode(events),
        headers: {'content-type': 'application/json'});
  });

  // GET /devices/{id}/ai-tools — P1-02: AI Tool Registry. API-key auth.
  // Item 9: key sirf *apne* device ke tools dekh sakti hai.
  router.get('/devices/<id>/ai-tools', (Request request, String id) async {
    final apiKey = request.context['apiKey'];
    if (apiKey == null) {
      return unauthorized('Valid scoped API key required (device bearer token nahi)');
    }
    final key = apiKey as ApiKeyRecord;
    if (key.deviceId != id) {
      return ApiError.scopeDenied('Yeh API key is device ki nahi hai');
    }

    final device = state.devices[id];
    if (device == null) {
      return ApiError.notFound('Device not found');
    }

    // Item 15: sirf is device ki registered custom capabilities.
    final tools = buildAiTools(
      device: device,
      scope: key.scope,
      customManifests: state.customCapabilityManifests
          .where((m) =>
              m['registered_by'] == null || m['registered_by'] == device.id)
          .toList(),
    );

    return Response.ok(
      jsonEncode({
        'device_id': id,
        'platform': device.platform,
        'tools': tools.map((t) => t.toJson()).toList(),
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  return router;
}

Response? _requireDeviceMatching(Request request, String expectedDeviceId) {
  final device = request.context['device'];
  if (device == null) {
    return unauthorized('Device auth required');
  }
  if ((device as dynamic).id != expectedDeviceId) {
    return ApiError.forbidden("Token doesn't match this device");
  }
  return null;
}
