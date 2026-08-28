import 'package:anime_tv/features/streaming/data/stremio_torrent_release_source.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses generic Stremio torrent metadata and dub/sub labels', () {
    final releases = StremioTorrentReleaseSource.parseStreams({
      'streams': [
        {
          'name': 'User source\n1080p HDR',
          'title':
              '[Group] Example Episode 01 HEVC\n'
              '👤 532 💾 647.82 MB ⚙️ UserProvider\n'
              'Dubbed / Dual Audio / Multi Subs',
          'infoHash': 'f03841b6b24585b1571df6b0c930d9946047058f',
          'fileIdx': 15,
          'behaviorHints': {'filename': 'Example - S01E01.mkv'},
        },
        {
          'name': 'User source\n720p',
          'title':
              '[SubsPlease] Example - 01 (720p)\n'
              '👤 39 💾 771.35 MB ⚙️ UserProvider',
          'infoHash': 'ab4369b560243237f9371ce896ee02ed00027b95',
          'fileIdx': 0,
        },
      ],
    });

    expect(releases, hasLength(2));
    expect(releases.first.quality, '1080p');
    expect(releases.first.codec, 'HEVC');
    expect(releases.first.isHdr, isTrue);
    expect(releases.first.isDubbed, isTrue);
    expect(releases.first.hasSubtitles, isTrue);
    expect(releases.first.preferredFileIndex, 15);
    expect(releases.first.seeders, 532);
    expect(releases.first.sizeLabel, '647.82 MB');
    expect(releases.first.provider, 'UserProvider');
    expect(releases.last.isDubbed, isFalse);
    expect(releases.last.hasSubtitles, isTrue);
  });

  test('ignores direct-only and malformed stream entries', () {
    final releases = StremioTorrentReleaseSource.parseStreams({
      'streams': [
        {'name': 'Direct', 'url': 'https://example.com/video.mp4'},
        {'name': 'Broken', 'infoHash': 'not-a-hash'},
      ],
    });

    expect(releases, isEmpty);
  });

  test('recognizes common dub tags without matching unrelated words', () {
    final releases = StremioTorrentReleaseSource.parseStreams({
      'streams': [
        {
          'name': '[Group] Example S01E01 [DUB] 1080p',
          'infoHash': '1111111111111111111111111111111111111111',
        },
        {
          'name': '[Group] Example S01E02 English Audio 1080p',
          'infoHash': '2222222222222222222222222222222222222222',
        },
        {
          'name': '[Group] Example S01E03 adubious-title 1080p',
          'infoHash': '3333333333333333333333333333333333333333',
        },
      ],
    });

    expect(releases.map((release) => release.isDubbed), [true, true, false]);
  });

  test('keeps the installed manifest source stable across episode hashes', () {
    const sourceId = 'stremio:example.com/addon/manifest.json';
    final first = StremioTorrentReleaseSource.parseStreams({
      'streams': [
        {
          'name': 'Example Episode 01',
          'infoHash': '1111111111111111111111111111111111111111',
        },
      ],
    }, sourceId: sourceId);
    final second = StremioTorrentReleaseSource.parseStreams({
      'streams': [
        {
          'name': 'Example Episode 02',
          'infoHash': '2222222222222222222222222222222222222222',
        },
      ],
    }, sourceId: sourceId);

    expect(first.single.provider, isNull);
    expect(second.single.provider, isNull);
    expect(first.single.sourceId, sourceId);
    expect(second.single.sourceId, sourceId);
  });

  test('rejects redirects instead of following them to another host', () async {
    final addonDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 302,
              headers: Headers.fromMap({
                'location': ['https://127.0.0.1/private'],
              }),
            ),
          ),
        ),
      );
    final kitsuDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'data': [
                  {
                    'relationships': {
                      'item': {
                        'data': {'id': '42'},
                      },
                    },
                  },
                ],
              },
            ),
          ),
        ),
      );
    final source = StremioTorrentReleaseSource(
      manifestUrl: 'https://example.com/addon/manifest.json',
      addonDio: addonDio,
      kitsuDio: kitsuDio,
      targetValidator: (_) async {},
    );

    await expectLater(
      source.search(
        const EpisodeReference(
          anilistMediaId: 1,
          malMediaId: 2,
          title: 'Example',
          episode: 1,
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an oversized untrusted stream response', () async {
    final addonDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data:
                  '{"streams":[],"padding":"'
                  '${List.filled(2049, List.filled(1024, 'x').join()).join()}"}',
            ),
          ),
        ),
      );
    final kitsuDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'data': [
                  {
                    'relationships': {
                      'item': {
                        'data': {'id': '42'},
                      },
                    },
                  },
                ],
              },
            ),
          ),
        ),
      );
    final source = StremioTorrentReleaseSource(
      manifestUrl: 'https://example.com/addon/manifest.json',
      addonDio: addonDio,
      kitsuDio: kitsuDio,
      targetValidator: (_) async {},
    );

    await expectLater(
      source.search(
        const EpisodeReference(
          anilistMediaId: 1,
          malMediaId: 2,
          title: 'Example',
          episode: 1,
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'uses manifest series capability and requests included MAL mapping data',
    () async {
      final addonRequests = <Uri>[];
      final addonDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              addonRequests.add(options.uri);
              if (options.uri.path.endsWith('/manifest.json')) {
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: const {
                      'types': ['series'],
                      'resources': [
                        {
                          'name': 'stream',
                          'types': ['series'],
                          'idPrefixes': ['kitsu'],
                        },
                      ],
                    },
                  ),
                );
                return;
              }
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const {
                    'streams': [
                      {
                        'name': '1080p',
                        'infoHash': 'f03841b6b24585b1571df6b0c930d9946047058f',
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
      final kitsuDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.queryParameters['include'], 'item');
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const {
                    'data': [
                      {
                        'relationships': {
                          'item': {
                            'data': {'id': '42'},
                          },
                        },
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
      final cinemetaDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(
                requestOptions: options,
                message: 'Cinemeta must remain lazy when Kitsu succeeds.',
              ),
            ),
          ),
        );
      final validated = <Uri>[];
      final source = StremioTorrentReleaseSource(
        manifestUrl:
            'https://example.com/private/manifest.json?private=do-not-copy',
        addonDio: addonDio,
        kitsuDio: kitsuDio,
        cinemetaDio: cinemetaDio,
        targetValidator: (uri) async => validated.add(uri),
      );

      final releases = await source.search(
        const EpisodeReference(
          anilistMediaId: 1,
          malMediaId: 2,
          title: 'Example',
          episode: 7,
        ),
      );

      expect(releases, hasLength(1));
      expect(addonRequests, hasLength(2));
      expect(
        addonRequests.last.path,
        '/private/stream/series/kitsu%3A42%3A7.json',
      );
      expect(addonRequests.last.query, isEmpty);
      expect(validated, addonRequests);
    },
  );

  test('falls back from Kitsu to year-matched IMDb series episode', () async {
    final addonRequests = <Uri>[];
    final addonDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            addonRequests.add(options.uri);
            if (options.uri.path.endsWith('/manifest.json')) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const {
                    'resources': [
                      {
                        'name': 'stream',
                        'types': ['anime', 'series'],
                        'idPrefixes': ['tt', 'kitsu'],
                      },
                    ],
                  },
                ),
              );
              return;
            }
            if (options.uri.path.contains('/kitsu%3A')) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 502,
                  data: 'upstream unavailable',
                ),
              );
              return;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: const {
                  'streams': [
                    {
                      'name': '1080p',
                      'infoHash': 'f03841b6b24585b1571df6b0c930d9946047058f',
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
    final kitsuDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'data': [
                  {
                    'relationships': {
                      'item': {
                        'data': {'id': '1697'},
                      },
                    },
                  },
                ],
              },
            ),
          ),
        ),
      );
    final cinemetaRequests = <Uri>[];
    final cinemetaDio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            cinemetaRequests.add(options.uri);
            if (options.uri.path.contains('/catalog/')) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const {
                    'metas': [
                      {
                        'id': 'tt1086236',
                        'name': 'Lucky Star',
                        'releaseInfo': '2007-2024',
                      },
                    ],
                  },
                ),
              );
              return;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: const {
                  'meta': {
                    'videos': [
                      {
                        'id': 'tt1086236:1:1',
                        'season': 1,
                        'episode': 1,
                        'released': '2007-04-08T00:00:00.000Z',
                      },
                      {
                        'id': 'tt1086236:2:1',
                        'season': 2,
                        'episode': 1,
                        'released': '2024-04-08T00:00:00.000Z',
                      },
                    ],
                  },
                },
              ),
            );
          },
        ),
      );
    final source = StremioTorrentReleaseSource(
      manifestUrl:
          'https://addon.example/user-path/manifest.json?token=private',
      addonDio: addonDio,
      kitsuDio: kitsuDio,
      cinemetaDio: cinemetaDio,
      targetValidator: (_) async {},
    );

    final releases = await source.search(
      const EpisodeReference(
        anilistMediaId: 1887,
        malMediaId: 1887,
        title: 'Lucky Star',
        year: 2024,
        episode: 1,
      ),
    );

    expect(releases, hasLength(1));
    expect(
      addonRequests.last.path,
      '/user-path/stream/series/tt1086236%3A2%3A1.json',
    );
    expect(addonRequests.skip(1).every((uri) => uri.query.isEmpty), isTrue);
    expect(cinemetaRequests, hasLength(2));
    expect(
      cinemetaRequests.every(
        (uri) =>
            uri.host == 'v3-cinemeta.strem.io' &&
            !uri.toString().contains('private'),
      ),
      isTrue,
    );
  });
}
