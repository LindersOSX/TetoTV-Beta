import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/features/downloads/data/adaptive_offline_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/hls_offline_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tetotv-hls-download-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  group('AdaptiveOfflineDownloadTransferClient', () {
    test('routes HLS MIME/path jobs and delegates ordinary HTTPS', () async {
      final standard = _RecordingTransferClient();
      final hls = _RecordingTransferClient();
      final client = AdaptiveOfflineDownloadTransferClient(
        standardClient: standard,
        hlsClient: hls,
      );

      await client.download(
        job: _job(path: '/movie.mp4', mimeType: 'video/mp4'),
        partialFile: File(path.join(temporary.path, 'movie.part')),
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      );
      await client.download(
        job: _job(path: '/master.M3U8'),
        partialFile: File(path.join(temporary.path, 'path-hls.part')),
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      );
      await client.download(
        job: _job(
          path: '/signed-stream',
          mimeType: 'application/vnd.apple.mpegurl; charset=utf-8',
        ),
        partialFile: File(path.join(temporary.path, 'mime-hls.part')),
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      );

      expect(standard.calls, 1);
      expect(hls.calls, 2);
    });
  });

  group('HlsOfflineDownloadTransferClient', () {
    test(
      'downloads a VOD and persists only relative local references',
      () async {
        const manifest = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:9
# signed-url=https://media.example.test/leak?token=manifest-secret
#EXTINF:6.0,remote title https://should-not-persist.test/secret
segments/a.ts?signature=segment-secret
#EXTINF:4.5,
/segments/b.ts
#EXT-X-ENDLIST
''';
        final adapter = _FixtureAdapter({
          'https://media.example.test/vod.m3u8?token=root-secret':
              _Fixture.text(manifest),
          'https://media.example.test/segments/a.ts?signature=segment-secret':
              _Fixture.bytes([1, 2, 3]),
          'https://media.example.test/segments/b.ts': _Fixture.bytes([4, 5]),
        });
        final progress = <DownloadTransferProgress>[];
        final partial = File(path.join(temporary.path, 'episode.m3u8.part'));

        final result = await _client(adapter).download(
          job: _job(
            path: '/vod.m3u8',
            query: 'token=root-secret',
            mimeType: 'application/vnd.apple.mpegurl',
          ),
          partialFile: partial,
          cancellation: DownloadCancellationToken(),
          requestHeaders: const {'Authorization': 'Bearer header-secret'},
          onProgress: progress.add,
        );

        final segmentDirectory = hlsSegmentDirectoryForPartialFile(partial);
        expect(
          segmentDirectory.path,
          path.join(temporary.path, 'episode.m3u8.hls'),
        );
        expect(
          await File(
            path.join(segmentDirectory.path, 'segment-000000.ts'),
          ).readAsBytes(),
          [1, 2, 3],
        );
        expect(
          await File(
            path.join(segmentDirectory.path, 'segment-000001.ts'),
          ).readAsBytes(),
          [4, 5],
        );
        final local = await partial.readAsString();
        expect(local, contains('episode.m3u8.hls/segment-000000.ts'));
        expect(local, contains('#EXT-X-ENDLIST'));
        expect(local, isNot(contains('https://')));
        expect(local, isNot(contains('secret')));
        expect(local, isNot(contains('remote title')));
        expect(result.receivedBytes, await partial.length());
        expect(result.totalBytes, await partial.length());
        expect(result.mimeType, 'application/vnd.apple.mpegurl');
        expect(progress.last.receivedBytes, 5);
        expect(progress.last.totalBytes, 5);
        expect(progress.last.speedBytesPerSecond, 0);
      },
    );

    test(
      'selects requested variant and otherwise deterministic best',
      () async {
        const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,NAME="Low"
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,NAME="Full HD"
https://cdn.example.test/high/index.m3u8
''';
        const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5,
video.ts
#EXT-X-ENDLIST
''';
        final bestAdapter = _FixtureAdapter({
          'https://origin.example.test/master.m3u8': _Fixture.text(master),
          'https://cdn.example.test/high/index.m3u8': _Fixture.text(media),
          'https://cdn.example.test/high/video.ts': _Fixture.bytes([8, 8]),
        });
        await _client(bestAdapter).download(
          job: _job(host: 'origin.example.test', path: '/master.m3u8'),
          partialFile: File(path.join(temporary.path, 'best.m3u8.part')),
          cancellation: DownloadCancellationToken(),
          requestHeaders: const {
            'Authorization': 'Bearer secret',
            'X-Provider-Key': 'also-secret',
          },
          onProgress: (_) {},
        );

        expect(
          bestAdapter.requests.map((request) => request.uri.toString()),
          isNot(contains('https://origin.example.test/low/index.m3u8')),
        );
        final crossOrigin = bestAdapter.requests.where(
          (request) => request.uri.host == 'cdn.example.test',
        );
        for (final request in crossOrigin) {
          expect(_header(request.headers, 'authorization'), isNull);
          expect(_header(request.headers, 'x-provider-key'), isNull);
        }

        final requestedAdapter = _FixtureAdapter({
          'https://origin.example.test/master.m3u8': _Fixture.text(master),
          'https://origin.example.test/low/index.m3u8': _Fixture.text(media),
          'https://origin.example.test/low/video.ts': _Fixture.bytes([3]),
        });
        await _client(requestedAdapter).download(
          job: _job(
            host: 'origin.example.test',
            path: '/master.m3u8',
            quality: '360p',
          ),
          partialFile: File(path.join(temporary.path, 'requested.m3u8.part')),
          cancellation: DownloadCancellationToken(),
          requestHeaders: const {'Authorization': 'Bearer secret'},
          onProgress: (_) {},
        );
        expect(
          requestedAdapter.requests.map((request) => request.uri.toString()),
          contains('https://origin.example.test/low/index.m3u8'),
        );
        expect(
          _header(requestedAdapter.requests.last.headers, 'authorization'),
          'Bearer secret',
        );
      },
    );

    test(
      'uses the effective redirect URI as the relative-reference base',
      () async {
        const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
segment.ts
#EXT-X-ENDLIST
''';
        final adapter = _FixtureAdapter({
          'https://origin.example.test/start.m3u8': _Fixture.redirect(
            'https://cdn.example.test/final/media.m3u8',
          ),
          'https://cdn.example.test/final/media.m3u8': _Fixture.text(media),
          'https://cdn.example.test/final/segment.ts': _Fixture.bytes([1]),
        });

        await _client(adapter).download(
          job: _job(host: 'origin.example.test', path: '/start.m3u8'),
          partialFile: File(path.join(temporary.path, 'redirect.m3u8.part')),
          cancellation: DownloadCancellationToken(),
          requestHeaders: const {'Authorization': 'Bearer secret'},
          onProgress: (_) {},
        );

        expect(
          adapter.requests.map((request) => request.uri.toString()),
          contains('https://cdn.example.test/final/segment.ts'),
        );
        expect(_header(adapter.requests.last.headers, 'authorization'), isNull);
      },
    );

    test(
      'resumes completed segments after cancellation and client restart',
      () async {
        const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
first.ts
#EXTINF:4,
second.ts
#EXT-X-ENDLIST
''';
        final token = DownloadCancellationToken();
        var cancelledOnce = false;
        final firstAdapter = _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(media),
          'https://media.example.test/first.ts': _Fixture.bytes([1, 2]),
          'https://media.example.test/second.ts': _Fixture.bytes(
            [3, 4],
            onFetch: () {
              if (!cancelledOnce) {
                cancelledOnce = true;
                token.cancel();
              }
            },
          ),
        });
        final partial = File(path.join(temporary.path, 'resume.m3u8.part'));
        await expectLater(
          _client(
            firstAdapter,
            limits: const HlsOfflineDownloadLimits(maximumConcurrency: 1),
          ).download(
            job: _job(path: '/vod.m3u8'),
            partialFile: partial,
            cancellation: token,
            onProgress: (_) {},
          ),
          throwsA(isA<DownloadTransferCancelled>()),
        );
        final directory = hlsSegmentDirectoryForPartialFile(partial);
        expect(
          await File(
            path.join(directory.path, 'segment-000000.ts'),
          ).readAsBytes(),
          [1, 2],
        );

        final restartedAdapter = _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(media),
          'https://media.example.test/second.ts': _Fixture.bytes([3, 4]),
        });
        final restartedProgress = <DownloadTransferProgress>[];
        await _client(
          restartedAdapter,
          limits: const HlsOfflineDownloadLimits(maximumConcurrency: 1),
        ).download(
          job: _job(path: '/vod.m3u8'),
          partialFile: partial,
          cancellation: DownloadCancellationToken(),
          onProgress: restartedProgress.add,
        );

        expect(
          restartedAdapter.requests.map((request) => request.uri.toString()),
          isNot(contains('https://media.example.test/first.ts')),
        );
        expect(restartedProgress.first.receivedBytes, 2);
        expect(restartedProgress.last.receivedBytes, 4);
        expect(await partial.exists(), isTrue);
      },
    );

    test('downloads and rewrites an initialization map once', () async {
      const media = '''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="init.mp4?token=secret"
#EXTINF:4,
one.m4s
#EXT-X-MAP:URI="init.mp4?token=secret"
#EXTINF:4,
two.m4s
#EXT-X-ENDLIST
''';
      final adapter = _FixtureAdapter({
        'https://media.example.test/vod.m3u8': _Fixture.text(media),
        'https://media.example.test/init.mp4?token=secret': _Fixture.bytes([
          0,
          0,
        ]),
        'https://media.example.test/one.m4s': _Fixture.bytes([1]),
        'https://media.example.test/two.m4s': _Fixture.bytes([2]),
      });
      final partial = File(path.join(temporary.path, 'mapped.m3u8.part'));

      await _client(adapter).download(
        job: _job(path: '/vod.m3u8'),
        partialFile: partial,
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      );

      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('init.mp4'),
        ),
        hasLength(1),
      );
      final local = await partial.readAsString();
      expect(local, contains('#EXT-X-MAP:URI="mapped.m3u8.hls/init-0000.mp4"'));
      expect(local, isNot(contains('token')));
    });

    test('never exceeds configured segment request concurrency', () async {
      const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
one.ts
#EXTINF:4,
two.ts
#EXTINF:4,
three.ts
#EXTINF:4,
four.ts
#EXT-X-ENDLIST
''';
      final adapter = _FixtureAdapter({
        'https://media.example.test/vod.m3u8': _Fixture.text(media),
        for (final name in ['one', 'two', 'three', 'four'])
          'https://media.example.test/$name.ts': _Fixture.bytes([
            1,
          ], fetchDelay: const Duration(milliseconds: 20)),
      });

      await _client(
        adapter,
        limits: const HlsOfflineDownloadLimits(maximumConcurrency: 2),
      ).download(
        job: _job(path: '/vod.m3u8'),
        partialFile: File(path.join(temporary.path, 'concurrent.m3u8.part')),
        cancellation: DownloadCancellationToken(),
        onProgress: (_) {},
      );

      expect(adapter.maximumActiveFetches, 2);
    });

    test('reports a positive sampled speed before final zero speed', () async {
      const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
slow.ts
#EXT-X-ENDLIST
''';
      final adapter = _FixtureAdapter({
        'https://media.example.test/vod.m3u8': _Fixture.text(media),
        'https://media.example.test/slow.ts': _Fixture.stream([
          (delay: Duration.zero, bytes: [1]),
          (delay: const Duration(milliseconds: 275), bytes: [2, 3]),
        ]),
      });
      final progress = <DownloadTransferProgress>[];

      await _client(adapter).download(
        job: _job(path: '/vod.m3u8'),
        partialFile: File(path.join(temporary.path, 'speed.m3u8.part')),
        cancellation: DownloadCancellationToken(),
        onProgress: progress.add,
      );

      expect(progress.any((sample) => sample.speedBytesPerSecond > 0), isTrue);
      expect(progress.last.speedBytesPerSecond, 0);
    });

    test('rejects HTTP 200 login pages in place of media segments', () async {
      const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
segment.ts
#EXT-X-ENDLIST
''';
      for (final fixture in [
        _Fixture.bytes(
          '<html><body>Sign in</body></html>'.codeUnits,
          contentType: 'text/html; charset=utf-8',
        ),
        _Fixture.bytes(
          '  <!doctype html><html>expired</html>'.codeUnits,
          contentType: 'application/octet-stream',
        ),
      ]) {
        await _expectCode(
          adapter: _FixtureAdapter({
            'https://media.example.test/vod.m3u8': _Fixture.text(media),
            'https://media.example.test/segment.ts': fixture,
          }),
          temporary: temporary,
          limits: const HlsOfflineDownloadLimits(),
          code: 'invalid_hls_media_response',
        );
      }
    });

    test('rejects live, encryption, byte ranges, and unsafe references', () async {
      final cases = <String, (String, String)>{
        'live': (
          '''#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\na.ts\n''',
          'hls_live_unsupported',
        ),
        'protected': (
          '''#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI="https://keys.test/key?secret=value"\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n''',
          'protected_hls_unsupported',
        ),
        'byte-range': (
          '''#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\n#EXT-X-BYTERANGE:10@0\na.ts\n#EXT-X-ENDLIST\n''',
          'hls_byterange_unsupported',
        ),
        'downgrade': (
          '''#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nhttp://media.test/a.ts?secret=value\n#EXT-X-ENDLIST\n''',
          'unsafe_hls_uri',
        ),
      };

      for (final entry in cases.entries) {
        final adapter = _FixtureAdapter({
          'https://media.example.test/vod.m3u8?root-secret=value':
              _Fixture.text(entry.value.$1),
        });
        Object? thrown;
        try {
          await _client(adapter).download(
            job: _job(path: '/vod.m3u8', query: 'root-secret=value'),
            partialFile: File(
              path.join(temporary.path, '${entry.key}.m3u8.part'),
            ),
            cancellation: DownloadCancellationToken(),
            requestHeaders: const {'Authorization': 'Bearer header-secret'},
            onProgress: (_) {},
          );
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<DownloadTransferException>());
        expect((thrown! as DownloadTransferException).code, entry.value.$2);
        expect(thrown.toString(), isNot(contains('secret')));
        expect(thrown.toString(), isNot(contains('Bearer')));
      }
    });

    test('rejects a master variant that requires external audio', () async {
      const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO="audio"
video.m3u8
''';
      await _expectCode(
        adapter: _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(master),
        }),
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(),
        code: 'unsupported_hls_rendition',
      );
    });

    test('rejects a master variant that requires external subtitles', () async {
      const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,SUBTITLES="subs"
video.m3u8
''';
      await _expectCode(
        adapter: _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(master),
        }),
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(),
        code: 'unsupported_hls_rendition',
      );
    });

    test('enforces playlist, variant, segment, and storage bounds', () async {
      const twoSegments = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4,
a.ts
#EXTINF:4,
b.ts
#EXT-X-ENDLIST
''';
      await _expectCode(
        adapter: _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(twoSegments),
        }),
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(maximumSegmentCount: 1),
        code: 'hls_segment_count_limit',
      );

      final segmentAdapter = _FixtureAdapter({
        'https://media.example.test/vod.m3u8': _Fixture.text(
          '''#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n''',
        ),
        'https://media.example.test/a.ts': _Fixture.bytes([1, 2, 3]),
      });
      await _expectCode(
        adapter: segmentAdapter,
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(maximumSegmentBytes: 2),
        code: 'hls_segment_limit',
      );

      final storageAdapter = _FixtureAdapter({
        'https://media.example.test/vod.m3u8': _Fixture.text(
          '''#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n''',
        ),
        'https://media.example.test/a.ts': _Fixture.bytes([1, 2, 3]),
      });
      await _expectCode(
        adapter: storageAdapter,
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(maximumTotalBytes: 2),
        code: 'hls_storage_limit',
      );

      const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1
