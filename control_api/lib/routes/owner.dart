/// Stage 2 (items 25, 30, 87): "owner" routes.
///
/// Problem: dashboard app sirf device bearer token rakhta hai, lekin
/// `POST /commands` sirf **scoped API key** accept karta hai — isliye
/// dashboard ke Pause/Stop/Watch Live/Locate/Keepalive sab 401 dete the.
///
/// Fix: device apna hi owner hai. `device bearer token` se authenticate
/// hone par yeh routes request ko ek **in-memory owner key** (us device
/// ke liye sab built-in scopes + us device ki custom capabilities) ke
/// saath normal `/commands` pipeline mein bhej dete hain — yani saari
/// validation, task state machine, device-state gate, audit log wahi
/// rehti hai. Owner key kabhi store/persist nahi hoti.
library;

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/device_auth.dart';
import '../models/api_key.dart';
import '../models/device.dart';
import '../models/errors.dart';
import '../storage/app_state.dart';
import '../util/http_utils.dart';
import '../validation/schema_validator.dart' show maxUploadRequestBodyBytes;

/// Device ke liye synthetic owner key (kabhi persist nahi hoti).
ApiKeyRecord ownerKeyFor(AppState state, Device device) {
  final customNames = state.customCapabilityManifests
      .where((m) =>
          m['registered_by'] == null || m['registered_by'] == device.id)
      .map((m) => m['capability'])
      .whereType<String>()
      .toSet();
  return ApiKeyRecord(
    keyId: 'owner_${device.id}',
    deviceId: device.id,
    label: 'owner',
    scope: ApiKeyScope(
      screenView: true,
      touchInput: true,
      keyboardText: true,
      files: true,
      apps: true,
      browser: true,
      clipboard: true,
      dataTransfer: true,
      contacts: true,
      location: true,
      background: true,
      messagingReply: true,
      customCapabilities: customNames,
    ),
    createdAt: device.pairedAt,
    secretHash: '', // kabhi match nahi hoga — yeh key bearer ke tor par use hi nahi hoti
  );
}

Router ownerRoutes(AppState state, Handler commandHandler) {
  final router = Router();

  Future<Response> forward(Request request, Device device, String path,
      Map<String, dynamic>? body) {
    final inner = Request(
      'POST',
      Uri.parse('http://internal$path'),
      body: body == null ? '' : jsonEncode(body),
      headers: {'content-type': 'application/json'},
      context: {'apiKey': ownerKeyFor(state, device)},
    );
    return Future.sync(() => commandHandler(inner));
  }

  // POST /owner/commands — normal Command Envelope, device token se.
  router.post('/owner/commands', (Request request) async {
    final device = request.context['device'];
    if (device is! Device) {
      return unauthorized('Device bearer token required (owner endpoint)');
    }
    final parsed = await readJsonObject(request, maxBytes: maxUploadRequestBodyBytes);
    if (!parsed.isOk) return parsed.error!;
    final body = parsed.body!;
    // Validator `api_key_id` required maangta hai; server isko
    // `commands.dart` mein waise bhi override kar deta hai.
    body['api_key_id'] = 'owner_${device.id}';
    return forward(request, device, '/commands', body);
  });

  // POST /owner/sessions/{id}/switch — device token se session switch.
  router.post('/owner/sessions/<sessionId>/switch',
      (Request request, String sessionId) async {
    final device = request.context['device'];
    if (device is! Device) {
      return unauthorized('Device bearer token required (owner endpoint)');
    }
    final parsed = await readJsonObject(request);
    if (!parsed.isOk) return parsed.error!;
    return forward(request, device,
        '/sessions/${Uri.encodeComponent(sessionId)}/switch', parsed.body!);
  });

  // GET /tasks[?active=true] — Items 30/87: apne device ke tasks ki list
  // (dashboard ke "Active tasks" screen ke liye).
  router.get('/tasks', (Request request) {
    final device = request.context['device'];
    if (device is! Device) {
      return unauthorized('Device bearer token required');
    }
    final activeOnly = request.url.queryParameters['active'] == 'true';
    final tasks = state.tasks.values
        .where((t) => t.deviceId == device.id)
        .where((t) => !activeOnly || !t.state.isTerminal)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return Response.ok(
      jsonEncode(tasks.take(200).map((t) => t.toJson()).toList()),
      headers: {'content-type': 'application/json'},
    );
  });

  return router;
}
