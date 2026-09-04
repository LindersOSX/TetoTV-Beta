import 'playback_session_diagnostics.dart';

const playbackPerformanceSchema = 'tetotv-playback-performance-v1';
const maximumPlaybackPerformanceSamples = 6;

/// Performance observations are intentionally a closed technical vocabulary.
/// Never pass through an MPV property map, a device decoder description, or
/// free-form strings: any of those can contain media identity or credentials.
Map<String, Object?> sanitizePlaybackPerformanceSnapshot(Object? raw) {
  if (raw is! Map) return {};
  final sessionId = _sessionId(raw['sessionId']);
  final attempt = _integer(raw['attempt'], minimum: 1, maximum: 10000);
  final startedAt = _timestamp(raw['startedAt']);
  final updatedAt = _timestamp(raw['updatedAt']);
  final sourceKind = _known(
    raw['sourceKind'],
    PlaybackDiagnosticSourceKind.values.map((value) => value.wireValue),
  );
  final decoder = _known(
    raw['requestedDecoder'],
    PlaybackDiagnosticDecoder.values.map((value) => value.wireValue),
  );
  final count = _integer(raw['sampleCount'], maximum: _maximumCount);
  if (sessionId == null ||
      attempt == null ||
      startedAt == null ||
      updatedAt == null ||
      DateTime.parse(updatedAt).isBefore(DateTime.parse(startedAt)) ||
      sourceKind == null ||
      decoder == null ||
      raw['engine'] != 'mpv' ||
      (raw['schema'] != null && raw['schema'] != playbackPerformanceSchema) ||
      count == null ||
      raw['samples'] is! List) {
    return {};
  }
  final rawSamples = raw['samples'] as List;
  final samples = <Map<String, Object?>>[];
  // Bound traversal as well as retention when loading an untrusted report.
  final offset = rawSamples.length > maximumPlaybackPerformanceSamples
      ? rawSamples.length - maximumPlaybackPerformanceSamples
      : 0;
  for (var index = offset; index < rawSamples.length; index++) {
    final sample = _sanitizeSample(rawSamples[index]);
    if (sample.isNotEmpty) samples.add(sample);
  }
  if (count < samples.length) return {};
  return {
    'schema': playbackPerformanceSchema,
    'sessionId': sessionId,
    'attempt': attempt,
    'startedAt': startedAt,
    'updatedAt': updatedAt,
    'engine': 'mpv',
    'sourceKind': sourceKind,
    'requestedDecoder': decoder,
    'sampleCount': count,
    'droppedSamples': count - samples.length,
    'samples': samples,
    'summary': _sanitizeSummary(raw['summary'], sampleCount: count),
  };
}

/// One instance represents one playback/open attempt. Totals outlive the small
/// sample ring, but never bridge missing, paused, seeking or background data.
class PlaybackPerformanceAccumulator {
  PlaybackPerformanceAccumulator({
    required this.sessionId,
    required this.attempt,
    required DateTime startedAt,
    required this.sourceKind,
    required this.requestedDecoder,
  }) : startedAt = startedAt.toUtc();

  final String sessionId;
  final int attempt;
  final DateTime startedAt;
  final String sourceKind;
  final String requestedDecoder;
  final _samples = <Map<String, Object?>>[];
  final _deltas = <String, int>{};
  final _observedIntervals = <String, int>{};
  final _latest = <String, Object?>{};
  Map<String, Object?>? _previous;
  int _sampleCount = 0;
  int _activeSampleCount = 0;
  int _activeIntervalCount = 0;
  int _counterResetCount = 0;
  int _gapCount = 0;
  double? _peakAvSyncMs;
  double? _minBufferSeconds;

