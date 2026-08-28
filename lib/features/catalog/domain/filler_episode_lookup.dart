import 'dart:collection';

import 'package:anime_tv/features/catalog/domain/anime_summary.dart';

/// The public identity needed to resolve filler metadata for one AniList entry.
///
/// A positive MyAnimeList ID is authoritative because Jikan's episode endpoint
/// is keyed by that ID. Titles are only used by the repository's conservative
/// fallback when AniList has no MAL mapping.
class FillerSeriesIdentity {
  FillerSeriesIdentity({
    required this.anilistMediaId,
    this.malMediaId,
    List<String> titles = const [],
    this.expectedEpisodes,
    this.seasonYear,
  }) : titles = List.unmodifiable(
         titles.map((title) => title.trim()).where((title) => title.isNotEmpty),
       );

  factory FillerSeriesIdentity.fromAnime(AnimeSummary anime) =>
      FillerSeriesIdentity(
        anilistMediaId: anime.id,
        malMediaId: anime.idMal,
        titles: <String>[
          anime.title,
          ?anime.titleEnglish,
          ?anime.titleRomaji,
          ...anime.synonyms,
        ],
        expectedEpisodes: anime.episodes,
        seasonYear: anime.seasonYear,
      );

  final int anilistMediaId;
  final int? malMediaId;
  final List<String> titles;
  final int? expectedEpisodes;
  final int? seasonYear;
}

enum FillerLookupStatus { confirmed, unavailable }

/// The upstream route that established the MAL series identity.
enum FillerDataSource { jikanMalId, jikanExactTitle }

enum FillerUnavailableReason {
  invalidIdentity,
  missingMalMapping,
  ambiguousTitle,
  network,
  invalidResponse,
  boundedLimit,
  unknown,
}

/// A fail-open filler lookup result.
///
/// Consumers must check [canAutoSkip] and [isConfirmedFiller]. An unavailable
/// or incomplete result always answers `false`, so a metadata problem can
/// never cause an episode to be skipped.
class FillerEpisodeLookup {
  FillerEpisodeLookup._({
    required this.status,
    required Set<int> confirmedFillerEpisodes,
    required this.isComplete,
    this.source,
    this.resolvedMalMediaId,
    this.fetchedAt,
    this.knownEpisodeCount = 0,
    this.unavailableReason,
  }) : confirmedFillerEpisodes = UnmodifiableSetView(
         Set<int>.from(confirmedFillerEpisodes),
       );

  factory FillerEpisodeLookup.confirmed({
    required Set<int> confirmedFillerEpisodes,
    required FillerDataSource source,
    required int resolvedMalMediaId,
    required DateTime fetchedAt,
    required int knownEpisodeCount,
  }) => FillerEpisodeLookup._(
    status: FillerLookupStatus.confirmed,
    confirmedFillerEpisodes: confirmedFillerEpisodes,
    source: source,
    resolvedMalMediaId: resolvedMalMediaId,
    fetchedAt: fetchedAt.toUtc(),
    knownEpisodeCount: knownEpisodeCount,
    isComplete: true,
  );

  factory FillerEpisodeLookup.unavailable({
    FillerUnavailableReason reason = FillerUnavailableReason.unknown,
  }) => FillerEpisodeLookup._(
    status: FillerLookupStatus.unavailable,
    confirmedFillerEpisodes: const <int>{},
    isComplete: false,
    unavailableReason: reason,
  );

  final FillerLookupStatus status;
  final Set<int> confirmedFillerEpisodes;
  final FillerDataSource? source;
  final int? resolvedMalMediaId;
  final DateTime? fetchedAt;
  final int knownEpisodeCount;
  final bool isComplete;
  final FillerUnavailableReason? unavailableReason;

  bool get canAutoSkip => status == FillerLookupStatus.confirmed && isComplete;

  bool isConfirmedFiller(int episode) =>
      canAutoSkip && episode > 0 && confirmedFillerEpisodes.contains(episode);
}

abstract interface class FillerEpisodeRepository {
  Future<FillerEpisodeLookup> lookup(
    FillerSeriesIdentity identity, {
    bool forceRefresh = false,
  });
}
