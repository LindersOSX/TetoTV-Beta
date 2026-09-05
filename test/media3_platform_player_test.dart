import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/diagnostics/playback_performance_monitor.dart';
import 'package:anime_tv/features/player/application/media3_platform_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sidecar batches deduplicate URIs and only forward typed supported fields',
    () async {
      final h = await _Harness.create();
      await h.player.open(
        Media(
          'https://media.example/deduplicated.mkv',
          extras: {
            'subtitles': [
              {
                'uri': 'https://captions.example/en.vtt',
                'title': 'English',
                'language': 'en',
                'mimeType': 'text/vtt',
                'unrelated': 'private-note',
              },
              {'uri': 'https://captions.example/en.vtt', 'title': 'Duplicate'},
              {
                'uri': 'https://captions.example/it.srt',
                'title': 123,
                'language': false,
                'mimeType': 'application/unknown-subtitle',
              },
            ],
          },
        ),
      );
      expect(h.arguments('open')['subtitles'], [
        {
          'uri': 'https://captions.example/en.vtt',
          'title': 'English',
          'language': 'en',
          'mimeType': 'text/vtt',
        },
        {'uri': 'https://captions.example/it.srt'},
      ]);
      await h.player.setSubtitleTrack(
        SubtitleTrack.uri('https://captions.example/it.srt'),
      );
      expect(h.arguments('setSubtitleTrack')['trackId'], 'sidecar:2');
    },
  );

  test('open batches at most 32 valid sidecars with typed metadata', () async {
    final h = await _Harness.create();
    final valid = List.generate(
      40,
      (index) => {
        'uri': 'https://captions.example/$index.vtt',
        'title': 'Caption $index',
        'language': index.isEven ? 'en' : 'es',
        'mimeType': 'text/vtt',
      },
    );
    await h.player.open(
      Media(
        'https://media.example/batch.mkv',
        extras: {
          'subtitles': [
            null,
            'not-a-row',
            {},
            {'uri': 12},
            {'uri': ''},
            {'uri': '/relative.vtt'},
            {'uri': 'javascript:alert(1)'},
            {'uri': 'https://user:secret@captions.example/private.vtt'},
            ...valid,
          ],
        },
      ),
    );
    expect(h.arguments('open')['subtitles'], valid.take(32).toList());
    expect(h.calls.where((call) => call.method == 'addSubtitleTrack'), isEmpty);
    await h.player.setSubtitleTrack(SubtitleTrack.uri(valid.first['uri']!));
    expect(h.arguments('setSubtitleTrack')['trackId'], 'sidecar:1');
    await h.player.setSubtitleTrack(SubtitleTrack.uri(valid[31]['uri']!));
    expect(h.arguments('setSubtitleTrack')['trackId'], 'sidecar:32');
    expect(h.calls.where((call) => call.method == 'addSubtitleTrack'), isEmpty);
  });

  test(
    'preloaded sidecar URI selects the registered track without reopening',
    () async {
      final h = await _Harness.create();
      const uri = 'https://captions.example/preloaded.srt';
      await h.player.open(
        Media(
          'https://media.example/preloaded.mkv',
          extras: {
            'subtitles': [
              {
                'uri': uri,
                'title': 'Italian',
                'language': 'it',
                'mimeType': 'application/x-subrip',
              },
            ],
          },
        ),
      );
      final before = h.calls.length;
      await h.player.addSubtitleTrack(SubtitleTrack.uri(uri), select: false);
      expect(h.calls, hasLength(before));
      await h.player.addSubtitleTrack(SubtitleTrack.uri(uri));
      expect(h.calls.last.method, 'setSubtitleTrack');
      expect(h.arguments('setSubtitleTrack')['trackId'], 'sidecar:1');
      expect(h.calls.where((call) => call.method == 'open'), hasLength(1));
      expect(
        h.calls.where((call) => call.method == 'addSubtitleTrack'),
        isEmpty,
      );
    },
  );

  test('new sidecar result is reused until the next episode opens', () async {
    final h = await _Harness.create(
      onCall: (call) async {
        if (call.method == 'addSubtitleTrack') return {'trackId': 'sidecar:1'};
        return null;
      },
    );
    await h.open();
    final subtitle = SubtitleTrack.uri('https://captions.example/reused.vtt');
    await h.player.addSubtitleTrack(subtitle, select: false);
    await h.player.addSubtitleTrack(subtitle);
    expect(h.arguments('setSubtitleTrack')['trackId'], 'sidecar:1');
    expect(
      h.calls.where((call) => call.method == 'addSubtitleTrack'),
      hasLength(1),
    );
    await h.open();
    await h.player.addSubtitleTrack(subtitle);
    expect(
      h.calls.where((call) => call.method == 'addSubtitleTrack'),
      hasLength(2),
    );
  });

  test(
    'invalid-only sidecar extras do not send a broken subtitle batch',
    () async {
      final h = await _Harness.create();
      await h.player.open(
        Media(
          'https://media.example/invalid-sidecars.mkv',
          extras: {
            'subtitles': [
              {'uri': 1},
              {'uri': 'ftp://captions.example/cc.srt'},
              {'uri': 'https://'},
            ],
          },
        ),
      );
      expect(h.arguments('open'), isNot(contains('subtitles')));
      await h.player.open(
        Media(
          'https://media.example/non-list-sidecars.mkv',
          extras: {
            'subtitles': {'uri': 'https://captions.example/cc.srt'},
          },
        ),
      );
      expect(h.arguments('open'), isNot(contains('subtitles')));
    },
  );

  test(
    'unsupported tracks are hidden but legacy supported flags remain optional',
    () async {
      final h = await _Harness.create();
      await h.open();
      h.state({
        'tracks': {
          'audio': [
            {'id': 'audio:unsupported', 'supported': false},
            {'id': 'audio:supported', 'supported': true, 'language': 'en'},
            {'id': 'audio:legacy', 'language': 'ja'},
          ],
          'subtitle': [
            {'id': 'subtitle:unsupported', 'supported': false},
            {'id': 'subtitle:supported', 'supported': true, 'language': 'es'},
            {'id': 'subtitle:legacy', 'language': 'it'},
          ],
          'video': [
            {'id': 'video:unsupported', 'supported': false},
          ],
        },
        'selectedAudio': 'audio:unsupported',
        'selectedSubtitle': 'subtitle:unsupported',
      });
      expect(h.player.state.tracks.audio.map((track) => track.id), [
        'auto',
        'no',
        'audio:supported',
        'audio:legacy',
      ]);
      expect(h.player.state.tracks.subtitle.map((track) => track.id), [
        'auto',
        'no',
        'subtitle:supported',
        'subtitle:legacy',
      ]);
      expect(
        h.player.state.tracks.video.map((track) => track.id),
        isNot(contains('video:unsupported')),
      );
      expect(h.player.state.track.audio.id, 'auto');
      expect(h.player.state.track.subtitle.id, 'no');
    },
  );

  test('Android file descriptors and absolute paths use file URIs', () async {
    final h = await _Harness.create();
    final descriptor = Media('fd://17');
    await h.player.open(descriptor);
    expect(h.arguments('open')['uri'], 'file:///proc/self/fd/17');
    expect(h.player.state.playlist.medias.single, same(descriptor));

    final file = Media('/storage/emulated/0/My Videos/episode #1.mkv');
    await h.player.open(file);
    final uri = Uri.parse(h.arguments('open')['uri'] as String);
    expect(uri.scheme, 'file');
    expect(
      uri.toFilePath(windows: false),
      '/storage/emulated/0/My Videos/episode #1.mkv',
    );
    expect(uri.fragment, isEmpty);
  });

  test(
    'declared MIME type reaches Media3 without forwarding other extras',
    () async {
      final h = await _Harness.create();
      await h.player.open(
        Media(
          'https://media.example/stream?id=1',
          extras: {
            'mimeType': 'application/x-mpegURL',
            'privateNote': 'fixture',
          },
        ),
      );
      expect(h.arguments('open')['mimeType'], 'application/x-mpegURL');
      expect(h.arguments('open'), isNot(contains('privateNote')));
      await h.player.open(
        Media('https://media.example/other', extras: {'mimeType': 42}),
      );
      expect(h.arguments('open'), isNot(contains('mimeType')));
    },
  );

  test(
    'creates without MPV initialization and sends one owned media open',
    () async {
      final h = await _Harness.create();
      final media = Media(
        'https://media.example/episode.mkv',
        httpHeaders: {
          'Authorization': 'Bearer fixture',
          'Referer': 'https://media.example/',
        },
        start: const Duration(seconds: 17),
        end: const Duration(minutes: 24),
      );
      await h.player.open(media, play: false);

      expect(h.calls.map((call) => call.method), ['create', 'open']);
      expect(h.calls.last.arguments, {
        'id': 42,
        'openId': 1,
        'uri': media.uri,
        'headers': media.httpHeaders,
        'startMs': 17000,
        'endMs': 1440000,
        'play': false,
      });
      expect(await h.player.handle, 42);
      expect(h.player.state.playlist.medias.single, same(media));
      expect(h.player.state.position, const Duration(seconds: 17));
      expect(h.player.state.buffering, isTrue);
      expect(h.player.state.playing, isFalse);
    },
  );

  test(
    'accepts one-item playlists but rejects ambiguous episode playlists',
    () async {
      final h = await _Harness.create();
      await h.player.open(Playlist([Media('https://media.example/one.mp4')]));
      expect(h.calls.last.method, 'open');
      final count = h.calls.length;
      await expectLater(h.player.open(Playlist([])), throwsArgumentError);
      await expectLater(
        h.player.open(
          Playlist([
            Media('https://media.example/one.mp4'),
            Media('https://media.example/two.mp4'),
          ]),
        ),
        throwsArgumentError,
      );
      expect(h.calls, hasLength(count));
    },
  );

  test(
    'ready state forwards position, audio, captions, rate and completion',
    () async {
      final h = await _Harness.create();
      await h.open();
      final positions = <Duration>[];
      final subscription = h.player.stream.position.listen(positions.add);
      addTearDown(subscription.cancel);
      h.state({
        'positionMs': 15000,
        'durationMs': 1440000,
        'bufferMs': 10000,
        'playing': true,
        'buffering': false,
        'renderedFirstFrame': true,
        'width': 1920,
        'height': 1080,
        'sourceFps': 23.976,
        'rate': 1.25,
        'volume': 0.6,
        'metrics': {'codec': 'h264', 'audioCodec': 'aac'},
        'tracks': {
          'audio': [
            {
              'id': 'audio:0:0',
              'title': 'English',
              'language': 'en',
              'channels': 2,
              'sampleRate': 48000,
              'isDefault': true,
            },
            {'id': 'audio:0:1', 'title': 'Japanese', 'language': 'ja'},
          ],
          'subtitle': [
            {'id': 'subtitle:1:0', 'title': 'Spanish', 'language': 'es'},
          ],
        },
        'selectedAudio': 'audio:0:0',
        'selectedSubtitle': 'subtitle:1:0',
      });
      await Future<void>.delayed(Duration.zero);
      final state = h.player.state;
      expect(positions, contains(const Duration(seconds: 15)));
      expect(state.duration, const Duration(minutes: 24));
      expect(state.buffer, const Duration(seconds: 25));
      expect(state.playing, isTrue);
      expect(state.buffering, isFalse);
      expect(state.rate, 1.25);
      expect(state.volume, 60);
      expect(state.width, 1920);
      expect(state.videoParams.h, 1080);
      expect(state.track.audio.language, 'en');
      expect(state.track.subtitle.language, 'es');
      expect(state.audioParams.sampleRate, 48000);
      expect(state.audioParams.channelCount, 2);
      expect(state.tracks.audio.map((track) => track.id), [
        'auto',
        'no',
        'audio:0:0',
        'audio:0:1',
      ]);
      h.state({'completed': true, 'playing': false});
      expect(h.player.state.completed, isTrue);
    },
  );

  test(
    'decoder replacement resets readiness and ignores old native generations',
    () async {
      final h = await _Harness.create();
      await h.open();
      h.state({
        'generation': 1,
        'width': 1920,
        'height': 1080,
        'renderedFirstFrame': true,
        'positionMs': 2000,
        'metrics': {'renderedFrames': 50},
      });
      expect(h.player.state.width, 1920);
      h.state({
        'generation': 2,
        'width': 1920,
        'height': 1080,
        'renderedFirstFrame': false,
        'positionMs': 2100,
      });
      expect(h.player.state.width, isNull);
      expect(h.player.state.height, isNull);
      expect(h.player.state.videoParams.w, isNull);
      expect(
        await h.player.readProperty('tetotv-rendered-frame-count'),
        isNull,
      );
      h.state({
        'generation': 1,
        'width': 1920,
        'height': 1080,
        'renderedFirstFrame': true,
        'positionMs': 9000,
      });
      expect(h.player.state.width, isNull);
      expect(h.player.state.position.inMilliseconds, 2100);
      h.state({
        'generation': 2,
        'width': 1280,
        'height': 720,
        'renderedFirstFrame': true,
        'positionMs': 2200,
      });
      expect(h.player.state.width, 1280);
      expect(h.player.state.playlist.medias, hasLength(1));
    },
  );

  test(
    'does not report video readiness before the native first frame',
    () async {
      final h = await _Harness.create();
      await h.open();
      h.state({'width': 1920, 'height': 1080, 'renderedFirstFrame': false});
      expect(h.player.state.width, isNull);
      expect(h.player.state.height, isNull);
      expect(h.player.state.videoParams.w, isNull);
      h.state({'width': 1920, 'height': 1080, 'renderedFirstFrame': true});
      expect(h.player.state.width, 1920);
      expect(h.player.state.height, 1080);
      await h.open();
      h.state({
        'width': 1920,
        'height': 1080,
        'renderedFirstFrame': false,
      }, openId: 2);
      expect(h.player.state.width, isNull);
    },
  );

  test(
    'ignores foreign player and stale episode state and error events',
    () async {
      final h = await _Harness.create();
      await h.open();
      final errors = <String>[];
      final subscription = h.player.stream.error.listen(errors.add);
      addTearDown(subscription.cancel);
      h.state({'positionMs': 2000});
      h.state({'positionMs': 8000}, id: 99);
      h.state({'positionMs': 9000}, openId: 0);
      expect(h.player.state.position.inMilliseconds, 2000);
      await h.open();
      h.state({'positionMs': 10000}, openId: 1);
      h.events.add({'type': 'error', 'id': 42, 'openId': 1, 'code': 'STALE'});
      h.state({'positionMs': 3000}, openId: 2);
      await Future<void>.delayed(Duration.zero);
      expect(h.player.state.position.inMilliseconds, 3000);
      expect(errors, isEmpty);
    },
  );

  test(
    'commands preserve selected track IDs, seek, speed and volume units',
    () async {
      final h = await _Harness.create();
      await h.open();
      await h.player.setAudioTrack(AudioTrack('audio:0:2', 'Italian', 'it'));
      await h.player.setSubtitleTrack(SubtitleTrack.no());
      await h.player.seek(const Duration(seconds: -5));
      await h.player.setRate(1.5);
      await h.player.setVolume(160);
      await h.player.setOptions({'captionSize': 26, 'fit': 'contain'});
      await h.player.setDecoderMode('hardware_adaptive');
      expect(h.arguments('setAudioTrack')['trackId'], 'audio:0:2');
      expect(h.arguments('setSubtitleTrack')['trackId'], 'no');
      expect(h.arguments('seek')['positionMs'], 0);
      expect(h.arguments('setRate')['rate'], 1.5);
      expect(h.arguments('setVolume')['volume'], 1);
      expect(h.arguments('setOptions')['options'], {
        'captionSize': 26,
        'fit': 'contain',
      });
      expect(h.arguments('setDecoderMode')['mode'], 'hardware_adaptive');
      for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
        await expectLater(h.player.setRate(invalid), throwsArgumentError);
      }
      await expectLater(h.player.setVolume(double.nan), throwsArgumentError);
    },
  );

  test(
    'multiple external subtitles retain selection intent and metadata',
    () async {
      final h = await _Harness.create();
      await h.open();
      await h.player.setSubtitleTrack(
        SubtitleTrack.uri(
          'https://captions.example/en.vtt',
          title: 'English',
          language: 'en',
        ),
      );
      await h.player.addSubtitleTrack(
        SubtitleTrack.uri(
          'https://captions.example/es.vtt',
          title: 'Spanish',
          language: 'es',
        ),
        select: false,
      );
      const data = 'WEBVTT\n\n00:00.000 --> 00:01.000\nHello';
      await h.player.addSubtitleTrack(
        SubtitleTrack.data(data, title: 'Inline', language: 'it'),
      );
      final additions = h.calls
          .where((call) => call.method == 'addSubtitleTrack')
          .map((call) => call.arguments as Map)
          .toList();
      expect(additions, hasLength(3));
      expect(additions[0], containsPair('select', true));
      expect(additions[1], containsPair('select', false));
      expect(additions[1], containsPair('language', 'es'));
      expect(additions[2], containsPair('data', data));
      expect(additions[2], isNot(contains('uri')));
      await h.player.setSubtitleTrack(
        SubtitleTrack('external:1', 'Spanish', 'es'),
      );
      expect(h.arguments('setSubtitleTrack')['trackId'], 'external:1');
    },
  );

  test('inline subtitle limit is measured in UTF-8 bytes', () async {
    final h = await _Harness.create();
    await h.open();
    for (final tooLarge in [
      List.filled(2 * 1024 * 1024 + 1, 'a').join(),
      List.filled(1024 * 1024 + 1, 'é').join(),
    ]) {
      // Both fit the retired 4 MiB limit but exceed Android's 2 MiB cap.
      await expectLater(
        h.player.addSubtitleTrack(SubtitleTrack.data(tooLarge)),
        throwsArgumentError,
      );
    }
    expect(h.calls.where((call) => call.method == 'addSubtitleTrack'), isEmpty);
  });

  test(
    'chapter queries and track lists are bounded; unknown properties stay absent',
    () async {
      final h = await _Harness.create();
      await h.open();
      h.state({
        'chapters': List.generate(
          300,
          (index) => {'title': 'Chapter $index', 'time': index * 90},
        ),
        'tracks': {
          'audio': List.generate(
            300,
            (index) => {'id': 'audio:$index', 'language': 'en'},
          ),
          'subtitle': List.generate(
            300,
            (index) => {'id': 'subtitle:$index', 'language': 'en'},
          ),
        },
      });
      expect(await h.player.readProperty('chapter-list/count'), '256');
      expect(await h.player.readProperty('chapter-list/1/title'), 'Chapter 1');
      expect(await h.player.readProperty('chapter-list/1/time'), '90');
      expect(await h.player.readProperty('chapter-list/256/title'), isNull);
      expect(await h.player.readProperty('stream-path'), isNull);
      expect(await h.player.readProperty('metadata'), isNull);
      expect(await h.player.readProperty('decoder-frame-drop-count'), isNull);
      expect(h.player.state.tracks.audio, hasLength(258));
      expect(h.player.state.tracks.subtitle, hasLength(258));
    },
  );

  test(
    'performance metrics never export unknown strings, secrets or invented zeros',
    () async {
      final h = await _Harness.create();
      await h.open();
      h.state({
        'metrics': {
          'codec': 'h264',
          'activeHwdec': 'mediacodec',
          'decoderName': 'https://private.example/secret',
          'audioCodec': 'Private.Movie.aac',
          'renderedFrames': 120,
          'droppedFrames': double.nan,
          'url': 'https://private.example/secret',
        },
      });
      final raw = <String, String?>{};
      for (final property in media3PlaybackPerformanceProperties) {
        raw[property] = await h.player.readProperty(property);
      }
      final metrics = playbackPerformanceMetricsFromProperties(
        raw,
        engine: 'media3',
      );
      expect(metrics['codec'], 'h264');
      expect(metrics['renderedFrames'], 120);
      expect(metrics, isNot(contains('decoderName')));
      expect(metrics, isNot(contains('audioCodec')));
      expect(metrics, isNot(contains('droppedFrames')));
      expect(metrics, isNot(contains('displayFps')));
      expect(jsonEncode(metrics), isNot(contains('private')));
      expect(jsonEncode(metrics), isNot(contains('Private')));
    },
  );

  test(
    'native errors expose only safe codes, not URLs or native messages',
    () async {
      final h = await _Harness.create();
      await h.open();
      final errors = <String>[];
      final subscription = h.player.stream.error.listen(errors.add);
      addTearDown(subscription.cancel);
      h.events.add({
        'type': 'error',
        'id': 42,
        'openId': 1,
        'code': 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
        'message': 'https://private.example/?token=secret',
      });
      h.events.add({
        'type': 'error',
        'id': 42,
        'openId': 1,
        'code': 'https://private.example/secret',
      });
      h.events.addError(StateError('https://private.example/secret'));
      h.events.add({
        'type': 'error',
        'id': 42,
        'openId': 1,
        'error': 'ERROR_CODE_DECODING_FAILED',
      });
      h.events.add({
        'type': 'error',
        'id': 42,
        'openId': 1,
        'error': 'https://private.example/secret',
      });
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(5));
      expect(errors.first, contains('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED'));
      expect(errors[1], 'Media3 could not play this stream.');
      expect(errors[2], 'Media3 connection interrupted.');
      expect(errors[3], contains('ERROR_CODE_DECODING_FAILED'));
      expect(errors.last, 'Media3 could not play this stream.');
      expect(errors.join(), isNot(contains('private')));
      expect(h.player.state.playing, isFalse);
      expect(h.player.state.buffering, isFalse);
    },
  );

  test('a failed native command does not poison the command queue', () async {
    final h = await _Harness.create(
      onCall: (call) async {
        if (call.method == 'pause') {
          throw PlatformException(code: 'fixture_failure');
        }
        return null;
      },
    );
    await h.open();
    await expectLater(h.player.pause(), throwsA(isA<PlatformException>()));
    await h.player.play();
    expect(h.calls.last.method, 'play');
  });

  test(
    'commands queued for an old episode are not sent after a new open',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final h = await _Harness.create(
        onCall: (call) async {
          if (call.method == 'seek') {
            entered.complete();
            await gate.future;
          }
          return null;
        },
      );
      await h.open();
      final seeking = h.player.seek(const Duration(seconds: 10));
      await entered.future;
      final pause = h.player.pause();
      final opening = h.open();
      gate.complete();
      await Future.wait([seeking, pause, opening]);
      expect(h.calls.where((call) => call.method == 'pause'), isEmpty);
      expect(h.calls.last.method, 'open');
      expect(h.calls.last.arguments, containsPair('openId', 2));
    },
  );

  test(
    'dispose is idempotent and ignores late events and new commands',
    () async {
      final h = await _Harness.create();
      await h.open();
      h.state({'positionMs': 1000});
      await Future.wait([h.player.dispose(), h.player.dispose()]);
      expect(h.calls.where((call) => call.method == 'dispose'), hasLength(1));
      final state = h.player.state;
      h.state({'positionMs': 9000});
      expect(h.player.state, same(state));
      expect(await h.player.readProperty('container-fps'), isNull);
      await expectLater(h.player.play(), throwsStateError);
      await expectLater(h.open(), throwsStateError);
      expect(h.player.state, same(state));
      expect(h.calls.where((call) => call.method == 'open'), hasLength(1));
    },
  );

  test(
    'a stale queued stop cannot erase the newly opened episode state',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final h = await _Harness.create(
        onCall: (call) async {
          if (call.method == 'seek') {
            entered.complete();
            await gate.future;
          }
          return null;
        },
      );
      await h.open();
      final seeking = h.player.seek(const Duration(seconds: 10));
      await entered.future;
      final stopping = h.player.stop();
      final next = Media('https://media.example/next-episode.mp4');
      final opening = h.player.open(next);
      gate.complete();
      await Future.wait([seeking, stopping, opening]);
      expect(h.calls.where((call) => call.method == 'stop'), isEmpty);
      expect(h.player.state.playlist.medias, [next]);
      expect(h.player.state.buffering, isTrue);
    },
  );

  test(
    'dispose during creation releases the native player once creation completes',
    () async {
      final gate = Completer<Map<String, Object?>>();
      final h = _Harness(
        onCall: (call) async {
          if (call.method == 'create') return gate.future;
          return null;
        },
      );
      final disposing = h.player.dispose();
      gate.complete({'id': 42});
      await disposing;
      expect(h.calls.map((call) => call.method), ['create', 'dispose']);
    },
  );
}

class _Harness {
  _Harness({Future<Object?> Function(MethodCall)? onCall}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final result = await onCall?.call(call);
          return call.method == 'create' ? result ?? {'id': 42} : result;
        });
    player = Media3PlatformPlayer(channel: channel, events: events.stream);
    addTearDown(() async {
      await player.dispose();
      await events.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }

  static Future<_Harness> create({
    Future<Object?> Function(MethodCall)? onCall,
  }) async {
    final harness = _Harness(onCall: onCall);
    await harness.player.ready;
    return harness;
  }

  static const channel = MethodChannel('dev.tetotv/media3-test');
  final events = StreamController<dynamic>.broadcast(sync: true);
  final calls = <MethodCall>[];
  late final Media3PlatformPlayer player;

  Future<void> open() =>
      player.open(Media('https://media.example/episode.mp4'));

  void state(Map<String, Object?> values, {int id = 42, int openId = 1}) =>
      events.add({'type': 'state', 'id': id, 'openId': openId, ...values});

  Map arguments(String method) =>
      calls.lastWhere((call) => call.method == method).arguments as Map;
}
