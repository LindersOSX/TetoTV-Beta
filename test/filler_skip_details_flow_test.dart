import 'dart:async';

import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/application/filler_episode_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:anime_tv/features/catalog/presentation/anime_details_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  const anime = AnimeSummary(
    id: 1,
    idMal: 20,
    title: 'Example Anime',
    titleEnglish: 'Example Anime',
    description: 'A series used to verify filler-aware playback navigation.',
    episodes: 12,
    score: 8,
    status: 'FINISHED',
    seasonYear: 2026,
  );

  testWidgets('skip filler toggle is a reachable D-pad focus stop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeFillerRepository(_confirmed({}));

    await _pumpDetails(
      tester,
      anime: anime,
      repository: repository,
      preferences: const SeriesPlaybackPreferences(),
    );

    final toggle = find.byKey(const ValueKey('episode-action-skip-filler'));
    expect(toggle, findsOneWidget);
    expect(find.text('Skip filler'), findsOneWidget);
    expect(find.text('OFF'), findsOneWidget);

    for (var index = 0; index < 4; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    final detector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: toggle,
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    expect(detector.focusNode?.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggle persists independently for the displayed series', (
    tester,
  ) async {
    final repository = _FakeFillerRepository(_confirmed({}));
    int? savedMediaId;
    SeriesPlaybackPreferences? savedPreferences;

    await _pumpDetails(
      tester,
      anime: anime,
      repository: repository,
      preferences: const SeriesPlaybackPreferences(),
      onSaved: (mediaId, preferences) {
        savedMediaId = mediaId;
        savedPreferences = preferences;
      },
    );

    await tester.tap(find.text('Skip filler'));
    await tester.pumpAndSettle();

    expect(savedMediaId, anime.id);
    expect(savedPreferences?.skipFillerEpisodes, isTrue);
    expect(find.text('ON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed selected filler shows indicators when skipping is off',
    (tester) async {
      final repository = _FakeFillerRepository(_confirmed({1}));

      await _pumpDetails(
        tester,
        anime: anime,
        repository: repository,
        preferences: const SeriesPlaybackPreferences(),
      );

      expect(find.text('FILLER'), findsNWidgets(2));
      expect(repository.lookups, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('global indicator preference prevents lookup and badges', (
    tester,
  ) async {
    final repository = _FakeFillerRepository(_confirmed({1}));

    await _pumpDetails(
      tester,
      anime: anime,
      repository: repository,
      preferences: const SeriesPlaybackPreferences(),
      showFillerIndicators: false,
    );

    expect(find.text('FILLER'), findsNothing);
    expect(repository.lookups, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual Play selected honors skip and names skipped episodes', (
    tester,
  ) async {
    final repository = _FakeFillerRepository(_confirmed({1, 2}));

    await _pumpDetails(
      tester,
      anime: anime,
      repository: repository,
      preferences: const SeriesPlaybackPreferences(skipFillerEpisodes: true),
    );

    // Enabled skipping does not prefetch solely to render an indicator.
    expect(repository.lookups, 0);
    await tester.tap(find.text('Play selected'));
    await tester.pumpAndSettle();

    expect(
      find.text('Skipped filler Episodes 1–2. Playing Episode 3.'),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Resolved episode 3'), findsOneWidget);
    expect(repository.lookups, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable data plays normally and explains once', (
    tester,
  ) async {
    final repository = _FakeFillerRepository(
      FillerEpisodeLookup.unavailable(reason: FillerUnavailableReason.network),
    );

    await _pumpDetails(
      tester,
      anime: anime,
      repository: repository,
      preferences: const SeriesPlaybackPreferences(skipFillerEpisodes: true),
    );
    await tester.tap(find.text('Play selected'));
    await tester.pumpAndSettle();

    expect(find.text('Resolved episode 1'), findsOneWidget);
    expect(
      find.text('Filler data is unavailable. Playing Episode 1 normally.'),
      findsOneWidget,
    );
    expect(repository.lookups, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not navigate when no non-filler episode remains', (
    tester,
  ) async {
    final repository = _FakeFillerRepository(
      _confirmed(Set<int>.from(List<int>.generate(12, (index) => index + 1))),
    );

    await _pumpDetails(
      tester,
      anime: anime,
      repository: repository,
      preferences: const SeriesPlaybackPreferences(skipFillerEpisodes: true),
    );
    await tester.tap(find.text('Play selected'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Episodes 1–12 are marked as filler. There are no later non-filler episodes available.',
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Play selected'), findsOneWidget);
    expect(find.textContaining('Resolved episode'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending lookup does not use ref or context after disposal', (
    tester,
  ) async {
    final completer = Completer<FillerEpisodeLookup>();
    final repository = _DelayedFillerRepository(completer.future);

    await _pumpDetails(
      tester,
      anime: anime,
      repository: repository,
      preferences: const SeriesPlaybackPreferences(skipFillerEpisodes: true),
    );
    await tester.tap(find.text('Play selected'));
    await tester.pump();
    expect(repository.lookups, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    completer.complete(_confirmed({1}));
    await tester.pumpAndSettle();

    expect(find.text('Filler skipped'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDetails(
  WidgetTester tester, {
  required AnimeSummary anime,
  required FillerEpisodeRepository repository,
  required SeriesPlaybackPreferences preferences,
  bool showFillerIndicators = true,
  void Function(int, SeriesPlaybackPreferences)? onSaved,
}) async {
  var storedPreferences = preferences;
  final router = GoRouter(
    initialLocation: '/anime/${anime.id}',
    routes: [
      GoRoute(
        path: '/anime/:id',
        builder: (_, _) => AnimeDetailsScreen(animeId: anime.id),
      ),
      GoRoute(
        path: '/resolve',
        builder: (_, state) => Scaffold(
          body: Text(
            'Resolved episode ${state.uri.queryParameters['episode']}',
          ),
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
        linkedTrackingProgressProvider((
          anilistMediaId: anime.id,
          malMediaId: anime.idMal,
        )).overrideWith((_) async => 0),
        latestPlaybackProvider(anime.id).overrideWith((_) async => null),
        seriesPlaybackPreferencesProvider(
          anime.id,
        ).overrideWith((_) async => storedPreferences),
        seriesPlaybackPreferencesWriterProvider.overrideWithValue((
          mediaId,
          preferences,
        ) async {
          storedPreferences = preferences;
          onSaved?.call(mediaId, preferences);
        }),
        fillerEpisodeRepositoryProvider.overrideWithValue(repository),
        settingsPreferencesProvider.overrideWith(
          (_) => _TestSettingsPreferencesController(
            SettingsPreferences(
              showFillerIndicators: showFillerIndicators,
              loaded: true,
            ),
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

FillerEpisodeLookup _confirmed(Set<int> fillers) =>
    FillerEpisodeLookup.confirmed(
      confirmedFillerEpisodes: fillers,
      source: FillerDataSource.jikanMalId,
      resolvedMalMediaId: 20,
      fetchedAt: DateTime.utc(2026),
      knownEpisodeCount: 12,
    );

class _FakeFillerRepository implements FillerEpisodeRepository {
  _FakeFillerRepository(this.result);

  final FillerEpisodeLookup result;
  int lookups = 0;

  @override
  Future<FillerEpisodeLookup> lookup(
    FillerSeriesIdentity identity, {
    bool forceRefresh = false,
  }) async {
    lookups++;
    return result;
  }
}

class _DelayedFillerRepository implements FillerEpisodeRepository {
  _DelayedFillerRepository(this.result);

  final Future<FillerEpisodeLookup> result;
  int lookups = 0;

  @override
  Future<FillerEpisodeLookup> lookup(
    FillerSeriesIdentity identity, {
    bool forceRefresh = false,
  }) {
    lookups++;
    return result;
  }
}

class _TestSettingsPreferencesController extends SettingsPreferencesController {
  _TestSettingsPreferencesController(SettingsPreferences initial)
    : super(
        const FlutterSecureStorage(),
        readValue: (_) async => null,
        writeValue: (_, _) async {},
        deleteValue: (_) async {},
      ) {
    state = initial;
  }
}
