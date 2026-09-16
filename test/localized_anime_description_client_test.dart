import 'dart:convert';

import 'package:anime_tv/features/catalog/data/anime_title_logo_client.dart';
import 'package:anime_tv/features/catalog/data/localized_anime_description_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads, sanitizes, and caches a language-matched description', () async {
    final store = _Store();
    final mappingRequests = <RequestOptions>[];
    final pageRequests = <RequestOptions>[];
    final client = LocalizedAnimeDescriptionClient(
      cacheStore: store,
      aniZipDio: _dio('https://api.ani.zip/', (request) {
        mappingRequests.add(request);
        return _mapping(anilistId: 154587, tmdbId: 209867);
      }),
      tmdbDio: _dio('https://www.themoviedb.org/', (request) {
        pageRequests.add(request);
        return _page(
          '<html lang="es"><head><meta name="description" '
          'content="Una aventura &amp; una promesa.&#x20;&lt;b&gt;Ahora&lt;/b&gt;">'
          '</head></html>',
        );
      }),
    );

    expect(
      await client.lookup(154587, 'es'),
      'Una aventura & una promesa. Ahora',
    );
    expect(mappingRequests.single.path, 'mappings');
    expect(mappingRequests.single.queryParameters, {'anilist_id': 154587});
    expect(pageRequests.single.path, 'tv/209867');
    expect(pageRequests.single.queryParameters, {'language': 'es-ES'});

    expect(await client.lookup(154587, 'es'), contains('Una aventura'));
    expect(mappingRequests, hasLength(1));
    expect(pageRequests, hasLength(1));
    expect(store.age, const Duration(days: 7));
  });

  test('maps every supported UI language to its metadata locale', () async {
    const expected = <String, String>{
      'es': 'es-ES',
      'pt': 'pt-BR',
      'fr': 'fr-FR',
      'hi': 'hi-IN',
      'de': 'de-DE',
    };
    final requestedLocales = <String>[];
    final client = LocalizedAnimeDescriptionClient(
      cacheStore: _Store(),
      aniZipDio: _dio(
        'https://api.ani.zip/',
        (request) => _mapping(
          anilistId: request.queryParameters['anilist_id'] as int,
          tmdbId: 400 + request.queryParameters['anilist_id'] as int,
          type: 'Movie',
        ),
      ),
      tmdbDio: _dio('https://www.themoviedb.org/', (request) {
        final locale = request.queryParameters['language'] as String;
        requestedLocales.add(locale);
        final language = locale.split('-').first;
        expect(request.path, startsWith('movie/'));
        return _page(
          '<html lang="$language"><meta property="og:description" '
          'content="Localized $language">',
        );
      }),
    );

    var id = 1;
    for (final entry in expected.entries) {
      expect(await client.lookup(id++, entry.key), 'Localized ${entry.key}');
    }
    expect(requestedLocales, expected.values.toList());
  });

  test(
    'rejects a mismatched identity before requesting the metadata page',
    () async {
      var pageCalls = 0;
      final client = LocalizedAnimeDescriptionClient(
        cacheStore: _Store(),
        aniZipDio: _dio(
          'https://api.ani.zip/',
          (_) => _mapping(anilistId: 999, tmdbId: 209867),
        ),
        tmdbDio: _dio('https://www.themoviedb.org/', (_) {
          pageCalls++;
          return _page('<html lang="es">');
        }),
      );

      expect(await client.lookup(154587, 'es'), isNull);
      expect(pageCalls, 0);
    },
  );

  test(
    'wrong-language pages are ignored and valid misses are cached',
    () async {
      final store = _Store();
      var mappingCalls = 0;
      var pageCalls = 0;
      final client = LocalizedAnimeDescriptionClient(
        cacheStore: store,
        aniZipDio: _dio('https://api.ani.zip/', (_) {
          mappingCalls++;
          return _mapping(anilistId: 1, tmdbId: 2);
        }),
        tmdbDio: _dio('https://www.themoviedb.org/', (_) {
          pageCalls++;
          return _page(
            '<html lang="en"><meta name="description" content="English">',
          );
        }),
      );

      expect(await client.lookup(1, 'fr'), isNull);
      expect(await client.lookup(1, 'fr'), isNull);
      expect(mappingCalls, 1);
      expect(pageCalls, 1);
      expect(store.age, const Duration(hours: 12));
    },
  );

  test(
    'a transport failure can use a safe stale localized description',
    () async {
      final now = DateTime.utc(2026, 9, 5);
      final store = _Store()
        ..data['localized-anime-description:v1:de:anilist:10'] = {
          'schema': 1,
          'anilistId': 10,
          'language': 'de',
          'found': true,
          'description': 'Zwischengespeicherte Beschreibung.',
          'fetchedAt': now
              .subtract(const Duration(days: 8))
              .millisecondsSinceEpoch,
        };
      final client = LocalizedAnimeDescriptionClient(
        cacheStore: store,
        clock: () => now,
        aniZipDio: _failingDio('https://api.ani.zip/'),
        tmdbDio: _dio(
          'https://www.themoviedb.org/',
          (_) => throw StateError('must not reach TMDB'),
        ),
      );

      expect(
        await client.lookup(10, 'de'),
        'Zwischengespeicherte Beschreibung.',
      );
      expect(store.expiredReads, 1);
    },
  );

  test(
    'unsupported locales and unsafe page metadata never leak through',
    () async {
      final client = LocalizedAnimeDescriptionClient(
        cacheStore: _Store(),
        aniZipDio: _dio(
          'https://api.ani.zip/',
          (_) => throw StateError('unsupported locale must not request'),
        ),
        tmdbDio: _dio(
          'https://www.themoviedb.org/',
          (_) => throw StateError('unsupported locale must not request'),
        ),
      );
      expect(await client.lookup(1, 'en'), isNull);
      expect(await client.lookup(1, 'ja'), isNull);
      expect(await client.lookup(0, 'es'), isNull);

      expect(
        LocalizedAnimeDescriptionClient.parseTmdbDescription(
          '<html lang="es"><meta name="description" '
          'content="texto &#x202e; oculto">',
          expectedLanguage: 'es',
        ),
        isNull,
      );
      expect(
        LocalizedAnimeDescriptionClient.parseTmdbDescription(
          '<html lang="en"><meta name="description" content="English">',
          expectedLanguage: 'es',
        ),
        isNull,
      );
    },
  );
}

