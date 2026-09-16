import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

/// The strongest conclusion TetoTV can draw from bounded, public source
/// metadata before handing a stream to the player.
enum EpisodeIdentityVerdict { match, mismatch, unknown }

/// A privacy-safe episode identity result.
///
/// Labels and filenames are deliberately not retained. Diagnostics can record
/// [reasonCode] without leaking a release name, media URL, or private-library
/// filename.
class EpisodeIdentityAssessment {
  const EpisodeIdentityAssessment(this.verdict, this.reasonCode);

  final EpisodeIdentityVerdict verdict;
  final String reasonCode;

  bool get isMatch => verdict == EpisodeIdentityVerdict.match;
  bool get isMismatch => verdict == EpisodeIdentityVerdict.mismatch;

  /// Whether the label identifies one episode rather than merely a batch or
  /// multi-episode video that happens to contain it.
  bool get isExactMatch =>
      isMatch &&
      reasonCode != 'episode_range_match' &&
      reasonCode != 'absolute_episode_range_match';
}

/// A confirmed mismatch is candidate-specific and can safely advance normal
/// source failover. Strict torrent file selection also uses the subclass below
/// when identity evidence is missing or ambiguous.
class EpisodeIdentityMismatchException implements Exception {
  const EpisodeIdentityMismatchException({required this.reasonCode});

  final String reasonCode;

  @override
  String toString() =>
      'This source identifies a different episode. TetoTV skipped it and '
      'will try another source.';
}

/// The torrent may contain the requested episode, but its file metadata does
/// not prove which playable file is that episode.
///
/// This extends [EpisodeIdentityMismatchException] so existing candidate
/// failover paths also skip ambiguous torrents. The distinct reason code and
/// message keep diagnostics and manual-source errors accurate.
class EpisodeIdentityAmbiguousException
    extends EpisodeIdentityMismatchException {
  const EpisodeIdentityAmbiguousException({required super.reasonCode});

  @override
  String toString() =>
      'TetoTV could not prove which torrent file is the requested episode. '
      'It skipped this source to avoid playing the wrong episode.';
}

/// Extracts an explicit season number from a catalog title when one exists.
///
/// A missing marker is intentionally not interpreted as season one: many
/// anime titles use sequel names rather than numbered seasons.
int? catalogSeasonNumber(EpisodeReference episode) {
  for (final value in <String?>[
    episode.title,
    episode.titleEnglish,
    episode.titleRomaji,
    episode.titleNative,
    ...episode.alternativeTitles,
  ]) {
    final season = _explicitSeasonNumber(value ?? '');
    if (season != null) return season;
  }
  if (episodeReferenceIsSpecial(episode)) return 0;
  return null;
}

/// Returns an authoritative absolute episode number only when the catalog or
/// provider supplied a positive season offset. Never infer this from sequel
/// titles or relation counts: split cours and specials make that unsafe.
int? absoluteEpisodeNumber(EpisodeReference episode) {
  final offset = episode.absoluteSeasonOffset;
  if (offset == null || offset <= 0 || episode.episode <= 0) return null;
  final absolute = offset + episode.episode;
  return absolute <= 100000 ? absolute : null;
}

bool episodeReferenceIsSpecial(EpisodeReference episode) {
  final format = episode.format?.trim().toUpperCase();
  return const {'SPECIAL', 'OVA', 'ONA', 'MUSIC'}.contains(format);
}

/// True when catalog titles identify a later installment but do not supply a
/// numeric season or authoritative absolute offset. Bare file numbers are
/// unsafe in this case because releases may restart at 1 or keep counting.
bool episodeReferenceHasUnresolvedSequelNumbering(EpisodeReference episode) {
  if (catalogSeasonNumber(episode) != null ||
      absoluteEpisodeNumber(episode) != null) {
    return false;
  }
  return <String?>[
    episode.title,
    episode.titleEnglish,
    episode.titleRomaji,
    episode.titleNative,
    ...episode.alternativeTitles,
  ].any((value) => _hasUnresolvedSequelHint(value ?? ''));
}

bool torrentContainerScopesRequestedSeason(
  String label,
  int? requestedSeason,
) => requestedSeason != null && _explicitSeasonNumber(label) == requestedSeason;

