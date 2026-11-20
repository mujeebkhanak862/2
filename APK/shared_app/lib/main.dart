import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'config/credential_store.dart';
import 'dashboard/home_dashboard.dart';
import 'dashboard/pairing_screen.dart';
import 'dashboard/permission_wizard.dart';
import 'platform_channels/platform_channel_bridge.dart';
import 'protocol/agent_connection.dart';
import 'protocol/api_client.dart';
import 'protocol/api_key.dart';
import 'protocol/status_reporter.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const DeviceAgentApp());
}

class DeviceAgentApp extends StatefulWidget {
  const DeviceAgentApp({super.key});

  @override
  State<DeviceAgentApp> createState() => _DeviceAgentAppState();
}

class _DeviceAgentAppState extends State<DeviceAgentApp> {
  // AppConfig.load() khud fail-fast hai (P0-03) — release build mein
  // agar koi non-localhost host plaintext http ke saath diya jaaye to
  // yahan turant `InsecureTransportConfigError` throw hoga.
  final AppConfig _config = AppConfig.load();

  // Item 24: credentials + local policy secure storage mein.
  final CredentialStore _store = SecureCredentialStore();

  // Item 25: dashboard `/owner/*` endpoints use karta hai (device token),
  // isliye alag API key / 'pending-setup' id ki zaroorat nahi.
  late final DeviceAgentApiClient _api = DeviceAgentApiClient(
    baseUrl: _config.controlApiBaseUrl,
    activeApiKeyId: 'owner',
  );

  AgentConnection? _agentConnection;
  StatusReporter? _statusReporter;
  final LockStateBridge _lockStateBridge = LockStateBridge();
  final LocationNetworkBridge _locationBridge = LocationNetworkBridge();
  final BackgroundBridge _backgroundBridge = BackgroundBridge();
  StreamSubscription<String>? _lockStateSubscription;

  bool _booting = true;
  bool _pairingInFlight = false;
  bool _resetting = false;
  String? _deviceId;
  ApiKeyScope? _policy; // Item 29: setup wizard ka device-local ceiling
  String? _pairingError;

  @override
  void initState() {
    super.initState();
    _api.onUnauthorized = _handleUnauthorized;
    _bootstrap();
  }

  /// Item 24: app start par saved credentials se seedha reconnect — naya
  /// device nahi banta.
  Future<void> _bootstrap() async {
    try {
      final creds = await _store.loadCredentials();
      final policy = await _store.loadPolicy();
      if (creds != null) {
        _api.setBearerToken(creds.bearerToken);
        _policy = policy;
        await _startAgent(creds.deviceId, creds.bearerToken);
        _deviceId = creds.deviceId;
      }
    } catch (_) {
      // Storage/connect problem — pairing screen par jaayenge.
    }
    if (!mounted) return;
    setState(() => _booting = false);
  }

  /// Agent connection + status reporting shuru karta hai. Pehle chalta
  /// hua instance ho to use pehle band karta hai (item 37: subscriptions/
  /// sockets leak nahi honge).
  Future<void> _startAgent(String deviceId, String bearerToken) async {
    await _stopAgent();

    final conn = AgentConnection(
      wsBaseUrl: _config.controlApiWsBaseUrl,
      deviceId: deviceId,
      bearerToken: bearerToken,
      localPolicy: _policy,
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
      // Privacy: location tabhi jaati hai jab user ne setup mein allow ki.
      locationAllowed: () => _policy?.location ?? false,
    );
    // Item 33: har (re)connect par poora status dobara.
    conn.onConnected = () => reporter.reportNow(includeLocation: true);
    // Item 53: server ne jaan-bujh kar connection band ki (unpaired /
    // token rotated / auth fail) => dobara pair. 'replaced' = doosra
    // instance chal raha hai; reconnect-ping-pong se bachne ke liye
    // chup-chaap ruk jaate hain.
    conn.onFatalClose = (reason) {
      if (reason == 'replaced') return;
      _handleUnauthorized();
    };

    _agentConnection = conn;
    _statusReporter = reporter;
    await conn.connect();
    reporter.start();

    // Item 85: Android par agent ko background mein zinda rakho.
    if (Platform.isAndroid) {
      try {
        await _backgroundBridge.startService();
      } catch (_) {
        // Foreground service start na ho (OS restriction) — agent
        // foreground mein phir bhi chalta hai; Permission Center se retry.
      }
    }

    _lockStateSubscription = _lockStateBridge.stateChanges().listen(
      (state) => conn.reportStatus(state: state),
      onError: (_) {
        // Platform channel missing — sun'na band; fake state nahi bhejte.
      },
    );
  }

