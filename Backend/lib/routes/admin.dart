/// Web dashboard ke liye "admin" routes.
///
/// Pehle har device apna hi owner tha (device token) aur har API key sirf EK
/// device se bandhi thi — isliye ek website par "mere saare devices" dikhane ka
/// koi tareeqa nahi tha. Ab ek **admin token** (env `ADMIN_TOKEN`, >= 32 chars)
/// hai jo maalik ko saare paired devices dikhata hai, kisi bhi device par
/// command chalane deta hai aur live screen dekhne ke liye browser-friendly
/// WebSocket ticket deta hai.
///
/// SECURITY: admin token = saare devices ka poora control. Sirf HTTPS par,
/// browser mein sirf sessionStorage (localStorage nahi), aur kisi ke saath
/// share na karein. `ADMIN_TOKEN` set na ho to yeh saare routes band (404).
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/device.dart';
import '../models/errors.dart';
import '../storage/app_state.dart';
import '../util/crypto_utils.dart';
import '../util/http_utils.dart';
import '../validation/schema_validator.dart' show maxUploadRequestBodyBytes;
import 'owner.dart' show ownerKeyFor;

const minAdminTokenLength = 32;

/// Sirf tests ke liye (environment variable test mein set nahi ho sakta).
String? debugAdminTokenOverride;

String? _configuredAdminToken() {
  final t = debugAdminTokenOverride ?? Platform.environment['ADMIN_TOKEN'] ?? '';
  return t.length >= minAdminTokenLength ? t : null;
}

bool isAdminEnabled() => _configuredAdminToken() != null;

/// Request ka `Authorization: Bearer` admin token se match karta hai? (constant-time)
bool isAdminRequest(Request request) {
  final expected = _configuredAdminToken();
  if (expected == null) return false;
  final header = request.headers['authorization'];
  if (header == null || !header.toLowerCase().startsWith('bearer ')) return false;
  return constantTimeEquals(header.substring(7).trim(), expected);
}

/// Ek command ko (full semantics: scope, schema, task gate, activity log) us
/// device par bhejta hai — HTTP route aur fast WebSocket dono yahi use karte hain.
Future<Response> forwardAdminCommand(AppState state, Handler commandHandler,
    Device device, Map<String, dynamic> body) {
  body['api_key_id'] = 'owner_${device.id}';
  final inner = Request(
    'POST',
    Uri.parse('http://internal/commands'),
    body: jsonEncode(body),
    headers: {'content-type': 'application/json'},
    context: {'apiKey': ownerKeyFor(state, device)},
  );
  return Future.sync(() => commandHandler(inner));
}