  void addSample(Map<String, Object?> sample) {
    final safe = _sanitizeSample(sample);
    if (safe.isEmpty) {
      // An invalid observation breaks continuity; never infer a healthy zero.
      _previous = null;
      _gapCount++;
      return;
    }
    _sampleCount++;
    for (final field in _latestSummaryFields) {
      if (safe.containsKey(field)) _latest[field] = safe[field];
    }
    final active = _isActive(safe);
    if (active) {
      _activeSampleCount++;
      final sync = safe['avSyncMs'] as num?;
      if (sync != null &&
          (_peakAvSyncMs == null || sync.abs() > _peakAvSyncMs!)) {
        _peakAvSyncMs = sync.abs().toDouble();
      }
      final buffer = safe['bufferSeconds'] as num?;
      if (buffer != null &&
          (_minBufferSeconds == null || buffer < _minBufferSeconds!)) {
        _minBufferSeconds = buffer.toDouble();
      }
    }
    final previous = _previous;
    if (previous != null) {
      final elapsed =
          (safe['elapsedMs'] as int) - (previous['elapsedMs'] as int);
      if (elapsed <= 0 || elapsed > 30000) {
        _gapCount++;
      } else if (active && _isActive(previous)) {
        final reset = _counterFields.any((field) {
          final before = previous[field] as int?;
          final after = safe[field] as int?;
          return before != null && after != null && after < before;
        });
        if (reset) {
          // Any reset can indicate a new decoder epoch. Do not combine the
          // other counters across this same ambiguous interval either.
          _counterResetCount++;
        } else {
          _activeIntervalCount++;
          for (final field in _counterFields) {
            final before = previous[field] as int?;
            final after = safe[field] as int?;
            if (before == null || after == null) continue;
            _deltas[field] = (_deltas[field] ?? 0) + after - before;
            _observedIntervals[field] = (_observedIntervals[field] ?? 0) + 1;
          }
        }
      }
    }
    _previous = safe;
    _samples.add(safe);
    if (_samples.length > maximumPlaybackPerformanceSamples) {
      _samples.removeAt(0);
    }
  }

  Map<String, Object?> snapshot({DateTime? updatedAt}) {
    final latest = _samples.isEmpty
        ? startedAt
        : DateTime.parse(_samples.last['timestamp'] as String);
    final updated = (updatedAt ?? latest).toUtc();
    return sanitizePlaybackPerformanceSnapshot({
      'schema': playbackPerformanceSchema,
      'sessionId': sessionId,
      'attempt': attempt,
      'startedAt': startedAt.toIso8601String(),
      'updatedAt': (updated.isBefore(startedAt) ? startedAt : updated)
          .toIso8601String(),
      'engine': 'mpv',
      'sourceKind': sourceKind,
      'requestedDecoder': requestedDecoder,
      'sampleCount': _sampleCount,
      'samples': _samples,
      'summary': {
        ..._latest,
        'sampleCount': _sampleCount,
        'activeSampleCount': _activeSampleCount,
        'excludedSampleCount': _sampleCount - _activeSampleCount,
        'activeIntervalCount': _activeIntervalCount,
        'counterResetCount': _counterResetCount,
        'gapCount': _gapCount,
        for (final field in _counterFields)
          if (_observedIntervals.containsKey(field)) ...{
            '${field}Delta': _deltas[field],
            '${field}ObservedIntervals': _observedIntervals[field],
          },
        'peakAvSyncMs': ?_peakAvSyncMs,
        'minBufferSeconds': ?_minBufferSeconds,
      },
    });
  }
}

