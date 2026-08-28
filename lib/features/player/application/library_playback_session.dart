import 'dart:async';

import 'package:anime_tv/features/player/domain/library_playback_request.dart';

enum LibraryPlaybackStartupFailure {
  decoder,
  container,
  noVideoFrame,
  unstableVideo,
}

extension LibraryPlaybackStartupFailureDetails
    on LibraryPlaybackStartupFailure {
  String get diagnosticCode => switch (this) {
    LibraryPlaybackStartupFailure.decoder => 'decoder_startup',
    LibraryPlaybackStartupFailure.container => 'container_startup',
    LibraryPlaybackStartupFailure.noVideoFrame => 'no_video_frame',
    LibraryPlaybackStartupFailure.unstableVideo => 'unstable_video',
  };

  String get safeMessage => switch (this) {
    LibraryPlaybackStartupFailure.decoder =>
      'The media decoder could not start this source.',
    LibraryPlaybackStartupFailure.container =>
      'The media container could not be opened.',
    LibraryPlaybackStartupFailure.noVideoFrame =>
      'The media source did not render a video frame.',
    LibraryPlaybackStartupFailure.unstableVideo =>
      'The media source could not play smoothly on this device.',
  };
}

/// Classifies only failures which make a private source unusable at startup.
/// Returned values are fixed enums so server URLs, item names, and decoder
/// error payloads never enter the session result or Auto Pick UI.
LibraryPlaybackStartupFailure? classifyLibraryPlaybackStartupFailure(
  Object? error,
) {
  final value = error?.toString().trim().toLowerCase() ?? '';
  if (value.isEmpty) return null;
  if (const [
    'could not open codec',
    'failed to initialize a decoder',
    'decoder for codec',
    'unsupported codec',
    'audio decoder',
    'video decoder',
    'failed to decode',
    'mediacodec',
  ].any(value.contains)) {
    return LibraryPlaybackStartupFailure.decoder;
  }
  if (const [
    'unsupported container',
    'unsupported format',
    'could not open demuxer',
    'failed to open demuxer',
    'could not recognize file format',
    'no playable streams',
  ].any(value.contains)) {
    return LibraryPlaybackStartupFailure.container;
  }
  if (value.contains('no video frame') ||
      value.contains('no first frame') ||
      value.contains('were rendered')) {
    return LibraryPlaybackStartupFailure.noVideoFrame;
  }
  if (value.contains('dropping too many frames') ||
      value.contains('could not play smoothly')) {
    return LibraryPlaybackStartupFailure.unstableVideo;
  }
  return null;
}

typedef LibraryPlaybackResultObserver =
    void Function(LibraryPlaybackResult result);

/// Serializes progress delivery across engine handoffs.
///
/// Ordinary playback samples are emitted no more than once every two seconds.
/// Play/pause transitions, forced checkpoints, and the final sample bypass the
/// time gate. A slow Jellyfin/Plex callback therefore cannot build an unbounded
/// queue while a player reports position several times per second.
class LibraryPlaybackSession {
  LibraryPlaybackSession(this.request);

  static const progressInterval = Duration(seconds: 2);

  final LibraryPlaybackRequest request;
  Future<void>? _startFuture;
  Future<void>? _progressDrain;
  LibraryPlaybackProgress? _pendingProgress;
  LibraryPlaybackProgress? _lastProgress;
  DateTime? _lastQueuedAt;
  bool? _lastQueuedPlaying;
  bool _completed = false;
  bool _finished = false;
  String? _failure;
  LibraryPlaybackResult? _terminalResult;
  Future<LibraryPlaybackResult>? _finishFuture;

  LibraryPlaybackProgress? get lastProgress => _lastProgress;
  bool get isFinished => _finished;

  /// Announces playback only after the typed player route has mounted.
  ///
  /// Progress delivery also awaits this future, so a slow media server can
  /// never observe progress before its Playing/started notification.
  Future<void> start() => _startFuture ??= _deliverStart();

