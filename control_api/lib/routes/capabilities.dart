import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/device_auth.dart';
import '../models/api_key.dart';
import '../models/device.dart';
import '../models/capabilities.dart';
import '../models/custom_capability.dart';
import '../models/errors.dart';
import '../storage/app_state.dart';
import '../util/http_utils.dart';

/// NOTE (P0-07): `/connectors/*` routes yahan se hata kar
/// `routes/connectors.dart` mein move ho gaye hain — woh ek real OAuth
/// implementation hai, ab is file mein sirf built-in/custom capability
/// discovery hai.
/// Item 15: custom capability registration limits.
const maxCustomManifestsPerDevice = 20;
const maxCustomManifestsTotal = 200;
const maxManifestBytes = 32 * 1024;
const maxActionsPerManifest = 50;

/// Authenticated caller (device ya API key) ka device id, warna `null`.
String? _callerDeviceId(Request request) {
  final device = request.context['device'];
  if (device is Device) return device.id;
  final key = request.context['apiKey'];
  if (key is ApiKeyRecord) return key.deviceId;
  return null;
}

/// Public view: `registered_by` (internal device id) kabhi bahar nahi
/// jaata, aur sirf caller ke apne device ke custom manifests dikhte hain.
Map<String, dynamic> _publicManifest(Map<String, dynamic> m) =>
    Map<String, dynamic>.of(m)..remove('registered_by');

List<Map<String, dynamic>> _customManifestsVisibleTo(
        AppState state, String deviceId) =>
    state.customCapabilityManifests
        .where((m) =>
            m['registered_by'] == null || m['registered_by'] == deviceId)
        .toList();

Router capabilityRoutes(AppState state) {
  final router = Router();

  // Item 23: ab authenticated (device token ya API key). Pehle custom
  // capabilities ke naam aur schemas bina login ke dikhte the.
  router.get('/capabilities', (Request request) {
    final deviceId = _callerDeviceId(request);
    if (deviceId == null) {
      return unauthorized('Authorization header chahiye (device token ya API key)');
    }
    // `is_custom` — purane consumers ke liye backward-compatible naya field.
    final all = [
      ...builtInCapabilityManifests().map((m) => {...m, 'is_custom': false}),
      ..._customManifestsVisibleTo(state, deviceId)
          .map((m) => {..._publicManifest(m), 'is_custom': true}),
    ];
    return Response.ok(jsonEncode(all),
        headers: {'content-type': 'application/json'});
  });

  router.get('/capabilities/<name>/schema', (Request request, String name) {
    final deviceId = _callerDeviceId(request);
    if (deviceId == null) {
      return unauthorized('Authorization header chahiye (device token ya API key)');
    }
    final all = [
      ...builtInCapabilityManifests(),
      ..._customManifestsVisibleTo(state, deviceId).map(_publicManifest),
    ];
    final match = all.where((m) => m['capability'] == name);
    if (match.isEmpty) {
      return ApiError.notFound('Unknown capability');
    }
    return Response.ok(jsonEncode(match.first),
        headers: {'content-type': 'application/json'});
  });

  // POST /capabilities/register — persistent + validated + trust-aware.
  router.post('/capabilities/register', (Request request) async {
    // Trust boundary #1: device-authentication zaroori.
    final device = request.context['device'];
    if (device is! Device) {
      return unauthorized('Capability registration ke liye device auth required hai');
    }

    // Item 15/18: safe parse + size cap.
    final parsed = await readJsonObject(request, maxBytes: maxManifestBytes);
    if (!parsed.isOk) return parsed.error!;
    final body = parsed.body!;

    // Item 15: count caps.
    if (state.customCapabilityManifests.length >= maxCustomManifestsTotal) {
      return ApiError.forbidden(
          'Server par maximum custom capabilities ($maxCustomManifestsTotal) register ho chuki hain');
    }
    final ownCount = state.customCapabilityManifests
        .where((m) => m['registered_by'] == device.id)
        .length;
    if (ownCount >= maxCustomManifestsPerDevice) {
      return ApiError.forbidden(
          'Ek device max $maxCustomManifestsPerDevice custom capabilities register kar sakta hai');
    }
    final actionList = body['actions'];
    if (actionList is List && actionList.length > maxActionsPerManifest) {
      return ApiError.invalidRequest(
          'Ek manifest mein max $maxActionsPerManifest actions ho sakte hain');
    }

    // ---- Shape/schema validation --------------------------------------
    final builtInNames = builtInCapabilityManifests().map((m) => m['capability'] as String).toSet();
    final alreadyRegisteredNames =
        state.customCapabilityManifests.map((m) => m['capability'] as String).toSet();
    final reservedNames = {...builtInNames, ...alreadyRegisteredNames};

    final validation = validateCustomManifest(body, reservedNames);
    if (!validation.isValid) {
      return ApiError.invalidRequest(validation.error!);
    }

    // Trust boundary #2: privileged (high-risk) capabilities.
    if (manifestIsPrivileged(body)) {
      return ApiError.forbidden(
          'Is manifest mein kam-se-kam ek "high" risk_level action hai — '
          'privileged capabilities is server se register nahi ho saktin');
    }

    // Item 15: ownership — client ka bheja hua `registered_by` hamesha
    // override hota hai. Yeh capability sirf isi device ki keys use kar
    // sakti hain.
    final stored = Map<String, dynamic>.of(body)
      ..['registered_by'] = device.id;
    state.customCapabilityManifests.add(stored);
    await state.persist();

    return Response.ok(jsonEncode(_publicManifest(stored)),
        headers: {'content-type': 'application/json'});
  });

  return router;
}
