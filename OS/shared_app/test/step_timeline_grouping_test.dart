import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/event_envelope.dart';
import 'package:shared_app/task_monitor/step_timeline.dart';
import 'package:shared_app/theme/app_theme.dart';

TaskProgressEvent _step(int n, String action, {bool ok = true, int? ms}) =>
    TaskProgressEvent(
      timestamp: DateTime.utc(2026, 10, 18, 12, 0, n),
      step: n,
      action: action,
      description: 'do $action',
      result: ok ? 'success' : 'fail',
      durationMs: ms,
    );

void main() {
  group('StepTimeline.group', () {
    test('capabilityOf', () {
      expect(StepTimeline.capabilityOf('input.tap'), 'input');
      expect(StepTimeline.capabilityOf('screen.capture'), 'screen');
      expect(StepTimeline.capabilityOf('plain'), 'plain');
    });

    test('consecutive same-capability steps collapse; order preserved', () {
      final g = StepTimeline.group([
        _step(1, 'input.tap'),
        _step(2, 'input.swipe'),
        _step(3, 'screen.capture'),
        _step(4, 'input.tap'),
      ]);
      expect(g.length, 3);
      expect(g[0].map((s) => s.step), [1, 2]);
      expect(g[1].map((s) => s.step), [3]);
      expect(g[2].map((s) => s.step), [4]);
    });

    test('empty list => no groups', () {
      expect(StepTimeline.group(const []), isEmpty);
    });
  });

  group('StepTimeline widget', () {
    Widget host(List<TaskProgressEvent> steps) => MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: StepTimeline(steps: steps)),
        );

    testWidgets('empty shows waiting text', (tester) async {
      await tester.pumpWidget(host(const []));
      expect(find.textContaining('intezaar'), findsOneWidget);
    });

    testWidgets('group header shows count, total duration and failures', (tester) async {
      await tester.pumpWidget(host([
        _step(1, 'input.tap', ms: 100),
        _step(2, 'input.swipe', ok: false, ms: 250),
        _step(3, 'screen.capture'),
      ]));
      expect(find.text('input · 2 steps'), findsOneWidget);
      expect(find.textContaining('350ms total'), findsOneWidget);
      expect(find.textContaining('1 failed'), findsOneWidget);
      // Failure wala group khula hai => uska step dikhta hai.
      expect(find.textContaining('Step 2:'), findsOneWidget);
    });

    testWidgets('single-step group renders as plain row (no expansion tile)', (tester) async {
      await tester.pumpWidget(host([_step(1, 'screen.capture')]));
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.textContaining('Step 1:'), findsOneWidget);
    });
  });
}
