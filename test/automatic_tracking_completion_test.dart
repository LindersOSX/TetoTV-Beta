import 'package:anime_tv/features/tracking/data/anilist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/kitsu_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/myanimelist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'completion needs the exact positive final count and finished airing',
    () {
      expect(
        trackingSeriesIsComplete(
          completedEpisodes: 12,
          totalEpisodes: 12,
          finishedAiring: true,
        ),
        isTrue,
      );
      expect(
        trackingSeriesIsComplete(
          completedEpisodes: 1,
          totalEpisodes: 1,
          finishedAiring: true,
        ),
        isTrue,
      );
      for (final total in <int?>[null, 0, -1, 11, 13]) {
        expect(
          trackingSeriesIsComplete(
            completedEpisodes: 12,
            totalEpisodes: total,
            finishedAiring: true,
          ),
          isFalse,
        );
      }
      expect(
        trackingSeriesIsComplete(
          completedEpisodes: 12,
          totalEpisodes: 12,
          finishedAiring: false,
        ),
        isFalse,
      );
    },
  );

  for (final provider in ['AniList', 'MAL', 'Kitsu']) {
    group(provider, () {
      test(
        'final episode writes progress and explicit Completed, not score',
        () async {
          final harness = _CompletionHarness(provider);
          await harness.sync(12);
          expect(harness.progress, 12);
          expect(harness.status, 'completed');
          expect(harness.mutations, isNotEmpty);
          for (final mutation in harness.mutations) {
            expect(
              mutation.keys,
              everyElement(
                isIn(['mediaId', 'progress', 'status', 'num_watched_episodes']),
              ),
            );
          }
        },
      );

      test('already-final progress still sends Completed on retry', () async {
        final harness = _CompletionHarness(provider)..progress = 12;
        await harness.sync(12);
        expect(harness.status, 'completed');
        expect(harness.mutations, hasLength(1));
        expect(
          harness.mutations.single['status'],
          provider == 'AniList' ? 'COMPLETED' : 'completed',
        );
        expect(harness.mutations.single.containsKey('progress'), isFalse);
        expect(
          harness.mutations.single.containsKey('num_watched_episodes'),
          isFalse,
        );
      });

      test('status failure can retry after progress was saved', () async {
        final harness = _CompletionHarness(provider)..failCompletion = true;
        await expectLater(harness.sync(12), throwsA(isA<DioException>()));
        harness.failCompletion = false;
        await harness.sync(12);
        expect(harness.progress, 12);
        expect(harness.status, 'completed');
      });

      for (final total in <Object?>[null, 0, -1, 12.5, '12', 24]) {
        test('does not complete with unverified total $total', () async {
          final harness = _CompletionHarness(provider)..total = total;
          await harness.sync(12);
          expect(harness.progress, 12);
          expect(harness.status, 'watching');
          expect(
            harness.mutations.any((m) => m.containsKey('status')),
            isFalse,
          );
        });
      }

      test('airing and partial episodes stay Watching', () async {
        final airing = _CompletionHarness(provider)..finishedAiring = false;
        await airing.sync(12);
        expect(airing.status, 'watching');
        final partial = _CompletionHarness(provider);
        await partial.sync(11);
        expect(partial.status, 'watching');
      });

      test(
        'rewatching an early episode cannot complete or reduce progress',
        () async {
          final harness = _CompletionHarness(provider)..progress = 12;
          await harness.sync(1);
          expect(harness.progress, 12);
          expect(harness.status, 'watching');
          expect(harness.mutations, isEmpty);
        },
      );

      test('mismatched metadata identity causes no mutation', () async {
        final harness = _CompletionHarness(provider)..metadataId = 999;
        await expectLater(harness.sync(12), throwsA(isA<FormatException>()));
        expect(harness.mutations, isEmpty);
      });

      test('uses stable catalog mapping and never title search', () async {
        final harness = _CompletionHarness(provider);
        await harness.sync(12, externalIds: true);
        expect(harness.status, 'completed');
        expect(harness.requests.any((r) => r.path.contains('search')), isFalse);
        if (provider == 'Kitsu') {
          expect(
            harness.requests.where((r) => r.path == '/mappings'),
            hasLength(2),
          );
        }
      });
    });
  }
}

