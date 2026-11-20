/// Chrome DevTools Protocol (CDP) client — Windows/Linux ke liye poori
/// browser automation isi ek file se hoti hai (koi native code nahi
/// chahiye control ke liye, sirf `BrowserBridge.launchDesktopBrowser()`
/// se Chrome ko debug-port ke saath launch karna padta hai — Section
/// 6.7 ki spirit ke mutabiq, jahan possible ho wahan native code kam se
/// kam rakhna).
///
/// Flow:
///   1. `BrowserBridge.launchDesktopBrowser()` — native launcher Chrome
///      ko `--remote-debugging-port=9333` ke saath start karta hai.
///   2. `CdpClient.connect()` — `http://localhost:9333/json/version` se
///      WebSocket debugger URL nikaalta hai, phir connect karta hai.
///   3. `navigate`, `click`, `typeText`, `getVisibleText`,
///      `evaluateJavaScript` — sab isi client ke methods hain.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../protocol/device_policy.dart';

class CdpException implements Exception {
  final String message;
  CdpException(this.message);
  @override
  String toString() => 'CdpException: $message';
}

class CdpClient {
  final WebSocket _socket;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  bool _closed = false;

  /// Item 77: socket band ho chuka hai (browser band hua / network). Caller
  /// is client ko cache mein na rakhe — naya connect kare.
  bool get isClosed => _closed;