one.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2
two.m3u8
''';
      await _expectCode(
        adapter: _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(master),
        }),
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(maximumVariantCount: 1),
        code: 'hls_variant_count_limit',
      );

      await _expectCode(
        adapter: _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(
            '''#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nchild.m3u8\n''',
          ),
        }),
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(maximumPlaylistCount: 1),
        code: 'hls_playlist_count_limit',
      );

      await _expectCode(
        adapter: _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.text(twoSegments),
        }),
        temporary: temporary,
        limits: const HlsOfflineDownloadLimits(maximumPlaylistBytes: 10),
        code: 'hls_playlist_limit',
      );
    });

    test(
      'rejects an HTTPS redirect downgrade without exposing its URL',
      () async {
        final adapter = _FixtureAdapter({
          'https://media.example.test/vod.m3u8': _Fixture.redirect(
            'http://unsafe.test/vod.m3u8?secret=value',
          ),
        });
        Object? thrown;
        try {
          await _client(adapter).download(
            job: _job(path: '/vod.m3u8'),
            partialFile: File(path.join(temporary.path, 'unsafe.m3u8.part')),
            cancellation: DownloadCancellationToken(),
            onProgress: (_) {},
          );
        } catch (error) {
          thrown = error;
        }
        expect(
          thrown,
          isA<DownloadTransferException>().having(
            (error) => error.code,
            'code',
            'unsafe_hls_uri',
          ),
        );
        expect(thrown.toString(), isNot(contains('secret')));
        expect(thrown.toString(), isNot(contains('unsafe.test')));
      },
    );
  });
}

