import 'package:control_api/models/api_key.dart';
import 'package:control_api/models/task.dart';
import 'package:control_api/storage/app_state.dart';
import 'package:test/test.dart';

void main() {
  group('ApiKeyScope.allowsCapability (P0-02)', () {
    test('screen-only key allows "screen", denies everything else', () {
      const scope = ApiKeyScope(screenView: true);
      expect(scope.allowsCapability('screen'), isTrue);
      expect(scope.allowsCapability('input'), isFalse);
      expect(scope.allowsCapability('files'), isFalse);
      expect(scope.allowsCapability('data'), isFalse);
    });

    test('touchInput OR keyboardText is enough for "input" capability', () {
      const touchOnly = ApiKeyScope(touchInput: true);
      const keyboardOnly = ApiKeyScope(keyboardText: true);
      const neither = ApiKeyScope();
      expect(touchOnly.allowsCapability('input'), isTrue);
      expect(keyboardOnly.allowsCapability('input'), isTrue);
      expect(neither.allowsCapability('input'), isFalse);
    });

    test('unknown capability is fail-closed denied', () {
      const scope = ApiKeyScope(
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
      expect(scope.allowsCapability('some_future_capability'), isFalse);
    });
  });

  group('allowsAction control.* is fail-closed by itself (P0-02)', () {
    test('even a fully-scoped key gets false from allowsAction for control.*', () {
      // Audit fix: pehle "koi bhi ek scope granted" se control.* chal
      // jaata tha. Ab allowsAction() control.* ke liye khud kabhi true
      // nahi deta — real authorization sirf route-level task-bound
      // `allowsCapability` check se hoti hai (commands.dart).
      const scope = ApiKeyScope(
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
      expect(scope.allowsAction('control.pause'), isFalse);
      expect(scope.allowsAction('control.resume'), isFalse);
      expect(scope.allowsAction('control.stop'), isFalse);
      expect(scope.allowsAction('control.switch'), isFalse);
    });
  });

  group('Task-bound control authorization scenario (P0-02)', () {
    test(
        'a screen-only key cannot pause a task that was started by an input command '
        '("unrelated capability se bypass na ho")', () {
      final state = AppState();
      // Task shuru hui thi ek "input" command se (jaise input.tap).
      final task = state.getOrCreateRunningTask('sess_x', 'dev_1', 'input');
      expect(task.originatingCapability, 'input');

      const screenOnlyKey = ApiKeyScope(screenView: true);
      // Yehi woh check hai jo commands.dart route mein control.pause se
      // pehle lagta hai.
      expect(screenOnlyKey.allowsCapability(task.originatingCapability), isFalse);
    });

    test('a key with the matching capability scope can control that task', () {
      final state = AppState();
      final task = state.getOrCreateRunningTask('sess_y', 'dev_1', 'input');
      const inputCapableKey = ApiKeyScope(touchInput: true);
      expect(inputCapableKey.allowsCapability(task.originatingCapability), isTrue);
    });

    test('TaskRecord.toJson exposes originatingCapability as "capability"', () {
      final task =
          TaskRecord(taskId: 't1', deviceId: 'd1', originatingCapability: 'files');
      expect(task.toJson()['capability'], 'files');
    });
  });
}
