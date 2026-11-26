import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'error_classifier.dart';

/// Metadata for a file uploaded to the Gemini Files API.
class UploadedGeminiFile {
  final String name;
  final Uri uri;
  final String apiKey;

  const UploadedGeminiFile({
    required this.name,
    required this.uri,
    required this.apiKey,
  });

  @override
  String toString() => 'UploadedGeminiFile(name: $name, uri: $uri)';
}

/// Exception thrown when a Gemini Files API upload fails with a non-2xx status
/// or an unexpected response payload.
class GeminiFilesApiException implements Exception, HasHttpStatusCode {
  @override
  final int? statusCode;
  final String message;

  const GeminiFilesApiException(this.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'GeminiFilesApiException: $message'
      : 'GeminiFilesApiException [$statusCode]: $message';
}

/// REST client for the Gemini Files API (`uploadType=media` upload and
/// best-effort fire-and-forget `DELETE`).
class GeminiFilesClient {
  static const _host = 'generativelanguage.googleapis.com';
  static final Uri _uploadUri = Uri.https(
    _host,
    '/upload/v1beta/files',
    const {'uploadType': 'media'},
  );

  final http.Client _httpClient;

  GeminiFilesClient({required http.Client httpClient})
      : _httpClient = httpClient;

  /// Uploads raw image [bytes] in a single request (`uploadType=media`) with
  /// [mimeType] and [apiKey], returning the remote file URI and resource name.
  Future<UploadedGeminiFile> uploadImage({
    required Uint8List bytes,
    required String mimeType,
    required String apiKey,
  }) async {
    final response = await _httpClient.post(
      _uploadUri,
      headers: <String, String>{
        'x-goog-api-key': apiKey,
        'Content-Type': mimeType,
      },
      body: bytes,
    );

    final bodyText = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GeminiFilesApiException(
        _extractErrorMessage(bodyText) ??
            'Files API upload failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(bodyText);
    } catch (_) {
      throw GeminiFilesApiException(
        'Invalid JSON in Files API response',
        statusCode: response.statusCode,
      );
    }

    final Map<String, Object?>? fileMap = switch (decoded) {
      {'file': final Map<String, Object?> nested} => nested,
      final Map<String, Object?> topLevel => topLevel,
      _ => null,
    };

    final name = fileMap?['name'];
    final uriStr = fileMap?['uri'];
    if (name is! String ||
        name.isEmpty ||
        uriStr is! String ||
        uriStr.isEmpty) {
      throw GeminiFilesApiException(
        'Missing file name or uri in Files API response',
        statusCode: response.statusCode,
      );
    }

    final parsedUri = Uri.tryParse(uriStr);
    if (parsedUri == null || !parsedUri.hasScheme) {
      throw GeminiFilesApiException(
        'Invalid file uri in Files API response',
        statusCode: response.statusCode,
      );
    }

    return UploadedGeminiFile(
      name: name,
      uri: parsedUri,
      apiKey: apiKey,
    );
  }

  /// Sends a best-effort `DELETE` request to remove a previously uploaded [file].
  ///
  /// Never throws; failures are logged with secrets masked and ignored so UI
  /// flows remain unblocked (Gemini auto-deletes files after 48 hours).
  Future<void> deleteFileBestEffort(UploadedGeminiFile file) async {
    try {
      final normalized =
          file.name.startsWith('/') ? file.name.substring(1) : file.name;
      final uri = Uri.https(_host, '/v1beta/$normalized');
      await _httpClient.delete(
        uri,
        headers: <String, String>{
          'x-goog-api-key': file.apiKey,
        },
      );
    } catch (e) {
      debugPrint(
        'Best-effort Gemini file delete failed (ignored): '
        '${maskSecrets(e.toString(), secretApiKey: file.apiKey)}',
      );
    }
  }

  String? _extractErrorMessage(String bodyText) {
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map<String, Object?>) {
        final error = decoded['error'];
        if (error is Map<String, Object?>) {
          final message = error['message'];
          final status = error['status'];
          final details = error['details'];
          final parts = <String>[];
          if (status is String && status.isNotEmpty) parts.add(status);
          if (message is String && message.isNotEmpty) parts.add(message);
          if (details is List) {
            for (final item in details) {
              if (item is Map<String, Object?> && item['reason'] is String) {
                parts.add(item['reason'] as String);
              }
            }
          }
          if (parts.isNotEmpty) return parts.join(': ');
        }
      }
    } catch (_) {
      // Non-JSON error body
    }
    final trimmed = bodyText.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
