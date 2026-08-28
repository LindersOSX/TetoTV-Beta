import 'package:anime_tv/features/catalog/data/anilist_catalog_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AniList remains primary and no backup is contacted', () async {
    var backupRequests = 0;
    final client = AniListCatalogClient(
      dio: _responseDio(
        'https://graphql.anilist.co',
        (_) => {
          'data': {
            'Page': {
              'media': [_aniListAnime(aniListId: 101, malId: 201)],
            },
          },
        },
      ),
      kitsuDio: _countingFailureDio(
        'https://kitsu.io/api/edge/',
        () => backupRequests++,
      ),
      jikanDio: _countingFailureDio(
        'https://api.jikan.moe/v4/',
        () => backupRequests++,
      ),
      aniZipDio: _countingFailureDio(
        'https://hayase.ani.zip/v1/',
        () => backupRequests++,
      ),
    );

    final results = await client.search('Primary');

    expect(results.single.id, 101);
    expect(results.single.metadataSource, CatalogMetadataSource.aniList);
    expect(backupRequests, 0);
  });

  test('retryable AniList failure uses mapped Kitsu first', () async {
    var jikanRequests = 0;
    final client = AniListCatalogClient(
      dio: _aniListFailureDio(status: 503, message: 'Service unavailable'),
      kitsuDio: _responseDio(
        'https://kitsu.io/api/edge/',
        (_) => {
          'data': [_kitsuAnime()],
          'included': _kitsuIncluded(aniListId: 102, malId: 202),
        },
      ),
      jikanDio: _countingFailureDio(
        'https://api.jikan.moe/v4/',
        () => jikanRequests++,
      ),
    );

    final results = await client.search('Kitsu-chain-102');

    expect(results.single.id, 102);
    expect(results.single.idMal, 202);
    expect(results.single.episodes, 12);
    expect(results.single.coverImageUrl, 'https://images.example/kitsu.jpg');
    expect(results.single.metadataSource, CatalogMetadataSource.kitsu);
    expect(jikanRequests, 0);
  });

  test(
    'Kitsu outage advances to independent Jikan and AniZip backup',
    () async {
      var mappingRequests = 0;
      final client = AniListCatalogClient(
        dio: _networkFailureDio('https://graphql.anilist.co'),
        kitsuDio: _networkFailureDio('https://kitsu.io/api/edge/'),
        jikanDio: _responseDio(
          'https://api.jikan.moe/v4/',
          (_) => {
            'data': [_jikanAnime(malId: 203), _jikanAnime(malId: 203)],
          },
        ),
        aniZipDio: _responseDio('https://hayase.ani.zip/v1/', (request) {
          mappingRequests++;
          expect(request.queryParameters['mal_id'], 203);
          return {'anilist_id': 103, 'mal_id': 203};
        }),
      );

      final results = await client.search('Jikan-chain-203');

      expect(
        results,
        hasLength(1),
        reason: 'canonical AniList IDs deduplicate',
      );
      expect(results.single.id, 103);
      expect(results.single.idMal, 203);
      expect(results.single.episodes, 24);
      expect(results.single.coverImageUrl, 'https://images.example/jikan.jpg');
      expect(results.single.metadataSource, CatalogMetadataSource.jikan);
      expect(mappingRequests, inInclusiveRange(1, 2));
    },
  );

  test(
    'details use Jikan title artwork and episode metadata if Kitsu fails',
    () async {
      final client = AniListCatalogClient(
        dio: _networkFailureDio('https://graphql.anilist.co'),
        kitsuDio: _networkFailureDio('https://kitsu.io/api/edge/'),
        jikanDio: _responseDio('https://api.jikan.moe/v4/', (request) {
          expect(request.uri.path, endsWith('/anime/204/full'));
          return {'data': _jikanAnime(malId: 204)};
        }),
        aniZipDio: _responseDio('https://hayase.ani.zip/v1/', (request) {
          expect(request.queryParameters['anilist_id'], 104);
          return {'anilist_id': 104, 'mal_id': 204};
        }),
      );

      final anime = await client.details(104);

      expect(anime.id, 104);
      expect(anime.idMal, 204);
      expect(anime.title, 'Backup title');
      expect(anime.episodes, 24);
      expect(anime.coverImageUrl, 'https://images.example/jikan.jpg');
      expect(anime.metadataSource, CatalogMetadataSource.jikan);
    },
  );

  test(
    'Home reaches Kitsu if both AniList and Jikan are unavailable',
    () async {
      final client = AniListCatalogClient(
        dio: _networkFailureDio('https://graphql.anilist.co'),
        kitsuDio: _responseDio(
          'https://kitsu.io/api/edge/',
          (_) => {
            'data': [_kitsuAnime()],
            'included': _kitsuIncluded(aniListId: 105, malId: 205),
          },
        ),
        jikanDio: _networkFailureDio('https://api.jikan.moe/v4/'),
      );

      final results = await client.trending(page: 97);

      expect(results.single.id, 105);
      expect(results.single.metadataSource, CatalogMetadataSource.kitsu);
    },
  );

  test(
    'Discover reaches its second mapped backup without duplicate IDs',
    () async {
      final client = AniListCatalogClient(
        dio: _networkFailureDio('https://graphql.anilist.co'),
        kitsuDio: _responseDio(
          'https://kitsu.io/api/edge/',
          (_) => {
            'data': [_kitsuAnime(), _kitsuAnime()],
            'included': _kitsuIncluded(aniListId: 106, malId: 206),
          },
        ),
        jikanDio: _networkFailureDio('https://api.jikan.moe/v4/'),
      );

      final results = await client.discover(
        const CatalogFilters(genre: 'Action', format: 'TV'),
        page: 98,
      );

      expect(results, hasLength(1));
      expect(results.single.id, 106);
      expect(results.single.metadataSource, CatalogMetadataSource.kitsu);
    },
  );

  test('nonretryable AniList rejection never contacts a backup', () async {
    var backupRequests = 0;
    final client = AniListCatalogClient(
      dio: _aniListFailureDio(status: 401, message: 'Invalid access token'),
      kitsuDio: _countingFailureDio(
        'https://kitsu.io/api/edge/',
        () => backupRequests++,
      ),
      jikanDio: _countingFailureDio(
        'https://api.jikan.moe/v4/',
        () => backupRequests++,
      ),
      aniZipDio: _countingFailureDio(
        'https://hayase.ani.zip/v1/',
        () => backupRequests++,
      ),
    );

    await expectLater(
      client.search('Do not retry'),
      throwsA(
        isA<AniListCatalogException>()
            .having((error) => error.retryable, 'retryable', isFalse)
            .having(
              (error) => error.message,
              'message',
              'Invalid access token',
            ),
      ),
    );
    expect(backupRequests, 0);
  });
}

