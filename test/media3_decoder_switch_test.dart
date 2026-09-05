import 'dart:async';
import 'dart:io';

import 'package:anime_tv/features/player/application/media3_platform_player.dart';
import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unsupported decoder keeps current playback and reports rejection',
    () async {
      final h = await _Harness.create(
        onDecoderChange: (_) async {
          throw PlatformException(code: 'media3_unsupported');
        },
      );
      h.publishPlayingState();
      final before = h.player.state;

      expect(
        await requestMedia3DecoderChange(
          h.player,
          PlaybackDecoderMode.software,
        ),
        isFalse,
      );

      expect(h.player.state.playing, before.playing);
      expect(h.player.state.position, before.position);
      expect(h.player.state.track.subtitle.id, before.track.subtitle.id);
      expect(h.player.state.track.audio.id, before.track.audio.id);
      expect(h.player.state.rate, before.rate);
      expect(h.errors, isEmpty);
      expect(h.calls.map((call) => call.method), [
        'create',
        'open',
        'setDecoderMode',
      ]);
    },
  );

  test(
    'successful switch sends one native mutation without a second open',
    () async {
      final h = await _Harness.create();

      expect(
        await requestMedia3DecoderChange(
          h.player,
          PlaybackDecoderMode.software,
        ),
        isTrue,
      );
      expect(h.calls.last.arguments, {
        'id': 42,
        'openId': 1,
        'mode': 'software',
      });
      expect(h.calls.where((call) => call.method == 'open'), hasLength(1));
      expect(h.calls.where((call) => call.method == 'seek'), isEmpty);
      expect(h.calls.where((call) => call.method == 'play'), isEmpty);
      expect(
        h.calls.where((call) => call.method == 'setSubtitleTrack'),
        isEmpty,
      );
    },
  );

  test('hardware selection maps to native hardware mode', () async {
    final h = await _Harness.create();

    expect(
      await requestMedia3DecoderChange(
        h.player,
        PlaybackDecoderMode.hardwareSafe,
      ),
      isTrue,
    );
    expect((h.calls.last.arguments as Map)['mode'], 'hardware');
  });

  test(
    'command failure is not disguised as an unsupported preflight',
    () async {
      final h = await _Harness.create(
        onDecoderChange: (_) async {
          throw PlatformException(code: 'media3_command_failed');
        },
      );

      await expectLater(
        requestMedia3DecoderChange(h.player, PlaybackDecoderMode.software),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'media3_command_failed',
          ),
        ),
      );
    },
  );

  test('choice does not resolve before native validation finishes', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final h = await _Harness.create(
      onDecoderChange: (_) async {
        entered.complete();
        await gate.future;
        throw PlatformException(code: 'media3_unsupported');
      },
    );
    var resolved = false;
    final request =
        requestMedia3DecoderChange(h.player, PlaybackDecoderMode.software).then(
          (accepted) {
            resolved = true;
            return accepted;
          },
        );
    await entered.future;

    expect(resolved, isFalse);
    gate.complete();
    expect(await request, isFalse);
  });

  final source = File(
    'lib/features/player/presentation/tv_player_screen.dart',
  ).readAsStringSync();
  String method(String start, String end) {
    final first = source.indexOf(start);
    expect(first, greaterThanOrEqualTo(0));
    final last = source.indexOf(end, first + start.length);
    expect(last, greaterThan(first));
    return source.substring(first, last);
  }

  test(
    'shared screen dispatches Media3 before MPV state and diagnostic mutations',
    () {
      final switchDecoder = method(
        'Future<void> _switchDecoder(',
        'Future<void> _switchMedia3Decoder(',
      );
      final dispatch = switchDecoder.indexOf('await _switchMedia3Decoder(');
      expect(dispatch, greaterThanOrEqualTo(0));
      expect(dispatch, lessThan(switchDecoder.indexOf('_decoderMode = mode')));
      expect(
        dispatch,
        lessThan(switchDecoder.indexOf('_playbackPerformance.endAttempt()')),
      );
      expect(
        dispatch,
        lessThan(switchDecoder.indexOf('_playbackPersistenceReady = false')),
      );
      expect(switchDecoder, contains("await platform.setProperty('hwdec'"));
      expect(switchDecoder, contains('await _openCurrentMedia('));
    },
  );

  test(
    'Media3 rejection returns before selection and performance attempt commit',
    () {
      final transaction = method(
        'Future<void> _switchMedia3Decoder(',
        'Future<void> _retryPlayback()',
      );
      final rejected = transaction.indexOf('if (!accepted)');
      final commit = transaction.indexOf('_decoderMode = mode');
      final rejection = transaction.substring(rejected, commit);
      expect(rejection, contains('_showTrackMessage('));
      expect(rejection, contains('return;'));
      expect(rejection, isNot(contains('_playbackError =')));
      expect(rejection, isNot(contains('_recordDiagnosticOutcome(')));
      expect(
        transaction.indexOf('await requestMedia3DecoderChange'),
        lessThan(rejected),
      );
      expect(
        transaction.indexOf('_playbackPerformance.beginAttempt('),
        greaterThan(commit),
      );
      expect(transaction, isNot(contains('_playbackPerformance.endAttempt()')));
      expect(transaction, isNot(contains('_playbackPersistenceReady =')));
      expect(transaction, isNot(contains('_saveDecoderPreference(')));
    },
  );

  test(
    'Media3 success preserves tracks and timeline without reopening or retoggling',
    () {
      final transaction = method(
        'Future<void> _switchMedia3Decoder(',
        'Future<void> _retryPlayback()',
      );
      for (final redundantMutation in [
        '_openCurrentMedia(',
        '_player.open(',
        '_restoreResumePosition(',
        '_applySubtitle(',
        '_applyPlayerTuning(',
        '_preferredAudioSelected = false',
        '_preferredSubtitleSelected = false',
        '_player.play(',
      ]) {
        expect(
          transaction,
          isNot(contains(redundantMutation)),
          reason: redundantMutation,
        );
      }
      expect(transaction, contains('_media3DecoderSwitchError'));
      expect(
        transaction,
        contains('throw StateError(synchronousPlaybackError)'),
      );
      expect(transaction, contains('PlaybackDiagnosticOutcome.failed'));
    },
  );
}

