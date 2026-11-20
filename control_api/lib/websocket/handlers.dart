import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:shelf/shelf.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/api_key.dart';
import '../models/device.dart';
import '../models/errors.dart';
import '../storage/app_state.dart';
import '../util/http_utils.dart';

/// **P0 SECURITY FIX (audit Section 7 / Section 13 #1).**
///
/// `deviceAuthMiddleware` sirf identity ko `request.context` mein daalta
/// hai — khud kisi request ko reject nahi karta (REST routes apni marzi
/// se check karte hain). WebSocket handlers pehle yeh check karte hi
/// nahi the, isliye koi bhi jo device/session id jaanta tha, seedha
/// connect kar sakta tha: device ka active connection replace kar sakta
/// tha, forwarded commands receive kar sakta tha, fake command_result/
/// event/screen_frame inject kar sakta tha, ya kisi aur ki live screen
/// subscribe kar sakta tha.
///
/// Yeh helper teeno WS routes ke liye ek hi jagah se authorization
/// decide karta hai, taaki logic duplicate na ho aur har route
/// consistently fail-closed rahe (koi identity match na ho to seedha
/// 401/403 — WS handshake shuru hi nahi hota).
/// `/devices/<id>/agent` — SIRF woh device khud connect kar sakti hai
/// jiska bearer token hai. Koi API key isse connect nahi kar sakti (yeh
/// device->server control channel hai, external client ka nahi).
Response? authorizeDeviceAgentConnection(Request request, AppState state, String deviceId) {
  final device = request.context['device'];
  if (device is! Device || device.id != deviceId) {
    return ApiError.unauthorized(
        'Device "$deviceId" ke liye valid device bearer token chahiye (Authorization: Bearer <device_token>) — '
        'yeh sirf paired device khud connect kar sakti hai.');
  }
  return null; // authorized
}

/// `/sessions/<id>` aur `/screen/<id>` — sessionId ek TaskRecord/taskId
/// hai, jiska ek owning device hota hai (`AppState.sessionToDevice`).
/// Authorized sirf woh hai jo:
///   - khud woh owning device ho (apna hi task monitor karna), YA
///   - ek enabled, us hi device se scoped, `screen_view` scope wali API
///     key ho (Dashboard/AI Verifier jaisa external monitor).
/// Scope ke liye `screenView` reuse kiya hai — koi alag "monitor" scope
/// nahi hai, aur "is device ki screen/progress dekhna" dono cases mein
/// wahi permission level hai. Unknown session id 404 deta hai (na ki
/// 401), taaki yeh leak na ho ke id sahi thi bas permission nahi thi.
Response? authorizeSessionConnection(Request request, AppState state, String sessionId) {
  // Credentials ke bina 401 — session id exist karti hai ya nahi, yeh
  // unauthenticated caller ko 404-vs-403 se pata nahi chalna chahiye.
  final isAdmin = request.context['admin'] == true; // admin ws-ticket
  if (!isAdmin &&
      request.context['device'] is! Device &&
      request.context['apiKey'] is! ApiKeyRecord) {
    return ApiError.unauthorized(
        'Authorization: Bearer <device_token ya screen_view API key> chahiye.');
  }
  final ownerDeviceId = state.sessionOwner(sessionId);
  if (ownerDeviceId == null) {
    return ApiError.notFound('Session "$sessionId" nahi mili.');
  }
  if (isAdmin) return null; // admin ticket: har session dekh/sun sakta hai

  final device = request.context['device'];
  if (device is Device && device.id == ownerDeviceId) {
    return null; // device apni khud ki session dekh/report kar rahi hai
  }

  final apiKey = request.context['apiKey'];
  if (apiKey is ApiKeyRecord &&
      apiKey.enabled &&
      apiKey.deviceId == ownerDeviceId &&
      apiKey.scope.screenView) {
    return null; // authorized scoped monitor
  }

  return ApiError.scopeDenied(
      'Session "$sessionId" access ke liye is device se scoped, '
      '"screen_view" scope wali API key ya khud device ka bearer token chahiye.');
}

