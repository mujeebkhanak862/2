import 'package:control_api/models/custom_capability.dart';
import 'package:test/test.dart';

Map<String, dynamic> _validManifest() => {
      'capability': 'weather',
      'version': '1.0.0',
      'required_permission': 'internet',
      'default_policy': 'ask',
      'actions': [
        {
          'name': 'weather.get_forecast',
          'risk_level': 'low',
          'params_schema': {
            'required': ['city']
          },
        },
      ],
    };

void main() {
  group('validateCustomManifest (P1-01)', () {
    test('a well-formed manifest is valid', () {
      final result = validateCustomManifest(_validManifest(), {});
      expect(result.isValid, isTrue);
    });

    test('missing capability is rejected', () {
      final m = _validManifest()..remove('capability');
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('capability name with invalid characters is rejected', () {
      final m = _validManifest();
      m['capability'] = 'Weather-App!';
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('registering a name that collides with a built-in capability is rejected '
        '("privileged registration trust")', () {
      final m = _validManifest();
      m['capability'] = 'screen'; // trying to shadow the built-in "screen" capability
      final actions = m['actions'] as List;
      (actions.first as Map)['name'] = 'screen.get_forecast';
      final result = validateCustomManifest(m, {'screen', 'input', 'files'});
      expect(result.isValid, isFalse);
    });

    test('missing version is rejected', () {
      final m = _validManifest()..remove('version');
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('empty actions list is rejected', () {
      final m = _validManifest();
      m['actions'] = <Map<String, dynamic>>[];
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('action name not prefixed with "<capability>." is rejected', () {
      final m = _validManifest();
      (m['actions'] as List).first['name'] = 'get_forecast'; // missing "weather." prefix
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('duplicate action names within one manifest are rejected', () {
      final m = _validManifest();
      final action = (m['actions'] as List).first;
      m['actions'] = [action, Map<String, dynamic>.from(action as Map)];
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('invalid risk_level is rejected', () {
      final m = _validManifest();
      (m['actions'] as List).first['risk_level'] = 'catastrophic';
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('missing risk_level is rejected', () {
      final m = _validManifest();
      (m['actions'] as List).first.remove('risk_level');
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('invalid default_policy is rejected', () {
      final m = _validManifest();
      m['default_policy'] = 'yolo';
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('default_policy defaults to "ask" when omitted (still valid)', () {
      final m = _validManifest()..remove('default_policy');
      expect(validateCustomManifest(m, {}).isValid, isTrue);
    });

    test('invalid platform_support values are rejected', () {
      final m = _validManifest();
      m['platform_support'] = ['android', 'ios']; // "ios" not supported by this project
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });

    test('valid platform_support is accepted', () {
      final m = _validManifest();
      m['platform_support'] = ['android', 'windows'];
      expect(validateCustomManifest(m, {}).isValid, isTrue);
    });

    test('params_schema present but not an object is rejected', () {
      final m = _validManifest();
      (m['actions'] as List).first['params_schema'] = 'not-an-object';
      expect(validateCustomManifest(m, {}).isValid, isFalse);
    });
  });

  group('manifestIsPrivileged (P1-01)', () {
    test('a manifest with only low/medium risk actions is not privileged', () {
      final m = _validManifest(); // risk_level: low
      expect(manifestIsPrivileged(m), isFalse);
    });

    test('a manifest with any high-risk action is privileged', () {
      final m = _validManifest();
      (m['actions'] as List).first['risk_level'] = 'high';
      expect(manifestIsPrivileged(m), isTrue);
    });

    test('a manifest with mixed risk levels, one high, is privileged', () {
      final m = _validManifest();
      final actions = m['actions'] as List;
      actions.add({
        'name': 'weather.delete_all_data',
        'risk_level': 'high',
        'params_schema': <String, dynamic>{},
      });
      expect(manifestIsPrivileged(m), isTrue);
    });
  });
}
