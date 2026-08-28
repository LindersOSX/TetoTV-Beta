import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

enum LibraryEpisodeOrigin { device, jellyfin, plex }

/// A private-library result which matched a public catalog episode locally.
///
/// This object may contain a server-local ID, so it must stay inside the app.
/// It is never serialized into Watch Together, analytics, diagnostics, or an
/// anime-tracking request.
class LibraryEpisodeSource {
  const LibraryEpisodeSource._({
    required this.origin,
    required this.stableKey,
    required this.title,
    required this.subtitle,
    required this.episodeNumber,
    this.jellyfinItem,
    this.plexItem,
    this.localDocument,
  });

  factory LibraryEpisodeSource.device({
    required LocalMediaDocument document,
    required EpisodeReference episode,
    required String stableKey,
  }) => LibraryEpisodeSource._(
    origin: LibraryEpisodeOrigin.device,
    stableKey: stableKey,
    title: document.name,
    subtitle: [
      'Local device',
      _localDocumentContainer(document),
      _fileSizeLabel(document.size),
    ].whereType<String>().where((value) => value.isNotEmpty).join(' • '),
    episodeNumber: episode.episode,
    localDocument: document,
  );

  factory LibraryEpisodeSource.jellyfin(JellyfinMediaItem item) =>
      LibraryEpisodeSource._(
        origin: LibraryEpisodeOrigin.jellyfin,
        stableKey: 'jellyfin:${item.id}',
        title: item.displayTitle,
        subtitle: [
          'Jellyfin',
          item.seriesName,
          _qualityLabel(item.videoWidth, item.videoHeight),
          item.videoCodec?.toUpperCase(),
          item.container?.toUpperCase(),
        ].whereType<String>().where((value) => value.isNotEmpty).join(' • '),
        episodeNumber:
            libraryServerEpisodeNumber(item.episodeNumber, item.name) ?? 0,
        jellyfinItem: item,
      );

  factory LibraryEpisodeSource.plex(PlexMediaItem item) =>
      LibraryEpisodeSource._(
        origin: LibraryEpisodeOrigin.plex,
        stableKey: 'plex:${item.ratingKey}',
        title: item.displayTitle,
        subtitle: [
          'Plex',
          item.grandparentTitle ?? item.parentTitle,
          _qualityLabel(
            item.preferredPart?.videoWidth,
            item.preferredPart?.videoHeight,
          ),
          item.preferredPart?.videoCodec?.toUpperCase(),
          item.preferredPart?.container?.toUpperCase(),
        ].whereType<String>().where((value) => value.isNotEmpty).join(' • '),
        episodeNumber: libraryServerEpisodeNumber(item.index, item.title) ?? 0,
        plexItem: item,
      );

  final LibraryEpisodeOrigin origin;
  final String stableKey;
  final String title;
  final String subtitle;
  final int episodeNumber;
  final JellyfinMediaItem? jellyfinItem;
  final PlexMediaItem? plexItem;
  final LocalMediaDocument? localDocument;

  /// Stable, non-private provider identity used by the unified player.
  String get providerId => switch (origin) {
    LibraryEpisodeOrigin.device => 'library-device',
    LibraryEpisodeOrigin.jellyfin => 'library-jellyfin',
    LibraryEpisodeOrigin.plex => 'library-plex',
  };

  String get providerName => switch (origin) {
    LibraryEpisodeOrigin.device => 'Local device',
    LibraryEpisodeOrigin.jellyfin => 'Jellyfin',
    LibraryEpisodeOrigin.plex => 'Plex',
  };

  int? get videoWidth =>
      jellyfinItem?.videoWidth ?? plexItem?.preferredPart?.videoWidth;

  int? get videoHeight =>
      jellyfinItem?.videoHeight ?? plexItem?.preferredPart?.videoHeight;

  String? get videoCodec =>
      jellyfinItem?.videoCodec ?? plexItem?.preferredPart?.videoCodec;

  String? get audioCodec =>
      jellyfinItem?.audioCodec ?? plexItem?.preferredPart?.audioCodec;

  String? get container =>
      jellyfinItem?.container ??
      plexItem?.preferredPart?.container ??
      (localDocument == null ? null : _localDocumentContainer(localDocument!));

  String? get qualityLabel => _qualityLabel(videoWidth, videoHeight);

  /// Whether discovery has enough validated information to offer this item.
  /// Plex sources are hydrated before reaching this point, while Jellyfin and
  /// Android document identities are validated locally without probing media.
  bool get isPlayableCandidate {
    final document = localDocument;
    if (document != null) return isSafeLocalVideoDocument(document);
    final jellyfin = jellyfinItem;
    if (jellyfin != null) {
      return jellyfin.isPlayable &&
          RegExp(r'^[A-Za-z0-9_-]{8,160}$').hasMatch(jellyfin.id);
    }
    final plex = plexItem;
    return plex != null &&
        plex.isPlayable &&
        plex.preferredPart?.key.trim().isNotEmpty == true;
  }

  bool get supportsCompatibilityTranscode =>
      jellyfinItem != null || plexItem != null;
}

/// Returns bounded, normalized aliases used only for local library matching.
/// AniList/MAL IDs are intentionally not included or sent to the media server.
Set<String> libraryCatalogTitleKeys(EpisodeReference episode) {
  final values = libraryCatalogSearchTerms(episode);
  final result = <String>{};
  for (final bounded in values) {
    final normalized = normalizeLibraryTitle(bounded);
    if (normalized.isEmpty) continue;
    result.add(normalized);
  }
  return Set.unmodifiable(result);
}

