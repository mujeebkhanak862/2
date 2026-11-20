import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/agent_connection.dart';
import 'package:shared_app/protocol/command_envelope.dart';

CommandEnvelope _envelope(String capability, String action) => CommandEnvelope(
      requestId: 'req_1',
      apiKeyId: 'key_1',
      capability: capability,
      action: action,
      params: const {},
    );

void main() {
  group('CommandDispatcher — messaging/notifications (P1-06)', () {
    test('notifications.read_event throws CapabilityUnavailableException, not a generic error',
        () async {
      final dispatcher = CommandDispatcher();
      expect(
        () => dispatcher.dispatch(_envelope('background', 'notifications.read_event')),
        throwsA(isA<CapabilityUnavailableException>()),
      );
    });

    test('messaging.send_reply throws CapabilityUnavailableException on non-Android hosts '
        '("Unsupported target => structured CAPABILITY_UNAVAILABLE"); '
        'Android par asli adapter hai (MessagingStore.kt)', () async {
      final dispatcher = CommandDispatcher();
      expect(
        () => dispatcher.dispatch(_envelope('background', 'messaging.send_reply')),
        throwsA(isA<CapabilityUnavailableException>()),
      );
    });

    test('messaging.get_event and messaging.prepare_reply also throw it', () async {
      final dispatcher = CommandDispatcher();
      expect(() => dispatcher.dispatch(_envelope('background', 'messaging.get_event')),
          throwsA(isA<CapabilityUnavailableException>()));
      expect(() => dispatcher.dispatch(_envelope('background', 'messaging.prepare_reply')),
          throwsA(isA<CapabilityUnavailableException>()));
    });

    test('CapabilityUnavailableException carries the action name and a human reason', () {
      final e = CapabilityUnavailableException('messaging.send_reply', 'Not implemented yet');
      expect(e.action, 'messaging.send_reply');
      expect(e.reason, 'Not implemented yet');
      expect(e.toString(), contains('CAPABILITY_UNAVAILABLE'));
      expect(e.toString(), contains('messaging.send_reply'));
    });

    test('a genuinely supported action (background.keepalive) does NOT throw '
        '(regression guard — only the truly-unimplemented ones should)', () async {
      final dispatcher = CommandDispatcher();
      final result = await dispatcher.dispatch(_envelope('background', 'background.keepalive'));
      expect(result['alive'], isTrue);
    });
  });
}
