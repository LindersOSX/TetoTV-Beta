import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry in {
    DioExceptionType.connectionError: 'CONNECTION_FAILED',
    DioExceptionType.connectionTimeout: 'REQUEST_TIMEOUT',
    DioExceptionType.sendTimeout: 'REQUEST_TIMEOUT',
    DioExceptionType.receiveTimeout: 'REQUEST_TIMEOUT',
    DioExceptionType.badCertificate: 'SECURE_CONNECTION_FAILED',
  }.entries) {
    test(
      '${entry.key} gives safe terminal service failure without retry',
      () async {
        var calls = 0;
        final dio = Dio(BaseOptions(baseUrl: 'https://torbox.test'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                calls++;
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: entry.key,
                    message:
                        'private.example token=private-secret at 192.168.1.20',
                  ),
                );
              },
            ),
          );
        final client = TorBoxClient(token: 'test-token', dio: dio);
        await expectLater(
          client.account(),
          throwsA(
            isA<TorBoxException>()
                .having((e) => e.code, 'code', entry.value)
                .having(
                  (e) => isTerminalDebridFailoverFailure(e),
                  'stops fan-out',
                  true,
                )
                .having(
                  (e) => e.toString(),
                  'safe message',
                  allOf(
                    isNot(contains('private')),
                    isNot(contains('192.168.1.20')),
                  ),
                ),
          ),
        );
        expect(calls, 1);
      },
    );
  }
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
