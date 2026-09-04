import 'package:anime_tv/features/catalog/data/anilist_catalog_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads, validates, sanitizes, and caches AniZip episode metadata',
    () async {
      var requests = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.ani.zip/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              expect(options.uri.path, '/mappings');
              expect(options.queryParameters['anilist_id'], 21);
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'mappings': <String, dynamic>{'anilist_id': 21},
                    'episodes': <String, dynamic>{
                      '1': <String, dynamic>{
                        'episode': '1',
                        'title': <String, dynamic>{
                          'en': 'Romance Dawn',
                          'x-jat': 'Romance Dawn',
                        },
                        'image': 'https://images.example/one-piece-1.jpg',
                        'summary':
                            '<b>Luffy</b> begins his adventure.\nSource: Test',
                        'runtime': 25,
                      },
                      '2': <String, dynamic>{
                        'episode': '2',
                        'title': <String, dynamic>{'x-jat': 'Zoro Appears'},
                        'image': 'http://images.example/not-secure.jpg',
                        'length': 24,
                      },
                      '3': <String, dynamic>{
                        'episode': '99',
                        'title': <String, dynamic>{'en': 'Wrong mapping'},
                      },
                      'S1': <String, dynamic>{
                        'episode': 'S1',
                        'title': <String, dynamic>{'en': 'Special'},
                      },
                    },
                  },
                ),
              );
            },
          ),
        );
      final client = AniListCatalogClient(episodeMetadataDio: dio);

      final first = await client.episodeMetadata(21);
      final cached = await client.episodeMetadata(21);

      expect(requests, 1);
      expect(identical(first, cached), isTrue);
      expect(first.keys, <int>[1, 2]);
      expect(first[1]?.title, 'Romance Dawn');
      expect(first[1]?.thumbnailUrl, 'https://images.example/one-piece-1.jpg');
      expect(first[1]?.synopsis, 'Luffy begins his adventure. Source: Test');
      expect(first[1]?.durationMinutes, 25);
      expect(first[2]?.title, 'Zoro Appears');
      expect(first[2]?.thumbnailUrl, isNull);
      expect(first[2]?.durationMinutes, 24);
    },
  );

  test('rejects episode metadata for a different AniList identity', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://api.ani.zip/'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'mappings': <String, dynamic>{'anilist_id': 999},
                'episodes': <String, dynamic>{
                  '1': <String, dynamic>{
                    'episode': '1',
                    'title': <String, dynamic>{'en': 'Wrong show'},
                  },
                },
              },
            ),
          ),
        ),
      );

    expect(
      await AniListCatalogClient(episodeMetadataDio: dio).episodeMetadata(21),
      isEmpty,
    );
  });
}
