class AppConfig {
  static const int timeoutSeconds = 30;
  static const Duration requestTimeout = Duration(seconds: timeoutSeconds);
  static const int maxPromptLength = 1000;

  static const double imageMaxWidth = 1536;
  static const double imageMaxHeight = 1536;
  static const int imageQuality = 85;

  static const int maxRetryCount = 2;
  static const List<Duration> retryDelays = <Duration>[
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
  ];

  static const String modelName = 'gemini-4-hydrogen';

  static const String initialPromptDefault =
      'この画像の簡潔な代替テキスト（Alt Text）を、装飾（**等）のないプレーンな日本語で生成してください。';
}
