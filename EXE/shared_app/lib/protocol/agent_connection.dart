/// Device-side Agent Connection — Control API se persistent WebSocket
/// (`WS /devices/{id}/agent`). Yeh file poore system ka woh missing loop
/// band karti hai jo pehle nahi tha: "command server se aata hai ->
/// device par actually execute hota hai -> result wapas jaata hai".
///
/// `api_client.dart` sirf **bhejne** wala client tha (commands POST
/// karna); yeh file **sunne** wala side hai — background mein chalti hai
/// aur incoming commands ko already-bani capability bridges
/// (`platform_channel_bridge.dart`) tak route karti hai.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import '../browser/cdp_client.dart';
import '../platform_channels/platform_channel_bridge.dart';
import 'command_envelope.dart';
import 'api_key.dart';
import 'device_policy.dart';
import 'websocket_client.dart' show reconnectDelay;

/// P0-01 — device-local task state. Server (`control_api`) ke TaskRecord
/// ka mirror hai, lekin authoritative nahi — server hi source-of-truth
/// hai (`/commands` route invalid transitions ko device tak forward hi
/// nahi karta). Yeh sirf device-side execution ko gate karne ke liye hai:
/// "PAUSED task ke liye koi nayi action dispatch na ho" ka asal
/// enforcement yahi hota hai, kyunki device hi actual native call
/// (tap/swipe/screen etc.) karta hai.
enum _TaskLocalStatus { running, paused, stopped }

class _DeviceTaskState {
  _TaskLocalStatus status;
  int completedSteps;
  String? lastAction;

  _DeviceTaskState({this.status = _TaskLocalStatus.running, this.completedSteps = 0});

  Map<String, dynamic> toCheckpointJson() =>
      {'completed_steps': completedSteps, if (lastAction != null) 'last_action': lastAction};
}

/// P1-06 — jab koi capability genuinely device par implement hi nahi hai
/// (jaise abhi notifications/messaging — Android NotificationListenerService
/// jaisi native OS-level integration chahiye jo is round mein nahi bani).
/// Generic `UnimplementedError` ki jagah yeh throw karte hain taaki
/// caller ko ek structured, deterministic error mile — "no fake success":
/// koi bhi caller/AI kabhi confuse na ho ke shayad kaam kar gaya ho.
class CapabilityUnavailableException implements Exception {
  final String action;
  final String reason;
  CapabilityUnavailableException(this.action, this.reason);
  @override
  String toString() => 'CAPABILITY_UNAVAILABLE: "$action" — $reason';
}

/// Dispatch us waqt reject hui jab task PAUSED tha — real "no new actions
/// dispatch" enforcement (TASK-01).
class TaskPausedException implements Exception {
  final String taskId;
  TaskPausedException(this.taskId);
  @override
  String toString() => 'TASK_PAUSED: task "$taskId" paused hai, nayi action dispatch nahi hogi';
}

/// Dispatch us waqt reject hui jab task STOPPED tha — task khatam ho
/// chuka, koi aur action allowed nahi (TASK-03).
class TaskStoppedException implements Exception {
  final String taskId;
  TaskStoppedException(this.taskId);
  @override
  String toString() => 'TASK_STOPPED: task "$taskId" stop ho chuka hai';
}

/// Item 53: server ke deliberate close codes (control_api) —
///  4000 replaced by a newer connection of the same device,
///  4001 device unpaired, 4002 token rotated.
/// Inpar reconnect nahi karte (4000 par reconnect karne se do instances
/// ek doosre ko baar-baar kick karte — ping-pong).
String? fatalReasonForCloseCode(int? code) {
  switch (code) {
    case 4000:
      return 'replaced';
    case 4001:
      return 'unpaired';
    case 4002:
      return 'token_rotated';
    default:
      return null; // 4003 (heartbeat timeout), 1006 etc. => normal reconnect
  }
}

/// Item 53: connect error 401/403 (galat/expired token) hai ya nahi.
/// dart:io ka exception message Dart version ke hisaab se alag hota hai,
/// isliye text mein status code dhoondhte hain.
bool isAuthFailure(Object error) {
  if (error is! WebSocketException) return false;
  final m = error.message;
  return m.contains('401') || m.contains('403');
}

/// Live stream default (pehle 6 fps; Stage 9: smooth live view ke liye 20) aur hard cap 30.
const liveStreamMaxFps = 20;
const liveStreamHardMaxFps = 30;

/// `quality` preset -> (native max width px, JPEG quality).
const liveStreamQualityPresets = <String, (int, int)>{
  'low': (540, 45),
  'medium': (720, 60),
  'high': (1080, 70),
  'ultra': (1440, 82),
};

/// Item 57: simple frame throttle — `maxFps` se tez aane wale frames drop.
class FrameThrottle {
  final Duration _minInterval;
  DateTime? _last;

  FrameThrottle({required int maxFps})
      : _minInterval = Duration(microseconds: (1000000 / maxFps).floor());

  bool shouldSend(DateTime now) {
    final last = _last;
    if (last != null && now.difference(last) < _minInterval) return false;
    _last = now;
    return true;
  }
}

class AgentConnection {
  final Uri wsBaseUrl;
  final String deviceId;
  final String bearerToken;

  WebSocket? _socket;
  Timer? _heartbeatTimer;
  final CommandDispatcher _dispatcher = CommandDispatcher();
  bool _shouldReconnect = true;

  // Item 53: reconnect state.
  Timer? _reconnectTimer;
  bool _connecting = false;
  int _attempt = 0;

  /// Item 53: server ne connection **jaan-bujh kar** band ki (replaced /
  /// unpaired / token rotated) ya auth fail hui — dobara connect karna
  /// bekaar (ya ping-pong) hai, isliye reconnect ruk jata hai aur
  /// caller ko yahan se batate hain (reason: `replaced`, `unpaired`,
  /// `token_rotated`, `auth`).
  void Function(String reason)? onFatalClose;

  /// Item 60: socket band hone par aaye `status_update`s ka merged latest
  /// copy — reconnect par flush hota hai.
  Map<String, dynamic>? _pendingStatus;

  AgentConnection({
    required this.wsBaseUrl,
    required this.deviceId,
    required this.bearerToken,
    this.localPolicy,
    this.onConnected,
  });

  /// Item 29: setup wizard mein user ne jo permissions chuni, woh is
  /// device ka **local ceiling** hai — server se koi bhi command aaye,
  /// policy mein jo capability allowed nahi use yahan device par hi
  /// reject kar diya jata hai (defence-in-depth, server ki scope check
  /// ke upar). `null` = koi local restriction nahi. Mutable taaki
  /// Permission Center se badal sake.
  ApiKeyScope? localPolicy;

