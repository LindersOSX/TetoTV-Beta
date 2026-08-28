import 'package:anime_tv/app/app.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/layout/interface_scaling.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/application/anime_title_logo_provider.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/home/presentation/home_screen.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses denser canvases as the active TV resolution increases', () {
    expect(tvCanvasWidthForPhysicalPixels(1280), 960);
    expect(tvCanvasWidthForPhysicalPixels(1920), 960);
    expect(tvCanvasWidthForPhysicalPixels(2560), 1280);
    expect(tvCanvasWidthForPhysicalPixels(3840), 1600);
  });

  testWidgets('renders the TV home shell', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trendingAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          seasonalAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          trackingHomeProvider.overrideWith(
            (_) => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const TetoTvApp(),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('main-nav-wordmark')), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Watch now'), findsOneWidget);
    expect(find.byKey(const ValueKey('main-nav-my-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('main-nav-settings')), findsOneWidget);
  });

  testWidgets('renders the home shell without overflow on a phone', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trendingAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          seasonalAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          trackingHomeProvider.overrideWith(
            (_) => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Continue watching'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double activating the in-app Home action refreshes shelves', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var trendingLoads = 0;
    var seasonalLoads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trendingAnimeProvider.overrideWith((_) async {
            trendingLoads++;
            return const [];
          }),
          seasonalAnimeProvider.overrideWith((_) async {
            seasonalLoads++;
            return const [];
          }),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home.navigation.home',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(trendingLoads, greaterThan(1));
    expect(seasonalLoads, greaterThan(1));
  });

  testWidgets('holding an unwatched Home shelf card opens status actions', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const hero = AnimeSummary(
      id: 1,
      title: 'Featured title',
      description: '',
      episodes: 12,
      score: null,
    );
    const unwatched = AnimeSummary(
      id: 2,
      idMal: 22,
      title: 'Unwatched trending title',
      description: '',
      episodes: 12,
      score: null,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeTitleLogoProvider.overrideWith((_, _) async => null),
          trendingAnimeProvider.overrideWith((_) async => [hero, unwatched]),
          seasonalAnimeProvider.overrideWith((_) async => const []),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Unwatched trending title'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Unwatched trending title'));
    await tester.pumpAndSettle();

    expect(find.text('Planning'), findsOneWidget);
    expect(
      find.text(
        'Add or update this show on your connected AniList and MAL accounts.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('featured carousel rotates the title and matching metadata', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const first = AnimeSummary(
      id: 1,
      title: 'First Trending Show',
      description: 'First description',
      episodes: 12,
      score: 7.1,
      seasonYear: 2025,
    );
    const second = AnimeSummary(
      id: 2,
      title: 'Second Trending Show',
      description: 'Second description',
      episodes: 24,
      score: 8.8,
      seasonYear: 2026,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeTitleLogoProvider.overrideWith((_, _) async => null),
          trendingAnimeProvider.overrideWith((_) async => [first, second]),
          seasonalAnimeProvider.overrideWith((_) async => const []),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('First Trending Show'), findsOneWidget);
    expect(find.text('First description'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Second Trending Show'), findsWidgets);
    expect(find.text('Second description'), findsOneWidget);
    expect(find.text('First description'), findsNothing);
  });

  testWidgets('featured carousel uses cover art when a banner is missing', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const cover = 'https://example.test/fallback-cover.jpg';
    const hero = AnimeSummary(
      id: 71,
      title: 'Cover-only hero',
      description: 'Still has artwork',
      coverImageUrl: cover,
      episodes: null,
      score: null,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeTitleLogoProvider.overrideWith((_, _) async => null),
          trendingAnimeProvider.overrideWith((_) async => const [hero]),
          seasonalAnimeProvider.overrideWith((_) async => const []),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    final artwork = tester.widget<NetworkArtwork>(
      find.byKey(const ValueKey('hero-art-71')),
    );
    expect(artwork.url, cover);
  });

  testWidgets('home artwork keeps a fixed height across title lengths', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      initialSetupCompletedStorageKey: 'true',
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const hero = AnimeSummary(
      id: 1,
      title: 'Hero',
      description: 'Hero',
      episodes: null,
      score: null,
    );
    const short = AnimeSummary(
      id: 2,
      title: 'Short',
      description: 'Short',
      episodes: null,
      score: null,
    );
    const long = AnimeSummary(
      id: 3,
      title: 'A much longer title that needs the reserved second line',
      description: 'Long',
      episodes: null,
      score: null,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeTitleLogoProvider.overrideWith((_, _) async => null),
          trendingAnimeProvider.overrideWith(
            (_) async => const [hero, short, long],
          ),
          seasonalAnimeProvider.overrideWith((_) async => const []),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final shortArtwork = find.byKey(const ValueKey('home-artwork-2'));
    final longArtwork = find.byKey(const ValueKey('home-artwork-3'));
    final heroPanel = find.byKey(const ValueKey('home-hero'));
    expect(shortArtwork, findsOneWidget);
    expect(longArtwork, findsOneWidget);
    expect(heroPanel, findsOneWidget);
    expect(tester.getTopLeft(find.byType(Scaffold).first), Offset.zero);
    expect(tester.getSize(find.byType(Scaffold).first).width, 1280);
    expect(tester.getTopLeft(heroPanel).dx, 60);
    expect(tester.getSize(heroPanel).width, 1220);
    expect(
      tester.getSize(shortArtwork).height,
      tester.getSize(longArtwork).height,
    );
  });

  testWidgets(
    'continue watching merges tracker titles with local resume precedence',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        initialSetupCompletedStorageKey: 'true',
      });
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final checkpoint = PlaybackCheckpoint(
        anilistMediaId: 101,
        malMediaId: 202,
        episode: 4,
        title: 'Local resume wins',
        position: const Duration(minutes: 8),
        duration: const Duration(minutes: 24),
        updatedAt: DateTime(2026, 8, 9),
      );
      const watching = [
        HomeTrackedAnime(
          tracked: TrackedAnime(
            mediaId: 101,
            title: 'AniList duplicate must be hidden',
            status: TrackingListStatus.watching,
            progress: 3,
          ),
          provider: TrackingProvider.anilist,
          anilistId: 101,
          coverImageUrl: null,
        ),
        HomeTrackedAnime(
          tracked: TrackedAnime(
            mediaId: 202,
            title: 'MAL duplicate must be hidden',
            status: TrackingListStatus.watching,
            progress: 3,
          ),
          provider: TrackingProvider.myAnimeList,
          anilistId: null,
          coverImageUrl: null,
        ),
        HomeTrackedAnime(
          tracked: TrackedAnime(
            mediaId: 303,
            title: 'Distinct AniList title remains',
            status: TrackingListStatus.watching,
            progress: 2,
          ),
          provider: TrackingProvider.anilist,
          anilistId: 303,
          coverImageUrl: null,
        ),
        HomeTrackedAnime(
          tracked: TrackedAnime(
            mediaId: 404,
            title: 'Distinct MAL title remains',
            status: TrackingListStatus.watching,
            progress: 1,
          ),
          provider: TrackingProvider.myAnimeList,
          anilistId: null,
          coverImageUrl: null,
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            trendingAnimeProvider.overrideWith((_) async => const []),
            seasonalAnimeProvider.overrideWith((_) async => const []),
            trackingHomeProvider.overrideWith(
              (_) async => const TrackingHomeData(
                watching: watching,
                planToWatch: [],
                completed: [],
              ),
            ),
            recentPlaybackProvider.overrideWith((_) async => [checkpoint]),
            dismissedContinueWatchingProvider.overrideWith(
              (_) async => const <int>{},
            ),
          ],
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Local resume wins'), findsWidgets);
      expect(find.text('AniList duplicate must be hidden'), findsNothing);
      expect(find.text('MAL duplicate must be hidden'), findsNothing);
      expect(find.text('Distinct AniList title remains'), findsOneWidget);
      expect(find.text('Distinct MAL title remains'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fresh TV installs open setup and can defer it', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    // The production TV shell normalizes 1080p output to a 960x540 canvas.
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isTelevisionProvider.overrideWithValue(true),
          trendingAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          seasonalAnimeProvider.overrideWith((_) => const <AnimeSummary>[]),
          trackingHomeProvider.overrideWith(
            (_) => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: const TetoTvApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('How would you like to set up TetoTV?'), findsOneWidget);
    expect(find.text('Setup on device'), findsOneWidget);
    expect(find.text('Setup on another device'), findsOneWidget);
    expect(
      find.text('Complete every setup step directly on this device.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Use a phone, tablet, or computer while this device stays on the setup screen.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Setup on device'));
    await tester.pumpAndSettle();
    expect(find.text('Set up TetoTV'), findsOneWidget);
    expect(find.text('Set up later'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Set up later'));
    await tester.pumpAndSettle();
    expect(find.text('Set up TetoTV'), findsNothing);
    expect(find.byKey(const ValueKey('main-nav-wordmark')), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
  });
}
