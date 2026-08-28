import 'dart:math' as math;

import 'package:dio/dio.dart';

bool skipSegmentDurationsCompatible(Duration requested, Duration current) {
  if (requested <= Duration.zero || current <= Duration.zero) return false;
  final requestedSeconds = requested.inMilliseconds / 1000;
  final toleranceSeconds = math.max(45.0, requestedSeconds * .05);
  return (requested - current).abs().inMilliseconds <=
      (toleranceSeconds * 1000).round();
}

/// Uses a deliberately tighter tolerance than marker acceptance when deciding
/// whether an empty Web/HLS lookup should be tried again. A manifest can settle
/// by tens of seconds while the wider marker tolerance still correctly accepts
/// AniSkip data for a slightly different encode.
bool skipSegmentLookupDurationsEquivalent(
  Duration completed,
  Duration current,
) {
  if (completed <= Duration.zero || current <= Duration.zero) return false;
  return (completed - current).abs() <= const Duration(seconds: 2);
}

/// Web manifests can briefly report a partial duration and a legitimate
/// AniSkip no-match before their final timeline is available. Keep an empty
/// lookup retryable for a few settled samples instead of permanently hiding
/// intro/outro controls for the rest of playback.
bool skipSegmentLookupIsComplete({
  required bool isWebStream,
  required bool externalFailed,
  required bool hasMarkers,
  required int attempts,
  bool runtimeProbesExhausted = false,
}) {
  if (runtimeProbesExhausted) return true;
  if (attempts >= 4) return true;
  if (externalFailed) return false;
  return hasMarkers || !isWebStream;
}

enum SkipSegmentKind { opening, ending, recap }

enum SkipSegmentSource { embeddedChapter, aniSkip }

class SkipSegment {
  const SkipSegment({
    required this.start,
    required this.end,
    required this.kind,
    required this.source,
  });

  final Duration start;
  final Duration end;
  final SkipSegmentKind kind;
  final SkipSegmentSource source;

  Duration get duration => end - start;

  String get actionLabel => switch (kind) {
    SkipSegmentKind.opening => 'Skip intro',
    SkipSegmentKind.ending => 'Skip outro',
    SkipSegmentKind.recap => 'Skip recap',
  };

  bool contains(Duration position) => position >= start && position < end;
}

class MediaChapter {
  const MediaChapter({required this.title, required this.start});

  final String title;
  final Duration start;
}

class AniSkipLookupResult {
  const AniSkipLookupResult({
    required this.segments,
    required this.probeCount,
    required this.usedDurationFallback,
    required this.runtimeFallbackSearchComplete,
  });

  final List<SkipSegment> segments;

  /// Number of distinct episode runtimes sent to AniSkip. This is safe to
  /// expose in diagnostics and makes duration-sensitive Web/HLS misses clear.
  final int probeCount;

  /// Whether a nearby runtime found markers after the exact Web runtime did
  /// not. No URL, title, catalog ID, or media identity is retained.
  final bool usedDurationFallback;

  /// True only when every bounded nearby-runtime probe completed without an
  /// unresolved transport/server failure. Empty results may be finalized only
  /// in this state; otherwise the player can retry later.
  final bool runtimeFallbackSearchComplete;
}