/// The public catalog production year. Four-digit tokens inside an official
/// title (for example "2001: A Space Odyssey") are title identity, not an
/// inferred release year.
int? libraryCatalogYear(EpisodeReference episode) =>
    _boundedLibraryYear(episode.year);

List<String> libraryCatalogSearchTerms(EpisodeReference episode) {
  final values = <String?>[
    episode.title,
    episode.titleEnglish,
    episode.titleRomaji,
    ...episode.alternativeTitles,
  ];
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values.take(24)) {
    final bounded = raw?.trim();
    final normalized = bounded == null ? '' : normalizeLibraryTitle(bounded);
    if (bounded == null ||
        bounded.length < 2 ||
        bounded.length > 200 ||
        normalized.isEmpty ||
        !seen.add(bounded.toLowerCase())) {
      continue;
    }
    result.add(bounded);
    if (result.length == 8) break;
  }
  return List.unmodifiable(result);
}

/// Full aliases plus safe hierarchy bases used to locate a server-side Series
/// container. Base terms are derived only from explicit season/special syntax.
List<String> libraryCatalogHierarchySearchTerms(EpisodeReference episode) {
  final result = <String>{...libraryCatalogSearchTerms(episode)};
  final specialFormat = const {
    'SPECIAL',
    'OVA',
    'ONA',
  }.contains(episode.format?.trim().toUpperCase());
  for (final raw in libraryCatalogSearchTerms(episode)) {
    final trimmed = raw.trim();
    String? base;
    if (specialFormat) {
      base = _specialParentTitle(trimmed);
    }
    base ??= RegExp(
      r'^(.*?)(?:\s+season\s+\d{1,3}|\s+\d{1,3}(?:st|nd|rd|th)\s+season|\s+s\d{1,3}|\s+specials?)$',
      caseSensitive: false,
    ).firstMatch(trimmed)?.group(1)?.trim();
    if (base != null && base.length >= 2 && base.length <= 200) {
      result.add(base);
    }
    if (result.length >= 12) break;
  }
  return List.unmodifiable(result.take(12));
}

/// Returns the explicit parent portion of a catalog special title.
///
/// The final colon is the only safe hierarchy separator here: franchise names
/// such as `Re:ZERO` can contain earlier colons that are part of the parent
/// identity. A very short prefix is rejected rather than becoming an overly
/// broad private-library search term.
String? _specialParentTitle(String value) {
  final separators = RegExp(r'[:：]').allMatches(value).toList(growable: false);
  if (separators.isEmpty) return null;
  final prefix = value.substring(0, separators.last.start).trim();
  final normalized = normalizeLibraryTitle(prefix);
  return prefix.length >= 4 && normalized.length >= 4 ? prefix : null;
}