/// Classifies a release label or resolved filename without guessing.
///
/// Recognized evidence includes SxxExx, `2x10`, Episode/EP/E forms, common
/// anime release suffixes (`Show - 10`) and bounded batch ranges. Numeric
/// boundaries prevent episode 1 from matching 10. Technical tokens such as
/// 1080p, 10-bit, years, and CRCs are not treated as episode evidence.
EpisodeIdentityAssessment assessEpisodeIdentityLabel({
  required String label,
  required int requestedEpisode,
  int? requestedSeason,
  int? requestedAbsoluteEpisode,
  bool requestedSpecial = false,
  bool allowSeasonRelativeBare = false,
  bool requireNumberingSchemeEvidence = false,
}) {
  if (requestedEpisode <= 0 || label.trim().isEmpty) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.unknown,
      'episode_identity_absent',
    );
  }

  final spans = _episodeSpans(label);
  final labelSeason = _explicitSeasonNumber(label);
  if (requestedSeason != null &&
      labelSeason != null &&
      requestedSeason != labelSeason &&
      spans.isEmpty) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.mismatch,
      'season_number_mismatch',
    );
  }
  if (spans.isEmpty) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.unknown,
      'episode_identity_absent',
    );
  }

  var episodeWasPresentInDifferentSeason = false;
  var specialWasPresentForRegularEpisode = false;
  var bareNumberingWasAmbiguous = false;
  final matching = <_EpisodeSpan>[];
  var matchedAbsolute = false;
  for (final span in spans) {
    if (span.isSpecial && !requestedSpecial) {
      if (span.contains(requestedEpisode)) {
        specialWasPresentForRegularEpisode = true;
      }
      continue;
    }
    final observedSeason = span.season ?? labelSeason;
    if (requestedSeason != null &&
        observedSeason != null &&
        observedSeason != requestedSeason) {
      if (span.contains(requestedEpisode) ||
          (requestedAbsoluteEpisode != null &&
              span.contains(requestedAbsoluteEpisode))) {
        episodeWasPresentInDifferentSeason = true;
      }
      continue;
    }

    final isBare = observedSeason == null;
    final absoluteEpisode = requestedAbsoluteEpisode;
    if (isBare && absoluteEpisode == null && requireNumberingSchemeEvidence) {
      bareNumberingWasAmbiguous = true;
      continue;
    }
    if (isBare &&
        absoluteEpisode != null &&
        absoluteEpisode != requestedEpisode) {
      if (span.contains(absoluteEpisode)) {
        matching.add(span);
        matchedAbsolute = true;
      } else if (span.contains(requestedEpisode)) {
        if (allowSeasonRelativeBare) {
          matching.add(span);
        } else {
          bareNumberingWasAmbiguous = true;
        }
      }
      continue;
    }
    final laterSeasonBare =
        isBare && requestedSeason != null && requestedSeason > 1;
    if (laterSeasonBare) {
      if (requestedAbsoluteEpisode == null) {
        if (allowSeasonRelativeBare && span.contains(requestedEpisode)) {
          matching.add(span);
        } else {
          bareNumberingWasAmbiguous = true;
        }
        continue;
      }
      if (span.contains(requestedEpisode)) {
        if (allowSeasonRelativeBare) {
          matching.add(span);
        } else {
          bareNumberingWasAmbiguous = true;
        }
      }
      continue;
    }

    if (span.contains(requestedEpisode)) matching.add(span);
  }

  if (matching.isNotEmpty) {
    final hasMultipleEpisodeIdentities = spans.any(
      (span) => !matching.any(
        (matched) =>
            matched.first == span.first &&
            matched.last == span.last &&
            matched.season == span.season &&
            matched.isSpecial == span.isSpecial,
      ),
    );
    final isRange =
        matching.any((span) => span.isRange) || hasMultipleEpisodeIdentities;
    return EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.match,
      matchedAbsolute
          ? isRange
                ? 'absolute_episode_range_match'
                : 'absolute_episode_number_match'
          : isRange
          ? 'episode_range_match'
          : 'episode_number_match',
    );
  }

  if (bareNumberingWasAmbiguous) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.unknown,
      'season_local_or_absolute_ambiguous',
    );
  }

  return EpisodeIdentityAssessment(
    EpisodeIdentityVerdict.mismatch,
    episodeWasPresentInDifferentSeason
        ? 'season_number_mismatch'
        : specialWasPresentForRegularEpisode
        ? 'special_episode_mismatch'
        : 'episode_number_mismatch',
  );
}

