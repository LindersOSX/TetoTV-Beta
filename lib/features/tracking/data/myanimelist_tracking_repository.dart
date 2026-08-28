import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:dio/dio.dart';

class MyAnimeListTrackingRepository implements TrackingRepository {
  MyAnimeListTrackingRepository({required String accessToken, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.myanimelist.net/v2',
              headers: {
                'Accept': 'application/json',
                'Authorization': 'Bearer $accessToken',
              },
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );

  final Dio _dio;

  @override
  Future<List<TrackedAnime>> list(TrackingListStatus status) async {
    final result = <TrackedAnime>[];
    // Use a fixed initial path with base URL, then use full URLs from paging
    String? nextUrl =
        'https://api.myanimelist.net/v2/users/@me/animelist'
        '?status=${myAnimeListStatus(status)}'
        '&limit=100&fields=list_status,num_episodes,status,title,alternative_titles,'
        'main_picture';
    final visitedPageUrls = <String>{};
    var pageCount = 0;
    while (nextUrl != null) {
      final pageUri = trustedMyAnimeListPageUri(nextUrl);
      if (pageUri == null) {
        throw const FormatException(
          'MAL returned an untrusted pagination link.',
        );
      }
      final canonicalUrl = pageUri.toString();
      if (!visitedPageUrls.add(canonicalUrl)) {
        throw const FormatException('MAL returned a pagination loop.');
      }
      pageCount++;
      if (pageCount > 50) {
        throw const FormatException('MAL returned too many result pages.');
      }

      // Reuse the configured client so interceptors, timeouts, and certificate
      // behavior remain consistent. Most importantly, never attach the bearer
      // token to a paging URL until its origin and path have been validated.
      final response = await _dio.get<Map<String, dynamic>>(canonicalUrl);
      final body = response.data ?? const {};
      final entries = (body['data'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      for (final entry in entries) {
        final node = entry['node'] as Map<String, dynamic>;
        final listStatus = entry['list_status'] as Map<String, dynamic>;
        final picture = node['main_picture'] as Map<String, dynamic>?;
        final alternatives =
            node['alternative_titles'] as Map<String, dynamic>?;
        final titleRomaji = node['title'] as String;
        final titleEnglish = alternatives?['en'] as String?;
        final updatedAt = DateTime.tryParse(
          listStatus['updated_at'] as String? ?? '',
        );
        final startDate = DateTime.tryParse(
          listStatus['start_date'] as String? ?? '',
        );
        result.add(
          TrackedAnime(
            mediaId: node['id'] as int,
            title: titleEnglish?.trim().isNotEmpty == true
                ? titleEnglish!
                : titleRomaji,
            titleEnglish: titleEnglish,
            titleRomaji: titleRomaji,
            status: status,
            progress: listStatus['num_episodes_watched'] as int? ?? 0,
            totalEpisodes: node['num_episodes'] as int?,
            coverImageUrl:
                picture?['large'] as String? ?? picture?['medium'] as String?,
            score: (listStatus['score'] as num?)?.toDouble(),
            updatedAt: updatedAt?.toLocal(),
            startDate: startDate,
            airingStatus: node['status'] as String?,
          ),
        );
      }
      final paging = body['paging'] as Map<String, dynamic>?;
      nextUrl = switch (paging?['next']) {
        final String value when value.isNotEmpty => value,
        _ => null,
      };
    }
    return result;
  }

  @override
  Future<int?> currentProgress(int mediaId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/anime/$mediaId',
      queryParameters: const {'fields': 'my_list_status'},
    );
    final status = response.data?['my_list_status'] as Map<String, dynamic>?;
    return status?['num_episodes_watched'] as int?;
  }

  @override
  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  }) async {
    final existing = await currentProgress(mediaId) ?? 0;
    if (completedEpisodes <= existing) return;
    await _dio.put<void>(
      '/anime/$mediaId/my_list_status',
      data: {'num_watched_episodes': completedEpisodes},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  @override
  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    await _dio.put<void>(
      '/anime/$mediaId/my_list_status',
      data: {'status': myAnimeListStatus(status)},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  @override
  Future<void> removeFromList({required int mediaId}) =>
      _dio.delete<void>('/anime/$mediaId/my_list_status');
}

Uri? trustedMyAnimeListPageUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.toLowerCase() != 'api.myanimelist.net' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.path != '/v2/users/@me/animelist') {
    return null;
  }
  return uri;
}

String myAnimeListStatus(TrackingListStatus status) => switch (status) {
  TrackingListStatus.watching => 'watching',
  TrackingListStatus.planToWatch => 'plan_to_watch',
  TrackingListStatus.completed => 'completed',
  TrackingListStatus.dropped => 'dropped',
  TrackingListStatus.onHold => 'on_hold',
};
