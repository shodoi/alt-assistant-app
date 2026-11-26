import 'dart:async';
import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/retry.dart';

import 'config.dart';

/// Callback used to instantiate an Android Cronet [http.Client].
typedef CronetClientFactory = http.Client Function();

/// Exception thrown when an in-flight HTTP request is explicitly cancelled by
/// user action (reset, picking a new image, API key change, or widget dispose).
class RequestCancelledException implements Exception {
  final Uri? uri;

  const RequestCancelledException([this.uri]);

  @override
  String toString() => uri == null
      ? 'RequestCancelledException'
      : 'RequestCancelledException: $uri';
}

/// Reusable handle that cancels all currently in-flight cancelable requests
/// owned by a screen or workflow.
class RequestCancelHandle {
  final Set<VoidCallback> _listeners = <VoidCallback>{};

  /// Aborts every currently active request attached to this handle.
  void cancelActiveRequests() {
    final snapshot = List<VoidCallback>.of(_listeners);
    for (final listener in snapshot) {
      listener();
    }
  }

  void _addListener(VoidCallback listener) => _listeners.add(listener);

  void _removeListener(VoidCallback listener) => _listeners.remove(listener);
}

/// Creates the base persistent HTTP transport client.
///
/// On Android, attempts to build a Google Play Services backed [CronetClient]
/// with HTTP/2 and HTTP/3 (QUIC) enabled. If initialization fails (e.g. device
/// lacks Play Services) or when running on non-Android platforms, falls back to
/// a persistent [IOClient].
http.Client createBaseHttpClient({
  bool? isAndroid,
  CronetClientFactory? cronetClientFactory,
}) {
  if (isAndroid ?? Platform.isAndroid) {
    try {
      return (cronetClientFactory ?? _createDefaultCronetClient)();
    } catch (e) {
      debugPrint(
        'Cronet initialization failed; falling back to persistent IOClient: $e',
      );
    }
  }
  return _createPersistentIoClient();
}

http.Client _createDefaultCronetClient() {
  final engine = CronetEngine.build(
    enableHttp2: true,
    enableQuic: true,
    enableBrotli: true,
    cacheMode: CacheMode.disabled,
  );
  return CronetClient.fromCronetEngine(engine, closeEngine: true);
}

http.Client _createPersistentIoClient() {
  final ioHttpClient = HttpClient()
    ..connectionTimeout = AppConfig.requestTimeout
    ..idleTimeout = const Duration(seconds: 30);
  return IOClient(ioHttpClient);
}

const Set<int> _retryableStatusCodes = <int>{429, 502, 503, 504};

bool _shouldRetryResponse(http.BaseResponse response) {
  final method = response.request?.method.toUpperCase();
  if (method == 'DELETE') return false;
  return _retryableStatusCodes.contains(response.statusCode);
}

bool _shouldRetryError(Object error, StackTrace _) {
  if (error is http.RequestAbortedException) return false;
  if (error is RequestCancelledException) return false;
  if (error is TimeoutException) return false;
  return error is SocketException ||
      error is HandshakeException ||
      error is http.ClientException;
}

/// Creates the layered resilient HTTP client:
/// Outer [TimeoutAbortingHttpClient] (30s timeout + [cancelHandle])
/// -> Middle [RetryClient] (max 2 retries, 0.5s -> 1.5s, transient errors only;
///    bypassed for `DELETE`)
/// -> Inner [baseClient] (`CronetClient` / persistent `IOClient` / test mock).
TimeoutAbortingHttpClient createResilientHttpClient({
  required http.Client baseClient,
  RequestCancelHandle? cancelHandle,
  RequestCancelHandle? deleteCancelHandle,
  Duration timeout = AppConfig.requestTimeout,
}) {
  final retryClient = RetryClient.withDelays(
    baseClient,
    AppConfig.retryDelays,
    when: _shouldRetryResponse,
    whenError: _shouldRetryError,
  );
  return TimeoutAbortingHttpClient(
    retryingInner: retryClient,
    nonRetryingInner: baseClient,
    cancelHandle: cancelHandle,
    deleteCancelHandle: deleteCancelHandle,
    timeout: timeout,
  );
}

/// Coordinates a shared persistent base [http.Client] and defers closing an
/// owned base client until tracked background cleanup tasks (such as
/// fire-and-forget `DELETE` calls) complete or hit a short safety timeout.
class ManagedHttpClient {
  static const Duration defaultShutdownTimeout = Duration(seconds: 5);

  final http.Client baseClient;
  final bool _ownsBaseClient;
  final Duration _shutdownTimeout;
  final RequestCancelHandle cleanupCancelHandle = RequestCancelHandle();
  final Set<Future<void>> _pendingCleanupTasks = <Future<void>>{};
  bool _disposed = false;