/// Authorized request se listener principal banata hai (revalidation ke liye).
WsListenerOwner listenerOwnerFor(Request request, AppState state, String sessionId) {
  final device = request.context['device'];
  final apiKey = request.context['apiKey'];
  return WsListenerOwner(
    sessionId: sessionId,
    sessionDeviceId: state.sessionOwner(sessionId) ?? '',
    apiKeyId: (device is! Device && apiKey is ApiKeyRecord) ? apiKey.keyId : null,
    principalDeviceId: device is Device ? device.id : null,
    principalTokenHash: device is Device ? device.bearerTokenHash : null,
  );
}

/// Device se aane wale ek WS text frame ka max size (screen_frame base64
/// JPEG ke liye kaafi, memory-exhaustion se bachne ke liye bounded).
const maxAgentMessageChars = 8 * 1024 * 1024;

/// `WS /sessions/{id}` — Dashboard/AI Verifier is stream se
/// task_progress/switch_event sunte hain (Section 2.3).
Handler sessionEventsHandler(AppState state, String sessionId, WsListenerOwner owner) {
  return webSocketHandler((WebSocketChannel webSocket, String? protocol) {
    state.registerListener(webSocket, owner);
    state.sessionListeners.putIfAbsent(sessionId, () => {}).add(webSocket);
    webSocket.stream.listen(
      (_) {
        // Client se koi incoming message expected nahi (read-only stream
        // hai dashboard ke liye) — agar future mein client-side ack
        // chahiye ho to yahan handle hoga.
      },
      onDone: () => state.unregisterListener(webSocket),
      onError: (_) => state.unregisterListener(webSocket),
    );
  }, pingInterval: _wsPingInterval);
}

/// `WS /screen/{id}` — continuous live frames (base64 JPEG strings, jaisa
/// native `ScreenCaptureBridge.liveFrames()` deta hai).
Handler screenFramesHandler(AppState state, String sessionId, WsListenerOwner owner) {
  return webSocketHandler((WebSocketChannel webSocket, String? protocol) {
    state.registerListener(webSocket, owner);
    state.screenListeners.putIfAbsent(sessionId, () => {}).add(webSocket);
    state.screenViewerAttached(sessionId); // idle timer cancel
    // Static screen par naye viewer ko blank na dikhe — taaza frame replay.
    final replay = state.replayableScreenFrame(sessionId);
    if (replay != null) {
      try {
        webSocket.sink.add(replay);
      } catch (_) {}
    }
    webSocket.stream.listen(
      (_) {},
      onDone: () => state.unregisterListener(webSocket),
      onError: (_) => state.unregisterListener(webSocket),
    );
  }, pingInterval: _wsPingInterval);
}

/// `WS /audio/{id}` — continuous live system-audio chunks (binary PCM16).
/// Screen handler jaisa hi, bas koi "last frame replay" nahi (audio mein
/// replay ka matlab nahi — chup rehna hi sahi jab tak naya chunk na aaye).
Handler audioFramesHandler(AppState state, String sessionId, WsListenerOwner owner) {
  return webSocketHandler((WebSocketChannel webSocket, String? protocol) {
    state.registerListener(webSocket, owner);
    state.audioListeners.putIfAbsent(sessionId, () => {}).add(webSocket);
    webSocket.stream.listen(
      (_) {},
      onDone: () => state.unregisterListener(webSocket),
      onError: (_) => state.unregisterListener(webSocket),
    );
  }, pingInterval: _wsPingInterval);
}

/// Device se aaya binary screen frame: `[0x01][idLen][sessionId][jpeg]`.
/// Same rules jo text `screen_frame` par lagte hain: sirf owning device,
/// size cap, server-side FPS cap.
const _binaryFrameTypeScreen = 0x01;
const _binaryFrameTypeAudio = 0x02;