class AniSkipClient {
  AniSkipClient({Dio? dio, this.retryDelay = const Duration(milliseconds: 600)})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
              headers: const {'Accept': 'application/json'},
            ),
          );

  final Dio _dio;
  final Duration retryDelay;

  Future<List<SkipSegment>> segments({
    required int malMediaId,
    required int episode,
    required Duration episodeDuration,
    bool allowRuntimeFallback = false,
  }) async => (await lookup(
    malMediaId: malMediaId,
    episode: episode,
    episodeDuration: episodeDuration,
    allowRuntimeFallback: allowRuntimeFallback,
  )).segments;

  Future<AniSkipLookupResult> lookup({
    required int malMediaId,
    required int episode,
    required Duration episodeDuration,
    bool allowRuntimeFallback = false,
  }) async {
    if (malMediaId <= 0 || episode <= 0 || episodeDuration.inSeconds <= 0) {
      return const AniSkipLookupResult(
        segments: [],
        probeCount: 0,
        usedDurationFallback: false,
        runtimeFallbackSearchComplete: false,
      );
    }
    final actualSeconds = episodeDuration.inMilliseconds / 1000;
    final probeLengths = allowRuntimeFallback
        ? aniSkipRuntimeProbes(episodeDuration)
        : <double>[actualSeconds];
    Object? lastTransientFailure;
    var observedCleanNoMatch = false;
    var hadTransientFailure = false;
    for (var probeIndex = 0; probeIndex < probeLengths.length; probeIndex++) {
      final probeLength = probeLengths[probeIndex];
      final uri = _aniSkipUri(
        malMediaId: malMediaId,
        episode: episode,
        episodeLength: probeLength,
      );
      // Preserve the existing one-shot transient retry for the exact runtime.
      // The nearby-duration probes already provide bounded retry diversity and
      // therefore execute once each to avoid hammering the community API.
      final requestAttempts = probeIndex == 0 ? 2 : 1;
      Map<String, dynamic>? body;
      for (var attempt = 0; attempt < requestAttempts; attempt++) {
        try {
          final response = await _dio.getUri<Map<String, dynamic>>(uri);
          final status = response.statusCode ?? 200;
          if (status == 404) {
            observedCleanNoMatch = true;
            body = response.data;
            break;
          }
          if (status == 429 || status >= 500) {
            throw DioException.badResponse(
              statusCode: status,
              requestOptions: response.requestOptions,
              response: response,
            );
          }
          body = response.data;
          break;
        } on DioException catch (error) {
          final status = error.response?.statusCode;
          if (status == 404) {
            observedCleanNoMatch = true;
            final data = error.response?.data;
            if (data is Map<String, dynamic>) body = data;
            break;
          }
          if (!_retryableAniSkipFailure(error)) rethrow;
          lastTransientFailure = error;
          hadTransientFailure = true;
          if (attempt + 1 < requestAttempts) {
            await Future<void>.delayed(retryDelay);
          }
        }
      }
      if (body == null || body['found'] != true || body['results'] is! List) {
        if (body != null) observedCleanNoMatch = true;
        continue;
      }
      final segments = _parseAniSkipSegments(
        body['results'] as List,
        actualSeconds: actualSeconds,
      );
      if (segments.isEmpty) continue;
      return AniSkipLookupResult(
        segments: segments,
        probeCount: probeIndex + 1,
        usedDurationFallback: probeIndex > 0,
        runtimeFallbackSearchComplete: false,
      );
    }
    if (!observedCleanNoMatch && lastTransientFailure != null) {
      throw lastTransientFailure;
    }
    return AniSkipLookupResult(
      segments: const [],
      probeCount: probeLengths.length,
      usedDurationFallback: false,
      runtimeFallbackSearchComplete:
          allowRuntimeFallback && !hadTransientFailure,
    );
  }

  Uri _aniSkipUri({
    required int malMediaId,
    required int episode,
    required double episodeLength,
  }) => Uri.parse(
    'https://api.aniskip.com/v2/skip-times/$malMediaId/$episode?'
    'types%5B%5D=op&types%5B%5D=ed&types%5B%5D=mixed-op&'
    'types%5B%5D=mixed-ed&types%5B%5D=recap&'
    'episodeLength=$episodeLength',
  );

  List<SkipSegment> _parseAniSkipSegments(
    List<dynamic> results, {
    required double actualSeconds,
  }) {
    // Container runtimes can include/exclude credits or round broadcast
    // durations. AniSkip markers are still valid when that small difference is
    // present, so use a conservative five-percent window with a 45s floor.
    final durationTolerance = math.max(45.0, actualSeconds * .05);
    final candidates = <({SkipSegment segment, double durationDelta})>[];
    for (final item in results) {
      if (item is! Map) continue;
      final interval = item['interval'];
      final start = interval is Map ? interval['startTime'] : null;
      final end = interval is Map ? interval['endTime'] : null;
      final referenceLength = item['episodeLength'];
      if (start is! num || end is! num) continue;
      final durationDelta = referenceLength is num
          ? (referenceLength.toDouble() - actualSeconds).abs()
          : 0.0;
      if (durationDelta > durationTolerance) continue;
      final kind = _aniSkipKind(item['skipType']?.toString());
      if (kind == null) continue;
      final aligned = alignAniSkipInterval(
        startSeconds: start.toDouble(),
        endSeconds: end.toDouble(),
        referenceSeconds: referenceLength is num
            ? referenceLength.toDouble()
            : null,
        actualSeconds: actualSeconds,
        kind: kind,
      );
      final startSeconds = aligned.start;
      final endSeconds = aligned.end;
      if (endSeconds - startSeconds < 8 || endSeconds - startSeconds > 240) {
        continue;
      }
      candidates.add((
        segment: SkipSegment(
          start: Duration(milliseconds: (startSeconds * 1000).round()),
          end: Duration(milliseconds: (endSeconds * 1000).round()),
          kind: kind,
          source: SkipSegmentSource.aniSkip,
        ),
        durationDelta: durationDelta,
      ));
    }
    candidates.sort((a, b) => a.durationDelta.compareTo(b.durationDelta));
    final selected = <SkipSegment>[];
    for (final candidate in candidates) {
      final duplicate = selected.any(
        (existing) =>
            existing.kind == candidate.segment.kind &&
            _overlapRatio(existing, candidate.segment) >= .65,
      );
      if (!duplicate) selected.add(candidate.segment);
    }
    selected.sort((a, b) => a.start.compareTo(b.start));
    return selected;
  }
}

bool _retryableAniSkipFailure(DioException error) {
  final status = error.response?.statusCode;
  return status == 429 ||
      (status != null && status >= 500) ||
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.unknown;
}

