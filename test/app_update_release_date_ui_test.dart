import 'dart:io';

import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('Public Updates shows its release date beside the version', (
    tester,
  ) async {
    final release = _release(
      '1.0.2',
      releasedAtUtc: DateTime.utc(2026, 8, 16, 19, 24),
    );
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        phase: AppUpdatePhase.upToDate,
        currentVersion: '1.0.2+410001',
        latestVersion: release.version,
        release: release,
        updateChannel: AppUpdateChannel.public,
      ),
    );

    expect(find.text('TetoTV 1.0.2+410001 • Aug 16, 2026'), findsOneWidget);
    expect(find.textContaining('Latest 1.0.2 • Aug 16, 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Beta Updates and release history show release dates', (
    tester,
  ) async {
    final latest = _release(
      '2.0.10',
      releasedAtUtc: DateTime.utc(2026, 8, 20, 2, 5),
    );
    final previous = _release(
      '2.0.9',
      releasedAtUtc: DateTime.utc(2026, 8, 12, 17, 30),
    );
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        phase: AppUpdatePhase.available,
        currentVersion: '2.0.9+410000',
        latestVersion: latest.version,
        release: latest,
        updateChannel: AppUpdateChannel.beta,
        developerMode: true,
        releaseHistory: [latest, previous],
      ),
    );

    expect(
      find.textContaining('Latest 2.0.10 Beta • Aug 20, 2026'),
      findsWidgets,
    );
    final latestHistoryEntry = find.text('2.0.10 Beta • Aug 20, 2026');
    expect(latestHistoryEntry, findsOneWidget);
    await tester.ensureVisible(latestHistoryEntry);
    await tester.pumpAndSettle();
    await tester.tap(latestHistoryEntry);
    await tester.pumpAndSettle();
    expect(find.text('2.0.9 Beta • Aug 12, 2026'), findsOneWidget);
    expect(
      find.text('Installed version: 2.0.9 • Aug 12, 2026'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Load release history opens the release picker after fetching', (
    tester,
  ) async {
    final latest = _release(
      '2.0.10',
      releasedAtUtc: DateTime.utc(2026, 8, 20, 2, 5),
    );
    final previous = _release(
      '2.0.9',
      releasedAtUtc: DateTime.utc(2026, 8, 12, 17, 30),
    );
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        currentVersion: '2.0.10+410010',
        latestVersion: latest.version,
        release: latest,
        updateChannel: AppUpdateChannel.beta,
        developerMode: true,
      ),
      releaseHistoryOnRefresh: [latest, previous],
    );

    for (var index = 0; index < 9; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.updates.release-history',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Choose a compatible signed release'),
      ),
      findsOneWidget,
    );
    expect(find.text('2.0.10 Beta • Aug 20, 2026'), findsWidgets);
    expect(find.text('2.0.9 Beta • Aug 12, 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing GitHub dates leave the version label clean', (
    tester,
  ) async {
    final release = _release('1.0.2');
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        phase: AppUpdatePhase.upToDate,
        currentVersion: '1.0.2+410001',
        latestVersion: release.version,
        release: release,
      ),
    );

    expect(find.text('TetoTV 1.0.2+410001'), findsOneWidget);
    expect(find.textContaining('Jan 1, 1970'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lower Android builds stay visible but cannot be selected', (
    tester,
  ) async {
    final installed = _release('2.0.10', androidVersionCode: 410010);
    final blocked = _release('2.0.9', androidVersionCode: 410009);
    await _pumpSystemUpdates(
      tester,
      AppUpdateState(
        phase: AppUpdatePhase.upToDate,
        currentVersion: '2.0.10+410010',
        latestVersion: installed.version,
        release: installed,
        updateChannel: AppUpdateChannel.beta,
        developerMode: true,
        releaseHistory: [installed, blocked],
      ),
    );

    final installedRelease = find.text('2.0.10 Beta');
    await tester.ensureVisible(installedRelease);
    await tester.pumpAndSettle();
    await tester.tap(installedRelease);
    await tester.pumpAndSettle();
    expect(find.text('2.0.9 Beta'), findsOneWidget);
    expect(
      find.text(
        'Blocked by Android • build 410009 is lower than installed build 410010',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('2.0.9 Beta'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.text('Choose a compatible signed release'),
      findsWidgets,
      reason: 'A blocked downgrade must not close the release picker.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'release history D-pad focus scrolls through blocked older releases',
    (tester) async {
      final releases = List.generate(
        15,
        (index) =>
            _release('2.0.${20 - index}', androidVersionCode: 410020 - index),
      );
      await _pumpSystemUpdates(
        tester,
        AppUpdateState(
          phase: AppUpdatePhase.upToDate,
          currentVersion: '2.0.20+410020',
          latestVersion: releases.first.version,
          release: releases.first,
          updateChannel: AppUpdateChannel.beta,
          developerMode: true,
          releaseHistory: releases,
        ),
      );

      final installedRelease = find.text('2.0.20 Beta');
      await tester.ensureVisible(installedRelease);
      await tester.pumpAndSettle();
      await tester.tap(installedRelease);
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'settings.selection.Choose a compatible signed release.0',
      );
      for (var index = 1; index < releases.length; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'settings.selection.Choose a compatible signed release.14',
      );
      final dialogScrollable = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Scrollable),
      );
      expect(dialogScrollable, findsOneWidget);
      final scrollState = tester.state<ScrollableState>(dialogScrollable);
      expect(scrollState.position.pixels, greaterThan(0));

      final lastRelease = find.text('2.0.6 Beta');
      expect(lastRelease, findsOneWidget);
      final blockedReleaseControl = tester.widget<TvFocusable>(
        find.ancestor(of: lastRelease, matching: find.byType(TvFocusable)),
      );
      expect(blockedReleaseControl.enabled, isFalse);
      final releaseRect = tester.getRect(lastRelease);
      final scrollRect = tester.getRect(dialogScrollable);
      expect(releaseRect.top, greaterThanOrEqualTo(scrollRect.top));
      expect(releaseRect.bottom, lessThanOrEqualTo(scrollRect.bottom));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.text('Choose a compatible signed release'),
        findsWidgets,
        reason: 'A focused blocked downgrade must remain non-selectable.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpSystemUpdates(
  WidgetTester tester,
  AppUpdateState state, {
  List<AppReleaseInfo>? releaseHistoryOnRefresh,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = _FixedAppUpdateController(
    state,
    releaseHistoryOnRefresh: releaseHistoryOnRefresh,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [appUpdateControllerProvider.overrideWith((_) => controller)],
      child: const MaterialApp(home: AccountsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('System'));
  await tester.pumpAndSettle();
}

AppReleaseInfo _release(
  String version, {
  DateTime? releasedAtUtc,
  int? androidVersionCode,
}) => AppReleaseInfo(
  tagName: 'v$version',
  version: version,
  name: 'TetoTV $version',
  releasedAtUtc: releasedAtUtc,
  androidVersionCode: androidVersionCode,
  asset: AppReleaseAsset(
    name: 'TetoTV-v$version-universal.apk',
    apiUrl:
        'https://api.github.com/repos/LindersOSX/TetoTV-Beta/releases/assets/1',
    publicUrl:
        'https://github.com/LindersOSX/TetoTV-Beta/releases/download/'
        'v$version/TetoTV-v$version-universal.apk',
    size: 2 * 1024 * 1024,
  ),
);

class _FixedAppUpdateController extends AppUpdateController {
  _FixedAppUpdateController(
    AppUpdateState fixedState, {
    this.releaseHistoryOnRefresh,
  }) : super(
         const FlutterSecureStorage(),
         _UnusedReleaseSource(),
         () async => fixedState.currentVersion,
         () async => const [],
         () async => Directory.systemTemp,
         (_) async => '',
       ) {
    state = fixedState;
  }

  final List<AppReleaseInfo>? releaseHistoryOnRefresh;

  @override
  Future<void> refreshReleaseHistory() async {
    final releases = releaseHistoryOnRefresh;
    if (releases == null) return;
    state = state.copyWith(releaseHistory: releases);
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
