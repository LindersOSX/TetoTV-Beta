import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes AniList and MyAnimeList airing states', () {
    expect(animeAiringStatusLabel('RELEASING'), 'AIRING');
    expect(animeAiringStatusLabel('currently_airing'), 'AIRING');
    expect(animeAiringStatusLabel('FINISHED'), 'FINISHED');
    expect(animeAiringStatusLabel('finished_airing'), 'FINISHED');
    expect(animeAiringStatusLabel('NOT_YET_RELEASED'), 'UNRELEASED');
    expect(animeAiringStatusLabel('not yet aired'), 'UNRELEASED');
    expect(animeAiringStatusLabel('upcoming'), 'UNRELEASED');
  });

  testWidgets('renders a compact status badge over poster art', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PosterAiringStatusBadge(status: 'RELEASING')),
      ),
    );

    expect(find.text('AIRING'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders an unreleased badge for future anime', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PosterAiringStatusBadge(status: 'NOT_YET_RELEASED'),
        ),
      ),
    );

    expect(find.text('UNRELEASED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