const _maximumCount = 1000000000;
const _maximumDurationMs = 604800000; // Seven days, including live streams.
const _counterFields = <String>{
  'droppedFrames',
  'decoderDroppedFrames',
  'mistimedFrames',
  'delayedFrames',
};
const _booleanFields = <String>{
  'playing',
  'buffering',
  'seeking',
  'hudVisible',
  'inForeground',
  'cacheUnderrun',
  'pausedForCache',
  'videoParametersAvailable',
};
const _eventDurationFields = <String>{
  'videoParametersAfterMs',
  'firstPositionAdvanceAfterMs',
  'bufferingTotalMs',
  'rebufferTotalMs',
};
const _eventCountFields = <String>{
  'bufferingEvents',
  'rebufferEvents',
  'userSeekCount',
};
const _latestSummaryFields = <String>{
  'codec',
  'audioCodec',
  'activeHwdec',
  'decoderName',
  'width',
  'height',
  'bitDepth',
  'pixelFormat',
  'sourceFps',
  'displayFps',
  'estimatedDisplayFps',
  'androidDisplayFps',
  'videoParametersAvailable',
  'openState',
  ..._eventDurationFields,
  ..._eventCountFields,
};
const _metricFields = <String>{
  'codec',
  'audioCodec',
  'activeHwdec',
  'decoderName',
  'width',
  'height',
  'bitDepth',
  'pixelFormat',
  'sourceFps',
  'displayFps',
  'estimatedDisplayFps',
  'androidDisplayFps',
  'videoBitrate',
  'audioBitrate',
  ..._counterFields,
  'avSyncMs',
  'bufferSeconds',
  'cacheBytes',
  'inputBytesPerSecond',
  'cacheUnderrun',
  'pausedForCache',
  'videoParametersAvailable',
  ..._eventDurationFields,
  ..._eventCountFields,
};
const _videoCodecs = <String>{
  'h264',
  'hevc',
  'av1',
  'vp9',
  'vp8',
  'mpeg1video',
  'mpeg2video',
  'mpeg4',
  'vc1',
  'wmv3',
  'theora',
  'mjpeg',
  'prores',
  'ffv1',
  'rawvideo',
};
const _audioCodecs = <String>{
  'aac',
  'ac3',
  'eac3',
  'dts',
  'truehd',
  'flac',
  'alac',
  'mp3',
  'mp2',
  'opus',
  'vorbis',
  'pcm',
  'pcm_s16le',
  'pcm_s16be',
  'pcm_s24le',
  'pcm_s24be',
  'pcm_s32le',
  'pcm_s32be',
  'pcm_f32le',
  'pcm_f64le',
  'wmav1',
  'wmav2',
  'wmapro',
  'wavpack',
  'ape',
};
const _hwdecValues = <String>{
  'no',
  'mediacodec',
  'mediacodec-copy',
  'd3d11va',
  'd3d11va-copy',
  'dxva2',
  'dxva2-copy',
  'videotoolbox',
  'videotoolbox-copy',
  'vaapi',
  'vaapi-copy',
  'vdpau',
  'vdpau-copy',
  'nvdec',
  'nvdec-copy',
  'cuda',
  'cuda-copy',
  'vulkan',
  'vulkan-copy',
  'drm',
  'drm-copy',
};
const _decoderNames = <String>{
  ..._videoCodecs,
  'libdav1d',
  'libaom-av1',
  'libvpx-vp9',
  'libvpx',
  'h264_mediacodec',
  'hevc_mediacodec',
  'av1_mediacodec',
  'vp9_mediacodec',
  'vp8_mediacodec',
  'mpeg2_mediacodec',
  'mpeg4_mediacodec',
  'h264_cuvid',
  'hevc_cuvid',
  'av1_cuvid',
  'vp9_cuvid',
  'vp8_cuvid',
  'mpeg2_cuvid',
  'h264_qsv',
  'hevc_qsv',
  'av1_qsv',
  'vp9_qsv',
  'mpeg2_qsv',
};
const _pixelFormats = <String>{
  'yuv420p',
  'yuv422p',
  'yuv444p',
  'yuv440p',
  'yuv411p',
  'yuv410p',
  'yuvj420p',
  'yuvj422p',
  'yuvj444p',
  'nv12',
  'nv21',
  'yuv420p9le',
  'yuv420p9be',
  'yuv420p10le',
  'yuv420p10be',
  'yuv420p12le',
  'yuv420p12be',
  'yuv420p16le',
  'yuv420p16be',
  'yuv422p10le',
  'yuv422p10be',
  'yuv422p12le',
  'yuv422p12be',
  'yuv422p16le',
  'yuv422p16be',
  'yuv444p10le',
  'yuv444p10be',
  'yuv444p12le',
  'yuv444p12be',
  'yuv444p16le',
  'yuv444p16be',
  'p010',
  'p010le',
  'p010be',
  'p016',
  'p016le',
  'p016be',
  'rgb24',
  'bgr24',
  'rgba',
  'bgra',
  'argb',
  'abgr',
  'rgb0',
  'bgr0',
  '0rgb',
  '0bgr',
  'rgb48le',
  'rgb48be',
  'gbrp',
  'gbrp10le',
  'gbrp12le',
  'gbrp16le',
  'gray',
  'gray10le',
  'gray12le',
  'gray16le',
  'mediacodec',
  'd3d11',
  'dxva2_vld',
  'vaapi',
  'vdpau',
  'cuda',
  'videotoolbox_vld',
  'drm_prime',
  'vulkan',
};

