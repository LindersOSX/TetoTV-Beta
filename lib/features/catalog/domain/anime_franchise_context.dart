import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';

/// Returns the smallest trustworthy label which distinguishes this catalog
/// entry from the other entries in its franchise.
///
/// AniList's `season` field is a broadcast quarter, not a franchise ordinal,
/// so the label is derived only from explicit localized titles and narrowly
/// corroborated direct relations. A named arc or special keeps its exact
/// preferred title rather than being assigned an invented season number.
String? animeFranchiseContextLabel({
  required AnimeSummary anime,
  required TitleLanguagePreference titlePreference,
}) {
  final preferredTitle = anime.displayTitle(titlePreference);
  final titles = _orderedCatalogTitles(anime, titlePreference);

  for (final title in titles) {
    final parsed = _parseExplicitContext(title);
    if (parsed?.hasSeasonIdentity == true) return parsed!.label;
  }

  if (_canNarrowlyInferFirstSeason(anime, titles)) return 'SEASON 1';

  for (final title in titles) {
    final parsed = _parseExplicitContext(title);
    if (parsed?.partNumber case final part?) {
      if (_hasContextualPredecessor(anime)) return 'PART $part';
    }
  }

  if (_hasContextualPredecessor(anime)) return preferredTitle;
  return null;
}

List<String> _orderedCatalogTitles(
  AnimeSummary anime,
  TitleLanguagePreference preference,
) {
  final values = switch (preference) {
    TitleLanguagePreference.english => <String?>[
      anime.titleEnglish,
      anime.titleRomaji,
      anime.title,
    ],
    TitleLanguagePreference.romaji => <String?>[
      anime.titleRomaji,
      anime.titleEnglish,
      anime.title,
    ],
  };
  final seen = <String>{};
  return [
    for (final value in values)
      if (value != null &&
          value.trim().isNotEmpty &&
          seen.add(_normalizeIdentity(value)))
        value.trim(),
  ];
}

bool _canNarrowlyInferFirstSeason(
  AnimeSummary anime,
  List<String> currentTitles,
) {
  if (!_isEpisodic(anime)) return false;
  final hasEpisodicPrequel = anime.relatedAnime.any(
    (relation) =>
        _relationType(relation) == 'PREQUEL' && _isEpisodic(relation.anime),
  );
  if (hasEpisodicPrequel) return false;

  final currentKeys = currentTitles
      .map(_normalizeIdentity)
      .where((value) => value.isNotEmpty)
      .toSet();
  if (currentKeys.isEmpty) return false;

  for (final relation in anime.relatedAnime) {
    if (_relationType(relation) != 'SEQUEL' || !_isEpisodic(relation.anime)) {
      continue;
    }
    final sequelTitles = _orderedCatalogTitles(
      relation.anime,
      TitleLanguagePreference.english,
    );
    for (final sequelTitle in sequelTitles) {
      final parsed = _parseExplicitContext(sequelTitle);
      if (parsed?.seasonNumber != 2 || parsed?.baseTitle == null) continue;
      if (currentKeys.contains(_normalizeIdentity(parsed!.baseTitle!))) {
        return true;
      }
    }
  }
  return false;
}

bool _hasContextualPredecessor(AnimeSummary anime) => anime.relatedAnime.any(
  (relation) => const {'PREQUEL', 'PARENT'}.contains(_relationType(relation)),
);

String _relationType(RelatedAnime relation) =>
    relation.relationType.trim().toUpperCase().replaceAll('_', ' ');

bool _isEpisodic(AnimeSummary anime) => const {
  'TV',
  'TV SHORT',
  'ONA',
}.contains(anime.format?.trim().toUpperCase().replaceAll('_', ' '));

