import 'package:anime_tv/features/streaming/data/debrid_account_history.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_models.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/torbox_models.dart';
import 'package:anime_tv/features/streaming/data/torbox_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DebridAccountHistory _history(
  Map<String, dynamic> Function(RequestOptions) response,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://account.test'))
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: response(options),
            ),
          );
        },
      ),
    );
  return DebridAccountHistory(dioFactory: (_, _) => dio);
}

DebridAccountHistoryItem _item(DebridService service, {bool ready = true}) =>
    DebridAccountHistoryItem(
      id: '42',
      name: 'Unrecognized season pack',
      service: service,
      ready: ready,
    );

void main() {
  test('manual account files require a secure provider playback URL', () async {
    for (final uri in [
      'http://cdn.test/file.mkv',
      'https://user:password@cdn.test/file.mkv',
      'https://cdn.test/file.mkv#fragment',
      'content://device/file',
    ]) {
      final file = DebridAccountVideoFile(
        id: '1',
        name: 'file.mkv',
        size: 10,
        open: () async =>
            StreamReady(uri: Uri.parse(uri), displayName: 'file.mkv'),
      );
      await expectLater(file.open(), throwsStateError);
    }
  });

  test(
    'Salieri-style shuffled pack selects every episode by filename, not index',
    () {
      const order = [6, 2, 3, 4, 5, 1, 7, 8, 9, 10, 11, 12];
      String name(int episode) =>
          '[Salieri] Chainsaw Man - ${episode.toString().padLeft(2, '0')} (1080p) (HDR) [Dual Audio].mkv';
      final torbox = [
        for (var i = 0; i < order.length; i++)
          TorBoxFile(id: i, name: name(order[i]), size: 1000),
      ];
      final realDebrid = [
        for (var i = 0; i < order.length; i++)
          RealDebridTorrentFile(
            id: i + 1,
            path: name(order[i]),
            bytes: 1000,
            selected: true,
          ),
      ];
      for (var episode = 1; episode <= 12; episode++) {
        final index = order.indexOf(episode);
        expect(
          selectTorBoxEpisodeFile(torbox, episode, requestedSeason: 1).id,
          index,
        );
        expect(
          selectEpisodeFile(realDebrid, episode, requestedSeason: 1).id,
          index + 1,
        );
      }
      expect(selectTorBoxEpisodeFile(torbox, 1).id, 5);
    },
  );

  test(
    'Real-Debrid preserves shuffled file/link identity after display sorting',
    () async {
      final calls = <String>[];
      final history = _history((request) {
        calls.add(request.path);
        if (request.path == '/torrents/info/42') {
          return {
            'id': '42',
            'status': 'downloaded',
            'files': [
              {
                'id': 1,
                'path': 'Show - 06 (HDR).mkv',
                'selected': 1,
                'bytes': 2000,
              },
              {'id': 2, 'path': 'info.nfo', 'selected': 1, 'bytes': 20},
              {
                'id': 6,
                'path': 'Show - 01 (HDR).mkv',
                'selected': 1,
                'bytes': 1000,
              },
            ],
            'links': [
              'https://rd.test/06',
              'https://rd.test/nfo',
              'https://rd.test/01',
            ],
          };
        }
        expect(request.path, '/unrestrict/link');
        expect(request.data, {'link': 'https://rd.test/01'});
        return {'download': 'https://cdn.test/episode-01.mkv'};
      });
      final files = await history.videoFiles(
        _item(DebridService.realDebrid),
        'test',
      );
      expect(files.map((file) => file.id), ['6', '1']);
      expect(calls, ['/torrents/info/42']); // Listing does not open any link.
      final ready = await files.first.open();
      expect(ready.uri.toString(), 'https://cdn.test/episode-01.mkv');
      expect(ready.displayName, 'Show - 01 (HDR).mkv');
      expect(ready.debridService, DebridService.realDebrid);
      expect(calls, ['/torrents/info/42', '/unrestrict/link']);
    },
  );

  test(
    'Real-Debrid does not assign one link to several cached files',
    () async {
      final history = _history(
        (_) => {
          'id': '42',
          'status': 'downloaded',
          'files': [
            {'id': 1, 'path': 'Part A.mkv', 'selected': 1},
            {'id': 2, 'path': 'Part B.mkv', 'selected': 1},
          ],
          'links': ['https://rd.test/unknown'],
        },
      );
      await expectLater(
        history.videoFiles(_item(DebridService.realDebrid), 'test'),
        throwsStateError,
      );
    },
  );

  test(
    'Real-Debrid offers only the selected file when one link is available',
    () async {
      final history = _history(
        (_) => {
          'id': '42',
          'status': 'downloaded',
          'files': [
            {'id': 1, 'path': 'Unavailable.mkv', 'selected': 0},
            {'id': 2, 'path': 'Available.mkv', 'selected': 1},
          ],
          'links': ['https://rd.test/available'],
        },
      );
      final files = await history.videoFiles(
        _item(DebridService.realDebrid),
        'test',
      );
      expect(files.single.id, '2');
    },
  );

  test(
    'Real-Debrid handles one link per file without selected flags',
    () async {
      final history = _history((request) {
        if (request.path == '/unrestrict/link') {
          expect(request.data, {'link': 'https://rd.test/a'});
          return {'download': 'https://cdn.test/a.mkv'};
        }
        return {
          'id': '42',
          'status': 'downloaded',
          'files': [
            {'id': 10, 'path': 'B.mkv'},
            {'id': 20, 'path': 'A.mkv'},
          ],
          'links': ['https://rd.test/b', 'https://rd.test/a'],
        };
      });
      final files = await history.videoFiles(
        _item(DebridService.realDebrid),
        'test',
      );
      expect((await files.first.open()).uri.path, '/a.mkv');
    },
  );

  test(
    'TorBox uses the explicit file ID, not its sorted or episode index',
    () async {
      final history = _history((request) {
        if (request.path == '/torrents/requestdl') {
          expect(request.queryParameters['torrent_id'], 42);
          expect(request.queryParameters['file_id'], 91);
          expect(request.queryParameters['zip_link'], false);
          return {'success': true, 'data': 'https://cdn.test/episode-2.mkv'};
        }
        expect(request.path, '/torrents/mylist');
        return {
          'success': true,
          'data': {
            'id': 42,
            'cached': true,
            'files': [
              {'id': 8, 'name': 'Show - 10.mkv', 'size': 10},
              {'id': 91, 'name': 'Show - 2.mkv', 'size': 20},
              {'id': 4, 'name': 'Show - 1.mkv', 'size': 30},
              {'id': 9, 'name': 'cover.jpg', 'size': 40},
            ],
          },
        };
      });
      final files = await history.videoFiles(
        _item(DebridService.torBox),
        'test',
      );
      expect(files.map((file) => file.id), ['4', '91', '8']);
      expect((await files[1].open()).uri.path, '/episode-2.mkv');
    },
  );

  test(
    'AllDebrid keeps nested file links attached to the chosen file',
    () async {
      final history = _history((request) {
        final data = switch (request.path) {
          '/v4.1/magnet/status' => {
            'magnets': {'id': 42, 'statusCode': 4},
          },
          '/v4/magnet/files' => {
            'magnets': [
              {
                'files': [
                  {
                    'n': 'Season',
                    'e': [
                      {'n': '02.mkv', 's': 20, 'l': 'https://ad.test/02'},
                      {'n': '01.mkv', 's': 10, 'l': 'https://ad.test/01'},
                      {
                        'n': 'README.txt',
                        's': 1,
                        'l': 'https://ad.test/readme',
                      },
                    ],
                  },
                ],
              },
            ],
          },
          '/v4/link/unlock' => {'link': 'https://cdn.test/01.mkv'},
          _ => throw StateError('Unexpected request ${request.path}'),
        };
        if (request.path == '/v4/link/unlock') {
          expect(request.data, {'link': 'https://ad.test/01'});
        }
        return {'status': 'success', 'data': data};
      });
      final files = await history.videoFiles(
        _item(DebridService.allDebrid),
        'test',
      );
      expect(files.map((file) => file.name), [
        'Season/01.mkv',
        'Season/02.mkv',
      ]);
      expect((await files.first.open()).uri.path, '/01.mkv');
    },
  );

  test(
    'Premiumize walks nested folders once and filters non-video files',
    () async {
      final folders = <String>[];
      final history = _history((request) {
        if (request.path == '/api/transfer/list') {
          return {
            'status': 'success',
            'transfers': [
              {'id': '42', 'status': 'finished', 'folder_id': 'root'},
            ],
          };
        }
        expect(request.path, '/api/folder/list');
        final id = request.queryParameters['id'] as String;
        folders.add(id);
        return {
          'status': 'success',
          'content': id == 'root'
              ? [
                  {'id': 'nested', 'name': 'Season', 'type': 'folder'},
                  {
                    'id': 'cover',
                    'name': 'cover.jpg',
                    'type': 'file',
                    'link': 'https://cdn.test/cover.jpg',
                  },
                ]
              : [
                  {'id': 'root', 'name': 'Cycle', 'type': 'folder'},
                  {
                    'id': 'ep2',
                    'name': 'Episode 2.mkv',
                    'type': 'file',
                    'size': 20,
                    'link': 'https://cdn.test/2.mkv',
                  },
                  {
                    'id': 'ep1',
                    'name': 'Episode 1.mkv',
                    'type': 'file',
                    'size': 10,
                    'link': 'https://cdn.test/1.mkv',
                  },
                ],
        };
      });
      final files = await history.videoFiles(
        _item(DebridService.premiumize),
        'test',
      );
      expect(folders, ['root', 'nested']);
      expect(files.map((file) => file.id), ['ep1', 'ep2']);
      expect((await files.first.open()).uri.path, '/1.mkv');
      expect(folders, ['root', 'nested']);
    },
  );

  test(
    'a pending account item never starts a download or file lookup',
    () async {
      final history = _history(
        (_) => throw StateError('Must not contact the service'),
      );
      for (final service in DebridService.values) {
        await expectLater(
          history.videoFiles(_item(service, ready: false), 'test'),
          throwsStateError,
        );
      }
    },
  );

  test('a stale ready flag is rechecked before files are offered', () async {
    final history = _history(
      (_) => {
        'success': true,
        'data': {
          'id': 42,
          'cached': false,
          'download_finished': false,
          'files': [
            {'id': 1, 'name': 'Show.mkv'},
          ],
        },
      },
    );
    await expectLater(
      history.videoFiles(_item(DebridService.torBox), 'test'),
      throwsStateError,
    );
  });
}
