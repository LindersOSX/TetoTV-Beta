import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses Bearer auth and parses the official magnet flow', () async {
    final paths = <String>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            paths.add(options.path);
            expect(options.headers['Authorization'], 'Bearer secret-key');
            expect(options.uri.toString(), isNot(contains('secret-key')));
            final data = switch (options.path) {
              '/v4/user' => {
                'status': 'success',
                'data': {
                  'user': {
                    'username': 'teto',
                    'email': 'teto@example.test',
                    'isPremium': true,
                    'premiumUntil': '4070908800',
                  },
                },
              },
              '/v4/magnet/upload' => {
                'status': 'success',
                'data': {
                  'magnets': [
                    {'id': 42, 'ready': false},
                  ],
                },
              },
              '/v4.1/magnet/status' => {
                'status': 'success',
                'data': {
                  'magnets': [
                    {
                      'id': 42,
                      'status': 'Ready',
                      'statusCode': 4,
                      'downloaded': 200,
                      'size': 200,
                    },
                  ],
                },
              },
              '/v4/magnet/files' => {
                'status': 'success',
                'data': {
                  'magnets': [
                    {
                      'id': 42,
                      'files': [
                        {
                          'n': 'Season',
                          'e': [
                            {
                              'n': 'Episode 02.mkv',
                              's': 200,
                              'l': 'https://redirect.test/file',
                            },
                          ],
                        },
                      ],
                    },
                  ],
                },
              },
              '/v4/magnet/delete' => {
                'status': 'success',
                'data': {'message': 'Magnet was successfully deleted'},
              },
              '/v4/link/unlock' => {
                'status': 'success',
                'data': {'delayed': 77},
              },
              '/v4/link/delayed' => {
                'status': 'success',
                'data': {
                  'status': 2,
                  'link': 'https://cdn.alldebrid.test/episode-02.mkv',
                },
              },
              _ => throw StateError('Unexpected request ${options.path}'),
            };
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
    final client = AllDebridClient(
      token: 'secret-key',
      dio: dio,
      delayedPollInterval: Duration.zero,
    );

    final account = await client.account();
    final upload = await client.uploadMagnet('magnet:?xt=urn:btih:test');
    final status = await client.magnetStatus(upload.id);
    final files = await client.magnetFiles(upload.id);
    final link = await client.unlock(files.single.link);
    await client.deleteMagnet(upload.id);

    expect(account.username, 'teto');
    expect(account.isPremium, isTrue);
    expect(upload.id, 42);
    expect(status.isReady, isTrue);
    expect(status.progress, 1);
    expect(files.single.name, 'Season/Episode 02.mkv');
    expect(link.host, 'cdn.alldebrid.test');
    expect(paths, containsAll(['/v4/link/unlock', '/v4/link/delayed']));
    expect(paths, contains('/v4/magnet/delete'));
  });

  test('maps an API authentication error without exposing the key', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://alldebrid.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'status': 'error',
                'error': {
                  'code': 'AUTH_BAD_APIKEY',
                  'message': 'The auth apikey is invalid',
                },
              },
            ),
          ),
        ),
      );
    final client = AllDebridClient(token: 'must-never-leak', dio: dio);

    await expectLater(
      client.account(),
      throwsA(
        isA<AllDebridException>()
            .having((error) => error.code, 'code', 'AUTH_BAD_APIKEY')
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains('must-never-leak')),
            ),
      ),
    );
  });
}
