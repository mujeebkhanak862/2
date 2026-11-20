/// Core Protocol — REST API client
///
/// Control API ke saath saari request/response calls yahin se hoti hain:
/// capability discovery, scoped-key management, aur commands bhejna.
/// (Architecture v4, Section 1.4 aur 3.3 ke endpoints implement karta hai.)
library;

import 'dart:convert';
import 'dart:io' show Platform;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'activity_event.dart';
import 'api_key.dart';
import 'capability_manifest.dart';
import 'command_envelope.dart';
import 'device_status.dart';
import 'task_summary.dart';

/// PROTOCOL_V1.md, Section 3 — canonical error envelope
/// (`{"error": {"code", "message", "request_id"}}`). `code` machine-
/// readable hai — UI/logic isi par switch kare (e.g. "SCOPE_DENIED" ->
/// "yeh permission maango" jaisa flow), `message` sirf display ke liye,
/// kabhi bhi `code` ke bajaye string-match mat karo kyunki `message` ka
/// wording badal sakta hai.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  ApiException(this.statusCode, this.code, this.message, {this.requestId});

  /// Server se raw response body parse karta hai. Canonical shape na ho
  /// (purana/malformed server, ya network-layer error page) to bhi crash
  /// nahi karta — `code` ko "UNKNOWN" fallback deta hai.
  factory ApiException.fromResponse(int statusCode, String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      if (error is Map<String, dynamic>) {
        return ApiException(
          statusCode,
          error['code'] as String? ?? 'UNKNOWN',
          error['message'] as String? ?? body,
          requestId: error['request_id'] as String?,
        );
      }
    } catch (_) {
      // body JSON nahi thi ya expected shape mein nahi — neeche fallback.
    }
    return ApiException(statusCode, 'UNKNOWN', body);
  }

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

class DeviceAgentApiClient {
  final Uri baseUrl; // e.g. https://control.example.com
  final http.Client _http;
  final Uuid _uuid = const Uuid();

  /// Currently-active scoped key jiske through requests bhejte hain. Dashboard
  /// key-switcher iske zariye active context badal sakta hai
  /// (control.switch, switch_type "api_key" — Section 4.1).
  String activeApiKeyId;
  String? _bearerToken;

  DeviceAgentApiClient({
    required this.baseUrl,
    required this.activeApiKeyId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  void setBearerToken(String token) => _bearerToken = token;

  void clearBearerToken() => _bearerToken = null;

  /// WebSocket channels (`/sessions`, `/screen`) ko bhi yahi token chahiye.
  String? get bearerToken => _bearerToken;

  /// Item 24: 401 aane par (token invalid/rotated/device unpaired)
  /// app ko batane ke liye — woh credentials clear karke dobara pair
  /// karwa sakta hai.
  void Function()? onUnauthorized;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_bearerToken != null) 'Authorization': 'Bearer $_bearerToken',
      };

  Uri _u(String path) => baseUrl.resolve(path);

  Future<T> _decode<T>(http.Response res, T Function(dynamic) parse) {
    if (res.statusCode == 401) onUnauthorized?.call();
    if (res.statusCode >= 200 && res.statusCode < 300) {
      final body = res.body.isEmpty ? null : jsonDecode(res.body);
      return Future.value(parse(body));
    }
    throw ApiException.fromResponse(res.statusCode, res.body);
  }

  // ---- Section 1.4 — Capability discovery -------------------------------

  Future<List<CapabilityManifest>> getCapabilities() async {
    final res = await _http.get(_u('/capabilities'), headers: _headers);
    return _decode(res, (body) => (body as List<dynamic>)
        .map((e) => CapabilityManifest.fromJson(e as Map<String, dynamic>))
        .toList());
  }

  Future<CapabilityManifest> getCapabilitySchema(String name) async {
    final res =
        await _http.get(_u('/capabilities/$name/schema'), headers: _headers);
    return _decode(
        res, (body) => CapabilityManifest.fromJson(body as Map<String, dynamic>));
  }

  // ---- Section 3.3 — Scoped API keys -------------------------------------

