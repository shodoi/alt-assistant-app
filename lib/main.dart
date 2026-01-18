import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AltTextGeneratorApp());
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
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  final _apiKeyController = TextEditingController();
  static const _apiKeyKey = 'gemini_api_key';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final key = await _storage.read(key: _apiKeyKey);
    if (key != null) {
      _apiKeyController.text = key;
    }
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _saveApiKey() async {
    await _storage.write(key: _apiKeyKey, value: _apiKeyController.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('API Key saved successfully')),
      );
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _apiKeyController,
                      decoration: const InputDecoration(
                        labelText: 'Gemini API Key',
                        border: OutlineInputBorder(),
                        helperText: 'Enter your Gemini API key here.',
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _saveApiKey,
                      child: const Text('Save API Key'),
                    ),
                  ],
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
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  final _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Uint8List? _imageBytes; // Changed from File? to Uint8List? for Web support
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  ChatSession? _chatSession;
  GenerativeModel? _model;
  String _statusMessage = '';

  static const _apiKeyKey = 'gemini_api_key';
  static const List<String> _modelHierarchy = [
    'gemini-3-flash-preview',
    'gemini-2.5-flash',
    'gemini-1.5-flash',
  ];
  int _currentModelIndex = 0;

  @override
  void initState() {
    super.initState();
    _checkApiKey();
  }

  Future<void> _checkApiKey() async {
    final key = await _storage.read(key: _apiKeyKey);
    if (key == null) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.pushNamed(context, '/settings');
        });
      }
    } else {
      _initModel(key);
    }
  }

  void _initModel(String apiKey) {
    _model = GenerativeModel(
      model: _modelHierarchy[_currentModelIndex],
      apiKey: apiKey,
    );
  }

  Future<void> _pickImage() async {
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

  Future<void> _generateAltText() async {
    if (_imageBytes == null) return;

    final key = await _storage.read(key: _apiKeyKey);
    if (key == null) {
      if (mounted) Navigator.pushNamed(context, '/settings');
      return;
    }

    setState(() {
      _isLoading = true;
      _statusMessage = 'モデルを選択中...';
      _messages.add(ChatMessage(role: 'user', text: '画像の代替テキストを生成中...'));
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
            TextPart('この画像の簡潔な代替テキスト（alt text）を日本語で生成してください。'),
            DataPart('image/jpeg', _imageBytes!),
          ])
        ];

        _chatSession = _model!.startChat();
        final response = await _chatSession!.sendMessage(content.first).timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw Exception('タイムアウトしました'),
        );

        if (mounted) {
          setState(() {
            _messages.add(ChatMessage(role: 'model', text: response.text ?? 'No response'));
            _isLoading = false;
            _statusMessage = '';
          });
        }
        return;
      } catch (e) {
        debugPrint('Error with $modelName: $e');
        String errorMsg = e.toString();
        if (errorMsg.contains('SAFETY') || errorMsg.contains('safety')) {
          errorMsg = '安全性ポリシーによりこの画像は処理できません（モデル: $modelName）';
          if (mounted) {
            setState(() {
              _messages.add(ChatMessage(role: 'model', text: errorMsg));
              _isLoading = false;
              _statusMessage = '';
            });
          }
          return; // Don't fallback for safety violations as other models will likely block it too
        }

        if (i == _modelHierarchy.length - 1) {
          if (mounted) {
            setState(() {
              _messages.add(ChatMessage(role: 'model', text: 'すべてのモデルでエラーが発生しました: $e'));
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

    final key = await _storage.read(key: _apiKeyKey);
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
              const Duration(seconds: 30),
              onTimeout: () => throw Exception('タイムアウトしました'),
            );
        if (mounted) {
          setState(() {
            _messages.add(ChatMessage(role: 'model', text: response.text ?? 'No response'));
            _isLoading = false;
            _statusMessage = '';
          });
          _scrollToBottom();
        }
        return;
      } catch (e) {
        debugPrint('Error with $modelName during send: $e');
        String errorMsg = e.toString();
        if (errorMsg.contains('SAFETY') || errorMsg.contains('safety')) {
          errorMsg = '安全性ポリシーにより回答を生成できません（モデル: $modelName）';
          if (mounted) {
            setState(() {
              _messages.add(ChatMessage(role: 'model', text: errorMsg));
              _isLoading = false;
              _statusMessage = '';
            });
          }
          return;
        }

        if (i == _modelHierarchy.length - 1) {
          if (mounted) {
            setState(() {
              _messages.add(ChatMessage(role: 'model', text: 'エラーが発生しました: $e'));
              _isLoading = false;
              _statusMessage = '';
            });
          }
        }
      }
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

  void _resetState() {
    setState(() {
      _imageBytes = null;
      _messages = [];
      _chatSession = null;
      _textController.clear();
      _isLoading = false;
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
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/settings')
                .then((_) => _checkApiKey()),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_imageBytes != null) ...[
              Container(
                height: 200,
                width: double.infinity,
                color: Colors.grey[200],
                child: Image.memory(_imageBytes!, fit: BoxFit.contain),
              ),
              if (_messages.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _generateAltText,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('altテキストを生成'),
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
                      decoration: const InputDecoration(
                        hintText: '追加の指示を入力...',
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                      enabled: _imageBytes != null, // Disable if no image
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _imageBytes != null ? _sendMessage : null,
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
}
