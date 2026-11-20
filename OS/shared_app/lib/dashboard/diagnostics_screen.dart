import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/app_info.dart';
import '../protocol/api_client.dart';
import '../theme/app_theme.dart';

enum _Level { ok, warn, fail, info }

class _Check {
  final String title;
  final _Level level;
  final String detail;
  const _Check(this.title, this.level, this.detail);
}

/// Item 89 (audit: "connection diagnostics and build/environment
/// validation screen"). Har check ka asli result dikhata hai — kuch bhi
/// fake "OK" nahi.
class DiagnosticsScreen extends StatefulWidget {
  final DeviceAgentApiClient api;
  final String deviceId;
  final Uri wsBaseUrl;
  const DiagnosticsScreen({
    super.key,
    required this.api,
    required this.deviceId,
    required this.wsBaseUrl,
  });

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final List<_Check> _checks = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  bool _isLocalHost(Uri u) =>
      u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '::1';

  Future<void> _run() async {
    setState(() {
      _running = true;
      _checks.clear();
    });
    final out = <_Check>[];

    // --- Build / environment ---
    out.add(_Check('App', _Level.info, '$kProductName v$kAppVersion'));
    out.add(_Check(
        'Build mode',
        kReleaseMode ? _Level.ok : _Level.warn,
        kReleaseMode
            ? 'Release'
            : (kDebugMode ? 'Debug — release build nahi hai' : 'Profile')));
    out.add(_Check('Platform', _Level.info,
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'));

    const configured = String.fromEnvironment('CONTROL_API_URL');
    out.add(_Check(
      'CONTROL_API_URL',
      configured.isEmpty && kReleaseMode ? _Level.fail : (configured.isEmpty ? _Level.warn : _Level.ok),
      configured.isEmpty
          ? 'Build mein set nahi (default localhost use ho raha). '
              '--dart-define=CONTROL_API_URL=https://... se build karein.'
          : 'Set',
    ));

    final base = widget.api.baseUrl;
    final secure = base.scheme == 'https' && widget.wsBaseUrl.scheme == 'wss';
    out.add(_Check(
      'Transport security',
      secure ? _Level.ok : (_isLocalHost(base) ? _Level.warn : _Level.fail),
      secure
          ? 'HTTPS + WSS (${base.host})'
          : '${base.scheme}/${widget.wsBaseUrl.scheme} — plaintext. '
              '${_isLocalHost(base) ? 'Sirf local testing ke liye theek.' : 'Public server par HTTPS/WSS zaroori hai.'}',
    ));
    setState(() {
      _checks
        ..clear()
        ..addAll(out);
    });

    // --- Connectivity (asli network calls) ---
    out.add(await _health(base));
    setState(() {
      _checks
        ..clear()
        ..addAll(out);
    });
    out.add(await _auth());
    out.add(await _capabilities());

    if (!mounted) return;
    setState(() {
      _checks
        ..clear()
        ..addAll(out);
      _running = false;
    });
  }

  Future<_Check> _health(Uri base) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final sw = Stopwatch()..start();
    try {
      final req = await client.getUrl(base.resolve('/healthz'));
      final res = await req.close().timeout(const Duration(seconds: 6));
      await res.drain<void>();
      sw.stop();
      if (res.statusCode == 200) {
        return _Check('Server reachable', _Level.ok,
            '/healthz OK · ${sw.elapsedMilliseconds} ms round-trip');
      }
      return _Check('Server reachable', _Level.fail,
          '/healthz ne ${res.statusCode} diya');
    } on TimeoutException {
      return const _Check('Server reachable', _Level.fail, 'Timeout (6s)');
    } catch (e) {
      return _Check('Server reachable', _Level.fail, 'Connect nahi hua: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<_Check> _auth() async {
    try {
      await widget.api.getDeviceStatus(widget.deviceId);
      return const _Check('Device token', _Level.ok, 'Server ne token accept kiya');
    } catch (e) {
      final msg = e.toString();
      final auth = msg.contains('401') || msg.contains('403');
      return _Check('Device token', _Level.fail,
          auth ? 'Token reject hua ($msg) — dobara pair karein.' : 'Check fail: $msg');
    }
  }

  Future<_Check> _capabilities() async {
    try {
      final caps = await widget.api.getCapabilities();
      return _Check('Capability manifest', _Level.ok,
          '${caps.length} capabilities server se mili');
    } catch (e) {
      return _Check('Capability manifest', _Level.fail, 'Fetch fail: $e');
    }
  }

  IconData _icon(_Level l) => switch (l) {
        _Level.ok => Icons.check_circle,
        _Level.warn => Icons.warning_amber_rounded,
        _Level.fail => Icons.error,
        _Level.info => Icons.info_outline,
      };

  StatusTone _tone(_Level l) => switch (l) {
        _Level.ok => StatusTone.success,
        _Level.warn => StatusTone.warning,
        _Level.fail => StatusTone.danger,
        _Level.info => StatusTone.neutral,
      };

  @override
  Widget build(BuildContext context) {
    final sem = semanticOf(context);
    Color colorFor(_Level l) => switch (l) {
          _Level.ok => sem.onSuccess,
          _Level.warn => sem.onWarning,
          _Level.fail => sem.onDanger,
          _Level.info => Theme.of(context).colorScheme.onSurfaceVariant,
        };
    final fails = _checks.where((c) => c.level == _Level.fail).length;
    final warns = _checks.where((c) => c.level == _Level.warn).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Re-run checks',
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          if (_running) const LinearProgressIndicator(),
          if (!_running && _checks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.md),
              child: StatusChip(
                label: fails > 0
                    ? '$fails problem${fails == 1 ? '' : 's'}'
                    : (warns > 0 ? 'OK, $warns warning${warns == 1 ? '' : 's'}' : 'All checks passed'),
                tone: fails > 0
                    ? StatusTone.danger
                    : (warns > 0 ? StatusTone.warning : StatusTone.success),
              ),
            ),
          for (final c in _checks)
            Card(
              child: ListTile(
                leading: Icon(_icon(c.level), color: colorFor(c.level)),
                title: Text(c.title),
                subtitle: Text(c.detail),
                trailing: StatusChip(label: c.level.name.toUpperCase(), tone: _tone(c.level)),
              ),
            ),
        ],
      ),
    );
  }
}
