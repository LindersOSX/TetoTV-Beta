import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/features/marketplace/data/web_playback_proxy.dart';
import 'package:anime_tv/features/player/application/library_playback_proxy.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SameOriginLibraryProxyUpstream', () {
    test(
      'rejects a cross-origin redirect before forwarding credentials',
      () async {
        final requests = <WebProxyUpstreamRequest>[];
        final upstream = SameOriginLibraryProxyUpstream(
          origin: Uri.parse('http://192.168.1.20:8096'),
          hopFetcher: (request) async {
            requests.add(request);
            return _response(
              request,
              status: HttpStatus.found,
              headers: {
                HttpHeaders.locationHeader: [
                  'https://attacker.example/collect',
                ],
              },
            );
          },
        );

        await expectLater(
          upstream.fetch(
            Uri.parse('http://192.168.1.20:8096/Videos/1/stream'),
            headers: const {'Authorization': 'MediaBrowser Token="secret"'},
          ),
          throwsFormatException,
        );

        expect(requests, hasLength(1));
        expect(requests.single.uri.host, '192.168.1.20');
        expect(requests.single.headers['Authorization'], contains('secret'));
      },
    );

    test('permits only configured same-origin private media references', () {
      final origin = privateLibraryPlaybackOrigin(
        Uri.parse('http://192.168.1.20:8096/jellyfin'),
      );
      expect(
        resolveSameOriginLibraryReference(
          origin,
          Uri.parse('http://192.168.1.20:8096/Videos/1/master.m3u8'),
          '../segments/1.ts',
        ),
        Uri.parse('http://192.168.1.20:8096/Videos/segments/1.ts'),
      );
      expect(
        () => resolveSameOriginLibraryReference(
          origin,
          Uri.parse('http://192.168.1.20:8096/Videos/1/master.m3u8'),
          'https://attacker.example/1.ts',
        ),
        throwsFormatException,
      );
      expect(
        () => privateLibraryPlaybackOrigin(
          Uri.parse('http://media.example/Videos/1/stream'),
        ),
        throwsFormatException,
      );
    });
  });

  group('LibraryPlaybackProxy', () {
    test(
      'keeps authenticated HLS segments and subtitles behind loopback',
      () async {
        final source = Uri.parse(
          'http://192.168.1.20:8096/Videos/1/master.m3u8',
        );
        final firstSubtitle = Uri.parse(
          'http://192.168.1.20:8096/Videos/1/Subtitles/0/Stream.vtt',
        );
        final secondSubtitle = Uri.parse(
          'http://192.168.1.20:8096/Videos/1/Subtitles/1/Stream.vtt',
        );
        final segment = Uri.parse(
          'http://192.168.1.20:8096/Videos/1/segment-1.ts',
        );
        final requests = <WebProxyUpstreamRequest>[];
        final proxy = LibraryPlaybackProxy(
          hopFetcher: (request) async {
            requests.add(request);
            if (request.uri == source) {
              return _response(
                request,
                contentType: 'application/vnd.apple.mpegurl',
                bytes: utf8.encode('''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10,
segment-1.ts
#EXT-X-ENDLIST
'''),
              );
            }
            if (request.uri == firstSubtitle || request.uri == secondSubtitle) {
              return _response(
                request,
                contentType: 'text/vtt',
                bytes: utf8.encode('WEBVTT\n\n00:00.000 --> 00:01.000\nHello'),
              );
            }
            expect(request.uri, segment);
            return _response(
              request,
              contentType: 'video/mp2t',
              bytes: const [1, 2, 3, 4],
            );
          },
        );
        final raw = _request(
          source: source,
          isCompatibilityStream: true,
          externalSubtitle: firstSubtitle.toString(),
          subtitleTracks: [
            LibraryExternalSubtitleTrack(
              uri: firstSubtitle,
              label: 'English',
              language: 'eng',
              contentType: 'text/vtt',
            ),
            LibraryExternalSubtitleTrack(
              uri: secondSubtitle,
              label: 'Signs',
              language: 'eng',
              contentType: 'text/vtt',
            ),
          ],
        );

        final protected = await proxy.protect(raw);
        addTearDown(() => protected.playbackLease?.close());

        expect(protected.source.host, InternetAddress.loopbackIPv4.address);
        expect(protected.isCompatibilityStream, isTrue);
        expect(protected.headers, isEmpty);
        expect(protected.source.toString(), isNot(contains('secret-token')));
        expect(protected.externalSubtitleTracks, hasLength(2));
        expect(
          protected.externalSubtitleTracks,
          everyElement(
            isA<LibraryExternalSubtitleTrack>().having(
              (track) => track.uri.host,
              'loopback host',
              InternetAddress.loopbackIPv4.address,
            ),
          ),
        );
        expect(
          Uri.parse(protected.externalSubtitle!).host,
          InternetAddress.loopbackIPv4.address,
        );

        final manifest = utf8.decode(
          (await _localRequest(protected.source)).body,
        );
        final segmentReference = manifest
            .split('\n')
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
        final segmentResponse = await _localRequest(
          Uri.parse(segmentReference),
        );
        expect(segmentResponse.body, [1, 2, 3, 4]);
        for (final track in protected.externalSubtitleTracks) {
          expect(
            utf8.decode((await _localRequest(track.uri)).body),
            startsWith('WEBVTT'),
          );
        }

        expect(requests, isNotEmpty);
        expect(
          requests,
          everyElement(
            isA<WebProxyUpstreamRequest>()
                .having((request) => request.uri.scheme, 'scheme', 'http')
                .having((request) => request.uri.host, 'host', '192.168.1.20')
                .having((request) => request.uri.port, 'port', 8096)
                .having(
                  (request) => request.headers['Authorization'],
                  'authorization',
                  contains('secret-token'),
                ),
          ),
        );
      },
    );

    test('rejects a cross-origin HLS resource before requesting it', () async {
      final source = Uri.parse('http://192.168.1.20:8096/Videos/1/master.m3u8');
      final requests = <WebProxyUpstreamRequest>[];
      final proxy = LibraryPlaybackProxy(
        hopFetcher: (request) async {
          requests.add(request);
          return _response(
            request,
            contentType: 'application/vnd.apple.mpegurl',
            bytes: utf8.encode('''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10,
https://attacker.example/collect.ts
#EXT-X-ENDLIST
'''),
          );
        },
      );

      await expectLater(
        proxy.protect(_request(source: source)),
        throwsFormatException,
      );

      expect(requests, hasLength(1));
      expect(requests.single.uri, source);
      expect(
        requests.single.headers['Authorization'],
        contains('secret-token'),
      );
    });

    test('leaves Android content URIs unchanged', () async {
      final request = _request(
        source: Uri.parse('content://media/external/video/media/7'),
        headers: const {},
      );

      expect(
        await const LibraryPlaybackProxy().protect(request),
        same(request),
      );
    });
  });
}