  Future<ApiKey> createApiKey({
    required String label,
    required ApiKeyScope scope,
  }) async {
    final res = await _http.post(
      _u('/api-keys'),
      headers: _headers,
      body: jsonEncode({'label': label, 'scope': scope.toJson()}),
    );
    return _decode(res, (body) => ApiKey.fromJson(body as Map<String, dynamic>));
  }

  Future<List<ApiKey>> listApiKeys() async {
    final res = await _http.get(_u('/api-keys'), headers: _headers);
    return _decode(res, (body) => (body as List<dynamic>)
        .map((e) => ApiKey.fromJson(e as Map<String, dynamic>))
        .toList());
  }

  Future<ApiKey> updateApiKeyPermissions(
      String keyId, ApiKeyScope newScope) async {
    final res = await _http.patch(
      _u('/api-keys/$keyId/permissions'),
      headers: _headers,
      body: jsonEncode({'scope': newScope.toJson()}),
    );
    return _decode(res, (body) => ApiKey.fromJson(body as Map<String, dynamic>));
  }

  /// `PATCH /api-keys/{id}/status` — disable/re-enable ek key bina delete
  /// kiye (audit P0-02 — "revoke/disable"). DELETE permanent hai; yeh
  /// temporary "pause" ke liye. Effect turant hai — server har request
  /// par live check karta hai, koi caching nahi.
  Future<ApiKey> setApiKeyEnabled(String keyId, bool enabled) async {
    final res = await _http.patch(
      _u('/api-keys/$keyId/status'),
      headers: _headers,
      body: jsonEncode({'enabled': enabled}),
    );
    return _decode(res, (body) => ApiKey.fromJson(body as Map<String, dynamic>));
  }

  Future<void> revokeApiKey(String keyId) async {
    final res = await _http.delete(_u('/api-keys/$keyId'), headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException.fromResponse(res.statusCode, res.body);
    }
  }

  // ---- Commands -----------------------------------------------------------

  /// Ek command bhejta hai aur naya request_id khud generate karta hai.
  Future<Map<String, dynamic>> sendCommand({
    required String capability,
    required String action,
    Map<String, dynamic> params = const {},
    String? payload,
    int? timeoutMs,
  }) async {
    final envelope = CommandEnvelope(
      requestId: _uuid.v4(),
      apiKeyId: activeApiKeyId,
      capability: capability,
      action: action,
      params: params,
      payload: payload,
      timeoutMs: timeoutMs,
    );
    // Item 25: dashboard sirf device token rakhta hai; `/commands` sirf
    // API key leta tha (isliye sab 401 the). `/owner/commands` device
    // token ko accept karke owner-key ke saath wahi pipeline chalata hai.
    final res = await _http.post(
      _u('/owner/commands'),
      headers: _headers,
      body: jsonEncode(envelope.toJson()),
    );
    return _decode(res, (body) => body as Map<String, dynamic>);
  }

