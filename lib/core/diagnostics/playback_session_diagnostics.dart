const playbackSessionDiagnosticComponent = 'playback-session';
const playbackSessionDiagnosticSchema = 'tetotv-playback-sessions-v2';
const maximumPlaybackSessionTimelines = 24;
const maximumPlaybackSessionTimelineEvents = 20;

enum PlaybackDiagnosticStage {
  sourceSelected('source_selected'),
  streamOpened('stream_opened'),
  decoderSelected('decoder_selected'),
  audioTrackSelected('audio_track_selected'),
  fallbackAttempted('fallback_attempted'),
  finalOutcome('final_outcome');

  const PlaybackDiagnosticStage(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticAudioIntent {
  sub('sub'),
  dub('dub'),
  unknown('unknown');

  const PlaybackDiagnosticAudioIntent(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticAudioCapability {
  sub('sub'),
  dub('dub'),
  multi('multi'),
  unknown('unknown');

  const PlaybackDiagnosticAudioCapability(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticAudioLanguage {
  english('english'),
  japanese('japanese'),
  other('other'),
  unknown('unknown');

  const PlaybackDiagnosticAudioLanguage(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticAudioPreferenceSource {
  seriesOverride('series_override'),
  pickerSelection('picker_selection'),
  sourceLabel('source_label'),
  globalPreference('global_preference'),
  unknown('unknown');

  const PlaybackDiagnosticAudioPreferenceSource(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticSourceKind {
  torrent('torrent'),
  web('web'),
  plex('plex'),
  jellyfin('jellyfin'),
  local('local'),
  privateLibrary('private_library'),
  unknown('unknown');

  const PlaybackDiagnosticSourceKind(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticDecoder {
  hardwareAdaptive('hardware_adaptive'),
  hardwareDirect('hardware_direct'),
  softwareCompatibility('software_compatibility'),
  unknown('unknown');

  const PlaybackDiagnosticDecoder(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticFallbackKind {
  source('source'),
  decoder('decoder'),
  libraryCompatibility('library_compatibility'),
  retry('retry');

  const PlaybackDiagnosticFallbackKind(this.wireValue);

  final String wireValue;
}

enum PlaybackDiagnosticOutcome {
  working('working'),
  completed('completed'),
  failed('failed'),
  exitedAfterStart('exited_after_start'),
  exitedBeforeStart('exited_before_start');

  const PlaybackDiagnosticOutcome(this.wireValue);

  final String wireValue;
}

/// Builds privacy-safe playback timelines from the bounded diagnostic event
/// ring. Only a strict vocabulary of technical fields is copied. Free-form
/// messages and unknown context never enter a playback session summary.
Map<String, Object?> derivePlaybackSessionDiagnostics(Object? rawEvents) {
  final grouped = <String, List<Map<String, Object?>>>{};
  if (rawEvents is Iterable) {
    for (final raw in rawEvents) {
      if (raw is! Map ||
          raw['component'] != playbackSessionDiagnosticComponent) {
        continue;
      }
      final context = raw['context'];
      if (context is! Map) continue;
      final sessionId = context['session_id']?.toString();
      final stage = _knownValue(
        context['stage'],
        PlaybackDiagnosticStage.values.map((value) => value.wireValue),
      );
      final timestamp = DateTime.tryParse(
        raw['timestamp']?.toString() ?? '',
      )?.toUtc();
      if (sessionId == null ||
          !RegExp(r'^pbs-[A-Za-z0-9_-]{16,40}$').hasMatch(sessionId) ||
          stage == null ||
          timestamp == null) {
        continue;
      }
      final sequence = _boundedInt(context['sequence'], maximum: 10000);
      final status = _knownValue(context['status'], _playbackStatuses);
      final sourceKind = _knownValue(
        context['source_kind'],
        PlaybackDiagnosticSourceKind.values.map((value) => value.wireValue),
      );
      final decoder = _knownValue(
        context['decoder'],
        PlaybackDiagnosticDecoder.values.map((value) => value.wireValue),
      );
      final codec = _safeCodec(context['codec']);
      final decoderName = _safeCodec(context['decoder_name']);
      final requestedAudio = _knownValue(
        context['requested_audio'],
        PlaybackDiagnosticAudioIntent.values.map((value) => value.wireValue),
      );
      final sourceAudioMode = _knownValue(
        context['source_audio_mode'],
        PlaybackDiagnosticAudioCapability.values.map(
          (value) => value.wireValue,
        ),
      );
      final selectedAudioLanguage = _knownValue(
        context['selected_audio_language'],
        PlaybackDiagnosticAudioLanguage.values.map((value) => value.wireValue),
      );
      final audioPreferenceSource = _knownValue(
        context['audio_preference_source'],
        PlaybackDiagnosticAudioPreferenceSource.values.map(
          (value) => value.wireValue,
        ),
      );
      final audioTrackCount = _boundedInt(
        context['audio_track_count'],
        maximum: 128,
      );
      final audioPreferenceMatched = context['audio_preference_matched'] is bool
          ? context['audio_preference_matched'] as bool
          : null;
      final fallbackKind = _knownValue(
        context['fallback_kind'],
        PlaybackDiagnosticFallbackKind.values.map((value) => value.wireValue),
      );
      final reasonCode = _safeReasonCode(context['reason_code']);
      final quality = _safeQuality(context['quality']);
      final cached = context['cached'] is bool
          ? context['cached'] as bool
          : null;
      final seekable = context['seekable'] is bool
          ? context['seekable'] as bool
          : null;
      final attempt = _boundedInt(context['attempt'], maximum: 1000);
      final elapsed = _boundedInt(
        context['elapsed_ms'],
        maximum: const Duration(days: 2).inMilliseconds,
      );
      final position = _boundedInt(
        context['position_ms'],
        maximum: const Duration(days: 2).inMilliseconds,
      );
      final duration = _boundedInt(
        context['duration_ms'],
        maximum: const Duration(days: 2).inMilliseconds,
      );
      final event = <String, Object?>{
        'timestamp': timestamp.toIso8601String(),
        'sequence': ?sequence,
        'stage': stage,
        'status': ?status,
        'sourceKind': ?sourceKind,
        'decoder': ?decoder,
        'codec': ?codec,
        'decoderName': ?decoderName,
        'requestedAudio': ?requestedAudio,
        'sourceAudioMode': ?sourceAudioMode,
        'selectedAudioLanguage': ?selectedAudioLanguage,
        'audioPreferenceSource': ?audioPreferenceSource,
        'audioTrackCount': ?audioTrackCount,
        'audioPreferenceMatched': ?audioPreferenceMatched,
        'fallbackKind': ?fallbackKind,
        'reasonCode': ?reasonCode,
        'quality': ?quality,
        'cached': ?cached,
        'seekable': ?seekable,
        'attempt': ?attempt,
        'elapsedMs': ?elapsed,
        'positionMs': ?position,
        'durationMs': ?duration,
      };
      grouped.putIfAbsent(sessionId, () => []).add(event);
    }
  }

  final sessions = <Map<String, Object?>>[];
  for (final entry in grouped.entries) {
    final timeline = entry.value
      ..sort((left, right) {
        final sequence = ((left['sequence'] as int?) ?? 0).compareTo(
          (right['sequence'] as int?) ?? 0,
        );
        if (sequence != 0) return sequence;
        return left['timestamp'].toString().compareTo(
          right['timestamp'].toString(),
        );
      });
    final boundedTimeline =
        timeline.length > maximumPlaybackSessionTimelineEvents
        ? timeline.sublist(
            timeline.length - maximumPlaybackSessionTimelineEvents,
          )
        : timeline;
    final sourceKind = _lastField(boundedTimeline, 'sourceKind') ?? 'unknown';
    final decoder = _lastField(boundedTimeline, 'decoder') ?? 'unknown';
    final codec = _lastField(boundedTimeline, 'codec') ?? 'unknown';
    final decoderName = _lastField(boundedTimeline, 'decoderName') ?? 'unknown';
    final requestedAudio =
        _lastField(boundedTimeline, 'requestedAudio') ?? 'unknown';
    final sourceAudioMode =
        _lastField(boundedTimeline, 'sourceAudioMode') ?? 'unknown';
    final selectedAudioLanguage =
        _lastField(boundedTimeline, 'selectedAudioLanguage') ?? 'unknown';
    final audioPreferenceSource =
        _lastField(boundedTimeline, 'audioPreferenceSource') ?? 'unknown';
    final audioPreferenceMatched = _lastBool(
      boundedTimeline,
      'audioPreferenceMatched',
    );
    final outcomeEvents = boundedTimeline.where(
      (event) =>
          event['stage'] == PlaybackDiagnosticStage.finalOutcome.wireValue,
    );
    final finalOutcome = outcomeEvents.isEmpty
        ? 'in_progress'
        : outcomeEvents.last['status']?.toString() ?? 'in_progress';
    final finalReasonCode = outcomeEvents.isEmpty
        ? _lastField(boundedTimeline, 'reasonCode')
        : outcomeEvents.last['reasonCode']?.toString() ??
              _lastField(boundedTimeline, 'reasonCode');
    final fallbackCount = boundedTimeline
        .where(
          (event) =>
              event['stage'] ==
              PlaybackDiagnosticStage.fallbackAttempted.wireValue,
        )
        .length;
    final observedStages = <String>{
      for (final event in boundedTimeline) event['stage']!.toString(),
    };
    sessions.add({
      'sessionId': entry.key,
      'startedAt': boundedTimeline.first['timestamp'],
      'lastEventAt': boundedTimeline.last['timestamp'],
      'finalOutcome': finalOutcome,
      'finalReasonCode': ?finalReasonCode,
      'sourceKind': sourceKind,
      'decoder': decoder,
      'codec': codec,
      'decoderName': decoderName,
      'requestedAudio': requestedAudio,
      'sourceAudioMode': sourceAudioMode,
      'selectedAudioLanguage': selectedAudioLanguage,
      'audioPreferenceSource': audioPreferenceSource,
      'audioPreferenceMatched': ?audioPreferenceMatched,
      'fallbackAttempts': fallbackCount,
      'observedStageCount': observedStages.length,
      'eventCount': boundedTimeline.length,
      'droppedTimelineEvents': timeline.length - boundedTimeline.length,
      'timeline': boundedTimeline,
    });
  }
  sessions.sort(
    (left, right) => right['lastEventAt'].toString().compareTo(
      left['lastEventAt'].toString(),
    ),
  );
  final boundedSessions = sessions
      .take(maximumPlaybackSessionTimelines)
      .toList(growable: false);
  final working = boundedSessions.cast<Map<String, Object?>?>().firstWhere(
    (session) => _workingOutcomes.contains(session!['finalOutcome']),
    orElse: () => null,
  );
  final failed = boundedSessions.cast<Map<String, Object?>?>().firstWhere(
    (session) => session!['finalOutcome'] == 'failed',
    orElse: () => null,
  );
  return {
    'playbackSessionSchema': playbackSessionDiagnosticSchema,
    'playbackSessionWindow': {
      'ordering': 'newest-first',
      'capacity': maximumPlaybackSessionTimelines,
      'retainedCount': boundedSessions.length,
      'droppedForCapacity': sessions.length - boundedSessions.length,
      'timelineEventCapacity': maximumPlaybackSessionTimelineEvents,
    },
    'playbackSessions': boundedSessions,
    'playbackSessionComparison': {
      'available': working != null && failed != null,
      if (working != null) 'working': _comparisonSide(working),
      if (failed != null) 'failed': _comparisonSide(failed),
      if (working != null && failed != null)
        'differences': {
          'sourceKindChanged': working['sourceKind'] != failed['sourceKind'],
          'decoderChanged': working['decoder'] != failed['decoder'],
          'codecChanged': working['codec'] != failed['codec'],
          'decoderNameChanged': working['decoderName'] != failed['decoderName'],
          'requestedAudioChanged':
              working['requestedAudio'] != failed['requestedAudio'],
          'sourceAudioModeChanged':
              working['sourceAudioMode'] != failed['sourceAudioMode'],
          'selectedAudioLanguageChanged':
              working['selectedAudioLanguage'] !=
              failed['selectedAudioLanguage'],
          'audioPreferenceMatchedChanged':
              working['audioPreferenceMatched'] !=
              failed['audioPreferenceMatched'],
          'fallbackAttemptDelta':
              ((failed['fallbackAttempts'] as int?) ?? 0) -
              ((working['fallbackAttempts'] as int?) ?? 0),
          'observedStageDelta':
              ((failed['observedStageCount'] as int?) ?? 0) -
              ((working['observedStageCount'] as int?) ?? 0),
        },
    },
  };
}

const _playbackStatuses = <String>{
  'selected',
  'opened',
  'open_failed',
  'selected_automatically',
  'selected_by_user',
  'attempted',
  'working',
  'completed',
  'failed',
  'exited_after_start',
  'exited_before_start',
};

const _workingOutcomes = <String>{'working', 'completed', 'exited_after_start'};

Map<String, Object?> _comparisonSide(Map<String, Object?> session) => {
  'sessionId': session['sessionId'],
  'startedAt': session['startedAt'],
  'lastEventAt': session['lastEventAt'],
  'finalOutcome': session['finalOutcome'],
  'finalReasonCode': ?session['finalReasonCode'],
  'sourceKind': session['sourceKind'],
  'decoder': session['decoder'],
  'codec': session['codec'],
  'decoderName': session['decoderName'],
  'requestedAudio': session['requestedAudio'],
  'sourceAudioMode': session['sourceAudioMode'],
  'selectedAudioLanguage': session['selectedAudioLanguage'],
  'audioPreferenceSource': session['audioPreferenceSource'],
  'audioPreferenceMatched': ?session['audioPreferenceMatched'],
  'fallbackAttempts': session['fallbackAttempts'],
  'observedStageCount': session['observedStageCount'],
  'eventCount': session['eventCount'],
};

String? _knownValue(Object? value, Iterable<String> allowed) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  return allowed.contains(normalized) ? normalized : null;
}

String? _lastField(List<Map<String, Object?>> events, String field) {
  for (final event in events.reversed) {
    final value = event[field];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

bool? _lastBool(List<Map<String, Object?>> events, String field) {
  for (final event in events.reversed) {
    final value = event[field];
    if (value is bool) return value;
  }
  return null;
}

int? _boundedInt(Object? value, {required int maximum}) {
  if (value is! num) return null;
  final result = value.toInt();
  return result >= 0 && result <= maximum ? result : null;
}

String? _safeReasonCode(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == null ||
      !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _safeQuality(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == null ||
      !RegExp(r'^(?:unknown|auto|4k|[1-9][0-9]{2,3}p)$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _safeCodec(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == null ||
      !RegExp(r'^[a-z0-9][a-z0-9._+-]{0,63}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}
