import 'package:control_api/ai_tools/ai_tool_registry.dart';
import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/device.dart';
import 'package:test/test.dart';

Device _device({required String platform}) => Device(
      id: 'device_1',
      name: 'Test Device',
      bearerTokenHash: 'irrelevant-for-these-tests',
      platform: platform,
      pairedAt: DateTime.now().toUtc(),
      lastSeenAt: DateTime.now().toUtc(),
    );

const _fullScope = ApiKeyScope(
  screenView: true,
  touchInput: true,
  keyboardText: true,
  files: true,
  apps: true,
  browser: true,
  clipboard: true,
  dataTransfer: true,
  contacts: true,
  location: true,
  background: true,
  messagingReply: true,
);

void main() {
  group('AI Tool Registry — device-aware filtering (P1-02)', () {
    test('a Windows device never gets contacts.list ("Unsupported device action '
        'AI tool list mein na aaye")', () {
      final tools = buildAiTools(
          device: _device(platform: 'windows'), scope: _fullScope, customManifests: const []);
      expect(tools.any((t) => t.name == 'contacts.list'), isFalse);
    });

    test('an Android device does get contacts.list', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'), scope: _fullScope, customManifests: const []);
      expect(tools.any((t) => t.name == 'contacts.list'), isTrue);
    });

    test('a Linux device never gets Android-only messaging/notification actions', () {
      final tools = buildAiTools(
          device: _device(platform: 'linux'), scope: _fullScope, customManifests: const []);
      expect(tools.any((t) => t.name.startsWith('messaging.')), isFalse);
      expect(tools.any((t) => t.name == 'notifications.read_event'), isFalse);
    });

    test('an unknown-platform (legacy) device gets everything the scope allows '
        '(permissive fallback, not restrictive)', () {
      final tools = buildAiTools(
          device: _device(platform: 'unknown'), scope: _fullScope, customManifests: const []);
      expect(tools.any((t) => t.name == 'contacts.list'), isTrue);
      expect(tools.any((t) => t.name.startsWith('messaging.')), isTrue);
    });

    test('cross-platform actions (e.g. input.tap) appear for every known platform', () {
      for (final platform in ['android', 'windows', 'linux']) {
        final tools = buildAiTools(
            device: _device(platform: platform), scope: _fullScope, customManifests: const []);
        expect(tools.any((t) => t.name == 'input.tap'), isTrue,
            reason: 'input.tap should be available on $platform');
      }
    });
  });

  group('AI Tool Registry — policy-aware filtering (P1-02)', () {
    test('an empty scope produces no built-in tools at all '
        '("denied scope tool unavailable")', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'),
          scope: const ApiKeyScope(),
          customManifests: const []);
      expect(tools, isEmpty);
    });

    test('a screen-only key only gets screen.* tools', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'),
          scope: const ApiKeyScope(screenView: true),
          customManifests: const []);
      expect(tools, isNotEmpty);
      expect(tools.every((t) => t.name.startsWith('screen.')), isTrue);
      expect(tools.any((t) => t.name == 'input.tap'), isFalse);
    });

    test('policy change updates the tool list ("policy change updates tools")', () {
      final device = _device(platform: 'android');
      final before = buildAiTools(
          device: device, scope: const ApiKeyScope(screenView: true), customManifests: const []);
      final after = buildAiTools(
          device: device,
          scope: const ApiKeyScope(screenView: true, touchInput: true),
          customManifests: const []);
      expect(before.any((t) => t.name == 'input.tap'), isFalse);
      expect(after.any((t) => t.name == 'input.tap'), isTrue);
    });

    test('messagingReply gates messaging.send_reply specifically (not the whole background scope)',
        () {
      final withoutReply = buildAiTools(
          device: _device(platform: 'android'),
          scope: const ApiKeyScope(background: true),
          customManifests: const []);
      expect(withoutReply.any((t) => t.name == 'messaging.send_reply'), isFalse);

      final withReply = buildAiTools(
          device: _device(platform: 'android'),
          scope: const ApiKeyScope(background: true, messagingReply: true),
          customManifests: const []);
      expect(withReply.any((t) => t.name == 'messaging.send_reply'), isTrue);
    });
  });

  group('AI Tool Registry — tool shape (P1-02)', () {
    test('every returned tool has a non-empty description', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'), scope: _fullScope, customManifests: const []);
      for (final tool in tools) {
        expect(tool.description, isNotEmpty);
      }
    });

    test('input_schema is a valid object shape with type "object"', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'), scope: _fullScope, customManifests: const []);
      final tap = tools.firstWhere((t) => t.name == 'input.tap');
      expect(tap.inputSchema['type'], 'object');
      final properties = tap.inputSchema['properties'] as Map;
      expect(properties.containsKey('x'), isTrue);
      expect(properties.containsKey('y'), isTrue);
      expect(tap.inputSchema['required'], ['x', 'y']);
    });

    test('requiredOneOf schemas surface as required_one_of in the tool input_schema', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'), scope: _fullScope, customManifests: const []);
      final filesRead = tools.firstWhere((t) => t.name == 'files.read');
      expect(filesRead.inputSchema['required_one_of'], ['path', 'target_path']);
    });
  });

  group('AI Tool Registry — custom capabilities (P1-02)', () {
    Map<String, dynamic> _customManifest({List<String>? platformSupport}) => {
          'capability': 'weather',
          'version': '1.0.0',
          'default_policy': 'ask',
          if (platformSupport != null) 'platform_support': platformSupport,
          'actions': [
            {
              'name': 'weather.get_forecast',
              'risk_level': 'low',
              'params_schema': {
                'required': ['city'],
                'properties': {
                  'city': {'type': 'string'}
                },
              },
            },
          ],
        };

    test('a custom capability WITHOUT explicit grant is now excluded (P1-02 security fix — '
        'this used to be "appears regardless of scope", which was exactly the audit-flagged '
        'gap: any key could use any registered custom capability)', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'),
          scope: const ApiKeyScope(), // no custom_capabilities granted
          customManifests: [_customManifest()]);
      expect(tools.any((t) => t.name == 'weather.get_forecast'), isFalse);
    });

    test('a custom capability WITH explicit grant (customCapabilities) appears', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'),
          scope: const ApiKeyScope(customCapabilities: {'weather'}),
          customManifests: [_customManifest()]);
      expect(tools.any((t) => t.name == 'weather.get_forecast'), isTrue);
    });

    test('granting a different custom capability does not leak this one', () {
      final tools = buildAiTools(
          device: _device(platform: 'android'),
          scope: const ApiKeyScope(customCapabilities: {'some_other_capability'}),
          customManifests: [_customManifest()]);
      expect(tools.any((t) => t.name == 'weather.get_forecast'), isFalse);
    });

    test('a custom capability still respects its own platform_support even when granted', () {
      final tools = buildAiTools(
          device: _device(platform: 'windows'),
          scope: const ApiKeyScope(customCapabilities: {'weather'}),
          customManifests: [
            _customManifest(platformSupport: const ['android'])
          ]);
      expect(tools.any((t) => t.name == 'weather.get_forecast'), isFalse);
    });
  });

  group('AI Tool Registry — messaging adapters (P1-06)', () {
    test('messaging actions ab Android par exposed hain (implemented: true); '
        'Linux par kabhi nahi', () {
      final android = buildAiTools(
          device: _device(platform: 'android'), scope: _fullScope, customManifests: const []);
      expect(android.any((t) => t.name == 'notifications.read_event'), isTrue);
      expect(android.any((t) => t.name == 'messaging.get_event'), isTrue);
      expect(android.any((t) => t.name == 'messaging.prepare_reply'), isTrue);
      expect(android.any((t) => t.name == 'messaging.send_reply'), isTrue);

      final linux = buildAiTools(
          device: _device(platform: 'linux'), scope: _fullScope, customManifests: const []);
      expect(linux.any((t) => t.name.startsWith('messaging.')), isFalse);
    });
  });
}
