import 'dart:async';

import 'package:anime_tv/features/settings/application/home_shelf_preferences_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Home shelf visibility and order persist independently', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const storage = FlutterSecureStorage();
    final visibility = HomeShelfPreferencesController(storage);
    final order = HomeShelfOrderController(storage);

    await visibility.toggle(HomeShelf.history);
    await order.move(HomeShelf.tracking, 2);

    final restoredVisibility = HomeShelfPreferencesController(storage);
    final restoredOrder = HomeShelfOrderController(storage);
    await restoredVisibility.load();
    await restoredOrder.load();

    expect(restoredVisibility.state, isNot(contains(HomeShelf.history)));
    expect(restoredOrder.state.take(3), [
      HomeShelf.history,
      HomeShelf.recentlyReleased,
      HomeShelf.tracking,
    ]);
  });

  test(
    'legacy shelf choices keep the previously fixed release shelf',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'home_shelves_v1': 'tracking,trending',
      });
      final controller = HomeShelfPreferencesController(
        const FlutterSecureStorage(),
      );

      await controller.load();

      expect(controller.state, contains(HomeShelf.tracking));
      expect(controller.state, contains(HomeShelf.trending));
      expect(controller.state, contains(HomeShelf.recentlyReleased));
      expect(controller.state, isNot(contains(HomeShelf.history)));
    },
  );

  test('new shelves are appended when restoring an older order', () async {
    FlutterSecureStorage.setMockInitialValues({
      'home_shelf_order_v1': 'trending,tracking',
    });
    final controller = HomeShelfOrderController(const FlutterSecureStorage());

    await controller.load();

    expect(controller.state.take(2), [HomeShelf.trending, HomeShelf.tracking]);
    expect(controller.state.toSet(), HomeShelf.values.toSet());
  });

  test('a shelf toggle made during load is never overwritten', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final readCompleter = Completer<String?>();
    var reads = 0;
    final controller = HomeShelfPreferencesController(
      const FlutterSecureStorage(),
      readValue: (_) {
        reads++;
        return readCompleter.future;
      },
    );

    final firstLoad = controller.load();
    final duplicateLoad = controller.load();
    await controller.toggle(HomeShelf.history);
    readCompleter.complete(
      HomeShelf.values.map((shelf) => shelf.name).join(','),
    );
    await Future.wait([firstLoad, duplicateLoad]);

    expect(reads, 1, reason: 'simultaneous loads should be coalesced');
    expect(controller.state, isNot(contains(HomeShelf.history)));
  });

  test('a shelf move made during load is never overwritten', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final readCompleter = Completer<String?>();
    final controller = HomeShelfOrderController(
      const FlutterSecureStorage(),
      readValue: (_) => readCompleter.future,
    );

    final load = controller.load();
    await controller.move(HomeShelf.tracking, 1);
    readCompleter.complete('trending,tracking');
    await load;

    expect(controller.state.take(2), [HomeShelf.history, HomeShelf.tracking]);
  });
}
