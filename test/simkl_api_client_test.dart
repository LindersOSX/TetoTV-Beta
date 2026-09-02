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
        'added': {'episodes': 1},
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