  ManagedHttpClient({
    http.Client? baseClient,
    bool? ownsBaseClient,
    Duration shutdownTimeout = defaultShutdownTimeout,
  })  : _ownsBaseClient = ownsBaseClient ?? (baseClient == null),
        baseClient = baseClient ?? createBaseHttpClient(),
        _shutdownTimeout = shutdownTimeout;

  /// Tracks a background cleanup [task] so [dispose] waits for it before
  /// closing an owned [baseClient].
  void trackCleanupTask(Future<void> task) {
    _pendingCleanupTasks.add(task);
    unawaited(task.whenComplete(() => _pendingCleanupTasks.remove(task)));
  }

  /// Releases the owned [baseClient], waiting for any tracked cleanup tasks
  /// up to [_shutdownTimeout] before aborting stragglers and closing.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_ownsBaseClient) return;
    if (_pendingCleanupTasks.isEmpty) {
      baseClient.close();
      return;
    }
    final pending = List<Future<void>>.of(_pendingCleanupTasks);
    unawaited(
      Future.wait(pending)
          .timeout(
            _shutdownTimeout,
            onTimeout: () {
              cleanupCancelHandle.cancelActiveRequests();
              return const <void>[];
            },
          )
          .catchError((_) => const <void>[])
          .whenComplete(baseClient.close),
    );
  }
}

/// Per-screen lifecycle helper that consolidates [RequestCancelHandle],
/// [TimeoutAbortingHttpClient], cleanup task tracking, and teardown over a
/// shared [ManagedHttpClient] (or a local one when mounted standalone).
class ScopedHttpClient {
  final ManagedHttpClient _managedClient;
  final bool _ownsManagedClient;
  final RequestCancelHandle cancelHandle = RequestCancelHandle();
  late final TimeoutAbortingHttpClient client;

  ScopedHttpClient({
    ManagedHttpClient? managedClient,
    http.Client? httpClient,
  })  : _ownsManagedClient = managedClient == null,
        _managedClient =
            managedClient ?? ManagedHttpClient(baseClient: httpClient) {
    client = createResilientHttpClient(
      baseClient: _managedClient.baseClient,
      cancelHandle: cancelHandle,
      deleteCancelHandle: _managedClient.cleanupCancelHandle,
    );
  }

  int? get lastResponseStatusCode => client.lastResponseStatusCode;

  void cancelActiveRequests() => cancelHandle.cancelActiveRequests();

  void trackCleanupTask(Future<void> task) =>
      _managedClient.trackCleanupTask(task);

  void dispose() {
    cancelHandle.cancelActiveRequests();
    client.close();
    if (_ownsManagedClient) {
      _managedClient.dispose();
    }
  }
}

enum _AbortReason { timeout, cancelled }

/// Outer HTTP client wrapper that converts every request into an [http.Abortable]
/// request, enforces a hard per-operation timeout, supports external
/// cancellation via [RequestCancelHandle], and routes `DELETE` requests directly
/// past the retry layer so deletes are never retried.
class TimeoutAbortingHttpClient extends http.BaseClient {
  final http.Client _retryingInner;
  final http.Client _nonRetryingInner;
  final RequestCancelHandle? _cancelHandle;
  final RequestCancelHandle? _deleteCancelHandle;
  final Duration _timeout;

  /// Records the HTTP status code of the most recent non-DELETE response,
  /// cleared at the start of each non-DELETE request. Used to preserve exact
  /// HTTP status classification (e.g. 401/403/429) when upstream SDKs omit it.
  int? lastResponseStatusCode;

  TimeoutAbortingHttpClient({
    required http.Client retryingInner,
    required http.Client nonRetryingInner,
    RequestCancelHandle? cancelHandle,
    RequestCancelHandle? deleteCancelHandle,
    Duration timeout = AppConfig.requestTimeout,
  })  : _retryingInner = retryingInner,
        _nonRetryingInner = nonRetryingInner,
        _cancelHandle = cancelHandle,
        _deleteCancelHandle = deleteCancelHandle,
        _timeout = timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final isDelete = request.method.toUpperCase() == 'DELETE';
    if (!isDelete) {
      lastResponseStatusCode = null;
    }

    final abortCompleter = Completer<void>();
    _AbortReason? abortReason;

    void triggerAbort(_AbortReason reason) {
      if (abortReason != null) return;
      abortReason = reason;
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
    }

