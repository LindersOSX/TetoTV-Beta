import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime_tv/features/catalog/data/jikan_filler_episode_repository.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 13, 12);

  test('loads every validated page by canonical MAL ID', () async {
    final requests = <RequestOptions>[];
    final repository = JikanFillerEpisodeRepository(
      dio: _stubDio(requests, (request) {
        final page = int.parse(request.queryParameters['page'].toString());
        return page == 1
            ? _episodePage(
                lastPage: 2,
                hasNext: true,
                episodes: const [(1, false), (2, true)],
              )
            : _episodePage(
                lastPage: 2,
                hasNext: false,
                episodes: const [(3, true)],
              );
      }),
      cacheStore: _MemoryCacheStore(),
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(anilistMediaId: 30013, malMediaId: 21),
    );

    expect(result.status, FillerLookupStatus.confirmed);
    expect(result.canAutoSkip, isTrue);
    expect(result.source, FillerDataSource.jikanMalId);
    expect(result.resolvedMalMediaId, 21);
    expect(result.knownEpisodeCount, 3);
    expect(result.confirmedFillerEpisodes, {2, 3});
    expect(result.isConfirmedFiller(2), isTrue);
    expect(result.isConfirmedFiller(1), isFalse);
    expect(requests, hasLength(2));
    expect(requests.first.path, 'anime/21/episodes');
    expect(requests.map((request) => request.queryParameters['page']), [1, 2]);
    expect(
      requests.every((request) => request.followRedirects == false),
      isTrue,
    );
  });

  test(
    'uses one exact corroborated title only when MAL ID is absent',
    () async {
      final requests = <RequestOptions>[];
      final repository = JikanFillerEpisodeRepository(
        dio: _stubDio(requests, (request) {
          if (request.path == 'anime') {
            return {
              'data': [
                {
                  'mal_id': 5114,
                  'title': 'Hagane no Renkinjutsushi: Fullmetal Alchemist',
                  'title_english': 'Fullmetal Alchemist: Brotherhood',
                  'titles': [
                    {
                      'type': 'English',
                      'title': 'Fullmetal Alchemist: Brotherhood',
                    },
                  ],
                  'episodes': 64,
                  'year': 2009,
                },
              ],
            };
          }
          return _episodePage(
            lastPage: 1,
            hasNext: false,
            episodes: const [(1, false), (2, true)],
          );
        }),
        cacheStore: _MemoryCacheStore(),
        minimumRequestInterval: Duration.zero,
        clock: () => now,
      );

      final result = await repository.lookup(
        FillerSeriesIdentity(
          anilistMediaId: 5114,
          titles: const ['Fullmetal Alchemist Brotherhood'],
          expectedEpisodes: 64,
          seasonYear: 2009,
        ),
      );

      expect(result.canAutoSkip, isTrue);
      expect(result.source, FillerDataSource.jikanExactTitle);
      expect(result.resolvedMalMediaId, 5114);
      expect(
        requests.first.queryParameters['q'],
        'Fullmetal Alchemist Brotherhood',
      );
      expect(requests.last.path, 'anime/5114/episodes');
    },
  );

  test(
    'ambiguous exact title match fails open without loading episodes',
    () async {
      final requests = <RequestOptions>[];
      final repository = JikanFillerEpisodeRepository(
        dio: _stubDio(requests, (_) {
          return {
            'data': [
              {
                'mal_id': 1,
                'title': 'Shared Name',
                'episodes': 12,
                'year': 2020,
              },
              {
                'mal_id': 2,
                'title': 'Shared Name',
                'episodes': 12,
                'year': 2020,
              },
            ],
          };
        }),
        cacheStore: _MemoryCacheStore(),
        minimumRequestInterval: Duration.zero,
        clock: () => now,
      );

      final result = await repository.lookup(
        FillerSeriesIdentity(
          anilistMediaId: 99,
          titles: const ['Shared Name'],
          expectedEpisodes: 12,
          seasonYear: 2020,
        ),
      );

      expect(result.status, FillerLookupStatus.unavailable);
      expect(result.unavailableReason, FillerUnavailableReason.ambiguousTitle);
      expect(result.canAutoSkip, isFalse);
      expect(result.isConfirmedFiller(1), isFalse);
      expect(requests, hasLength(1));
    },
  );

  test('an uncorroborated or merely similar title fails open', () async {
    final requests = <RequestOptions>[];
    final repository = JikanFillerEpisodeRepository(
      dio: _stubDio(requests, (_) {
        return {
          'data': [
            {
              'mal_id': 20,
              'title': 'Naruto Shippuden',
              'episodes': 500,
              'year': 2007,
            },
          ],
        };
      }),
      cacheStore: _MemoryCacheStore(),
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(
        anilistMediaId: 20,
        titles: const ['Naruto'],
        expectedEpisodes: 220,
        seasonYear: 2002,
      ),
    );

    expect(result.status, FillerLookupStatus.unavailable);
    expect(result.isConfirmedFiller(101), isFalse);
    expect(requests, hasLength(1));
  });

  test('unknown filler values invalidate the whole result', () async {
    final requests = <RequestOptions>[];
    final repository = JikanFillerEpisodeRepository(
      dio: _stubDio(requests, (_) {
        return {
          'pagination': {'last_visible_page': 1, 'has_next_page': false},
          'data': [
            {'mal_id': 1, 'filler': true},
            {'mal_id': 2, 'filler': null},
          ],
        };
      }),
      cacheStore: _MemoryCacheStore(),
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 1),
    );

    expect(result.status, FillerLookupStatus.unavailable);
    expect(result.unavailableReason, FillerUnavailableReason.invalidResponse);
    expect(result.isConfirmedFiller(1), isFalse);
  });

  test('a non-contiguous episode catalog fails open', () async {
    final requests = <RequestOptions>[];
    final repository = JikanFillerEpisodeRepository(
      dio: _stubDio(
        requests,
        (_) => _episodePage(
          lastPage: 1,
          hasNext: false,
          episodes: const [(1, false), (3, true)],
        ),
      ),
      cacheStore: _MemoryCacheStore(),
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 1),
    );

    expect(result.status, FillerLookupStatus.unavailable);
    expect(result.unavailableReason, FillerUnavailableReason.invalidResponse);
    expect(result.canAutoSkip, isFalse);
  });

  test('pagination beyond the configured bound does not continue', () async {
    final requests = <RequestOptions>[];
    final repository = JikanFillerEpisodeRepository(
      dio: _stubDio(requests, (_) {
        return _episodePage(
          lastPage: 3,
          hasNext: true,
          episodes: const [(1, true)],
        );
      }),
      cacheStore: _MemoryCacheStore(),
      maximumPages: 2,
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 1),
    );

    expect(result.status, FillerLookupStatus.unavailable);
    expect(result.unavailableReason, FillerUnavailableReason.boundedLimit);
    expect(result.isConfirmedFiller(1), isFalse);
    expect(requests, hasLength(1));
  });

  test('chunked oversized response is cancelled before later chunks', () async {
    final requests = <RequestOptions>[];
    var producedChunks = 0;
    var streamCleanedUp = false;

    Stream<Uint8List> oversizedChunks() async* {
      try {
        for (var index = 0; index < 3; index++) {
          producedChunks++;
          yield Uint8List.fromList(List<int>.filled(40, 120));
          await Future<void>.delayed(Duration.zero);
        }
      } finally {
        streamCleanedUp = true;
      }
    }

    final dio = Dio(BaseOptions(baseUrl: 'https://api.jikan.test/v4/'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.resolve(
            Response<ResponseBody>(
              requestOptions: request,
              statusCode: 200,
              // Deliberately omit Content-Length to exercise the incremental
              // cap used for HTTP chunked responses.
              data: ResponseBody(oversizedChunks(), 200),
            ),
          );
        },
      ),
    );
    final repository = JikanFillerEpisodeRepository(
      dio: dio,
      cacheStore: _MemoryCacheStore(),
      maximumResponseBytes: 64,
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 1),
    );

    expect(result.status, FillerLookupStatus.unavailable);
    expect(result.unavailableReason, FillerUnavailableReason.boundedLimit);
    expect(requests, hasLength(1));
    expect(requests.single.responseType, ResponseType.stream);
    expect(producedChunks, 2);
    expect(streamCleanedUp, isTrue);
  });

  test('confirmed results persist and a fresh cache avoids network', () async {
    final cache = _MemoryCacheStore();
    final firstRequests = <RequestOptions>[];
    final first = JikanFillerEpisodeRepository(
      dio: _stubDio(
        firstRequests,
        (_) => _episodePage(
          lastPage: 1,
          hasNext: false,
          episodes: const [(1, false), (2, true)],
        ),
      ),
      cacheStore: cache,
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );
    final identity = FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 21);
    final networkResult = await first.lookup(identity);

    final secondRequests = <RequestOptions>[];
    final second = JikanFillerEpisodeRepository(
      dio: _stubDio(secondRequests, (_) => throw StateError('no network')),
      cacheStore: cache,
      minimumRequestInterval: Duration.zero,
      clock: () => now.add(const Duration(hours: 1)),
    );
    final cachedResult = await second.lookup(identity);

    expect(networkResult.isConfirmedFiller(2), isTrue);
    expect(cachedResult.isConfirmedFiller(2), isTrue);
    expect(firstRequests, hasLength(1));
    expect(secondRequests, isEmpty);
    expect(cache.writes, 1);
  });

  test('stale cache is ignored and a network error still fails open', () async {
    final cache = _MemoryCacheStore()
      ..values['filler:jikan:v1:mal:21'] = {
        'schema': 1,
        'status': 'confirmed',
        'source': 'jikanMalId',
        'malMediaId': 21,
        'fetchedAt': now
            .subtract(const Duration(days: 2))
            .millisecondsSinceEpoch,
        'knownEpisodeCount': 1,
        'fillerEpisodes': [1],
      };
    final requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://api.jikan.test/v4/'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      ),
    );
    final repository = JikanFillerEpisodeRepository(
      dio: dio,
      cacheStore: cache,
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 21),
    );

    expect(result.status, FillerLookupStatus.unavailable);
    expect(result.unavailableReason, FillerUnavailableReason.network);
    expect(result.isConfirmedFiller(1), isFalse);
    expect(requests, hasLength(1));
  });

  test('concurrent identical lookups share one request', () async {
    final requests = <RequestOptions>[];
    final gate = Completer<void>();
    final requestStarted = Completer<void>();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.jikan.test/v4/'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          requests.add(request);
          if (!requestStarted.isCompleted) requestStarted.complete();
          await gate.future;
          handler.resolve(
            Response<ResponseBody>(
              requestOptions: request,
              statusCode: 200,
              data: ResponseBody.fromString(
                jsonEncode(
                  _episodePage(
                    lastPage: 1,
                    hasNext: false,
                    episodes: const [(1, true)],
                  ),
                ),
                200,
              ),
            ),
          );
        },
      ),
    );
    final repository = JikanFillerEpisodeRepository(
      dio: dio,
      cacheStore: _MemoryCacheStore(),
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );
    final identity = FillerSeriesIdentity(anilistMediaId: 1, malMediaId: 1);

    final first = repository.lookup(identity);
    final second = repository.lookup(identity);
    await requestStarted.future.timeout(const Duration(seconds: 1));
    expect(requests, hasLength(1));
    gate.complete();
    final results = await Future.wait([first, second]);

    expect(results.every((result) => result.isConfirmedFiller(1)), isTrue);
    expect(requests, hasLength(1));
  });

  test('invalid identity never performs a request', () async {
    final requests = <RequestOptions>[];
    final repository = JikanFillerEpisodeRepository(
      dio: _stubDio(requests, (_) => const <String, dynamic>{}),
      cacheStore: _MemoryCacheStore(),
      minimumRequestInterval: Duration.zero,
      clock: () => now,
    );

    final result = await repository.lookup(
      FillerSeriesIdentity(anilistMediaId: 0, malMediaId: 21),
    );

    expect(result.unavailableReason, FillerUnavailableReason.invalidIdentity);
    expect(result.canAutoSkip, isFalse);
    expect(requests, isEmpty);
  });
}

Dio _stubDio(
  List<RequestOptions> requests,
  Map<String, dynamic> Function(RequestOptions request) responder,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.jikan.test/v4/'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final payload = responder(request);
        handler.resolve(
          Response<ResponseBody>(
            requestOptions: request,
            statusCode: 200,
            data: ResponseBody.fromString(jsonEncode(payload), 200),
          ),
        );
      },
    ),
  );
  return dio;
}

Map<String, dynamic> _episodePage({
  required int lastPage,
  required bool hasNext,
  required List<(int, bool)> episodes,
}) => {
  'pagination': {'last_visible_page': lastPage, 'has_next_page': hasNext},
  'data': [
    for (final (episode, filler) in episodes)
      {'mal_id': episode, 'filler': filler},
  ],
};

class _MemoryCacheStore implements FillerEpisodeCacheStore {
  final Map<String, Map<String, dynamic>> values = {};
  int writes = 0;

  @override
  Future<Map<String, dynamic>?> read(String key) async => values[key];

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> payload, {
    required Duration maxAge,
  }) async {
    writes++;
    values[key] = Map<String, dynamic>.from(payload);
  }
}