Map<String, Object?> _sanitizeSample(Object? raw) {
  if (raw is! Map) return {};
  final timestamp = _timestamp(raw['timestamp']);
  final elapsed = _integer(raw['elapsedMs'], maximum: _maximumDurationMs);
  if (timestamp == null || elapsed == null) return {};
  final safe = <String, Object?>{'timestamp': timestamp, 'elapsedMs': elapsed};
  for (final field in _booleanFields) {
    if (raw[field] is bool) safe[field] = raw[field];
  }
  for (final field in ['positionMs', 'durationMs', ..._eventDurationFields]) {
    final value = _integer(raw[field], maximum: _maximumDurationMs);
    if (value != null) safe[field] = value;
  }
  for (final field in {..._counterFields, ..._eventCountFields}) {
    final value = _integer(raw[field], maximum: _maximumCount);
    if (value != null) safe[field] = value;
  }
  for (final entry in const {
    'width': 32768,
    'height': 32768,
    'bitDepth': 64,
  }.entries) {
    final value = _integer(raw[entry.key], minimum: 1, maximum: entry.value);
    if (value != null) safe[entry.key] = value;
  }
  for (final field in ['videoBitrate', 'audioBitrate', 'inputBytesPerSecond']) {
    final value = _number(raw[field], maximum: 1000000000000);
    if (value != null) safe[field] = value;
  }
  final bytes = _integer(raw['cacheBytes'], maximum: 1000000000000000);
  if (bytes != null) safe['cacheBytes'] = bytes;
  for (final field in [
    'sourceFps',
    'displayFps',
    'estimatedDisplayFps',
    'androidDisplayFps',
  ]) {
    final value = _number(raw[field], minimum: 0.001, maximum: 1000);
    if (value != null) safe[field] = value;
  }
  final speed = _number(raw['playbackSpeed'], minimum: 0.01, maximum: 100);
  if (speed != null) safe['playbackSpeed'] = speed;
  final sync = _number(raw['avSyncMs'], minimum: -3600000, maximum: 3600000);
  if (sync != null) safe['avSyncMs'] = sync;
  final buffer = _number(raw['bufferSeconds'], maximum: 604800);
  if (buffer != null) safe['bufferSeconds'] = buffer;
  for (final entry in const {
    'codec': _videoCodecs,
    'audioCodec': _audioCodecs,
    'activeHwdec': _hwdecValues,
    'decoderName': _decoderNames,
    'pixelFormat': _pixelFormats,
    'probeStatus': {'supported', 'partial', 'unavailable', 'timeout'},
    'openState': {'opening', 'opened', 'failed'},
  }.entries) {
    final value = _known(raw[entry.key], entry.value);
    if (value != null) safe[entry.key] = value;
  }
  safe['availableMetrics'] = [
    for (final field in _metricFields)
      if (safe.containsKey(field)) field,
  ];
  return safe;
}

