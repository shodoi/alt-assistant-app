import 'dart:async';

import 'package:http/http.dart' as http;

/// Shared transport mock that captures incoming [http.BaseRequest]s (including
/// [http.Abortable.abortTrigger]) and tracks client `close()` lifecycle.
class AbortObservingHttpClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(
    http.BaseRequest request,
    List<int> bodyBytes,
    Future<void>? abortTrigger,
  ) _handler;

  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final List<bool> abortCompletedFlags = <bool>[];
  final Completer<void> _closedCompleter = Completer<void>();

  bool _isClosed = false;
  int _closeCount = 0;

  AbortObservingHttpClient(this._handler);

  bool get isClosed => _isClosed;

  int get closeCount => _closeCount;

  /// Completes as soon as [close] is called on this client.
  Future<void> get onClosed => _closedCompleter.future;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_isClosed) {
      throw http.ClientException(
        'HTTP client is already closed',
        request.url,
      );
    }
    requests.add(request);
    final Future<void>? trigger =
        request is http.Abortable ? request.abortTrigger : null;
    final idx = abortCompletedFlags.length;
    abortCompletedFlags.add(false);
    if (trigger != null) {
      unawaited(trigger.whenComplete(() {
        abortCompletedFlags[idx] = true;
      }));
    }
    final bytes = await request.finalize().toBytes();
    return _handler(request, bytes, trigger);
  }

  @override
  void close() {
    _isClosed = true;
    _closeCount++;
    if (!_closedCompleter.isCompleted) {
      _closedCompleter.complete();
    }
    super.close();
  }
}

http.StreamedResponse toStreamedResponse(http.Response response) {
  return http.StreamedResponse(
    http.ByteStream.fromBytes(response.bodyBytes),
    response.statusCode,
    contentLength: response.contentLength,
    headers: response.headers,
  );
}
