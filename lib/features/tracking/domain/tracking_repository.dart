import 'package:anime_tv/core/preferences/title_language_preference.dart';

enum TrackingListStatus { watching, planToWatch, completed, dropped, onHold }

extension TrackingListStatusLabel on TrackingListStatus {
  String get displayName => switch (this) {
    TrackingListStatus.watching => 'Watching',
    TrackingListStatus.planToWatch => 'Planning',
    TrackingListStatus.completed => 'Completed',
    TrackingListStatus.dropped => 'Dropped',
    TrackingListStatus.onHold => 'On Hold',
  };
}

class TrackedAnime {
  const TrackedAnime({
    required this.mediaId,
    required this.title,
    required this.status,
    required this.progress,
    this.titleEnglish,
    this.titleRomaji,
    this.totalEpisodes,
    this.coverImageUrl,
    this.score,
    this.updatedAt,
    this.startDate,
    this.airingStatus,
    this.anilistId,
    this.malId,
    this.sourceUrl,
  });

  final int mediaId;
  final String title;
  final String? titleEnglish;
  final String? titleRomaji;
  final TrackingListStatus status;
  final int progress;
  final int? totalEpisodes;
  final String? coverImageUrl;
  final double? score;
  final DateTime? updatedAt;
  final DateTime? startDate;
  final String? airingStatus;
  final int? anilistId;
  final int? malId;
  final String? sourceUrl;

  String displayTitle(TitleLanguagePreference preference) =>
      preferredAnimeTitle(
        preference: preference,
        fallback: title,
        english: titleEnglish,
        romaji: titleRomaji,
      );
}

/// Catalog identifiers that a tracker can resolve without title matching.
class TrackingMediaIds {
  const TrackingMediaIds({
    this.simklId,
    this.kitsuId,
    this.anilistId,
    this.malId,
  });

  final int? simklId;
  final int? kitsuId;
  final int? anilistId;
  final int? malId;

  bool get isEmpty =>
      simklId == null && kitsuId == null && anilistId == null && malId == null;
}

/// A tracker permanently has no catalog mapping for the supplied stable IDs.
///
/// This is deliberately narrower than a generic provider or network failure:
/// callers may discard queued work for this title, while transient failures
/// must remain retryable.
final class TrackingMediaMappingNotFoundException implements Exception {
  const TrackingMediaMappingNotFoundException();

  @override
  String toString() =>
      'The connected tracker has no catalog mapping for this title.';
}

abstract interface class TrackingRepository {
  Future<List<TrackedAnime>> list(TrackingListStatus status);

  Future<int?> currentProgress(int mediaId);

  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  });

  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  });

  Future<void> removeFromList({required int mediaId});
}

/// Optional repository surface for providers that accept multiple catalog IDs.
///
/// SIMKL accepts AniList and MAL IDs directly. Kitsu resolves those stable IDs
/// through its mapping endpoint. Callers must never fall back to title guesses.
abstract interface class ExternalIdTrackingRepository {
  Future<int?> currentProgressByIds(TrackingMediaIds ids);

  Future<void> updateProgressByIds({
    required TrackingMediaIds ids,
    required int completedEpisodes,
  });

  Future<void> updateStatusByIds({
    required TrackingMediaIds ids,
    required TrackingListStatus status,
  });

  Future<void> removeFromListByIds(TrackingMediaIds ids);
}

/// Optional mutation surface for trackers that may normalize the requested
/// watchlist status and return the authoritative value they stored.
abstract interface class ResolvedStatusTrackingRepository {
  Future<TrackingListStatus> updateStatusResolved({
    required int mediaId,
    required TrackingListStatus status,
  });
}

/// Optional rating mutation surface. Scores use the app-wide 1–10 scale;
/// `null` clears a rating.
abstract interface class RatingTrackingRepository {
  Future<void> updateRating({required int mediaId, required double? score});
}
