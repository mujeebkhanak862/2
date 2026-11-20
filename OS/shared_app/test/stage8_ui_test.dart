// Stage 8 (item 88/89): theme system, risk levels, honest-unavailable UI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/api_client.dart';
import 'package:shared_app/protocol/api_key.dart';
import 'package:shared_app/task_monitor/background_tasks_screen.dart';
import 'package:shared_app/theme/app_theme.dart';

void main() {
  group('ApiKeyScope risk levels', () {
    test('empty scope = none', () {
      expect(const ApiKeyScope().riskLevel, RiskLevel.none);
      expect(const ApiKeyScope().enabledScopes, isEmpty);
    });

    test('read-only style scopes = low', () {
      expect(const ApiKeyScope(location: true).riskLevel, RiskLevel.low);
      expect(const ApiKeyScope(screenView: true, location: true).riskLevel,
          RiskLevel.low);
    });

    test('files only = medium; touch input alone = medium', () {
      expect(const ApiKeyScope(files: true).riskLevel, RiskLevel.medium);
      expect(const ApiKeyScope(touchInput: true).riskLevel, RiskLevel.medium);
    });

    test('touch + keyboard = high; isHighRisk combo = high', () {
      expect(const ApiKeyScope(touchInput: true, keyboardText: true).riskLevel,
          RiskLevel.high);
      expect(
          const ApiKeyScope(touchInput: true, files: true, dataTransfer: true)
              .riskLevel,
          RiskLevel.high);
    });

    test('messaging reply (weight 3) + one more = high', () {
      expect(const ApiKeyScope(messagingReply: true, files: true).riskLevel,
          RiskLevel.high);
    });

    test('every enabled scope has a human description', () {
      const all = ApiKeyScope(
        screenView: true, touchInput: true, keyboardText: true, files: true,
        apps: true, browser: true, clipboard: true, dataTransfer: true,
        contacts: true, location: true, background: true, messagingReply: true,
        customCapabilities: {'my.tool'},
      );
      final infos = all.enabledScopes;
      expect(infos.length, 13);
      for (final i in infos) {
        expect(i.description.trim(), isNotEmpty);
      }
    });
  });

  group('ApiKey model', () {
    test('parses last_used_at / expires_at', () {
      final k = ApiKey.fromJson({
        'key_id': 'k1',
        'label': 'L',
        'scope': <String, dynamic>{},
        'created_at': '2026-10-01T00:00:00Z',
        'enabled': true,
        'last_used_at': '2026-10-05T10:00:00Z',
        'expires_at': '2000-01-01T00:00:00Z',
      });
      expect(k.lastUsedAt, DateTime.utc(2026, 10, 5, 10));
      expect(k.isExpired, isTrue);
    });

    test('missing optional fields are null / not expired', () {
      final k = ApiKey.fromJson({
        'key_id': 'k2',
        'label': 'L',
        'scope': <String, dynamic>{},
        'created_at': '2026-10-01T00:00:00Z',
      });
      expect(k.lastUsedAt, isNull);
      expect(k.expiresAt, isNull);
      expect(k.isExpired, isFalse);
    });
  });

  group('Theme', () {
    test('light and dark build with semantic extension', () {
      for (final t in [AppTheme.light(), AppTheme.dark()]) {
        expect(t.useMaterial3, isTrue);
        expect(t.extension<SemanticColors>(), isNotNull);
      }
      expect(AppTheme.dark().brightness, Brightness.dark);
    });

    test('toneForState mapping', () {
      expect(toneForState('Online'), StatusTone.success);
      expect(toneForState('Locked'), StatusTone.warning);
      expect(toneForState('Sleeping'), StatusTone.neutral);
      expect(toneForState('Offline'), StatusTone.danger);
    });

    testWidgets('StatusChip renders label and icon', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: StatusChip(label: 'Online', tone: StatusTone.success, icon: Icons.circle),
        ),
      ));
      expect(find.text('Online'), findsOneWidget);
      expect(find.byIcon(Icons.circle), findsOneWidget);
    });
  });

  testWidgets('Background Tasks states messaging scope + limits honestly',
      (tester) async {
    final api = DeviceAgentApiClient(
        baseUrl: Uri.parse('http://127.0.0.1:1'), activeApiKeyId: 'owner');
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: BackgroundTasksScreen(api: api, deviceId: 'device_x'),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.textContaining('supported apps only'), findsOneWidget);
    expect(find.textContaining('CAPABILITY_UNAVAILABLE'), findsOneWidget);
  });
}
