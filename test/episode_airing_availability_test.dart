import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/episode_airing_availability.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 2, 12);

  test('describes a known next episode without estimating a schedule', () {
    final anime = AnimeSummary(
      id: 6,
      title: 'Countdown series',
      description: '',
      episodes: 12,
      score: null,
      status: 'RELEASING',
      nextAiringEpisode: 7,
      nextAiringAt: DateTime.utc(2026, 9, 5, 12),
    );

    expect(
      nextEpisodeAiringCountdownLabel(anime: anime, now: now),
      'next episode in 3 days',
    );
    expect(
      episodeAiringDateLabel(anime.nextAiringAt!),
      contains('September 5, 2026'),
    );
  });

  test('does not fabricate a next-episode countdown', () {
    expect(
      nextEpisodeAiringCountdownLabel(
        anime: const AnimeSummary(
          id: 7,
          title: 'Schedule unknown',
          description: '',
          episodes: 12,
          score: null,
          status: 'RELEASING',
          nextAiringEpisode: 7,
        ),
        now: now,
      ),
      isNull,
    );
  });

  test('marks the explicitly scheduled next episode unaired with its date', () {
    final availability = episodeAiringAvailability(
      anime: AnimeSummary(
        id: 1,
        title: 'Scheduled series',
        description: '',
        episodes: 24,
        score: null,
        status: 'RELEASING',
        nextAiringEpisode: 13,
        nextAiringAt: DateTime.utc(2026, 9, 8, 17),
      ),
      episode: 13,
      now: now,
    );

    expect(availability.kind, EpisodeAiringAvailabilityKind.episodeUnaired);
    expect(availability.episode, 13);
    expect(availability.expectedAt, DateTime.utc(2026, 9, 8, 17));
  });

  test('does not invent an air date for a later confirmed episode', () {
    final availability = episodeAiringAvailability(
      anime: AnimeSummary(
        id: 2,
        title: 'Later episode',
        description: '',
        episodes: 24,
        score: null,
        status: 'RELEASING',
        nextAiringEpisode: 13,
        nextAiringAt: DateTime.utc(2026, 9, 8, 17),
      ),
      episode: 14,
      now: now,
    );

    expect(availability.kind, EpisodeAiringAvailabilityKind.episodeUnaired);
    expect(availability.episode, 14);
    expect(availability.expectedAt, isNull);
  });

  test(
    'marks a whole unreleased series unavailable with its premiere date',
    () {
      final availability = episodeAiringAvailability(
        anime: AnimeSummary(
          id: 3,
          title: 'Future series',
          description: '',
          episodes: 12,
          score: null,
          status: 'NOT_YET_RELEASED',
          startDate: DateTime(2026, 10, 4),
        ),
        episode: 1,
        now: now,
      );

      expect(availability.kind, EpisodeAiringAvailabilityKind.seriesUnaired);
      expect(availability.expectedAt, DateTime(2026, 10, 4));
    },
  );

  test('fails open when a cached next-airing timestamp has passed', () {
    final availability = episodeAiringAvailability(
      anime: AnimeSummary(
        id: 4,
        title: 'Stale schedule',
        description: '',
        episodes: 12,
        score: null,
        status: 'RELEASING',
        nextAiringEpisode: 5,
        nextAiringAt: DateTime.utc(2026, 9, 1, 17),
      ),
      episode: 5,
      now: now,
    );

    expect(availability.isAvailable, isTrue);
  });

  test('does not block an episode when airing metadata is unknown', () {
    final availability = episodeAiringAvailability(
      anime: const AnimeSummary(
        id: 5,
        title: 'Unknown schedule',
        description: '',
        episodes: 24,
        score: null,
        status: 'RELEASING',
      ),
      episode: 24,
      now: now,
    );

    expect(availability.isAvailable, isTrue);
  });
}
