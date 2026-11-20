import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/pairing_code_registry.dart';
import '../models/activity.dart';
import '../models/api_key.dart';
import '../models/device.dart';
import '../models/task.dart';
import '../util/crypto_utils.dart';
import '../util/versioned_map.dart';
import '../connectors/connector_models.dart';
import '../connectors/connector_provider.dart';
import '../connectors/credential_encryption.dart';

/// Poora server ka state — **single process**, ab persistent bhi hai
/// (`Persistence` class se, `lib/storage/persistence.dart`). Runtime
/// mein sab kuch memory mein hi rehta hai (fast reads), har mutation ke
/// baad disk par bhi save ho jaata hai — taaki restart survive ho sake.
/// Item 44: same `request_id` abhi bhi in-flight hai.
class DuplicateRequestException implements Exception {
  final String requestId;
  const DuplicateRequestException(this.requestId);
  @override
  String toString() => 'DuplicateRequestException: request_id "$requestId" abhi in-flight hai';
}

class AppState {
  final VersionedMap<Device> devices = VersionedMap<Device>();
  final VersionedMap<ApiKeyRecord> apiKeys =
      VersionedMap<ApiKeyRecord>(); // keyId -> record

  // Item 22: hash-indexed lookup. Index `secretHash -> id`; map badalne
  // par (version change) agle lookup par lazily rebuild hota hai.
  // SHA-256 hash par lookup hota hai, is liye Map ka timing attacker ko
  // secret ke baare mein kuch nahi batata; final match phir bhi
  // constant-time compare se verify hota hai.
  final Map<String, String> _deviceTokenIndex = {};
  int _deviceIndexVersion = -1;
  final Map<String, String> _apiKeyIndex = {};
  int _apiKeyIndexVersion = -1;
  final List<ActivityEvent> activityLog = [];

  /// Item 10: server-issued one-time pairing codes (memory-only).
  PairingCodeRegistry pairingCodes = PairingCodeRegistry();

  /// P1-01 — persistent, validated custom capability registrations
  /// (`POST /capabilities/register`). Pehle yeh ek route-local, non-
  /// persisted list thi — ab `AppState` ka hissa hai (baaki sab state
  /// ki tarah), is liye restart survive karti hai.
  final List<Map<String, dynamic>> customCapabilityManifests = [];

  /// `bin/server.dart` startup par set karta hai. Route handlers isi ke
  /// through `persist()` call karte hain har mutation ke baad.
  Future<void> Function()? onMutated;

  /// Route handlers isko har mutation (pairing, key create/update/delete,
  /// location update) ke baad call karte hain. `onMutated` na set ho
  /// (jaise tests mein) to chup-chaap no-op.
  Future<void> persist() async {
    if (onMutated != null) await onMutated!();
  }

  /// Device ka persistent agent connection — `WS /devices/{id}/agent`.
  /// Isi ke through commands device tak forward hote hain aur wahan se
  /// events/results wapas aate hain.
  final Map<String, WebSocketChannel> deviceConnections = {};

  /// `WS /sessions/{id}` — dashboard/AI Verifier clients jo task_progress/
  /// switch_event sunte hain. Ek session mein multiple listeners ho sakte
  /// hain.
  final Map<String, Set<WebSocketChannel>> sessionListeners = {};

  /// `WS /screen/{id}` — live frame listeners.
  final Map<String, Set<WebSocketChannel>> screenListeners = {};

  /// `WS /audio/{id}` — live system-audio listeners (same session_id as screen,
  /// par alag socket/channel — screen band ho to audio khud band nahi hoti).
  final Map<String, Set<WebSocketChannel>> audioListeners = {};

  /// P0 fix: har session/screen listener ka principal (kisne connect kiya)
  /// yaad rakhte hain, taaki key revoke/disable/expire ya device token
  /// rotate/unpair hone par khule sockets turant band ho sakein — pehle
  /// authorization sirf handshake par hoti thi.
  final Map<WebSocketChannel, WsListenerOwner> listenerOwners = {};

  /// Listener register karta hai (handshake ke baad, handlers.dart se).
  void registerListener(WebSocketChannel ws, WsListenerOwner owner) {
    listenerOwners[ws] = owner;
  }