    final activeCancelHandle = isDelete ? _deleteCancelHandle : _cancelHandle;
    VoidCallback? cancelListener;
    if (activeCancelHandle != null) {
      cancelListener = () => triggerAbort(_AbortReason.cancelled);
      activeCancelHandle._addListener(cancelListener);
    }

    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.whenComplete(() => triggerAbort(_AbortReason.cancelled)),
      );
    }

    final timer = Timer(_timeout, () => triggerAbort(_AbortReason.timeout));

    var cleanedUp = false;
    void cleanup() {
      if (cleanedUp) return;
      cleanedUp = true;
      timer.cancel();
      if (cancelListener != null) {
        activeCancelHandle?._removeListener(cancelListener);
      }
    }

    final abortableRequest = _toAbortableRequest(
      request,
      abortCompleter.future,
    );
    final targetClient = isDelete ? _nonRetryingInner : _retryingInner;
    final resultCompleter = Completer<http.StreamedResponse>();

    unawaited(
      abortCompleter.future.whenComplete(() {
        if (!resultCompleter.isCompleted) {
          cleanup();
          resultCompleter.completeError(
            _exceptionForAbort(
              abortReason ?? _AbortReason.cancelled,
              request.url,
            ),
          );
        }
      }),
    );

    unawaited(
      targetClient.send(abortableRequest).then<void>(
        (response) {
        if (abortReason != null) {
          cleanup();
          unawaited(
            response.stream.listen((_) {}).cancel().catchError((_) {}),
          );
          if (!resultCompleter.isCompleted) {
            resultCompleter.completeError(
              _exceptionForAbort(abortReason!, request.url),
            );
          }
          return;
        }

        if (!isDelete) {
          lastResponseStatusCode = response.statusCode;
        }

        final wrappedStream = _wrapResponseStream(
          response.stream,
          requestUrl: request.url,
          abortFuture: abortCompleter.future,
          getAbortReason: () => abortReason,
          cleanup: cleanup,
        );

        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(
            http.StreamedResponse(
              wrappedStream,
              response.statusCode,
              contentLength: response.contentLength,
              request: response.request ?? abortableRequest,
              headers: response.headers,
              isRedirect: response.isRedirect,
              persistentConnection: response.persistentConnection,
              reasonPhrase: response.reasonPhrase,
            ),
          );
        } else {
          cleanup();
          unawaited(
            response.stream.listen((_) {}).cancel().catchError((_) {}),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        cleanup();
        if (!resultCompleter.isCompleted) {
          if (abortReason != null) {
            resultCompleter.completeError(
              _exceptionForAbort(abortReason!, request.url),
            );
          } else {
            resultCompleter.completeError(error, stackTrace);
          }
        }
      },
      ),
    );

    return resultCompleter.future;
  }

  http.BaseRequest _toAbortableRequest(
    http.BaseRequest request,
    Future<void> abortTrigger,
  ) {
    if (request is http.Request) {
      return http.AbortableRequest(
        request.method,
        request.url,
        abortTrigger: abortTrigger,
      )
        ..persistentConnection = request.persistentConnection
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
    }

    final stream = request.finalize();
    final streamed = http.AbortableStreamedRequest(
      request.method,
      request.url,
      abortTrigger: abortTrigger,
    )
      ..persistentConnection = request.persistentConnection
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..contentLength = request.contentLength
      ..headers.addAll(request.headers);

    stream.listen(
      streamed.sink.add,
      onError: streamed.sink.addError,
      onDone: streamed.sink.close,
      cancelOnError: true,
    );
    return streamed;
  }

  Stream<List<int>> _wrapResponseStream(
    http.ByteStream source, {
    required Uri requestUrl,
    required Future<void> abortFuture,
    required _AbortReason? Function() getAbortReason,
    required VoidCallback cleanup,
  }) {
    StreamSubscription<List<int>>? subscription;
    late final StreamController<List<int>> controller;

    controller = StreamController<List<int>>(
      onListen: () {
        if (getAbortReason() case final reason?) {
          cleanup();
          controller
            ..addError(_exceptionForAbort(reason, requestUrl))
            ..close();
          return;
        }

        unawaited(
          abortFuture.whenComplete(() {
            cleanup();
            if (!controller.isClosed) {
              controller
                ..addError(
                  _exceptionForAbort(
                    getAbortReason() ?? _AbortReason.cancelled,
                    requestUrl,
                  ),
                )
                ..close();
            }
            unawaited(subscription?.cancel().catchError((_) {}));
          }),
        );

        subscription = source.listen(
          controller.add,
          onError: (Object error, StackTrace stackTrace) {
            subscription = null;
            cleanup();
            if (controller.isClosed) return;
            final reason = getAbortReason();
            if (reason != null || error is http.RequestAbortedException) {
              controller.addError(
                _exceptionForAbort(
                  reason ?? _AbortReason.cancelled,
                  requestUrl,
                ),
              );
            } else {
              controller.addError(error, stackTrace);
            }
          },
          onDone: () {
            subscription = null;
            cleanup();
            if (!controller.isClosed) {
              unawaited(controller.close());
            }
          },
          cancelOnError: true,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        cleanup();
        return subscription?.cancel();
      },
      sync: true,
    );

    return controller.stream;
  }

  Exception _exceptionForAbort(_AbortReason reason, Uri url) {
    switch (reason) {
      case _AbortReason.timeout:
        return TimeoutException(
          'Request timed out after ${_timeout.inSeconds}s',
          _timeout,
        );
      case _AbortReason.cancelled:
        return RequestCancelledException(url);
    }
  }
}
