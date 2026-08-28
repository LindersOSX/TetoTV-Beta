import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'uses Bearer auth and parses official account and transfer models',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://premiumize.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.headers['Authorization'], 'Bearer private-key');
              expect(options.uri.toString(), isNot(contains('private-key')));
              final data = switch (options.path) {
                '/api/account/info' => <String, dynamic>{
                  'status': 'success',
                  'customer_id': '12345',
                  'premium_until': 4070908800,
                  'limit_used': .25,
                  'booster_points': 10,
                },
                '/api/transfer/directdl' => <String, dynamic>{
                  'status': 'success',
                  'content': [
                    {
                      'path': 'Show/Episode 02.mkv',
                      'size': 200,
                      'link': 'https://cdn.premiumize.test/02.mkv',
                    },
                  ],
                },
                '/api/cache/check' => <String, dynamic>{
                  'status': 'success',
                  'response': [true],
                  'filename': ['Show'],
                  'filesize': ['200'],
                },
                '/api/transfer/create' => <String, dynamic>{
                  'status': 'success',
                  'id': 'transfer-1',
                  'name': 'Show',
                },
                '/api/transfer/list' => <String, dynamic>{
                  'status': 'success',
                  'transfers': [
                    {
                      'id': 'transfer-1',
                      'name': 'Show',
                      'status': 'finished',
                      'progress': 1,
                      'message': '',
                      'folder_id': 'folder-1',
                      'file_id': null,
                    },
                  ],
                },
                '/api/item/details' => <String, dynamic>{
                  'status': 'success',
                  'id': 'file-1',
                  'name': 'Episode 02.mkv',
                  'size': 200,
                  'link': 'https://cdn.premiumize.test/item.mkv',
                },
                '/api/folder/list' => <String, dynamic>{
                  'status': 'success',
                  'content': [
                    {'id': 'nested', 'name': 'Season', 'type': 'folder'},
                    {
                      'id': 'file-1',
                      'name': 'Episode 02.mkv',
                      'type': 'file',
                      'size': 200,
                      'link': 'https://cdn.premiumize.test/folder.mkv',
                    },
                  ],
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
      final client = PremiumizeClient(token: 'private-key', dio: dio);

      final account = await client.account();
      final cached = await client.isCached('magnet:?xt=urn:btih:test');
      final direct = await client.directDownload('magnet:?xt=urn:btih:test');
      final created = await client.createTransfer('magnet:?xt=urn:btih:test');
      final transfers = await client.transfers();
      final item = await client.itemDetails('file-1');
      final folder = await client.folderContents('folder-1');

      expect(account.customerId, '12345');
      expect(account.isPremium, isTrue);
      expect(account.limitUsed, .25);
      expect(cached, isTrue);
      expect(direct.single.name, 'Show/Episode 02.mkv');
      expect(created.id, 'transfer-1');
      expect(transfers.single.isReady, isTrue);
      expect(item.link.scheme, 'https');
      expect(folder.where((entry) => entry.isFolder), hasLength(1));
      expect(folder.where((entry) => !entry.isFolder), hasLength(1));
    },
  );

  test('maps a business-logic authentication error', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://premiumize.test'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: const {
                'status': 'error',
                'code': 'authentication_failed',
                'message': 'API key invalid',
              },
            ),
          ),
        ),
      );
    final client = PremiumizeClient(token: 'hidden-key', dio: dio);

    await expectLater(
      client.account(),
      throwsA(
        isA<PremiumizeException>()
            .having(
              (error) => error.isAuthenticationFailure,
              'authentication failure',
              isTrue,
            )
            .having(
              (error) => error.toString(),
              'message',
              isNot(contains('hidden-key')),
            ),
      ),
    );
  });
}
