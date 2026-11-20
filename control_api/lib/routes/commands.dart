import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/device_auth.dart';
import '../models/activity.dart';
import '../models/api_key.dart';
import '../models/errors.dart';
import '../models/task.dart';
import '../storage/app_state.dart';
import '../util/http_utils.dart';
import '../validation/data_channel_security.dart';
import '../validation/schema_validator.dart';

/// P0-01 — control.pause/resume/stop is set mein hain, in par
/// server-side TaskRecord state machine chalta hai (baaki commands sirf
/// task ko implicitly RUNNING create/keep karte hain).
const _taskControlActions = {
  'control.pause',
  'control.resume',
  'control.stop',
  // Audit fix (Section 8 / Section 13 #2) — explicit completion/failure.
  'control.complete',
  'control.fail',
};

/// `control.complete`/`control.fail` device tak forward NAHI hoti —
/// yeh caller/orchestrator ka judgment hai ke uska multi-step kaam
/// khatam ho gaya (ya fail ho gaya), device ko kuch "karne" ki zaroorat
/// nahi (device already har non-control command se pehle task state
/// dubara check karta hai; ek baar server COMPLETED/FAILED maan le, to
/// koi bhi aage ki non-control command server-side hi reject ho jaati
/// hai — neeche wala fail-closed dispatch gate). Isse yeh fayda hai ke
/// task ko complete/fail mark karna device ke online hone par depend
/// nahi karta — device offline ho chuki ho tab bhi kaam ko "done" mark
/// kiya ja sakta hai.
const _serverOnlyControlActions = {'control.complete', 'control.fail'};

/// PROTOCOL_V1.md — sirf yeh major version supported hai. Minor version
/// mismatch (e.g. client "1.5" bhejta hai) tolerate karte hain (forward-
/// compatible additive fields), lekin major mismatch ("2.0") reject.
const _supportedProtocolMajor = '1';

bool _isProtocolVersionSupported(String? version) {
  if (version == null) return false;
  final major = version.split('.').first;
  return major == _supportedProtocolMajor;
}