  /// Section 4.1 — Universal Switch API.
  Future<void> switchSession({
    required String sessionId,
    required SwitchType switchType,
    required String value,
  }) async {
    final res = await _http.post(
      _u('/owner/sessions/$sessionId/switch'),
      headers: _headers,
      body: jsonEncode({
        'switch_type': switchType.wireValue,
        'value': value,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException.fromResponse(res.statusCode, res.body);
    }
  }

  /// Section 1.4 — external connector OAuth/API-key auth flow start karta
  /// hai (Google Drive, Slack, CRM, custom company API waghera).
  Future<Map<String, dynamic>> startConnectorAuth(String connectorName) async {
    final res =
        await _http.post(_u('/connectors/$connectorName/auth'), headers: _headers);
    return _decode(res, (body) => body as Map<String, dynamic>);
  }

  // ---- Pairing (naya) — POST /devices/pair -------------------------------

  /// Pairing screen se milne wale code se device register karta hai —
  /// bearer token wapas milta hai jo aage sab management calls
  /// (key creation, status, waghera) authenticate karta hai. Yeh call
  /// hone ke baad `setBearerToken()` yahi token le kar call karna
  /// zaroori hai (main.dart mein wired hai).
  static const String _pairingSecret =
      String.fromEnvironment('PAIRING_SECRET', defaultValue: '');

  Future<Map<String, dynamic>> pairDevice({
    required String pairingCode,
    required String deviceName,
  }) async {
    final res = await _http.post(
      _u('/devices/pair'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'pairing_code': pairingCode,
        'device_name': deviceName,
        // P1-02 — AI Tool Registry ko batata hai ke is device par
        // kaunsi capabilities OS-level par actually support hoti hain
        // (jaise `contacts` sirf Android par). `Platform.operatingSystem`
        // is app ke teeno supported targets par exactly 'android' /
        // 'windows' / 'linux' deta hai — Control API ki validation se
        // seedha match karta hai.
        'platform': Platform.operatingSystem,
        // Item 10: server par PAIRING_SECRET set ho to wahi yahan bhejna
        // hai. Build time par do: `--dart-define=PAIRING_SECRET=...`
        if (_pairingSecret.isNotEmpty) 'pairing_secret': _pairingSecret,
      }),
    );
    return _decode(res, (body) => body as Map<String, dynamic>);
  }

  // ---- Section 10/11 — Device status, location, network -----------------

  Future<DeviceStatus> getDeviceStatus(String deviceId) async {
    final res =
        await _http.get(_u('/devices/$deviceId/status'), headers: _headers);
    return _decode(
        res, (body) => DeviceStatus.fromJson(body as Map<String, dynamic>));
  }

  /// `location.write` scope wale key iske through location report kar
  /// saktay hain (Section 11.5) — background agent se ya manual "Locate
  /// Device" action se.
  Future<void> reportLocation(
      String deviceId, Map<String, dynamic> locationJson) async {
    final res = await _http.post(
      _u('/devices/$deviceId/location'),
      headers: _headers,
      body: jsonEncode(locationJson),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException.fromResponse(res.statusCode, res.body);
    }
  }

  // ---- Section 9.6 — Unified Activity History -----------------------------

  Future<List<ActivityEvent>> getActivityHistory(String deviceId,
      {int limit = 50}) async {
    final res = await _http.get(
      _u('/devices/$deviceId/activity?limit=$limit'),
      headers: _headers,
    );
    return _decode(res, (body) => (body as List<dynamic>)
        .map((e) => ActivityEvent.fromJson(e as Map<String, dynamic>))
        .toList());
  }

  /// Item 30/87: apne device ke tasks (active ho ya sab).
  Future<List<TaskSummary>> getTasks({bool activeOnly = false}) async {
    final res = await _http.get(
      _u('/tasks${activeOnly ? '?active=true' : ''}'),
      headers: _headers,
    );
    return _decode(res, (body) => (body as List<dynamic>)
        .map((e) => TaskSummary.fromJson(e as Map<String, dynamic>))
        .toList());
  }

  /// Item 32: network status server ko report karo.
  Future<void> reportNetwork(
      String deviceId, Map<String, dynamic> networkJson) async {
    final res = await _http.post(
      _u('/devices/$deviceId/network'),
      headers: _headers,
      body: jsonEncode(networkJson),
    );
    if (res.statusCode == 401) onUnauthorized?.call();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException.fromResponse(res.statusCode, res.body);
    }
  }

  /// Item 21 (client side): device ko server se unpair karo.
  Future<void> unpairDevice(String deviceId) async {
    final res = await _http.delete(_u('/devices/$deviceId'), headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException.fromResponse(res.statusCode, res.body);
    }
  }

  /// Item 21 (client side): naya bearer token. Caller ko naya token
  /// secure storage mein save karke `setBearerToken` + reconnect karna hai.
  Future<String> rotateToken(String deviceId) async {
    final res = await _http.post(
      _u('/devices/$deviceId/rotate-token'),
      headers: _headers,
    );
    return _decode(res, (body) => (body as Map<String, dynamic>)['bearer_token'] as String);
  }

  void close() => _http.close();
}
