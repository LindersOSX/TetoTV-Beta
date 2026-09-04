import 'dart:async';

import 'package:anime_tv/features/tracking/data/simkl_account_session.dart';
import 'package:anime_tv/features/tracking/data/simkl_api_client.dart';
import 'package:anime_tv/features/tracking/data/simkl_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'anime cache single-flights, merges activity deltas, and diffs removals',
    () async {
      var now = DateTime.utc(2026, 9, 3, 12);
      var allWatermark = '2026-09-03T12:00:00Z';
      var animeWatermark = '2026-09-03T12:00:00Z';
      var removalWatermark = '2026-09-03T11:00:00Z';
      var fullRows = [
        _animeRow(simklId: 37089, title: 'Original title', status: 'watching'),
      ];
      var deltaRows = <Map<String, dynamic>>[];
      var currentIds = <int>{37089};
      var activityRequests = 0;
      final libraryQueries = <Map<String, dynamic>>[];
      final cache = _MemoryCache();

      Dio makeDio() => _dio((options) {
        if (options.path == '/sync/activities') {
          activityRequests++;
          return _response(options, {
            'all': allWatermark,
            'settings': {'all': '2026-09-01T00:00:00Z'},
            'anime': {
              'all': animeWatermark,
              'removed_from_list': removalWatermark,
            },
          });
        }
        if (options.path == '/sync/all-items/anime') {
          libraryQueries.add(
            Map<String, dynamic>.from(options.queryParameters),
          );
          if (options.queryParameters['extended'] == 'simkl_ids_only') {
            return _response(options, {
              'anime': [
                for (final id in currentIds)
                  {
                    'ids': {'simkl': id},
                  },
              ],
            });
          }
          return _response(options, {
            'anime': options.queryParameters.containsKey('date_from')
                ? deltaRows
                : fullRows,
          });
        }
        throw StateError('Unexpected request ${options.path}');
      });

      final registry = SimklAccountSessionRegistry(
        persistentCache: cache,
        now: () => now,
        delay: (_) async {},
      );
      final session = registry.session(
        accessToken: 'account-one-token',
        clientId: 'public-client-id',
        appVersion: '2.0.66',
        cacheScopeLoader: () async => 'simkl-profile-one',
        dio: makeDio(),
        postScheduler: SimklPostScheduler(delay: (_) async {}),
      );

      final initial = await Future.wait([
        session.animeLibrary(),
        session.animeLibrary(),
        session.animeLibrary(),
      ]);
      expect(initial.every((list) => list.length == 1), isTrue);
      expect(activityRequests, 1);
      expect(libraryQueries, hasLength(1));
      expect(libraryQueries.single, containsPair('language', 'en'));
      expect(libraryQueries.single, isNot(contains('date_from')));
      expect(libraryQueries.single['extended'], 'full');
      expect(libraryQueries.single['episode_watched_at'], 'yes');
      expect(libraryQueries.single['include_all_episodes'], 'yes');

      await session.animeLibrary();
      expect(activityRequests, 1);
      expect(libraryQueries, hasLength(1));

      now = now.add(const Duration(minutes: 21));
      await session.animeLibrary();
      expect(activityRequests, 2);
      expect(libraryQueries, hasLength(1));

      allWatermark = '2026-09-03T12:40:00Z';
      animeWatermark = '2026-09-03T12:40:00Z';
      deltaRows = [
        _animeRow(simklId: 37089, title: 'Updated title', status: 'completed'),
        _animeRow(simklId: 47089, title: 'New title', status: 'watching'),
      ];
      currentIds = {37089, 47089};
      now = now.add(const Duration(minutes: 21));
      final merged = await session.animeLibrary();
      expect(merged, hasLength(2));
      expect(
        merged.singleWhere((row) => row.simklId == 37089).title,
        'Updated title',
      );
      expect(
        merged.singleWhere((row) => row.simklId == 37089).status,
        'completed',
      );
      expect(activityRequests, 3);
      expect(libraryQueries, hasLength(2));
      expect(libraryQueries.last['date_from'], '2026-09-03T12:00:00Z');
      expect(libraryQueries.last['extended'], 'full');
      expect(libraryQueries.last['episode_watched_at'], 'yes');
      expect(libraryQueries.last['include_all_episodes'], 'yes');

      allWatermark = '2026-09-03T13:00:00Z';
      removalWatermark = '2026-09-03T13:00:00Z';
      currentIds = {47089};
      now = now.add(const Duration(minutes: 21));
      final afterRemoval = await session.animeLibrary();
      expect(afterRemoval.map((row) => row.simklId), [47089]);
      expect(activityRequests, 4);
      expect(libraryQueries, hasLength(3));
      expect(libraryQueries.last['extended'], 'simkl_ids_only');
      expect(libraryQueries.last, isNot(contains('date_from')));

      final restarted =
          SimklAccountSessionRegistry(
            persistentCache: cache,
            now: () => now,
            delay: (_) async {},
          ).session(
            accessToken: 'account-one-token',
            clientId: 'public-client-id',
            appVersion: '2.0.66',
            cacheScopeLoader: () async => 'simkl-profile-one',
            dio: makeDio(),
            postScheduler: SimklPostScheduler(delay: (_) async {}),
          );
      expect((await restarted.animeLibrary()).map((row) => row.simklId), [
        47089,
      ]);
      expect(activityRequests, 4);
      expect(libraryQueries, hasLength(3));
    },
  );

  test('profile cache refreshes only when settings activity changes', () async {
    var now = DateTime.utc(2026, 9, 3, 12);
    var settingsWatermark = '2026-09-03T10:00:00Z';
    var username = 'First Name';
    var activityRequests = 0;
    var profileRequests = 0;
    final session = SimklAccountSession(
      client: _client(
        _dio((options) {
          if (options.path == '/sync/activities') {
            activityRequests++;
            return _response(options, {
              'all': settingsWatermark,
              'settings': {'all': settingsWatermark},
              'anime': {
                'all': '2026-09-01T00:00:00Z',
                'removed_from_list': '2026-09-01T00:00:00Z',
              },
            });
          }
          if (options.path == '/users/settings') {
            profileRequests++;
            return _response(options, {
              'user': {'name': username},
              'account': {'id': 42, 'type': 'free'},
            });
          }
          throw StateError('Unexpected request ${options.path}');
        }),
      ),
      persistentCache: _MemoryCache(),
      cacheScopeLoader: () async => 'simkl-profile-one',
      now: () => now,
      delay: (_) async {},
    );

    expect((await session.profile()).username, 'First Name');
    expect((await session.profile()).username, 'First Name');
    expect(activityRequests, 1);
    expect(profileRequests, 1);

    now = now.add(const Duration(minutes: 21));
    expect((await session.profile()).username, 'First Name');
    expect(activityRequests, 2);
    expect(profileRequests, 1);

    settingsWatermark = '2026-09-03T13:00:00Z';
    username = 'Updated Name';
    now = now.add(const Duration(minutes: 21));
    expect((await session.profile()).username, 'Updated Name');
    expect(activityRequests, 3);
    expect(profileRequests, 2);
  });

  test('E1 and E3 watched with target 3 submits only missing E2', () async {
    late RequestOptions historyRequest;
    final requestedPaths = <String>[];
    final client = _client(
      _dio((options) {
        requestedPaths.add(options.path);
        if (options.path == '/sync/all-items/anime') {
          return _response(options, {
            'anime': [
              _animeRow(
                simklId: 37089,
                title: 'Non-contiguous history',
                status: 'watching',
                progress: 2,
                watchedEpisodeNumbers: const [1, 3],
              ),
            ],
          });
        }
        if (options.path == '/sync/activities') {
          return _response(options, const {
            'all': '2026-09-03T12:00:00Z',
            'settings': {'all': '2026-09-03T12:00:00Z'},
            'anime': {
              'all': '2026-09-03T12:00:00Z',
              'removed_from_list': '2026-09-03T12:00:00Z',
            },
          });
        }
        if (options.path == '/sync/history') {
          historyRequest = options;
          return _response(options, const {
            'added': {
              'episodes': 1,
              'statuses': [
                {
                  'response': {'status': 'watching'},
                },
              ],
            },
            'not_found': {'movies': [], 'shows': [], 'episodes': []},
          }, statusCode: 201);
        }
        throw StateError('Unexpected request ${options.path}');
      }),
    );
    final repository = SimklTrackingRepository.forTesting(
      SimklAccountSession(
        client: client,
        persistentCache: _MemoryCache(),
        cacheScopeLoader: () async => 'simkl-profile-one',
        delay: (_) async {},
      ),
    );

    const ids = TrackingMediaIds(anilistId: 1234);
    expect(await repository.currentProgressByIds(ids), 1);

    await repository.updateProgressByIds(ids: ids, completedEpisodes: 3);

    expect(historyRequest.data, {
      'anime': [
        {
          'ids': {'anilist': '1234'},
          'episodes': [
            {'number': 2},
          ],
        },
      ],
    });
    expect(requestedPaths, isNot(contains('/sync/watched')));
    expect(await repository.currentProgressByIds(ids), 3);
  });

  test('disconnect cleanup removes every saved SIMKL profile cache', () async {
    final cache = _MemoryCache()
      ..values['simkl-profile-one'] = {'schema': 2}
      ..values['simkl-profile-two'] = {'schema': 2};
    final registry = SimklAccountSessionRegistry(persistentCache: cache);

    await registry.clearPersistentScopes([
      'simkl-profile-one',
      'simkl-profile-two',
      'simkl-profile-one',
      null,
    ]);

    expect(cache.values, isEmpty);
  });

  test(
    'cached anime without an activity watermark is fully refreshed',
    () async {
      final cache = _MemoryCache()
        ..values['simkl-profile-one'] = {
          'schema': 2,
          'checkedAt': '2026-09-03T12:00:00Z',
          'activities': null,
          'profile': null,
          'anime': [
            _animeRow(
              simklId: 37089,
              title: 'Interrupted snapshot',
              status: 'watching',
            ),
          ],
        };
      var libraryRequests = 0;
      var activityRequests = 0;
      final session = SimklAccountSession(
        client: _client(
          _dio((options) {
            if (options.path == '/sync/all-items/anime') {
              libraryRequests++;
              expect(options.queryParameters, isNot(contains('date_from')));
              return _response(options, {
                'anime': [
                  _animeRow(
                    simklId: 47089,
                    title: 'Current library',
                    status: 'completed',
                  ),
                ],
              });
            }
            if (options.path == '/sync/activities') {
              activityRequests++;
              return _response(options, const {
                'all': '2026-09-03T13:00:00Z',
                'settings': {'all': '2026-09-03T13:00:00Z'},
                'anime': {
                  'all': '2026-09-03T13:00:00Z',
                  'removed_from_list': '2026-09-03T13:00:00Z',
                },
              });
            }
            throw StateError('Unexpected request ${options.path}');
          }),
        ),
        persistentCache: cache,
        cacheScopeLoader: () async => 'simkl-profile-one',
        delay: (_) async {},
      );

      final rows = await session.animeLibrary();

      expect(rows.map((row) => row.simklId), [47089]);
      expect(libraryRequests, 1);
      expect(activityRequests, 1);
    },
  );

  test('cached profile without an activity watermark is refreshed', () async {
    final cache = _MemoryCache()
      ..values['simkl-profile-one'] = {
        'schema': 2,
        'checkedAt': '2026-09-03T12:00:00Z',
        'activities': null,
        'profile': const SimklUserProfile(
          username: 'Old Name',
          plan: SimklAccountPlan.free,
        ).toJson(),
        'anime': null,
      };
    var profileRequests = 0;
    var activityRequests = 0;
    final session = SimklAccountSession(
      client: _client(
        _dio((options) {
          if (options.path == '/sync/activities') {
            activityRequests++;
            return _response(options, const {
              'all': '2026-09-03T13:00:00Z',
              'settings': {'all': '2026-09-03T13:00:00Z'},
              'anime': {
                'all': '2026-09-03T13:00:00Z',
                'removed_from_list': '2026-09-03T13:00:00Z',
              },
            });
          }
          if (options.path == '/users/settings') {
            profileRequests++;
            return _response(options, const {
              'user': {'name': 'Current Name'},
              'account': {'id': 42, 'type': 'free'},
            });
          }
          throw StateError('Unexpected request ${options.path}');
        }),
      ),
      persistentCache: cache,
      cacheScopeLoader: () async => 'simkl-profile-one',
      delay: (_) async {},
    );

    expect((await session.profile()).username, 'Current Name');
    expect(activityRequests, 1);
    expect(profileRequests, 1);
  });

  test('disconnect cannot resurrect cache from an in-flight request', () async {
    final cache = _MemoryCache();
    final requestStarted = Completer<void>();
    final releaseRequest = Completer<void>();
    final registry = SimklAccountSessionRegistry(persistentCache: cache);
    final session = registry.session(
      accessToken: 'account-one-token',
      clientId: 'public-client-id',
      appVersion: '2.0.67',
      cacheScopeLoader: () async => 'simkl-profile-one',
      dio: Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path == '/sync/activities') {
                handler.resolve(
                  _response(options, const {
                    'all': '2026-09-03T13:00:00Z',
                    'settings': {'all': '2026-09-03T13:00:00Z'},
                    'anime': {
                      'all': '2026-09-03T13:00:00Z',
                      'removed_from_list': '2026-09-03T13:00:00Z',
                    },
                  }),
                );
                return;
              }
              requestStarted.complete();
              releaseRequest.future.then((_) {
                handler.resolve(
                  _response(options, const {
                    'user': {'name': 'Disconnected User'},
                    'account': {'id': 42, 'type': 'free'},
                  }),
                );
              });
            },
          ),
        ),
      postScheduler: SimklPostScheduler(delay: (_) async {}),
    );

    final profileRequest = session.profile();
    await requestStarted.future;
    await registry.clearPersistentScopes(['simkl-profile-one']);
    releaseRequest.complete();
    await profileRequest;

    expect(cache.values, isEmpty);
  });

  test('read retry uses bounded exponential waits and five attempts', () async {
    var requests = 0;
    final delays = <Duration>[];
    final session = SimklAccountSession(
      client: _client(
        Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                if (options.path == '/sync/activities') {
                  handler.resolve(
                    _response(options, const {
                      'all': '2026-09-03T13:00:00Z',
                      'settings': {'all': '2026-09-03T13:00:00Z'},
                      'anime': {
                        'all': '2026-09-03T13:00:00Z',
                        'removed_from_list': '2026-09-03T13:00:00Z',
                      },
                    }),
                  );
                  return;
                }
                requests++;
                if (requests < 5) {
                  final response = Response<Map<String, dynamic>>(
                    requestOptions: options,
                    statusCode: 503,
                    data: const {'error': 'unavailable'},
                  );
                  handler.reject(
                    DioException.badResponse(
                      statusCode: 503,
                      requestOptions: options,
                      response: response,
                    ),
                  );
                  return;
                }
                handler.resolve(
                  _response(options, const {
                    'user': {'name': 'Retry User'},
                    'account': {'id': 42, 'type': 'free'},
                  }),
                );
              },
            ),
          ),
      ),
      persistentCache: _MemoryCache(),
      cacheScopeLoader: () async => 'simkl-profile-one',
      delay: (duration) async => delays.add(duration),
    );

    expect((await session.profile()).username, 'Retry User');
    expect(requests, 5);
    expect(delays, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ]);
  });

  test(
    'network outage retries then serves cache without renewing it',
    () async {
      final cache = _MemoryCache()
        ..values['simkl-profile-one'] = {
          'schema': 2,
          'checkedAt': '2026-09-03T11:00:00Z',
          'activities': const SimklActivitySnapshot(
            all: '2026-09-03T11:00:00Z',
            animeAll: '2026-09-03T11:00:00Z',
            animeRemovedFromList: '2026-09-03T11:00:00Z',
            settingsAll: '2026-09-03T11:00:00Z',
          ).toJson(),
          'profile': const SimklUserProfile(
            username: 'Offline User',
            plan: SimklAccountPlan.free,
          ).toJson(),
          'anime': null,
        };
      var requests = 0;
      final delays = <Duration>[];
      final session = SimklAccountSession(
        client: _client(
          Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  requests++;
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionError,
                      error: 'offline',
                    ),
                  );
                },
              ),
            ),
        ),
        persistentCache: cache,
        cacheScopeLoader: () async => 'simkl-profile-one',
        now: () => DateTime.utc(2026, 9, 3, 12),
        delay: (duration) async => delays.add(duration),
      );

      expect((await session.profile()).username, 'Offline User');
      expect(requests, 5);
      expect(delays, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
      expect(cache.saveCount, 0);
    },
  );

  test('read does not retry an unapproved HTTP status', () async {
    var requests = 0;
    final delays = <Duration>[];
    final session = SimklAccountSession(
      client: _client(
        Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests++;
                final response = Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 501,
                  data: const {'error': 'not implemented'},
                );
                handler.reject(
                  DioException.badResponse(
                    statusCode: 501,
                    requestOptions: options,
                    response: response,
                  ),
                );
              },
            ),
          ),
      ),
      persistentCache: _MemoryCache(),
      cacheScopeLoader: () async => 'simkl-profile-one',
      delay: (duration) async => delays.add(duration),
    );

    await expectLater(session.profile(), throwsA(isA<SimklApiException>()));
    expect(requests, 1);
    expect(delays, isEmpty);
  });
}

