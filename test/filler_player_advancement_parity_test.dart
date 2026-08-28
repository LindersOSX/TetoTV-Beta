import 'dart:io';

import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/streaming/application/next_episode_preparation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nextAiring marks N + 1 unavailable to completion fallback', () {
    const details = AnimeSummary(
      id: 7,
      title: 'Airing Show',
      description: '',
      episodes: 12,
      score: null,
      nextAiringEpisode: 6,
    );

    expect(isEpisodeAvailableForPlayback(details, 5), isTrue);
    expect(isEpisodeAvailableForPlayback(details, 6), isFalse);
  });

  test('MPV next episode uses the shared fail-open filler flow', () {
    final source = File(
      'lib/features/player/presentation/tv_player_screen.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> _playNextEpisode() async');
    expect(start, greaterThanOrEqualTo(0));
    final tail = source.substring(start);
    final end = tail.indexOf('\n  Future<void> ', 40);
    final method = end < 0 ? tail : tail.substring(0, end);

    expect(
      method,
      contains(
        'final details = await ref.read(animeDetailsProvider(mediaId).future)',
      ),
    );
    expect(
      method,
      contains(
        'final fillerRepository = ref.read(fillerEpisodeRepositoryProvider)',
      ),
    );
    expect(method, contains('final skipFillerEpisodes ='));
    expect(method, contains('if (!mounted) return;'));
    expect(method, contains('episodeNavigationCeiling('));
    expect(method, contains('resolveFillerEpisodeNavigation('));
    expect(method, contains('repository: fillerRepository'));
    expect(method, contains('skipEnabled: skipFillerEpisodes'));
    expect(method, contains('showFillerSkipNotification(context, decision)'));
    expect(
      RegExp(
        r'unawaited\(\s*showFillerSkipNotification\(context, decision\)',
      ).hasMatch(method),
      isTrue,
    );
    expect(
      method,
      isNot(contains('await showFillerSkipNotification(context, decision)')),
    );
    expect(RegExp(r'next(?:Ep|Episode) == null').hasMatch(method), isTrue);
    expect(
      RegExp(
        r'isEpisodeAvailableForPlayback\(details, [^)]+\)',
      ).allMatches(method).length,
      greaterThanOrEqualTo(2),
      reason: 'MPV must guard both requested and filler-skipped episodes',
    );

    final firstRefRead = method.indexOf('ref.read(');
    final entryMountedGuard = method.indexOf('if (!mounted');
    final repositoryCapture = method.indexOf(
      'final fillerRepository = ref.read(fillerEpisodeRepositoryProvider)',
    );
    final firstAwait = method.indexOf(
      'await ref.read(animeDetailsProvider(mediaId).future)',
    );
    final mountedGuard = method.indexOf('if (!mounted) return;', firstAwait);
    final fillerLookup = method.indexOf('resolveFillerEpisodeNavigation(');
    expect(entryMountedGuard, greaterThanOrEqualTo(0));
    expect(entryMountedGuard, lessThan(firstRefRead));
    expect(repositoryCapture, lessThan(firstAwait));
    expect(mountedGuard, greaterThan(firstAwait));
    expect(mountedGuard, lessThan(fillerLookup));
  });
}