/// Validates explicit provider fields. Unlike a free-form stream label, these
/// values came from the title/episode records the provider selected, so a
/// disagreement is strong enough to exclude the source.
EpisodeIdentityAssessment assessExplicitProviderEpisodeIdentity({
  required EpisodeReference episode,
  int? episodeNumber,
  int? seasonNumber,
  String? seriesTitle,
}) {
  if (episodeNumber != null && episodeNumber != episode.episode) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.mismatch,
      'explicit_episode_mismatch',
    );
  }
  final requestedSeason = catalogSeasonNumber(episode);
  if (requestedSeason != null &&
      seasonNumber != null &&
      requestedSeason != seasonNumber) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.mismatch,
      'explicit_season_mismatch',
    );
  }
  final providerTitle = seriesTitle ?? '';
  final title = _comparableSeriesTitleKey(providerTitle);
  var titleMatched = false;
  if (title.isNotEmpty) {
    final aliases =
        <String?>[
              episode.title,
              episode.titleEnglish,
              episode.titleRomaji,
              episode.titleNative,
              ...episode.alternativeTitles,
            ]
            .map((value) => _comparableSeriesTitleKey(value ?? ''))
            .where((key) => key.isNotEmpty)
            .toList(growable: false);
    titleMatched = aliases.any((alias) => alias == title);
    if (!titleMatched &&
        aliases.isNotEmpty &&
        aliases.every(
          (alias) => _seriesTitlesAreClearlyDifferent(alias, title),
        )) {
      return const EpisodeIdentityAssessment(
        EpisodeIdentityVerdict.mismatch,
        'explicit_series_mismatch',
      );
    }
  }
  // A matching title or season can rule out the wrong series/season, but it
  // cannot prove which episode the provider resolved. Only an explicit,
  // matching episode number is strong enough to bypass a misleading server
  // label such as "Server - 1".
  if (episodeNumber != null) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.match,
      'explicit_episode_identity_match',
    );
  }
  return const EpisodeIdentityAssessment(
    EpisodeIdentityVerdict.unknown,
    'episode_identity_absent',
  );
}

/// Checks the most specific playback evidence first. A resolved filename can
/// overrule a broad batch release label; an unknown filename falls back to the
/// selected release's label.
EpisodeIdentityAssessment assessPlaybackEpisodeIdentity({
  required EpisodeReference episode,
  required StreamReady stream,
  required ReleaseCandidate release,
}) {
  final strictTorrentFile =
      stream.isDirectTorrent || stream.debridService != null;
  final providerIdentity = stream.providerEpisodeIdentity;
  EpisodeIdentityAssessment? explicitProviderAssessment;
  if (providerIdentity != null) {
    explicitProviderAssessment = assessExplicitProviderEpisodeIdentity(
      episode: episode,
      episodeNumber: providerIdentity.episodeNumber,
      seasonNumber: providerIdentity.seasonNumber,
      seriesTitle: providerIdentity.seriesTitle,
    );
    if (explicitProviderAssessment.isMismatch) {
      return explicitProviderAssessment;
    }
    if (!strictTorrentFile &&
        explicitProviderAssessment.verdict != EpisodeIdentityVerdict.unknown) {
      return explicitProviderAssessment;
    }
  }
  final season = catalogSeasonNumber(episode);
  final absoluteEpisode = absoluteEpisodeNumber(episode);
  final special = episodeReferenceIsSpecial(episode);
  final resolved = assessEpisodeIdentityLabel(
    label: stream.displayName,
    requestedEpisode: episode.episode,
    requestedSeason: season,
    requestedAbsoluteEpisode: absoluteEpisode,
    requestedSpecial: special,
    allowSeasonRelativeBare: torrentContainerScopesRequestedSeason(
      release.releaseName,
      season,
    ),
  );
  if (resolved.verdict != EpisodeIdentityVerdict.unknown) return resolved;
  // The concrete torrent/debrid selectors prove the file before producing a
  // StreamReady. Keep the route-level guard tolerant of opaque CDN display
  // names, while still allowing a contradictory resolved filename to veto an
  // otherwise trusted provider identity or broad release label.
  if (explicitProviderAssessment?.isMatch == true) {
    return explicitProviderAssessment!;
  }
  return assessEpisodeIdentityLabel(
    label: release.releaseName,
    requestedEpisode: episode.episode,
    requestedSeason: season,
    requestedAbsoluteEpisode: absoluteEpisode,
    requestedSpecial: special,
  );
}

