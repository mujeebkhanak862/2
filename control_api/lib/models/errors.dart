import 'dart:convert';

import 'package:shelf/shelf.dart';

/// PROTOCOL_V1.md, Section 3 — canonical error envelope. **Har** error
/// response server se isi shape mein jaata hai — koi route ab apna
/// alag ad-hoc `{"error": "..."}` string nahi bhejta.
class ApiError {
  final String code;
  final String message;
  final String? requestId;

  const ApiError(this.code, this.message, {this.requestId});

  Map<String, dynamic> toJson() => {
        'error': {
          'code': code,
          'message': message,
          if (requestId != null) 'request_id': requestId,
        },
      };

  Response toResponse(int statusCode) => Response(
        statusCode,
        body: jsonEncode(toJson()),
        headers: {'content-type': 'application/json'},
      );

  // ---- Convenience constructors — PROTOCOL_V1.md ka canonical enum ----

  static Response unauthorized(String message, {String? requestId}) =>
      ApiError('UNAUTHORIZED', message, requestId: requestId).toResponse(401);

  static Response scopeDenied(String message, {String? requestId}) =>
      ApiError('SCOPE_DENIED', message, requestId: requestId).toResponse(403);

  static Response forbidden(String message, {String? requestId}) =>
      ApiError('FORBIDDEN', message, requestId: requestId).toResponse(403);

  static Response notFound(String message, {String? requestId}) =>
      ApiError('NOT_FOUND', message, requestId: requestId).toResponse(404);

  static Response invalidRequest(String message, {String? requestId}) =>
      ApiError('INVALID_REQUEST', message, requestId: requestId).toResponse(400);

  static Response unsupportedProtocolVersion(String message, {String? requestId}) =>
      ApiError('UNSUPPORTED_PROTOCOL_VERSION', message, requestId: requestId)
          .toResponse(400);

  static Response payloadTooLarge(String message, {String? requestId}) =>
      ApiError('PAYLOAD_TOO_LARGE', message, requestId: requestId).toResponse(413);

  static Response rateLimited(String message, {String? requestId, int? retryAfterSeconds}) {
    final err = ApiError('RATE_LIMITED', message, requestId: requestId);
    final res = err.toResponse(429);
    if (retryAfterSeconds != null) {
      return res.change(headers: {'retry-after': '$retryAfterSeconds'});
    }
    return res;
  }

  static Response deviceOffline(String message, {String? requestId}) =>
      ApiError('DEVICE_OFFLINE', message, requestId: requestId).toResponse(503);

  static Response timeout(String message, {String? requestId}) =>
      ApiError('TIMEOUT', message, requestId: requestId).toResponse(504);

  static Response internal(String message, {String? requestId}) =>
      ApiError('INTERNAL', message, requestId: requestId).toResponse(500);
}

/// PROTOCOL_V1.md ke frozen enum ka Dart-side mirror — command **result**
/// ke andar use hota hai jab OS/platform koi action support hi nahi
/// karta (P1-06 — "capability-unavailable result, not pretend success").
/// Yeh HTTP error nahi hai, isliye `ApiError` se alag.
const String capabilityUnavailableCode = 'CAPABILITY_UNAVAILABLE';

Map<String, dynamic> capabilityUnavailableResult(String reason) => {
      'error_code': capabilityUnavailableCode,
      'message': reason,
    };