  /// Item 33: har successful (re)connect ke baad call hota hai — caller
  /// yahan se poora status (lock state, battery, network, location)
  /// dobara bhejta hai, taaki server ko reconnect par stale/default state
  /// na maanni pade.
  Future<void> Function()? onConnected;

  Future<void> connect() async {
    _shouldReconnect = true;
    _attempt = 0;
    await _connectOnce();
  }

  /// Item 53: ek hi waqt mein ek hi connect attempt (`_connecting`), purane
  /// socket ke late callbacks naye socket ko nahi chhedte (identity
  /// check), reconnect ek hi timer se exponential backoff + jitter ke
  /// saath (pehle fixed 5s aur har failure par naya Timer = storm).
  Future<void> _connectOnce() async {
    if (_connecting || !_shouldReconnect) return;
    _connecting = true;
    try {
      // P0-03 — defense-in-depth: agar caller galti se http(s) base URL
      // pass kar de, yahan normalize kar dete hain (dart:io ka
      // `WebSocket.connect` sirf ws/wss scheme accept karta hai).
      final normalizedBase = (wsBaseUrl.scheme == 'ws' || wsBaseUrl.scheme == 'wss')
          ? wsBaseUrl
          : wsBaseUrl.replace(scheme: wsBaseUrl.scheme == 'https' ? 'wss' : 'ws');
      final uri = normalizedBase.replace(path: '${normalizedBase.path}/devices/$deviceId/agent');

      final WebSocket socket;
      try {
        socket = await WebSocket.connect(
          uri.toString(),
          headers: {'Authorization': 'Bearer $bearerToken'},
        );
      } catch (e) {
        if (isAuthFailure(e)) {
          _stopForever('auth');
          return;
        }
        _scheduleReconnect();
        return;
      }

      if (!_shouldReconnect) {
        // connect() ke dauran disconnect() ho gaya.
        unawaited(socket.close());
        return;
      }

      _socket = socket;
      _attempt = 0;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        _send({'kind': 'heartbeat'});
      });

      socket.listen(
        _handleRaw,
        onDone: () => _handleDisconnect(socket),
        onError: (_) => _handleDisconnect(socket),
        cancelOnError: true,
      );

      // Item 60: disconnect ke dauran jama hua status pehle bhejo.
      final pending = _pendingStatus;
      if (pending != null) {
        _pendingStatus = null;
        _send(pending);
      }

