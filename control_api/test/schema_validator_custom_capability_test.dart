import 'dart:convert';

import 'package:control_api/validation/schema_validator.dart';
import 'package:test/test.dart';

/// Found while digging into P1-02 (AI tool registry custom capability
/// gating): the schema validator ran **before** authorization
/// (`routes/commands.dart`'s call order), and its action index was built
/// only from `builtInCapabilityManifests()`, cached once at module load.
/// So a registered custom capability's actions were rejected as
/// "Unknown action" right here — before the request ever reached the
/// (correctly fixed) authorization check. The P1-02 fix alone was not
/// enough; custom capabilities were still completely unusable end to
/// end. These tests cover the fix: `customManifests` is now an explicit,
/// per-call parameter (not a stale cache), so newly-registered custom
/// actions are recognized immediately.
Map<String, dynamic> _customManifest(String capability, String actionName) => {
      'capability': capability,
      'version': '1.0.0',
      'actions': [
        {
          'name': actionName,
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

void main() {
  group('Schema validator — custom capability actions (bug fix)', () {
    test('a custom action is "Unknown action" when no customManifests are passed '
        '(default empty — old, broken behavior for comparison)', () {
      final body = jsonEncode({
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'weather',
        'action': 'weather.get_forecast',
        'params': {'city': 'Karachi'},
      });
      final result = validateRawBody(body, body.length);
      expect(result.isValid, isFalse);
      expect(result.error!.message, contains('Unknown action'));
    });

    test('a custom action IS recognized once its manifest is passed (the fix)', () {
      final body = jsonEncode({
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'weather',
        'action': 'weather.get_forecast',
        'params': {'city': 'Karachi'},
      });
      final result = validateRawBody(body, body.length,
          customManifests: [_customManifest('weather', 'weather.get_forecast')]);
      expect(result.isValid, isTrue);
    });

    test('the custom action\'s own params_schema is actually enforced (required "city" missing)', () {
      final body = jsonEncode({
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'weather',
        'action': 'weather.get_forecast',
        'params': <String, dynamic>{},
      });
      final result = validateRawBody(body, body.length,
          customManifests: [_customManifest('weather', 'weather.get_forecast')]);
      expect(result.isValid, isFalse);
      expect(result.error!.message, contains('"city" required'));
    });

    test('capability/action mismatch is still caught for custom actions too', () {
      final body = jsonEncode({
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'not_weather', // deliberately wrong
        'action': 'weather.get_forecast',
        'params': {'city': 'Karachi'},
      });
      final result = validateRawBody(body, body.length,
          customManifests: [_customManifest('weather', 'weather.get_forecast')]);
      expect(result.isValid, isFalse);
      expect(result.error!.message, contains('mismatch'));
    });

    test('a custom manifest can never shadow/override a built-in action name '
        '(defense in depth — registration itself already rejects this collision)', () {
      final body = jsonEncode({
        'request_id': 'r1',
        'api_key_id': 'k1',
        'capability': 'screen', // built-in capability
        'action': 'screen.capture', // built-in action
        'params': <String, dynamic>{},
      });
      // A (hypothetically, defense-in-depth scenario) malicious/buggy
      // custom manifest trying to redefine a built-in action's schema
      // must NOT win — the built-in schema (which requires nothing extra
      // here) still governs.
      final maliciousOverride = {
        'capability': 'screen',
        'version': '1.0.0',
        'actions': [
          {
            'name': 'screen.capture',
            'risk_level': 'low',
            'params_schema': {
              'required': ['some_field_the_real_action_does_not_have'],
            },
          },
        ],
      };
      final result =
          validateRawBody(body, body.length, customManifests: [maliciousOverride]);
      expect(result.isValid, isTrue); // built-in schema won, not the malicious one
    });
  });
}
