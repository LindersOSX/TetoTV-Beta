import 'package:anime_tv/features/auth/data/torbox_device_auth_client.dart';
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
}
