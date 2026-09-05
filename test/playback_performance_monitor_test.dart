import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/diagnostics/playback_performance_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Media3 monitor preserves engine and optional rendered counter', (
    tester,
  ) async {
    final h = _Harness(
      tester,
      engine: 'media3',
      read: (property) async => switch (property) {
        'current-tracks/video/codec' => 'h264',
        'tetotv-rendered-frame-count' => '120',
        _ => null,
      },
    )..begin();
    await h.open();
    expect(h.requests, orderedEquals(media3PlaybackPerformanceProperties));
    final snapshot = await h.snapshot();
    expect(snapshot['engine'], 'media3');
    final sample = _lastSample(snapshot);
    expect(sample['codec'], 'h264');
    expect(sample['renderedFrames'], 120);
    expect(sample, isNot(contains('droppedFrames')));
    expect(sample, isNot(contains('displayFps')));
    expect(sample['probeStatus'], 'partial');
    await h.close();
  });

  test('Media3 scalar parser has the same privacy and numeric allowlists', () {
    expect(
      playbackPerformanceMetricsFromProperties({
        'tetotv-rendered-frame-count': '0',
        'current-tracks/video/codec': 'HEVC',
        'current-tracks/video/decoder': 'private.movie.mkv',
        'track-list': 'https://private.example/token',
      }, engine: 'media3'),
      {'renderedFrames': 0, 'codec': 'hevc'},
    );
    for (final value in ['-1', '1.5', 'NaN', 'Infinity', '1000000001']) {
      expect(
        playbackPerformanceMetricsFromProperties({
          'tetotv-rendered-frame-count': value,
        }, engine: 'media3'),
        isEmpty,
      );
    }
    expect(
      playbackPerformanceMetricsFromMpv({'tetotv-rendered-frame-count': '12'}),
      isEmpty,
    );
    expect(
      playbackPerformanceProperties,
      isNot(contains('tetotv-rendered-frame-count')),
    );
    expect(
      playbackPerformanceMetricsFromProperties({
        'frame-drop-count': '0',
      }, engine: 'https://private'),
      isEmpty,
    );
  });

  test(
    'parser uses a closed scalar allowlist and never returns raw secrets',
    () {
      final metrics = playbackPerformanceMetricsFromMpv({
        'hwdec-current': ' MEDIACODEC-COPY ',
        'current-tracks/video/codec': ' HEVC ',
        'current-tracks/video/decoder': 'https://private.example/token',
        'current-tracks/audio/codec': 'Private.Movie.aac',
        'video-dec-params/pixelformat': 'yuv420p10le',
        'track-list': 'private movie',
        'metadata': 'private-secret',
        'stream-path': 'https://private.example/movie',
        'http-header-fields': 'Authorization: private-secret',
        'demuxer-cache-state': '{"filename":"private movie"}',
        'demuxer-cache-state/fw-bytes': '1048576',
      });
      expect(metrics, {
        'activeHwdec': 'mediacodec-copy',
        'codec': 'hevc',
        'pixelFormat': 'yuv420p10le',
        'bitDepth': 10,
        'cacheBytes': 1048576,
      });
      expect(jsonEncode(metrics), isNot(contains('private')));
      expect(playbackPerformanceProperties, isNot(contains('track-list')));
      expect(playbackPerformanceProperties, isNot(contains('metadata')));
      expect(playbackPerformanceProperties, isNot(contains('stream-path')));
      expect(
        playbackPerformanceProperties,
        isNot(contains('demuxer-cache-state')),
      );
      expect(
        playbackPerformanceProperties.toSet().length,
        playbackPerformanceProperties.length,
      );
    },
  );

  test(
    'missing, invalid, infinite and out-of-range values never become zero',
    () {
      expect(playbackPerformanceMetricsFromMpv({}), isEmpty);
      expect(
        playbackPerformanceMetricsFromMpv({
          'frame-drop-count': null,
          'decoder-frame-drop-count': 'unavailable',
          'mistimed-frame-count': '-1',
          'vo-delayed-frame-count': '1.5',
          'avsync': 'NaN',
          'container-fps': 'Infinity',
          'display-fps': '0',
          'video-params/w': '32769',
          'video-params/h': '0',
          'cache-speed': '-1',
          'video-bitrate': '1000000000001',
          'demuxer-cache-duration': '-2',
          'paused-for-cache': 'unknown',
        }),
        isEmpty,
      );
      expect(
        playbackPerformanceMetricsFromMpv({
          'frame-drop-count': '0',
          'avsync': '0',
          'demuxer-cache-duration': '0',
          'cache-speed': '0',
          'paused-for-cache': 'no',
          'demuxer-cache-state/underrun': ' YES ',
        }),
        {
          'droppedFrames': 0,
          'avSyncMs': 0,
          'bufferSeconds': 0,
          'inputBytesPerSecond': 0,
          'pausedForCache': false,
          'cacheUnderrun': true,
        },
      );
    },
  );

  test('A/V seconds convert to signed milliseconds and rates retain units', () {
    expect(
      playbackPerformanceMetricsFromMpv({
        'avsync': '-0.125',
        'container-fps': '23.976',
        'display-fps': '59.94',
        'estimated-display-fps': '60',
        'video-bitrate': '4000000',
        'audio-bitrate': '128000',
        'demuxer-cache-duration': '1.25',
      }),
      {
        'avSyncMs': -125,
        'sourceFps': 23.976,
        'displayFps': 59.94,
        'estimatedDisplayFps': 60,
        'videoBitrate': 4000000,
        'audioBitrate': 128000,
        'bufferSeconds': 1.25,
      },
    );
  });

  for (final entry in {
    'nv12': 8,
    'yuv444p12be': 12,
    'p010': 10,
    'p010le': 10,
    'p016be': 16,
  }.entries) {
    test('pixel format ${entry.key} has known bit depth ${entry.value}', () {
      expect(
        playbackPerformanceMetricsFromMpv({
          'video-dec-params/pixelformat': entry.key,
        })['bitDepth'],
        entry.value,
      );
    });
  }

  testWidgets('no native reads before open, after failure or after disposal', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    await tester.pump(const Duration(seconds: 10));
    expect(h.requests, isEmpty);
    await h.open();
    expect(h.requests, orderedEquals(playbackPerformanceProperties));
    h.monitor.failed();
    final count = h.requests.length;
    await tester.pump(const Duration(seconds: 30));
    await h.monitor.capture();
    expect(h.requests, hasLength(count));
    expect(
      (await h.snapshot())['summary'],
      containsPair('openState', 'failed'),
    );
    await h.close();
    final contextReads = h.contextReads;
    h.monitor.beginAttempt(
      attempt: 2,
      sourceKind: 'web',
      requestedDecoder: 'hardware_adaptive',
    );
    h.monitor.opened();
    h.monitor.stateChanged();
    h.monitor.noteSeek();
    h.monitor.markVideoParametersAvailable();
    h.monitor.failed();
    h.monitor.endAttempt();
    await h.monitor.capture();
    await tester.pump(const Duration(seconds: 30));
    expect(h.requests, hasLength(count));
    expect(h.contextReads, contextReads);
  });

  testWidgets('unsupported exceptions and nulls are retried after startup', (
    tester,
  ) async {
    var ready = false;
    final h = _Harness(
      tester,
      read: (property) async {
        if (property == 'current-tracks/video/codec') {
          if (!ready) throw StateError('private media not ready');
          return 'hevc';
        }
        if (property == 'hwdec-current') return ready ? 'mediacodec' : null;
        return null;
      },
    )..begin();
    await h.open();
    expect((await h.snapshot())['summary'], isNot(contains('codec')));
    ready = true;
    await tester.pump(const Duration(seconds: 5));
    final snapshot = await h.snapshot();
    expect(snapshot['summary'], containsPair('codec', 'hevc'));
    expect(snapshot['summary'], containsPair('activeHwdec', 'mediacodec'));
    expect(_lastSample(snapshot)['probeStatus'], 'partial');
    expect(
      h.requests.where((p) => p == 'current-tracks/video/codec'),
      hasLength(2),
    );
    expect(jsonEncode(snapshot), isNot(contains('private')));
    await h.close();
  });

  testWidgets('four hanging native calls retain their slots across timeouts', (
    tester,
  ) async {
    final pending = <Completer<String?>>[];
    final h = _Harness(
      tester,
      read: (_) {
        final completer = Completer<String?>();
        pending.add(completer);
        return completer.future;
      },
    )..begin();
    await h.open();
    expect(pending, hasLength(4));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_lastSample(await h.snapshot())['probeStatus'], 'timeout');
    await tester.pump(const Duration(seconds: 60));
    expect(pending, hasLength(4));
    h.begin(attempt: 2);
    await h.open();
    await tester.pump(const Duration(seconds: 30));
    expect(pending, hasLength(4));
    await h.close();
    for (final completer in pending) {
      completer.completeError(StateError('late private error'));
    }
    await tester.pump();
    expect(pending, hasLength(4));
  });

  testWidgets('native concurrency stays bounded and settled slots recover', (
    tester,
  ) async {
    final pending = <Completer<String?>>[];
    var hanging = true;
    var active = 0;
    var peak = 0;
    final h = _Harness(
      tester,
      read: (_) {
        active++;
        if (active > peak) peak = active;
        if (!hanging) {
          active--;
          return Future.value(null);
        }
        final completer = Completer<String?>();
        pending.add(completer);
        return completer.future.whenComplete(() => active--);
      },
    )..begin();
    await h.open();
    await tester.pump(const Duration(milliseconds: 250));
    await h.monitor.capture();
    expect(peak, 4);
    hanging = false;
    for (final completer in pending) {
      completer.complete(null);
    }
    await tester.pump();
    await h.monitor.capture();
    expect(h.requests.length, 4 + playbackPerformanceProperties.length);
    expect(peak, 4);
    await h.close();
  });

  testWidgets('late samples cannot cross attempts or a seek transition', (
    tester,
  ) async {
    final pending = <Completer<String?>>[];
    var hanging = true;
    final h = _Harness(
      tester,
      read: (property) {
        if (hanging) {
          final completer = Completer<String?>();
          pending.add(completer);
          return completer.future;
        }
        return Future.value(
          property == 'current-tracks/video/codec' ? 'hevc' : null,
        );
      },
    )..begin();
    await h.open();
    h.begin(attempt: 2);
    await h.open();
    hanging = false;
    for (final completer in pending) {
      completer.complete('av1');
    }
    await tester.pump();
    expect(jsonEncode(await h.snapshot()), isNot(contains('av1')));
    await h.monitor.capture();
    expect((await h.snapshot())['summary'], containsPair('codec', 'hevc'));
    hanging = true;
    pending.clear();
    final capture = h.monitor.capture();
    h.monitor.noteSeek();
    hanging = false;
    for (final completer in pending) {
      completer.complete('av1');
    }
    await tester.pump();
    await capture;
    expect(jsonEncode(await h.snapshot()), isNot(contains('av1')));
    await h.close();
  });

  testWidgets('one hung property cannot starve later healthy counters', (
    tester,
  ) async {
    final hung = Completer<String?>();
    final h = _Harness(
      tester,
      read: (property) {
        if (property == 'hwdec-current') return hung.future;
        return Future.value(switch (property) {
          'frame-drop-count' => '7',
          'demuxer-cache-duration' => '2.5',
          'avsync' => '-0.02',
          _ => null,
        });
      },
    )..begin();
    await h.open();
    await tester.pump(const Duration(milliseconds: 250));
    for (var index = 0; index < 3; index++) {
      await h.monitor.capture();
      final sample = _lastSample(await h.snapshot());
      expect(sample['droppedFrames'], 7);
      expect(sample['bufferSeconds'], 2.5);
      expect(sample['avSyncMs'], -20);
      expect(sample['probeStatus'], 'timeout');
    }
    expect(h.requests.where((p) => p == 'hwdec-current'), hasLength(1));
    expect(h.requests.where((p) => p == 'frame-drop-count'), hasLength(4));
    await h.close();
    hung.complete(null);
    await tester.pump();
  });

  testWidgets('background transitions stop issuing remaining native probes', (
    tester,
  ) async {
    final pending = <Completer<String?>>[];
    final h = _Harness(
      tester,
      read: (_) {
        final completer = Completer<String?>();
        pending.add(completer);
        return completer.future;
      },
    )..begin();
    await h.open();
    expect(pending, hasLength(4));
    h.foreground = false;
    h.monitor.stateChanged();
    for (final completer in pending) {
      completer.complete('av1');
    }
    await tester.pump();
    expect(pending, hasLength(4));
    expect(jsonEncode(await h.snapshot()), isNot(contains('av1')));
    await h.close();
  });

  testWidgets(
    'probe budget bounds a sequence of slow but responsive requests',
    (tester) async {
      final h = _Harness(
        tester,
        read: (_) =>
            Future.delayed(const Duration(milliseconds: 190), () => null),
      )..begin();
      await h.open();
      await tester.pump(const Duration(milliseconds: 751));
      final snapshot = await h.snapshot();
      expect(_lastSample(snapshot)['probeStatus'], 'timeout');
      expect(h.requests.length, lessThan(playbackPerformanceProperties.length));
      final count = h.requests.length;
      await tester.pump(const Duration(seconds: 1));
      expect(h.requests, hasLength(count));
      await h.close();
    },
  );

  testWidgets('terminal failure freezes evidence despite all late callbacks', (
    tester,
  ) async {
    final h = _Harness(
      tester,
      read: (property) async =>
          property == 'current-tracks/video/codec' ? 'hevc' : null,
    )..begin();
    await h.open();
    h.monitor.failed();
    final terminal = await h.snapshot();
    final writes = h.writes.length;
    final reads = h.requests.length;
    final contextReads = h.contextReads;
    for (var index = 0; index < 100; index++) {
      h.monitor.opened(videoParametersAvailable: true);
      h.monitor.stateChanged();
      h.monitor.noteSeek();
      h.monitor.markVideoParametersAvailable();
      h.monitor.failed();
    }
    await h.monitor.capture();
    await tester.pump(const Duration(seconds: 30));
    await h.close();
    expect(await h.snapshot(), terminal);
    expect(h.writes, hasLength(writes));
    expect(h.requests, hasLength(reads));
    expect(h.contextReads, contextReads);
  });

  testWidgets('unobserved process gaps are not inferred as buffering time', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    h.buffering = true;
    await h.open();
    await tester.pump(const Duration(seconds: 1));
    h.monitor.stateChanged();
    h.tickOffset = const Duration(minutes: 1);
    h.monitor.stateChanged();
    expect(
      (await h.snapshot())['summary'],
      containsPair('bufferingTotalMs', 1000),
    );
    await h.close();
  });

  testWidgets('pause, background and seeks exclude buffering intervals', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    h.buffering = true;
    await h.open();
    await tester.pump(const Duration(seconds: 2));
    h.playing = false;
    h.monitor.stateChanged();
    await tester.pump(const Duration(seconds: 4));
    h.playing = true;
    h.monitor.stateChanged();
    await tester.pump(const Duration(seconds: 1));
    h.foreground = false;
    h.monitor.stateChanged();
    await tester.pump(const Duration(seconds: 4));
    h.foreground = true;
    h.monitor.stateChanged();
    await tester.pump(const Duration(seconds: 1));
    h.seeking = true;
    h.monitor.noteSeek();
    await tester.pump(const Duration(seconds: 4));
    h.seeking = false;
    h.monitor.stateChanged();
    h.monitor.stateChanged();
    await tester.pump(const Duration(seconds: 1));
    h.buffering = false;
    h.monitor.stateChanged();
    final summary = (await h.snapshot())['summary'] as Map;
    expect(summary['bufferingTotalMs'], 5000);
    expect(summary['bufferingEvents'], 4);
    expect(summary['rebufferTotalMs'], 0);
    expect(summary['userSeekCount'], 1);
    await h.close();
  });

  testWidgets(
    'parameter readiness does not turn startup buffering into rebuffer',
    (tester) async {
      final h = _Harness(tester)..begin();
      h.buffering = true;
      h.monitor.stateChanged();
      await tester.pump(const Duration(seconds: 2));
      h.monitor.markVideoParametersAvailable();
      await h.open();
      await tester.pump(const Duration(seconds: 2));
      h.buffering = false;
      h.monitor.stateChanged();
      await tester.pump(const Duration(seconds: 1));
      h.position = const Duration(seconds: 1);
      h.monitor.stateChanged();
      h.buffering = true;
      h.monitor.stateChanged();
      await tester.pump(const Duration(seconds: 2));
      h.buffering = false;
      h.monitor.stateChanged();
      final summary = (await h.snapshot())['summary'] as Map;
      expect(summary['videoParametersAfterMs'], 2000);
      expect(summary['firstPositionAdvanceAfterMs'], 5000);
      expect(summary['bufferingEvents'], 2);
      expect(summary['bufferingTotalMs'], 6000);
      expect(summary['rebufferEvents'], 1);
      expect(summary['rebufferTotalMs'], 2000);
      await h.close();
    },
  );

  testWidgets('resume seeking cannot count as first natural position advance', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    await h.open();
    await tester.pump(const Duration(milliseconds: 100));
    h.monitor.noteSeek(userInitiated: false);
    h.seeking = true;
    h.monitor.stateChanged();
    h.position = const Duration(minutes: 10);
    await tester.pump(const Duration(milliseconds: 100));
    h.seeking = false;
    h.monitor.stateChanged();
    var summary = (await h.snapshot())['summary'] as Map;
    expect(summary, isNot(contains('firstPositionAdvanceAfterMs')));
    expect(summary['userSeekCount'], 0);
    h.monitor.stateChanged();
    await tester.pump(const Duration(seconds: 1));
    h.position += const Duration(seconds: 1);
    h.monitor.stateChanged();
    summary = (await h.snapshot())['summary'] as Map;
    expect(summary['firstPositionAdvanceAfterMs'], 1200);
    await h.close();
  });

  testWidgets('unannounced large position jumps are not natural progress', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    await h.open();
    await tester.pump(const Duration(seconds: 1));
    h.position = const Duration(minutes: 20);
    h.monitor.stateChanged();
    expect(
      (await h.snapshot())['summary'],
      isNot(contains('firstPositionAdvanceAfterMs')),
    );
    await h.close();
  });

  testWidgets('wall clock changes cannot alter elapsed or buffer durations', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    h.buffering = true;
    await h.open();
    h.wallClock = h.wallClock.subtract(const Duration(days: 3));
    await tester.pump(const Duration(seconds: 2));
    h.monitor.markVideoParametersAvailable();
    h.wallClock = h.wallClock.add(const Duration(days: 30));
    await tester.pump(const Duration(seconds: 2));
    h.buffering = false;
    h.monitor.stateChanged();
    final snapshot = await h.snapshot();
    expect(_lastSample(snapshot)['elapsedMs'], 4000);
    expect((snapshot['summary'] as Map)['bufferingTotalMs'], 4000);
    expect((snapshot['summary'] as Map)['videoParametersAfterMs'], 2000);
    expect(snapshot['updatedAt'], '2026-09-04T12:00:04.000Z');
    await h.close();
  });

  testWidgets('background timer avoids native reads and observes exclusions', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    await h.open();
    h.foreground = false;
    h.monitor.stateChanged();
    final count = h.requests.length;
    await tester.pump(const Duration(seconds: 30));
    expect(h.requests, hasLength(count));
    expect(_lastSample(await h.snapshot())['inForeground'], false);
    await h.close();
  });

  testWidgets('default sampling is 5 seconds and routine saves are throttled', (
    tester,
  ) async {
    final h = _Harness(tester)..begin();
    await h.open();
    expect(h.monitor.sampleInterval, const Duration(seconds: 5));
    expect(h.monitor.persistInterval, const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 1));
    expect(h.writes, hasLength(2));
    await tester.pump(const Duration(seconds: 14));
    expect(h.requests, hasLength(4 * playbackPerformanceProperties.length));
    expect(h.writes, hasLength(2));
    await tester.pump(const Duration(seconds: 5));
    expect(h.writes, hasLength(3));
    await h.close();
  });

  testWidgets('transition bursts write at most once a second', (tester) async {
    final h = _Harness(tester)..begin();
    await h.open();
    for (var index = 0; index < 500; index++) {
      h.hud = !h.hud;
      h.monitor.stateChanged();
    }
    await tester.pump();
    expect(h.writes, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    expect(h.writes, hasLength(2));
    expect(h.writes.last['samples'], hasLength(6));
    expect(h.writes.last['sampleCount'], greaterThan(500));
    await h.close();
  });

  testWidgets('slow storage coalesces snapshots and serializes writes', (
    tester,
  ) async {
    final gate = Completer<void>();
    var active = 0;
    var peak = 0;
    var first = true;
    final h = _Harness(
      tester,
      persist: (_) async {
        active++;
        if (active > peak) peak = active;
        if (first) {
          first = false;
          await gate.future;
        }
        active--;
      },
    )..begin();
    await h.open();
    for (var index = 0; index < 100; index++) {
      h.monitor.noteSeek();
      unawaited(h.monitor.flush());
    }
    await tester.pump();
    expect(h.writes, hasLength(1));
    h.monitor.failed();
    gate.complete();
    await tester.pump();
    expect(h.writes, hasLength(2));
    expect(peak, 1);
    expect(h.writes.last['summary'], containsPair('userSeekCount', 100));
    expect(h.writes.last['summary'], containsPair('openState', 'failed'));
    await h.close();
  });

  testWidgets('hanging storage retains only the newest 24 pending attempts', (
    tester,
  ) async {
    final gate = Completer<void>();
    var first = true;
    final h = _Harness(
      tester,
      persist: (_) async {
        if (first) {
          first = false;
          await gate.future;
        }
      },
    )..begin();
    await tester.pump();
    for (var attempt = 2; attempt <= 100; attempt++) {
      h.begin(attempt: attempt);
    }
    expect(h.writes, hasLength(1));
    h.monitor.endAttempt();
    gate.complete();
    await tester.pump();
    expect(h.writes, hasLength(25));
    expect(
      h.writes.skip(1).map((s) => s['attempt']),
      orderedEquals(List.generate(24, (index) => index + 77)),
    );
    await h.close();
  });

  testWidgets('persistence and context errors stay optional and recover', (
    tester,
  ) async {
    var throwWrite = true;
    final h = _Harness(
      tester,
      persist: (_) async {
        if (throwWrite) throw StateError('private persistence failure');
      },
    )..begin();
    await h.open();
    h.throwContext = true;
    expect(h.monitor.stateChanged, returnsNormally);
    await h.monitor.capture();
    h.monitor.noteSeek();
    h.throwContext = false;
    throwWrite = false;
    h.monitor.stateChanged();
    expect(await h.snapshot(), isNotEmpty);
    await h.close();
  });
}

