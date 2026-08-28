import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/data/anilist_catalog_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/airing_calendar_screen.dart';
import 'package:anime_tv/features/catalog/presentation/discover_screen.dart';
import 'package:anime_tv/features/catalog/presentation/search_screen.dart';
import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_source_resolver.dart';
import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/downloads/presentation/download_manager_screen.dart';
import 'package:anime_tv/features/home/presentation/home_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/presentation/my_list_screen.dart';
import 'package:anime_tv/features/watch_together/presentation/watch_together_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final entry in const <({String name, Size size})>[
    (name: 'portrait', size: Size(360, 800)),
    (name: 'landscape', size: Size(800, 360)),
  ]) {
    testWidgets('core phone surfaces fit in ${entry.name}', (tester) async {
      tester.view.physicalSize = entry.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final downloadedAt = DateTime.utc(2026, 8, 26);
      final downloadedEpisode = DownloadJob(
        id: 'phone-layout-download',
        anilistMediaId: 1,
        episode: 12,
        seriesTitle: 'A deliberately long downloaded anime title',
        sourceLabel: 'Web stream',
        transport: DownloadTransport.https,
        status: DownloadJobStatus.completed,
        relativePath: 'show/episode-12.mkv',
        expectedBytes: 100,
        receivedBytes: 100,
        queuePosition: 0,
        createdAt: downloadedAt,
        updatedAt: downloadedAt,
      );

      final screens = <Widget>[
        const SearchScreen(),
        const DiscoverScreen(),
        const MyListScreen(),
        const AiringCalendarScreen(),
        const DownloadManagerScreen(),
        const WatchTogetherScreen(),
        const AccountsScreen(),
      ];
      for (final screen in screens) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isTelevisionProvider.overrideWithValue(false),
              settingsPreferencesProvider.overrideWith(
                (_) => _PhoneSettingsController(),
              ),
              catalogClientProvider.overrideWithValue(_EmptyCatalogClient()),
              trackingListProvider.overrideWith(
                (_, _) async => const TrackingListResult(items: []),
              ),
              airingWeekProvider.overrideWith((_) async => const []),
              trackingHomeProvider.overrideWith(
                (_) async => const TrackingHomeData(
                  watching: [],
                  planToWatch: [],
                  completed: [],
                ),
              ),
              downloadManagerProvider.overrideWith(
                (_) => _EmptyDownloadsController([downloadedEpisode]),
              ),
              seasonDownloadControllerProvider.overrideWith(
                (_) => _EmptySeasonController(
                  const SeasonDownloadState(
                    phase: SeasonDownloadPhase.running,
                    total: 12,
                    processed: 4,
                    queued: 3,
                    skipped: 1,
                  ),
                ),
              ),
            ],
            child: MaterialApp(theme: AppTheme.dark, home: screen),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));

        final layoutException = tester.takeException();
        expect(
          layoutException,
          isNull,
          reason: '${screen.runtimeType} overflowed in ${entry.name}',
        );
        expect(
          find.byKey(const ValueKey('phone-bottom-navigation')),
          entry.name == 'portrait' ? findsOneWidget : findsNothing,
          reason: '${screen.runtimeType} has the wrong mobile navigation',
        );
        expect(
          find.byKey(const ValueKey('main-navigation')),
          entry.name == 'landscape' ? findsOneWidget : findsNothing,
          reason: '${screen.runtimeType} duplicated or omitted navigation',
        );
      }
    });
  }

  for (final entry in const <({String name, Size size})>[
    (name: 'portrait', size: Size(360, 800)),
    (name: 'landscape', size: Size(800, 360)),
  ]) {
    testWidgets('Home fits on a ${entry.name} phone', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        initialSetupCompletedStorageKey: 'true',
      });
      tester.view.physicalSize = entry.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isTelevisionProvider.overrideWithValue(false),
            settingsPreferencesProvider.overrideWith(
              (_) => _PhoneSettingsController(),
            ),
            trendingAnimeProvider.overrideWith((_) async => const []),
            seasonalAnimeProvider.overrideWith((_) async => const []),
            trackingHomeProvider.overrideWith(
              (_) async => const TrackingHomeData(
                watching: [],
                planToWatch: [],
                completed: [],
              ),
            ),
            recentPlaybackProvider.overrideWith((_) async => const []),
            dismissedContinueWatchingProvider.overrideWith(
              (_) async => const <int>{},
            ),
          ],
          child: MaterialApp(theme: AppTheme.dark, home: const HomeScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));

      expect(find.byKey(const ValueKey('home-hero')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-top-right-header')), findsOne);
      expect(
        find.byKey(const ValueKey('phone-bottom-navigation')),
        entry.name == 'portrait' ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('main-navigation')),
        entry.name == 'landscape' ? findsOneWidget : findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        entry.name == 'landscape' ? 'home.header-search' : 'home.watch-now',
      );
      if (entry.name == 'landscape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'home.watch-now',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in const <({String name, Size size})>[
    (name: 'portrait', size: Size(360, 800)),
    (name: 'landscape', size: Size(800, 360)),
  ]) {
    testWidgets('all Settings sections remain usable in ${entry.name}', (
      tester,
    ) async {
      tester.view.physicalSize = entry.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isTelevisionProvider.overrideWithValue(false),
            settingsPreferencesProvider.overrideWith(
              (_) => _PhoneSettingsController(),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const AccountsScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));

      for (final section in const [
        'Customize',
        'Streaming',
        'Tracking',
        'System',
      ]) {
        await tester.tap(find.text(section).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final topException = tester.takeException();
        expect(
          topException,
          isNull,
          reason: '$section overflowed at the top in ${entry.name}',
        );

        final verticalScroll = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              (widget.axisDirection == AxisDirection.down ||
                  widget.axisDirection == AxisDirection.up),
        );
        if (verticalScroll.evaluate().isNotEmpty) {
          final scrollState = tester.state<ScrollableState>(
            verticalScroll.first,
          );
          if (scrollState.position.hasContentDimensions) {
            scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: '$section overflowed when scrolled in ${entry.name}',
            );
            scrollState.position.jumpTo(0);
            await tester.pump();
          }
        }
      }
    });
  }
}

class _PhoneSettingsController extends SettingsPreferencesController {
  _PhoneSettingsController() : super(const FlutterSecureStorage()) {
    state = const SettingsPreferences(
      loaded: true,
      offlineDownloadsEnabled: true,
    );
  }

  @override
  Future<void> load() async {}
}

class _EmptyCatalogClient extends AniListCatalogClient {
  _EmptyCatalogClient()
    : super(
        dio: Dio(BaseOptions(baseUrl: 'https://example.invalid')),
        kitsuDio: Dio(BaseOptions(baseUrl: 'https://example.invalid')),
      );

  @override
  Future<List<AnimeSummary>> discover(
    CatalogFilters filters, {
    int page = 1,
  }) async => const [];
}

class _EmptyDownloadsController extends DownloadManagerController {
  _EmptyDownloadsController([List<DownloadJob> jobs = const []])
    : super(
        repository: DownloadRepository(),
        storage: OfflineDownloadStorage(),
        transferClient: DioDownloadTransferClient(),
        autoInitialize: false,
      ) {
    state = DownloadManagerState(jobs: jobs, initialized: true);
  }
}

class _EmptySeasonController extends SeasonDownloadController {
  _EmptySeasonController([
    SeasonDownloadState initial = const SeasonDownloadState(),
  ]) : super.withActions(
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
