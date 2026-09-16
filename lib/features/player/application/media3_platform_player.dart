import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// Android Media3 behind the same state/command contract as the MPV player.
/// No libmpv instance or media_kit video controller is created by this adapter.
class Media3PlatformPlayer extends PlatformPlayer {
  Media3PlatformPlayer({
    this._channel = const MethodChannel('dev.tetotv/media3'),
    Stream<dynamic>? events,
  }) : super(configuration: const PlayerConfiguration(title: 'TetoTV')) {
    _events = (events ?? _nativeEvents).listen(
      _onEvent,
      onError: (Object _, StackTrace _) {
        if (!_disposed) errorController.add('Media3 connection interrupted.');
      },
    );
    ready = _create();
    // A failed initialization is also awaited by open()/the surface. Attach a
    // handler immediately so disposal before the first open cannot leak it.
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  static final Stream<dynamic> _nativeEvents = const EventChannel(
    'dev.tetotv/media3/events',
  ).receiveBroadcastStream();
  // EventChannel teardown normally completes immediately. Keep a small,
  // bounded allowance for platform/plugin cleanup, but never let a broken
  // cancellation strand the authoritative native decoder release.
  static const Duration _eventCancellationTimeout = Duration(milliseconds: 500);
  final MethodChannel _channel;
  late final StreamSubscription<dynamic> _events;
  late final Future<int> ready;
  int? _id;
  int _openId = 0;
  int _nativeGeneration = 0;
  bool _disposed = false;
  bool _firstFrameSeen = false;
  Future<void>? _disposeFuture;
  bool _eventsDisposed = false;
  bool _nativeDisposed = false;
  bool _dartStateDisposed = false;
  Map<String, Object?> _releaseDiagnostic = const {};
  Future<void> _commands = Future<void>.value();
  Map<String, Object?> _metrics = const {};
  List<Map<String, Object?>> _chapters = const [];
  final Map<String, String> _externalSubtitleIds = {};

  /// Closed, scalar-only native teardown evidence for local diagnostics.
  Map<String, Object?> get releaseDiagnostic => _releaseDiagnostic;

  Future<int> _create() async {
    final result = await _channel.invokeMapMethod<String, Object?>('create');
    final id = result?['id'];
    if (id is! int) throw StateError('Media3 could not be initialized.');
    _id = id;
    if (!completer.isCompleted) completer.complete();
    return id;
  }

  Future<T?> _command<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) {
    if (_disposed) return Future<T?>.error(StateError('Player is closed.'));
    final epoch = _openId;
    final task = _commands.then<T?>((_) async {
      final id = await ready;
      if (_disposed || epoch != _openId) return null;
      return _channel.invokeMethod<T>(method, {
        'id': id,
        'openId': epoch,
        ...args,
      });
    });
    _commands = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  @override
  Future<int> get handle => ready;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (_disposed) throw StateError('Player is closed.');
    final media = switch (playable) {
      Media value => value,
      Playlist value when value.medias.length == 1 => value.medias.single,
      _ => throw ArgumentError('Media3 expects one media item per episode.'),
    };
    _openId++;
    _nativeGeneration = 0;
    _firstFrameSeen = false;
    _externalSubtitleIds.clear();
    _metrics = const {};
    _chapters = const [];
    _publish(
      PlayerState(
        playlist: Playlist([media]),
        volume: state.volume,
        rate: state.rate,
        buffering: true,
        position: media.start ?? Duration.zero,
      ),
    );
    // media_kit normalizes Android content URIs into an owned descriptor. Keep
    // the Media in state.playlist so its finalizer cannot close it mid-stream.
    final uri = media.uri.startsWith('fd://')
        ? Uri.file('/proc/self/fd/${media.uri.substring(5)}').toString()
        : media.uri.startsWith('/')
        ? Uri.file(media.uri).toString()
        : media.uri;
    final sidecars = _sidecars(media.extras?['subtitles']);
    final audioSidecars = _audioSidecars(media.extras?['audioTracks']);
    for (var index = 0; index < sidecars.length; index++) {
      final uri = sidecars[index]['uri'];
      if (uri is String) _externalSubtitleIds[uri] = 'sidecar:${index + 1}';
    }
    await _command<void>('open', {
      'uri': uri,
      'headers': media.httpHeaders ?? const <String, String>{},
      'startMs': media.start?.inMilliseconds ?? 0,
      'endMs': media.end?.inMilliseconds,
      if (media.extras?['mimeType'] is String)
        'mimeType': media.extras!['mimeType'],
      if (sidecars.isNotEmpty) 'subtitles': sidecars,
      if (audioSidecars.isNotEmpty) 'audioTracks': audioSidecars,
      'play': play,
    });
  }

