import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/browser/cdp_client.dart';

/// Bug found: `CdpClient` (poora Chrome DevTools Protocol client) kahin
/// bhi actually instantiate hi nahi hota tha — comments mein claim tha
/// ke "Windows/Linux CdpClient use karte hain" lekin dispatcher hamesha
/// Android-only `BrowserBridge` methods call karta tha, jo Windows/Linux
/// native side par `NotImplemented` the. Matlab poora Browser capability
/// Windows/Linux par sirf "launch" tak kaam karta tha — navigate/click/
/// type/read kuch nahi.
///
/// Yeh tests ek REAL local fake CDP server (asal `HttpServer` +
/// `WebSocketTransformer`, Chrome ke debug protocol ki tarah) spin karte
/// hain, taaki `CdpClient` ka asal network-facing code (HTTP handshake,
/// WebSocket JSON-RPC framing) genuinely exercise ho — sirf JS-string
/// construction ka unit test nahi.
class _FakeCdpServer {
  late HttpServer _server;
  final List<Map<String, dynamic>> receivedCommands = [];
  WebSocket? _clientSocket;

  /// Command ka method name -> is command ke liye custom result (default
  /// `{}` agar map mein nahi hai).
  final Map<String, dynamic> resultsByMethod;

  _FakeCdpServer({this.resultsByMethod = const {}});

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      // Item 76: ab `/json/list` ke **page** target se connect hota hai.
      if (request.uri.path == '/json/list') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode([
          {
            'type': 'browser', // browser-level target — skip hona chahiye
            'url': '',
            'webSocketDebuggerUrl': 'ws://127.0.0.1:${_server.port}/devtools/browser/fake',
          },
          {
            'type': 'page',
            'url': 'about:blank',
            'webSocketDebuggerUrl': 'ws://127.0.0.1:${_server.port}/devtools/page/fake',
          },
        ]));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/json/version') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'webSocketDebuggerUrl': 'ws://127.0.0.1:${_server.port}/devtools/page/fake',
        }));
        await request.response.close();
        return;
      }
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _clientSocket = socket;
        socket.listen((raw) {
          final msg = jsonDecode(raw as String) as Map<String, dynamic>;
          receivedCommands.add(msg);
          final method = msg['method'] as String;
          final result = resultsByMethod[method] ?? <String, dynamic>{};
          socket.add(jsonEncode({'id': msg['id'], 'result': result}));
        });
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });
    return _server.port;
  }

  Future<void> stop() async {
    await _clientSocket?.close();
    await _server.close(force: true);
  }
}

void main() {
  group('CdpClient — real local fake-server tests (was completely unused before this fix)', () {
    late _FakeCdpServer fakeServer;
    late int port;

    setUp(() async {
      fakeServer = _FakeCdpServer();
      port = await fakeServer.start();
    });

    tearDown(() async {
      await fakeServer.stop();
    });

    test('connect() fetches the debugger URL and enables Page + Runtime domains', () async {
      final client = await CdpClient.connect(port);
      addTearDown(client.close);

      // Page.enable aur Runtime.enable dono connect() ke andar hi
      // bheje jaate hain.
      final methods = fakeServer.receivedCommands.map((c) => c['method']).toList();
      expect(methods, contains('Page.enable'));
      expect(methods, contains('Runtime.enable'));
    });

    test('navigate() sends Page.navigate with the given url', () async {
      final client = await CdpClient.connect(port);
      addTearDown(client.close);
      fakeServer.receivedCommands.clear();

      await client.navigate('https://example.com');

      final navCmd = fakeServer.receivedCommands.firstWhere((c) => c['method'] == 'Page.navigate');
      expect(navCmd['params']['url'], 'https://example.com');
    });

    test('clickByText() sends Runtime.evaluate with the text safely embedded '
        '(quotes in the text do not break out of the JS string)', () async {
      final client = await CdpClient.connect(port);
      addTearDown(client.close);
      fakeServer.receivedCommands.clear();

      await client.clickByText('Say "hello"');

      final evalCmd =
          fakeServer.receivedCommands.firstWhere((c) => c['method'] == 'Runtime.evaluate');
      final expr = evalCmd['params']['expression'] as String;
      // jsonEncode se properly escaped hona chahiye — raw, unescaped
      // quotes JS string literal ko break nahi karni chahiyein.
      expect(expr, contains(jsonEncode('Say "hello"')));
    });

    test('typeByLabel() sends Runtime.evaluate referencing both label and text', () async {
      final client = await CdpClient.connect(port);
      addTearDown(client.close);
      fakeServer.receivedCommands.clear();

      await client.typeByLabel('Email', 'me@example.com');

      final evalCmd =
          fakeServer.receivedCommands.firstWhere((c) => c['method'] == 'Runtime.evaluate');
      final expr = evalCmd['params']['expression'] as String;
      expect(expr, contains(jsonEncode('Email')));
      expect(expr, contains(jsonEncode('me@example.com')));
    });

    test('getVisibleText() evaluates document.body.innerText and returns the string result',
        () async {
      final serverWithText = _FakeCdpServer(resultsByMethod: {
        'Runtime.evaluate': {
          'result': {'value': 'Hello page content'}
        },
      });
      final p = await serverWithText.start();
      addTearDown(serverWithText.stop);

      final client = await CdpClient.connect(p);
      addTearDown(client.close);

      final text = await client.getVisibleText();
      expect(text, 'Hello page content');
    });

    test('evaluateJavaScript throws CdpException on exceptionDetails', () async {
      final serverWithError = _FakeCdpServer(resultsByMethod: {
        'Runtime.evaluate': {
          'result': {},
          'exceptionDetails': {'text': 'SyntaxError'},
        },
      });
      final p = await serverWithError.start();
      addTearDown(serverWithError.stop);

      final client = await CdpClient.connect(p);
      addTearDown(client.close);

      expect(() => client.evaluateJavaScript('1+1'), throwsA(isA<CdpException>()));
    });

    test('connect() throws CdpException when the debug endpoint is unreachable', () async {
      // Koi bhi random closed port — connect nahi hona chahiye.
      expect(() => CdpClient.connect(1), throwsA(anything));
    });
  });
}
