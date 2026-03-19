import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

import 'config.dart';
import 'history_database.dart';
import 'history_page.dart';
import 'dart:io' show Platform;
import 'package:file_selector/file_selector.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'camera_screen.dart';



void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AltTextGeneratorApp());
}

class SecureStorageHelper {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static Future<String?> read({required String key}) async {
    if (Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } else {
      return await _storage.read(key: key);
    }
  }

  static Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      await delete(key: key);
      return;
    }
    
    if (Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } else {
      await _storage.write(key: key, value: value);
    }
  }
  
  static Future<void> delete({required String key}) async {
    if (Platform.isMacOS) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } else {
      await _storage.delete(key: key);
    }
  }
}

class AltTextGeneratorApp extends StatelessWidget {
  const AltTextGeneratorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alt 生成くん',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomePage(),
        '/settings': (context) => const SettingsPage(),
        '/history': (context) => const HistoryPage(),
      },
    );
  }
}

// --- Settings Page ---

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _apiKeyController = TextEditingController();
  final _promptController = TextEditingController();
  static const _apiKeyKey = 'gemini_api_key';
  static const _modelOrderKey = 'model_order';
  static const _customPromptKey = 'custom_initial_prompt';
  bool _isLoading = true;
  bool _isVerifying = false;
  List<String> _modelOrder = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true); // ローディング状態
    final key = await SecureStorageHelper.read(key: _apiKeyKey);
    final modelOrderJson = await SecureStorageHelper.read(key: _modelOrderKey);
    final customPrompt = await SecureStorageHelper.read(key: _customPromptKey);
    
    List<String> loadedOrder = List<String>.from(AppConfig.defaultModelOrder);
    if (modelOrderJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(modelOrderJson);
        loadedOrder = decoded.cast<String>();
        // Check for any missing new models or removed old models
        final defaultSet = AppConfig.defaultModelOrder.toSet();
        final loadedSet = loadedOrder.toSet();
        
        // Add any missing models to the end
        for (final model in AppConfig.defaultModelOrder) {
          if (!loadedSet.contains(model)) {
            loadedOrder.add(model);
          }
        }
        
        // Remove any models that are no longer in default (optional, but good for cleanup)
        loadedOrder.removeWhere((model) => !defaultSet.contains(model));

      } catch (e) {
        debugPrint('Error decoding model order: $e');
      }
    }

    if (mounted) {
      setState(() {
        if (key != null) _apiKeyController.text = key;
        if (customPrompt != null) {
          _promptController.text = customPrompt;
        }
        _modelOrder = loadedOrder;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveApiKey() async {
    final newKey = _apiKeyController.text.trim();
    if (newKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API Keyを入力してください')),
      );
      return;
    }

    setState(() {
      _isVerifying = true;
    });

    try {
      // APIキーの有効性検証
      final model = GenerativeModel(
        model: 'gemini-3.1-flash-lite-preview', 
        apiKey: newKey,
      );
      // テストリクエスト
      await model.generateContent([Content.text('test')]);

      // 保存
      await SecureStorageHelper.write(key: _apiKeyKey, value: newKey);
      await SecureStorageHelper.write(key: _modelOrderKey, value: jsonEncode(_modelOrder));
      await SecureStorageHelper.write(key: _customPromptKey, value: _promptController.text);
      
      if (mounted) {
        FocusScope.of(context).unfocus(); // キーボードを閉じる
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('API Keyを確認し、保存しました'),
            backgroundColor: Colors.green,
          ),
        );
        // Navigator.pop(context) を削除
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('API Keyが無効か、通信エラーです: ${e.toString().split(']').last.trim()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isVerifying = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: true,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: colorScheme.surfaceTint,
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // --- API Key Section ---
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.key, color: Colors.teal.shade600, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'API Key',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.teal.shade700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _apiKeyController,
                                decoration: InputDecoration(
                                  labelText: 'Gemini API Key',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  helperText: 'Enter your Gemini API key here.',
                                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                                ),
                                autofillHints: const [AutofillHints.password],
                                obscureText: true,
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: _isVerifying ? null : _saveApiKey,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.teal.shade600,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  icon: _isVerifying
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ))
                                      : const Icon(Icons.save),
                                  label: Text(_isVerifying ? '検証中...' : 'Save API Key'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // --- Model Priority Section ---
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.swap_vert, color: Colors.deepPurple.shade600, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'モデル優先順位',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.deepPurple.shade700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'ドラッグ＆ドロップで並べ替え',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                clipBehavior: Clip.antiAlias,
                                height: 56.0 * _modelOrder.length + 16, // Dynamic height
                                child: ReorderableListView(
                                  buildDefaultDragHandles: false,
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  proxyDecorator: (child, index, animation) {
                                    return AnimatedBuilder(
                                      animation: animation,
                                      builder: (context, child) {
                                        return Material(
                                          elevation: 4,
                                          borderRadius: BorderRadius.circular(8),
                                          color: Colors.deepPurple.shade50,
                                          shadowColor: Colors.deepPurple.shade200,
                                          child: child,
                                        );
                                      },
                                      child: child,
                                    );
                                  },
                                  children: [
                                    for (int index = 0; index < _modelOrder.length; index++)
                                      ReorderableDragStartListener(
                                        key: Key(_modelOrder[index]),
                                        index: index,
                                        child: Container(
                                          height: 48,
                                          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: colorScheme.surface,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: index == 0
                                                  ? Colors.deepPurple.shade300
                                                  : Colors.grey.shade200,
                                              width: index == 0 ? 1.5 : 1,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 36,
                                                alignment: Alignment.center,
                                                child: Container(
                                                  width: 24,
                                                  height: 24,
                                                  decoration: BoxDecoration(
                                                    color: index == 0
                                                        ? Colors.deepPurple.shade600
                                                        : Colors.grey.shade400,
                                                    borderRadius: BorderRadius.circular(12),
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: Text(
                                                    '${index + 1}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  _modelOrder[index],
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: index == 0
                                                        ? FontWeight.w600
                                                        : FontWeight.normal,
                                                    color: index == 0
                                                        ? Colors.deepPurple.shade700
                                                        : null,
                                                  ),
                                                ),
                                              ),
                                              Icon(
                                                Icons.drag_indicator,
                                                color: Colors.grey.shade400,
                                                size: 20,
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                  onReorder: (int oldIndex, int newIndex) {
                                    setState(() {
                                      if (oldIndex < newIndex) {
                                        newIndex -= 1;
                                      }
                                      final String item = _modelOrder.removeAt(oldIndex);
                                      _modelOrder.insert(newIndex, item);
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () async {
                                        await SecureStorageHelper.write(
                                          key: _modelOrderKey,
                                          value: jsonEncode(_modelOrder),
                                        );
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('モデル順を保存しました'),
                                              backgroundColor: Colors.green,
                                            ),
                                          );
                                        }
                                      },
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.deepPurple.shade600,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(Icons.save, size: 18),
                                      label: const Text('モデル順を保存'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () async {
                                      setState(() {
                                        _modelOrder = List<String>.from(AppConfig.defaultModelOrder);
                                      });
                                      await SecureStorageHelper.delete(key: _modelOrderKey);
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('デフォルトに戻しました'),
                                          ),
                                        );
                                      }
                                    },
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    child: const Text('デフォルトに戻す'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // --- Custom Prompt Section ---
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.edit_note, color: Colors.amber.shade800, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'カスタム初期プロンプト',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.amber.shade900,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '標準設定: ${AppConfig.initialPromptDefault}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextField(
                                controller: _promptController,
                                maxLines: 4,
                                maxLength: AppConfig.maxPromptLength,
                                decoration: InputDecoration(
                                  hintText: 'ここにカスタムプロンプトを入力...',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () async {
                                        final text = _promptController.text.trim();
                                        if (text.length > AppConfig.maxPromptLength) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('プロンプトが長すぎます')),
                                          );
                                          return;
                                        }
                                        
                                        await SecureStorageHelper.write(
                                            key: _customPromptKey,
                                            value: text);
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                                content:
                                                    Text('プロンプトを保存しました')),
                                          );
                                        }
                                      },
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.amber.shade800,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(Icons.save, size: 18),
                                      label: const Text('プロンプトを保存'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () async {
                                      await SecureStorageHelper.delete(key: _customPromptKey);
                                      setState(() {
                                        _promptController.clear();
                                      });
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                              content: Text('デフォルトに戻しました')),
                                        );
                                      }
                                    },
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    child: const Text('リセット'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

// --- Home Page ---

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = ImagePicker();
  final _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Uint8List? _imageBytes; // Changed from File? to Uint8List? for Web support
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  ChatSession? _chatSession;
  GenerativeModel? _model;
  String _statusMessage = '';

  static const _apiKeyKey = 'gemini_api_key';
  static const _modelOrderKey = 'model_order';
  List<String> _modelHierarchy = List<String>.from(AppConfig.defaultModelOrder);
  int _currentModelIndex = 0;
  int? _currentHistoryId;
  String? _customPrompt; // 追加

  bool get _isCustomPromptActive => _customPrompt != null && _customPrompt!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _checkApiKey();
  }

  Future<void> _checkApiKey() async {
    final key = await SecureStorageHelper.read(key: _apiKeyKey);
    final modelOrderJson = await SecureStorageHelper.read(key: _modelOrderKey);
    final customPrompt = await SecureStorageHelper.read(key: 'custom_initial_prompt');

    if (key == null) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.pushNamed(context, '/settings');
        });
      }
    } else {
      // モデル階層とカスタムプロンプトの動的構築
      List<String> hierarchy = List<String>.from(AppConfig.defaultModelOrder);
      
      if (modelOrderJson != null) {
        try {
          final List<dynamic> decoded = jsonDecode(modelOrderJson);
          hierarchy = decoded.cast<String>();
          // Ensure at least default models are present if something is weird, or just trust the user
          if (hierarchy.isEmpty) {
            hierarchy = AppConfig.defaultModelOrder;
          }
        } catch (e) {
          debugPrint('Error loading model order in HomePage: $e');
        }
      }
      
      setState(() {
        _modelHierarchy = hierarchy;
        _customPrompt = customPrompt; // ステートを更新
      });
      _initModel(key);
    }
  }

  void _initModel(String apiKey) {
    if (_modelHierarchy.isEmpty) return; // Should not happen given defaults
    _model = GenerativeModel(
      model: _modelHierarchy[_currentModelIndex],
      apiKey: apiKey,
    );
  }

  Future<void> _pickImage() async {
    if (Platform.isMacOS) {
      await _pickImageMacOS();
    } else {
      await _pickImageMobile();
    }
  }

  Future<void> _pickImageMobile() async {
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('ライブラリから選択'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('カメラで撮影'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    final pickedFile = await _picker.pickImage(source: source);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      setState(() {
        _imageBytes = bytes;
        _messages = [];
        _chatSession = null;
      });
    }
  }

  Future<void> _pickImageMacOS() async {
    final source = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('画像を選択'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('ファイルから選択'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('カメラで撮影'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
          ],
        ),
      ),
    );

    if (source == 'file') {
      const XTypeGroup typeGroup = XTypeGroup(
        label: 'images',
        extensions: ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'],
      );
      final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file != null) {
        final bytes = await file.readAsBytes();
        setState(() {
          _imageBytes = bytes;
          _messages = [];
          _chatSession = null;
        });
      }
    } else if (source == 'camera') {
      await _takePictureWithCamera();
    }
  }

  Future<void> _takePictureWithCamera() async {
    try {
      CameraDescription? camera;
      
      if (!Platform.isMacOS) {
        final cameras = await availableCameras();
        if (cameras.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('カメラが見つかりません')),
            );
          }
          return;
        }
        camera = cameras.first;
      }

      final result = await Navigator.push<XFile>(
        context,
        MaterialPageRoute(
          builder: (context) => CameraScreen(camera: camera),
        ),
      );

      if (result != null) {
        final bytes = await result.readAsBytes();
        setState(() {
          _imageBytes = bytes;
          _messages = [];
          _chatSession = null;
        });
      }
    } catch (e) {
      debugPrint('Error accessing camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('カメラへのアクセスに失敗しました')),
        );
      }
    }
  }

  Future<void> _generateAltText() async {
    if (_imageBytes == null) return;

    final key = await SecureStorageHelper.read(key: _apiKeyKey);
    if (key == null) {
      if (mounted) Navigator.pushNamed(context, '/settings');
      return;
    }

    final customPrompt = await SecureStorageHelper.read(key: 'custom_initial_prompt');
    final prompt = (customPrompt != null && customPrompt.isNotEmpty)
        ? customPrompt
        : AppConfig.initialPromptDefault;

    final userMessage = _isCustomPromptActive ? 'カスタム指示を実行中...' : '画像の代替テキストを生成中...';

    setState(() {
      _isLoading = true;
      _statusMessage = 'モデルを選択中...';
      _messages.add(ChatMessage(role: 'user', text: userMessage));
    });

    for (int i = 0; i < _modelHierarchy.length; i++) {
      final modelName = _modelHierarchy[i];
      try {
        _currentModelIndex = i;
        _initModel(key);
        setState(() {
          _statusMessage = '$modelName で生成を試行中...';
        });

        final content = [
          Content.multi([
            TextPart(prompt),
            DataPart('image/jpeg', _imageBytes!),
          ])
        ];

        _chatSession = _model!.startChat();
        final response = await _chatSession!.sendMessage(content.first).timeout(
          Duration(seconds: AppConfig.timeoutSeconds), // const削除
          onTimeout: () => throw Exception('タイムアウトしました'),
        );

        if (mounted) {
          final generatedText = _cleanAiText(response.text ?? 'No response');
          setState(() {
            _messages.add(ChatMessage(role: 'model', text: generatedText));
            _isLoading = false;
            _statusMessage = '';
          });
          if (response.text != null) {
            _saveToHistory(generatedText);
          }
        }
        return;
      } catch (e) {
        debugPrint('Error with $modelName: $e');
        
        if (i == _modelHierarchy.length - 1) {
          // 最後のモデルでも失敗した場合のみユーザーに通知
          String userError = 'エラーが発生しました。時間をおいて再試行してください。';
          String errorMsg = e.toString();
          if (errorMsg.contains('SAFETY') || errorMsg.contains('safety')) {
            userError = '安全性ポリシーによりこの画像は処理できませんでした。';
          }
          
          if (mounted) {
            setState(() {
              _messages.add(ChatMessage(role: 'model', text: userError));
              _isLoading = false;
              _statusMessage = '';
            });
          }
        } else {
          setState(() {
            _statusMessage = '$modelName が失敗しました。次のモデルを試します...';
          });
        }
      }
    }
  }

  Future<void> _sendMessage() async {
    if (_textController.text.isEmpty || _chatSession == null) return;

    final key = await SecureStorageHelper.read(key: _apiKeyKey);
    if (key == null) return;

    final userMessage = _textController.text;
    setState(() {
      _messages.add(ChatMessage(role: 'user', text: userMessage));
      _isLoading = true;
      _statusMessage = '回答を生成中...';
      _textController.clear();
    });

    _scrollToBottom();

    for (int i = _currentModelIndex; i < _modelHierarchy.length; i++) {
      final modelName = _modelHierarchy[i];
      try {
        setState(() {
          _statusMessage = '$modelName で回答を生成中...';
        });

        if (i != _currentModelIndex) {
          _currentModelIndex = i;
          _initModel(key);
          final history = _chatSession?.history.toList() ?? [];
          _chatSession = _model!.startChat(history: history);
        }

        final response = await _chatSession!.sendMessage(Content.text(userMessage)).timeout(
              Duration(seconds: AppConfig.timeoutSeconds), // const削除
              onTimeout: () => throw Exception('タイムアウトしました'),
            );
        if (mounted) {
          setState(() {
            _messages.add(ChatMessage(role: 'model', text: _cleanAiText(response.text ?? 'No response')));
            _isLoading = false;
            _statusMessage = '';
          });
          _scrollToBottom();
          // チャットの続きも履歴に保存（タイトルは最初の生成結果を維持）
          final historyTitle = _messages.firstWhere((m) => m.role == 'model', orElse: () => _messages.first).text;
          _saveToHistory(historyTitle);
        }
        return;
      } catch (e) {
        debugPrint('Error with $modelName during send: $e');
        
        if (i == _modelHierarchy.length - 1) {
           String userError = 'エラーが発生しました。';
           String errorMsg = e.toString();
           if (errorMsg.contains('SAFETY') || errorMsg.contains('safety')) {
             userError = '安全性ポリシーにより回答できませんでした。';
           }

          if (mounted) {
            setState(() {
              _messages.add(ChatMessage(role: 'model', text: userError));
              _isLoading = false;
              _statusMessage = '';
            });
          }
        } else {
          setState(() {
            _statusMessage = '$modelName が失敗しました。次のモデルを試します...';
          });
        }
      }
    }
  }

  void _regenerateLatestResponse() {
    if (_messages.isEmpty) return;

    // 最新のユーザーメッセージを探す
    int lastUserIndex = -1;
    for (int i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') {
        lastUserIndex = i;
        break;
      }
    }

    if (lastUserIndex == -1) return;

    final lastUserMsg = _messages[lastUserIndex];

    // そのユーザーメッセージ以降をすべて削除
    setState(() {
      _messages.removeRange(lastUserIndex, _messages.length);
    });

    if (lastUserMsg.text == '画像の代替テキストを生成中...' || lastUserMsg.text == 'カスタム指示を実行中...') {
      _generateAltText();
    } else {
      _textController.text = lastUserMsg.text;
      _sendMessage();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _restoreFromHistory(HistoryItem item) async {
    final key = await SecureStorageHelper.read(key: _apiKeyKey);
    if (key == null) return;

    setState(() {
      _isLoading = true;
      _statusMessage = 'チャットを復元中...';
    });

    try {
      final messages = (jsonDecode(item.messagesJson ?? '[]') as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList();

      setState(() {
        _imageBytes = item.fullImage;
        _messages = messages;
        _isLoading = false;
        _statusMessage = '';
        _currentHistoryId = item.id; // セッションIDをセット
      });

      // Re-initialize model and chat session with history
      _initModel(key);
      final history = messages
          .map((m) => Content(m.role, [TextPart(m.text)]))
          .toList();
      
      // Remove the last message if it's from the model, because startChat will use it
      // Actually, startChat(history: ...) expects the full history.
      _chatSession = _model!.startChat(history: history);
    } catch (e) {
      debugPrint('Error restoring history: $e');
      setState(() {
        _isLoading = false;
        _statusMessage = '';
      });
    }
  }

  Future<void> _saveToHistory(String text) async {
    if (_imageBytes == null) return;

    try {
      final originalImage = img.decodeImage(_imageBytes!);
      if (originalImage == null) return;

      // サムネイル作成 (100x100程度)
      final thumbnailImage = img.copyResize(originalImage, width: 100);
      final thumbnailBytes = Uint8List.fromList(img.encodePng(thumbnailImage));

      // 解析用のフル画像を少し圧縮して保存 (max 1024px)
      img.Image optimizedImage = originalImage;
      if (originalImage.width > 1024 || originalImage.height > 1024) {
        optimizedImage = img.copyResize(originalImage,
            width: originalImage.width > originalImage.height ? 1024 : null,
            height: originalImage.height >= originalImage.width ? 1024 : null);
      }
      final fullImageBytes = Uint8List.fromList(img.encodeJpg(optimizedImage, quality: 80));

      final item = HistoryItem(
        id: _currentHistoryId, // 指定があれば更新になる
        altText: text,
        thumbnail: thumbnailBytes,
        fullImage: fullImageBytes,
        messagesJson: jsonEncode(_messages.map((m) => m.toJson()).toList()),
        createdAt: DateTime.now(),
      );

      if (_currentHistoryId == null) {
        final id = await HistoryDatabase.instance.insert(item);
        setState(() {
          _currentHistoryId = id;
        });
      } else {
        await HistoryDatabase.instance.update(item);
      }
    } catch (e) {
      debugPrint('Error saving history: $e');
    }
  }

  String _cleanAiText(String text) {
    // 太字などのマークダウン装飾記号を除去
    return text.replaceAll('**', '');
  }

  void _resetState() {
    setState(() {
      _imageBytes = null;
      _messages = [];
      _chatSession = null;
      _textController.clear();
      _isLoading = false;
      _statusMessage = '';
      _currentHistoryId = null; // IDをリセット
    });
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alt 生成くん'),
        actions: [
          if (_imageBytes != null || _messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _resetState,
              tooltip: 'リセット',
            ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () async {
              final result = await Navigator.pushNamed(context, '/history');
              if (result is HistoryItem && mounted) {
                _restoreFromHistory(result);
              }
            },
            tooltip: '履歴',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.pushNamed(context, '/settings');
              _checkApiKey();
            },
            tooltip: '設定',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_imageBytes != null) ...[
              InkWell(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        backgroundColor: Colors.black,
                        body: GestureDetector(
                          onTap: () => Navigator.pop(context),
                          behavior: HitTestBehavior.opaque, // 空白部分もタッチ反応させる
                          child: Center(
                            child: Hero(
                              tag: 'selectedImage',
                              child: Image.memory(
                                _imageBytes!,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
                child: Stack(
                  children: [
                    Container(
                      height: 200,
                      width: double.infinity,
                      color: Colors.grey[200],
                      child: Hero(
                        tag: 'selectedImage',
                        child: Image.memory(
                          _imageBytes!,
                          fit: BoxFit.contain,
                          semanticLabel: '選択された画像',
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.zoom_in,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_messages.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _generateAltText,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(_isCustomPromptActive ? '指示を実行' : 'Altテキストを生成'),
                  ),
                ),
            ] else
              InkWell(
                onTap: _pickImage,
                child: Container(
                  height: 200,
                  width: double.infinity,
                  color: Colors.grey[200],
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.add_a_photo, size: 50, color: Colors.grey),
                      SizedBox(height: 8),
                      Text(
                        'タップして画像を選択',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final isUser = msg.role == 'user';
                  return Container(
                    margin:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    alignment:
                        isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isUser ? Colors.blue[100] : Colors.green[100],
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (isUser)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Flexible(child: MarkdownBody(data: msg.text)),
                                if (index == _messages.lastIndexWhere((m) => m.role == 'user') && !_isLoading)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8.0),
                                    child: Tooltip(
                                      message: '回答を再生成',
                                      child: InkWell(
                                        onTap: _regenerateLatestResponse,
                                        child: const Icon(Icons.refresh,
                                            size: 18, color: Colors.blue),
                                      ),
                                    ),
                                  ),
                              ],
                            )
                          else
                            MarkdownBody(data: msg.text),
                          if (!isUser) ...[
                            const SizedBox(height: 8),
                            InkWell(
                              onTap: () => _copyToClipboard(msg.text),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.copy, size: 16),
                                  SizedBox(width: 4),
                                  Text('Copy', style: TextStyle(fontSize: 12)),
                                ],
                              ),
                            )
                          ]
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_isLoading)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    Text(_statusMessage,
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    const LinearProgressIndicator(),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add_photo_alternate),
                    onPressed: _pickImage,
                    tooltip: '画像を選択',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      maxLength: AppConfig.maxPromptLength,
                      decoration: const InputDecoration(
                        hintText: '追加の指示を入力...',
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        counterText: '', // カウンターを非表示
                      ),
                      onSubmitted: (_) => _sendMessage(),
                      enabled: _imageBytes != null, // Disable if no image
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _imageBytes != null ? _sendMessage : null,
                    tooltip: '送信',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatMessage {
  final String role;
  final String text;

  ChatMessage({required this.role, required this.text});

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: json['role'] as String,
        text: json['text'] as String,
      );
}
