import 'package:flutter/material.dart';

import '../platform_channels/platform_channel_bridge.dart';

/// Per-app notification filter (sirf Android). Jis app ka switch OFF hai uski
/// notifications/messaging events agent na buffer karta hai na API se deta hai.
/// Yeh setting sirf is device ke UI se badalti hai — remote API se nahi.
class NotificationFilterScreen extends StatefulWidget {
  const NotificationFilterScreen({super.key});

  @override
  State<NotificationFilterScreen> createState() => _NotificationFilterScreenState();
}

class _NotificationFilterScreenState extends State<NotificationFilterScreen> {
  final _notifications = NotificationsBridge();
  final _apps = AppLauncherBridge();

  List<Map<String, dynamic>> _installed = const [];
  Set<String> _blocked = {};
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final apps = await _apps.listInstalledApps();
      final blocked = await _notifications.getBlockedPackages();
      apps.sort((a, b) => (a['name'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['name'] ?? '').toString().toLowerCase()));
      if (!mounted) return;
      setState(() {
        _installed = apps;
        _blocked = blocked.toSet();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggle(String id, bool allowed) async {
    final next = {..._blocked};
    allowed ? next.remove(id) : next.add(id);
    setState(() => _blocked = next);
    try {
      await _notifications.setBlockedPackages(next.toList());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Filter save nahi hua: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final visible = _installed.where((a) {
      if (q.isEmpty) return true;
      return (a['name'] ?? '').toString().toLowerCase().contains(q) ||
          (a['identifier'] ?? '').toString().toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Notification apps')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!)))
              : Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Switch OFF = us app ki notifications agent ko/API ko nahi milengi. '
                        'Yeh setting sirf yahin se badalti hai.',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'App dhundhein',
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final app = visible[i];
                          final id = (app['identifier'] ?? '').toString();
                          return SwitchListTile(
                            title: Text((app['name'] ?? id).toString()),
                            subtitle: Text(id),
                            value: !_blocked.contains(id),
                            onChanged: (v) => _toggle(id, v),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
