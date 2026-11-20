import 'package:control_api/ai_tools/ai_tool_registry.dart';
import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:test/test.dart';

/// Audit fix (P1-02, Section 13): "AI tool registry ... custom
/// capability policy gating is explicitly incomplete." — deeper dig
/// showed the real gap was bigger than just the AI tool registry: the
/// actual `POST /commands` dispatch gate (`routes/commands.dart`) used
/// `ApiKeyScope.allowsAction()`, which is fail-closed for any action
/// not in its fixed built-in switch — so a registered custom capability
/// could **never** be called by *any* key, no matter what permissions
/// it had. These tests cover the new `ApiKeyScope.customCapabilities` /
/// `allowsCustomCapability()` fix at the model level; `commands.dart`'s
/// wiring is exercised indirectly through existing route tests.
Device _device(String id, {String platform = 'unknown'}) => Device(
      id: id,
      name: 'dev-$id',
      bearerTokenHash: 'irrelevant',
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
      platform: platform,
    );

Map<String, dynamic> _customManifest(String capability, List<String> actionNames) => {
      'capability': capability,
      'actions': actionNames
          .map((n) => {'name': n, 'risk_level': 'medium', 'implemented': true})
          .toList(),
    };

void main() {
  group('ApiKeyScope.allowsCustomCapability', () {
    test('a key with no custom_capabilities allows nothing custom (fail-closed default)', () {
      const scope = ApiKeyScope();
      expect(scope.allowsCustomCapability('home_automation'), isFalse);
    });

    test('a key explicitly granted a custom capability is allowed', () {
      const scope = ApiKeyScope(customCapabilities: {'home_automation'});
      expect(scope.allowsCustomCapability('home_automation'), isTrue);
    });

    test('granting one custom capability does not leak to a different one', () {
      const scope = ApiKeyScope(customCapabilities: {'home_automation'});
      expect(scope.allowsCustomCapability('other_custom_thing'), isFalse);
    });

    test('allowsAction() never allows a custom action name, even if granted via customCapabilities '
        '(action-level vs capability-level are intentionally different gates)', () {
      const scope = ApiKeyScope(customCapabilities: {'home_automation'});
      expect(scope.allowsAction('home_automation.turn_on_lights'), isFalse);
    });

    test('JSON round-trip preserves custom_capabilities', () {
      const scope = ApiKeyScope(customCapabilities: {'a', 'b'});
      final restored = ApiKeyScope.fromJson(scope.toJson());
      expect(restored.customCapabilities, {'a', 'b'});
    });

    test('missing custom_capabilities key in JSON defaults to empty (backward compatible '
        'with API keys created before this fix)', () {
      final scope = ApiKeyScope.fromJson({'screen_view': true});
      expect(scope.customCapabilities, isEmpty);
      expect(scope.screenView, isTrue);
    });
  });

  group('buildAiTools — custom capability policy gating (P1-02)', () {
    test('a key WITHOUT the custom capability granted sees none of its tools', () {
      final tools = buildAiTools(
        device: _device('d1'),
        scope: const ApiKeyScope(), // nothing granted
        customManifests: [_customManifest('home_automation', ['home_automation.turn_on_lights'])],
      );
      expect(tools.where((t) => t.capability == 'home_automation'), isEmpty);
    });

    test('a key WITH the custom capability granted sees its tools', () {
      final tools = buildAiTools(
        device: _device('d1'),
        scope: const ApiKeyScope(customCapabilities: {'home_automation'}),
        customManifests: [_customManifest('home_automation', ['home_automation.turn_on_lights'])],
      );
      expect(tools.map((t) => t.name), contains('home_automation.turn_on_lights'));
    });

    test('granting a DIFFERENT custom capability does not expose this one', () {
      final tools = buildAiTools(
        device: _device('d1'),
        scope: const ApiKeyScope(customCapabilities: {'some_other_capability'}),
        customManifests: [_customManifest('home_automation', ['home_automation.turn_on_lights'])],
      );
      expect(tools, isEmpty);
    });

    test('built-in tools are unaffected by customCapabilities being empty', () {
      final tools = buildAiTools(
        device: _device('d1'),
        scope: const ApiKeyScope(screenView: true),
        customManifests: const [],
      );
      expect(tools.map((t) => t.name), contains('screen.capture'));
    });
  });
}