  Future<void> _stopAgent() async {
    await _lockStateSubscription?.cancel();
    _lockStateSubscription = null;
    _statusReporter?.stop();
    _statusReporter = null;
    _agentConnection?.disconnect();
    _agentConnection = null;
    if (Platform.isAndroid) {
      try {
        await _backgroundBridge.stopService();
      } catch (_) {}
    }
  }

  Future<void> _onPaired(String pairingCode, String deviceName) async {
    if (_pairingInFlight) return; // item 37: double-tap = do device nahi
    _pairingInFlight = true;
    try {
      final result = await _api.pairDevice(
        pairingCode: pairingCode,
        deviceName: deviceName,
      );
      final deviceId = result['device_id'] as String;
      final bearerToken = result['bearer_token'] as String;

      _api.setBearerToken(bearerToken);
      // Pehle save (device server par ban chuka hai), phir connect — taaki
      // connect fail ho to bhi retry se doosra device na bane.
      try {
        await _store.saveCredentials(
            StoredCredentials(deviceId: deviceId, bearerToken: bearerToken));
      } catch (_) {
        // Secure storage unavailable — is session mein chalega, restart
        // par dobara pair karna padega.
      }
      await _startAgent(deviceId, bearerToken);

      if (!mounted) return;
      setState(() {
        _deviceId = deviceId;
        _pairingError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _pairingError = 'Pairing server se connect nahi ho saka: $e');
    } finally {
      _pairingInFlight = false;
    }
  }

  /// Item 29: wizard ka scope ab sach mein kaam karta hai — device-local
  /// policy ceiling (save + AgentConnection par enforce).
  Future<void> _onPolicyConfirmed(ApiKeyScope scope) async {
    try {
      await _store.savePolicy(scope);
    } catch (_) {}
    _agentConnection?.localPolicy = scope;
    if (!mounted) return;
    setState(() => _policy = scope);
  }

  /// Item 24: 401 = token invalid/rotated ya device server se hat chuka.
  void _handleUnauthorized() {
    if (_deviceId == null || _resetting) return;
    unawaited(_resetToPairing(
        'Device ka session expire ho gaya ya server se hata diya gaya — dobara pair karein.'));
  }

  Future<void> _resetToPairing(String message) async {
    _resetting = true;
    try {
      await _stopAgent();
      try {
        await _store.clear();
      } catch (_) {}
      _api.clearBearerToken();
      if (!mounted) return;
      setState(() {
        _deviceId = null;
        _policy = null;
        _pairingError = message;
      });
    } finally {
      _resetting = false;
    }
  }

  /// Item 21 (client): server se unpair karke local data clear.
  Future<void> _unpair() async {
    final id = _deviceId;
    if (id != null) {
      try {
        await _api.unpairDevice(id);
      } catch (_) {
        // Server unreachable bhi ho to local reset karte hain.
      }
    }
    await _resetToPairing('Device unpair ho gaya.');
  }

  @override
  void dispose() {
    unawaited(_stopAgent());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_booting) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (_deviceId == null) {
      home = _pairingError != null
          ? _PairingErrorScreen(
              message: _pairingError!,
              onRetry: () => setState(() => _pairingError = null),
            )
          : PairingScreen(onPaired: _onPaired);
    } else if (_policy == null) {
      home = PermissionWizard(
        title: 'Setup Permissions',
        onConfirm: (scope) => unawaited(_onPolicyConfirmed(scope)),
      );
    } else {
      home = HomeDashboard(
        api: _api,
        deviceId: _deviceId!,
        wsBaseUrl: _config.controlApiWsBaseUrl,
        onUnpair: _unpair,
      );
    }

    return MaterialApp(
      title: 'Universal Device Agent',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: home,
    );
  }
}

class _PairingErrorScreen extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _PairingErrorScreen({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}
