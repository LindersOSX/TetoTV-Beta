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
