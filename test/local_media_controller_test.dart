import 'dart:convert';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/local_media/application/local_media_controller.dart';
import 'package:anime_tv/features/local_media/data/jellyfin_client.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('local document contract accepts only provider-backed content URIs', () {
    final document = LocalMediaDocument.fromMap(const {
      'uri': 'content://com.android.providers.media/video/42',
      'name': ' USB video.mkv ',
      'mimeType': 'video/x-matroska',
      'size': 4096,
      'persistedReadPermission': true,
    });

    expect(document.name, 'USB video.mkv');
    expect(document.size, 4096);
    expect(document.persistedReadPermission, isTrue);
    for (final value in const [
      'file:///storage/emulated/0/video.mkv',
      'https://media.example/video.mkv',
      'content:opaque-value',
      'content:///missing-authority/video/42',
      'content://user:password@provider/video/42',
      'content://provider/video/42#fragment',
    ]) {
      expect(
        () => LocalMediaDocument.fromMap({'uri': value, 'name': 'video'}),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('picker persists only grants Android confirms are durable', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('dev.tetotv/android_tv');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    var persisted = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickLocalVideo');
      return <String, Object?>{
        'uri': 'content://usb.provider/video/42',
        'name': 'USB video.mkv',
        'mimeType': 'video/x-matroska',
        'size': 4096,
        'persistedReadPermission': persisted,
      };
    });
    final controller = LocalMediaController(
      storage,
      JellyfinClient(_stubDio((request) => _json(request, const {}))),
      AndroidTvBridge.instance,
    );

    final sessionOnly = await controller.pickLocalVideo();
    expect(sessionOnly?.persistedReadPermission, isFalse);
    expect(await storage.read(key: 'local_media_recent_document'), isNull);
    expect(controller.state.message, contains('only until TetoTV closes'));

    persisted = true;
    final durable = await controller.pickLocalVideo();
    expect(durable?.persistedReadPermission, isTrue);
    final saved =
        jsonDecode((await storage.read(key: 'local_media_document_index_v2'))!)
            as Map<String, dynamic>;
    expect(saved['version'], 2);
    final documents = (saved['documents'] as List).cast<Map>();
    expect(documents, hasLength(1));
    expect(documents.single['uri'], 'content://usb.provider/video/42');
    expect(documents.single['persistedReadPermission'], isTrue);
    expect(await storage.read(key: 'local_media_recent_document'), isNull);
  });

  test(
    'persisted picker grants build a deduplicated newest-first index',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('dev.tetotv/android_tv');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      var picked = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickLocalVideo');
        picked++;
        final episode = picked == 3 ? 1 : picked;
        return <String, Object?>{
          'uri': 'content://usb.provider/video/$episode',
          'name': 'Series S01E${episode.toString().padLeft(2, '0')}.mkv',
          'mimeType': 'video/x-matroska',
          'size': 4096,
          'persistedReadPermission': true,
        };
      });
      final controller = LocalMediaController(
        storage,
        JellyfinClient(_stubDio((request) => _json(request, const {}))),
        AndroidTvBridge.instance,
      );

      await controller.pickLocalVideo();
      await controller.pickLocalVideo();
      await controller.pickLocalVideo();

      expect(
        controller.localDocuments.map((document) => document.uri.toString()),
        ['content://usb.provider/video/1', 'content://usb.provider/video/2'],
      );
      expect(controller.recentLocalDocument?.name, 'Series S01E01.mkv');
      final saved =
          jsonDecode(
                (await storage.read(key: 'local_media_document_index_v2'))!,
              )
              as Map<String, dynamic>;
      final documents = (saved['documents'] as List).cast<Map>();
      expect(documents.map((document) => document['uri']), [
        'content://usb.provider/video/1',
        'content://usb.provider/video/2',
      ]);
    },
  );

  test('connect persists a token but never the submitted password', () async {
    final requests = <RequestOptions>[];
    final controller = LocalMediaController(
      storage,
      JellyfinClient(
        _stubDio((request) {
          requests.add(request);
          if (request.uri.path.endsWith('/System/Info/Public')) {
            return _json(request, {
              'ServerName': 'Living Room',
              'Version': '10.10.7',
              'Id': 'server-id-12345678',
            });
          }
          if (request.uri.path.endsWith('/Users/AuthenticateByName')) {
            return _json(request, {
              'AccessToken': 'saved-access-token-1234567890',
              'User': {'Id': 'user-id-12345678', 'Name': 'Viewer'},
            });
          }
          return _json(request, {
            'Items': [
              {
                'Id': 'movie-id-12345678',
                'Name': 'Local Movie',
                'Type': 'Movie',
              },
            ],
            'TotalRecordCount': 1,
          });
        }),
      ),
      AndroidTvBridge.instance,
    );

    await controller.connect(
      address: '192.168.1.25:8096/jellyfin',
      username: 'Viewer',
      password: 'never-save-this-password',
    );

    expect(controller.state.busy, isFalse);
    expect(controller.state.connection?.serverName, 'Living Room');
    expect(controller.state.items.single.name, 'Local Movie');
    expect(requests.map((request) => request.uri.path), [
      '/jellyfin/System/Info/Public',
      '/jellyfin/Users/AuthenticateByName',
      '/jellyfin/Items',
    ]);
    final persisted = await storage.readAll();
    expect(
      persisted['local_media_jellyfin_access_token'],
      'saved-access-token-1234567890',
    );
    expect(persisted['local_media_jellyfin_username'], 'Viewer');
    expect(persisted.keys, isNot(contains('local_media_jellyfin_password')));
    expect(persisted.values, isNot(contains('never-save-this-password')));
  });

  test('load restores the session and refreshes its root library', () async {
    FlutterSecureStorage.setMockInitialValues({
      'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
      'local_media_jellyfin_server_name': 'Living Room',
      'local_media_jellyfin_server_version': '10.10.7',
      'local_media_jellyfin_user_id': 'user-id-12345678',
      'local_media_jellyfin_username': 'Viewer',
      'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
      'local_media_jellyfin_device_id': 'device-id-12345678',
      'local_media_recent_document': jsonEncode({
        'uri': 'content://com.android.providers.media/video/42',
        'name': 'USB video.mkv',
        'mimeType': 'video/x-matroska',
        'size': 1024,
        'persistedReadPermission': true,
      }),
    });
    RequestOptions? request;
    final controller = LocalMediaController(
      storage,
      JellyfinClient(
        _stubDio((value) {
          request = value;
          return _json(value, {
            'Items': [
              {
                'Id': 'folder-id-12345678',
                'Name': 'Shows',
                'Type': 'CollectionFolder',
              },
            ],
            'TotalRecordCount': 1,
          });
        }),
      ),
      AndroidTvBridge.instance,
    );

    await controller.load();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.busy, isFalse);
    expect(controller.state.connection?.username, 'Viewer');
    expect(controller.state.recentLocalDocument?.name, 'USB video.mkv');
    expect(controller.state.localDocuments, hasLength(1));
    expect(await storage.read(key: 'local_media_recent_document'), isNull);
    expect(await storage.read(key: 'local_media_document_index_v2'), isNotNull);
    expect(controller.state.items.single.name, 'Shows');
    expect(request?.uri.path, '/jellyfin/Items');
    expect(
      request?.headers['Authorization'],
      contains('Token="saved-access-token-1234567890"'),
    );
  });

  test(
    'one failed Jellyfin alias does not discard a successful alias',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_server_name': 'Living Room',
        'local_media_jellyfin_server_version': '10.10.7',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final searched = <String>[];
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            if (term == null) {
              return _json(request, const {'Items': [], 'TotalRecordCount': 0});
            }
            searched.add(term);
            if (term == 'Unavailable alias') {
              return _jsonStatus(request, const {}, 503);
            }
            return _json(request, {
              'Items': [
                {
                  'Id': 'episode-id-12345678',
                  'Name': 'Episode 7',
                  'Type': 'Episode',
                  'SeriesName': 'Sousou no Frieren',
                  'ParentIndexNumber': 1,
                  'IndexNumber': 7,
                },
              ],
              'TotalRecordCount': 1,
            });
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 123,
          title: 'Unavailable alias',
          titleRomaji: 'Sousou no Frieren',
          episode: 7,
        ),
      );

      expect(searched, containsAll(['Unavailable alias', 'Sousou no Frieren']));
      expect(matches.map((item) => item.id), ['episode-id-12345678']);
    },
  );

  test(
    'exact Jellyfin series traversal finds episodes omitted by search',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_server_name': 'Living Room',
        'local_media_jellyfin_server_version': '10.10.7',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final requestedParents = <String>[];
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            final parent = request.uri.queryParameters['parentId'];
            if (term != null) {
              return _json(request, {
                'Items': [
                  {
                    'Id': 'series-id-12345678',
                    'Name': 'Sousou no Frieren',
                    'Type': 'Series',
                    'ProductionYear': 2023,
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == 'series-id-12345678') {
              requestedParents.add(parent!);
              return _json(request, {
                'Items': [
                  {
                    'Id': 'season-id-12345678',
                    'Name': 'Season 1',
                    'Type': 'Season',
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == 'season-id-12345678') {
              requestedParents.add(parent!);
              return _json(request, {
                'Items': [
                  {
                    'Id': 'episode-id-12345678',
                    'Name': 'Like a Fairy Tale',
                    'Type': 'Episode',
                    'SeriesName': 'Sousou no Frieren',
                    'ParentIndexNumber': 1,
                    'IndexNumber': 7,
                    'MediaSources': [
                      {
                        'Id': 'media-source-12345678',
                        'Container': 'mkv',
                        'SupportsDirectPlay': true,
                        'MediaStreams': [
                          {
                            'Type': 'Video',
                            'Codec': 'h264',
                            'Width': 1920,
                            'Height': 1080,
                          },
                        ],
                      },
                    ],
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            return _json(request, const {'Items': [], 'TotalRecordCount': 0});
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 123,
          title: 'Frieren: Beyond Journey’s End',
          titleRomaji: 'Sousou no Frieren',
          year: 2023,
          episode: 7,
        ),
      );

      expect(matches.map((item) => item.id), ['episode-id-12345678']);
      expect(matches.single.videoHeight, 1080);
      expect(requestedParents, ['series-id-12345678', 'season-id-12345678']);
    },
  );

  test(
    'release-decorated Lain folder traverses Season Unknown safely',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_server_name': 'Living Room',
        'local_media_jellyfin_server_version': '10.11.11',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      const seriesId = 'serial-lain-series-12345678';
      const seasonId = 'serial-lain-season-unknown';
      const episodeId = 'serial-lain-episode-00000001';
      const decoratedTitle =
          '[Reaktor] Serial Experiments Lain - Complete '
          '[1080p][x265][10-bit][Dual-Audio]';
      final requestedParents = <String>[];
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            final parent = request.uri.queryParameters['parentId'];
            if (term != null) {
              return _json(request, const {
                'Items': [
                  {'Id': seriesId, 'Name': decoratedTitle, 'Type': 'Series'},
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == seriesId) {
              requestedParents.add(parent!);
              return _json(request, const {
                'Items': [
                  {'Id': seasonId, 'Name': 'Season Unknown', 'Type': 'Season'},
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == seasonId) {
              requestedParents.add(parent!);
              return _json(request, const {
                'Items': [
                  {
                    'Id': episodeId,
                    'Name': 'Serial Experiments Lain - E01',
                    'Type': 'Episode',
                    'SeriesName': decoratedTitle,
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            return _json(request, const {'Items': [], 'TotalRecordCount': 0});
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 339,
          malMediaId: 339,
          title: 'Serial Experiments Lain',
          year: 1998,
          episode: 1,
        ),
      );

      expect(matches.map((item) => item.id), [episodeId]);
      expect(requestedParents, [seriesId, seasonId]);
    },
  );

  test(
    'Jellyfin lookup queries a metadata-normalized Lucky Star alias',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_server_name': 'Living Room',
        'local_media_jellyfin_server_version': '10.11.11',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final searched = <String>[];
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            if (term != null) {
              searched.add(term);
              if (term == 'lucky star') {
                return _json(request, {
                  'Items': [
                    {
                      'Id': 'episode-id-lucky-star-19',
                      'Name': 'There is Substance in 2-D',
                      'Type': 'Episode',
                      'SeriesName': 'Lucky Star',
                      'ProductionYear': 2007,
                      'ParentIndexNumber': 1,
                      'IndexNumber': 19,
                    },
                  ],
                  'TotalRecordCount': 1,
                });
              }
            }
            return _json(request, const {'Items': [], 'TotalRecordCount': 0});
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 1887,
          malMediaId: 1887,
          title: 'Lucky☆Star',
          year: 2007,
          episode: 19,
        ),
      );

      expect(searched, containsAll(['Lucky☆Star', 'lucky star']));
      expect(matches.map((item) => item.id), ['episode-id-lucky-star-19']);
    },
  );

  test(
    'Jellyfin hierarchy deterministically enriches an earlier direct hit',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            final parent = request.uri.queryParameters['parentId'];
            if (term != null) {
              return _json(request, const {
                'Items': [
                  {
                    'Id': 'fruits-episode-12345678',
                    'Name': 'Episode 1',
                    'Type': 'Episode',
                    'SeriesName': 'Fruits Basket',
                    'ParentIndexNumber': 1,
                    'IndexNumber': 1,
                  },
                  {
                    'Id': 'fruits-series-12345678',
                    'Name': 'Fruits Basket',
                    'Type': 'Series',
                    'ProductionYear': 2019,
                    'ProviderIds': {'Tmdb': '79141'},
                  },
                ],
                'TotalRecordCount': 2,
              });
            }
            if (parent == 'fruits-series-12345678') {
              return _json(request, const {
                'Items': [
                  {
                    'Id': 'fruits-season-12345678',
                    'Name': 'Season 1',
                    'Type': 'Season',
                    'IndexNumber': 1,
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == 'fruits-season-12345678') {
              return _json(request, const {
                'Items': [
                  {
                    'Id': 'fruits-episode-12345678',
                    'Name': 'Episode 1',
                    'Type': 'Episode',
                    'SeriesName': 'Fruits Basket',
                    'ParentIndexNumber': 1,
                    'IndexNumber': 1,
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            return _json(request, const {'Items': [], 'TotalRecordCount': 0});
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 105334,
          title: 'Fruits Basket',
          year: 2019,
          episode: 1,
        ),
      );

      expect(matches, hasLength(1));
      expect(matches.single.seriesProductionYear, 2019);
      expect(matches.single.seriesProviderIds['tmdb'], '79141');
    },
  );

  test(
    'Jellyfin prioritizes the expected season beyond the first twelve',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final requestedSeasons = <String>[];
      var lookupRequests = 0;
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            final parent = request.uri.queryParameters['parentId'];
            if (term != null) {
              lookupRequests++;
              return _json(request, const {
                'Items': [
                  {
                    'Id': 'adaptive-series-12345678',
                    'Name': 'Adaptive Show',
                    'Type': 'Series',
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == 'adaptive-series-12345678') {
              lookupRequests++;
              return _json(request, {
                'Items': [
                  for (var season = 1; season <= 20; season++)
                    {
                      'Id':
                          'adaptive-season-${season.toString().padLeft(8, '0')}',
                      'Name': 'Season $season',
                      'Type': 'Season',
                      'IndexNumber': season,
                    },
                ],
                'TotalRecordCount': 20,
              });
            }
            if (parent?.startsWith('adaptive-season-') == true) {
              lookupRequests++;
              requestedSeasons.add(parent!);
              final season = int.parse(parent.substring(parent.length - 8));
              return _json(request, {
                'Items': season == 20
                    ? [
                        {
                          'Id': 'adaptive-episode-12345678',
                          'Name': 'Episode 1',
                          'Type': 'Episode',
                          'SeriesName': 'Adaptive Show',
                          'ParentIndexNumber': 20,
                          'IndexNumber': 1,
                        },
                      ]
                    : const [],
                'TotalRecordCount': season == 20 ? 1 : 0,
              });
            }
            return _json(request, const {'Items': [], 'TotalRecordCount': 0});
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();
      lookupRequests = 0;

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 12345,
          title: 'Adaptive Show Season 20',
          episode: 1,
        ),
      );

      expect(requestedSeasons.first, 'adaptive-season-00000020');
      expect(matches.map((item) => item.id), ['adaptive-episode-12345678']);
      expect(lookupRequests, lessThanOrEqualTo(24));
    },
  );

  test(
    'Jellyfin episode lookup never exceeds its global request budget',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      var lookupRequests = 0;
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            final parent = request.uri.queryParameters['parentId'];
            final start =
                int.tryParse(request.uri.queryParameters['startIndex'] ?? '') ??
                0;
            if (term != null) {
              lookupRequests++;
              return _json(request, {
                'Items': [
                  for (var show = 1; show <= 3; show++)
                    {
                      'Id': 'budget-show-0000000$show',
                      'Name': 'Budget Show',
                      'Type': 'Series',
                    },
                ],
                'TotalRecordCount': 3,
              });
            }
            if (parent?.contains('-season-') == true) {
              lookupRequests++;
              return _json(request, {
                'Items': [
                  {
                    'Id': '$parent-episode-${start.toString().padLeft(3, '0')}',
                    'Name': 'Episode ${start + 1}',
                    'Type': 'Episode',
                    'SeriesName': 'Budget Show',
                    'ParentIndexNumber': 1,
                    'IndexNumber': start + 1,
                  },
                ],
                'TotalRecordCount': 1000,
              });
            }
            if (parent?.startsWith('budget-show-') == true) {
              lookupRequests++;
              return _json(request, {
                'Items': [
                  for (var season = 1; season <= 30; season++)
                    {
                      'Id':
                          '$parent-season-${season.toString().padLeft(3, '0')}',
                      'Name': 'Season $season',
                      'Type': 'Season',
                      'IndexNumber': season,
                    },
                ],
                'TotalRecordCount': 30,
              });
            }
            return _json(request, const {'Items': [], 'TotalRecordCount': 0});
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();
      lookupRequests = 0;

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 12345,
          title: 'Budget Show',
          episode: 999,
        ),
      );

      expect(matches, isEmpty);
      expect(lookupRequests, 24);
    },
  );

  test(
    'Jellyfin episode traversal paginates past one hundred children',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final episodeStarts = <int>[];
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final term = request.uri.queryParameters['searchTerm'];
            final parent = request.uri.queryParameters['parentId'];
            final start =
                int.tryParse(request.uri.queryParameters['startIndex'] ?? '') ??
                0;
            if (term != null) {
              return _json(request, const {
                'Items': [
                  {
                    'Id': 'series-pagination-12345678',
                    'Name': 'Long Running Show',
                    'Type': 'Series',
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == 'series-pagination-12345678') {
              return _json(request, const {
                'Items': [
                  {
                    'Id': 'season-pagination-12345678',
                    'Name': 'Season 1',
                    'Type': 'Season',
                  },
                ],
                'TotalRecordCount': 1,
              });
            }
            if (parent == 'season-pagination-12345678') {
              episodeStarts.add(start);
              if (start == 0) {
                return _json(request, {
                  'Items': [
                    for (var index = 1; index <= 100; index++)
                      {
                        'Id':
                            'episode-page-${index.toString().padLeft(8, '0')}',
                        'Name': 'Episode $index',
                        'Type': 'Episode',
                        'SeriesName': 'Long Running Show',
                        'ParentIndexNumber': 1,
                        'IndexNumber': index,
                      },
                  ],
                  'TotalRecordCount': 101,
                });
              }
              return _json(request, const {
                'Items': [
                  {
                    'Id': 'episode-page-00000101',
                    'Name': 'Episode 101',
                    'Type': 'Episode',
                    'SeriesName': 'Long Running Show',
                    'ParentIndexNumber': 1,
                    'IndexNumber': 101,
                    'MediaSources': [
                      {
                        'Id': 'source-page-00000101',
                        'Container': 'mkv',
                        'SupportsDirectPlay': true,
                      },
                    ],
                  },
                ],
                'TotalRecordCount': 101,
              });
            }
            return _json(request, const {'Items': [], 'TotalRecordCount': 0});
          }),
        ),
        AndroidTvBridge.instance,
      );
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 12345,
          title: 'Long Running Show',
          episode: 101,
        ),
      );

      expect(episodeStarts, [0, 100]);
      expect(matches.map((item) => item.id), ['episode-page-00000101']);
    },
  );

  test(
    'load more appends the next Jellyfin page without replacing prior items',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_server_name': 'Living Room',
        'local_media_jellyfin_server_version': '10.10.7',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final requestedStartIndexes = <String?>[];
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            final startIndex = request.uri.queryParameters['startIndex'];
            requestedStartIndexes.add(startIndex);
            final offset = int.tryParse(startIndex ?? '') ?? 0;
            final count = offset == 0 ? 100 : 1;
            return _json(request, {
              'Items': [
                for (var index = 0; index < count; index++)
                  {
                    'Id':
                        'movie-id-${(offset + index).toString().padLeft(8, '0')}',
                    'Name': 'Movie ${offset + index}',
                    'Type': 'Movie',
                  },
              ],
              'TotalRecordCount': 101,
            });
          }),
        ),
        AndroidTvBridge.instance,
      );

      await controller.load();
      expect(controller.state.items, hasLength(100));
      expect(controller.state.totalCount, 101);

      await controller.loadMore();

      expect(requestedStartIndexes, ['0', '100']);
      expect(controller.state.items, hasLength(101));
      expect(controller.state.items.first.name, 'Movie 0');
      expect(controller.state.items.last.name, 'Movie 100');

      await controller.loadMore();
      expect(requestedStartIndexes, hasLength(2));
    },
  );

  test(
    'invalid saved server and document values are discarded safely',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://public.example.com:8096',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
        'local_media_recent_document': jsonEncode({
          'uri': 'file:///storage/emulated/0/private.mkv',
          'name': 'Unsafe path',
        }),
      });
      var requestCount = 0;
      final controller = LocalMediaController(
        storage,
        JellyfinClient(
          _stubDio((request) {
            requestCount++;
            return _json(request, const {});
          }),
        ),
        AndroidTvBridge.instance,
      );

      await controller.load();

      expect(controller.state.loaded, isTrue);
      expect(controller.state.connection, isNull);
      expect(controller.state.recentLocalDocument, isNull);
      expect(requestCount, 0);
    },
  );

  test(
    'resume checkpoints do not expose a media URL or token in storage keys',
    () async {
      final controller = LocalMediaController(
        storage,
        JellyfinClient(_stubDio((request) => _json(request, const {}))),
        AndroidTvBridge.instance,
      );
      final source = Uri.parse(
        'https://media.example.com/video.mkv?api_key=secret-token',
      );

      await controller.saveResumePosition(source, const Duration(seconds: 4));
      expect(await controller.resumePosition(source), Duration.zero);

      await controller.saveResumePosition(source, const Duration(minutes: 15));
      expect(
        await controller.resumePosition(source),
        const Duration(minutes: 15),
      );
      final persisted = await storage.readAll();
      final resumeKeys = persisted.keys
          .where((key) => key.startsWith('local_media_resume_'))
          .toList();
      expect(resumeKeys, hasLength(1));
      expect(resumeKeys.single, isNot(contains('media.example.com')));
      expect(resumeKeys.single, isNot(contains('secret-token')));
    },
  );

  test('corrupt negative resume checkpoints clamp to the beginning', () async {
    final controller = LocalMediaController(
      storage,
      JellyfinClient(_stubDio((request) => _json(request, const {}))),
      AndroidTvBridge.instance,
    );
    final source = Uri.parse('content://media/video/42');
    FlutterSecureStorage.setMockInitialValues({
      'local_media_resume_${controller.checkpointId(source)}': '-45000',
    });

    expect(await controller.resumePosition(source), Duration.zero);
  });

  test(
    'disconnect removes the account token while preserving device identity',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_jellyfin_base_url': 'http://192.168.1.25:8096/jellyfin',
        'local_media_jellyfin_server_name': 'Living Room',
        'local_media_jellyfin_server_version': '10.10.7',
        'local_media_jellyfin_user_id': 'user-id-12345678',
        'local_media_jellyfin_username': 'Viewer',
        'local_media_jellyfin_access_token': 'saved-access-token-1234567890',
        'local_media_jellyfin_device_id': 'device-id-12345678',
      });
      final controller = LocalMediaController(
        storage,
        JellyfinClient(_stubDio((request) => _json(request, const {}))),
        AndroidTvBridge.instance,
      );

      await controller.disconnect();

      final persisted = await storage.readAll();
      expect(persisted['local_media_jellyfin_access_token'], isNull);
      expect(persisted['local_media_jellyfin_user_id'], isNull);
      expect(persisted['local_media_jellyfin_device_id'], 'device-id-12345678');
      expect(controller.state.connection, isNull);
    },
  );
}

Dio _stubDio(Response<dynamic> Function(RequestOptions request) responder) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(responder(request)),
    ),
  );
  return dio;
}

Response<ResponseBody> _json(
  RequestOptions request,
  Map<String, dynamic> data,
) => _jsonStatus(request, data, 200);

Response<ResponseBody> _jsonStatus(
  RequestOptions request,
  Map<String, dynamic> data,
  int statusCode,
) => Response<ResponseBody>(
  requestOptions: request,
  statusCode: statusCode,
  data: ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: const {
      Headers.contentTypeHeader: ['application/json'],
    },
  ),
);