  /// Listener ko sab jagah se hata deta hai (onDone/onError par).
  void unregisterListener(WebSocketChannel ws) {
    listenerOwners.remove(ws);
    for (final set in sessionListeners.values) {
      set.remove(ws);
    }
    final emptied = <String>[];
    for (final e in screenListeners.entries) {
      if (e.value.remove(ws) && e.value.isEmpty) emptied.add(e.key);
    }
    for (final id in emptied) {
      _scheduleScreenIdle(id);
    }
    for (final set in audioListeners.values) {
      set.remove(ws);
    }
  }

  // ---- last viewer chhodne par device ko capture band karne ka signal ----
  /// Viewer ke turant wapas aane (reconnect) par capture band na ho — isliye grace.
  Duration screenIdleGrace = const Duration(seconds: 15);
  final Map<String, Timer> _screenIdleTimers = {};

  void screenViewerAttached(String sessionId) {
    _screenIdleTimers.remove(sessionId)?.cancel();
  }

  void _scheduleScreenIdle(String sessionId) {
    _screenIdleTimers[sessionId]?.cancel();
    _screenIdleTimers[sessionId] = Timer(screenIdleGrace, () {
      _screenIdleTimers.remove(sessionId);
      final still = screenListeners[sessionId];
      if (still != null && still.isNotEmpty) return;
      final owner = sessionOwner(sessionId);
      if (owner != null) {
        notifyDevice(owner, {'kind': 'screen_idle', 'session_id': sessionId});
      }
      _lastScreenFrame.remove(sessionId);
    });
  }

  /// Har registered listener ko dobara validate karta hai; jiska
  /// credential ab valid nahi (key delete/disabled/expired, device
  /// unpaired, device token rotated, ya session ka owner badal gaya)
  /// use close(4001..4004) karta hai. Returns: band kiye gaye sockets.
  int revalidateListeners() {
    var closed = 0;
    for (final entry in listenerOwners.entries.toList()) {
      final reason = _listenerInvalidReason(entry.value);
      if (reason == null) continue;
      closed++;
      unregisterListener(entry.key);
      try {
        entry.key.sink.close(4004, reason);
      } catch (_) {}
    }
    return closed;
  }

  String? _listenerInvalidReason(WsListenerOwner o) {
    if (sessionOwner(o.sessionId) != o.sessionDeviceId) {
      return 'session no longer available';
    }
    final keyId = o.apiKeyId;
    if (keyId != null) {
      final k = apiKeys[keyId];
      if (k == null || !k.enabled || k.isExpired || !k.scope.screenView) {
        return 'api key revoked, disabled or expired';
      }
      if (k.deviceId != o.sessionDeviceId) return 'api key revoked, disabled or expired';
    }
    final devId = o.principalDeviceId;
    if (devId != null) {
      final d = devices[devId];
      if (d == null || d.bearerTokenHash != o.principalTokenHash) {
        return 'device token revoked or rotated';
      }
    }
    return null;
  }

  /// Session -> device mapping, taaki `/sessions/{id}/switch` aur command
  /// routing ko pata chale kis device se baat karni hai.
  final Map<String, String> sessionToDevice = {};

  /// In-flight command -> completer, request_id se correlate hota hai
  /// jab device apna result WS par wapas bhejta hai.
  final Map<String, Completer<Map<String, dynamic>>> pendingCommands = {};

  /// Item 7: `request_id` -> jis device ko command bheja gaya. Sirf wahi
  /// device is request ka `command_result` complete kar sakta hai.
  final Map<String, String> pendingCommandDevice = {};

  /// Item 6: session/task ka asli owner device (mapping ya task record
  /// se). `null` matlab session abhi tak kisi ki nahi hai.
  String? sessionOwner(String sessionId) =>
      sessionToDevice[sessionId] ?? tasks[sessionId]?.deviceId;

  /// Item 6/7: kya `deviceId` is session ko use karne ka haqdar hai?
  /// Unclaimed session (owner `null`) par `true` — pehli baar claim
  /// karne wala owner ban jata hai (dekhein [claimSession]).
  bool sessionBelongsTo(String sessionId, String deviceId) {
    final owner = sessionOwner(sessionId);
    return owner == null || owner == deviceId;
  }

