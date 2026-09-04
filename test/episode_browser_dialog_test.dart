import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/catalog_episode_metadata.dart';
import 'package:anime_tv/features/catalog/presentation/episode_browser_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  testWidgets('embedded browser opens with a restrained fade and lift', (
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

    final animation = tester.widget<TweenAnimationBuilder<double>>(
      find.byKey(const ValueKey('episode-browser-open-animation')),
    );
    expect(animation.duration, const Duration(milliseconds: 160));
    expect(animation.curve, Curves.easeOutCubic);

    final initialOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('episode-browser-open-opacity')),
    );
    final initialSlide = tester.widget<Transform>(
      find.byKey(const ValueKey('episode-browser-open-slide')),
    );
    expect(initialOpacity.opacity, 0);
    expect(initialSlide.transform.getTranslation().y, 10);

    await tester.pump(const Duration(milliseconds: 80));
    final midOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('episode-browser-open-opacity')),
    );
    final midSlide = tester.widget<Transform>(
      find.byKey(const ValueKey('episode-browser-open-slide')),
    );
    expect(midOpacity.opacity, inExclusiveRange(0, 1));
    expect(midSlide.transform.getTranslation().y, inExclusiveRange(0, 10));

    await tester.pump(const Duration(milliseconds: 80));
    final finalOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('episode-browser-open-opacity')),
    );
    final finalSlide = tester.widget<Transform>(
      find.byKey(const ValueKey('episode-browser-open-slide')),
    );
    expect(finalOpacity.opacity, 1);
    expect(finalSlide.transform.getTranslation().y, 0);
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

  testWidgets('embedded browser exits upward from its first visible row', (
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

    expect(closed, isTrue);
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