Dio _responseDio(
  String baseUrl,
  Map<String, dynamic> Function(RequestOptions request) response,
) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<Map<String, dynamic>>(
          data: response(options),
          requestOptions: options,
          statusCode: 200,
        ),
      ),
    ),
  );
  return dio;
}

Dio _countingFailureDio(String baseUrl, void Function() onRequest) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest();
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

Dio _networkFailureDio(String baseUrl) => _countingFailureDio(baseUrl, () {});

Dio _aniListFailureDio({required int status, required String message}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          response: Response<Map<String, dynamic>>(
            data: {
              'errors': [
                {'message': message, 'status': status},
              ],
            },
            requestOptions: options,
            statusCode: status,
          ),
          type: DioExceptionType.badResponse,
        ),
      ),
    ),
  );
  return dio;
}

Map<String, dynamic> _aniListAnime({
  required int aniListId,
  required int malId,
}) => {
  'id': aniListId,
  'idMal': malId,
  'title': {
    'userPreferred': 'Primary title',
    'english': 'Primary title',
    'romaji': 'Primary title',
  },
  'description': 'Primary metadata',
  'episodes': 12,
  'averageScore': 80,
  'genres': ['Action'],
  'coverImage': {'extraLarge': 'https://images.example/anilist.jpg'},
  'bannerImage': null,
  'format': 'TV',
  'status': 'FINISHED',
  'season': 'SPRING',
  'seasonYear': 2024,
  'duration': 24,
  'synonyms': <String>[],
  'isAdult': false,
  'nextAiringEpisode': null,
};

Map<String, dynamic> _kitsuAnime() => {
  'type': 'anime',
  'id': '42',
  'attributes': {
    'canonicalTitle': 'Backup title',
    'titles': {'en': 'Backup title', 'en_jp': 'Backup title'},
    'synopsis': 'Kitsu metadata',
    'episodeCount': 12,
    'averageRating': '82',
    'posterImage': {'large': 'https://images.example/kitsu.jpg'},
    'coverImage': {'large': 'https://images.example/kitsu-banner.jpg'},
    'subtype': 'TV',
    'status': 'finished',
    'startDate': '2024-04-01',
    'episodeLength': 24,
  },
  'relationships': {
    'mappings': {
      'data': [
        {'type': 'mappings', 'id': 'al'},
        {'type': 'mappings', 'id': 'mal'},
      ],
    },
    'categories': {
      'data': [
        {'type': 'categories', 'id': 'action'},
      ],
    },
  },
};

List<Map<String, dynamic>> _kitsuIncluded({
  required int aniListId,
  required int malId,
}) => [
  {
    'type': 'mappings',
    'id': 'al',
    'attributes': {'externalSite': 'anilist/anime', 'externalId': '$aniListId'},
  },
  {
    'type': 'mappings',
    'id': 'mal',
    'attributes': {'externalSite': 'myanimelist/anime', 'externalId': '$malId'},
  },
  {
    'type': 'categories',
    'id': 'action',
    'attributes': {'title': 'Action'},
  },
];

Map<String, dynamic> _jikanAnime({required int malId}) => {
  'mal_id': malId,
  'title': 'Backup title',
  'title_english': 'Backup title',
  'synopsis': 'Jikan metadata',
  'episodes': 24,
  'score': 8.4,
  'images': {
    'jpg': {'large_image_url': 'https://images.example/jikan.jpg'},
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
  'aired': {'from': '2024-04-01T00:00:00Z'},
};
