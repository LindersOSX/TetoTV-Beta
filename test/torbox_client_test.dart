import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'createTorrent sends the atomic cached-only flag and rejects a malformed ID',
    () async {
      FormData? submittedForm;
      final dio = Dio(BaseOptions(baseUrl: 'https://torbox.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.path, '/torrents/createtorrent');
              submittedForm = options.data as FormData;
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const {
                    'success': true,
                    'data': {'torrent_id': 'not-a-number'},
                  },
                ),
              );
            },
          ),
        );
      final client = TorBoxClient(token: 'test-token', dio: dio);

      await expectLater(
        client.createTorrent('magnet:?xt=urn:btih:test', addOnlyIfCached: true),
        throwsA(
          isA<TorBoxException>().having(
            (error) => error.message,
            'message',
            contains('invalid torrent ID'),
          ),
        ),
      );
      final fields = Map<String, String>.fromEntries(submittedForm!.fields);
      expect(fields['add_only_if_cached'], 'true');
      expect(fields['magnet'], 'magnet:?xt=urn:btih:test');
    },
  );

  test('createTorrent preserves the TorBox atomic cache-miss code', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://torbox.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: const {
                  'success': false,
                  'error': 'DOWNLOAD_NOT_CACHED',
                  'detail': 'The torrent is not cached.',
                },
              ),
            );
          },
        ),
      );
    final client = TorBoxClient(token: 'test-token', dio: dio);

    await expectLater(
      client.createTorrent('magnet:?xt=urn:btih:test', addOnlyIfCached: true),
      throwsA(
        isA<TorBoxException>().having(
          (error) => error.code,
          'code',
          'DOWNLOAD_NOT_CACHED',
        ),
      ),
    );
  });

  test('parses current checkcached object hits and null misses', () async {
    const hash = '0123456789abcdef0123456789abcdef01234567';
    var calls = 0;
    final dio = Dio(BaseOptions(baseUrl: 'https://torbox.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/torrents/checkcached');
            expect(options.queryParameters['hash'], hash);
            expect(options.queryParameters['format'], 'object');
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: calls++ == 0
                    ? const {
                        'success': true,
                        'data': {
                          hash: {'hash': hash, 'name': 'Cached torrent'},
                        },
                      }
                    : const {'success': true, 'data': null},
              ),
            );
          },
        ),
      );
    final client = TorBoxClient(token: 'test-token', dio: dio);

    expect(await client.isTorrentCached(hash), isTrue);
    expect(await client.isTorrentCached(hash), isFalse);
  });
}