  /// Session ko `deviceId` ke liye claim karta hai, **sirf agar** woh
  /// abhi unclaimed hai ya pehle se isi device ki hai. Dusre device ki
  /// session ko kabhi overwrite nahi karta. Returns `true` agar ab yeh
  /// session `deviceId` ki hai.
  bool claimSession(String sessionId, String deviceId) {
    if (!sessionBelongsTo(sessionId, deviceId)) return false;
    sessionToDevice[sessionId] = deviceId;
    return true;
  }

  /// Item 21: device ko aur uske saare data ko hata do (unpair).
  /// Returns `false` agar device exist hi nahi karta.
  Future<bool> removeDevice(String deviceId) async {
    if (devices.remove(deviceId) == null) return false;
    apiKeys.removeWhere((_, k) => k.deviceId == deviceId);
    connectorCredentials.removeWhere((_, c) => c.deviceId == deviceId);
    final taskIds = tasks.values
        .where((t) => t.deviceId == deviceId)
        .map((t) => t.taskId)
        .toList();
    for (final id in taskIds) {
      tasks.remove(id);
    }
    sessionToDevice.removeWhere((_, owner) => owner == deviceId);
    customCapabilityManifests
        .removeWhere((m) => m['registered_by'] == deviceId);
    activityLog.removeWhere((e) => e.deviceId == deviceId);
    final conn = deviceConnections.remove(deviceId);
    try {
      await conn?.sink.close(4001, 'device unpaired');
    } catch (_) {}
    revalidateListeners(); // is device ke sessions/keys ke khule WS band
    await persist();
    return true;
  }

  /// P0-01 — Real TaskRecord state machine. Key = taskId (== session_id,
  /// see `models/task.dart` doc comment for why). In-memory hi hai abhi
  /// (task lifecycle ki durability P1-09/DEP-01 ka scope hai, is item ka
  /// nahi) — restart par running tasks reset ho jaate hain, jo safe hai
  /// (paused/stopped claim nahi karte jo sach na ho).
  final Map<String, TaskRecord> tasks = {};

  /// Kisi bhi non-control command ke params mein session_id ho aur uska
  /// koi TaskRecord abhi tak na bana ho, to is command se implicitly ek
  /// naya task RUNNING state mein start ho jaata hai — task ka "start"
  /// isi tarah define hai (koi alag control.start action nahi hai).
  /// `capability` — is command ka `envelope['capability']` — task ki
  /// `originatingCapability` ban jaati hai (P0-02 authorization binding
  /// ke liye).
  TaskRecord getOrCreateRunningTask(
      String taskId, String deviceId, String capability) {
    final existing = tasks[taskId];
    if (existing != null) return existing;
    final task = TaskRecord(
        taskId: taskId, deviceId: deviceId, originatingCapability: capability);
    tasks[taskId] = task;
    return task;
  }

  /// Stale task cleanup. Status doc (item 59) ise "done" bata raha tha
  /// lekin source mein yeh tha hi nahi — tasks/sessionToDevice hamesha
  /// badhte rehte the aur ek mara hua RUNNING task kabhi khatam nahi hota.
  ///  * RUNNING task jis par `runningStaleAfter` se zyada activity nahi
  ///    hui => FAILED (reason `stale: ...`), device + listeners ko batao.
  ///  * PAUSED task `pausedStaleAfter` se zyada => FAILED (user ke wait
  ///    karne ki wajah se lamba window).
  ///  * Terminal task `terminalRetention` se purana => hata do (task,
  ///    session mapping; uske listeners revalidation se band honge).
  /// Returns (failed ids, removed ids).
  ({List<String> failed, List<String> removed}) sweepTasks({
    Duration runningStaleAfter = const Duration(hours: 24),
    Duration pausedStaleAfter = const Duration(days: 7),
    Duration terminalRetention = const Duration(days: 7),
    DateTime? now,
  }) {
    final t = (now ?? DateTime.now()).toUtc();
    final failed = <String>[];
    final removed = <String>[];
    for (final task in tasks.values.toList()) {
      final idle = t.difference(task.updatedAt.toUtc());
      if (task.state == TaskState.running && idle > runningStaleAfter ||
          task.state == TaskState.paused && idle > pausedStaleAfter) {
        task.state = TaskState.failed;
        task.terminalReason =
            'stale: no activity for ${idle.inHours}h (auto-failed by server)';
        task.updatedAt = t;
        failed.add(task.taskId);
        broadcastTaskState(task);
        notifyDeviceTaskState(task);
      } else if (task.state.isTerminal && idle > terminalRetention) {
        tasks.remove(task.taskId);
        sessionToDevice.remove(task.taskId);
        clearScreenFrameState(task.taskId);
        removed.add(task.taskId);
      }
    }
    if (removed.isNotEmpty) revalidateListeners();
    if (failed.isNotEmpty || removed.isNotEmpty) persist();
    return (failed: failed, removed: removed);
  }

