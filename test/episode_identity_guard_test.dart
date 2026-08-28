import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('free-form episode identity', () {
    test('uses numeric boundaries instead of substring matching', () {
      expect(
        _label('Show Episode 1', episode: 1).verdict,
        EpisodeIdentityVerdict.match,
      );
      expect(
        _label('Show Episode 10', episode: 1).verdict,
        EpisodeIdentityVerdict.mismatch,
      );
      expect(
        _label('Show Episode 1', episode: 10).verdict,
        EpisodeIdentityVerdict.mismatch,
      );
    });

    test('recognizes season/episode forms and bounded batches', () {
      expect(
        _label('Show S02E10.mkv', episode: 10, season: 2).verdict,
        EpisodeIdentityVerdict.match,
      );
      expect(
        _label('Show 2x10.mkv', episode: 10, season: 2).verdict,
        EpisodeIdentityVerdict.match,
      );
      expect(
        _label('Show S01E01-12 [1080p]', episode: 10, season: 1).verdict,
        EpisodeIdentityVerdict.match,
      );
      expect(
        _label('Show S01E01-12 [1080p]', episode: 13, season: 1).verdict,
        EpisodeIdentityVerdict.mismatch,
      );
      expect(
        _label('Show S01E01-12 [1080p]', episode: 10, season: 2).reasonCode,
        'season_number_mismatch',
      );
    });

    test('allows explicit long-running episode numbers', () {
      expect(
        _label('Long Show Episode 720', episode: 720).verdict,
        EpisodeIdentityVerdict.match,
      );
      expect(
        _label('Long Show E720.mkv', episode: 720).verdict,
        EpisodeIdentityVerdict.match,
      );
    });

    test(
      'later-season bare numbers remain ambiguous without a season marker',
      () {
        expect(
          _label('My Hero Academia - 88.mkv', episode: 25, season: 4),
          isA<EpisodeIdentityAssessment>()
              .having(
                (assessment) => assessment.verdict,
                'verdict',
                EpisodeIdentityVerdict.unknown,
              )
              .having(
                (assessment) => assessment.reasonCode,
                'reasonCode',
                'season_local_or_absolute_ambiguous',
              ),
        );
        expect(
          _label('My Hero Academia S04E25.mkv', episode: 25, season: 4).verdict,
          EpisodeIdentityVerdict.match,
        );
      },
    );

    test('recognizes anime episode suffixes followed by release tags', () {
      expect(
        _label('Show - 08 [1080p].mkv', episode: 8).verdict,
        EpisodeIdentityVerdict.match,
      );
      expect(
        _label('Show - 08 [1080p].mkv', episode: 7).verdict,
        EpisodeIdentityVerdict.mismatch,
      );
    });

    test('does not infer technical numbers as episodes', () {
      for (final label in <String>[
        'Show 1080p 10-bit x265',
        'Show - 720.mkv',
        'Show [2026] [1080p]',
        'Show [5.1] audio',
        'Show [7.1] surround',
        'Show [23.976] fps',
        'feature-a.mkv',
      ]) {
        expect(
          _label(label, episode: 720).verdict,
          EpisodeIdentityVerdict.unknown,
          reason: label,
        );
      }
    });
  });

  group('explicit provider identity', () {
    test(
      'rejects confirmed episode, season, and unrelated title mismatches',
      () {
        final episode = _episode(
          title: 'My Hero Academia Season 4',
          episode: 10,
        );
        expect(
          assessExplicitProviderEpisodeIdentity(
            episode: episode,
            episodeNumber: 11,
          ).reasonCode,
          'explicit_episode_mismatch',
        );
        expect(
          assessExplicitProviderEpisodeIdentity(
            episode: episode,
            episodeNumber: 10,
            seasonNumber: 3,
          ).reasonCode,
          'explicit_season_mismatch',
        );
        expect(
          assessExplicitProviderEpisodeIdentity(
            episode: episode,
            episodeNumber: 10,
            seriesTitle: 'Serial Experiments Lain',
          ).reasonCode,
          'explicit_series_mismatch',
        );
      },
    );

    test('accepts an exact alternate title after season normalization', () {
      final assessment = assessExplicitProviderEpisodeIdentity(
        episode: _episode(
          title: 'My Hero Academia Season 4',
          episode: 10,
          alternatives: const ['Boku no Hero Academia 4th Season'],
        ),
        episodeNumber: 10,
        seasonNumber: 4,
        seriesTitle: 'Boku no Hero Academia',
      );

      expect(assessment.verdict, EpisodeIdentityVerdict.match);
    });

    test('treats translated and overlapping sequel titles as uncertain', () {
      final translated = assessExplicitProviderEpisodeIdentity(
        episode: _episode(title: 'ボクのヒーローアカデミア', episode: 10),
        seriesTitle: 'My Hero Academia',
      );
      final overlapping = assessExplicitProviderEpisodeIdentity(
        episode: _episode(title: 'Naruto', episode: 10),
        seriesTitle: 'Naruto Shippuden',
      );

      expect(translated.verdict, EpisodeIdentityVerdict.unknown);
      expect(overlapping.verdict, EpisodeIdentityVerdict.unknown);
    });

    test('season and title alone cannot prove an episode match', () {
      final assessment = assessExplicitProviderEpisodeIdentity(
        episode: _episode(title: 'Show Season 4', episode: 18),
        seasonNumber: 4,
        seriesTitle: 'Show',
      );

      expect(assessment.verdict, EpisodeIdentityVerdict.unknown);
    });
  });

  group('debrid file selection', () {
    test('confirmed match overrides a wrong preferred file index', () {
      final index = selectEpisodeFileIndex(
        labels: const ['Show - 01.mkv', 'Show - 02.mkv'],
        playable: const [true, true],
        sizes: const [900, 1000],
        requestedEpisode: 1,
        preferredFileIndex: 1,
      );

      expect(index, 0);
    });

    test('ambiguous metadata fails open and retains the preferred index', () {
      final index = selectEpisodeFileIndex(
        labels: const ['feature-a.mkv', 'feature-b.mkv'],
        playable: const [true, true],
        sizes: const [900, 1000],
        requestedEpisode: 1,
        preferredFileIndex: 0,
      );

      expect(index, 0);
    });

    test('episodic packs do not select unknown extras after a mismatch', () {
      expect(
        () => selectEpisodeFileIndex(
          labels: const ['Show - 02.mkv', 'NCOP.mkv', 'NCED.mkv', 'sample.mkv'],
          playable: const [true, true, true, true],
          sizes: const [1000, 1200, 1100, 100],
          requestedEpisode: 1,
          preferredFileIndex: 1,
        ),
        throwsA(isA<EpisodeIdentityMismatchException>()),
      );
    });

    test('fully ambiguous multi-file packs continue to fail open', () {
      final index = selectEpisodeFileIndex(
        labels: const ['feature-a.mkv', 'feature-b.mkv', 'bonus.mkv'],
        playable: const [true, true, true],
        sizes: const [900, 1000, 800],
        requestedEpisode: 1,
        preferredFileIndex: 2,
      );

      expect(index, 2);
    });

    test('retains a preferred index when it also confirms the episode', () {
      final index = selectEpisodeFileIndex(
        labels: const ['Show E01 720p.mkv', 'Show E01 1080p.mkv'],
        playable: const [true, true],
        sizes: const [900, 1000],
        requestedEpisode: 1,
        preferredFileIndex: 0,
      );

      expect(index, 0);
    });

    test('selects the requested season when episode numbers repeat', () {
      final index = selectEpisodeFileIndex(
        labels: const ['Show S01E01.mkv', 'Show S02E01.mkv'],
        playable: const [true, true],
        sizes: const [1000, 900],
        requestedEpisode: 1,
        requestedSeason: 2,
        preferredFileIndex: 0,
      );

      expect(index, 1);
    });

    test('later-season absolute packs retain the provider-selected file', () {
      final index = selectEpisodeFileIndex(
        labels: const [
          'My Hero Academia - 87.mkv',
          'My Hero Academia - 88.mkv',
          'My Hero Academia - 25.mkv',
        ],
        playable: const [true, true, true],
        sizes: const [900, 1000, 1100],
        requestedEpisode: 25,
        requestedSeason: 4,
        preferredFileIndex: 1,
      );

      expect(index, 1);
    });

    test('refuses a batch containing only confirmed wrong episodes', () {
      expect(
        () => selectEpisodeFileIndex(
          labels: const ['Show - 02.mkv', 'Show - 03.mkv'],
          playable: const [true, true],
          sizes: const [900, 1000],
          requestedEpisode: 1,
        ),
        throwsA(
          isA<EpisodeIdentityMismatchException>().having(
            (error) => error.reasonCode,
            'reasonCode',
            'episode_number_mismatch',
          ),
        ),
      );
    });
  });

  group('resolved playback identity', () {
    test(
      'trusted provider episode overrides a presentation server ordinal',
      () {
        final assessment = assessPlaybackEpisodeIdentity(
          episode: _episode(title: 'Show', episode: 18),
          stream: StreamReady(
            uri: Uri.parse('https://example.invalid/play'),
            displayName: 'Provider / Server - 1',
            providerEpisodeIdentity: const ProviderEpisodeIdentity(
              episodeNumber: 18,
              seriesTitle: 'Show',
            ),
          ),
          release: _release('Provider / Server - 1'),
        );

        expect(assessment.verdict, EpisodeIdentityVerdict.match);
        expect(assessment.reasonCode, 'explicit_episode_identity_match');
      },
    );

    test('trusted provider mismatch overrides a plausible display label', () {
      final assessment = assessPlaybackEpisodeIdentity(
        episode: _episode(title: 'Show', episode: 18),
        stream: StreamReady(
          uri: Uri.parse('https://example.invalid/play'),
          displayName: 'Show Episode 18',
          providerEpisodeIdentity: const ProviderEpisodeIdentity(
            episodeNumber: 17,
            seriesTitle: 'Show',
          ),
        ),
        release: _release('Show Episode 18'),
      );

      expect(assessment.verdict, EpisodeIdentityVerdict.mismatch);
      expect(assessment.reasonCode, 'explicit_episode_mismatch');
    });

    test('resolved file evidence takes priority over a broad batch label', () {
      final assessment = assessPlaybackEpisodeIdentity(
        episode: _episode(title: 'Show Season 1', episode: 2),
        stream: StreamReady(
          uri: Uri.parse('https://example.invalid/play'),
          displayName: 'Show S01E02.mkv',
        ),
        release: _release('Show S01E01-12 batch'),
      );

      expect(assessment.verdict, EpisodeIdentityVerdict.match);
    });

    test('exception and diagnostics remain filename and URL free', () {
      final error = EpisodeIdentityMismatchException(
        reasonCode: 'episode_number_mismatch',
      );

      expect(error.toString(), isNot(contains('example.invalid')));
      expect(error.toString(), isNot(contains('.mkv')));
      expect(error.reasonCode, 'episode_number_mismatch');
    });
  });
}

EpisodeIdentityAssessment _label(
  String label, {
  required int episode,
  int? season,
}) => assessEpisodeIdentityLabel(
  label: label,
  requestedEpisode: episode,
  requestedSeason: season,
);

EpisodeReference _episode({
  required String title,
  required int episode,
  List<String> alternatives = const [],
}) => EpisodeReference(
  anilistMediaId: 1,
  title: title,
  episode: episode,
  alternativeTitles: alternatives,
);

ReleaseCandidate _release(String name) => ReleaseCandidate(
  infoHash: 'hash',
  magnetUri: 'magnet:?xt=urn:btih:hash',
  releaseName: name,
  seeders: 1,
  sourceId: 'test',
);
