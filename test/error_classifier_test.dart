import 'dart:async';
import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:my_alt_generator/error_classifier.dart';

void main() {
  group('maskSecrets', () {
    test('masks exact secretApiKey including URL-encoded form', () {
      const secret = 'my+secret/key=12345';
      final encoded = Uri.encodeQueryComponent(secret);
      final input = 'Failed for $secret and encoded=$encoded';
      final masked = maskSecrets(input, secretApiKey: secret);

      expect(masked, isNot(contains(secret)));
      expect(masked, isNot(contains(encoded)));
      expect(masked, contains('***'));
    });

    test('masks Google AIza API keys, query params, and auth headers', () {
      const input =
          'POST https://generativelanguage.googleapis.com/v1beta/files?key=AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz123456 '
          'headers={x-goog-api-key: secret-header-key, Authorization: Bearer tok_987654} '
          'fallback=AIzaSyAnotherKeyValue999999';
      final masked = maskSecrets(input);

      expect(masked, isNot(contains('AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz123456')));
      expect(masked, isNot(contains('secret-header-key')));
      expect(masked, isNot(contains('tok_987654')));
      expect(masked, isNot(contains('AIzaSyAnotherKeyValue999999')));
      expect(masked, contains('key=***'));
      expect(masked, contains('x-goog-api-key: ***'));
      expect(masked, contains('Authorization: Bearer ***'));
    });
  });

  group('classifyError', () {
    test('classifies TimeoutException as timeout with Timeout 30s label', () {
      final result = classifyError(
        TimeoutException('timed out', const Duration(seconds: 30)),
      );

      expect(result.category, ErrorCategory.timeout);
      expect(result.detailLabel, 'Timeout 30s');
      expect(result.format(), contains('タイムアウト'));
      expect(result.format(), endsWith('（詳細: Timeout 30s）'));
    });

    test('classifies network exceptions as network with specific detail labels', () {
      final socketRes = classifyError(const SocketException('Failed host lookup'));
      expect(socketRes.category, ErrorCategory.network);
      expect(socketRes.detailLabel, 'SocketException');
      expect(socketRes.format(), contains('通信エラー'));
      expect(socketRes.format(), endsWith('（詳細: SocketException）'));

      final tlsRes = classifyError(const HandshakeException('TLS failed'));
      expect(tlsRes.category, ErrorCategory.network);
      expect(tlsRes.detailLabel, 'HandshakeException');

      final clientRes = classifyError(
        http.ClientException('Connection closed', Uri.https('example.com', '/')),
      );
      expect(clientRes.category, ErrorCategory.network);
      expect(clientRes.detailLabel, 'ClientException');

      final cronetRes = classifyError(
        CronetException('net::ERR_INTERNET_DISCONNECTED', Uri.https('example.com', '/')),
      );
      expect(cronetRes.category, ErrorCategory.network);
      expect(cronetRes.detailLabel, 'CronetException');
    });

    test('classifies InvalidApiKey and HTTP 401/403 as invalidApiKey', () {
      final sdkInvalid = classifyError(InvalidApiKey('API key not valid'));
      expect(sdkInvalid.category, ErrorCategory.invalidApiKey);
      expect(sdkInvalid.detailLabel, 'InvalidApiKey');
      expect(sdkInvalid.format(), contains('APIキー'));
      expect(sdkInvalid.format(), endsWith('（詳細: InvalidApiKey）'));

      final http401 = classifyError(
        ServerException('Request had invalid authentication credentials.'),
        httpStatusCode: 401,
      );
      expect(http401.category, ErrorCategory.invalidApiKey);
      expect(http401.detailLabel, 'HTTP 401');

      final http403 = classifyError(
        const FormatException('Forbidden'),
        httpStatusCode: 403,
      );
      expect(http403.category, ErrorCategory.invalidApiKey);
      expect(http403.detailLabel, 'HTTP 403');
    });

    test('classifies HTTP 429 and 5xx as serverTemporary', () {
      final http503 = classifyError(
        GenerativeAIException('Server Error [503]: Service Unavailable'),
      );
      expect(http503.category, ErrorCategory.serverTemporary);
      expect(http503.detailLabel, 'HTTP 503');
      expect(http503.format(), contains('サーバー'));
      expect(http503.format(), endsWith('（詳細: HTTP 503）'));

      final http500 = classifyError(
        GenerativeAIException('Server Error [500]: Internal Server Error'),
      );
      expect(http500.category, ErrorCategory.serverTemporary);
      expect(http500.detailLabel, 'HTTP 500');

      final http429 = classifyError(
        ServerException('Resource has been exhausted (e.g. check quota).'),
        httpStatusCode: 429,
      );
      expect(http429.category, ErrorCategory.serverTemporary);
      expect(http429.detailLabel, 'HTTP 429');

      final quotaWithoutCode = classifyError(
        ServerException('Resource has been exhausted (e.g. check quota).'),
      );
      expect(quotaWithoutCode.category, ErrorCategory.serverTemporary);
      expect(quotaWithoutCode.detailLabel, 'HTTP 429');
    });

    test('classifies SAFETY responses as safety', () {
      final res = classifyError(
        GenerativeAIException('Response was blocked due to safety'),
      );
      expect(res.category, ErrorCategory.safety);
      expect(res.detailLabel, 'SAFETY');
      expect(res.format(), contains('安全性ポリシー'));
      expect(res.format(), endsWith('（詳細: SAFETY）'));
    });

    test('classifies unknown errors as other and never leaks API keys', () {
      const secret = 'AIzaSyVerySecretKey1234567890';
      final res = classifyError(
        Exception('Unexpected failure with key=$secret and [bracket] text'),
        secretApiKey: secret,
      );
      expect(res.category, ErrorCategory.other);
      expect(res.format(), contains('予期しないエラー'));
      expect(res.format(), isNot(contains(secret)));
      expect(res.format(), isNot(contains('AIza')));

      final badRequest = classifyError(
        ServerException('Invalid argument'),
        httpStatusCode: 400,
      );
      expect(badRequest.category, ErrorCategory.other);
      expect(badRequest.detailLabel, 'HTTP 400');
    });

    test(
        'does NOT fall through to body regex when explicit httpStatusCode is provided',
        () {
      final explicit400With500InBody = classifyError(
        ServerException('Invalid argument: upstream Server Error [500] and HTTP 503'),
        httpStatusCode: 400,
      );
      expect(explicit400With500InBody.category, ErrorCategory.other);
      expect(explicit400With500InBody.detailLabel, 'HTTP 400');

      final explicit404With429InBody = classifyError(
        ServerException('Resource not found: status: 429'),
        httpStatusCode: 404,
      );
      expect(explicit404With429InBody.category, ErrorCategory.other);
      expect(explicit404With429InBody.detailLabel, 'HTTP 404');
    });

    test('ignores bare non-HTTP 3-digit numbers like offset 512 or 500 KB', () {
      final offsetErr = classifyError(Exception('Parse error at offset 512'));
      expect(offsetErr.category, ErrorCategory.other);
      expect(offsetErr.detailLabel, 'UnknownError');

      final sizeErr = classifyError(Exception('Payload exceeded 500 KB limit'));
      expect(sizeErr.category, ErrorCategory.other);
      expect(sizeErr.detailLabel, 'UnknownError');

      final portErr = classifyError(Exception('Refused on code 4290 or item 401'));
      expect(portErr.category, ErrorCategory.other);
      expect(portErr.detailLabel, 'UnknownError');
    });

    test('extracts structured HTTP status patterns and respects auth precedence across multiple codes', () {
      final httpPattern = classifyError(Exception('Request failed with HTTP 503'));
      expect(httpPattern.category, ErrorCategory.serverTemporary);
      expect(httpPattern.detailLabel, 'HTTP 503');

      final statusPattern = classifyError(Exception('Backend returned status: 429'));
      expect(statusPattern.category, ErrorCategory.serverTemporary);
      expect(statusPattern.detailLabel, 'HTTP 429');

      final statusCodePattern = classifyError(Exception('Gateway status code=502'));
      expect(statusCodePattern.category, ErrorCategory.serverTemporary);
      expect(statusCodePattern.detailLabel, 'HTTP 502');

      final authBeforeServer = classifyError(
        Exception('HTTP 401 unauthorized while forwarding HTTP 503'),
      );
      expect(authBeforeServer.category, ErrorCategory.invalidApiKey);
      expect(authBeforeServer.detailLabel, 'HTTP 401');

      final serverAfterNonTemp = classifyError(
        Exception('Gateway status: 400 caused by upstream HTTP 503'),
      );
      expect(serverAfterNonTemp.category, ErrorCategory.serverTemporary);
      expect(serverAfterNonTemp.detailLabel, 'HTTP 503');
    });

    test('evaluates InvalidApiKey and HTTP 401/403 before safety keyword', () {
      final invalidKeyWithSafety = classifyError(
        InvalidApiKey('API key invalid while checking safety settings'),
      );
      expect(invalidKeyWithSafety.category, ErrorCategory.invalidApiKey);
      expect(invalidKeyWithSafety.detailLabel, 'InvalidApiKey');

      final http401WithSafety = classifyError(
        ServerException('Unauthorized access to safety endpoint'),
        httpStatusCode: 401,
      );
      expect(http401WithSafety.category, ErrorCategory.invalidApiKey);
      expect(http401WithSafety.detailLabel, 'HTTP 401');

      final http403WithSafety = classifyError(
        ServerException('Forbidden by safety policy credentials'),
        httpStatusCode: 403,
      );
      expect(http403WithSafety.category, ErrorCategory.invalidApiKey);
      expect(http403WithSafety.detailLabel, 'HTTP 403');
    });
  });
}