  /// Control transition ka rollback (device tak forward fail/timeout
  /// hone par). Pehle blind `task.state = ...` tha — agar beech mein koi
  /// aur request state badal chuki ho ya task hat chuka ho (null `!`
  /// crash), to galat state overwrite ho jaati. Ab sirf tab rollback
  /// jab task abhi bhi wahi state mein ho jo *isi request* ne set ki thi.
  bool rollbackTask(String taskId, TaskState to, TaskState? expectedCurrent) {
    final task = tasks[taskId];
    if (task == null || expectedCurrent == null || task.state != expectedCurrent) {
      return false;
    }
    task.state = to;
    task.touch();
    persist();
    return true;
  }

  /// `task_state` event broadcast karta hai (PROTOCOL_V1.md, naya event
  /// `type` jo Section 2 mein reserved kiya gaya hai P0-01 ke liye).
  void broadcastTaskState(TaskRecord task) {
    broadcastToSession(task.taskId, {
      'protocol_version': '1.0',
      'type': 'task_state',
      'session_id': task.taskId,
      'task_id': task.taskId,
      'state': task.state.wireValue,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Item 56: device ko ek best-effort message bhejta hai (jaise
  /// `task_state`). Offline ho ya send fail ho to chup-chaap `false`.
  bool notifyDevice(String deviceId, Map<String, dynamic> message) {
    final conn = deviceConnections[deviceId];
    if (conn == null) return false;
    try {
      conn.sink.add(jsonEncode(message));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Item 56: task ka naya state device ko bhi batao (server-only
  /// transitions `control.complete`/`control.fail` device tak command
  /// ke roop mein nahi jaati, isliye device ko live-stream band karne
  /// ka koi signal nahi milta tha).
  void notifyDeviceTaskState(TaskRecord task) {
    notifyDevice(task.deviceId, {
      'kind': 'task_state',
      'session_id': task.taskId,
      'state': task.state.wireValue,
    });
  }

  void logActivity(ActivityEvent event) {
    activityLog.add(event);
    // Simple bound — memory unbounded na ho, purane events drop.
    if (activityLog.length > 5000) {
      activityLog.removeAt(0);
    }
  }

  /// P1-09 — time-based retention (audit: "retention removes old
  /// events"). Count-based bound (upar, 5000) ek memory-safety floor
  /// hai; yeh asal retention *policy* hai — `AUDIT_RETENTION_DAYS` env
  /// var se configurable (default 90 din), `bin/server.dart` ke periodic
  /// timer se call hota hai.
  int pruneActivityLog({Duration retention = const Duration(days: 90)}) {
    final cutoff = DateTime.now().toUtc().subtract(retention);
    final before = activityLog.length;
    activityLog.removeWhere((e) => e.timestamp.isBefore(cutoff));
    return before - activityLog.length; // kitne events remove hue
  }

  /// P0-06 fix — pehle yahan plaintext `d.bearerToken == token` compare
  /// hota tha. Ab `Device` sirf hash store karta hai, is liye incoming
  /// token ko hash karke compare karte hain (`ApiKeyRecord`'s secret
  /// check ke bilkul same pattern).
  Device? deviceByToken(String token) {
    final incomingHash = hashSecretUtil(token);
    if (_deviceIndexVersion != devices.version) {
      _deviceTokenIndex.clear();
      for (final d in devices.values) {
        _deviceTokenIndex[d.bearerTokenHash] = d.id;
      }
      _deviceIndexVersion = devices.version;
    }
    final id = _deviceTokenIndex[incomingHash];
    final d = id == null ? null : devices[id];
    // Index-hit ko hamesha current record ke against re-verify karo
    // (stale entry / in-place token rotation ke khilaf).
    if (d != null && constantTimeEquals(d.bearerTokenHash, incomingHash)) {
      return d;
    }
    return null;
  }

  /// API key secret se record dhoondta hai (enabled + non-expired hi).
  ApiKeyRecord? apiKeyBySecret(String secret) {
    final incomingHash = hashSecretUtil(secret);
    if (_apiKeyIndexVersion != apiKeys.version) {
      _apiKeyIndex.clear();
      for (final k in apiKeys.values) {
        _apiKeyIndex[k.secretHash] = k.keyId;
      }
      _apiKeyIndexVersion = apiKeys.version;
    }
    final keyId = _apiKeyIndex[incomingHash];
    final k = keyId == null ? null : apiKeys[keyId];
    if (k != null &&
        constantTimeEquals(k.secretHash, incomingHash) &&
        k.enabled &&
        !k.isExpired) {
      return k;
    }
    return null;
  }

  /// Item 43: jo connected devices `maxSilence` se zyada waqt se chup hain
  /// (heartbeat/koi message nahi) unka connection band karke `OFFLINE`
  /// mark karta hai. WS ping ke saath milkar dead connections pakadta hai.
  /// Returns: jin devices ko offline kiya unki ids.
  List<String> sweepStaleDevices(
      {Duration maxSilence = const Duration(seconds: 90), DateTime? now}) {
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(maxSilence);
    final stale = <String>[];
    for (final entry in deviceConnections.entries.toList()) {
      final device = devices[entry.key];
      if (device == null || device.lastSeenAt.toUtc().isBefore(cutoff)) {
        stale.add(entry.key);
      }
    }
    for (final id in stale) {
      final conn = deviceConnections.remove(id);
      try {
        conn?.sink.close(4003, 'heartbeat timeout');
      } catch (_) {}
      final device = devices[id];
      if (device != null) device.state = 'OFFLINE';
    }
    return stale;
  }

  /// Ek device ko ek command bhejta hai uske persistent connection par,
  /// aur result ka wait karta hai (ya timeout).
  Future<Map<String, dynamic>> sendCommandToDevice(
    String deviceId,
    Map<String, dynamic> envelope, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final conn = deviceConnections[deviceId];
    if (conn == null) {
      throw StateError('Device offline hai (koi active connection nahi)');
    }
    final requestId = envelope['request_id'] as String;
    // Item 44: same request_id ka doosra in-flight command reject — warna
    // pehle waale ka completer overwrite ho jata aur dono callers ke
    // results mix ho sakte the.
    if (pendingCommands.containsKey(requestId)) {
      throw DuplicateRequestException(requestId);
    }
    final completer = Completer<Map<String, dynamic>>();
    pendingCommands[requestId] = completer;
    pendingCommandDevice[requestId] = deviceId;

    try {
      conn.sink.add(jsonEncode({'kind': 'command', ...envelope}));
      return await completer.future.timeout(timeout);
    } finally {
      pendingCommands.remove(requestId);
      pendingCommandDevice.remove(requestId);
    }
  }

  /// Ek session ke saare listeners ko ek event broadcast karta hai.
  void broadcastToSession(String sessionId, Map<String, dynamic> event) {
    final listeners = sessionListeners[sessionId];
    if (listeners == null) return;
    final payload = jsonEncode(event);
    // Item 48: ek dead listener baaki sabko na roke — copy par iterate
    // karte hain aur har add try/catch mein hai.
    for (final l in List.of(listeners)) {
      try {
        l.sink.add(payload);
      } catch (_) {
        listeners.remove(l);
      }
    }
  }

  // ---- Admin web dashboard: browser WebSocket ke liye ek-baar-use tickets ----
  static const wsTicketTtl = Duration(seconds: 60);
  final Map<String, DateTime> _wsTickets = {};

  String issueWsTicket() {
    final now = DateTime.now().toUtc();
    _wsTickets.removeWhere((_, exp) => exp.isBefore(now));
    final t = randomHex(24);
    _wsTickets[t] = now.add(wsTicketTtl);
    return t;
  }

  /// Valid + unexpired ticket ek baar hi chalta hai.
  bool consumeWsTicket(String ticket) {
    final exp = _wsTickets.remove(ticket);
    return exp != null && exp.isAfter(DateTime.now().toUtc());
  }

  /// Server-side frame-rate cap (device ka 6fps throttle bharose ka nahi:
  /// buggy/compromised paired device bhi flood kar sakta hai). 15 fps se
  /// tez aane wale frames drop.
  static const minScreenFrameInterval = Duration(milliseconds: 33); // ~30 fps cap
  final Map<String, DateTime> _lastScreenFrameAt = {};

  /// Aakhri frame (static screen par naye viewer ko turant dikhane ke liye).
  /// Sirf thodi der (30s) tak replay hota hai — purani screen ka frame
  /// baad mein kisi naye viewer ko nahi dikhna chahiye.
  final Map<String, ({dynamic frame, DateTime at})> _lastScreenFrame = {};
  static const screenFrameReplayMaxAge = Duration(seconds: 30);

  bool allowScreenFrame(String sessionId, {DateTime? now}) {
    final t = (now ?? DateTime.now()).toUtc();
    final last = _lastScreenFrameAt[sessionId];
    if (last != null && t.difference(last) < minScreenFrameInterval) return false;
    _lastScreenFrameAt[sessionId] = t;
    return true;
  }

  /// Naye screen viewer ko (agar RUNNING task ka taaza frame ho) wahi do.
  dynamic replayableScreenFrame(String sessionId, {DateTime? now}) {
    final entry = _lastScreenFrame[sessionId];
    if (entry == null) return null;
    final t = (now ?? DateTime.now()).toUtc();
    if (t.difference(entry.at) > screenFrameReplayMaxAge) {
      _lastScreenFrame.remove(sessionId);
      return null;
    }
    final task = tasks[sessionId];
    if (task != null && task.state != TaskState.running) return null;
    return entry.frame;
  }

  void clearScreenFrameState(String sessionId) {
    _lastScreenFrameAt.remove(sessionId);
    _lastScreenFrame.remove(sessionId);
  }

void broadcastToAudio(String sessionId, dynamic chunk) {
    final listeners = audioListeners[sessionId];
    if (listeners == null) return;
    for (final l in List.of(listeners)) {
      try {
        l.sink.add(chunk);
      } catch (_) {
        listeners.remove(l);
      }
    }
  }

  void broadcastToScreen(String sessionId, dynamic frame) {
    _lastScreenFrame[sessionId] = (frame: frame, at: DateTime.now().toUtc());
    final listeners = screenListeners[sessionId];
    if (listeners == null) return;
    for (final l in List.of(listeners)) {
      try {
        l.sink.add(frame);
      } catch (_) {
        listeners.remove(l);
      }
    }
  }

  // ---- P0-07: Connector OAuth ---------------------------------------------

  /// `state` token -> in-flight authorization request. Chhota, short-lived
  /// (10 min) hai — persist nahi karte (restart ke beech koi in-flight
  /// OAuth login shayad hi survive kare, aur agar na bhi kare to user
  /// bas dobara "Connect" click karega).
  final Map<String, PendingConnectorAuth> pendingConnectorAuths = {};

  /// Key format: `"$deviceId:$connectorName"`.
  final Map<String, ConnectorCredential> connectorCredentials = {};

  String _connectorKey(String deviceId, String connectorName) =>
      '$deviceId:$connectorName';

  ConnectorCredential? connectorCredentialFor(String deviceId, String connectorName) =>
      connectorCredentials[_connectorKey(deviceId, connectorName)];

  void storeConnectorCredential(ConnectorCredential credential) {
    connectorCredentials[
        _connectorKey(credential.deviceId, credential.connectorName)] = credential;
  }

  void removeConnectorCredential(String deviceId, String connectorName) {
    connectorCredentials.remove(_connectorKey(deviceId, connectorName));
  }

  /// **Token refresh (audit: "expired token refreshes")** — is device ke
  /// is connector ke liye ek istemal-ke-laayak (valid, non-expired)
  /// plaintext access token deta hai. Agar stored token expire ho chuka
  /// ho (ya expire hone wala ho), pehle `provider.refresh()` call karke
  /// naya token le aata hai, encrypt karke store update karta hai, phir
  /// return karta hai — caller (jo bhi connector API call kar raha ho)
  /// ko kabhi khud refresh-logic handle nahi karni padti.
  ///
  /// `null` deta hai agar connector connected hi nahi hai (caller isko
  /// "not authenticated" ki tarah treat kare).
  /// Item 47: concurrent refresh calls ek hi refresh share karti hain
  /// (per connector credential) — pehle do requests ek saath refresh
  /// token use karte the aur dusri `invalid_grant` pa sakti thi.
  final Map<String, Future<String?>> _refreshInFlight = {};

  /// Valid access token deta hai (zaroorat par refresh karke). `null`
  /// matlab "connected nahi / dobara auth chahiye":
  ///  * credential hi nahi hai,
  ///  * decrypt nahi ho paya (encryption key badal gayi/missing),
  ///  * refresh token nahi hai ya provider ne `invalid_grant` diya
  ///    (is case mein stale credential hata di jati hai).
  /// Doosre refresh errors (network, provider down) `StateError` ke
  /// roop mein bahar aate hain — caller ko 5xx dena chahiye.
  Future<String?> getValidAccessToken(
      String deviceId, String connectorName, ConnectorProvider provider) async {
    final credential = connectorCredentialFor(deviceId, connectorName);
    if (credential == null) return null;

    if (!credential.isAccessTokenExpiredOrExpiringSoon) {
      try {
        return await decryptSecret(credential.encryptedAccessToken);
      } catch (_) {
        return null; // decrypt fail => re-auth chahiye (500 nahi)
      }
    }

    final key = _connectorKey(deviceId, connectorName);
    final inFlight = _refreshInFlight[key];
    if (inFlight != null) return inFlight;

    final future = _refreshAccessToken(credential, provider);
    _refreshInFlight[key] = future;
    try {
      return await future;
    } finally {
      _refreshInFlight.remove(key);
    }
  }

  Future<String?> _refreshAccessToken(
      ConnectorCredential credential, ConnectorProvider provider) async {
    // Refresh token hi nahi hai — user ko dobara connect karna hoga.
    if (credential.encryptedRefreshToken == null) return null;
    try {
      final refreshToken = await decryptSecret(credential.encryptedRefreshToken!);
      final newTokens = await provider.refresh(refreshToken: refreshToken);

      credential.encryptedAccessToken = await encryptSecret(newTokens.accessToken);
      // Google (aur zyada tar providers) refresh par naya refresh_token
      // nahi dete — purana hi rakhte hain agar naya na mila ho.
      if (newTokens.refreshToken != null) {
        credential.encryptedRefreshToken =
            await encryptSecret(newTokens.refreshToken!);
      }
      credential.accessTokenExpiresAt = newTokens.accessTokenExpiresAt;
      if (newTokens.grantedScopes.isNotEmpty) {
        credential.grantedScopes = newTokens.grantedScopes;
      }
      await persist();
      return newTokens.accessToken;
    } on StateError catch (e) {
      // `invalid_grant` = refresh token revoke/expire — credential
      // bekaar hai, hata do taaki status "not connected" dikhe.
      if (e.message.toLowerCase().contains('invalid_grant')) {
        removeConnectorCredential(credential.deviceId, credential.connectorName);
        await persist();
        return null;
      }
      rethrow;
    } catch (_) {
      // Decrypt/crypto error — re-auth chahiye.
      return null;
    }
  }
}

/// Ek session/screen WebSocket listener ka authenticated principal.
/// Exactly ek of `apiKeyId` / `principalDeviceId` set hota hai.
class WsListenerOwner {
  final String sessionId;
  final String sessionDeviceId; // session ka owning device (connect ke waqt)
  final String? apiKeyId;
  final String? principalDeviceId;
  final String? principalTokenHash; // connect ke waqt device token hash

  const WsListenerOwner({
    required this.sessionId,
    required this.sessionDeviceId,
    this.apiKeyId,
    this.principalDeviceId,
    this.principalTokenHash,
  });
}
