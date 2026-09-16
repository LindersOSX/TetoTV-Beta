import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:dio/dio.dart';

class KitsuTrackingRepository
    implements
        TrackingRepository,
        ExternalIdTrackingRepository,
        RatingTrackingRepository {
  KitsuTrackingRepository({required String accessToken, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://kitsu.io/api/edge',
              headers: {
                'Accept': 'application/vnd.api+json',
                'Content-Type': 'application/vnd.api+json',
                'Authorization': 'Bearer $accessToken',
              },
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
              maxRedirects: 0,
            ),
          );

  final Dio _dio;
  String? _cachedUserId;

  @override
  Future<List<TrackedAnime>> list(TrackingListStatus status) async {
    final userId = await _userId();
    final rows = <TrackedAnime>[];
    final visited = <String>{};
    String? nextUrl;
    var page = 0;

    do {
      page++;
      if (page > 50) {
        throw const FormatException('Kitsu returned too many result pages.');
      }

      late final Response<Map<String, dynamic>> response;
      if (nextUrl == null) {
        response = await _dio.get<Map<String, dynamic>>(
          '/library-entries',
          queryParameters: {
            'filter[userId]': userId,
            'filter[kind]': 'anime',
            'filter[status]': kitsuStatus(status),
            'include': 'anime,anime.mappings',
            'page[limit]': 20,
            'page[offset]': 0,
          },
        );
      } else {
        final pageUri = trustedKitsuLibraryPageUri(nextUrl);
        if (pageUri == null) {
          throw const FormatException(
            'Kitsu returned an untrusted pagination link.',
          );
        }
        final canonical = pageUri.toString();
        if (!visited.add(canonical)) {
          throw const FormatException('Kitsu returned a pagination loop.');
        }
        response = await _dio.get<Map<String, dynamic>>(canonical);
      }

      final body = response.data ?? const <String, dynamic>{};
      final included = _includedIndex(body['included']);
      for (final raw in _resourceList(body['data'])) {
        final attributes = _map(raw['attributes']);
        final animeRef = _relationshipData(raw, 'anime');
        final anime = animeRef == null
            ? null
            : included['${animeRef.type}:${animeRef.id}'];
        if (anime == null) continue;
        final animeId = int.tryParse(animeRef!.id);
        if (animeId == null || animeId <= 0) continue;
        final animeAttributes = _map(anime['attributes']);
        final titles = _map(animeAttributes['titles']);
        final canonicalTitle = _nonEmpty(animeAttributes['canonicalTitle']);
        final english = _nonEmpty(titles['en']);
        final romaji = _nonEmpty(titles['en_jp']);
        final title = english ?? romaji ?? canonicalTitle;
        if (title == null) continue;
        final poster = _map(animeAttributes['posterImage']);
        final mappings = _mappingIds(anime, included);

        rows.add(
          TrackedAnime(
            mediaId: animeId,
            title: title,
            titleEnglish: english,
            titleRomaji: romaji,
            status: status,
            progress: _nonNegativeInt(attributes['progress']) ?? 0,
            totalEpisodes: _positiveInt(animeAttributes['episodeCount']),
            coverImageUrl:
                _nonEmpty(poster['large']) ?? _nonEmpty(poster['medium']),
            score: switch (_nonNegativeInt(attributes['ratingTwenty'])) {
              final int rating when rating >= 2 && rating <= 20 => rating / 2,
              _ => null,
            },
            updatedAt: _dateTime(attributes['updatedAt']),
            startDate: _dateTime(animeAttributes['startDate']),
            airingStatus: _nonEmpty(animeAttributes['status']),
            anilistId: mappings.anilistId,
            malId: mappings.malId,
          ),
        );
      }

      nextUrl = switch (_map(body['links'])['next']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      };
    } while (nextUrl != null);

    return rows;
  }

  @override
  Future<int?> currentProgress(int mediaId) async {
    final entry = await _entry(mediaId);
    return _nonNegativeInt(_map(entry?['attributes'])['progress']);
  }

  @override
  Future<int?> currentProgressByIds(TrackingMediaIds ids) async {
    final mediaId = await _resolveMediaId(ids);
    return currentProgress(mediaId);
  }

  @override
  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  }) async {
    _requireMediaId(mediaId);
    if (completedEpisodes < 0) {
      throw ArgumentError.value(
        completedEpisodes,
        'completedEpisodes',
        'Progress cannot be negative.',
      );
    }
    final entry = await _entry(mediaId);
    final existing = _nonNegativeInt(_map(entry?['attributes'])['progress']);
    if (existing != null && completedEpisodes <= existing) return;
    if (entry == null) {
      await _createEntry(
        mediaId: mediaId,
        attributes: {
          'status': kitsuStatus(TrackingListStatus.watching),
          'progress': completedEpisodes,
        },
      );
      return;
    }
    await _patchEntry(entry, {'progress': completedEpisodes});
  }

  @override
  Future<void> updateProgressByIds({
    required TrackingMediaIds ids,
    required int completedEpisodes,
  }) async => updateProgress(
    mediaId: await _resolveMediaId(ids),
    completedEpisodes: completedEpisodes,
  );

  @override
  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    _requireMediaId(mediaId);
    final entry = await _entry(mediaId);
    final value = kitsuStatus(status);
    if (entry == null) {
      await _createEntry(mediaId: mediaId, attributes: {'status': value});
      return;
    }
    await _patchEntry(entry, {'status': value});
  }

  @override
  Future<void> updateStatusByIds({
    required TrackingMediaIds ids,
    required TrackingListStatus status,
  }) async => updateStatus(mediaId: await _resolveMediaId(ids), status: status);

  @override
  Future<void> updateRating({
    required int mediaId,
    required double? score,
  }) async {
    _requireMediaId(mediaId);
    final ratingTwenty = _ratingTwenty(score);
    final entry = await _entry(mediaId);
    if (entry == null) {
      // Clearing a rating must not manufacture a new planned-list entry.
      if (ratingTwenty == null) return;
      await _createEntry(
        mediaId: mediaId,
        attributes: {
          'status': kitsuStatus(TrackingListStatus.planToWatch),
          'ratingTwenty': ratingTwenty,
        },
      );
      return;
    }
    await _patchEntry(entry, {'ratingTwenty': ratingTwenty});
  }

  @override
  Future<void> removeFromList({required int mediaId}) async {
    _requireMediaId(mediaId);
    final entry = await _entry(mediaId);
    final id = _resourceId(entry);
    if (id == null) return;
    await _dio.delete<void>('/library-entries/$id');
  }

  @override
  Future<void> removeFromListByIds(TrackingMediaIds ids) async =>
      removeFromList(mediaId: await _resolveMediaId(ids));

  Future<String> _userId() async {
    if (_cachedUserId case final value?) return value;
    final response = await _dio.get<Map<String, dynamic>>(
      '/users',
      queryParameters: const {'filter[self]': 'true', 'page[limit]': 1},
    );
    final users = _resourceList(response.data?['data']);
    final id = users.isEmpty ? null : _resourceId(users.first);
    if (id == null) {
      throw StateError('Kitsu account could not be verified.');
    }
    return _cachedUserId = id;
  }

  Future<Map<String, dynamic>?> _entry(int mediaId) async {
    _requireMediaId(mediaId);
    final response = await _dio.get<Map<String, dynamic>>(
      '/library-entries',
      queryParameters: {
        'filter[userId]': await _userId(),
        'filter[animeId]': mediaId,
        'page[limit]': 2,
      },
    );
    final entries = _resourceList(response.data?['data']);
    if (entries.length > 1) {
      throw StateError('Kitsu returned duplicate library entries.');
    }
    return entries.firstOrNull;
  }

  Future<void> _createEntry({
    required int mediaId,
    required Map<String, dynamic> attributes,
  }) async {
    final userId = await _userId();
    await _dio.post<void>(
      '/library-entries',
      data: {
        'data': {
          'type': 'libraryEntries',
          'attributes': attributes,
          'relationships': {
            'user': {
              'data': {'type': 'users', 'id': userId},
            },
            'anime': {
              'data': {'type': 'anime', 'id': '$mediaId'},
            },
          },
        },
      },
    );
  }

  Future<void> _patchEntry(
    Map<String, dynamic> entry,
    Map<String, dynamic> attributes,
  ) async {
    final id = _resourceId(entry);
    if (id == null) {
      throw StateError('Kitsu returned an invalid library entry.');
    }
    await _dio.patch<void>(
      '/library-entries/$id',
      data: {
        'data': {'type': 'libraryEntries', 'id': id, 'attributes': attributes},
      },
    );
  }

  Future<int> _resolveMediaId(TrackingMediaIds ids) async {
    if (_positive(ids.kitsuId) case final direct?) return direct;
    final resolved = <int>{};
    if (_positive(ids.anilistId) case final anilist?) {
      if (await _mappedAnimeId('anilist/anime', anilist) case final id?) {
        resolved.add(id);
      }
    }
    if (_positive(ids.malId) case final mal?) {
      if (await _mappedAnimeId('myanimelist/anime', mal) case final id?) {
        resolved.add(id);
      }
    }
    if (resolved.length > 1) {
      throw StateError('Kitsu returned conflicting catalog mappings.');
    }
    if (resolved.firstOrNull case final id?) return id;
    throw const TrackingMediaMappingNotFoundException();
  }

  Future<int?> _mappedAnimeId(String externalSite, int externalId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/mappings',
      queryParameters: {
        'filter[externalSite]': externalSite,
        'filter[externalId]': externalId,
        'include': 'item',
        'page[limit]': 2,
      },
    );
    final ids = <int>{};
    for (final mapping in _resourceList(response.data?['data'])) {
      final item = _relationshipData(mapping, 'item');
      if (item?.type != 'anime') continue;
      if (int.tryParse(item!.id) case final int value when value > 0) {
        ids.add(value);
      }
    }
    for (final resource in _resourceList(response.data?['included'])) {
      if (resource['type'] != 'anime') continue;
      if (int.tryParse(_resourceId(resource) ?? '') case final int value
          when value > 0) {
        ids.add(value);
      }
    }
    if (ids.length > 1) {
      throw StateError('Kitsu returned an ambiguous catalog mapping.');
    }
    return ids.firstOrNull;
  }
}

