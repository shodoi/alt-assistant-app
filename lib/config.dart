class AppConfig {
  static const int timeoutSeconds = 30;
  static const int maxImageSize = 1024;
  static const int historyLimit = 30;
  static const int maxPromptLength = 1000;
  
  static const String initialPromptDefault = 'この画像の簡潔な代替テキスト（Alt Text）を、装飾（**等）のないプレーンな日本語で生成してください。';
}
