import 'dart:async';

import 'package:anime_tv/core/diagnostics/playback_performance_diagnostics.dart';

typedef PlaybackPropertyReader = Future<String?> Function(String property);
typedef PlaybackPerformanceWriter =
    Future<void> Function(Map<String, Object?> snapshot);

/// In-process player state only. Never accepts a media URL, title or headers.
class PlaybackPerformanceContext {
  const PlaybackPerformanceContext({
    required this.position,
    required this.duration,
    required this.playing,
    required this.buffering,
    required this.seeking,
    required this.hudVisible,
    required this.inForeground,
    this.playbackSpeed = 1,
    this.androidDisplayFps,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final bool seeking;
  final bool hudVisible;
  final bool inForeground;
  final double playbackSpeed;
  final double? androidDisplayFps;
}

/// Optional read-only built-in player telemetry. No recovery actions or player
/// mutations. Backend adapters expose only the common scalar vocabulary below.
///
/// At most four native requests remain outstanding, including timeouts from
/// old attempts. A timeout cannot release a still-running native call's slot,
/// nor preempt a synchronous native operation. One write runs at a time, with
/// coalesced pending snapshots bounded to the same 24 attempts as retention.
class PlaybackPerformanceMonitor {
  PlaybackPerformanceMonitor({
    required this.sessionId,
    required this._readProperty,
    required this._context,
    required this._persist,
    this.engine = 'mpv',
    DateTime Function()? clock,
    this._monotonicClock,
    this.sampleInterval = const Duration(seconds: 5),
    this.persistInterval = const Duration(seconds: 15),
    this.propertyTimeout = const Duration(milliseconds: 200),
    this.probeBudget = const Duration(milliseconds: 750),
  }) : _clock = clock ?? DateTime.now;

  final String sessionId;
  final String engine;
  final PlaybackPropertyReader _readProperty;
  final PlaybackPerformanceContext Function() _context;
  final PlaybackPerformanceWriter _persist;
  final DateTime Function() _clock;
  final Duration Function()? _monotonicClock;
  final Stopwatch _uptime = Stopwatch()..start();
  final Duration sampleInterval;
  final Duration persistInterval;
  final Duration propertyTimeout;
  final Duration probeBudget;
  final Set<String> _pendingProperties = {};
  final Map<int, Map<String, Object?>> _pendingWrites = {};
  PlaybackPerformanceAccumulator? _accumulator;
  Timer? _timer;
  Timer? _transitionSaveTimer;
  Future<void>? _writeDrain;
  int _generation = 0;
  int _stateRevision = 0;
  int? _capturingGeneration;
  bool _disposed = false;
  String _openState = 'opening';
  DateTime? _startedAt;
  Duration? _startedTick;
  Duration? _lastPersistTick;
  Duration? _lastContextTick;
  Duration? _progressPosition;
  Duration? _progressTick;
  bool _awaitingSeekBaseline = false;
  int? _videoParametersAfterMs;
  int? _firstPositionAdvanceAfterMs;
  int _bufferingEvents = 0;
  int _bufferingTotalMs = 0;
  int _rebufferEvents = 0;
  int _rebufferTotalMs = 0;
  int _userSeekCount = 0;
  bool _bufferingSegmentActive = false;
  bool _bufferingSegmentIsRebuffer = false;

  Duration get _tick => _monotonicClock?.call() ?? _uptime.elapsed;

  void beginAttempt({
    required int attempt,
    required String sourceKind,
    required String requestedDecoder,
  }) {
    if (_disposed) return;
    endAttempt();
    _generation++;
    _startedAt = _clock().toUtc();
    _startedTick = _tick;
    _lastPersistTick = null;
    _lastContextTick = null;
    _progressPosition = null;
    _progressTick = null;
    _awaitingSeekBaseline = false;
    _videoParametersAfterMs = null;
    _firstPositionAdvanceAfterMs = null;
    _bufferingEvents = 0;
    _bufferingTotalMs = 0;
    _rebufferEvents = 0;
    _rebufferTotalMs = 0;
    _userSeekCount = 0;
    _bufferingSegmentActive = false;
    _bufferingSegmentIsRebuffer = false;
    _openState = 'opening';
    _accumulator = PlaybackPerformanceAccumulator(
      sessionId: sessionId,
      attempt: attempt,
      startedAt: _startedAt!,
      sourceKind: sourceKind,
      requestedDecoder: requestedDecoder,
      engine: engine,
    );
    _accumulator!.addSample({
      'timestamp': _startedAt!.toIso8601String(),
      'elapsedMs': 0,
      'openState': 'opening',
      'probeStatus': 'unavailable',
    });
    _save(force: true);
    _timer = Timer.periodic(sampleInterval, (_) => unawaited(capture()));
  }

  void opened({bool videoParametersAvailable = false}) {
    if (_disposed || _accumulator == null || _openState == 'failed') return;
    _openState = 'opened';
    if (videoParametersAvailable) {
      _videoParametersAfterMs ??= _elapsed(_tick);
    }
    stateChanged();
    unawaited(capture());
  }

  void failed() {
    if (_disposed || _accumulator == null) return;
    _openState = 'failed';
    _timer?.cancel();
    _generation++;
    stateChanged();
    _save(force: true);
    // Freeze terminal evidence. Late player/lifecycle callbacks cannot evict
    // the final metric samples or change the failed attempt after this point.
    _accumulator = null;
  }

  /// Parameters are available, not proof of a rendered video frame.
  void markVideoParametersAvailable() {
    if (_disposed || _accumulator == null || _openState == 'failed') return;
    if (_videoParametersAfterMs != null) return;
    _videoParametersAfterMs = _elapsed(_tick);
    stateChanged();
  }

  /// Observe transitions promptly, including while opening. No native reads
  /// occur here. Writes are coalesced to at most one transition write/second.
  void stateChanged() {
    if (_disposed || _accumulator == null) return;
    _stateRevision++;
    final state = _safeContext();
    if (state == null) return;
    _accumulator!.addSample(_contextSample(state, _tick));
    _save(transition: true);
  }

  /// Call before seeking. Automatic restoration does not increase the user
  /// counter, and its position jump cannot establish initial progress.
  void noteSeek({bool userInitiated = true}) {
    if (_disposed || _accumulator == null) return;
    if (userInitiated) _userSeekCount++;
    _stateRevision++;
    _awaitingSeekBaseline = true;
    _progressPosition = null;
    _progressTick = null;
    final state = _safeContext();
    if (state == null) return;
    _accumulator!.addSample(_contextSample(state, _tick, seekBoundary: true));
    _save(transition: true);
  }

  Future<void> capture() async {
    if (_disposed ||
        _capturingGeneration == _generation ||
        _accumulator == null ||
        _openState != 'opened') {
      return;
    }
    final state = _safeContext();
    if (state == null) return;
    if (!state.inForeground) {
      stateChanged();
      return;
    }
    final generation = _generation;
    final revision = _stateRevision;
    _capturingGeneration = generation;
    try {
      final results = <String, String?>{};
      final properties = engine == 'media3'
          ? media3PlaybackPerformanceProperties
          : playbackPerformanceProperties;
      var index = 0;
      var timedOut = false;
      final probeStarted = _tick;
      Future<void> worker() async {
        while (!_disposed &&
            generation == _generation &&
            revision == _stateRevision) {
          if (index >= properties.length) return;
          final remaining = probeBudget - (_tick - probeStarted);
          if (remaining <= Duration.zero || _pendingProperties.length >= 4) {
            // Do not consume the shared work index: other workers may still
            // have usable slots after an old request occupies one indefinitely.
            timedOut = true;
            return;
          }
          final property = properties[index++];
          if (_pendingProperties.contains(property)) {
            timedOut = true;
            continue;
          }
          _pendingProperties.add(property);
          final operation = Future<String?>.sync(() => _readProperty(property));
          unawaited(
            operation.then<void>(
              (_) => _pendingProperties.remove(property),
              onError: (Object _, StackTrace _) {
                _pendingProperties.remove(property);
              },
            ),
          );
          try {
            final value = await operation.timeout(
              remaining < propertyTimeout ? remaining : propertyTimeout,
            );
            if (value != null && value.length <= 128) {
              results[property] = value;
            }
          } on TimeoutException {
            timedOut = true;
          } catch (_) {
            // Missing properties can throw during startup. Retry next sample;
            // never retain/log engine errors, URLs or other private strings.
          }
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
      if (_disposed ||
          generation != _generation ||
          revision != _stateRevision ||
          _accumulator == null) {
        return;
      }
      final current = _safeContext();
      if (current == null) return;
      final native = playbackPerformanceMetricsFromProperties(
        results,
        engine: engine,
      );
      _accumulator!.addSample({
        ..._contextSample(current, _tick),
        ...native,
        'probeStatus': timedOut
            ? 'timeout'
            : native.isEmpty
            ? 'unavailable'
            : _metricFieldsForEngine(engine).values.every(native.containsKey)
            ? 'supported'
            : 'partial',
      });
      _save();
    } catch (_) {
      // Optional telemetry must never disrupt playback.
    } finally {
      if (_capturingGeneration == generation) _capturingGeneration = null;
    }
  }

  PlaybackPerformanceContext? _safeContext() {
    if (_disposed) return null;
    try {
      return _context();
    } catch (_) {
      return null;
    }
  }

  int _elapsed(Duration tick) => (tick - _startedTick!).inMilliseconds.clamp(
    0,
    const Duration(days: 7).inMilliseconds,
  );

  // Wall time anchors an attempt only. Intervals and ordering cannot jump
  // backwards when network time or the user changes the system clock.
  DateTime _timestamp(Duration tick) =>
      _startedAt!.add(Duration(milliseconds: _elapsed(tick)));

  Map<String, Object?> _contextSample(
    PlaybackPerformanceContext current,
    Duration tick, {
    bool seekBoundary = false,
  }) {
    final lastTick = _lastContextTick;
    if (_bufferingSegmentActive && lastTick != null) {
      final duration = (tick - lastTick).inMilliseconds;
      // Do not infer operation across a suspended/unobserved process gap.
      if (duration >= 0 && duration <= sampleInterval.inMilliseconds * 3) {
        _bufferingTotalMs += duration;
        if (_bufferingSegmentIsRebuffer) _rebufferTotalMs += duration;
      }
    }
    final seeking = current.seeking || seekBoundary || _awaitingSeekBaseline;
    final eligible =
        current.playing &&
        current.inForeground &&
        !seeking &&
        _openState != 'failed';
    final isBuffering = eligible && current.buffering;
    if (isBuffering && !_bufferingSegmentActive) {
      _bufferingEvents++;
      // Parameters may exist while startup stalls. Only natural clock progress
      // ends startup; each buffering segment keeps its original category.
      _bufferingSegmentIsRebuffer = _firstPositionAdvanceAfterMs != null;
      if (_bufferingSegmentIsRebuffer) _rebufferEvents++;
    }
    _bufferingSegmentActive = isBuffering;
    if (eligible && !current.buffering && _openState == 'opened') {
      final position = _progressPosition;
      final baselineTick = _progressTick;
      var resetBaseline = position == null || baselineTick == null;
      if (position != null && baselineTick != null) {
        final delta = (current.position - position).inMilliseconds;
        final observedMs = (tick - baselineTick).inMilliseconds;
        final expectedMs = observedMs * current.playbackSpeed;
        if (observedMs > 0 &&
            observedMs <= sampleInterval.inMilliseconds * 3 &&
            delta > 100 &&
            delta <= expectedMs + 1000) {
          _firstPositionAdvanceAfterMs ??= _elapsed(tick);
        }
        // Keep repeated/very small positions as one baseline. A periodic read
        // and a position event may arrive at the same tick; replacing that
        // baseline with an unchanged position would erase real elapsed time.
        resetBaseline =
            delta < 0 ||
            delta > 100 ||
            observedMs > sampleInterval.inMilliseconds * 3;
      }
      if (resetBaseline) {
        _progressPosition = current.position;
        _progressTick = tick;
      }
    } else {
      _progressPosition = null;
      _progressTick = null;
    }
    // The first post-seek observation is excluded too: it cannot bridge a
    // drop-counter interval or turn a resume position jump into progress.
    if (_awaitingSeekBaseline && !current.seeking && !seekBoundary) {
      _awaitingSeekBaseline = false;
    }
    _lastContextTick = tick;
    return {
      'timestamp': _timestamp(tick).toIso8601String(),
      'elapsedMs': _elapsed(tick),
      'positionMs': current.position.inMilliseconds,
      'durationMs': current.duration.inMilliseconds,
      'playing': current.playing,
      'buffering': current.buffering,
      'seeking': seeking,
      'hudVisible': current.hudVisible,
      'inForeground': current.inForeground,
      'playbackSpeed': current.playbackSpeed,
      'androidDisplayFps': ?current.androidDisplayFps,
      'openState': _openState,
      'videoParametersAvailable': _videoParametersAfterMs != null,
      'videoParametersAfterMs': ?_videoParametersAfterMs,
      'firstPositionAdvanceAfterMs': ?_firstPositionAdvanceAfterMs,
      'bufferingEvents': _bufferingEvents,
      'bufferingTotalMs': _bufferingTotalMs,
      'rebufferEvents': _rebufferEvents,
      'rebufferTotalMs': _rebufferTotalMs,
      'userSeekCount': _userSeekCount,
    };
  }

  void _save({bool force = false, bool transition = false}) {
    final accumulator = _accumulator;
    if (accumulator == null) return;
    final tick = _tick;
    final sincePersist = _lastPersistTick == null
        ? persistInterval
        : tick - _lastPersistTick!;
    final minimum = transition ? const Duration(seconds: 1) : persistInterval;
    if (!force && sincePersist < minimum) {
      if (transition && _transitionSaveTimer == null) {
        final generation = _generation;
        _transitionSaveTimer = Timer(minimum - sincePersist, () {
          _transitionSaveTimer = null;
          if (!_disposed && generation == _generation) _save(transition: true);
        });
      }
      return;
    }
    _transitionSaveTimer?.cancel();
    _transitionSaveTimer = null;
    _lastPersistTick = tick;
    _pendingWrites[accumulator.attempt] = accumulator.snapshot(
      updatedAt: _timestamp(tick),
    );
    while (_pendingWrites.length > 24) {
      _pendingWrites.remove(_pendingWrites.keys.first);
    }
    _writeDrain ??= Future<void>.microtask(_drainWrites);
  }

  Future<void> _drainWrites() async {
    try {
      while (_pendingWrites.isNotEmpty) {
        final snapshot = _pendingWrites.remove(_pendingWrites.keys.first)!;
        try {
          await _persist(snapshot);
        } catch (_) {
          // Best-effort storage, with bounded memory even on hangs.
        }
      }
    } finally {
      _writeDrain = null;
    }
  }

  void endAttempt() {
    if (_accumulator == null) return;
    _timer?.cancel();
    _timer = null;
    _transitionSaveTimer?.cancel();
    _transitionSaveTimer = null;
    _generation++;
    // The owner ends the attempt before releasing the player. This final
    // synchronous context read never starts a native property request.
    stateChanged();
    _save(force: true);
    _accumulator = null;
  }

  Future<void> flush() {
    _save(force: true);
    return _writeDrain ?? Future<void>.value();
  }

  void dispose() {
    if (_disposed) return;
    endAttempt();
    _timer?.cancel();
    _transitionSaveTimer?.cancel();
    _generation++;
    _disposed = true;
    _uptime.stop();
  }
}

/// Only scalar technical properties. Never request track-list, metadata,
/// stream-path, title, URL, headers, filenames, or raw cache-state objects.
const playbackPerformanceProperties = <String>[
  'hwdec-current',
  'current-tracks/video/codec',
  'current-tracks/video/decoder',
  'current-tracks/audio/codec',
  'video-params/w',
  'video-params/h',
  'video-dec-params/pixelformat',
  'container-fps',
  'display-fps',
  'estimated-display-fps',
  'frame-drop-count',
  'decoder-frame-drop-count',
  'mistimed-frame-count',
  'vo-delayed-frame-count',
  'avsync',
  'demuxer-cache-duration',
  'demuxer-cache-state/fw-bytes',
  'cache-speed',
  'demuxer-cache-state/underrun',
  'paused-for-cache',
  'video-bitrate',
  'audio-bitrate',
];

/// Media3 reports rendered output buffers through its adapter. This counter is
/// optional and must not be presented as a measured physical display FPS.
const media3PlaybackPerformanceProperties = <String>[
  ...playbackPerformanceProperties,
  'tetotv-rendered-frame-count',
];

const _mpvStringFields = {
  'hwdec-current': 'activeHwdec',
  'current-tracks/video/codec': 'codec',
  'current-tracks/video/decoder': 'decoderName',
  'current-tracks/audio/codec': 'audioCodec',
  'video-dec-params/pixelformat': 'pixelFormat',
};
const _mpvNumberFields = {
  'video-params/w': 'width',
  'video-params/h': 'height',
  'container-fps': 'sourceFps',
  'display-fps': 'displayFps',
  'estimated-display-fps': 'estimatedDisplayFps',
  'frame-drop-count': 'droppedFrames',
  'decoder-frame-drop-count': 'decoderDroppedFrames',
  'mistimed-frame-count': 'mistimedFrames',
  'vo-delayed-frame-count': 'delayedFrames',
  'avsync': 'avSyncMs',
  'demuxer-cache-duration': 'bufferSeconds',
  'demuxer-cache-state/fw-bytes': 'cacheBytes',
  'cache-speed': 'inputBytesPerSecond',
  'video-bitrate': 'videoBitrate',
  'audio-bitrate': 'audioBitrate',
};
const _mpvBooleanFields = {
  'demuxer-cache-state/underrun': 'cacheUnderrun',
  'paused-for-cache': 'pausedForCache',
};
const _mpvMetricFields = {
  ..._mpvStringFields,
  ..._mpvNumberFields,
  ..._mpvBooleanFields,
};

const _media3NumberFields = {
  'tetotv-rendered-frame-count': 'renderedFrames',
};

Map<String, String> _metricFieldsForEngine(String engine) => {
  ..._mpvMetricFields,
  if (engine == 'media3') ..._media3NumberFields,
};

Map<String, Object?> playbackPerformanceMetricsFromMpv(
  Map<String, String?> properties,
) => playbackPerformanceMetricsFromProperties(properties);

Map<String, Object?> playbackPerformanceMetricsFromProperties(
  Map<String, String?> properties, {
  String engine = 'mpv',
}) {
  if (engine != 'mpv' && engine != 'media3') return {};
  final result = <String, Object?>{};
  for (final field in _mpvStringFields.entries) {
    final value = properties[field.key];
    if (value != null && value.length <= 64) result[field.value] = value;
  }
  for (final field in {
    ..._mpvNumberFields,
    if (engine == 'media3') ..._media3NumberFields,
  }.entries) {
    final raw = properties[field.key];
    if (raw == null || raw.length > 128) continue;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite) continue;
    result[field.value] = field.value == 'avSyncMs' ? value * 1000 : value;
  }
  for (final field in _mpvBooleanFields.entries) {
    final value = properties[field.key]?.trim().toLowerCase();
    if (value == 'yes' || value == 'true') result[field.value] = true;
    if (value == 'no' || value == 'false') result[field.value] = false;
  }
  final pixelFormat =
      properties['video-dec-params/pixelformat']?.trim().toLowerCase() ?? '';
  if (pixelFormat.length <= 64) {
    final depth = RegExp(
      r'^(?:yuv(?:420|422|444)p|gbrp|gray)(9|10|12|14|16)(?:le|be)$',
    ).firstMatch(pixelFormat);
    if (depth != null) {
      result['bitDepth'] = int.parse(depth[1]!);
    } else if (const {
      'yuv420p',
      'yuv422p',
      'yuv444p',
      'nv12',
      'nv21',
      'gray',
    }.contains(pixelFormat)) {
      result['bitDepth'] = 8;
    } else if (const {'p010', 'p010le', 'p010be'}.contains(pixelFormat)) {
      result['bitDepth'] = 10;
    } else if (const {'p016', 'p016le', 'p016be'}.contains(pixelFormat)) {
      result['bitDepth'] = 16;
    }
  }
  // Reuse the persisted allowlist at the parser boundary too. A bounded scalar
  // string can still be a URL/token: length and shape are not privacy checks.
  // This fixed envelope is never persisted or returned.
  final safe = sanitizePlaybackPerformanceSnapshot({
    'sessionId': 'pbs-nativeMetricParser0000',
    'attempt': 1,
    'startedAt': '2026-01-01T00:00:00Z',
    'updatedAt': '2026-01-01T00:00:00Z',
    'engine': engine,
    'sourceKind': 'web',
    'requestedDecoder': 'hardware_adaptive',
    'sampleCount': 1,
    'samples': [
      {'timestamp': '2026-01-01T00:00:00Z', 'elapsedMs': 0, ...result},
    ],
  });
  final sample = (safe['samples'] as List).single as Map<String, Object?>;
  return {
    for (final entry in sample.entries)
      if (_metricFieldsForEngine(engine).containsValue(entry.key) ||
          entry.key == 'bitDepth')
        entry.key: entry.value,
  };
}
