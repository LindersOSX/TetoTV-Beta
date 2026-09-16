import 'package:anime_tv/features/tracking/data/kitsu_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads paged Kitsu library entries and stable catalog mappings',
    () async {
      final requests = <RequestOptions>[];
      final dio = _testDio((request) {
        requests.add(request);
        if (request.uri.path.endsWith('/users')) {
          return _response(request, {
            'data': [
              {'type': 'users', 'id': '7'},
            ],
          });
        }
        final secondPage = request.uri.queryParameters['page[offset]'] == '20';
        if (secondPage) {
          return _response(request, const {
            'data': <Object?>[],
            'links': <String, Object?>{'next': null},
          });
        }
        return _response(request, {
          'data': [
            {
              'type': 'libraryEntries',
              'id': '51',
              'attributes': {
                'status': 'current',
                'progress': 4,
                'ratingTwenty': 15,
                'updatedAt': '2026-09-01T12:00:00Z',
              },
              'relationships': {
                'anime': {
                  'data': {'type': 'anime', 'id': '9'},
                },
              },
            },
          ],
          'included': [
            {
              'type': 'anime',
              'id': '9',
              'attributes': {
                'canonicalTitle': 'Fallback',
                'titles': {'en': 'English title', 'en_jp': 'Romaji title'},
                'episodeCount': 12,
                'posterImage': {'large': 'https://media.kitsu.io/poster.jpg'},
                'status': 'current',
                'startDate': '2026-01-02',
              },
              'relationships': {
                'mappings': {
                  'data': [
                    {'type': 'mappings', 'id': '101'},
                    {'type': 'mappings', 'id': '102'},
                  ],
                },
              },
            },
            {
              'type': 'mappings',
              'id': '101',
              'attributes': {
                'externalSite': 'anilist/anime',
                'externalId': '1234',
              },
            },
            {
              'type': 'mappings',
              'id': '102',
              'attributes': {
                'externalSite': 'myanimelist/anime',
                'externalId': '5678',
              },
            },
          ],
          'links': {'next': '/api/edge/library-entries?page%5Boffset%5D=20'},
        });
      });
      final repository = KitsuTrackingRepository(
        accessToken: 'unused',
        dio: dio,
      );

      final result = await repository.list(TrackingListStatus.watching);

      expect(result, hasLength(1));
      expect(result.single.mediaId, 9);
      expect(result.single.title, 'English title');
      expect(result.single.progress, 4);
      expect(result.single.score, 7.5);
      expect(result.single.anilistId, 1234);
      expect(result.single.malId, 5678);
      expect(requests, hasLength(3));
      expect(
        requests[1].uri.queryParameters,
        containsPair('filter[status]', 'current'),
      );
      expect(
        requests[1].uri.queryParameters,
        containsPair('page[limit]', '20'),
      );
      expect(
        requests.map((request) => request.headers['Authorization']),
        everyElement('Bearer kitsu-test-token'),
      );
    },
  );

  test(
    'rejects an untrusted Kitsu pagination link before requesting it',
    () async {
      final requests = <Uri>[];
      final dio = _testDio((request) {
        requests.add(request.uri);
        if (request.uri.path.endsWith('/users')) {
          return _response(request, {
            'data': [
              {'type': 'users', 'id': '7'},
            ],
          });
        }
        return _response(request, const {
          'data': <Object?>[],
          'links': {'next': 'https://attacker.example/collect'},
        });
      });

      await expectLater(
        KitsuTrackingRepository(
          accessToken: 'unused',
          dio: dio,
        ).list(TrackingListStatus.planToWatch),
        throwsA(isA<FormatException>()),
      );
      expect(requests, hasLength(2));
      expect(requests.last.host, 'kitsu.io');
    },
  );

  test(
    'resolves AniList and MAL mappings before creating a status entry',
    () async {
      RequestOptions? mutation;
      final mappingSites = <String>[];
      final dio = _testDio((request) {
        if (request.uri.path.endsWith('/users')) {
          return _response(request, {
            'data': [
              {'type': 'users', 'id': '7'},
            ],
          });
        }
        if (request.uri.path.endsWith('/mappings')) {
          mappingSites.add(
            request.uri.queryParameters['filter[externalSite]']!,
          );
          return _response(request, {
            'data': [
              {
                'type': 'mappings',
                'id': '1',
                'relationships': {
                  'item': {
                    'data': {'type': 'anime', 'id': '9'},
                  },
                },
              },
            ],
          });
        }
        if (request.method == 'GET' &&
            request.uri.path.endsWith('/library-entries')) {
          return _response(request, const {'data': <Object?>[]});
        }
        mutation = request;
        return _response(request, const {});
      });
      final repository = KitsuTrackingRepository(
        accessToken: 'unused',
        dio: dio,
      );

      await repository.updateStatusByIds(
        ids: const TrackingMediaIds(anilistId: 1234, malId: 5678),
        status: TrackingListStatus.onHold,
      );

      expect(mappingSites, ['anilist/anime', 'myanimelist/anime']);
      expect(mutation?.method, 'POST');
      final body = mutation?.data as Map<String, dynamic>;
      final data = body['data'] as Map<String, dynamic>;
      expect(data['attributes'], {'status': 'on_hold'});
      final relationships = data['relationships'] as Map<String, dynamic>;
      expect(
        ((relationships['anime'] as Map<String, dynamic>)['data']
            as Map<String, dynamic>)['id'],
        '9',
      );
    },
  );

  test(
    'does not regress Kitsu progress and converts ratingTwenty exactly',
    () async {
      final mutations = <RequestOptions>[];
      final dio = _testDio((request) {
        if (request.uri.path.endsWith('/users')) {
          return _response(request, {
            'data': [
              {'type': 'users', 'id': '7'},
            ],
          });
        }
        if (request.method == 'GET') {
          return _response(request, {
            'data': [
              {
                'type': 'libraryEntries',
                'id': '51',
                'attributes': {'progress': 8},
              },
            ],
          });
        }
        mutations.add(request);
        return _response(request, const {});
      });
      final repository = KitsuTrackingRepository(
        accessToken: 'unused',
        dio: dio,
      );

      await repository.updateProgress(mediaId: 9, completedEpisodes: 7);
      await repository.updateRating(mediaId: 9, score: 8.5);

      expect(mutations, hasLength(1));
      final body = mutations.single.data as Map<String, dynamic>;
      final data = body['data'] as Map<String, dynamic>;
      expect(data['attributes'], {'ratingTwenty': 17});
      await expectLater(
        repository.updateRating(mediaId: 9, score: 8.25),
        throwsArgumentError,
      );
    },
  );

  test(
    'clearing an absent Kitsu rating does not create a list entry',
    () async {
      final mutations = <RequestOptions>[];
      final dio = _testDio((request) {
        if (request.uri.path.endsWith('/users')) {
          return _response(request, {
            'data': [
              {'type': 'users', 'id': '7'},
            ],
          });
        }
        if (request.method == 'GET' &&
            request.uri.path.endsWith('/library-entries')) {
          return _response(request, const {'data': <Object?>[]});
        }
        mutations.add(request);
        return _response(request, const {});
      });

      await KitsuTrackingRepository(
        accessToken: 'unused',
        dio: dio,
      ).updateRating(mediaId: 9, score: null);

      expect(mutations, isEmpty);
    },
  );

  test(
    'an absent Kitsu catalog mapping is a typed permanent outcome',
    () async {
      final mappingSites = <String>[];
      final dio = _testDio((request) {
        if (request.uri.path.endsWith('/mappings')) {
          mappingSites.add(
            request.uri.queryParameters['filter[externalSite]']!,
          );
          return _response(request, const {'data': <Object?>[]});
        }
        fail('A mapping miss must not reach another Kitsu endpoint.');
      });
      final repository = KitsuTrackingRepository(
        accessToken: 'unused',
        dio: dio,
      );

      await expectLater(
        repository.updateStatusByIds(
          ids: const TrackingMediaIds(anilistId: 1234, malId: 5678),
          status: TrackingListStatus.planToWatch,
        ),
        throwsA(isA<TrackingMediaMappingNotFoundException>()),
      );
      expect(mappingSites, ['anilist/anime', 'myanimelist/anime']);
    },
  );

  test('Kitsu pagination URL policy permits only the official edge path', () {
    expect(
      trustedKitsuLibraryPageUri(
        '/api/edge/library-entries?page%5Boffset%5D=20',
      )?.host,
      'kitsu.io',
    );
    expect(
      trustedKitsuLibraryPageUri(
        'https://kitsu.io/api/edge/library-entries?page%5Boffset%5D=20',
      ),
      isNotNull,
    );
    expect(
      trustedKitsuLibraryPageUri(
        'https://kitsu.io.evil.example/api/edge/library-entries',
      ),
      isNull,
    );
    expect(
      trustedKitsuLibraryPageUri('https://kitsu.io/api/edge/users'),
      isNull,
    );
  });
}

Dio _testDio(Response<dynamic> Function(RequestOptions) responder) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://kitsu.io/api/edge',
      headers: const {
        'Accept': 'application/vnd.api+json',
        'Content-Type': 'application/vnd.api+json',
        'Authorization': 'Bearer kitsu-test-token',
      },
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(responder(options)),
    ),
  );
  return dio;
}

Response<Map<String, dynamic>> _response(
  RequestOptions request,
  Map<String, dynamic> data,
) => Response<Map<String, dynamic>>(
  requestOptions: request,
  statusCode: 200,
  data: data,
);
