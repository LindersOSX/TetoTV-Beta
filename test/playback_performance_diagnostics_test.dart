import 'dart:convert';

import 'package:anime_tv/core/diagnostics/playback_performance_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MPV remains default and Media3 keeps its own engine identity', () {
    expect(_accumulator().snapshot()['engine'], 'mpv');
    final accumulator = _accumulator(engine: 'media3');
    accumulator.addSample({..._sample(0), 'renderedFrames': 0});
    accumulator.addSample({..._sample(5000), 'renderedFrames': 120});
    final snapshot = accumulator.snapshot();
    expect(snapshot['engine'], 'media3');
    final roundTrip = sanitizePlaybackPerformanceSnapshot(
      jsonDecode(jsonEncode(snapshot)),
    );
    expect(roundTrip, snapshot);
    expect(roundTrip['summary'], containsPair('renderedFramesDelta', 120));
    expect(
      roundTrip['summary'],
      containsPair('renderedFramesObservedIntervals', 1),
    );
    expect(jsonEncode(roundTrip), isNot(contains('displayedFps')));
    for (final engine in ['external', 'vlc', 'MEDIA3', 'https://private']) {
      expect(_accumulator(engine: engine).snapshot(), isEmpty);
    }
  });

  test('rendered counters retain absence and reset boundaries without FPS', () {
    final accumulator = _accumulator(engine: 'media3');
    accumulator.addSample({..._sample(0), 'renderedFrames': -1});
    expect(
      (accumulator.snapshot()['samples'] as List).single,
      isNot(contains('renderedFrames')),
    );
    expect(
      accumulator.snapshot()['summary'],
      isNot(contains('renderedFramesDelta')),
    );
    accumulator.addSample({..._sample(5000), 'renderedFrames': 120});
    accumulator.addSample({..._sample(10000), 'renderedFrames': 5});
    accumulator.addSample({..._sample(15000), 'renderedFrames': 105});
    final summary = accumulator.snapshot()['summary'] as Map;
    expect(summary['counterResetCount'], 1);
    expect(summary['renderedFramesDelta'], 100);
    expect(summary['renderedFramesObservedIntervals'], 1);
    expect(summary, isNot(contains('displayFps')));
    expect(summary, isNot(contains('estimatedDisplayFps')));
  });

  test('strict allowlist removes private data at every nesting level', () {
    final accumulator = _accumulator();
    accumulator.addSample({
      ..._sample(0),
      'codec': ' HEVC ',
      'audioCodec': 'aac',
      'activeHwdec': 'mediacodec-copy',
      'decoderName': 'Private.Movie.mkv',
      'pixelFormat': 'yuv420p10le',
      'title': 'Private Movie',
      'filename': r'C:\Private\movie.mkv',
      'headers': {'Authorization': 'Bearer private-secret'},
      'rawMpv': {'path': 'https://private.example/movie'},
      'availableMetrics': ['https://private.example', 'headers'],
    });
    final raw = accumulator.snapshot();
    raw['title'] = 'Private Movie';
    (raw['summary'] as Map)['token'] = 'private-secret';
    final result = sanitizePlaybackPerformanceSnapshot(raw);
    final sample = (result['samples'] as List).single as Map;
    expect(sample['codec'], 'hevc');
    expect(sample['activeHwdec'], 'mediacodec-copy');
    expect(sample['pixelFormat'], 'yuv420p10le');
    expect(sample, isNot(contains('decoderName')));
    expect(sample['availableMetrics'], containsAll(['codec', 'audioCodec']));
    final encoded = jsonEncode(result);
    for (final secret in ['Private', 'private.example', 'private-secret']) {
      expect(encoded, isNot(contains(secret)));
    }
  });

  test('unknown technical-looking strings cannot smuggle media identity', () {
    final accumulator = _accumulator();
    accumulator.addSample({
      ..._sample(0),
      'codec': 'some_private_movie',
      'audioCodec': 'private.aac',
      'activeHwdec': 'private_decoder',
      'decoderName': 'c2.private.title.decoder',
      'pixelFormat': 'private_movie',
      'probeStatus': 'error: private token',
    });
    final sample = (accumulator.snapshot()['samples'] as List).single as Map;
    for (final field in [
      'codec',
      'audioCodec',
      'activeHwdec',
      'decoderName',
      'pixelFormat',
      'probeStatus',
    ]) {
      expect(sample, isNot(contains(field)), reason: field);
    }
  });

  test('rejects malformed snapshot headers without coercing values', () {
    final baseline = _accumulator().snapshot();
    for (final invalid in <Object?>[null, [], 'private', 42]) {
      expect(sanitizePlaybackPerformanceSnapshot(invalid), isEmpty);
    }
    for (final entry in <String, Object?>{
      'sessionId': 'pbs-private',
      'attempt': 0,
      'startedAt': 'private',
      'updatedAt': '2020-01-01T00:00:00Z',
      'engine': 'https://private.example',
      'sourceKind': 'private_media_title',
      'requestedDecoder': 'hardware',
      'sampleCount': double.nan,
      'samples': {'path': 'private'},
      'schema': 'unknown',
    }.entries) {
      expect(
        sanitizePlaybackPerformanceSnapshot({
          ...baseline,
          entry.key: entry.value,
        }),
        isEmpty,
        reason: entry.key,
      );
    }
    for (final attempt in [1.5, 10001, double.infinity, '1', null]) {
      expect(
        sanitizePlaybackPerformanceSnapshot({...baseline, 'attempt': attempt}),
        isEmpty,
      );
    }
  });

  test(
    'numeric metrics reject NaN, infinity, strings, fractions and bounds',
    () {
      final accumulator = _accumulator();
      accumulator.addSample({
        ..._sample(0),
        'positionMs': -1,
        'durationMs': 604800001,
        'width': 1920.5,
        'height': 0,
        'bitDepth': 65,
        'sourceFps': double.nan,
        'displayFps': double.infinity,
        'estimatedDisplayFps': 0,
        'videoBitrate': -1,
        'audioBitrate': '128000',
        'cacheBytes': double.negativeInfinity,
        'inputBytesPerSecond': 1000000000001,
        'droppedFrames': -1,
        'decoderDroppedFrames': null,
        'mistimedFrames': 0.5,
        'delayedFrames': 1000000001,
        'avSyncMs': double.nan,
        'bufferSeconds': 604801,
        'playing': 'yes',
        'cacheUnderrun': 1,
        'playbackSpeed': 0,
      });
      final sample = (accumulator.snapshot()['samples'] as List).single as Map;
      expect(sample['availableMetrics'], isEmpty);
      expect(sample, isNot(contains('positionMs')));
      expect(sample, isNot(contains('durationMs')));
      expect(sample, isNot(contains('playing')));
      expect(sample, isNot(contains('playbackSpeed')));
      expect(() => jsonEncode(accumulator.snapshot()), returnsNormally);
    },
  );

  test('missing metrics are omitted; actual observed zeros are retained', () {
    final accumulator = _accumulator();
    accumulator.addSample({..._sample(0), 'probeStatus': 'unavailable'});
    var summary = accumulator.snapshot()['summary'] as Map;
    expect(summary, isNot(contains('droppedFramesDelta')));
    expect(summary, isNot(contains('peakAvSyncMs')));
    expect(summary, isNot(contains('minBufferSeconds')));
    accumulator.addSample({..._sample(10000), 'droppedFrames': 0});
    summary = accumulator.snapshot()['summary'] as Map;
    expect(summary, isNot(contains('droppedFramesDelta')));
    accumulator.addSample({
      ..._sample(20000),
      'droppedFrames': 0,
      'avSyncMs': 0,
      'bufferSeconds': 0,
    });
    summary = accumulator.snapshot()['summary'] as Map;
    expect(summary['droppedFramesDelta'], 0);
    expect(summary['droppedFramesObservedIntervals'], 1);
    expect(summary['peakAvSyncMs'], 0);
    expect(summary['minBufferSeconds'], 0);
  });

  test(
    'totals aggregate observed deltas and survive six-sample ring eviction',
    () {
      final accumulator = _accumulator();
      for (var index = 0; index < 10; index++) {
        accumulator.addSample({
          ..._sample(index * 1000),
          'droppedFrames': 100 + index * 2,
          'decoderDroppedFrames': 200 + index,
          'mistimedFrames': index * 3,
          'delayedFrames': index * 4,
          'avSyncMs': index == 0 ? -300 : 5,
          'bufferSeconds': index == 0 ? 0.25 : 10,
        });
      }
      final result = accumulator.snapshot();
      final summary = result['summary'] as Map;
      expect(result['sampleCount'], 10);
      expect(result['droppedSamples'], 4);
      expect(result['samples'], hasLength(6));
      expect(((result['samples'] as List).first as Map)['elapsedMs'], 4000);
      expect(summary['droppedFramesDelta'], 18);
      expect(summary['decoderDroppedFramesDelta'], 9);
      expect(summary['mistimedFramesDelta'], 27);
      expect(summary['delayedFramesDelta'], 36);
      expect(summary['droppedFramesObservedIntervals'], 9);
      expect(summary['peakAvSyncMs'], 300);
      expect(summary['minBufferSeconds'], 0.25);
    },
  );

  test(
    'counter reset breaks the entire interval and establishes a new baseline',
    () {
      final accumulator = _accumulator();
      accumulator.addSample({
        ..._sample(0),
        'droppedFrames': 100,
        'delayedFrames': 10,
      });
      accumulator.addSample({
        ..._sample(1000),
        'droppedFrames': 1,
        'delayedFrames': 10,
      });
      var summary = accumulator.snapshot()['summary'] as Map;
      expect(summary['counterResetCount'], 1);
      expect(summary, isNot(contains('droppedFramesDelta')));
      expect(summary, isNot(contains('delayedFramesDelta')));
      accumulator.addSample({
        ..._sample(2000),
        'droppedFrames': 4,
        'delayedFrames': 12,
      });
      summary = accumulator.snapshot()['summary'] as Map;
      expect(summary['droppedFramesDelta'], 3);
      expect(summary['delayedFramesDelta'], 2);
      expect(summary['droppedFramesObservedIntervals'], 1);
    },
  );

  for (final exclusion in [
    <String, Object?>{'playing': false},
    <String, Object?>{'seeking': true},
    <String, Object?>{'inForeground': false},
    <String, Object?>{'inForeground': null},
  ]) {
    test('excludes both edges of inactive observations: $exclusion', () {
      final accumulator = _accumulator();
      accumulator.addSample({..._sample(0), 'droppedFrames': 0, 'avSyncMs': 2});
      accumulator.addSample({
        ..._sample(1000),
        ...exclusion,
        'droppedFrames': 20,
        'avSyncMs': -1000,
        'bufferSeconds': 0,
      });
      accumulator.addSample({
        ..._sample(2000),
        'droppedFrames': 25,
        'avSyncMs': -4,
      });
      var summary = accumulator.snapshot()['summary'] as Map;
      expect(summary, isNot(contains('droppedFramesDelta')));
      expect(summary['excludedSampleCount'], 1);
      expect(summary['peakAvSyncMs'], 4);
      expect(summary, isNot(contains('minBufferSeconds')));
      accumulator.addSample({..._sample(3000), 'droppedFrames': 27});
      summary = accumulator.snapshot()['summary'] as Map;
      expect(summary['droppedFramesDelta'], 2);
    });
  }

  test('buffering and HUD visibility remain diagnostic observations', () {
    final accumulator = _accumulator();
    accumulator.addSample({..._sample(0), 'droppedFrames': 0});
    accumulator.addSample({
      ..._sample(1000),
      'droppedFrames': 3,
      'buffering': true,
      'hudVisible': true,
      'bufferSeconds': 0,
      'pausedForCache': true,
    });
    final result = accumulator.snapshot();
    expect((result['summary'] as Map)['droppedFramesDelta'], 3);
    expect((result['summary'] as Map)['minBufferSeconds'], 0);
    expect(((result['samples'] as List).last as Map)['pausedForCache'], true);
  });

  test(
    'gaps, invalid observations and nonmonotonic clocks break continuity',
    () {
      final accumulator = _accumulator();
      accumulator.addSample({..._sample(0), 'droppedFrames': 10});
      accumulator.addSample({..._sample(31000), 'droppedFrames': 10});
      accumulator.addSample({..._sample(30000), 'droppedFrames': 10});
      accumulator.addSample({'timestamp': 'private', 'droppedFrames': 10});
      accumulator.addSample({..._sample(32000), 'droppedFrames': 10});
      final summary = accumulator.snapshot()['summary'] as Map;
      expect(summary['gapCount'], 3);
      expect(summary, isNot(contains('droppedFramesDelta')));
      expect(summary['sampleCount'], 4);
    },
  );

  test('a missing counter cannot bridge a partial probe', () {
    final accumulator = _accumulator();
    accumulator.addSample({..._sample(0), 'droppedFrames': 10});
    accumulator.addSample({..._sample(1000), 'probeStatus': 'timeout'});
    accumulator.addSample({..._sample(2000), 'droppedFrames': 10});
    expect(
      accumulator.snapshot()['summary'] as Map,
      isNot(contains('droppedFramesDelta')),
    );
  });

  test('summary loading requires evidence for a zero counter delta', () {
    final accumulator = _accumulator();
    accumulator.addSample(_sample(0));
    final snapshot = accumulator.snapshot();
    snapshot['summary'] = {
      'droppedFramesDelta': 0,
      'droppedFramesObservedIntervals': 0,
      'peakAvSyncMs': 0,
      'minBufferSeconds': 0,
      'activeSampleCount': 0,
      'reason': 'private title',
    };
    final summary =
        sanitizePlaybackPerformanceSnapshot(snapshot)['summary'] as Map;
    expect(summary, isNot(contains('droppedFramesDelta')));
    expect(summary, isNot(contains('peakAvSyncMs')));
    expect(summary, isNot(contains('minBufferSeconds')));
    expect(summary, isNot(contains('reason')));
  });

  test(
    'snapshot mutation cannot change the accumulator or retained samples',
    () {
      final accumulator = _accumulator();
      final original = {..._sample(0), 'droppedFrames': 1};
      accumulator.addSample(original);
      original['droppedFrames'] = 100;
      final snapshot = accumulator.snapshot();
      ((snapshot['samples'] as List).first as Map)['droppedFrames'] = 200;
      ((snapshot['samples'] as List).first as Map)['availableMetrics'] = [
        'private',
      ];
      expect(
        ((accumulator.snapshot()['samples'] as List).first
            as Map)['droppedFrames'],
        1,
      );
    },
  );

  test('timestamps normalize to UTC and snapshots sanitize idempotently', () {
    final accumulator = _accumulator();
    accumulator.addSample({
      ..._sample(0),
      'timestamp': '2026-09-04T07:00:00-05:00',
      'decoderName': 'hevc_mediacodec',
      'width': 3840,
      'height': 2160,
      'bitDepth': 10,
      'sourceFps': 23.976,
    });
    final snapshot = accumulator.snapshot();
    expect(
      ((snapshot['samples'] as List).single as Map)['timestamp'],
      '2026-09-04T12:00:00.000Z',
    );
    expect(sanitizePlaybackPerformanceSnapshot(snapshot), snapshot);
  });

  test('late state and event fields are bounded technical observations', () {
    final accumulator = _accumulator();
    accumulator.addSample({
      ..._sample(1000),
      'androidDisplayFps': 59.94,
      'videoParametersAvailable': true,
      'videoParametersAfterMs': 125,
      'firstPositionAdvanceAfterMs': 750,
      'bufferingTotalMs': 250,
      'rebufferTotalMs': 100,
      'bufferingEvents': 2,
      'rebufferEvents': 1,
      'userSeekCount': 3,
      'openState': 'OPENED',
    });
    final snapshot = accumulator.snapshot();
    final sample = (snapshot['samples'] as List).single as Map;
    final summary = snapshot['summary'] as Map;
    for (final entry in <String, Object?>{
      'androidDisplayFps': 59.94,
      'videoParametersAvailable': true,
      'videoParametersAfterMs': 125,
      'firstPositionAdvanceAfterMs': 750,
      'bufferingTotalMs': 250,
      'rebufferTotalMs': 100,
      'bufferingEvents': 2,
      'rebufferEvents': 1,
      'userSeekCount': 3,
      'openState': 'opened',
    }.entries) {
      expect(sample[entry.key], entry.value, reason: entry.key);
      expect(summary[entry.key], entry.value, reason: entry.key);
      if (entry.key != 'openState') {
        expect(sample['availableMetrics'], contains(entry.key));
      }
    }

    accumulator.addSample({
      ..._sample(2000),
      'androidDisplayFps': double.infinity,
      'videoParametersAvailable': 'yes',
      'videoParametersAfterMs': -1,
      'firstPositionAdvanceAfterMs': 0.5,
      'bufferingTotalMs': 604800001,
      'rebufferTotalMs': '100',
      'bufferingEvents': double.nan,
      'rebufferEvents': -1,
      'userSeekCount': 1000000001,
      'openState': 'opened https://private.example',
    });
    final invalidSample =
        (accumulator.snapshot()['samples'] as List).last as Map;
    expect(invalidSample['availableMetrics'], isEmpty);
    expect(invalidSample, isNot(contains('openState')));
    expect(() => jsonEncode(accumulator.snapshot()), returnsNormally);
  });

  test('latest available metadata survives context-only ring eviction', () {
    final accumulator = _accumulator();
    accumulator.addSample({
      ..._sample(0),
      'codec': 'hevc',
      'activeHwdec': 'mediacodec',
      'decoderName': 'hevc_mediacodec',
      'pixelFormat': 'yuv420p10le',
      'bitDepth': 10,
      'width': 3840,
      'height': 2160,
      'sourceFps': 23.976,
      'videoParametersAvailable': true,
      'videoParametersAfterMs': 0,
      'openState': 'opened',
    });
    for (var index = 1; index <= maximumPlaybackPerformanceSamples; index++) {
      accumulator.addSample({
        ..._sample(index * 1000),
        'playing': false,
        'bufferingTotalMs': index * 100,
        'userSeekCount': index,
      });
    }
    final snapshot = accumulator.snapshot();
    final summary = snapshot['summary'] as Map;
    expect(snapshot['droppedSamples'], 1);
    for (final sample in (snapshot['samples'] as List).cast<Map>()) {
      expect(sample, isNot(contains('codec')));
    }
    expect(summary['codec'], 'hevc');
    expect(summary['activeHwdec'], 'mediacodec');
    expect(summary['decoderName'], 'hevc_mediacodec');
    expect(summary['pixelFormat'], 'yuv420p10le');
    expect(summary['bitDepth'], 10);
    expect(summary['width'], 3840);
    expect(summary['height'], 2160);
    expect(summary['sourceFps'], 23.976);
    expect(summary['videoParametersAvailable'], true);
    expect(summary['videoParametersAfterMs'], 0);
    expect(summary['openState'], 'opened');
    expect(summary['bufferingTotalMs'], 600);
    expect(summary['userSeekCount'], 6);
    expect(summary, isNot(contains('droppedFramesDelta')));
    expect(sanitizePlaybackPerformanceSnapshot(snapshot), snapshot);
  });

  test('invalid calendar timestamps cannot normalize into valid evidence', () {
    final baseline = _accumulator().snapshot();
    for (final timestamp in [
      '2026-02-30T12:00:00Z',
      '2026-13-01T12:00:00Z',
      '2026-00-01T12:00:00Z',
      '2026-09-00T12:00:00Z',
      '2026-09-04T24:00:00Z',
      '2026-09-04T12:60:00Z',
      '2026-09-04T12:00:60Z',
      '2026-09-04T12:00:00+24:00',
      '2026-09-04T12:00:00-00:60',
    ]) {
      expect(
        sanitizePlaybackPerformanceSnapshot({
          ...baseline,
          'startedAt': timestamp,
          'updatedAt': '2027-01-01T00:00:00Z',
        }),
        isEmpty,
        reason: timestamp,
      );
      final accumulator = _accumulator();
      accumulator.addSample({..._sample(0), 'timestamp': timestamp});
      expect(accumulator.snapshot()['samples'], isEmpty, reason: timestamp);
    }
  });

  test('summary coverage cannot claim intervals without active evidence', () {
    final accumulator = _accumulator();
    accumulator.addSample(_sample(0));
    accumulator.addSample(_sample(1000));
    accumulator.addSample(_sample(2000));
    final snapshot = accumulator.snapshot();
    for (final rawSummary in <Map<String, Object?>>[
      {'activeSampleCount': 0, 'activeIntervalCount': 1},
      {'activeSampleCount': 1, 'activeIntervalCount': 1},
      {'activeSampleCount': 3, 'activeIntervalCount': 3},
      {'activeSampleCount': 3, 'activeIntervalCount': 0},
      {'activeSampleCount': 3},
      {},
    ]) {
      final summary =
          sanitizePlaybackPerformanceSnapshot({
                ...snapshot,
                'summary': {
                  ...rawSummary,
                  'droppedFramesObservedIntervals': 1,
                  'droppedFramesDelta': 0,
                },
              })['summary']
              as Map;
      expect(
        summary,
        isNot(contains('droppedFramesDelta')),
        reason: '$rawSummary',
      );
      expect(
        summary,
        isNot(contains('droppedFramesObservedIntervals')),
        reason: '$rawSummary',
      );
    }
    final summary =
        sanitizePlaybackPerformanceSnapshot({
              ...snapshot,
              'summary': {
                'activeSampleCount': 2,
                'excludedSampleCount': 3,
                'activeIntervalCount': 1,
                'counterResetCount': 3,
                'droppedFramesObservedIntervals': 1,
                'droppedFramesDelta': 0,
              },
            })['summary']
            as Map;
    expect(summary['excludedSampleCount'], 1);
    expect(summary['droppedFramesDelta'], 0);
    expect(summary, isNot(contains('counterResetCount')));
  });
}

PlaybackPerformanceAccumulator _accumulator({String engine = 'mpv'}) =>
    PlaybackPerformanceAccumulator(
      sessionId: 'pbs-performanceTest1234',
      engine: engine,
      attempt: 1,
      startedAt: DateTime.utc(2026, 9, 4, 12),
      sourceKind: 'web',
      requestedDecoder: 'hardware_adaptive',
    );

Map<String, Object?> _sample(int elapsedMs) => {
  'timestamp': DateTime.utc(
    2026,
    9,
    4,
    12,
  ).add(Duration(milliseconds: elapsedMs)).toIso8601String(),
  'elapsedMs': elapsedMs,
  'playing': true,
  'buffering': false,
  'seeking': false,
  'hudVisible': false,
  'inForeground': true,
};
