import 'package:flutter/material.dart';
import 'dart:io' show Platform;

import '../protocol/api_client.dart';
import '../protocol/device_status.dart';
import '../theme/app_theme.dart';
import 'activity_history_screen.dart';
import 'device_status_screen.dart';
import 'diagnostics_screen.dart';
import 'key_manager_screen.dart';
import '../task_monitor/active_tasks_screen.dart';
import '../task_monitor/background_tasks_screen.dart';
import 'permission_center.dart';

/// Section 10.1 ka "My Phone" card + navigation shortcuts — [ View Status ]
/// [ Background Tasks ] [ Activity History ] — plus Key Manager, jo poore
/// dashboard/ module ko ek jagah wire karta hai.
class HomeDashboard extends StatefulWidget {
  final DeviceAgentApiClient api;
  final String deviceId;

  /// Items 30: Tasks screen ko WebSocket base URL chahiye.
  final Uri wsBaseUrl;

  /// Item 21: unpair ka callback (credentials clear + wapas pairing).
  final Future<void> Function()? onUnpair;

  const HomeDashboard({
    super.key,
    required this.api,
    required this.deviceId,
    required this.wsBaseUrl,
    this.onUnpair,
  });

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard> {
  DeviceAgentApiClient get api => widget.api;
  String get deviceId => widget.deviceId;
  Uri get wsBaseUrl => widget.wsBaseUrl;
  Future<void> Function()? get onUnpair => widget.onUnpair;

  DeviceStatus? _status;
  bool _statusFailed = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final st = await api.getDeviceStatus(deviceId);
      if (!mounted) return;
      setState(() {
        _status = st;
        _statusFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _statusFailed = true);
    }
  }

  String get _platformName {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Device';
  }

  IconData get _platformIcon {
    if (Platform.isAndroid) return Icons.smartphone;
    return Icons.computer;
  }

  Widget _headerCard(BuildContext context) {
    final st = _status;
    final battery = st?.batteryPercent;
    final net = st?.network;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(_platformIcon,
                      color: Theme.of(context).colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('This $_platformName device',
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(deviceId,
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loadStatus,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                StatusChip(label: _platformName, tone: StatusTone.neutral, icon: _platformIcon),
                if (st != null)
                  StatusChip(
                    label: st.state.label,
                    tone: toneForState(st.state.label),
                    icon: Icons.circle,
                  )
                else
                  StatusChip(
                    label: _statusFailed ? 'Status unavailable' : 'Checking...',
                    tone: _statusFailed ? StatusTone.danger : StatusTone.neutral,
                  ),
                if (battery != null)
                  StatusChip(
                    label: '$battery%',
                    tone: battery <= 15 ? StatusTone.danger : StatusTone.neutral,
                    icon: battery <= 15 ? Icons.battery_alert : Icons.battery_full,
                  ),
                if (net != null)
                  StatusChip(
                    label: net.connected ? net.connectionType : 'No network',
                    tone: net.connected ? StatusTone.success : StatusTone.danger,
                    icon: net.connected ? Icons.wifi : Icons.wifi_off,
                  ),
              ],
            ),
            const SizedBox(height: Spacing.lg),
            // Quick actions (audit: "quick actions and clearer hierarchy").
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => _open(context,
                        (_) => ActiveTasksScreen(api: api, wsBaseUrl: wsBaseUrl)),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Tasks'),
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () =>
                        _open(context, (_) => KeyManagerScreen(api: api)),
                    icon: const Icon(Icons.vpn_key),
                    label: const Text('API Keys'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, WidgetBuilder builder) {
    Navigator.push(context, MaterialPageRoute(builder: builder))
        .then((_) => _loadStatus());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Universal Device Agent')),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          _headerCard(context),
          const SectionHeader('Manage'),
          _tile(
            context,
            icon: Icons.devices_other,
            title: 'Device Status',
            subtitle: 'Power / Lock / Screen / Location / Network',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    DeviceStatusScreen(api: api, deviceId: deviceId),
              ),
            ),
          ),
          _tile(
            context,
            icon: Icons.play_circle_outline,
            title: 'Tasks',
            subtitle: 'Active/recent tasks — monitor, pause, stop, watch live',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ActiveTasksScreen(api: api, wsBaseUrl: wsBaseUrl),
              ),
            ),
          ),
          _tile(
            context,
            icon: Icons.verified_user_outlined,
            title: 'Permission Center',
            subtitle: 'Screen capture, accessibility, files, contacts, location',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PermissionCenterScreen()),
            ),
          ),
          _tile(
            context,
            icon: Icons.bolt,
            title: 'Background Tasks',
            subtitle: 'Locked-device agent, notifications, messaging (supported apps)',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    BackgroundTasksScreen(api: api, deviceId: deviceId),
              ),
            ),
          ),
          _tile(
            context,
            icon: Icons.history,
            title: 'Activity History',
            subtitle: 'Unified log of everything the agent has done',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ActivityHistoryScreen(api: api, deviceId: deviceId),
              ),
            ),
          ),
          _tile(
            context,
            icon: Icons.vpn_key,
            title: 'API Keys',
            subtitle: 'Create/revoke scoped keys (Master Key Generator)',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => KeyManagerScreen(api: api)),
            ),
          ),
          _tile(
            context,
            icon: Icons.health_and_safety_outlined,
            title: 'Diagnostics',
            subtitle: 'Server, token, HTTPS/WSS aur build checks',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DiagnosticsScreen(
                    api: api, deviceId: deviceId, wsBaseUrl: wsBaseUrl),
              ),
            ),
          ),
          if (onUnpair != null)
            _tile(
              context,
              icon: Icons.link_off,
              title: 'Unpair this device',
              subtitle: 'Server se hatao, saari API keys revoke, local data clear',
              onTap: () async {
                final sure = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Unpair device?'),
                    content: const Text(
                        'Is device ki saari API keys aur tasks server se hat jayenge.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Unpair')),
                    ],
                  ),
                );
                if (sure == true) await onUnpair!();
              },
            ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
