import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/anime_trailer.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';

/// Versioned JSON boundary between the live catalog model and durable offline
/// metadata. Decoding is intentionally tolerant: unknown fields and malformed
/// optional values are ignored so an older download remains usable after an
/// app update (and a newer snapshot remains usable after a rollback).
class OfflineAnimeSnapshotCodec {
  const OfflineAnimeSnapshotCodec();

  static const int currentSchemaVersion = 1;
  static const String _kind = 'anime-summary';

  OfflineMediaMetadata encode(
    AnimeSummary anime, {
    required DateTime updatedAt,
    String? coverRelativePath,
    String? bannerRelativePath,
  }) {
    return OfflineMediaMetadata(
      anilistMediaId: anime.id,
      malMediaId: anime.idMal,
      title: anime.title,
      schemaVersion: currentSchemaVersion,
      metadata: <String, Object?>{
        'kind': _kind,
        'version': currentSchemaVersion,
        'anime': _encodeAnime(anime, includeRelations: true),
      },
      coverRelativePath: coverRelativePath,
      bannerRelativePath: bannerRelativePath,
      updatedAt: updatedAt.toUtc(),
    );
  }

  AnimeSummary decode(
    OfflineMediaMetadata snapshot, {
    Uri? verifiedCoverFileUri,
    Uri? verifiedBannerFileUri,
  }) {
    final envelope = snapshot.metadata;
    final encodedAnime = _map(envelope['anime']) ?? envelope;
    return _decodeAnime(
      encodedAnime,
      fallbackId: snapshot.anilistMediaId,
      fallbackMalId: snapshot.malMediaId,
      fallbackTitle: snapshot.title,
      verifiedCoverFileUri: _verifiedFileUri(verifiedCoverFileUri),
      verifiedBannerFileUri: _verifiedFileUri(verifiedBannerFileUri),
    );
  }
}

Map<String, Object?> _encodeAnime(
  AnimeSummary anime, {
  required bool includeRelations,
}) => <String, Object?>{
  'id': anime.id,
  'idMal': anime.idMal,
  'title': anime.title,
  'titleEnglish': anime.titleEnglish,
  'titleRomaji': anime.titleRomaji,
  'description': anime.description,
  'episodes': anime.episodes,
  'score': anime.score,
  'coverImageUrl': _publicHttpsUrl(anime.coverImageUrl),
  'bannerImageUrl': _publicHttpsUrl(anime.bannerImageUrl),
  'trailer': _encodeTrailer(anime.trailer),
  'genres': anime.genres,
  'synonyms': anime.synonyms,
  'format': anime.format,
  'status': anime.status,
  'season': anime.season,
  'seasonYear': anime.seasonYear,
  'durationMinutes': anime.durationMinutes,
  'nextAiringEpisode': anime.nextAiringEpisode,
  'isAdult': anime.isAdult,
  'metadataSource': anime.metadataSource.name,
  'studios': [
    for (final studio in anime.studios)
      <String, Object?>{'id': studio.id, 'name': studio.name},
  ],
  'staff': [for (final person in anime.staff) _encodePerson(person)],
  'characters': [
    for (final character in anime.characters)
      <String, Object?>{
        'id': character.id,
        'name': character.name,
        'imageUrl': _publicHttpsUrl(character.imageUrl),
        'role': character.role,
        'voiceActor': character.voiceActor == null
            ? null
            : _encodePerson(character.voiceActor!),
      },
  ],
  if (includeRelations)
    'relatedAnime': [
      for (final relation in anime.relatedAnime)
        <String, Object?>{
          'relationType': relation.relationType,
          'anime': _encodeAnime(relation.anime, includeRelations: false),
        },
    ],
};

Map<String, Object?> _encodePerson(AnimePerson person) => <String, Object?>{
  'id': person.id,
  'name': person.name,
  'imageUrl': _publicHttpsUrl(person.imageUrl),
};

Map<String, Object?>? _encodeTrailer(AnimeTrailer? trailer) => trailer == null
    ? null
    : <String, Object?>{
        'provider': trailer.provider.name,
        'videoId': trailer.videoId,
        'thumbnailUrl': _publicHttpsUrl(trailer.thumbnailUrl),
      };

