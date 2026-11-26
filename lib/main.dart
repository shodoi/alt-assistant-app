import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'config.dart';
import 'error_classifier.dart';
import 'gemini_files_client.dart';
import 'image_mime.dart';
import 'resilient_http_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AltTextGeneratorApp());
}

const _secureStorage = FlutterSecureStorage();

/// Creates a [GenerativeModel] configured with [AppConfig.modelName].
GenerativeModel _createGenerativeModel({
  required String apiKey,
  http.Client? httpClient,
}) {
  return GenerativeModel(
    model: AppConfig.modelName,
    apiKey: apiKey,
    httpClient: httpClient,
  );
}

class AltTextGeneratorApp extends StatefulWidget {
  final http.Client? httpClient;

  @visibleForTesting
  final http.Client Function()? baseClientFactory;

  const AltTextGeneratorApp({
    super.key,
    this.httpClient,
    @visibleForTesting this.baseClientFactory,
  });

  @override
  State<AltTextGeneratorApp> createState() => _AltTextGeneratorAppState();
}

class _AltTextGeneratorAppState extends State<AltTextGeneratorApp> {
  late ManagedHttpClient _managedClient;

  @override
  void initState() {
    super.initState();
    _managedClient = _createManagedClient();
  }

  ManagedHttpClient _createManagedClient() {
    if (widget.httpClient != null) {
      return ManagedHttpClient(
        baseClient: widget.httpClient,
        ownsBaseClient: false,
      );
    }
    return ManagedHttpClient(
      baseClient: (widget.baseClientFactory ?? createBaseHttpClient)(),
      ownsBaseClient: true,
    );
  }

  @override
  void didUpdateWidget(covariant AltTextGeneratorApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.httpClient != widget.httpClient ||
        oldWidget.baseClientFactory != widget.baseClientFactory) {
      _managedClient.dispose();
      _managedClient = _createManagedClient();
    }
  }

  @override
  void dispose() {
    _managedClient.dispose();
    super.dispose();
  }

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
        '/': (context) => HomePage(managedHttpClient: _managedClient),
        '/settings': (context) =>
            SettingsPage(managedHttpClient: _managedClient),
      },
    );
  }
}

// --- Settings Page ---

class SettingsPage extends StatefulWidget {
  final http.Client? httpClient;
  final ManagedHttpClient? managedHttpClient;

