/// Items 30/87: "Active tasks" — pehle `TaskMonitorScreen` kisi screen se
/// reachable hi nahi tha. Yeh list `GET /tasks` se aati hai aur har row
/// tap par us task ka monitor kholti hai.
library;

import 'package:flutter/material.dart';

import '../protocol/api_client.dart';
import '../protocol/task_summary.dart';
import 'task_monitor_screen.dart';

class ActiveTasksScreen extends StatefulWidget {
  final DeviceAgentApiClient api;
  final Uri wsBaseUrl;
  const ActiveTasksScreen({super.key, required this.api, required this.wsBaseUrl});

  @override
  State<ActiveTasksScreen> createState() => _ActiveTasksScreenState();
}

class _ActiveTasksScreenState extends State<ActiveTasksScreen> {
  List<TaskSummary> _tasks = const [];
  bool _loading = true;
  bool _activeOnly = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tasks = await widget.api.getTasks(activeOnly: _activeOnly);
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Tasks load nahi hue: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        actions: [
          IconButton(
            tooltip: _activeOnly ? 'Show all' : 'Show active only',
            icon: Icon(_activeOnly ? Icons.filter_alt : Icons.filter_alt_off),
            onPressed: () {
              setState(() => _activeOnly = !_activeOnly);
              _refresh();
            },
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : _tasks.isEmpty
                  ? const Center(child: Text('Koi task nahi'))
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.separated(
                        itemCount: _tasks.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final t = _tasks[i];
                          return ListTile(
                            leading: Icon(
                              t.state == 'PAUSED'
                                  ? Icons.pause_circle_outline
                                  : t.isActive
                                      ? Icons.play_circle_outline
                                      : Icons.check_circle_outline,
                            ),
                            title: Text('${t.capability} · ${t.state}'),
                            subtitle: Text(t.taskId),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => TaskMonitorScreen(
                                  api: widget.api,
                                  wsBaseUrl: widget.wsBaseUrl,
                                  sessionId: t.taskId,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
