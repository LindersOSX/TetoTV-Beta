import 'package:anime_tv/features/tracking/data/anilist_tracking_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('looks up and deletes the AniList media-list entry', () async {
    final requests = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final query =
              (options.data as Map<String, dynamic>)['query'] as String;
          final data = query.contains('Viewer')
              ? const {
                  'Viewer': {'id': 7},
                }
              : query.contains('DeleteMediaListEntry')
              ? const {
                  'DeleteMediaListEntry': {'deleted': true},
                }
              : const {
                  'MediaList': {'id': 42},
                };
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {'data': data},
            ),
          );
        },
      ),
    );
    final repository = AniListTrackingRepository(
      accessToken: 'unused-by-injected-client',
      dio: dio,
    );

    await repository.removeFromList(mediaId: 9001);

    expect(requests, hasLength(3));
    expect((requests[1].data as Map<String, dynamic>)['variables'], {
      'mediaId': 9001,
      'userId': 7,
    });
    expect((requests[2].data as Map<String, dynamic>)['variables'], {'id': 42});
  });

  test('removal is idempotent when the title is not on AniList', () async {
    var requestCount = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://graphql.anilist.co'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestCount++;
          final query =
              (options.data as Map<String, dynamic>)['query'] as String;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'data': query.contains('Viewer')
                    ? const {
                        'Viewer': {'id': 7},
                      }
                    : const {'MediaList': null},
              },
            ),
          );
        },
      ),
    );
    final repository = AniListTrackingRepository(
      accessToken: 'unused-by-injected-client',
      dio: dio,
    );

    await repository.removeFromList(mediaId: 9001);

    expect(requestCount, 2);
  });
}
