import 'package:anime_tv/features/catalog/domain/anime_summary.dart';

enum EpisodeAiringAvailabilityKind { available, episodeUnaired, seriesUnaired }

/// Builds the short, human-readable countdown used beside a releasing
/// series' status.
///
/// AniList only exposes an exact timestamp for the immediate next episode,
/// so this deliberately returns `null` when that timestamp is missing,
/// stale, or belongs to a non-releasing series. The UI must never estimate a
/// schedule from a show's usual broadcast day.
String? nextEpisodeAiringCountdownLabel({
  required AnimeSummary anime,
  DateTime? now,
}) {
  final normalizedStatus = anime.status?.trim().toUpperCase().replaceAll(
    RegExp(r'[\s-]+'),
    '_',
  );
  if (normalizedStatus != 'RELEASING' &&
      normalizedStatus != 'AIRING' &&
      normalizedStatus != 'CURRENTLY_AIRING') {
    return null;
  }

  final airingAt = anime.nextAiringAt;
  final nextEpisode = anime.nextAiringEpisode;
  if (airingAt == null || nextEpisode == null || nextEpisode <= 0) return null;

  final remaining = airingAt.difference(now ?? DateTime.now());
  if (remaining <= Duration.zero) return null;

  final minutes = remaining.inMinutes;
  if (minutes < 60) return 'next episode in less than an hour';

  if (minutes < Duration.minutesPerDay) {
    final hours = (minutes / Duration.minutesPerHour).ceil();
    return 'next episode in $hours ${hours == 1 ? 'hour' : 'hours'}';
  }

  final days = (minutes / Duration.minutesPerDay).ceil();
  return 'next episode in $days ${days == 1 ? 'day' : 'days'}';
}

/// Formats a known catalog air date without implying a time of day.
String episodeAiringDateLabel(DateTime value) {
  const months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final local = value.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}

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
