import 'dart:async';

import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/application/anime_title_logo_provider.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/anime_trailer.dart';
import 'package:anime_tv/features/catalog/presentation/anime_details_screen.dart';
import 'package:anime_tv/features/catalog/presentation/anime_title_logo_view.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/episode_discovery_prefetch_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';

void main() {
  testWidgets('details shows an in-app trailer action when metadata has one', (
    tester,
  ) async {
    final anime = AnimeSummary(
      id: 51,
      title: 'Trailer Show',
      description: '',
      episodes: 12,
      score: 8,
      trailer: AnimeTrailer.tryCreate(
        provider: 'youtube',
        videoId: 'abcDEF_12-3',
      ),
    );
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
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 51)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('anime-details-watch-trailer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('anime-details-download-season')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('anime-details-information-actions')),
        matching: find.byKey(const ValueKey('anime-details-download-season')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-actions-panel')),
        matching: find.byKey(const ValueKey('anime-details-download-season')),
      ),
      findsNothing,
    );
    expect(find.text('Watch trailer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled offline downloads remove the season action', (
    tester,
  ) async {
    const anime = AnimeSummary(
      id: 52,
      title: 'No Downloads Show',
      description: '',
      episodes: 12,
      score: 8,
      staff: [AnimePerson(id: 1, name: 'Example Staff')],
    );
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
            (_) => _LoadedSettingsController(
              const SettingsPreferences(
                loaded: true,
                offlineDownloadsEnabled: false,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 52)),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('anime-details-download-season')),
      findsNothing,
    );
    expect(find.text('Download season'), findsNothing);
    expect(find.text('Cast & crew'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV details uses a bounded language-matched clear logo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const anime = AnimeSummary(
      id: 53,
      title: 'Fallback Title',
      titleEnglish: 'English Details Title Season 4',
      titleRomaji: 'Romaji Details Title 4',
      description: 'Details logo layout test.',
      episodes: 12,
      score: 8,
    );
    final logoRequests = <TitleLanguagePreference>[];
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
            (_) => _LoadedSettingsController(
              const SettingsPreferences(
                loaded: true,
                showTitleStyle: ShowTitleStyle.englishLogo,
              ),
            ),
          ),
          titleLanguagePreferenceProvider.overrideWith(
            (_) =>
                _StaticTitleLanguageController(TitleLanguagePreference.english),
          ),
          animeTitleLogoProvider.overrideWith((_, request) async {
            logoRequests.add(request.titleLanguage);
            return AnimeTitleLogo(
              url: Uri.parse(
                'https://assets.fanart.tv/fanart/tv/details-english.png',
              ),
              source: AnimeTitleLogoSource.fanartTvHd,
              languageCode: 'en',
            );
          }),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 53)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    expect(logoRequests, contains(TitleLanguagePreference.english));
    final info = find.byKey(const ValueKey('anime-details-info'));
    final logo = find.descendant(
      of: info,
      matching: find.byType(CachedNetworkImage),
    );
    expect(logo, findsOneWidget);
    expect(
      tester.widget<CachedNetworkImage>(logo).imageUrl,
      'https://assets.fanart.tv/fanart/tv/details-english.png',
    );
    final logoRect = tester.getRect(logo);
    final infoRect = tester.getRect(info);
    final titleLogo = tester.widget<AnimeTitleLogoView>(
      find.descendant(of: info, matching: find.byType(AnimeTitleLogoView)),
    );
    expect(titleLogo.logoContextLabel, 'SEASON 4');
    expect(titleLogo.logoContextMaxLines, 1);
    expect(logoRect.height, lessThanOrEqualTo(88));
    expect(infoRect.contains(logoRect.topLeft), isTrue);
    expect(
      infoRect.contains(logoRect.bottomRight - const Offset(.1, .1)),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile details falls back to the selected Romaji title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const anime = AnimeSummary(
      id: 54,
      title: 'Fallback Title',
      titleEnglish: 'English Details Title',
      titleRomaji: 'Romaji Details Title',
      description: 'Details text fallback test.',
      episodes: 12,
      score: 8,
    );
    final logoRequests = <TitleLanguagePreference>[];
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
          titleLanguagePreferenceProvider.overrideWith(
            (_) =>
                _StaticTitleLanguageController(TitleLanguagePreference.romaji),
          ),
          animeTitleLogoProvider.overrideWith((_, request) async {
            logoRequests.add(request.titleLanguage);
            return null;
          }),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 54)),
      ),
    );
    await tester.pumpAndSettle();

    expect(logoRequests, contains(TitleLanguagePreference.romaji));
    expect(find.text('Romaji Details Title'), findsOneWidget);
    expect(find.text('English Details Title'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('completed local episodes immediately advance details progress', () {
    expect(
      effectiveCompletedEpisodeProgress(
        trackedProgress: 3,
        localEpisode: 5,
        localCompleted: true,
      ),
      5,
    );
    expect(
      effectiveCompletedEpisodeProgress(
        trackedProgress: 7,
        localEpisode: 5,
        localCompleted: true,
      ),
      7,
    );
    expect(
      effectiveCompletedEpisodeProgress(trackedProgress: 3, localEpisode: 5),
      3,
    );
  });

  testWidgets('details error state starts on Back', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeDetailsProvider.overrideWith(
            (_, _) async => throw StateError('offline'),
          ),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 1)),
      ),
    );
    await tester.pumpAndSettle();

    final detector = find.descendant(
      of: find.byType(TvFocusable).first,
      matching: find.byType(FocusableActionDetector),
    );
    expect(
      tester.widget<FocusableActionDetector>(detector).focusNode?.hasFocus,
      isTrue,
    );
    expect(find.text('Could not load anime'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening details immediately warms the selected episode', (
    tester,
  ) async {
    const anime = AnimeSummary(
      id: 44,
      idMal: 440,
      title: 'Prefetched Show',
      description: '',
      episodes: 12,
      score: 8,
      seasonYear: 2026,
    );
    EpisodeReference? warmed;
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
          episodeDiscoveryPrefetcherProvider.overrideWithValue((
            episode, {
            required preferences,
          }) {
            warmed = episode;
            return EpisodeDiscoveryPrefetchHandle.completed();
          }),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 44)),
      ),
    );
    await tester.pumpAndSettle();

    expect(warmed?.anilistMediaId, 44);
    expect(warmed?.episode, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'details waits for disabled source preferences before prefetching',
    (tester) async {
      const anime = AnimeSummary(
        id: 46,
        title: 'Private source choices',
        description: '',
        episodes: 12,
        score: 8,
      );
      final loadGate = Completer<void>();
      final settings = _DelayedSettingsController(loadGate);
      var prefetchCalls = 0;
      var debridStarts = 0;
      var webStarts = 0;
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
            settingsPreferencesProvider.overrideWith((_) => settings),
            episodeDiscoveryPrefetcherProvider.overrideWithValue((
              episode, {
              required preferences,
            }) {
              prefetchCalls++;
              if (preferences.debridStreamsEnabled) debridStarts++;
              if (preferences.webStreamsEnabled) webStarts++;
              return EpisodeDiscoveryPrefetchHandle.completed();
            }),
          ],
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 46)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(prefetchCalls, 0);
      expect(debridStarts, 0);
      expect(webStarts, 0);

      loadGate.complete();
      await tester.pumpAndSettle();

      expect(prefetchCalls, 1);
      expect(debridStarts, 0);
      expect(webStarts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rapid D-pad episode changes only prefetch the final selection', (
    tester,
  ) async {
    const anime = AnimeSummary(
      id: 45,
      idMal: 450,
      title: 'Debounced Show',
      description: '',
      episodes: 12,
      score: 8,
      seasonYear: 2026,
    );
    final warmedEpisodes = <int>[];
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
          episodeDiscoveryPrefetcherProvider.overrideWithValue((
            episode, {
            required preferences,
          }) {
            warmedEpisodes.add(episode.episode);
            return EpisodeDiscoveryPrefetchHandle.completed();
          }),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 45)),
      ),
    );
    await tester.pumpAndSettle();
    expect(warmedEpisodes, contains(1));
    warmedEpisodes.clear();

    final nextControl = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-step-next')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    nextControl.focusNode!.requestFocus();
    await tester.pump();
    for (var i = 0; i < 3; i += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Episode 4 of 12'), findsOneWidget);
    expect(warmedEpisodes, isEmpty);
    await tester.pump(const Duration(milliseconds: 299));
    expect(warmedEpisodes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(warmedEpisodes, [4]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'returning to a cancelled episode restarts only that latest prefetch',
    (tester) async {
      const anime = AnimeSummary(
        id: 48,
        title: 'Traversal race',
        description: '',
        episodes: 12,
        score: 8,
      );
      final startedEpisodes = <int>[];
      final cancelledEpisodes = <int>[];
      final firstCancellationCanFinish = Completer<void>();
      var activeHandles = 0;
      var maximumActiveHandles = 0;
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
              (_) => _LoadedSettingsController(
                const SettingsPreferences(
                  debridStreamsEnabled: false,
                  webStreamsEnabled: true,
                  loaded: true,
                ),
              ),
            ),
            episodeDiscoveryPrefetcherProvider.overrideWithValue((
              episode, {
              required preferences,
            }) {
              startedEpisodes.add(episode.episode);
              activeHandles++;
              if (activeHandles > maximumActiveHandles) {
                maximumActiveHandles = activeHandles;
              }
              final handleNumber = startedEpisodes.length;
              final completion = Completer<void>();
              var cancelled = false;
              return EpisodeDiscoveryPrefetchHandle(
                done: completion.future,
                cancel: () async {
                  if (cancelled) return;
                  cancelled = true;
                  cancelledEpisodes.add(episode.episode);
                  if (handleNumber == 1) {
                    await firstCancellationCanFinish.future;
                  }
                  activeHandles--;
                  completion.complete();
                },
              );
            }),
          ],
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 48)),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(startedEpisodes, [1]);
      expect(activeHandles, 1);

      final nextControl = tester.widget<FocusableActionDetector>(
        find
            .descendant(
              of: find.byKey(const ValueKey('episode-step-next')),
              matching: find.byType(FocusableActionDetector),
            )
            .first,
      );
      nextControl.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Episode 2 of 12'), findsOneWidget);
      expect(cancelledEpisodes, [1]);
      expect(activeHandles, 1);

      final previousControl = tester.widget<FocusableActionDetector>(
        find
            .descendant(
              of: find.byKey(const ValueKey('episode-step-previous')),
              matching: find.byType(FocusableActionDetector),
            )
            .first,
      );
      previousControl.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 299));
      expect(find.text('Episode 1 of 12'), findsOneWidget);
      expect(startedEpisodes, [1]);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(startedEpisodes, [1]);
      expect(activeHandles, 1);

      firstCancellationCanFinish.complete();
      await tester.pump();
      await tester.pump();
      expect(startedEpisodes, [1, 1]);
      expect(activeHandles, 1);
      expect(maximumActiveHandles, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(activeHandles, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing episode and leaving details cancel active prefetch', (
    tester,
  ) async {
    const anime = AnimeSummary(
      id: 47,
      title: 'Cancelable discovery',
      description: '',
      episodes: 12,
      score: 8,
    );
    final cancelledEpisodes = <int>[];
    final startedEpisodes = <int>[];
    final completions = <int, Completer<void>>{};
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
            (_) => _LoadedSettingsController(
              const SettingsPreferences(
                debridStreamsEnabled: false,
                webStreamsEnabled: true,
                loaded: true,
              ),
            ),
          ),
          episodeDiscoveryPrefetcherProvider.overrideWithValue((
            episode, {
            required preferences,
          }) {
            startedEpisodes.add(episode.episode);
            final completion = completions.putIfAbsent(
              episode.episode,
              Completer<void>.new,
            );
            return EpisodeDiscoveryPrefetchHandle(
              done: completion.future,
              cancel: () async {
                cancelledEpisodes.add(episode.episode);
                if (!completion.isCompleted) completion.complete();
              },
            );
          }),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 47)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(startedEpisodes, [1]);

    final nextControl = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('episode-step-next')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    nextControl.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(cancelledEpisodes, [1]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(startedEpisodes, [1, 2]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(cancelledEpisodes, [1, 2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('episode action layout fits a smaller 16:9 TV canvas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const anime = AnimeSummary(
      id: 1,
      title: 'The Example Hero and the Long Adventure Title',
      description:
          'A detailed synopsis that explains the story, its characters, and '
          'the challenges they face across a long television season.',
      episodes: 24,
      score: 8.4,
      genres: ['Action', 'Adventure', 'Fantasy'],
      format: 'TV',
      status: 'RELEASING',
      durationMinutes: 24,
      relatedAnime: [
        RelatedAnime(
          relationType: 'SEQUEL',
          anime: AnimeSummary(
            id: 2,
            title: 'The Example Hero Season 2',
            description: '',
            episodes: 12,
            score: 8.1,
          ),
        ),
      ],
    );

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
          trackingListProvider(
            TrackingListStatus.planToWatch,
          ).overrideWith((_) async => const TrackingListResult(items: [])),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 1)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Play from beginning'), findsOneWidget);
    expect(find.text('Start watching'), findsOneWidget);
    expect(find.text('My List status'), findsOneWidget);
    expect(find.text('Episode 1 of 24'), findsOneWidget);
    expect(find.text('Related series'), findsOneWidget);
    expect(find.text('RELATED'), findsNothing);
    expect(find.text('The Example Hero Season 2'), findsNothing);
    expect(find.text('Episodes'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AspectRatio && (widget.aspectRatio - 2 / 3).abs() < .001,
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-step-previous')),
        matching: find.byType(FocusableActionDetector),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-step-next')),
        matching: find.byType(FocusableActionDetector),
      ),
      findsOneWidget,
    );
    final compactTvPoster = tester.getRect(
      find.byKey(const ValueKey('anime-details-poster')),
    );
    final compactTvInfo = tester.getRect(
      find.byKey(const ValueKey('anime-details-info')),
    );
    final compactTvActions = tester.getRect(
      find.byKey(const ValueKey('episode-actions-panel')),
    );
    expect(compactTvPoster.height / 540, closeTo(.60, .01));
    expect(compactTvPoster.right, lessThan(compactTvInfo.left));
    expect(compactTvInfo.right, lessThan(compactTvActions.left));
    await tester.tap(find.text('My List status'));
    await tester.pumpAndSettle();
    expect(find.text('Planning'), findsOneWidget);
    expect(find.text('Watching'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('episode action layout scales up on a full HD TV canvas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final anime = AnimeSummary(
      id: 1,
      title: 'Black Torch',
      description:
          'A detailed synopsis that remains readable beside the poster and '
          'playback controls on a full resolution television layout.',
      episodes: 24,
      score: 7.8,
      genres: ['Action', 'Adventure', 'Fantasy'],
      format: 'TV',
      status: 'RELEASING',
      durationMinutes: 24,
      seasonYear: 2026,
      staff: [AnimePerson(id: 10, name: 'Example Director')],
      trailer: AnimeTrailer.tryCreate(
        provider: 'youtube',
        videoId: 'abcDEF_12-3',
      ),
      relatedAnime: [
        RelatedAnime(
          relationType: 'SEQUEL',
          anime: AnimeSummary(
            id: 2,
            title: 'Black Torch Season 2',
            description: '',
            episodes: 12,
            score: 8,
          ),
        ),
      ],
    );

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
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 1)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('EPISODE 1 OF 24'), findsOneWidget);
    expect(find.text('Start watching'), findsOneWidget);
    expect(find.text('Play from beginning'), findsOneWidget);
    expect(find.text('Play selected'), findsOneWidget);
    expect(find.text('Watch trailer'), findsOneWidget);
    expect(find.text('Cast & crew'), findsOneWidget);
    expect(find.text('Related series'), findsOneWidget);
    expect(find.text('Download season'), findsOneWidget);
    expect(find.text('2026'), findsWidgets);
    expect(find.text('24m'), findsWidgets);
    expect(find.text('7.8 / 10'), findsOneWidget);
    final castControl = tester.widget<FocusableActionDetector>(
      find
          .ancestor(
            of: find.text('Cast & crew'),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    castControl.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final relatedControl = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('anime-details-related-series')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    expect(relatedControl.focusNode?.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final downloadControl = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('anime-details-download-season')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    expect(downloadControl.focusNode?.hasFocus, isTrue);
    final informationActionRects = <Rect>[
      for (final key in const [
        ValueKey('anime-details-watch-trailer'),
        ValueKey('anime-details-cast-crew'),
        ValueKey('anime-details-related-series'),
        ValueKey('anime-details-download-season'),
      ])
        tester.getRect(find.byKey(key)),
    ];
    for (var index = 1; index < informationActionRects.length; index++) {
      expect(
        informationActionRects[index].top,
        closeTo(informationActionRects.first.top, .01),
      );
      expect(
        informationActionRects[index].bottom,
        closeTo(informationActionRects.first.bottom, .01),
      );
      expect(
        informationActionRects[index].left,
        greaterThan(informationActionRects[index - 1].right),
      );
    }
    expect(informationActionRects.first.height, 58);
    final posterCenter = tester.getCenter(
      find.byKey(const ValueKey('anime-details-poster')),
    );
    final infoCenter = tester.getCenter(
      find.byKey(const ValueKey('anime-details-info')),
    );
    final actionsCenter = tester.getCenter(
      find.byKey(const ValueKey('episode-actions-panel')),
    );
    expect((posterCenter.dy - actionsCenter.dy).abs(), lessThan(1));
    expect((infoCenter.dy - actionsCenter.dy).abs(), lessThan(1));
    final posterRect = tester.getRect(
      find.byKey(const ValueKey('anime-details-poster')),
    );
    final infoRect = tester.getRect(
      find.byKey(const ValueKey('anime-details-info')),
    );
    final actionsRect = tester.getRect(
      find.byKey(const ValueKey('episode-actions-panel')),
    );
    expect(posterRect.height / 1080, closeTo(.60, .01));
    expect(posterRect.right, lessThan(infoRect.left));
    expect(infoRect.right, lessThan(actionsRect.left));
    expect(actionsRect.right, lessThanOrEqualTo(1920));
    expect(tester.takeException(), isNull);
  });

  testWidgets('future shows display an unreleased cover badge', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const anime = AnimeSummary(
      id: 11,
      title: 'Future Anime',
      description: 'This series has not premiered yet.',
      episodes: 12,
      score: null,
      status: 'NOT_YET_RELEASED',
      seasonYear: 2027,
    );

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
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 11)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('UNRELEASED'), findsOneWidget);
    expect(find.text('Not released yet'), findsOneWidget);
    expect(find.text('Start watching'), findsNothing);
    for (final key in const [
      'episode-action-resume',
      'episode-action-restart',
      'episode-action-selected',
      'episode-step-previous',
      'episode-step-next',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(FocusableActionDetector),
        ),
        findsNothing,
        reason: '$key must not become a D-pad focus stop before release',
      );
    }
    final backControl = tester.widget<FocusableActionDetector>(
      find
          .ancestor(
            of: find.text('Back'),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    expect(backControl.focusNode?.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(700, 600), Size(720, 600), Size(800, 600)]) {
    testWidgets(
      'episode actions remain responsive and focusable at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final anime = AnimeSummary(
          id: 21,
          title: 'Responsive Mid Width Anime With a Long Title',
          description:
              'A longer synopsis verifies that the information column remains '
              'readable without crowding the playback actions at tablet and '
              'small television widths.',
          episodes: 24,
          score: 8.7,
          genres: ['Action', 'Adventure', 'Fantasy'],
          format: 'TV',
          status: 'RELEASING',
          durationMinutes: 24,
          seasonYear: 2026,
          staff: [AnimePerson(id: 1, name: 'Director')],
          relatedAnime: [
            RelatedAnime(
              relationType: 'SEQUEL',
              anime: AnimeSummary(
                id: 22,
                title: 'Responsive Sequel',
                description: '',
                episodes: 12,
                score: 8,
              ),
            ),
          ],
        );

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
            ],
            child: const MaterialApp(home: AnimeDetailsScreen(animeId: 21)),
          ),
        );
        await tester.pumpAndSettle();

        final posterRect = tester.getRect(
          find.byKey(const ValueKey('anime-details-poster')),
        );
        expect(posterRect.left, greaterThanOrEqualTo(0));
        expect(posterRect.top, greaterThanOrEqualTo(0));
        expect(posterRect.right, lessThanOrEqualTo(size.width));
        expect(posterRect.bottom, lessThanOrEqualTo(size.height));

        if (size.width < 800) {
          final backControl = tester.widget<FocusableActionDetector>(
            find
                .ancestor(
                  of: find.text('Back'),
                  matching: find.byType(FocusableActionDetector),
                )
                .first,
          );
          expect(backControl.focusNode?.hasFocus, isTrue);
          await tester.ensureVisible(
            find.byKey(const ValueKey('episode-actions-panel')),
          );
          await tester.pump();
        } else {
          final resumeControl = tester.widget<FocusableActionDetector>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('episode-action-resume')),
                  matching: find.byType(FocusableActionDetector),
                )
                .first,
          );
          expect(resumeControl.focusNode?.hasFocus, isTrue);
        }
        final actionsRect = tester.getRect(
          find.byKey(const ValueKey('episode-actions-panel')),
        );
        expect(actionsRect.left, greaterThanOrEqualTo(0));
        expect(actionsRect.top, greaterThanOrEqualTo(0));
        expect(actionsRect.right, lessThanOrEqualTo(size.width));
        expect(actionsRect.bottom, lessThanOrEqualTo(size.height));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in const [
    Size(360, 800),
    Size(390, 844),
    Size(412, 915),
    Size(768, 832),
    Size(1536, 2048),
    Size(800, 360),
    Size(844, 390),
  ]) {
    testWidgets(
      'episode action layout fits mobile ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final anime = AnimeSummary(
          id: 1,
          title: 'A Long Example Anime Title for a Small Mobile Screen',
          description:
              'A synopsis that remains readable while the compact page scrolls '
              'instead of forcing the television columns into a phone viewport.',
          episodes: 12,
          score: 8.2,
          genres: ['Action', 'Adventure', 'Fantasy'],
          format: 'TV',
          status: 'RELEASING',
          durationMinutes: 24,
          seasonYear: 2026,
          staff: [AnimePerson(id: 10, name: 'Example Director')],
          trailer: AnimeTrailer.tryCreate(
            provider: 'youtube',
            videoId: 'abcDEF_12-3',
          ),
          relatedAnime: [
            RelatedAnime(
              relationType: 'SEQUEL',
              anime: AnimeSummary(
                id: 2,
                title: 'Example Season Two',
                description: '',
                episodes: 12,
                score: 8,
              ),
            ),
          ],
        );

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
            ],
            child: const MaterialApp(home: AnimeDetailsScreen(animeId: 1)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Start watching'), findsOneWidget);
        expect(find.text('Play from beginning'), findsOneWidget);
        expect(find.text('Play selected'), findsOneWidget);
        expect(find.text('Watch trailer'), findsOneWidget);
        expect(find.text('Cast & crew'), findsOneWidget);
        expect(find.text('Related series'), findsOneWidget);
        expect(find.text('Download season'), findsOneWidget);
        expect(find.text('EP 1 / 12'), findsOneWidget);
        final informationActionTops = <double>[
          for (final key in const [
            ValueKey('anime-details-watch-trailer'),
            ValueKey('anime-details-cast-crew'),
            ValueKey('anime-details-related-series'),
            ValueKey('anime-details-download-season'),
          ])
            tester.getTopLeft(find.byKey(key)).dy,
        ];
        for (final top in informationActionTops.skip(1)) {
          expect(top, closeTo(informationActionTops.first, .01));
        }
        final posterSize = tester.getSize(
          find.byKey(const ValueKey('anime-details-poster')),
        );
        expect(posterSize.width, inInclusiveRange(112, 320));
        if (size.width >= 1200) {
          expect(posterSize.width, greaterThanOrEqualTo(300));
        }
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('episode-actions-panel')))
              .dy,
          greaterThan(
            tester
                .getBottomLeft(
                  find.byKey(const ValueKey('anime-details-poster')),
                )
                .dy,
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _DelayedSettingsController extends SettingsPreferencesController {
  _DelayedSettingsController(this.gate) : super(const FlutterSecureStorage());

  final Completer<void> gate;

  @override
  Future<void> load() async {
    await gate.future;
    state = const SettingsPreferences(
      debridStreamsEnabled: false,
      webStreamsEnabled: false,
      loaded: true,
    );
  }
}

class _LoadedSettingsController extends SettingsPreferencesController {
  _LoadedSettingsController([
    SettingsPreferences preferences = const SettingsPreferences(loaded: true),
  ]) : super(const FlutterSecureStorage()) {
    state = preferences;
  }

  @override
  Future<void> load() async {}
}

class _StaticTitleLanguageController extends TitleLanguagePreferenceController {
  _StaticTitleLanguageController(TitleLanguagePreference initial)
    : super(const FlutterSecureStorage()) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}
