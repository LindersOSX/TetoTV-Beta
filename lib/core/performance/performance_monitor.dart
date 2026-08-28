import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

typedef PerformanceEventRecorder =
    Future<void> Function(String name, Duration duration);

class PerformanceMonitor {
  PerformanceMonitor({
    PerformanceEventRecorder? recorder,
    DateTime Function()? now,
    this.slowFrameSampleInterval = const Duration(seconds: 5),
  }) : _recorder = recorder ?? TetoTvDatabase.instance.recordPerformance,
       _now = now ?? DateTime.now;

  static final instance = PerformanceMonitor();
  final PerformanceEventRecorder _recorder;
  final DateTime Function() _now;
  final Duration slowFrameSampleInterval;
  bool _started = false;
  final Stopwatch _startup = Stopwatch();
  Future<void> _writeTail = Future.value();
  Timer? _slowFrameTimer;
  DateTime? _lastSlowFrameRecord;
  Duration? _pendingSlowFrame;

  void start() {
    if (_started) return;
    _started = true;
    _startup.start();
    SchedulerBinding.instance.addTimingsCallback(_recordFrames);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _startup.stop();
      _record('startup_first_frame', _startup.elapsed);
    });
  }

  void _recordFrames(List<FrameTiming> timings) {
    Duration? slowest;
    for (final timing in timings) {
      final total = timing.totalSpan;
      if (total <= const Duration(milliseconds: 20)) continue;
      if (slowest == null || total > slowest) slowest = total;
    }
    if (slowest != null) _queueSlowFrame(slowest);
  }

  void _queueSlowFrame(Duration duration) {
    final pending = _pendingSlowFrame;
    if (pending == null || duration > pending) _pendingSlowFrame = duration;

    final lastRecord = _lastSlowFrameRecord;
    final now = _now();
    if (lastRecord == null ||
        now.difference(lastRecord) >= slowFrameSampleInterval) {
      _flushSlowFrame();
      return;
    }

    _slowFrameTimer ??= Timer(
      slowFrameSampleInterval - now.difference(lastRecord),
      _flushSlowFrame,
    );
  }

  void _flushSlowFrame() {
    _slowFrameTimer?.cancel();
    _slowFrameTimer = null;
    final duration = _pendingSlowFrame;
    _pendingSlowFrame = null;
    if (duration == null) return;
    _lastSlowFrameRecord = _now();
    _record('slow_frame', duration);
  }

  void _record(String name, Duration duration) {
    _writeTail = _writeTail.then((_) => _recorder(name, duration)).catchError((
      _,
    ) {
      // Diagnostics must never make app startup or frame delivery fail.
    });
  }

  @visibleForTesting
  void recordSlowFrame(Duration duration) => _queueSlowFrame(duration);

  @visibleForTesting
  Future<void> flush() async {
    _flushSlowFrame();
    await _writeTail;
  }
}
