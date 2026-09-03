import 'dart:io';

import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:anime_tv/core/notifications/app_notification_controller.dart';
import 'package:anime_tv/core/notifications/app_notification_store.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('AppNotificationStore', () {
    late Database database;
    late AppNotificationStore store;

    setUp(() async {
      database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (database, _) => createAppNotificationsTable(database),
        ),
      );
      store = AppNotificationStore(TetoTvDatabase.forTesting(database));
    });

    tearDown(() => database.close());

    test('duplicate upserts preserve the original read state', () async {
      final createdAt = DateTime.utc(2026, 9, 2, 12);
      final readAt = createdAt.add(const Duration(minutes: 1));
      final notice = _notice(createdAt: createdAt);

      await store.upsert(notice);
      await store.markRead(notice.id, readAt);
      await store.upsert(
        AppNotification(
          id: notice.id,
          kind: notice.kind,
          title: 'Updated title',
          body: 'Updated body',
          action: notice.action,
          createdAtUtc: createdAt.add(const Duration(hours: 1)),
          targetVersion: notice.targetVersion,
          targetVersionCode: notice.targetVersionCode,
          targetChannel: notice.targetChannel,
        ),
      );

      final stored = (await store.load()).single;
      expect(stored.title, 'Updated title');
      expect(stored.body, 'Updated body');
      expect(stored.createdAtUtc, createdAt);
      expect(stored.readAtUtc, readAt);
    });

    test(
      'mark all read persists and unread ordering is newest first',
      () async {
        final first = _notice(createdAt: DateTime.utc(2026, 9, 1));
        final second = _notice(
          id: 'app-update:beta:410043',
          version: '2.0.66',
          versionCode: 410043,
          createdAt: DateTime.utc(2026, 9, 2),
        );
        await store.upsert(first);
        await store.upsert(second);

        expect((await store.load()).map((item) => item.id), [
          second.id,
          first.id,
        ]);
        await store.markAllRead(DateTime.utc(2026, 9, 3));
        expect((await store.load()).where((item) => !item.isRead), isEmpty);
      },
    );

    test('reading survives a device clock correction', () async {
      final createdAt = DateTime.utc(2026, 9, 2);
      final notice = _notice(createdAt: createdAt);
      await store.upsert(notice);

      await store.markRead(
        notice.id,
        createdAt.subtract(const Duration(days: 1)),
      );

      expect((await store.load()).single.readAtUtc, createdAt);
    });
  });

  test(
    'v10 to v11 migration preserves data and creates notification inbox',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tetotv-notifications-v11-',
      );
      final databasePath =
          '${temporary.path}${Platform.pathSeparator}tetotv.db';
      addTearDown(() async {
        await databaseFactoryFfi.deleteDatabase(databasePath);
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
      });

      var database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 10,
          onCreate: (database, _) async {
            await database.execute('''
            CREATE TABLE legacy_fixture (
              id INTEGER PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
            await database.insert('legacy_fixture', {
              'id': 1,
              'value': 'preserved',
            });
          },
        ),
      );
      await database.close();

      database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: tetoTvDatabaseSchemaVersion,
          onConfigure: configureTetoTvDatabase,
          onUpgrade: upgradeTetoTvDatabaseSchema,
        ),
      );
      addTearDown(database.close);

      expect(
        (await database.query('legacy_fixture')).single['value'],
        'preserved',
      );
      expect(await database.getVersion(), 11);
      final table = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        ['app_notifications'],
      );
      expect(table, hasLength(1));
      final indexes = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
        ['app_notifications_unread_created'],
      );
      expect(indexes, hasLength(1));
    },
  );

  group('AppNotificationController', () {
    late Database database;
    late AppNotificationStore store;
    late AppNotificationController controller;
    final clock = DateTime.utc(2026, 9, 2, 12);

    setUp(() async {
      database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (database, _) => createAppNotificationsTable(database),
        ),
      );
      store = AppNotificationStore(TetoTvDatabase.forTesting(database));
      controller = AppNotificationController(store, clock: () => clock);
      await controller.load();
    });

    tearDown(() async {
      controller.dispose();
      await database.close();
    });

    test('available update is durable, deduplicated, and actionable', () async {
      final update = _updateState();

      await controller.syncAppUpdate(update);
      expect(controller.state.unreadCount, 1);
      expect(
        controller.state.items.single.action,
        AppNotificationAction.openAppUpdates,
      );

      await controller.markRead(controller.state.items.single.id);
      expect(controller.state.unreadCount, 0);
      await controller.syncAppUpdate(update.copyWith(progress: .8));

      expect(controller.state.items, hasLength(1));
      expect(controller.state.items.single.isRead, isTrue);

      final restored = AppNotificationController(store, clock: () => clock);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.state.items, hasLength(1));
      expect(restored.state.unreadCount, 0);
    });

    test('newer build replaces the stale same-channel item', () async {
      await controller.syncAppUpdate(_updateState());
      await controller.markAllRead();
      await controller.syncAppUpdate(
        _updateState(version: '2.0.66', versionCode: 410043),
      );

      expect(controller.state.items, hasLength(1));
      expect(controller.state.unreadCount, 1);
      expect(controller.state.items.single.targetVersionCode, 410043);
    });

    test('release notes are stored as bounded plain text', () async {
      final markdown =
          '# Changes\n[Details](https://example.invalid/private) **Faster** updates '
          '${'with more fixes ' * 80}`code`';

      await controller.syncAppUpdate(_updateState(notes: markdown));

      final body = controller.state.items.single.body;
      expect(body, startsWith('Changes Details Faster updates'));
      expect(body, isNot(contains('https://')));
      expect(body, isNot(contains('**')));
      expect(body.length, lessThanOrEqualTo(480));
    });

    test('switching update channels removes the unactionable notice', () async {
      await store.upsert(
        AppNotification(
          id: 'app-update:public:420001',
          kind: AppNotificationKind.appUpdate,
          title: 'TetoTV 1.0.1 is available',
          body: 'Public update',
          action: AppNotificationAction.openAppUpdates,
          createdAtUtc: clock,
          targetVersion: '1.0.1',
          targetVersionCode: 420001,
          targetChannel: 'public',
        ),
      );
      await controller.load();
      expect(controller.state.items, hasLength(1));

      await controller.syncAppUpdate(
        const AppUpdateState(
          loaded: true,
          currentVersion: '2.0.64+410041',
          updateChannel: AppUpdateChannel.beta,
        ),
      );

      expect(controller.state.items, isEmpty);
    });

    test(
      'installed and up-to-date releases clear stale update items',
      () async {
        await controller.syncAppUpdate(_updateState());
        expect(controller.state.items, hasLength(1));

        await controller.syncAppUpdate(
          _updateState(
            currentVersion: '2.0.65+410042',
            phase: AppUpdatePhase.idle,
          ),
        );
        expect(controller.state.items, isEmpty);

        await controller.syncAppUpdate(
          _updateState(version: '2.0.66', versionCode: 410043),
        );
        await controller.syncAppUpdate(
          _updateState(
            version: '2.0.66',
            versionCode: 410043,
            currentVersion: '2.0.66+410043',
            phase: AppUpdatePhase.upToDate,
          ),
        );
        expect(controller.state.items, isEmpty);
      },
    );
  });
}

AppNotification _notice({
  String id = 'app-update:beta:410042',
  String version = '2.0.65',
  int versionCode = 410042,
  required DateTime createdAt,
}) => AppNotification(
  id: id,
  kind: AppNotificationKind.appUpdate,
  title: 'TetoTV $version Beta is available',
  body: 'A new Beta update is ready to install from TetoTV settings.',
  action: AppNotificationAction.openAppUpdates,
  createdAtUtc: createdAt,
  targetVersion: version,
  targetVersionCode: versionCode,
  targetChannel: 'beta',
);

AppUpdateState _updateState({
  String version = '2.0.65',
  int versionCode = 410042,
  String currentVersion = '2.0.64+410041',
  AppUpdatePhase phase = AppUpdatePhase.ready,
  String notes = '',
}) => AppUpdateState(
  loaded: true,
  phase: phase,
  currentVersion: currentVersion,
  latestVersion: version,
  updateChannel: AppUpdateChannel.beta,
  release: AppReleaseInfo(
    tagName: 'v$version',
    version: version,
    name: 'TetoTV $version',
    notes: notes,
    androidVersionCode: versionCode,
    asset: const AppReleaseAsset(
      name: 'TetoTV-universal.apk',
      apiUrl: 'https://api.github.com/example',
      publicUrl: 'https://github.com/example',
      size: 1,
    ),
  ),
);
