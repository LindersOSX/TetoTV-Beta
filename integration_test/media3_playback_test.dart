import 'dart:io';

import 'package:anime_tv/features/player/application/media3_platform_player.dart';
import 'package:anime_tv/features/player/presentation/media3_video_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final useSurfaceView in [false, true]) {
    testWidgets(
      'built-in Media3 ${useSurfaceView ? "SurfaceView" : "TextureView"} renders, seeks, selects captions and reopens',
      (tester) async {
        // Deliberately do not call MediaKit.ensureInitialized(): this test must
        // render through Android Media3 without opening the MPV engine.
        final backend = Media3PlatformPlayer();
        final player = Player(platformPlayer: backend);
        final errors = <String>[];
        final subscription = player.stream.error.listen(errors.add);
        final temporary = await Directory.systemTemp.createTemp(
          'tetotv-media3-smoke-',
        );
        final asset = await rootBundle.load('assets/videos/mpv_smoke.mp4');
        final videoFile = await File(
          '${temporary.path}/sample.mp4',
        ).writeAsBytes(asset.buffer.asUint8List());
        addTearDown(() async {
          await subscription.cancel();
          await player.dispose();
          await temporary.delete(recursive: true);
        });
        var hudTapCount = 0;
        Widget playerView() => MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: Media3VideoSurface(
                    player: backend,
                    useSurfaceView: useSurfaceView,
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: TextButton(
                    onPressed: () => hudTapCount++,
                    child: const Text('TetoTV shared HUD'),
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pumpWidget(playerView());

        Future<void> waitUntil(bool Function() condition) async {
          final watch = Stopwatch()..start();
          while (!condition() && watch.elapsed < const Duration(seconds: 30)) {
            await tester.pump(const Duration(milliseconds: 200));
          }
          expect(
            condition(),
            isTrue,
            reason:
                'Media3 did not reach expected state; errors=$errors; '
                'subtitles=${player.state.tracks.subtitle.map((t) => '${t.id}:${t.language}').toList()}; '
                'selected=${player.state.track.subtitle.id}',
          );
        }

        await player.open(Media(videoFile.path));
        await waitUntil(
          () =>
              (player.state.width ?? 0) > 0 &&
              player.state.position.inMilliseconds > 500,
        );
        expect(
          await backend.readProperty('tetotv-rendered-frame-count'),
          isNotNull,
        );
        await tester.tap(find.text('TetoTV shared HUD'));
        await tester.pump();
        expect(
          hudTapCount,
          1,
          reason: 'Flutter HUD must remain above the video',
        );
        await player.pause();
        await waitUntil(() => !player.state.playing);
        await player.seek(const Duration(seconds: 1));
        await waitUntil(
          () => (player.state.position.inMilliseconds - 1000).abs() < 300,
        );
        await player.setRate(1.25);
        await waitUntil(() => player.state.rate == 1.25);
        await backend.setOptions({
          'subtitleSize': 28,
          'subtitlePosition': 88,
          'fit': 'contain',
        });
        await player.setSubtitleTrack(
          SubtitleTrack.data(
            'WEBVTT\n\n00:00.000 --> 00:30.000\nMedia3 caption smoke test\n',
            title: 'English test',
            language: 'en',
          ),
        );
        await waitUntil(
          () => player.state.tracks.subtitle.any((t) => t.language == 'en'),
        );
        await player.setSubtitleTrack(SubtitleTrack.no());
        await waitUntil(() => player.state.track.subtitle.id == 'no');
        await player.play();
        await waitUntil(() => player.state.playing);
        final english = await File(
          '${temporary.path}/english.vtt',
        ).writeAsString('WEBVTT\n\n00:00.000 --> 00:30.000\nEnglish sidecar\n');
        final spanish = await File(
          '${temporary.path}/spanish.vtt',
        ).writeAsString('WEBVTT\n\n00:00.000 --> 00:30.000\nSpanish sidecar\n');
        await player.open(
          Media(
            videoFile.path,
            extras: {
              'mimeType': 'video/mp4',
              'subtitles': [
                {
                  'uri': english.uri.toString(),
                  'title': 'English',
                  'language': 'en',
                  'mimeType': 'text/vtt',
                },
                {
                  'uri': spanish.uri.toString(),
                  'title': 'Spanish',
                  'language': 'es',
                  'mimeType': 'text/vtt',
                },
              ],
            },
          ),
          play: false,
        );
        await waitUntil(
          () => (player.state.width ?? 0) > 0 && !player.state.buffering,
        );
        expect(player.state.playing, isFalse);
        await waitUntil(
          () =>
              player.state.tracks.subtitle
                  .where((t) => t.id.startsWith('sidecar:'))
                  .length ==
              2,
        );
        await player.setSubtitleTrack(
          SubtitleTrack.uri(
            spanish.uri.toString(),
            title: 'Spanish',
            language: 'es',
          ),
        );
        await waitUntil(() => player.state.track.subtitle.language == 'es');
        expect(
          player.state.tracks.subtitle
              .where((t) => t.id.startsWith('sidecar:'))
              .length,
          2,
        );
        final selectedAudio = player.state.tracks.audio.firstWhere(
          (track) => track.id != 'auto' && track.id != 'no',
        );
        await player.setAudioTrack(selectedAudio);
        await waitUntil(() => player.state.track.audio.id == selectedAudio.id);
        await backend.setDecoderMode('software');
        await waitUntil(
          () =>
              (player.state.width ?? 0) > 0 &&
              !player.state.buffering &&
              player.state.track.audio.id == selectedAudio.id &&
              player.state.track.subtitle.language == 'es',
        );
        expect(player.state.playing, isFalse);
        expect(player.state.rate, 1.25);
        await backend.setDecoderMode('hardware');
        await waitUntil(
          () =>
              (player.state.width ?? 0) > 0 &&
              !player.state.buffering &&
              player.state.track.audio.id == selectedAudio.id &&
              player.state.track.subtitle.language == 'es',
        );
        expect(player.state.playing, isFalse);
        final screenshot = await backend.screenshot(format: 'image/png');
        expect(screenshot, isNotNull);
        expect(screenshot!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        for (final fit in ['cover', 'fill', 'contain']) {
          await backend.setOptions({'fit': fit});
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull);
        }
        // Recreate only the native view (not the player) to exercise lifecycle
        // recovery without losing selected tracks or the overlaid Flutter HUD.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(playerView());
        await tester.pump(const Duration(milliseconds: 500));
        expect(player.state.track.subtitle.language, 'es');
        await tester.tap(find.text('TetoTV shared HUD'));
        expect(hudTapCount, 2);
        await player.play();
        await waitUntil(() => player.state.playing);
        await player.open(
          Media(
            videoFile.path,
            start: const Duration(seconds: 1),
            end: const Duration(seconds: 2),
          ),
        );
        await waitUntil(() => player.state.completed);
        expect(player.state.duration, const Duration(seconds: 2));
        expect(
          player.state.position.inMilliseconds,
          inInclusiveRange(1900, 2100),
        );
        expect(errors, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
