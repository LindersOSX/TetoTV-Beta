import 'dart:io';

import 'package:anime_tv/features/auth/data/anilist_pairing_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('health retries bounded Android DNS lookup failures', () async {
    var calls = 0;
    final delays = <Duration>[];
    final dio = _dio((request, handler) {
      calls++;
      if (calls < 3) {
        _rejectDns(request, handler);
        return;
      }
      handler.resolve(
        Response<Object?>(
          requestOptions: request,
          statusCode: 200,
          data: {
            'status': 'ok',
            'providers': {'anilist': true},
          },
        ),
      );
    });
    addTearDown(() => dio.close(force: true));
    final client = TrackingPairingClient(
      TrackingProvider.anilist,
      baseUrl: 'https://auth.example.test',
      dio: dio,
      delay: (duration) async => delays.add(duration),
    );

    await client.ensureReady();

    expect(calls, 3);
    expect(delays, const [
      Duration(milliseconds: 400),
      Duration(milliseconds: 1200),
    ]);
  });

  test(
    'session creation retries only when DNS never opened a connection',
    () async {
      var calls = 0;
      final dio = _dio((request, handler) {
        calls++;
        if (calls == 1) {
          _rejectDns(request, handler);
          return;
        }
        handler.resolve(
          Response<Object?>(
            requestOptions: request,
            statusCode: 201,
            data: _pairingPayload(),
          ),
        );
      });
      addTearDown(() => dio.close(force: true));
      final client = TrackingPairingClient(
        TrackingProvider.anilist,
        baseUrl: 'https://auth.example.test',
        dio: dio,
        delay: (_) async {},
      );

      final session = await client.createSession();

      expect(calls, 2);
      expect(session.userCode, 'TEST-CODE');
    },
  );

  test('non-DNS connection failure is not retried or exposed raw', () async {
    var calls = 0;
    final dio = _dio((request, handler) {
      calls++;
      handler.reject(
        DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
          error: const SocketException('Connection refused'),
        ),
      );
    });
    addTearDown(() => dio.close(force: true));
    final client = TrackingPairingClient(
      TrackingProvider.anilist,
      baseUrl: 'https://auth.example.test',
      dio: dio,
      delay: (_) async {},
    );

    await expectLater(
      client.ensureReady(),
      throwsA(
        isA<TrackingPairingServiceException>()
            .having((error) => error.reasonCode, 'reason', 'network_failure')
            .having(
              (error) => error.toString(),
              'message',
              allOf(contains('could not be reached'), isNot(contains('Dio'))),
            ),
      ),
    );
    expect(calls, 1);
  });

  test(
    'HTTP 429 keeps bounded Retry-After metadata and no response body',
    () async {
      final dio = _dio((request, handler) {
        handler.reject(
          DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response<Object?>(
              requestOptions: request,
              statusCode: 429,
              headers: Headers.fromMap({
                'retry-after': ['27'],
              }),
              data: {'error': 'private server detail'},
            ),
          ),
        );
      });
      addTearDown(() => dio.close(force: true));
      final client = TrackingPairingClient(
        TrackingProvider.anilist,
        baseUrl: 'https://auth.example.test',
        dio: dio,
      );

      await expectLater(
        client.createSession(),
        throwsA(
          isA<TrackingPairingServiceException>()
              .having((error) => error.reasonCode, 'reason', 'rate_limited')
              .having((error) => error.httpStatus, 'status', 429)
              .having(
                (error) => error.retryAfter,
                'retry after',
                const Duration(seconds: 27),
              )
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('private server detail')),
              ),
        ),
      );
    },
  );

  test('polling 429 stays pending and carries its backoff reason', () async {
    final dio = _dio((request, handler) {
      handler.reject(
        DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response<Object?>(
            requestOptions: request,
            statusCode: 429,
            headers: Headers.fromMap({
              'retry-after': ['45'],
            }),
          ),
        ),
      );
    });
    addTearDown(() => dio.close(force: true));
    final client = TrackingPairingClient(
      TrackingProvider.anilist,
      baseUrl: 'https://auth.example.test',
      dio: dio,
    );

    final result = await client.poll(_session());

    expect(result.status, PairingStatus.pending);
    expect(result.retryAfter, const Duration(seconds: 45));
    expect(result.diagnosticReason, 'rate_limited');
  });

  test('polling DNS failures use the safe app-authored exception', () async {
    final dio = _dio(_rejectDns);
    addTearDown(() => dio.close(force: true));
    final client = TrackingPairingClient(
      TrackingProvider.anilist,
      baseUrl: 'https://auth.example.test',
      dio: dio,
    );

    await expectLater(
      client.poll(_session()),
      throwsA(
        isA<TrackingPairingServiceException>()
            .having((error) => error.reasonCode, 'reason', 'dns_lookup_failed')
            .having(
              (error) => error.toString(),
              'message',
              allOf(contains('Private DNS'), isNot(contains('DioException'))),
            ),
      ),
    );
  });

  test('acknowledgement authenticates deletion after secure storage', () async {
    RequestOptions? observed;
    final dio = _dio((request, handler) {
      observed = request;
      handler.resolve(
        Response<Object?>(requestOptions: request, statusCode: 200),
      );
    });
    addTearDown(() => dio.close(force: true));
    final client = TrackingPairingClient(
      TrackingProvider.anilist,
      baseUrl: 'https://auth.example.test',
      dio: dio,
    );

    await client.acknowledge(_session());

    expect(observed?.method, 'DELETE');
    expect(observed?.path, 'v1/anilist/pairings/pairing-id');
    expect(observed?.headers['Authorization'], 'Pairing device-code');
  });

  test('missing acknowledgement state is an idempotent success', () async {
    final dio = _dio((request, handler) {
      handler.reject(
        DioException(
          requestOptions: request,
          type: DioExceptionType.badResponse,
          response: Response<Object?>(requestOptions: request, statusCode: 404),
        ),
      );
    });
    addTearDown(() => dio.close(force: true));
    final client = TrackingPairingClient(
      TrackingProvider.anilist,
      baseUrl: 'https://auth.example.test',
      dio: dio,
    );

    await client.acknowledge(_session());
  });
}

Dio _dio(
  void Function(RequestOptions request, RequestInterceptorHandler handler)
  responder,
) =>
    Dio(BaseOptions(baseUrl: 'https://auth.example.test/'))
      ..interceptors.add(InterceptorsWrapper(onRequest: responder));

void _rejectDns(RequestOptions request, RequestInterceptorHandler handler) {
  handler.reject(
    DioException(
      requestOptions: request,
      type: DioExceptionType.connectionError,
      error: const SocketException(
        'Failed host lookup: auth.example.test',
        osError: OSError('No address associated with hostname', 7),
      ),
    ),
  );
}

Map<String, Object?> _pairingPayload() => {
  'pairing_id': 'pairing-id',
  'device_code': 'device-code',
  'user_code': 'TEST-CODE',
  'verification_uri': 'https://auth.example.test/pair',
  'verification_uri_complete': 'https://auth.example.test/pair?code=TEST-CODE',
  'expires_at': DateTime.now()
      .toUtc()
      .add(const Duration(minutes: 10))
      .toIso8601String(),
  'interval': 5,
};

PairingSession _session() => PairingSession(
  pairingId: 'pairing-id',
  deviceCode: 'device-code',
  userCode: 'TEST-CODE',
  verificationUri: 'https://auth.example.test/pair',
  verificationUriComplete: 'https://auth.example.test/pair?code=TEST-CODE',
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
  pollInterval: const Duration(seconds: 5),
);