bool playbackEpisodeIdentityIsCompatible({
  required EpisodeReference episode,
  required StreamReady stream,
  required ReleaseCandidate release,
}) {
  final assessment = assessPlaybackEpisodeIdentity(
    episode: episode,
    stream: stream,
    release: release,
  );
  return !assessment.isMismatch;
}

void verifyPlaybackEpisodeIdentity({
  required EpisodeReference episode,
  required StreamReady stream,
  required ReleaseCandidate release,
}) {
  final assessment = assessPlaybackEpisodeIdentity(
    episode: episode,
    stream: stream,
    release: release,
  );
  if (assessment.isMismatch) {
    throw EpisodeIdentityMismatchException(reasonCode: assessment.reasonCode);
  }
}

/// Selects one playable file only when its name proves the requested episode.
///
/// A provider file index is a tie-breaker between files that independently
/// prove the same episode; it is never identity evidence by itself. Batch
/// ranges and opaque filenames fail closed because starting either video may
/// begin at a different episode.
int selectEpisodeFileIndex({
  required List<String> labels,
  required List<bool> playable,
  required List<int> sizes,
  required int requestedEpisode,
  int? requestedSeason,
  int? requestedAbsoluteEpisode,
  bool requestedSpecial = false,
  String? containerLabel,
  bool requireNumberingSchemeEvidence = false,
  int? preferredFileIndex,
}) {
  if (labels.length != playable.length || labels.length != sizes.length) {
    throw ArgumentError('Episode file metadata lengths must match.');
  }
  final candidates = <_FileIdentityCandidate>[];
  final containerSeason = _explicitSeasonNumber(containerLabel ?? '');
  final allowSeasonRelativeBare =
      requestedSeason != null && containerSeason == requestedSeason;
  final requireBareNumberingProof =
      requireNumberingSchemeEvidence ||
      (requestedSeason == null &&
          requestedAbsoluteEpisode == null &&
          _hasUnresolvedSequelHint(containerLabel ?? ''));
  for (var index = 0; index < labels.length; index++) {
    if (!playable[index]) continue;
    candidates.add(
      _FileIdentityCandidate(
        index: index,
        size: sizes[index],
        assessment: assessEpisodeIdentityLabel(
          label: labels[index],
          requestedEpisode: requestedEpisode,
          requestedSeason: requestedSeason,
          requestedAbsoluteEpisode: requestedAbsoluteEpisode,
          requestedSpecial: requestedSpecial,
          allowSeasonRelativeBare: allowSeasonRelativeBare,
          requireNumberingSchemeEvidence: requireBareNumberingProof,
        ),
      ),
    );
  }
  if (candidates.isEmpty) {
    throw StateError('The source contains no supported video files.');
  }

  final matches = candidates
      .where((candidate) => candidate.assessment.isExactMatch)
      .toList(growable: false);
  if (matches.isNotEmpty) {
    final matchedAbsolute = matches.any(
      (candidate) =>
          candidate.assessment.reasonCode == 'absolute_episode_number_match',
    );
    final matchedRelative = matches.any(
      (candidate) => candidate.assessment.reasonCode == 'episode_number_match',
    );
    if (matchedAbsolute && matchedRelative) {
      throw const EpisodeIdentityAmbiguousException(
        reasonCode: 'episode_numbering_scheme_ambiguous',
      );
    }
    if (preferredFileIndex != null) {
      for (final candidate in matches) {
        if (candidate.index == preferredFileIndex) return candidate.index;
      }
    }
    return _largest(matches).index;
  }

  if (candidates.any(
    (candidate) =>
        candidate.assessment.isMatch && !candidate.assessment.isExactMatch,
  )) {
    throw const EpisodeIdentityAmbiguousException(
      reasonCode: 'episode_range_ambiguous',
    );
  }

  // Once any playable file identifies a concrete (but different) episode,
  // this is an episodic pack rather than an opaque collection of videos.
  // Do not let an unknown extra such as NCOP, NCED, sample, or trailer win
  // merely because it is larger or was the add-on's preferred file. Packs
  // where every filename is genuinely ambiguous are rejected below.
  final confirmedMismatch = candidates.where(
    (candidate) =>
        candidate.assessment.verdict == EpisodeIdentityVerdict.mismatch,
  );
  if (confirmedMismatch.isNotEmpty) {
    final reason = confirmedMismatch
        .map((candidate) => candidate.assessment.reasonCode)
        .firstWhere(
          (reason) => reason == 'season_number_mismatch',
          orElse: () => 'episode_number_mismatch',
        );
    throw EpisodeIdentityMismatchException(reasonCode: reason);
  }

  throw const EpisodeIdentityAmbiguousException(
    reasonCode: 'episode_file_identity_ambiguous',
  );
}

