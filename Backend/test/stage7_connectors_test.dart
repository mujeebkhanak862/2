// Stage 7 (item 86): connector file download.
import 'dart:convert';

import 'package:control_api/connectors/connector_provider.dart';
import 'package:control_api/connectors/dropbox_provider.dart';
import 'package:control_api/connectors/google_drive_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleDriveConnectorProvider.downloadFile', () {
    GoogleDriveConnectorProvider make(MockClientHandler h) => GoogleDriveConnectorProvider(
        httpClient: MockClient(h), clientId: 'id', clientSecret: 'secret');

    test('regular file: metadata then alt=media, bytes returned', () async {
      final urls = <String>[];
      final p = make((req) async {
        urls.add(req.url.toString());
        if (req.url.queryParameters['alt'] == 'media') {
          return http.Response.bytes(utf8.encode('hello'), 200);
        }
        return http.Response(
            jsonEncode({'id': 'abcde12345', 'name': 'a.txt', 'mimeType': 'text/plain', 'size': '5'}),
            200);
      });
      final f = await p.downloadFile('tok', 'abcde12345');
      expect(utf8.decode(f.bytes), 'hello');
      expect(f.name, 'a.txt');
      expect(f.mimeType, 'text/plain');
      expect(urls.last, contains('alt=media'));
    });

    test('Google Doc is exported as text/plain', () async {
      late Uri last;
      final p = make((req) async {
        last = req.url;
        if (req.url.path.endsWith('/export')) {
          return http.Response('doc text', 200);
        }
        return http.Response(
            jsonEncode({'name': 'Doc', 'mimeType': 'application/vnd.google-apps.document'}), 200);
      });
      final f = await p.downloadFile('tok', 'abcde12345');
      expect(last.path, endsWith('/export'));
      expect(last.queryParameters['mimeType'], 'text/plain');
      expect(f.mimeType, 'text/plain');
    });

    test('declared size over the limit is rejected before downloading', () async {
      var downloaded = false;
      final p = make((req) async {
        if (req.url.queryParameters['alt'] == 'media') downloaded = true;
        return http.Response(
            jsonEncode({'name': 'big', 'mimeType': 'x/y', 'size': '${connectorMaxDownloadBytes + 1}'}),
            200);
      });
      await expectLater(p.downloadFile('tok', 'abcde12345'), throwsA(isA<ConnectorFileTooLarge>()));
      expect(downloaded, isFalse);
    });

    test('invalid file ids (path injection) are rejected without any request', () async {
      var called = false;
      final p = make((req) async {
        called = true;
        return http.Response('{}', 200);
      });
      for (final bad in ['../../etc', 'a/b', 'x', 'abc def', '']) {
        await expectLater(p.downloadFile('tok', bad), throwsA(isA<ArgumentError>()), reason: bad);
      }
      expect(called, isFalse);
    });

    test('unsupported Google-native type -> clear error', () async {
      final p = make((req) async => http.Response(
          jsonEncode({'name': 'Form', 'mimeType': 'application/vnd.google-apps.form'}), 200));
      await expectLater(p.downloadFile('tok', 'abcde12345'), throwsA(isA<StateError>()));
    });
  });

  group('DropboxConnectorProvider.downloadFile', () {
    DropboxConnectorProvider make(MockClientHandler h) => DropboxConnectorProvider(
        httpClient: MockClient(h), appKey: 'key', appSecret: 'secret');

    test('sends the path in Dropbox-API-Arg and returns bytes + name', () async {
      late http.Request seen;
      final p = make((req) async {
        seen = req;
        return http.Response.bytes(utf8.encode('data'), 200, headers: {
          'dropbox-api-result': jsonEncode({'name': 'report.pdf'}),
          'content-type': 'application/octet-stream',
        });
      });
      final f = await p.downloadFile('tok', '/docs/report.pdf');
      expect(seen.url.host, 'content.dropboxapi.com');
      expect(jsonDecode(seen.headers['Dropbox-API-Arg']!), {'path': '/docs/report.pdf'});
      expect(f.name, 'report.pdf');
      expect(utf8.decode(f.bytes), 'data');
    });

    test('non-ASCII paths are escaped so the header stays ASCII', () async {
      late http.Request seen;
      final p = make((req) async {
        seen = req;
        return http.Response.bytes([1], 200);
      });
      await p.downloadFile('tok', '/docs/résumé.pdf');
      final header = seen.headers['Dropbox-API-Arg']!;
      expect(header.codeUnits.every((c) => c < 128), isTrue);
      expect(jsonDecode(header), {'path': '/docs/résumé.pdf'});
    });

    test('oversize body and empty path are rejected', () async {
      final big = make((req) async =>
          http.Response.bytes(List.filled(connectorMaxDownloadBytes + 1, 0), 200));
      await expectLater(big.downloadFile('tok', '/a'), throwsA(isA<ConnectorFileTooLarge>()));
      await expectLater(big.downloadFile('tok', ''), throwsA(isA<ArgumentError>()));
    });
  });
}
