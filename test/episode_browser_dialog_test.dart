import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/catalog_episode_metadata.dart';
import 'package:anime_tv/features/catalog/presentation/episode_browser_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('header arrows keep focus, cross pages, and clamp at the end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: EpisodeBrowserDialog(
          anime: const AnimeSummary(
            id: 990,
            title: 'Header navigation',
            description: '',
            episodes: 13,
            score: null,
          ),
          selectedEpisode: 6,
          totalEpisodes: 13,
          embedded: true,
          onEpisodeSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final next = tester.widget<TvFocusable>(
      find.byKey(const ValueKey('episode-step-next')),
    );
    next.focusNode!.requestFocus();
    await tester.pump();
    for (var i = 7; i <= 13; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Episode $i of 13'), findsOneWidget);
      if (i < 13) expect(next.focusNode!.hasFocus, isTrue);
    }
    expect(
      find.byKey(const ValueKey('episode-browser-card-13')),
      findsOneWidget,
    );
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'episode-browser.number',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_cardHasFocus(tester, 13), isTrue);
    expect(tester.takeException(), isNull);
  });
  for (final palette in [
    AppThemePalette.defaults,
    AppThemePalette.fromSeeds(
      background: const Color(0xFF0B1320),
      surface: const Color(0xFF172535),
      accent: const Color(0xFF00B8CC),
      primaryText: Colors.white,
      mutedText: const Color(0xFFACBACC),
    ),
  ]) {
    testWidgets('episode carousel shares glass controls and outer-only focus '
        '${palette.accent}', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: const EpisodeBrowserDialog(
            anime: AnimeSummary(
              id: 902,
              title: 'Uniform carousel',
              description: '',
              episodes: 24,
              score: null,
            ),
            selectedEpisode: 1,
            totalEpisodes: 24,
            isTelevision: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      BoxDecoration surface(String key) =>
          tester.widget<Container>(find.byKey(ValueKey(key))).decoration!
              as BoxDecoration;
      expect(
        surface('episode-browser-surface'),
        TetoBoxStyle.translucentPanelDecoration(palette),
      );
      expect(
        surface('episode-browser-header'),
        TetoBoxStyle.translucentPanelDecoration(palette),
      );
      expect(
        surface('episode-browser-pagination'),
        TetoBoxStyle.translucentPanelDecoration(palette),
      );
      final resting = surface('episode-browser-card-surface-2');
      expect(resting, TetoBoxStyle.translucentControlDecoration(palette));
      _cardFocusNode(tester, 2).requestFocus();
      await tester.pumpAndSettle();
      expect(surface('episode-browser-card-surface-2'), resting);
      final focusFrame = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byKey(const ValueKey('episode-browser-card-2')),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final outline = focusFrame.foregroundDecoration! as BoxDecoration;
      expect(outline.color, Colors.transparent);
      expect(outline.border!.top.color, palette.focusRing);
      final glow = focusFrame.decoration! as BoxDecoration;
      expect(glow.boxShadow!.last.color, palette.focusGlow);
      final selectedPage = surface('episode-page-surface-1');
      final otherPage = surface('episode-page-surface-2');
      expect(selectedPage.gradient, otherPage.gradient);
      expect(selectedPage.border!.top.color, palette.accentBright);
      final pageControl = tester.widget<TvFocusable>(
        find.descendant(
          of: find.byKey(const ValueKey('episode-browser-page-button-0')),
          matching: find.byType(TvFocusable),
        ),
      );
      expect(
        pageControl.borderRadius,
        BorderRadius.circular(TetoBoxStyle.radius),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_cardHasFocus(tester, 4), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(_cardHasFocus(tester, 9), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('episode browser presents two columns and three rows per page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int? selectedEpisode;
    const anime = AnimeSummary(
      id: 901,
      title: 'Episode Browser Show',
      description: 'Series synopsis must not be reused for an episode.',
      episodes: 1184,
      score: 8,
      durationMinutes: 24,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                selectedEpisode = await showEpisodeBrowserDialog(
                  context,
                  anime: anime,
                  selectedEpisode: 1,
                  totalEpisodes: 1184,
                );
              },
              child: const Text('Browse'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('episode-browser-dialog')),
      findsOneWidget,
    );
    for (var episode = 1; episode <= 6; episode++) {
      expect(
        find.byKey(ValueKey('episode-browser-card-$episode')),
        findsOneWidget,
      );
    }
    expect(find.byKey(const ValueKey('episode-browser-card-7')), findsNothing);
    final first = tester.getRect(
      find.byKey(const ValueKey('episode-browser-card-1')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('episode-browser-card-2')),
    );
    final third = tester.getRect(
      find.byKey(const ValueKey('episode-browser-card-3')),
    );
    final fifth = tester.getRect(
      find.byKey(const ValueKey('episode-browser-card-5')),
    );
    expect(second.top, closeTo(first.top, .01));
    expect(second.left, greaterThan(first.left));
    expect(third.top, greaterThan(first.top));
    expect(third.left, closeTo(first.left, .01));
    expect(fifth.top, greaterThan(third.top));
    expect(fifth.left, closeTo(first.left, .01));
    expect(find.text('Episode details unavailable.'), findsWidgets);
    expect(find.textContaining('24 min'), findsWidgets);
    expect(
      find.byKey(const ValueKey('episode-browser-page-ellipsis-4')),
      findsOneWidget,
    );
    expect(find.text('198'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('episode-browser-next-page')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('episode-browser-card-1')), findsNothing);
    expect(
      find.byKey(const ValueKey('episode-browser-card-7')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-browser-card-12')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('episode-browser-card-12')));
    await tester.pumpAndSettle();
    expect(selectedEpisode, 12);
    expect(find.byKey(const ValueKey('episode-browser-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D-pad pages at horizontal edges and preserves the row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: EpisodeBrowserDialog(
          anime: const AnimeSummary(
            id: 904,
            title: 'Remote Show',
            description: '',
            episodes: 24,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 24,
          isTelevision: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var press = 0; press < 2; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }

    expect(
      find.byKey(const ValueKey('episode-browser-card-7')),
      findsOneWidget,
    );
    expect(_cardHasFocus(tester, 7), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('episode-browser-card-2')),
      findsOneWidget,
    );
    expect(_cardHasFocus(tester, 2), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_cardHasFocus(tester, 4), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('episode-browser-card-9')),
      findsOneWidget,
    );
    expect(_cardHasFocus(tester, 9), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards use episode metadata and keep honest fallbacks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: EpisodeBrowserDialog(
          anime: const AnimeSummary(
            id: 905,
            title: 'Metadata Show',
            description: 'Series text must never be shown as episode text.',
            episodes: 2,
            score: null,
            durationMinutes: 24,
            bannerImageUrl: 'https://images.example/series-banner.jpg',
          ),
          selectedEpisode: 1,
          totalEpisodes: 2,
          episodeMetadataFuture:
              Future.value(const <int, CatalogEpisodeMetadata>{
                1: CatalogEpisodeMetadata(
                  episode: 1,
                  title: 'Asteroid Blues',
                  thumbnailUrl: 'https://images.example/episode-1.jpg',
                  synopsis: 'Spike follows a dangerous bounty.',
                  durationMinutes: 25,
                ),
              }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Asteroid Blues'), findsOneWidget);
    expect(find.text('Spike follows a dangerous bounty.'), findsOneWidget);
    expect(find.textContaining('25 min'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('episode-browser-selected-1')),
      findsOneWidget,
    );
    _cardFocusNode(tester, 2).requestFocus();
    await tester.pump();
    expect(_cardHasFocus(tester, 2), isTrue);
    expect(
      find.byKey(const ValueKey('episode-browser-selected-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-browser-selected-2')),
      findsNothing,
    );
    final firstArtwork = tester.widget<NetworkArtwork>(
      find.descendant(
        of: find.byKey(const ValueKey('episode-browser-card-1')),
        matching: find.byType(NetworkArtwork),
      ),
    );
    expect(firstArtwork.url, 'https://images.example/episode-1.jpg');
    expect(firstArtwork.fit, BoxFit.contain);
    final secondArtwork = tester.widget<NetworkArtwork>(
      find.descendant(
        of: find.byKey(const ValueKey('episode-browser-card-2')),
        matching: find.byType(NetworkArtwork),
      ),
    );
    expect(secondArtwork.url, 'https://images.example/series-banner.jpg');
    expect(find.text('SERIES ART'), findsOneWidget);
    expect(find.text('Episode details unavailable.'), findsOneWidget);
    expect(
      find.text('Series text must never be shown as episode text.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('embedded browser uses the shared episode-page surface', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: EpisodeBrowserDialog(
          anime: const AnimeSummary(
            id: 908,
            title: 'Animated Episodes',
            description: '',
            episodes: 2,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 2,
          embedded: true,
          onClose: () {},
          onEpisodeSelected: (_) {},
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('episode-browser-header')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('episode-browser-close')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('episode-browser-open-animation')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('episode-browser-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('redesigned cards and paging fit a phone-sized screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const EpisodeBrowserDialog(
          anime: AnimeSummary(
            id: 910,
            title: 'Phone Episodes',
            description: '',
            episodes: 12,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 12,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('episode-browser-header')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-browser-card-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-browser-card-3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('episode-browser-card-4')), findsNothing);
    expect(
      find.byKey(const ValueKey('episode-browser-pagination')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('page changes use a short directional transition', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const EpisodeBrowserDialog(
          anime: AnimeSummary(
            id: 909,
            title: 'Paged Episodes',
            description: '',
            episodes: 12,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 12,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('episode-browser-page-transition')),
    );
    expect(switcher.duration, const Duration(milliseconds: 120));
    await tester.tap(find.byKey(const ValueKey('episode-browser-next-page')));
    await tester.pump();
    expect(find.byKey(const ValueKey('episode-browser-page-0')), findsNothing);
    expect(
      find.byKey(const ValueKey('episode-browser-page-1')),
      findsOneWidget,
    );
    expect(find.byType(GridView), findsOneWidget);
    expect(_cardHasFocus(tester, 7), isTrue);
    // Navigation works during the entrance, without waiting for its scale or
    // slide to settle and without an outgoing grid competing for focus.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 16));
    expect(_cardHasFocus(tester, 9), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 16));
    expect(_cardHasFocus(tester, 10), isTrue);
    await tester.pump(const Duration(milliseconds: 28));
    final incoming = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('episode-browser-page-1')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(incoming.opacity.value, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('episode-browser-page-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus motion isolates artwork and uses display-sized decodes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const EpisodeBrowserDialog(
          anime: AnimeSummary(
            id: 917,
            title: 'Lightweight Episodes',
            description: '',
            episodes: 12,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 12,
          isTelevision: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final content = find.byKey(
      const ValueKey('episode-browser-card-content-2'),
    );
    expect(tester.widget(content), isA<RepaintBoundary>());
    expect(
      tester.widget(find.byKey(const ValueKey('episode-browser-artwork-2'))),
      isA<RepaintBoundary>(),
    );
    final artworkFinder = find.descendant(
      of: content,
      matching: find.byType(NetworkArtwork),
    );
    final artwork = tester.widget<NetworkArtwork>(artworkFinder);
    final renderedWidth = tester.getSize(artworkFinder).width;
    expect(artwork.cacheWidth, greaterThanOrEqualTo(renderedWidth));
    expect(artwork.cacheWidth, lessThan(320));
    _cardFocusNode(tester, 2).requestFocus();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.widget<NetworkArtwork>(artworkFinder), same(artwork));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'only a focused card description scrolls after three seconds and resets',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const longSynopsis =
          'A patient investigation carries the crew across the entire city '
          'while each new clue changes what they know about the missing ship. '
          'Old allies return, hidden motives surface, and the team must decide '
          'who they can trust before the final signal disappears forever. '
          'The journey continues through several districts so every important '
          'detail has enough room to be presented to the viewer.';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const EpisodeBrowserDialog(
            anime: AnimeSummary(
              id: 909,
              title: 'Scrolling Episodes',
              description: '',
              episodes: 2,
              score: null,
            ),
            selectedEpisode: 1,
            totalEpisodes: 2,
            episodeMetadata: <int, CatalogEpisodeMetadata>{
              1: CatalogEpisodeMetadata(
                episode: 1,
                title: 'The Title Must Stay Still',
                synopsis: longSynopsis,
              ),
              2: CatalogEpisodeMetadata(
                episode: 2,
                title: 'A Short Follow-up',
                synopsis: 'A short description.',
              ),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final descriptionController = _descriptionController(tester, 1);
      expect(descriptionController.position.maxScrollExtent, greaterThan(0));
      final titleTop = tester.getTopLeft(
        find.byKey(const ValueKey('episode-browser-title-1')),
      );
      final descriptionTop = tester.getTopLeft(
        find.byKey(const ValueKey('episode-browser-description-1')),
      );

      await tester.pump(const Duration(milliseconds: 2999));
      expect(descriptionController.offset, 0);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(descriptionController.offset, greaterThan(0));
      expect(
        descriptionController.offset,
        lessThan(descriptionController.position.maxScrollExtent),
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('episode-browser-description-1')),
            )
            .dy,
        lessThan(descriptionTop.dy),
      );
      expect(
        tester.getTopLeft(
          find.byKey(const ValueKey('episode-browser-title-1')),
        ),
        titleTop,
      );

      await tester.pump(const Duration(minutes: 1));
      expect(
        descriptionController.offset,
        closeTo(descriptionController.position.maxScrollExtent, .01),
      );

      _cardFocusNode(tester, 2).requestFocus();
      await tester.pump();
      expect(descriptionController.offset, 0);
      await tester.pump(const Duration(seconds: 4));
      expect(descriptionController.offset, 0);

      _cardFocusNode(tester, 1).requestFocus();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      _cardFocusNode(tester, 2).requestFocus();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(descriptionController.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion keeps the focused synopsis still', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const synopsis =
        'A deliberately long accessible synopsis fills enough lines to exceed '
        'the visible card. It should remain completely still when the device '
        'has disabled animations, even after the normal three second delay. '
        'The complete text remains available to assistive technology.';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const EpisodeBrowserDialog(
              anime: AnimeSummary(
                id: 912,
                title: 'Reduced Motion Episodes',
                description: '',
                episodes: 1,
                score: null,
              ),
              selectedEpisode: 1,
              totalEpisodes: 1,
              episodeMetadata: <int, CatalogEpisodeMetadata>{
                1: CatalogEpisodeMetadata(
                  episode: 1,
                  title: 'An Accessible Episode',
                  synopsis: synopsis,
                ),
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final descriptionController = _descriptionController(tester, 1);
    expect(descriptionController.position.maxScrollExtent, greaterThan(0));
    expect(_cardHasFocus(tester, 1), isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(descriptionController.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('episode card semantics include the complete synopsis', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const synopsis =
        'Every word of this synopsis should be spoken by TalkBack.';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const EpisodeBrowserDialog(
          anime: AnimeSummary(
            id: 913,
            title: 'Semantic Episodes',
            description: '',
            episodes: 1,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 1,
          episodeMetadata: <int, CatalogEpisodeMetadata>{
            1: CatalogEpisodeMetadata(
              episode: 1,
              title: 'The Spoken Episode',
              synopsis: synopsis,
            ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final semanticsWidgets = tester.widgetList<Semantics>(
      find.descendant(
        of: find.byKey(const ValueKey('episode-browser-card-1')),
        matching: find.byType(Semantics),
      ),
    );
    expect(
      semanticsWidgets.any(
        (widget) => widget.properties.label?.contains(synopsis) ?? false,
      ),
      isTrue,
    );
    semanticsHandle.dispose();
  });

  testWidgets('pointer hover and touch focus start the description delay', (
    tester,
  ) async {
    final previousHighlightStrategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy = previousHighlightStrategy,
    );
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const longSynopsis =
        'This deliberately long episode description provides enough text to '
        'overflow the synopsis viewport. It keeps adding context about the '
        'characters, their route, their discoveries, and their eventual plan '
        'so the automatic upward movement is observable in this focused test.';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: EpisodeBrowserDialog(
          anime: const AnimeSummary(
            id: 910,
            title: 'Pointer Episodes',
            description: '',
            episodes: 2,
            score: null,
          ),
          selectedEpisode: 2,
          totalEpisodes: 2,
          embedded: true,
          episodeMetadata: const <int, CatalogEpisodeMetadata>{
            1: CatalogEpisodeMetadata(
              episode: 1,
              title: 'Pointer Target',
              synopsis: longSynopsis,
            ),
          },
          onClose: () {},
          onEpisodeSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final descriptionController = _descriptionController(tester, 1);
    expect(descriptionController.position.maxScrollExtent, greaterThan(0));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('episode-browser-card-1'))),
    );
    await tester.pump();
    expect(_cardHasFocus(tester, 1), isTrue);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(descriptionController.offset, greaterThan(0));

    await mouse.moveTo(Offset.zero);
    _cardFocusNode(tester, 2).requestFocus();
    await tester.pump();
    expect(descriptionController.offset, 0);

    await tester.tap(find.byKey(const ValueKey('episode-browser-card-1')));
    await tester.pump();
    expect(_cardHasFocus(tester, 1), isTrue);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(descriptionController.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing a focused card cancels its delayed scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const EpisodeBrowserDialog(
          anime: AnimeSummary(
            id: 911,
            title: 'Disposable Episodes',
            description: '',
            episodes: 1,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 1,
          episodeMetadata: <int, CatalogEpisodeMetadata>{
            1: CatalogEpisodeMetadata(
              episode: 1,
              title: 'A Focused Episode',
              synopsis: 'A description that will never start scrolling.',
            ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_cardHasFocus(tester, 1), isTrue);
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('embedded browser reaches number control above the first row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: EpisodeBrowserDialog(
          anime: const AnimeSummary(
            id: 907,
            title: 'Integrated Episodes',
            description: '',
            episodes: 12,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 12,
          isTelevision: true,
          embedded: true,
          onClose: () => closed = true,
          onEpisodeSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_cardHasFocus(tester, 1), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(closed, isFalse);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'episode-browser.number',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('edge paging clamps focus on a short final TV page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const EpisodeBrowserDialog(
          anime: AnimeSummary(
            id: 906,
            title: 'Ten Episode Show',
            description: '',
            episodes: 10,
            score: null,
          ),
          selectedEpisode: 6,
          totalEpisodes: 10,
          isTelevision: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_cardHasFocus(tester, 6), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('episode-browser-card-9')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-browser-card-10')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('episode-browser-card-11')), findsNothing);
    expect(_cardHasFocus(tester, 10), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browser marks known unaired episodes without inventing dates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final anime = AnimeSummary(
      id: 902,
      title: 'Weekly Show',
      description: '',
      episodes: 24,
      score: null,
      status: 'RELEASING',
      durationMinutes: 23,
      nextAiringEpisode: 13,
      nextAiringAt: DateTime(2099, 9, 8, 12),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: EpisodeBrowserDialog(
          anime: anime,
          selectedEpisode: 13,
          totalEpisodes: 24,
          now: DateTime(2099, 9, 1, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('episode-browser-card-13')),
      findsOneWidget,
    );
    expect(find.text('September 8, 2099'), findsOneWidget);
    expect(find.textContaining('Next episode in 7 days'), findsOneWidget);
    // Only the immediate next episode has an authoritative date. Later
    // future episodes stay clearly unavailable without borrowing that date.
    expect(find.text('UNAIRED'), findsWidgets);
    expect(find.text('This episode has not aired yet.'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a one-page episode browser does not render pagination', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const EpisodeBrowserDialog(
          anime: AnimeSummary(
            id: 903,
            title: 'Short Show',
            description: '',
            episodes: 4,
            score: null,
          ),
          selectedEpisode: 1,
          totalEpisodes: 4,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('episode-browser-card-4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-browser-pagination')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

bool _cardHasFocus(WidgetTester tester, int episode) {
  return _cardFocusNode(tester, episode).hasFocus;
}

FocusableActionDetector _cardFocusable(WidgetTester tester, int episode) {
  final focusable = find.descendant(
    of: find.byKey(ValueKey('episode-browser-card-$episode')),
    matching: find.byType(FocusableActionDetector),
  );
  return tester.widget<FocusableActionDetector>(focusable);
}

FocusNode _cardFocusNode(WidgetTester tester, int episode) {
  return _cardFocusable(tester, episode).focusNode!;
}

ScrollController _descriptionController(WidgetTester tester, int episode) {
  return tester
      .widget<SingleChildScrollView>(
        find.byKey(ValueKey('episode-browser-description-scroll-$episode')),
      )
      .controller!;
}
