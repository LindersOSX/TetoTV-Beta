import 'package:anime_tv/features/auth/data/simkl_broker_capability_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts SIMKL only when every broker capability agrees', () async {
    late RequestOptions request;
    final client = SimklBrokerCapabilityClient(
      baseUrl: 'https://auth.example.test',
      dio: _jsonDio((options) {
        request = options;
        return {
          'status': 'ok',
          'providers': {'simkl': true},
          'callbacks': {
            'simkl': 'https://auth.example.test/oauth/simkl/callback',
          },
          'provider_client_ids': {'simkl': 'public-simkl-client-id'},
        };
      }),
    );

    final capability = await client.probe();

    expect(request.uri.toString(), 'https://auth.example.test/health');
    expect(capability?.clientId, 'public-simkl-client-id');
    expect(
      capability?.callbackUri.toString(),
      'https://auth.example.test/oauth/simkl/callback',
    );
  });

  test('accepts direct PIN readiness with a public client ID alone', () async {
    final client = SimklBrokerCapabilityClient(
      baseUrl: 'https://auth.example.test',
      dio: _jsonDio(
        (_) => {
          'status': 'ok',
          'providers': {'simkl': false},
          'provider_device_flows': {'simkl': true},
          'provider_client_ids': {'simkl': 'public-simkl-client-id'},
        },
      ),
    );

    final capability = await client.probe();

    expect(capability?.clientId, 'public-simkl-client-id');
    expect(capability?.callbackUri, isNull);
  });

  test('direct PIN readiness does not trust an unrelated callback', () async {
    final client = SimklBrokerCapabilityClient(
      baseUrl: 'https://auth.example.test',
      dio: _jsonDio(
        (_) => {
          'status': 'ok',
          'provider_device_flows': {'simkl': true},
          'callbacks': {
            'simkl': 'https://attacker.example.test/oauth/simkl/callback',
          },
          'provider_client_ids': {'simkl': 'public-simkl-client-id'},
        },
      ),
    );

    final capability = await client.probe();

    expect(capability, isNotNull);
    expect(capability?.callbackUri, isNull);
  });

  test('fails closed for incomplete or cross-origin readiness', () async {
    for (final payload in <Map<String, dynamic>>[
      {
        'status': 'ok',
        'providers': {'simkl': false},
        'callbacks': {
          'simkl': 'https://auth.example.test/oauth/simkl/callback',
        },
        'provider_client_ids': {'simkl': 'public-id'},
      },
      {
        'status': 'ok',
        'providers': {'simkl': true},
        'callbacks': {'simkl': 'https://attacker.example/oauth/simkl/callback'},
        'provider_client_ids': {'simkl': 'public-id'},
      },
      {
        'status': 'ok',
        'providers': {'simkl': true},
        'callbacks': {
          'simkl': 'https://auth.example.test/oauth/simkl/callback',
        },
        'provider_client_ids': {'simkl': null},
      },
    ]) {
      final client = SimklBrokerCapabilityClient(
        baseUrl: 'https://auth.example.test',
        dio: _jsonDio((_) => payload),
      );
      expect(await client.probe(), isNull);
    }
  });

  test('creates and polls the standalone SIMKL broker flow', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (options.path.endsWith('/v1/simkl/pairings')) {
              return handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 201,
                  data: {
                    'pairing_id': 'AbCdEfGhIjKlMnOpQrStUvWx',
                    'device_code':
                        'abcdefghijklmnopqrstuvwxyzABCDEFGH123456789',
                    'user_code': 'ABCD-EFGH',
                    'verification_uri': 'https://auth.example.test/pair',
                    'verification_uri_complete':
                        'https://auth.example.test/pair?code=ABCD-EFGH',
                    'expires_at': '2026-09-02T12:10:00.000Z',
                    'interval': 5,
                  },
                ),
              );
            }
            return handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: const {
                  'status': 'authorized',
                  'access_token': 'opaque.simkl-token_value',
                  'expires_at': '2031-09-01T12:00:00.000Z',
                },
              ),
            );
          },
        ),
      );
    final client = SimklBrokerCapabilityClient(
      baseUrl: 'https://auth.example.test',
      dio: dio,
    );
    final capability = SimklBrokerCapability(
      clientId: 'public-simkl-client-id',
      callbackUri: Uri(
        scheme: 'https',
        host: 'auth.example.test',
        path: '/oauth/simkl/callback',
      ),
    );

    final session = await client.createPairing(capability);
    final result = await client.pollPairing(session);

    expect(session.userCode, 'ABCD-EFGH');
    expect(session.pollInterval, const Duration(seconds: 5));
    expect(result.status, PairingStatus.authorized);
    expect(result.accessToken, 'opaque.simkl-token_value');
    expect(requests, hasLength(2));
    expect(requests.first.method, 'POST');
    expect(
      requests.last.headers['Authorization'],
      'Pairing abcdefghijklmnopqrstuvwxyzABCDEFGH123456789',
    );
  });

  test('rejects a non-root or non-HTTPS broker before requesting it', () {
    expect(
      () => SimklBrokerCapabilityClient(baseUrl: 'http://auth.example.test'),
      throwsArgumentError,
    );
    expect(
      () => SimklBrokerCapabilityClient(
        baseUrl: 'https://auth.example.test/nested',
      ),
      throwsArgumentError,
    );
  });
}

Dio _jsonDio(Map<String, dynamic> Function(RequestOptions) responseFor) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 200,
            data: responseFor(options),
          ),
        ),
      ),
    );
}
