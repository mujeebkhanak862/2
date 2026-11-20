import 'package:flutter/material.dart';
import '../protocol/event_envelope.dart';
import '../theme/app_theme.dart';

/// Section 2.2 — "Step timeline: har action ek list mein add hota jaye
/// (action, timestamp, result: success/fail)".
///
/// Item 89: lagataar aane wale same-capability steps (jaise 12 `input.*`)
/// ek group mein collapse hote hain — group header par count, total
/// duration aur failures dikhte hain; sabse naya group aur failure wale
/// groups khule rehte hain. Naya upar.
class StepTimeline extends StatelessWidget {
  final List<TaskProgressEvent> steps;
  const StepTimeline({super.key, required this.steps});

  /// `input.tap` -> `input`.
  static String capabilityOf(String action) {
    final i = action.indexOf('.');
    return i <= 0 ? action : action.substring(0, i);
  }

  /// Lagataar same-capability steps ke groups (purane se naye order mein).
  static List<List<TaskProgressEvent>> group(List<TaskProgressEvent> steps) {
    final groups = <List<TaskProgressEvent>>[];
    for (final s in steps) {
      if (groups.isNotEmpty &&
          capabilityOf(groups.last.last.action) == capabilityOf(s.action)) {
        groups.last.add(s);
      } else {
        groups.add([s]);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('Task shuru hone ka intezaar...')),
      );
    }
    final groups = group(steps);
    return ListView.builder(
      reverse: true, // latest group upar
      itemCount: groups.length,
      itemBuilder: (ctx, i) {
        final idx = groups.length - 1 - i;
        final g = groups[idx];
        final isNewest = idx == groups.length - 1;
        return _GroupTile(
          // Key mein group ki pehli step: naya step aane par bhi expansion state bachi rahe.
          key: ValueKey('grp_${g.first.step}'),
          steps: g,
          initiallyExpanded: isNewest || g.any((s) => !s.succeeded),
        );
      },
    );
  }
}

class _GroupTile extends StatelessWidget {
  final List<TaskProgressEvent> steps;
  final bool initiallyExpanded;
  const _GroupTile({super.key, required this.steps, required this.initiallyExpanded});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = steps.where((s) => !s.succeeded).length;
    final totalMs = steps.fold<int>(0, (a, s) => a + (s.durationMs ?? 0));
    final cap = StepTimeline.capabilityOf(steps.first.action);

    // Single step: group wrapper ki zaroorat nahi — seedha row.
    if (steps.length == 1) {
      return _stepTile(context, steps.first);
    }

    return Card(
      child: Theme(
        // ExpansionTile ke default divider hata do.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: Icon(
            failed == 0 ? Icons.check_circle : Icons.error,
            color: failed == 0 ? semanticOf(context).onSuccess : scheme.error,
          ),
          title: Text('$cap · ${steps.length} steps',
              style: Theme.of(context).textTheme.titleSmall),
          subtitle: Text([
            'Steps ${steps.first.step}–${steps.last.step}',
            if (totalMs > 0) '${totalMs}ms total',
            if (failed > 0) '$failed failed',
          ].join(' · ')),
          // Naya step upar (group ke andar bhi).
          children: [
            for (final s in steps.reversed) _stepTile(context, s, dense: true),
          ],
        ),
      ),
    );
  }

  Widget _stepTile(BuildContext context, TaskProgressEvent step, {bool dense = false}) {
    final scheme = Theme.of(context).colorScheme;
    final ok = step.succeeded;
    final tile = ListTile(
      dense: dense,
      leading: Icon(
        ok ? Icons.check_circle : Icons.error,
        color: ok ? semanticOf(context).onSuccess : scheme.error,
      ),
      title: Text('Step ${step.step}: ${step.description}'),
      subtitle: Text('${step.action} · ${step.timestamp.toLocal()}'
          '${step.durationMs != null ? ' · ${step.durationMs}ms' : ''}'),
      trailing: step.screenshotUrl != null
          ? const Icon(Icons.image_outlined, size: 20)
          : null,
    );
    // Failed step ko highlight (audit: "error states").
    if (ok) return tile;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: tile,
    );
  }
}
