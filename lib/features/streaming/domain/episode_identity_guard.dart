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
}

/// A confirmed mismatch is candidate-specific and can safely advance normal
/// source failover. Unknown/ambiguous evidence must remain playable.
class EpisodeIdentityMismatchException implements Exception {
  const EpisodeIdentityMismatchException({required this.reasonCode});

  final String reasonCode;

  @override
  String toString() =>
      'This source identifies a different episode. TetoTV skipped it and '
      'will try another source.';
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
    ...episode.alternativeTitles,
  ]) {
    final season = _explicitSeasonNumber(value ?? '');
    if (season != null) return season;
  }
  return null;
}

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

  // A bare filename number cannot safely identify a season-local episode in
  // later seasons. Anime packs frequently use absolute numbering, so both
  // `Show - 25` and `Show - 88` are plausible for season 4 episode 25. Keep
  // the provider-selected file unless the filename supplies an explicit
  // season marker such as S04E25, 4x25, or "4th Season".
  if (requestedSeason != null &&
      requestedSeason > 1 &&
      labelSeason == null &&
      spans.every((span) => span.season == null)) {
    return const EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.unknown,
      'season_local_or_absolute_ambiguous',
    );
  }

  var episodeWasPresentInDifferentSeason = false;
  for (final span in spans) {
    if (!span.contains(requestedEpisode)) continue;
    final observedSeason = span.season ?? labelSeason;
    if (requestedSeason != null &&
        observedSeason != null &&
        observedSeason != requestedSeason) {
      episodeWasPresentInDifferentSeason = true;
      continue;
    }
    return EpisodeIdentityAssessment(
      EpisodeIdentityVerdict.match,
      span.isRange ? 'episode_range_match' : 'episode_number_match',
    );
  }

  return EpisodeIdentityAssessment(
    EpisodeIdentityVerdict.mismatch,
    episodeWasPresentInDifferentSeason
        ? 'season_number_mismatch'
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
  final providerIdentity = stream.providerEpisodeIdentity;
  if (providerIdentity != null) {
    final explicit = assessExplicitProviderEpisodeIdentity(
      episode: episode,
      episodeNumber: providerIdentity.episodeNumber,
      seasonNumber: providerIdentity.seasonNumber,
      seriesTitle: providerIdentity.seriesTitle,
    );
    if (explicit.verdict != EpisodeIdentityVerdict.unknown) return explicit;
  }
  final season = catalogSeasonNumber(episode);
  final resolved = assessEpisodeIdentityLabel(
    label: stream.displayName,
    requestedEpisode: episode.episode,
    requestedSeason: season,
  );
  if (resolved.verdict != EpisodeIdentityVerdict.unknown) return resolved;
  return assessEpisodeIdentityLabel(
    label: release.releaseName,
    requestedEpisode: episode.episode,
    requestedSeason: season,
  );
}

bool playbackEpisodeIdentityIsCompatible({
  required EpisodeReference episode,
  required StreamReady stream,
  required ReleaseCandidate release,
}) => !assessPlaybackEpisodeIdentity(
  episode: episode,
  stream: stream,
  release: release,
).isMismatch;

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

/// Selects one playable file while excluding only confirmed wrong episodes.
///
/// Explicit matching evidence beats an add-on file index. If no file exposes
/// useful identity evidence, the preferred index (or largest playable file)
/// remains available instead of rejecting an ambiguous source.
int selectEpisodeFileIndex({
  required List<String> labels,
  required List<bool> playable,
  required List<int> sizes,
  required int requestedEpisode,
  int? requestedSeason,
  int? preferredFileIndex,
}) {
  if (labels.length != playable.length || labels.length != sizes.length) {
    throw ArgumentError('Episode file metadata lengths must match.');
  }
  final candidates = <_FileIdentityCandidate>[];
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
        ),
      ),
    );
  }
  if (candidates.isEmpty) {
    throw StateError('The source contains no supported video files.');
  }

  final matches = candidates
      .where(
        (candidate) =>
            candidate.assessment.verdict == EpisodeIdentityVerdict.match,
      )
      .toList(growable: false);
  if (matches.isNotEmpty) {
    if (preferredFileIndex != null) {
      for (final candidate in matches) {
        if (candidate.index == preferredFileIndex) return candidate.index;
      }
    }
    return _largest(matches).index;
  }

  // Once any playable file identifies a concrete (but different) episode,
  // this is an episodic pack rather than an opaque collection of videos.
  // Do not let an unknown extra such as NCOP, NCED, sample, or trailer win
  // merely because it is larger or was the add-on's preferred file. Packs
  // where every filename is genuinely ambiguous still retain the historic
  // fail-open behavior below.
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

  final unknown = candidates
      .where(
        (candidate) =>
            candidate.assessment.verdict == EpisodeIdentityVerdict.unknown,
      )
      .toList(growable: false);
  if (preferredFileIndex != null) {
    for (final candidate in unknown) {
      if (candidate.index == preferredFileIndex) return candidate.index;
    }
  }
  if (unknown.isNotEmpty) return _largest(unknown).index;

  // [candidates] is non-empty and, at this point, contains only unknown
  // evidence, so one of the branches above must have returned.
  throw StateError('The source contains no selectable video files.');
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
  const _EpisodeSpan(this.first, this.last, {this.season});

  final int first;
  final int last;
  final int? season;

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
      r'(?:\s[-–—]\s+|[\[(]\s*)0*(\d{1,4})(?:v\d+)?(?:\s*[-~]\s*0*(\d{1,4}))?(?!\.\d)(?=\s*(?:\[|\]|\)|$|[._]))',
      caseSensitive: false,
    ),
    (match) => _span(match.group(1), match.group(2)),
  );
  return spans;
}

_EpisodeSpan? _span(
  String? firstValue,
  String? lastValue, {
  int? season,
  bool explicit = false,
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
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
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
