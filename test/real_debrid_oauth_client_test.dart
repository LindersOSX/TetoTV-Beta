import 'package:anime_tv/features/auth/data/real_debrid_oauth_client.dart';
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
}
