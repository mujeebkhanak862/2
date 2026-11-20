/// Item 28: Permission Center.
///
/// Native OS permissions (MediaProjection consent, Accessibility
/// service, folder picker, Contacts, Location) pehle UI se kabhi
/// request hi nahi hote the — isliye Android par screen capture, input,
/// files, contacts, location sab "permission nahi" ke error se fail
/// hote. Yeh screen har permission ka status dikhati hai aur ek button
/// deti hai jo sahi native flow trigger karta hai.
library;

import 'package:flutter/material.dart';

import 'dart:io' show Platform;

import '../config/autostart.dart';
import '../platform_channels/platform_channel_bridge.dart';
import 'notification_filter_screen.dart';

enum PermissionState { unknown, granted, denied }

/// Ek permission row. `check` (optional) bina user-dialog ke status
/// batata hai; `request` native flow chalata hai aur nateeja deta hai.
class PermissionItem {
  final String title;
  final String description;
  final Future<bool?> Function()? check;
  final Future<bool> Function() request;
  final String actionLabel;

  const PermissionItem({
    required this.title,
    required this.description,
    required this.request,
    this.check,
    this.actionLabel = 'Grant',
  });
}

/// Real native bridges se bani default list.
List<PermissionItem> defaultPermissionItems() {
  final screen = ScreenCaptureBridge();
  final input = InputBridge();
  final files = FilesBridge();
  final contacts = ContactsBridge();
  final location = LocationNetworkBridge();
  final notifications = NotificationsBridge();
  final background = BackgroundBridge();
  final autostart = AutostartService();
  return [
    PermissionItem(
      title: 'Screen capture',
      description:
          'Screenshots aur Watch Live ke liye OS consent (har session mein dobara maanga ja sakta hai).',
      request: () => screen.requestPermission(),
    ),
    PermissionItem(
      title: 'Input control (Accessibility)',
      description:
          'Tap/swipe/typing ke liye. Android par Settings > Accessibility mein service ON karni hoti hai.',
      check: () => input.isEnabled(),
      request: () async {
        if (await input.isEnabled()) return true;
        await input.openPlatformInputSettings();
        return false; // user Settings se wapas aakar "Re-check" dabaye
      },
      actionLabel: 'Open settings',
    ),
    PermissionItem(
      title: 'Files folder',
      description:
          'Default: sirf app sandbox. Zyada access ke liye ek folder chunein.',
      check: () async => (await files.getAllowedRoot()) != null,
      request: () async => (await files.pickDirectory()) != null,
      actionLabel: 'Pick folder',
    ),
    PermissionItem(
      title: 'Contacts',
      description: 'Naam/number list padhne ke liye.',
      check: () => contacts.isAvailable(),
      request: () => contacts.requestPermission(),
    ),
    PermissionItem(
      title: 'Location',
      description: 'Device ki location (Locate Device) ke liye.',
      request: () => location.requestPermission(),
    ),
    if (Platform.isAndroid) ...[
      PermissionItem(
        title: 'Notification access',
        description:
            'Recent notifications padhne ke liye (notifications.read_event). '
            'Sirf memory mein, disk par save nahi hote.',
        check: () => notifications.isEnabled(),
        request: () async {
          if (await notifications.isEnabled()) return true;
          await notifications.openSettings();
          return false; // Settings se wapas aakar "Re-check"
        },
        actionLabel: 'Open settings',
      ),
      PermissionItem(
        title: 'Run in background',
        description:
            'Agent ko background mein chalta rakhne wali foreground service '
            '(ek persistent notification dikhegi).',
        check: () => background.isRunning(),
        request: () => background.startService(),
        actionLabel: 'Start',
      ),
      PermissionItem(
        title: 'Battery: unrestricted',
        description:
            'Battery optimization se exemption — warna Android/OEM agent ko '
            'maar sakta hai.',
        check: () => background.isIgnoringBatteryOptimizations(),
        request: () async {
          if (await background.isIgnoringBatteryOptimizations()) return true;
          await background.requestIgnoreBatteryOptimizations();
          return false;
        },
        actionLabel: 'Allow',
      ),
    ],
    if (autostart.isSupported)
      PermissionItem(
        title: 'Start at login',
        description: 'Computer login par agent apne aap chalu ho.',
        check: () => autostart.isEnabled(),
        request: () => autostart.enable(),
        actionLabel: 'Enable',
      ),
    if (autostart.supportsSystemd)
      PermissionItem(
        title: 'Auto-restart on crash (systemd)',
        description:
            'Linux user service: agent crash ho ya kill ho to apne aap dobara '
            'chalu. "Start at login" ki jagah leta hai (dono ek saath nahi).',
        check: () => autostart.isSystemdEnabled(),
        request: () => autostart.enable(linuxKind: LinuxAutostartKind.systemd),
        actionLabel: 'Enable',
      ),
  ];
}

class PermissionCenterScreen extends StatefulWidget {
  final List<PermissionItem>? items;
  const PermissionCenterScreen({super.key, this.items});

  @override
  State<PermissionCenterScreen> createState() => _PermissionCenterScreenState();
}

class _PermissionCenterScreenState extends State<PermissionCenterScreen> {
  late final List<PermissionItem> _items =
      widget.items ?? defaultPermissionItems();
  late final List<PermissionState> _states =
      List.filled(_items.length, PermissionState.unknown);
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _recheckAll();
  }

  Future<void> _recheckAll() async {
    for (var i = 0; i < _items.length; i++) {
      final check = _items[i].check;
      if (check == null) continue;
      try {
        final ok = await check();
        if (!mounted) return;
        setState(() => _states[i] = ok == true
            ? PermissionState.granted
            : PermissionState.denied);
      } catch (_) {
        // Native side implement nahi / error — unknown hi rehne do.
      }
    }
  }

  Future<void> _request(int i) async {
    setState(() => _busy.add(i));
    try {
      final ok = await _items[i].request();
      if (!mounted) return;
      setState(() =>
          _states[i] = ok ? PermissionState.granted : PermissionState.denied);
    } catch (e) {
      if (!mounted) return;
      setState(() => _states[i] = PermissionState.denied);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_items[i].title}: $e')));
    } finally {
      if (mounted) setState(() => _busy.remove(i));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Permission Center'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-check',
            onPressed: _recheckAll,
          ),
        ],
      ),
      body: ListView.separated(
        itemCount: _items.length + (Platform.isAndroid ? 1 : 0),
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return ListTile(
              leading: const Icon(Icons.filter_alt_outlined),
              title: const Text('Notification apps (filter)'),
              subtitle: const Text('Kin apps ki notifications agent ko mil sakti hain — apps chuniye.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const NotificationFilterScreen())),
            );
          }
          final item = _items[i];
          final state = _states[i];
          return ListTile(
            leading: Icon(
              switch (state) {
                PermissionState.granted => Icons.check_circle,
                PermissionState.denied => Icons.error_outline,
                PermissionState.unknown => Icons.help_outline,
              },
              color: switch (state) {
                PermissionState.granted => Colors.green,
                PermissionState.denied => Colors.orange,
                PermissionState.unknown => Colors.grey,
              },
            ),
            title: Text(item.title),
            subtitle: Text(item.description),
            trailing: _busy.contains(i)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : (state == PermissionState.granted
                    ? const Text('Granted')
                    : FilledButton.tonal(
                        onPressed: () => _request(i),
                        child: Text(item.actionLabel),
                      )),
          );
        },
      ),
    );
  }
}
