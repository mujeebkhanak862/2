/// Pairing screen — Items 35/37.
///
/// Pehle: sirf ek static icon (asli QR nahi), device naam hamesha "My
/// Device" (TODO), aur button `onPaired` ko bina rok-tok baar-baar
/// call kar sakta tha (double-tap = do device). Ab: asli QR
/// (`qr_flutter`), user device ka naam khud likhta hai, aur pairing
/// ke dauran button disabled rehta hai.
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform_channels/platform_channel_bridge.dart';

class PairingScreen extends StatefulWidget {
  /// Pairing code aur user ka chuna hua device name.
  final Future<void> Function(String pairingCode, String deviceName) onPaired;
  final String defaultDeviceName;

  const PairingScreen({
    super.key,
    required this.onPaired,
    this.defaultDeviceName = 'My Device',
  });

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _pairingChannel = NativeCapabilityChannel(ChannelNames.pairing);
  late final TextEditingController _nameController =
      TextEditingController(text: widget.defaultDeviceName);
  // Item 10: server-issued one-time code (server par REQUIRE_PAIRING_CODE
  // on ho to zaroori; warna khali chhod sakte hain).
  final TextEditingController _serverCodeController = TextEditingController();
  String? _pairingCode;
  bool _loading = true;
  bool _pairing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startPairing();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _serverCodeController.dispose();
    super.dispose();
  }

  Future<void> _startPairing() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = await _pairingChannel.invoke<String>('generatePairingCode');
      if (!mounted) return;
      setState(() {
        _pairingCode = code;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Pairing shuru nahi ho saki: $e';
        _loading = false;
      });
    }
  }

  Future<void> _continue() async {
    final generated = _pairingCode;
    final serverCode = _serverCodeController.text.trim();
    // Server code diya ho to wahi bhejte hain; warna purana (legacy) flow.
    final code = serverCode.isNotEmpty ? serverCode : generated;
    final name = _nameController.text.trim();
    if (code == null || _pairing) return;
    if (name.isEmpty || name.length > 100) {
      setState(() => _error = 'Device ka naam 1 se 100 characters ke beech likhein');
      return;
    }
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      await widget.onPaired(code, name);
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair This Device')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _loading
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Item 89: onboarding — pehli baar aane waale ko 3 steps.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Card(
                        child: ExpansionTile(
                          initiallyExpanded: true,
                          leading: Image.asset('assets/brand/logo.png',
                              width: 36, height: 36),
                          title: const Text('Universal Device Agent'),
                          subtitle: const Text('3 steps mein shuru karein'),
                          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          expandedAlignment: Alignment.centerLeft,
                          children: const [
                            Text('1. Is device ko ek naam dein aur (agar server maange) '
                                'owner se mila Server pairing code daalein.'),
                            SizedBox(height: 8),
                            Text('2. Permissions chunein — sirf wahi jo aap dena chahte hain; '
                                'baad mein Permission Center se badal sakte hain.'),
                            SizedBox(height: 8),
                            Text('3. API Keys banayein: har key ka alag, seemit access hota hai.'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_pairingCode != null)
                      QrImageView(
                        data: _pairingCode!,
                        size: 200,
                        backgroundColor: Colors.white,
                      ),
                    const SizedBox(height: 16),
                    Text('Pairing code: ${_pairingCode ?? '—'}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 24),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: TextField(
                        controller: _nameController,
                        maxLength: 100,
                        decoration: const InputDecoration(
                          labelText: 'Device name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: TextField(
                        controller: _serverCodeController,
                        maxLength: 12,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Server pairing code (e.g. ABCD-EFGH)',
                          helperText:
                              'Owner se mila ek-baar-use code (5 min valid). '
                              'Server par zaroori na ho to khali chhodein.',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 16),
                    if (_pairingCode == null)
                      FilledButton(
                          onPressed: _startPairing, child: const Text('Retry'))
                    else
                      FilledButton(
                        onPressed: _pairing ? null : _continue,
                        child: _pairing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Text("I've scanned it — Continue"),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
