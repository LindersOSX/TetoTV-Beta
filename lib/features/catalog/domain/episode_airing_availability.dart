import 'package:anime_tv/features/catalog/domain/anime_summary.dart';

enum EpisodeAiringAvailabilityKind { available, episodeUnaired, seriesUnaired }

class EpisodeAiringAvailability {
  const EpisodeAiringAvailability._({
    required this.kind,
    this.episode,
    this.expectedAt,
  });

  const EpisodeAiringAvailability.available()
    : this._(kind: EpisodeAiringAvailabilityKind.available);

  const EpisodeAiringAvailability.episodeUnaired({
    required int episode,
    DateTime? expectedAt,
  }) : this._(
         kind: EpisodeAiringAvailabilityKind.episodeUnaired,
         episode: episode,
         expectedAt: expectedAt,
       );

  const EpisodeAiringAvailability.seriesUnaired({DateTime? expectedAt})
    : this._(
        kind: EpisodeAiringAvailabilityKind.seriesUnaired,
        expectedAt: expectedAt,
      );

  final EpisodeAiringAvailabilityKind kind;
  final int? episode;
  final DateTime? expectedAt;

  bool get isAvailable => kind == EpisodeAiringAvailabilityKind.available;
}

/// Returns a conservative release state for an episode.
///
/// A series-level `NOT_YET_RELEASED` status and AniList's explicit next-airing
/// episode are authoritative. Missing schedule metadata is deliberately
/// fail-open, so stale or incomplete catalog data never blocks playback.
EpisodeAiringAvailability episodeAiringAvailability({
  required AnimeSummary anime,
  required int episode,
  DateTime? now,
}) {
  final normalizedStatus = anime.status?.trim().toUpperCase().replaceAll(
    RegExp(r'[\s-]+'),
    '_',
  );
  if (normalizedStatus == 'NOT_YET_RELEASED' ||
      normalizedStatus == 'UPCOMING' ||
      normalizedStatus == 'TBA' ||
      normalizedStatus == 'UNRELEASED') {
    return EpisodeAiringAvailability.seriesUnaired(expectedAt: anime.startDate);
  }

  final nextEpisode = anime.nextAiringEpisode;
  if (nextEpisode == null || nextEpisode <= 0 || episode < nextEpisode) {
    return const EpisodeAiringAvailability.available();
  }

  final expectedAt = anime.nextAiringAt;
  final referenceTime = now ?? DateTime.now();
  // If a cached schedule says the episode should already have aired, let the
  // normal resolver decide. This avoids a stale schedule becoming a lockout.
  if (expectedAt != null && !expectedAt.isAfter(referenceTime)) {
    return const EpisodeAiringAvailability.available();
  }

  return EpisodeAiringAvailability.episodeUnaired(
    episode: episode,
    // AniList only supplies an exact date for its immediate next episode.
    // Do not present that date as the date of a later episode.
    expectedAt: episode == nextEpisode ? expectedAt : null,
  );
}
