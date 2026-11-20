import 'package:flutter/material.dart';
import '../protocol/activity_event.dart';
import '../protocol/api_client.dart';
import '../theme/app_theme.dart';

/// Item 89: filters (result / category / task) + redacted detail view.
class ActivityHistoryScreen extends StatefulWidget {
  final DeviceAgentApiClient api;
  final String deviceId;
  const ActivityHistoryScreen(
      {super.key, required this.api, required this.deviceId});

  @override
  State<ActivityHistoryScreen> createState() => _ActivityHistoryScreenState();
}

enum _ResultFilter { all, success, fail, pending }

class _ActivityHistoryScreenState extends State<ActivityHistoryScreen> {
  List<ActivityEvent> _events = [];
  bool _loading = true;
  String? _error;

  _ResultFilter _result = _ResultFilter.all;
  String? _category; // eventType; null = sab
  final TextEditingController _taskFilter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _taskFilter.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final events = await widget.api.getActivityHistory(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _events = events;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'History load nahi ho saki: $e';
        _loading = false;
      });
    }
  }

  IconData _iconFor(String eventType) => switch (eventType) {
        'message_reply' => Icons.reply,
        'location_updated' => Icons.location_on_outlined,
        'network_changed' => Icons.wifi,
        'device_online' => Icons.cloud_done_outlined,
        'device_offline' => Icons.cloud_off_outlined,
        'switch_event' => Icons.swap_horiz,
        _ => Icons.history,
      };

  StatusTone _toneFor(ActivityEvent e) => switch (e.status) {
        'success' => StatusTone.success,
        'fail' => StatusTone.danger,
        _ => StatusTone.warning,
      };

  List<ActivityEvent> get _filtered {
    final task = _taskFilter.text.trim().toLowerCase();
    return _events.where((e) {
      final okResult = switch (_result) {
        _ResultFilter.all => true,
        _ResultFilter.success => e.status == 'success',
        _ResultFilter.fail => e.status == 'fail',
        _ResultFilter.pending => e.status != 'success' && e.status != 'fail',
      };
      if (!okResult) return false;
      if (_category != null && e.eventType != _category) return false;
      if (task.isNotEmpty && !(e.taskId ?? '').toLowerCase().contains(task)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Task id ka sirf shuruaati hissa dikhao (detail view redacted hai).
  String _redactId(String? id) {
    if (id == null || id.isEmpty) return '—';
    if (id.length <= 8) return id;
    return '${id.substring(0, 6)}…${id.substring(id.length - 2)}';
  }

  void _showDetail(ActivityEvent e) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.xl, Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.eventType, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Spacing.sm),
              StatusChip(label: e.status, tone: _toneFor(e)),
              const SizedBox(height: Spacing.lg),
              _kv(ctx, 'When', e.timestamp.toLocal().toString()),
              _kv(ctx, 'Actor', e.actor),
              _kv(ctx, 'Source', e.source ?? '—'),
              _kv(ctx, 'Task', _redactId(e.taskId)),
              _kv(ctx, 'Device', _redactId(e.deviceId)),
              const SizedBox(height: Spacing.md),
              Text(
                'Privacy: IDs chhote kar ke dikhaye gaye hain; message/screen/'
                'file content log mein store hi nahi hota.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(BuildContext ctx, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 72,
                child: Text(k,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
            Expanded(child: Text(v)),
          ],
        ),
      );

  Widget _filters(BuildContext context) {
    final categories = _events.map((e) => e.eventType).toSet().toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.sm, Spacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Spacing.sm,
            children: [
              for (final f in _ResultFilter.values)
                ChoiceChip(
                  label: Text(switch (f) {
                    _ResultFilter.all => 'All',
                    _ResultFilter.success => 'Success',
                    _ResultFilter.fail => 'Failed',
                    _ResultFilter.pending => 'Pending',
                  }),
                  selected: _result == f,
                  onSelected: (_) => setState(() => _result = f),
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          const SizedBox(height: Spacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.sm),
                  child: ChoiceChip(
                    label: const Text('All categories'),
                    selected: _category == null,
                    onSelected: (_) => setState(() => _category = null),
                  ),
                ),
                for (final c in categories)
                  Padding(
                    padding: const EdgeInsets.only(right: Spacing.sm),
                    child: ChoiceChip(
                      label: Text(c),
                      selected: _category == c,
                      onSelected: (_) => setState(() => _category = c),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.sm),
          TextField(
            controller: _taskFilter,
            decoration: const InputDecoration(
                labelText: 'Task id', isDense: true),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _filtered;
    return Scaffold(
      appBar: AppBar(title: const Text('Activity History')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : Column(
                  children: [
                    _filters(context),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.lg, vertical: Spacing.sm),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('${shown.length} of ${_events.length} events',
                            style: Theme.of(context).textTheme.labelMedium),
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _refresh,
                        child: shown.isEmpty
                            ? ListView(children: [
                                Padding(
                                  padding: const EdgeInsets.all(Spacing.xxl),
                                  child: Center(
                                      child: Text(_events.isEmpty
                                          ? 'Koi activity nahi.'
                                          : 'Filter se koi event match nahi hua.')),
                                )
                              ])
                            : ListView.builder(
                                itemCount: shown.length,
                                itemBuilder: (ctx, i) {
                                  final e = shown[i];
                                  return ListTile(
                                    leading: Icon(_iconFor(e.eventType)),
                                    title: Text(e.eventType),
                                    subtitle: Text(
                                        '${e.actor}${e.source != null ? ' · ${e.source}' : ''}'
                                        ' · ${e.timestamp.toLocal()}'),
                                    trailing: StatusChip(
                                        label: e.status, tone: _toneFor(e)),
                                    onTap: () => _showDetail(e),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
