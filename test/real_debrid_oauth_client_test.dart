import 'package:anime_tv/features/auth/data/real_debrid_oauth_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RealDebridDeviceSession', () {
    test('parses the official device response and preserves the user code', () {
      final now = DateTime.utc(2026, 8, 10, 12);

      final session = RealDebridDeviceSession.fromJson({
        'device_code': 'device-secret',
        'user_code': 'ABCD1234EFGHI',
        'verification_url': 'https://real-debrid.com/device',
        'interval': '5',
        'expires_in': '1800',
      }, now: now);

      expect(session.deviceCode, 'device-secret');
      expect(session.userCode, 'ABCD1234EFGHI');
      expect(
        session.verificationUrl,
        Uri.parse('https://real-debrid.com/device'),
      );
      expect(session.interval, const Duration(seconds: 5));
      expect(session.expiresAt, now.add(const Duration(minutes: 30)));
    });

    test('clamps polling intervals to a safe range', () {
      final fast = RealDebridDeviceSession.fromJson({
        'device_code': 'fast',
        'user_code': 'FAST-CODE',
        'verification_url': 'https://real-debrid.com/device',
        'interval': 0,
        'expires_in': 1800,
      });
      final slow = RealDebridDeviceSession.fromJson({
        'device_code': 'slow',
        'user_code': 'SLOW-CODE',
        'verification_url': 'https://real-debrid.com/device',
        'interval': 120,
        'expires_in': 1800,
      });

      expect(fast.interval, const Duration(seconds: 3));
      expect(slow.interval, const Duration(seconds: 30));
    });

    test('rejects missing codes, expired sessions, and untrusted URLs', () {
      for (final body in [
        {
          'device_code': 'device-secret',
          'verification_url': 'https://real-debrid.com/device',
          'expires_in': 1800,
        },
        {
          'device_code': 'device-secret',
          'user_code': 'CODE',
          'verification_url': 'https://real-debrid.com/device',
          'expires_in': 0,
        },
        {
          'device_code': 'device-secret',
          'user_code': 'CODE',
          'verification_url': 'http://real-debrid.com/device',
          'expires_in': 1800,
        },
        {
          'device_code': 'device-secret',
          'user_code': 'CODE',
          'verification_url': 'https://real-debrid.com.attacker.test/device',
          'expires_in': 1800,
        },
      ]) {
        expect(
          () => RealDebridDeviceSession.fromJson(body),
          throwsFormatException,
          reason: body.toString(),
        );
      }
    });
  });

  test('start maps HTTP 429 and never replays device-code creation', () async {
    var requests = 0;
    final dio = _rejectingDio(
      onRequest: (options) {
        requests++;
        return _rateLimitFailure(options, retryAfter: '9999');
      },
    );

    final error = await _capture(
      RealDebridOAuthClient(dio: dio).startDeviceAuthorization(),
    );

    expect(error, isA<RealDebridOAuthException>());
    final oauthError = error as RealDebridOAuthException;
    expect(oauthError.stage, RealDebridOAuthStage.start);
    expect(oauthError.reasonCode, 'rate_limited');
    expect(oauthError.retryAfter, const Duration(minutes: 5));
    expect(oauthError.isPollingDeferred, isFalse);
    expect(oauthError.toString(), isNot(contains('DioException')));
    expect(oauthError.toString(), isNot(contains('private-provider-body')));
    expect(requests, 1, reason: 'device-code creation must not be replayed');
  });

  test(
    'credentials polling 429 remains pending and honors Retry-After',
    () async {
      var requests = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://real-debrid.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 429,
                  headers: Headers.fromMap(const {
                    'retry-after': ['17'],
                  }),
                  data: const {'error': 'private-provider-body'},
                ),
              );
            },
          ),
        );

      final error = await _capture(
        RealDebridOAuthClient(dio: dio).pollCredentials(_session()),
      );

      expect(error, isA<RealDebridOAuthException>());
      final oauthError = error as RealDebridOAuthException;
      expect(oauthError.stage, RealDebridOAuthStage.poll);
      expect(oauthError.isPollingDeferred, isTrue);
      expect(oauthError.retryAfter, const Duration(seconds: 17));
      expect(oauthError.toString(), contains('continue automatically'));
      expect(oauthError.toString(), isNot(contains('device-secret')));
      expect(oauthError.toString(), isNot(contains('private-provider-body')));
      expect(requests, 1);
    },
  );

  test('token exchange 429 is safe and is not retried automatically', () async {
    var requests = 0;
    final dio = _rejectingDio(
      onRequest: (options) {
        requests++;
        return _rateLimitFailure(options, retryAfter: '8');
      },
    );

    final error = await _capture(
      RealDebridOAuthClient(dio: dio).exchangeDeviceCode(
        session: _session(),
        credentials: const RealDebridOAuthCredentials(
          clientId: 'private-client-id',
          clientSecret: 'private-client-secret',
        ),
      ),
    );

    expect(error, isA<RealDebridOAuthException>());
    final oauthError = error as RealDebridOAuthException;
    expect(oauthError.stage, RealDebridOAuthStage.exchange);
    expect(oauthError.isPollingDeferred, isFalse);
    expect(oauthError.retryAfter, const Duration(seconds: 8));
    expect(oauthError.toString(), contains('approved the device'));
    expect(oauthError.toString(), isNot(contains('private-client-secret')));
    expect(oauthError.toString(), isNot(contains('DioException')));
    expect(requests, 1, reason: 'the token POST must not be replayed');
  });
}

RealDebridDeviceSession _session() => RealDebridDeviceSession(
  deviceCode: 'device-secret',
  userCode: 'ABCD1234',
  verificationUrl: Uri.parse('https://real-debrid.com/device'),
  interval: const Duration(seconds: 5),
  expiresAt: DateTime.now().add(const Duration(minutes: 10)),
);

Future<Object> _capture(Future<Object?> operation) async {
  try {
    await operation;
  } catch (error) {
    return error;
  }
  fail('Expected the operation to throw.');
}

Dio _rejectingDio({
  required DioException Function(RequestOptions options) onRequest,
}) => Dio(BaseOptions(baseUrl: 'https://real-debrid.test'))
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(onRequest(options)),
    ),
  );

DioException _rateLimitFailure(
  RequestOptions options, {
  required String retryAfter,
}) => DioException(
  requestOptions: options,
  type: DioExceptionType.badResponse,
  response: Response<Map<String, dynamic>>(
    requestOptions: options,
    statusCode: 429,
    headers: Headers.fromMap({
      'retry-after': [retryAfter],
    }),
    data: const {'error': 'private-provider-body'},
  ),
);
