import 'dart:async';
import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

/// Interface implemented by API exceptions that carry an HTTP status code.
abstract interface class HasHttpStatusCode {
  int? get statusCode;
}

/// Six user-facing error categories defined by the resilience specification.
enum ErrorCategory {
  timeout,
  network,
  invalidApiKey,
  serverTemporary,
  safety,
  other,
}

/// A classified error with a user-friendly Japanese message and a short,
/// sanitized technical detail label.
class ClassifiedError {
  final ErrorCategory category;
  final String userMessage;
  final String detailLabel;

  const ClassifiedError({
    required this.category,
    required this.userMessage,
    required this.detailLabel,
  });

  /// Formats the message for UI display with the short detail label appended.
  String format() => '$userMessage（詳細: $detailLabel）';
}

final RegExp _googleApiKeyPattern = RegExp(r'AIza[0-9A-Za-z\-_]{10,}');
final RegExp _querySecretPattern = RegExp(
  r'([?&](?:key|api_key|apikey|token|access_token)=)[^&\s,' "'" r'"\)]+',
  caseSensitive: false,
);
final RegExp _headerSecretPattern = RegExp(
  r'((?:x-goog-api-key|authorization)\s*[:=]\s*(?:Bearer\s+)?)[^\s,\}\]"' "'" r']+',
  caseSensitive: false,
);
final RegExp _serverErrorStatusPattern = RegExp(r'Server Error \[(\d{3})\]');
final RegExp _httpStatusCodePattern = RegExp(r'\b(401|403|429|5\d\d)\b');

/// Masks API keys, auth headers, and secret query parameters from [input].
String maskSecrets(String input, {String? secretApiKey}) {
  var result = input;
  final trimmedSecret = secretApiKey?.trim();
  if (trimmedSecret != null && trimmedSecret.isNotEmpty) {
    result = result.replaceAll(trimmedSecret, '***');
    final encoded = Uri.encodeQueryComponent(trimmedSecret);
    if (encoded != trimmedSecret) {
      result = result.replaceAll(encoded, '***');
    }
  }
  result = result.replaceAll(_googleApiKeyPattern, '***');
  result = result.replaceAllMapped(
    _querySecretPattern,
    (m) => '${m.group(1)}***',
  );
  result = result.replaceAllMapped(
    _headerSecretPattern,
    (m) => '${m.group(1)}***',
  );
  return result;
}

/// Classifies [error] into one of the 6 [ErrorCategory] values and produces
/// a sanitized [ClassifiedError].
ClassifiedError classifyError(
  Object error, {
  String? secretApiKey,
  int? httpStatusCode,
}) {
  final effectiveStatus =
      httpStatusCode ?? (error is HasHttpStatusCode ? error.statusCode : null);

  final ClassifiedError raw = _classifyRaw(error, effectiveStatus);
  final safeDetail = maskSecrets(raw.detailLabel, secretApiKey: secretApiKey);
  final safeMessage = maskSecrets(raw.userMessage, secretApiKey: secretApiKey);

  return ClassifiedError(
    category: raw.category,
    userMessage: safeMessage,
    detailLabel: safeDetail,
  );
}

