import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/catalog/data/anime_title_logo_client.dart';
import 'package:anime_tv/features/catalog/data/localized_anime_title_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses exact language tags and never invents a missing title', () async {
    final store = _Store();
    var calls = 0;
    final client = LocalizedAnimeTitleClient(
      cacheStore: store,
      dio: _dio((r) {
        calls++;
        expect(r.uri.host, 'api.ani.zip');
        expect(r.followRedirects, isFalse);
        expect(r.queryParameters, {'anilist_id': 10});
        return _body(10, {
          'en': 'English',
          'es': 'Título español',
          'pt-BR': 'Título português',
          'fr': 'Titre français',
          'hi': 'हिन्दी नाम',
          'de': 'Deutscher Titel',
          'ja': '日本語',
        });
      }),
    );
    expect(await client.lookup(10, 'es'), 'Título español');
    expect(await client.lookup(10, 'pt'), 'Título português');
    expect(await client.lookup(10, 'fr'), 'Titre français');
    expect(await client.lookup(10, 'hi'), 'हिन्दी नाम');
    expect(await client.lookup(10, 'de'), 'Deutscher Titel');
    expect(await client.lookup(10, 'en'), isNull);
    expect(await client.lookup(10, 'ja'), isNull);
    expect(calls, 1);
    expect(store.data.values.single['titles'], isNot(contains('en')));
    expect(store.age, const Duration(days: 7));
  });

  test(
    'base title wins over regional title regardless of insertion order',
    () async {
      final client = LocalizedAnimeTitleClient(
        cacheStore: _Store(),
        dio: _dio(
          (_) =>
              _body(1, {'es-MX': 'Regional', 'es': 'Base', 'es-ES': 'España'}),
        ),
      );
      expect(await client.lookup(1, 'es'), 'Base');
    },
  );

  test(
    'valid missing metadata is cached without falling back to English',
    () async {
      final store = _Store();
      final first = LocalizedAnimeTitleClient(
        cacheStore: store,
        dio: _dio(
          (_) => _body(1, {'en': 'My Hero Academia', 'pt': 'My Hero Academia'}),
        ),
      );
      expect(await first.lookup(1, 'es'), isNull);
      final second = LocalizedAnimeTitleClient(
        cacheStore: store,
        dio: _dio((_) => throw StateError('Must use cache')),
      );
      expect(await second.lookup(1, 'es'), isNull);
      expect(await second.lookup(1, 'pt'), 'My Hero Academia');
    },
  );

  test(
    'wrong identity and malformed/oversized title strings are rejected',
    () async {
      final store = _Store();
      var mismatch = true;
      final client = LocalizedAnimeTitleClient(
        cacheStore: store,
        dio: _dio(
          (_) => _body(mismatch ? 999 : 1, {
            'es': 'Wrong identity',
            'pt': 'bad\nline',
            'fr': 'x' * 501,
            'hi': '\u202ehidden',
            'de': '  ',
          }),
        ),
      );
      expect(await client.lookup(1, 'es'), isNull);
      expect(store.data, isEmpty);
      mismatch = false;
      expect(await client.lookup(1, 'pt'), isNull);
      expect(await client.lookup(1, 'fr'), isNull);
      expect(await client.lookup(1, 'hi'), isNull);
      expect(await client.lookup(1, 'de'), isNull);
    },
  );

  test(
    'transient failures do not poison the persistent missing-title cache',
    () async {
      var calls = 0;
      final store = _Store();
      final client = LocalizedAnimeTitleClient(
        cacheStore: store,
        dio: _dio((_) {
          if (++calls == 1) throw StateError('Temporary failure');
          return _body(1, {'es': 'Recuperado'});
        }),
      );
      expect(await client.lookup(1, 'es'), isNull);
      expect(store.data, isEmpty);
      expect(await client.lookup(1, 'es'), 'Recuperado');
    },
  );

  test(
    'deduplicates languages and caps parallel metadata requests at three',
    () async {
      final release = Completer<void>();
      var active = 0;
      var peak = 0;
      var calls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.ani.zip/'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (r, handler) async {
            active++;
            calls++;
            if (active > peak) peak = active;
            await release.future;
            active--;
            handler.resolve(
              Response(
                requestOptions: r,
                statusCode: 200,
                data: _body(r.queryParameters['anilist_id'] as int, {
                  'es': 'Uno',
                  'fr': 'Un',
                }),
              ),
            );
          },
        ),
      );
      final client = LocalizedAnimeTitleClient(cacheStore: _Store(), dio: dio);
      final requests = [
        for (var i = 1; i <= 8; i++) client.lookup(i, 'es'),
        client.lookup(1, 'fr'),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 3);
      release.complete();
      final results = await Future.wait(requests);
      expect(results.last, 'Un');
      expect(peak, 3);
      expect(calls, 8);
    },
  );

  test(
    'oversized streamed body is rejected before decoding or caching',
    () async {
      final store = _Store();
      final client = LocalizedAnimeTitleClient(
        cacheStore: store,
        dio: _dio(
          (_) => ResponseBody.fromString(
            'x' * (LocalizedAnimeTitleClient.maximumResponseBytes + 1),
            200,
          ),
        ),
      );
      expect(await client.lookup(1, 'es'), isNull);
      expect(store.data, isEmpty);
    },
  );

  test(
    'invalid IDs and unsupported languages never read cache or network',
    () async {
      final store = _Store();
      final client = LocalizedAnimeTitleClient(
        cacheStore: store,
        dio: _dio((_) => throw StateError('No lookup')),
      );
      expect(await client.lookup(0, 'es'), isNull);
      expect(await client.lookup(1, 'en'), isNull);
      expect(await client.lookup(1, 'xx'), isNull);
      expect(store.reads, 0);
    },
  );
}

ResponseBody _body(int id, Map<String, String> titles) =>
    ResponseBody.fromString(
      jsonEncode({
        'mappings': {'anilist_id': id},
        'titles': titles,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Dio _dio(ResponseBody Function(RequestOptions) response) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.ani.zip/'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (r, handler) {
        try {
          handler.resolve(
            Response(requestOptions: r, statusCode: 200, data: response(r)),
          );
        } catch (_) {
          handler.reject(
            DioException(
              requestOptions: r,
              type: DioExceptionType.connectionError,
            ),
          );
        }
      },
    ),
  );
  return dio;
}

class _Store implements AnimeTitleLogoCacheStore {
  final data = <String, Map<String, dynamic>>{};
  Duration? age;
  int reads = 0;
  @override
  Future<Map<String, dynamic>?> read(
    String key, {
    bool allowExpired = false,
  }) async {
    reads++;
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
