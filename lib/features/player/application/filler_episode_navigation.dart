import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:flutter/foundation.dart';

int episodeNavigationCeiling({
  required int requestedEpisode,
  int? declaredTotalEpisodes,
  int? nextAiringEpisode,
}) {
  final declared = declaredTotalEpisodes;
  if (declared != null && declared > 0) {
    return declared < requestedEpisode ? requestedEpisode : declared;
  }
  final lastAired = (nextAiringEpisode ?? (requestedEpisode + 1)) - 1;
  return lastAired < requestedEpisode ? requestedEpisode : lastAired;
}

@immutable
class FillerEpisodeNavigationDecision {
  const FillerEpisodeNavigationDecision({
    required this.episode,
    this.skippedEpisodes = const [],
    this.dataUnavailable = false,
  });

  /// The next episode to play, or null when every remaining episode is
  /// confirmed filler.
  final int? episode;
  final List<int> skippedEpisodes;
  final bool dataUnavailable;

  bool get skippedAny => skippedEpisodes.isNotEmpty;
}

/// Selects the first non-filler episode at or after [requestedEpisode].
///
/// The caller must only set [canAutoSkip] after a complete, unambiguous lookup.
/// Anything less than a confirmed result deliberately fails open and preserves
/// the requested episode.
FillerEpisodeNavigationDecision decideFillerEpisodeNavigation({
  required int requestedEpisode,
  required int totalEpisodes,
  required bool skipEnabled,
  required bool canAutoSkip,
  required Set<int> confirmedFillerEpisodes,
}) {
  if (!skipEnabled || !canAutoSkip || totalEpisodes < requestedEpisode) {
    return FillerEpisodeNavigationDecision(episode: requestedEpisode);
  }

  final skipped = <int>[];
  var candidate = requestedEpisode;
  while (candidate <= totalEpisodes &&
      confirmedFillerEpisodes.contains(candidate)) {
    skipped.add(candidate);
    candidate++;
  }
  return FillerEpisodeNavigationDecision(
    episode: candidate <= totalEpisodes ? candidate : null,
    skippedEpisodes: List.unmodifiable(skipped),
  );
}

String fillerEpisodeListLabel(Iterable<int> episodes) {
  final values = episodes.toSet().toList()..sort();
  if (values.isEmpty) return '';
  final ranges = <String>[];
  var start = values.first;
  var end = start;
  for (final value in values.skip(1)) {
    if (value == end + 1) {
      end = value;
      continue;
    }
    ranges.add(start == end ? '$start' : '$start–$end');
    start = value;
    end = value;
  }
  ranges.add(start == end ? '$start' : '$start–$end');
  return '${values.length == 1 ? 'Episode' : 'Episodes'} ${ranges.join(', ')}';
}

/// Looks up filler metadata and returns a fail-open playback decision.
Future<FillerEpisodeNavigationDecision> resolveFillerEpisodeNavigation({
  required FillerEpisodeRepository repository,
  required FillerSeriesIdentity identity,
  required int requestedEpisode,
  required int totalEpisodes,
  required bool skipEnabled,
}) async {
  if (!skipEnabled) {
    return FillerEpisodeNavigationDecision(episode: requestedEpisode);
  }
  try {
    final lookup = await repository.lookup(identity);
    if (!lookup.canAutoSkip) {
      return FillerEpisodeNavigationDecision(
        episode: requestedEpisode,
        dataUnavailable: true,
      );
    }
    final confirmedCeiling = lookup.knownEpisodeCount < totalEpisodes
        ? lookup.knownEpisodeCount
        : totalEpisodes;
    if (confirmedCeiling <= 0 || requestedEpisode > confirmedCeiling) {
      return FillerEpisodeNavigationDecision(
        episode: requestedEpisode,
        dataUnavailable: true,
      );
    }
    final decision = decideFillerEpisodeNavigation(
      requestedEpisode: requestedEpisode,
      totalEpisodes: confirmedCeiling,
      skipEnabled: true,
      canAutoSkip: lookup.canAutoSkip,
      confirmedFillerEpisodes: lookup.confirmedFillerEpisodes,
    );
    if (decision.episode == null && confirmedCeiling < totalEpisodes) {
      // The known filler run reaches the edge of Jikan's currently published
      // episode metadata. Do not infer that the first unknown/unaired episode
      // is canonical; preserve the user's requested episode instead.
      return FillerEpisodeNavigationDecision(
        episode: requestedEpisode,
        dataUnavailable: true,
      );
    }
    return decision;
  } catch (_) {
    // Filler metadata is optional. Playback always continues when upstream
    // data cannot be established with complete confidence.
    return FillerEpisodeNavigationDecision(
      episode: requestedEpisode,
      dataUnavailable: true,
    );
  }
}