ClassifiedError _classifyRaw(Object error, int? statusCode) {
  // 1. Timeout
  if (error is TimeoutException) {
    final seconds = error.duration?.inSeconds ?? AppConfig.timeoutSeconds;
    return ClassifiedError(
      category: ErrorCategory.timeout,
      userMessage: '通信がタイムアウトしました。電波の良い場所で再試行してください。',
      detailLabel: 'Timeout ${seconds}s',
    );
  }

  // 2. Network / connection errors (checked before HTTP status so transport
  //    failures after an earlier HTTP status are classified as network errors)
  if (error is SocketException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'SocketException',
    );
  }
  if (error is HandshakeException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'HandshakeException',
    );
  }
  if (error is TlsException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'TlsException',
    );
  }
  if (error is HttpException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'HttpException',
    );
  }
  if (error is QuicException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'QuicException',
    );
  }
  if (error is NetworkException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'NetworkException',
    );
  }
  if (error is CronetException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'CronetException',
    );
  }
  if (error is http.ClientException) {
    return const ClassifiedError(
      category: ErrorCategory.network,
      userMessage: '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      detailLabel: 'ClientException',
    );
  }

  final rawMessage = error.toString();
  final lower = rawMessage.toLowerCase();

  // 3. Safety policy
  if (lower.contains('safety')) {
    return const ClassifiedError(
      category: ErrorCategory.safety,
      userMessage: '安全性ポリシーによりこのコンテンツは処理できませんでした。',
      detailLabel: 'SAFETY',
    );
  }

  // 4. Invalid API key / authentication error
  if (error is InvalidApiKey) {
    return const ClassifiedError(
      category: ErrorCategory.invalidApiKey,
      userMessage: 'APIキーが無効または権限がありません。設定画面でAPIキーを確認してください。',
      detailLabel: 'InvalidApiKey',
    );
  }
  if (statusCode == 401 || statusCode == 403) {
    return ClassifiedError(
      category: ErrorCategory.invalidApiKey,
      userMessage: 'APIキーが無効または権限がありません。設定画面でAPIキーを確認してください。',
      detailLabel: 'HTTP $statusCode',
    );
  }
  if (lower.contains('api_key_invalid') ||
      lower.contains('api key not valid') ||
      lower.contains('api key expired') ||
      lower.contains('permission_denied') ||
      lower.contains('unauthenticated') ||
      lower.contains('invalid authentication')) {
    return const ClassifiedError(
      category: ErrorCategory.invalidApiKey,
      userMessage: 'APIキーが無効または権限がありません。設定画面でAPIキーを確認してください。',
      detailLabel: 'InvalidApiKey',
    );
  }

  // 5. Server busy / temporary error (HTTP 429 / 5xx)
  final extractedCode = _extractServerStatusCode(rawMessage, statusCode);
  if (extractedCode != null &&
      (extractedCode == 429 ||
          (extractedCode >= 500 && extractedCode <= 599))) {
    return ClassifiedError(
      category: ErrorCategory.serverTemporary,
      userMessage: 'サーバーが混雑しているか一時的なエラーが発生しました。しばらく待ってから再試行してください。',
      detailLabel: 'HTTP $extractedCode',
    );
  }
  if (lower.contains('resource has been exhausted') ||
      lower.contains('resource_exhausted') ||
      lower.contains('rate limit') ||
      lower.contains('too many requests') ||
      lower.contains('quota')) {
    return const ClassifiedError(
      category: ErrorCategory.serverTemporary,
      userMessage: 'サーバーが混雑しているか一時的なエラーが発生しました。しばらく待ってから再試行してください。',
      detailLabel: 'HTTP 429',
    );
  }
  if (lower.contains('service unavailable') ||
      lower.contains('overloaded') ||
      lower.contains('internal error')) {
    return const ClassifiedError(
      category: ErrorCategory.serverTemporary,
      userMessage: 'サーバーが混雑しているか一時的なエラーが発生しました。しばらく待ってから再試行してください。',
      detailLabel: 'ServerError',
    );
  }

  // 6. Other unexpected errors (explicit labels safe under --obfuscate)
  final otherLabel = _otherDetailLabel(error, statusCode);
  return ClassifiedError(
    category: ErrorCategory.other,
    userMessage: '予期しないエラーが発生しました。時間をおいて再試行してください。',
    detailLabel: otherLabel,
  );
}

int? _extractServerStatusCode(String rawMessage, int? explicitStatusCode) {
  if (explicitStatusCode != null &&
      (explicitStatusCode == 429 ||
          (explicitStatusCode >= 500 && explicitStatusCode <= 599))) {
    return explicitStatusCode;
  }
  final serverMatch = _serverErrorStatusPattern.firstMatch(rawMessage);
  if (serverMatch != null) {
    return int.tryParse(serverMatch.group(1)!);
  }
  final genericMatch = _httpStatusCodePattern.firstMatch(rawMessage);
  if (genericMatch != null) {
    final parsed = int.tryParse(genericMatch.group(1)!);
    if (parsed == 429 || (parsed != null && parsed >= 500 && parsed <= 599)) {
      return parsed;
    }
  }
  return null;
}

String _otherDetailLabel(Object error, int? statusCode) {
  if (statusCode != null && statusCode >= 400) {
    return 'HTTP $statusCode';
  }
  if (error is FormatException) return 'FormatException';
  if (error is GenerativeAISdkException) return 'GenerativeAISdkException';
  if (error is UnsupportedUserLocation) return 'UnsupportedUserLocation';
  if (error is GenerativeAIException) return 'GenerativeAIException';
  if (error is StateError) return 'StateError';
  if (error is ArgumentError) return 'ArgumentError';
  return 'UnknownError';
}
