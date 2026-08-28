import 'dart:convert';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/local_media/data/jellyfin_client.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Jellyfin server address policy', () {
    test('normalizes a private server address and preserves its base path', () {
      expect(
        normalizeJellyfinServerUri(' 192.168.1.25:8096/jellyfin/// '),
        Uri.parse('http://192.168.1.25:8096/jellyfin'),
      );
      expect(
        normalizeJellyfinServerUri('HTTPS://Media.Example.COM/jellyfin/'),
        Uri.parse('https://media.example.com/jellyfin'),
      );
      expect(
        normalizeJellyfinServerUri('http://[fd12:3456::7]:8096/'),
        Uri.parse('http://[fd12:3456::7]:8096'),
      );
    });

    test(
      'rejects credentials, URL state, unsupported schemes, and public HTTP',
      () {
        for (final value in const [
          '',
          'ftp://192.168.1.25/video',
          'http://user:password@192.168.1.25:8096',
          'http://192.168.1.25:8096?token=secret',
          'http://192.168.1.25:8096/#fragment',
          'http://8.8.8.8:8096',
          'http://example.com:8096',
          'http://192.168.1.25:0',
          'http://192.168.1.25:not-a-port',
          'http://192.168.1.25:70000',
        ]) {
          expect(normalizeJellyfinServerUri(value), isNull, reason: value);
        }
      },
    );

    test(
      'recognizes private IP boundaries without trusting public addresses',
      () {
        for (final host in const [
          'localhost',
          '10.0.0.1',
          '172.16.0.1',
          '172.31.255.254',
          '192.168.50.2',
          '127.0.0.1',
          '169.254.1.2',
          'fd12:3456::7',
          'fe80::1',
        ]) {
          expect(isPrivateJellyfinHost(host), isTrue, reason: host);
        }
        for (final host in const [
          '8.8.8.8',
          '172.15.255.255',
          '172.32.0.1',
          '192.167.1.1',
          'example.com',
          'jellyfin',
          'jellyfin.local',
          '224.0.0.1',
          'ff02::1',
        ]) {
          expect(isPrivateJellyfinHost(host), isFalse, reason: host);
        }
      },
    );
  });

  group('Jellyfin client requests', () {
    test(
      'authenticates without exposing the password in a URL or auth header',
      () async {
        final requests = <RequestOptions>[];
        final client = JellyfinClient(
          _stubDio((request) {
            requests.add(request);
            if (request.uri.path.endsWith('/System/Info/Public')) {
              return _json(request, {
                'ServerName': 'Living Room',
                'Version': '10.10.7',
                'Id': 'server-12345678',
              });
            }
            return _json(request, {
              'AccessToken': 'access-token-1234567890',
              'User': {'Id': 'user-id-12345678', 'Name': 'Viewer'},
            });
          }),
        );

        final connection = await client.authenticate(
          baseUri: Uri.parse('http://192.168.1.25:8096/jellyfin'),
          username: ' Viewer ',
          password: 'correct horse battery staple',
          deviceId: 'device"id\r\nInjected: value',
        );

        expect(connection.serverName, 'Living Room');
        expect(connection.username, 'Viewer');
        expect(requests, hasLength(2));
        expect(requests[0].uri.path, '/jellyfin/System/Info/Public');
        expect(requests[0].headers['Authorization'], isNull);
        expect(requests[1].method, 'POST');
        expect(requests[1].uri.path, '/jellyfin/Users/AuthenticateByName');
        expect(requests[1].uri.toString(), isNot(contains('correct horse')));
        expect(requests[1].data, {
          'Username': 'Viewer',
          'Pw': 'correct horse battery staple',
        });
        final authorization = requests[1].headers['Authorization'] as String;
        expect(authorization, startsWith('MediaBrowser '));
        expect(
          authorization,
          contains(r'DeviceId="device\"idInjected: value"'),
        );
        expect(authorization, isNot(contains('\r')));
        expect(authorization, isNot(contains('\n')));
        expect(authorization, isNot(contains('correct horse')));
        expect(authorization, isNot(contains('Token=')));
      },
    );

    test('never follows a redirect carrying a saved session token', () async {
      final requests = <RequestOptions>[];
      final client = JellyfinClient(
        _stubDio((request) {
          requests.add(request);
          return _raw(
            requestOptions: request,
            statusCode: 302,
            headers: Headers.fromMap({
              'location': ['https://attacker.example/collect'],
            }),
            data: const {},
          );
        }),
      );

      await expectLater(
        client.items(_connection()),
        throwsA(
          isA<JellyfinException>().having(
            (error) => error.message,
            'message',
            contains('redirected'),
          ),
        ),
      );

      expect(requests, hasLength(1));
      expect(requests.single.uri.host, '192.168.1.25');
      expect(requests.single.followRedirects, isFalse);
      expect(
        requests.single.headers['Authorization'],
        contains('Token="access-token-1234567890"'),
      );
    });

    test(
      'lists bounded media and keeps the token out of generated URLs',
      () async {
        RequestOptions? captured;
        final client = JellyfinClient(
          _stubDio((request) {
            captured = request;
            return _json(request, {
              'Items': [
                {
                  'Id': 'episode-id-12345678',
                  'Name': 'A New Start',
                  'Type': 'Episode',
                  'SeriesName': 'Example Series',
                  'ParentIndexNumber': 2,
                  'IndexNumber': 3,
                  'ProviderIds': {
                    'AniList': '339',
                    'Tmdb': 'private-db-shape-is-ignored',
                    'Tvdb': '80554',
                    'Imdb': 'tt10808888',
                  },
                  'RunTimeTicks': 14_400_000_000,
                  'ImageTags': {'Primary': 'image-tag-123'},
                  'MediaSources': [
                    {
                      'Id': 'source/id?value',
                      'Container': 'mkv',
                      'SupportsDirectPlay': false,
                      'MediaStreams': [
                        {
                          'Type': 'Video',
                          'Codec': 'av1',
                          'BitDepth': 10,
                          'Width': 1920,
                          'Height': 1080,
                        },
                        {
                          'Type': 'Audio',
                          'Codec': 'opus',
                          'Index': 1,
                          'Language': 'jpn',
                          'IsDefault': true,
                        },
                        {
                          'Type': 'Audio',
                          'Codec': 'aac',
                          'Index': 2,
                          'Language': 'eng',
                        },
                        {
                          'Type': 'Audio',
                          'Codec': 'aac',
                          'Index': 10001,
                          'Language': 'invalid-index',
                        },
                        {
                          'Type': 'Subtitle',
                          'Codec': 'ass',
                          'Index': 3,
                          'Language': 'eng',
                          'DisplayTitle': 'English - ASS - Default',
                          'IsTextSubtitleStream': true,
                          'IsDefault': true,
                        },
                      ],
                    },
                  ],
                },
                {'Id': 'short', 'Name': 'Rejected', 'Type': 'Movie'},
              ],
              'TotalRecordCount': 2,
            });
          }),
        );

        final page = await client.items(
          _connection(),
          parentId: 'folder-id-12345678',
          startIndex: 100,
        );

        expect(page.items, hasLength(1));
        expect(page.items.single.name, 'A New Start');
        expect(page.items.single.episodeNumber, 3);
        expect(page.items.single.providerIds, {
          'anilist': '339',
          'tvdb': '80554',
          'imdb': 'tt10808888',
        });
        expect(page.items.single.videoCodec, 'av1');
        expect(page.items.single.videoBitDepth, 10);
        expect(page.items.single.audioCodec, 'opus');
        expect(page.items.single.audioStreams, hasLength(2));
        expect(page.items.single.audioStreams.first.index, 1);
        expect(page.items.single.audioStreams.first.language, 'jpn');
        expect(page.items.single.audioStreams.first.isDefault, isTrue);
        expect(page.items.single.audioStreams.last.index, 2);
        expect(page.items.single.audioStreams.last.language, 'eng');
        expect(page.items.single.audioStreams.last.isDefault, isFalse);
        expect(page.items.single.supportsDirectPlay, isFalse);
        expect(page.items.single.subtitleStreams, hasLength(1));
        expect(page.items.single.subtitleStreams.single.index, 3);
        expect(page.items.single.subtitleStreams.single.isDefault, isTrue);
        expect(captured?.uri.path, '/jellyfin/Items');
        expect(captured?.uri.queryParameters['parentId'], 'folder-id-12345678');
        expect(captured?.uri.queryParameters['startIndex'], '100');
        expect(captured?.uri.queryParameters['limit'], '100');
        expect(
          captured?.uri.queryParameters['fields']?.split(','),
          containsAll(['MediaSources', 'MediaStreams', 'ProviderIds']),
        );
        expect(captured?.headers['Authorization'], contains('Token='));

        final stream = client.streamUri(_connection(), page.items.single);
        final image = client.imageUri(_connection(), page.items.single);
        expect(stream.path, '/jellyfin/Videos/episode-id-12345678/stream');
        expect(stream.queryParameters['mediaSourceId'], 'source/id?value');
        expect(stream.queryParameters, isNot(contains('api_key')));
        expect(stream.toString(), isNot(contains('access-token')));
        expect(
          image?.path,
          '/jellyfin/Items/episode-id-12345678/Images/Primary',
        );
        expect(image.toString(), isNot(contains('access-token')));
      },
    );

    test(
      'uses authenticated HLS compatibility playback for AV1 without putting the token in the URL',
      () {
        final client = JellyfinClient();
        const item = JellyfinMediaItem(
          id: 'episode-id-12345678',
          name: 'AV1 episode',
          type: 'Episode',
          mediaSourceId: 'source-id-12345678',
          container: 'mkv',
          videoCodec: 'av1',
          videoBitDepth: 10,
          audioCodec: 'opus',
          supportsDirectPlay: true,
          subtitleStreams: [
            JellyfinSubtitleStream(
              index: 4,
              label: 'English - ASS - Default',
              language: 'eng',
              isDefault: true,
            ),
          ],
        );

        final plan = client.playbackPlan(
          _connection(),
          item,
          playSessionId: 'session_1234567890abcdef',
        );

        expect(plan.method, JellyfinPlayMethod.transcode);
        expect(
          plan.uri.path,
          '/jellyfin/Videos/episode-id-12345678/master.m3u8',
        );
        expect(plan.uri.queryParameters['VideoCodec'], 'h264');
        expect(plan.uri.queryParameters['AudioCodec'], 'aac');
        expect(plan.uri.queryParameters['EnableSubtitlesInManifest'], 'false');
        expect(
          plan.uri.queryParameters['PlaySessionId'],
          'session_1234567890abcdef',
        );
        expect(plan.uri.queryParameters, isNot(contains('api_key')));
        expect(plan.uri.toString(), isNot(contains('access-token')));
        expect(plan.headers['Authorization'], contains('Token='));
        expect(plan.mediaContentType, 'application/x-mpegURL');
        expect(
          plan.externalSubtitleUri?.path,
          '/jellyfin/Videos/episode-id-12345678/source-id-12345678/'
          'Subtitles/4/0/Stream.vtt',
        );
        expect(plan.externalSubtitleUri?.query, isEmpty);
        expect(
          plan.externalSubtitleUri.toString(),
          isNot(contains('access-token')),
        );
        expect(plan.subtitleContentType, 'text/vtt');
      },
    );

    test(
      'keeps compatibility video usable when subtitle metadata is incomplete',
      () {
        final client = JellyfinClient();
        const item = JellyfinMediaItem(
          id: 'episode-id-12345678',
          name: 'AV1 episode',
          type: 'Episode',
          videoCodec: 'av1',
          subtitleStreams: [
            JellyfinSubtitleStream(index: 4, label: 'English ASS'),
          ],
        );

        final plan = client.playbackPlan(
          _connection(),
          item,
          playSessionId: 'session_1234567890abcdef',
        );

        expect(plan.method, JellyfinPlayMethod.transcode);
        expect(plan.externalSubtitleUri, isNull);
        expect(plan.subtitleContentType, isNull);
      },
    );

    test(
      'pins compatibility transcodes to the requested bounded audio stream',
      () {
        final client = JellyfinClient();
        const item = JellyfinMediaItem(
          id: 'episode-dual-12345678',
          name: 'Dual-audio episode',
          type: 'Episode',
          mediaSourceId: 'source-dual-12345678',
          container: 'mkv',
          videoCodec: 'av1',
          videoBitDepth: 10,
          supportsDirectPlay: true,
          audioStreams: [
            JellyfinAudioStream(index: 1, language: 'ja-JP', isDefault: true),
            JellyfinAudioStream(index: 2, language: 'en-US'),
          ],
        );

        final dubPlan = client.playbackPlan(
          _connection(),
          item,
          playSessionId: 'session_dual_dub_123456',
          requestedAudio: PlaybackAudioPreference.dub,
        );
        final subPlan = client.compatibilityPlaybackPlan(
          _connection(),
          item,
          playSessionId: 'session_dual_sub_123456',
          requestedAudio: PlaybackAudioPreference.sub,
        );
        final defaultPlan = client.playbackPlan(
          _connection(),
          item,
          playSessionId: 'session_dual_default_123',
        );

        expect(dubPlan.uri.queryParameters['AudioStreamIndex'], '2');
        expect(subPlan.uri.queryParameters['AudioStreamIndex'], '1');
        expect(defaultPlan.uri.queryParameters['AudioStreamIndex'], '1');
        expect(dubPlan.uri.queryParameters, isNot(contains('api_key')));
      },
    );

    test(
      'exports every text subtitle token-free and ranks the preferred language first',
      () {
        final client = JellyfinClient();
        const item = JellyfinMediaItem(
          id: 'episode-id-12345678',
          name: 'AV1 episode',
          type: 'Episode',
          mediaSourceId: 'source-id-12345678',
          videoCodec: 'av1',
          subtitleStreams: [
            JellyfinSubtitleStream(
              index: 8,
              label: 'Unknown default',
              isDefault: true,
            ),
            JellyfinSubtitleStream(
              index: 4,
              label: 'English full',
              language: 'en-US',
            ),
            JellyfinSubtitleStream(
              index: 6,
              label: 'Japanese signs',
              language: 'jpn',
              isForced: true,
            ),
          ],
        );

        final englishPlan = client.playbackPlan(
          _connection(),
          item,
          playSessionId: 'session_english_123456',
          preferredSubtitleLanguage: 'eng',
        );
        final japanesePlan = client.playbackPlan(
          _connection(),
          item,
          playSessionId: 'session_japanese_12345',
          preferredSubtitleLanguage: 'ja-JP',
        );

        expect(englishPlan.externalSubtitleTracks.map((track) => track.label), [
          'English full',
          'Unknown default',
          'Japanese signs',
        ]);
        expect(
          japanesePlan.externalSubtitleTracks.map((track) => track.label),
          ['Japanese signs', 'Unknown default', 'English full'],
        );
        expect(
          japanesePlan.externalSubtitleTracks.map((track) => track.language),
          ['jpn', null, 'en-US'],
        );
        for (final track in japanesePlan.externalSubtitleTracks) {
          expect(track.contentType, 'text/vtt');
          expect(track.uri.query, isEmpty);
          expect(track.uri.toString(), isNot(contains('access-token')));
          expect(track.uri.toString(), isNot(contains('api_key')));
        }
      },
    );

    test('keeps ordinary H.264 direct play token-free', () {
      final client = JellyfinClient();
      const item = JellyfinMediaItem(
        id: 'episode-id-12345678',
        name: 'H.264 episode',
        type: 'Episode',
        mediaSourceId: 'source-id-12345678',
        container: 'mkv',
        videoCodec: 'h264',
        videoBitDepth: 8,
        supportsDirectPlay: true,
      );

      final plan = client.playbackPlan(
        _connection(),
        item,
        playSessionId: 'session_1234567890abcdef',
        requestedAudio: PlaybackAudioPreference.dub,
      );

      expect(plan.method, JellyfinPlayMethod.directPlay);
      expect(plan.uri.path, '/jellyfin/Videos/episode-id-12345678/stream');
      expect(plan.uri.queryParameters['static'], 'true');
      expect(plan.uri.queryParameters, isNot(contains('AudioStreamIndex')));
      expect(plan.mediaContentType, 'video/x-matroska');
      expect(plan.uri.toString(), isNot(contains('access-token')));
    });

    test('prefers an H.264/AAC transcode for TrueHD audio', () {
      final client = JellyfinClient();
      const item = JellyfinMediaItem(
        id: 'episode-truehd-12345678',
        name: 'TrueHD episode',
        type: 'Episode',
        mediaSourceId: 'source-truehd-12345678',
        container: 'mkv',
        videoCodec: 'h264',
        videoBitDepth: 8,
        audioCodec: 'truehd',
        supportsDirectPlay: true,
      );

      final plan = client.playbackPlan(
        _connection(),
        item,
        playSessionId: 'session_truehd_123456789',
      );

      expect(plan.method, JellyfinPlayMethod.transcode);
      expect(plan.uri.queryParameters['VideoCodec'], 'h264');
      expect(plan.uri.queryParameters['AudioCodec'], 'aac');
      expect(plan.uri.queryParameters, isNot(contains('api_key')));
      expect(plan.uri.toString(), isNot(contains('access-token')));
    });

    test('explicit compatibility selection transcodes ordinary H.264/AAC', () {
      final client = JellyfinClient();
      const item = JellyfinMediaItem(
        id: 'episode-compatible-12345678',
        name: 'Ordinary episode',
        type: 'Episode',
        mediaSourceId: 'source-compatible-12345678',
        container: 'mkv',
        videoCodec: 'h264',
        videoBitDepth: 8,
        audioCodec: 'aac',
        supportsDirectPlay: true,
      );

      final direct = client.playbackPlan(
        _connection(),
        item,
        playSessionId: 'session_direct_1234567890',
      );
      final compatibility = client.compatibilityPlaybackPlan(
        _connection(),
        item,
        playSessionId: 'session_fallback_123456789',
      );

      expect(direct.method, JellyfinPlayMethod.directPlay);
      expect(compatibility.method, JellyfinPlayMethod.transcode);
      expect(compatibility.mediaContentType, 'application/x-mpegURL');
      expect(compatibility.uri.queryParameters['AudioCodec'], 'aac');
    });

    test('transcodes H.264 Hi10P but keeps HEVC Main 10 direct play', () {
      final client = JellyfinClient();
      const hi10p = JellyfinMediaItem(
        id: 'episode-h264-12345678',
        name: 'H.264 Hi10P episode',
        type: 'Episode',
        mediaSourceId: 'source-h264-12345678',
        container: 'mkv',
        videoCodec: 'h264',
        videoBitDepth: 10,
        supportsDirectPlay: true,
      );
      const hevcMain10 = JellyfinMediaItem(
        id: 'episode-hevc-12345678',
        name: 'HEVC Main 10 episode',
        type: 'Episode',
        mediaSourceId: 'source-hevc-12345678',
        container: 'mkv',
        videoCodec: 'hevc',
        videoBitDepth: 10,
        supportsDirectPlay: true,
      );

      final h264Plan = client.playbackPlan(
        _connection(),
        hi10p,
        playSessionId: 'session_h264_1234567890',
      );
      final hevcPlan = client.playbackPlan(
        _connection(),
        hevcMain10,
        playSessionId: 'session_hevc_1234567890',
      );

      expect(h264Plan.method, JellyfinPlayMethod.transcode);
      expect(h264Plan.uri.queryParameters['VideoCodec'], 'h264');
      expect(hevcPlan.method, JellyfinPlayMethod.directPlay);
    });

    test(
      'ignores malformed optional numeric fields instead of losing the library',
      () async {
        final client = JellyfinClient(
          _stubDio(
            (request) => _json(request, {
              'Items': [
                {
                  'Id': 'episode-id-12345678',
                  'Name': 'Malformed Metadata',
                  'Type': 'Episode',
                  'ParentIndexNumber': 'not-a-number',
                  'IndexNumber': '3',
                  'RunTimeTicks': 'unknown',
                },
              ],
              'TotalRecordCount': 1,
            }),
          ),
        );

        final page = await client.items(_connection());

        expect(page.items, hasLength(1));
        expect(page.items.single.seasonNumber, isNull);
        expect(page.items.single.episodeNumber, 3);
        expect(page.items.single.runTimeTicks, isNull);
      },
    );

    test(
      'rejects oversized decoded responses even without Content-Length',
      () async {
        final client = JellyfinClient(
          _stubDio(
            (request) => _json(request, {
              'ServerName': 'Jellyfin',
              'Version': '10.10.7',
              'Id': 'server-12345678',
              'padding': List<String>.filled(4 * 1024 * 1024 + 1, 'x').join(),
            }),
          ),
        );

        await expectLater(
          client.publicInfo(Uri.parse('https://media.example.com')),
          throwsA(
            isA<JellyfinException>().having(
              (error) => error.message,
              'message',
              contains('too much data'),
            ),
          ),
        );
      },
    );

    test('maps unauthorized responses to a bounded account error', () async {
      final client = JellyfinClient(
        _stubDio(
          (request) =>
              _raw(requestOptions: request, statusCode: 401, data: const {}),
        ),
      );

      await expectLater(
        client.items(_connection()),
        throwsA(
          isA<JellyfinException>().having(
            (error) => error.message,
            'message',
            contains('rejected'),
          ),
        ),
      );
    });

    test(
      'logs out with the saved token and accepts an empty 204 response',
      () async {
        RequestOptions? captured;
        final client = JellyfinClient(
          _stubDio((request) {
            captured = request;
            return _raw(
              requestOptions: request,
              statusCode: 204,
              data: const {},
            );
          }),
        );

        await client.logout(_connection());

        expect(captured?.method, 'POST');
        expect(captured?.uri.path, '/jellyfin/Sessions/Logout');
        expect(
          captured?.headers['Authorization'],
          contains('Token="access-token-1234567890"'),
        );
      },
    );

    test(
      'searches recursively and parses the server resume checkpoint',
      () async {
        RequestOptions? captured;
        final client = JellyfinClient(
          _stubDio((request) {
            captured = request;
            return _json(request, {
              'Items': [
                {
                  'Id': 'episode-id-12345678',
                  'Name': 'The Search',
                  'Type': 'Episode',
                  'ProductionYear': 2024,
                  'RunTimeTicks': 14_400_000_000,
                  'MediaStreams': [
                    {'Type': 'Video', 'Codec': 'h264', 'BitDepth': 10},
                  ],
                  'UserData': {
                    'PlaybackPositionTicks': 450_000_000,
                    'Played': false,
                  },
                },
              ],
              'TotalRecordCount': 1,
            });
          }),
        );

        final results = await client.search(_connection(), ' Search ');

        expect(results.single.name, 'The Search');
        expect(results.single.resumePosition, const Duration(seconds: 45));
        expect(results.single.duration, const Duration(minutes: 24));
        expect(results.single.videoCodec, 'h264');
        expect(results.single.videoBitDepth, 10);
        expect(results.single.productionYear, 2024);
        expect(captured?.uri.queryParameters['searchTerm'], 'Search');
        expect(captured?.uri.queryParameters['recursive'], 'true');
        expect(captured?.uri.queryParameters['limit'], '60');
        expect(
          captured?.uri.queryParameters['fields']?.split(','),
          containsAll(['MediaSources', 'MediaStreams']),
        );
        expect(captured?.uri.toString(), isNot(contains('access-token')));
      },
    );

    test(
      'reports playback progress without putting the token in the URL',
      () async {
        RequestOptions? captured;
        final client = JellyfinClient(
          _stubDio((request) {
            captured = request;
            return _raw(
              requestOptions: request,
              statusCode: 204,
              data: const {},
            );
          }),
        );
        const item = JellyfinMediaItem(
          id: 'episode-id-12345678',
          name: 'Episode',
          type: 'Episode',
        );

        await client.reportPlaybackProgress(
          _connection(),
          item,
          playSessionId: 'session_1234567890abcdef',
          position: const Duration(seconds: 90),
        );

        expect(captured?.method, 'POST');
        expect(captured?.uri.path, '/jellyfin/Sessions/Playing/Progress');
        expect(captured?.uri.toString(), isNot(contains('access-token')));
        expect(captured?.headers['Authorization'], contains('Token='));
        expect(captured?.data, containsPair('PositionTicks', 900_000_000));
        expect(captured?.data, containsPair('PlayMethod', 'DirectPlay'));
      },
    );

    test('loads artwork without following a token-bearing redirect', () async {
      RequestOptions? captured;
      final imageUri = Uri.parse(
        'http://192.168.1.25:8096/jellyfin/Items/item-123/Images/Primary',
      );
      final client = JellyfinClient(
        _stubDio((request) {
          captured = request;
          return _binary(
            requestOptions: request,
            statusCode: 200,
            bytes: const [1, 2, 3],
          );
        }),
      );

      expect(await client.imageBytes(_connection(), imageUri), [1, 2, 3]);
      expect(captured?.followRedirects, isFalse);
      expect(captured?.headers['Authorization'], contains('Token='));
      expect(captured?.uri.toString(), isNot(contains('access-token')));

      final redirected = JellyfinClient(
        _stubDio(
          (request) => _binary(
            requestOptions: request,
            statusCode: 302,
            bytes: const [],
            headers: Headers.fromMap({
              'location': ['https://attacker.example/collect'],
            }),
          ),
        ),
      );
      await expectLater(
        redirected.imageBytes(_connection(), imageUri),
        throwsA(
          isA<JellyfinException>().having(
            (error) => error.message,
            'message',
            contains('redirected'),
          ),
        ),
      );
    });
  });
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
) => _raw(requestOptions: request, statusCode: 200, data: data);

Response<ResponseBody> _raw({
  required RequestOptions requestOptions,
  required int statusCode,
  required Map<String, dynamic> data,
  Headers? headers,
}) => Response<ResponseBody>(
  requestOptions: requestOptions,
  statusCode: statusCode,
  headers: headers ?? Headers(),
  data: ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: const {
      Headers.contentTypeHeader: ['application/json'],
    },
  ),
);

Response<ResponseBody> _binary({
  required RequestOptions requestOptions,
  required int statusCode,
  required List<int> bytes,
  Headers? headers,
}) => Response<ResponseBody>(
  requestOptions: requestOptions,
  statusCode: statusCode,
  headers: headers ?? Headers(),
  data: ResponseBody.fromBytes(bytes, statusCode),
);

JellyfinConnection _connection() => JellyfinConnection(
  baseUri: Uri.parse('http://192.168.1.25:8096/jellyfin'),
  serverName: 'Living Room',
  serverVersion: '10.10.7',
  userId: 'user-id-12345678',
  username: 'Viewer',
  accessToken: 'access-token-1234567890',
  deviceId: 'device-id-12345678',
);
