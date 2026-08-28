import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('normalizes a secure broker origin', () {
    expect(
      normalizeAuthBrokerBaseUrl('  https://auth.example.com/  '),
      'https://auth.example.com',
    );
    expect(
      normalizeAuthBrokerBaseUrl('https://auth.example.com/tetotv/'),
      'https://auth.example.com/tetotv',
    );
  });

  test('rejects unsafe or ambiguous broker URLs', () {
    expect(normalizeAuthBrokerBaseUrl('http://auth.example.com'), isNull);
    expect(normalizeAuthBrokerBaseUrl('https://user@auth.example.com'), isNull);
    expect(normalizeAuthBrokerBaseUrl('https://auth.example.com/?x=1'), isNull);
    expect(normalizeAuthBrokerBaseUrl('not a URL'), isNull);
  });

  test(
    'migrates the retired production override to the Wispbyte broker',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        authBrokerUrlStorageKey: Uri(
          scheme: 'https',
          host: [
            'tetotv-auth',
            String.fromCharCodes([111, 110, 114, 101, 110, 100, 101, 114]),
            'com',
          ].join('.'),
        ).toString(),
      });

      final effective = await effectiveAuthBrokerBaseUrl(storage);

      expect(effective, 'https://tetotv-bot.wisp.uno');
      expect(
        await storage.read(key: authBrokerUrlStorageKey),
        'https://tetotv-bot.wisp.uno',
      );
    },
  );

  test('preserves an explicit non-retired HTTPS broker override', () async {
    FlutterSecureStorage.setMockInitialValues({
      authBrokerUrlStorageKey: 'https://auth.example.com/',
    });

    expect(
      await effectiveAuthBrokerBaseUrl(storage),
      'https://auth.example.com',
    );
  });
}