String normalizeLibraryTitle(String value) {
  if (value.length > 500) return '';
  return value
      .trim()
      .toLowerCase()
      .replaceAll('&', ' and ')
      .replaceAll('×', ' x ')
      // Catalogs commonly retain decorative title symbols while Jellyfin,
      // Plex, TMDb, and OMDb normalize them away. Treat those symbols as word
      // separators so titles such as "Lucky☆Star" still match "Lucky Star".
      // This remains exact token matching; it never permits substrings.
      .replaceAll(
        RegExp(r'''[\[\](){}<>:;,.!?/\\|_+\-=~`'"‘’“”★☆＊♥♡♪♫・·•—–−：]'''),
        ' ',
      )
      .replaceAll(RegExp(r'[\u200B-\u200D\u2060\uFEFF]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

enum LibraryCatalogIdMatch { unavailable, match, conflict }

/// Compares only public anime-catalog IDs understood by both sides.
/// Unknown providers are ignored and malformed IDs never become title hints.
LibraryCatalogIdMatch libraryProviderIdsMatchCatalog({
  required Map<String, String> providerIds,
  required EpisodeReference episode,
}) {
  final catalogIds = _libraryCatalogProviderIds(episode);
  var compared = false;
  var matched = false;
  for (final entry in providerIds.entries.take(40)) {
    final key = entry.key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final value = entry.value.trim();
    if (value.isEmpty || value.length > 32) continue;
    final canonicalKey = _canonicalLibraryProviderKey(key);
    if (canonicalKey == null) continue;
    final catalogValue = catalogIds[canonicalKey];
    if (catalogValue == null) continue;
    final normalizedValue = _normalizedLibraryProviderValue(
      canonicalKey,
      value,
    );
    if (normalizedValue == null) continue;
    compared = true;
    if (normalizedValue != catalogValue) {
      return LibraryCatalogIdMatch.conflict;
    }
    matched = true;
  }
  if (!compared) return LibraryCatalogIdMatch.unavailable;
  return matched ? LibraryCatalogIdMatch.match : LibraryCatalogIdMatch.conflict;
}

Map<String, String> _libraryCatalogProviderIds(EpisodeReference episode) {
  final result = <String, String>{
    if (episode.anilistMediaId > 0) 'anilist': '${episode.anilistMediaId}',
    if (episode.malMediaId case final value? when value > 0)
      'myanimelist': '$value',
  };
  for (final entry in episode.publicProviderIds.entries.take(40)) {
    final key = _canonicalLibraryProviderKey(entry.key);
    if (key == null) continue;
    final value = _normalizedLibraryProviderValue(key, entry.value);
    if (value != null) result[key] = value;
  }
  return result;
}

String? _canonicalLibraryProviderKey(String raw) {
  final key = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return switch (key) {
    'anilist' || 'anilistid' => 'anilist',
    'myanimelist' || 'myanimelistid' || 'mal' => 'myanimelist',
    'tmdb' || 'themoviedb' => 'tmdb',
    'tvdb' || 'thetvdb' => 'tvdb',
    'imdb' => 'imdb',
    _ => null,
  };
}

String? _normalizedLibraryProviderValue(String key, String raw) {
  final value = raw.trim().toLowerCase();
  if (key == 'imdb') {
    return RegExp(r'^tt\d{7,10}$').hasMatch(value) ? value : null;
  }
  if (!RegExp(r'^\d{1,12}$').hasMatch(value)) return null;
  final parsed = int.tryParse(value);
  return parsed == null || parsed <= 0 ? null : '$parsed';
}

int? libraryCatalogSeasonHint(EpisodeReference episode) =>
    _libraryTitleIdentity(episode).seasonNumber;

bool librarySeriesMatchesCatalog({
  required String? serverSeriesTitle,
  required Set<String> catalogTitleKeys,
  int? catalogYear,
  int? serverYear,
}) {
  final raw = serverSeriesTitle?.trim();
  if (raw == null || raw.isEmpty || raw.length > 500) return false;
  final effectiveCatalogYear = _boundedLibraryYear(catalogYear);
  final boundedServerYear = _boundedLibraryYear(serverYear);
  final officialTitleYears = <int>{};
  for (final title in catalogTitleKeys) {
    officialTitleYears.addAll(_libraryYearsIn(title));
  }
  final titleYears = _libraryYearsIn(raw)..removeAll(officialTitleYears);
  if (boundedServerYear != null &&
      titleYears.isNotEmpty &&
      titleYears.any((year) => year != boundedServerYear)) {
    return false;
  }
  if (effectiveCatalogYear != null &&
      ((boundedServerYear != null &&
              boundedServerYear != effectiveCatalogYear) ||
          titleYears.any((year) => year != effectiveCatalogYear))) {
    return false;
  }
  final normalizedCandidates = <String>{normalizeLibraryTitle(raw)};
  final withoutReleaseDecoration = _withoutLibrarySeriesReleaseDecoration(raw);
  if (withoutReleaseDecoration != null) {
    normalizedCandidates.add(normalizeLibraryTitle(withoutReleaseDecoration));
  }
  normalizedCandidates.removeWhere((candidate) => candidate.isEmpty);
  for (final normalized in normalizedCandidates) {
    if (catalogTitleKeys.contains(normalized)) return true;
    var withoutSuffixYears = normalized;
    for (final year in titleYears) {
      withoutSuffixYears = withoutSuffixYears.replaceAll(
        RegExp('\\b$year\\b'),
        ' ',
      );
    }
    withoutSuffixYears = withoutSuffixYears
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (withoutSuffixYears.isNotEmpty &&
        catalogTitleKeys.contains(withoutSuffixYears)) {
      return true;
    }
  }
  return false;
}

/// Some private libraries use a release-group folder as the series title,
/// such as `[Reaktor] Serial Experiments Lain`. Ignore one bounded
/// leading bracket tag, but keep the remaining title an exact catalog match.
/// This does not permit arbitrary prefix or substring matching.
String? _withoutLeadingLibraryReleaseTags(String raw) {
  final remainder = raw.trimLeft();
  if (!remainder.startsWith('[')) return null;
  final closing = remainder.indexOf(']');
  if (closing <= 1 || closing > 81) return null;
  final tag = remainder.substring(1, closing);
  if (!RegExp(r'^[^\[\]\r\n]{1,80}$').hasMatch(tag)) return null;
  final title = remainder.substring(closing + 1).trimLeft();
  return title.isEmpty ? null : title;
}

/// Removes only bounded release decoration around an otherwise exact series
/// title. This is intentionally not fuzzy matching: one leading group and
/// recognized technical groups at the end may be ignored, and `- Complete`
/// is ignored only when one of those release markers was present.
String? _withoutLibrarySeriesReleaseDecoration(String raw) {
  var title = raw.trim();
  var removedDecoration = false;
  final withoutLeading = _withoutLeadingLibraryReleaseTags(title);
  if (withoutLeading != null) {
    title = withoutLeading;
    removedDecoration = true;
  }
  for (var index = 0; index < 12; index++) {
    final trailingTag = RegExp(
      r'\s*\[([^\]\r\n]{1,80})\]\s*$',
    ).firstMatch(title);
    if (trailingTag == null || !_isLibraryReleaseTag(trailingTag.group(1)!)) {
      break;
    }
    title = title.substring(0, trailingTag.start).trimRight();
    removedDecoration = true;
  }
  if (removedDecoration) {
    final completeSuffix = RegExp(
      r'\s+(?:-|–|—|:)\s*complete\s*$',
      caseSensitive: false,
    ).firstMatch(title);
    if (completeSuffix != null) {
      title = title.substring(0, completeSuffix.start).trimRight();
    }
  }
  title = title.trim();
  return removedDecoration && title.isNotEmpty ? title : null;
}

/// Matches a playable episode's owning series. Public catalog IDs win when a
/// server supplies them; otherwise the exact normalized title is required.
/// A base-series match is accepted only when the catalog explicitly names a
/// season and the server episode carries that same season number.
bool librarySeriesMatchesEpisodeCatalog({
  required String? serverSeriesTitle,
  required EpisodeReference episode,
  int? serverSeasonNumber,
  int? serverYear,
  Map<String, String> providerIds = const {},
}) {
  final idMatch = libraryProviderIdsMatchCatalog(
    providerIds: providerIds,
    episode: episode,
  );
  if (idMatch == LibraryCatalogIdMatch.match) return true;

  final identity = _libraryTitleIdentity(episode);
  final catalogYear = libraryCatalogYear(episode);
  final fullTitleMatch = librarySeriesMatchesCatalog(
    serverSeriesTitle: serverSeriesTitle,
    catalogTitleKeys: identity.fullTitleKeys,
    catalogYear: catalogYear,
    serverYear: serverYear,
  );
  if (fullTitleMatch) {
    return idMatch != LibraryCatalogIdMatch.conflict;
  }
  final expectedSeason = identity.seasonNumber;
  // Catalogs often model a sequel/special as its own media ID while Jellyfin
  // and Plex model it as Season N/Season 0 of the parent show. In that one
  // structural case, exact base title + authoritative season is safer than a
  // parent-show ID which is expected to differ from the catalog media ID.
  return expectedSeason != null &&
      serverSeasonNumber == expectedSeason &&
      librarySeriesMatchesCatalog(
        serverSeriesTitle: serverSeriesTitle,
        catalogTitleKeys: identity.baseTitleKeys,
        // This is the parent series. Its production year is not the child
        // sequel/special catalog entry's production year.
        catalogYear: null,
        serverYear: serverYear,
      );
}

/// A Series container can be traversed before its child season is known. This
/// permits an exact full title or a safely derived base title, while playback
/// matching still requires the child episode's authoritative season number.
bool librarySeriesMayContainEpisode({
  required String? serverSeriesTitle,
  required EpisodeReference episode,
  int? serverYear,
  Map<String, String> providerIds = const {},
}) {
  final idMatch = libraryProviderIdsMatchCatalog(
    providerIds: providerIds,
    episode: episode,
  );
  if (idMatch == LibraryCatalogIdMatch.match) return true;
  final identity = _libraryTitleIdentity(episode);
  final fullTitleMatch = librarySeriesMatchesCatalog(
    serverSeriesTitle: serverSeriesTitle,
    catalogTitleKeys: identity.fullTitleKeys,
    catalogYear: libraryCatalogYear(episode),
    serverYear: serverYear,
  );
  if (fullTitleMatch) return idMatch != LibraryCatalogIdMatch.conflict;
  return (identity.seasonNumber != null &&
      librarySeriesMatchesCatalog(
        serverSeriesTitle: serverSeriesTitle,
        catalogTitleKeys: identity.baseTitleKeys,
        catalogYear: null,
        serverYear: serverYear,
      ));
}

class _LibraryTitleIdentity {
  const _LibraryTitleIdentity({
    required this.fullTitleKeys,
    required this.baseTitleKeys,
    required this.seasonNumber,
  });

  final Set<String> fullTitleKeys;
  final Set<String> baseTitleKeys;
  final int? seasonNumber;
}

_LibraryTitleIdentity _libraryTitleIdentity(EpisodeReference episode) {
  final full = libraryCatalogTitleKeys(episode);
  final base = <String>{};
  final seasonNumbers = <int>{};
  for (final title in full) {
    final parsed = _stripExplicitSeasonSuffix(title);
    if (parsed == null || parsed.$1.length < 2) continue;
    base.add(parsed.$1);
    seasonNumbers.add(parsed.$2);
  }
  if (const {
    'SPECIAL',
    'OVA',
    'ONA',
  }.contains(episode.format?.trim().toUpperCase())) {
    for (final raw in libraryCatalogSearchTerms(episode)) {
      final parent = _specialParentTitle(raw);
      if (parent == null) continue;
      final prefix = normalizeLibraryTitle(parent);
      if (prefix.length >= 2) base.add(prefix);
    }
    if (base.isNotEmpty) seasonNumbers.add(0);
  }
  // Conflicting aliases (for example a bad synonym naming another season)
  // cannot safely authorize base-series matching.
  final season = seasonNumbers.length == 1 ? seasonNumbers.single : null;
  return _LibraryTitleIdentity(
    fullTitleKeys: full,
    baseTitleKeys: season == null ? const {} : Set.unmodifiable(base),
    seasonNumber: season,
  );
}

(String, int)? _stripExplicitSeasonSuffix(String normalizedTitle) {
  final patterns = <RegExp>[
    RegExp(r'^(.*?) season (\d{1,3})$'),
    RegExp(r'^(.*?) (\d{1,3})(?:st|nd|rd|th) season$'),
    RegExp(r'^(.*?) s(\d{1,3})$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(normalizedTitle);
    if (match == null) continue;
    final number = int.tryParse(match.group(2)!);
    if (number != null && number >= 0 && number <= 1000) {
      return (match.group(1)!.trim(), number);
    }
  }
  final wordMatch = RegExp(
    r'^(.*?) (?:(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth) season|season (one|two|three|four|five|six|seven|eight|nine|ten))$',
  ).firstMatch(normalizedTitle);
  if (wordMatch != null) {
    final word = wordMatch.group(2) ?? wordMatch.group(3)!;
    final number = const {
      'first': 1,
      'one': 1,
      'second': 2,
      'two': 2,
      'third': 3,
      'three': 3,
      'fourth': 4,
      'four': 4,
      'fifth': 5,
      'five': 5,
      'sixth': 6,
      'six': 6,
      'seventh': 7,
      'seven': 7,
      'eighth': 8,
      'eight': 8,
      'ninth': 9,
      'nine': 9,
      'tenth': 10,
      'ten': 10,
    }[word]!;
    return (wordMatch.group(1)!.trim(), number);
  }
  final special = RegExp(
    r'^(.*?) (?:specials?|ovas?|onas?|oads?)$',
  ).firstMatch(normalizedTitle);
  return special == null ? null : (special.group(1)!.trim(), 0);
}

/// Returns a server's authoritative episode number, or one unambiguous
/// explicit fallback such as `Episode 05`/`E05` when the server omitted it.
/// Bare numbers and conflicting tokens deliberately remain unknown.
int? libraryServerEpisodeNumber(int? authoritativeNumber, String title) {
  if (authoritativeNumber != null) {
    return authoritativeNumber > 0 && authoritativeNumber <= 100000
        ? authoritativeNumber
        : null;
  }
  if (title.length > 500) return null;
  final numbers = _explicitLibraryEpisodeNumbers(normalizeLibraryTitle(title));
  return numbers.length == 1 ? numbers.single : null;
}

bool jellyfinItemMatchesEpisode({
  required JellyfinMediaItem item,
  required EpisodeReference episode,
}) {
  if (item.type == 'Episode') {
    return _serverEpisodeOrdinalMatches(
          authoritativeNumber: item.episodeNumber,
          serverEpisodeTitle: item.name,
          episode: episode,
        ) &&
        librarySeriesMatchesEpisodeCatalog(
          serverSeriesTitle: item.seriesName,
          episode: episode,
          serverSeasonNumber: item.seasonNumber,
          serverYear:
              item.seriesProductionYear ??
              (item.productionYear == libraryCatalogYear(episode)
                  ? item.productionYear
                  : null),
          providerIds: item.seriesProviderIds,
        );
  }
  if (item.type == 'Video' && episode.format?.trim().toUpperCase() != 'MOVIE') {
    final idMatch = libraryProviderIdsMatchCatalog(
      providerIds: item.providerIds,
      episode: episode,
    );
    if (idMatch == LibraryCatalogIdMatch.conflict) return false;
    if (idMatch == LibraryCatalogIdMatch.match &&
        item.episodeNumber == episode.episode) {
      return true;
    }
    return _serverEpisodeTitleMatchesCatalog(item.name, episode);
  }
  return episode.episode == 1 &&
      const {'Movie', 'Video'}.contains(item.type) &&
      librarySeriesMatchesEpisodeCatalog(
        serverSeriesTitle: item.name,
        episode: episode,
        serverYear: item.productionYear,
        providerIds: item.providerIds,
      );
}

bool plexItemMatchesEpisode({
  required PlexMediaItem item,
  required EpisodeReference episode,
}) {
  if (item.type == PlexMediaType.episode) {
    return _serverEpisodeOrdinalMatches(
          authoritativeNumber: item.index,
          serverEpisodeTitle: item.title,
          episode: episode,
        ) &&
        librarySeriesMatchesEpisodeCatalog(
          serverSeriesTitle: item.grandparentTitle,
          episode: episode,
          serverSeasonNumber: item.parentIndex,
          serverYear:
              item.seriesYear ??
              (item.year == libraryCatalogYear(episode) ? item.year : null),
          providerIds: item.seriesProviderIds,
        );
  }
  return episode.episode == 1 &&
      item.type == PlexMediaType.movie &&
      librarySeriesMatchesEpisodeCatalog(
        serverSeriesTitle: item.title,
        episode: episode,
        serverYear: item.year,
        providerIds: item.providerIds,
      );
}

bool _serverEpisodeOrdinalMatches({
  required int? authoritativeNumber,
  required String serverEpisodeTitle,
  required EpisodeReference episode,
}) {
  // Jellyfin/Plex IndexNumber is authoritative. Never let a filename-like
  // title override a conflicting server episode index.
  if (authoritativeNumber != null) {
    return authoritativeNumber == episode.episode;
  }
  return _episodeNumberMatchesRemainder(
    normalizeLibraryTitle(serverEpisodeTitle),
    episode.episode,
    allowBare: false,
  );
}

bool _serverEpisodeTitleMatchesCatalog(
  String serverEpisodeTitle,
  EpisodeReference episode,
) {
  if (serverEpisodeTitle.length > 500) return false;
  final normalized = normalizeLibraryTitle(serverEpisodeTitle);
  final titleMatch = _catalogTitleMatchInText(normalized, episode);
  if (titleMatch == null) return false;
  return _episodeNumberMatchesRemainder(
    _removeMatchedTitle(normalized, titleMatch.alias),
    episode.episode,
  );
}

/// Returns only library candidates whose public identity is unambiguous
/// enough for hands-free playback. All matching candidates remain available
/// to the manual picker; this merely prevents result arrival order from
/// choosing between remakes or different local seasons.
List<LibraryEpisodeSource> unambiguousLibraryAutoPickSources({
  required Iterable<LibraryEpisodeSource> sources,
  required EpisodeReference episode,
}) {
  var candidates = sources
      .where((source) => librarySourceMatchesEpisode(source, episode))
      .toList(growable: false);
  final catalogYear = libraryCatalogYear(episode);
  if (catalogYear != null) {
    final exactYear = candidates
        .where(
          (source) =>
              librarySourceYear(source, episode: episode) == catalogYear,
        )
        .toList(growable: false);
    // A yearless exact title remains available for manual selection, but it
    // cannot safely identify one catalog remake hands-free. If an exact-year
    // candidate exists, keep only those; otherwise fail closed for Auto Pick.
    if (exactYear.isEmpty) return const [];
    candidates = exactYear;
  }
  if (candidates.length <= 1) return List.unmodifiable(candidates);
  // Even matching season/year metadata does not establish a viewer preference
  // between two private servers or files. Keep every remaining choice visible
  // manually and never let async arrival order pick one hands-free.
  return const [];
}

bool librarySourceMatchesEpisode(
  LibraryEpisodeSource source,
  EpisodeReference episode,
) {
  if (source.stableKey.isEmpty || source.episodeNumber != episode.episode) {
    return false;
  }
  final document = source.localDocument;
  if (document != null) {
    return localDocumentMatchesEpisode(document: document, episode: episode);
  }
  final jellyfin = source.jellyfinItem;
  if (jellyfin != null) {
    return jellyfinItemMatchesEpisode(item: jellyfin, episode: episode);
  }
  final plex = source.plexItem;
  return plex != null && plexItemMatchesEpisode(item: plex, episode: episode);
}

int? librarySourceYear(
  LibraryEpisodeSource source, {
  EpisodeReference? episode,
}) {
  final officialTitleYears = episode == null
      ? const <int>{}
      : _libraryCatalogTitleTokenYears(episode);
  int? titleYear(Iterable<String> values) {
    final years = <int>{};
    for (final value in values) {
      years.addAll(_libraryYearsIn(value));
    }
    years.removeAll(officialTitleYears);
    return years.length == 1 ? years.single : null;
  }

  final jellyfin = source.jellyfinItem;
  if (jellyfin != null) {
    if (jellyfin.type == 'Episode') {
      return _boundedLibraryYear(jellyfin.seriesProductionYear) ??
          titleYear([if (jellyfin.seriesName != null) jellyfin.seriesName!]);
    }
    return _boundedLibraryYear(jellyfin.productionYear) ??
        titleYear([jellyfin.name]);
  }
  final plex = source.plexItem;
  if (plex != null) {
    if (plex.type == PlexMediaType.episode) {
      return _boundedLibraryYear(plex.seriesYear) ??
          titleYear([
            if (plex.grandparentTitle != null) plex.grandparentTitle!,
          ]);
    }
    return _boundedLibraryYear(plex.year) ?? titleYear([plex.title]);
  }
  // Device filenames frequently contain four-digit resolution/build tokens;
  // Ignore dimensions such as 1920x1080, but retain standalone year tags so
  // an explicitly named remake cannot be selected hands-free as another.
  final document = source.localDocument;
  if (document == null) return null;
  final years = _libraryFilenameYearsIn(document.name)
    ..removeAll(officialTitleYears);
  return years.length == 1 ? years.single : null;
}

int? librarySourceSeasonNumber(LibraryEpisodeSource source) {
  final jellyfinSeason = source.jellyfinItem?.seasonNumber;
  if (jellyfinSeason != null && jellyfinSeason >= 0 && jellyfinSeason <= 1000) {
    return jellyfinSeason;
  }
  final plexSeason = source.plexItem?.parentIndex;
  if (plexSeason != null && plexSeason >= 0 && plexSeason <= 1000) {
    return plexSeason;
  }
  final name = source.localDocument?.name;
  if (name == null || name.length > 500) return null;
  final match = RegExp(
    r'(?:^|[^A-Za-z0-9])s(\d{1,3})[ ._-]*e\d+',
    caseSensitive: false,
  ).firstMatch(name);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Conservatively recognizes a recently granted device file as this episode.
///
/// A full catalog alias and an exact episode token must both be present. This
/// deliberately fails closed for vague filenames so an unrelated local video
/// is never offered just because it was opened recently.
class _LibraryTextTitleMatch {
  const _LibraryTextTitleMatch(this.alias);

  final String alias;
}

_LibraryTextTitleMatch? _catalogTitleMatchInText(
  String normalizedText,
  EpisodeReference episode,
) {
  bool contains(String alias) => ' $normalizedText '.contains(' $alias ');
  final identity = _libraryTitleIdentity(episode);
  final fullMatches =
      identity.fullTitleKeys
          .where((alias) => alias.length >= 2 && contains(alias))
          .toList(growable: false)
        ..sort((left, right) => right.length.compareTo(left.length));
  if (fullMatches.isNotEmpty) return _LibraryTextTitleMatch(fullMatches.first);

  final expectedSeason = identity.seasonNumber;
  if (expectedSeason == null) return null;
  final seasons = _explicitSeasonNumbersInText(normalizedText);
  if (seasons.length != 1 || seasons.single != expectedSeason) return null;
  final baseMatches =
      identity.baseTitleKeys
          .where((alias) => alias.length >= 2 && contains(alias))
          .toList(growable: false)
        ..sort((left, right) => right.length.compareTo(left.length));
  return baseMatches.isEmpty ? null : _LibraryTextTitleMatch(baseMatches.first);
}

Set<int> _explicitSeasonNumbersInText(String normalizedText) {
  final result = <int>{};
  for (final pattern in [
    RegExp(r'(?:^|\s)s0*(\d{1,3})e\d+(?=$|\s)'),
    RegExp(r'(?:^|\s)season 0*(\d{1,3})(?=$|\s)'),
  ]) {
    for (final match in pattern.allMatches(normalizedText)) {
      final value = int.tryParse(match.group(1)!);
      if (value != null && value <= 1000) result.add(value);
    }
  }
  return result;
}

String _removeMatchedTitle(String normalizedText, String alias) =>
    (' $normalizedText '.replaceFirst(
      ' $alias ',
      ' ',
    )).replaceAll(RegExp(r'\s+'), ' ').trim();

bool _episodeNumberMatchesRemainder(
  String remainder,
  int number, {
  bool allowBare = true,
}) {
  if (number <= 0 || number > 100000) return false;
  final escaped = RegExp.escape('$number');
  final explicitEpisodes = _explicitLibraryEpisodeNumbers(remainder);
  if (explicitEpisodes.isNotEmpty) {
    return explicitEpisodes.length == 1 && explicitEpisodes.single == number;
  }
  if (!allowBare) return false;
  return RegExp(
    '(?:^|[\\s._\\-\\[\\]()])0*$escaped(?:v\\d+)?'
    '(?=\$|[\\s._\\-\\[\\]()])',
    caseSensitive: false,
  ).hasMatch(remainder);
}

Set<int> _explicitLibraryEpisodeNumbers(String value) {
  final explicitEpisodes = <int>{};
  for (final pattern in [
    RegExp(
      r'(?:^|[^A-Za-z0-9])s\d{1,3}[ ._-]*e0*(\d{1,6})(?:v\d+)?(?=$|[^0-9])',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:^|[^A-Za-z0-9])(?:ep(?:isode)?|e)[ ._-]*0*(\d{1,6})(?:v\d+)?(?=$|[^0-9])',
      caseSensitive: false,
    ),
  ]) {
    for (final match in pattern.allMatches(value)) {
      final parsed = int.tryParse(match.group(1)!);
      if (parsed != null && parsed > 0 && parsed <= 100000) {
        explicitEpisodes.add(parsed);
      }
    }
  }
  return explicitEpisodes;
}

bool localDocumentMatchesEpisode({
  required LocalMediaDocument document,
  required EpisodeReference episode,
}) {
  final name = document.name.trim();
  if (!isSafeLocalVideoDocument(document) || name.length > 500) {
    return false;
  }
  final stem = name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '');
  var identityStem = stem.replaceFirst(
    RegExp(r'^\s*\[[^\]\r\n]{1,80}\]\s*'),
    '',
  );
  // Release names commonly end in several independent technical groups, for
  // example `[1080p][x265 10bit][Dual-Audio]`. Remove only bounded groups at
  // the very end so brackets which are part of the actual title stay intact.
  for (var index = 0; index < 12; index++) {
    final trailingTag = RegExp(
      r'\s*\[([^\]\r\n]{1,80})\]\s*$',
    ).firstMatch(identityStem);
    if (trailingTag == null || !_isLibraryReleaseTag(trailingTag.group(1)!)) {
      break;
    }
    identityStem = identityStem.substring(0, trailingTag.start);
  }
  final normalized = normalizeLibraryTitle(identityStem);
  if (normalized.isEmpty) return false;
  final titleMatch = _catalogTitleMatchInText(normalized, episode);
  if (titleMatch == null) return false;
  final catalogYear = libraryCatalogYear(episode);
  final filenameYears = _libraryFilenameYearsIn(stem)
    ..removeAll(_libraryCatalogTitleTokenYears(episode));
  if (catalogYear != null && filenameYears.any((year) => year != catalogYear)) {
    return false;
  }
  final number = episode.episode;
  final episodeSearchText = _removeMatchedTitle(normalized, titleMatch.alias);
  if (number == 1 && episode.format?.trim().toUpperCase() == 'MOVIE') {
    var movieRemainder = episodeSearchText;
    if (catalogYear != null) {
      movieRemainder = movieRemainder
          .replaceAll(RegExp('\\b$catalogYear\\b'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    if (movieRemainder.isEmpty) return true;
  }
  if (_localRemainderHasUnexpectedWords(episodeSearchText)) return false;
  return _episodeNumberMatchesRemainder(episodeSearchText, number);
}

bool _isLibraryReleaseTag(String rawTag) {
  final normalized = rawTag
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9+]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAllMapped(
        RegExp(r'\b(\d{1,2})\s+bit\b'),
        (match) => '${match.group(1)}bit',
      );
  if (normalized.isEmpty) return false;
  if (RegExp(r'^[0-9a-f]{8}$').hasMatch(normalized)) return true;
  const knownTokens = {
    'aac',
    'ac3',
    'audio',
    'av1',
    'avc',
    'bd',
    'bdrip',
    'bluray',
    'dub',
    'dubbed',
    'dual',
    'eac3',
    'eng',
    'english',
    'flac',
    'h264',
    'h265',
    'hdr',
    'hevc',
    'hi10p',
    'hardsub',
    'jpn',
    'multi',
    'opus',
    'remux',
    'softsub',
    'sub',
    'subbed',
    'truehd',
    'web',
    'webdl',
    'webrip',
    'x264',
    'x265',
  };
  final tokens = normalized.split(' ');
  return tokens.every(
    (token) =>
        knownTokens.contains(token) ||
        RegExp(
          r'^(?:4k|\d{3,4}p|\d{3,4}x\d{3,4}|\d{1,2}bit|v\d{1,3})$',
        ).hasMatch(token),
  );
}

bool _localRemainderHasUnexpectedWords(String remainder) {
  const allowed = {
    'episode',
    'ep',
    'season',
    'special',
    'ova',
    'ona',
    'bd',
    'bluray',
    'web',
    'webrip',
    'webdl',
    'remux',
    'dub',
    'dubbed',
    'sub',
    'subbed',
    'dual',
    'audio',
    'bit',
    'hi10p',
    'x264',
    'x265',
    'h264',
    'h265',
    'hdr',
    'hevc',
    'avc',
    'aac',
    'flac',
    'opus',
  };
  return RegExp(
    r'\b[a-z]{2,}\b',
  ).allMatches(remainder).any((match) => !allowed.contains(match.group(0)));
}

int? _boundedLibraryYear(int? value) =>
    value != null && value >= 1900 && value <= 2099 ? value : null;

Set<int> _libraryYearsIn(String value) {
  if (value.length > 500) return const {};
  return RegExp(
    r'\b(?:19|20)\d{2}\b',
  ).allMatches(value).map((match) => int.parse(match.group(0)!)).toSet();
}

Set<int> _libraryFilenameYearsIn(String value) {
  if (value.length > 500) return const {};
  return RegExp(
    r'\b(?:19|20)\d{2}\b(?![xX]\d)',
  ).allMatches(value).map((match) => int.parse(match.group(0)!)).toSet();
}

Set<int> _libraryCatalogTitleTokenYears(EpisodeReference episode) {
  final years = <int>{};
  for (final title in libraryCatalogSearchTerms(episode)) {
    years.addAll(_libraryYearsIn(title));
  }
  return years;
}

/// Validates a single user-granted Android document without opening it.
///
/// This deliberately accepts only bounded provider-backed `content://`
/// identities and recognizable video metadata. It never turns a filename
/// into a filesystem path and never broadens the Storage Access Framework
/// permission granted by the viewer.
bool isSafeLocalVideoDocument(
  LocalMediaDocument document, {
  bool requirePersistedPermission = false,
}) {
  final uri = document.uri;
  final serializedUri = uri.toString();
  if (requirePersistedPermission && !document.persistedReadPermission) {
    return false;
  }
  if (serializedUri.isEmpty ||
      serializedUri.length > 2048 ||
      uri.scheme != 'content' ||
      !uri.hasAuthority ||
      uri.authority.trim().isEmpty ||
      uri.authority.length > 255 ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  final name = document.name.trim();
  if (name.isEmpty ||
      name.length > 300 ||
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(name)) {
    return false;
  }
  final mime = document.mimeType?.trim().toLowerCase();
  if (mime != null &&
      (mime.isEmpty ||
          mime.length > 128 ||
          !RegExp(
            r'^[a-z0-9!#$&^_.+\-]+/[a-z0-9!#$&^_.+\-]+$',
          ).hasMatch(mime))) {
    return false;
  }
  final size = document.size;
  if (size != null && (size < 0 || size > (1 << 60))) return false;
  return _looksLikeVideo(document);
}

bool _looksLikeVideo(LocalMediaDocument document) {
  final mime = document.mimeType?.trim().toLowerCase();
  if (mime?.startsWith('video/') == true) return true;
  if (const {
    'application/x-matroska',
    'application/vnd.apple.mpegurl',
    'application/mpegurl',
    'application/x-mpegurl',
  }.contains(mime)) {
    return true;
  }
  return RegExp(
    r'\.(?:mkv|mp4|m4v|webm|avi|mov|ts|m2ts)$',
    caseSensitive: false,
  ).hasMatch(document.name);
}

String? _qualityLabel(int? width, int? height) {
  if (height != null && height > 0) return '${height}p';
  if (width == null || width <= 0) return null;
  if (width >= 3800) return '2160p';
  if (width >= 2500) return '1440p';
  if (width >= 1800) return '1080p';
  if (width >= 1200) return '720p';
  return null;
}

String? _fileSizeLabel(int? bytes) {
  if (bytes == null || bytes <= 0) return null;
  const gibibyte = 1024 * 1024 * 1024;
  const mebibyte = 1024 * 1024;
  if (bytes >= gibibyte) {
    return '${(bytes / gibibyte).toStringAsFixed(1)} GB';
  }
  if (bytes >= mebibyte) return '${(bytes / mebibyte).round()} MB';
  return null;
}

String? _localDocumentContainer(LocalMediaDocument document) {
  final mime = document.mimeType?.trim().toLowerCase();
  const mimeLabels = {
    'video/x-matroska': 'MKV',
    'application/x-matroska': 'MKV',
    'video/mp4': 'MP4',
    'video/webm': 'WEBM',
    'video/x-msvideo': 'AVI',
    'application/vnd.apple.mpegurl': 'HLS',
    'application/x-mpegurl': 'HLS',
  };
  final fromMime = mimeLabels[mime];
  if (fromMime != null) return fromMime;
  final extension = RegExp(
    r'\.([A-Za-z0-9]{2,5})$',
  ).firstMatch(document.name)?.group(1)?.toUpperCase();
  return extension ?? document.mimeType;
}