void handleAgentBinaryFrame(AppState state, String deviceId, List<int> raw) {
  if (raw.length < 3 || raw.length > maxAgentMessageChars) return;
  final type = raw[0];
  if (type != _binaryFrameTypeScreen && type != _binaryFrameTypeAudio) return;
  final idLen = raw[1];
  if (idLen == 0 || raw.length <= 2 + idLen) return;
  final String sessionId;
  try {
    sessionId = utf8.decode(raw.sublist(2, 2 + idLen));
  } catch (_) {
    return;
  }
  if (state.sessionOwner(sessionId) != deviceId) return;
  final payload = Uint8List.fromList(raw.sublist(2 + idLen));
  if (type == _binaryFrameTypeScreen) {
    if (!state.allowScreenFrame(sessionId)) return;
    state.broadcastToScreen(sessionId, payload);
  } else {
    // Audio: koi FPS-jaisa throttle nahi (chunks already server-independent
    // cadence par hain, ~50/sec @20ms — chhote hain, allowScreenFrame ka
    // 30fps cap yahan drop/gap paida karega jo ghararahat ban jayega).
    state.broadcastToAudio(sessionId, payload);
  }
}

/// `WS /devices/{id}/agent` — **naya endpoint**, jo pehle missing tha.
/// Device khud (background mein) is se persistent connection banata hai
/// (pairing ke turant baad). Server isi channel se:
///   - `{"type": "command", ...envelope}` bhejta hai (POST /commands se
///     forward hui)
///   - Device wahan se `{"type": "command_result", "request_id": ...,
///     "result": {...}}` ya `{"type": "event", ...event_envelope}`
///     (task_progress/switch_event) ya `{"type": "screen_frame",
///     "session_id": ..., "data": "<base64>"}` wapas bhej sakta hai.
///
/// **Client-side note:** `shared_app` mein iske corresponding
/// `AgentConnection` + `CommandDispatcher` classes add kiye gaye hain
/// (`lib/protocol/agent_connection.dart`) — yeh dono milke poora
/// "command server se aata hai -> device par execute hota hai -> result
/// wapas jaata hai" loop close karte hain.
/// Item 43: server har WS par ping bhejta hai — dead connection (mobile
/// network drop bina FIN ke) pakdi jaati hai aur `onDone` chalta hai,
/// warna device TCP timeout tak "online" dikhta rehta.
const _wsPingInterval = Duration(seconds: 30);

