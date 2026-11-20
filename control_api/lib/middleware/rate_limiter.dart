/// P0-05 — Rate Limiting + Abuse Protection.
///
/// Pehle server par koi bhi request-rate limit nahi thi — koi bhi scoped
/// key (ya raw IP) `/commands` ko jitni marzi tez hit kar sakti thi.
/// Yeh middleware ek **in-memory, single-process** sliding-window rate
/// limiter hai.
///
/// **Deployment caveat (jaan-bujh kar yahan likha hai, chhupaya nahi):**
/// counters is process ke RAM mein hain. Agar Control API kabhi
/// multiple instances/replicas mein chalaya jaaye (horizontal scaling),
/// to har instance ki apni alag counting hogi — asal effective limit
/// `configured_limit × instance_count` ho jayega, aur restart par saare
/// counters reset ho jaate hain. Ek single Railway instance (jo
/// HOW_TO_CONNECT.md ka default setup hai) ke liye yeh sahi hai. Agar
/// kabhi multi-instance deployment chahiye ho, to yeh Redis (ya kisi
/// shared store) par migrate karna hoga — abhi ke scope se bahar hai.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../models/api_key.dart';
import '../routes/admin.dart' show isAdminRequest;
import '../models/device.dart';
import '../models/errors.dart';

/// Sliding-window counter, ek identity ke liye.
class _Window {
  DateTime windowStart;
  int count;
  _Window(this.windowStart, this.count);
}

/// Generic sliding-window limiter — kisi bhi "identity string" ke liye
/// reusable (alag-alag limiters alag purposes ke liye instantiate hote
/// hain: general, per-action-class, WS-connection-attempts).
class SlidingWindowLimiter {
  final int maxRequests;
  final Duration window;
  final Map<String, _Window> _state = {};

  SlidingWindowLimiter({required this.maxRequests, required this.window});

  /// `null` agar allowed hai; warna kitne seconds mein retry karna
  /// chahiye.
  int? checkAndIncrement(String identity) {
    final now = DateTime.now();
    final w = _state[identity];
    if (w == null || now.difference(w.windowStart) >= window) {
      _state[identity] = _Window(now, 1);
      return null;
    }
    w.count += 1;
    if (w.count > maxRequests) {
      final elapsed = now.difference(w.windowStart);
      final remaining = window - elapsed;
      return remaining.inSeconds < 1 ? 1 : remaining.inSeconds;
    }
    return null;
  }

  /// Periodic cleanup — bahut purani (expired) windows hata deta hai
  /// taaki `_state` map unbounded grow na kare (long-running process,
  /// bohot saari distinct identities/IPs ho sakti hain over time).
  void sweepExpired() {
    final now = DateTime.now();
    _state.removeWhere((_, w) => now.difference(w.windowStart) >= window * 2);
  }
}

/// Request se ek stable "identity" nikalta hai rate-limiting ke liye —
/// priority order: authenticated API key > authenticated device > IP
/// address (unauthenticated requests, jaise `/devices/pair`, ke liye
/// fallback).
/// Item 17: client IP. Proxy ke peeche (`trustProxy == true`) asli client
/// `X-Forwarded-For` ka **pehla** entry hota hai; warna socket ka
/// remote address. `trustProxy` sirf tab true karo jab server sach mein
/// TLS/reverse proxy ke peeche ho — warna koi bhi header spoof kar ke
/// rate limit bypass kar sakta hai.
String clientIp(Request request, {bool trustProxy = false}) {
  if (trustProxy) {
    final xff = request.headers['x-forwarded-for'];
    if (xff != null && xff.trim().isNotEmpty) {
      final first = xff.split(',').first.trim();
      if (first.isNotEmpty && first.length <= 64) return first;
    }
  }
  final connInfo = request.context['shelf.io.connection_info'];
  if (connInfo is HttpConnectionInfo) return connInfo.remoteAddress.address;
  return 'unknown';
}

String identityFor(Request request, {bool trustProxy = false}) {
  final apiKey = request.context['apiKey'];
  if (apiKey is ApiKeyRecord) return 'key:${apiKey.keyId}';

  final device = request.context['device'];
  if (device is Device) return 'device:${device.id}';

  final ip = clientIp(request, trustProxy: trustProxy);
  return ip == 'unknown' ? 'unknown' : 'ip:$ip';
}

/// Action-class ke hisaab se stricter limits — audit: "screen/file/input
/// ke liye stricter limits". Capability prefix se class decide hota hai.
/// Jo capability yahan list nahi, unke liye sirf general limit lagta hai.
const Map<String, int> _actionClassLimitsPerMinute = {
  'screen': 30, // bandwidth-heavy, streaming
  'input': 40, // automation-abuse-prone (spam taps/swipes)
  'files': 20, // disk I/O + potentially large payloads
  'data': 20, // file transfer — same reasoning as files
};

