import 'dart:convert';

import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:control_api/models/api_key.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:control_api/websocket/handlers.dart';

/// Stage 9.2 — system-audio streaming: binary frame routing (type 0x02),
/// audio listener registry, and scope gating (reuses screenView).

class _Sink implements WebSocketSink {
  final List<dynamic> sent = [];
  @override
  void add(dynamic data) => sent.add(data);
  @override
  Future close([int? code, String? reason]) async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Ws implements WebSocketChannel {
  @override
  final _Sink sink = _Sink();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

List<int> _frame(int type, String sessionId, List<int> payload) {
  final id = utf8.encode(sessionId);
  return [type, id.length, ...id, ...payload];
}

void main() {
  group('binary audio frame (type 0x02)', () {
    AppState setup() {
      final s = AppState();
      s.sessionToDevice['t1'] = 'dev_1';
      return s;
    }

    test('a well-formed audio frame reaches audio listeners only', () {
      final s = setup();
      final audioViewer = _Ws(), screenViewer = _Ws();
      s.audioListeners['t1'] = {audioViewer};
      s.screenListeners['t1'] = {screenViewer};
      handleAgentBinaryFrame(s, 'dev_1', _frame(0x02, 't1', [1, 2, 3, 4]));
      expect(audioViewer.sink.sent.single, [1, 2, 3, 4]);
      expect(screenViewer.sink.sent, isEmpty);
    });

    test('audio frames are NOT subject to the screen fps cap', () {
      final s = setup();
      final viewer = _Ws();
      s.audioListeners['t1'] = {viewer};
      final f = _frame(0x02, 't1', [9]);
      handleAgentBinaryFrame(s, 'dev_1', f);
      handleAgentBinaryFrame(s, 'dev_1', f); // turant doosra — audio mein drop nahi hona chahiye
      expect(viewer.sink.sent.length, 2);
    });

    test('a frame for a session not owned by this device is dropped', () {
      final s = setup();
      final viewer = _Ws();
      s.audioListeners['t1'] = {viewer};
      handleAgentBinaryFrame(s, 'dev_2', _frame(0x02, 't1', [1]));
      expect(viewer.sink.sent, isEmpty);
    });

    test('an unknown frame type is dropped without throwing', () {
      final s = setup();
      expect(() => handleAgentBinaryFrame(s, 'dev_1', _frame(0x09, 't1', [1])), returnsNormally);
    });

    test('unregisterListener removes from audioListeners too', () {
      final s = setup();
      final ws = _Ws();
      s.audioListeners['t1'] = {ws};
      s.registerListener(ws, const WsListenerOwner(sessionId: 't1', sessionDeviceId: 'dev_1'));
      s.unregisterListener(ws);
      expect(s.audioListeners['t1'], isEmpty);
    });
  });

  group('audio scope (reuses screenView)', () {
    ApiKeyScope scope({bool screenView = false}) => ApiKeyScope(screenView: screenView);

    test('a key with screen_view can use audio.watch_live and the audio capability', () {
      final s = scope(screenView: true);
      expect(s.allowsAction('audio.watch_live'), isTrue);
      expect(s.allowsAction('audio.stop_live'), isTrue);
      expect(s.allowsCapability('audio'), isTrue);
    });

    test('a key WITHOUT screen_view cannot use audio', () {
      final s = scope();
      expect(s.allowsAction('audio.watch_live'), isFalse);
      expect(s.allowsCapability('audio'), isFalse);
    });
  });
}
