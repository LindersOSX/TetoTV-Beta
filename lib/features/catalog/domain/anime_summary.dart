import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/domain/anime_trailer.dart';

/// The public, account-free service which supplied the displayed metadata.
///
/// [AnimeSummary.id] remains an AniList ID for every source. This provenance
/// is deliberately informational and must never be used as a tracking ID.
enum CatalogMetadataSource { aniList, kitsu, jikan }

class AnimeSummary {
  const AnimeSummary({
    required this.id,
    required this.title,
    required this.description,
    required this.episodes,
    required this.score,
    this.idMal,
    this.titleEnglish,
    this.titleRomaji,
    this.coverImageUrl,
    this.bannerImageUrl,
    this.trailer,
    this.genres = const [],
    this.synonyms = const [],
    this.format,
    this.status,
    this.season,
    this.seasonYear,
    this.durationMinutes,
    this.nextAiringEpisode,
    this.isAdult = false,
    this.relatedAnime = const [],
    this.studios = const [],
    this.staff = const [],
    this.characters = const [],
    this.metadataSource = CatalogMetadataSource.aniList,
  });

  final int id;
  final int? idMal;
  final String title;
  final String? titleEnglish;
  final String? titleRomaji;
  final String description;
  final int? episodes;
  final double? score;
  final String? coverImageUrl;
  final String? bannerImageUrl;
  final AnimeTrailer? trailer;
  final List<String> genres;
  final List<String> synonyms;
  final String? format;
  final String? status;
  final String? season;
  final int? seasonYear;
  final int? durationMinutes;
  final int? nextAiringEpisode;
  final bool isAdult;
  final List<RelatedAnime> relatedAnime;
  final List<AnimeStudio> studios;
  final List<AnimePerson> staff;
  final List<AnimeCharacter> characters;
  final CatalogMetadataSource metadataSource;

  String displayTitle(TitleLanguagePreference preference) =>
      preferredAnimeTitle(
        preference: preference,
        fallback: title,
        english: titleEnglish,
        romaji: titleRomaji,
      );
}

class AnimeStudio {
  const AnimeStudio({required this.id, required this.name});
  final int id;
  final String name;
}

class AnimePerson {
  const AnimePerson({required this.id, required this.name, this.imageUrl});
  final int id;
  final String name;
  final String? imageUrl;
}

class AnimeCharacter {
  const AnimeCharacter({
    required this.id,
    required this.name,
    this.imageUrl,
    this.role,
    this.voiceActor,
  });
  final int id;
  final String name;
  final String? imageUrl;
  final String? role;
  final AnimePerson? voiceActor;
}

class AiringScheduleEntry {
  const AiringScheduleEntry({
    required this.anime,
    required this.episode,
    required this.airingAt,
  });
  final AnimeSummary anime;
  final int episode;
  final DateTime airingAt;
}

class CatalogFilters {
  const CatalogFilters({
    this.search,
    this.genre,
    this.tag,
    this.format,
    this.status,
    this.season,
    this.year,
    this.minimumScore,
    this.includeAdult = false,
    this.sort = 'POPULARITY_DESC',
  });
  final String? search;
  final String? genre;
  final String? tag;
  final String? format;
  final String? status;
  final String? season;
  final int? year;
  final int? minimumScore;
  final bool includeAdult;
  final String sort;
}

class RelatedAnime {
  const RelatedAnime({required this.anime, required this.relationType});

  final AnimeSummary anime;
  final String relationType;
}