HlsOfflineDownloadTransferClient _client(
  HttpClientAdapter adapter, {
  HlsOfflineDownloadLimits limits = const HlsOfflineDownloadLimits(),
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return HlsOfflineDownloadTransferClient(dio: dio, limits: limits);
}

Future<void> _expectCode({
  required _FixtureAdapter adapter,
  required Directory temporary,
  required HlsOfflineDownloadLimits limits,
  required String code,
}) async {
  await expectLater(
    _client(adapter, limits: limits).download(
      job: _job(path: '/vod.m3u8'),
      partialFile: File(
        path.join(temporary.path, 'bounded-${code.hashCode}.m3u8.part'),
      ),
      cancellation: DownloadCancellationToken(),
      onProgress: (_) {},
    ),
    throwsA(
      isA<DownloadTransferException>().having(
        (error) => error.code,
        'code',
        code,
      ),
    ),
  );
}

DownloadJob _job({
  String host = 'media.example.test',
  required String path,
  String? query,
  String? mimeType,
  String? quality,
}) {
  final now = DateTime.utc(2026, 8, 24);
  return DownloadJob(
    id: 'hls-job-${path.hashCode}',
    anilistMediaId: 1,
    episode: 1,
    seriesTitle: 'Example',
    sourceLabel: 'Provider',
    transport: DownloadTransport.https,
    status: DownloadJobStatus.downloading,
    sourceUri: Uri(scheme: 'https', host: host, path: path, query: query),
    relativePath: '1/episode.m3u8',
    mimeType: mimeType,
    quality: quality,
    queuePosition: 0,
    createdAt: now,
    updatedAt: now,
  );
}

Object? _header(Map<String, dynamic> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

final class _RecordingTransferClient implements DownloadTransferClient {
  int calls = 0;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  }) async {
    calls++;
    return const DownloadTransferResult(receivedBytes: 1, totalBytes: 1);
  }
}