AnimeSummary _decodeAnime(
  Map<String, Object?> value, {
  required int fallbackId,
  int? fallbackMalId,
  required String fallbackTitle,
  Uri? verifiedCoverFileUri,
  Uri? verifiedBannerFileUri,
}) {
  final id = _positiveInt(value['id']) ?? fallbackId;
  final title = _nonEmptyString(value['title']) ?? fallbackTitle;
  final metadataSourceName = _string(value['metadataSource']);
  final metadataSource = CatalogMetadataSource.values.firstWhere(
    (candidate) => candidate.name == metadataSourceName,
    orElse: () => CatalogMetadataSource.aniList,
  );
  return AnimeSummary(
    id: id,
    idMal: _positiveInt(value['idMal']) ?? fallbackMalId,
    title: title,
    titleEnglish: _nonEmptyString(value['titleEnglish']),
    titleRomaji: _nonEmptyString(value['titleRomaji']),
    description: _string(value['description']) ?? '',
    episodes: _positiveInt(value['episodes']),
    score: _finiteDouble(value['score']),
    coverImageUrl:
        verifiedCoverFileUri?.toString() ??
        _publicHttpsUrl(_string(value['coverImageUrl'])),
    bannerImageUrl:
        verifiedBannerFileUri?.toString() ??
        _publicHttpsUrl(_string(value['bannerImageUrl'])),
    trailer: _decodeTrailer(value['trailer']),
    genres: _stringList(value['genres']),
    synonyms: _stringList(value['synonyms']),
    format: _nonEmptyString(value['format']),
    status: _nonEmptyString(value['status']),
    season: _nonEmptyString(value['season']),
    seasonYear: _positiveInt(value['seasonYear']),
    durationMinutes: _positiveInt(value['durationMinutes']),
    nextAiringEpisode: _positiveInt(value['nextAiringEpisode']),
    isAdult: value['isAdult'] == true,
    metadataSource: metadataSource,
    studios: _decodeStudios(value['studios']),
    staff: _decodePeople(value['staff']),
    characters: _decodeCharacters(value['characters']),
    relatedAnime: _decodeRelations(value['relatedAnime']),
  );
}

AnimeTrailer? _decodeTrailer(Object? value) {
  final trailer = _map(value);
  if (trailer == null) return null;
  return AnimeTrailer.tryCreate(
    provider: trailer['provider'],
    videoId: trailer['videoId'],
    thumbnailUrl: _publicHttpsUrl(_string(trailer['thumbnailUrl'])),
  );
}

List<AnimeStudio> _decodeStudios(Object? value) => [
  for (final entry in _maps(value))
    if (_positiveInt(entry['id']) case final int id)
      if (_nonEmptyString(entry['name']) case final String name)
        AnimeStudio(id: id, name: name),
];

List<AnimePerson> _decodePeople(Object? value) => [
  for (final entry in _maps(value))
    if (_decodePerson(entry) case final AnimePerson person) person,
];

AnimePerson? _decodePerson(Map<String, Object?> value) {
  final id = _positiveInt(value['id']);
  final name = _nonEmptyString(value['name']);
  if (id == null || name == null) return null;
  return AnimePerson(
    id: id,
    name: name,
    imageUrl: _publicHttpsUrl(_string(value['imageUrl'])),
  );
}

List<AnimeCharacter> _decodeCharacters(Object? value) => [
  for (final entry in _maps(value))
    if (_positiveInt(entry['id']) case final int id)
      if (_nonEmptyString(entry['name']) case final String name)
        AnimeCharacter(
          id: id,
          name: name,
          imageUrl: _publicHttpsUrl(_string(entry['imageUrl'])),
          role: _nonEmptyString(entry['role']),
          voiceActor: _decodeOptionalPerson(entry['voiceActor']),
        ),
];

AnimePerson? _decodeOptionalPerson(Object? value) {
  final person = _map(value);
  return person == null ? null : _decodePerson(person);
}

List<RelatedAnime> _decodeRelations(Object? value) => [
  for (final entry in _maps(value))
    if (_map(entry['anime']) case final anime?)
      if (_positiveInt(anime['id']) case final int id)
        if (_nonEmptyString(anime['title']) case final String title)
          RelatedAnime(
            relationType: _nonEmptyString(entry['relationType']) ?? 'UNKNOWN',
            anime: _decodeAnime(anime, fallbackId: id, fallbackTitle: title),
          ),
];

Uri? _verifiedFileUri(Uri? value) {
  if (value == null || value.scheme != 'file' || !value.isAbsolute) return null;
  return value;
}

String? _publicHttpsUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  const credentialQueryKeys = <String>{
    'access_token',
    'api_key',
    'apikey',
    'auth',
    'authorization',
    'credential',
    'key',
    'password',
    'secret',
    'sig',
    'signature',
    'token',
  };
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.queryParameters.keys.any(
        (key) => credentialQueryKeys.contains(key.trim().toLowerCase()),
      )) {
    return null;
  }
  return uri.toString();
}

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

Iterable<Map<String, Object?>> _maps(Object? value) sync* {
  if (value is! List) return;
  for (final entry in value) {
    final mapped = _map(entry);
    if (mapped != null) yield mapped;
  }
}

String? _string(Object? value) => value is String ? value : null;

String? _nonEmptyString(Object? value) {
  final text = _string(value)?.trim();
  return text == null || text.isEmpty ? null : text;
}

int? _positiveInt(Object? value) {
  final parsed = switch (value) {
    int number => number,
    num number when number.isFinite => number.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };
  return parsed != null && parsed > 0 ? parsed : null;
}

double? _finiteDouble(Object? value) {
  final parsed = switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };
  return parsed?.isFinite == true ? parsed : null;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (_nonEmptyString(entry) case final String text) text,
  ];
}
