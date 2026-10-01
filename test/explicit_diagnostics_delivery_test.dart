import 'dart:async';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('default total deadline bounds a transport that never responds', (
    tester,
  ) async {
    RequestOptions? request;
    final dio = _dio((options, _) => request = options);
    DiagnosticsShareException? failure;
    var successes = 0;
    final result = ExplicitDiagnosticsReportClient(dio: dio).send(_report());
    final observed = result.then<void>(
      (_) => successes++,
      onError: (Object error) => failure = error as DiagnosticsShareException,
    );
    await _startRequest(tester);
    expect(request, isNotNull);
    await tester.pump(const Duration(seconds: 29));
    expect(failure, isNull);
    await tester.pump(const Duration(seconds: 2));
    await observed;
    expect(failure?.failure, DiagnosticsShareFailure.timeout);
    expect(failure?.message, contains('may have received'));
    expect(request!.cancelToken!.isCancelled, isTrue);
    expect(successes, 0);
  });

  testWidgets('late acknowledgement cannot turn a timeout into success', (
    tester,
  ) async {
    RequestOptions? request;
    RequestInterceptorHandler? handler;
    final dio = _dio((options, pending) {
      request = options;
      handler = pending;
    });
    var successes = 0;
    DiagnosticsShareException? failure;
    final observed =
        ExplicitDiagnosticsReportClient(
              dio: dio,
              overallTimeout: const Duration(seconds: 2),
            )
            .send(_report())
            .then<void>(
              (_) => successes++,
              onError: (Object error) =>
                  failure = error as DiagnosticsShareException,
            );
    await _startRequest(tester);
    await tester.pump(const Duration(seconds: 3));
    await observed;
    handler!.resolve(_ack(request!));
    await tester.pump();
    expect(failure?.failure, DiagnosticsShareFailure.timeout);
    expect(successes, 0);
  });

  testWidgets('cancelling a stalled request stops waiting immediately', (
    tester,
  ) async {
    final cancellation = CancelToken();
    RequestOptions? request;
    DiagnosticsShareException? failure;
    final observed =
        ExplicitDiagnosticsReportClient(
              dio: _dio((options, _) => request = options),
              cancelToken: cancellation,
            )
            .send(_report())
            .then<void>(
              (_) => fail('Cancellation must not confirm delivery'),
              onError: (Object error) =>
                  failure = error as DiagnosticsShareException,
            );
    await _startRequest(tester);
    cancellation.cancel('private reason must not enter the UI');
    await tester.pump();
    await observed;
    expect(request!.cancelToken!.isCancelled, isTrue);
    expect(failure?.failure, DiagnosticsShareFailure.cancelled);
    expect(failure?.message, contains('not confirmed'));
    expect(failure?.message, isNot(contains('private')));
  });

  for (final cancel in [true, false]) {
    testWidgets(
      'total ${cancel ? 'cancellation' : 'deadline'} covers retry delay',
      (tester) async {
        var attempts = 0;
        final delay = Completer<void>();
        final cancellation = CancelToken();
        DiagnosticsShareException? failure;
        final dio = _dio((options, handler) {
          attempts++;
          handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 503,
              data: {'error': 'channel_unavailable'},
            ),
          );
        });
        final observed =
            ExplicitDiagnosticsReportClient(
                  dio: dio,
                  cancelToken: cancellation,
                  overallTimeout: const Duration(seconds: 2),
                  retryDelay: (_) => delay.future,
                )
                .send(_report())
                .then<void>(
                  (_) => fail('Unconfirmed response must not be success'),
                  onError: (Object error) =>
                      failure = error as DiagnosticsShareException,
                );
        await _startRequest(tester);
        expect(attempts, 1);
        if (cancel) {
          cancellation.cancel();
          await tester.pump();
        } else {
          await tester.pump(const Duration(seconds: 3));
        }
        await observed;
        delay.complete();
        await tester.pump();
        expect(attempts, 1);
        expect(
          failure?.failure,
          cancel
              ? DiagnosticsShareFailure.cancelled
              : DiagnosticsShareFailure.timeout,
        );
      },
    );
  }

  test('already-cancelled send never uploads', () async {
    final cancellation = CancelToken()..cancel();
    var attempts = 0;
    await expectLater(
      ExplicitDiagnosticsReportClient(
        dio: _dio((_, _) => attempts++),
        cancelToken: cancellation,
      ).send(_report()),
      throwsA(_failure(DiagnosticsShareFailure.cancelled)),
    );
    expect(attempts, 0);
  });

  test('a valid confirmation completes without a lingering deadline', () async {
    final response = await ExplicitDiagnosticsReportClient(
      dio: _dio((options, handler) => handler.resolve(_ack(options))),
    ).send(_report());
    expect(response.reference, 'AbCdEfGhIjKlMnOp');
    expect(response.duplicate, isFalse);
  });

  for (final (status, body, failure) in [
    (
      202,
      {'status': 'queued', 'incident_id': 'AbCdEfGhIjKlMnOp'},
      DiagnosticsShareFailure.invalidConfirmation,
    ),
    (
      202,
      {'status': 'posted', 'incident_id': 'bad'},
      DiagnosticsShareFailure.invalidConfirmation,
    ),
    (
      202,
      '<html>private response</html>',
      DiagnosticsShareFailure.invalidConfirmation,
    ),
    (429, {}, DiagnosticsShareFailure.rateLimited),
    (413, {}, DiagnosticsShareFailure.reportTooLarge),
    (400, {}, DiagnosticsShareFailure.reportRejected),
    (415, {}, DiagnosticsShareFailure.reportRejected),
    (503, {}, DiagnosticsShareFailure.channelUnavailable),
  ]) {
    test('HTTP $status preserves safe failure $failure', () async {
      await expectLater(
        ExplicitDiagnosticsReportClient(
          dio: _dio(
            (options, handler) => handler.resolve(
              Response<Object?>(
                requestOptions: options,
                statusCode: status,
                data: body,
              ),
            ),
          ),
          retryDelay: (_) async {},
        ).send(_report()),
        throwsA(
          _failure(failure).having(
            (error) => error.message,
            'safe message',
            isNot(contains('private')),
          ),
        ),
      );
    });
  }

  for (final type in [
    DioExceptionType.receiveTimeout,
    DioExceptionType.transformTimeout,
    DioExceptionType.connectionError,
  ]) {
    test('$type retries remain bounded with a safe final failure', () async {
      var attempts = 0;
      await expectLater(
        ExplicitDiagnosticsReportClient(
          dio: _dio((options, handler) {
            attempts++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: type,
                message: 'private network address',
              ),
            );
          }),
          retryDelay: (_) async {},
        ).send(_report()),
        throwsA(
          _failure(
            type != DioExceptionType.connectionError
                ? DiagnosticsShareFailure.timeout
                : DiagnosticsShareFailure.networkUnavailable,
          ).having(
            (error) => error.message,
            'safe message',
            isNot(contains('private')),
          ),
        ),
      );
      expect(attempts, 3);
    });
  }

  test(
    'malformed receiver JSON is not mistaken for a network outage or retried',
    () async {
      var attempts = 0;
      await expectLater(
        ExplicitDiagnosticsReportClient(
          dio: _dio((options, handler) {
            attempts++;
            handler.reject(
              DioException(
                requestOptions: options,
                error: const FormatException('private proxy response'),
              ),
            );
          }),
          retryDelay: (_) async {},
        ).send(_report()),
        throwsA(_failure(DiagnosticsShareFailure.invalidConfirmation)),
      );
      expect(attempts, 1);
    },
  );
}

TypeMatcher<DiagnosticsShareException> _failure(
  DiagnosticsShareFailure failure,
) => isA<DiagnosticsShareException>().having(
  (error) => error.failure,
  'failure',
  failure,
);

Future<void> _startRequest(WidgetTester tester) async {
  // Dio chains request interceptors through zero-duration event-queue timers,
  // not just microtasks. Advance those before asserting transport activity.
  for (var step = 0; step < 5; step++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Dio _dio(void Function(RequestOptions, RequestInterceptorHandler) callback) =>
    Dio()..interceptors.add(InterceptorsWrapper(onRequest: callback));

Response<Object?> _ack(RequestOptions request) => Response<Object?>(
  requestOptions: request,
  statusCode: 202,
  data: {'status': 'posted', 'incident_id': 'AbCdEfGhIjKlMnOp'},
);

ExplicitDiagnosticsReport _report() => ExplicitDiagnosticsReport(
  eventId: 'diag-AbCdEfGhIjKlMnOpQrStUvWx',
  submittedAt: DateTime.utc(2026, 9, 30),
  appVersion: '2.0.77',
  buildNumber: 410054,
  androidSdk: 36,
  abi: 'arm64-v8a',
  deviceClass: 'tv',
  report: 'Redacted technical data',
);