final class _Fixture {
  const _Fixture({
    required this.status,
    required this.body,
    this.headers = const {},
    this.onFetch,
    this.fetchDelay = Duration.zero,
    this.chunks,
  });

  factory _Fixture.text(String text) => _Fixture.bytes(text.codeUnits);

  factory _Fixture.bytes(
    List<int> bytes, {
    void Function()? onFetch,
    Duration fetchDelay = Duration.zero,
    String? contentType,
  }) => _Fixture(
    status: HttpStatus.ok,
    body: bytes,
    headers: {
      HttpHeaders.contentLengthHeader: ['${bytes.length}'],
      if (contentType != null) HttpHeaders.contentTypeHeader: [contentType],
    },
    onFetch: onFetch,
    fetchDelay: fetchDelay,
  );

  factory _Fixture.stream(List<({Duration delay, List<int> bytes})> chunks) {
    final length = chunks.fold<int>(
      0,
      (sum, chunk) => sum + chunk.bytes.length,
    );
    return _Fixture(
      status: HttpStatus.ok,
      body: const [],
      headers: {
        HttpHeaders.contentLengthHeader: ['$length'],
      },
      chunks: chunks,
    );
  }

  factory _Fixture.redirect(String location) => _Fixture(
    status: HttpStatus.found,
    body: const [],
    headers: {
      HttpHeaders.locationHeader: [location],
      HttpHeaders.contentLengthHeader: ['0'],
    },
  );

