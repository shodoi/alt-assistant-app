import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:my_alt_generator/resilient_http_client.dart';

import 'test_helpers.dart';

void main() {
  group('createBaseHttpClient', () {
    test('uses cronetClientFactory on Android when initialization succeeds', () {
      final fakeCronet = MockClient((_) async => http.Response('ok', 200));
      final client = createBaseHttpClient(
        isAndroid: true,
        cronetClientFactory: () => fakeCronet,
      );
      expect(identical(client, fakeCronet), isTrue);
    });

    test('falls back to persistent IOClient when Cronet initialization throws', () {
      final client = createBaseHttpClient(
        isAndroid: true,
        cronetClientFactory: () => throw StateError('Play Services unavailable'),
      );
      addTearDown(client.close);
      expect(client, isA<IOClient>());
    });

    test('returns persistent IOClient without calling Cronet on non-Android', () {
      var factoryCalled = false;
      final client = createBaseHttpClient(
        isAndroid: false,
        cronetClientFactory: () {
          factoryCalled = true;
          return MockClient((_) async => http.Response('ok', 200));
        },
      );
      addTearDown(client.close);
      expect(factoryCalled, isFalse);
      expect(client, isA<IOClient>());
    });
  });

  group('ResilientHttpClient abort and timeout', () {
    testWidgets(
      'aborts hanging request via abortTrigger at 30s with TimeoutException and no retry',
      (WidgetTester tester) async {
        final transport = AbortObservingHttpClient((request, bytes, trigger) {
          final completer = Completer<http.StreamedResponse>();
          trigger?.whenComplete(() {
            if (!completer.isCompleted) {
              completer.completeError(http.RequestAbortedException(request.url));
            }
          });
          return completer.future;
        });

        final client = createResilientHttpClient(baseClient: transport);
        Object? caughtError;
        unawaited(
          client
              .post(Uri.https('example.com', '/test'), body: 'hi')
              .then<void>((_) {}, onError: (Object e) => caughtError = e),
        );

        await tester.pump(const Duration(seconds: 29));
        expect(caughtError, isNull);
        expect(transport.abortCompletedFlags.single, isFalse);

        await tester.pump(const Duration(seconds: 1));
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single, isA<http.Abortable>());
        expect(transport.abortCompletedFlags.single, isTrue);
        expect(caughtError, isA<TimeoutException>());

        // Ensure no retry timer fires afterwards.
        await tester.pump(const Duration(seconds: 5));
        expect(transport.requests, hasLength(1));
      },
    );

    testWidgets(
      'aborts in-flight request via RequestCancelHandle with RequestCancelledException and remains reusable',
      (WidgetTester tester) async {
        var attempt = 0;
        final transport = AbortObservingHttpClient((request, bytes, trigger) {
          attempt++;
          if (attempt == 1) {
            final completer = Completer<http.StreamedResponse>();
            trigger?.whenComplete(() {
              if (!completer.isCompleted) {
                completer.completeError(
                  http.RequestAbortedException(request.url),
                );
              }
            });
            return completer.future;
          }
          return Future.value(
            http.StreamedResponse(Stream.value('ok'.codeUnits), 200),
          );
        });

        final cancelHandle = RequestCancelHandle();
        final client = createResilientHttpClient(
          baseClient: transport,
          cancelHandle: cancelHandle,
        );

        Object? caughtError;
        unawaited(
          client
              .post(Uri.https('example.com', '/first'), body: '1')
              .then<void>((_) {}, onError: (Object e) => caughtError = e),
        );

        await tester.pump();
        expect(transport.requests, hasLength(1));
        expect(transport.abortCompletedFlags[0], isFalse);

        cancelHandle.cancelActiveRequests();
        await tester.pump();

        expect(transport.abortCompletedFlags[0], isTrue);
        expect(caughtError, isA<RequestCancelledException>());

        // Client and cancelHandle remain reusable for subsequent requests.
        http.Response? secondResponse;
        unawaited(
          client
              .post(Uri.https('example.com', '/second'), body: '2')
              .then<void>((r) => secondResponse = r),
        );
        await tester.pump();
        expect(secondResponse?.statusCode, 200);
        expect(secondResponse?.body, 'ok');
      },
    );

    testWidgets('caps total wait time including retries at 30s',
        (WidgetTester tester) async {
      var attempt = 0;
      final transport = AbortObservingHttpClient((request, bytes, trigger) {
        attempt++;
        final completer = Completer<http.StreamedResponse>();
        trigger?.whenComplete(() {
          if (!completer.isCompleted) {
            completer.completeError(http.RequestAbortedException(request.url));
          }
        });
        if (attempt == 1) {
          // Fail after 20s with SocketException -> triggers retry after 0.5s.
          Timer(const Duration(seconds: 20), () {
            if (!completer.isCompleted) {
              completer.completeError(const SocketException('dropped'));
            }
          });
        }
        // Attempt 2 hangs until aborted at t=30s (9.5s into attempt 2).
        return completer.future;
      });

      final client = createResilientHttpClient(baseClient: transport);
      Object? caughtError;
      unawaited(
        client
            .post(Uri.https('example.com', '/slow-retry'), body: 'payload')
            .then<void>((_) {}, onError: (Object e) => caughtError = e),
      );

      await tester.pump(const Duration(seconds: 20));
      expect(transport.requests, hasLength(1));
      expect(caughtError, isNull);

      await tester.pump(const Duration(milliseconds: 500));
      expect(transport.requests, hasLength(2));
      expect(caughtError, isNull);

      await tester.pump(const Duration(seconds: 9, milliseconds: 500));
      expect(caughtError, isA<TimeoutException>());
      expect(transport.abortCompletedFlags[1], isTrue);
    });
  });

  group('ResilientHttpClient retry policy', () {
    testWidgets(
      'retries SocketException, HandshakeException, and ClientException up to 2 times with 0.5s -> 1.5s delays',
      (WidgetTester tester) async {
        final transientErrors = <Object>[
          const SocketException('connection reset'),
          const HandshakeException('tls handshake failed'),
          http.ClientException('connection closed'),
        ];

        for (final err in transientErrors) {
          final attemptTimes = <Duration>[];
          final start = tester.binding.clock.now();

          final transport = AbortObservingHttpClient((request, bytes, trigger) async {
            attemptTimes.add(tester.binding.clock.now().difference(start));
            if (attemptTimes.length <= 2) {
              throw err;
            }
            return http.StreamedResponse(
              Stream.value('recovered'.codeUnits),
              200,
            );
          });

          final client = createResilientHttpClient(baseClient: transport);
          http.Response? response;
          unawaited(
            client
                .post(Uri.https('example.com', '/retry'), body: 'data')
                .then<void>((r) => response = r),
          );

          await tester.pump();
          expect(attemptTimes, [Duration.zero]);
          expect(response, isNull);

          await tester.pump(const Duration(milliseconds: 499));
          expect(attemptTimes, hasLength(1));

          await tester.pump(const Duration(milliseconds: 1));
          expect(attemptTimes, [
            Duration.zero,
            const Duration(milliseconds: 500),
          ]);
          expect(response, isNull);

          await tester.pump(const Duration(milliseconds: 1499));
          expect(attemptTimes, hasLength(2));

          await tester.pump(const Duration(milliseconds: 1));
          expect(attemptTimes, [
            Duration.zero,
            const Duration(milliseconds: 500),
            const Duration(milliseconds: 2000),
          ]);
          expect(response?.statusCode, 200);
          expect(response?.body, 'recovered');
        }
      },
    );

    testWidgets(
      'retries HTTP 429, 502, 503, 504 up to 2 times (max 3 attempts total)',
      (WidgetTester tester) async {
        for (final statusCode in const [429, 502, 503, 504]) {
          var attempts = 0;
          final transport = MockClient((request) async {
            attempts++;
            return http.Response('temporary error', statusCode);
          });

          final client = createResilientHttpClient(baseClient: transport);
          Object? unexpectedError;
          http.Response? response;
          unawaited(
            client
                .post(Uri.https('example.com', '/status-$statusCode'), body: 'x')
                .then<void>(
                  (r) => response = r,
                  onError: (Object e) => unexpectedError = e,
                ),
          );

          await tester.pump(const Duration(seconds: 3));
          expect(unexpectedError, isNull);
          expect(attempts, 3, reason: 'HTTP $statusCode should try 1 + 2 retries');
          expect(response?.statusCode, statusCode);
          expect(client.lastResponseStatusCode, statusCode);
        }
      },
    );

    testWidgets('does NOT retry HTTP 400, 401, 403, 404, 500',
        (WidgetTester tester) async {
      for (final statusCode in const [400, 401, 403, 404, 500]) {
        var attempts = 0;
        final transport = MockClient((request) async {
          attempts++;
          return http.Response('non-retryable error', statusCode);
        });

        final client = createResilientHttpClient(baseClient: transport);
        Object? unexpectedError;
        http.Response? response;
        unawaited(
          client
              .post(Uri.https('example.com', '/status-$statusCode'), body: 'x')
              .then<void>(
                (r) => response = r,
                onError: (Object e) => unexpectedError = e,
              ),
        );

        await tester.pump(const Duration(seconds: 3));
        expect(unexpectedError, isNull);
        expect(attempts, 1, reason: 'HTTP $statusCode must NOT be retried');
        expect(response?.statusCode, statusCode);
      }
    });

    testWidgets(
      'NEVER retries DELETE requests even on SocketException or HTTP 503',
      (WidgetTester tester) async {
        var socketAttempts = 0;
        final socketTransport = MockClient((request) async {
          socketAttempts++;
          throw const SocketException('offline');
        });
        final client1 = createResilientHttpClient(baseClient: socketTransport);
        Object? err1;
        unawaited(
          client1
              .delete(Uri.https('example.com', '/v1beta/files/1'))
              .then<void>((_) {}, onError: (Object e) => err1 = e),
        );
        await tester.pump(const Duration(seconds: 5));
        expect(socketAttempts, 1);
        expect(err1, isA<SocketException>());

        var statusAttempts = 0;
        final statusTransport = MockClient((request) async {
          statusAttempts++;
          return http.Response('unavailable', 503);
        });
        final client2 = createResilientHttpClient(baseClient: statusTransport);
        http.Response? res2;
        unawaited(
          client2
              .delete(Uri.https('example.com', '/v1beta/files/2'))
              .then<void>((r) => res2 = r),
        );
        await tester.pump(const Duration(seconds: 5));
        expect(statusAttempts, 1);
        expect(res2?.statusCode, 503);
      },
    );

    testWidgets(
      'DELETE requests are not aborted by RequestCancelHandle (so reset/dispose cleanup can finish)',
      (WidgetTester tester) async {
        final completer = Completer<http.StreamedResponse>();
        final transport = AbortObservingHttpClient((request, bytes, trigger) {
          trigger?.whenComplete(() {
            if (!completer.isCompleted) {
              completer.completeError(http.RequestAbortedException(request.url));
            }
          });
          return completer.future;
        });

        final cancelHandle = RequestCancelHandle();
        final client = createResilientHttpClient(
          baseClient: transport,
          cancelHandle: cancelHandle,
        );

        http.Response? response;
        unawaited(
          client
              .delete(Uri.https('example.com', '/v1beta/files/cleanup'))
              .then<void>((r) => response = r),
        );

        await tester.pump();
        cancelHandle.cancelActiveRequests();
        await tester.pump();

        expect(transport.abortCompletedFlags.single, isFalse);
        completer.complete(http.StreamedResponse(const Stream.empty(), 200));
        await tester.pump();
        expect(response?.statusCode, 200);
      },
    );
  });

  group('ManagedHttpClient and ScopedHttpClient lifecycle', () {
    testWidgets(
      'waits for tracked DELETE cleanup to complete before closing an owned base client',
      (WidgetTester tester) async {
        final deleteCompleter = Completer<http.StreamedResponse>();
        late AbortObservingHttpClient transport;
        transport = AbortObservingHttpClient((request, bytes, trigger) {
          // Simulate Cronet closing mid-flight if close() is called too early.
          unawaited(transport.onClosed.whenComplete(() {
            if (!deleteCompleter.isCompleted) {
              deleteCompleter.completeError(
                http.ClientException('Closed mid-flight', request.url),
              );
            }
          }));
          trigger?.whenComplete(() {
            if (!deleteCompleter.isCompleted) {
              deleteCompleter.completeError(
                http.RequestAbortedException(request.url),
              );
            }
          });
          return deleteCompleter.future;
        });

        final managed = ManagedHttpClient(
          baseClient: transport,
          ownsBaseClient: true,
        );
        final scope = ScopedHttpClient(managedClient: managed);

        http.Response? deleteResponse;
        Object? deleteError;
        final deleteTask = scope.client
            .delete(Uri.https('example.com', '/v1beta/files/cleanup-1'))
            .then<void>(
              (r) => deleteResponse = r,
              onError: (Object e) => deleteError = e,
            );
        scope.trackCleanupTask(deleteTask);

        await tester.pump();
        expect(transport.requests, hasLength(1));

        // Disposing screen scope + app managed client while DELETE is in-flight
        scope.dispose();
        managed.dispose();
        await tester.pump();

        expect(transport.isClosed, isFalse);
        expect(transport.abortCompletedFlags.single, isFalse);
        expect(deleteError, isNull);

        // Complete the DELETE -> client closes immediately afterwards.
        deleteCompleter.complete(http.StreamedResponse(const Stream.empty(), 200));
        await tester.pump();

        expect(deleteError, isNull);
        expect(deleteResponse?.statusCode, 200);
        expect(transport.isClosed, isTrue);
      },
    );

    testWidgets(
      'aborts hanging DELETE and closes owned base client after safety timeout with zero pending timers',
      (WidgetTester tester) async {
        final deleteCompleter = Completer<http.StreamedResponse>();
        final transport = AbortObservingHttpClient((request, bytes, trigger) {
          trigger?.whenComplete(() {
            if (!deleteCompleter.isCompleted) {
              deleteCompleter.completeError(
                http.RequestAbortedException(request.url),
              );
            }
          });
          return deleteCompleter.future;
        });

        final managed = ManagedHttpClient(
          baseClient: transport,
          ownsBaseClient: true,
        );
        final scope = ScopedHttpClient(managedClient: managed);

        final deleteTask = scope.client
            .delete(Uri.https('example.com', '/v1beta/files/hanging'))
            .then<void>((_) {}, onError: (_) {});
        scope.trackCleanupTask(deleteTask);

        await tester.pump();
        scope.dispose();
        managed.dispose();

        await tester.pump(const Duration(seconds: 4));
        expect(transport.isClosed, isFalse);
        expect(transport.abortCompletedFlags.single, isFalse);

        await tester.pump(const Duration(seconds: 1));
        expect(transport.abortCompletedFlags.single, isTrue);
        expect(transport.isClosed, isTrue);
      },
    );

    testWidgets(
      'does NOT close an unowned injected base client on dispose',
      (WidgetTester tester) async {
        final transport = AbortObservingHttpClient(
          (request, bytes, trigger) async =>
              http.StreamedResponse(const Stream.empty(), 200),
        );

        final managed = ManagedHttpClient(
          baseClient: transport,
          ownsBaseClient: false,
        );
        final scope = ScopedHttpClient(managedClient: managed);
        scope.dispose();
        managed.dispose();
        await tester.pump();

        expect(transport.isClosed, isFalse);
      },
    );
  });
}