class _Harness {
  _Harness({Future<void> Function(MethodCall)? onDecoderChange}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'create') return {'id': 42};
          if (call.method == 'setDecoderMode') {
            await onDecoderChange?.call(call);
          }
          return null;
        });
    player = Media3PlatformPlayer(channel: channel, events: events.stream);
    final errorSubscription = player.stream.error.listen(errors.add);
    addTearDown(() async {
      await errorSubscription.cancel();
      await player.dispose();
      await events.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }

  static Future<_Harness> create({
    Future<void> Function(MethodCall)? onDecoderChange,
  }) async {
    final h = _Harness(onDecoderChange: onDecoderChange);
    await h.player.ready;
    await h.player.open(Media('https://media.example/episode.mp4'));
    return h;
  }

  static const channel = MethodChannel('dev.tetotv/media3-decoder-switch-test');
  final calls = <MethodCall>[];
  final errors = <String>[];
  final events = StreamController<dynamic>.broadcast(sync: true);
  late final Media3PlatformPlayer player;

  void publishPlayingState() => events.add({
    'type': 'state',
    'id': 42,
    'openId': 1,
    'playing': true,
    'positionMs': 15000,
    'durationMs': 120000,
    'rate': 1.25,
    'width': 1280,
    'height': 720,
    'renderedFirstFrame': true,
    'selectedAudio': 'audio/g1/t0',
    'selectedSubtitle': 'sidecar:1',
    'tracks': {
      'audio': [
        {'id': 'audio/g1/t0', 'language': 'en'},
      ],
      'subtitle': [
        {'id': 'sidecar:1', 'language': 'es'},
      ],
    },
  });
}