  final int status;
  final List<int> body;
  final Map<String, List<String>> headers;
  final void Function()? onFetch;
  final Duration fetchDelay;
  final List<({Duration delay, List<int> bytes})>? chunks;
}

final class _CapturedRequest {
  const _CapturedRequest({required this.uri, required this.headers});

  final Uri uri;
  final Map<String, dynamic> headers;
}

final class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.fixtures);

  final Map<String, _Fixture> fixtures;
  final List<_CapturedRequest> requests = [];
  int _activeFetches = 0;
  int maximumActiveFetches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      _CapturedRequest(uri: options.uri, headers: Map.of(options.headers)),
    );
    final fixture = fixtures[options.uri.toString()];
    if (fixture == null) {
      throw StateError('Unexpected test request path: ${options.uri.path}');
    }
    fixture.onFetch?.call();
    _activeFetches++;
    maximumActiveFetches = _activeFetches > maximumActiveFetches
        ? _activeFetches
        : maximumActiveFetches;
    if (fixture.fetchDelay > Duration.zero) {
      await Future<void>.delayed(fixture.fetchDelay);
    }
    _activeFetches--;
    final chunks = fixture.chunks;
    if (chunks != null) {
      return ResponseBody(
        () async* {
          for (final chunk in chunks) {
            if (chunk.delay > Duration.zero) {
              await Future<void>.delayed(chunk.delay);
            }
            yield Uint8List.fromList(chunk.bytes);
          }
        }(),
        fixture.status,
        headers: fixture.headers,
      );
    }
    return ResponseBody.fromBytes(
      fixture.body,
      fixture.status,
      headers: fixture.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
