import 'dart:convert';

import 'package:anime_tv/features/catalog/data/anime_title_logo_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('title-logo lookup flow', () {
    test('fresh positive cache avoids both artwork services', () async {
      final cache = _FakeCacheStore(
        fresh: _positiveCache(
          url: 'https://assets.fanart.tv/title.png',
          source: AnimeTitleLogoSource.fanartTvHd,
          tvdbId: 101,
        ),
      );
      var networkRequests = 0;
      final client = AnimeTitleLogoClient(
        aniZipDio: _failureDio(
          'https://api.ani.zip/',
          onRequest: () => networkRequests++,
        ),
        fanartDio: _failureDio(
          'https://webservice.fanart.tv/v3.2/',
          onRequest: () => networkRequests++,
        ),
        cacheStore: cache,
        fanartApiKey: 'project-key',
      );

      final logo = await client.lookup(123);

      expect(logo?.url.toString(), 'https://assets.fanart.tv/title.png');
      expect(logo?.source, AnimeTitleLogoSource.fanartTvHd);
      expect(networkRequests, 0);
      expect(cache.reads, [(key: 'title-logo:v7:anilist:123', stale: false)]);
      expect(cache.writes, isEmpty);
    });

    test('fresh negative cache avoids repeated missing-logo lookups', () async {
      final cache = _FakeCacheStore(fresh: _negativeCache());
      var networkRequests = 0;
      final client = AnimeTitleLogoClient(
        aniZipDio: _failureDio(
          'https://api.ani.zip/',
          onRequest: () => networkRequests++,
        ),
        cacheStore: cache,
      );

      expect(await client.lookup(44), isNull);
      expect(networkRequests, 0);
      expect(cache.writes, isEmpty);
    });

    test('AniZip direct Clearlogo is returned and positively cached', () async {
      final cache = _FakeCacheStore();
      final aniZipRequests = <RequestOptions>[];
      var fanartRequests = 0;
      final client = AnimeTitleLogoClient(
        aniZipDio: _responseDio('https://api.ani.zip/', (request) {
          aniZipRequests.add(request);
          return {
            'mappings': {'thetvdb_id': '777'},
            'images': [
              {
                'coverType': 'Clearlogo',
                'url': 'https://artworks.thetvdb.com/lower-priority.webp',
              },
              {
                'coverType': 'Clearlogo',
                'url': 'https://artworks.thetvdb.com/show-title.png',
              },
            ],
          };
        }),
        fanartDio: _failureDio(
          'https://webservice.fanart.tv/v3.2/',
          onRequest: () => fanartRequests++,
        ),
        cacheStore: cache,
        fanartApiKey: 'project-key',
      );

      final logo = await client.lookup(321);

      expect(aniZipRequests, hasLength(1));
      expect(aniZipRequests.single.path, 'mappings');
      expect(aniZipRequests.single.queryParameters, {'anilist_id': 321});
      expect(fanartRequests, 1);
      expect(
        logo?.url.toString(),
        'https://artworks.thetvdb.com/show-title.png',
      );
      expect(logo?.source, AnimeTitleLogoSource.aniZip);
      expect(logo?.tvdbId, 777);
      expect(cache.writes, hasLength(1));
      expect(cache.writes.single.maxAge, const Duration(days: 14));
      expect(cache.writes.single.value['found'], isTrue);
      expect(
        (cache.writes.single.value['logo'] as Map)['url'],
        'https://artworks.thetvdb.com/show-title.png',
      );
    });

    test('AniZip JSON text is decoded before resolving Clearlogo', () async {
      final cache = _FakeCacheStore();
      final client = AnimeTitleLogoClient(
        aniZipDio: _responseDio(
          'https://api.ani.zip/',
          (_) => jsonEncode({
            'mappings': {'thetvdb_id': 80177},
            'images': [
              {
                'coverType': 'Clearlogo',
                'url': 'https://artworks.thetvdb.com/banners/show-title.png',
              },
            ],
          }),
        ),
        cacheStore: cache,
      );

      final logo = await client.lookup(1887);

      expect(
        logo?.url.toString(),
        'https://artworks.thetvdb.com/banners/show-title.png',
      );
      expect(logo?.tvdbId, 80177);
      expect(cache.writes.single.value['found'], isTrue);
    });

    test('AniZip UTF-8 bytes are decoded before resolving Clearlogo', () async {
      final client = AnimeTitleLogoClient(
        aniZipDio: _responseDio(
          'https://api.ani.zip/',
          (_) => utf8.encode(
            jsonEncode({
              'images': [
                {
                  'coverType': 'Clearlogo',
                  'url': 'https://artworks.thetvdb.com/byte-title.webp',
                },
              ],
            }),
          ),
        ),
        cacheStore: _FakeCacheStore(),
      );

      expect(
        (await client.lookup(1890))?.url.toString(),
        'https://artworks.thetvdb.com/byte-title.webp',
      );
    });

    test(
      'oversized AniZip JSON text is rejected without being cached',
      () async {
        final cache = _FakeCacheStore();
        final client = AnimeTitleLogoClient(
          aniZipDio: _responseDio(
            'https://api.ani.zip/',
            (_) =>
                ' ' * (AnimeTitleLogoClient.maximumMetadataResponseBytes + 1),
          ),
          cacheStore: cache,
        );

        expect(await client.lookup(1891), isNull);
        expect(cache.writes, isEmpty);
      },
    );

    test(
      'known non-English AniZip logo is replaced by English Fanart',
      () async {
        final cache = _FakeCacheStore();
        var fanartRequests = 0;
        final client = AnimeTitleLogoClient(
          aniZipDio: _responseDio(
            'https://api.ani.zip/',
            (_) => {
              'mappings': {'thetvdb_id': 778},
              'images': [
                {
                  'coverType': 'Clearlogo',
                  'url': 'https://artworks.thetvdb.com/japanese.png',
                  'lang': 'ja',
                },
              ],
            },
          ),
          fanartDio: _responseDio('https://webservice.fanart.tv/v3.2/', (_) {
            fanartRequests++;
            return {
              'clearlogo': [
                {'url': 'https://assets.fanart.tv/english.png', 'lang': 'en'},
              ],
            };
          }),
          cacheStore: cache,
          fanartApiKey: 'project-key',
        );

        final logo = await client.lookup(322);

        expect(fanartRequests, 1);
        expect(logo?.url.toString(), 'https://assets.fanart.tv/english.png');
        expect(logo?.languageCode, 'en');
      },
    );

    test(
      'language-matched Fanart HD logo supersedes matching AniZip',
      () async {
        final client = AnimeTitleLogoClient(
          aniZipDio: _responseDio(
            'https://api.ani.zip/',
            (_) => {
              'mappings': {'thetvdb_id': 781},
              'images': [
                {
                  'coverType': 'Clearlogo',
                  'url': 'https://artworks.thetvdb.com/english.png',
                  'lang': 'en',
                },
              ],
            },
          ),
          fanartDio: _responseDio(
            'https://webservice.fanart.tv/v3.2/',
            (_) => {
              'hdtvlogo': [
                {
                  'url': 'https://assets.fanart.tv/english-hd.png',
                  'lang': 'en',
                },
              ],
            },
          ),
          cacheStore: _FakeCacheStore(),
          fanartApiKey: 'project-key',
        );

        final logo = await client.lookup(325);

        expect(logo?.url.toString(), 'https://assets.fanart.tv/english-hd.png');
        expect(logo?.source, AnimeTitleLogoSource.fanartTvHd);
        expect(logo?.languageCode, 'en');
      },
    );

    test(
      'language-unknown AniZip logo is replaced by English Fanart',
      () async {
        final client = AnimeTitleLogoClient(
          aniZipDio: _responseDio(
            'https://api.ani.zip/',
            (_) => {
              'mappings': {'thetvdb_id': 779},
              'images': [
                {
                  'coverType': 'Clearlogo',
                  'url': 'https://artworks.thetvdb.com/unknown-language.png',
                },
              ],
            },
          ),
          fanartDio: _responseDio(
            'https://webservice.fanart.tv/v3.2/',
            (_) => {
              'hdtvlogo': [
                {
                  'url': 'https://assets.fanart.tv/english-hd.png',
                  'lang': 'en',
                },
              ],
            },
          ),
          cacheStore: _FakeCacheStore(),
          fanartApiKey: 'project-key',
        );

        final logo = await client.lookup(323);

        expect(logo?.url.toString(), 'https://assets.fanart.tv/english-hd.png');
        expect(logo?.languageCode, 'en');
      },
    );

    test(
      'unknown AniZip logo remains fallback when Fanart is not English',
      () async {
        final client = AnimeTitleLogoClient(
          aniZipDio: _responseDio(
            'https://api.ani.zip/',
            (_) => {
              'mappings': {'thetvdb_id': 780},
              'images': [
                {
                  'coverType': 'Clearlogo',
                  'url': 'https://artworks.thetvdb.com/unknown-language.png',
                },
              ],
            },
          ),
          fanartDio: _responseDio(
            'https://webservice.fanart.tv/v3.2/',
            (_) => {
              'hdtvlogo': [
                {
                  'url': 'https://assets.fanart.tv/also-unknown.png',
                  'lang': '00',
                },
              ],
            },
          ),
          cacheStore: _FakeCacheStore(),
          fanartApiKey: 'project-key',
        );

        final logo = await client.lookup(324);

        expect(
          logo?.url.toString(),
          'https://artworks.thetvdb.com/unknown-language.png',
        );
        expect(logo?.languageCode, isNull);
      },
    );

    test(
      'Fanart is an optional fallback after AniZip supplies TVDB ID',
      () async {
        final cache = _FakeCacheStore();
        final fanartRequests = <RequestOptions>[];
        final client = AnimeTitleLogoClient(
          aniZipDio: _responseDio(
            'https://api.ani.zip/',
            (_) => {
              'mappings': {'thetvdb_id': 2468},
              'images': [
                {
                  'coverType': 'Fanart',
                  'url': 'https://artworks.thetvdb.com/not-a-clear-logo.jpg',
                },
              ],
            },
          ),
          fanartDio: _responseDio('https://webservice.fanart.tv/v3.2/', (
            request,
          ) {
            fanartRequests.add(request);
            return {
              'hdtvlogo': [
                {
                  'url': 'https://assets.fanart.tv/title.png',
                  'lang': 'en',
                  'likes': '5',
                },
              ],
            };
          }),
          cacheStore: cache,
          fanartApiKey: ' project-key ',
          fanartClientKey: ' personal-key ',
        );

        final logo = await client.lookup(1357);

        expect(fanartRequests, hasLength(1));
        expect(fanartRequests.single.path, 'tv/2468');
        expect(fanartRequests.single.queryParameters, {
          'api_key': 'project-key',
          'client_key': 'personal-key',
        });
        expect(logo?.url.toString(), 'https://assets.fanart.tv/title.png');
        expect(logo?.source, AnimeTitleLogoSource.fanartTvHd);
        expect(logo?.tvdbId, 2468);
        expect(cache.writes.single.maxAge, const Duration(days: 14));
      },
    );

    test('Fanart is never called without a project API key', () async {
      final cache = _FakeCacheStore();
      var fanartRequests = 0;
      final client = AnimeTitleLogoClient(
        aniZipDio: _responseDio(
          'https://api.ani.zip/',
          (_) => {
            'mappings': {'thetvdb_id': 99},
            'images': const [],
          },
        ),
        fanartDio: _failureDio(
          'https://webservice.fanart.tv/v3.2/',
          onRequest: () => fanartRequests++,
        ),
        cacheStore: cache,
        fanartApiKey: '   ',
      );

      expect(await client.lookup(55), isNull);
      expect(fanartRequests, 0);
      expect(cache.writes.single.value['found'], isFalse);
      expect(cache.writes.single.maxAge, const Duration(hours: 12));
    });

    test('AniZip outage falls back to an expired safe cached logo', () async {
      final cache = _FakeCacheStore(
        stale: _positiveCache(
          url: 'https://artworks.thetvdb.com/still-safe.png',
          source: AnimeTitleLogoSource.aniZip,
          tvdbId: 808,
        ),
      );
      final client = AnimeTitleLogoClient(
        aniZipDio: _failureDio('https://api.ani.zip/'),
        cacheStore: cache,
      );

      final logo = await client.lookup(909);

      expect(
        logo?.url.toString(),
        'https://artworks.thetvdb.com/still-safe.png',
      );
      expect(cache.reads, [
        (key: 'title-logo:v7:anilist:909', stale: false),
        (key: 'title-logo:v7:anilist:909', stale: true),
      ]);
      expect(cache.writes, isEmpty);
    });

    test('Fanart outage also falls back to an expired cached logo', () async {
      final cache = _FakeCacheStore(
        stale: _positiveCache(
          url: 'https://assets.fanart.tv/fanart.png',
          source: AnimeTitleLogoSource.fanartTv,
          tvdbId: 73,
        ),
      );
      final client = AnimeTitleLogoClient(
        aniZipDio: _responseDio(
          'https://api.ani.zip/',
          (_) => {
            'mappings': {'thetvdb_id': 73},
            'images': const [],
          },
        ),
        fanartDio: _failureDio('https://webservice.fanart.tv/v3.2/'),
        cacheStore: cache,
        fanartApiKey: 'project-key',
      );

      final logo = await client.lookup(74);

      expect(logo?.url.toString(), 'https://assets.fanart.tv/fanart.png');
      expect(cache.writes, isEmpty);
    });

    test('unsafe stale data is ignored when services fail', () async {
      final cache = _FakeCacheStore(
        stale: _positiveCache(
          url: 'file:///private/title.png',
          source: AnimeTitleLogoSource.aniZip,
        ),
      );
      final client = AnimeTitleLogoClient(
        aniZipDio: _failureDio('https://api.ani.zip/'),
        cacheStore: cache,
      );

      expect(await client.lookup(75), isNull);
    });

    test('concurrent lookups for one title share a single request', () async {
      final cache = _FakeCacheStore();
      var requests = 0;
      final client = AnimeTitleLogoClient(
        aniZipDio: _responseDio('https://api.ani.zip/', (_) {
          requests++;
          return {
            'images': [
              {
                'coverType': 'Clearlogo',
                'url': 'https://artworks.thetvdb.com/coalesced.png',
              },
            ],
          };
        }),
        cacheStore: cache,
      );

      final first = client.lookup(76);
      final second = client.lookup(76);
      final results = await Future.wait([first, second]);

      expect(identical(first, second), isTrue);
      expect(requests, 1);
      expect(results.map((logo) => logo?.url.toString()), {
        'https://artworks.thetvdb.com/coalesced.png',
      });
      expect(cache.writes, hasLength(1));
    });

    test('invalid AniList IDs do not touch cache or network', () async {
      final cache = _FakeCacheStore();
      var requests = 0;
      final client = AnimeTitleLogoClient(
        aniZipDio: _failureDio(
          'https://api.ani.zip/',
          onRequest: () => requests++,
        ),
        cacheStore: cache,
      );

      expect(await client.lookup(0), isNull);
      expect(await client.lookup(-1), isNull);
      expect(cache.reads, isEmpty);
      expect(requests, 0);
    });
  });

  group('AniZip clear-logo parsing', () {
    test('selects a safe transparent PNG and preserves TVDB mapping', () {
      final logo = AnimeTitleLogoClient.parseAniZipLogo({
        'images': [
          {
            'coverType': 'Fanart',
            'url': 'https://artworks.thetvdb.com/show.jpg',
          },
          {
            'coverType': 'Clearlogo',
            'url': 'https://artworks.thetvdb.com/show-logo.png',
          },
        ],
      }, tvdbId: 123);

      expect(logo?.url.toString(), endsWith('show-logo.png'));
      expect(logo?.source, AnimeTitleLogoSource.aniZip);
      expect(logo?.tvdbId, 123);
    });

    test('prefers an English logo when AniZip supplies language metadata', () {
      final logo = AnimeTitleLogoClient.parseAniZipLogo({
        'images': [
          {
            'coverType': 'Clearlogo',
            'url': 'https://artworks.thetvdb.com/japanese.png',
            'lang': 'ja',
            'likes': '999',
          },
          {
            'coverType': 'Clearlogo',
            'url': 'https://artworks.thetvdb.com/english.png',
            'language': {'iso_639_1': 'en'},
            'likes': '1',
          },
        ],
      });

      expect(logo?.url.toString(), endsWith('english.png'));
      expect(logo?.languageCode, 'en');
    });

    test('Romaji preference selects Japanese artwork and not English', () {
      final logo = AnimeTitleLogoClient.parseAniZipLogo({
        'images': [
          {
            'coverType': 'Clearlogo',
            'url': 'https://artworks.thetvdb.com/english.png',
            'lang': 'en',
            'likes': '999',
          },
          {
            'coverType': 'Clearlogo',
            'url': 'https://artworks.thetvdb.com/japanese.png',
            'language': {'iso_639_1': 'ja'},
            'likes': '1',
          },
        ],
      }, preferredLanguage: 'ja');

      expect(logo?.url.toString(), endsWith('japanese.png'));
      expect(logo?.languageCode, 'ja');
    });

    test(
      'Romaji preference returns no logo when only English is available',
      () {
        final logo = AnimeTitleLogoClient.parseAniZipLogo({
          'images': [
            {
              'coverType': 'Clearlogo',
              'url': 'https://artworks.thetvdb.com/english.png',
              'lang': 'en',
            },
          ],
        }, preferredLanguage: 'ja');

        expect(logo, isNull);
      },
    );

    test('rejects non-HTTPS and executable-looking artwork', () {
      final logo = AnimeTitleLogoClient.parseAniZipLogo({
        'images': [
          {'coverType': 'Clearlogo', 'url': 'http://example.com/logo.png'},
          {'coverType': 'Clearlogo', 'url': 'https://example.com/logo.svg'},
          {
            'coverType': 'Clearlogo',
            'url': 'https://attacker.example/logo.png',
          },
        ],
      });

      expect(logo, isNull);
    });
  });

  group('Fanart.tv clear-logo parsing', () {
    test('prefers English HD TV logos then likes', () {
      final logo = AnimeTitleLogoClient.parseFanartLogo({
        'hdtvlogo': [
          {
            'url': 'https://assets.fanart.tv/japanese.png',
            'lang': 'ja',
            'likes': '500',
          },
          {
            'url': 'https://assets.fanart.tv/english-low.png',
            'lang': 'en',
            'likes': '2',
          },
          {
            'url': 'https://assets.fanart.tv/english-high.png',
            'lang': 'en',
            'likes': '9',
          },
        ],
        'clearlogo': [
          {
            'url': 'https://assets.fanart.tv/standard.png',
            'lang': 'en',
            'likes': '100',
          },
        ],
      }, tvdbId: 456);

      expect(logo?.url.toString(), endsWith('english-high.png'));
      expect(logo?.source, AnimeTitleLogoSource.fanartTvHd);
      expect(logo?.tvdbId, 456);
    });

    test('falls back to standard clearlogo', () {
      final logo = AnimeTitleLogoClient.parseFanartLogo({
        'clearlogo': [
          {
            'url': 'https://assets.fanart.tv/standard.png',
            'lang': '00',
            'likes': '1',
          },
        ],
      }, tvdbId: 789);

      expect(logo?.source, AnimeTitleLogoSource.fanartTv);
    });

    test('English standard logo beats a Japanese HD logo', () {
      final logo = AnimeTitleLogoClient.parseFanartLogo({
        'hdtvlogo': [
          {
            'url': 'https://assets.fanart.tv/japanese-hd.png',
            'lang': 'ja',
            'likes': '900',
          },
        ],
        'clearlogo': [
          {
            'url': 'https://assets.fanart.tv/english-standard.png',
            'lang': 'en',
            'likes': '1',
          },
        ],
      }, tvdbId: 790);

      expect(logo?.url.toString(), endsWith('english-standard.png'));
      expect(logo?.source, AnimeTitleLogoSource.fanartTv);
      expect(logo?.languageCode, 'en');
    });

    test('Romaji preference selects a Japanese Fanart logo', () {
      final logo = AnimeTitleLogoClient.parseFanartLogo(
        {
          'hdtvlogo': [
            {
              'url': 'https://assets.fanart.tv/english.png',
              'lang': 'en',
              'likes': '999',
            },
            {
              'url': 'https://assets.fanart.tv/japanese.png',
              'lang': 'ja',
              'likes': '1',
            },
          ],
        },
        tvdbId: 791,
        preferredLanguage: 'ja',
      );

      expect(logo?.url.toString(), endsWith('japanese.png'));
      expect(logo?.languageCode, 'ja');
    });
  });

  test('cached logo decoder rejects unsafe URLs', () {
    expect(
      AnimeTitleLogo.fromJson({
        'url': 'file:///private/logo.png',
        'source': AnimeTitleLogoSource.aniZip.name,
      }),
      isNull,
    );
    expect(
      AnimeTitleLogo.fromJson({
        'url': 'https://attacker.example/logo.png',
        'source': AnimeTitleLogoSource.aniZip.name,
      }),
      isNull,
    );
  });
}

