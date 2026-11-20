import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/dashboard/permission_wizard.dart';
import 'package:shared_app/protocol/api_key.dart';
import 'package:shared_app/protocol/capability_manifest.dart';

/// Follow-up fix (P1-02): Permission Wizard ab custom capabilities ke
/// liye ek real UI section deta hai (pehle sirf data preserve hoti thi,
/// koi toggle nahi tha).
void main() {
  final weatherManifest = CapabilityManifest(
    capability: 'weather',
    version: '1.0.0',
    actions: const [
      CapabilityAction(
          name: 'weather.get_forecast', paramsSchema: {}, riskLevel: RiskLevel.low),
    ],
    requiredPermission: 'weather.access',
    defaultPolicy: 'ask',
    isCustom: true,
  );

  testWidgets('no custom-capabilities section when none are available', (tester) async {
    ApiKeyScope? confirmed;
    await tester.pumpWidget(MaterialApp(
      home: PermissionWizard(onConfirm: (s) => confirmed = s),
    ));

    expect(find.text('Custom Capabilities'), findsNothing);

    await tester.tap(find.text('Confirm Permissions'));
    await tester.pumpAndSettle();
    expect(confirmed!.customCapabilities, isEmpty);
  });

  testWidgets('shows a checkbox per available custom capability, unchecked by default',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PermissionWizard(
        availableCustomCapabilities: [weatherManifest],
        onConfirm: (_) {},
      ),
    ));

    expect(find.text('Custom Capabilities'), findsOneWidget);
    expect(find.text('weather'), findsOneWidget);
    final checkbox =
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).first);
    expect(checkbox.value, isFalse);
  });

  testWidgets('checking a custom capability includes it in the confirmed scope', (tester) async {
    ApiKeyScope? confirmed;
    await tester.pumpWidget(MaterialApp(
      home: PermissionWizard(
        availableCustomCapabilities: [weatherManifest],
        onConfirm: (s) => confirmed = s,
      ),
    ));

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.tap(find.text('Confirm Permissions'));
    await tester.pumpAndSettle();

    expect(confirmed!.customCapabilities, {'weather'});
  });

  testWidgets('an already-granted custom capability starts checked (edit-mode round-trip)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PermissionWizard(
        initialScope: const ApiKeyScope(customCapabilities: {'weather'}),
        availableCustomCapabilities: [weatherManifest],
        onConfirm: (_) {},
      ),
    ));

    final checkbox =
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).first);
    expect(checkbox.value, isTrue);
  });

  testWidgets('unchecking an already-granted capability removes it on confirm', (tester) async {
    ApiKeyScope? confirmed;
    await tester.pumpWidget(MaterialApp(
      home: PermissionWizard(
        initialScope: const ApiKeyScope(customCapabilities: {'weather'}),
        availableCustomCapabilities: [weatherManifest],
        onConfirm: (s) => confirmed = s,
      ),
    ));

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.tap(find.text('Confirm Permissions'));
    await tester.pumpAndSettle();

    expect(confirmed!.customCapabilities, isEmpty);
  });
}
