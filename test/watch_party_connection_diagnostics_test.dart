import 'dart:convert';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final type in DioExceptionType.values) {
    test(
      'connection failure retains only the closed ${type.name} category',
      () async {
        var calls = 0;
        final dio = _dio((options, handler) {
          calls++;
          handler.reject(
            DioException(
              requestOptions: options,
              type: type,
              message: 'private-host.example?access_token=private-token',
              error: 'Authorization: Bearer private-token',
              response: type == DioExceptionType.badResponse
                  ? Response<Object?>(
                      requestOptions: options,
                      statusCode: 503,
                      data: '<html>private-token</html>',
                    )
                  : null,
            ),
          );
        });
        final client = WatchPartyClient(baseUrl: _origin, dio: dio);
        final error = await _capture(client.create());
        final expected = switch (type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.sendTimeout ||
          DioExceptionType.receiveTimeout ||
          DioExceptionType.transformTimeout => 'timeout',
          DioExceptionType.badResponse => 'server_error',
          _ => 'network_unavailable',
        };
        expect(error.code, expected);
        expect(error.transportType, type);
        expect(
          error.statusCode,
          type == DioExceptionType.badResponse ? 503 : null,
        );
        expect(error.diagnosticDetails['phase'], type.name);
        expect(error.diagnosticDetails['reason_code'], expected);
        expect(error.toString(), expected);
        expect(jsonEncode(error.diagnosticDetails), isNot(contains('private')));
        expect(calls, 1, reason: 'room creation is never blindly retried');
      },
    );
  }

  test(
    'wrapped decoder FormatException is invalid_response, not an outage',
    () async {
      final dio = _dio((options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            error: const FormatException('private body token'),
            response: Response<Object?>(
              requestOptions: options,
              statusCode: 200,
            ),
          ),
        );
      });
      final error = await _capture(
        WatchPartyClient(baseUrl: _origin, dio: dio).health(),
      );
      expect(error.code, 'invalid_response');
      expect(error.statusCode, 200);
      expect(error.transportType, DioExceptionType.unknown);
      expect(error.diagnosticDetails, {
        'reason_code': 'invalid_response',
        'phase': 'unknown',
        'code': 200,
      });
    },
  );

  for (final data in <Object?>[
    '<html>private body token</html>',
    '{"private-token":',
    '[1,2,3]',
    'null',
    {..._createdJson, 'room_code': 123},
    {
      ..._createdJson,
      'host_token': ['private-token'],
    },
    {..._createdJson, 'expires_at': 'not-a-date'},
    {..._createdJson, 'watch_url': 'https://[invalid]'},
  ]) {
    test(
      'malformed successful create response stays invalid_response: ${data.runtimeType}',
      () async {
        var calls = 0;
        final dio = _dio((options, handler) {
          calls++;
          expect(options.responseType, ResponseType.plain);
          handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 201,
              data: data,
            ),
          );
        });
        final client = WatchPartyClient(baseUrl: _origin, dio: dio)
          ..setPublicIdentity(
            WatchPartyPublicIdentity.tryCreate(displayName: 'Viewer'),
          );
        final error = await _capture(client.create());
        expect(error.code, 'invalid_response');
        expect(error.statusCode, 201);
        expect(error.transportType, isNull);
        expect(error.diagnosticDetails, {
          'reason_code': 'invalid_response',
          'code': 201,
        });
        expect(
          calls,
          1,
          reason: 'a malformed successful create cannot be retried',
        );
      },
    );
  }

  test(
    'raw JSON success is decoded without changing room URLs or capabilities',
    () async {
      final dio = _dio(
        (options, handler) => handler.resolve(
          Response<Object?>(
            requestOptions: options,
            statusCode: 201,
            data: jsonEncode(_createdJson),
          ),
        ),
      );
      final result = await WatchPartyClient(
        baseUrl: _origin,
        dio: dio,
      ).create();
      expect(result.session.roomCode, '23456789');
      expect(
        result.session.token,
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(
        result.session.watchUrl.toString(),
        '$_origin/watch?room=23456789',
      );
    },
  );

  test(
    'malformed nested snapshot carries the successful join HTTP status',
    () async {
      final dio = _dio(
        (options, handler) => handler.resolve(
          Response<Object?>(
            requestOptions: options,
            statusCode: 200,
            data: {
              'participant_token': _createdJson['host_token'],
              'expires_at': _createdJson['expires_at'],
              'state': {
                'room_code': '23456789',
                'role': 'guest',
                'revision': 'private-value',
              },
            },
          ),
        ),
      );
      final error = await _capture(
        WatchPartyClient(baseUrl: _origin, dio: dio).join('23456789'),
      );
      expect(error.code, 'invalid_response');
      expect(error.statusCode, 200);
    },
  );

  for (final rawError in <Object?>[
    'private-token https://private-host.example',
    {'secret': 'private-token'},
    null,
  ]) {
    test(
      'unknown HTTP error body remains a safe server_error: ${rawError.runtimeType}',
      () async {
        final dio = _dio(
          (options, handler) => handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 502,
              data: {'error': rawError},
            ),
          ),
        );
        final error = await _capture(
          WatchPartyClient(baseUrl: _origin, dio: dio).create(),
        );
        expect(error.code, 'server_error');
        expect(error.statusCode, 502);
        expect(error.diagnosticDetails, {
          'reason_code': 'server_error',
          'code': 502,
        });
      },
    );
  }

  test(
    'known HTTP errors and a bounded retry hint remain compatible',
    () async {
      final dio = _dio(
        (options, handler) => handler.resolve(
          Response<Object?>(
            requestOptions: options,
            statusCode: 429,
            headers: Headers.fromMap({
              'retry-after': ['60'],
            }),
            data: '{"error":"rate_limited"}',
          ),
        ),
      );
      final error = await _capture(
        WatchPartyClient(baseUrl: _origin, dio: dio).create(),
      );
      expect(error.code, 'rate_limited');
      expect(error.statusCode, 429);
      expect(error.retryAfter, const Duration(seconds: 60));
    },
  );

  test(
    'client exception diagnostics close unknown codes and invalid statuses',
    () {
      const error = WatchPartyClientException(
        'private-token',
        statusCode: 123456,
      );
      expect(error.diagnosticDetails, {'reason_code': 'unknown_error'});
    },
  );

  test(
    'create failure metadata survives database sanitization and copied export',
    () async {
      final events = <Map<String, Object?>>[];
      final dio = _dio(
        (options, handler) => handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
            message: 'private-host.example?token=private-token',
            response: Response<Object?>(
              requestOptions: options,
              statusCode: 504,
              data: {'private': 'private-token'},
            ),
          ),
        ),
      );
      final controller = WatchPartyController(
        WatchPartyClient(baseUrl: _origin, dio: dio),
        diagnostics: (message, details) async {
          events.add({'message': message, 'context': details});
        },
      );
      addTearDown(controller.dispose);
      expect(await controller.create(), isFalse);
      expect(controller.state.isBusy, isFalse);
      expect(controller.state.isActive, isFalse);
      final failure = events.single;
      final safe =
          sanitizeDiagnosticContext(
                failure['context'],
                component: 'watch-party',
              )
              as Map;
      expect(safe['operation'], 'room_create');
      expect(safe['step'], 'create');
      expect(safe['status'], 'failed');
      expect(safe['reason_code'], 'timeout');
      expect(safe['phase'], 'receiveTimeout');
      expect(safe['code'], 504);
      final report = buildRedactedDiagnosticsText(
        version: const AppVersionInfo(name: '2.0.77', code: 410054),
        profile: _profile,
        isTelevision: true,
        diagnostics: {
          'diagnosticEvents': [
            {
              'component': 'watch-party',
              'message': failure['message'],
              'context': safe,
            },
          ],
        },
        generatedAt: DateTime.utc(2026, 9, 30),
      );
      final decoded = jsonDecode(report) as Map;
      final exported =
          ((decoded['diagnostics'] as Map)['diagnosticEvents'] as List).single
              as Map;
      final context = exported['context'] as Map;
      expect(context['operation'], 'room_create');
      expect(context['reason_code'], 'timeout');
      expect(context['phase'], 'receiveTimeout');
      expect(context['code'], 504);
      expect(report, isNot(contains('private-host')));
      expect(report, isNot(contains('private-token')));
      expect(report, isNot(contains(_origin)));
    },
  );

  test(
    'post-create read failure is logged without a second room creation',
    () async {
      var createCalls = 0;
      final events = <Map<String, Object?>>[];
      final dio = _dio((options, handler) {
        if (options.method == 'POST') {
          createCalls++;
          handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 201,
              data: _createdJson,
            ),
          );
        } else {
          handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 200,
              data: '<html>private-token</html>',
            ),
          );
        }
      });
      final controller = WatchPartyController(
        WatchPartyClient(baseUrl: _origin, dio: dio),
        diagnostics: (_, details) async => events.add(details),
      );
      addTearDown(controller.dispose);
      expect(await controller.create(), isFalse);
      expect(createCalls, 1);
      final failure = events.single;
      expect(failure['step'], 'read_room');
      expect(failure['reason_code'], 'invalid_response');
      expect(failure['code'], 200);
      expect(failure, isNot(contains('phase')));
      expect(controller.state.isActive, isFalse);
    },
  );
}

const _origin = 'https://tetotv.example';
const _createdJson = <String, Object?>{
  'room_code': '23456789',
  'host_token': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'expires_at': '2030-01-01T00:00:00Z',
};

Dio _dio(void Function(RequestOptions, RequestInterceptorHandler) request) =>
    Dio(BaseOptions(baseUrl: _origin))
      ..interceptors.add(InterceptorsWrapper(onRequest: request));

Future<WatchPartyClientException> _capture(Future<Object?> request) async {
  try {
    await request;
  } on WatchPartyClientException catch (error) {
    return error;
  }
  throw StateError('Expected a safe client failure.');
}

const _profile = TvDeviceProfile(
  manufacturer: 'Example',
  model: 'TV',
  sdk: 36,
  abis: ['arm64-v8a'],
  displayModes: [],
  hdrTypes: [],
  codecs: [],
  audioOutputs: [],
);
