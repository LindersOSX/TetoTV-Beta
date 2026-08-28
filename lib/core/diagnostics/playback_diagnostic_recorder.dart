import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';

typedef PlaybackDiagnosticClock = DateTime Function();

/// Serializes a single player's bounded, privacy-safe diagnostic timeline.
///
/// Callers choose only enums and short reason codes. This API deliberately has
/// no parameter capable of accepting a URL, header, provider/server ID, title,
/// filename, torrent hash, or local path.
class PlaybackDiagnosticSessionRecorder {
  factory PlaybackDiagnosticSessionRecorder({
    required TetoTvDatabase database,
    String? sessionId,
    PlaybackDiagnosticClock? clock,
    Random? random,
  }) {
    final effectiveClock = clock ?? DateTime.now;
    return PlaybackDiagnosticSessionRecorder._(
      database,
      _validatedSessionId(
        sessionId ?? _newSessionId(random ?? Random.secure()),
      ),
      effectiveClock,
      effectiveClock().toUtc(),
    );
  }

  PlaybackDiagnosticSessionRecorder._(
    this._database,
    this.sessionId,
    this._clock,
    this._startedAt,
  );

  final TetoTvDatabase _database;
  final PlaybackDiagnosticClock _clock;
  final DateTime _startedAt;
  final String sessionId;
  Future<void> _tail = Future<void>.value();
  int _sequence = 0;

  Future<void> sourceSelected({
    required PlaybackDiagnosticSourceKind sourceKind,
    String? quality,
    bool automatic = false,
    bool? cached,
    bool? seekable,
    PlaybackDiagnosticAudioIntent? requestedAudio,
    PlaybackDiagnosticAudioCapability? sourceAudioCapability,
    PlaybackDiagnosticAudioPreferenceSource? audioPreferenceSource,
  }) => _record(
    stage: PlaybackDiagnosticStage.sourceSelected,
    status: automatic ? 'selected_automatically' : 'selected_by_user',
    sourceKind: sourceKind,
    quality: quality,
    cached: cached,
    seekable: seekable,
    requestedAudio: requestedAudio,
    sourceAudioCapability: sourceAudioCapability,
    audioPreferenceSource: audioPreferenceSource,
  );

  Future<void> audioTrackSelected({
    required PlaybackDiagnosticAudioIntent requestedAudio,
    required PlaybackDiagnosticAudioLanguage selectedAudioLanguage,
    required PlaybackDiagnosticAudioPreferenceSource audioPreferenceSource,
    required int audioTrackCount,
    required bool preferenceMatched,
  }) => _record(
    stage: PlaybackDiagnosticStage.audioTrackSelected,
    status: 'selected',
    requestedAudio: requestedAudio,
    selectedAudioLanguage: selectedAudioLanguage,
    audioPreferenceSource: audioPreferenceSource,
    audioTrackCount: audioTrackCount,
    audioPreferenceMatched: preferenceMatched,
  );

  Future<void> streamOpened({
    required PlaybackDiagnosticSourceKind sourceKind,
    required bool succeeded,
    String? codec,
    String? reasonCode,
    int attempt = 1,
  }) => _record(
    stage: PlaybackDiagnosticStage.streamOpened,
    status: succeeded ? 'opened' : 'open_failed',
    sourceKind: sourceKind,
    codec: codec,
    reasonCode: reasonCode,
    attempt: attempt,
    severity: succeeded ? 'info' : 'warning',
  );

  Future<void> decoderSelected({
    required PlaybackDiagnosticDecoder decoder,
    required bool automatic,
    String? codec,
    String? decoderName,
    String? reasonCode,
  }) => _record(
    stage: PlaybackDiagnosticStage.decoderSelected,
    status: automatic ? 'selected_automatically' : 'selected_by_user',
    decoder: decoder,
    codec: codec,
    decoderName: decoderName,
    reasonCode: reasonCode,
  );

  Future<void> fallbackAttempted({
    required PlaybackDiagnosticFallbackKind fallbackKind,
    PlaybackDiagnosticSourceKind? sourceKind,
    PlaybackDiagnosticDecoder? decoder,
    String? codec,
    String? decoderName,
    required String reasonCode,
    int attempt = 1,
  }) => _record(
    stage: PlaybackDiagnosticStage.fallbackAttempted,
    status: 'attempted',
    fallbackKind: fallbackKind,
    sourceKind: sourceKind,
    decoder: decoder,
    codec: codec,
    decoderName: decoderName,
    reasonCode: reasonCode,
    attempt: attempt,
    severity: 'warning',
  );

  Future<void> finalOutcome({
    required PlaybackDiagnosticOutcome outcome,
    String? reasonCode,
    Duration? position,
    Duration? duration,
  }) => _record(
    stage: PlaybackDiagnosticStage.finalOutcome,
    status: outcome.wireValue,
    reasonCode: reasonCode,
    position: position,
    duration: duration,
    severity: outcome == PlaybackDiagnosticOutcome.failed ? 'error' : 'info',
  );

  Future<void> flush() => _tail;