LibraryPlaybackRequest _request({
  required Uri source,
  Map<String, String> headers = const {
    'Authorization': 'MediaBrowser Token="secret-token"',
  },
  String? externalSubtitle,
  List<LibraryExternalSubtitleTrack> subtitleTracks = const [],
  bool isCompatibilityStream = false,
}) => LibraryPlaybackRequest(
  source: source,
  title: 'Private episode',
  releaseName: 'Private episode.mkv',
  streamLabel: 'Jellyfin',
  checkpointKey: 'local:0123456789abcdef',
  timelineIdentity: 'private-server-item-7',
  headers: headers,
  externalSubtitle: externalSubtitle,
  externalSubtitleTracks: subtitleTracks,
  isCompatibilityStream: isCompatibilityStream,
);

WebProxyUpstreamResponse _response(
  WebProxyUpstreamRequest request, {
  int status = HttpStatus.ok,
  String contentType = '',
  Map<String, List<String>> headers = const {},
  List<int> bytes = const [],
}) => WebProxyUpstreamResponse(
  statusCode: status,
  uri: request.uri,
  requestHeaders: request.headers,
  headers: {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    if (contentType.isNotEmpty) HttpHeaders.contentTypeHeader: [contentType],
    HttpHeaders.contentLengthHeader: ['${bytes.length}'],
  },
  body: Stream.value(bytes),
);

Future<_LocalResponse> _localRequest(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    final body = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    return _LocalResponse(response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

class _LocalResponse {
  const _LocalResponse(this.status, this.body);

  final int status;
  final List<int> body;
}