  @override
  Future<void> play() async => _command<void>('play');
  @override
  Future<void> pause() async => _command<void>('pause');
  @override
  Future<void> playOrPause() => state.playing ? pause() : play();
  @override
  Future<void> seek(Duration duration) async => _command<void>('seek', {
    'positionMs': duration.inMilliseconds.clamp(0, 1 << 52),
  });
  @override
  Future<void> stop() async {
    final epoch = _openId;
    await _command<void>('stop');
    if (!_disposed && epoch == _openId) {
      _firstFrameSeen = false;
      _metrics = const {};
      _publish(PlayerState(volume: state.volume, rate: state.rate));
    }
  }

  @override
  Future<void> setRate(double rate) async {
    if (!rate.isFinite || rate <= 0) throw ArgumentError.value(rate);
    await _command<void>('setRate', {'rate': rate});
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!volume.isFinite) throw ArgumentError.value(volume);
    await _command<void>('setVolume', {'volume': volume.clamp(0, 100) / 100});
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    await _command<void>('setAudioTrack', {'trackId': track.id});
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    if (track.uri || track.data) {
      await addSubtitleTrack(track);
    } else {
      await _command<void>('setSubtitleTrack', {'trackId': track.id});
    }
  }

  Future<void> addSubtitleTrack(
    SubtitleTrack track, {
    bool select = true,
  }) async {
    if (!track.uri && !track.data) {
      if (select) await setSubtitleTrack(track);
      return;
    }
    if (track.data && utf8.encode(track.id).length > 2 * 1024 * 1024) {
      throw ArgumentError('Subtitle file is too large.');
    }
    final registered = _externalSubtitleIds[track.id];
    if (registered != null) {
      if (select) {
        await _command<void>('setSubtitleTrack', {'trackId': registered});
      }
      return;
    }
    final epoch = _openId;
    final result = await _command<Map<Object?, Object?>>('addSubtitleTrack', {
      if (track.uri) 'uri': track.id,
      if (track.data) 'data': track.id,
      'title': track.title,
      'language': track.language,
      'select': select,
    });
    if (!_disposed && epoch == _openId && result?['trackId'] is String) {
      _externalSubtitleIds[track.id] = result!['trackId']! as String;
    }
  }

  Future<void> setOptions(Map<String, Object?> options) async {
    await _command<void>('setOptions', {'options': options});
  }

  Future<void> setDecoderMode(String mode) async {
    await _command<void>('setDecoderMode', {'mode': mode});
  }

  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) => _command<Uint8List>('screenshot', {'format': format});

  /// Only equivalent technical scalar values are supplied to diagnostics.
  /// Missing counters stay unknown; a decoder-render count is NOT screen FPS.
  Future<String?> readProperty(String property) async {
    if (_disposed) return null;
    if (property == 'chapter-list/count') return '${_chapters.length}';
    final chapter = RegExp(
      r'^chapter-list/(\d+)/(title|time)$',
    ).firstMatch(property);
    if (chapter != null) {
      final index = int.parse(chapter.group(1)!);
      if (index >= _chapters.length) return null;
      return _chapters[index][chapter.group(2)]?.toString();
    }
    final key = _propertyFields[property];
    if (key == null) return null;
    final value = _metrics[key];
    if (value is bool) return value ? 'yes' : 'no';
    return value is String || (value is num && value.isFinite)
        ? value.toString()
        : null;
  }

  static const _propertyFields = {
    'hwdec-current': 'activeHwdec',
    'current-tracks/video/codec': 'codec',
    'current-tracks/video/decoder': 'decoderName',
    'current-tracks/audio/codec': 'audioCodec',
    'video-dec-params/pixelformat': 'pixelFormat',
    'video-params/w': 'width',
    'video-params/h': 'height',
    'container-fps': 'sourceFps',
    'estimated-vf-fps': 'sourceFps',
    'display-fps': 'displayFps',
    'frame-drop-count': 'droppedFrames',
    'tetotv-rendered-frame-count': 'renderedFrames',
    'demuxer-cache-duration': 'bufferSeconds',
    'video-bitrate': 'videoBitrate',
    'audio-bitrate': 'audioBitrate',
    'paused-for-cache': 'pausedForCache',
    'tetotv-external-audio-fallback': 'externalAudioFallback',
  };

  void _onEvent(dynamic event) {
    if (_disposed ||
        event is! Map ||
        event['id'] != _id ||
        event['openId'] != _openId) {
      return;
    }
    final generation = _int(event['generation']);
    if (generation > 0) {
      if (generation < _nativeGeneration) return;
      if (generation > _nativeGeneration) {
        _nativeGeneration = generation;
        _firstFrameSeen = false;
        _metrics = const {};
        _chapters = const [];
      }
    }
    if (event['type'] == 'error') {
      _publish(state.copyWith(playing: false, buffering: false));
      // Never forward provider URLs, HTTP headers, or raw native exceptions.
      final code = event['code'] ?? event['error'];
      final safeCode =
          code is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)
          ? ' ($code)'
          : '';
      errorController.add('Media3 could not play this stream$safeCode.');
      return;
    }
    if (event['type'] != 'state') return;
    _firstFrameSeen = _firstFrameSeen || event['renderedFirstFrame'] == true;
    final metrics = event['metrics'];
    if (metrics is Map) {
      _metrics = {
        for (final key in _propertyFields.values.toSet())
          if (metrics[key] is String ||
              metrics[key] is num ||
              metrics[key] is bool)
            key: metrics[key],
      };
    }
    final width = _int(event['width']);
    final height = _int(event['height']);
    final fps = _number(event['sourceFps']);
    _metrics = {
      ..._metrics,
      if (width > 0) 'width': width,
      if (height > 0) 'height': height,
      if (fps != null && fps > 0) 'sourceFps': fps,
      if (event['bufferMs'] is num)
        'bufferSeconds': _int(event['bufferMs']) / 1000,
    };
    if (event['chapters'] case final List<dynamic> chapters) {
      _chapters = [
        for (final item in chapters.take(256))
          if (item is Map && item['title'] is String && item['time'] is num)
            {'title': item['title'], 'time': item['time']},
      ];
    }
    final rawTracks = event['tracks'];
    final audio = <AudioTrack>[AudioTrack.auto(), AudioTrack.no()];
    final subtitles = <SubtitleTrack>[SubtitleTrack.auto(), SubtitleTrack.no()];
    if (rawTracks is Map) {
      for (final item in _maps(rawTracks['audio'])) {
        final id = item['id'];
        if (item['supported'] == false ||
            id is! String ||
            id == 'auto' ||
            id == 'no') {
          continue;
        }
        audio.add(
          AudioTrack(
            id,
            _string(item['title']),
            _string(item['language']),
            codec: _string(item['codec']),
            channelscount: _positive(item['channels']),
            samplerate: _positive(item['sampleRate']),
            isDefault: item['isDefault'] == true,
          ),
        );
      }
      for (final item in _maps(rawTracks['subtitle'])) {
        final id = item['id'];
        if (item['supported'] == false ||
            id is! String ||
            id == 'auto' ||
            id == 'no') {
          continue;
        }
        subtitles.add(
          SubtitleTrack(id, _string(item['title']), _string(item['language'])),
        );
      }
    }
    final video = VideoTrack(
      'video',
      null,
      null,
      codec: _string(_metrics['codec']),
      decoder: _string(_metrics['decoderName']),
      w: width > 0 ? width : null,
      h: height > 0 ? height : null,
      fps: fps,
    );
    final tracks = Tracks(audio: audio, subtitle: subtitles, video: [video]);
    final track = Track(
      video: video,
      audio:
          audio.where((t) => t.id == event['selectedAudio']).firstOrNull ??
          AudioTrack.auto(),
      subtitle:
          subtitles
              .where((t) => t.id == event['selectedSubtitle'])
              .firstOrNull ??
          SubtitleTrack.no(),
    );
    final position = Duration(milliseconds: _int(event['positionMs']));
    _publish(
      PlayerState(
        // copyWith cannot clear nullable dimensions. A recreated decoder must
        // prove its own first frame rather than inherit the previous surface.
        playlist: state.playlist,
        position: position,
        duration: Duration(milliseconds: _int(event['durationMs'])),
        buffer: position + Duration(milliseconds: _int(event['bufferMs'])),
        playing: event['playing'] == true,
        buffering: event['buffering'] == true,
        completed: event['completed'] == true,
        volume: (_number(event['volume']) ?? state.volume / 100) * 100,
        rate: _number(event['rate']) ?? state.rate,
        width: _firstFrameSeen && width > 0 ? width : null,
        height: _firstFrameSeen && height > 0 ? height : null,
        videoParams: VideoParams(
          w: _firstFrameSeen && width > 0 ? width : null,
          h: _firstFrameSeen && height > 0 ? height : null,
        ),
        audioParams: AudioParams(
          sampleRate: track.audio.samplerate,
          channelCount: track.audio.channelscount,
        ),
        track: track,
        tracks: tracks,
      ),
    );
  }

  void _publish(PlayerState next) {
    if (_disposed) return;
    final old = state;
    state = next;
    if (old.playlist != next.playlist) playlistController.add(next.playlist);
    if (old.position != next.position) positionController.add(next.position);
    if (old.duration != next.duration) durationController.add(next.duration);
    if (old.buffer != next.buffer) bufferController.add(next.buffer);
    if (old.playing != next.playing) playingController.add(next.playing);
    if (old.buffering != next.buffering) {
      bufferingController.add(next.buffering);
    }
    if (old.completed != next.completed) {
      completedController.add(next.completed);
    }
    if (old.rate != next.rate) rateController.add(next.rate);
    if (old.volume != next.volume) volumeController.add(next.volume);
    if (old.width != next.width) widthController.add(next.width);
    if (old.height != next.height) heightController.add(next.height);
    if (old.videoParams != next.videoParams) {
      videoParamsController.add(next.videoParams);
    }
    if (old.audioParams != next.audioParams) {
      audioParamsController.add(next.audioParams);
    }
    if (old.tracks != next.tracks) tracksController.add(next.tracks);
    if (old.track != next.track) trackController.add(next.track);
  }

  static String? _string(Object? value) => value is String ? value : null;
  static int _int(Object? value) =>
      value is num && value.isFinite ? value.toInt().clamp(0, 1 << 52) : 0;
  static int? _positive(Object? value) => _int(value) > 0 ? _int(value) : null;
  static double? _number(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;
  static Iterable<Map<dynamic, dynamic>> _maps(Object? value) =>
      value is List ? value.take(256).whereType<Map>() : const [];

  static List<Map<String, Object?>> _sidecars(Object? value) {
    final result = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final row in _maps(value)) {
      final rawUri = row['uri'];
      if (rawUri is! String ||
          rawUri.isEmpty ||
          rawUri.length > 16384 ||
          RegExp(r'[\s\x00-\x1f]').hasMatch(rawUri)) {
        continue;
      }
      final uri = Uri.tryParse(rawUri);
      if (uri == null) continue;
      final valid = switch (uri.scheme.toLowerCase()) {
        'https' || 'http' => uri.host.isNotEmpty && uri.userInfo.isEmpty,
        'file' => uri.path.isNotEmpty && uri.host.isEmpty,
        'content' => uri.authority.isNotEmpty,
        _ => false,
      };
      if (!valid || !seen.add(rawUri)) continue;
      final mime = row['mimeType'];
      result.add({
        'uri': rawUri,
        if (row['title'] is String) 'title': row['title'],
        if (row['language'] is String) 'language': row['language'],
        if (const {
          'text/vtt',
          'application/x-subrip',
          'text/x-ssa',
          'application/ttml+xml',
        }.contains(mime))
          'mimeType': mime,
      });
      if (result.length == 32) break;
    }
    return result;
  }

  static List<Map<String, Object?>> _audioSidecars(Object? value) {
    final result = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final row in _maps(value)) {
      final rawUri = row['uri'];
      if (rawUri is! String ||
          rawUri.isEmpty ||
          rawUri.length > 16384 ||
          RegExp(r'[\s\x00-\x1f]').hasMatch(rawUri)) {
        continue;
      }
      final uri = Uri.tryParse(rawUri);
      final rawMime = row['mimeType'];
      final mime = rawMime is String
          ? rawMime.toLowerCase().split(';').first.trim()
          : null;
      final supportedMime =
          mime != null &&
          (mime.startsWith('audio/') ||
              const {
                'application/vnd.apple.mpegurl',
                'application/x-mpegurl',
                'application/octet-stream',
              }.contains(mime));
      if (uri == null ||
          uri.scheme.toLowerCase() != 'http' ||
          uri.host != '127.0.0.1' ||
          !uri.hasPort ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.path.isEmpty ||
          uri.path == '/' ||
          uri.userInfo.isNotEmpty ||
          !supportedMime ||
          !seen.add(rawUri)) {
        continue;
      }
      result.add({
        'uri': rawUri,
        if (row['title'] is String) 'title': row['title'],
        if (row['language'] is String) 'language': row['language'],
        'mimeType': mime == 'application/x-mpegurl'
            ? 'application/vnd.apple.mpegurl'
            : mime,
      });
      if (result.length == 8) break;
    }
    return result;
  }

  @override
  // Concurrent callers share one attempt. A pending native release can later
  // recheck its owned playback thread, but never invokes ExoPlayer.release()
  // twice; Dart state/controllers are still closed exactly once.
  // ignore: must_call_super
  Future<void> dispose() {
    if (_nativeDisposed && _dartStateDisposed) return Future<void>.value();
    final active = _disposeFuture;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _disposeAttempt().whenComplete(() {
      if (identical(_disposeFuture, operation)) _disposeFuture = null;
    });
    _disposeFuture = operation;
    return operation;
  }

  Future<void> _disposeAttempt() async {
    _disposed = true;
    _openId++;
    try {
      if (!_eventsDisposed) {
        _eventsDisposed = true;
        try {
          await _events.cancel().timeout(_eventCancellationTimeout);
        } catch (_) {
          // Native ownership is the authoritative teardown boundary. The
          // disposed/open epoch guards already reject late events, so a failed
          // or non-completing stream cleanup must never strand decoder release.
        }
      }
      if (!_nativeDisposed) {
        final id = await ready;
        // Disposal is not queued behind a failed or stale media mutation.
        try {
          final result = await _channel.invokeMapMethod<String, Object?>(
            'dispose',
            {'id': id},
          );
          _captureReleaseDiagnostic(
            result,
            fallbackStatus: 'completed',
            fallbackReasonCode: 'media3_release_complete',
          );
        } on PlatformException catch (error) {
          _captureReleaseDiagnostic(
            error.details,
            fallbackStatus: 'failed',
            fallbackReasonCode: error.code == 'media3_release_pending'
                ? 'media3_release_pending'
                : 'platform_error',
          );
          rethrow;
        }
        _nativeDisposed = true;
      }
    } finally {
      if (!_dartStateDisposed) {
        await super.dispose();
        _dartStateDisposed = true;
      }
    }
  }

  void _captureReleaseDiagnostic(
    Object? raw, {
    required String fallbackStatus,
    required String fallbackReasonCode,
  }) {
    final values = raw is Map ? raw : const <Object?, Object?>{};
    const statuses = {'completed', 'completed_after_wait', 'failed'};
    const reasons = {'media3_release_complete', 'media3_release_pending'};
    final rawStatus = values['status'];
    final rawReason = values['reasonCode'];
    final elapsed = values['waitElapsedMs'];
    final timeout = values['timeoutMs'];
    _releaseDiagnostic = Map<String, Object?>.unmodifiable({
      'stage': 'release_waiting',
      'status': rawStatus is String && statuses.contains(rawStatus)
          ? rawStatus
          : fallbackStatus,
      'reason_code': rawReason is String && reasons.contains(rawReason)
          ? rawReason
          : fallbackReasonCode,
      if (elapsed is int) 'wait_elapsed_ms': elapsed.clamp(0, 10_000),
      if (timeout is int) 'timeout_ms': timeout.clamp(0, 10_000),
      'playback_thread_alive': values['playbackThreadAlive'] == true,
    });
  }
}
