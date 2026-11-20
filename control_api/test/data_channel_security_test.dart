import 'dart:convert';

import 'package:control_api/validation/data_channel_security.dart';
import 'package:test/test.dart';

void main() {
  group('validateFilePath (P1-08, DATA-01)', () {
    test('a normal absolute path is valid', () {
      expect(validateFilePath('/sdcard/Download/report.pdf').isValid, isTrue);
    });

    test('a Windows-style absolute path is valid', () {
      expect(validateFilePath(r'C:\Users\me\Documents\file.txt').isValid, isTrue);
    });

    test('".." traversal is rejected (forward slash form)', () {
      expect(validateFilePath('/sdcard/../../../etc/passwd').isValid, isFalse);
    });

    test('".." traversal is rejected (backslash form)', () {
      expect(validateFilePath(r'..\..\Windows\System32\config').isValid, isFalse);
    });

    test('".." anywhere in the path, not just at the start, is rejected', () {
      expect(validateFilePath('/sdcard/Download/../../secret.txt').isValid, isFalse);
    });

    test('empty path is rejected', () {
      expect(validateFilePath('').isValid, isFalse);
    });

    test('null byte in path is rejected', () {
      expect(validateFilePath('/sdcard/file.txt\u0000.exe').isValid, isFalse);
    });

    test('an extremely long path is rejected', () {
      final longPath = '/${List.filled(5000, 'a').join()}';
      expect(validateFilePath(longPath).isValid, isFalse);
    });

    test('a path that merely contains "dotdot" as text (not "..") is fine', () {
      expect(validateFilePath('/sdcard/dotdot-report.pdf').isValid, isTrue);
    });
  });

  group('validateUploadPayloadSize (P1-08, SEC-02)', () {
    test('a small valid base64 payload is accepted', () {
      final payload = base64.encode(List<int>.filled(1000, 65)); // 1000 bytes
      final result = validateUploadPayloadSize(payload);
      expect(result.isValid, isTrue);
      expect(result.decodedByteLength, 1000);
    });

    test('missing payload is rejected', () {
      expect(validateUploadPayloadSize(null).isValid, isFalse);
    });

    test('empty payload string is rejected', () {
      expect(validateUploadPayloadSize('').isValid, isFalse);
    });

    test('an oversized payload is rejected before decoding fully '
        '("oversized upload rejected before storage/dispatch")', () {
      // maxUploadPayloadBytes + some margin, base64-encoded.
      final oversizedBytes = List<int>.filled(maxUploadPayloadBytes + 1024, 66);
      final payload = base64.encode(oversizedBytes);
      final result = validateUploadPayloadSize(payload);
      expect(result.isValid, isFalse);
    });

    test('a payload exactly at the limit is accepted', () {
      final bytes = List<int>.filled(maxUploadPayloadBytes, 67);
      final payload = base64.encode(bytes);
      final result = validateUploadPayloadSize(payload);
      expect(result.isValid, isTrue);
    });

    test('malformed base64 is rejected with a clear error, not a crash', () {
      final result = validateUploadPayloadSize('not valid base64 !!! @@@');
      expect(result.isValid, isFalse);
    });
  });

  group('validateUploadFileType (P1-08)', () {
    test('common document/media file types are allowed', () {
      for (final path in [
        '/sdcard/Download/report.pdf',
        '/sdcard/Pictures/photo.jpg',
        '/sdcard/Documents/notes.txt',
        '/sdcard/Music/song.mp3',
        '/sdcard/data.json',
      ]) {
        expect(validateUploadFileType(path).isValid, isTrue, reason: path);
      }
    });

    test('Windows executables are blocked', () {
      for (final ext in ['.exe', '.msi', '.bat', '.cmd', '.scr']) {
        expect(validateUploadFileType('/tmp/malware$ext').isValid, isFalse, reason: ext);
      }
    });

    test('shell scripts are blocked', () {
      expect(validateUploadFileType('/tmp/script.sh').isValid, isFalse);
    });

    test('APKs are blocked (silent-install risk)', () {
      expect(validateUploadFileType('/sdcard/app.apk').isValid, isFalse);
    });

    test('native libraries are blocked', () {
      expect(validateUploadFileType('/tmp/payload.dll').isValid, isFalse);
      expect(validateUploadFileType('/tmp/payload.so').isValid, isFalse);
    });

    test('extension check is case-insensitive', () {
      expect(validateUploadFileType('/tmp/MALWARE.EXE').isValid, isFalse);
    });

    test('a filename that merely contains a dangerous word (not the actual extension) is fine',
        () {
      expect(validateUploadFileType('/sdcard/my-exe-notes.txt').isValid, isTrue);
    });
  });
}
