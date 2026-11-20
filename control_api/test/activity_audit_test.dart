import 'package:control_api/models/activity.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:test/test.dart';

ActivityEvent _event(String eventType, {String actor = 'api_key:key_1', DateTime? timestamp}) =>
    ActivityEvent(
      eventType: eventType,
      deviceId: 'device_1',
      timestamp: timestamp ?? DateTime.now().toUtc(),
      status: 'success',
      actor: actor,
    );

void main() {
  group('ActivityEvent.effectiveCategory inference (P1-09)', () {
    test('task-level actions (input/screen/files/etc.) infer category "task"', () {
      for (final eventType in [
        'input.tap', 'screen.capture', 'files.read', 'browser.navigate',
        'clipboard.write', 'data.upload', 'app_launcher.launch', 'contacts.list',
        'control.pause',
      ]) {
        expect(_event(eventType).effectiveCategory, 'task', reason: eventType);
      }
    });

    test('connector.* infers category "connector"', () {
      expect(_event('connector.connected').effectiveCategory, 'connector');
      expect(_event('connector.disconnected').effectiveCategory, 'connector');
      expect(_event('connector.connect_failed').effectiveCategory, 'connector');
    });

    test('location.refresh infers category "location"', () {
      expect(_event('location.refresh').effectiveCategory, 'location');
    });

    test('background.keepalive infers category "background"', () {
      expect(_event('background.keepalive').effectiveCategory, 'background');
    });

    test('switch_event infers category "device"', () {
      expect(_event('switch_event').effectiveCategory, 'device');
    });

    test('an explicit category override takes priority over inference', () {
      final event = ActivityEvent(
        eventType: 'input.tap', // would normally infer "task"
        deviceId: 'd1',
        timestamp: DateTime.now().toUtc(),
        status: 'success',
        actor: 'api_key:k1',
        category: 'security', // explicit override
      );
      expect(event.effectiveCategory, 'security');
    });

    test('an unrecognized event type falls back to "other", not a crash', () {
      expect(_event('some_totally_new_thing').effectiveCategory, 'other');
    });
  });

  group('ActivityEvent.keyId extraction (P1-09)', () {
    test('extracts the key id from "api_key:<id>" actor convention', () {
      expect(_event('input.tap', actor: 'api_key:key_abc123').keyId, 'key_abc123');
    });

    test('returns null for non-api-key actors (e.g. device_agent)', () {
      expect(_event('connector.connected', actor: 'device_agent').keyId, isNull);
    });
  });

  group('ActivityEvent.toJson includes category and key_id (P1-09)', () {
    test('toJson always includes a category field', () {
      final json = _event('input.tap').toJson();
      expect(json['category'], 'task');
    });

    test('toJson includes key_id when derivable', () {
      final json = _event('input.tap', actor: 'api_key:key_1').toJson();
      expect(json['key_id'], 'key_1');
    });

    test('toJson never includes raw request params/content fields '
        '("sensitive payload not exposed in normal activity endpoint")', () {
      final json = _event('files.write').toJson();
      expect(json.containsKey('params'), isFalse);
      expect(json.containsKey('payload'), isFalse);
      expect(json.containsKey('content'), isFalse);
      expect(json.containsKey('text'), isFalse);
    });
  });

  group('AppState.pruneActivityLog — time-based retention (P1-09)', () {
    test('removes events older than the retention window', () {
      final state = AppState();
      final now = DateTime.now().toUtc();
      state.logActivity(_event('input.tap', timestamp: now.subtract(const Duration(days: 100))));
      state.logActivity(_event('input.tap', timestamp: now.subtract(const Duration(days: 1))));

      final removed = state.pruneActivityLog(retention: const Duration(days: 90));
      expect(removed, 1);
      expect(state.activityLog.length, 1);
    });

    test('keeps all events when none exceed the retention window', () {
      final state = AppState();
      final now = DateTime.now().toUtc();
      state.logActivity(_event('input.tap', timestamp: now.subtract(const Duration(days: 5))));
      state.logActivity(_event('input.tap', timestamp: now.subtract(const Duration(days: 10))));

      final removed = state.pruneActivityLog(retention: const Duration(days: 90));
      expect(removed, 0);
      expect(state.activityLog.length, 2);
    });

    test('an empty activity log prunes cleanly with no error', () {
      final state = AppState();
      expect(state.pruneActivityLog(), 0);
    });
  });
}
