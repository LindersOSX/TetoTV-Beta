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

  String displayTitle(TitleLanguagePreference preference) =>
      preferredAnimeTitle(
        preference: preference,
        fallback: title,
        english: titleEnglish,
        romaji: titleRomaji,
      );
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
