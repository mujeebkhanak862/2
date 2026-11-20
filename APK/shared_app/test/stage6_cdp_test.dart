// Stage 6: CDP client real-Chrome behaviours (items 76-79).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/browser/cdp_client.dart';

/// Real Chrome jaisa fake: `/json/version` browser-level URL deta hai jahan
/// `Page.*` commands REJECT hote hain; sirf **page** target par chalte hain.
class _RealisticChrome {
  late HttpServer server;
  final List<String> pageCommands = [];
  final List<String> browserCommands = [];
  WebSocket? pageSocket;
  bool withPageTarget;
  int jsonNewCalls = 0;
  int listCalls = 0;

  _RealisticChrome({this.withPageTarget = true});

  Future<int> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      final port = server.port;
      if (path == '/json/version') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
            {'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/browser/x'}));
        await req.response.close();
      } else if (path == '/json/list') {
        listCalls++;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode([
          {'type': 'browser', 'url': '', 'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/browser/x'},
          {'type': 'page', 'url': 'devtools://devtools/bundled/x', 'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/page/devtools'},
          if (withPageTarget)
            {'type': 'page', 'url': 'https://example.com', 'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/page/real'},
        ]));
        await req.response.close();
      } else if (path == '/json/new' && req.method == 'PUT') {
        jsonNewCalls++;
        withPageTarget = true;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'type': 'page',
          'url': 'about:blank',
          'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/page/real',
        }));
        await req.response.close();
      } else if (WebSocketTransformer.isUpgradeRequest(req)) {
        final isPage = path == '/devtools/page/real';
        final ws = await WebSocketTransformer.upgrade(req);
        if (isPage) pageSocket = ws;
        ws.listen((raw) {
          final msg = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = msg['method'] as String;
          if (!isPage) {
            browserCommands.add(method);
            // Browser-level target par Page.* / Runtime.* maujood nahi.
            ws.add(jsonEncode({
              'id': msg['id'],
              'error': {'message': "'$method' wasn't found"}
            }));
            return;
          }
          pageCommands.add(method);
          ws.add(jsonEncode({'id': msg['id'], 'result': <String, dynamic>{}}));
        });
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
    return server.port;
  }

  Future<void> stop() async {
    await pageSocket?.close();
    await server.close(force: true);
  }
}

void main() {
  test('connects to the PAGE target, never the browser-level endpoint (item 76)', () async {
    final chrome = _RealisticChrome();
    final port = await chrome.start();
    addTearDown(chrome.stop);

    final client = await CdpClient.connect(port);
    await client.navigate('https://example.com');
    await client.close();

    expect(chrome.browserCommands, isEmpty);
    expect(chrome.pageCommands, containsAll(['Page.enable', 'Runtime.enable', 'Page.navigate']));
  });

  test('skips devtools:// pages when choosing the target', () async {
    final chrome = _RealisticChrome();
    final port = await chrome.start();
    addTearDown(chrome.stop);
    final url = await CdpClient.pickPageTargetUrl(port);
    expect(url, endsWith('/devtools/page/real'));
  });

  test('opens a new tab via PUT /json/new when no page target exists', () async {
    final chrome = _RealisticChrome(withPageTarget: false);
    final port = await chrome.start();
    addTearDown(chrome.stop);

    final client = await CdpClient.connect(port);
    await client.close();
    expect(chrome.jsonNewCalls, 1);
    expect(chrome.pageCommands, contains('Page.enable'));
  });

  test('pending requests fail fast when the browser closes (item 77)', () async {
    final chrome = _RealisticChrome();
    final port = await chrome.start();
    addTearDown(chrome.stop);

    final client = await CdpClient.connect(port);
    expect(client.isClosed, isFalse);
    // Server ab kuch reply nahi karega: socket band karke dekho ki
    // pending future 15s timeout ka intezaar na kare.
    final pendingEval = client.evaluateJavaScript('1+1');
    await chrome.pageSocket!.close();
    await expectLater(
      pendingEval.timeout(const Duration(seconds: 3)),
      throwsA(isA<CdpException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.isClosed, isTrue);
    // Band client par naya command turant fail hota hai.
    await expectLater(client.getTitle(), throwsA(isA<CdpException>()));
  });

  test('connectWhenReady polls until the debug endpoint comes up (item 78)', () async {
    // Pehle ek free port nikalo, uspar server DEER se start karo.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final late = _LateStart(port);
    addTearDown(late.stop);
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), late.start));

    final client = await CdpClient.connectWhenReady(port,
        timeout: const Duration(seconds: 8),
        interval: const Duration(milliseconds: 100));
    await client.close();
    expect(late.chrome.pageCommands, contains('Page.enable'));
  });

  test('connectWhenReady gives a clear error when nothing ever listens', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    await expectLater(
      CdpClient.connectWhenReady(port,
          timeout: const Duration(milliseconds: 600),
          interval: const Duration(milliseconds: 100)),
      throwsA(isA<CdpException>()),
    );
  });
}

/// Fixed port par late start hone wala _RealisticChrome.
class _LateStart {
  final int port;
  final chrome = _RealisticChrome();
  _LateStart(this.port);

  Future<void> start() async {
    chrome.server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    chrome.server.listen((req) async {
      final p = req.uri.path;
      if (p == '/json/list') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode([
          {'type': 'page', 'url': 'about:blank', 'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/page/real'},
        ]));
        await req.response.close();
      } else if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        chrome.pageSocket = ws;
        ws.listen((raw) {
          final msg = jsonDecode(raw as String) as Map<String, dynamic>;
          chrome.pageCommands.add(msg['method'] as String);
          ws.add(jsonEncode({'id': msg['id'], 'result': <String, dynamic>{}}));
        });
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  }

  Future<void> stop() async {
    await chrome.pageSocket?.close();
    try {
      await chrome.server.close(force: true);
    } catch (_) {}
  }
}
