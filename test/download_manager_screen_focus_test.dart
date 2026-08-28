import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_source_resolver.dart';
import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/downloads/presentation/download_manager_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('Left from Downloads Refresh focuses the first job action', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 24);
    await _pumpDownloads(
      tester,
      jobs: [
        DownloadJob(
          id: 'first-download',
          anilistMediaId: 1,
          episode: 1,
          seriesTitle: 'First download',
          sourceLabel: 'Web stream',
          transport: DownloadTransport.https,
          status: DownloadJobStatus.completed,
          relativePath: 'first-download/media.mkv',
          expectedBytes: 1,
          receivedBytes: 1,
          queuePosition: 0,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    await _expectRefreshLeftTargetsFirstContent(tester);
  });

  testWidgets('Left from Downloads Refresh focuses the season action', (
    tester,
  ) async {
    await _pumpDownloads(
      tester,
      season: const SeasonDownloadState(
        phase: SeasonDownloadPhase.running,
        total: 2,
        processed: 1,
      ),
    );

    await _expectRefreshLeftTargetsFirstContent(tester);
  });

  testWidgets('Left from empty Downloads Refresh returns to navigation', (
    tester,
  ) async {
    await _pumpDownloads(tester);

    expect(find.text('No offline episodes yet'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'downloads.refresh');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'top-level.active-navigation',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled offline downloads redirect a direct manager route', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/downloads',
      routes: [
        GoRoute(
          path: '/downloads',
          builder: (_, _) => const DownloadManagerScreen(),
        ),
        GoRoute(
          path: '/settings/accounts',
          builder: (_, _) => const Scaffold(body: Text('SETTINGS TARGET')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _DisabledDownloadsSettingsController(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('SETTINGS TARGET'), findsOneWidget);
    expect(find.text('Downloads'), findsNothing);
  });

  testWidgets(
    'direct manager route waits for the persisted master switch before initialization',
    (tester) async {
      final settings = _PendingDownloadsSettingsController();
      var managerInitializations = 0;
      final router = GoRouter(
        initialLocation: '/downloads',
        routes: [
          GoRoute(
            path: '/downloads',
            builder: (_, _) => const DownloadManagerScreen(),
          ),
          GoRoute(
            path: '/settings/accounts',
            builder: (_, _) => const Scaffold(body: Text('SETTINGS TARGET')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith((_) => settings),
            downloadManagerProvider.overrideWith((_) {
              managerInitializations++;
              return _SeededDownloadsController(const []);
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      expect(managerInitializations, 0);
      expect(find.text('Downloads'), findsNothing);

      settings.finishLoading(enabled: false);
      await tester.pumpAndSettle();

      expect(managerInitializations, 0);
      expect(find.text('SETTINGS TARGET'), findsOneWidget);
      expect(find.text('Downloads'), findsNothing);
    },
  );
}

Future<void> _pumpDownloads(
  WidgetTester tester, {
  List<DownloadJob> jobs = const [],
  SeasonDownloadState season = const SeasonDownloadState(),
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsPreferencesProvider.overrideWith(
          (_) => _EnabledDownloadsSettingsController(),
        ),
        downloadManagerProvider.overrideWith(
          (_) => _SeededDownloadsController(jobs),
        ),
        seasonDownloadControllerProvider.overrideWith(
          (_) => _SeededSeasonController(season),
        ),
      ],
      child: const MaterialApp(home: DownloadManagerScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _expectRefreshLeftTargetsFirstContent(WidgetTester tester) async {
  final refresh = tester.widget<FocusableActionDetector>(
    find.descendant(
      of: find.byKey(const ValueKey('downloads-refresh')),
      matching: find.byType(FocusableActionDetector),
    ),
  );
  refresh.focusNode!.requestFocus();
  await tester.pump();
  expect(FocusManager.instance.primaryFocus?.debugLabel, 'downloads.refresh');

  await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
  await tester.pump();
  expect(
    FocusManager.instance.primaryFocus?.debugLabel,
    'downloads.content.first',
  );
  expect(tester.takeException(), isNull);
}

class _SeededDownloadsController extends DownloadManagerController {
  _SeededDownloadsController(List<DownloadJob> jobs)
    : super(
        repository: DownloadRepository(),
        storage: OfflineDownloadStorage(),
        transferClient: DioDownloadTransferClient(),
        autoInitialize: false,
      ) {
    state = DownloadManagerState(jobs: jobs, initialized: true);
  }
}

class _SeededSeasonController extends SeasonDownloadController {
  _SeededSeasonController(SeasonDownloadState initial)
    : super.withActions(
        initializeDownloads: _noop,
        existingEpisodes: (_) async => const {},
        enqueueDownload: (_) => _noop(),
        pinCatalog: (_) => _noop(),
        saveEpisodeMetadata: (_) => _noop(),
        sourceResolver: const _UnusedSeasonResolver(),
      ) {
    state = initial;
  }
}

class _DisabledDownloadsSettingsController
    extends SettingsPreferencesController {
  _DisabledDownloadsSettingsController() : super(const FlutterSecureStorage()) {
    state = const SettingsPreferences(
      loaded: true,
      offlineDownloadsEnabled: false,
    );
  }

  @override
  Future<void> load() async {}
}

class _EnabledDownloadsSettingsController
    extends SettingsPreferencesController {
  _EnabledDownloadsSettingsController() : super(const FlutterSecureStorage()) {
    state = const SettingsPreferences(
      loaded: true,
      offlineDownloadsEnabled: true,
    );
  }

  @override
  Future<void> load() async {}
}

class _PendingDownloadsSettingsController
    extends SettingsPreferencesController {
  _PendingDownloadsSettingsController() : super(const FlutterSecureStorage()) {
    state = const SettingsPreferences(
      loaded: false,
      offlineDownloadsEnabled: true,
    );
  }

  void finishLoading({required bool enabled}) {
    state = SettingsPreferences(loaded: true, offlineDownloadsEnabled: enabled);
  }

  @override
  Future<void> load() async {}
}

class _UnusedSeasonResolver implements SeasonEpisodeDownloadResolver {
  const _UnusedSeasonResolver();

  @override
  Future<bool> directTorrentAvailable() async => false;

  @override
  Future<ResolvedSeasonDownload?> resolve({
    required SeasonDownloadPlan plan,
    required EpisodeReference episode,
    required SeasonDownloadAffinity affinity,
  }) async => null;
}

Future<void> _noop() async {}