_FileIdentityCandidate _largest(List<_FileIdentityCandidate> candidates) =>
    candidates.reduce((left, right) => left.size >= right.size ? left : right);

class _FileIdentityCandidate {
  const _FileIdentityCandidate({
    required this.index,
    required this.size,
    required this.assessment,
  });

  final int index;
  final int size;
  final EpisodeIdentityAssessment assessment;
}

class _EpisodeSpan {
  const _EpisodeSpan(
    this.first,
    this.last, {
    this.season,
    this.isSpecial = false,
  });

  final int first;
  final int last;
  final int? season;
  final bool isSpecial;

  bool get isRange => first != last;
  bool contains(int episode) => episode >= first && episode <= last;
}

List<_EpisodeSpan> _episodeSpans(String value) {
  final spans = <_EpisodeSpan>[];
  final occupied = <(int, int)>[];

  void collect(RegExp expression, _EpisodeSpan? Function(RegExpMatch) read) {
    for (final match in expression.allMatches(value)) {
      if (occupied.any(
        (range) => match.start < range.$2 && match.end > range.$1,
      )) {
        continue;
      }
      final span = read(match);
      if (span == null) continue;
      spans.add(span);
      occupied.add((match.start, match.end));
    }
  }

  collect(
    RegExp(
      r'\b(?:specials?|sp|ova|ona|oad)\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*(?:(?:specials?|sp|ova|ona|oad)\s*)?0*(\d{1,4}))?\b',
      caseSensitive: false,
    ),
    (match) => _span(
      match.group(1),
      match.group(2),
      season: 0,
      explicit: true,
      isSpecial: true,
    ),
  );
  collect(
    RegExp(
      r'\bs(?:eason\s*)?0*(\d{1,3})\s*[._ -]*e(?:p(?:isode)?)?\s*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*(?:(?:s0*\d{1,3}\s*)?e(?:p(?:isode)?)?\s*)?0*(\d{1,4}))?',
      caseSensitive: false,
    ),
    (match) => _span(
      match.group(2),
      match.group(3),
      season: _number(match.group(1)),
      explicit: true,
    ),
  );
  collect(
    RegExp(
      r'\bseason\s*0*(\d{1,3})\s*[._ -]*(?:episode|ep)\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?',
      caseSensitive: false,
    ),
    (match) => _span(
      match.group(2),
      match.group(3),
      season: _number(match.group(1)),
      explicit: true,
    ),
  );
  collect(
    RegExp(
      r'\b0*(\d{1,3})x0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?\b',
      caseSensitive: false,
    ),
    (match) => _span(
      match.group(2),
      match.group(3),
      season: _number(match.group(1)),
      explicit: true,
    ),
  );
  collect(
    RegExp(
      r'\b(?:episodes?|eps?|ep)\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*(?:(?:episodes?|eps?|ep)\s*)?0*(\d{1,4}))?',
      caseSensitive: false,
    ),
    (match) => _span(match.group(1), match.group(2), explicit: true),
  );
  collect(
    RegExp(
      r'\be\s*[:#._ -]*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*e?\s*0*(\d{1,4}))?\b',
      caseSensitive: false,
    ),
    (match) => _span(match.group(1), match.group(2), explicit: true),
  );
  collect(
    RegExp(
      r'\s[-–—]\s+0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?\b(?!\.\d)(?!\s*(?:-\s*)?(?:bits?|ch(?:annels?)?|fps|hz)\b)',
      caseSensitive: false,
    ),
    (match) => _span(match.group(1), match.group(2)),
  );
  collect(
    RegExp(
      r'[\[(]\s*0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?(?=\s*[\])])',
      caseSensitive: false,
    ),
    (match) => _span(match.group(1), match.group(2)),
  );
  collect(
    RegExp(
      r'(?:^|[\\/])\s*0*(\d{1,4})(?:v\d+)?(?=\.(?:mkv|mp4|m4v|webm|avi|mov|ts|m2ts)\s*$)',
      caseSensitive: false,
    ),
    (match) => _span(match.group(1), null),
  );
  return spans;
}