      final cb = onConnected;
      if (cb != null) {
        // Callback fail ho to connection nahi girna chahiye.
        unawaited(cb().catchError((_) {}));
      }
    } finally {
      _connecting = false;
    }
  }

  void _handleDisconnect(WebSocket socket) {
    // Purane/replaced socket ka late callback — ignore.
    if (!identical(_socket, socket)) return;
    _heartbeatTimer?.cancel();
    _socket = null;
    final fatal = fatalReasonForCloseCode(socket.closeCode);
    if (fatal != null) {
      _stopForever(fatal);
      return;
    }
    if (_shouldReconnect) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay(_attempt++), () {
      unawaited(_connectOnce());
    });
  }

  void _stopForever(String reason) {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    final cb = onFatalClose;
    if (cb != null) cb(reason);
  }

  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    unawaited(_cancelLiveStream(stopNative: false));
    _socket?.close();
    _socket = null;
    // Fix ke saath aaya cleanup — `_desktopCdp` (agar khula hai) ko bhi
    // band karte hain, warna WebSocket connection process lifetime tak
    // khuli reh jaati (poora agent disconnect ho jaaye tab bhi).
    _dispatcher._desktopCdp?.close();
  }

  /// Device khud task ka natija report kare (pehle sirf API caller ke
  /// `control.complete/fail` ya server ke stale sweeper se task khatam hota tha).
  /// Server sirf RUNNING/PAUSED task par, sirf owning device se maanta hai.
  void reportTaskResult(String sessionId, {required bool success, String? reason}) {
    _send({
      'kind': 'event',
      'type': 'task_result',
      'session_id': sessionId,
      'state': success ? 'completed' : 'failed',
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  /// Binary frame: `[type][idLen][sessionId utf8][payload]` — base64/JSON
  /// overhead nahi. `type` 0x01 = screen (JPEG), 0x02 = audio (PCM16).
  /// Server `handleAgentBinaryFrame` dono ko isi tarah parse/forward karta hai.
  void _sendBinaryFrame(String sessionId, List<int> payload, {int type = 0x01}) {
    final id = utf8.encode(sessionId);
    if (id.isEmpty || id.length > 255) return;
    final out = Uint8List(2 + id.length + payload.length);
    out[0] = type;
    out[1] = id.length;
    out.setRange(2, 2 + id.length, id);
    out.setRange(2 + id.length, out.length, payload);
    _socket?.add(out);
  }

  void _send(Map<String, dynamic> message) {
    _socket?.add(jsonEncode(message));
  }

  /// P1-05 — device ki real (native-reported) lock/sleep/screen state
  /// server ko batata hai (`status_update` message —
  /// `control_api/lib/websocket/handlers.dart` isko handle karta hai).
  ///
  /// **Honest gap**: is round mein koi native platform-channel bridge
  /// nahi likha gaya jo actual OS lock-state detect kare (Android
  /// `KeyguardManager`, Windows session-lock APIs, waghera) — woh native
  /// Kotlin/C++ code hai. Yeh method sirf **pipe** hai — jab bhi woh
  /// native detection ban jaye, bas yahan se call karna hai, poora
  /// server-side handling (state update, activity log, gating) already
  /// ready hai. Is liye yeh method abhi is file mein kahin se automatically
  /// call nahi hota — fake/guessed state bhejna se behtar hai kuch na
  /// bhejna (server apna khud ka honest optimistic default rakhta hai
  /// jab tak asal data na aaye).
  ///
  /// `state` in mein se ek honi chahiye: `ONLINE_UNLOCKED`,
  /// `ONLINE_LOCKED`, `SCREEN_OFF`, `SLEEPING`, `OFFLINE`, `POWERED_OFF`.
  void reportStatus({
    String? state,
    int? batteryPercent,
    bool? backgroundActive,
    Map<String, dynamic>? network,
    Map<String, dynamic>? location,
  }) {
    final msg = <String, dynamic>{
      'kind': 'status_update',
      if (state != null) 'state': state,
      if (batteryPercent != null) 'battery_percent': batteryPercent,
      if (backgroundActive != null) 'background_active': backgroundActive,
      if (network != null) 'network': network,
      if (location != null) 'location': location,
    };
    if (_socket == null) {
      // Item 60: pehle yeh chup-chaap drop ho jata tha. Ab latest values
      // merge hokar reconnect par bheji jaati hain.
      _pendingStatus = {...?_pendingStatus, ...msg};
      return;
    }
    _send(msg);
  }

  /// Item 54: binary/non-string frame ya koi bhi andar ka error connection
  /// ya isolate ko nahi girata.
  void _handleRaw(dynamic raw) {
    if (raw is! String) return; // binary frame — ignore
    unawaited(_onMessage(raw).catchError((Object _) {}));
  }

  Future<void> _onMessage(String raw) async {
    final Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return;
    }

    // Item 56: server se task state change (complete/fail/stop...).
    if (msg['kind'] == 'task_state') {
      await _applyServerTaskState(msg);
      return;
    }
    // Server: is session ka koi screen viewer nahi bacha => capture band
    // (battery/bandwidth/privacy — pehle bina viewer ke bhi chalta rehta tha).
    if (msg['kind'] == 'screen_idle') {
      final sid = msg['session_id'];
      if (sid is String && sid == _liveStreamSessionId) {
        await _cancelLiveStream();
      }
      if (sid is String && sid == _audioStreamSessionId) {
        await _cancelAudioStream();
      }
      return;
    }
    if (msg['kind'] != 'command') return;

    final requestId = msg['request_id'];
    try {
      await _processCommand(msg);
    } catch (e) {
      // Item 54: koi bhi unexpected error (bad envelope, cast failure,
      // ...) — server ko result bhejo taaki woh poore timeout tak na
      // ruke.
      if (requestId is String) {
        _send({
          'kind': 'command_result',
          'request_id': requestId,
          'result': {'error_code': 'INVALID_COMMAND', 'message': e.toString()},
        });
      }
    }
  }

  /// Item 56: server-side terminal/pause state device par bhi apply karo
  /// aur us session ki live stream band karo (privacy, battery, bandwidth).
  Future<void> _applyServerTaskState(Map<String, dynamic> msg) async {
    final sessionId = msg['session_id'];
    final state = msg['state'];
    if (sessionId is! String || state is! String) return;
    _dispatcher.applyServerTaskState(sessionId, state);
    if (state != 'RUNNING' && _liveStreamSessionId == sessionId) {
      await _cancelLiveStream();
    }
  }

  Future<void> _processCommand(Map<String, dynamic> msg) async {
    final CommandEnvelope envelope;
    try {
      envelope = CommandEnvelope.fromJson(msg);
    } catch (e) {
      final rid = msg['request_id'];
      if (rid is String) {
        _send({
          'kind': 'command_result',
          'request_id': rid,
          'result': {'error_code': 'INVALID_COMMAND', 'message': 'Envelope parse nahi hua: $e'},
        });
      }
      return;
    }

    // Item 29: local policy ceiling. `control.*` aur `screen.stop_live`
    // hamesha allowed (rokna kabhi block nahi hona chahiye).
    final policy = localPolicy;
    if (policy != null &&
        envelope.action != 'screen.stop_live' &&
        !policy.allowsCapability(envelope.capability)) {
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {
          'error_code': 'POLICY_DENIED',
          'message': '"${envelope.capability}" is device ki local '
              'permission policy mein allowed nahi hai',
        },
      });
      return;
    }

    if (envelope.capability == 'screen' && envelope.action == 'screen.watch_live') {
      await _startLiveStream(envelope);
      return;
    }
    if (envelope.capability == 'audio' && envelope.action == 'audio.watch_live') {
      await _startAudioStream(envelope);
      return;
    }
    if (envelope.capability == 'audio' && envelope.action == 'audio.stop_live') {
      await _cancelAudioStream();
      _send({'kind': 'command_result', 'request_id': envelope.requestId, 'result': {}});
      return;
    }
    if (envelope.capability == 'screen' && envelope.action == 'screen.stop_live') {
      // Item 55: pehle try/catch nahi tha aur `_liveStreamSub` cancel nahi
      // hota tha (frames chalte rehte).
      try {
        await _cancelLiveStream(stopNative: false);
        await _dispatcher.dispatch(envelope); // native stopStream
        _send({'kind': 'command_result', 'request_id': envelope.requestId, 'result': {}});
      } catch (e) {
        _send({
          'kind': 'command_result',
          'request_id': envelope.requestId,
          'result': {'error': e.toString()},
        });
      }
      return;
    }

    final stopwatch = Stopwatch()..start();
    try {
      final result = await _dispatcher.dispatch(envelope);
      stopwatch.stop();

      // control.stop **aur control.pause** dono par, agar isi session ka
      // live-stream chal raha ho, usko bhi cancel karte hain (P1-03
      // acceptance: "Task complete/pause par auto-stop"). Stop ka case
      // pehle se tha (P0-01); pause missing tha — paused task ka screen
      // dekhte rehna bhi resource-waste hai jab koi naya action ho hi
      // nahi raha. Resume par live-stream **wapas apne aap shuru nahi**
      // hota (jaan-bujh kar) — user ko explicitly "Watch Live" dobara
      // dabana hoga, taaki koi surprise background stream na chale.
      if (envelope.capability == 'control' &&
          (envelope.action == 'control.stop' ||
              envelope.action == 'control.pause' ||
              envelope.action == 'control.complete' ||
              envelope.action == 'control.fail')) {
        final sessionId = envelope.params['session_id'] as String?;
        if (sessionId != null && _liveStreamSessionId == sessionId) {
          await _cancelLiveStream();
        }
        if (sessionId != null && _audioStreamSessionId == sessionId) {
          await _cancelAudioStream();
        }
      }

      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': result,
      });
      _sendTaskProgress(envelope, success: true, durationMs: stopwatch.elapsedMilliseconds);
    } on TaskPausedException catch (e) {
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {'error_code': 'TASK_PAUSED', 'message': e.toString()},
      });
      // Paused/stopped-gate rejections khud task_progress steps nahi
      // hain (koi action actually chali hi nahi) — is liye progress event
      // nahi bhejte, sirf command_result se caller ko pata chal jaata hai.
    } on TaskStoppedException catch (e) {
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {'error_code': 'TASK_STOPPED', 'message': e.toString()},
      });
    } on CapabilityUnavailableException catch (e) {
      // P1-06 — structured, deterministic "unavailable" — audit:
      // "Unsupported target => structured CAPABILITY_UNAVAILABLE... koi
      // fake success nahi." Generic exception-string se alag, taaki
      // caller programmatically detect kar sake ke yeh ek "feature nahi
      // hai" case hai, koi transient error nahi.
      stopwatch.stop();
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {'error_code': 'CAPABILITY_UNAVAILABLE', 'message': e.reason},
      });
      _sendTaskProgress(envelope,
          success: false,
          description: 'Not available: ${e.action}',
          durationMs: stopwatch.elapsedMilliseconds);
    } on PlatformException catch (e) {
      // P1-07 — native platform-channel code (location/network/screen/
      // contacts, waghera) jab ek coded error deta hai (jaise
      // "PERMISSION_DENIED", "LOCATION_DISABLED"), Flutter use apne aap
      // `PlatformException.code` mein map kar deta hai. Pehle yahan yeh
      // generic `catch (e)` mein gir jaata tha — `e.toString()` ek
      // un-structured, hard-to-parse string ban jaata (audit:
      // "Permission denied explicit; location disabled explicit" — jo
      // pehle explicit nahi tha). Ab uska `.code` seedha `error_code`
      // ban ke jaata hai — koi bhi caller/AI programmatically handle kar
      // sakta hai (retry karna hai, permission maangni hai, ya bas
      // "unavailable" dikhana hai).
      stopwatch.stop();
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {'error_code': e.code, 'message': e.message ?? 'Native error'},
      });
      _sendTaskProgress(envelope,
          success: false,
          description: 'Failed (${e.code}): ${envelope.action}',
          durationMs: stopwatch.elapsedMilliseconds);
    } catch (e) {
      stopwatch.stop();
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {'error': e.toString()},
      });
      _sendTaskProgress(envelope,
          success: false, description: e.toString(), durationMs: stopwatch.elapsedMilliseconds);
    }
  }

  StreamSubscription<dynamic>? _liveStreamSub;
  String? _liveStreamSessionId;
  StreamSubscription<dynamic>? _audioStreamSub;
  String? _audioStreamSessionId;

  Future<void> _startLiveStream(CommandEnvelope envelope) async {
    final sessionId = envelope.params['session_id'] as String? ?? envelope.requestId;

    // Paused/stopped task par naya live stream bhi shuru nahi hona
    // chahiye — same gate jo baaki actions par lagta hai.
    try {
      _dispatcher.checkTaskGate(sessionId);
    } on TaskPausedException catch (e) {
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {'error_code': 'TASK_PAUSED', 'message': e.toString()},
      });
      return;
    } on TaskStoppedException catch (e) {
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {'error_code': 'TASK_STOPPED', 'message': e.toString()},
      });
      return;
    }

    await _cancelLiveStream(stopNative: false);
    _liveStreamSessionId = sessionId;
    // Item 57: FPS cap — native side frames tezi se bhej sakta hai aur
    // slow network par woh WebSocket buffer mein jama hokar memory badhate
    // the. Throttle ke bina bhi har frame JPEG hota hai, isliye extra
    // frames drop karna safe hai.
    final fps = ((envelope.params['fps'] as num?)?.toInt() ?? liveStreamMaxFps)
        .clamp(1, liveStreamHardMaxFps);
    final preset = liveStreamQualityPresets[envelope.params['quality']] ??
        liveStreamQualityPresets['high']!;
    final throttle = FrameThrottle(maxFps: fps);
    // Pehla event (frame ya error) — taaki "started" jhootha na ho jab
    // native side ne permission/session na hone par error diya.
    final firstEvent = Completer<Object?>(); // null => frame aaya
    _liveStreamSub = _dispatcher.screenBridge
        .liveFrames(fps: fps, maxWidth: preset.$1, quality: preset.$2)
        .listen(
      (frame) {
        if (!firstEvent.isCompleted) firstEvent.complete(null);
        if (!throttle.shouldSend(DateTime.now())) return;
        if (frame is List<int>) {
          _sendBinaryFrame(sessionId, frame);
        } else {
          _send({'kind': 'screen_frame', 'session_id': sessionId, 'data': frame});
        }
      },
      // Item 58: stream error/done par resources saaf, crash nahi.
      onError: (Object e) {
        if (!firstEvent.isCompleted) firstEvent.complete(e);
        unawaited(_cancelLiveStream());
      },
      onDone: () {
        if (!firstEvent.isCompleted) firstEvent.complete('STREAM_ENDED');
        if (_liveStreamSessionId == sessionId) {
          _liveStreamSub = null;
          _liveStreamSessionId = null;
        }
      },
      cancelOnError: true,
    );
    final first = await firstEvent.future
        .timeout(const Duration(seconds: 4), onTimeout: () => 'NO_FRAME_YET');
    if (first != null && first != 'NO_FRAME_YET') {
      await _cancelLiveStream();
      final text = first.toString();
      final needsPermission = first is PlatformException
          ? first.code == 'PERMISSION_REQUIRED'
          : text.contains('PERMISSION_REQUIRED');
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {
          'error_code': needsPermission ? 'PERMISSION_REQUIRED' : 'STREAM_FAILED',
          'message': needsPermission
              ? 'Screen capture consent/session active nahi hai.'
              : 'Live stream shuru nahi hui: $text',
        },
      });
      return;
    }
    final size = await _dispatcher.screenBridge.screenSize();
    _send({
      'kind': 'command_result',
      'request_id': envelope.requestId,
      // Static screen par Android frame tab hi deta hai jab content badle,
      // isliye "abhi tak koi frame nahi" error nahi — saaf bata dete hain.
      'result': {
        'started': true,
        'first_frame_received': first == null,
        if (size != null) 'screen': {'width': size.width, 'height': size.height},
        'fps': fps,
        'quality': envelope.params['quality'] ?? 'high',
      },
    });
  }

  /// Live stream band karo (subscription cancel + optionally native
  /// `stopStream`). Multiple jagah se safely call ho sakta hai.
  Future<void> _cancelLiveStream({bool stopNative = true}) async {
    final sub = _liveStreamSub;
    _liveStreamSub = null;
    _liveStreamSessionId = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    if (stopNative && sub != null) {
      try {
        await _dispatcher.screenBridge.stopLiveStream();
      } catch (_) {}
    }
  }

  /// `audio.watch_live` — system audio (PCM16, 16kHz, mono) ka live stream.
  /// Screen stream se mostly independent chalta hai (ek viewer dono chaahe to
  /// `screen.watch_live` aur `audio.watch_live` dono bhejta hai — website
  /// isi tarah karti hai).
  Future<void> _startAudioStream(CommandEnvelope envelope) async {
    final sessionId = envelope.params['session_id'] as String? ?? envelope.requestId;
    try {
      _dispatcher.checkTaskGate(sessionId);
    } on TaskPausedException catch (e) {
      _send({'kind': 'command_result', 'request_id': envelope.requestId,
        'result': {'error_code': 'TASK_PAUSED', 'message': e.toString()}});
      return;
    } on TaskStoppedException catch (e) {
      _send({'kind': 'command_result', 'request_id': envelope.requestId,
        'result': {'error_code': 'TASK_STOPPED', 'message': e.toString()}});
      return;
    }

    await _cancelAudioStream();
    _audioStreamSessionId = sessionId;
    final firstEvent = Completer<Object?>();
    _audioStreamSub = _dispatcher.screenBridge.audioFrames().listen(
      (chunk) {
        if (!firstEvent.isCompleted) firstEvent.complete(null);
        if (chunk is List<int>) _sendBinaryFrame(sessionId, chunk, type: 0x02);
      },
      onError: (Object e) {
        if (!firstEvent.isCompleted) firstEvent.complete(e);
        unawaited(_cancelAudioStream());
      },
      onDone: () {
        if (!firstEvent.isCompleted) firstEvent.complete('STREAM_ENDED');
        if (_audioStreamSessionId == sessionId) {
          _audioStreamSub = null;
          _audioStreamSessionId = null;
        }
      },
      cancelOnError: true,
    );
    final first = await firstEvent.future
        .timeout(const Duration(seconds: 4), onTimeout: () => 'NO_FRAME_YET');
    if (first != null && first != 'NO_FRAME_YET') {
      await _cancelAudioStream();
      final text = first.toString();
      final unsupported = first is PlatformException
          ? first.code == 'CAPABILITY_UNAVAILABLE'
          : text.contains('CAPABILITY_UNAVAILABLE');
      final needsPermission = first is PlatformException
          ? first.code == 'PERMISSION_REQUIRED'
          : text.contains('PERMISSION_REQUIRED');
      _send({
        'kind': 'command_result',
        'request_id': envelope.requestId,
        'result': {
          'error_code': unsupported
              ? 'CAPABILITY_UNAVAILABLE'
              : (needsPermission ? 'PERMISSION_REQUIRED' : 'STREAM_FAILED'),
          'message': unsupported
              ? 'System-audio streaming is platform par abhi supported nahi (sirf Android 10+).'
              : (needsPermission
                  ? 'Screen capture consent/session active nahi hai (audio bhi usi se chalta hai).'
                  : 'Audio stream shuru nahi hui: $text'),
        },
      });
      return;
    }
    _send({
      'kind': 'command_result',
      'request_id': envelope.requestId,
      'result': {
        'started': true,
        'sample_rate': 16000,
        'channels': 1,
        'format': 'pcm_s16le',
      },
    });
  }

  Future<void> _cancelAudioStream() async {
    final sub = _audioStreamSub;
    _audioStreamSub = null;
    _audioStreamSessionId = null;
    try {
      await sub?.cancel();
    } catch (_) {}
  }

  /// P1-04 — Task Progress Event Quality + Safe Metadata.
  ///
  /// Pehle yahan `'step': 0` **hardcoded** tha (kabhi increment hi nahi
  /// hota tha — koi bhi step number 0 hi bhejta, timeline reconstruct
  /// karna namumkin tha) aur `description` success par sirf action ka
  /// naam thi (jaise "input.tap" — kuch bhi useful nahi batata). Duration
  /// bilkul nahi thi.
  ///
  /// Ab:
  ///   - `step` — real, per-task incrementing counter (P0-01 ke
  ///     `_DeviceTaskState.completedSteps` se — wahi checkpoint jo
  ///     `control.resume` bhi use karta hai, single source of truth).
  ///   - `duration_ms` — dispatch mein laga waqt.
  ///   - `description` — safe, params-aware (coordinates, file paths,
  ///     URLs — **kabhi bhi typed text ya clipboard content nahi**,
  ///     sirf metadata jo timeline reconstruct karne ke liye kaafi hai
  ///     bina kisi sensitive payload ke — audit: "Never put message/file
  ///     contents into normal task logs").
  void _sendTaskProgress(CommandEnvelope envelope,
      {required bool success, String? description, int durationMs = 0}) {
    final sessionId = envelope.params['session_id'] as String?;
    if (sessionId == null) return; // sirf session-scoped commands ke liye
    final step = _dispatcher.currentStepFor(sessionId);
    _send({
      'kind': 'event',
      'session_id': sessionId,
      'protocol_version': CommandEnvelope.currentProtocolVersion,
      // Yahan se aage — jo bhi fields hain, yeh hubahu woh shape hai jo
      // Dart client's TaskProgressEvent.fromJson (event_envelope.dart)
      // expect karta hai. "type" yahan is *inner* event ka type hai
      // ("task_progress"), server ke WS-multiplexing "kind" se alag —
      // dono ko overload karna hi woh bug tha jo shuru mein tha.
      'type': 'task_progress',
      'step': step,
      'action': envelope.action,
      'description': description ?? describeActionSafely(envelope, success: success),
      'result': success ? 'success' : 'fail',
      'duration_ms': durationMs,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// P1-04 — safe, params-aware description. **Kabhi bhi typed text,
  /// clipboard content, ya message content nahi deta** — sirf metadata
  /// jo user ke actual data ko expose kiye bina timeline useful banata
  /// hai (coordinates, file paths, URLs, field labels — yeh sab already
  /// "kahan/kya action" batate hain, "kya data" nahi).
  ///
  /// Top-level function hai (class method nahi) taaki tests seedha isko
  /// call kar sakein bina poori `AgentConnection`/WebSocket setup kiye.
}

String describeActionSafely(CommandEnvelope envelope, {required bool success}) {
  if (!success) return 'Failed: ${envelope.action}';
  final p = envelope.params;
  switch (envelope.action) {
    case 'screen.capture':
      return 'Captured a screenshot';
    case 'screen.watch_live':
      return 'Started live screen stream';
    case 'screen.stop_live':
      return 'Stopped live screen stream';
    case 'audio.watch_live':
      return 'Started live audio stream';
    case 'audio.stop_live':
      return 'Stopped live audio stream';
    case 'input.tap':
      return 'Tapped at (${p['x']}, ${p['y']})';
    case 'input.swipe':
      return 'Swiped from (${p['x1']}, ${p['y1']}) to (${p['x2']}, ${p['y2']})';
    case 'input.key':
      return 'Pressed ${p['key']} key';
    case 'input.type_text':
      // Kabhi actual text nahi — sirf length (kitna type hua, kya nahi).
      final len = (p['text'] as String?)?.length;
      return len != null ? 'Typed $len character(s)' : 'Typed text';
    case 'files.list':
      return 'Listed files at ${p['path']}';
    case 'files.read':
      return 'Read file at ${p['path'] ?? p['target_path']}';
    case 'files.write':
      return 'Wrote file at ${p['path'] ?? p['target_path']}';
    case 'files.delete':
      return 'Deleted file at ${p['path']}';
    case 'app_launcher.launch':
      return 'Launched app: ${p['identifier']}';
    case 'app_launcher.list':
      return 'Listed installed apps';
    case 'browser.navigate':
      return 'Navigated to ${p['url']}';
    case 'browser.click':
      return 'Clicked element: ${p['text']}';
    case 'browser.type_text':
      return 'Typed into field: ${p['field_label']}'; // field label hai, typed VALUE nahi
    case 'browser.read':
      return 'Read browser page content';
    case 'clipboard.read':
      return 'Read clipboard'; // content kabhi nahi
    case 'clipboard.write':
      return 'Wrote to clipboard'; // content kabhi nahi
    case 'data.upload':
      return 'Uploaded file to ${p['path'] ?? p['target_path']}';
    case 'data.download':
      return 'Downloaded file from ${p['path'] ?? p['target_path']}';
    case 'contacts.list':
      return 'Listed contacts'; // names/numbers kabhi nahi
    case 'control.pause':
      return 'Paused task';
    case 'control.resume':
      return 'Resumed task';
    case 'control.stop':
      return 'Stopped task';
    case 'control.switch':
      return 'Switched session mode';
    case 'location.refresh':
      return 'Refreshed location';
    case 'background.keepalive':
      return 'Background keepalive';
    default:
      return 'Performed ${envelope.action}';
  }
}

/// Ek `CommandEnvelope` ko actual native call mein convert karta hai —
/// already-bani `platform_channel_bridge.dart` ki classes use karte
/// hue. Yeh dispatcher hi hai jo "protocol" ko "asal device action" se
/// jodta hai.
class CommandDispatcher {
  final screenBridge = ScreenCaptureBridge();
  final inputBridge = InputBridge();
  final filesBridge = FilesBridge();
  final appLauncherBridge = AppLauncherBridge();
  final clipboardBridge = ClipboardBridge();
  final browserBridge = BrowserBridge();
  final locationNetworkBridge = LocationNetworkBridge();
  final contactsBridge = ContactsBridge();
  final notificationsBridge = NotificationsBridge();

  /// Fix — Windows/Linux ke liye. Session-scoped rakhte hain (naya
  /// connect() sirf tab jab pehli baar chahiye ho, ya purana connection
  /// mar chuka ho) — CDP ek stateful WebSocket hai, har command par
  /// dobara connect karna (a) slow hai aur (b) galat bhi, kyunki tab/page
  /// context reconnect karne se reset ho jaata.
  CdpClient? _desktopCdp;

  Future<CdpClient>? _cdpConnecting;

  /// Items 77/78: cached client tabhi reuse hota hai jab uska socket zinda
  /// ho (pehle browser band hone par `_desktopCdp` hamesha ke liye stale
  /// rehta tha). Concurrent calls ek hi connect/launch share karti hain
  /// (pehle har call apna Chrome launch kar deti thi), aur browser ready
  /// hone tak poll hota hai.
  Future<CdpClient> _ensureDesktopBrowser() {
    final existing = _desktopCdp;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    _desktopCdp = null;
    return _cdpConnecting ??= _connectDesktopBrowser().whenComplete(() {
      _cdpConnecting = null;
    });
  }

  Future<CdpClient> _connectDesktopBrowser() async {
    // Pehle bina launch kiye try karo (browser pehle se debug port par ho).
    CdpClient? client;
    try {
      client = await CdpClient.connect(BrowserBridge.desktopDebugPort);
    } catch (_) {
      // `launchDesktopBrowser()` best-effort hai. **Honest caveat**: agar
      // browser already BINA debug-port ke chal raha ho, Chrome/Edge us
      // running instance ko naya `--remote-debugging-port` flag nahi
      // deta — user ko browser band karke dobara try karna hoga.
      await browserBridge.launchDesktopBrowser();
      client = await CdpClient.connectWhenReady(BrowserBridge.desktopDebugPort);
    }
    _desktopCdp = client;
    return client;
  }

  /// P0-01 — session_id (== server ka taskId) se local task state.
  final Map<String, _DeviceTaskState> _tasks = {};

  _DeviceTaskState _taskFor(String sessionId) =>
      _tasks.putIfAbsent(sessionId, () => _DeviceTaskState());

  /// P1-04 — `_sendTaskProgress` ke liye public read-only accessor. Yeh
  /// wahi checkpoint counter hai jo `control.resume` bhi return karta
  /// hai (`_DeviceTaskState.completedSteps`) — single source of truth,
  /// progress-event step numbering aur resume-checkpoint kabhi drift
  /// nahi karenge.
  int currentStepFor(String sessionId) => _taskFor(sessionId).completedSteps;

  /// Item 56: server ne task ka state badla (jaise `control.complete`/
  /// `control.fail` jo device tak command ke roop mein aati hi nahi).
  /// Terminal states device par `stopped` ban jaati hain taaki agla koi
  /// bhi command `checkTaskGate()` se reject ho; `PAUSED`/`RUNNING`
  /// seedhe map hote hain.
  void applyServerTaskState(String sessionId, String serverState) {
    switch (serverState) {
      case 'PAUSED':
        _taskFor(sessionId).status = _TaskLocalStatus.paused;
        break;
      case 'RUNNING':
        _taskFor(sessionId).status = _TaskLocalStatus.running;
        break;
      case 'STOPPED':
      case 'COMPLETED':
      case 'FAILED':
        _taskFor(sessionId).status = _TaskLocalStatus.stopped;
        break;
    }
  }

  /// Item 59: `_tasks` kabhi saaf nahi hota tha (har session ke liye ek
  /// entry hamesha). Ab `maxTrackedTasks` cross hone par sabse purane
  /// **stopped** entries hat jaate hain (running/paused kabhi nahi).
  /// Dart ka default Map insertion-ordered hai, isliye "pehle aaya =
  /// pehle gaya".
  static const maxTrackedTasks = 200;

  void _pruneTasks() {
    if (_tasks.length <= maxTrackedTasks) return;
    final removable = _tasks.entries
        .where((e) => e.value.status == _TaskLocalStatus.stopped)
        .map((e) => e.key)
        .toList();
    for (final key in removable) {
      if (_tasks.length <= maxTrackedTasks * 3 ~/ 4) break;
      _tasks.remove(key);
    }
  }

  /// Test/diagnostics ke liye.
  int get trackedTaskCount => _tasks.length;

  /// Kisi bhi session-scoped, non-control action se pehle call hota hai.
  /// PAUSED/STOPPED task par throw karta hai — yehi asal jagah hai jahan
  /// "PAUSED task par koi nayi action dispatch nahi" enforce hota hai,
  /// kyunki yahi wo layer hai jo actual native call karne se pehle aata
  /// hai.
  void checkTaskGate(String? sessionId) {
    if (sessionId == null) return; // session-scoped nahi — gate apply nahi hoti
    final task = _tasks[sessionId];
    if (task == null) return; // abhi tak koi task record nahi — pehli action hai
    if (task.status == _TaskLocalStatus.paused) {
      throw TaskPausedException(sessionId);
    }
    if (task.status == _TaskLocalStatus.stopped) {
      throw TaskStoppedException(sessionId);
    }
  }

  Future<Map<String, dynamic>> dispatch(CommandEnvelope envelope) async {
    final p = envelope.params;
    final sessionId = p['session_id'] as String?;

    // control.* apni khud ki state-machine logic switch-case ke andar
    // handle karta hai (neeche) — baaki sab session-scoped actions gate
    // se guzarte hain. `screen.stop_live` bhi exempt hai — yeh khud ek
    // cleanup/cancellation action hai, isko PAUSED/STOPPED task par bhi
    // chalne dena chahiye (warna stream kabhi band hi nahi ho payega).
    if (envelope.capability != 'control' && envelope.action != 'screen.stop_live') {
      checkTaskGate(sessionId);
    }

    final result = await _dispatchInner(envelope, p);
    _pruneTasks();

    // Kamyaab execution ke baad checkpoint (step count) aage badhao —
    // control.resume isi checkpoint se "continue" ka signal deta hai.
    if (sessionId != null && envelope.capability != 'control') {
      final task = _taskFor(sessionId);
      task.completedSteps += 1;
      task.lastAction = envelope.action;
    }
    return result;
  }

  Future<Map<String, dynamic>> _dispatchInner(
      CommandEnvelope envelope, Map<String, dynamic> p) async {
    switch (envelope.action) {
      // ---- screen ---------------------------------------------------------
      case 'screen.capture':
        final b64 = await screenBridge.captureScreenshot();
        return {'screenshot': b64};
      case 'screen.stop_live':
        await screenBridge.stopLiveStream();
        return {};
      case 'audio.stop_live':
        return {}; // AgentConnection socket layer _cancelAudioStream() se handle karta hai

      // ---- input ------------------------------------------------------------
      case 'input.tap':
        await inputBridge.tap((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
        return {};
      case 'input.swipe':
        await inputBridge.swipe(
          (p['x1'] as num).toDouble(),
          (p['y1'] as num).toDouble(),
          (p['x2'] as num).toDouble(),
          (p['y2'] as num).toDouble(),
          durationMs: (p['duration_ms'] as num?)?.toInt() ?? 200,
        );
        return {};
      case 'input.key':
        if (!Platform.isAndroid) {
          throw CapabilityUnavailableException(
              envelope.action, 'Back/Home/Recents keys sirf Android par supported hain.');
        }
        await inputBridge.pressKey(p['key'] as String? ?? '');
        return {};
      case 'input.type_text':
        await inputBridge.typeText(p['text'] as String? ?? '',
            append: p['append'] == true);
        return {};

      // ---- files --------------------------------------------------------------
      case 'files.list':
        final entries = await filesBridge.listDirectory(p['path'] as String? ?? '');
        return {'entries': entries};
      case 'files.read':
      case 'data.download':
        final data = await filesBridge.readFile(p['path'] as String? ?? p['target_path'] as String? ?? '');
        return {'data': data};
      case 'files.write':
      case 'data.upload':
        final writePath = p['path'] as String? ?? p['target_path'] as String? ?? '';
        // Item 14: device-side defence-in-depth (server par bhi check hai).
        if (isDangerousFilePath(writePath)) {
          throw ArgumentError(
              'Is file type ko write karna security policy se blocked hai');
        }
        final ok = await filesBridge.writeFile(
          writePath,
          envelope.payload ?? '',
        );
        return {'success': ok};
      case 'files.delete':
        final ok = await filesBridge.deleteFile(p['path'] as String? ?? '');
        return {'success': ok};

      // ---- app_launcher ---------------------------------------------------
      case 'app_launcher.launch':
        final appId = p['identifier'] as String?;
        if (!isPlausibleAppIdentifier(appId)) {
          throw ArgumentError('app identifier invalid hai');
        }
        final ok = await appLauncherBridge.launchApp(appId!);
        return {'success': ok};
      case 'app_launcher.list':
        final apps = await appLauncherBridge.listInstalledApps();
        return {'apps': apps};

      // ---- browser ------------------------------------------------------------
      // Fix — pehle yeh sirf Android (semantic-tree) path tha; Windows/
      // Linux par `browserBridge.*` calls `NotImplemented` return karte
      // (native side par koi handler nahi), aur is comment mein claim
      // kiya jaata tha ke "CdpClient apne flow mein use hota hai" — jo
      // sach nahi tha, `CdpClient` kahin instantiate hi nahi hota tha.
      // Ab platform ke hisaab se branch karte hain: Android par existing
      // accessibility path, Windows/Linux par `_ensureDesktopBrowser()`
      // se CDP session.
      case 'browser.navigate':
        // Item 13: device-side bhi sirf http/https (file://, intent:,
        // javascript: etc. block) — Android aur desktop dono.
        if (!isAllowedBrowserUrl(p['url'] as String?)) {
          throw ArgumentError('Sirf http/https URLs allowed hain');
        }
        if (Platform.isAndroid) {
          final ok = await browserBridge.openUrl(p['url'] as String? ?? '');
          return {'success': ok};
        }
        final cdp = await _ensureDesktopBrowser();
        await cdp.navigate(p['url'] as String? ?? '');
        return {'success': true};
      case 'browser.click':
        if (Platform.isAndroid) {
          final ok = await browserBridge.findAndClick(p['text'] as String? ?? '');
          return {'success': ok};
        }
        final cdp = await _ensureDesktopBrowser();
        final ok = await cdp.clickByText(p['text'] as String? ?? '');
        return {'success': ok};
      case 'browser.type_text':
        if (Platform.isAndroid) {
          final ok = await browserBridge.findAndType(
            p['field_label'] as String? ?? '',
            p['text'] as String? ?? '',
          );
          return {'success': ok};
        }
        final cdp = await _ensureDesktopBrowser();
        final ok = await cdp.typeByLabel(
          p['field_label'] as String? ?? '',
          p['text'] as String? ?? '',
        );
        return {'success': ok};
      case 'browser.read':
        if (Platform.isAndroid) {
          final text = await browserBridge.getVisibleText();
          return {'text': text};
        }
        final cdp = await _ensureDesktopBrowser();
        final text = await cdp.getVisibleText();
        return {'text': text};

      // ---- clipboard ----------------------------------------------------------
      case 'clipboard.read':
        final text = await clipboardBridge.readText();
        return {'text': text};
      case 'clipboard.write':
        final ok = await clipboardBridge.writeText(p['text'] as String? ?? '');
        return {'success': ok};

      // ---- contacts -----------------------------------------------------------
      case 'contacts.list':
        final contacts = await contactsBridge.listContacts();
        return {
          'contacts': contacts
              .map((c) => {
                    'id': c.id,
                    'name': c.name,
                    'phoneNumbers': c.phoneNumbers,
                    'emails': c.emails,
                  })
              .toList(),
        };

      // ---- location -----------------------------------------------------------
      case 'location.refresh':
        final loc = await locationNetworkBridge.getLocation();
        return {'location': loc};

      // ---- control --------------------------------------------------------
      case 'control.switch':
        // Task lifecycle se related nahi — session-level meta-event,
        // server hi (/sessions/{id}/switch) is se deal karta hai. Device
        // tak yeh route hi nahi hota is dispatcher se; agar kabhi ho bhi
        // to yahan sirf acknowledge.
        return {'acknowledged': true};

      // ---- control.pause/resume/stop — P0-01: real local state ------------
      // Server ne yeh command sirf tabhi forward ki hai jab uski apni
      // TaskRecord state machine ne transition ko valid maana ho — is
      // liye yahan hum blindly apply kar sakte hain (server ne pehle hi
      // fail-closed check kar liya). Device-side yeh state agle actions
      // ke liye `checkTaskGate()` ka source hai.
      case 'control.pause': {
        final sessionId = p['session_id'] as String?;
        if (sessionId == null) {
          throw ArgumentError('control.pause ke liye params.session_id required hai');
        }
        _taskFor(sessionId).status = _TaskLocalStatus.paused;
        return {'acknowledged': true, 'state': 'PAUSED'};
      }

      case 'control.resume': {
        final sessionId = p['session_id'] as String?;
        if (sessionId == null) {
          throw ArgumentError('control.resume ke liye params.session_id required hai');
        }
        final task = _taskFor(sessionId);
        task.status = _TaskLocalStatus.running;

        // Audit fix (Section 8) — agar server ne apna authoritative
        // checkpoint bheja hai (`params.server_checkpoint`, server ke
        // `TaskRecord.lastCheckpoint` se — `control_api/lib/routes/
        // commands.dart` mein set hota hai) aur woh device ke apne
        // in-memory checkpoint se AAGE hai, to usko adopt karte hain.
        // "Aage" ki condition zaroori hai: normal same-process
        // pause/resume mein device ka local checkpoint hi sabse fresh
        // hota hai (server ka thoda purana ho sakta hai agar abhi last
        // step ka event abhi tak deliver na hua ho) — sirf device
        // process restart jaisे case mein (local completedSteps == 0
        // hote hue bhi server ke paas pehle se progress hai) yeh
        // condition trigger hoti hai aur checkpoint wapas mil jaata hai,
        // warna kabhi galti se peeche nahi jaate.
        final serverCheckpoint = p['server_checkpoint'] as Map<String, dynamic>?;
        final serverSteps = serverCheckpoint?['completed_steps'] as int?;
        if (serverSteps != null && serverSteps > task.completedSteps) {
          task.completedSteps = serverSteps;
          task.lastAction = serverCheckpoint?['last_action'] as String? ?? task.lastAction;
        }

        return {
          'acknowledged': true,
          'state': 'RUNNING',
          // Checkpoint wapas bhejte hain — caller/AI orchestration isi se
          // "kahan se continue karna hai" decide kar sakta hai (audit
          // TASK-02: "resume => valid checkpoint se continue").
          'checkpoint': task.toCheckpointJson(),
        };
      }

      case 'control.stop': {
        final sessionId = p['session_id'] as String?;
        if (sessionId == null) {
          throw ArgumentError('control.stop ke liye params.session_id required hai');
        }
        _taskFor(sessionId).status = _TaskLocalStatus.stopped;
        // Live-stream cancellation `AgentConnection._onMessage` mein
        // hoti hai (is class ko WebSocket/stream ka access nahi hai) —
        // yahan sirf task state set karte hain taaki agli koi bhi action
        // `checkTaskGate()` se turant reject ho.
        return {'acknowledged': true, 'state': 'STOPPED'};
      }

      // ---- background (Section 9) ------------------------------------------
      case 'background.keepalive':
        return {'alive': true};
      case 'notifications.read_event':
        // Item 84: Android par asli implementation; baaki platforms par
        // honest unavailable.
        if (!Platform.isAndroid) {
          throw CapabilityUnavailableException(
              envelope.action, 'Notifications sirf Android par supported hain.');
        }
        if (!await notificationsBridge.isEnabled()) {
          throw CapabilityUnavailableException(
              envelope.action,
              'Notification access enable nahi hai — Permission Center se '
              '"Notification access" ON karein.');
        }
        final limit = ((p['limit'] as num?)?.toInt() ?? 20).clamp(1, 100);
        final since = (p['since_ms'] as num?)?.toInt() ?? 0;
        return {
          'notifications': await notificationsBridge.getRecent(limit: limit, sinceMs: since),
        };
      case 'messaging.get_event':
      case 'messaging.prepare_reply':
      case 'messaging.send_reply':
        // P1-06: provider-specific adapter — supported messaging apps ki
        // notification inline-reply ke zariye (MessagingStore.kt). Baaki
        // sab (desktop, unsupported app) honest CAPABILITY_UNAVAILABLE.
        if (!Platform.isAndroid) {
          throw CapabilityUnavailableException(envelope.action,
              'Messaging adapters sirf Android par supported hain.');
        }
        if (!await notificationsBridge.isEnabled()) {
          throw CapabilityUnavailableException(
              envelope.action,
              'Notification access enable nahi hai — Permission Center se '
              '"Notification access" ON karein.');
        }
        try {
          if (envelope.action == 'messaging.get_event') {
            final limit = ((p['limit'] as num?)?.toInt() ?? 20).clamp(1, 50);
            final since = (p['since_ms'] as num?)?.toInt() ?? 0;
            final pkg = p['package'];
            if (pkg != null && pkg is! String) {
              throw ArgumentError('"package" ek string honi chahiye');
            }
            return {
              'events': await notificationsBridge.getMessagingEvents(
                  limit: limit, sinceMs: since, package: pkg as String?),
            };
          }
          if (envelope.action == 'messaging.prepare_reply') {
            final eventId = p['event_id'];
            final text = p['text'];
            if (eventId is! String || eventId.isEmpty || text is! String) {
              throw ArgumentError('"event_id" aur "text" (strings) zaroori hain');
            }
            return await notificationsBridge.prepareReply(eventId, text);
          }
          final draftId = p['draft_id'];
          if (draftId is! String || draftId.isEmpty) {
            throw ArgumentError('"draft_id" (string) zaroori hai — pehle '
                'messaging.prepare_reply chalayein');
          }
          return await notificationsBridge.sendReply(draftId);
        } on PlatformException catch (e) {
          // Unsupported provider / no inline reply => structured unavailable
          // (audit: "Unsupported target => CAPABILITY_UNAVAILABLE").
          if (e.code == 'UNSUPPORTED_TARGET' || e.code == 'REPLY_UNSUPPORTED') {
            throw CapabilityUnavailableException(
                envelope.action, e.message ?? 'Is target par reply supported nahi.');
          }
          rethrow;
        }

      default:
        throw UnimplementedError('Unknown action: ${envelope.action}');
    }
  }
}