  void _failAllPending(Object error) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  CdpClient._(this._socket) {
    _socket.listen(
      (raw) {
        if (raw is! String) return;
        final Map<String, dynamic> msg;
        try {
          msg = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        if (msg.containsKey('id')) {
          final id = msg['id'] as int;
          final completer = _pending.remove(id);
          if (completer != null) {
            if (msg.containsKey('error')) {
              completer.completeError(
                  CdpException((msg['error'] as Map)['message'].toString()));
            } else {
              completer.complete(
                  (msg['result'] as Map?)?.cast<String, dynamic>() ?? {});
            }
          }
        } else {
          // CDP events (Page.loadEventFired, waghera) — abhi sirf
          // forward karte hain, koi consumer chahe to sun sakta hai.
          _controller.add(msg);
        }
      },
      onDone: () {
        _closed = true;
        // Item 77: pehle pending requests 15s timeout tak latakti thi.
        _failAllPending(CdpException('Browser connection band ho gaya'));
        if (!_controller.isClosed) _controller.close();
      },
      onError: (Object e) {
        _closed = true;
        _failAllPending(CdpException('Browser connection error: $e'));
      },
      cancelOnError: true,
    );
  }

  /// [port] wahi hona chahiye jo `BrowserBridge.launchDesktopBrowser()` ne
  /// use kiya (default `BrowserBridge.desktopDebugPort`).
  /// Item 76: **page** target se connect karta hai. Pehle `/json/version` ka
  /// `webSocketDebuggerUrl` use hota tha — woh *browser-level* endpoint
  /// hai jahan `Page.*`/`Runtime.*` commands chalte hi nahi (real Chrome par
  /// `Page.enable` hi fail). Ab `/json/list` se pehla `type == "page"`
  /// target (normal tab) chunte hain; na ho to `/json/new` se naya tab.
  static Future<CdpClient> connect(int port) async {
    final wsUrl = await pickPageTargetUrl(port);
    final socket = await WebSocket.connect(wsUrl);
    final client = CdpClient._(socket);
    try {
      await client._send('Page.enable');
      await client._send('Runtime.enable');
    } catch (_) {
      await client.close();
      rethrow;
    }
    return client;
  }

  /// Chrome ke debug endpoint se kisi **page** target ka WebSocket URL.
  /// (Public + static taaki tests seedha check kar sakein.)
  static Future<String> pickPageTargetUrl(int port) async {
    final base = 'http://localhost:$port';
    final res =
        await http.get(Uri.parse('$base/json/list')).timeout(const Duration(seconds: 5));
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body);
      if (list is List) {
        for (final t in list) {
          if (t is Map &&
              t['type'] == 'page' &&
              t['webSocketDebuggerUrl'] is String &&
              !(t['url'] as String? ?? '').startsWith('devtools://')) {
            return t['webSocketDebuggerUrl'] as String;
          }
        }
      }
    }
    // Koi page tab nahi — naya khol lo (Chrome 111+ par PUT zaroori).
    final created = await http
        .put(Uri.parse('$base/json/new?about:blank'))
        .timeout(const Duration(seconds: 5));
    if (created.statusCode == 200) {
      final t = jsonDecode(created.body);
      if (t is Map && t['webSocketDebuggerUrl'] is String) {
        return t['webSocketDebuggerUrl'] as String;
      }
    }
    throw CdpException('Chrome mein koi page target nahi mila');
  }

  /// Item 78: browser launch ke baad debug endpoint ready hone tak poll
  /// karta hai (fixed 800ms sleep cold start par kaafi nahi tha).
  static Future<CdpClient> connectWhenReady(int port,
      {Duration timeout = const Duration(seconds: 12),
      Duration interval = const Duration(milliseconds: 300)}) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        return await connect(port);
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(interval);
      }
    }
    throw CdpException(
        'Browser debug port $port par ready nahi hua (${lastError ?? 'timeout'})');
  }

  Future<Map<String, dynamic>> _send(String method,
      [Map<String, dynamic> params = const {}]) {
    if (_closed) {
      return Future.error(CdpException('Browser connection band hai'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(id);
      throw CdpException('$method timeout ho gaya');
    });
  }

  /// Naye tab/URL par navigate karta hai.
  Future<void> navigate(String url) async {
    // Item 13: CDP-level defence — `file://` navigate + `browser.read`
    // se local files padhi ja sakti thi.
    if (!isAllowedBrowserUrl(url)) {
      throw ArgumentError('Sirf http/https URLs allowed hain');
    }
    await _send('Page.navigate', {'url': url});
  }

  /// Arbitrary JavaScript expression evaluate karta hai — click/type/
  /// read sab isi ke upar bane hain, taaki sirf ek hi low-level primitive
  /// maintain karna pade.
  Future<dynamic> evaluateJavaScript(String expression) async {
    final result = await _send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    final value = result['result'] as Map<String, dynamic>?;
    if (value == null) return null;
    if (result.containsKey('exceptionDetails')) {
      throw CdpException('JS error: ${result['exceptionDetails']}');
    }
    return value['value'];
  }

  /// CSS selector se match hone wale pehle element par click karta hai.
  Future<bool> click(String cssSelector) async {
    final escaped = jsonEncode(cssSelector);
    final result = await evaluateJavaScript('''
      (function() {
        const el = document.querySelector($escaped);
        if (!el) return false;
        el.scrollIntoView({block: 'center'});
        el.click();
        return true;
      })()
    ''');
    return result == true;
  }

  /// **Fix — pehle yeh methods (aur poora `CdpClient` class) kahin bhi
  /// actually use hi nahi hota tha** (dekhein `agent_connection.dart`'s
  /// dispatcher — `browser.click`/`browser.type_text`/`browser.read`
  /// hamesha `BrowserBridge`'s Android-only accessibility methods call
  /// karte the, jo Windows/Linux native side par bilkul implement hi
  /// nahi hain — `NotImplemented` return karte hain). Server ka schema
  /// (`browser.click`'s `text` param) coordinate/CSS-selector nahi,
  /// **visible text** maangta hai — Android jaisa hi contract, taaki
  /// dono platforms ka AI-facing behavior consistent rahe. Yeh method
  /// wahi contract CDP ke zariye implement karta hai: saare
  /// clickable-looking elements mein se, jinka visible text target se
  /// match kare, unme se sabse chhota/specific wala choose karta hai
  /// (taaki koi bada wrapping `<div>` galti se match na ho jo apne andar
  /// bhi target text rakhta ho).
  Future<bool> clickByText(String text) async {
    final escapedText = jsonEncode(text);
    final result = await evaluateJavaScript('''
      (function() {
        const target = $escapedText;
        const candidates = Array.from(document.querySelectorAll(
          'button, a, [role="button"], input[type="submit"], input[type="button"], *'
        )).filter(el => {
          const t = (el.innerText || el.value || el.textContent || '').trim();
          if (!(t.length > 0 && t.includes(target))) return false;
          // Item 79: `offsetParent !== null` fixed/sticky elements ko hide
          // maan leta tha — asli visibility check.
          const cs = window.getComputedStyle(el);
          return el.getClientRects().length > 0 &&
                 cs.visibility !== 'hidden' && cs.display !== 'none';
        }).sort((a, b) => {
          const la = (a.innerText || a.value || a.textContent || '').length;
          const lb = (b.innerText || b.value || b.textContent || '').length;
          return la - lb;
        });
        const el = candidates[0];
        if (!el) return false;
        el.scrollIntoView({block: 'center'});
        el.click();
        return true;
      })()
    ''');
    return result == true;
  }

  /// `typeText()` ka text/label-based counterpart — dekhein `clickByText`
  /// ka doc-comment, same wajah. `field_label` ko `<label>` text,
  /// `aria-label`, `placeholder`, ya `name` attribute se match karta hai
  /// (Android ke label/hint-based field lookup ke barabar).
  Future<bool> typeByLabel(String fieldLabel, String text) async {
    final escapedLabel = jsonEncode(fieldLabel);
    final escapedText = jsonEncode(text);
    final result = await evaluateJavaScript('''
      (function() {
        const label = $escapedLabel;
        let target = null;
        for (const l of Array.from(document.querySelectorAll('label'))) {
          if ((l.innerText || '').trim().includes(label)) {
            target = l.control || (l.htmlFor ? document.getElementById(l.htmlFor) : null);
            if (target) break;
          }
        }
        if (!target) {
          const escLabel = JSON.stringify(label).slice(1, -1);
          target = document.querySelector(
            '[aria-label*="' + escLabel + '"], [placeholder*="' + escLabel +
            '"], [name*="' + escLabel + '"]'
          );
        }
        if (!target) return false;
        const proto = Object.getPrototypeOf(target);
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (setter) { setter.call(target, $escapedText); } else { target.value = $escapedText; }
        target.dispatchEvent(new Event('input', { bubbles: true }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()
    ''');
    return result == true;
  }

  /// CSS selector wale input/textarea mein text set karta hai (React/Vue
  /// jaisi frameworks ke controlled-inputs ke liye native setter + input
  /// event dispatch zaroori hota hai, sirf `.value =` kaafi nahi hota).
  Future<bool> typeText(String cssSelector, String text) async {
    final escapedSelector = jsonEncode(cssSelector);
    final escapedText = jsonEncode(text);
    final result = await evaluateJavaScript('''
      (function() {
        const el = document.querySelector($escapedSelector);
        if (!el) return false;
        const proto = Object.getPrototypeOf(el);
        const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
        if (setter) { setter.call(el, $escapedText); } else { el.value = $escapedText; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()
    ''');
    return result == true;
  }

  /// Poore visible page ka text — AI agent isse page samajh sakta hai
  /// (Android ke `getVisibleText()` ke barabar, wahan accessibility tree
  /// se, yahan DOM se).
  Future<String> getVisibleText() async {
    final result = await evaluateJavaScript('document.body.innerText');
    return result?.toString() ?? '';
  }

  Future<String> getTitle() async {
    final result = await evaluateJavaScript('document.title');
    return result?.toString() ?? '';
  }

  Future<String> getCurrentUrl() async {
    final result = await evaluateJavaScript('window.location.href');
    return result?.toString() ?? '';
  }

  /// Screenshot base64 PNG mein — Task Monitor ke screenshot flow se
  /// consistent shape.
  Future<String?> captureScreenshot() async {
    final result = await _send('Page.captureScreenshot', {'format': 'png'});
    return result['data'] as String?;
  }

  Future<void> close() async {
    await _socket.close();
    await _controller.close();
  }
}
