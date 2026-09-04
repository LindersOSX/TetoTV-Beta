import 'package:anime_tv/features/auth/data/simkl_pin_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/settings/application/simkl_account_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates a direct official SIMKL PIN session', () async {
    late RequestOptions request;
    final now = DateTime.utc(2026, 9, 2, 12);
    final client = _client(
      now: () => now,
      onRequest: (options) {
        request = options;
        return const {
          'result': 'OK',
          'device_code': 'server-device-code',
          'user_code': '483414',
          'verification_uri': 'https://simkl.com/pin',
          'expires_in': 600,
          'interval': 5,
        };
      },
    );

    final session = await client.createPairing();

    expect(request.method, 'GET');
    expect(request.path, '/oauth/pin');
    expect(request.queryParameters, {
      'client_id': 'public-client-id',
      'app-name': 'tetotv',
      'app-version': '2.0.64',
    });
    expect(request.headers['User-Agent'], 'tetotv/2.0.64');
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(session.userCode, '483414');
    expect(session.verificationUri, 'https://simkl.com/pin');
    expect(session.pollInterval, const Duration(seconds: 5));
    expect(session.expiresAt, now.add(const Duration(minutes: 10)));
  });

  test('accepts the official SIMKL PIN URL with a trailing slash', () async {
    final client = _client(
      onRequest: (_) => const {
        'result': 'OK',
        'user_code': '483414',
        'verification_uri': 'https://simkl.com/pin/',
        'expires_in': 600,
        'interval': 5,
      },
    );

    final session = await client.createPairing();

    expect(session.verificationUri, 'https://simkl.com/pin/');
  });

  test('polls pending then returns the authorized access token', () async {
    var polls = 0;
    final requests = <RequestOptions>[];
    final client = _client(
      onRequest: (options) {
        requests.add(options);
        polls++;
        if (polls == 1) {
          return const {'result': 'KO', 'message': 'Authorization pending'};
        }
        return const {'result': 'OK', 'access_token': 'private-simkl-token'};
      },
    );
    final session = _session();

    final pending = await client.pollPairing(session);
    final authorized = await client.pollPairing(session);

    expect(pending.status, PairingStatus.pending);
    expect(authorized.status, PairingStatus.authorized);
    expect(authorized.accessToken, 'private-simkl-token');
    expect(requests, hasLength(2));
    expect(requests.first.path, '/oauth/pin/483414');
    expect(requests.first.queryParameters['client_id'], 'public-client-id');
  });

  test('treats a recycled PIN initialization response as expired', () async {
    final client = _client(
      onRequest: (_) => const {
        'result': 'OK',
        'device_code': 'new-device-code',
        'user_code': '999999',
        'verification_uri': 'https://simkl.com/pin',
        'expires_in': 600,
        'interval': 5,
      },
    );

    final result = await client.pollPairing(_session());

    expect(result.status, PairingStatus.expired);
  });

  test('rejects a non-official verification URL', () async {
    final client = _client(
      onRequest: (_) => const {
        'result': 'OK',
        'user_code': '483414',
        'verification_uri': 'https://example.test/pin',
        'expires_in': 600,
        'interval': 5,
      },
    );

    await expectLater(
      client.createPairing(),
      throwsA(isA<SimklPinException>()),
    );
  });

  test('surfaces a retry-after-aware transient PIN failure', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException.badResponse(
              statusCode: 429,
              requestOptions: options,
              response: Response<Object?>(
                requestOptions: options,
                statusCode: 429,
                headers: Headers.fromMap({
                  'retry-after': ['17'],
                }),
              ),
            ),
          ),
        ),
      );
    final client = SimklPinClient(
      clientId: 'public-client-id',
      appVersion: '2.0.64',
      dio: dio,
      now: () => DateTime.utc(2026, 9, 2, 12),
    );

    await expectLater(
      client.pollPairing(_session()),
      throwsA(
        isA<SimklPinTransientException>()
            .having((error) => error.statusCode, 'statusCode', 429)
            .having(
              (error) => error.retryAfter,
              'retryAfter',
              const Duration(seconds: 17),
            ),
      ),
    );
  });

  test('does not classify a terminal PIN response as retryable', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException.badResponse(
              statusCode: 401,
              requestOptions: options,
              response: Response<Object?>(
                requestOptions: options,
                statusCode: 401,
              ),
            ),
          ),
        ),
      );
    final client = SimklPinClient(
      clientId: 'public-client-id',
      appVersion: '2.0.64',
      dio: dio,
      now: () => DateTime.utc(2026, 9, 2, 12),
    );

    await expectLater(
      client.pollPairing(_session()),
      throwsA(
        isA<SimklPinException>().having(
          (error) => error is SimklPinTransientException,
          'is transient',
          isFalse,
        ),
      ),
    );
  });

  test('PIN retry policy respects interval, retry-after, cap, and limit', () {
    const policy = SimklPairingPollPolicy();

    expect(
      policy.retryDelay(
        pollInterval: const Duration(seconds: 5),
        consecutiveFailures: 1,
      ),
      const Duration(seconds: 5),
    );
    expect(
      policy.retryDelay(
        pollInterval: const Duration(seconds: 5),
        consecutiveFailures: 2,
      ),
      const Duration(seconds: 10),
    );
    expect(
      policy.retryDelay(
        pollInterval: const Duration(seconds: 5),
        consecutiveFailures: 3,
        retryAfter: const Duration(seconds: 45),
      ),
      const Duration(seconds: 45),
    );
    expect(
      policy.retryDelay(
        pollInterval: const Duration(seconds: 30),
        consecutiveFailures: 4,
        retryAfter: const Duration(minutes: 2),
      ),
      SimklPairingPollPolicy.maximumDelay,
    );
    expect(policy.canRetry(4), isTrue);
    expect(policy.canRetry(5), isFalse);
  });
}

SimklPinClient _client({
  required Map<String, dynamic> Function(RequestOptions) onRequest,
  DateTime Function()? now,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 200,
            data: onRequest(options),
          ),
        ),
      ),
    );
  return SimklPinClient(
    clientId: 'public-client-id',
    appVersion: '2.0.64',
    dio: dio,
    now: now ?? () => DateTime.utc(2026, 9, 2, 12),
  );
}

PairingSession _session() => PairingSession(
  pairingId: '483414',
  deviceCode: '483414',
  userCode: '483414',
  verificationUri: 'https://simkl.com/pin',
  verificationUriComplete: 'https://simkl.com/pin',
  expiresAt: DateTime.utc(2026, 9, 2, 12, 10),
  pollInterval: const Duration(seconds: 5),
);