/// P0-05 middleware — general per-identity limit (sab routes) + stricter
/// per-action-class limit (sirf `POST /commands`, body ke `capability`
/// field se class decide hoti hai).
///
/// **Body replay note:** shelf ka `Request` body ek single-read stream
/// hai. Is middleware ko action-class jaanne ke liye body padhna padta
/// hai, is liye yeh use `request.change(body: ...)` se **replay** karta
/// hai taaki downstream (`commands.dart`'s P0-04 validator) usi body ko
/// dobara pura padh sake — body sirf ek dafa hi HTTP se aata hai, yahan
/// sirf Dart-level mein buffer karke wapas attach kiya ja raha hai.
Middleware rateLimitMiddleware({bool trustProxy = false}) {
  // Web dashboard (admin token) interactive hai — click/drag/typing 120/min se
  // zyada ho jaate the aur 429 aata tha. Valid admin token ke liye alag, bahut
  // bada bucket (galat token wale ab bhi neeche wale strict IP limit se guzarte hain).
  final adminLimiter =
      SlidingWindowLimiter(maxRequests: 6000, window: const Duration(minutes: 1));
  // Item 10/17: unauthenticated pairing endpoint ke liye alag, bahut
  // strict bucket (fake devices ka mass-creation rokne ke liye).
  final pairLimiter =
      SlidingWindowLimiter(maxRequests: 10, window: const Duration(hours: 1));
  final generalLimiter =
      SlidingWindowLimiter(maxRequests: 120, window: const Duration(minutes: 1));
  final actionClassLimiters = {
    for (final entry in _actionClassLimitsPerMinute.entries)
      entry.key: SlidingWindowLimiter(
          maxRequests: entry.value, window: const Duration(minutes: 1)),
  };

  // Har 5 minute mein expired windows sweep karte hain — memory leak na ho.
  Timer.periodic(const Duration(minutes: 5), (_) {
    generalLimiter.sweepExpired();
    pairLimiter.sweepExpired();
    for (final l in actionClassLimiters.values) {
      l.sweepExpired();
    }
  });

  return (Handler inner) {
    return (Request request) async {
      final identity = identityFor(request, trustProxy: trustProxy);

      if (request.method == 'POST' &&
          (request.requestedUri.path == '/devices/pair' ||
              request.requestedUri.path == '/pairing-codes')) {
        final pairRetry = pairLimiter.checkAndIncrement(identity);
        if (pairRetry != null) {
          return ApiError.rateLimited(
              'Pairing rate limit exceed ho gaya — $pairRetry seconds mein retry karein',
              retryAfterSeconds: pairRetry);
        }
      }

      // ---- Admin (valid ADMIN_TOKEN) — fast interactive bucket -----------
      if (isAdminRequest(request)) {
        final adminRetry = adminLimiter.checkAndIncrement('admin');
        if (adminRetry != null) {
          return ApiError.rateLimited(
              'Admin rate limit exceed ho gaya — $adminRetry seconds mein retry karein',
              retryAfterSeconds: adminRetry);
        }
        return inner(request);
      }

      // ---- General per-identity limit (sab routes) -----------------------
      final generalRetry = generalLimiter.checkAndIncrement(identity);
      if (generalRetry != null) {
        return ApiError.rateLimited(
            'Rate limit exceed ho gaya — $generalRetry seconds mein retry karein',
            retryAfterSeconds: generalRetry);
      }

      // ---- Per-action-class limit (sirf POST /commands) -------------------
      if (request.method == 'POST' && request.requestedUri.path == '/commands') {
        final bodyBytes = await request.read().expand((e) => e).toList();
        // Body ko downstream ke liye replay-attach karte hain — chahe
        // parsing yahan fail ho jaaye (malformed JSON), asal error
        // response P0-04 ka validator hi dega (yahan hum sirf
        // action-class *pata karne* ki koshish kar rahe hain, malformed
        // body ko yahan reject nahi karte — woh uska sahi jagah nahi hai).
        final replayedRequest = request.change(body: bodyBytes);

        String? capability;
        try {
          final decoded = jsonDecode(utf8.decode(bodyBytes));
          if (decoded is Map<String, dynamic>) {
            capability = decoded['capability'] as String?;
          }
        } catch (_) {
          // Malformed JSON — action-class pata nahi chal saka, general
          // limit hi apply hoga (jaisa ho chuka hai upar), aur P0-04 ka
          // validator ise turant clean 400 dega.
        }

        if (capability != null && actionClassLimiters.containsKey(capability)) {
          final classRetry =
              actionClassLimiters[capability]!.checkAndIncrement(identity);
          if (classRetry != null) {
            return ApiError.rateLimited(
                '"$capability" capability ke liye rate limit exceed ho gaya — '
                '$classRetry seconds mein retry karein',
                retryAfterSeconds: classRetry);
          }
        }

        return inner(replayedRequest);
      }

      return inner(request);
    };
  };
}
