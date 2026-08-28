import 'package:anime_tv/features/discord/data/discord_device_pairing_client.dart';
import 'package:anime_tv/features/discord/domain/discord_device_pairing.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'creates a bounded Discord-only device session without redirects',
    () async {
      RequestOptions? captured;
      final client = DiscordDeviceAuthClient(
        dio: _stubDio((options, handler) {
          captured = options;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: _sessionPayload(),
            ),
          );
        }),
      );

      final session = await client.createSession();

      expect(captured?.path, 'oauth2/device/authorize');
      expect(captured?.followRedirects, isFalse);
      expect(captured?.maxRedirects, 0);
      expect(captured?.data, {
        'client_id': DiscordDeviceAuthClient.applicationId,
        'scope': DiscordDeviceAuthClient.requestedScopes,
      });
      expect(session.userCode, 'ABCD-EFGH');
      expect(
        session.verificationUri,
        Uri.parse('https://discord.com/activate'),
      );
      expect(session.pairingId, 'discord-device');
      expect(session.toString(), isNot(contains(_deviceCode)));
      expect(session.toString(), isNot(contains('ABCD-EFGH')));
    },
  );

  test('rejects a non-Discord or redirected verification session', () async {
    for (final invalid in [
      'https://evil.example/activate?user_code=ABCD-EFGH',
      'https://discord.com/activate?user_code=ABCD-EFGH&next=evil',
      'http://discord.com/activate?user_code=ABCD-EFGH',
    ]) {
      final client = DiscordDeviceAuthClient(
        dio: _resolvedDio({
          ..._sessionPayload(),
          'verification_uri_complete': invalid,
        }),
      );
      await expectLater(
        client.createSession(),
        throwsA(isA<DiscordDeviceAuthException>()),
        reason: invalid,
      );
    }
  });

  test(
    'poll sends the private code once and requires both exact scopes',
    () async {
      RequestOptions? captured;
      final client = DiscordDeviceAuthClient(
        dio: _stubDio((options, handler) {
          captured = options;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: _tokenPayload(),
            ),
          );
        }),
      );

      final result = await client.poll(_session());

      expect(result.status, DiscordDevicePairingPollStatus.authorized);
      expect(result.token?.tokenType, 1);
      expect(
        result.token?.scopes.split(' '),
        containsAll(['openid', 'sdk.social_layer_presence']),
      );
      expect(captured?.followRedirects, isFalse);
      expect(captured?.maxRedirects, 0);
      expect(captured?.data, {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': _deviceCode,
        'client_id': DiscordDeviceAuthClient.applicationId,
      });

      for (final scopes in [
        'openid',
        'sdk.social_layer_presence',
        'identify',
      ]) {
        final missingScopeClient = DiscordDeviceAuthClient(
          dio: _resolvedDio({..._tokenPayload(), 'scope': scopes}),
        );
        await expectLater(
          missingScopeClient.poll(_session()),
          throwsA(isA<DiscordDeviceAuthException>()),
          reason: scopes,
        );
      }
    },
  );

  test('maps standard device-flow waiting and terminal OAuth errors', () async {
    for (final entry in <String, DiscordDevicePairingPollStatus>{
      'authorization_pending': DiscordDevicePairingPollStatus.pending,
      'slow_down': DiscordDevicePairingPollStatus.slowDown,
      'expired_token': DiscordDevicePairingPollStatus.expired,
      'access_denied': DiscordDevicePairingPollStatus.expired,
    }.entries) {
      final client = DiscordDeviceAuthClient(dio: _oauthErrorDio(entry.key));
      final result = await client.poll(_session());
      expect(result.status, entry.value, reason: entry.key);
    }
  });

  test('errors and model diagnostics never reveal OAuth secrets', () async {
    const serverSecret = 'server-secret-access-token-value';
    final client = DiscordDeviceAuthClient(
      dio: _oauthErrorDio(
        'server_error',
        extra: {'access_token': serverSecret, 'device_code': _deviceCode},
      ),
    );

    Object? failure;
    try {
      await client.poll(_session());
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<DiscordDeviceAuthException>());
    expect(failure.toString(), isNot(contains(serverSecret)));
    expect(failure.toString(), isNot(contains(_deviceCode)));
    expect(_session().toString(), isNot(contains(_deviceCode)));
  });

  test(
    'rejects every non-200 response instead of accepting redirects',
    () async {
      for (final status in [201, 302, 307]) {
        final client = DiscordDeviceAuthClient(
          dio: _stubDio((options, handler) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: status,
                data: _sessionPayload(),
              ),
            );
          }),
        );
        await expectLater(
          client.createSession(),
          throwsA(isA<DiscordDeviceAuthException>()),
          reason: '$status',
        );
      }
    },
  );
}

Dio _stubDio(
  void Function(RequestOptions, RequestInterceptorHandler) callback,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://discord.com/api/v10/'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => callback(options, handler),
    ),
  );
  return dio;
}

Dio _resolvedDio(Map<String, dynamic> payload) => _stubDio((options, handler) {
  handler.resolve(
    Response<Map<String, dynamic>>(
      requestOptions: options,
      statusCode: 200,
      data: payload,
    ),
  );
});

Dio _oauthErrorDio(String code, {Map<String, dynamic> extra = const {}}) =>
    _stubDio((options, handler) {
      handler.reject(
        DioException.badResponse(
          statusCode: 400,
          requestOptions: options,
          response: Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: 400,
            data: {'error': code, ...extra},
          ),
        ),
      );
    });

Map<String, dynamic> _sessionPayload() => {
  'device_code': _deviceCode,
  'user_code': 'ABCD-EFGH',
  'verification_uri': 'https://discord.com/activate',
  'verification_uri_complete':
      'https://discord.com/activate?user_code=ABCD-EFGH',
  'expires_in': 600,
  'interval': 5,
};

Map<String, dynamic> _tokenPayload() => {
  'access_token': _accessToken,
  'refresh_token': _refreshToken,
  'token_type': 'Bearer',
  'expires_in': 604800,
  'scope': 'openid sdk.social_layer_presence',
};

DiscordDevicePairingSession _session() => DiscordDevicePairingSession(
  pairingId: 'discord-device',
  deviceCode: _deviceCode,
  userCode: 'ABCD-EFGH',
  verificationUri: Uri.parse('https://discord.com/activate'),
  verificationUriComplete: Uri.parse(
    'https://discord.com/activate?user_code=ABCD-EFGH',
  ),
  expiresAt: DateTime.now().add(const Duration(minutes: 10)),
  pollInterval: const Duration(seconds: 5),
);

final _deviceCode = List<String>.filled(48, 'd').join();
final _accessToken = List<String>.filled(48, 'a').join();
final _refreshToken = List<String>.filled(48, 'r').join();
