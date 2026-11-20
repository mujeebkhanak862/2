import 'package:flutter_test/flutter_test.dart';
import 'package:shared_app/protocol/device_policy.dart';

void main() {
  group('isAllowedBrowserUrl', () {
    test('http/https only', () {
      expect(isAllowedBrowserUrl('https://example.com'), isTrue);
      expect(isAllowedBrowserUrl('http://example.com/x'), isTrue);
      for (final u in ['file:///etc/passwd', 'javascript:1', 'intent://x', 'data:,', '', null, 'example.com']) {
        expect(isAllowedBrowserUrl(u), isFalse, reason: '$u');
      }
    });
  });

  group('isDangerousFilePath', () {
    test('blocks executables, scripts, and Windows bypass tricks', () {
      for (final p in ['/t/a.exe', '/t/A.EXE', '/t/a.ps1', r'C:\t\a.exe.', r'C:\t\a.exe ', r'C:\t\a.txt:x.exe', '/t/a.desktop']) {
        expect(isDangerousFilePath(p), isTrue, reason: p);
      }
    });
    test('allows normal files', () {
      for (final p in ['/t/a.pdf', '/t/my-exe-notes.txt', r'C:\Users\me\a.docx']) {
        expect(isDangerousFilePath(p), isFalse, reason: p);
      }
    });
  });

  group('isPlausibleAppIdentifier', () {
    test('rejects shell metacharacters and empties', () {
      expect(isPlausibleAppIdentifier('firefox.desktop'), isTrue);
      expect(isPlausibleAppIdentifier('bash -c "x"; rm -rf /'), isFalse);
      expect(isPlausibleAppIdentifier('a|b'), isFalse);
      expect(isPlausibleAppIdentifier(''), isFalse);
      expect(isPlausibleAppIdentifier(null), isFalse);
    });
  });
}