Router commandRoutes(AppState state) {
  final router = Router();

  // POST /commands — Core Protocol ka dil. Command Envelope leta hai,
  // Policy Engine check karta hai (Section 3.5), phir device ko forward
  // karta hai uske persistent WS connection par.
  router.post('/commands', (Request request) async {
    final apiKey = request.context['apiKey'];
    if (apiKey == null) {
      return unauthorized('Valid scoped API key required (Authorization: Bearer <secret>)');
    }
    final key = apiKey as ApiKeyRecord;

    // ---- P0-04: Strict Request + Schema Validation ---------------------
    // Poora validation flow ab `validation/schema_validator.dart` mein
    // hai (single canonical validator layer) — yahan sirf orchestrate
    // karte hain: body-size + malformed-JSON check, phir protocol
    // version (apna dedicated error code/status hai isliye alag rakha),
    // phir baaki sab (required fields, capability/action known hain,
    // params schema, payload, timeout_ms).
    final String rawBody;
    try {
      rawBody = await request.readAsString();
    } on BodyTooLargeException {
      return ApiError.payloadTooLarge(
          'Request body $maxUploadRequestBodyBytes bytes se zyada hai — reject');
    }
    final bodyByteLength = utf8.encode(rawBody).length;
    final bodyResult = validateRawBody(rawBody, bodyByteLength,
        customManifests: state.customCapabilityManifests);
    if (!bodyResult.isValid) {
      final err = bodyResult.error!;
      return err.kind == 'PAYLOAD_TOO_LARGE'
          ? ApiError.payloadTooLarge(err.message)
          : ApiError.invalidRequest(err.message);
    }
    final envelope = bodyResult.envelope!;
    final requestId = envelope['request_id'] as String;

    // ---- PROTOCOL_V1.md: version check (protocol freeze, P0 item #1) ----
    final protocolVersion = envelope['protocol_version'] as String?;
    if (!_isProtocolVersionSupported(protocolVersion)) {
      return ApiError.unsupportedProtocolVersion(
        'protocol_version "${protocolVersion ?? '(missing)'}" supported nahi hai — '
        'yeh server sirf major version "$_supportedProtocolMajor.x" accept karta hai',
        requestId: requestId,
      );
    }

    // (validateRawBody() ne already `capability`/`action` ki presence,
    // type, aur ek-doosre se consistency check kar li hai — yahan sirf
    // extract karte hain, dubara validate nahi karna.)
    final capability = envelope['capability'] as String;
    final action = envelope['action'] as String;

    // ---- Policy Engine: ACTION-level scope check (P0-02, audit fix) -----
    // Pehle yahan `key.allows(capability)` tha — broad capability-level
    // check, jo audit ne explicitly disallow kiya hai ("Do not authorize
    // only by broad capability"). Ab `allowsAction(action)` — har action
    // apna dedicated scope-field check karta hai (`api_key.dart` mein
    // poora mapping hai, fail-closed default ke saath).
    //
    // `control.pause/resume/stop` yahan **exempt** hain — `allowsAction`
    // in ke liye hamesha `false` deta hai (fail-closed default, kyunki
    // in actions ka asal authorization kisi generic action-name check se
    // nahi ho sakta — task/session ki *originating capability* chahiye
    // hoti hai, jo neeche task-lifecycle block mein pata chalti hai).
    // Skip na karte to yeh yahin 403 ho jaate, kabhi task tak pahunchte
    // hi nahi.
    // Audit fix (P1-02): custom (P1-01) capability actions ke liye
    // `allowsAction()` hamesha `false` deta hai (woh sirf built-in
    // actions jaanta hai) — pehle isi wajah se koi bhi registered
    // custom capability **kabhi call hi nahi ho sakti thi**, chahe
    // caller ki API key ko explicitly uski permission di bhi gayi ho
    // (feature registration ke baad khud hi dead code ban jaata tha).
    // Ab: agar action built-in scope se allowed nahi, lekin `capability`
    // ek registered custom manifest hai AUR is key ko us specific
    // custom capability ki explicit permission di gayi hai, to allow.
    // Item 15: custom capability sirf usi device ki keys ke liye valid
    // hai jisne use register kiya (`registered_by`); purane manifests
    // (registered_by nahi) backward-compat ke liye sabke liye valid.
    final isRegisteredCustomCapability = state.customCapabilityManifests.any(
        (m) =>
            m['capability'] == capability &&
            (m['registered_by'] == null || m['registered_by'] == key.deviceId));
    final authorized = _taskControlActions.contains(action) ||
        key.scope.allowsAction(action) ||
        (isRegisteredCustomCapability && key.scope.allowsCustomCapability(capability));
    if (!authorized) {
      state.logActivity(ActivityEvent(
        eventType: action,
        deviceId: key.deviceId,
        timestamp: DateTime.now().toUtc(),
        status: 'fail',
        actor: 'api_key:${key.keyId}',
      ));
      return ApiError.scopeDenied(
        'Yeh key "$action" action ke liye authorized nahi hai',
        requestId: requestId,
      );
    }

    // Item 20: envelope ka `api_key_id` client likhta hai — audit/device
    // tak hamesha authenticated key ki asli id jaye, spoofed nahi.
    envelope['api_key_id'] = key.keyId;

    // Item 13: browser.navigate sirf http/https (file://, javascript:,
    // intent:, data: jaisi schemes block).
    if (action == 'browser.navigate') {
      final navParams = envelope['params'] as Map<String, dynamic>? ?? const {};
      final urlResult = validateBrowserUrl(navParams['url'] as String?);
      if (!urlResult.isValid) {
        state.logActivity(ActivityEvent(
          eventType: action,
          deviceId: key.deviceId,
          timestamp: DateTime.now().toUtc(),
          status: 'fail',
          actor: 'api_key:${key.keyId}',
        ));
        return ApiError.invalidRequest(urlResult.error!, requestId: requestId);
      }
    }

    // Agar command kisi session se related hai (screen/task commands
    // mein aam taur par params.session_id hota hai), to us session ko
    // is device se map kar dete hain — taaki WS /sessions/{id} listeners
    // ko events mil sakein.
    final params = envelope['params'] as Map<String, dynamic>? ?? const {};
    final sessionId = params['session_id'] as String?;
    // Item 6: pehle yahan mapping bina check ke overwrite hoti thi —
    // dusre device ki session hijack ho sakti thi. Ab sirf unclaimed ya
    // apni hi session claim hoti hai; warna 404 (existence leak nahi).
    if (sessionId != null && !state.claimSession(sessionId, key.deviceId)) {
      state.logActivity(ActivityEvent(
        eventType: action,
        deviceId: key.deviceId,
        timestamp: DateTime.now().toUtc(),
        status: 'fail',
        actor: 'api_key:${key.keyId}',
      ));
      return ApiError.notFound('Session "$sessionId" nahi mili',
          requestId: requestId);
    }

    // `control.*` ka matlab hi ek task/session par kaam hai. Bina
    // session_id ke yeh action pehle seedha device tak bina kisi
    // task-bound authorization ke forward ho jata tha.
    if (_taskControlActions.contains(action) && sessionId == null) {
      return ApiError.invalidRequest(
          '"$action" ke liye params.session_id required hai',
          requestId: requestId);
    }

    // ---- P1-05: device-state-aware dispatch gate ---------------------------
    // "Never claim remote execution when OS cannot support it." — device
    // ki reported state (P1-05, `websocket/handlers.dart`'s `status_update`)
    // ke hisaab se kuch capabilities fundamentally dispatch hi nahi honi
    // chahiye. `control.*` exempt hai (pause/resume/stop kisi bhi state mein
    // meaningful hai — chalti hui automation ko rokna hamesha allowed hona
    // chahiye, chahe screen ka access ho ya na ho).
    final device = state.devices[key.deviceId];
    if (device != null && capability != 'control') {
      final gateError = deviceStateGateError(device.state, capability, requestId);
      if (gateError != null) {
        state.logActivity(ActivityEvent(
          eventType: action,
          deviceId: key.deviceId,
          taskId: sessionId,
          timestamp: DateTime.now().toUtc(),
          status: 'fail',
          actor: 'api_key:${key.keyId}',
        ));
        return gateError;
      }
    }

    // ---- P1-08: Data Channel Hardening — path/size/type checks ------------
    // "SEC-02: oversized upload rejected before storage/dispatch" aur
    // "DATA-01: traversal rejected" — dono is block mein, device tak
    // forward hone se pehle hi.
    if (action == 'files.list' ||
        action == 'files.read' ||
        action == 'files.write' ||
        action == 'files.delete' ||
        action == 'data.upload' ||
        action == 'data.download') {
      final path = params['path'] as String? ?? params['target_path'] as String?;
      if (path != null) {
        final pathResult = validateFilePath(path);
        if (!pathResult.isValid) {
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'fail',
            actor: 'api_key:${key.keyId}',
          ));
          return ApiError.invalidRequest(pathResult.error!, requestId: requestId);
        }

        if (action == 'files.write' || action == 'data.upload') {
          final typeResult = validateUploadFileType(path);
          if (!typeResult.isValid) {
            state.logActivity(ActivityEvent(
              eventType: action,
              deviceId: key.deviceId,
              taskId: sessionId,
              timestamp: DateTime.now().toUtc(),
              status: 'fail',
              actor: 'api_key:${key.keyId}',
            ));
            return ApiError.forbidden(typeResult.error!, requestId: requestId);
          }
        }
      }

      if (action == 'files.write' || action == 'data.upload') {
        final payload = envelope['payload'] as String?;
        final sizeResult = validateUploadPayloadSize(payload);
        if (!sizeResult.isValid) {
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'fail',
            actor: 'api_key:${key.keyId}',
          ));
          return ApiError.payloadTooLarge(sizeResult.error!, requestId: requestId);
        }
      }
    }

    // ---- P0-01: Real TaskRecord state machine ------------------------------
    // `session_id` hi task ka correlation id hai (models/task.dart mein
    // wajah documented hai — envelope shape todni nahi thi).
    //
    // `_rollbackTaskState` set hoti hai jab hum ek control transition
    // apply kar chuke hain lekin device tak forward abhi hona baaki hai —
    // agar forward fail ho jaaye (device offline/timeout), to isi se
    // server ka state wapas revert karte hain, taaki server aur device
    // ka pause/resume/stop view kabhi mismatch na ho (server ne "paused"
    // maan liya ho lekin device ne kabhi suna hi na ho, aisa nahi hona
    // chahiye).
    TaskState? rollbackTaskState;
    TaskState? appliedTaskState; // is request ne jo state set ki (rollback guard)
    // Audit fix (Section 8) — `control.resume` ke saath server ka
    // authoritative `lastCheckpoint` bhi device ko forward karte hain
    // (params.server_checkpoint, ek naya *optional* params field —
    // PROTOCOL_V1.md ka frozen top-level envelope shape nahi badla,
    // sirf params ke andar ek additive key hai). Device isko sirf tab
    // use karta hai jab uska apna in-memory checkpoint us se peeche ho
    // (jaise process restart ke baad) — normal same-process pause/resume
    // mein device ka local checkpoint hi authoritative rehta hai.
    Map<String, dynamic>? resumeServerCheckpoint;
    if (sessionId != null) {
      if (_taskControlActions.contains(action)) {
        // control.pause / control.resume / control.stop — koi existing
        // task hona zaroori hai (in actions ka matlab hi hai ke koi task
        // pehle se chal raha ho).
        final task = state.tasks[sessionId];
        if (task == null) {
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'fail',
            actor: 'api_key:${key.keyId}',
          ));
          return ApiError.notFound(
            'Task "$sessionId" nahi mila — pehle koi command us session_id '
            'ke saath run honi chahiye thi',
            requestId: requestId,
          );
        }

        if (action == 'control.resume' && task.lastCheckpoint != null) {
          resumeServerCheckpoint = task.lastCheckpoint;
        }

        // ---- P0-02: task/session capability-bound authorization ---------
        // Yehi woh asal check hai jo interim OR-bypass ki jagah leta hai.
        // Key ke paas is task ko originally shuru karne wali capability
        // ka scope hona zaroori hai — koi unrelated capability isse
        // bypass nahi kar sakti (audit: "control action unrelated
        // capability se bypass na ho").
        if (!(key.scope.allowsCapability(task.originatingCapability) ||
            key.scope.allowsCustomCapability(task.originatingCapability))) {
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'fail',
            actor: 'api_key:${key.keyId}',
          ));
          return ApiError.scopeDenied(
            'Yeh key "${task.originatingCapability}" capability (task '
            '"$sessionId" ki originating capability) ke liye authorized '
            'nahi hai — is liye "$action" nahi chala sakti',
            requestId: requestId,
          );
        }

        final stateBeforeTransition = task.state;
        final transition = task.applyAction(action);
        if (!transition.allowed) {
          // ---- Invalid/unknown transition -> REJECT, device tak dispatch
          // bilkul nahi hota (audit requirement: "Unknown/invalid
          // transitions reject karo").
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'fail',
            actor: 'api_key:${key.keyId}',
          ));
          return ApiError.invalidRequest(
            transition.reason ?? 'Invalid task state transition',
            requestId: requestId,
          );
        }

        // control.fail ke saath optional params.reason ho sakta hai —
        // capture kar lete hain (idempotent repeat par bhi override karna
        // theek hai, latest reason hi meaningful hai).
        if (action == 'control.fail') {
          final reason = params['reason'] as String?;
          if (reason != null) task.terminalReason = reason;
        }

        // ---- control.complete / control.fail: server-authoritative, ----
        // device tak forward NAHI hoti (upar `_serverOnlyControlActions`
        // ka comment dekhein) — turant respond karte hain.
        if (_serverOnlyControlActions.contains(action)) {
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'success',
            actor: 'api_key:${key.keyId}',
          ));
          if (!transition.isNoop) {
            state.broadcastTaskState(task);
            // Item 56: device ko bhi batao (live stream band karne ke liye).
            state.notifyDeviceTaskState(task);
            state.persist();
          }
          return Response.ok(
            jsonEncode({'acknowledged': true, 'task': task.toJson()}),
            headers: {'content-type': 'application/json'},
          );
        }

        // Idempotent repeats: kuch revert nahi karna (state already
        // unchanged). Real transitions: agar device tak forward fail ho
        // jaaye to niche rollback ho jayega.
        if (!transition.isNoop) {
          rollbackTaskState = stateBeforeTransition;
          appliedTaskState = task.state;
        }
      } else {
        // Koi normal (non-control) command — task ko implicitly
        // RUNNING mein create/track karte hain agar abhi tak nahi bana.
        final task = state.getOrCreateRunningTask(sessionId, key.deviceId, capability);
        if (task.state == TaskState.running) task.touch(); // stale-sweeper ke liye

        // ---- Fail-closed dispatch gate --------------------------------
        // PAUSED task ke liye koi nayi action dispatch nahi honi chahiye
        // (TASK-01 acceptance). STOPPED task ke liye bhi nahi (task khatam
        // ho chuka). control.switch is gate se exempt nahi hai by design —
        // woh bhi ek session-scoped action hai jo paused/stopped task par
        // nahi chalni chahiye.
        if (task.state == TaskState.paused) {
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'fail',
            actor: 'api_key:${key.keyId}',
          ));
          return ApiError.invalidRequest(
            'Task "$sessionId" abhi PAUSED hai — pehle control.resume karein',
            requestId: requestId,
          );
        }
        if (task.state == TaskState.stopped ||
            task.state == TaskState.completed ||
            task.state == TaskState.failed) {
          state.logActivity(ActivityEvent(
            eventType: action,
            deviceId: key.deviceId,
            taskId: sessionId,
            timestamp: DateTime.now().toUtc(),
            status: 'fail',
            actor: 'api_key:${key.keyId}',
          ));
          return ApiError.invalidRequest(
            'Task "$sessionId" ${task.state.wireValue} hai — is par nayi '
            'action dispatch nahi ho sakti',
            requestId: requestId,
          );
        }
      }
    }

    // ---- Forward to device -------------------------------------------------
    if (resumeServerCheckpoint != null) {
      envelope['params'] = {...params, 'server_checkpoint': resumeServerCheckpoint};
    }
    try {
      // Item 38: envelope ka `timeout_ms` ab sach mein use hota hai
      // (pehle validate hota tha par ignore; hamesha 15s).
      final requestedTimeoutMs = (envelope['timeout_ms'] as num?)?.toInt();
      // Item 39: file transfer actions (10 MiB base64 tak) ko default 15s
      // kaafi nahi — unka default 60s.
      final defaultTimeoutMs = _isFileTransferAction(action) ? 60000 : 15000;
      final dispatchTimeout = Duration(
          milliseconds:
              (requestedTimeoutMs ?? defaultTimeoutMs).clamp(1000, 120000).toInt());
      final result = await state.sendCommandToDevice(key.deviceId, envelope,
          timeout: dispatchTimeout);
      state.logActivity(ActivityEvent(
        eventType: action,
        deviceId: key.deviceId,
        taskId: sessionId,
        timestamp: DateTime.now().toUtc(),
        status: 'success',
        actor: 'api_key:${key.keyId}',
      ));
      // Item 32: `location.refresh` ka result server par bhi save karo,
      // taaki Device Status mein location dikhe (pehle kabhi save nahi
      // hota tha).
      if (action == 'location.refresh') {
        final clean = sanitizeLocation(result);
        if (clean != null && device != null) {
          device.lastLocation = clean;
          state.persist();
        }
      }
      // Forward kamyaab hui — agar yeh ek real (non-noop) task
      // transition thi, ab isko authoritative maan kar broadcast karte
      // hain.
      if (rollbackTaskState != null && sessionId != null) {
        final t = state.tasks[sessionId];
        if (t != null) {
          state.broadcastTaskState(t);
          state.persist();
        }
      }
      // Control actions ke response mein authoritative server-side task
      // state bhi shamil karte hain (caller ko device ke bare {acknowledged
      // :true} se aage ek real state dikhta hai).
      final responseBody = _taskControlActions.contains(action) &&
              sessionId != null &&
              state.tasks.containsKey(sessionId)
          ? {...result, 'task': state.tasks[sessionId]!.toJson()}
          : result;
      return Response.ok(jsonEncode(responseBody),
          headers: {'content-type': 'application/json'});
    } on StateError catch (e) {
      // Device offline — agar hum ne abhi task transition apply ki thi,
      // usko revert karo (server aur device ka view mismatch nahi hona
      // chahiye).
      if (rollbackTaskState != null && sessionId != null) {
        state.rollbackTask(sessionId, rollbackTaskState, appliedTaskState);
      }
      state.logActivity(ActivityEvent(
        eventType: action,
        deviceId: key.deviceId,
        taskId: sessionId,
        timestamp: DateTime.now().toUtc(),
        status: 'fail',
        actor: 'api_key:${key.keyId}',
      ));
      return ApiError.deviceOffline(e.message, requestId: requestId);
    } on DuplicateRequestException catch (e) {
      // Item 44: is request_id ka command abhi chal raha hai. Rollback
      // nahi karte — task transition is request ne apply hi nahi ki
      // (ya pehle wali request ki hai).
      return ApiError.invalidRequest(
          'request_id "${e.requestId}" abhi in-flight hai — naya unique request_id use karein',
          requestId: requestId);
    } on TimeoutException {
      // Item 49 + Stage 9: timeout par outcome UNKNOWN hai — device ne command
      // apply kar li ho sakti hai (sirf jawab late/gum hua). Pehle rollback hota
      // tha => server RUNNING, device PAUSED (mismatch). Ab transition *rakhte*
      // hain (conservative: koi nayi action dispatch nahi hoti) aur device ko
      // current state dubara bhejte hain (best-effort resync).
      if (rollbackTaskState != null && sessionId != null) {
        final t = state.tasks[sessionId];
        if (t != null) {
          state.notifyDeviceTaskState(t);
          state.persist();
        }
      }
      state.logActivity(ActivityEvent(
        eventType: action,
        deviceId: key.deviceId,
        taskId: sessionId,
        timestamp: DateTime.now().toUtc(),
        status: 'fail',
        actor: 'api_key:${key.keyId}',
      ));
      return ApiError.timeout(
        rollbackTaskState != null
            ? 'Command timeout — outcome unknown: control transition server par lagu '
                'rakhi gayi hai (device ne apply kiya ho sakta hai); task ki state check karein'
            : 'Command timeout ya device response nahi de raha',
        requestId: requestId,
      );
    } catch (e) {
      // Item 49: baaki sab (TypeError, encode error, ...) internal error
      // hain, timeout nahi. Rollback ka logic same.
      if (rollbackTaskState != null && sessionId != null) {
        state.rollbackTask(sessionId, rollbackTaskState, appliedTaskState);
      }
      state.logActivity(ActivityEvent(
        eventType: action,
        deviceId: key.deviceId,
        taskId: sessionId,
        timestamp: DateTime.now().toUtc(),
        status: 'fail',
        actor: 'api_key:${key.keyId}',
      ));
      return ApiError.internal('Command process karte waqt unexpected error',
          requestId: requestId);
    }
  });

  // POST /sessions/{session_id}/switch — Section 4, Universal Switch API.
  router.post('/sessions/<sessionId>/switch', (Request request, String sessionId) async {
    final apiKey = request.context['apiKey'];
    if (apiKey == null) {
      return unauthorized('Valid scoped API key required');
    }
    final key = apiKey as ApiKeyRecord;

    // ---- P0-04: safe JSON parsing + size bound (yeh route bhi /commands
    // jaisa hi crash-prone tha malformed JSON par) -------------------------
    final String rawBody;
    try {
      rawBody = await request.readAsString();
    } on BodyTooLargeException {
      return ApiError.payloadTooLarge(
          'Request body $maxRequestBodyBytes bytes se zyada hai — reject');
    }
    if (utf8.encode(rawBody).length > maxRequestBodyBytes) {
      return ApiError.payloadTooLarge(
          'Request body $maxRequestBodyBytes bytes se zyada hai — reject');
    }
    Map<String, dynamic> body;
    try {
      final parsed = jsonDecode(rawBody);
      if (parsed is! Map<String, dynamic>) {
        return ApiError.invalidRequest('Request body ek JSON object hona chahiye');
      }
      body = parsed;
    } on FormatException catch (e) {
      return ApiError.invalidRequest('Malformed JSON: ${e.message}');
    }

    final switchType = body['switch_type'];
    final value = body['value'];
    if (switchType is! String || switchType.isEmpty) {
      return ApiError.invalidRequest('"switch_type" required hai aur ek non-empty string honi chahiye');
    }
    if (value is! String) {
      return ApiError.invalidRequest('"value" required hai aur ek string honi chahiye');
    }

    // ---- P0-02: task/session capability-bound authorization -------------
    // Pehle yahan `allowsAction('control.switch')` tha, jo interim
    // OR-bypass policy use karta tha (koi bhi ek scope granted ho to
    // chalega, chahe unrelated ho) — ab woh method control.* ke liye
    // hamesha `false` deta hai (fail-closed, `models/api_key.dart`
    // dekhein). Asal authorization ab do cases mein bant'i hai:
    //
    // Case A — is session ka pehle se ek TaskRecord bana hua hai (matlab
    // kam-se-kam ek asal command us session_id par chal chuki hai):
    // switch usi task ki originating capability se bind hota hai — bilkul
    // pause/resume/stop jaisa, koi unrelated capability bypass nahi kar
    // sakti.
    //
    // Case B — koi task abhi tak nahi bana (switch hi is session ki
    // *pehli* action hai). Yeh ek real, existing UI flow hai
    // (`task_monitor_screen.dart`'s mode-switcher — "Hybrid" ya
    // "Snapshot" seedha select karna, bina pehle "Watch Live" click
    // kiye, `screen.watch_live` kabhi chalti hi nahi). Is case mein do
    // sub-cases hain:
    //   B1: `switch_type == 'viewing_mode'` — yeh hamesha screen
    //       capability ke baare mein hota hai (Snapshot/Live/Hybrid,
    //       Section 2.1). Is liye seedha `screenView` scope maangte hain,
    //       aur task ko `screen` capability ke saath implicitly create
    //       kar dete hain — taaki is session par future pause/resume/
    //       stop bhi consistently `screen` se bound rahein.
    //   B2: Baaki switch_types (`device`, `api_key`, `capability_target`)
    //       — yeh session-level meta-switches hain, kisi ek specific
    //       capability se tied nahi (poori tarah session ka target hi
    //       badal rahe hain), is liye inka koi ek "originating
    //       capability" infer nahi ho sakta. Yahan floor conservative
    //       rakha hai: key ke paas kam-se-kam koi ek real capability
    //       scope granted hona chahiye (poori tarah khaali/scope-less
    //       key allowed nahi) — yeh interim policy jaisa dikhta hai,
    //       lekin farq yeh hai ke yeh sirf inhi do narrow, task-less
    //       meta-switch-types tak mehdood hai; pause/resume/stop aur
    //       viewing_mode switch is se kabhi bypass nahi hote.
    // Item 6: session kisi aur device ki hai to 404 — switch se dusre
    // device ki session par events inject/hijack nahi ho sakte.
    if (!state.sessionBelongsTo(sessionId, key.deviceId)) {
      state.logActivity(ActivityEvent(
        eventType: 'switch_event',
        deviceId: key.deviceId,
        taskId: sessionId,
        timestamp: DateTime.now().toUtc(),
        status: 'fail',
        actor: 'api_key:${key.keyId}',
      ));
      return ApiError.notFound('Session "$sessionId" nahi mili');
    }

    final existingTask = state.tasks[sessionId];
    if (existingTask != null) {
      if (!(key.scope.allowsCapability(existingTask.originatingCapability) ||
          key.scope.allowsCustomCapability(existingTask.originatingCapability))) {
        state.logActivity(ActivityEvent(
          eventType: 'switch_event',
          deviceId: key.deviceId,
          taskId: sessionId,
          timestamp: DateTime.now().toUtc(),
          status: 'fail',
          actor: 'api_key:${key.keyId}',
        ));
        return ApiError.scopeDenied(
            'Yeh key "${existingTask.originatingCapability}" capability (task '
            '"$sessionId" ki originating capability) ke liye authorized nahi hai');
      }
    } else if (switchType == 'viewing_mode') {
      if (!key.scope.screenView) {
        state.logActivity(ActivityEvent(
          eventType: 'switch_event',
          deviceId: key.deviceId,
          taskId: sessionId,
          timestamp: DateTime.now().toUtc(),
          status: 'fail',
          actor: 'api_key:${key.keyId}',
        ));
        return ApiError.scopeDenied(
            'Yeh key "screen" capability ke liye authorized nahi hai '
            '(viewing_mode switch)');
      }
      // Session ka pehla real interaction yehi switch tha — task ko
      // "screen" capability se register kar dete hain (baad ki
      // pause/resume/stop calls isi se bind hongi).
      state.getOrCreateRunningTask(sessionId, key.deviceId, 'screen');
    } else {
      // B2 — device/api_key/capability_target: koi ek capability infer
      // nahi ho sakti, is liye "kam-se-kam kuch to granted ho" floor.
      final hasAnyCapability = key.scope.allowsCapability('screen') ||
          key.scope.allowsCapability('input') ||
          key.scope.allowsCapability('files') ||
          key.scope.allowsCapability('app_launcher') ||
          key.scope.allowsCapability('browser') ||
          key.scope.allowsCapability('clipboard') ||
          key.scope.allowsCapability('data') ||
          key.scope.allowsCapability('contacts') ||
          key.scope.allowsCapability('location') ||
          key.scope.allowsCapability('background');
      if (!hasAnyCapability) {
        state.logActivity(ActivityEvent(
          eventType: 'switch_event',
          deviceId: key.deviceId,
          taskId: sessionId,
          timestamp: DateTime.now().toUtc(),
          status: 'fail',
          actor: 'api_key:${key.keyId}',
        ));
        return ApiError.scopeDenied(
            'Yeh key ke paas koi bhi capability scope granted nahi hai — '
            '"$switchType" switch ke liye kam se kam ek chahiye');
      }
    }

    state.claimSession(sessionId, key.deviceId);

    // Item 50 (decision): switch ek **UI/orchestrator signal** hai — yeh
    // `switch_event` sirf is session ke subscribed listeners (dashboard,
    // AI verifier) ko broadcast hota hai; device ko kuch forward nahi
    // hota, aur `device`/`api_key`/`capability_target` switch ka koi
    // server-side routing effect nahi hai. (Asli device/key choice
    // caller khud karta hai: alag device = alag API key + alag
    // /commands call.)

    // Section 4.3 — switch_event turant broadcast hota hai, is se pehle
    // ke actual command complete ho (dashboard/AI ka context turant sync
    // rahe). PROTOCOL_V1.md Section 2 ke mutabiq protocol_version +
    // session_id bhi shamil hain.
    state.broadcastToSession(sessionId, {
      'protocol_version': '1.0',
      'type': 'switch_event',
      'session_id': sessionId,
      'switch_type': switchType,
      'new_value': value,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    state.logActivity(ActivityEvent(
      eventType: 'switch_event',
      deviceId: key.deviceId,
      taskId: sessionId,
      timestamp: DateTime.now().toUtc(),
      status: 'success',
      actor: 'api_key:${key.keyId}',
    ));

    return Response(204);
  });

  return router;
}

/// P1-05 — device state ke hisaab se capability dispatch gate ("Never
/// claim remote execution when OS cannot support it"). Screen-dependent
/// capabilities (jinhe ek unlocked, awake screen chahiye) sirf
/// ONLINE_UNLOCKED mein chalti hain. Background-capable capabilities
/// (OS-service-level, screen dekhe bina bhi kaam karti hain) ONLINE_LOCKED/
/// SCREEN_OFF mein bhi chal sakti hain — lekin SLEEPING/OFFLINE/POWERED_OFF
/// mein nahi, un states mein agent khud hi effectively kuch execute nahi
/// kar sakta.
const screenDependentCapabilities = {
  'screen',
  'input',
  'browser',
  'app_launcher',
  'clipboard',
};

Response? deviceStateGateError(String deviceState, String capability, String? requestId) {
  switch (deviceState) {
    case 'ONLINE_UNLOCKED':
      return null; // sab kuch allowed
    case 'ONLINE_LOCKED':
    case 'SCREEN_OFF':
      if (screenDependentCapabilities.contains(capability)) {
        return ApiError.forbidden(
          'Device abhi $deviceState hai — "$capability" ke liye unlocked, '
          'awake screen chahiye. Background capabilities (files/data/'
          'location/contacts) abhi bhi kaam karti hain.',
          requestId: requestId,
        );
      }
      return null; // background-capable capability, allowed
    case 'SLEEPING':
    case 'OFFLINE':
    case 'POWERED_OFF':
      return ApiError.deviceOffline(
        'Device abhi $deviceState hai — koi bhi remote action execute nahi ho sakti',
        requestId: requestId,
      );
    default:
      // Yeh case practically unreachable hai — `Device.state` sirf
      // `_validDeviceStates`-filtered values se hi set hoti hai
      // (`websocket/handlers.dart`). Defensive fail-open, security
      // boundary nahi hai (state khud hamara internal representation
      // hai, external input nahi).
      return null;
  }
}

/// File transfer actions jo bade base64 payloads le/de sakte hain.
bool _isFileTransferAction(String action) =>
    action == 'files.read' ||
    action == 'files.write' ||
    action == 'data.upload' ||
    action == 'data.download';
