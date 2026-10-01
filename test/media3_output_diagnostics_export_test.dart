import 'dart:convert';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/diagnostics/playback_performance_diagnostics.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'full report retains effective Media3 output without generic exemptions',
    () {
      final now = DateTime.utc(2026, 9, 30, 23);
      final accumulator = PlaybackPerformanceAccumulator(
        sessionId: 'pbs-abcdefghijklmnopqrstuvwx',
        attempt: 1,
        startedAt: now,
        engine: 'media3',
        sourceKind: 'torrent',
        requestedDecoder: 'hardware_adaptive',
      );
      accumulator.addSample({
        'timestamp': now.toIso8601String(),
        'elapsedMs': 0,
        'surfaceType': 'texture',
        'codecQueueingMode': 'synchronous',
        'codecQueueingCompatibility': true,
        'androidSdk': 30,
        'decoderName': 'OMX.MTK.VIDEO.DECODER.HEVC',
        'audioUnderruns': 3,
        'audioSinkErrors': 1,
        'videoCodecErrors': 2,
        'url': 'https://private.example/movie?token=private-secret',
      });
      final performance = accumulator.snapshot(updatedAt: now);
      performance['rawDecoderDetails'] = 'private-title';
      final report = buildRedactedDiagnosticsText(
        version: const AppVersionInfo(name: '2.0.77', code: 410054),
        profile: const TvDeviceProfile(
          manufacturer: 'Amazon',
          model: 'AFTKRT',
          sdk: 30,
          abis: ['armeabi-v7a'],
          displayModes: [],
          hdrTypes: [],
          codecs: [],
          audioOutputs: [],
        ),
        isTelevision: true,
        generatedAt: now,
        diagnostics: {
          'playbackPerformance': [performance],
          'diagnosticEvents': [
            {
              'headers': 'private-secret',
              'path': 'https://private.example/movie',
            },
          ],
        },
      );
      final diagnostics = (jsonDecode(report) as Map)['diagnostics'] as Map;
      final exported =
          (diagnostics['playbackPerformance'] as List).single as Map;
      for (final row in [
        (exported['samples'] as List).single as Map,
        exported['summary'] as Map,
      ]) {
        expect(row['surfaceType'], 'texture');
        expect(row['codecQueueingMode'], 'synchronous');
        expect(row['codecQueueingCompatibility'], true);
        expect(row['androidSdk'], 30);
        expect(row['decoderName'], 'omx.mtk.video.decoder.hevc');
        expect(row['audioUnderruns'], 3);
        expect(row['audioSinkErrors'], 1);
        expect(row['videoCodecErrors'], 2);
      }
      for (final private in [
        'private-secret',
        'private.example',
        'private-title',
      ]) {
        expect(report, isNot(contains(private)));
      }
    },
  );
}
