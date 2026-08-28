import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a truly fresh install requires setup', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = SetupProgressController(const FlutterSecureStorage());
    await controller.load();
    expect(controller.state.loaded, isTrue);
    expect(controller.state.completed, isFalse);
  });

  test('an upgrade with existing preferences skips forced setup', () async {
    FlutterSecureStorage.setMockInitialValues({
      'settings_selected_debrid_provider': 'real-debrid',
    });
    const storage = FlutterSecureStorage();
    final controller = SetupProgressController(storage);
    await controller.load();
    expect(controller.state.completed, isTrue);
    expect(await storage.read(key: initialSetupCompletedStorageKey), 'true');
  });

  test('skip or finish persists completion', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = SetupProgressController(storage);
    await controller.complete();
    expect(controller.state.completed, isTrue);

    final restored = SetupProgressController(storage);
    await restored.load();
    expect(restored.state.completed, isTrue);
  });

  test(
    'an interrupted fresh setup resumes instead of looking migrated',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      const storage = FlutterSecureStorage();
      final started = SetupProgressController(storage);
      await started.start();
      await storage.write(key: 'input_use_built_in_keyboard', value: 'false');

      final restored = SetupProgressController(storage);
      await restored.load();

      expect(restored.state.loaded, isTrue);
      expect(restored.state.completed, isFalse);
    },
  );

  test('completion clears the interrupted-setup marker', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final controller = SetupProgressController(storage);
    await controller.start();
    await controller.complete();

    expect(await storage.read(key: initialSetupStartedStorageKey), isNull);
    expect(await storage.read(key: initialSetupCompletedStorageKey), 'true');
  });
}
