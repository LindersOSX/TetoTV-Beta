import 'package:anime_tv/features/auth/data/torbox_device_auth_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TorBoxDeviceSession', () {
    test('parses a valid device authorization response', () {
      final session = TorBoxDeviceSession.fromJson({
        'device_code': 'device-secret',
        'code': '123456',
        'verification_url': 'https://torbox.app/link',
        'friendly_verification_url': 'https://torbox.app/link/123456',
        'expires_at': '2099-08-01T12:00:00Z',
        'interval': 5,
      });

      expect(session.deviceCode, 'device-secret');
      expect(session.userCode, '123456');
      expect(session.verificationUrl.scheme, 'https');
      expect(session.interval, const Duration(seconds: 5));
    });

    test('clamps unsafe polling intervals', () {
      final fast = TorBoxDeviceSession.fromJson({
        'device_code': 'fast',
        'code': '111111',
        'verification_url': 'https://torbox.app/link',
        'friendly_verification_url': 'https://torbox.app/link/111111',
        'expires_at': '2099-08-01T12:00:00Z',
        'interval': 0,
      });
      final slow = TorBoxDeviceSession.fromJson({
        'device_code': 'slow',
        'code': '222222',
        'verification_url': 'https://torbox.app/link',
        'friendly_verification_url': 'https://torbox.app/link/222222',
        'expires_at': '2099-08-01T12:00:00Z',
        'interval': 120,
      });

      expect(fast.interval, const Duration(seconds: 3));
      expect(slow.interval, const Duration(seconds: 30));
    });

    test('rejects insecure or incomplete authorization data', () {
      expect(
        () => TorBoxDeviceSession.fromJson({
          'device_code': 'device-secret',
          'code': '123456',
          'verification_url': 'http://torbox.app/link',
          'friendly_verification_url': 'https://torbox.app/link/123456',
          'expires_at': '2099-08-01T12:00:00Z',
          'interval': 5,
        }),
        throwsFormatException,
      );
      expect(
        () => TorBoxDeviceSession.fromJson({
          'device_code': 'device-secret',
          'code': '123456',
          'verification_url': 'https://torbox.app.attacker.test/link',
          'friendly_verification_url': 'https://tor.box/link',
          'expires_at': '2099-08-01T12:00:00Z',
          'interval': 5,
        }),
        throwsFormatException,
      );
    });
  });

  group('TorBoxDeviceAuthClient', () {
    TorBoxDeviceSession session() => TorBoxDeviceSession(
      deviceCode: 'device-secret',
      userCode: '123456',
      verificationUrl: Uri.parse('https://torbox.app/oauth/device'),
      friendlyVerificationUrl: Uri.parse('https://tor.box/link'),
      expiresAt: DateTime.utc(2099),
      interval: const Duration(seconds: 5),
    );

    test('returns null only for TorBox pending-device response', () async {
      final dio = _responseDio(
        statusCode: 400,
        body: const {
          'success': false,
          'error': 'DEVICE_CODE_NOT_USED',
          'detail': 'Waiting for approval.',
          'data': null,
        },
      );

      expect(await TorBoxDeviceAuthClient(dio: dio).poll(session()), isNull);
    });

    test('returns the API token from the current TorBox response', () async {
      final dio = _responseDio(
        statusCode: 200,
        body: const {
          'success': true,
          'error': null,
          'data': {'access_token': 'approved-token', 'token_type': 'Bearer'},
        },
      );

      expect(
        await TorBoxDeviceAuthClient(dio: dio).poll(session()),
        'approved-token',
      );
    });

    test('surfaces non-pending 400 responses instead of polling forever', () {
      final dio = _responseDio(
        statusCode: 400,
        body: const {
          'success': false,
          'error': 'DEVICE_AUTH_NOT_ALLOWED',
          'detail': 'This account cannot use device authorization.',
          'data': null,
        },
      );

      expect(
        () => TorBoxDeviceAuthClient(dio: dio).poll(session()),
        throwsA(
          isA<TorBoxDeviceAuthException>()
              .having((error) => error.code, 'code', 'DEVICE_AUTH_NOT_ALLOWED')
              .having(
                (error) => error.message,
                'message',
                contains('cannot use device authorization'),
              ),
        ),
      );
    });
  });
}

Dio _responseDio({
  required int statusCode,
  required Map<String, dynamic> body,
}) {
  return Dio(BaseOptions(baseUrl: 'https://torbox.test'))
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.path, '/user/auth/device/token');
          expect(options.data, {'device_code': 'device-secret'});
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: statusCode,
              data: body,
            ),
          );
        },
      ),
    );
}
