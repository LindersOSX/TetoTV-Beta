import 'dart:async';

import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:anime_tv/features/player/application/filler_episode_navigation.dart';
import 'package:anime_tv/features/player/presentation/filler_skip_notification.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  final identity = FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 20);

  test('disabled skip never performs a filler lookup', () async {
    final repository = _FakeFillerRepository(
      FillerEpisodeLookup.confirmed(
        confirmedFillerEpisodes: {2},
        source: FillerDataSource.jikanMalId,
        resolvedMalMediaId: 20,
        fetchedAt: DateTime.utc(2026),
        knownEpisodeCount: 12,
      ),
    );

    final decision = await resolveFillerEpisodeNavigation(
      repository: repository,
      identity: identity,
      requestedEpisode: 2,
      totalEpisodes: 12,
      skipEnabled: false,
    );

    expect(repository.lookups, 0);
    expect(decision.episode, 2);
    expect(decision.skippedEpisodes, isEmpty);
    expect(decision.dataUnavailable, isFalse);
  });

  test('unavailable or ambiguous data fails open', () async {
    final repository = _FakeFillerRepository(
      FillerEpisodeLookup.unavailable(
        reason: FillerUnavailableReason.ambiguousTitle,
      ),
    );

    final decision = await resolveFillerEpisodeNavigation(
      repository: repository,
      identity: identity,
      requestedEpisode: 2,
      totalEpisodes: 12,
      skipEnabled: true,
    );

    expect(repository.lookups, 1);
    expect(decision.episode, 2);
    expect(decision.skippedEpisodes, isEmpty);
    expect(decision.dataUnavailable, isTrue);
  });

  test(
    'manual selected playback skips a confirmed contiguous filler range',
    () async {
      final repository = _FakeFillerRepository(
        FillerEpisodeLookup.confirmed(
          confirmedFillerEpisodes: {2, 3, 4, 9},
          source: FillerDataSource.jikanMalId,
          resolvedMalMediaId: 20,
          fetchedAt: DateTime.utc(2026),
          knownEpisodeCount: 12,
        ),
      );

      final decision = await resolveFillerEpisodeNavigation(
        repository: repository,
        identity: identity,
        requestedEpisode: 2,
        totalEpisodes: 12,
        skipEnabled: true,
      );

      expect(decision.episode, 5);
      expect(decision.skippedEpisodes, [2, 3, 4]);
      expect(fillerEpisodeListLabel(decision.skippedEpisodes), 'Episodes 2–4');
      expect(fillerEpisodeListLabel([2, 3, 7, 9, 10]), 'Episodes 2–3, 7, 9–10');
    },
  );

  test('does not navigate when every remaining episode is filler', () {
    final decision = decideFillerEpisodeNavigation(
      requestedEpisode: 11,
      totalEpisodes: 12,
      skipEnabled: true,
      canAutoSkip: true,
      confirmedFillerEpisodes: {11, 12},
    );

    expect(decision.episode, isNull);
    expect(decision.skippedEpisodes, [11, 12]);
  });

  test('does not jump beyond currently confirmed episode metadata', () async {
    final repository = _FakeFillerRepository(
      FillerEpisodeLookup.confirmed(
        confirmedFillerEpisodes: {
          for (var episode = 3; episode <= 12; episode++) episode,
        },
        source: FillerDataSource.jikanMalId,
        resolvedMalMediaId: 20,
        fetchedAt: DateTime.utc(2026),
        knownEpisodeCount: 12,
      ),
    );

    final decision = await resolveFillerEpisodeNavigation(
      repository: repository,
      identity: identity,
      requestedEpisode: 3,
      totalEpisodes: 24,
      skipEnabled: true,
    );

    expect(decision.episode, 3);
    expect(decision.skippedEpisodes, isEmpty);
    expect(decision.dataUnavailable, isTrue);
  });

  test('episode ceiling remains valid beyond episode 999', () {
    expect(episodeNavigationCeiling(requestedEpisode: 1001), 1001);
    expect(
      episodeNavigationCeiling(requestedEpisode: 1001, nextAiringEpisode: 1010),
      1009,
    );
    expect(
      episodeNavigationCeiling(
        requestedEpisode: 1001,
        declaredTotalEpisodes: 1200,
      ),
      1200,
    );
  });

  test('repository exceptions fail open', () async {
    final decision = await resolveFillerEpisodeNavigation(
      repository: _ThrowingFillerRepository(),
      identity: identity,
      requestedEpisode: 7,
      totalEpisodes: 12,
      skipEnabled: true,
    );

    expect(decision.episode, 7);
    expect(decision.skippedEpisodes, isEmpty);
    expect(decision.dataUnavailable, isTrue);
  });

  test('unavailable notice state is retained once per series', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final state = container.read(fillerUnavailableNotifiedSeriesProvider);
    expect(state, isEmpty);
    container.read(fillerUnavailableNotifiedSeriesProvider.notifier).state = {
      ...state,
      1,
    };

    expect(container.read(fillerUnavailableNotifiedSeriesProvider), {1});
  });

  testWidgets('skip notice names the range without blocking replacement', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () {
                unawaited(
                  showFillerSkipNotification(
                    context,
                    const FillerEpisodeNavigationDecision(
                      episode: 5,
                      skippedEpisodes: [2, 3, 4],
                    ),
                  ),
                );
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Episode 5')),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(
      find.text('Skipped filler Episodes 2–4. Playing Episode 5.'),
      findsOneWidget,
    );
    expect(find.text('Episode 5'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Continue'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

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

class _ThrowingFillerRepository implements FillerEpisodeRepository {
  @override
  Future<FillerEpisodeLookup> lookup(
    FillerSeriesIdentity identity, {
    bool forceRefresh = false,
  }) => throw StateError('offline');
}
