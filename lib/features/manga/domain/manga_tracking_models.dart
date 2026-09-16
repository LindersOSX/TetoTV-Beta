import 'package:anime_tv/features/auth/domain/tracking_provider.dart';

bool supportsMangaTracking(TrackingProvider provider) =>
    provider == TrackingProvider.anilist ||
    provider == TrackingProvider.myAnimeList;

class MangaTrackingTitleKey {
  MangaTrackingTitleKey({
    required String ownerKey,
    required String sourceId,
    required String publicationId,
  }) : ownerKey = mangaTrackingText(ownerKey, 128),
       sourceId = mangaTrackingText(sourceId, 128),
       publicationId = mangaTrackingText(publicationId, 512);

  final String ownerKey;
  final String sourceId;
  final String publicationId;

  bool matches(MangaTrackingTitleKey other) =>
      ownerKey == other.ownerKey &&
      sourceId == other.sourceId &&
      publicationId == other.publicationId;

  Map<String, Object> toJson() => {
    'owner': ownerKey,
    'source': sourceId,
    'publication': publicationId,
  };
}

class MangaTrackingSearchResult {
  MangaTrackingSearchResult({
    required this.provider,
    required this.mediaId,
    required String title,
    String? format,
    this.totalChapters,
  }) : title = mangaTrackingText(title, 512),
       format = format == null ? null : mangaTrackingText(format, 64) {
    if (!supportsMangaTracking(provider) ||
        mediaId < 1 ||
        mediaId > 2147483647 ||
        (totalChapters != null &&
            (totalChapters! < 1 || totalChapters! > 100000))) {
      throw const FormatException('Invalid manga tracking record.');
    }
  }

  final TrackingProvider provider;
  final int mediaId;
  final String title;
  final String? format;
  final int? totalChapters;
  Uri get url => provider == TrackingProvider.anilist
      ? Uri.https('anilist.co', '/manga/$mediaId')
      : Uri.https('myanimelist.net', '/manga/$mediaId');

  Map<String, Object?> toJson() => {
    'provider': provider.slug,
    'id': mediaId,
    'title': title,
    'format': format,
    'chapters': totalChapters,
  };

  factory MangaTrackingSearchResult.fromJson(Map<String, dynamic> json) =>
      MangaTrackingSearchResult(
        provider: mangaTrackingProvider(json['provider']),
        mediaId: mangaTrackingInt(json['id'], 1, 2147483647),
        title: json['title'] as String,
        format: json['format'] as String?,
        totalChapters: json['chapters'] == null
            ? null
            : mangaTrackingInt(json['chapters'], 1, 100000),
      );
}

class MangaTrackingLink {
  MangaTrackingLink({
    required this.titleKey,
    required this.record,
    required String profileId,
    required String accountId,
    required String bindingId,
    required this.linkedAt,
  }) : profileId = mangaTrackingText(profileId, 128),
       accountId = mangaTrackingText(accountId, 128),
       bindingId = mangaTrackingText(bindingId, 128);

  final MangaTrackingTitleKey titleKey;
  final MangaTrackingSearchResult record;
  final String profileId;
  final String accountId;

  /// Unique local binding generation. Relinking invalidates old outbox rows.
  final String bindingId;
  final DateTime linkedAt;
  TrackingProvider get provider => record.provider;

  Map<String, Object?> toJson() => {
    ...titleKey.toJson(),
    'record': record.toJson(),
    'profile': profileId,
    'account': accountId,
    'binding': bindingId,
    'linkedAt': linkedAt.toUtc().millisecondsSinceEpoch,
  };

  factory MangaTrackingLink.fromJson(Map<String, dynamic> json) =>
      MangaTrackingLink(
        titleKey: MangaTrackingTitleKey(
          ownerKey: json['owner'] as String,
          sourceId: json['source'] as String,
          publicationId: json['publication'] as String,
        ),
        record: MangaTrackingSearchResult.fromJson(
          Map<String, dynamic>.from(json['record'] as Map),
        ),
        profileId: json['profile'] as String,
        accountId: json['account'] as String,
        bindingId: json['binding'] as String,
        linkedAt: DateTime.fromMillisecondsSinceEpoch(
          mangaTrackingInt(json['linkedAt'], 0, 8640000000000000),
          isUtc: true,
        ),
      );
}

class MangaTrackingPending {
  const MangaTrackingPending({
    required this.bindingId,
    required this.completedChapters,
    this.attempts = 0,
    required this.nextAttemptAt,
    this.serverRetryAt,
    this.lastError,
    this.needsAttention = false,
  });
  final String bindingId;
  final int completedChapters;
  final int attempts;
  final DateTime nextAttemptAt;
  final DateTime? serverRetryAt;
  final String? lastError;
  final bool needsAttention;

  Map<String, Object?> toJson() => {
    'binding': bindingId,
    'progress': completedChapters,
    'attempts': attempts,
    'next': nextAttemptAt.toUtc().millisecondsSinceEpoch,
    'serverRetry': serverRetryAt?.toUtc().millisecondsSinceEpoch,
    'error': lastError,
    'attention': needsAttention,
  };

  factory MangaTrackingPending.fromJson(Map<String, dynamic> json) =>
      MangaTrackingPending(
        bindingId: mangaTrackingText(json['binding'] as String, 128),
        completedChapters: mangaTrackingInt(json['progress'], 1, 100000),
        attempts: mangaTrackingInt(json['attempts'], 0, 100),
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(
          mangaTrackingInt(json['next'], 0, 8640000000000000),
          isUtc: true,
        ),
        serverRetryAt: json['serverRetry'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                mangaTrackingInt(json['serverRetry'], 0, 8640000000000000),
                isUtc: true,
              ),
        lastError: json['error'] == null
            ? null
            : mangaTrackingText(json['error'] as String, 256),
        needsAttention: json['attention'] == true,
      );
}

class MangaTrackingException implements Exception {
  const MangaTrackingException(
    this.message, {
    this.retryable = false,
    this.retryAfter,
    this.requiresReconnect = false,
  });
  final String message;
  final bool retryable;
  final Duration? retryAfter;
  final bool requiresReconnect;
  @override
  String toString() => message;
}

String mangaTrackingText(String value, int maximumLength) {
  final text = value.trim();
  if (text.isEmpty ||
      text.length > maximumLength ||
      text.runes.any((rune) => rune < 32 || rune == 127)) {
    throw const FormatException('Invalid manga tracking text.');
  }
  return text;
}

int mangaTrackingInt(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('Invalid manga tracking number.');
  }
  return value;
}

TrackingProvider mangaTrackingProvider(Object? slug) {
  for (final value in [
    TrackingProvider.anilist,
    TrackingProvider.myAnimeList,
  ]) {
    if (value.slug == slug) return value;
  }
  throw const FormatException('Manga tracking supports AniList and MAL only.');
}