Handler deviceAgentHandler(AppState state, String deviceId) {
  return webSocketHandler((WebSocketChannel webSocket, String? protocol) {
    // Duplicate-connection replacement (audit Section 7): agar isi
    // device ki pehle se ek connection khuli hai (stale reconnect, ya
    // do processes ek hi device token se connect ho gaye), purani wali
    // ko explicitly close karte hain instead of use silently ignore
    // karke reference drop karne — warna woh socket kabhi close nahi
    // hoti aur commands galti se purani (dead) connection par bhejne ki
    // koshish ho sakti thi.
    final previous = state.deviceConnections[deviceId];
    if (previous != null && !identical(previous, webSocket)) {
      previous.sink.close(4000, 'replaced by a new connection from the same device');
    }
    state.deviceConnections[deviceId] = webSocket;
    final device = state.devices[deviceId];
    if (device != null) {
      // P1-05 fix: pehle yahan hardcoded 'ONLINE_UNLOCKED' set hota tha
      // — matlab "WebSocket connect ho gaya" aur "phone unlocked hai"
      // ko ek hi maan liya jaata tha (audit: "Distinguish device online
      // from app/agent connected"). Asal lock/sleep/screen-off state
      // device khud `status_update` message se batata hai (neeche
      // `_handleAgentMessage`) — yahan connect ke waqt sirf itna maante
      // hain ke agent reachable ho gaya hai.
      //
      // Agar device pehle se OFFLINE/POWERED_OFF thi (ya yeh pehla
      // connect hai), to ek optimistic default 'ONLINE_UNLOCKED' use
      // karte hain (audit ke fixed 6-state vocabulary mein koi 7th
      // "unknown" state nahi hai) — jo turant sahi ho jaata hai jaise hi
      // device apna pehla real `status_update` bhejta hai. Agar pehle
      // se koi aur real state pata thi (jaise ONLINE_LOCKED, reconnect
      // ka case), usi ko preserve karte hain — reconnect hi apne aap
      // "unlocked" nahi bana deta.
      //
      // **Honest gap**: OS-level real lock/sleep detection (Android
      // KeyguardManager, Windows session-lock APIs, waghera) abhi
      // implement nahi hui — yeh native platform code ka kaam hai jo
      // is round mein nahi likha gaya. `agent_connected` field (GET
      // /devices/{id}/status) is optimistic default se **independent**
      // hai — woh hamesha sach batata hai ke WS abhi connected hai ya
      // nahi, chahe `state` ka guess kuch bhi ho.
      if (device.state == 'OFFLINE' || device.state == 'POWERED_OFF') {
        device.state = 'ONLINE_UNLOCKED';
      }
      device.lastSeenAt = DateTime.now().toUtc();
      state.persist();
    }

    webSocket.stream.listen(
      (raw) {
        try {
          // Binary screen frame (base64 + JSON ka overhead hata diya):
          // [0x01][idLen][sessionId utf8][JPEG bytes]
          if (raw is List<int>) {
            handleAgentBinaryFrame(state, deviceId, raw);
            return;
          }
          if (raw is! String || raw.length > maxAgentMessageChars) return;
          final msg = jsonDecode(raw) as Map<String, dynamic>;
          handleAgentMessage(state, deviceId, msg);
        } catch (_) {
          // Malformed frame — ignore, connection zinda rakhte hain.
        }
      },
      onDone: () {
        // Sirf apni hi entry hatao — agar isi beech ek naya connection
        // replace kar chuka hai (upar wala close), to uska reference mat
        // udao (warna abhi-abhi bani nayi connection galti se "offline"
        // dikh jaati).
        if (identical(state.deviceConnections[deviceId], webSocket)) {
          state.deviceConnections.remove(deviceId);
          if (device != null) {
            device.state = 'OFFLINE';
            state.persist();
          }
        }
      },
      onError: (_) {
        if (identical(state.deviceConnections[deviceId], webSocket)) {
          state.deviceConnections.remove(deviceId);
          if (device != null) {
            device.state = 'OFFLINE';
            state.persist();
          }
        }
      },
    );
  }, pingInterval: _wsPingInterval);
}

