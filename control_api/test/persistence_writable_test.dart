import 'dart:io';

import 'package:control_api/storage/app_state.dart';
import 'package:control_api/storage/persistence.dart';
import 'package:test/test.dart';

void main() {
  group('Persistence.verifyWritable (DEP-01)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('persistence_writable_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('returns true for a writable directory ("health endpoint works" precondition)',
        () async {
      final stateFile = File('${tempDir.path}/state.json');
      final persistence = Persistence(AppState(), fileOverride: stateFile);
      expect(await persistence.verifyWritable(), isTrue);
    });

    test('creates the parent directory if it does not exist yet', () async {
      final nestedFile = File('${tempDir.path}/nested/deep/state.json');
      final persistence = Persistence(AppState(), fileOverride: nestedFile);
      expect(await persistence.verifyWritable(), isTrue);
      expect(Directory('${tempDir.path}/nested/deep').existsSync(), isTrue);
    });

    test('the write-probe file does not linger after the check', () async {
      final stateFile = File('${tempDir.path}/state.json');
      final persistence = Persistence(AppState(), fileOverride: stateFile);
      await persistence.verifyWritable();
      expect(File('${tempDir.path}/.write_probe').existsSync(), isFalse);
    });
  });

  group('Persistence.dataDirectory (DEP-01)', () {
    test('defaults to /data when DATA_DIR is not set', () {
      // NOTE: is test process ke apne actual environment par depend
      // karta hai — agar DATA_DIR already set hai (CI mein set kiya ja
      // sakta hai), yeh test uska respect karega, hardcode nahi karega.
      final expected = Platform.environment['DATA_DIR'] ?? '/data';
      expect(Persistence.dataDirectory(), expected);
    });
  });
}
