import 'dart:io';

import 'package:anime_tv/core/notifications/app_notification.dart';
import 'package:anime_tv/core/notifications/app_notification_controller.dart';
import 'package:anime_tv/core/notifications/app_notification_store.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bell caps the visible badge but announces the exact count', (
    tester,
  ) async {
    final notifications = AppNotificationController(
      _MemoryNotificationStore([
        for (var index = 0; index < 100; index++)
          AppNotification(
            id: 'app-update:beta:${410042 + index}',
            kind: AppNotificationKind.appUpdate,
            title: 'TetoTV update ${index + 1}',
            body: 'Update available.',
            action: AppNotificationAction.openAppUpdates,
            createdAtUtc: DateTime.utc(
              2026,
              9,
              2,
            ).add(Duration(minutes: index)),
            targetVersion: '2.0.${65 + index}',
            targetVersionCode: 410042 + index,
            targetChannel: 'beta',
          ),
      ]),
    );
    await notifications.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appNotificationControllerProvider.overrideWith((_) => notifications),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: TetoNotificationBell()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('99+'), findsOneWidget);
    final semantics = tester.widget<Semantics>(
      find.byKey(const ValueKey('notification-bell-semantics')),
    );
    expect(
      semantics.properties.label,
      'Notifications, 100 unread notifications',
    );

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('update panel stays live, closes safely, and installs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _MemoryNotificationStore([_notice()]);
    final notifications = AppNotificationController(store);
    await notifications.load();
    final updates = _TestAppUpdateController(_readyUpdateState());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appNotificationControllerProvider.overrideWith((_) => notifications),
          appUpdateControllerProvider.overrideWith((_) => updates),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: TetoNotificationBell(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(TetoNotificationBell)),
      const Size.square(52),
    );
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byType(TetoNotificationBell));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notification-menu-surface')),
      findsOneWidget,
    );
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
    expect(notifications.state.unreadCount, 0);

    updates.setTestState(
      _readyUpdateState().copyWith(
        phase: AppUpdatePhase.downloading,
        progress: .42,
        message: 'Downloading update…',
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('notification-update-progress')),
      findsOneWidget,
    );
    expect(find.text('Downloading update…'), findsOneWidget);

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('notification-menu-surface')),
      findsOneWidget,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notification-menu-surface')),
      findsNothing,
    );

    updates.setTestState(_readyUpdateState());
    await tester.tap(find.byType(TetoNotificationBell));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(updates.installCalls, 1);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty inbox can manually check for updates', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notifications = AppNotificationController(
      _MemoryNotificationStore(const []),
    );
    await notifications.load();
    final updates = _TestAppUpdateController(
      const AppUpdateState(loaded: true, phase: AppUpdatePhase.idle),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appNotificationControllerProvider.overrideWith((_) => notifications),
          appUpdateControllerProvider.overrideWith((_) => updates),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: TetoNotificationBell(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('notification-unread-badge')),
      findsNothing,
    );
    await tester.tap(find.byType(TetoNotificationBell));
    await tester.pumpAndSettle();
    expect(find.text('You\'re all caught up'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notification-empty-check')));
    await tester.pumpAndSettle();
    expect(updates.checkCalls, 1);
    expect(updates.lastAutomatic, isFalse);
    expect(updates.lastLaunchInstaller, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('announcement renders as a notice without an update action', (
    tester,
  ) async {
    final notifications = AppNotificationController(
      _MemoryNotificationStore([
        AppNotification(
          id: 'app-announcement:${List.filled(64, 'a').join()}',
          kind: AppNotificationKind.announcement,
          title: 'TetoTV announcement',
          body: 'Maintenance is complete.',
          action: AppNotificationAction.none,
          createdAtUtc: DateTime.utc(2026, 9, 2),
        ),
      ]),
    );
    await notifications.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appNotificationControllerProvider.overrideWith((_) => notifications),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: TetoNotificationBell()),
        ),
      ),
    );
    await tester.tap(find.byType(TetoNotificationBell));
    await tester.pumpAndSettle();

    expect(find.text('TetoTV announcement'), findsOneWidget);
    expect(find.text('Maintenance is complete.'), findsOneWidget);
    expect(find.text('NOTICE'), findsOneWidget);
    expect(find.text('Check'), findsNothing);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('announcement cards stay D-pad focusable in a mixed inbox', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = _announcement('a', 'First announcement.');
    final second = _announcement('b', 'Second announcement.');
    final notifications = AppNotificationController(
      _MemoryNotificationStore([first, second, _notice()]),
    );
    await notifications.load();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appNotificationControllerProvider.overrideWith((_) => notifications),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: TetoNotificationBell(),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TetoNotificationBell));
    await tester.pumpAndSettle();

    FocusableActionDetector detectorFor(String id) =>
        tester.widget<FocusableActionDetector>(
          find.ancestor(
            of: find.byKey(ValueKey('notification-item-$id')),
            matching: find.byType(FocusableActionDetector),
          ),
        );

    expect(detectorFor(first.id).focusNode?.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(detectorFor(second.id).focusNode?.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}

AppNotification _announcement(String hashCharacter, String body) =>
    AppNotification(
      id: 'app-announcement:${List.filled(64, hashCharacter).join()}',
      kind: AppNotificationKind.announcement,
      title: 'TetoTV announcement',
      body: body,
      action: AppNotificationAction.none,
      createdAtUtc: DateTime.utc(2026, 9, 2),
    );

AppNotification _notice() => AppNotification(
  id: 'app-update:beta:410042',
  kind: AppNotificationKind.appUpdate,
  title: 'TetoTV 2.0.65 Beta is available',
  body: 'A new Beta update is ready to install from TetoTV settings.',
  action: AppNotificationAction.openAppUpdates,
  createdAtUtc: DateTime.utc(2026, 9, 2),
  targetVersion: '2.0.65',
  targetVersionCode: 410042,
  targetChannel: 'beta',
);

AppUpdateState _readyUpdateState() => AppUpdateState(
  loaded: true,
  phase: AppUpdatePhase.ready,
  currentVersion: '2.0.64+410041',
  latestVersion: '2.0.65',
  updateChannel: AppUpdateChannel.beta,
  message: 'TetoTV 2.0.65 Beta is ready to install.',
  release: AppReleaseInfo(
    tagName: 'v2.0.65',
    version: '2.0.65',
    name: 'TetoTV 2.0.65',
    androidVersionCode: 410042,
    asset: const AppReleaseAsset(
      name: 'TetoTV-v2.0.65-universal.apk',
      apiUrl: 'https://api.github.com/example',
      publicUrl: 'https://github.com/example',
      size: 1,
    ),
  ),
);

class _TestAppUpdateController extends AppUpdateController {
  _TestAppUpdateController(AppUpdateState initial)
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => initial.currentVersion,
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = initial;
  }

  int checkCalls = 0;
  int installCalls = 0;
  bool? lastAutomatic;
  bool? lastLaunchInstaller;

  void setTestState(AppUpdateState value) => state = value;

  @override
  Future<void> checkForUpdates({
    bool automatic = false,
    bool launchInstaller = false,
  }) async {
    checkCalls++;
    lastAutomatic = automatic;
    lastLaunchInstaller = launchInstaller;
  }

  @override
  Future<void> installDownloadedUpdate() async {
    installCalls++;
  }
}

class _UnusedReleaseSource extends AppReleaseSource {
  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) =>
      throw UnimplementedError();

  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) => throw UnimplementedError();
}

class _MemoryNotificationStore extends AppNotificationStore {
  _MemoryNotificationStore(List<AppNotification> seed)
    : _items = List.of(seed),
      super(TetoTvDatabase.instance);

  List<AppNotification> _items;

  @override
  Future<List<AppNotification>> load() async => List.unmodifiable(_items);

  @override
  Future<void> markAllRead(DateTime readAtUtc) async {
    _items = [for (final item in _items) item.copyWith(readAtUtc: readAtUtc)];
  }
}
