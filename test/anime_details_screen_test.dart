import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/features/catalog/application/anime_title_logo_provider.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:anime_tv/features/catalog/presentation/episode_browser_dialog.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
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
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final size in const [
    Size(960, 540),
    Size(1280, 720),
    Size(1920, 1080),
  ]) {
    testWidgets('four-digit resume label stays complete on $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const anime = AnimeSummary(
        id: 609,
        title: 'Long Running Series',
        description: 'A saved episode with a long number.',
        episodes: 1500,
        score: null,
        status: 'RELEASING',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isTelevisionProvider.overrideWithValue(true),
            animeDetailsProvider.overrideWith((_, _) async => anime),
            trackingHomeProvider.overrideWith(
              (_) async => const TrackingHomeData(
                watching: [],
                planToWatch: [],
                completed: [],
              ),
            ),
            latestPlaybackProvider(anime.id).overrideWith(
              (_) async => PlaybackCheckpoint(
                anilistMediaId: anime.id,
                episode: 1234,
                title: anime.title,
                position: const Duration(minutes: 10),
                duration: const Duration(minutes: 20),
                updatedAt: DateTime.utc(2026, 9, 30),
              ),
            ),
            settingsPreferencesProvider.overrideWith(
              (_) => _LoadedSettingsController(),
            ),
          ],
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 609)),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.text('Resume Eps 1234');
      expect(label, findsOneWidget);
      expect(tester.widget<Text>(label).semanticsLabel, 'Resume Episode 1234');
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: label, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      final buttonRect = tester.getRect(
        find.byKey(const ValueKey('episode-action-resume')),
      );
      final labelRect = tester.getRect(label);
      expect(labelRect.left, greaterThanOrEqualTo(buttonRect.left));
      expect(labelRect.right, lessThanOrEqualTo(buttonRect.right));
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    (total: 13, linked: 5, local: 13, completed: false, expected: 5),
    (total: 13, linked: 5, local: 7, completed: true, expected: 7),
    (total: 13, linked: 20, local: 1, completed: false, expected: 13),
    (total: null, linked: 0, local: 4, completed: true, expected: 4),
  ]) {
    testWidgets(
      'personal watched progress is independent of airing status $scenario',
      (tester) async {
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final anime = AnimeSummary(
          id: 599,
          title: 'Watch Progress',
          description:
              'Progress from linked trackers or completed local playback.',
          episodes: scenario.total,
          score: null,
          status: 'FINISHED',
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isTelevisionProvider.overrideWithValue(true),
              animeDetailsProvider.overrideWith((_, _) async => anime),
              trackingHomeProvider.overrideWith(
                (_) async => const TrackingHomeData(
                  watching: [],
                  planToWatch: [],
                  completed: [],
                ),
              ),
              linkedTrackingProgressProvider.overrideWith(
                (_, _) async => scenario.linked,
              ),
              latestPlaybackProvider(anime.id).overrideWith(
                (_) async => PlaybackCheckpoint(
                  anilistMediaId: anime.id,
                  episode: scenario.local,
                  title: anime.title,
                  position: const Duration(minutes: 10),
                  duration: const Duration(minutes: 20),
                  completed: scenario.completed,
                  updatedAt: DateTime.utc(2026, 9, 29),
                ),
              ),
              settingsPreferencesProvider.overrideWith(
                (_) => _LoadedSettingsController(),
              ),
            ],
            child: const MaterialApp(home: AnimeDetailsScreen(animeId: 599)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Finished airing'), findsOneWidget);
        final bar = find.byKey(
          const ValueKey('anime-details-watched-progress-bar'),
        );
        if (scenario.total == null) {
          expect(
            find.text('Watched ${scenario.expected} episodes'),
            findsOneWidget,
          );
          expect(bar, findsNothing);
        } else {
          expect(
            find.text('Watched ${scenario.expected} of ${scenario.total}'),
            findsOneWidget,
          );
          expect(
            tester.widget<LinearProgressIndicator>(bar).value,
            scenario.expected / scenario.total!,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('resumable episode uses one primary action and a progress line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const anime = AnimeSummary(
      id: 599,
      title: 'Resume Layout',
      description: 'A series with a saved episode.',
      episodes: 13,
      score: 8,
      status: 'FINISHED',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isTelevisionProvider.overrideWithValue(true),
          animeDetailsProvider.overrideWith((_, _) async => anime),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
          latestPlaybackProvider(anime.id).overrideWith(
            (_) async => PlaybackCheckpoint(
              anilistMediaId: anime.id,
              episode: 13,
              title: anime.title,
              position: const Duration(minutes: 10),
              duration: const Duration(minutes: 20),
              updatedAt: DateTime.utc(2026, 9, 28),
            ),
          ),
          settingsPreferencesProvider.overrideWith(
            (_) => _LoadedSettingsController(),
          ),
        ],
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 599)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Resume Eps 13'), findsOneWidget);
    final resumeText = tester.widget<Text>(find.text('Resume Eps 13'));
    expect(resumeText.semanticsLabel, 'Resume Episode 13');
    expect(resumeText.overflow, TextOverflow.visible);
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.descendant(
              of: find.text('Resume Eps 13'),
              matching: find.byType(RichText),
            ),
          )
          .didExceedMaxLines,
      isFalse,
    );
    expect(find.text('Episode 13 of 13'), findsNothing);
    expect(find.text('Play from beginning'), findsOneWidget);
    expect(find.text('Play selected'), findsNothing);
    expect(find.text('Status: Finished'), findsNothing);
    expect(
      find.byKey(const ValueKey('anime-details-finished-status')),
      findsOneWidget,
    );
    expect(find.text('Finished airing'), findsOneWidget);
    expect(find.text('Watched 0 of 13'), findsOneWidget);
    expect(find.text('Browse all episodes'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('episode-resume-progress')),
          )
          .value,
      .5,
    );
    expect(tester.takeException(), isNull);
  });

  for (final releaseStatus in <String?>[
    'FINISHED',
    'finished_airing',
    'Finished Airing',
    'RELEASING',
    'NOT_YET_RELEASED',
    null,
  ]) {
    testWidgets(
      'finished badge follows catalog status $releaseStatus without watch progress',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final anime = AnimeSummary(
          id: 599,
          title: 'Release Status',
          description: 'An unwatched series.',
          episodes: 13,
          score: 8,
          status: releaseStatus,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isTelevisionProvider.overrideWithValue(true),
              animeDetailsProvider.overrideWith((_, _) async => anime),
              trackingHomeProvider.overrideWith(
                (_) async => const TrackingHomeData(
                  watching: [],
                  planToWatch: [],
                  completed: [],
                ),
              ),
              latestPlaybackProvider(anime.id).overrideWith((_) async => null),
              settingsPreferencesProvider.overrideWith(
                (_) => _LoadedSettingsController(),
              ),
            ],
            child: const MaterialApp(home: AnimeDetailsScreen(animeId: 599)),
          ),
        );
        await tester.pumpAndSettle();
        final finished =
            releaseStatus?.toUpperCase().startsWith('FINISHED') ?? false;
        final badge = find.byKey(
          const ValueKey('anime-details-finished-status'),
        );
        expect(badge, finished ? findsOneWidget : findsNothing);
        if (finished) {
          expect(find.text('Finished airing'), findsOneWidget);
          expect(find.text('Watched 0 of 13'), findsOneWidget);
          expect(find.text('Start watching'), findsOneWidget);
          expect(
            find.descendant(
              of: badge,
              matching: find.byType(FocusableActionDetector),
            ),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final status in const [
    (raw: 'FINISHED', key: 'finished', label: 'Finished airing'),
    (raw: 'RELEASING', key: 'airing', label: 'Airing'),
    (raw: 'NOT_YET_RELEASED', key: 'unreleased', label: 'Unreleased'),
  ]) {
    for (final layout in const [
      (size: Size(1280, 720), scale: 1.0),
      (size: Size(1920, 1080), scale: 1.0),
      (size: Size(1920, 1080), scale: 1.35),
      (size: Size(390, 844), scale: 1.4),
    ]) {
      testWidgets(
        '${status.label} shares the facts baseline and sizing on $layout',
        (tester) async {
          tester.view.physicalSize = layout.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final anime = AnimeSummary(
            id: 599,
            title: 'Aligned Media Facts',
            description: 'All release states align with the other media facts.',
            episodes: 12,
            score: 8.3,
            seasonYear: 2024,
            durationMinutes: 24,
            status: status.raw,
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                isTelevisionProvider.overrideWithValue(
                  layout.size.width >= 960,
                ),
                animeDetailsProvider.overrideWith((_, _) async => anime),
                trackingHomeProvider.overrideWith(
                  (_) async => const TrackingHomeData(
                    watching: [],
                    planToWatch: [],
                    completed: [],
                  ),
                ),
                latestPlaybackProvider(
                  anime.id,
                ).overrideWith((_) async => null),
                settingsPreferencesProvider.overrideWith(
                  (_) => _LoadedSettingsController(),
                ),
              ],
              child: MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(layout.scale)),
                  child: child!,
                ),
                home: const AnimeDetailsScreen(animeId: 599),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final statusFact = find.byKey(
            ValueKey('anime-details-${status.key}-status'),
          );
          expect(statusFact, findsOneWidget);
          final facts = find
              .ancestor(of: statusFact, matching: find.byType(Wrap))
              .first;
          final wrap = tester.widget<Wrap>(facts);
          expect(wrap.children, hasLength(4));
          expect(wrap.crossAxisAlignment, WrapCrossAlignment.center);
          final labels = <Finder>[
            for (final label in ['2024', '24m', '8.3 / 10', status.label])
              find.descendant(of: facts, matching: find.text(label)),
          ];
          final style = tester.widget<Text>(labels.first).style;
          expect(style?.height, 1.25);
          for (final label in labels) {
            expect(label, findsOneWidget);
            expect(tester.widget<Text>(label).style, style);
            final item = find
                .ancestor(of: label, matching: find.byType(Row))
                .first;
            final icon = find.descendant(of: item, matching: find.byType(Icon));
            expect(
              tester.getCenter(icon).dy,
              closeTo(tester.getCenter(label).dy, .01),
            );
            final paragraph = tester.renderObject<RenderParagraph>(label);
            expect(paragraph.didExceedMaxLines, isFalse);
          }
          // Each wrapped line has one text baseline, not an offset status.
          for (var index = 1; index < labels.length; index++) {
            final previous = labels[index - 1];
            final current = labels[index];
            if ((tester.getCenter(previous).dy - tester.getCenter(current).dy)
                    .abs() <
                1) {
              double baseline(Finder label) {
                final paragraph = tester.renderObject<RenderParagraph>(label);
                final painter = TextPainter(
                  text: paragraph.text,
                  textDirection: paragraph.textDirection,
                  textScaler: paragraph.textScaler,
                  strutStyle: paragraph.strutStyle,
                  textHeightBehavior: paragraph.textHeightBehavior,
                )..layout(maxWidth: paragraph.size.width);
                final value =
                    tester.getTopLeft(label).dy +
                    painter.computeLineMetrics().first.baseline;
                painter.dispose();
                return value;
              }

              expect(baseline(current), closeTo(baseline(previous), .01));
            }
          }
          if (layout.size.width == 1920 && layout.scale == 1) {
            expect(
              tester.getCenter(labels.last).dy,
              closeTo(tester.getCenter(labels.first).dy, .01),
            );
          }
          expect(find.textContaining('Status:'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final layout in const [
    (size: Size(960, 540), scale: 1.0),
    (size: Size(1920, 1080), scale: 1.0),
    (size: Size(360, 800), scale: 1.0),
    (size: Size(400, 700), scale: 2.0),
  ]) {
    testWidgets(
      'More Info is a readable actionable progress-header control on $layout',
      (tester) async {
        tester.view.physicalSize = layout.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        try {
          final anime = _moreMenuAnime();
          final palette = AppThemePalette.fromSeeds(
            background: const Color(0xFF071B2C),
            surface: const Color(0xFF12364A),
            accent: const Color(0xFF3CC8A8),
            primaryText: const Color(0xFFF4F9FF),
            mutedText: const Color(0xFF9BC0D1),
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                ..._moreMenuOverrides(anime),
                isTelevisionProvider.overrideWithValue(
                  layout.size.width >= 960,
                ),
                latestPlaybackProvider(
                  anime.id,
                ).overrideWith((_) async => null),
              ],
              child: MaterialApp(
                theme: AppTheme.darkFor(palette),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(layout.scale)),
                  child: child!,
                ),
                home: AnimeDetailsScreen(animeId: anime.id),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final control = find.byKey(const ValueKey('anime-details-more'));
          final progress = find.byKey(
            const ValueKey('anime-details-watch-progress'),
          );
          expect(find.text('More'), findsNothing);
          expect(find.text('More Info'), findsOneWidget);
          expect(
            find.descendant(of: progress, matching: control),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: control,
              matching: find.byIcon(Icons.info_rounded),
            ),
            findsOneWidget,
          );
          expect(tester.getSemantics(control).label, 'More Info');
          expect(tester.getSemantics(control).flagsCollection.isButton, isTrue);
          final buttonRect = tester.getRect(control);
          final headerRect = tester.getRect(progress);
          expect(buttonRect.left, greaterThanOrEqualTo(headerRect.left));
          expect(buttonRect.top, greaterThanOrEqualTo(headerRect.top));
          expect(buttonRect.right, lessThanOrEqualTo(headerRect.right));
          expect(buttonRect.bottom, lessThanOrEqualTo(headerRect.bottom));
          expect(buttonRect.right, closeTo(headerRect.right, .01));
          final label = find.text('More Info');
          expect(
            tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
            isFalse,
          );
          if (layout.size.width == 1920 && layout.scale == 1) {
            expect(
              tester.getCenter(label).dy,
              closeTo(tester.getCenter(find.text('Watched 0 of 12')).dy, .01),
            );
            final primary = tester
                .widget<FocusableActionDetector>(
                  find
                      .descendant(
                        of: find.byKey(const ValueKey('episode-action-resume')),
                        matching: find.byType(FocusableActionDetector),
                      )
                      .first,
                )
                .focusNode!;
            primary.requestFocus();
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pumpAndSettle();
            expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pumpAndSettle();
            expect(primary.hasFocus, isTrue);
          }
          await _openInformationMenu(tester);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pumpAndSettle();
          expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  for (final size in const [Size(960, 540), Size(1920, 1080), Size(360, 800)]) {
    testWidgets('finished status and More menu fit $size with a custom theme', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final palette = AppThemePalette.fromSeeds(
        background: const Color(0xFF071B2C),
        surface: const Color(0xFF12364A),
        accent: const Color(0xFF3CC8A8),
        primaryText: const Color(0xFFF4F9FF),
        mutedText: const Color(0xFF9BC0D1),
      );
      final anime = AnimeSummary(
        id: 599,
        title: 'Serial Experiments Lain',
        description:
            'A series with a saved episode and finished release status. '
            'This description is long enough to exercise the compact television layout.',
        episodes: 13,
        score: 8,
        status: 'FINISHED',
        format: 'TV',
        seasonYear: 1998,
        durationMinutes: 23,
        genres: const ['Drama', 'Mystery', 'Psychological'],
        staff: const [AnimePerson(id: 1, name: 'Director')],
        trailer: AnimeTrailer.tryCreate(
          provider: 'youtube',
          videoId: 'abcDEF_12-3',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isTelevisionProvider.overrideWithValue(size.width >= 960),
            animeDetailsProvider.overrideWith((_, _) async => anime),
            trackingHomeProvider.overrideWith(
              (_) async => const TrackingHomeData(
                watching: [],
                planToWatch: [],
                completed: [],
              ),
            ),
            latestPlaybackProvider(anime.id).overrideWith(
              (_) async => PlaybackCheckpoint(
                anilistMediaId: anime.id,
                episode: 13,
                title: anime.title,
                position: const Duration(minutes: 10),
                duration: const Duration(minutes: 20),
                updatedAt: DateTime.utc(2026, 9, 28),
              ),
            ),
            settingsPreferencesProvider.overrideWith(
              (_) => _LoadedSettingsController(),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.darkFor(palette),
            home: const AnimeDetailsScreen(animeId: 599),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final badge = find.byKey(const ValueKey('anime-details-finished-status'));
      expect(badge, findsOneWidget);
      final badgeIcon = tester.widget<Icon>(
        find.descendant(of: badge, matching: find.byType(Icon)),
      );
      expect(badgeIcon.color, palette.accentBright);
      _expectInformationActionsHidden();
      await _openInformationMenu(tester);
      final tray = find.byKey(const ValueKey('anime-details-more-menu'));
      final informationPanel = tester.widget<Container>(tray);
      final episodePanel = tester.widget<Container>(
        find.byKey(const ValueKey('episode-actions-panel')),
      );
      expect(informationPanel.decoration, episodePanel.decoration);
      final gradient =
          (informationPanel.decoration! as BoxDecoration).gradient!
              as LinearGradient;
      expect(gradient.colors, [
        palette.surface.withValues(alpha: .78),
        palette.background.withValues(alpha: .66),
      ]);
      final trayRect = tester.getRect(tray);
      expect(trayRect.left, greaterThanOrEqualTo(0));
      expect(trayRect.right, lessThanOrEqualTo(size.width));
      final actionRects = <Rect>[
        for (final key in const [
          ValueKey('anime-details-watch-trailer-surface'),
          ValueKey('anime-details-cast-crew-surface'),
          ValueKey('anime-details-download-season-surface'),
        ])
          tester.getRect(find.byKey(key)),
      ];
      for (final action in actionRects) {
        expect(trayRect.contains(action.center), isTrue);
      }
      _expectVerticalInformationActions(actionRects, gap: 8);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

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

    _expectInformationActionsHidden();
    await _openInformationMenu(tester);
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
        of: find.byKey(const ValueKey('anime-details-more-menu')),
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

    _expectInformationActionsHidden();
    await _openInformationMenu(tester);
    expect(
      find.byKey(const ValueKey('anime-details-download-season')),
      findsNothing,
    );
    expect(find.text('Download season'), findsNothing);
    expect(find.text('Cast & crew'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('More actions return to More after their destination closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final anime = _moreMenuAnime();
    final router = GoRouter(
      initialLocation: '/anime/57',
      routes: [
        GoRoute(
          path: '/anime/:id',
          builder: (_, _) => const AnimeDetailsScreen(animeId: 57),
          routes: [
            for (final destination in ['credits', 'franchise'])
              GoRoute(
                path: destination,
                builder: (_, _) => Scaffold(body: Text(destination)),
              ),
          ],
        ),
        GoRoute(
          path: '/trailer',
          builder: (_, _) => const Scaffold(body: Text('trailer')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _moreMenuOverrides(anime),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    for (final action in [
      ('watch-trailer', 'trailer'),
      ('cast-crew', 'credits'),
      ('related-series', 'franchise'),
    ]) {
      await _openInformationMenu(tester);
      _detailsActionFocusNode(tester, action.$1).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.text(action.$2),
        findsOneWidget,
        reason: 'route=${router.routeInformationProvider.value.uri}',
      );
      expect(
        find.byKey(const ValueKey('anime-details-more-menu')),
        findsNothing,
      );
      router.pop();
      await tester.pumpAndSettle();
      expect(
        _detailsActionFocusNode(tester, 'more').hasFocus,
        isTrue,
        reason: 'after closing ${action.$1}',
      );
    }
    await _openInformationMenu(tester);
    await tester.tap(
      find.byKey(const ValueKey('anime-details-download-season')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('season-download-dialog')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('anime-details-more-menu')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('More dismissals never leave the details page or leak focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _moreMenuOverrides(_moreMenuAnime()),
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 57)),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.goBack,
    ]) {
      await _openInformationMenu(tester);
      final physicalKey = key == LogicalKeyboardKey.goBack
          ? PhysicalKeyboardKey.escape
          : null;
      await tester.sendKeyDownEvent(key, physicalKey: physicalKey);
      await tester.sendKeyRepeatEvent(key, physicalKey: physicalKey);
      await tester.sendKeyUpEvent(key, physicalKey: physicalKey);
      await tester.pumpAndSettle();
      expect(find.byType(AnimeDetailsScreen), findsOneWidget);
      _expectInformationActionsHidden();
      expect(
        _detailsActionFocusNode(tester, 'more').hasFocus,
        isTrue,
        reason:
            'after dismissal by $key; focus=${FocusManager.instance.primaryFocus}',
      );
    }
    await _openInformationMenu(tester);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    _expectInformationActionsHidden();
    expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
    await _openInformationMenu(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('held horizontal closing keys cannot move restored More focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _moreMenuOverrides(_moreMenuAnime()),
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 57)),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ]) {
      await _openInformationMenu(tester);
      await tester.sendKeyDownEvent(key);
      await tester.pumpAndSettle();
      expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
      await tester.sendKeyRepeatEvent(key);
      await tester.pumpAndSettle();
      expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
      await tester.sendKeyUpEvent(key);
      expect(
        find.byKey(const ValueKey('anime-details-more-menu')),
        findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(400, 360), const Size(400, 700)]) {
    testWidgets('large-text More menu stays within safe bounds at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._moreMenuOverrides(_moreMenuAnime()),
            isTelevisionProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2.5),
                padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
              ),
              child: child!,
            ),
            home: const AnimeDetailsScreen(animeId: 57),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _openInformationMenu(tester);
      final menu = find.byKey(const ValueKey('anime-details-more-menu'));
      expect(tester.widget<Container>(menu).clipBehavior, Clip.antiAlias);
      final rect = tester.getRect(menu);
      expect(rect.left, greaterThanOrEqualTo(34));
      expect(rect.right, lessThanOrEqualTo(size.width - 34));
      expect(rect.top, greaterThanOrEqualTo(40));
      expect(rect.bottom, lessThanOrEqualTo(size.height - 36));
      for (final label in [
        'Watch trailer',
        'Cast & crew',
        'Related series',
        'Download season',
      ]) {
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(label))
              .didExceedMaxLines,
          isFalse,
          reason: label,
        );
      }
      for (var index = 0; index < 3; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(
        _detailsActionFocusNode(tester, 'download-season').hasFocus,
        isTrue,
      );
      final lastRect = tester.getRect(
        find.byKey(const ValueKey('anime-details-download-season-surface')),
      );
      expect(lastRect.top, greaterThanOrEqualTo(rect.top));
      expect(lastRect.bottom, lessThanOrEqualTo(rect.bottom));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

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

  testWidgets('Romaji preference controls the details text fallback', (
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
    expect(logoRequests, isNot(contains(TitleLanguagePreference.english)));
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

    for (var i = 2; i <= 4; i++) {
      await _selectDetailsEpisode(tester, i);
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const ValueKey('episode-manual-selector')), findsNothing);
    expect(warmedEpisodes, isEmpty);
    await tester.pump(const Duration(milliseconds: 249));
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
      await _selectDetailsEpisode(tester, 2);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('episode-manual-selector')),
        findsNothing,
      );
      expect(cancelledEpisodes, [1]);
      expect(activeHandles, 1);
      await _selectDetailsEpisode(tester, 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 299));
      expect(
        find.byKey(const ValueKey('episode-manual-selector')),
        findsNothing,
      );
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
    await _selectDetailsEpisode(tester, 2);
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

    final anime = AnimeSummary(
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
      staff: const [AnimePerson(id: 10, name: 'Example Director')],
      trailer: AnimeTrailer.tryCreate(
        provider: 'youtube',
        videoId: 'abcDEF_12-3',
      ),
      relatedAnime: const [
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

    expect(find.text('Play from beginning'), findsNothing);
    expect(find.text('Start watching'), findsOneWidget);
    expect(find.text('My List'), findsOneWidget);
    expect(find.text('Episode 1 of 24'), findsNothing);
    _expectInformationActionsHidden();
    expect(find.text('More'), findsNothing);
    expect(find.text('More Info'), findsOneWidget);
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
      findsNothing,
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
    expect(compactTvPoster.height / 540, closeTo(.66, .01));
    expect(compactTvPoster.right, lessThan(compactTvInfo.left));
    expect(compactTvInfo.right, lessThan(compactTvActions.left));
    final moreRect = tester.getRect(
      find.byKey(const ValueKey('anime-details-more-surface')),
    );
    expect(moreRect.width, lessThan(compactTvActions.width));
    expect(moreRect.height, lessThanOrEqualTo(34));
    expect(compactTvActions.contains(moreRect.topLeft), isTrue);
    expect(compactTvActions.contains(moreRect.bottomRight), isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('anime-details-info')),
        matching: find.byKey(const ValueKey('anime-details-more')),
      ),
      findsNothing,
    );
    await _openInformationMenu(tester);
    _expectCompactInformationMenu(tester, large: true);
    final trailerFocus = _detailsActionFocusNode(tester, 'watch-trailer');
    expect(trailerFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(trailerFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_detailsActionFocusNode(tester, 'cast-crew').hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
    _expectInformationActionsHidden();
    await tester.tap(find.text('My List'));
    await tester.pumpAndSettle();
    expect(find.text('Planning'), findsOneWidget);
    expect(find.text('Watching'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final hasRelatedSeries in [false, true]) {
    testWidgets('More menu stays compact on a roomy TV '
        '(related: $hasRelatedSeries)', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final anime = AnimeSummary(
        id: 54,
        title: 'Roomy TV Details',
        description: 'An action tray with a matching control height.',
        episodes: 12,
        score: 8,
        staff: const [AnimePerson(id: 1, name: 'Director')],
        trailer: AnimeTrailer.tryCreate(
          provider: 'youtube',
          videoId: 'abcDEF_12-3',
        ),
        relatedAnime: hasRelatedSeries
            ? const [
                RelatedAnime(
                  relationType: 'SEQUEL',
                  anime: AnimeSummary(
                    id: 55,
                    title: 'Roomy TV Sequel',
                    description: '',
                    episodes: 12,
                    score: 8,
                  ),
                ),
              ]
            : const [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isTelevisionProvider.overrideWithValue(true),
            animeDetailsProvider.overrideWith((_, _) async => anime),
            trackingHomeProvider.overrideWith(
              (_) async => const TrackingHomeData(
                watching: [],
                planToWatch: [],
                completed: [],
              ),
            ),
          ],
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 54)),
        ),
      );
      await tester.pumpAndSettle();

      final referenceHeight = tester
          .getSize(find.byKey(const ValueKey('episode-action-manage-list')))
          .height;
      expect(referenceHeight, 49);
      _expectInformationActionsHidden();
      await _openInformationMenu(tester);
      final actionRects = <Rect>[
        for (final key in [
          const ValueKey('anime-details-watch-trailer-surface'),
          const ValueKey('anime-details-cast-crew-surface'),
          if (hasRelatedSeries)
            const ValueKey('anime-details-related-series-surface'),
          const ValueKey('anime-details-download-season-surface'),
        ])
          tester.getRect(find.byKey(key)),
      ];
      for (final action in actionRects) {
        expect(action.height, greaterThanOrEqualTo(56));
      }
      _expectVerticalInformationActions(actionRects, gap: 8);
      _expectCompactInformationMenu(
        tester,
        large: true,
        hasRelatedSeries: hasRelatedSeries,
      );
      expect(tester.takeException(), isNull);
    });
  }

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
      coverImageUrl: 'https://example.com/cover.jpg',
      bannerImageUrl: 'https://example.com/banner.jpg',
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

    final blurredBackdrop = find.descendant(
      of: find.byType(ImageFiltered),
      matching: find.byType(NetworkArtwork),
    );
    expect(blurredBackdrop, findsOneWidget);
    expect(
      tester.widget<NetworkArtwork>(blurredBackdrop).url,
      anime.coverImageUrl,
    );

    expect(find.text('Episode 1 of 24'), findsNothing);
    expect(find.text('Start watching'), findsOneWidget);
    expect(find.text('Play from beginning'), findsNothing);
    expect(find.text('Play selected'), findsNothing);
    expect(find.text('Browse all episodes'), findsOneWidget);
    _expectInformationActionsHidden();
    expect(find.text('2026'), findsWidgets);
    expect(find.text('24m'), findsWidgets);
    expect(find.text('7.8 / 10'), findsOneWidget);
    await _openInformationMenu(tester);
    _expectCompactInformationMenu(tester, large: true);
    final trailerFocus = _detailsActionFocusNode(tester, 'watch-trailer');
    expect(trailerFocus.hasFocus, isTrue);
    for (final id in ['cast-crew', 'related-series', 'download-season']) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_detailsActionFocusNode(tester, id).hasFocus, isTrue);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_detailsActionFocusNode(tester, 'download-season').hasFocus, isTrue);
    final informationTray = tester.widget<Container>(
      find.byKey(const ValueKey('anime-details-more-menu')),
    );
    expect(informationTray.padding, const EdgeInsets.all(12));
    final episodePanel = tester.widget<Container>(
      find.byKey(const ValueKey('episode-actions-panel')),
    );
    expect(informationTray.decoration, episodePanel.decoration);
    final housing = informationTray.decoration! as BoxDecoration;
    expect(housing.borderRadius, BorderRadius.circular(TetoBoxStyle.radius));
    expect(housing.border, isNotNull);
    final housingGradient = housing.gradient! as LinearGradient;
    expect(housingGradient.begin, Alignment.topCenter);
    expect(housingGradient.end, Alignment.bottomCenter);
    expect(housingGradient.colors.first.a, closeTo(.78, .01));
    expect(housingGradient.colors.last.a, closeTo(.66, .01));
    final trailerSurface = tester.widget<Container>(
      find.byKey(const ValueKey('anime-details-watch-trailer-surface')),
    );
    expect(
      trailerSurface.decoration,
      TetoBoxStyle.decoration(
        tester
            .element(find.byKey(const ValueKey('anime-details-more-menu')))
            .appPalette,
      ),
    );
    final stableTrailerDecoration = trailerSurface.decoration;
    trailerFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Container>(
            find.byKey(const ValueKey('anime-details-watch-trailer-surface')),
          )
          .decoration,
      stableTrailerDecoration,
      reason: 'focus only adds the outer glow, not a new interior fill',
    );
    final focusGlow = tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const ValueKey('anime-details-watch-trailer')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final glowDecoration = focusGlow.decoration! as BoxDecoration;
    expect(glowDecoration.color, isNull);
    expect(glowDecoration.gradient, isNull);
    expect(glowDecoration.boxShadow, isNotEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
    final posterRect = tester.getRect(
      find.byKey(const ValueKey('anime-details-poster')),
    );
    final infoRect = tester.getRect(
      find.byKey(const ValueKey('anime-details-info')),
    );
    final actionsRect = tester.getRect(
      find.byKey(const ValueKey('episode-actions-panel')),
    );
    expect(actionsRect.top, greaterThan(0));
    expect(actionsRect.bottom, lessThan(1080));
    expect(actionsRect.center.dy, closeTo(540, 50));
    expect(posterRect.height / 1080, closeTo(.66, .01));
    expect(posterRect.right, lessThan(infoRect.left));
    expect(infoRect.right, lessThan(actionsRect.left));
    expect(actionsRect.right, lessThanOrEqualTo(1920));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'episode number picker validates range and selects a valid episode',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const anime = AnimeSummary(
        id: 13,
        title: 'Long Running Anime',
        description: 'A show where direct episode entry is useful.',
        episodes: 12,
        score: 8,
        status: 'RELEASING',
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
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 13)),
        ),
      );
      await tester.pumpAndSettle();

      await _openDetailsBrowser(tester);
      await tester.tap(find.byKey(const ValueKey('episode-manual-selector')));
      await tester.pumpAndSettle();
      expect(find.byType(TvKeyboardDialog), findsOneWidget);
      expect(find.text('Choose episode (1–12)'), findsOneWidget);

      await tester.tap(find.text('CLEAR'));
      await tester.tap(find.text('9'));
      await tester.tap(find.text('9'));
      await tester.tap(find.text('DONE'));
      await tester.pump();

      expect(find.byType(TvKeyboardDialog), findsOneWidget);
      expect(find.text('Enter an episode from 1 to 12.'), findsOneWidget);

      await tester.tap(find.text('CLEAR'));
      await tester.tap(find.text('4'));
      await tester.tap(find.text('DONE'));
      await tester.pumpAndSettle();

      expect(find.byType(TvKeyboardDialog), findsNothing);
      expect(find.text('Episode 4 of 12'), findsOneWidget);

      expect(
        find.byKey(const ValueKey('episode-step-previous')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('episode-step-next')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('episode-browser-card-4')));
      await tester.pumpAndSettle();
      expect(find.text('Play selected'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('episode-manual-selector')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Down reaches Browse Episodes and selection restores selector focus',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const anime = AnimeSummary(
        id: 130,
        title: 'Remote Episode Browser',
        description: '',
        episodes: 12,
        score: 8,
        status: 'RELEASING',
        durationMinutes: 24,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isTelevisionProvider.overrideWithValue(true),
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
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 130)),
        ),
      );
      await tester.pumpAndSettle();

      final browse = tester.widget<TvFocusable>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('episode-browser-prompt')),
              matching: find.byType(TvFocusable),
            )
            .first,
      );
      browse.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('episode-browser-page')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('episode-browser-card-4')));
      await tester.pumpAndSettle();
      expect(find.text('Play selected'), findsOneWidget);
      expect(browse.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(browse.focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Back closes the episode browser and restores middle focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const anime = AnimeSummary(
      id: 131,
      title: 'Episode Browser Back',
      description: '',
      episodes: 12,
      score: 8,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isTelevisionProvider.overrideWithValue(true),
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
        child: const MaterialApp(home: AnimeDetailsScreen(animeId: 131)),
      ),
    );
    await tester.pumpAndSettle();

    final selector = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find
                .ancestor(
                  of: find.byKey(const ValueKey('episode-browser-prompt')),
                  matching: find.byType(TvFocusable),
                )
                .first,
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    selector.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final browserTransition = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('episode-browser-transition')),
    );
    expect(browserTransition.duration, const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('episode-browser-overlay')),
      findsOneWidget,
    );
    expect(find.byType(BackdropFilter), findsNothing);
    final background = find.byKey(
      const ValueKey('episode-browser-artwork-blur'),
    );
    expect(tester.widget<ImageFiltered>(background).enabled, isTrue);
    expect(
      tester
          .widget<NetworkArtwork>(
            find.descendant(
              of: background,
              matching: find.byType(NetworkArtwork),
            ),
          )
          .cacheWidth,
      480,
    );
    await tester.pump(const Duration(milliseconds: 110));
    final openingFade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('episode-browser-overlay')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(openingFade.opacity.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('episode-browser-page')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('episode-browser-overlay')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('episode-browser-page')), findsNothing);
    expect(
      find.byKey(const ValueKey('episode-browser-artwork-blur')),
      findsNothing,
    );
    expect(selector.focusNode!.hasFocus, isTrue);
    expect(find.text('Episode 1 of 12'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'episode number picker is semantics-actionable and Back restores focus',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();

      const anime = AnimeSummary(
        id: 15,
        title: 'Accessible Episode Picker',
        description: 'A show with direct episode selection.',
        episodes: 12,
        score: 8,
        status: 'RELEASING',
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
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 15)),
        ),
      );
      await tester.pumpAndSettle();

      await _openDetailsBrowser(tester);
      final selector = find.semantics.byLabel(
        'Episode 1 of 12. Choose episode number',
      );
      expect(selector, findsOneWidget);
      final selectorFocus = tester.widget<FocusableActionDetector>(
        find
            .descendant(
              of: find.byKey(const ValueKey('episode-manual-selector')),
              matching: find.byType(FocusableActionDetector),
            )
            .first,
      );
      selectorFocus.focusNode!.requestFocus();
      await tester.pump();
      tester.semantics.tap(selector);
      await tester.pumpAndSettle();

      expect(find.byType(TvKeyboardDialog), findsOneWidget);
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pump();
      expect(find.byType(TvKeyboardDialog), findsOneWidget);
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pumpAndSettle();

      expect(find.byType(TvKeyboardDialog), findsNothing);
      expect(selectorFocus.focusNode?.hasFocus, isTrue);
      expect(find.byType(AnimeDetailsScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'manual episode selection preserves the polished unaired notice',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final anime = AnimeSummary(
        id: 14,
        title: 'Scheduled Anime',
        description: 'A currently airing series.',
        episodes: 24,
        score: 8,
        status: 'RELEASING',
        nextAiringEpisode: 13,
        nextAiringAt: DateTime.utc(2099, 9, 8, 12),
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
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 14)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data?.startsWith(
                    'Status: Releasing · next episode in ',
                  ) ??
                  false) &&
              (widget.data?.endsWith('September 8, 2099') ?? false),
        ),
        findsOneWidget,
      );
      await _openDetailsBrowser(tester);
      await tester.tap(find.byKey(const ValueKey('episode-manual-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CLEAR'));
      await tester.tap(find.byKey(const ValueKey('tv-keyboard-key-number-1')));
      await tester.tap(find.byKey(const ValueKey('tv-keyboard-key-number-3')));
      await tester.tap(find.text('DONE'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('episode-browser-card-13')));
      await tester.pumpAndSettle();

      expect(find.text('Episode 13 of 24'), findsNothing);
      expect(find.text('Episode 13 has not aired yet.'), findsOneWidget);
      expect(find.text('Expected air date: September 8, 2099'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('episode-action-selected')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selecting a scheduled unaired episode shows its date and skips prefetch',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final anime = AnimeSummary(
        id: 12,
        title: 'Weekly Anime',
        description: 'A currently airing series.',
        episodes: 24,
        score: 8,
        status: 'RELEASING',
        nextAiringEpisode: 2,
        nextAiringAt: DateTime.utc(2099, 9, 8, 12),
      );
      final prefetchedEpisodes = <int>[];

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
              prefetchedEpisodes.add(episode.episode);
              return EpisodeDiscoveryPrefetchHandle.completed();
            }),
          ],
          child: const MaterialApp(home: AnimeDetailsScreen(animeId: 12)),
        ),
      );
      await tester.pumpAndSettle();
      expect(prefetchedEpisodes, [1]);

      await _selectDetailsEpisode(tester, 2);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Episode 2 of 24'), findsNothing);
      expect(find.text('Episode 2 has not aired yet.'), findsOneWidget);
      expect(find.text('Expected air date: September 8, 2099'), findsOneWidget);
      expect(prefetchedEpisodes, [1]);
      expect(
        find.byKey(const ValueKey('episode-action-selected')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('future shows display a polished unreleased premiere state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final anime = AnimeSummary(
      id: 11,
      title: 'Future Anime',
      description: 'This series has not premiered yet.',
      episodes: 12,
      score: null,
      status: 'NOT_YET_RELEASED',
      seasonYear: 2100,
      startDate: DateTime(2100, 4, 6),
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

    expect(find.text('Unreleased'), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('anime-details-unreleased-status')),
        matching: find.text('Unreleased'),
      ),
      findsOneWidget,
    );
    expect(find.text('This series has not aired yet.'), findsOneWidget);
    expect(find.text('Expected premiere date: April 6, 2100'), findsOneWidget);
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
          .descendant(
            of: find.byType(TetoBackButton),
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
              isTelevisionProvider.overrideWithValue(false),
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
                .descendant(
                  of: find.byType(TetoBackButton),
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
              isTelevisionProvider.overrideWithValue(false),
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
        expect(find.text('Play from beginning'), findsNothing);
        expect(find.text('Play selected'), findsNothing);
        _expectInformationActionsHidden();
        expect(find.text('Episode 1 of 12'), findsNothing);
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
        await _openInformationMenu(tester);
        _expectCompactInformationMenu(tester, large: false);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(_detailsActionFocusNode(tester, 'more').hasFocus, isTrue);
        final browserPrompt = find.byKey(
          const ValueKey('episode-browser-prompt'),
        );
        expect(browserPrompt, findsOneWidget);
        if (size == const Size(390, 844)) {
          await tester.ensureVisible(browserPrompt);
          await tester.pumpAndSettle();
          await tester.fling(browserPrompt, const Offset(0, -80), 800);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('episode-browser-page')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

void _expectInformationActionsHidden() {
  for (final id in [
    'watch-trailer',
    'cast-crew',
    'related-series',
    'download-season',
  ]) {
    expect(find.byKey(ValueKey('anime-details-$id')), findsNothing);
  }
  expect(
    find.byKey(const ValueKey('anime-details-information-actions')),
    findsNothing,
  );
}

AnimeSummary _moreMenuAnime() => AnimeSummary(
  id: 57,
  title: 'Menu test',
  description: '',
  episodes: 12,
  score: null,
  staff: const [AnimePerson(id: 1, name: 'Director')],
  trailer: AnimeTrailer.tryCreate(provider: 'youtube', videoId: 'abcDEF_12-3'),
  relatedAnime: const [
    RelatedAnime(
      relationType: 'SEQUEL',
      anime: AnimeSummary(
        id: 58,
        title: 'Sequel',
        description: '',
        episodes: 12,
        score: null,
      ),
    ),
  ],
);

List<Override> _moreMenuOverrides(AnimeSummary anime) => [
  animeDetailsProvider.overrideWith((_, _) async => anime),
  trackingHomeProvider.overrideWith(
    (_) async =>
        const TrackingHomeData(watching: [], planToWatch: [], completed: []),
  ),
  settingsPreferencesProvider.overrideWith((_) => _LoadedSettingsController()),
];

FocusNode _detailsActionFocusNode(WidgetTester tester, String id) => tester
    .widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(ValueKey('anime-details-$id')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    )
    .focusNode!;

Future<void> _openInformationMenu(WidgetTester tester) async {
  final more = find.byKey(const ValueKey('anime-details-more'));
  await tester.ensureVisible(more);
  await tester.pumpAndSettle();
  _detailsActionFocusNode(tester, 'more').requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('anime-details-more-menu')), findsOneWidget);
}

void _expectCompactInformationMenu(
  WidgetTester tester, {
  required bool large,
  bool hasRelatedSeries = true,
}) {
  final menu = find.byKey(const ValueKey('anime-details-more-menu'));
  final menuRect = tester.getRect(menu);
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(menuRect.width, closeTo(large ? 340 : 300, .01));
  expect(menuRect.left, greaterThanOrEqualTo(16));
  expect(menuRect.right, lessThanOrEqualTo(viewport.width - 16));
  expect(menuRect.top, greaterThanOrEqualTo(16));
  expect(menuRect.bottom, lessThanOrEqualTo(viewport.height - 16));
  final rects = <Rect>[];
  for (final action in [
    ('Watch trailer', 'watch-trailer'),
    ('Cast & crew', 'cast-crew'),
    if (hasRelatedSeries) ('Related series', 'related-series'),
    ('Download season', 'download-season'),
  ]) {
    final box = tester.getRect(
      find.byKey(ValueKey('anime-details-${action.$2}-surface')),
    );
    rects.add(box);
    expect(box.height, greaterThanOrEqualTo(large ? 56 : 48));
    expect(menuRect.contains(box.topLeft), isTrue);
    expect(menuRect.contains(box.bottomRight), isTrue);
    final label = find.text(action.$1);
    expect(tester.widget<Text>(label).style?.fontSize, large ? 18 : 15);
    expect(
      tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
      isFalse,
    );
  }
  _expectVerticalInformationActions(rects, gap: 8);
  final scrollable = tester.state<ScrollableState>(
    find.descendant(of: menu, matching: find.byType(Scrollable)),
  );
  expect(scrollable.position.maxScrollExtent, 0);
}

void _expectVerticalInformationActions(
  List<Rect> actions, {
  required double gap,
}) {
  for (final action in actions) {
    expect(action.width, greaterThan(0));
    expect(action.height, closeTo(actions.first.height, .01));
  }
  for (var index = 1; index < actions.length; index++) {
    expect(actions[index].left, actions.first.left);
    expect(actions[index].width, actions.first.width);
    expect(actions[index].top - actions[index - 1].bottom, closeTo(gap, .01));
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

Future<void> _openDetailsBrowser(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey('episode-browser-prompt')),
  );
  await tester.tap(find.byKey(const ValueKey('episode-browser-prompt')));
  await tester.pumpAndSettle();
}

Future<void> _selectDetailsEpisode(WidgetTester tester, int episode) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey('episode-browser-prompt')),
  );
  await tester.tap(find.byKey(const ValueKey('episode-browser-prompt')));
  await tester.pump();
  tester
      .widget<EpisodeBrowserDialog>(find.byType(EpisodeBrowserDialog))
      .onEpisodeSelected!(episode);
  await tester.pump();
}