SimklApiClient _client(Dio dio) => SimklApiClient(
  accessToken: 'private-access-token',
  clientId: 'public-client-id',
  appVersion: '2.0.66',
  dio: dio,
  postScheduler: SimklPostScheduler(delay: (_) async {}),
);

Dio _dio(Response<dynamic> Function(RequestOptions) responseFor) =>
    Dio(BaseOptions(baseUrl: 'https://api.simkl.com'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) =>
              handler.resolve(responseFor(options)),
        ),
      );

Response<Map<String, dynamic>> _response(
  RequestOptions options,
  Map<String, dynamic> data, {
  int statusCode = 200,
}) => Response<Map<String, dynamic>>(
  requestOptions: options,
  statusCode: statusCode,
  data: data,
);

Map<String, dynamic> _animeRow({
  required int simklId,
  required String title,
  required String status,
  int progress = 1,
  List<int> watchedEpisodeNumbers = const [],
}) => {
  'status': status,
  'watched_episodes_count': progress,
  'total_episodes_count': 12,
  'show': {
    'title': title,
    'poster': '12/abc',
    'ids': {
      'simkl': simklId,
      'anilist': '1234',
      'mal': '5678',
      'slug': 'cached-anime',
    },
  },
  'seasons': [
    {
      'number': 1,
      'episodes': [
        for (final number in watchedEpisodeNumbers)
          {'number': number, 'watched_at': '2026-09-03T11:00:00Z'},
      ],
    },
  ],
};

class _MemoryCache implements SimklPersistentCache {
  final Map<String, Map<String, dynamic>> values = {};
  int saveCount = 0;

  @override
  Future<Map<String, dynamic>?> load(String scope) async => values[scope];

  @override
  Future<void> save(String scope, Map<String, dynamic> payload) async {
    saveCount++;
    values[scope] = payload;
  }

  @override
  Future<void> remove(String scope) async {
    values.remove(scope);
  }
}
