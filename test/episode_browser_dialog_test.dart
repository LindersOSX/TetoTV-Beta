import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/catalog_episode_metadata.dart';
import 'package:anime_tv/features/catalog/presentation/episode_browser_dialog.dart';
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
  final focusable = find.descendant(
    of: find.byKey(ValueKey('episode-browser-card-$episode')),
    matching: find.byType(FocusableActionDetector),
  );
  return tester
          .widget<FocusableActionDetector>(focusable)
          .focusNode
          ?.hasFocus ==
      true;
}