String kitsuStatus(TrackingListStatus status) => switch (status) {
  TrackingListStatus.watching => 'current',
  TrackingListStatus.planToWatch => 'planned',
  TrackingListStatus.completed => 'completed',
  TrackingListStatus.dropped => 'dropped',
  TrackingListStatus.onHold => 'on_hold',
};

Uri? trustedKitsuLibraryPageUri(String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) return null;
  final uri = parsed.isAbsolute
      ? parsed
      : Uri.parse(
          'https://kitsu.io/api/edge/library-entries',
        ).resolveUri(parsed);
  if (uri.scheme.toLowerCase() != 'https' ||
      uri.host.toLowerCase() != 'kitsu.io' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.path != '/api/edge/library-entries') {
    return null;
  }
  return uri;
}

({int? anilistId, int? malId}) _mappingIds(
  Map<String, dynamic> anime,
  Map<String, Map<String, dynamic>> included,
) {
  int? anilistId;
  int? malId;
  final relationship = _map(_map(anime['relationships'])['mappings']);
  for (final reference in _resourceList(relationship['data'])) {
    final type = _nonEmpty(reference['type']);
    final id = _nonEmpty(reference['id']);
    final mapping = type == null || id == null ? null : included['$type:$id'];
    final attributes = _map(mapping?['attributes']);
    final externalId = int.tryParse(_nonEmpty(attributes['externalId']) ?? '');
    if (externalId == null || externalId <= 0) continue;
    switch (_nonEmpty(attributes['externalSite'])) {
      case 'anilist/anime':
        anilistId ??= externalId;
      case 'myanimelist/anime':
        malId ??= externalId;
    }
  }
  return (anilistId: anilistId, malId: malId);
}

