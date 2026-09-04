import 'package:anime_tv/features/tracking/data/simkl_api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads the SIMKL profile and avatar with all required metadata',
    () async {
      late RequestOptions request;
      final client = _client(
        dio: _dio((options) {
          request = options;
          return _success(
            options,
            status: 200,
            data: {
              'user': {
                'name': 'TetoFan',
                'avatar': 'https://simkl.in/avatars/12/abc/user_100.jpg',
              },
              'account': {
                'id': 42,
                'timezone': 'America/Chicago',
                'type': 'vip',
              },
            },
          );
        }),
      );

      final profile = await client.profile();

      expect(request.method, 'POST');
      expect(request.path, '/users/settings');
      expect(request.data, isNull);
      expect(request.queryParameters, {
        'client_id': 'public-client-id',
        'app-name': 'tetotv',
        'app-version': '2.0.64',
      });
      expect(request.headers['User-Agent'], 'tetotv/2.0.64');
      expect(request.headers['Authorization'], 'Bearer private-access-token');
      expect(request.headers['Content-Type'], 'application/json');
      expect(profile.username, 'TetoFan');
      expect(profile.avatarUrl, 'https://simkl.in/avatars/12/abc/user_100.jpg');
      expect(profile.accountId, 42);
      expect(profile.timezone, 'America/Chicago');
      expect(profile.plan, SimklAccountPlan.vip);
    },
  );

  test('accepts null activity watermarks for a fresh SIMKL account', () async {
    final client = _client(
      dio: _dio(
        (options) => _success(
          options,
          status: 200,
          data: const {
            'all': null,
            'anime': {'all': null, 'removed_from_list': null},
            'settings': {'all': null},
          },
        ),
      ),
    );

    final activities = await client.activities();

    expect(activities.all, isNull);
    expect(activities.animeAll, isNull);
    expect(activities.animeRemovedFromList, isNull);
    expect(activities.settingsAll, isNull);
  });

  test('serializes and paces canonical-ID history writes', () async {
    var now = DateTime.utc(2026, 9, 2, 12);
    final delays = <Duration>[];
    final requests = <RequestOptions>[];
    var active = 0;
    var maximumActive = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests.add(options);
            active++;
            maximumActive = active > maximumActive ? active : maximumActive;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            active--;
            handler.resolve(_historySuccess(options));
          },
        ),
      );
    final client = _client(
      dio: dio,
      now: () => now,
      delay: (duration) async {
        delays.add(duration);
        now = now.add(duration);
      },
    );
    final animeId = SimklAnimeId(37089);

    await Future.wait([
      client.markAnimeEpisodeWatched(
        animeId: animeId,
        episodeNumber: 1,
        watchedAt: DateTime.utc(2026, 9, 2, 11, 30),
      ),
      client.markAnimeEpisodeWatched(animeId: animeId, episodeNumber: 2),
    ]);

    expect(maximumActive, 1);
    expect(delays, [const Duration(seconds: 1)]);
    expect(requests, hasLength(2));
    expect(requests.first.path, '/sync/history');
    expect(requests.first.data, {
      'anime': [
        {
          'ids': {'simkl': 37089},
          'episodes': [
            {'number': 1, 'watched_at': '2026-09-02T11:30:00.000Z'},
          ],
        },
      ],
    });
    expect(((requests.last.data as Map)['anime'] as List).single, {
      'ids': {'simkl': 37089},
      'episodes': [
        {'number': 2},
      ],
    });
  });

  test('surfaces 429 without retrying a history mutation', () async {
    var requests = 0;
    final client = _client(
      dio: Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              final response = Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 429,
                headers: Headers.fromMap({
                  'retry-after': ['7'],
                }),
                data: const {'error': 'rate_limit', 'code': 429},
              );
              handler.reject(
                DioException.badResponse(
                  statusCode: 429,
                  requestOptions: options,
                  response: response,
                ),
              );
            },
          ),
        ),
    );

    await expectLater(
      client.markAnimeEpisodeWatched(
        animeId: SimklAnimeId(37089),
        episodeNumber: 1,
      ),
      throwsA(
        isA<SimklRateLimitException>().having(
          (error) => error.retryAfter,
          'retryAfter',
          const Duration(seconds: 7),
        ),
      ),
    );
    expect(requests, 1);
  });

  test(
    'loads an anime list with explicit external IDs and attribution',
    () async {
      late RequestOptions request;
      final client = _client(
        dio: _dio((options) {
          request = options;
          return _success(
            options,
            status: 200,
            data: {
              'anime': [
                {
                  'status': 'watching',
                  'watched_episodes_count': 4,
                  'total_episodes_count': 12,
                  'user_rating': 8.5,
                  'last_watched_at': '2026-09-01T12:30:00Z',
                  'show': {
                    'title': 'Test Anime',
                    'poster': '12/abc',
                    'ids': {
                      'simkl': 37089,
                      'anilist': '1234',
                      'mal': 5678,
                      'slug': 'test-anime',
                    },
                  },
                  'seasons': [
                    {
                      'number': 1,
                      'episodes': [
                        {'number': 1, 'watched_at': '2026-09-01T12:00:00Z'},
                        {'number': 3, 'watched_at': '2026-09-01T12:30:00Z'},
                      ],
                    },
                  ],
                },
              ],
            },
          );
        }),
      );

      final entries = await client.animeLibrary();

      expect(request.method, 'GET');
      expect(request.path, '/sync/all-items/anime');
      expect(request.queryParameters, {
        'language': 'en',
        'extended': 'full',
        'episode_watched_at': 'yes',
        'include_all_episodes': 'yes',
        'client_id': 'public-client-id',
        'app-name': 'tetotv',
        'app-version': '2.0.64',
      });
      expect(entries, hasLength(1));
      expect(entries.single.simklId, 37089);
      expect(entries.single.anilistId, 1234);
      expect(entries.single.malId, 5678);
      expect(entries.single.slug, 'test-anime');
      expect(entries.single.progress, 4);
      expect(entries.single.totalEpisodes, 12);
      expect(entries.single.watchedEpisodeNumbers, {1, 3});
      expect(entries.single.contiguousProgress, 1);
    },
  );

  test(
    'rejects a malformed full-library response instead of wiping cache',
    () async {
      final client = _client(
        dio: _dio(
          (options) =>
              _success(options, status: 200, data: const {'shows': []}),
        ),
      );

      await expectLater(
        client.animeLibrary(),
        throwsA(
          isA<SimklApiException>().having(
            (error) => error.code,
            'code',
            'invalid_list_response',
          ),
        ),
      );
    },
  );

  test(
    'requests an activity delta and accepts an omitted anime bucket',
    () async {
      late RequestOptions request;
      final client = _client(
        dio: _dio((options) {
          request = options;
          return _success(options, status: 200, data: const {});
        }),
      );

      final entries = await client.animeLibrary(
        dateFrom: '2026-09-03T12:00:00Z',
      );

      expect(entries, isEmpty);
      expect(request.path, '/sync/all-items/anime');
      expect(request.queryParameters['date_from'], '2026-09-03T12:00:00Z');
      expect(request.queryParameters['language'], 'en');
      expect(request.queryParameters['extended'], 'full');
      expect(request.queryParameters['episode_watched_at'], 'yes');
      expect(request.queryParameters['include_all_episodes'], 'yes');
    },
  );

  test('loads authoritative anime IDs for removal reconciliation', () async {
    late RequestOptions request;
    final client = _client(
      dio: _dio((options) {
        request = options;
        return _success(
          options,
          status: 200,
          data: const {
            'anime': [
              {
                'ids': {'simkl': 37089},
              },
              {
                'show': {
                  'ids': {'simkl': '47089'},
                },
              },
            ],
          },
        );
      }),
    );

    expect(await client.animeLibraryIds(), {37089, 47089});
    expect(request.path, '/sync/all-items/anime');
    expect(request.queryParameters['extended'], 'simkl_ids_only');
    expect(request.queryParameters, isNot(contains('date_from')));
  });

  test('returns the actual status stored by add-to-list', () async {
    late RequestOptions request;
    final client = _client(
      dio: _dio((options) {
        request = options;
        return _success(
          options,
          status: 201,
          data: const {
            'added': {
              'movies': [],
              'shows': [
                {
                  'to': 'watching',
                  'type': 'show',
                  'ids': {'simkl': 37089, 'anilist': '1234'},
                },
              ],
            },
            'not_found': {'movies': [], 'shows': []},
          },
        );
      }),
    );

    final actual = await client.setAnimeStatus(
      ids: SimklMediaIds(anilist: 1234),
      status: 'plantowatch',
    );

    expect(request.path, '/sync/add-to-list');
    expect(request.data, {
      'anime': [
        {
          'to': 'plantowatch',
          'ids': {'anilist': '1234'},
        },
      ],
    });
    expect((request.data as Map).containsKey('to'), isFalse);
    expect(actual, 'watching');
  });

  test('removes anime through shows and validates deleted response', () async {
    late RequestOptions request;
    final client = _client(
      dio: _dio((options) {
        request = options;
        return _success(
          options,
          status: 201,
          data: const {
            'deleted': {'movies': 0, 'shows': 1},
            'not_found': {'movies': [], 'shows': []},
          },
        );
      }),
    );

    await client.removeAnime(SimklMediaIds(mal: 5678));

    expect(request.path, '/sync/history/remove');
    expect(request.data, {
      'shows': [
        {
          'ids': {'mal': '5678'},
        },
      ],
    });
  });

  test('does not accept an add response as a removal response', () async {
    final client = _client(
      dio: _dio(
        (options) => _success(
          options,
          status: 201,
          data: const {
            'added': {'shows': 1},
            'not_found': {'movies': [], 'shows': []},
          },
        ),
      ),
    );

    await expectLater(
      client.removeAnime(SimklMediaIds(simkl: 37089)),
      throwsA(
        isA<SimklApiException>().having(
          (error) => error.code,
          'code',
          'invalid_list_remove_response',
        ),
      ),
    );
  });

  test('does not treat a 201 with not_found as a successful write', () async {
    final client = _client(
      dio: _dio(
        (options) => _success(
          options,
          status: 201,
          data: {
            'added': {'episodes': 0},
            'not_found': {
              'movies': const [],
              'shows': [
                {
                  'ids': {'simkl': 37089},
                },
              ],
              'episodes': const [],
            },
          },
        ),
      ),
    );

    await expectLater(
      client.markAnimeEpisodeWatched(
        animeId: SimklAnimeId(37089),
        episodeNumber: 1,
      ),
      throwsA(isA<SimklUnresolvedIdentityException>()),
    );
  });

  test('canonical IDs and episode numbers must be positive', () async {
    expect(() => SimklAnimeId(0), throwsArgumentError);
    final client = _client(dio: _dio(_historySuccess));
    await expectLater(
      client.markAnimeEpisodeWatched(
        animeId: SimklAnimeId(1),
        episodeNumber: 0,
      ),
      throwsArgumentError,
    );
  });
}

SimklApiClient _client({
  required Dio dio,
  SimklClock? now,
  SimklDelay? delay,
}) => SimklApiClient(
  accessToken: 'private-access-token',
  clientId: 'public-client-id',
  appVersion: '2.0.64',
  dio: dio,
  postScheduler: SimklPostScheduler(now: now, delay: delay),
);

Dio _dio(Response<dynamic> Function(RequestOptions) responseFor) {
  return Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(responseFor(options)),
      ),
    );
}

Response<Map<String, dynamic>> _historySuccess(RequestOptions options) =>
    _success(
      options,
      status: 201,
      data: const {
        'added': {
          'episodes': 1,
          'statuses': [
            {
              'response': {'status': 'watching'},
            },
          ],
        },
        'not_found': {'movies': [], 'shows': [], 'episodes': []},
      },
    );

Response<Map<String, dynamic>> _success(
  RequestOptions options, {
  required int status,
  required Map<String, dynamic> data,
}) => Response<Map<String, dynamic>>(
  requestOptions: options,
  statusCode: status,
  data: data,
);
