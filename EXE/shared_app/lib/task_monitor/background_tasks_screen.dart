import 'package:flutter/material.dart';
import '../protocol/api_client.dart';
import '../protocol/device_status.dart';
import '../theme/app_theme.dart';

/// Section 9 — Locked-Device Background Agent & Messaging.
/// Screen automation ke bina bhi background events/replies ka status
/// dikhata hai, jab device LOCKED ya SCREEN_OFF state mein ho.
class BackgroundTasksScreen extends StatefulWidget {
  final DeviceAgentApiClient api;
  final String deviceId;
  const BackgroundTasksScreen(
      {super.key, required this.api, required this.deviceId});

  @override
  State<BackgroundTasksScreen> createState() => _BackgroundTasksScreenState();
}

class _BackgroundTasksScreenState extends State<BackgroundTasksScreen> {
  DeviceStatus? _status;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final status = await widget.api.getDeviceStatus(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  // Item 36: pehle try/catch nahi tha — server/network error par
  // unhandled exception aur koi feedback nahi.
  Future<void> _sendKeepalive() async {
    // Section 9.3 — background.keepalive action.
    try {
      await widget.api.sendCommand(
        capability: 'background',
        action: 'background.keepalive',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Keepalive failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _status?.state;
    // Section 9.4 — screen control se separate: yahan sirf background-capable
    // actions dikhaye jaate hain, screen automation nahi.
    final canRunBackground = state?.allowsBackgroundActions ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Background Tasks')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(Spacing.lg),
                children: [
                  Card(
                    child: ListTile(
                      leading: Icon(
                        canRunBackground
                            ? Icons.bolt_outlined
                            : Icons.bolt_outlined,
                        color: canRunBackground
                            ? semanticOf(context).onSuccess
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      title: Text('Device state: ${state?.label ?? 'Unknown'}'),
                      subtitle: Text(canRunBackground
                          ? 'Background-capable actions available '
                              '(notifications, keepalive)'
                          : 'Background automation not available in this state'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const SectionHeader('Capabilities'),
                  // Audit Section 11: messaging ko available dikhana galat
                  // hoga jab tak koi provider/app adapter installed nahi —
                  // isliye har cheez ka asli status chip ke saath.
                  _capabilityTile(
                    context,
                    icon: Icons.notifications_none,
                    title: 'Notifications (read)',
                    subtitle: 'notifications.read_event',
                    chip: const StatusChip(
                      label: 'Android only · needs Notification access',
                      tone: StatusTone.warning,
                      icon: Icons.info_outline,
                    ),
                  ),
                  _capabilityTile(
                    context,
                    icon: Icons.chat_bubble_outline,
                    title: 'Messaging (read / reply)',
                    subtitle: 'messaging.get_event · messaging.prepare_reply · '
                        'messaging.send_reply',
                    chip: const StatusChip(
                      label: 'Android · supported apps only (WhatsApp, Telegram, '
                          'Signal, Messenger, SMS) · reply = notification inline-reply',
                      tone: StatusTone.warning,
                      icon: Icons.info_outline,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                    child: Text(
                      'Limits: reply tabhi jab notification abhi dismiss na hui ho; '
                      '"sent" ka matlab app ko handoff hai (delivery confirm nahi). '
                      'Doosre apps/desktop par CAPABILITY_UNAVAILABLE.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SectionHeader('Actions'),
                  ListTile(
                    leading: const Icon(Icons.favorite_border),
                    title: const Text('Keepalive'),
                    subtitle: const Text('Background session ko zinda rakhein'),
                    trailing: FilledButton(
                      onPressed: canRunBackground ? _sendKeepalive : null,
                      child: const Text('Send'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _capabilityTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget chip,
    bool dimmed = false,
  }) {
    return Opacity(
      opacity: dimmed ? 0.75 : 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                      child: Text(title,
                          style: Theme.of(context).textTheme.titleMedium)),
                ],
              ),
              const SizedBox(height: Spacing.xs),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Spacing.sm),
              chip,
            ],
          ),
        ),
      ),
    );
  }
}
