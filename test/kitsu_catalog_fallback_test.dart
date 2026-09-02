import 'package:anime_tv/features/catalog/data/kitsu_catalog_fallback.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'seasonal fallback filters the Kitsu request before pagination',
    () async {
      RequestOptions? captured;
      final dio = Dio(BaseOptions(baseUrl: 'https://kitsu.io/api/edge/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured = options;
              handler.resolve(
                Response<Map<String, dynamic>>(
                  data: {
                    'data': [_animeResource()],
                    'included': _includedResources(),
                  },
                  requestOptions: options,
                  statusCode: 200,
                ),
              );
            },
          ),
        );
      final fallback = KitsuCatalogFallback(dio: dio);

      final results = await fallback.seasonal(DateTime(2026, 8, 10), page: 2);

      expect(results.single.id, 101);
      expect(captured?.uri.path, endsWith('/anime'));
      expect(captured?.queryParameters['filter[seasonYear]'], 2026);
      expect(captured?.queryParameters['filter[season]'], 'summer');
      expect(captured?.queryParameters['page[offset]'], 20);
      expect(captured?.queryParameters['sort'], '-userCount');
    },
  );
}

Map<String, dynamic> _animeResource() => {
  'type': 'anime',
  'id': '42',
  'attributes': {
    'canonicalTitle': 'Current season title',
    'titles': {'en': 'Current season title'},
    'synopsis': 'A safe seasonal fixture.',
    'averageRating': '80',
    'startDate': '2026-07-08',
    'subtype': 'TV',
    'status': 'current',
    'posterImage': {'large': 'https://images.example/poster.jpg'},
  },
  'relationships': {
    'mappings': {
      'data': [
        {'type': 'mappings', 'id': 'anilist'},
      ],
    },
    'categories': {'data': <Map<String, dynamic>>[]},
  },
};

List<Map<String, dynamic>> _includedResources() => [
  {
    'type': 'mappings',
    'id': 'anilist',
    'attributes': {'externalSite': 'anilist/anime', 'externalId': '101'},
  },
];
