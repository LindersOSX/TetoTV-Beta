import 'package:anime_tv/features/settings/application/torbox_settings_controller.dart';
import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'a rejected replacement does not hide the saved TorBox account',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        DebridService.torBox.tokenStorageKey: 'existing-token',
      });
      final controller = TorBoxSettingsController(
        storage,
        (token) => token == 'existing-token'
            ? _PaidTorBoxClient()
            : _FreeTorBoxClient(),
      );

      await controller.load();
      expect(controller.state.hasSavedToken, isTrue);

      expect(await controller.saveAndValidate('invalid-replacement'), isFalse);
      expect(controller.state.hasSavedToken, isTrue);
      expect(
        await storage.read(key: DebridService.torBox.tokenStorageKey),
        'existing-token',
      );
    },
  );

  test(
    'one-time Essential premium is accepted without recurring billing',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final controller = TorBoxSettingsController(
        storage,
        (_) => _OneTimeEssentialTorBoxClient(),
      );

      expect(await controller.saveAndValidate('one-time-token'), isTrue);
      expect(controller.state.account?.planName, 'Essential');
      expect(controller.state.account?.isSubscribed, isFalse);
      expect(controller.state.account?.hasApiStreaming, isTrue);
      expect(
        await storage.read(key: DebridService.torBox.tokenStorageKey),
        'one-time-token',
      );
    },
  );

  test('expired paid-plan time is still rejected', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = TorBoxSettingsController(
      storage,
      (_) => _ExpiredTorBoxClient(),
    );

    expect(await controller.saveAndValidate('expired-token'), isFalse);
    expect(controller.state.hasSavedToken, isFalse);
    expect(
      await storage.read(key: DebridService.torBox.tokenStorageKey),
      isNull,
    );
  });
}

class _PaidTorBoxClient extends TorBoxClient {
  _PaidTorBoxClient() : super(token: 'test');

  @override
  Future<TorBoxAccount> account() async => TorBoxAccount(
    id: 1,
    email: 'paid@example.test',
    plan: 2,
    isSubscribed: true,
    premiumUntil: DateTime.utc(2099),
  );
}

class _FreeTorBoxClient extends TorBoxClient {
  _FreeTorBoxClient() : super(token: 'test');

  @override
  Future<TorBoxAccount> account() async => const TorBoxAccount(
    id: 2,
    email: 'free@example.test',
    plan: 0,
    isSubscribed: false,
  );
}

class _OneTimeEssentialTorBoxClient extends TorBoxClient {
  _OneTimeEssentialTorBoxClient() : super(token: 'test');

  @override
  Future<TorBoxAccount> account() async => TorBoxAccount(
    id: 3,
    email: 'one-time@example.test',
    plan: 1,
    isSubscribed: false,
    premiumUntil: DateTime.utc(2099),
  );
}

class _ExpiredTorBoxClient extends TorBoxClient {
  _ExpiredTorBoxClient() : super(token: 'test');

  @override
  Future<TorBoxAccount> account() async => TorBoxAccount(
    id: 4,
    email: 'expired@example.test',
    plan: 1,
    isSubscribed: true,
    premiumUntil: DateTime.utc(2020),
  );
}
