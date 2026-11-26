// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

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

File _createTempSampleImage() {
  final tempDir = Directory.systemTemp.createTempSync('alt_test_');
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  return File('${tempDir.path}/sample.png')
    ..writeAsBytesSync(_transparent1x1Png);
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

Future<void> _selectTestImage(WidgetTester tester) async {
  final imageFile = _createTempSampleImage();
  _mockImagePickerChannel(imageFile);

  await tester.tap(find.text('タップして画像を選択'));
  await tester.pumpAndSettle();

  await _selectImageSourceAndWait(tester, 'ライブラリから選択');
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

void _setMockStorage([
  Map<String, String> values = const {'gemini_api_key': 'test-key'},
]) {
  FlutterSecureStorage.setMockInitialValues(Map<String, String>.from(values));
}

Future<void> _pumpHomeWithSelectedImage(
  WidgetTester tester, {
  required http.Client httpClient,
  Map<String, String> storageValues = const {'gemini_api_key': 'test-key'},
}) async {
  _setMockStorage(storageValues);
  await tester.pumpWidget(AltTextGeneratorApp(httpClient: httpClient));
  await tester.pumpAndSettle();
  await _selectTestImage(tester);
}

void main() {
  testWidgets('App title smoke test', (WidgetTester tester) async {
    _setMockStorage();
    // Build our app and trigger a frame.
    await tester.pumpWidget(const AltTextGeneratorApp());

    // Verify that our app title is displayed.
    expect(find.text('Alt 生成くん'), findsOneWidget);
  });

  testWidgets('SettingsPage hides model priority UI and shows gemini-4-hydrogen read-only',
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

  testWidgets('SettingsPage validates API key once against gemini-4-hydrogen and ignores legacy model_order',
      (WidgetTester tester) async {
    _setMockStorage(const {'model_order': '["gemini-3.1-pro"]'});

    final requestedUris = <Uri>[];
    final mockClient = MockClient((request) async {
      requestedUris.add(request.url);
      return _geminiSuccessResponse('ok');
    });

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: mockClient));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Gemini API Key'), 'new-test-key');
    await tester.tap(find.text('Save API Key'));
    await tester.pumpAndSettle();

    expect(requestedUris, hasLength(1));
    expect(requestedUris.single.path, endsWith('/models/gemini-4-hydrogen:generateContent'));
    expect(find.text('API Keyを確認し、保存しました'), findsOneWidget);
  });

  testWidgets('HomePage generates alt text once with gemini-4-hydrogen and generic loading text',
      (WidgetTester tester) async {
    final requestedUris = <Uri>[];
    final completer = Completer<http.Response>();
    final mockClient = MockClient((request) {
      requestedUris.add(request.url);
      return completer.future;
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

    expect(find.text('Altテキストを生成中...'), findsOneWidget);
    expect(find.textContaining('gemini'), findsNothing);
    expect(find.textContaining('モデルを選択中'), findsNothing);
    expect(find.textContaining('試行中'), findsNothing);

    completer.complete(_geminiSuccessResponse('青い空の画像'));
    await tester.pumpAndSettle();

    expect(requestedUris, hasLength(1));
    expect(requestedUris.single.path, endsWith('/models/gemini-4-hydrogen:generateContent'));
    expect(find.text('青い空の画像'), findsOneWidget);
  });

  testWidgets('HomePage shows error immediately without retry or fallback when alt text generation fails',
      (WidgetTester tester) async {
    final requestedUris = <Uri>[];
    final mockClient = MockClient((request) async {
      requestedUris.add(request.url);
      return http.Response('Server Error', 500);
    });

    await _pumpHomeWithSelectedImage(tester, httpClient: mockClient);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    expect(requestedUris, hasLength(1));
    expect(requestedUris.single.path, endsWith('/models/gemini-4-hydrogen:generateContent'));
    expect(find.text('エラーが発生しました。時間をおいて再試行してください。'), findsOneWidget);
  });

  testWidgets('HomePage chat follow-up sends one request to gemini-4-hydrogen with generic loading text',
      (WidgetTester tester) async {
    final requestedUris = <Uri>[];
    Completer<http.Response>? followUpCompleter;
    final mockClient = MockClient((request) {
      requestedUris.add(request.url);
      if (requestedUris.length == 1) {
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

    expect(requestedUris, hasLength(2));
    expect(requestedUris[1].path, endsWith('/models/gemini-4-hydrogen:generateContent'));
    expect(find.text('青空'), findsOneWidget);
  });

  testWidgets('HomePage chat follow-up shows error immediately without retry or fallback on failure',
      (WidgetTester tester) async {
    final requestedUris = <Uri>[];
    final mockClient = MockClient((request) async {
      requestedUris.add(request.url);
      if (requestedUris.length == 1) {
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

    expect(requestedUris, hasLength(2));
    expect(requestedUris[1].path, endsWith('/models/gemini-4-hydrogen:generateContent'));
    expect(find.text('エラーが発生しました。'), findsOneWidget);
  });

  testWidgets('HomePage offers gallery and camera in bottom sheet and picks camera image via image_picker',
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
    expect((pickerCalls.single.arguments as Map)['source'], ImageSource.camera.index);
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

  testWidgets('HomePage renders chat messages as SelectableText and copies AI response to clipboard',
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

    int callCount = 0;
    final mockClient = MockClient((request) async {
      callCount++;
      if (callCount == 1) {
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

    expect(find.widgetWithText(SelectableText, '画像の代替テキストを生成中...'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, '青い空の画像'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, 'もっと短くして'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, '青空'), findsOneWidget);

    await tester.tap(find.text('Copy').first);
    await tester.pumpAndSettle();

    expect(copiedText, '青い空の画像');
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });
}
