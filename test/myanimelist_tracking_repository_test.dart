import 'package:anime_tv/features/tracking/data/myanimelist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'rejects an untrusted MAL pagination URL before sending a token',
    () async {
      final requestedUrls = <Uri>[];
      final dio = _testDio((request) {
        requestedUrls.add(request.uri);
        return _response(request, {
          'data': const <Object?>[],
          'paging': const {'next': 'https://attacker.example/collect'},
        });
      });
      final repository = MyAnimeListTrackingRepository(
        accessToken: 'unused-by-injected-client',
        dio: dio,
      );

      await expectLater(
        repository.list(TrackingListStatus.watching),
        throwsA(isA<FormatException>()),
      );

      expect(requestedUrls, hasLength(1));
      expect(requestedUrls.single.host, 'api.myanimelist.net');
    },
  );

  test('follows trusted MAL pagination with the configured client', () async {
    final requestedUrls = <Uri>[];
    final authorizationHeaders = <Object?>[];
    final dio = _testDio((request) {
      requestedUrls.add(request.uri);
      authorizationHeaders.add(request.headers['Authorization']);
      final isFirstPage = requestedUrls.length == 1;
      return _response(request, {
        'data': const <Object?>[],
        'paging': {
          if (isFirstPage)
            'next':
                'https://api.myanimelist.net/v2/users/@me/animelist?offset=100',
        },
      });
    });
    final repository = MyAnimeListTrackingRepository(
      accessToken: 'unused-by-injected-client',
      dio: dio,
    );

    await repository.list(TrackingListStatus.watching);

    expect(requestedUrls, hasLength(2));
    expect(authorizationHeaders, everyElement('Bearer test-access-token'));
  });

  test('rejects pagination loops', () async {
    const page =
        'https://api.myanimelist.net/v2/users/@me/animelist?offset=100';
    var requestCount = 0;
    final dio = _testDio((request) {
      requestCount++;
      return _response(request, {
        'data': const <Object?>[],
        'paging': const {'next': page},
      });
    });
    final repository = MyAnimeListTrackingRepository(
      accessToken: 'unused-by-injected-client',
      dio: dio,
    );

    await expectLater(
      repository.list(TrackingListStatus.watching),
      throwsA(isA<FormatException>()),
    );
    expect(requestCount, 2);
  });

  test('removes an anime from the MAL list with DELETE', () async {
    RequestOptions? captured;
    final dio = _testDio((request) {
      captured = request;
      return _response(request, const {});
    });
    final repository = MyAnimeListTrackingRepository(
      accessToken: 'unused-by-injected-client',
      dio: dio,
    );

    await repository.removeFromList(mediaId: 5150);

    expect(captured?.method, 'DELETE');
    expect(captured?.uri.path, '/v2/anime/5150/my_list_status');
  });
}

Dio _testDio(Response<dynamic> Function(RequestOptions) responder) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://api.myanimelist.net/v2',
      headers: const {'Authorization': 'Bearer test-access-token'},
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(responder(options)),
    ),
  );
  return dio;
}

Response<Map<String, dynamic>> _response(
  RequestOptions request,
  Map<String, dynamic> data,
) => Response<Map<String, dynamic>>(
  requestOptions: request,
  statusCode: 200,
  data: data,
);