_ExplicitContext? _parseExplicitContext(String title) {
  final finalSeason = RegExp(
    r'\b(?:the\s+)?final\s+season\b',
    caseSensitive: false,
  ).firstMatch(title);
  final numericSeason = RegExp(
    r'\bseason\s*0*(\d{1,3})\b',
    caseSensitive: false,
  ).firstMatch(title);
  final ordinalSeason = RegExp(
    r'\b0*(\d{1,3})(?:st|nd|rd|th)\s+season\b',
    caseSensitive: false,
  ).firstMatch(title);
  final wordSeason = RegExp(
    r'\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+season\b',
    caseSensitive: false,
  ).firstMatch(title);
  final shortSeason = RegExp(
    r'(?:^|[\s:._-])s\s*0*(\d{1,3})(?=$|[\s:._-])',
    caseSensitive: false,
  ).firstMatch(title);
  final japaneseSeason = RegExp(
    r'(\d{1,3})\s*(?:期|シーズン)',
    caseSensitive: false,
  ).firstMatch(title);

  final seasonMatch =
      finalSeason ??
      numericSeason ??
      ordinalSeason ??
      wordSeason ??
      shortSeason ??
      japaneseSeason;
  final seasonNumber = _positiveNumber(
    numericSeason?.group(1) ??
        ordinalSeason?.group(1) ??
        shortSeason?.group(1) ??
        japaneseSeason?.group(1),
  );
  final wordSeasonNumber = wordSeason == null
      ? null
      : const <String, int>{
          'first': 1,
          'second': 2,
          'third': 3,
          'fourth': 4,
          'fifth': 5,
          'sixth': 6,
          'seventh': 7,
          'eighth': 8,
          'ninth': 9,
          'tenth': 10,
        }[wordSeason.group(1)!.toLowerCase()];
  final resolvedSeasonNumber = seasonNumber ?? wordSeasonNumber;
  final partNumber = _partNumber(title);
  final specialNumber = _positiveNumber(
    RegExp(
      r'\bspecial\s*0*(\d{1,3})\b',
      caseSensitive: false,
    ).firstMatch(title)?.group(1),
  );

  if (seasonMatch == null && partNumber == null) return null;
  final labels = <String>[
    if (finalSeason != null)
      'FINAL SEASON'
    else if (resolvedSeasonNumber != null)
      'SEASON $resolvedSeasonNumber',
    if (partNumber != null) 'PART $partNumber',
    if (specialNumber != null) 'SPECIAL $specialNumber',
  ];
  if (labels.isEmpty) return null;

  final rawBase = seasonMatch == null
      ? null
      : title.substring(0, seasonMatch.start).trim();
  return _ExplicitContext(
    label: labels.join(' · '),
    baseTitle: rawBase == null || rawBase.isEmpty ? null : rawBase,
    seasonNumber: resolvedSeasonNumber,
    finalSeason: finalSeason != null,
    partNumber: partNumber,
  );
}

int? _partNumber(String title) {
  final numeric = RegExp(
    r'\b(?:part|cour)\s*0*(\d{1,3})\b',
    caseSensitive: false,
  ).firstMatch(title);
  final ordinal = RegExp(
    r'\b0*(\d{1,3})(?:st|nd|rd|th)\s+(?:part|cour)\b',
    caseSensitive: false,
  ).firstMatch(title);
  final parsed = _positiveNumber(numeric?.group(1) ?? ordinal?.group(1));
  if (parsed != null) return parsed;
  final roman = RegExp(
    r'\b(?:part|cour)\s+(i|ii|iii|iv|v|vi|vii|viii|ix|x)\b',
    caseSensitive: false,
  ).firstMatch(title)?.group(1)?.toLowerCase();
  return const <String, int>{
    'i': 1,
    'ii': 2,
    'iii': 3,
    'iv': 4,
    'v': 5,
    'vi': 6,
    'vii': 7,
    'viii': 8,
    'ix': 9,
    'x': 10,
  }[roman];
}

int? _positiveNumber(String? value) {
  final parsed = int.tryParse(value ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

String _normalizeIdentity(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r"[’'`]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

class _ExplicitContext {
  const _ExplicitContext({
    required this.label,
    required this.baseTitle,
    required this.seasonNumber,
    required this.finalSeason,
    required this.partNumber,
  });

  final String label;
  final String? baseTitle;
  final int? seasonNumber;
  final bool finalSeason;
  final int? partNumber;

  bool get hasSeasonIdentity => seasonNumber != null || finalSeason;
}
