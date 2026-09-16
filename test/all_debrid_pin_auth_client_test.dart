import 'package:anime_tv/features/auth/data/all_debrid_pin_auth_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts and completes the official PIN authorization flow', () async {
    var checks = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final data = options.path == '/v4.1/pin/get'
                ? const <String, dynamic>{
                    'status': 'success',
                    'data': {
                      'pin': 'TETO',
                      'check': 'check-id',
                      'expires_in': 600,
                      'user_url': 'https://alldebrid.com/pin/?pin=TETO',
                    },
                  }
                : <String, dynamic>{
                    'status': 'success',
                    'data': {
                      'activated': ++checks > 1,
                      'expires_in': 590,
                      if (checks > 1) 'apikey': 'approved-api-key',
                    },
                  };
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
    final client = AllDebridPinAuthClient(dio: dio);

    final session = await client.start();
    expect(session.pin, 'TETO');
    expect(session.verificationUrl.scheme, 'https');
    expect(await client.poll(session), isNull);
    expect(await client.poll(session), 'approved-api-key');
  });

  test('rejects a PIN page outside the AllDebrid service', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'status': 'success',
                'data': {
                  'pin': 'TETO',
                  'check': 'check-id',
                  'expires_in': 600,
                  'user_url': 'https://alldebrid.com.attacker.test/pin/',
                },
              },
            ),
          ),
        ),
      );

    expect(
      AllDebridPinAuthClient(dio: dio).start(),
      throwsA(isA<AllDebridException>()),
    );
  });

  test(
    'start maps HTTP 429 without replaying PIN creation or leaking Dio',
    () async {
      var requests = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 429,
                    headers: Headers.fromMap(const {
                      'retry-after': ['9999'],
                    }),
                    data: const {'error': 'private-provider-response'},
                  ),
                ),
              );
            },
          ),
        );

      Object? thrown;
      try {
        await AllDebridPinAuthClient(dio: dio).start();
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<AllDebridPinAuthException>());
      final error = thrown! as AllDebridPinAuthException;
      expect(error.httpStatus, 429);
      expect(error.retryAfter, const Duration(minutes: 5));
      expect(error.isPollingDeferred, isFalse);
      expect(error.toString(), contains('rate-limited'));
      expect(error.toString(), isNot(contains('DioException')));
      expect(error.toString(), isNot(contains('private-provider-response')));
      expect(requests, 1, reason: 'PIN creation must not be replayed');
    },
  );

  test('polling HTTP 429 remains pending with bounded Retry-After', () async {
    var requests = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 429,
                  headers: Headers.fromMap(const {
                    'retry-after': ['12'],
                  }),
                  data: const {'error': 'do-not-render-this'},
                ),
              ),
            );
          },
        ),
      );
    final session = AllDebridPinSession(
      pin: 'TETO',
      check: 'private-check-secret',
      verificationUrl: Uri.parse('https://alldebrid.com/pin/'),
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );

    Object? thrown;
    try {
      await AllDebridPinAuthClient(dio: dio).poll(session);
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<AllDebridPinAuthException>());
    final error = thrown! as AllDebridPinAuthException;
    expect(error.isPollingDeferred, isTrue);
    expect(error.retryAfter, const Duration(seconds: 12));
    expect(error.toString(), contains('continue automatically'));
    expect(error.toString(), isNot(contains('private-check-secret')));
    expect(error.toString(), isNot(contains('do-not-render-this')));
    expect(requests, 1);
  });
}
