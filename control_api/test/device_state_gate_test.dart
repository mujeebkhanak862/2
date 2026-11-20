import 'package:control_api/routes/commands.dart';
import 'package:test/test.dart';

void main() {
  group('deviceStateGateError (P1-05)', () {
    test('ONLINE_UNLOCKED allows every capability', () {
      for (final capability in [
        'screen', 'input', 'browser', 'app_launcher', 'clipboard', // screen-dependent
        'files', 'data', 'location', 'contacts', 'background', // background-capable
      ]) {
        expect(deviceStateGateError('ONLINE_UNLOCKED', capability, 'req_1'), isNull,
            reason: '$capability should be allowed when ONLINE_UNLOCKED');
      }
    });

    test('ONLINE_LOCKED blocks screen-dependent capabilities '
        '("Locked phone exposes only supported actions")', () {
      for (final capability in screenDependentCapabilities) {
        final result = deviceStateGateError('ONLINE_LOCKED', capability, 'req_1');
        expect(result, isNotNull, reason: '$capability should be blocked when locked');
      }
    });

    test('ONLINE_LOCKED still allows background-capable capabilities', () {
      for (final capability in ['files', 'data', 'location', 'contacts', 'background']) {
        expect(deviceStateGateError('ONLINE_LOCKED', capability, 'req_1'), isNull,
            reason: '$capability should still work when locked');
      }
    });

    test('SCREEN_OFF behaves the same as ONLINE_LOCKED', () {
      expect(deviceStateGateError('SCREEN_OFF', 'input', 'req_1'), isNotNull);
      expect(deviceStateGateError('SCREEN_OFF', 'files', 'req_1'), isNull);
    });

    test('SLEEPING blocks everything '
        '("offline/powered-off clearly unavailable")', () {
      for (final capability in ['screen', 'input', 'files', 'data', 'location']) {
        expect(deviceStateGateError('SLEEPING', capability, 'req_1'), isNotNull);
      }
    });

    test('OFFLINE blocks everything', () {
      for (final capability in ['screen', 'input', 'files', 'data', 'location']) {
        expect(deviceStateGateError('OFFLINE', capability, 'req_1'), isNotNull);
      }
    });

    test('POWERED_OFF blocks everything', () {
      for (final capability in ['screen', 'input', 'files', 'data', 'location']) {
        expect(deviceStateGateError('POWERED_OFF', capability, 'req_1'), isNotNull);
      }
    });

    test('an unrecognized state string fails open (defensive, practically unreachable)', () {
      expect(deviceStateGateError('SOME_FUTURE_STATE', 'screen', 'req_1'), isNull);
    });
  });
}
