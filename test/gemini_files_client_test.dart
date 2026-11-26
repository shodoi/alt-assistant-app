import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_alt_generator/error_classifier.dart';
import 'package:my_alt_generator/gemini_files_client.dart';

void main() {
  group('GeminiFilesClient', () {
    test('uploadImage sends raw binary POST with uploadType=media, Content-Type, and x-goog-api-key', () async {
      final rawBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
      http.Request? captured;

      final mockClient = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'file': {
              'name': 'files/img-001',
              'uri': 'https://generativelanguage.googleapis.com/v1beta/files/img-001',
              'mimeType': 'image/png',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final filesClient = GeminiFilesClient(httpClient: mockClient);
      final uploaded = await filesClient.uploadImage(
        bytes: rawBytes,
        mimeType: 'image/png',
        apiKey: 'secret-api-key-xyz',
      );

      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(
        captured!.url.toString(),
        'https://generativelanguage.googleapis.com/upload/v1beta/files?uploadType=media',
      );
      expect(captured!.headers['x-goog-api-key'], 'secret-api-key-xyz');
      expect(captured!.headers['content-type'], 'image/png');
      expect(captured!.bodyBytes, rawBytes);

      expect(uploaded.name, 'files/img-001');
      expect(
        uploaded.uri,
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/files/img-001'),
      );
      expect(uploaded.apiKey, 'secret-api-key-xyz');
      expect(uploaded.toString(), isNot(contains('secret-api-key-xyz')));
    });

    test('uploadImage throws GeminiFilesApiException with statusCode on HTTP error and classifies properly', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 403,
              'message': 'API key not valid for secret-key-123',
            },
          }),
          403,
          headers: {'content-type': 'application/json'},
        );
      });

      final filesClient = GeminiFilesClient(httpClient: mockClient);
      Object? caught;
      try {
        await filesClient.uploadImage(
          bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF]),
          mimeType: 'image/jpeg',
          apiKey: 'secret-key-123',
        );
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<GeminiFilesApiException>());
      final classified = classifyError(caught!, secretApiKey: 'secret-key-123');
      expect(classified.category, ErrorCategory.invalidApiKey);
      expect(classified.detailLabel, 'HTTP 403');
      expect(classified.format(), isNot(contains('secret-key-123')));
    });

    test('deleteFileBestEffort sends DELETE to /v1beta/{fileName} with x-goog-api-key', () async {
      final capturedRequests = <http.Request>[];
      final mockClient = MockClient((request) async {
        capturedRequests.add(request);
        return http.Response('{}', 200);
      });

      final filesClient = GeminiFilesClient(httpClient: mockClient);
      await filesClient.deleteFileBestEffort(
        fileName: 'files/abc123',
        apiKey: 'my-key',
      );
      await filesClient.deleteFileBestEffort(
        fileName: '/files/def456',
        apiKey: 'my-key',
      );

      expect(capturedRequests, hasLength(2));
      expect(capturedRequests[0].method, 'DELETE');
      expect(
        capturedRequests[0].url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/files/abc123',
      );
      expect(capturedRequests[0].headers['x-goog-api-key'], 'my-key');
      expect(
        capturedRequests[1].url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/files/def456',
      );
    });

    test('deleteFileBestEffort swallows network and server failures without throwing', () async {
      final failingClient = MockClient((request) async {
        throw const SocketException('offline');
      });
      final filesClient = GeminiFilesClient(httpClient: failingClient);

      await expectLater(
        filesClient.deleteFileBestEffort(
          fileName: 'files/offline-1',
          apiKey: 'secret-key',
        ),
        completes,
      );
    });
  });
}