  void report({
    required Duration position,
    required Duration duration,
    required bool playing,
    DateTime? sampledAt,
    bool force = false,
  }) {
    if (_finished) return;
    final now = (sampledAt ?? DateTime.now()).toUtc();
    final safeDuration = duration.isNegative ? Duration.zero : duration;
    final maximum = safeDuration > Duration.zero
        ? safeDuration
        : const Duration(hours: 24);
    final safePosition = position.isNegative
        ? Duration.zero
        : position > maximum
        ? maximum
        : position;
    final progress = LibraryPlaybackProgress(
      position: safePosition,
      duration: safeDuration,
      playing: playing,
      sampledAt: now,
    );
    _lastProgress = progress;
    final stateChanged = _lastQueuedPlaying != playing;
    final intervalElapsed =
        _lastQueuedAt == null ||
        now.difference(_lastQueuedAt!) >= progressInterval;
    if (!force && !stateChanged && !intervalElapsed) return;
    _lastQueuedAt = now;
    _lastQueuedPlaying = playing;
    _enqueueProgress(progress);
  }

  void markCompleted({
    Duration? position,
    Duration? duration,
    bool playing = false,
  }) {
    if (_finished) return;
    _completed = true;
    final last = _lastProgress;
    report(
      position: position ?? duration ?? last?.position ?? Duration.zero,
      duration: duration ?? last?.duration ?? Duration.zero,
      playing: playing,
      force: true,
    );
  }

  void markFailed(LibraryPlaybackStartupFailure failure) {
    if (_finished) return;
    _failure = failure.safeMessage;
  }

  Future<LibraryPlaybackResult> finish({
    LibraryPlaybackResultObserver? onResult,
  }) {
    final result = _terminalResult ??= _buildTerminalResult();
    _finished = true;
    if (onResult != null) {
      try {
        onResult(result);
      } catch (_) {
        // A route observer cannot change playback shutdown semantics.
      }
    }
    return _finishFuture ??= _deliverFinish(result);
  }

  LibraryPlaybackResult _buildTerminalResult() {
    final progress = _lastProgress;
    final reason = _failure != null
        ? LibraryPlaybackEndReason.failed
        : _completed
        ? LibraryPlaybackEndReason.completed
        : LibraryPlaybackEndReason.exited;
    return LibraryPlaybackResult(
      position: progress?.position ?? request.initialPosition,
      duration: progress?.duration ?? Duration.zero,
      reason: reason,
      started: _startFuture != null || progress != null,
      error: _failure,
      failureStage: _failure == null
          ? null
          : LibraryPlaybackFailureStage.playbackStartup,
    );
  }

  Future<LibraryPlaybackResult> _deliverFinish(
    LibraryPlaybackResult result,
  ) async {
    final started = _startFuture;
    if (started != null) await started;
    final progress = _lastProgress;
    if (progress != null) _enqueueProgress(progress);
    while (_progressDrain != null) {
      await _progressDrain!;
    }
    final callback = request.onFinished;
    if (callback != null) {
      try {
        await callback(result);
      } catch (_) {
        // Server progress reporting must never strand or crash the player route.
      }
    }
    return result;
  }

  void _enqueueProgress(LibraryPlaybackProgress progress) {
    final callback = request.onProgress;
    if (callback == null) return;
    _pendingProgress = progress;
    if (_progressDrain != null) return;
    late final Future<void> drain;
    drain = _drainProgress(callback).whenComplete(() {
      if (identical(_progressDrain, drain)) _progressDrain = null;
      if (_pendingProgress != null) _enqueueProgress(_pendingProgress!);
    });
    _progressDrain = drain;
  }

  Future<void> _drainProgress(LibraryPlaybackProgressCallback callback) async {
    while (_pendingProgress != null) {
      final progress = _pendingProgress!;
      _pendingProgress = null;
      await start();
      try {
        await callback(progress);
      } catch (_) {
        // Best effort: offline media servers must not interrupt playback.
      }
    }
  }

  Future<void> _deliverStart() async {
    final callback = request.onStarted;
    if (callback == null) return;
    try {
      await callback(request.initialPosition);
    } catch (_) {
      // Media-server writeback is best effort and must not block playback.
    }
  }
}