  Future<void> _record({
    required PlaybackDiagnosticStage stage,
    required String status,
    PlaybackDiagnosticSourceKind? sourceKind,
    PlaybackDiagnosticDecoder? decoder,
    String? codec,
    String? decoderName,
    PlaybackDiagnosticAudioIntent? requestedAudio,
    PlaybackDiagnosticAudioCapability? sourceAudioCapability,
    PlaybackDiagnosticAudioLanguage? selectedAudioLanguage,
    PlaybackDiagnosticAudioPreferenceSource? audioPreferenceSource,
    int? audioTrackCount,
    bool? audioPreferenceMatched,
    PlaybackDiagnosticFallbackKind? fallbackKind,
    String? reasonCode,
    String? quality,
    bool? cached,
    bool? seekable,
    int? attempt,
    Duration? position,
    Duration? duration,
    String severity = 'info',
  }) {
    final occurredAt = _clock().toUtc();
    final sequence = ++_sequence;
    final safeReason = _reasonCode(reasonCode);
    final safeQuality = _quality(quality);
    final safeCodec = _codec(codec);
    final safeDecoderName = _technicalName(decoderName);
    final details = <String, Object?>{
      'session_id': sessionId,
      'sequence': sequence,
      'stage': stage.wireValue,
      'status': status,
      'elapsed_ms': occurredAt
          .difference(_startedAt)
          .inMilliseconds
          .clamp(0, const Duration(days: 2).inMilliseconds),
      'source_kind': ?sourceKind?.wireValue,
      'decoder': ?decoder?.wireValue,
      'codec': ?safeCodec,
      'decoder_name': ?safeDecoderName,
      'requested_audio': ?requestedAudio?.wireValue,
      'source_audio_mode': ?sourceAudioCapability?.wireValue,
      'selected_audio_language': ?selectedAudioLanguage?.wireValue,
      'audio_preference_source': ?audioPreferenceSource?.wireValue,
      'audio_track_count': ?audioTrackCount?.clamp(0, 128),
      'audio_preference_matched': ?audioPreferenceMatched,
      'fallback_kind': ?fallbackKind?.wireValue,
      'reason_code': ?safeReason,
      'quality': ?safeQuality,
      'cached': ?cached,
      'seekable': ?seekable,
      'attempt': ?attempt?.clamp(1, 1000),
      'position_ms': ?position?.inMilliseconds.clamp(
        0,
        const Duration(days: 2).inMilliseconds,
      ),
      'duration_ms': ?duration?.inMilliseconds.clamp(
        0,
        const Duration(days: 2).inMilliseconds,
      ),
    };
    _tail = _tail
        .catchError((_) {
          // One failed diagnostic write must not suppress later stages.
        })
        .then(
          (_) => _database.recordDiagnosticEvent(
            category: playbackSessionDiagnosticComponent,
            severity: severity,
            message: _stageMessage(stage),
            details: details,
            occurredAt: occurredAt,
          ),
        );
    return _tail;
  }
}

String _validatedSessionId(String value) {
  if (!RegExp(r'^pbs-[A-Za-z0-9_-]{16,40}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'sessionId', 'is not a safe session ID');
  }
  return value;
}

String _newSessionId(Random random) {
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return 'pbs-${base64Url.encode(bytes).replaceAll('=', '')}';
}

String? _reasonCode(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null ||
      !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _quality(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null ||
      !RegExp(r'^(?:unknown|auto|4k|[1-9][0-9]{2,3}p)$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _codec(String? value) {
  return _technicalName(value);
}

String? _technicalName(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null ||
      !RegExp(r'^[a-z0-9][a-z0-9._+-]{0,63}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

/// Converts an engine/provider error into a fixed reason code. Raw exception
/// text is never persisted in a playback session timeline.
String playbackDiagnosticFailureReasonCode(Object? error) {
  final value = error?.toString().trim().toLowerCase() ?? '';
  if (value.contains('different episode') ||
      value.contains('episode identity')) {
    return 'episode_identity_mismatch';
  }
  if (value.contains('dropping too many frames') ||
      value.contains('frame-drop') ||
      value.contains('frame drop')) {
    return 'frame_drops';
  }
  if (const [
    'could not open codec',
    'failed to initialize a decoder',
    'decoder for codec',
    'unsupported codec',
    'failed to decode',
    'mediacodec',
  ].any(value.contains)) {
    return 'codec_open_failed';
  }
  if (value.contains('no video frame') ||
      value.contains('no first frame') ||
      value.contains('were rendered')) {
    return 'no_video_frames';
  }
  if (value.contains('timed out') || value.contains('timeout')) {
    return 'timeout';
  }
  if (value.contains('network') ||
      value.contains('connection') ||
      value.contains('socket') ||
      value.contains('http ')) {
    return 'network_error';
  }
  if (value.contains('stream changed manually')) return 'manual_source_change';
  if (value.contains('10-bit') || value.contains('hi10')) {
    return 'codec_compatibility';
  }
  if (value.contains('seek')) return 'seek_failed';
  if (value.contains('cache') || value.contains('release unavailable')) {
    return 'source_unavailable';
  }
  return 'playback_error';
}

String _stageMessage(PlaybackDiagnosticStage stage) => switch (stage) {
  PlaybackDiagnosticStage.sourceSelected => 'Playback source selected',
  PlaybackDiagnosticStage.streamOpened => 'Playback stream open result',
  PlaybackDiagnosticStage.decoderSelected => 'Playback decoder selected',
  PlaybackDiagnosticStage.audioTrackSelected => 'Playback audio track selected',
  PlaybackDiagnosticStage.fallbackAttempted => 'Playback fallback attempted',
  PlaybackDiagnosticStage.finalOutcome => 'Playback session final outcome',
};
