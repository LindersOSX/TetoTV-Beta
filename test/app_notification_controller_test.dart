import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:anime_tv/core/notifications/app_announcement_client.dart';
import 'package:anime_tv/core/notifications/app_notification_controller.dart';
import 'package:anime_tv/core/notifications/app_notification_store.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets(
    'foreground refresh scheduler pauses, resumes immediately, and avoids overlap',
    (tester) async {
      var announcementCalls = 0;
      var updateCalls = 0;
      var holdAnnouncement = Completer<void>();
      final scheduler = AppNotificationRefreshScheduler(
        announcementInterval: const Duration(seconds: 1),
        updateInterval: const Duration(seconds: 2),
        refreshAnnouncements: () {
          announcementCalls++;
          return holdAnnouncement.future;
        },
        refreshAppUpdate: () async {
          updateCalls++;
        },
      );
      addTearDown(() {
        scheduler.dispose();
        if (!holdAnnouncement.isCompleted) holdAnnouncement.complete();
      });

      scheduler.start();
      await tester.pump(const Duration(seconds: 1));
      expect(announcementCalls, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(announcementCalls, 1, reason: 'slow fetches must not stack');
      expect(updateCalls, 2);

      holdAnnouncement.complete();
      await tester.pump();
      holdAnnouncement = Completer<void>()..complete();
      await tester.pump(const Duration(seconds: 1));
      expect(announcementCalls, 2);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final pausedAnnouncements = announcementCalls;
      final pausedUpdates = updateCalls;
      await tester.pump(const Duration(seconds: 5));
      expect(announcementCalls, pausedAnnouncements);
      expect(updateCalls, pausedUpdates);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(announcementCalls, pausedAnnouncements + 1);
      expect(updateCalls, pausedUpdates + 1);
      scheduler.dispose();
    },
  );

  testWidgets(
    'update polling interval starts after the prior check completes',
    (tester) async {
      var updateCalls = 0;
      final firstUpdate = Completer<void>();
      final scheduler = AppNotificationRefreshScheduler(
        announcementInterval: const Duration(hours: 1),
        updateInterval: const Duration(seconds: 2),
        refreshAnnouncements: () async {},
        refreshAppUpdate: () {
          updateCalls++;
          return updateCalls == 1 ? firstUpdate.future : Future<void>.value();
        },
      );
      addTearDown(() {
        scheduler.dispose();
        if (!firstUpdate.isCompleted) firstUpdate.complete();
      });

      scheduler.start();
      await tester.pump(const Duration(seconds: 2));
      expect(updateCalls, 1);

      await tester.pump(const Duration(seconds: 10));
      expect(updateCalls, 1, reason: 'an in-flight check must not be stacked');

      firstUpdate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1999));
      expect(updateCalls, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(updateCalls, 2);
      await tester.pump();
      scheduler.dispose();
    },
  );

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
    'v10 migration preserves data and creates the current notification inbox',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tetotv-notifications-migration-',
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
      expect(await database.getVersion(), tetoTvDatabaseSchemaVersion);
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

  test('v11 notification rows survive the current inbox schema', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'tetotv-notifications-v12-',
    );
    final databasePath = '${temporary.path}${Platform.pathSeparator}tetotv.db';
    addTearDown(() async {
      await databaseFactoryFfi.deleteDatabase(databasePath);
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    });

    var database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 11,
        onCreate: (database, _) async {
          await database.execute('''
            CREATE TABLE app_notifications (
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              action TEXT NOT NULL,
              target_version TEXT,
              target_version_code INTEGER,
              target_channel TEXT,
              created_at INTEGER NOT NULL,
              read_at INTEGER,
              CHECK(kind IN ('app_update')),
              CHECK(length(body) BETWEEN 1 AND 512),
              CHECK(action IN ('open_app_updates'))
            )
          ''');
          await database.execute('''
            CREATE INDEX app_notifications_unread_created
            ON app_notifications(read_at, created_at DESC)
          ''');
          await database.insert('app_notifications', {
            'id': 'app-update:beta:410042',
            'kind': 'app_update',
            'title': 'Update available',
            'body': 'Update body',
            'action': 'open_app_updates',
            'target_version': '2.0.65',
            'target_version_code': 410042,
            'target_channel': 'beta',
            'created_at': 1,
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
    final store = AppNotificationStore(TetoTvDatabase.forTesting(database));
    await store.upsert(
      AppNotification(
        id: 'app-announcement:${List.filled(64, 'b').join()}',
        kind: AppNotificationKind.announcement,
        title: 'TetoTV announcement',
        body: 'A durable notice',
        action: AppNotificationAction.none,
        createdAtUtc: DateTime.utc(2026, 9, 2),
      ),
    );

    final rows = await store.load();
    expect(
      rows.map((item) => item.kind),
      containsAll(AppNotificationKind.values),
    );
    expect(await database.getVersion(), tetoTvDatabaseSchemaVersion);
  });

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

    test(
      'remote announcements persist, deduplicate, and retain read state',
      () async {
        final announcement = AppNotification(
          id: 'app-announcement:${List.filled(64, 'a').join()}',
          kind: AppNotificationKind.announcement,
          title: 'TetoTV announcement',
          body: 'Maintenance is complete.',
          action: AppNotificationAction.none,
          createdAtUtc: clock,
        );
        final remoteController = AppNotificationController(
          store,
          announcementApi: _StaticAnnouncementApi([announcement]),
          clock: () => clock,
        );
        addTearDown(remoteController.dispose);

        await remoteController.refreshAnnouncements();
        expect(remoteController.state.items, hasLength(1));
        expect(remoteController.state.items.single.id, announcement.id);
        expect(remoteController.state.items.single.body, announcement.body);
        expect(
          remoteController.state.items.single.kind,
          AppNotificationKind.announcement,
        );
        await remoteController.markAllRead();
        await remoteController.refreshAnnouncements();

        expect(remoteController.state.items, hasLength(1));
        expect(remoteController.state.items.single.isRead, isTrue);
        final restored = AppNotificationController(store, clock: () => clock);
        addTearDown(restored.dispose);
        await restored.load();
        expect(restored.state.items.single.body, 'Maintenance is complete.');
        expect(restored.state.items.single.isRead, isTrue);
      },
    );

    test(
      'dismissed announcements stay out of the inbox after refresh',
      () async {
        final announcement = AppNotification(
          id: 'app-announcement:${List.filled(64, 'f').join()}',
          kind: AppNotificationKind.announcement,
          title: 'TetoTV announcement',
          body: 'A message the viewer can dismiss.',
          action: AppNotificationAction.none,
          createdAtUtc: clock,
        );
        final remoteController = AppNotificationController(
          store,
          announcementApi: _StaticAnnouncementApi([announcement]),
          clock: () => clock,
        );
        addTearDown(remoteController.dispose);

        await remoteController.refreshAnnouncements();
        expect(remoteController.state.inboxItems, hasLength(1));

        await remoteController.dismiss(announcement.id);
        expect(remoteController.state.inboxItems, isEmpty);

        await remoteController.refreshAnnouncements();
        expect(remoteController.state.items.single.isRead, isTrue);
        expect(remoteController.state.inboxItems, isEmpty);
      },
    );

    test(
      'announcement mirror rolls back completely when one row fails',
      () async {
        final original = AppNotification(
          id: 'app-announcement:${List.filled(64, 'c').join()}',
          kind: AppNotificationKind.announcement,
          title: 'TetoTV announcement',
          body: 'Keep this notice.',
          action: AppNotificationAction.none,
          createdAtUtc: clock,
        );
        await store.upsert(original);

        final replacement = AppNotification(
          id: 'app-announcement:${List.filled(64, 'd').join()}',
          kind: AppNotificationKind.announcement,
          title: 'TetoTV announcement',
          body: 'A valid replacement.',
          action: AppNotificationAction.none,
          createdAtUtc: clock,
        );
        final invalid = AppNotification(
          id: 'app-announcement:${List.filled(64, 'e').join()}',
          kind: AppNotificationKind.announcement,
          title: '',
          body: 'This row violates the database constraint.',
          action: AppNotificationAction.none,
          createdAtUtc: clock,
        );

        await expectLater(
          store.syncAnnouncements([replacement, invalid]),
          throwsA(anything),
        );
        expect(await store.load(), hasLength(1));
        expect((await store.load()).single.id, original.id);
      },
    );

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

class _StaticAnnouncementApi implements AppAnnouncementApi {
  const _StaticAnnouncementApi(this.items);

  final List<AppNotification> items;

  @override
  Future<List<AppNotification>> fetch() async => items;
}

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
