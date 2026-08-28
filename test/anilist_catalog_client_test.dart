import 'dart:io';

import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/data/anilist_catalog_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Dio interceptedDio(dynamic responseData) {
    final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<Map<String, dynamic>>(
              data: responseData as Map<String, dynamic>,
              requestOptions: options,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    return dio;
  }

  Dio rejectedAniListDio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response<Map<String, dynamic>>(
                data: const {
                  'errors': [
                    {
                      'message':
                          'The AniList API has been temporarily disabled.',
                      'status': 403,
                    },
                  ],
                },
                requestOptions: options,
                statusCode: 403,
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );
    return dio;
  }

  Dio graphQlErrorAniListDio() => interceptedDio({
    'errors': [
      {'message': 'Internal server error'},
    ],
  });

  Dio networkErrorAniListDio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: const SocketException('offline'),
            ),
          );
        },
      ),
    );
    return dio;
  }

  Dio kitsuDio(Map<String, dynamic> Function(RequestOptions) responseFor) {
    final dio = Dio(BaseOptions(baseUrl: 'https://kitsu.io/api/edge/'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<Map<String, dynamic>>(
              data: responseFor(options),
              requestOptions: options,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    return dio;
  }

  Dio jikanDio(Map<String, dynamic> Function(RequestOptions) responseFor) {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.jikan.moe/v4/'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<Map<String, dynamic>>(
              data: responseFor(options),
              requestOptions: options,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    return dio;
  }

  Dio failedAniZipDio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://hayase.ani.zip/v1/'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        ),
      ),
    );
    return dio;
  }

  Dio seededNamesThenOutageAniListDio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final body = options.data as Map<String, dynamic>;
          final query = body['query'] as String;
          if (query.contains('query AnimeDetails')) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                data: {
                  'data': {
                    'Media': {
                      ..._calendarMedia(100),
                      'studios': {
                        'nodes': [
                          {'id': 71, 'name': 'Studio Test'},
                        ],
                      },
                      'staff': {
                        'nodes': [
                          {
                            'id': 81,
                            'name': {'full': 'Staff Test'},
                            'image': {'large': null},
                          },
                        ],
                      },
                    },
                  },
                },
                requestOptions: options,
                statusCode: 200,
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response<Map<String, dynamic>>(
                data: const {
                  'errors': [
                    {'message': 'AniList unavailable'},
                  ],
                },
                requestOptions: options,
                statusCode: 503,
              ),
            ),
          );
        },
      ),
    );
    return dio;
  }

  Map<String, dynamic> kitsuAnimeResource() => {
    'type': 'anime',
    'id': '42',
    'attributes': {
      'canonicalTitle': 'Fallback Romaji',
      'titles': {'en': 'Fallback English', 'en_jp': 'Fallback Romaji'},
      'synopsis': 'Available during an AniList outage.',
      'episodeCount': 12,
      'averageRating': '84.5',
      'posterImage': {'large': 'https://example.com/poster.jpg'},
      'coverImage': {'large': 'https://example.com/banner.jpg'},
      'subtype': 'TV',
      'status': 'finished',
      'startDate': '2024-04-01',
      'episodeLength': 24,
      'youtubeVideoId': 'abcDEF_12-3',
      'abbreviatedTitles': ['Fallback'],
    },
    'relationships': {
      'mappings': {
        'data': [
          {'type': 'mappings', 'id': 'anilist-map'},
          {'type': 'mappings', 'id': 'mal-map'},
        ],
      },
      'categories': {
        'data': [
          {'type': 'categories', 'id': 'action'},
        ],
      },
    },
  };

  List<Map<String, dynamic>> kitsuIncluded() => [
    {
      'type': 'mappings',
      'id': 'anilist-map',
      'attributes': {'externalSite': 'anilist/anime', 'externalId': '100'},
    },
    {
      'type': 'mappings',
      'id': 'mal-map',
      'attributes': {'externalSite': 'myanimelist/anime', 'externalId': '200'},
    },
    {
      'type': 'categories',
      'id': 'action',
      'attributes': {'title': 'Action'},
    },
  ];

  Dio mappedKitsuDio() => kitsuDio(
    (_) => {
      'data': [kitsuAnimeResource()],
      'included': kitsuIncluded(),
    },
  );

  Map<String, dynamic> jikanAnimeResource() => {
    'mal_id': 200,
    'title': 'Fallback Romaji',
    'title_english': 'Fallback English',
    'title_japanese': 'Fallback Japanese',
    'synopsis': 'Mapped through the read-only Jikan backup.',
    'episodes': 12,
    'score': 8.6,
    'images': {
      'jpg': {'large_image_url': 'https://example.com/jikan-poster.jpg'},
    },
    'type': 'TV',
    'status': 'Finished Airing',
    'season': 'spring',
    'year': 2024,
    'duration': '24 min per ep',
    'genres': [
      {'mal_id': 1, 'name': 'Action'},
    ],
    'themes': <Map<String, dynamic>>[],
    'demographics': <Map<String, dynamic>>[],
    'aired': {'from': '2024-03-25T00:00:00+00:00'},
    'broadcast': {'day': 'Mondays', 'time': '12:00', 'timezone': 'Asia/Tokyo'},
  };

  group('AniListCatalogClient', () {
    test('strips HTML tags from descriptions', () async {
      final client = AniListCatalogClient(
        dio: interceptedDio({
          'data': {
            'Page': {
              'media': [
                {
                  'id': 1,
                  'idMal': null,
                  'title': {
                    'userPreferred': 'Test Anime',
                    'english': 'Test Anime English',
                    'romaji': 'Test Anime Romaji',
                  },
                  'description':
                      'A <b>bold</b> story.<br/>Second line.<br />'
                      'Entities: &amp; &quot; &#039;',
                  'episodes': 12,
                  'averageScore': 85,
                  'genres': <String>[],
                  'coverImage': {'extraLarge': null},
                  'bannerImage': null,
                  'format': 'TV',
                  'status': 'FINISHED',
                  'season': 'SPRING',
                  'seasonYear': 2023,
                  'duration': 24,
                  'synonyms': <String>[],
                  'nextAiringEpisode': null,
                },
              ],
            },
          },
        }),
      );

      final results = await client.trending();

      expect(results, hasLength(1));
      final desc = results.first.description;
      expect(desc, isNot(contains('<b>')));
      expect(desc, isNot(contains('<br')));
      expect(desc, contains('bold'));
      expect(desc, contains('Second line.'));
      expect(desc, contains('& " \''));
      expect(results.first.title, 'Test Anime English');
      expect(
        results.first.displayTitle(TitleLanguagePreference.romaji),
        'Test Anime Romaji',
      );
    });

    test('maps score from AniList 0–100 to 0.0–10.0', () async {
      final client = AniListCatalogClient(
        dio: interceptedDio({
          'data': {
            'Page': {
              'media': [
                {
                  'id': 2,
                  'idMal': null,
                  'title': {'userPreferred': 'Scored'},
                  'description': '',
                  'episodes': 1,
                  'averageScore': 80,
                  'genres': <String>[],
                  'coverImage': {'extraLarge': null},
                  'bannerImage': null,
                  'format': 'OVA',
                  'status': 'FINISHED',
                  'season': null,
                  'seasonYear': null,
                  'duration': 30,
                  'synonyms': <String>[],
                  'nextAiringEpisode': null,
                },
              ],
            },
          },
        }),
      );

      final results = await client.trending();

      expect(results.first.score, closeTo(8.0, 0.001));
    });

    test('returns null score when averageScore is absent', () async {
      final client = AniListCatalogClient(
        dio: interceptedDio({
          'data': {
            'Page': {
              'media': [
                {
                  'id': 3,
                  'idMal': null,
                  'title': {'userPreferred': 'Unscored'},
                  'description': '',
                  'episodes': null,
                  'averageScore': null,
                  'genres': <String>[],
                  'coverImage': <String, dynamic>{},
                  'bannerImage': null,
                  'format': null,
                  'status': null,
                  'season': null,
                  'seasonYear': null,
                  'duration': null,
                  'synonyms': <String>[],
                  'nextAiringEpisode': null,
                },
              ],
            },
          },
        }),
      );

      final results = await client.trending();

      expect(results.first.score, isNull);
      expect(results.first.episodes, isNull);
      expect(results.first.coverImageUrl, isNull);
    });

    test('seasonal uses correct quarter for each month', () async {
      // We can verify the query variables by checking that seasonal() doesn't
      // throw with a stubbed response regardless of the date.
      for (final month in [1, 4, 7, 10]) {
        final client = AniListCatalogClient(
          dio: interceptedDio({
            'data': {
              'Page': {'media': <dynamic>[]},
            },
          }),
        );

        await expectLater(
          client.seasonal(now: DateTime(2023, month)),
          completes,
        );
      }
    });

    test(
      'trending has a mapped cold-cache backup on AniList server outage',
      () async {
        final requests = <RequestOptions>[];
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((options) {
            requests.add(options);
            return {
              'data': [jikanAnimeResource()],
            };
          }),
        );

        final results = await client.trending();

        expect(results.map((item) => item.id), [100]);
        expect(results.single.idMal, 200);
        expect(results.single.score, 8.6);
        expect(requests.single.uri.path, endsWith('/top/anime'));
        expect(requests.single.queryParameters['filter'], 'airing');
      },
    );

    test(
      'Jikan mapping rejects a same-title Kitsu result with another MAL id',
      () async {
        final included = kitsuIncluded();
        final malAttributes = included[1]['attributes'] as Map<String, dynamic>;
        malAttributes['externalId'] = '201';
        final jikan = jikanAnimeResource()..['mal_id'] = 999999;
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          aniZipDio: failedAniZipDio(),
          kitsuDio: kitsuDio(
            (_) => {
              'data': [kitsuAnimeResource()],
              'included': included,
            },
          ),
          jikanDio: jikanDio(
            (_) => {
              'data': [jikan],
            },
          ),
        );

        final results = await client.trending();

        expect(results, isEmpty);
      },
    );

    test('Jikan mature metadata is rejected before Kitsu mapping', () async {
      final mature = jikanAnimeResource()
        ..['rating'] = 'Rx - Hentai'
        ..['genres'] = [
          {'mal_id': 12, 'name': 'Hentai'},
        ];
      var kitsuRequests = 0;
      final client = AniListCatalogClient(
        dio: rejectedAniListDio(),
        kitsuDio: kitsuDio((_) {
          kitsuRequests++;
          return {
            'data': [kitsuAnimeResource()],
            'included': kitsuIncluded(),
          };
        }),
        jikanDio: jikanDio(
          (_) => {
            'data': [mature],
          },
        ),
      );

      expect(await client.trending(), isEmpty);
      expect(kitsuRequests, 0);
    });

    test('Jikan to Kitsu mapping caps concurrent searches at four', () async {
      var active = 0;
      var maximumActive = 0;
      final asyncKitsu = Dio(BaseOptions(baseUrl: 'https://kitsu.io/api/edge/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              active++;
              if (active > maximumActive) maximumActive = active;
              await Future<void>.delayed(const Duration(milliseconds: 15));
              active--;
              handler.resolve(
                Response<Map<String, dynamic>>(
                  data: {
                    'data': [kitsuAnimeResource()],
                    'included': kitsuIncluded(),
                  },
                  requestOptions: options,
                  statusCode: 200,
                ),
              );
            },
          ),
        );
      final client = AniListCatalogClient(
        dio: rejectedAniListDio(),
        kitsuDio: asyncKitsu,
        jikanDio: jikanDio(
          (_) => {
            'data': List<Map<String, dynamic>>.generate(
              9,
              (_) => jikanAnimeResource(),
            ),
          },
        ),
      );

      expect(await client.trending(), hasLength(1));
      expect(maximumActive, greaterThan(1));
      expect(maximumActive, lessThanOrEqualTo(4));
    });

    test(
      'seasonal has a mapped cold-cache backup on AniList GraphQL error',
      () async {
        final requests = <RequestOptions>[];
        final client = AniListCatalogClient(
          dio: graphQlErrorAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((options) {
            requests.add(options);
            return {
              'data': [jikanAnimeResource()],
            };
          }),
        );

        final results = await client.seasonal(now: DateTime(2024, 4, 1));

        expect(results.map((item) => item.id), [100]);
        expect(requests.single.uri.path, endsWith('/seasons/2024/spring'));
      },
    );

    test(
      'discover has a filtered mapped cold-cache backup on network error',
      () async {
        final requests = <RequestOptions>[];
        final client = AniListCatalogClient(
          dio: networkErrorAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((options) {
            requests.add(options);
            if (options.uri.path.endsWith('/genres/anime')) {
              return {
                'data': [
                  {'mal_id': 1, 'name': 'Action'},
                ],
              };
            }
            return {
              'data': [jikanAnimeResource()],
            };
          }),
        );

        final results = await client.discover(
          const CatalogFilters(
            search: 'Fallback',
            genre: 'Action',
            tag: 'Action',
            format: 'TV',
            status: 'FINISHED',
            season: 'SPRING',
            year: 2024,
            minimumScore: 80,
            sort: 'SCORE_DESC',
          ),
        );

        expect(results.map((item) => item.id), [100]);
        final request = requests.singleWhere(
          (item) => item.uri.path == '/v4/anime',
        );
        expect(request.queryParameters['q'], 'Fallback');
        expect(request.queryParameters['genres'], 1);
        expect(request.queryParameters['type'], 'tv');
        expect(request.queryParameters['status'], 'complete');
        expect(request.queryParameters['min_score'], 8.0);
      },
    );

    test(
      'Discover include-adult mode keeps safe Jikan fallback results',
      () async {
        final jikanRequests = <RequestOptions>[];
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((request) {
            jikanRequests.add(request);
            return {
              'data': [jikanAnimeResource()],
            };
          }),
        );

        final results = await client.discover(
          const CatalogFilters(includeAdult: true),
        );

        expect(results, hasLength(1));
        expect(results.single.isAdult, isFalse);
        expect(jikanRequests, hasLength(1));
        expect(jikanRequests.single.queryParameters['sfw'], isTrue);
      },
    );

    test(
      'Discover include-adult mode reaches safe Kitsu when Jikan is down',
      () async {
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: kitsuDio(
            (_) => {
              'data': [kitsuAnimeResource()],
              'included': kitsuIncluded(),
            },
          ),
          jikanDio: jikanDio((_) => throw StateError('Jikan unavailable')),
        );

        final results = await client.discover(
          const CatalogFilters(includeAdult: true),
        );

        expect(results, hasLength(1));
        expect(results.single.isAdult, isFalse);
        expect(results.single.metadataSource, CatalogMetadataSource.kitsu);
      },
    );

    test(
      'Discover fallback returns no full-length TV matches for TV Short',
      () async {
        var jikanRequests = 0;
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((_) {
            jikanRequests++;
            return const {'data': <Map<String, dynamic>>[]};
          }),
        );

        final results = await client.discover(
          const CatalogFilters(format: 'TV_SHORT'),
        );

        expect(results, isEmpty);
        expect(jikanRequests, 0);
      },
    );

    test(
      'Discover fallback never treats an AniList tag as title text',
      () async {
        final requests = <RequestOptions>[];
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((options) {
            requests.add(options);
            return {
              'data': [
                {'mal_id': 1, 'name': 'Action'},
              ],
            };
          }),
        );

        final results = await client.discover(
          const CatalogFilters(search: 'Fallback', tag: 'Elf'),
        );

        expect(results, isEmpty);
        expect(requests, hasLength(1));
        expect(requests.single.uri.path, endsWith('/genres/anime'));
        expect(requests.single.queryParameters, isNot(contains('q')));
      },
    );

    test('airing calendar has a mapped cold-cache schedule backup', () async {
      final scheduleRequests = <RequestOptions>[];
      final singleEpisode = jikanAnimeResource()..['episodes'] = 1;
      final client = AniListCatalogClient(
        dio: rejectedAniListDio(),
        kitsuDio: mappedKitsuDio(),
        jikanDio: jikanDio((options) {
          scheduleRequests.add(options);
          return {
            'data': [singleEpisode],
          };
        }),
      );

      final results = await client.airingSchedule(
        from: DateTime.utc(2024, 4),
        to: DateTime.utc(2024, 4, 8),
      );

      expect(scheduleRequests, hasLength(1));
      expect(scheduleRequests.single.uri.path, endsWith('/schedules'));
      expect(
        scheduleRequests.single.queryParameters,
        isNot(contains('filter')),
      );
      expect(results, hasLength(1));
      expect(results.single.anime.id, 100);
      expect(results.single.episode, 1);
      expect(results.single.airingAt, DateTime.utc(2024, 4, 1, 3));
    });

    test(
      'calendar fallback follows bounded pagination and omits guessed episodes',
      () async {
        final requestedPages = <int>[];
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((options) {
            final page = options.queryParameters['page'] as int;
            requestedPages.add(page);
            if (page == 1) {
              return {
                'data': [jikanAnimeResource()],
                'pagination': {'has_next_page': true},
              };
            }
            return const {
              'data': <Map<String, dynamic>>[],
              'pagination': {'has_next_page': false},
            };
          }),
        );

        final results = await client.airingSchedule(
          from: DateTime.utc(2024, 4),
          to: DateTime.utc(2024, 4, 8),
        );

        expect(requestedPages, [1, 2]);
        expect(results, isEmpty);
      },
    );

    test('primary airing calendar excludes adult titles', () async {
      final adult = <String, dynamic>{..._calendarMedia(2), 'isAdult': true};
      final client = AniListCatalogClient(
        dio: interceptedDio({
          'data': {
            'Page': {
              'pageInfo': {'hasNextPage': false},
              'airingSchedules': [
                {
                  'episode': 3,
                  'airingAt': 1_800_000_001,
                  'media': _calendarMedia(1),
                },
                {'episode': 4, 'airingAt': 1_800_000_002, 'media': adult},
              ],
            },
          },
        }),
      );

      final results = await client.airingSchedule(
        from: DateTime.utc(2027),
        to: DateTime.utc(2028),
      );

      expect(results.map((entry) => entry.anime.id), [1]);
    });

    test('primary studio and staff collections exclude adult titles', () async {
      final safe = _calendarMedia(1);
      final adult = <String, dynamic>{..._calendarMedia(2), 'isAdult': true};
      final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final body = options.data as Map<String, dynamic>;
              final query = body['query'] as String;
              final data = query.contains('query StudioAnime')
                  ? {
                      'Studio': {
                        'media': {
                          'nodes': [safe, adult],
                        },
                      },
                    }
                  : {
                      'Staff': {
                        'staffMedia': {
                          'nodes': [safe, adult],
                        },
                      },
                    };
              handler.resolve(
                Response<Map<String, dynamic>>(
                  data: {'data': data},
                  requestOptions: options,
                  statusCode: 200,
                ),
              );
            },
          ),
        );
      final client = AniListCatalogClient(dio: dio);

      expect((await client.studioAnime(7)).map((anime) => anime.id), [1]);
      expect((await client.staffAnime(8)).map((anime) => anime.id), [1]);
    });

    test(
      'search falls back to mapped Kitsu results during AniList outage',
      () async {
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: kitsuDio(
            (_) => {
              'data': [kitsuAnimeResource()],
              'included': kitsuIncluded(),
            },
          ),
        );

        final results = await client.search('Fallback');

        expect(results, hasLength(1));
        final anime = results.single;
        expect(anime.id, 100);
        expect(anime.idMal, 200);
        expect(anime.title, 'Fallback English');
        expect(anime.titleRomaji, 'Fallback Romaji');
        expect(anime.score, closeTo(8.45, 0.001));
        expect(anime.genres, ['Action']);
        expect(anime.season, 'SPRING');
      },
    );

    test(
      'details falls back by AniList mapping during AniList outage',
      () async {
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: kitsuDio((options) {
            if (options.uri.path.endsWith('/mappings')) {
              expect(options.queryParameters['include'], 'item');
              return {
                'data': [
                  {
                    'type': 'mappings',
                    'id': 'anilist-map',
                    'relationships': {
                      'item': {
                        'data': {'type': 'anime', 'id': '42'},
                      },
                    },
                  },
                ],
              };
            }
            return {'data': kitsuAnimeResource(), 'included': kitsuIncluded()};
          }),
        );

        final anime = await client.details(100);

        expect(anime.id, 100);
        expect(anime.idMal, 200);
        expect(anime.episodes, 12);
        expect(anime.durationMinutes, 24);
        expect(anime.trailer?.provider.name, 'youtube');
        expect(anime.trailer?.videoId, 'abcDEF_12-3');
      },
    );

    test(
      'fallback rejects adult categories even when Kitsu rating is incorrect',
      () async {
        final resource = kitsuAnimeResource();
        final attributes = resource['attributes'] as Map<String, dynamic>;
        attributes['nsfw'] = false;
        attributes['ageRating'] = 'PG';
        final relationships = resource['relationships'] as Map<String, dynamic>;
        relationships['categories'] = {
          'data': [
            {'type': 'categories', 'id': 'adult-category'},
          ],
        };
        final included = kitsuIncluded()
          ..add({
            'type': 'categories',
            'id': 'adult-category',
            'attributes': {'title': 'Yaoi'},
          });
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: kitsuDio(
            (_) => {
              'data': [resource],
              'included': included,
            },
          ),
        );

        final results = await client.search('Incorrectly rated title');

        expect(results, isEmpty);
      },
    );

    test(
      'ignores malformed media entries without losing valid results',
      () async {
        final client = AniListCatalogClient(
          dio: interceptedDio({
            'data': {
              'Page': {
                'media': [
                  null,
                  {
                    'id': 4,
                    'idMal': null,
                    'title': {'userPreferred': 'Valid'},
                    'description': '',
                    'episodes': 1,
                    'averageScore': null,
                    'genres': [null, 'Comedy'],
                    'coverImage': <String, dynamic>{},
                    'bannerImage': null,
                    'format': 'TV',
                    'status': 'FINISHED',
                    'season': null,
                    'seasonYear': null,
                    'duration': 3,
                    'synonyms': [null, 'Still valid'],
                    'nextAiringEpisode': null,
                  },
                ],
              },
            },
          }),
        );

        final results = await client.search('Valid');

        expect(results, hasLength(1));
        expect(results.single.genres, ['Comedy']);
        expect(results.single.synonyms, ['Still valid']);
      },
    );

    test('discover forwards the complete filter set to AniList', () async {
      final requestBodies = <Map<String, dynamic>>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestBodies.add(
                Map<String, dynamic>.from(options.data as Map<String, dynamic>),
              );
              handler.resolve(
                Response<Map<String, dynamic>>(
                  data: const {
                    'data': {
                      'Page': {'media': <dynamic>[]},
                    },
                  },
                  requestOptions: options,
                  statusCode: 200,
                ),
              );
            },
          ),
        );
      final client = AniListCatalogClient(dio: dio);

      await client.discover(
        const CatalogFilters(
          search: 'Frieren',
          genre: 'Fantasy',
          tag: 'Elf',
          format: 'TV',
          status: 'RELEASING',
          season: 'FALL',
          year: 2026,
          minimumScore: 80,
          includeAdult: true,
          sort: 'SCORE_DESC',
        ),
      );

      expect(
        requestBodies.map(
          (body) => (body['variables'] as Map<String, dynamic>)['page'],
        ),
        [1, 2],
      );
      for (var index = 0; index < requestBodies.length; index++) {
        expect(requestBodies[index]['variables'], {
          'page': index + 1,
          'search': 'Frieren',
          'genre': 'Fantasy',
          'tag': 'Elf',
          'format': 'TV',
          'status': 'RELEASING',
          'season': 'FALL',
          'year': 2026,
          'minimumScore': 80,
          'sort': ['SCORE_DESC'],
        });
      }
    });

    test('discover omits unused nullable arguments', () async {
      final requestBodies = <Map<String, dynamic>>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestBodies.add(
                Map<String, dynamic>.from(options.data as Map<String, dynamic>),
              );
              handler.resolve(
                Response<Map<String, dynamic>>(
                  data: const {
                    'data': {
                      'Page': {'media': <dynamic>[]},
                    },
                  },
                  requestOptions: options,
                  statusCode: 200,
                ),
              );
            },
          ),
        );
      final client = AniListCatalogClient(dio: dio);

      await client.discover(const CatalogFilters());

      expect(requestBodies, hasLength(2));
      for (var index = 0; index < requestBodies.length; index++) {
        expect(requestBodies[index]['variables'], {
          'page': index + 1,
          'isAdult': false,
          'sort': ['POPULARITY_DESC'],
        });
      }
    });

    test(
      'discover combines exactly two pages into 60 ordered results',
      () async {
        final requestedPages = <int>[];
        final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final body = options.data as Map<String, dynamic>;
                final variables = body['variables'] as Map<String, dynamic>;
                final page = variables['page'] as int;
                requestedPages.add(page);
                final firstId = page == 1 ? 1 : 31;
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    data: {
                      'data': {
                        'Page': {
                          'media': List.generate(
                            30,
                            (index) => _catalogMedia(firstId + index),
                          ),
                        },
                      },
                    },
                    requestOptions: options,
                    statusCode: 200,
                  ),
                );
              },
            ),
          );
        final client = AniListCatalogClient(dio: dio);

        final results = await client.discover(const CatalogFilters());

        expect(requestedPages, [1, 2]);
        expect(results, hasLength(60));
        expect(
          results.map((anime) => anime.id),
          List.generate(60, (i) => i + 1),
        );
      },
    );

    test(
      'discover logical page two requests AniList pages three and four',
      () async {
        final requestedPages = <int>[];
        final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final body = options.data as Map<String, dynamic>;
                final variables = body['variables'] as Map<String, dynamic>;
                requestedPages.add(variables['page'] as int);
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    data: const {
                      'data': {
                        'Page': {'media': <Map<String, dynamic>>[]},
                      },
                    },
                    requestOptions: options,
                    statusCode: 200,
                  ),
                );
              },
            ),
          );
        final client = AniListCatalogClient(dio: dio);

        await client.discover(const CatalogFilters(), page: 2);

        expect(requestedPages, [3, 4]);
      },
    );

    test(
      'discover keeps the first occurrence of duplicate anime ids',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final body = options.data as Map<String, dynamic>;
                final variables = body['variables'] as Map<String, dynamic>;
                final page = variables['page'] as int;
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    data: {
                      'data': {
                        'Page': {
                          'media': page == 1
                              ? [
                                  _catalogMedia(1),
                                  _catalogMedia(2, title: 'Page one copy'),
                                ]
                              : [
                                  _catalogMedia(2, title: 'Page two copy'),
                                  _catalogMedia(3),
                                ],
                        },
                      },
                    },
                    requestOptions: options,
                    statusCode: 200,
                  ),
                );
              },
            ),
          );
        final client = AniListCatalogClient(dio: dio);

        final results = await client.discover(const CatalogFilters());

        expect(results.map((anime) => anime.id), [1, 2, 3]);
        expect(results[1].title, 'Page one copy');
      },
    );

    test(
      'discover retries AniList illegal combinations without sort',
      () async {
        final requests = <Map<String, dynamic>>[];
        final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final body = Map<String, dynamic>.from(
                  options.data as Map<String, dynamic>,
                );
                requests.add(
                  Map<String, dynamic>.from(
                    body['variables'] as Map<String, dynamic>,
                  ),
                );
                final hasSort = (body['variables'] as Map).containsKey('sort');
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    data: hasSort
                        ? const {
                            'errors': [
                              {
                                'message':
                                    'Illegal operation and value combination',
                              },
                            ],
                          }
                        : const {
                            'data': {
                              'Page': {'media': <dynamic>[]},
                            },
                          },
                    requestOptions: options,
                    statusCode: 200,
                  ),
                );
              },
            ),
          );
        final client = AniListCatalogClient(dio: dio);

        await expectLater(
          client.discover(
            const CatalogFilters(genre: 'Fantasy', sort: 'SCORE_DESC'),
          ),
          completion(isEmpty),
        );

        expect(requests, hasLength(4));
        expect(
          requests
              .where((request) => request.containsKey('sort'))
              .map((request) => request['page']),
          [1, 2],
        );
        expect(
          requests
              .where((request) => !request.containsKey('sort'))
              .map((request) => request['page']),
          [1, 2],
        );
        expect(requests.last['genre'], 'Fantasy');
      },
    );

    test(
      'airing calendar follows AniList pagination beyond the first 50',
      () async {
        final requestedPages = <int>[];
        final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final body = options.data as Map<String, dynamic>;
                final variables = body['variables'] as Map<String, dynamic>;
                final page = variables['page'] as int;
                requestedPages.add(page);
                handler.resolve(
                  Response<Map<String, dynamic>>(
                    data: {
                      'data': {
                        'Page': {
                          'pageInfo': {'hasNextPage': page == 1},
                          'airingSchedules': [
                            {
                              'episode': page,
                              'airingAt': 1_800_000_000 + page,
                              'media': _calendarMedia(page),
                            },
                          ],
                        },
                      },
                    },
                    requestOptions: options,
                    statusCode: 200,
                  ),
                );
              },
            ),
          );
        final client = AniListCatalogClient(dio: dio);

        final entries = await client.airingSchedule(
          from: DateTime(2027),
          to: DateTime(2027, 1, 8),
        );

        expect(requestedPages, [1, 2]);
        expect(entries.map((entry) => entry.anime.id), [1, 2]);
      },
    );

    test(
      'cold studio and staff outage never substitutes unrelated provider IDs',
      () async {
        final client = AniListCatalogClient(
          dio: rejectedAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio(
            (_) => throw StateError('No name lookup should be attempted.'),
          ),
        );

        await expectLater(client.studioAnime(987654), completion(isEmpty));
        await expectLater(client.staffAnime(456789), completion(isEmpty));
      },
    );

    test(
      'studio and staff backup reject the first fuzzy provider-name result',
      () async {
        final jikanRequests = <String>[];
        final client = AniListCatalogClient(
          dio: seededNamesThenOutageAniListDio(),
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((options) {
            jikanRequests.add(options.uri.path);
            if (options.uri.path.endsWith('/producers')) {
              return {
                'data': [
                  {'mal_id': 999, 'title': 'Different Studio'},
                ],
              };
            }
            if (options.uri.path.endsWith('/people')) {
              return {
                'data': [
                  {'mal_id': 998, 'name': 'Different Person'},
                ],
              };
            }
            throw StateError('No unrelated collection should be requested.');
          }),
        );

        await client.details(100);

        expect(await client.studioAnime(71), isEmpty);
        expect(await client.staffAnime(81), isEmpty);
        expect(jikanRequests, ['/v4/producers', '/v4/people']);
      },
    );

    test('studio backup rejects ambiguous duplicate exact names', () async {
      final jikanRequests = <String>[];
      final client = AniListCatalogClient(
        dio: seededNamesThenOutageAniListDio(),
        kitsuDio: mappedKitsuDio(),
        jikanDio: jikanDio((options) {
          jikanRequests.add(options.uri.path);
          return {
            'data': [
              {'mal_id': 701, 'title': 'Studio Test'},
              {'mal_id': 702, 'title': 'Studio Test'},
            ],
          };
        }),
      );

      await client.details(100);

      expect(await client.studioAnime(71), isEmpty);
      expect(jikanRequests, ['/v4/producers']);
    });

    test(
      'exposed studio and staff collections use name-mapped Jikan backups',
      () async {
        final aniList = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final body = options.data as Map<String, dynamic>;
                final query = body['query'] as String;
                if (query.contains('query AnimeDetails')) {
                  handler.resolve(
                    Response<Map<String, dynamic>>(
                      data: {
                        'data': {
                          'Media': {
                            ..._calendarMedia(100),
                            'trailer': {
                              'site': 'youtube',
                              'id': 'abcDEF_12-3',
                              'thumbnail': 'https://images.example/trailer.jpg',
                            },
                            'studios': {
                              'nodes': [
                                {'id': 71, 'name': 'Studio Test'},
                              ],
                            },
                            'staff': {
                              'nodes': [
                                {
                                  'id': 81,
                                  'name': {'full': 'Staff Test'},
                                  'image': {'large': null},
                                },
                              ],
                            },
                          },
                        },
                      },
                      requestOptions: options,
                      statusCode: 200,
                    ),
                  );
                  return;
                }
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                    response: Response<Map<String, dynamic>>(
                      data: const {
                        'errors': [
                          {'message': 'AniList unavailable'},
                        ],
                      },
                      requestOptions: options,
                      statusCode: 503,
                    ),
                  ),
                );
              },
            ),
          );
        final jikanRequests = <String>[];
        final client = AniListCatalogClient(
          dio: aniList,
          kitsuDio: mappedKitsuDio(),
          jikanDio: jikanDio((options) {
            jikanRequests.add(options.uri.path);
            if (options.uri.path.endsWith('/producers')) {
              return {
                'data': [
                  {'mal_id': 701, 'title': 'Studio Test'},
                ],
              };
            }
            if (options.uri.path.endsWith('/people')) {
              return {
                'data': [
                  {'mal_id': 801, 'name': 'Staff Test'},
                ],
              };
            }
            if (options.uri.path.endsWith('/people/801/full')) {
              return {
                'data': {
                  'anime': [
                    {'anime': jikanAnimeResource()},
                  ],
                  'voices': <Map<String, dynamic>>[],
                },
              };
            }
            if (options.uri.path.endsWith('/anime')) {
              return {
                'data': [jikanAnimeResource()],
              };
            }
            throw StateError('Unexpected Jikan request: ${options.uri}');
          }),
        );

        final details = await client.details(100);
        expect(details.studios.single.name, 'Studio Test');
        expect(details.staff.single.name, 'Staff Test');
        expect(details.trailer?.provider.name, 'youtube');
        expect(details.trailer?.videoId, 'abcDEF_12-3');

        final studio = await client.studioAnime(71);
        final staff = await client.staffAnime(81);

        expect(studio.map((item) => item.id), [100]);
        expect(staff.map((item) => item.id), [100]);
        expect(
          jikanRequests,
          containsAll(<String>[
            '/v4/producers',
            '/v4/anime',
            '/v4/people',
            '/v4/people/801/full',
          ]),
        );
      },
    );
  });
}

Map<String, dynamic> _calendarMedia(int id) => {
  'id': id,
  'idMal': id + 100,
  'title': {
    'userPreferred': 'Show $id',
    'english': 'Show $id',
    'romaji': 'Show $id',
  },
  'description': '',
  'episodes': 12,
  'averageScore': 80,
  'genres': <String>[],
  'coverImage': {'extraLarge': null},
  'bannerImage': null,
  'format': 'TV',
  'status': 'RELEASING',
  'season': 'WINTER',
  'seasonYear': 2027,
  'duration': 24,
  'synonyms': <String>[],
  'nextAiringEpisode': {'episode': id + 1},
  'isAdult': false,
};

Map<String, dynamic> _catalogMedia(int id, {String? title}) => {
  ..._calendarMedia(id),
  'title': {
    'userPreferred': title ?? 'Show $id',
    'english': title ?? 'Show $id',
    'romaji': title ?? 'Show $id',
  },
};
