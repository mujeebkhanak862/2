import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/agent_connection.dart';
import 'package:shared_app/protocol/command_envelope.dart';

CommandEnvelope _envelope(String capability, String action, Map<String, dynamic> params) =>
    CommandEnvelope(
      protocolVersion: CommandEnvelope.currentProtocolVersion,
      requestId: 'req_1',
      apiKeyId: 'key_1',
      capability: capability,
      action: action,
      params: params,
    );

void main() {
  group('describeActionSafely (P1-04)', () {
    test('failure always returns a generic "Failed: <action>", never leaking exception detail', () {
      final e = _envelope('input', 'input.tap', {'x': 1, 'y': 2});
      expect(describeActionSafely(e, success: false), 'Failed: input.tap');
    });

    test('input.tap includes coordinates (safe, not sensitive)', () {
      final e = _envelope('input', 'input.tap', {'x': 100, 'y': 250});
      expect(describeActionSafely(e, success: true), 'Tapped at (100, 250)');
    });

    test('input.swipe includes both coordinate pairs', () {
      final e = _envelope('input', 'input.swipe', {'x1': 0, 'y1': 0, 'x2': 100, 'y2': 100});
      expect(describeActionSafely(e, success: true), 'Swiped from (0, 0) to (100, 100)');
    });

    test('input.type_text NEVER includes the actual typed text — only length '
        '("Never put message/file contents into normal task logs")', () {
      final e = _envelope('input', 'input.type_text', {'text': 'my-secret-password-123'});
      final description = describeActionSafely(e, success: true);
      expect(description.contains('my-secret-password-123'), isFalse);
      expect(description, 'Typed 23 character(s)');
    });

    test('clipboard.write never echoes the actual clipboard content', () {
      final e = _envelope('clipboard', 'clipboard.write', {'text': 'sensitive clipboard data'});
      final description = describeActionSafely(e, success: true);
      expect(description.contains('sensitive clipboard data'), isFalse);
      expect(description, 'Wrote to clipboard');
    });

    test('clipboard.read never echoes content (there is none to echo, but still generic)', () {
      final e = _envelope('clipboard', 'clipboard.read', {});
      expect(describeActionSafely(e, success: true), 'Read clipboard');
    });

    test('browser.type_text includes the field label but never the typed value', () {
      final e = _envelope('browser', 'browser.type_text',
          {'field_label': 'Password', 'text': 'hunter2-actual-password'});
      final description = describeActionSafely(e, success: true);
      expect(description.contains('hunter2-actual-password'), isFalse);
      expect(description, 'Typed into field: Password');
    });

    test('files.read includes the path (metadata, not file content)', () {
      final e = _envelope('files', 'files.read', {'path': '/sdcard/Documents/report.pdf'});
      expect(describeActionSafely(e, success: true), 'Read file at /sdcard/Documents/report.pdf');
    });

    test('files.read falls back to legacy target_path param name', () {
      final e = _envelope('files', 'files.read', {'target_path': '/sdcard/legacy.txt'});
      expect(describeActionSafely(e, success: true), 'Read file at /sdcard/legacy.txt');
    });

    test('browser.navigate includes the URL', () {
      final e = _envelope('browser', 'browser.navigate', {'url': 'https://example.com'});
      expect(describeActionSafely(e, success: true), 'Navigated to https://example.com');
    });

    test('contacts.list never includes any contact data (there is none in params anyway)', () {
      final e = _envelope('contacts', 'contacts.list', {});
      expect(describeActionSafely(e, success: true), 'Listed contacts');
    });

    test('control.pause/resume/stop have clear, distinct descriptions', () {
      expect(
          describeActionSafely(_envelope('control', 'control.pause', {'session_id': 's1'}),
              success: true),
          'Paused task');
      expect(
          describeActionSafely(_envelope('control', 'control.resume', {'session_id': 's1'}),
              success: true),
          'Resumed task');
      expect(
          describeActionSafely(_envelope('control', 'control.stop', {'session_id': 's1'}),
              success: true),
          'Stopped task');
    });

    test('an unknown/future action falls back to a generic but non-empty description', () {
      final e = _envelope('future_capability', 'future_capability.do_something', {});
      final description = describeActionSafely(e, success: true);
      expect(description, isNotEmpty);
      expect(description, 'Performed future_capability.do_something');
    });
  });

  group('CommandDispatcher.currentStepFor (P1-04)', () {
    test('starts at 0 for a session with no completed steps yet', () {
      final dispatcher = CommandDispatcher();
      expect(dispatcher.currentStepFor('brand_new_session'), 0);
    });
  });
}