/// AniSkip selects submitted markers using the requested episode runtime.
/// Web/HLS cuts commonly differ by a bumper or trailing slate, and the API may
/// return a no-match even though its returned marker runtime would pass our
/// conservative 45-second compatibility check. Probe that same bounded window
/// and stop as soon as markers are found.
List<double> aniSkipRuntimeProbes(Duration episodeDuration) {
  if (episodeDuration <= Duration.zero) return const [];
  final actual = episodeDuration.inMilliseconds / 1000;
  final result = <double>[actual];
  // AniSkip normally matches within roughly 15 seconds. These offsets cover
  // the accepted +/-45s window while limiting a clean Web no-match to five
  // requests total.
  for (final offset in const [30.0, 45.0]) {
    if (actual - offset > 0) result.add(actual - offset);
    result.add(actual + offset);
  }
  return result;
}

/// Openings and recaps are anchored to the beginning of an encode; endings
/// are anchored to its end. Uniformly stretching timestamps shifts both scenes
/// when Web providers add/remove bumpers or trailing material.
({double start, double end}) alignAniSkipInterval({
  required double startSeconds,
  required double endSeconds,
  required double? referenceSeconds,
  required double actualSeconds,
  required SkipSegmentKind kind,
}) {
  var alignedStart = startSeconds;
  var alignedEnd = endSeconds;
  if (kind == SkipSegmentKind.ending &&
      referenceSeconds != null &&
      referenceSeconds > 0) {
    final distanceFromEnd = math.max(0.0, referenceSeconds - endSeconds);
    final markerDuration = endSeconds - startSeconds;
    alignedEnd = actualSeconds - distanceFromEnd;
    alignedStart = alignedEnd - markerDuration;
  }
  return (
    start: alignedStart.clamp(0, actualSeconds).toDouble(),
    end: alignedEnd.clamp(0, actualSeconds).toDouble(),
  );
}

String skipSegmentKey(SkipSegment segment) =>
    '${segment.kind.name}:${segment.start.inMilliseconds}';

SkipSegment? activeSkipSegmentAt({
  required Iterable<SkipSegment> segments,
  required Duration position,
  Set<String> consumed = const {},
}) {
  for (final segment in segments) {
    if (segment.contains(position) &&
        !consumed.contains(skipSegmentKey(segment))) {
      return segment;
    }
  }
  return null;
}

bool shouldAutomaticallySkipSegment(
  SkipSegment segment, {
  required bool autoSkipIntros,
  required bool autoSkipOutros,
}) =>
    (segment.kind == SkipSegmentKind.opening && autoSkipIntros) ||
    (segment.kind == SkipSegmentKind.ending && autoSkipOutros);

List<SkipSegment> skipSegmentsFromChapters(
  List<MediaChapter> chapters,
  Duration mediaDuration,
) {
  if (chapters.isEmpty || mediaDuration <= Duration.zero) return const [];
  final ordered = [...chapters]..sort((a, b) => a.start.compareTo(b.start));
  final result = <SkipSegment>[];
  for (var index = 0; index < ordered.length; index++) {
    final chapter = ordered[index];
    final kind = _chapterKind(chapter.title);
    if (kind == null) continue;
    final end = index + 1 < ordered.length
        ? ordered[index + 1].start
        : mediaDuration;
    final segment = SkipSegment(
      start: chapter.start,
      end: end > mediaDuration ? mediaDuration : end,
      kind: kind,
      source: SkipSegmentSource.embeddedChapter,
    );
    if (segment.duration >= const Duration(seconds: 8) &&
        segment.duration <= const Duration(minutes: 4)) {
      result.add(segment);
    }
  }
  return result;
}

List<SkipSegment> mergeSkipSegments(
  List<SkipSegment> embedded,
  List<SkipSegment> external,
) {
  final result = [...embedded];
  for (final candidate in external) {
    if (result.any(
      (existing) =>
          existing.kind == candidate.kind &&
          _overlapRatio(existing, candidate) >= .5,
    )) {
      continue;
    }
    result.add(candidate);
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

SkipSegmentKind? _aniSkipKind(String? value) => switch (value) {
  'op' || 'mixed-op' => SkipSegmentKind.opening,
  'ed' || 'mixed-ed' => SkipSegmentKind.ending,
  'recap' => SkipSegmentKind.recap,
  _ => null,
};

SkipSegmentKind? _chapterKind(String title) {
  final normalized = title
      .toLowerCase()
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      .trim();
  if (RegExp(
    r'(^|\b)(opening|op|intro)(?:\s*\d+)?(\b|$)',
  ).hasMatch(normalized)) {
    return SkipSegmentKind.opening;
  }
  if (RegExp(
    r'(^|\b)(ending|ed|outro|credits)(?:\s*\d+)?(\b|$)',
  ).hasMatch(normalized)) {
    return SkipSegmentKind.ending;
  }
  if (RegExp(r'(^|\b)(recap|previously)(\b|$)').hasMatch(normalized)) {
    return SkipSegmentKind.recap;
  }
  return null;
}

double _overlapRatio(SkipSegment left, SkipSegment right) {
  final start = math.max(left.start.inMilliseconds, right.start.inMilliseconds);
  final end = math.min(left.end.inMilliseconds, right.end.inMilliseconds);
  if (end <= start) return 0;
  final shorter = math.min(
    left.duration.inMilliseconds,
    right.duration.inMilliseconds,
  );
  return shorter <= 0 ? 0 : (end - start) / shorter;
}
