import 'package:shelf/shelf.dart';

import '../models/api_key.dart';
import '../models/device.dart';
import '../models/errors.dart';
import '../storage/app_state.dart';

/// `Authorization: Bearer <token>` do cheezein ho sakta hai:
///  - Device ka apna bearer token (pairing se mila) — device khud apni
///    keys manage kar raha hai (dashboard app se).
///  - Ek scoped API key ka secret — koi external client (AI agent) is
///    device ko control kar raha hai.
///
/// Middleware dono try karta hai aur jo bhi match kare, request context
/// mein daal deta hai (`context['device']` ya `context['apiKey']`).
/// Route handlers khud decide karte hain unhe kaunsa chahiye tha.
Middleware deviceAuthMiddleware(AppState state) {
  return (Handler innerHandler) {
    return (Request request) async {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return innerHandler(request);
      }
      final token = authHeader.substring('Bearer '.length);

      final device = state.deviceByToken(token);
      if (device != null) {
        return innerHandler(request.change(context: {'device': device}));
      }

      // Item 21/22: constant-time lookup, expired keys reject.
      final key = state.apiKeyBySecret(token);
      if (key != null) {
        key.lastUsedAt = DateTime.now().toUtc();
        return innerHandler(request.change(context: {'apiKey': key}));
      }

      return innerHandler(request);
    };
  };
}

/// PROTOCOL_V1.md canonical error envelope se — pehle yahan ek alag
/// ad-hoc `{"error": message}` shape thi, ab sab routes isi ek function
/// se guzarte hain.
Response unauthorized(String message) => ApiError.unauthorized(message);

/// Items 8/9: generic "yeh request is `deviceId` ke liye authorized hai?"
/// check. Do hi tareeqe valid hain:
///  * device apna hi bearer token (`context['device']`, id match), ya
///  * us hi device ki API key (`context['apiKey']`, `key.deviceId` match).
///
/// Returns `null` agar authorized; warna ready-made 401/403 response.
/// Jaan-bujh kar dusre device ke liye 403 ki jagah 404-jaisa behaviour
/// nahi rakha — yahan device id se hi request aayi hai, isliye 403 theek.
Response? authorizeForDevice(Request request, String deviceId,
    {bool allowApiKey = true}) {
  final device = request.context['device'];
  if (device is Device) {
    return device.id == deviceId
        ? null
        : ApiError.scopeDenied('Yeh device is resource ka owner nahi hai');
  }
  final key = request.context['apiKey'];
  if (allowApiKey && key is ApiKeyRecord) {
    return key.deviceId == deviceId
        ? null
        : ApiError.scopeDenied('Yeh API key is device ki nahi hai');
  }
  return ApiError.unauthorized(
      'Authorization header chahiye (device token${allowApiKey ? ' ya API key' : ''})');
}
