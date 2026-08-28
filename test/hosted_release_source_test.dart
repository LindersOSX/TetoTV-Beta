import 'package:anime_tv/features/streaming/data/hosted_release_source.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HostedReleaseSource JSON parsing', () {
    test('parses required fields from a minimal release entry', () async {
      final source = HostedReleaseSource(
        baseUrl: 'https://example.test',
        dio: _fakeDio(const [
          {
            'info_hash': 'aabbccddaabbccddaabbccddaabbccddaabbccdd',
            'magnet_uri':
                'magnet:?xt=urn:btih:aabbccddaabbccddaabbccddaabbccddaabbccdd',
            'release_name': 'Show - 01',
            'seeders': 42,
          },
        ]),
      );

      final results = await source.search(
        const EpisodeReference(anilistMediaId: 1, title: 'Show', episode: 1),
      );

      expect(results, hasLength(1));
      expect(results.first.releaseName, 'Show - 01');
      expect(results.first.seeders, 42);
      expect(results.first.isBatch, isFalse);
      expect(results.first.isDubbed, isFalse);
      expect(results.first.isHdr, isFalse);
      expect(results.first.hasSubtitles, isFalse);
    });

    test('parses all optional metadata fields when present', () async {
      const hash = 'f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0';
      final source = HostedReleaseSource(
        baseUrl: 'https://example.test',
        dio: _fakeDio(const [
          {
            'info_hash': hash,
            'magnet_uri': 'magnet:?xt=urn:btih:$hash',
            'release_name': '[Group] Show S01 Batch HEVC 1080p HDR Dual-Audio',
            'seeders': 120,
            'is_batch': true,
            'is_dubbed': true,
            'has_subtitles': true,
            'is_hdr': true,
            'quality': '1080p',
            'codec': 'HEVC',
            'size_label': '4.2 GB',
            'provider': 'UserProvider',
            'preferred_file_index': 7,
          },
        ]),
      );

      final results = await source.search(
        const EpisodeReference(anilistMediaId: 1, title: 'Show', episode: 1),
      );

      expect(results, hasLength(1));
      final r = results.first;
      expect(r.isBatch, isTrue);
      expect(r.isDubbed, isTrue);
      expect(r.hasSubtitles, isTrue);
      expect(r.isHdr, isTrue);
      expect(r.quality, '1080p');
      expect(r.codec, 'HEVC');
      expect(r.sizeLabel, '4.2 GB');
      expect(r.provider, 'UserProvider');
      expect(r.preferredFileIndex, 7);
    });

    test('accepts a {releases: [...]} wrapper response shape', () async {
      const hash = 'abababababababababababababababababababababab';
      final source = HostedReleaseSource(
        baseUrl: 'https://example.test',
        dio: _fakeDio(const {
          'releases': [
            {
              'info_hash': hash,
              'magnet_uri': 'magnet:?xt=urn:btih:$hash',
              'release_name': 'Example',
              'seeders': 1,
            },
          ],
        }),
      );

      final results = await source.search(
        const EpisodeReference(anilistMediaId: 2, title: 'Example', episode: 1),
      );

      expect(results, hasLength(1));
      expect(results.first.releaseName, 'Example');
    });

    test('returns empty list for empty response', () async {
      final source = HostedReleaseSource(
        baseUrl: 'https://example.test',
        dio: _fakeDio(const []),
      );

      final results = await source.search(
        const EpisodeReference(anilistMediaId: 3, title: 'Nothing', episode: 1),
      );

      expect(results, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Injects a pre-canned response via an interceptor so real Dio handles the
// rest of the pipeline (no need to subclass or fake Dio itself).
// ---------------------------------------------------------------------------

Dio _fakeDio(dynamic payload) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            data: payload,
            requestOptions: options,
            statusCode: 200,
          ),
        );
      },
    ),
  );
  return dio;
}
