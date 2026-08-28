import 'package:flutter/foundation.dart';

const int maximumWatchPartyTimelineDurationMilliseconds = 24 * 60 * 60 * 1000;
const int maximumWatchPartyTimelineAnchors = 6;

enum WatchPartyTimelineAnchorKind {
  recapStart,
  recapEnd,
  openingStart,
  openingEnd,
  endingStart,
  endingEnd,
}

extension on WatchPartyTimelineAnchorKind {
  String get wireName => switch (this) {
    WatchPartyTimelineAnchorKind.recapStart => 'recap_start',
    WatchPartyTimelineAnchorKind.recapEnd => 'recap_end',
    WatchPartyTimelineAnchorKind.openingStart => 'opening_start',
    WatchPartyTimelineAnchorKind.openingEnd => 'opening_end',
    WatchPartyTimelineAnchorKind.endingStart => 'ending_start',
    WatchPartyTimelineAnchorKind.endingEnd => 'ending_end',
  };
}

WatchPartyTimelineAnchorKind? _watchPartyTimelineAnchorKindFromWireName(
  Object? value,
) => switch (value) {
  'recap_start' => WatchPartyTimelineAnchorKind.recapStart,
  'recap_end' => WatchPartyTimelineAnchorKind.recapEnd,
  'opening_start' => WatchPartyTimelineAnchorKind.openingStart,
  'opening_end' => WatchPartyTimelineAnchorKind.openingEnd,
  'ending_start' => WatchPartyTimelineAnchorKind.endingStart,
  'ending_end' => WatchPartyTimelineAnchorKind.endingEnd,
  _ => null,
};

@immutable
class WatchPartyTimelineAnchor {
  const WatchPartyTimelineAnchor({required this.kind, required this.position});

  final WatchPartyTimelineAnchorKind kind;
  final Duration position;

  Map<String, Object> toJson() => <String, Object>{
    'kind': kind.wireName,
    'position_ms': position.inMilliseconds,
  };

