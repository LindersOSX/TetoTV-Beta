import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/episode_browser_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('large TV browser presents a paged four-by-four episode grid', (
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
    for (var episode = 1; episode <= 16; episode++) {
      expect(
        find.byKey(ValueKey('episode-browser-card-$episode')),
        findsOneWidget,
      );
    }
    expect(find.byKey(const ValueKey('episode-browser-card-17')), findsNothing);
    final first = tester.getRect(
      find.byKey(const ValueKey('episode-browser-card-1')),
    );
    final fourth = tester.getRect(
      find.byKey(const ValueKey('episode-browser-card-4')),
    );
    final fifth = tester.getRect(
      find.byKey(const ValueKey('episode-browser-card-5')),
    );
    expect(fourth.top, closeTo(first.top, .01));
    expect(fourth.left, greaterThan(first.left));
    expect(fifth.top, greaterThan(first.top));
    expect(fifth.left, closeTo(first.left, .01));
    expect(find.text('Episode synopsis unavailable.'), findsWidgets);
    expect(find.text('24 min'), findsWidgets);
    expect(
      find.byKey(const ValueKey('episode-browser-page-ellipsis-4')),
      findsOneWidget,
    );
    expect(find.text('74'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('episode-browser-next-page')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('episode-browser-card-1')), findsNothing);
    expect(
      find.byKey(const ValueKey('episode-browser-card-17')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-browser-card-32')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('episode-browser-card-20')));
    await tester.pumpAndSettle();
    expect(selectedEpisode, 20);
    expect(find.byKey(const ValueKey('episode-browser-dialog')), findsNothing);
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
          now: DateTime(2099, 9, 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('episode-browser-card-13')),
      findsOneWidget,
    );
    expect(find.text('September 8, 2099'), findsOneWidget);
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