ResponseBody _mapping({
  required int anilistId,
  required int tmdbId,
  String type = 'TV',
}) => ResponseBody.fromString(
  jsonEncode({
    'mappings': {
      'anilist_id': anilistId,
      'themoviedb_id': '$tmdbId',
      'type': type,
    },
  }),
  200,
);

ResponseBody _page(String html) => ResponseBody.fromString(html, 200);

Dio _dio(
  String baseUrl,
  ResponseBody Function(RequestOptions request) response,
) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        try {
          handler.resolve(
            Response<ResponseBody>(
              requestOptions: request,
              statusCode: 200,
              data: response(request),
            ),
          );
        } catch (error) {
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
              error: error,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

Dio _failingDio(String baseUrl) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.reject(
        DioException(
          requestOptions: request,
          type: DioExceptionType.connectionError,
        ),
      ),
    ),
  );
  return dio;
}

class _Store implements AnimeTitleLogoCacheStore {
  final data = <String, Map<String, dynamic>>{};
  Duration? age;
  int expiredReads = 0;

  @override
  Future<Map<String, dynamic>?> read(
    String key, {
    bool allowExpired = false,
  }) async {
    if (allowExpired) expiredReads++;
    return data[key];
  }

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    required Duration maxAge,
  }) async {
    data[key] = value;
    age = maxAge;
  }
}
