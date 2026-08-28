import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/anime_details_screen.dart';
import 'package:anime_tv/features/downloads/application/season_download_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_source_resolver.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/episode_discovery_prefetch_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets(
    'season completion snackbar can open Downloads after details is removed',
    (tester) async {
      const anime = AnimeSummary(
        id: 51,
        title: 'Snackbar Route Safety',
        description: '',
        episodes: 12,
        score: 8,
      );
      final seasonDownloads = _TestSeasonDownloadController();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const AnimeDetailsScreen(animeId: 51),
          ),
          GoRoute(
            path: '/other',
            builder: (_, _) =>
                const Scaffold(body: SizedBox(key: ValueKey('other-route'))),
          ),
          GoRoute(
            path: '/downloads',
            builder: (_, _) => const Scaffold(
              body: SizedBox(key: ValueKey('downloads-route')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeDetailsProvider.overrideWith((_, _) async => anime),
            trackingHomeProvider.overrideWith(
              (_) async => const TrackingHomeData(
                watching: [],
                planToWatch: [],
                completed: [],
              ),
            ),
            settingsPreferencesProvider.overrideWith(
              (_) => _LoadedSettingsController(),
            ),
            seasonDownloadControllerProvider.overrideWith(
              (_) => seasonDownloads,
            ),
            episodeDiscoveryPrefetcherProvider.overrideWithValue(
              (_, {required preferences}) =>
                  EpisodeDiscoveryPrefetchHandle.completed(),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      seasonDownloads.completeFor(51);
      await tester.pump();
      expect(find.widgetWithText(SnackBarAction, 'Downloads'), findsOneWidget);

      router.go('/other');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('other-route')), findsOneWidget);

      await tester.tap(find.widgetWithText(SnackBarAction, 'Downloads'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('downloads-route')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('season download started snackbar closes after five seconds', (
    tester,
  ) async {
    const anime = AnimeSummary(
      id: 52,
      title: 'Snackbar Timeout',
      description: '',
      episodes: 12,
      score: 8,
    );
    final seasonDownloads = _TestSeasonDownloadController();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeDetailsProvider.overrideWith((_, _) async => anime),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
          settingsPreferencesProvider.overrideWith(
            (_) => _LoadedSettingsController(),
          ),
          seasonDownloadControllerProvider.overrideWith((_) => seasonDownloads),
          episodeDiscoveryPrefetcherProvider.overrideWithValue(
            (_, {required preferences}) =>
                EpisodeDiscoveryPrefetchHandle.completed(),
          ),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 52)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('anime-details-download-season')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Downloads'));
    await tester.pump();

    const started =
        'Season download started. Keep TetoTV open until it finishes.';
    expect(find.text(started), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text(started), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(started), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _TestSeasonDownloadController extends SeasonDownloadController {
  _TestSeasonDownloadController()
    : super.withActions(
        initializeDownloads: _noop,
        existingEpisodes: (_) async => <int>{},
        enqueueDownload: (_) async {},
        pinCatalog: (_) async {},
        saveEpisodeMetadata: (_) async {},
        sourceResolver: const _NoopSeasonDownloadResolver(),
      );

  @override
  Future<SeasonDownloadStartResult> start(SeasonDownloadPlan plan) async =>
      SeasonDownloadStartResult.started;

  void completeFor(int mediaId) {
    state = SeasonDownloadState(
      phase: SeasonDownloadPhase.completed,
      mediaId: mediaId,
      total: 1,
      processed: 1,
      queued: 1,
      eventId: state.eventId + 1,
    );
  }
}

class _NoopSeasonDownloadResolver implements SeasonEpisodeDownloadResolver {
  const _NoopSeasonDownloadResolver();

  @override
  Future<bool> directTorrentAvailable() async => false;

  @override
  Future<ResolvedSeasonDownload?> resolve({
    required SeasonDownloadPlan plan,
    required EpisodeReference episode,
    required SeasonDownloadAffinity affinity,
  }) async => null;
}

class _LoadedSettingsController extends SettingsPreferencesController {
  _LoadedSettingsController() : super(const FlutterSecureStorage()) {
    state = const SettingsPreferences(loaded: true);
  }

  @override
  Future<void> load() async {}
}

Future<void> _noop() async {}