Map<String, dynamic> _positiveCache({
  required String url,
  required AnimeTitleLogoSource source,
  int? tvdbId,
}) => {
  'schema': 7,
  'found': true,
  'logo': {'url': url, 'source': source.name, 'tvdbId': ?tvdbId},
};

Map<String, dynamic> _negativeCache() => {'schema': 7, 'found': false};

Dio _responseDio(
  String baseUrl,
  Object? Function(RequestOptions request) response,
) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<Object?>(
          data: response(options),
          requestOptions: options,
          statusCode: 200,
        ),
      ),
    ),
  );
  return dio;
}

Dio _failureDio(String baseUrl, {void Function()? onRequest}) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call();
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        );
      },
    ),
  );
  return dio;
}

class _FakeCacheStore implements AnimeTitleLogoCacheStore {
  _FakeCacheStore({this.fresh, this.stale});

  final Map<String, dynamic>? fresh;
  final Map<String, dynamic>? stale;
  final reads = <({String key, bool stale})>[];
  final writes =
      <({String key, Map<String, dynamic> value, Duration maxAge})>[];

  @override
  Future<Map<String, dynamic>?> read(
    String key, {
    bool allowExpired = false,
  }) async {
    reads.add((key: key, stale: allowExpired));
    return allowExpired ? stale : fresh;
  }

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    required Duration maxAge,
  }) async {
    writes.add((key: key, value: value, maxAge: maxAge));
  }
}
