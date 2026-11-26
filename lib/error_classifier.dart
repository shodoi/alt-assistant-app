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
final RegExp _structuredHttpStatusPattern = RegExp(
  r'Server Error \[(\d{3})\]|\bHTTP\s+(\d{3})\b|\bstatus(?:\s+code)?(?:\s*[:=]\s*|\s+)(\d{3})\b',
  caseSensitive: false,
);

String _userMessageFor(ErrorCategory category) => switch (category) {
      ErrorCategory.timeout => '通信がタイムアウトしました。電波の良い場所で再試行してください。',
      ErrorCategory.network => '通信エラーが発生しました。ネットワーク接続を確認して再試行してください。',
      ErrorCategory.invalidApiKey =>
        'APIキーが無効または権限がありません。設定画面でAPIキーを確認してください。',
      ErrorCategory.serverTemporary =>
        'サーバーが混雑しているか一時的なエラーが発生しました。しばらく待ってから再試行してください。',
      ErrorCategory.safety => '安全性ポリシーによりこのコンテンツは処理できませんでした。',
      ErrorCategory.other => '予期しないエラーが発生しました。時間をおいて再試行してください。',
    };

ClassifiedError _classified(ErrorCategory category, String detailLabel) =>
    ClassifiedError(
      category: category,
      userMessage: _userMessageFor(category),
      detailLabel: detailLabel,
    );

bool _isAuthStatus(int code) => code == 401 || code == 403;

bool _isTemporaryServerStatus(int code) =>
    code == 429 || (code >= 500 && code <= 599);

String? _networkDetailLabel(Object error) {
  if (error is SocketException) return 'SocketException';
  if (error is HandshakeException) return 'HandshakeException';
  if (error is TlsException) return 'TlsException';
  if (error is HttpException) return 'HttpException';
  if (error is QuicException) return 'QuicException';
  if (error is NetworkException) return 'NetworkException';
  if (error is CronetException) return 'CronetException';
  if (error is http.ClientException) return 'ClientException';
  return null;
}

List<int> _extractStructuredStatusCodes(String rawMessage) {
  final codes = <int>[];
  for (final match in _structuredHttpStatusPattern.allMatches(rawMessage)) {
    final token = match.group(1) ?? match.group(2) ?? match.group(3);
    final parsed = token == null ? null : int.tryParse(token);
    if (parsed != null) {
      codes.add(parsed);
    }
  }
  return codes;
}

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
    return _classified(ErrorCategory.timeout, 'Timeout ${seconds}s');
  }

  // 2. Network / connection errors (checked before HTTP status so transport
  //    failures after an earlier HTTP status are classified as network errors)
  final networkLabel = _networkDetailLabel(error);
  if (networkLabel != null) {
    return _classified(ErrorCategory.network, networkLabel);
  }

  final rawMessage = error.toString();
  final lower = rawMessage.toLowerCase();

  // When an explicit status code is known, trust it directly without falling
  // through to regex extraction from body text.
  final statusCodes = statusCode != null
      ? <int>[statusCode]
      : _extractStructuredStatusCodes(rawMessage);

  // 3. Invalid API key / authentication error (evaluated before safety so
  //    auth failures mentioning "safety" are never misclassified as safety).
  if (error is InvalidApiKey) {
    return _classified(ErrorCategory.invalidApiKey, 'InvalidApiKey');
  }
  for (final code in statusCodes) {
    if (_isAuthStatus(code)) {
      return _classified(ErrorCategory.invalidApiKey, 'HTTP $code');
    }
  }
  if (lower.contains('api_key_invalid') ||
      lower.contains('api key not valid') ||
      lower.contains('api key expired') ||
      lower.contains('permission_denied') ||
      lower.contains('unauthenticated') ||
      lower.contains('invalid authentication')) {
    return _classified(ErrorCategory.invalidApiKey, 'InvalidApiKey');
  }

  // 4. Safety policy
  if (lower.contains('safety')) {
    return _classified(ErrorCategory.safety, 'SAFETY');
  }

  // 5. Server busy / temporary error (HTTP 429 / 5xx)
  for (final code in statusCodes) {
    if (_isTemporaryServerStatus(code)) {
      return _classified(ErrorCategory.serverTemporary, 'HTTP $code');
    }
  }
  if (statusCode == null) {
    if (lower.contains('resource has been exhausted') ||
        lower.contains('resource_exhausted') ||
        lower.contains('rate limit') ||
        lower.contains('too many requests') ||
        lower.contains('quota')) {
      return _classified(ErrorCategory.serverTemporary, 'HTTP 429');
    }
    if (lower.contains('service unavailable') ||
        lower.contains('overloaded') ||
        lower.contains('internal error')) {
      return _classified(ErrorCategory.serverTemporary, 'ServerError');
    }
  }

  // 6. Other unexpected errors (explicit labels safe under --obfuscate)
  return _classified(ErrorCategory.other, _otherDetailLabel(error, statusCode));
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