class _CompletionHarness {
  _CompletionHarness(this.provider) {
    final dio = Dio(BaseOptions(baseUrl: 'https://tracker.invalid'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          final response = _respond(request);
          if (response.statusCode == 503) {
            handler.reject(
              DioException.badResponse(
                statusCode: 503,
                requestOptions: request,
                response: response,
              ),
            );
          } else {
            handler.resolve(response);
          }
        },
      ),
    );
    repository = switch (provider) {
      'AniList' => AniListTrackingRepository(accessToken: 'unused', dio: dio),
      'MAL' => MyAnimeListTrackingRepository(accessToken: 'unused', dio: dio),
      _ => KitsuTrackingRepository(accessToken: 'unused', dio: dio),
    };
  }

  final String provider;
  late final AutomaticCompletionTrackingRepository repository;
  final requests = <RequestOptions>[];
  final mutations = <Map<String, dynamic>>[];
  int progress = 11;
  Object? total = 12;
  int metadataId = 9;
  bool finishedAiring = true;
  bool failCompletion = false;
  String status = 'watching';

  Future<void> sync(int episode, {bool externalIds = false}) =>
      repository.updateProgressAndCompletion(
        ids: TrackingMediaIds(
          anilistId: 9,
          malId: 9,
          kitsuId: externalIds ? null : 9,
        ),
        completedEpisodes: episode,
      );

  Response<Map<String, dynamic>> _respond(RequestOptions request) {
    Map<String, dynamic> data;
    Map<String, dynamic>? mutation;
    if (provider == 'AniList') {
      final body = request.data as Map<String, dynamic>;
      final query = body['query'] as String;
      if (query.contains('SaveMediaListEntry')) {
        mutation = Map<String, dynamic>.from(body['variables'] as Map);
        data = {
          'data': {
            'SaveMediaListEntry': {'id': 51, ...mutation},
          },
        };
      } else if (query.contains('Media(id:')) {
        data = {
          'data': {
            'Media': {
              'id': metadataId,
              'episodes': total,
              'status': finishedAiring ? 'FINISHED' : 'RELEASING',
            },
          },
        };
      } else if (query.contains('Viewer')) {
        data = {
          'data': {
            'Viewer': {'id': 7},
          },
        };
      } else {
        expect(query, contains('MediaList('));
        data = {
          'data': {
            'MediaList': {'id': 51, 'progress': progress},
          },
        };
      }
    } else if (provider == 'MAL') {
      if (request.method == 'PUT') {
        mutation = Map<String, dynamic>.from(request.data as Map);
        data = mutation;
      } else {
        expect(request.path, '/anime/9');
        expect(request.queryParameters['fields'], contains('num_episodes'));
        data = {
          'id': metadataId,
          'num_episodes': total,
          'status': finishedAiring ? 'finished_airing' : 'currently_airing',
          'my_list_status': {'num_episodes_watched': progress},
        };
      }
    } else if (request.method == 'PATCH') {
      expect(request.path, '/library-entries/51');
      final resource = (request.data as Map)['data'] as Map;
      mutation = Map<String, dynamic>.from(resource['attributes'] as Map);
      data = {'data': resource};
    } else if (request.path == '/anime/9') {
      data = {
        'data': {
          'type': 'anime',
          'id': '$metadataId',
          'attributes': {
            'episodeCount': total,
            'status': finishedAiring ? 'finished' : 'current',
          },
        },
      };
    } else if (request.path == '/users') {
      data = {
        'data': [
          {'type': 'users', 'id': '7'},
        ],
      };
    } else if (request.path == '/mappings') {
      data = {
        'data': [
          {
            'type': 'mappings',
            'id': '101',
            'relationships': {
              'item': {
                'data': {'type': 'anime', 'id': '9'},
              },
            },
          },
        ],
      };
    } else {
      expect(request.path, '/library-entries');
      expect(request.queryParameters['filter[animeId]'], 9);
      data = {
        'data': [
          {
            'type': 'libraryEntries',
            'id': '51',
            'attributes': {'progress': progress},
          },
        ],
      };
    }
    if (mutation != null) {
      mutations.add(mutation);
      if (mutation.containsKey('status') && failCompletion) {
        return Response(requestOptions: request, statusCode: 503, data: {});
      }
      progress =
          (mutation['progress'] ?? mutation['num_watched_episodes']) as int? ??
          progress;
      if (mutation.containsKey('status')) status = 'completed';
    }
    return Response(requestOptions: request, statusCode: 200, data: data);
  }
}
