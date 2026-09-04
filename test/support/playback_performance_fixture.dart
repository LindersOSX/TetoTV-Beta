import 'package:anime_tv/core/diagnostics/playback_performance_diagnostics.dart';

/// A full technical sample payload, including startup and buffering metadata.
/// Accumulation gives fixtures the same summary invariants as real playback.
Map<String, Object?> playbackPerformanceFixture({
  required DateTime updatedAt,
  int attempt = 1,
  String sessionId = 'pbs-abcdefghijklmnopqrstuvwx',
  int sampleCount = 12,
}) {
  final startedAt = updatedAt.subtract(Duration(seconds: sampleCount * 5));
  final accumulator = PlaybackPerformanceAccumulator(
    sessionId: sessionId,
    attempt: attempt,
    startedAt: startedAt,
    sourceKind: 'web',
    requestedDecoder: 'hardware_adaptive',
  );
  for (var index = 0; index < sampleCount; index++) {
    accumulator.addSample({
      'timestamp': startedAt
          .add(Duration(seconds: (index + 1) * 5))
          .toIso8601String(),
      'elapsedMs': (index + 1) * 5000,
      'positionMs': index * 5000,
      'durationMs': 1440000,
      'playing': true,
      'buffering': false,
      'seeking': false,
      'hudVisible': index.isEven,
      'inForeground': true,
      'playbackSpeed': 1.0,
      'openState': 'opened',
      'probeStatus': 'supported',
      'codec': 'h264',
      'audioCodec': 'aac',
      'activeHwdec': 'mediacodec-copy',
      'decoderName': 'h264_mediacodec',
      'pixelFormat': 'yuv420p',
      'width': 1920,
      'height': 1080,
      'bitDepth': 8,
      'sourceFps': 23.976023976023978,
      'displayFps': 59.94005994005994,
      'estimatedDisplayFps': 59.99843534322212,
      'androidDisplayFps': 60.0,
      'videoBitrate': 8000000.625,
      'audioBitrate': 192000.125,
      'droppedFrames': index * 2,
      'decoderDroppedFrames': index,
      'mistimedFrames': index * 3,
      'delayedFrames': index,
      'avSyncMs': 25.325323454545,
      'bufferSeconds': 60.888283474747,
      'cacheBytes': 63001234,
      'inputBytesPerSecond': 11351325.232345324,
      'cacheUnderrun': false,
      'pausedForCache': false,
      'videoParametersAvailable': true,
      'videoParametersAfterMs': 9532,
      'firstPositionAdvanceAfterMs': 11215,
      'bufferingTotalMs': 562,
      'rebufferTotalMs': 250,
      'bufferingEvents': 2,
      'rebufferEvents': 1,
      'userSeekCount': 0,
    });
  }
  return accumulator.snapshot(updatedAt: updatedAt);
}