  const SettingsPage({
    super.key,
    this.httpClient,
    this.managedHttpClient,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _apiKeyController = TextEditingController();
  final _promptController = TextEditingController();
  late final ScopedHttpClient _http;

  static const _apiKeyKey = 'gemini_api_key';
  static const _customPromptKey = 'custom_initial_prompt';
  bool _isLoading = true;
  bool _isVerifying = false;

  @override
  void initState() {
    super.initState();
    _http = ScopedHttpClient(
      managedClient: widget.managedHttpClient,
      httpClient: widget.httpClient,
    );
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    final key = await _secureStorage.read(key: _apiKeyKey);
    final customPrompt = await _secureStorage.read(key: _customPromptKey);

    if (mounted) {
      setState(() {
        if (key != null) _apiKeyController.text = key;
        if (customPrompt != null) {
          _promptController.text = customPrompt;
        }
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
      final model = _createGenerativeModel(
        apiKey: newKey,
        httpClient: _http.client,
      );
      await model.generateContent([Content.text('test')]);

      await _secureStorage.write(key: _apiKeyKey, value: newKey);
      await _secureStorage.write(
        key: _customPromptKey,
        value: _promptController.text,
      );

      if (mounted) {
        FocusScope.of(context).unfocus();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('API Keyを確認し、保存しました'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on RequestCancelledException {
      // Cancelled on dispose; do not surface an error snackbar.
    } catch (e) {
      final classified = classifyError(
        e,
        secretApiKey: newKey,
        httpStatusCode: _http.lastResponseStatusCode,
      );
      debugPrint(
        'Error verifying API key: '
        '${maskSecrets(e.toString(), secretApiKey: newKey)}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(classified.format()),
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
    _http.dispose();
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
                                  Icon(
                                    Icons.key,
                                    color: Colors.teal.shade600,
                                    size: 20,
                                  ),
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
                                  prefixIcon:
                                      const Icon(Icons.vpn_key_outlined),
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
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
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
                                          ),
                                        )
                                      : const Icon(Icons.save),
                                  label: Text(
                                    _isVerifying ? '検証中...' : 'Save API Key',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // --- Model Info Section ---
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
                                  Icon(
                                    Icons.smart_toy_outlined,
                                    color: Colors.deepPurple.shade600,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '使用モデル',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.deepPurple.shade700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.deepPurple.shade200,
                                  ),
                                ),
                                child: Text(
                                  AppConfig.modelName,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.deepPurple.shade700,
                                  ),
                                ),
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
                                  Icon(
                                    Icons.edit_note,
                                    color: Colors.amber.shade800,
                                    size: 20,
                                  ),
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
                                        final text =
                                            _promptController.text.trim();
                                        if (text.length >
                                            AppConfig.maxPromptLength) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                              content: Text('プロンプトが長すぎます'),
                                            ),
                                          );
                                          return;
                                        }

                                        await _secureStorage.write(
                                          key: _customPromptKey,
                                          value: text,
                                        );
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                              content: Text('プロンプトを保存しました'),
                                            ),
                                          );
                                        }
                                      },
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.amber.shade800,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                      ),
                                      icon: const Icon(Icons.save, size: 18),
                                      label: const Text('プロンプトを保存'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () async {
                                      await _secureStorage.delete(
                                        key: _customPromptKey,
                                      );
                                      setState(() {
                                        _promptController.clear();
                                      });
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('デフォルトに戻しました'),
                                          ),
                                        );
                                      }
                                    },
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                        horizontal: 16,
                                      ),
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
  final http.Client? httpClient;
  final ManagedHttpClient? managedHttpClient;

  const HomePage({
    super.key,
    this.httpClient,
    this.managedHttpClient,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = ImagePicker();
  final _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  late final ScopedHttpClient _http;
  late final GeminiFilesClient _filesClient;

  Uint8List? _imageBytes;
  String? _imageMimeType;
  UploadedGeminiFile? _uploadedFile;
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _hasInitialGeneration = false;
  ChatSession? _chatSession;
  GenerativeModel? _model;
  String _statusMessage = '';
  String? _currentApiKey;
  int _operationId = 0;

  static const _apiKeyKey = 'gemini_api_key';
  String? _customPrompt;

  bool get _isCustomPromptActive =>
      _customPrompt != null && _customPrompt!.isNotEmpty;

  bool get _canSendMessage =>
      _imageBytes != null &&
      !_isLoading &&
      (_chatSession != null || _hasInitialGeneration);

  @override
  void initState() {
    super.initState();
    _http = ScopedHttpClient(
      managedClient: widget.managedHttpClient,
      httpClient: widget.httpClient,
    );
    _filesClient = GeminiFilesClient(httpClient: _http.client);
    _checkApiKey();
  }

  void _scheduleFileDelete(UploadedGeminiFile file) {
    final future = _filesClient.deleteFileBestEffort(file);
    _http.trackCleanupTask(future);
    unawaited(future);
  }

  void _discardUploadedFile() {
    final uploaded = _uploadedFile;
    _uploadedFile = null;
    if (uploaded == null) return;
    _scheduleFileDelete(uploaded);
  }

  Future<void> _checkApiKey() async {
    final key = await _secureStorage.read(key: _apiKeyKey);
    final customPrompt =
        await _secureStorage.read(key: 'custom_initial_prompt');
    if (!mounted) return;

    if (key == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.pushNamed(context, '/settings');
        }
      });
      return;
    }

    final apiKeyChanged = (_currentApiKey != null && _currentApiKey != key) ||
        (_uploadedFile != null && _uploadedFile!.apiKey != key);
    _currentApiKey = key;

    if (apiKeyChanged) {
      _operationId++;
      _http.cancelActiveRequests();
      _discardUploadedFile();
      _chatSession = null;
    }

    setState(() {
      _customPrompt = customPrompt;
      if (apiKeyChanged) {
        _isLoading = false;
        _statusMessage = '';
      }
    });
    _initModel(key);
  }

  void _initModel(String apiKey) {
    _model = _createGenerativeModel(
      apiKey: apiKey,
      httpClient: _http.client,
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

    final pickedFile = await _picker.pickImage(
      source: source,
      maxWidth: AppConfig.imageMaxWidth,
      maxHeight: AppConfig.imageMaxHeight,
      imageQuality: AppConfig.imageQuality,
    );
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      if (!mounted) return;
      _operationId++;
      _http.cancelActiveRequests();
      _discardUploadedFile();
      setState(() {
        _imageBytes = bytes;
        _imageMimeType = detectImageMimeType(bytes);
        _messages = [];
        _chatSession = null;
        _hasInitialGeneration = false;
        _isLoading = false;
        _statusMessage = '';
      });
    }
  }

  /// Uploads [_imageBytes] to the Gemini Files API if not already cached for
  /// [apiKey]. Returns `null` if cancelled or stale, and rethrows errors so
  /// callers never fall back to inline Base64 data.
  Future<UploadedGeminiFile?> _ensureImageUploaded({
    required int opId,
    required String apiKey,
  }) async {
    final existing = _uploadedFile;
    if (existing != null && existing.apiKey == apiKey) {
      return existing;
    }
    if (existing != null) {
      _discardUploadedFile();
    }

    final bytes = _imageBytes;
    if (bytes == null) return null;
    final mimeType = _imageMimeType ?? detectImageMimeType(bytes);

    final uploaded = await _filesClient.uploadImage(
      bytes: bytes,
      mimeType: mimeType,
      apiKey: apiKey,
    );

    if (!mounted || _operationId != opId) {
      _scheduleFileDelete(uploaded);
      return null;
    }

    _uploadedFile = uploaded;
    return uploaded;
  }

  void _clearLoadingIfCurrent(int opId) {
    if (!mounted || _operationId != opId) return;
    if (_isLoading || _statusMessage.isNotEmpty) {
      setState(() {
        _isLoading = false;
        _statusMessage = '';
      });
    }
  }

  void _handleChatError({
    required int opId,
    required Object error,
    required String apiKey,
    required String errorLogPrefix,
  }) {
    if (!mounted || _operationId != opId) return;
    final classified = classifyError(
      error,
      secretApiKey: apiKey,
      httpStatusCode: _http.lastResponseStatusCode,
    );
    debugPrint(
      '$errorLogPrefix: ${maskSecrets(error.toString(), secretApiKey: apiKey)}',
    );
    setState(() {
      _messages.add(ChatMessage(role: 'model', text: classified.format()));
      _isLoading = false;
      _statusMessage = '';
    });
  }

  /// Ensures the current image is uploaded for [apiKey], reporting any
  /// non-cancel error to the chat log and updating [_statusMessage] once
  /// ready. Returns `null` if cancelled, stale, or failed.
  Future<UploadedGeminiFile?> _prepareUploadedFile({
    required int opId,
    required String apiKey,
    required bool needsUpload,
    required String nextStatusMessage,
    required String errorLogPrefix,
  }) async {
    UploadedGeminiFile? uploaded;
    try {
      uploaded = await _ensureImageUploaded(opId: opId, apiKey: apiKey);
    } on RequestCancelledException {
      _clearLoadingIfCurrent(opId);
      return null;
    } catch (e) {
      _handleChatError(
        opId: opId,
        error: e,
        apiKey: apiKey,
        errorLogPrefix: errorLogPrefix,
      );
      return null;
    }

    if (uploaded == null || !mounted || _operationId != opId) {
      _clearLoadingIfCurrent(opId);
      return null;
    }

    if (needsUpload) {
      setState(() {
        _statusMessage = nextStatusMessage;
      });
    }
    return uploaded;
  }

  /// Sends [content] via [_chatSession] with abort-aware timeout, classified
  /// error handling, and state updates.
  Future<void> _sendChatRequest({
    required int opId,
    required String apiKey,
    required Content content,
    required String errorLogPrefix,
    VoidCallback? onSuccess,
  }) async {
    try {
      final response = await _chatSession!.sendMessage(content);

      if (mounted && _operationId == opId) {
        final cleanedText = _cleanAiText(response.text ?? 'No response');
        setState(() {
          _messages.add(ChatMessage(role: 'model', text: cleanedText));
          _isLoading = false;
          _statusMessage = '';
        });
        onSuccess?.call();
      }
    } on RequestCancelledException {
      _clearLoadingIfCurrent(opId);
    } catch (e) {
      _handleChatError(
        opId: opId,
        error: e,
        apiKey: apiKey,
        errorLogPrefix: errorLogPrefix,
      );
    }
  }

  Future<void> _generateAltText() async {
    if (_isLoading || _imageBytes == null) return;

    final opId = ++_operationId;
    setState(() {
      _isLoading = true;
      _statusMessage = '';
    });

    try {
      final key = await _secureStorage.read(key: _apiKeyKey);
      if (!mounted || _operationId != opId || _imageBytes == null) return;
      if (key == null) {
        _clearLoadingIfCurrent(opId);
        Navigator.pushNamed(context, '/settings');
        return;
      }

      final customPrompt =
          await _secureStorage.read(key: 'custom_initial_prompt');
      if (!mounted || _operationId != opId || _imageBytes == null) return;

      _currentApiKey = key;
      if (_uploadedFile != null && _uploadedFile!.apiKey != key) {
        _discardUploadedFile();
        _chatSession = null;
      }

      final prompt = (customPrompt != null && customPrompt.isNotEmpty)
          ? customPrompt
          : AppConfig.initialPromptDefault;

      final userMessage =
          _isCustomPromptActive ? 'カスタム指示を実行中...' : '画像の代替テキストを生成中...';
      final needsUpload = _uploadedFile == null;

      setState(() {
        _statusMessage = needsUpload ? '画像をアップロード中...' : 'Altテキストを生成中...';
        _messages.add(ChatMessage(role: 'user', text: userMessage));
      });

      final uploaded = await _prepareUploadedFile(
        opId: opId,
        apiKey: key,
        needsUpload: needsUpload,
        nextStatusMessage: 'Altテキストを生成中...',
        errorLogPrefix: 'Error uploading image',
      );
      if (uploaded == null) return;

      _initModel(key);
      _chatSession = _model!.startChat();
      _hasInitialGeneration = true;

      await _sendChatRequest(
        opId: opId,
        apiKey: key,
        content: Content.multi([
          TextPart(prompt),
          FilePart(uploaded.uri),
        ]),
        errorLogPrefix: 'Error generating alt text',
      );
    } finally {
      _clearLoadingIfCurrent(opId);
    }
  }

  Future<void> _sendMessage() async {
    final userMessage = _textController.text;
    if (userMessage.isEmpty || !_canSendMessage) return;

    final opId = ++_operationId;
    setState(() {
      _isLoading = true;
      _statusMessage = '';
    });

    try {
      final key = await _secureStorage.read(key: _apiKeyKey);
      if (!mounted ||
          _operationId != opId ||
          _imageBytes == null ||
          key == null) {
        return;
      }

      _currentApiKey = key;
      if (_uploadedFile != null && _uploadedFile!.apiKey != key) {
        _discardUploadedFile();
        _chatSession = null;
      }

      final needsUpload = _chatSession == null && _uploadedFile == null;

      setState(() {
        _messages.add(ChatMessage(role: 'user', text: userMessage));
        _statusMessage = needsUpload ? '画像をアップロード中...' : '回答を生成中...';
        _textController.clear();
      });

      _scrollToBottom();

      Content contentToSend;
      if (_chatSession == null) {
        final uploaded = await _prepareUploadedFile(
          opId: opId,
          apiKey: key,
          needsUpload: needsUpload,
          nextStatusMessage: '回答を生成中...',
          errorLogPrefix: 'Error uploading image for chat',
        );
        if (uploaded == null) return;

        _initModel(key);
        _chatSession = _model!.startChat();
        contentToSend = Content.multi([
          TextPart(userMessage),
          FilePart(uploaded.uri),
        ]);
      } else {
        contentToSend = Content.text(userMessage);
      }

      await _sendChatRequest(
        opId: opId,
        apiKey: key,
        content: contentToSend,
        errorLogPrefix: 'Error during send',
        onSuccess: _scrollToBottom,
      );
    } finally {
      _clearLoadingIfCurrent(opId);
    }
  }

  void _regenerateLatestResponse() {
    if (_isLoading || _messages.isEmpty) return;

    int lastUserIndex = -1;
    for (int i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].role == 'user') {
        lastUserIndex = i;
        break;
      }
    }

    if (lastUserIndex == -1) return;

    final lastUserMsg = _messages[lastUserIndex];

    setState(() {
      _messages.removeRange(lastUserIndex, _messages.length);
    });

    if (lastUserMsg.text == '画像の代替テキストを生成中...' ||
        lastUserMsg.text == 'カスタム指示を実行中...') {
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

  String _cleanAiText(String text) {
    return text.replaceAll('**', '');
  }

  void _resetState() {
    _operationId++;
    _http.cancelActiveRequests();
    _discardUploadedFile();
    setState(() {
      _imageBytes = null;
      _imageMimeType = null;
      _messages = [];
      _chatSession = null;
      _hasInitialGeneration = false;
      _textController.clear();
      _isLoading = false;
      _statusMessage = '';
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
    _operationId++;
    _discardUploadedFile();
    _http.dispose();
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
            onPressed: () async {
              await Navigator.pushNamed(context, '/settings');
              await _checkApiKey();
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
                          behavior: HitTestBehavior.opaque,
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
                          color: Colors.black.withValues(alpha: 0.5),
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
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
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
                                Flexible(child: SelectableText(msg.text)),
                                if (index ==
                                        _messages.lastIndexWhere(
                                          (m) => m.role == 'user',
                                        ) &&
                                    !_isLoading)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8.0),
                                    child: Tooltip(
                                      message: '回答を再生成',
                                      child: InkWell(
                                        onTap: _regenerateLatestResponse,
                                        child: const Icon(
                                          Icons.refresh,
                                          size: 18,
                                          color: Colors.blue,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            )
                          else
                            SelectableText(msg.text),
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
                    Text(
                      _statusMessage,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
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
                        counterText: '',
                      ),
                      onSubmitted: _canSendMessage ? (_) => _sendMessage() : null,
                      enabled: _canSendMessage,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _canSendMessage ? _sendMessage : null,
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
}