Map<String, Object?> _sanitizeSummary(Object? raw, {required int sampleCount}) {
  final safe = <String, Object?>{'sampleCount': sampleCount};
  if (raw is! Map) return safe;
  final latest = _sanitizeSample({
    ...raw,
    'timestamp': '2026-01-01T00:00:00Z',
    'elapsedMs': 0,
  });
  for (final field in _latestSummaryFields) {
    if (latest.containsKey(field)) safe[field] = latest[field];
  }
  final activeSamples = _integer(
    raw['activeSampleCount'],
    maximum: sampleCount,
  );
  if (activeSamples != null) {
    safe['activeSampleCount'] = activeSamples;
    safe['excludedSampleCount'] = sampleCount - activeSamples;
    // Coverage is bounded by active observations, not just the retained ring or
    // total sample count. Missing evidence must not turn into a healthy zero.
    final maximumIntervals = activeSamples > 0 ? activeSamples - 1 : 0;
    final activeIntervals = _integer(
      raw['activeIntervalCount'],
      maximum: maximumIntervals,
    );
    if (activeIntervals != null) {
      safe['activeIntervalCount'] = activeIntervals;
    }
    final resets = _integer(
      raw['counterResetCount'],
      maximum: maximumIntervals - (activeIntervals ?? 0),
    );
    if (resets != null) safe['counterResetCount'] = resets;
  }
  final gaps = _integer(raw['gapCount'], maximum: _maximumCount);
  if (gaps != null) safe['gapCount'] = gaps;
  for (final field in _counterFields) {
    final intervals = _integer(
      raw['${field}ObservedIntervals'],
      minimum: 1,
      maximum: safe['activeIntervalCount'] as int? ?? 0,
    );
    final delta = _integer(raw['${field}Delta'], maximum: 1000000000000000);
    if (intervals != null && delta != null) {
      safe['${field}ObservedIntervals'] = intervals;
      safe['${field}Delta'] = delta;
    }
  }
  if ((safe['activeSampleCount'] as int? ?? 0) > 0) {
    final peak = _number(raw['peakAvSyncMs'], maximum: 3600000);
    if (peak != null) safe['peakAvSyncMs'] = peak;
    final buffer = _number(raw['minBufferSeconds'], maximum: 604800);
    if (buffer != null) safe['minBufferSeconds'] = buffer;
  }
  return safe;
}

bool _isActive(Map<String, Object?> sample) =>
    sample['playing'] == true &&
    sample['seeking'] == false &&
    sample['inForeground'] == true;

String? _sessionId(Object? raw) =>
    raw is String && RegExp(r'^pbs-[A-Za-z0-9_-]{16,40}$').hasMatch(raw)
    ? raw
    : null;

String? _known(Object? raw, Iterable<String> allowed) {
  if (raw is! String || raw.length > 64) return null;
  final normalized = raw.trim().toLowerCase();
  return allowed.contains(normalized) ? normalized : null;
}

String? _timestamp(Object? raw) {
  if (raw is! String || raw.length > 40) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-](\d{2}):(\d{2}))$',
  ).firstMatch(raw);
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  // DateTime.tryParse accepts calendar overflow (e.g. February 30 or 24:00).
  // Reject it before parsing so malformed evidence is not silently rewritten.
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59 ||
      (match[7] != null && int.parse(match[7]!) > 23) ||
      (match[8] != null && int.parse(match[8]!) > 59)) {
    return null;
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || parsed.year < 0 || parsed.year > 9999) return null;
  return parsed.toUtc().toIso8601String();
}

int? _integer(Object? raw, {int minimum = 0, required int maximum}) {
  if (raw is! num || !raw.isFinite || raw < minimum || raw > maximum) {
    return null;
  }
  final integer = raw.toInt();
  return raw == integer ? integer : null;
}

num? _number(Object? raw, {num minimum = 0, required num maximum}) {
  if (raw is! num || !raw.isFinite || raw < minimum || raw > maximum) {
    return null;
  }
  return raw;
}