Map<String, Map<String, dynamic>> _includedIndex(Object? value) => {
  for (final resource in _resourceList(value))
    if (_nonEmpty(resource['type']) case final type?)
      if (_resourceId(resource) case final id?) '$type:$id': resource,
};

({String type, String id})? _relationshipData(
  Map<String, dynamic> resource,
  String name,
) {
  final data = _map(_map(_map(resource['relationships'])[name])['data']);
  final type = _nonEmpty(data['type']);
  final id = _nonEmpty(data['id']);
  return type == null || id == null ? null : (type: type, id: id);
}

List<Map<String, dynamic>> _resourceList(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList()
    : const [];

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

String? _resourceId(Map<String, dynamic>? resource) =>
    _nonEmpty(resource?['id']);

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

int? _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final result = value.toInt();
  return result < 0 ? null : result;
}

int? _positiveInt(Object? value) {
  final result = _nonNegativeInt(value);
  return result == null || result <= 0 ? null : result;
}

int? _positive(int? value) => value != null && value > 0 ? value : null;

DateTime? _dateTime(Object? value) {
  final source = _nonEmpty(value);
  return source == null ? null : DateTime.tryParse(source)?.toLocal();
}

void _requireMediaId(int mediaId) {
  if (mediaId <= 0) {
    throw ArgumentError.value(mediaId, 'mediaId', 'Use a positive Kitsu ID.');
  }
}

int? _ratingTwenty(double? score) {
  if (score == null) return null;
  if (!score.isFinite || score < 1 || score > 10) {
    throw ArgumentError.value(score, 'score', 'Use a score from 1 to 10.');
  }
  final doubled = score * 2;
  if ((doubled - doubled.round()).abs() > 0.000001) {
    throw ArgumentError.value(score, 'score', 'Use half-point increments.');
  }
  return doubled.round();
}
