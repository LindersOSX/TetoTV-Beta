import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:dio/dio.dart';

class AniListTrackingRepository implements TrackingRepository {
  AniListTrackingRepository({required String accessToken, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://graphql.anilist.co',
              headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $accessToken',
              },
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );

  final Dio _dio;
  int? _cachedViewerId;

  @override
  Future<List<TrackedAnime>> list(TrackingListStatus status) async {
    final viewerId = await _viewerId();
    final result = <TrackedAnime>[];
    var page = 1;
    var hasNextPage = true;
    const maxPages = 20; // safety guard against runaway pagination
    while (hasNextPage && page <= maxPages) {
      final data = await _graphQl(
        r'''
query ($userId: Int!, $status: MediaListStatus!, $page: Int!) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    mediaList(userId: $userId, type: ANIME, status: $status) {
      mediaId
      progress
      status
      score(format: POINT_10_DECIMAL)
      updatedAt
      startedAt { year month day }
      media {
        episodes
        status
        title { userPreferred english romaji }
        coverImage { extraLarge }
      }
    }
  }
}
''',
        {'userId': viewerId, 'status': anilistStatus(status), 'page': page},
      );
      final pageData = data['Page'] as Map<String, dynamic>;
      final entries = (pageData['mediaList'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      for (final entry in entries) {
        final media = entry['media'] as Map<String, dynamic>;
        final title = media['title'] as Map<String, dynamic>;
        final titleEnglish = title['english'] as String?;
        final titleRomaji = title['romaji'] as String?;
        final fallbackTitle = title['userPreferred'] as String;
        final cover = media['coverImage'] as Map<String, dynamic>?;
        final startedAt = entry['startedAt'] as Map<String, dynamic>?;
        result.add(
          TrackedAnime(
            mediaId: entry['mediaId'] as int,
            title: titleEnglish?.trim().isNotEmpty == true
                ? titleEnglish!
                : titleRomaji?.trim().isNotEmpty == true
                ? titleRomaji!
                : fallbackTitle,
            titleEnglish: titleEnglish,
            titleRomaji: titleRomaji,
            status: status,
            progress: entry['progress'] as int? ?? 0,
            totalEpisodes: media['episodes'] as int?,
            coverImageUrl: cover?['extraLarge'] as String?,
            score: (entry['score'] as num?)?.toDouble(),
            updatedAt: switch (entry['updatedAt']) {
              final int timestamp when timestamp > 0 =>
                DateTime.fromMillisecondsSinceEpoch(
                  timestamp * 1000,
                  isUtc: true,
                ).toLocal(),
              _ => null,
            },
            startDate: _fuzzyDate(startedAt),
            airingStatus: media['status'] as String?,
          ),
        );
      }
      final pageInfo = pageData['pageInfo'] as Map<String, dynamic>;
      hasNextPage = pageInfo['hasNextPage'] as bool? ?? false;
      page++;
    }
    return result;
  }

  @override
  Future<int?> currentProgress(int mediaId) async {
    final viewerId = await _viewerId();
    final data = await _graphQl(
      r'''
query ($mediaId: Int!, $userId: Int!) {
  MediaList(mediaId: $mediaId, userId: $userId) {
    progress
  }
}
''',
      {'mediaId': mediaId, 'userId': viewerId},
    );
    final entry = data['MediaList'] as Map<String, dynamic>?;
    return entry?['progress'] as int?;
  }

  @override
  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  }) async {
    final existing = await currentProgress(mediaId) ?? 0;
    if (completedEpisodes <= existing) return;
    await _graphQl(
      r'''
mutation ($mediaId: Int!, $progress: Int!) {
  SaveMediaListEntry(mediaId: $mediaId, progress: $progress) {
    id
    progress
  }
}
''',
      {'mediaId': mediaId, 'progress': completedEpisodes},
    );
  }

  @override
  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    await _graphQl(
      r'''
mutation ($mediaId: Int!, $status: MediaListStatus!) {
  SaveMediaListEntry(mediaId: $mediaId, status: $status) {
    id
    status
  }
}
''',
      {'mediaId': mediaId, 'status': anilistStatus(status)},
    );
  }

  @override
  Future<void> removeFromList({required int mediaId}) async {
    final viewerId = await _viewerId();
    final lookup = await _graphQl(
      r'''
query ($mediaId: Int!, $userId: Int!) {
  MediaList(mediaId: $mediaId, userId: $userId) { id }
}
''',
      {'mediaId': mediaId, 'userId': viewerId},
    );
    final entry = lookup['MediaList'] as Map<String, dynamic>?;
    final entryId = entry?['id'] as int?;
    if (entryId == null) return;
    await _graphQl(
      r'''
mutation ($id: Int!) {
  DeleteMediaListEntry(id: $id) { deleted }
}
''',
      {'id': entryId},
    );
  }

  Future<int> _viewerId() async {
    if (_cachedViewerId case final id?) return id;
    final data = await _graphQl('query { Viewer { id } }', const {});
    final viewer = data['Viewer'] as Map<String, dynamic>;
    return _cachedViewerId = viewer['id'] as int;
  }

  Future<Map<String, dynamic>> _graphQl(
    String query,
    Map<String, dynamic> variables,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '',
      data: {'query': query, 'variables': variables},
    );
    final body = response.data ?? const {};
    if (body['errors'] case final List<dynamic> errors when errors.isNotEmpty) {
      final first = errors.first;
      if (first is Map<String, dynamic>) {
        throw StateError(first['message'] as String? ?? 'AniList API error.');
      }
      throw StateError('AniList API error.');
    }
    return body['data'] as Map<String, dynamic>? ?? const {};
  }
}

DateTime? _fuzzyDate(Map<String, dynamic>? value) {
  final year = value?['year'] as int?;
  if (year == null || year <= 0) return null;
  final month = (value?['month'] as int? ?? 1).clamp(1, 12);
  final day = (value?['day'] as int? ?? 1).clamp(1, 31);
  return DateTime(year, month, day);
}

String anilistStatus(TrackingListStatus status) => switch (status) {
  TrackingListStatus.watching => 'CURRENT',
  TrackingListStatus.planToWatch => 'PLANNING',
  TrackingListStatus.completed => 'COMPLETED',
  TrackingListStatus.dropped => 'DROPPED',
  TrackingListStatus.onHold => 'PAUSED',
};
