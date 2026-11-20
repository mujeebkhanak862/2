import 'dart:io';

import 'package:control_api/storage/app_state.dart';
import 'package:control_api/storage/persistence.dart';
import 'package:test/test.dart';

void main() {
  group('Custom capability manifest persistence (P1-01)', () {
    late Directory tempDir;
    late File stateFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('capability_persistence_test');
      stateFile = File('${tempDir.path}/state.json');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('a registered custom manifest survives a save + load round-trip '
        '("Restart ke baad registered safe manifest survives")', () async {
      final writerState = AppState();
      writerState.customCapabilityManifests.add({
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
      });
      await Persistence(writerState, fileOverride: stateFile).save();

      final readerState = AppState();
      await Persistence(readerState, fileOverride: stateFile).load();

      expect(readerState.customCapabilityManifests.length, 1);
      expect(readerState.customCapabilityManifests.first['capability'], 'weather');
      final actions = readerState.customCapabilityManifests.first['actions'] as List;
      expect(actions.first['name'], 'weather.get_forecast');
    });

    test('missing file loads cleanly with no custom manifests', () async {
      final state = AppState();
      await Persistence(state, fileOverride: stateFile).load();
      expect(state.customCapabilityManifests, isEmpty);
    });

    test('multiple manifests all survive the round-trip', () async {
      final writerState = AppState();
      writerState.customCapabilityManifests.addAll([
        {
          'capability': 'weather',
          'version': '1.0.0',
          'actions': [
            {'name': 'weather.get_forecast', 'risk_level': 'low', 'params_schema': <String, dynamic>{}}
          ],
        },
        {
          'capability': 'notes',
          'version': '2.1.0',
          'actions': [
            {'name': 'notes.create', 'risk_level': 'medium', 'params_schema': <String, dynamic>{}}
          ],
        },
      ]);
      await Persistence(writerState, fileOverride: stateFile).save();

      final readerState = AppState();
      await Persistence(readerState, fileOverride: stateFile).load();
      expect(readerState.customCapabilityManifests.length, 2);
      final names = readerState.customCapabilityManifests.map((m) => m['capability']).toSet();
      expect(names, {'weather', 'notes'});
    });
  });
}
