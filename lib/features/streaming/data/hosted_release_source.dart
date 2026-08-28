import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';

class HostedReleaseSource implements ReleaseSource {
  HostedReleaseSource({required String baseUrl, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 25),
              headers: const {'Accept': 'application/json'},
            ),
          );

  final Dio _dio;

  @override
  String get id => 'hosted-resolver';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async {
    final response = await _dio.get<dynamic>(
      '/v1/releases',
      queryParameters: {
        'anilist_id': episode.anilistMediaId,
        if (episode.malMediaId != null) 'mal_id': episode.malMediaId,
        'title': episode.title,
        'episode': episode.episode,
        if (episode.alternativeTitles.isNotEmpty)
          'alternative_titles': episode.alternativeTitles.join('|'),
      },
    );
    final body = response.data;
    final raw = switch (body) {
      final List<dynamic> values => values,
      final Map<String, dynamic> map =>
        map['releases'] as List<dynamic>? ?? const [],
      _ => const <dynamic>[],
    };
    return raw
        .cast<Map<String, dynamic>>()
        .map((item) {
          return ReleaseCandidate(
            infoHash: item['info_hash'] as String? ?? '',
            magnetUri: item['magnet_uri'] as String,
            releaseName: item['release_name'] as String? ?? 'Release',
            seeders: item['seeders'] as int? ?? 0,
            sourceId: item['source_id'] as String? ?? id,
            isBatch: item['is_batch'] as bool? ?? false,
            preferredFileIndex: item['preferred_file_index'] as int?,
            quality: item['quality'] as String?,
            codec: item['codec'] as String?,
            sizeLabel: item['size_label'] as String?,
            provider: item['provider'] as String?,
            isDubbed: item['is_dubbed'] as bool? ?? false,
            hasSubtitles: item['has_subtitles'] as bool? ?? false,
            isHdr: item['is_hdr'] as bool? ?? false,
          );
        })
        .toList(growable: false);
  }
}