_EpisodeSpan? _span(
  String? firstValue,
  String? lastValue, {
  int? season,
  bool explicit = false,
  bool isSpecial = false,
}) {
  final first = _number(firstValue);
  final parsedLast = _number(lastValue);
  if (first == null || !_plausibleEpisode(first, explicit: explicit)) {
    return null;
  }
  final last = parsedLast ?? first;
  if (!_plausibleEpisode(last, explicit: explicit)) return null;
  return _EpisodeSpan(
    first <= last ? first : last,
    first <= last ? last : first,
    season: season,
    isSpecial: isSpecial || season == 0,
  );
}

int? _number(String? value) => int.tryParse(value ?? '');

bool _plausibleEpisode(int? value, {required bool explicit}) {
  if (value == null || value <= 0 || value > (explicit ? 9999 : 1500)) {
    return false;
  }
  if (explicit) return true;
  if (value >= 1900 && value <= 2100) return false;
  return !const {240, 360, 480, 540, 576, 720, 1080, 1440}.contains(value);
}

int? _explicitSeasonNumber(String value) {
  final expressions = <RegExp>[
    RegExp(r'\bseason\s*0*(\d{1,3})\b', caseSensitive: false),
    RegExp(r'\b0*(\d{1,3})(?:st|nd|rd|th)\s+season\b', caseSensitive: false),
    RegExp(r'\bs0*(\d{1,3})(?=\s*e\d|\b)', caseSensitive: false),
    RegExp(r'\b0*(\d{1,3})x\d{1,4}\b', caseSensitive: false),
  ];
  for (final expression in expressions) {
    final parsed = _number(expression.firstMatch(value)?.group(1));
    if (parsed != null && parsed >= 0) return parsed;
  }
  return null;
}

bool _hasUnresolvedSequelHint(String value) {
  if (RegExp(
    r'\b(?:the\s+)?final\s+season\b',
    caseSensitive: false,
  ).hasMatch(value)) {
    return true;
  }
  final wordSeason = RegExp(
    r'\b(second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+season\b',
    caseSensitive: false,
  );
  if (wordSeason.hasMatch(value)) return true;
  final part = RegExp(
    r'\b(?:part|cour)\s*(\d{1,3}|ii|iii|iv|v|vi|vii|viii|ix|x)\b',
    caseSensitive: false,
  ).firstMatch(value);
  if (part != null) {
    final raw = part.group(1)!.toLowerCase();
    final number =
        int.tryParse(raw) ??
        const <String, int>{
          'ii': 2,
          'iii': 3,
          'iv': 4,
          'v': 5,
          'vi': 6,
          'vii': 7,
          'viii': 8,
          'ix': 9,
          'x': 10,
        }[raw];
    if (number != null && number > 1) return true;
  }
  return RegExp(
    r'\b(?:ii|iii|iv|v|vi|vii|viii|ix|x)\s*$',
    caseSensitive: false,
  ).hasMatch(value.trim());
}

String _seriesTitleKey(String value) => value
    .toLowerCase()
    .replaceAll(
      RegExp(
        r'\b(?:season\s*\d{1,3}|\d{1,3}(?:st|nd|rd|th)\s+season|s\d{1,3})\b',
        caseSensitive: false,
      ),
      ' ',
    )
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

String _comparableSeriesTitleKey(String value) {
  // Transliteration is provider-specific. Treat non-ASCII titles as
  // incomparable instead of falsely rejecting a localized match.
  if (value.runes.any((rune) => rune > 0x7f)) return '';
  return _seriesTitleKey(value);
}

bool _seriesTitlesAreClearlyDifferent(String expected, String observed) {
  if (expected == observed) return false;
  final expectedTokens = expected.split(' ').where(_usefulTitleToken).toSet();
  final observedTokens = observed.split(' ').where(_usefulTitleToken).toSet();
  if (expectedTokens.isEmpty || observedTokens.isEmpty) return false;
  return expectedTokens.intersection(observedTokens).isEmpty;
}

bool _usefulTitleToken(String token) =>
    token.length >= 2 && !const {'a', 'an', 'the', 'tv'}.contains(token);