  static WatchPartyTimelineAnchor? tryFromJson(
    Map<String, Object?> value, {
    required Duration duration,
  }) {
    if (value.length != 2 ||
        !value.containsKey('kind') ||
        !value.containsKey('position_ms')) {
      return null;
    }
    final kind = _watchPartyTimelineAnchorKindFromWireName(value['kind']);
    final rawMilliseconds = value['position_ms'];
    final milliseconds = rawMilliseconds is int ? rawMilliseconds : null;
    if (kind == null ||
        milliseconds == null ||
        milliseconds < 0 ||
        milliseconds > duration.inMilliseconds) {
      return null;
    }
    return WatchPartyTimelineAnchor(
      kind: kind,
      position: Duration(milliseconds: milliseconds),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WatchPartyTimelineAnchor &&
      kind == other.kind &&
      position == other.position;

  @override
  int get hashCode => Object.hash(kind, position);
}

/// A public, privacy-safe description of an episode's playback timeline.
///
/// It contains only the duration and common intro/outro boundaries. It never
/// includes a filename, URL, provider token, media hash, subtitle, or frame.
@immutable
class WatchPartyTimelineProfile {
  const WatchPartyTimelineProfile._({
    required this.duration,
    required this.anchors,
  });

  final Duration duration;
  final List<WatchPartyTimelineAnchor> anchors;

  static WatchPartyTimelineProfile? tryCreate({
    required Duration duration,
    Iterable<WatchPartyTimelineAnchor> anchors = const [],
  }) {
    if (duration <= Duration.zero ||
        duration.inMilliseconds >
            maximumWatchPartyTimelineDurationMilliseconds) {
      return null;
    }
    final byKind = <WatchPartyTimelineAnchorKind, WatchPartyTimelineAnchor>{};
    for (final anchor in anchors) {
      if (anchor.position < Duration.zero || anchor.position > duration) {
        continue;
      }
      byKind[anchor.kind] = anchor;
    }
    final ordered = byKind.values.toList(growable: false)
      ..sort((left, right) => left.position.compareTo(right.position));
    return WatchPartyTimelineProfile._(
      duration: duration,
      anchors: List<WatchPartyTimelineAnchor>.unmodifiable(
        ordered.take(maximumWatchPartyTimelineAnchors),
      ),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'version': 1,
    'duration_ms': duration.inMilliseconds,
    'anchors': anchors.map((anchor) => anchor.toJson()).toList(growable: false),
  };

  static WatchPartyTimelineProfile? tryFromJson(Map<String, Object?> value) {
    if (value.length != 3 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        !value.containsKey('duration_ms') ||
        !value.containsKey('anchors')) {
      return null;
    }
    final rawDurationMilliseconds = value['duration_ms'];
    final durationMilliseconds = rawDurationMilliseconds is int
        ? rawDurationMilliseconds
        : null;
    final rawAnchors = value['anchors'];
    if (durationMilliseconds == null ||
        durationMilliseconds <= 0 ||
        durationMilliseconds > maximumWatchPartyTimelineDurationMilliseconds ||
        rawAnchors is! List ||
        rawAnchors.length > maximumWatchPartyTimelineAnchors) {
      return null;
    }
    final duration = Duration(milliseconds: durationMilliseconds);
    final anchors = <WatchPartyTimelineAnchor>[];
    final kinds = <WatchPartyTimelineAnchorKind>{};
    for (final rawAnchor in rawAnchors) {
      if (rawAnchor is! Map) return null;
      final anchor = WatchPartyTimelineAnchor.tryFromJson(
        rawAnchor.map((key, value) => MapEntry(key.toString(), value)),
        duration: duration,
      );
      if (anchor == null || !kinds.add(anchor.kind)) return null;
      anchors.add(anchor);
    }
    return tryCreate(duration: duration, anchors: anchors);
  }

  WatchPartyTimelineAnchor? anchor(WatchPartyTimelineAnchorKind kind) {
    for (final anchor in anchors) {
      if (anchor.kind == kind) return anchor;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is WatchPartyTimelineProfile &&
      duration == other.duration &&
      listEquals(anchors, other.anchors);

  @override
  int get hashCode => Object.hash(duration, Object.hashAll(anchors));
}

enum WatchPartyTimelineCompatibility {
  exact,
  compatible,
  adjusted,
  differentCut,
  unverified,
}

@immutable
class WatchPartyTimelineMapping {
  const WatchPartyTimelineMapping({
    required this.position,
    required this.compatibility,
    required this.usedTimelineMapping,
  });

  final Duration position;
  final WatchPartyTimelineCompatibility compatibility;
  final bool usedTimelineMapping;
}

/// Maps a host timestamp to the same program moment in a guest's release.
///
/// Matching named boundaries (recap, opening, and ending) form a piecewise
/// timeline. This handles releases with a different pre-roll, intro length, or
/// credit length without sharing any media data. Without enough shared
/// boundaries, the raw position is retained and the uncertain edit is surfaced
/// to the viewer instead of guessing an offset.
WatchPartyTimelineMapping mapWatchPartyTimeline({
  required Duration hostPosition,
  required WatchPartyTimelineProfile? host,
  required WatchPartyTimelineProfile? guest,
  required bool exactFingerprint,
  Duration guestOffset = Duration.zero,
}) {
  final safeHostPosition = hostPosition.isNegative
      ? Duration.zero
      : hostPosition;
  if (host == null || guest == null) {
    return WatchPartyTimelineMapping(
      position: _applyGuestOffset(
        safeHostPosition,
        guest?.duration,
        guestOffset,
      ),
      compatibility: exactFingerprint
          ? WatchPartyTimelineCompatibility.exact
          : WatchPartyTimelineCompatibility.unverified,
      usedTimelineMapping: false,
    );
  }

  if (exactFingerprint) {
    return WatchPartyTimelineMapping(
      position: _applyGuestOffset(
        safeHostPosition,
        guest.duration,
        guestOffset,
      ),
      compatibility: WatchPartyTimelineCompatibility.exact,
      usedTimelineMapping: false,
    );
  }

  final durationDelta = (host.duration - guest.duration).abs().inMilliseconds;
  final internalPairs = <({int host, int guest})>[];
  for (final kind in WatchPartyTimelineAnchorKind.values) {
    final hostAnchor = host.anchor(kind);
    final guestAnchor = guest.anchor(kind);
    if (hostAnchor == null || guestAnchor == null) continue;
    internalPairs.add((
      host: hostAnchor.position.inMilliseconds,
      guest: guestAnchor.position.inMilliseconds,
    ));
  }
  internalPairs.sort((left, right) => left.host.compareTo(right.host));
  final monotonicInternalPairs = <({int host, int guest})>[];
  for (final pair in internalPairs) {
    if (monotonicInternalPairs.isEmpty ||
        pair.host > monotonicInternalPairs.last.host &&
            pair.guest > monotonicInternalPairs.last.guest) {
      monotonicInternalPairs.add(pair);
    }
  }

  final closeDuration = durationDelta <= 2000;
  if (closeDuration &&
      monotonicInternalPairs.every((pair) {
        return (pair.host - pair.guest).abs() <= 2000;
      })) {
    return WatchPartyTimelineMapping(
      position: _applyGuestOffset(
        safeHostPosition,
        guest.duration,
        guestOffset,
      ),
      compatibility: WatchPartyTimelineCompatibility.compatible,
      usedTimelineMapping: false,
    );
  }

  final hasVerifiedAnchorMap = monotonicInternalPairs.length >= 2;
  final clearlyDifferentCut = durationDelta > 90000;
  if (!hasVerifiedAnchorMap) {
    return WatchPartyTimelineMapping(
      position: _applyGuestOffset(
        safeHostPosition,
        guest.duration,
        guestOffset,
      ),
      compatibility: WatchPartyTimelineCompatibility.differentCut,
      usedTimelineMapping: false,
    );
  }

  final pairs = <({int host, int guest})>[
    (host: 0, guest: 0),
    ...monotonicInternalPairs,
    (host: host.duration.inMilliseconds, guest: guest.duration.inMilliseconds),
  ];
  final hostMilliseconds = safeHostPosition.inMilliseconds.clamp(
    0,
    host.duration.inMilliseconds,
  );
  var left = pairs.first;
  var right = pairs.last;
  for (var index = 1; index < pairs.length; index++) {
    if (hostMilliseconds <= pairs[index].host) {
      left = pairs[index - 1];
      right = pairs[index];
      break;
    }
  }
  final hostSpan = right.host - left.host;
  final progress = hostSpan <= 0
      ? 0.0
      : (hostMilliseconds - left.host) / hostSpan;
  final mappedMilliseconds =
      left.guest + ((right.guest - left.guest) * progress).round();
  final mapped = _applyGuestOffset(
    Duration(milliseconds: mappedMilliseconds),
    guest.duration,
    guestOffset,
  );
  return WatchPartyTimelineMapping(
    position: mapped,
    compatibility: clearlyDifferentCut
        ? WatchPartyTimelineCompatibility.differentCut
        : WatchPartyTimelineCompatibility.adjusted,
    usedTimelineMapping: true,
  );
}

Duration _applyGuestOffset(
  Duration position,
  Duration? duration,
  Duration offset,
) {
  final adjusted = position + offset;
  if (adjusted.isNegative) return Duration.zero;
  if (duration != null && duration > Duration.zero && adjusted > duration) {
    return duration;
  }
  return adjusted;
}
