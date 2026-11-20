/// Core Protocol — WebSocket client
///
/// Do WebSocket channels use hote hain (Architecture v4, Section 2.3):
///   WS /sessions/{id}  → task_progress / switch_event jaise DeviceAgentEvent
///   WS /screen/{id}    → "Watch Live" ke baad continuous raw frames
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'event_envelope.dart';

/// P0-03 — defense-in-depth: agar caller galti se http(s) base URL pass
/// kar de (ws/wss ki jagah), yahan hi normalize kar dete hain, taaki
/// `WebSocketChannel.connect()` ko kabhi galat scheme na mile (jo
/// runtime error deta hai). `AppConfig` (config/app_config.dart) mein
/// yeh already sahi se derive hota hai — yeh sirf ek safety net hai.
Uri _asWsUri(Uri baseUrl) {
  if (baseUrl.scheme == 'ws' || baseUrl.scheme == 'wss') return baseUrl;
  final wsScheme = baseUrl.scheme == 'https' ? 'wss' : 'ws';
  return baseUrl.replace(scheme: wsScheme);
}

/// Exponential backoff (1s, 2s, 4s ... max 30s) + jitter.
Duration reconnectDelay(int attempt, {Random? random}) {
  final capped = min(attempt, 5); // 2^5 = 32s ~ cap 30s
  final base = min(30, 1 << capped);
  final jitterMs = (random ?? Random()).nextInt(500);
  return Duration(seconds: base, milliseconds: jitterMs);
}

/// Items 26/27: session events channel.
///
/// Pehle: (1) koi `Authorization` header nahi jata tha — server ab auth
/// maangta hai, isliye kabhi connect nahi hota tha; (2) ek hi baar
/// connect hota tha, aur agar session abhi server ko pata hi nahi (404)
/// ya network gira, to hamesha ke liye band; (3) `onError` handle nahi.
///
/// Ab: bearer token ke saath connect, aur disconnect/error par
/// automatic reconnect with backoff jab tak [close] na ho. Ek hi
/// broadcast stream hamesha `events` se milti hai, reconnect ke beech
/// bhi.
class SessionEventChannel {
  final Uri _wsBaseUrl;
  final String _sessionId;
  final String? _bearerToken;
  final _controller = StreamController<DeviceAgentEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  int _attempt = 0;
  bool _closed = false;

  /// Connection status UI ke liye (true = abhi connected).
  final connected = StreamController<bool>.broadcast();

  SessionEventChannel._(this._wsBaseUrl, this._sessionId, this._bearerToken) {
    _open();
  }

  factory SessionEventChannel.connect(Uri wsBaseUrl, String sessionId,
          {String? bearerToken}) =>
      SessionEventChannel._(wsBaseUrl, sessionId, bearerToken);

  Uri get _uri => _asWsUri(_wsBaseUrl)
      .replace(path: '${_wsBaseUrl.path}/sessions/$_sessionId');

  void _open() {
    if (_closed) return;
    try {
      _channel = IOWebSocketChannel.connect(
        _uri,
        headers: {
          if (_bearerToken != null) 'Authorization': 'Bearer $_bearerToken',
        },
      );
    } catch (_) {
      _scheduleRetry();
      return;
    }
    var gotAnything = false;
    _sub = _channel!.stream.listen(
      (raw) {
        if (!gotAnything) {
          gotAnything = true;
          _attempt = 0;
          if (!connected.isClosed) connected.add(true);
        }
        try {
          final json = jsonDecode(raw as String) as Map<String, dynamic>;
          _controller.add(DeviceAgentEvent.fromJson(json));
        } catch (_) {
          // Malformed/unknown event — ignore, stream chalti rahe.
        }
      },
      onDone: _onDisconnected,
      onError: (_) => _onDisconnected(),
      cancelOnError: true,
    );
  }

  void _onDisconnected() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (!connected.isClosed) connected.add(false);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(reconnectDelay(_attempt++), _open);
  }

  Stream<DeviceAgentEvent> get events => _controller.stream;

  Future<void> close() async {
    _closed = true;
    _retryTimer?.cancel();
    await _sub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    await _controller.close();
    await connected.close();
  }
}

/// Item 26: live screen frames channel (bearer token ke saath).
class LiveScreenChannel {
  /// Lagatar fail hone par itni baar dobara try (backoff 1,2,4,8,15,15... s);
  /// phir `frames` stream error + done deta hai (UI \"stream closed\" dikhata hai).
  static const _maxReconnectAttempts = 8;

  final Uri _uri;
  final String? _bearerToken;
  final StreamController<dynamic> _controller = StreamController<dynamic>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retryTimer;
  bool _closed = false;
  int _failures = 0;

  LiveScreenChannel._(this._uri, this._bearerToken) {
    _open();
  }

  factory LiveScreenChannel.connect(Uri wsBaseUrl, String sessionId,
      {String? bearerToken}) {
    final uri =
        _asWsUri(wsBaseUrl).replace(path: '${wsBaseUrl.path}/screen/$sessionId');
    return LiveScreenChannel._(uri, bearerToken);
  }

  void _open() {
    if (_closed) return;
    final ch = IOWebSocketChannel.connect(
      _uri,
      headers: {
        if (_bearerToken != null) 'Authorization': 'Bearer $_bearerToken',
      },
    );
    _channel = ch;
    // Handshake fail par `ready` error deta hai — sunna zaroori (warna unhandled
    // async error). Kamyab handshake par failure counter reset.
    ch.ready.then((_) {
      if (identical(_channel, ch)) _failures = 0;
    }, onError: (Object _) {});
    _sub = ch.stream.listen(
      (data) {
        if (!_controller.isClosed) _controller.add(data);
      },
      onError: (Object _) => _scheduleReconnect(ch),
      onDone: () => _scheduleReconnect(ch),
      cancelOnError: true,
    );
  }

  void _scheduleReconnect(WebSocketChannel ch) {
    if (_closed || !identical(_channel, ch)) return; // double-schedule guard
    _channel = null;
    _sub = null;
    _failures++;
    if (_failures > _maxReconnectAttempts) {
      _closed = true;
      if (!_controller.isClosed) {
        _controller.addError(StateError('Live stream connection lost'));
        _controller.close();
      }
      return;
    }
    final secs = _failures <= 4 ? (1 << (_failures - 1)) : 15;
    _retryTimer = Timer(Duration(seconds: secs), _open);
  }

  // Item 89: preview (StreamBuilder), fullscreen view aur FPS counter —
  // ek se zyada listener chahiye, isliye broadcast (live frames ke liye
  // drop-when-no-listener theek hai). Reconnect ke beech stream band nahi hoti.
  Stream<dynamic> get frames => _controller.stream;

  Future<void> close() async {
    _closed = true;
    _retryTimer?.cancel();
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      await _channel?.sink.close();
    } catch (_) {}
    if (!_controller.isClosed) await _controller.close();
  }
}
