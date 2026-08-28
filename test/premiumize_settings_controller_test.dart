import 'package:anime_tv/features/settings/application/premiumize_settings_controller.dart';
import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('validates premium status before securely replacing a key', () async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.premiumize.tokenStorageKey: 'existing-key',
    });
    final controller = PremiumizeSettingsController(
      storage,
      (token) => token == 'existing-key' ? _PremiumClient() : _FreeClient(),
    );

    await controller.load();
    expect(controller.state.hasSavedToken, isTrue);
    expect(await controller.saveAndValidate('free-key'), isFalse);
    expect(controller.state.hasSavedToken, isTrue);
    expect(
      await storage.read(key: DebridService.premiumize.tokenStorageKey),
      'existing-key',
    );
  });

  test('disconnect deletes the Premiumize key', () async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.premiumize.tokenStorageKey: 'existing-key',
    });
    final controller = PremiumizeSettingsController(
      storage,
      (_) => _PremiumClient(),
    );

    await controller.load();
    await controller.disconnect();

    expect(
      await storage.read(key: DebridService.premiumize.tokenStorageKey),
      isNull,
    );
    expect(controller.state.hasSavedToken, isFalse);
  });
}

class _PremiumClient extends PremiumizeClient {
  _PremiumClient() : super(token: 'test');

  @override
  Future<PremiumizeAccount> account() async => PremiumizeAccount(
    customerId: 'premium-user',
    limitUsed: .2,
    boosterPoints: 0,
    premiumUntil: DateTime.utc(2099),
  );
}

class _FreeClient extends PremiumizeClient {
  _FreeClient() : super(token: 'test');

  @override
  Future<PremiumizeAccount> account() async => const PremiumizeAccount(
    customerId: 'free-user',
    limitUsed: 0,
    boosterPoints: 0,
  );
}