Map _lastSample(Map<String, Object?> snapshot) =>
    (snapshot['samples'] as List).last as Map;

class _Harness {
  _Harness(
    this.tester, {
    PlaybackPropertyReader? read,
    PlaybackPerformanceWriter? persist,
    String engine = 'mpv',
  }) {
    final epoch = tester.binding.clock.now();
    monitor = PlaybackPerformanceMonitor(
      sessionId: 'pbs-monitorTests12345678',
      engine: engine,
      clock: () => wallClock,
      monotonicClock: () =>
          tester.binding.clock.now().difference(epoch) + tickOffset,
      readProperty: (property) {
        requests.add(property);
        return read?.call(property) ?? Future.value(null);
      },
      context: () {
        contextReads++;
        if (throwContext) throw StateError('private context failure');
        return PlaybackPerformanceContext(
          position: position,
          duration: const Duration(hours: 1),
          playing: playing,
          buffering: buffering,
          seeking: seeking,
          hudVisible: hud,
          inForeground: foreground,
          androidDisplayFps: 60,
        );
      },
      persist: (snapshot) async {
        writes.add(snapshot);
        await persist?.call(snapshot);
      },
    );
  }

  final WidgetTester tester;
  late final PlaybackPerformanceMonitor monitor;
  final requests = <String>[];
  final writes = <Map<String, Object?>>[];
  DateTime wallClock = DateTime.utc(2026, 9, 4, 12);
  Duration position = Duration.zero;
  Duration tickOffset = Duration.zero;
  bool playing = true;
  bool buffering = false;
  bool seeking = false;
  bool hud = false;
  bool foreground = true;
  bool throwContext = false;
  int contextReads = 0;

  void begin({int attempt = 1}) => monitor.beginAttempt(
    attempt: attempt,
    sourceKind: 'web',
    requestedDecoder: 'hardware_adaptive',
  );

  Future<void> open() async {
    monitor.opened();
    await tester.pump();
  }

  Future<Map<String, Object?>> snapshot() async {
    final saved = monitor.flush();
    await tester.pump();
    await saved;
    return writes.last;
  }

  Future<void> close() async {
    monitor.dispose();
    await tester.pump();
  }
}