/// `WS /admin/control?ticket=` — tez, ordered control channel. Browser har click
/// par naya HTTP request (headers + auth + response-wait) nahi karta: ek WebSocket
/// par messages pipeline hote hain, har ka jawab `id` se match hota hai.
///   client -> {id, device_id, capability, action, params, timeout_ms?}
///   server -> {id, ok:true, result} | {id, ok:false, status, error}
Handler adminControlHandler(AppState state, Handler commandHandler) {
  const maxInFlight = 32;
  return webSocketHandler((WebSocketChannel ws, String? protocol) {
    var inFlight = 0;
    void reply(Map<String, dynamic> m) {
      try {
        ws.sink.add(jsonEncode(m));
      } catch (_) {}
    }

    ws.stream.listen((raw) async {
      Map<String, dynamic> msg;
      try {
        if (raw is! String || raw.length > 200000) return;
        msg = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      final id = msg['id'];
      if (id is! String) return;
      // Website<->server latency meter — device tak nahi jaata, seedha pong.
      if (msg['capability'] == '__ping') {
        reply({'id': id, 'ok': true, 'result': {'pong': true}});
        return;
      }
      final device = state.devices[msg['device_id']];
      if (device == null) {
        reply({'id': id, 'ok': false, 'status': 404, 'error': 'Device nahi mila'});
        return;
      }
      if (inFlight >= maxInFlight) {
        reply({'id': id, 'ok': false, 'status': 429, 'error': 'Bahut saari commands in-flight hain'});
        return;
      }
      inFlight++;
      try {
        final res = await forwardAdminCommand(state, commandHandler, device, {
          'protocol_version': '1.0',
          'request_id': randomHex(12),
          'capability': msg['capability'],
          'action': msg['action'],
          'params': msg['params'] is Map ? msg['params'] : <String, dynamic>{},
          if (msg['timeout_ms'] is int) 'timeout_ms': msg['timeout_ms'],
        });
        final text = await res.readAsString();
        dynamic decoded;
        try {
          decoded = jsonDecode(text);
        } catch (_) {
          decoded = {'raw': text};
        }
        if (res.statusCode == 200) {
          reply({'id': id, 'ok': true, 'result': decoded});
        } else {
          final d = decoded is Map ? decoded : <String, dynamic>{};
          reply({
            'id': id,
            'ok': false,
            'status': res.statusCode,
            'error': (d['message'] ?? (d['error'] is Map ? d['error']['message'] : d['error']) ?? text).toString(),
            'error_code': d['error_code'] ?? (d['error'] is Map ? d['error']['code'] : null),
          });
        }
      } catch (e) {
        reply({'id': id, 'ok': false, 'status': 500, 'error': e.toString()});
      } finally {
        inFlight--;
      }
    }, onError: (_) {});
  }, pingInterval: const Duration(seconds: 20));
}

Router adminRoutes(AppState state, Handler commandHandler) {
  final router = Router();

  Response? guard(Request request) {
    if (!isAdminEnabled()) {
      return ApiError.notFound('Admin API band hai (ADMIN_TOKEN set nahi)');
    }
    if (!isAdminRequest(request)) {
      return unauthorized('Admin token required (Authorization: Bearer <ADMIN_TOKEN>)');
    }
    return null;
  }

  Response json(Object body) => Response.ok(jsonEncode(body),
      headers: {'content-type': 'application/json', 'cache-control': 'no-store'});

  // GET /admin/devices — saare paired devices + live connection + active tasks.
  router.get('/admin/devices', (Request request) {
    final denied = guard(request);
    if (denied != null) return denied;
    final devices = state.devices.values.map((Device d) {
      final active = state.tasks.values
          .where((t) => t.deviceId == d.id && !t.state.isTerminal)
          .toList();
      return {
        ...d.toStatusJson(),
        'id': d.id,
        'name': d.name,
        'platform': d.platform,
        'connected': state.deviceConnections.containsKey(d.id),
        'active_task_count': active.length,
        'active_tasks': active.take(20).map((t) => t.toJson()).toList(),
      };
    }).toList()
      ..sort((a, b) {
        final c = (b['connected'] == true ? 1 : 0) - (a['connected'] == true ? 1 : 0);
        return c != 0 ? c : (a['name'] as String).compareTo(b['name'] as String);
      });
    return json({'devices': devices});
  });

  // GET /admin/devices/{id}/tasks[?active=true]
  router.get('/admin/devices/<id>/tasks', (Request request, String id) {
    final denied = guard(request);
    if (denied != null) return denied;
    if (state.devices[id] == null) return ApiError.notFound('Device "$id" nahi mila');
    final activeOnly = request.url.queryParameters['active'] == 'true';
    final tasks = state.tasks.values
        .where((t) => t.deviceId == id)
        .where((t) => !activeOnly || !t.state.isTerminal)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return json({'tasks': tasks.take(200).map((t) => t.toJson()).toList()});
  });

  // POST /admin/devices/{id}/commands — normal Command Envelope, us device par.
  router.post('/admin/devices/<id>/commands', (Request request, String id) async {
    final denied = guard(request);
    if (denied != null) return denied;
    final device = state.devices[id];
    if (device == null) return ApiError.notFound('Device "$id" nahi mila');
    final parsed = await readJsonObject(request, maxBytes: maxUploadRequestBodyBytes);
    if (!parsed.isOk) return parsed.error!;
    return forwardAdminCommand(state, commandHandler, device, parsed.body!);
  });

  // POST /admin/ws-ticket — browser WebSocket header (Authorization) bhej nahi
  // sakta; isliye chhota, ek-baar-use ticket `?ticket=` mein.
  router.post('/admin/ws-ticket', (Request request) {
    final denied = guard(request);
    if (denied != null) return denied;
    return json({
      'ticket': state.issueWsTicket(),
      'expires_in': AppState.wsTicketTtl.inSeconds,
    });
  });

  return router;
}

/// `?ticket=` valid ho to request ko admin-context ke saath wapas deta hai
/// (ticket consume ho jata hai); warna request jaisi thi waisi.
Request applyWsTicket(Request request, AppState state) {
  final t = request.url.queryParameters['ticket'];
  if (t != null && t.isNotEmpty && state.consumeWsTicket(t)) {
    return request.change(context: {'admin': true});
  }
  return request;
}

/// CORS — sirf `CORS_ALLOWED_ORIGINS` (comma-separated exact origins) ko.
/// Khaali => koi cross-origin browser access nahi. Preflight (OPTIONS) auth se
/// pehle yahin jawab hota hai.
Middleware corsMiddleware(Set<String> allowedOrigins) {
  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'];
      final allowed = origin != null && allowedOrigins.contains(origin);
      final cors = <String, String>{
        if (allowed) 'access-control-allow-origin': origin,
        if (allowed) 'vary': 'Origin',
        if (allowed) 'access-control-allow-headers': 'Authorization, Content-Type',
        if (allowed) 'access-control-allow-methods': 'GET, POST, PATCH, DELETE, OPTIONS',
        if (allowed) 'access-control-max-age': '600',
      };
      if (request.method == 'OPTIONS') {
        return Response(allowed ? 204 : 403, headers: cors);
      }
      final response = await inner(request);
      return allowed ? response.change(headers: cors) : response;
    };
  };
}