/// Device se aaye ek decoded message ko process karta hai.
///
/// Items 6/7 — **ownership enforcement**: device sirf *apni* sessions
/// ke liye `event`/`screen_frame` bhej sakta hai, aur sirf *apne ko
/// bheje gaye* commands ka `command_result` complete kar sakta hai.
/// Pehle koi bhi paired device kisi bhi session mein fake events/frames
/// inject kar sakta tha ya dusre device ka pending command complete kar
/// sakta tha. (Public hai taaki unit tests seedha call kar sakein.)
void handleAgentMessage(AppState state, String deviceId, Map<String, dynamic> msg) {
  // Device->server messages 'kind' se multiplex hote hain — 'type' key
  // andar wale event object ke liye reserved hai (task_progress/
  // switch_event ka apna 'type' field), taaki dono clash na karein.
  final kind = msg['kind'] as String?;
  switch (kind) {
    case 'command_result':
      final requestId = msg['request_id'] as String?;
      final completer = requestId != null ? state.pendingCommands[requestId] : null;
      if (requestId != null && state.pendingCommandDevice[requestId] != deviceId) {
        break; // yeh command is device ko bheja hi nahi gaya tha
      }
      if (completer != null && !completer.isCompleted) {
        completer.complete((msg['result'] as Map<String, dynamic>?) ?? {});
      }
      break;

    case 'event':
      // task_progress / switch_event — jis session ke liye hai, uske
      // listeners ko forward. 'kind' aur 'session_id' hata dete hain,
      // baaki poora object (jisme apna 'type': 'task_progress' hai)
      // wahi shape hai jo DeviceAgentEvent.fromJson expect karta hai.
      final sessionId = msg['session_id'] as String?;
      if (sessionId != null && state.sessionOwner(sessionId) == deviceId) {
        final event = Map<String, dynamic>.from(msg)
          ..remove('session_id')
          ..remove('kind');

        // Audit fix (Section 8 / Section 13 #2) — real checkpoint
        // reporting. Har `task_progress` step (device ka har
        // successfully-completed action) server ke `TaskRecord.
        // lastCheckpoint` ko refresh karta hai — pehle yeh field kabhi
        // set hi nahi hota tha (sirf declare hua tha). Shape
        // `_DeviceTaskState.toCheckpointJson()` (device) se match karta
        // hai jaan-bujh kar, taaki `control.resume` isi ko wapas
        // `params.server_checkpoint` ki tarah forward kar sake bina
        // kisi conversion ke.
        if (event['type'] == 'task_progress') {
          final step = event['step'];
          if (step is int) {
            final task = state.tasks[sessionId];
            if (task != null) {
              task.recordCheckpoint({
                'completed_steps': step,
                if (event['action'] != null) 'last_action': event['action'],
              });
            }
          }
        }

        // Device khud task ka natija report kare (completed/failed) — sirf owning
        // device (upar check), sirf RUNNING/PAUSED task se; terminal par ignore.
        if (event['type'] == 'task_result') {
          final task = state.tasks[sessionId];
          final wanted = event['state'];
          if (task != null && (wanted == 'completed' || wanted == 'failed')) {
            final before = task.state;
            task.applyAction(wanted == 'completed' ? 'control.complete' : 'control.fail');
            if (task.state != before) {
              final reason = event['reason'];
              if (wanted == 'failed' && reason is String && reason.isNotEmpty) {
                task.terminalReason =
                    reason.length > 500 ? reason.substring(0, 500) : reason;
              }
              state.broadcastTaskState(task);
              state.persist();
            }
          }
        }

        state.broadcastToSession(sessionId, event);
      }
      break;

    case 'screen_frame':
      final sessionId = msg['session_id'] as String?;
      final data = msg['data'];
      if (sessionId != null &&
          data is String &&
          data.length <= maxAgentMessageChars &&
          state.sessionOwner(sessionId) == deviceId &&
          state.allowScreenFrame(sessionId)) {
        state.broadcastToScreen(sessionId, data);
      }
      break;

    case 'heartbeat':
      final device = state.devices[deviceId];
      if (device != null) device.lastSeenAt = DateTime.now().toUtc();
      break;

    // P1-05 — device apni asal (native-reported) lock/sleep/screen state
    // batata hai. Jab bhi yeh message aata hai, server ka optimistic
    // connect-time default (upar `deviceAgentHandler`) overwrite ho
    // jaata hai real data se.
    case 'status_update':
      final device = state.devices[deviceId];
      if (device == null) break;
      final newState = msg['state'] as String?;
      if (newState != null && _validDeviceStates.contains(newState)) {
        device.state = newState;
      }
      final battery = msg['battery_percent'];
      if (battery is int && battery >= 0 && battery <= 100) {
        device.batteryPercent = battery;
      }
      // Item 52: background agent sach mein chal raha hai ya nahi.
      final bg = msg['background_active'];
      if (bg is bool) device.backgroundActive = bg;
      // Item 32: location/network ab status_update ke saath bhi aate hain.
      final loc = msg['location'];
      if (loc is Map<String, dynamic>) {
        final clean = sanitizeLocation(loc);
        if (clean != null) device.lastLocation = clean;
      }
      final net = msg['network'];
      if (net is Map<String, dynamic>) {
        final clean = sanitizeNetwork(net);
        if (clean != null) device.lastNetwork = clean;
      }
      device.lastSeenAt = DateTime.now().toUtc();
      state.persist();
      break;
  }
}

const _validDeviceStates = {
  'ONLINE_UNLOCKED',
  'ONLINE_LOCKED',
  'SCREEN_OFF',
  'SLEEPING',
  'OFFLINE',
  'POWERED_OFF',
};
