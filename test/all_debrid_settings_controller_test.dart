import 'package:anime_tv/features/settings/application/all_debrid_settings_controller.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('validates premium status before securely replacing a key', () async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.allDebrid.tokenStorageKey: 'existing-key',
    });
    final controller = AllDebridSettingsController(
      storage,
      (token) => token == 'existing-key'
          ? _PremiumAllDebridClient()
          : _FreeAllDebridClient(),
    );

    await controller.load();
    expect(controller.state.hasSavedToken, isTrue);
    expect(await controller.saveAndValidate('free-key'), isFalse);
    expect(controller.state.hasSavedToken, isTrue);
    expect(
      await storage.read(key: DebridService.allDebrid.tokenStorageKey),
      'existing-key',
    );
  });
}

class _PremiumAllDebridClient extends AllDebridClient {
  _PremiumAllDebridClient() : super(token: 'test');

  @override
  Future<AllDebridAccount> account() async => AllDebridAccount(
    username: 'premium-user',
    email: 'premium@example.test',
    isPremium: true,
    premiumUntil: DateTime.utc(2099),
  );
}

class _FreeAllDebridClient extends AllDebridClient {
  _FreeAllDebridClient() : super(token: 'test');

  @override
  Future<AllDebridAccount> account() async => const AllDebridAccount(
    username: 'free-user',
    email: 'free@example.test',
    isPremium: false,
  );
}
