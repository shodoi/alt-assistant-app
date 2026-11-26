import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

import 'package:my_alt_generator/main.dart';

const List<int> _transparent1x1Png = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0,
  0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1,
  13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

// Minimal valid 1x1 JPEG bytes (SOI + APP0 + ... + EOI).
const List<int> _minimalJpeg = <int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
  0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
  0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
  0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
  0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
  0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
  0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
  0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
  0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
  0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
  0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
  0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
  0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
  0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
  0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
  0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
  0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
  0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
  0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
  0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
  0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
  0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD5, 0xDB, 0x20, 0xA8, 0xF1, 0x45, 0x00,
  0x14, 0x50, 0x01, 0x45, 0x00, 0xFF, 0xD9,
];

File _createTempSampleImage({
  List<int> bytes = _transparent1x1Png,
  String filename = 'sample.png',
}) {
  final tempDir = Directory.systemTemp.createTempSync('alt_test_');
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  return File('${tempDir.path}/$filename')..writeAsBytesSync(bytes);
}

List<MethodCall> _mockImagePickerChannel(File imageFile) {
  const imagePickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  messenger.setMockMethodCallHandler(imagePickerChannel, (call) async {
    calls.add(call);
    if (call.method == 'pickImage') {
      return imageFile.path;
    }
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(imagePickerChannel, null);
  });

  return calls;
}

Future<void> _selectImageSourceAndWait(
  WidgetTester tester,
  String optionLabel,
) async {
  await tester.tap(find.text(optionLabel));
  await tester.pumpAndSettle();
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _selectTestImage(
  WidgetTester tester, {
  List<int> bytes = _transparent1x1Png,
  String filename = 'sample.png',
  bool useBottomIcon = false,
}) async {
  final imageFile = _createTempSampleImage(bytes: bytes, filename: filename);
  _mockImagePickerChannel(imageFile);

  if (useBottomIcon) {
    await tester.tap(find.byIcon(Icons.add_photo_alternate));
  } else {
    await tester.tap(find.text('タップして画像を選択'));
  }
  await tester.pumpAndSettle();

  await _selectImageSourceAndWait(tester, 'ライブラリから選択');
}

http.Response _filesUploadSuccessResponse({
  String name = 'files/test-file-1',
  String mimeType = 'image/png',
}) {
  return http.Response(
    jsonEncode({
      'file': {
        'name': name,
        'uri': 'https://generativelanguage.googleapis.com/v1beta/$name',
        'mimeType': mimeType,
      },
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

http.Response _geminiSuccessResponse(String text) {
  return http.Response(
    jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': text}
            ],
            'role': 'model',
          },
        }
      ],
    }),
    200,
    headers: {'content-type': 'application/json'},
  );
}

bool _isUploadRequest(http.BaseRequest request) =>
    request.method == 'POST' && request.url.path == '/upload/v1beta/files';

bool _isGenerateRequest(http.BaseRequest request) =>
    request.method == 'POST' &&
    request.url.path.endsWith('/models/gemini-4-hydrogen:generateContent');

bool _isDeleteRequest(http.BaseRequest request) =>
    request.method == 'DELETE' && request.url.path.startsWith('/v1beta/files/');

void _setMockStorage([
  Map<String, String> values = const {'gemini_api_key': 'test-key'},
]) {
  FlutterSecureStorage.setMockInitialValues(Map<String, String>.from(values));
}

Future<void> _pumpHomeWithSelectedImage(
  WidgetTester tester, {
  required http.Client httpClient,
  Map<String, String> storageValues = const {'gemini_api_key': 'test-key'},
  List<int> imageBytes = _transparent1x1Png,
  String filename = 'sample.png',
}) async {
  _setMockStorage(storageValues);
  await tester.pumpWidget(AltTextGeneratorApp(httpClient: httpClient));
  await tester.pumpAndSettle();
  await _selectTestImage(tester, bytes: imageBytes, filename: filename);
}

