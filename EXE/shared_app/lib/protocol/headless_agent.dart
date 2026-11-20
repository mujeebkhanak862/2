/// Item 85 (headless Android agent): UI ke bina agent chalane wala Dart
/// entrypoint. Native `HeadlessAgent.kt` ek alag FlutterEngine mein
/// `agentMain` chalata hai jab Activity band ho aur agent mode ON ho.
///
/// `main.dart` ka `_startAgent` aur yeh file **same wiring** rakhte hain
/// (AgentConnection + StatusReporter + lock-state stream) — ek badle to
/// doosri bhi dekhein. UI-only cheezein (pairing screen, dashboard,
/// setup wizard) yahan nahi; credentials/policy secure storage se aate hain.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import '../config/credential_store.dart';
import '../platform_channels/platform_channel_bridge.dart';
import 'agent_connection.dart';
import 'status_reporter.dart';

@pragma('vm:entry-point')
Future<void> agentMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HeadlessAgentRunner().run();
}

class HeadlessAgentRunner {
  static const MethodChannel _control = MethodChannel(ChannelNames.headless);

  final CredentialStore _store;
  final LockStateBridge _lockStateBridge = LockStateBridge();
  final LocationNetworkBridge _locationBridge = LocationNetworkBridge();

  AgentConnection? _conn;
  StatusReporter? _reporter;
  StreamSubscription<String>? _lockSub;

  HeadlessAgentRunner({CredentialStore? store})
      : _store = store ?? SecureCredentialStore();

  bool _stopped = false;

  /// `conn.connect()` throw kare (network/DNS/boot ke waqt) to engine \"running\"
  /// dikhata par kuch karta nahi tha. Ab backoff (2s..60s) ke saath tab tak
  /// retry jab tak connect na ho ya agent band na ho.
  Future<void> _connectWithRetry(AgentConnection conn) async {
    var delay = const Duration(seconds: 2);
    while (!_stopped) {
      try {
        await conn.connect();
        return;
      } catch (_) {
        await Future<void>.delayed(delay);
        if (delay < const Duration(seconds: 60)) delay *= 2;
      }
    }
  }

  /// Native ko batao ki headless engine ki ab zaroorat nahi, aur saaf karo.
  Future<void> _stopSelf() async {
    _stopped = true;
    await _lockSub?.cancel();
    _lockSub = null;
    _reporter?.stop();
    _conn?.disconnect();
    try {
      await _control.invokeMethod<void>('stopSelf');
    } catch (_) {
      // Native channel nahi (test/host) — kuch nahi.
    }
  }

  Future<void> run() async {
    final AppConfig config;
    try {
      config = AppConfig.load();
    } catch (_) {
      // Insecure/missing config — headless mein UI nahi jo error dikhaye.
      await _stopSelf();
      return;
    }

    StoredCredentials? creds;
    try {
      creds = await _store.loadCredentials();
    } catch (_) {
      creds = null;
    }
    if (creds == null) {
      // Device paired nahi — headless agent ka koi matlab nahi.
      await _stopSelf();
      return;
    }
    final policy = await _store.loadPolicy();

    final conn = AgentConnection(
      wsBaseUrl: config.controlApiWsBaseUrl,
      deviceId: creds.deviceId,
      bearerToken: creds.bearerToken,
      localPolicy: policy,
    );
    final reporter = StatusReporter(
      send: ({state, batteryPercent, backgroundActive, network, location}) =>
          conn.reportStatus(
        state: state,
        batteryPercent: batteryPercent,
        backgroundActive: backgroundActive,
        network: network,
        location: location,
      ),
      readLockState: _lockStateBridge.currentState,
      readBattery: _locationBridge.getBatteryPercent,
      readNetwork: _locationBridge.getNetworkStatus,
      readLocation: _locationBridge.getLocation,
      // Privacy: location tabhi jab user ne setup mein allow ki thi.
      locationAllowed: () => policy?.location ?? false,
    );
    conn.onConnected = () => reporter.reportNow(includeLocation: true);
    // 'replaced' = UI engine (ya doosra instance) ab connected hai — chup
    // chaap ruk jao. Baaki fatal close (unpaired/token rotated) => band;
    // dobara pair UI se hi ho sakta hai.
    conn.onFatalClose = (reason) => unawaited(_stopSelf());

    _conn = conn;
    _reporter = reporter;
    await _connectWithRetry(conn);
    if (_stopped) return;
    reporter.start();

    _lockSub = _lockStateBridge.stateChanges().listen(
          (state) => conn.reportStatus(state: state),
          onError: (_) {},
        );
  }
}
