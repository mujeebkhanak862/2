import 'package:flutter/material.dart';
import '../protocol/api_client.dart';
import 'permission_center.dart';
import '../protocol/device_status.dart';
import '../theme/app_theme.dart';

/// Section 10.1 (Power/Lock/Screen/Connection/Background) + Section 11.4
/// (Location + Network) — ek hi combined card, jaisa doc mein diagram diya
/// gaya hai.
class DeviceStatusScreen extends StatefulWidget {
  final DeviceAgentApiClient api;
  final String deviceId;
  const DeviceStatusScreen(
      {super.key, required this.api, required this.deviceId});

  @override
  State<DeviceStatusScreen> createState() => _DeviceStatusScreenState();
}

class _DeviceStatusScreenState extends State<DeviceStatusScreen> {
  DeviceStatus? _status;
  bool _loading = true;
  String? _error;

  // Item 89 (audit: "permission indicators"): is device par har OS
  // permission ka asli status. `null` = is permission ka silent check
  // possible nahi (OS user-dialog ke bina nahi batata) ya check fail hua.
  final Map<String, bool?> _perms = {};
  List<PermissionItem> _permItems = const [];

  @override
  void initState() {
    super.initState();
    _permItems = defaultPermissionItems();
    _refresh();
  }

  Future<void> _loadPermissions() async {
    final results = <String, bool?>{};
    await Future.wait(_permItems.map((item) async {
      final check = item.check;
      if (check == null) {
        results[item.title] = null;
        return;
      }
      try {
        results[item.title] = await check();
      } catch (_) {
        results[item.title] = null; // platform/channel available nahi
      }
    }));
    if (!mounted) return;
    setState(() {
      _perms
        ..clear()
        ..addAll(results);
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _loadPermissions(); // parallel; status se independent
    try {
      final status = await widget.api.getDeviceStatus(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Section 11.4 — UI ko clearly batana chahiye jab value OS
        // permission/privacy/offline ki wajah se unavailable ho.
        _error = 'Status unavailable (offline, permission, ya platform '
            'limitation ho sakti hai): $e';
        _loading = false;
      });
    }
  }

  Future<void> _locateDevice() async {
    try {
      // Section 4 ka generic pattern reuse: ek "locate" command bhejna
      // location capability ke through.
      await widget.api.sendCommand(
        capability: 'location',
        action: 'location.refresh',
      );
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Locate failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device Status')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.all(Spacing.lg),
                    children: [
                      _stateCard(context),
                      const SectionHeader('Location'),
                      _locationCard(context),
                      const SectionHeader('Network'),
                      _networkCard(context),
                      const SectionHeader('Permissions'),
                      _permissionsCard(context),
                      const SizedBox(height: Spacing.lg),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _refresh,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Refresh Status'),
                            ),
                          ),
                          const SizedBox(width: Spacing.md),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _locateDevice,
                              icon: const Icon(Icons.location_searching),
                              label: const Text('Locate Device'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }

  /// "Device state" (OS: locked/screen-off...) aur "agent connection"
  /// (agent server se connected hai ya nahi) alag cheezein hain — audit
  /// ne dono ka fark dikhane ko kaha; state offline => agent bhi offline.
  Widget _stateCard(BuildContext context) {
    final st = _status!;
    final agentConnected = st.state != DeviceState.offline &&
        st.state != DeviceState.poweredOff;
    final battery = st.batteryPercent;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                StatusChip(
                  label: st.state.label,
                  tone: toneForState(st.state.label),
                  icon: Icons.smartphone,
                ),
                StatusChip(
                  label: agentConnected ? 'Agent connected' : 'Agent disconnected',
                  tone: agentConnected ? StatusTone.success : StatusTone.danger,
                  icon: agentConnected ? Icons.link : Icons.link_off,
                ),
                StatusChip(
                  label: st.backgroundActive ? 'Background active' : 'Background idle',
                  tone: st.backgroundActive ? StatusTone.success : StatusTone.neutral,
                  icon: Icons.bolt_outlined,
                ),
              ],
            ),
            const SizedBox(height: Spacing.lg),
            Row(
              children: [
                Icon(
                  battery == null
                      ? Icons.battery_unknown
                      : (battery <= 15
                          ? Icons.battery_alert
                          : Icons.battery_full),
                  color: battery != null && battery <= 15
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                const SizedBox(width: Spacing.sm),
                Text(battery != null ? 'Battery $battery%' : 'Battery: unavailable',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _locationCard(BuildContext context) {
    final loc = _status!.lastKnownLocation;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: loc == null
            ? const _UnavailableRow(
                icon: Icons.location_off_outlined,
                text: 'Unavailable — permission, privacy setting ya offline '
                    'hone ki wajah se location nahi mili.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('Last known',
                      '${loc.latitude.toStringAsFixed(4)}, ${loc.longitude.toStringAsFixed(4)}'),
                  _row('Accuracy', '±${loc.accuracyM.toStringAsFixed(0)} m'),
                  _row('Source', loc.source),
                  _row('Updated', loc.timestamp.toLocal().toString()),
                ],
              ),
      ),
    );
  }

  Widget _permissionsCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: _permItems.isEmpty
            ? const _UnavailableRow(
                icon: Icons.shield_outlined,
                text: 'Is platform par koi permission item nahi.')
            : Column(
                children: [
                  for (final item in _permItems)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(item.title,
                                style: Theme.of(context).textTheme.bodyMedium),
                          ),
                          _permChip(item),
                        ],
                      ),
                    ),
                  const SizedBox(height: Spacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '"Asked on use" = OS bina dialog ke status nahi batata '
                      '(jaise screen capture consent). Badalne ke liye '
                      'Permission Center kholein.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _permChip(PermissionItem item) {
    if (!_perms.containsKey(item.title)) {
      return const StatusChip(label: 'Checking…', tone: StatusTone.neutral);
    }
    final v = _perms[item.title];
    if (v == true) {
      return const StatusChip(
          label: 'Granted', tone: StatusTone.success, icon: Icons.check_circle);
    }
    if (v == false) {
      return const StatusChip(
          label: 'Not granted', tone: StatusTone.danger, icon: Icons.block);
    }
    return const StatusChip(
        label: 'Asked on use', tone: StatusTone.neutral, icon: Icons.help_outline);
  }

  Widget _networkCard(BuildContext context) {
    final net = _status!.network;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: net == null
            ? const _UnavailableRow(
                icon: Icons.wifi_off,
                text: 'Unavailable — network info report nahi hui.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusChip(
                    label: net.connected ? 'Connected' : 'Disconnected',
                    tone: net.connected ? StatusTone.success : StatusTone.danger,
                    icon: net.connected ? Icons.wifi : Icons.wifi_off,
                  ),
                  const SizedBox(height: Spacing.md),
                  // SSID UI mein masked (Section 11.4).
                  _row('SSID', net.ssid != null ? '••••••••' : '--'),
                  _row('Type', net.connectionType),
                ],
              ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

class _UnavailableRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _UnavailableRow({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: Spacing.md),
          Expanded(child: Text(text)),
        ],
      );
}
