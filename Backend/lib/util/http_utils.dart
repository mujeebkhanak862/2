/// Shared HTTP helpers (Stage 1 security fixes: items 11, 16, 18).
library;

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../models/errors.dart';

// ---------------------------------------------------------------------------
// Item 18: safe JSON body parsing
// ---------------------------------------------------------------------------

/// Nateeja [readJsonObject] ka: ya to parsed `body`, ya ready-made
/// `error` response (400/413).
class JsonBodyResult {
  final Map<String, dynamic>? body;
  final Response? error;
  const JsonBodyResult._(this.body, this.error);
  factory JsonBodyResult.ok(Map<String, dynamic> body) =>
      JsonBodyResult._(body, null);
  factory JsonBodyResult.fail(Response error) => JsonBodyResult._(null, error);
  bool get isOk => body != null;
}

/// Request body ko JSON **object** ke tor par safely parse karta hai.
/// Malformed JSON, non-object JSON, ya `maxBytes` se bada body par
/// HTTP 500 ke bajaye clean 400/413 deta hai.
Future<JsonBodyResult> readJsonObject(Request request,
    {int maxBytes = 64 * 1024}) async {
  final String raw;
  try {
    raw = await request.readAsString();
  } on BodyTooLargeException {
    return JsonBodyResult.fail(
        ApiError.payloadTooLarge('Request body bahut bada hai'));
  } catch (_) {
    return JsonBodyResult.fail(
        ApiError.invalidRequest('Request body padha nahi ja saka'));
  }
  if (utf8.encode(raw).length > maxBytes) {
    return JsonBodyResult.fail(ApiError.payloadTooLarge(
        'Request body $maxBytes bytes se zyada hai'));
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return JsonBodyResult.fail(
        ApiError.invalidRequest('Body valid JSON nahi hai'));
  }
  if (decoded is! Map<String, dynamic>) {
    return JsonBodyResult.fail(
        ApiError.invalidRequest('Body ek JSON object hona chahiye'));
  }
  return JsonBodyResult.ok(decoded);
}

/// Device location ko validate karke sirf whitelisted fields return
/// karta hai; invalid ho to `null`.
Map<String, dynamic>? sanitizeLocation(Map<String, dynamic> raw) {
  final lat = raw['latitude'];
  final lng = raw['longitude'];
  if (lat is! num || lng is! num) return null;
  if (lat.isNaN || lng.isNaN) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  final accuracy = raw['accuracy_m'];
  final source = raw['source'];
  final timestamp = raw['timestamp'];
  return {
    'latitude': lat,
    'longitude': lng,
    if (accuracy is num && !accuracy.isNaN && accuracy >= 0)
      'accuracy_m': accuracy,
    if (source is String && source.length <= 32) 'source': source,
    'timestamp': timestamp is String && timestamp.length <= 40
        ? timestamp
        : DateTime.now().toUtc().toIso8601String(),
  };
}

/// Network status ko whitelist+validate karta hai (item 32).
Map<String, dynamic>? sanitizeNetwork(Map<String, dynamic> raw) {
  final connected = raw['connected'];
  if (connected is! bool) return null;
  final ssid = raw['ssid'];
  final type = raw['connection_type'];
  return {
    'connected': connected,
    if (ssid is String && ssid.length <= 64) 'ssid': ssid,
    if (type is String && type.length <= 32) 'connection_type': type,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
  };
}

// ---------------------------------------------------------------------------
// Item 11: HTML escaping
// ---------------------------------------------------------------------------

const HtmlEscape _htmlEscape = HtmlEscape(HtmlEscapeMode.unknown);

/// Untrusted text ko HTML mein daalne se pehle escape karo.
/// `HtmlEscapeMode.unknown` sabse strict mode hai: `& < > " ' /` sab
/// escape karta hai (text aur attribute dono context mein safe).
String escapeHtml(String input) => _htmlEscape.convert(input);

// ---------------------------------------------------------------------------
// Item 16: global body-size limit
// ---------------------------------------------------------------------------

/// Stream ke beech mein limit cross hone par throw hota hai.
class BodyTooLargeException implements Exception {
  final int limit;
  const BodyTooLargeException(this.limit);
  @override
  String toString() => 'BodyTooLargeException(limit: $limit)';
}

/// Middleware: `Content-Length` header badi ho to body padhe bina hi 413;
/// chunked/unknown-length body ko stream karte waqt count karta hai aur
/// limit cross hote hi [BodyTooLargeException] throw karta hai (jo yahin
/// pakad kar 413 mein badal diya jata hai).
///
/// WebSocket upgrade requests (GET, no body) par koi asar nahi.
Middleware bodySizeLimitMiddleware(int maxBytes) {
  return (Handler inner) {
    return (Request request) async {
      final declared = request.contentLength;
      if (declared != null && declared > maxBytes) {
        return ApiError.payloadTooLarge(
            'Request body $maxBytes bytes se zyada hai');
      }
      if (request.method == 'GET' || request.method == 'HEAD') {
        return inner(request);
      }
      var seen = 0;
      final limited = request.read().transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            seen += chunk.length;
            if (seen > maxBytes) {
              sink.addError(BodyTooLargeException(maxBytes));
              sink.close();
            } else {
              sink.add(chunk);
            }
          },
        ),
      );
      try {
        return await inner(request.change(body: limited));
      } on BodyTooLargeException {
        return ApiError.payloadTooLarge(
            'Request body $maxBytes bytes se zyada hai');
      }
    };
  };
}
