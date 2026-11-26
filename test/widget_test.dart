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
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_alt_generator/main.dart';

const List<int> _transparent1x1Png = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0,
  0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1,
  13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

Future<void> _selectTestImage(WidgetTester tester) async {
  final tempDir = Directory.systemTemp.createTempSync('alt_test_');
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  final imageFile = File('${tempDir.path}/sample.png')
    ..writeAsBytesSync(_transparent1x1Png);

  const fileSelectorChannel = MethodChannel('plugins.flutter.io/file_selector');
  const fileSelectorMacOsChannel =
      'dev.flutter.pigeon.file_selector_macos.FileSelectorApi.displayOpenPanel';
  const imagePickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(fileSelectorChannel, (call) async {
    if (call.method == 'openFile') {
      return <String>[imageFile.path];
    }
    return null;
  });
  messenger.setMockMessageHandler(fileSelectorMacOsChannel, (message) async {
    return const StandardMessageCodec()
        .encodeMessage(<Object?>[<String>[imageFile.path]]);
  });
  messenger.setMockMethodCallHandler(imagePickerChannel, (call) async {
    if (call.method == 'pickImage') {
      return imageFile.path;
    }
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(fileSelectorChannel, null);
    messenger.setMockMessageHandler(fileSelectorMacOsChannel, null);
    messenger.setMockMethodCallHandler(imagePickerChannel, null);
  });

  await tester.tap(find.text('タップして画像を選択'));
  await tester.pumpAndSettle();

  if (Platform.isMacOS) {
    await tester.tap(find.text('ファイルから選択'));
  } else {
    await tester.tap(find.text('ライブラリから選択'));
  }
  await tester.pumpAndSettle();
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
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

void main() {
  testWidgets('App title smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const AltTextGeneratorApp());

    // Verify that our app title is displayed.
    expect(find.text('Alt 生成くん'), findsOneWidget);
  });

  testWidgets('SettingsPage hides model priority UI and shows gemini-4-hydrogen read-only',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'gemini_api_key': 'test-key'});
    FlutterSecureStorage.setMockInitialValues({'gemini_api_key': 'test-key'});

    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('モデル優先順位'), findsNothing);
    expect(find.text('ドラッグ＆ドロップで並べ替え'), findsNothing);
    expect(find.text('モデル順を保存'), findsNothing);
    expect(find.text('gemini-4-hydrogen'), findsOneWidget);
  });

  testWidgets('SettingsPage validates API key once against gemini-4-hydrogen and ignores legacy model_order',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'model_order': '["gemini-3.1-pro"]',
    });
    FlutterSecureStorage.setMockInitialValues({
      'model_order': '["gemini-3.1-pro"]',
    });

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
    SharedPreferences.setMockInitialValues({
      'gemini_api_key': 'test-key',
      'model_order': '["gemini-3.1-pro"]',
    });
    FlutterSecureStorage.setMockInitialValues({
      'gemini_api_key': 'test-key',
      'model_order': '["gemini-3.1-pro"]',
    });

    final requestedUris = <Uri>[];
    final completer = Completer<http.Response>();
    final mockClient = MockClient((request) {
      requestedUris.add(request.url);
      return completer.future;
    });

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: mockClient));
    await tester.pumpAndSettle();

    await _selectTestImage(tester);
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
    SharedPreferences.setMockInitialValues({'gemini_api_key': 'test-key'});
    FlutterSecureStorage.setMockInitialValues({'gemini_api_key': 'test-key'});

    final requestedUris = <Uri>[];
    final mockClient = MockClient((request) async {
      requestedUris.add(request.url);
      return http.Response('Server Error', 500);
    });

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: mockClient));
    await tester.pumpAndSettle();

    await _selectTestImage(tester);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    expect(requestedUris, hasLength(1));
    expect(requestedUris.single.path, endsWith('/models/gemini-4-hydrogen:generateContent'));
    expect(find.text('エラーが発生しました。時間をおいて再試行してください。'), findsOneWidget);
  });

  testWidgets('HomePage chat follow-up sends one request to gemini-4-hydrogen with generic loading text',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'gemini_api_key': 'test-key'});
    FlutterSecureStorage.setMockInitialValues({'gemini_api_key': 'test-key'});

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

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: mockClient));
    await tester.pumpAndSettle();

    await _selectTestImage(tester);
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
    SharedPreferences.setMockInitialValues({'gemini_api_key': 'test-key'});
    FlutterSecureStorage.setMockInitialValues({'gemini_api_key': 'test-key'});

    final requestedUris = <Uri>[];
    final mockClient = MockClient((request) async {
      requestedUris.add(request.url);
      if (requestedUris.length == 1) {
        return _geminiSuccessResponse('青い空の画像');
      }
      return http.Response('Server Error', 500);
    });

    await tester.pumpWidget(AltTextGeneratorApp(httpClient: mockClient));
    await tester.pumpAndSettle();

    await _selectTestImage(tester);
    await tester.tap(find.text('Altテキストを生成'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'もっと短くして');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(requestedUris, hasLength(2));
    expect(requestedUris[1].path, endsWith('/models/gemini-4-hydrogen:generateContent'));
    expect(find.text('エラーが発生しました。'), findsOneWidget);
  });
}
