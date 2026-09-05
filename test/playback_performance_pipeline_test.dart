import 'dart:convert';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/diagnostics/playback_performance_monitor.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  for (final engine in ['mpv', 'media3']) {
    test(
      '$engine scalar probes survive real SQLite storage and the explicit report',
      () async {
        final database = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
        );
        addTearDown(database.close);
        await createPlaybackPerformanceTable(database);
        final start = DateTime.utc(2026, 9, 4, 18);
        var tick = Duration.zero;
        var droppedFrames = 0;
        final requested = <String>[];
        final monitor = PlaybackPerformanceMonitor(
          sessionId: 'pbs-abcdefghijklmnopqrstuvwx',
          engine: engine,
          clock: () => start.add(tick),
          monotonicClock: () => tick,
          readProperty: (property) async {
            requested.add(property);
            return switch (property) {
              'hwdec-current' => 'mediacodec',
              'current-tracks/video/codec' => 'h264',
              // Even malformed native strings cannot cross the allowlist.
              'current-tracks/video/decoder' => 'https://private.example/key',
              'current-tracks/audio/codec' => 'aac',
              'frame-drop-count' => '$droppedFrames',
              'tetotv-rendered-frame-count' => '${tick.inSeconds * 24}',
              'video-params/w' => '1920',
              'video-params/h' => '1080',
              'container-fps' => '23.976',
              'avsync' => '0.04',
              'demuxer-cache-duration' => '12.5',
              _ => null,
            };
          },
          context: () => PlaybackPerformanceContext(
            position: tick,
            duration: const Duration(minutes: 24),
            playing: true,
            buffering: false,
            seeking: false,
            hudVisible: false,
            inForeground: true,
            androidDisplayFps: 60,
          ),
          persist: (snapshot) => database.transaction(
            (transaction) => persistPlaybackPerformanceSnapshot(
              transaction,
              snapshot,
              now: start.add(tick),
            ),
          ),
        );
        addTearDown(monitor.dispose);
        monitor.beginAttempt(
          attempt: 1,
          sourceKind: 'torrent',
          requestedDecoder: 'hardware_direct',
        );
        monitor.opened(videoParametersAvailable: true);
        // Allow the automatic initial capture to finish without advancing time.
        await Future<void>.delayed(Duration.zero);
        await monitor.flush();
        expect(requested, contains('frame-drop-count'));

        tick = const Duration(seconds: 5);
        droppedFrames = 4;
        await monitor.capture();
        tick = const Duration(seconds: 10);
        droppedFrames = 7;
        await monitor.capture();
        monitor.endAttempt();
        await monitor.flush();

        final history = await loadPlaybackPerformanceHistory(
          database,
          now: start.add(tick),
        );
        final report = buildRedactedDiagnosticsText(
          version: const AppVersionInfo(name: 'local-test', code: 1),
          profile: const TvDeviceProfile(
            manufacturer: 'Example',
            model: 'TV',
            sdk: 34,
            abis: ['armeabi-v7a'],
            displayModes: [],
            hdrTypes: [],
            codecs: [],
            audioOutputs: [],
          ),
          isTelevision: true,
          diagnostics: history,
          generatedAt: start.add(tick),
        );
        final exported = jsonDecode(report) as Map<String, dynamic>;
        final attempts = exported['diagnostics']['playbackPerformance'] as List;
        expect(attempts, hasLength(1));
        final record = attempts.single as Map;
        final summary = record['summary'] as Map;
        expect(record['sessionId'], 'pbs-abcdefghijklmnopqrstuvwx');
        expect(record['attempt'], 1);
        expect(record['engine'], engine);
        expect(record['requestedDecoder'], 'hardware_direct');
        expect(summary['activeHwdec'], 'mediacodec');
        expect(summary['codec'], 'h264');
        expect(summary['droppedFramesDelta'], 7);
        expect(summary['droppedFramesObservedIntervals'], 2);
        expect(summary['peakAvSyncMs'], 40);
        expect(summary['firstPositionAdvanceAfterMs'], 5000);
        if (engine == 'media3') {
          expect(summary['renderedFramesDelta'], 240);
          expect(summary['renderedFramesObservedIntervals'], 2);
        } else {
          expect(summary, isNot(contains('renderedFramesDelta')));
        }
        expect(summary, isNot(contains('decoderDroppedFramesDelta')));
        expect(summary, isNot(contains('decoderName')));
        expect(report, isNot(contains('private.example')));
        expect(
          report.length,
          lessThanOrEqualTo(maximumExplicitDiagnosticsCharacters),
        );
        expect(
          requested.every(
            (engine == 'media3'
                    ? media3PlaybackPerformanceProperties
                    : playbackPerformanceProperties)
                .contains,
          ),
          isTrue,
        );
      },
    );
  }
}