/// Transport mock that observes [http.Abortable.abortTrigger] on every request.
class _AbortAwareMockClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(
    http.BaseRequest request,
    List<int> bodyBytes,
    Future<void>? abortTrigger,
  ) _handler;

  final List<http.BaseRequest> requests = [];
  final List<bool> abortedFlags = [];

  _AbortAwareMockClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    final idx = abortedFlags.length;
    abortedFlags.add(false);
    if (trigger != null) {
      unawaited(trigger.whenComplete(() {
        abortedFlags[idx] = true;
      }));
    }
    final bytes = await request.finalize().toBytes();
    return _handler(request, bytes, trigger);
  }
}

http.StreamedResponse _toStreamedResponse(http.Response response) {
  return http.StreamedResponse(
    http.ByteStream.fromBytes(response.bodyBytes),
    response.statusCode,
    contentLength: response.contentLength,
    headers: response.headers,
  );
}

void main() {
  testWidgets('App title smoke test', (WidgetTester tester) async {
    _setMockStorage();
    await tester.pumpWidget(const AltTextGeneratorApp());

    expect(find.text('Alt 生成くん'), findsOneWidget);
  });

  testWidgets(
      'SettingsPage hides model priority UI and shows gemini-4-hydrogen read-only',
      (WidgetTester tester) async {
    _setMockStorage();

    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('モデル優先順位'), findsNothing);
    expect(find.text('ドラッグ＆ドロップで並べ替え'), findsNothing);
    expect(find.text('モデル順を保存'), findsNothing);
    expect(find.text('デフォルトに戻す'), findsNothing);
    expect(find.text('gemini-4-hydrogen'), findsOneWidget);
  });

  testWidgets(
      'SettingsPage validates API key once against gemini-4-hydrogen and ignores legacy model_order',
      (WidgetTester tester) async {
    _setMockStorage(const {'model_order': '["gemini-3.1-pro"]'});

    final requestedUris = <Uri>[];
    final mockClient = MockClient((request) async {
      requestedUris.add(request.url);
      return _geminiSuccessResponse('ok');
    });

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: mockClient));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Gemini API Key'),
      'new-test-key',
    );
    await tester.tap(find.text('Save API Key'));
    await tester.pumpAndSettle();

    expect(requestedUris, hasLength(1));
    expect(
      requestedUris.single.path,
      endsWith('/models/gemini-4-hydrogen:generateContent'),
    );
    expect(find.text('API Keyを確認し、保存しました'), findsOneWidget);
  });

  testWidgets(
      'HomePage uploads raw binary via Files API once, shows 2-stage loading, and sends FilePart without inlineData',
      (WidgetTester tester) async {
    final requests = <http.Request>[];
    final uploadCompleter = Completer<http.Response>();
    final generateCompleter = Completer<http.Response>();

    final mockClient = MockClient((request) {
      requests.add(request);
      if (_isUploadRequest(request)) {
        return uploadCompleter.future;
      }
      return generateCompleter.future;
    });

    await _pumpHomeWithSelectedImage(
      tester,
      httpClient: mockClient,
      storageValues: const {
        'gemini_api_key': 'test-key',
        'model_order': '["gemini-3.1-pro"]',
      },
    );

    await tester.tap(find.text('Altテキストを生成'));
    await tester.pump();
    await tester.pump();

    // Stage 1: Uploading via Files API
    expect(find.text('画像をアップロード中...'), findsOneWidget);
    expect(find.textContaining('gemini'), findsNothing);

    uploadCompleter.complete(_filesUploadSuccessResponse());
    await tester.pump();
    await tester.pump();

    // Stage 2: Generating Alt Text
    expect(find.text('Altテキストを生成中...'), findsOneWidget);
    expect(find.textContaining('gemini'), findsNothing);
    expect(find.textContaining('モデルを選択中'), findsNothing);
    expect(find.textContaining('試行中'), findsNothing);

    generateCompleter.complete(_geminiSuccessResponse('青い空の画像'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    final uploadReq = requests[0];
    expect(_isUploadRequest(uploadReq), isTrue);
    expect(uploadReq.url.queryParameters['uploadType'], 'media');
    expect(uploadReq.headers['x-goog-api-key'], 'test-key');
    expect(uploadReq.headers['content-type'], 'image/png');
    expect(uploadReq.bodyBytes, _transparent1x1Png);

    final generateReq = requests[1];
    expect(_isGenerateRequest(generateReq), isTrue);
    expect(generateReq.body, contains('file_uri'));
    expect(
      generateReq.body,
      contains('https://generativelanguage.googleapis.com/v1beta/files/test-file-1'),
    );
    expect(generateReq.body, isNot(contains('inlineData')));
    expect(find.text('青い空の画像'), findsOneWidget);
  });

  testWidgets('HomePage detects JPEG MIME type from magic bytes on upload',
      (WidgetTester tester) async {
    http.Request? uploadReq;
    final mockClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        uploadReq = request;
        return _filesUploadSuccessResponse(mimeType: 'image/jpeg');
      }
      return _geminiSuccessResponse('JPEG画像の説明');
    });

    await _pumpHomeWithSelectedImage(
      tester,
      httpClient: mockClient,
      imageBytes: _minimalJpeg,
      filename: 'photo.jpg',
    );
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    expect(uploadReq, isNotNull);
    expect(uploadReq!.headers['content-type'], 'image/jpeg');
    expect(uploadReq!.bodyBytes, _minimalJpeg);
    expect(find.text('JPEG画像の説明'), findsOneWidget);
  });

  testWidgets(
      'HomePage fails immediately without retry on HTTP 500 and reuses cached file_uri on regenerate',
      (WidgetTester tester) async {
    final requests = <http.Request>[];
    var generateAttempts = 0;
    final regenerateCompleter = Completer<http.Response>();

    final mockClient = MockClient((request) async {
      requests.add(request);
      if (_isUploadRequest(request)) {
        return _filesUploadSuccessResponse(name: 'files/cached-1');
      }
      if (_isGenerateRequest(request)) {
        generateAttempts++;
        if (generateAttempts == 1) {
          return http.Response('Server Error', 500);
        }
        return regenerateCompleter.future;
      }
      return http.Response('{}', 200);
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    // 1 upload + 1 generate (NO retry on HTTP 500)
    expect(requests.where(_isUploadRequest), hasLength(1));
    expect(requests.where(_isGenerateRequest), hasLength(1));
    expect(find.textContaining('（詳細: HTTP 500）'), findsOneWidget);

    // Regenerate reuses cached file_uri without re-uploading
    await tester.tap(find.byTooltip('回答を再生成'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Altテキストを生成中...'), findsOneWidget);
    expect(find.text('画像をアップロード中...'), findsNothing);

    regenerateCompleter.complete(_geminiSuccessResponse('再生成されたAltテキスト'));
    await tester.pumpAndSettle();

    expect(requests.where(_isUploadRequest), hasLength(1));
    expect(requests.where(_isGenerateRequest), hasLength(2));
    expect(find.text('再生成されたAltテキスト'), findsOneWidget);
  });

  testWidgets(
      'HomePage does NOT fall back to inline Base64 when Files API upload fails',
      (WidgetTester tester) async {
    final requests = <http.Request>[];
    final mockClient = MockClient((request) async {
      requests.add(request);
      if (_isUploadRequest(request)) {
        return http.Response('Internal Error', 500);
      }
      return _geminiSuccessResponse('should not be called');
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(_isUploadRequest(requests.single), isTrue);
    expect(requests.where(_isGenerateRequest), isEmpty);
    expect(find.textContaining('（詳細: HTTP 500）'), findsOneWidget);
  });

  testWidgets(
      'HomePage chat follow-up sends zero image re-upload and shows generic loading text',
      (WidgetTester tester) async {
    final requests = <http.Request>[];
    Completer<http.Response>? followUpCompleter;

    final mockClient = MockClient((request) {
      requests.add(request);
      if (_isUploadRequest(request)) {
        return Future.value(_filesUploadSuccessResponse());
      }
      if (_isDeleteRequest(request)) {
        return Future.value(http.Response('{}', 200));
      }
      if (requests.where(_isGenerateRequest).length == 1) {
        return Future.value(_geminiSuccessResponse('青い空の画像'));
      }
      followUpCompleter = Completer<http.Response>();
      return followUpCompleter!.future;
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'もっと短くして');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(find.text('回答を生成中...'), findsOneWidget);
    expect(find.textContaining('gemini'), findsNothing);

    followUpCompleter!.complete(_geminiSuccessResponse('青空'));
    await tester.pumpAndSettle();

    expect(requests.where(_isUploadRequest), hasLength(1));
    final generateRequests = requests.where(_isGenerateRequest).toList();
    expect(generateRequests, hasLength(2));
    expect(generateRequests[1].body, isNot(contains('inlineData')));
    expect(generateRequests[1].body, contains('file_uri'));
    expect(find.text('青空'), findsOneWidget);
  });

  testWidgets(
      'HomePage chat follow-up shows classified error immediately without retry on HTTP 500',
      (WidgetTester tester) async {
    final requests = <http.Request>[];
    final mockClient = MockClient((request) async {
      requests.add(request);
      if (_isUploadRequest(request)) {
        return _filesUploadSuccessResponse();
      }
      if (requests.where(_isGenerateRequest).length == 1) {
        return _geminiSuccessResponse('青い空の画像');
      }
      return http.Response('Server Error', 500);
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'もっと短くして');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(requests.where(_isUploadRequest), hasLength(1));
    expect(requests.where(_isGenerateRequest), hasLength(2));
    expect(find.textContaining('（詳細: HTTP 500）'), findsOneWidget);
  });

  testWidgets(
      'HomePage sends best-effort non-retried DELETE on reset, new image, and dispose without blocking or showing errors',
      (WidgetTester tester) async {
    final deleteRequests = <http.Request>[];
    var uploadIndex = 0;

    final mockClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        uploadIndex++;
        return _filesUploadSuccessResponse(name: 'files/img-$uploadIndex');
      }
      if (_isGenerateRequest(request)) {
        return _geminiSuccessResponse('結果 $uploadIndex');
      }
      if (_isDeleteRequest(request)) {
        deleteRequests.add(request);
        // Simulate offline failure on DELETE: must NOT retry and must NOT display error!
        throw const SocketException('offline during delete');
      }
      return http.Response('{}', 200);
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    // 1. Reset triggers DELETE once (no retry, no error shown)
    await tester.tap(find.byTooltip('リセット'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));

    expect(deleteRequests, hasLength(1));
    expect(deleteRequests[0].url.path, '/v1beta/files/img-1');
    expect(deleteRequests[0].headers['x-goog-api-key'], 'test-key');
    expect(find.textContaining('エラー'), findsNothing);

    // 2. Pick image -> generate -> pick another image triggers DELETE for img-2
    await _selectTestImage(tester);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    await _selectTestImage(
      tester,
      bytes: _minimalJpeg,
      filename: 'second.jpg',
      useBottomIcon: true,
    );
    await tester.pump(const Duration(seconds: 3));

    expect(deleteRequests, hasLength(2));
    expect(deleteRequests[1].url.path, '/v1beta/files/img-2');
    expect(find.textContaining('エラー'), findsNothing);

    // 3. Generate img-3 -> dispose screen triggers DELETE for img-3
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));

    expect(deleteRequests, hasLength(3));
    expect(deleteRequests[2].url.path, '/v1beta/files/img-3');
  });

  testWidgets(
      'Changing API key in Settings discards cached file_uri, deletes old file, and re-uploads with new key',
      (WidgetTester tester) async {
    final uploadRequests = <http.Request>[];
    final deleteRequests = <http.Request>[];
    final generateRequests = <http.Request>[];

    final mockClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        uploadRequests.add(request);
        return _filesUploadSuccessResponse(
          name: 'files/key-file-${uploadRequests.length}',
        );
      }
      if (_isDeleteRequest(request)) {
        deleteRequests.add(request);
        return http.Response('{}', 200);
      }
      if (_isGenerateRequest(request)) {
        generateRequests.add(request);
        return _geminiSuccessResponse('応答 ${generateRequests.length}');
      }
      return http.Response('{}', 200);
    });

    await _pumpHomeWithSelectedImage(
      tester,
      httpClient: mockClient,
      storageValues: const {'gemini_api_key': 'old-api-key'},
    );
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    expect(uploadRequests, hasLength(1));
    expect(uploadRequests[0].headers['x-goog-api-key'], 'old-api-key');

    // Open Settings and save a new API key
    await tester.tap(find.byTooltip('設定'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Gemini API Key'),
      'new-api-key',
    );
    await tester.tap(find.text('Save API Key'));
    await tester.pumpAndSettle();

    // Navigate back to HomePage and wait for the Settings SnackBar to dismiss
    await tester.pageBack();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Old uploaded file was deleted using old-api-key
    expect(deleteRequests, hasLength(1));
    expect(deleteRequests[0].url.path, '/v1beta/files/key-file-1');
    expect(deleteRequests[0].headers['x-goog-api-key'], 'old-api-key');

    // Follow-up chat re-uploads image under new-api-key and succeeds
    await tester.enterText(find.byType(TextField), 'もっと詳しく');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(uploadRequests, hasLength(2));
    expect(uploadRequests[1].headers['x-goog-api-key'], 'new-api-key');
    expect(generateRequests.last.headers['x-goog-api-key'], 'new-api-key');
    expect(
      generateRequests.last.body,
      contains('files/key-file-2'),
    );
  });

  testWidgets(
      '30s timeout aborts underlying request via abortTrigger and immediately releases ChatSession mutex for next follow-up',
      (WidgetTester tester) async {
    var generateCallCount = 0;
    late _AbortAwareMockClient transport;
    transport = _AbortAwareMockClient((request, bytes, abortTrigger) {
      if (_isUploadRequest(request)) {
        return Future.value(_toStreamedResponse(_filesUploadSuccessResponse()));
      }
      if (_isGenerateRequest(request)) {
        generateCallCount++;
        if (generateCallCount == 1) {
          return Future.value(
            _toStreamedResponse(_geminiSuccessResponse('初回Alt')),
          );
        }
        if (generateCallCount == 2) {
          // Hang until aborted at 30s
          final completer = Completer<http.StreamedResponse>();
          abortTrigger?.whenComplete(() {
            if (!completer.isCompleted) {
              completer.completeError(http.RequestAbortedException(request.url));
            }
          });
          return completer.future;
        }
        // Immediate follow-up retry succeeds
        return Future.value(
          _toStreamedResponse(_geminiSuccessResponse('タイムアウト後の再試行成功')),
        );
      }
      return Future.value(_toStreamedResponse(http.Response('{}', 200)));
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: transport);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    // Trigger hanging follow-up chat
    await tester.enterText(find.byType(TextField), '短くして');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    final hangingIndex = transport.requests.length - 1;
    expect(transport.abortedFlags[hangingIndex], isFalse);

    // Advance FakeAsync by 30s -> abortTrigger completes and timeout error shows
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(transport.abortedFlags[hangingIndex], isTrue);
    expect(find.textContaining('タイムアウト'), findsOneWidget);
    expect(find.textContaining('（詳細: Timeout 30s）'), findsOneWidget);

    // Immediately send another follow-up -> ChatSession._mutex is NOT deadlocked
    await tester.enterText(find.byType(TextField), 'もう一度短くして');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('タイムアウト後の再試行成功'), findsOneWidget);
  });

  testWidgets(
      'Reset button aborts in-flight request via abortTrigger without adding an error message',
      (WidgetTester tester) async {
    late _AbortAwareMockClient transport;
    transport = _AbortAwareMockClient((request, bytes, abortTrigger) {
      final completer = Completer<http.StreamedResponse>();
      abortTrigger?.whenComplete(() {
        if (!completer.isCompleted) {
          completer.completeError(http.RequestAbortedException(request.url));
        }
      });
      return completer.future;
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: transport);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pump();
    await tester.pump();

    expect(transport.requests, hasLength(1));
    expect(transport.abortedFlags.single, isFalse);

    await tester.tap(find.byTooltip('リセット'));
    await tester.pumpAndSettle();

    expect(transport.abortedFlags.single, isTrue);
    expect(find.text('タップして画像を選択'), findsOneWidget);
    expect(find.textContaining('エラー'), findsNothing);
    expect(find.textContaining('タイムアウト'), findsNothing);
  });

  testWidgets(
      'SettingsPage API key verification times out and aborts at 30s',
      (WidgetTester tester) async {
    _setMockStorage(const {});
    final transport = _AbortAwareMockClient((request, bytes, abortTrigger) {
      final completer = Completer<http.StreamedResponse>();
      abortTrigger?.whenComplete(() {
        if (!completer.isCompleted) {
          completer.completeError(http.RequestAbortedException(request.url));
        }
      });
      return completer.future;
    });

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: transport));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Gemini API Key'),
      'slow-key',
    );
    await tester.tap(find.text('Save API Key'));
    await tester.pump();
    expect(find.text('検証中...'), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();

    expect(transport.abortedFlags.single, isTrue);
    expect(find.text('Save API Key'), findsOneWidget);
    expect(find.textContaining('（詳細: Timeout 30s）'), findsOneWidget);
  });

  testWidgets(
      'Transient HTTP 503 and SocketException automatically retry up to 2 times and succeed within 30s',
      (WidgetTester tester) async {
    var generateAttempts = 0;
    final mockClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        return _filesUploadSuccessResponse();
      }
      if (_isGenerateRequest(request)) {
        generateAttempts++;
        if (generateAttempts == 1) {
          throw const SocketException('transient drop');
        }
        if (generateAttempts == 2) {
          return http.Response('Service Unavailable', 503);
        }
        return _geminiSuccessResponse('リトライ後に成功したAlt');
      }
      return http.Response('{}', 200);
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pump();
    // Advance past 0.5s + 1.5s retry delays
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(generateAttempts, 3);
    expect(find.text('リトライ後に成功したAlt'), findsOneWidget);
  });

  testWidgets(
      'SettingsPage classifies auth error without bracket truncation and masks API key secrets',
      (WidgetTester tester) async {
    _setMockStorage(const {});
    const secretKey = 'AIzaSySecretTestKeyDoNotExpose999';
    var attempts = 0;

    final mockClient = MockClient((request) async {
      attempts++;
      return http.Response(
        jsonEncode({
          'error': {
            'code': 400,
            'message': '[GoogleAuth] API key not valid: $secretKey',
            'details': [
              {'reason': 'API_KEY_INVALID'}
            ],
          },
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: mockClient));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Gemini API Key'),
      secretKey,
    );
    await tester.tap(find.text('Save API Key'));
    await tester.pumpAndSettle();

    // Must NOT retry HTTP 400 / InvalidApiKey
    expect(attempts, 1);
    expect(find.textContaining('APIキーが無効'), findsOneWidget);
    expect(find.textContaining('（詳細: InvalidApiKey）'), findsOneWidget);
    // Secret key must NEVER appear in the snackbar error output
    final snackBarFinder = find.byType(SnackBar);
    expect(snackBarFinder, findsOneWidget);
    expect(
      find.descendant(
        of: snackBarFinder,
        matching: find.textContaining(secretKey),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: snackBarFinder,
        matching: find.textContaining('AIzaSy'),
      ),
      findsNothing,
    );
  });

  testWidgets('HomePage classifies SAFETY response with SAFETY detail label',
      (WidgetTester tester) async {
    final mockClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        return _filesUploadSuccessResponse();
      }
      return http.Response(
        jsonEncode({
          'promptFeedback': {
            'blockReason': 'SAFETY',
            'safetyRatings': <Object>[],
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    expect(find.textContaining('安全性ポリシー'), findsOneWidget);
    expect(find.textContaining('（詳細: SAFETY）'), findsOneWidget);
  });

  testWidgets(
      'HomePage classifies exhausted network error (SocketException) after 2 retries and masks secrets',
      (WidgetTester tester) async {
    const secretKey = 'AIzaSyHomeSecretKey987654321';
    var networkAttempts = 0;
    final networkClient = MockClient((request) async {
      networkAttempts++;
      throw const SocketException('Connection refused for key=$secretKey');
    });

    await _pumpHomeWithSelectedImage(
      tester,
      httpClient: networkClient,
      storageValues: const {'gemini_api_key': secretKey},
    );
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(networkAttempts, 3);
    expect(find.textContaining('通信エラー'), findsOneWidget);
    expect(find.textContaining('（詳細: SocketException）'), findsOneWidget);
    expect(find.textContaining(secretKey), findsNothing);
  });

  testWidgets(
      'HomePage classifies exhausted HTTP 503 after 2 retries and masks secrets',
      (WidgetTester tester) async {
    const secretKey = 'AIzaSyHomeSecretKey987654321';
    var busyAttempts = 0;
    final busyClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        return _filesUploadSuccessResponse();
      }
      if (_isDeleteRequest(request)) {
        return http.Response('{}', 200);
      }
      busyAttempts++;
      return http.Response('Service Unavailable $secretKey', 503);
    });

    await _pumpHomeWithSelectedImage(
      tester,
      httpClient: busyClient,
      storageValues: const {'gemini_api_key': secretKey},
    );
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(busyAttempts, 3);
    expect(find.textContaining('サーバーが混雑'), findsOneWidget);
    expect(find.textContaining('（詳細: HTTP 503）'), findsOneWidget);
    expect(find.textContaining(secretKey), findsNothing);
  });

  testWidgets(
      'HomePage classifies HTTP 400 as other without retry and masks secrets',
      (WidgetTester tester) async {
    const secretKey = 'AIzaSyHomeSecretKey987654321';
    var badRequestAttempts = 0;
    final badRequestClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        return _filesUploadSuccessResponse();
      }
      if (_isDeleteRequest(request)) {
        return http.Response('{}', 200);
      }
      badRequestAttempts++;
      return http.Response(
        jsonEncode({
          'error': {
            'code': 400,
            'message': 'Invalid argument for $secretKey',
          },
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    });

    await _pumpHomeWithSelectedImage(
      tester,
      httpClient: badRequestClient,
      storageValues: const {'gemini_api_key': secretKey},
    );
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    expect(badRequestAttempts, 1);
    expect(find.textContaining('予期しないエラー'), findsOneWidget);
    expect(find.textContaining('（詳細: HTTP 400）'), findsOneWidget);
    expect(find.textContaining(secretKey), findsNothing);
  });

  testWidgets(
      'HomePage offers gallery and camera in bottom sheet and passes 1536px / quality 85 to image_picker',
      (WidgetTester tester) async {
    _setMockStorage();
    final imageFile = _createTempSampleImage();
    final pickerCalls = _mockImagePickerChannel(imageFile);

    await tester.pumpWidget(const AltTextGeneratorApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('タップして画像を選択'));
    await tester.pumpAndSettle();

    expect(find.text('ライブラリから選択'), findsOneWidget);
    expect(find.text('カメラで撮影'), findsOneWidget);
    expect(find.text('ファイルから選択'), findsNothing);

    await _selectImageSourceAndWait(tester, 'カメラで撮影');

    expect(pickerCalls, hasLength(1));
    expect(pickerCalls.single.method, 'pickImage');
    final args = pickerCalls.single.arguments as Map;
    expect(args['source'], ImageSource.camera.index);
    expect(args['maxWidth'], 1536.0);
    expect(args['maxHeight'], 1536.0);
    expect(args['imageQuality'], 85);
    expect(find.text('Altテキストを生成'), findsOneWidget);
  });

  testWidgets('HomePage has no history button or /history route',
      (WidgetTester tester) async {
    _setMockStorage();

    await tester.pumpWidget(const AltTextGeneratorApp());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.history), findsNothing);
    expect(find.byTooltip('履歴'), findsNothing);
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.routes?.containsKey('/history'), isFalse);
  });

  testWidgets(
      'HomePage renders chat messages as SelectableText and copies AI response to clipboard',
      (WidgetTester tester) async {
    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    var generateCount = 0;
    final mockClient = MockClient((request) async {
      if (_isUploadRequest(request)) {
        return _filesUploadSuccessResponse();
      }
      generateCount++;
      if (generateCount == 1) {
        return _geminiSuccessResponse('青い空の画像');
      }
      return _geminiSuccessResponse('青空');
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'もっと短くして');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(SelectableText, '画像の代替テキストを生成中...'),
      findsOneWidget,
    );
    expect(find.widgetWithText(SelectableText, '青い空の画像'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, 'もっと短くして'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, '青空'), findsOneWidget);

    await tester.tap(find.text('Copy').first);
    await tester.pumpAndSettle();

    expect(copiedText, '青い空の画像');
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });
}
