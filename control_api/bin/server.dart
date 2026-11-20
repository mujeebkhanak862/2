import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:control_api/auth/device_auth.dart';
import 'package:control_api/middleware/rate_limiter.dart';
import 'package:control_api/middleware/safe_logging.dart';
import 'package:control_api/models/errors.dart';
import 'package:control_api/routes/admin.dart';
import 'package:control_api/routes/api_keys.dart';
import 'package:control_api/routes/capabilities.dart';
import 'package:control_api/routes/commands.dart';
import 'package:control_api/routes/connectors.dart';
import 'package:control_api/routes/devices.dart';
import 'package:control_api/auth/pairing_code_registry.dart';
import 'package:control_api/routes/owner.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/storage/persistence.dart';
import 'package:control_api/util/http_utils.dart';
import 'package:control_api/util/tls_bind_policy.dart';
import 'package:control_api/validation/schema_validator.dart' show maxUploadRequestBodyBytes;
import 'package:control_api/websocket/handlers.dart';

void main(List<String> args) async {
  final state = AppState();
  // Item 10: pairing code TTL (default 300s, 60..3600 ke beech clamp).
  final ttlSeconds =
      (int.tryParse(Platform.environment['PAIRING_CODE_TTL_SECONDS'] ?? '') ?? 300)
          .clamp(60, 3600)
          .toInt();
  state.pairingCodes = PairingCodeRegistry(ttl: Duration(seconds: ttlSeconds));

  // Item 4/17: TLS-proxy signal pehle hi nikal lete hain — rate limiter
  // ko bhi chahiye (X-Forwarded-For trust karne ke liye), aur bind
  // decision ko bhi. Railway apne edge par hamesha TLS terminate karta
  // hai aur `RAILWAY_ENVIRONMENT*` env vars set karta hai, isliye woh
  // bhi explicit `BEHIND_TLS_PROXY=true` jaisa hi signal maana jata hai
  // (warna deploy par server localhost par bind hokar /healthz fail
  // kar deta tha).
  final behindTlsProxy =
      parseBehindTlsProxy(Platform.environment['BEHIND_TLS_PROXY']) ||
          Platform.environment.containsKey('RAILWAY_ENVIRONMENT') ||
          Platform.environment.containsKey('RAILWAY_ENVIRONMENT_NAME');

  // Item 4: production config check — missing env vars ka saaf warning.
  _warnAboutMissingConfig();

  // ---- Persistence — restart survive karne ke liye --------------------
  // README/HOW_TO_CONNECT.md mein likha hai: Railway par isko kaam karne
  // ke liye ek Volume `/data` par mount karna zaroori hai, warna yeh
  // sirf container ke andar ka ephemeral folder hoga.
  final persistence = Persistence(state);
  await persistence.load();

  // ---- DEP-01: Deployment Durability — startup health check ------------
  // "Restart with attached volume retains state; without volume warning
  // is explicit; health endpoint works." Health endpoint (`/healthz`)
  // already neeche hai. Yahan do cheezein turant, server start hote hi,
  // check karte hain — kisi request ke beech mein pehli baar pata chalne
  // se behtar hai.
  final dataDir = Persistence.dataDirectory();
  final writable = await persistence.verifyWritable();
  if (!writable) {
    // ignore: avoid_print
    print('WARNING: DATA_DIR ("$dataDir") likhne-ke-laayak nahi hai — '
        'saara state sirf in-memory rahega, koi restart survive nahi karega, '
        'aur is process ke andar hi save() calls silently fail hote rahenge. '
        'Check karein: directory exist karti hai? Permissions sahi hain?');
  } else {
    final deviceCount = state.devices.length;
    // ignore: avoid_print
    print('DATA_DIR ("$dataDir") writable hai. $deviceCount device(s) load hui.');
    if (deviceCount == 0) {
      // ignore: avoid_print
      print('NOTE: 0 devices load hui — agar yeh ek fresh deployment hai to '
          'normal hai. Agar yeh ek restart hai aur pehle devices paired thi, '
          'to iska matlab Railway Volume attach nahi hai (data restart par '
          'lost ho gaya) — Railway dashboard mein Volume check karein '
          '(HOW_TO_CONNECT.md).');
    }
  }
  state.onMutated = persistence.save;

  // Safety net — high-frequency events (activity log, jo har command ke
  // saath badalta hai) har mutation par explicitly save nahi karte
  // (bahut zyada disk writes ho jaate), isliye ek periodic save bhi
  // rakha hai taaki woh bhi zyada der tak un-persisted na rahe.
  Timer.periodic(const Duration(seconds: 30), (_) => persistence.save());

  // P0 fix: (1) stale device connections (heartbeat 30s, cutoff 90s) —
  // sweepStaleDevices pehle kahin call hi nahi hota tha; (2) khule
  // session/screen sockets ko dobara validate (expired API key etc.).
  Timer.periodic(const Duration(seconds: 30), (_) {
    state.sweepStaleDevices();
    state.revalidateListeners();
  });

  // Item 59 (pehle sirf status doc mein tha): stale tasks ko FAILED karo,
  // purane terminal tasks hatao.
  Timer.periodic(const Duration(hours: 1), (_) {
    state.sweepTasks();
  });

  // P1-09 — audit retention policy. Default 90 din, `AUDIT_RETENTION_DAYS`
  // env var se override ho sakta hai. Roz ek baar chalta hai (har 30
  // second check karne ki zaroorat nahi — yeh ek din-level policy hai).
  final retentionDays = int.tryParse(Platform.environment['AUDIT_RETENTION_DAYS'] ?? '') ?? 90;
  Timer.periodic(const Duration(hours: 24), (_) {
    final removed = state.pruneActivityLog(retention: Duration(days: retentionDays));
    if (removed > 0) {
      // ignore: avoid_print
      print('Audit retention: $removed events (older than $retentionDays din) removed');
      persistence.save();
    }
  });

  final router = Router();

  // ---- REST routes --------------------------------------------------------
  router.mount('/', deviceRoutes(state));
  router.mount('/', apiKeyRoutes(state));
  router.mount('/', capabilityRoutes(state));
  final commandRouter = commandRoutes(state);
  router.mount('/', commandRouter.call);
  router.mount('/', ownerRoutes(state, commandRouter.call).call);
  router.mount('/', adminRoutes(state, commandRouter.call).call);
  router.mount('/', connectorRoutes(state));

  // ---- WebSocket routes -----------------------------------------------------
  // P0-05 — connection-count limits: ek session par bahut zyada
  // listeners jud jaana (galti se ya jaan-bujh kar) server ko har naye
  // event ko excessive fan-out karne par majboor kar sakta hai. Yahan
  // WS upgrade hone se PEHLE hi reject karte hain (normal HTTP 429,
  // handshake kabhi hota hi nahi).
  // P0 SECURITY FIX — har WS route par authorization check WS upgrade se
  // PEHLE hoti hai (normal HTTP 401/403/404, handshake kabhi hota hi
  // nahi agar unauthorized). Yeh `deviceAuthMiddleware` ke context par
  // depend karta hai, jo is pipeline mein router se pehle chal chuka
  // hota hai — isliye `request.context['device']`/`['apiKey']` yahan
  // tak pahunchte-pahunchte already resolve ho chuke hain.
  const maxListenersPerSession = 5;
  router.get('/sessions/<id>', (Request request, String id) async {
    request = applyWsTicket(request, state);
    final authError = authorizeSessionConnection(request, state, id);
    if (authError != null) return authError;
    if ((state.sessionListeners[id]?.length ?? 0) >= maxListenersPerSession) {
      return ApiError.rateLimited(
          'Session "$id" par already $maxListenersPerSession listeners connected hain');
    }
    return await sessionEventsHandler(state, id, listenerOwnerFor(request, state, id))(request);
  });
  router.get('/screen/<id>', (Request request, String id) async {
    request = applyWsTicket(request, state);
    final authError = authorizeSessionConnection(request, state, id);
    if (authError != null) return authError;
    if ((state.screenListeners[id]?.length ?? 0) >= maxListenersPerSession) {
      return ApiError.rateLimited(
          'Session "$id" ka live screen already $maxListenersPerSession viewers dekh rahe hain');
    }
    return await screenFramesHandler(state, id, listenerOwnerFor(request, state, id))(request);
  });
  router.get('/audio/<id>', (Request request, String id) async {
    request = applyWsTicket(request, state);
    final authError = authorizeSessionConnection(request, state, id);
    if (authError != null) return authError;
    if ((state.audioListeners[id]?.length ?? 0) >= maxListenersPerSession) {
      return ApiError.rateLimited(
          'Session "$id" ka live audio already $maxListenersPerSession listeners sun rahe hain');
    }
    return await audioFramesHandler(state, id, listenerOwnerFor(request, state, id))(request);
  });
  // Web dashboard ka tez control channel (admin ws-ticket se).
  router.get('/admin/control', (Request request) async {
    request = applyWsTicket(request, state);
    if (request.context['admin'] != true) {
      return unauthorized('Valid admin ws-ticket (?ticket=) required');
    }
    return await adminControlHandler(state, commandRouter.call)(request);
  });
  router.get('/devices/<id>/agent', (Request request, String id) async {
    final authError = authorizeDeviceAgentConnection(request, state, id);
    if (authError != null) return authError;
    return await deviceAgentHandler(state, id)(request);
  });

  router.get('/healthz', (Request request) => Response.ok('ok'));
  // /healthz Railway ke liye hamesha 200 (process zinda). /readyz sach batata
  // hai: DATA_DIR likhne layak na ho (Volume mount nahi) to 503 — warna server
  // "healthy" dikhta rehta aur restart par saari state kho jati.
  router.get('/readyz', (Request request) async {
    final ok = await persistence.verifyWritable();
    return Response(ok ? 200 : 503,
        body: jsonEncode({'persistence_writable': ok}),
        headers: {'content-type': 'application/json'});
  });

  // Web dashboard (alag origin, jaise Netlify) ke liye CORS — sirf listed origins.
  final corsOrigins = (Platform.environment['CORS_ALLOWED_ORIGINS'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();

  final pipeline = const Pipeline()
      .addMiddleware(corsMiddleware(corsOrigins))
      .addMiddleware(safeRequestLogging())
      // Item 16: global body-size limit (auth/rate-limit se pehle, taaki
      // bade body memory mein bhar hi na sake). Ceiling = upload limit
      // (item 39); baaki actions ka tighter 2 MiB limit validator mein hai.
      .addMiddleware(bodySizeLimitMiddleware(maxUploadRequestBodyBytes + 1024 * 1024))
      .addMiddleware(deviceAuthMiddleware(state))
      // P0-05 — auth ke BAAD rakha hai, taaki identity (api key / device)
      // resolve ho chuki ho jab rate-limiter usko identify karne ki
      // koshish kare (warna sab unauthenticated requests IP par fallback
      // ho jaate, jo NAT ke peeche multiple legit users ko ek hi bucket
      // mein daal deta).
      .addMiddleware(rateLimitMiddleware(trustProxy: behindTlsProxy))
      .addHandler(router.call);

  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  // ---- P0-03: Production HTTPS/WSS Transport -----------------------------
  //
  // Do deployment patterns yahan support hote hain:
  //
  // 1: **Reverse-proxy TLS termination (Railway ka default, recommended)**
  //    — Railway (ya koi bhi PaaS: Render, Fly.io, etc.) khud apne edge
  //    par HTTPS/WSS terminate karta hai aur andar plain HTTP se container
  //    tak forward karta hai. Yeh **normal, safe pattern hai** — client
  //    se leke Railway tak transport encrypted rehta hai; Railway-se-
  //    container ka hop private network ke andar hota hai. Is mode mein
  //    yahan `SSL_CERT_PATH`/`SSL_KEY_PATH` set NAHI karne (default) —
  //    lekin ab (audit fix) sirf itna kaafi nahi: `BEHIND_TLS_PROXY=true`
  //    bhi explicitly set karna hoga, warna server safe default (localhost-
  //    only bind) mein rahega — dekhein neeche.
  //
  // 2: **Direct in-process TLS (self-hosting, koi reverse proxy nahi)** —
  //    agar koi VPS par bina proxy ke seedha yeh binary expose kar raha
  //    ho, to `SSL_CERT_PATH` + `SSL_KEY_PATH` env vars set karke server
  //    khud HTTPS/WSS par terminate kar sakta hai.
  //
  // Dono mein se koi bhi mode ho, TLS certificate validation kabhi bypass
  // nahi hoti (yahan koi `badCertificateCallback` ya `SecurityContext`
  // override nahi hai jo validation skip kare).
  final certPath = Platform.environment['SSL_CERT_PATH'];
  final keyPath = Platform.environment['SSL_KEY_PATH'];

  // Audit fix (P0-03, Section 13): "Direct server still listens
  // plaintext when TLS env vars are absent, so deployment must be
  // configured correctly." — matlab yeh purely operator-trust par tha:
  // agar koi galti se plain HTTP port seedha internet par expose kar de
  // (reverse proxy lagana bhool jaaye), koi safety net nahi thi — server
  // chup-chap `anyIPv4` (sab interfaces) par bind ho jaata, device
  // tokens/API keys plaintext internet par chal jaate.
  //
  // Ab "secure by default": agar TLS certs nahi hain (Mode 1, reverse
  // proxy wala) to server sirf **localhost** par bind hota hai, jab tak
  // operator explicitly `BEHIND_TLS_PROXY=true` set karke yeh na bataye
  // ke "haan, mujhe pata hai, ek TLS-terminating reverse proxy already
  // mere saamne hai" — jo Railway/Render/Fly.io jaisi deployments ke
  // liye ek baar ka, deliberate opt-in hai, accidental exposure nahi.
  final hasDirectTls = certPath != null && keyPath != null;
  final bindAddress = shouldBindAllInterfaces(
          hasDirectTls: hasDirectTls, behindTlsProxy: behindTlsProxy)
      ? InternetAddress.anyIPv4
      : InternetAddress.loopbackIPv4;

  HttpServer server;
  if (hasDirectTls) {
    final context = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath,
          password: Platform.environment['SSL_KEY_PASSWORD']);
    server = await shelf_io.serve(
      pipeline,
      bindAddress,
      port,
      securityContext: context,
    );
    // ignore: avoid_print
    print('Control API listening on https://${server.address.host}:${server.port} '
        '(direct TLS termination)');
    // ignore: avoid_print
    print('WebSocket endpoints: wss://<host>:${server.port}/sessions/{id} , '
        '/screen/{id} , /devices/{id}/agent');
  } else {
    server = await shelf_io.serve(pipeline, bindAddress, port);
    if (behindTlsProxy) {
      // ignore: avoid_print
      print('Control API listening on http://${server.address.host}:${server.port} '
          '(plaintext, all interfaces — BEHIND_TLS_PROXY=true set, '
          'trusting that a TLS-terminating reverse proxy is in front, '
          'e.g. Railway\'s edge.)');
    } else {
      // ignore: avoid_print
      print('Control API listening on http://${server.address.host}:${server.port} '
          '(plaintext, LOCALHOST ONLY — safe default, is se bahar koi '
          'connect nahi kar sakta). Production ke liye do options:');
      // ignore: avoid_print
      print('  1. SSL_CERT_PATH + SSL_KEY_PATH env vars set karein '
          '(direct TLS termination), YA');
      // ignore: avoid_print
      print('  2. Agar ek TLS-terminating reverse proxy (Railway/Render/'
          'Fly.io/nginx) pehle se saamne hai, BEHIND_TLS_PROXY=true set '
          'karein — is se sab interfaces par bind hoga.');
    }
    // ignore: avoid_print
    print('WebSocket endpoints: ws://<host>:${server.port}/sessions/{id} , '
        '/screen/{id} , /devices/{id}/agent');
  }
}

/// Item 4: startup par production-critical env vars check karta hai aur
/// jo missing ho uska saaf warning print karta hai (server band nahi
/// karta — local development mein yeh sab optional hain).
void _warnAboutMissingConfig() {
  final env = Platform.environment;
  void warn(String msg) {
    // ignore: avoid_print
    print('CONFIG WARNING: $msg');
  }

  if ((env['ADMIN_TOKEN'] ?? '').length < 32) {
    warn('ADMIN_TOKEN (>= 32 chars) set nahi hai — web dashboard (/admin/*) band hai. '
        'Set karne ke liye: `openssl rand -hex 32`.');
  }
  if ((env['CORS_ALLOWED_ORIGINS'] ?? '').isEmpty) {
    warn('CORS_ALLOWED_ORIGINS khaali hai — alag domain par hosted website (jaise '
        'Netlify) server se browser mein baat nahi kar paegi. Example: '
        'CORS_ALLOWED_ORIGINS=https://meri-site.netlify.app');
  }
  if ((env['CONNECTOR_ENCRYPTION_KEY'] ?? '').isEmpty) {
    warn('CONNECTOR_ENCRYPTION_KEY set nahi hai — connector (Google Drive/'
        'Dropbox) credentials ke liye ephemeral key use hogi aur restart '
        'ke baad woh credentials decrypt nahi honge.');
  }
  if ((env['CONNECTOR_REDIRECT_BASE_URL'] ?? '').isEmpty) {
    warn('CONNECTOR_REDIRECT_BASE_URL set nahi hai — OAuth callback URL '
        'sahi nahi banega.');
  }
  if ((env['PAIRING_SECRET'] ?? '').isEmpty) {
    warn('PAIRING_SECRET set nahi hai — POST /devices/pair koi bhi '
        '(rate-limit ke andar) call kar sakta hai. Production mein set karein.');
  }
  if ((env['REQUIRE_PAIRING_CODE'] ?? '').toLowerCase() == 'true' &&
      (env['ADMIN_SECRET'] ?? '').length < 16) {
    warn('REQUIRE_PAIRING_CODE=true hai lekin ADMIN_SECRET (min 16 chars) '
        'set nahi — pehla device pair karne ka koi tareeqa nahi bachega.');
  }
  final dataDir = env['DATA_DIR'] ?? '';
  if (dataDir.isEmpty) {
    warn('DATA_DIR set nahi hai — default `/data` use hoga; Railway par '
        'Volume `/data` mount karke DATA_DIR=/data set karein.');
  }
}
