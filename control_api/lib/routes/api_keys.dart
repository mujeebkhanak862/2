import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/device_auth.dart';
import '../models/api_key.dart';
import '../models/errors.dart';
import '../storage/app_state.dart';
import '../util/crypto_utils.dart';
import '../util/http_utils.dart';

Router apiKeyRoutes(AppState state) {
  final router = Router();

  // POST /api-keys {label, scope, [expires_in_days]} — device-authenticated
  // (dashboard app khud apne device ke liye key bana raha hai).
  //
  // Item 18: malformed JSON / galat types par 500 nahi, clean 400.
  // Item 21: optional `expires_in_days` (1..3650).
  router.post('/api-keys', (Request request) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');

    final parsed = await readJsonObject(request);
    if (!parsed.isOk) return parsed.error!;
    final body = parsed.body!;

    final rawLabel = body['label'];
    if (rawLabel != null && rawLabel is! String) {
      return ApiError.invalidRequest('"label" ek string honi chahiye');
    }
    final label = ((rawLabel as String?) ?? '').trim();
    if (label.length > 100) {
      return ApiError.invalidRequest('"label" 100 characters se zyada nahi ho sakti');
    }

    final scope = ApiKeyScope.tryParse(body['scope'] ?? const <String, dynamic>{});
    if (scope == null) {
      return ApiError.invalidRequest(
          '"scope" ek JSON object hona chahiye jisme saari values bool '
          '(aur custom_capabilities string list) hon');
    }
    if (scope.customCapabilities.length > 50 ||
        scope.customCapabilities.any((c) => c.length > 64)) {
      return ApiError.invalidRequest(
          '"custom_capabilities" max 50 entries, har ek max 64 chars');
    }

    DateTime? expiresAt;
    final rawExpiry = body['expires_in_days'];
    if (rawExpiry != null) {
      if (rawExpiry is! int || rawExpiry < 1 || rawExpiry > 3650) {
        return ApiError.invalidRequest(
            '"expires_in_days" 1 se 3650 ke beech ka integer hona chahiye');
      }
      expiresAt = DateTime.now().toUtc().add(Duration(days: rawExpiry));
    }

    // Item 19: 96-bit id + exists-check.
    var keyId = 'key_${randomHex(12)}';
    while (state.apiKeys.containsKey(keyId)) {
      keyId = 'key_${randomHex(12)}';
    }
    final secret = ApiKeyRecord.generateSecret();
    final record = ApiKeyRecord(
      keyId: keyId,
      deviceId: (device as dynamic).id as String,
      label: label,
      scope: scope,
      createdAt: DateTime.now().toUtc(),
      secretHash: ApiKeyRecord.hashSecret(secret),
      expiresAt: expiresAt,
    );
    state.apiKeys[keyId] = record;
    await state.persist();

    // Secret sirf isi response mein ek baar dikhta hai.
    return Response.ok(
      jsonEncode(record.toJson(plaintextSecretOnce: secret)),
      headers: {'content-type': 'application/json'},
    );
  });

  // GET /api-keys — sirf calling device ki apni keys.
  router.get('/api-keys', (Request request) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');
    final deviceId = (device as dynamic).id as String;

    final keys = state.apiKeys.values
        .where((k) => k.deviceId == deviceId)
        .map((k) => k.toJson())
        .toList();
    return Response.ok(jsonEncode(keys),
        headers: {'content-type': 'application/json'});
  });

  // PATCH /api-keys/{id}/permissions {scope}
  router.patch('/api-keys/<id>/permissions', (Request request, String id) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');

    final record = state.apiKeys[id];
    if (record == null || record.deviceId != (device as dynamic).id) {
      return ApiError.notFound('Key not found');
    }
    final parsed = await readJsonObject(request);
    if (!parsed.isOk) return parsed.error!;
    final newScope =
        ApiKeyScope.tryParse(parsed.body!['scope'] ?? const <String, dynamic>{});
    if (newScope == null) {
      return ApiError.invalidRequest(
          '"scope" ek JSON object hona chahiye jisme saari values bool '
          '(aur custom_capabilities string list) hon');
    }
    if (newScope.customCapabilities.length > 50 ||
        newScope.customCapabilities.any((c) => c.length > 64)) {
      return ApiError.invalidRequest(
          '"custom_capabilities" max 50 entries, har ek max 64 chars');
    }
    final updated = ApiKeyRecord(
      keyId: record.keyId,
      deviceId: record.deviceId,
      label: record.label,
      scope: newScope,
      createdAt: record.createdAt,
      secretHash: record.secretHash,
      enabled: record.enabled,
      expiresAt: record.expiresAt,
      lastUsedAt: record.lastUsedAt,
    );
    state.apiKeys[id] = updated;
    await state.persist();
    return Response.ok(jsonEncode(updated.toJson()),
        headers: {'content-type': 'application/json'});
  });

  // PATCH /api-keys/{id}/status {enabled: bool} — disable/re-enable.
  router.patch('/api-keys/<id>/status', (Request request, String id) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');

    final record = state.apiKeys[id];
    if (record == null || record.deviceId != (device as dynamic).id) {
      return ApiError.notFound('Key not found');
    }
    final parsed = await readJsonObject(request);
    if (!parsed.isOk) return parsed.error!;
    final enabled = parsed.body!['enabled'];
    if (enabled is! bool) {
      return ApiError.invalidRequest('"enabled" (bool) field required');
    }
    record.enabled = enabled;
    state.revalidateListeners(); // disable => khule WS turant band
    await state.persist();
    return Response.ok(jsonEncode(record.toJson()),
        headers: {'content-type': 'application/json'});
  });

  // DELETE /api-keys/{id} — turant revoke.
  router.delete('/api-keys/<id>', (Request request, String id) async {
    final device = request.context['device'];
    if (device == null) return unauthorized('Device auth required');

    final record = state.apiKeys[id];
    if (record == null || record.deviceId != (device as dynamic).id) {
      return ApiError.notFound('Key not found');
    }
    state.apiKeys.remove(id);
    state.revalidateListeners(); // revoke => khule WS turant band
    await state.persist();
    return Response(204);
  });

  return router;
}
