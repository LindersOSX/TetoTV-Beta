import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/data/kitsu_catalog_fallback.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/anime_trailer.dart';
import 'package:dio/dio.dart';

/// A catalog failure whose retryability is known without exposing the request
/// URL, GraphQL variables, account state, or response payload.
class AniListCatalogException implements Exception {
  const AniListCatalogException(this.message, {required this.retryable});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

class AniListCatalogClient {
  static const _fallbackMaxStaleAge = Duration(hours: 24);
  static const _jikanMappingConcurrency = 4;
  static const _jikanSchedulePageLimit = 4;
  static const _jikanSchedulePageSize = 25;

  AniListCatalogClient({Dio? dio, Dio? kitsuDio, Dio? jikanDio, Dio? aniZipDio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://graphql.anilist.co',
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: const {'Accept': 'application/json'},
            ),
          ),
      _kitsu = KitsuCatalogFallback(dio: kitsuDio),
      _jikanDio =
          jikanDio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.jikan.moe/v4/',
              connectTimeout: const Duration(seconds: 6),
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: const {'Accept': 'application/json'},
            ),
          ),
      _aniZipDio =
          aniZipDio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://hayase.ani.zip/v1/',
              connectTimeout: const Duration(seconds: 6),
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: const {'Accept': 'application/json'},
            ),
          );

  final Dio _dio;
  final KitsuCatalogFallback _kitsu;
  final Dio _jikanDio;
  final Dio _aniZipDio;
  final Map<int, String> _knownStudioNames = <int, String>{};
  final Map<int, String> _knownStaffNames = <int, String>{};
  final Map<int, int> _knownAniListIdByMalId = <int, int>{};
  final Map<int, int> _knownMalIdByAniListId = <int, int>{};

  Future<List<AnimeSummary>> trending({int page = 1}) async {
    const query = r'''
      query TrendingAnime($page: Int!) {
        Page(page: $page, perPage: 20) {
          media(type: ANIME, sort: TRENDING_DESC, isAdult: false) {
            id
            idMal
            title { userPreferred english romaji }
            description(asHtml: false)
            episodes
            averageScore
            genres
            coverImage { extraLarge }
            bannerImage
            format
            status
            season
            seasonYear
            duration
            synonyms
            isAdult
            nextAiringEpisode { episode }
          }
        }
      }
    ''';

    try {
      return await _mediaPage(query, {'page': page});
    } catch (error) {
      if (!_isRetryableAniListFailure(error)) rethrow;
      return _fallbackCatalogList(
        operation: 'trending',
        unavailableMessage: 'Trending anime',
        preferJikan: true,
        kitsuRequest: () => _kitsu.trending(page: page),
        jikanRequest: () => _jikanCatalogFallback(
          path: 'top/anime',
          queryParameters: {
            'page': page,
            'limit': 20,
            'filter': 'airing',
            'sfw': true,
          },
          diagnosticMode: 'jikan-trending',
          unavailableMessage: 'Trending anime',
        ),
      );
    }
  }

  Future<List<AnimeSummary>> seasonal({DateTime? now, int page = 1}) async {
    final date = now ?? DateTime.now();
    final season = switch (date.month) {
      <= 3 => 'WINTER',
      <= 6 => 'SPRING',
      <= 9 => 'SUMMER',
      _ => 'FALL',
    };
    const query = r'''
      query SeasonalAnime(
        $page: Int!,
        $season: MediaSeason!,
        $year: Int!
      ) {
        Page(page: $page, perPage: 20) {
          media(
            type: ANIME,
            season: $season,
            seasonYear: $year,
            sort: POPULARITY_DESC,
            isAdult: false
          ) {
            id
            idMal
            title { userPreferred english romaji }
            description(asHtml: false)
            episodes
            averageScore
            genres
            coverImage { extraLarge }
            bannerImage
            format
            status
            season
            seasonYear
            duration
            synonyms
            isAdult
            nextAiringEpisode { episode }
          }
        }
      }
    ''';
    try {
      return await _mediaPage(query, {
        'page': page,
        'season': season,
        'year': date.year,
      });
    } catch (error) {
      if (!_isRetryableAniListFailure(error)) rethrow;
      return _fallbackCatalogList(
        operation: 'seasonal',
        unavailableMessage: 'Seasonal anime',
        preferJikan: true,
        kitsuRequest: () => _kitsu.seasonal(date, page: page),
        jikanRequest: () => _jikanCatalogFallback(
          path: 'seasons/${date.year}/${season.toLowerCase()}',
          queryParameters: {'page': page, 'limit': 20, 'sfw': true},
          diagnosticMode: 'jikan-seasonal',
          unavailableMessage: 'Seasonal anime',
        ),
      );
    }
  }

  Future<List<AnimeSummary>> search(String term, {int page = 1}) async {
    const query = r'''
      query SearchAnime($page: Int!, $search: String!) {
        Page(page: $page, perPage: 20) {
          media(
            type: ANIME,
            search: $search,
            sort: SEARCH_MATCH,
            isAdult: false
          ) {
            id
            idMal
            title { userPreferred english romaji }
            description(asHtml: false)
            episodes
            averageScore
            genres
            coverImage { extraLarge }
            bannerImage
            format
            status
            season
            seasonYear
            duration
            synonyms
            isAdult
            nextAiringEpisode { episode }
          }
        }
      }
    ''';
    try {
      return await _mediaPage(query, {'page': page, 'search': term});
    } catch (error) {
      if (!_isRetryableAniListFailure(error)) rethrow;
      return _fallbackCatalogList(
        operation: 'search',
        unavailableMessage: 'Anime search',
        kitsuRequest: () => _kitsu.search(term, page: page),
        jikanRequest: () => _jikanCatalogFallback(
          path: 'anime',
          queryParameters: {'q': term, 'page': page, 'limit': 20, 'sfw': true},
          diagnosticMode: 'jikan-search',
          unavailableMessage: 'Anime search',
          allowKitsuIdentityBridge: false,
        ),
      );
    }
  }

  Future<AnimeSummary> details(int id) async {
    const query = r'''
      query AnimeDetails($id: Int!) {
        Media(id: $id, type: ANIME) {
          id
          idMal
          title { userPreferred english romaji }
          description(asHtml: false)
          episodes
          averageScore
          genres
          coverImage { extraLarge }
          bannerImage
          trailer { id site thumbnail }
          format
          status
          season
          seasonYear
          duration
          synonyms
          isAdult
          nextAiringEpisode { episode }
          studios(isMain: true) { nodes { id name } }
          staff(perPage: 10, sort: RELEVANCE) {
            nodes { id name { full } image { large } }
          }
          characters(perPage: 12, sort: ROLE) {
            edges {
              role
              node { id name { full } image { large } }
              voiceActors(language: ENGLISH, sort: RELEVANCE) {
                id name { full } image { large }
              }
            }
          }
          relations {
            edges {
              relationType
              node {
                id
                idMal
                type
                title { userPreferred english romaji }
                description(asHtml: false)
                episodes
                averageScore
                genres
                coverImage { extraLarge }
                bannerImage
                format
                status
                season
                seasonYear
                duration
                synonyms
                isAdult
                nextAiringEpisode { episode }
              }
            }
          }
        }
      }
    ''';
    try {
      final data = await _graphQl(query, {'id': id});
      final media = data['Media'] as Map<String, dynamic>?;
      if (media == null) {
        throw const AniListCatalogException(
          'Anime not found.',
          retryable: false,
        );
      }
      final anime = _mapAnime(media);
      _rememberCatalogIdentities([anime]);
      return anime;
    } catch (error) {
      if (!_isRetryableAniListFailure(error)) rethrow;
      try {
        final fallback = await _kitsu.detailsForAniListId(id);
        _rememberCatalogIdentities([fallback]);
        await _recordCatalogFallback(
          'kitsu-details',
          source: CatalogMetadataSource.kitsu,
        );
        return fallback;
      } catch (_) {
        try {
          return await _jikanDetailsFallback(id);
        } catch (_) {
          throw StateError(
            'Anime details and both read-only backups are temporarily '
            'unavailable. Please try again shortly.',
          );
        }
      }
    }
  }

  Future<List<AnimeSummary>> discover(
    CatalogFilters filters, {
    int page = 1,
  }) async {
    const query = r'''
      query DiscoverAnime(
        $page: Int!, $search: String, $genre: String, $tag: String,
        $format: MediaFormat,
        $status: MediaStatus, $season: MediaSeason, $year: Int,
        $minimumScore: Int, $isAdult: Boolean, $sort: [MediaSort!]
      ) {
        Page(page: $page, perPage: 30) {
          media(
            type: ANIME, search: $search, isAdult: $isAdult,
            genre: $genre, tag: $tag, format: $format,
            status: $status, season: $season, seasonYear: $year,
            averageScore_greater: $minimumScore, sort: $sort
          ) {
            id idMal title { userPreferred english romaji }
            description(asHtml: false) episodes averageScore genres
            coverImage { extraLarge } bannerImage format status season
            seasonYear duration synonyms isAdult nextAiringEpisode { episode }
          }
        }
      }
    ''';
    final variables = <String, dynamic>{
      // AniList's isAdult=true means "adult titles only". The Discover
      // setting is inclusive, so omit the predicate when enabled and retain
      // the explicit safe-only predicate when it is disabled.
      if (!filters.includeAdult) 'isAdult': false,
      'sort': [filters.sort],
    };
    void addIfPresent(String key, Object? value) {
      if (value != null) variables[key] = value;
    }

    final search = filters.search?.trim();
    addIfPresent('search', search == null || search.isEmpty ? null : search);
    addIfPresent('genre', filters.genre);
    addIfPresent('tag', filters.tag);
    addIfPresent('format', filters.format);
    addIfPresent('status', filters.status);
    addIfPresent('season', filters.season);
    addIfPresent('year', filters.year);
    addIfPresent('minimumScore', filters.minimumScore);
    try {
      return await _discoverPages(query, variables, logicalPage: page);
    } catch (error) {
      // AniList occasionally rejects an otherwise valid filter request with
      // "Illegal operation and value combination" when a sort is combined
      // with other media arguments. Retry the same filters without a server
      // sort instead of leaving Discover unusable. The small returned page is
      // then sorted locally to retain the user's requested ordering.
      if (!_isIllegalDiscoverCombination(error)) {
        if (!_isRetryableAniListFailure(error)) rethrow;
        return _discoverFallback(filters, page: page);
      }
      final retryVariables = Map<String, dynamic>.from(variables)
        ..remove('sort');
      try {
        final results = await _discoverPages(
          query,
          retryVariables,
          logicalPage: page,
        );
        return _sortDiscoverResults(results, filters.sort);
      } catch (retryError) {
        if (!_isRetryableAniListFailure(retryError)) rethrow;
        return _discoverFallback(filters, page: page);
      }
    }
  }

  Future<List<AnimeSummary>> _discoverPages(
    String query,
    Map<String, dynamic> variables, {
    required int logicalPage,
  }) async {
    // Two 30-item pages produce ten rows on the standard TV grid. Keep both
    // requests in one Future so a filter refresh can never render a partial
    // page or combine results belonging to different filter selections.
    final firstApiPage = logicalPage * 2 - 1;
    final pages = await Future.wait([
      for (final page in [firstApiPage, firstApiPage + 1])
        _mediaPage(query, {...variables, 'page': page}),
    ]);
    final uniqueById = <int, AnimeSummary>{};
    for (final page in pages) {
      for (final anime in page) {
        // A boundary duplicate keeps its page-one position and payload.
        uniqueById.putIfAbsent(anime.id, () => anime);
      }
    }
    return uniqueById.values.toList(growable: false);
  }

  Future<List<AiringScheduleEntry>> airingSchedule({
    required DateTime from,
    required DateTime to,
  }) async {
    const query = r'''
      query AiringCalendar($page: Int!, $from: Int!, $to: Int!) {
        Page(page: $page, perPage: 50) {
          pageInfo { hasNextPage }
          airingSchedules(
            airingAt_greater: $from, airingAt_lesser: $to, sort: TIME
          ) {
            episode airingAt
            media {
              id idMal title { userPreferred english romaji }
              description(asHtml: false) episodes averageScore genres
              coverImage { extraLarge } bannerImage format status season
              seasonYear duration synonyms isAdult nextAiringEpisode { episode }
            }
          }
        }
      }
    ''';
    final entries = <AiringScheduleEntry>[];
    var pageNumber = 1;
    var hasNextPage = true;
    // A week normally spans several AniList pages. Fetching only page one
    // made the followed-only calendar appear empty whenever a user's show was
    // outside the first 50 global airings.
    try {
      while (hasNextPage && pageNumber <= 20) {
        final data = await _graphQl(query, {
          'page': pageNumber,
          'from': from.millisecondsSinceEpoch ~/ 1000,
          'to': to.millisecondsSinceEpoch ~/ 1000,
        });
        final page = data['Page'] as Map<String, dynamic>?;
        final schedules =
            page?['airingSchedules'] as List<dynamic>? ?? const [];
        for (final item in schedules.whereType<Map<String, dynamic>>()) {
          final media = item['media'];
          final episode = item['episode'];
          final airingAt = item['airingAt'];
          if (media is! Map<String, dynamic> ||
              episode is! int ||
              airingAt is! int) {
            continue;
          }
          final anime = _mapAnime(media);
          if (anime.isAdult) continue;
          entries.add(
            AiringScheduleEntry(
              anime: anime,
              episode: episode,
              airingAt: DateTime.fromMillisecondsSinceEpoch(airingAt * 1000),
            ),
          );
        }
        final pageInfo = page?['pageInfo'] as Map<String, dynamic>?;
        hasNextPage = pageInfo?['hasNextPage'] == true;
        pageNumber++;
      }
      return entries;
    } catch (error) {
      if (!_isRetryableAniListFailure(error)) rethrow;
      return _jikanAiringFallback(from: from, to: to);
    }
  }

  Future<List<AnimeSummary>> studioAnime(int studioId) async {
    const query = r'''
      query StudioAnime($id: Int!) {
        Studio(id: $id) {
          media(page: 1, perPage: 30, sort: POPULARITY_DESC, isMain: true) {
            nodes {
              id idMal title { userPreferred english romaji }
              description(asHtml: false) episodes averageScore genres
              coverImage { extraLarge } bannerImage format status season
              seasonYear duration synonyms isAdult nextAiringEpisode { episode }
            }
          }
        }
      }
    ''';
    try {
      final data = await _graphQl(query, {'id': studioId});
      final studio = data['Studio'] as Map<String, dynamic>?;
      final media = studio?['media'] as Map<String, dynamic>?;
      return (media?['nodes'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_mapAnime)
          .where((anime) => !anime.isAdult)
          .toList(growable: false);
    } catch (error) {
      if (!_isRetryableAniListFailure(error)) rethrow;
      return _jikanStudioFallback(studioId);
    }
  }

  Future<List<AnimeSummary>> staffAnime(int staffId) async {
    const query = r'''
      query StaffAnime($id: Int!) {
        Staff(id: $id) {
          staffMedia(page: 1, perPage: 30, type: ANIME, sort: POPULARITY_DESC) {
            nodes {
              id idMal title { userPreferred english romaji }
              description(asHtml: false) episodes averageScore genres
              coverImage { extraLarge } bannerImage format status season
              seasonYear duration synonyms isAdult nextAiringEpisode { episode }
            }
          }
        }
      }
    ''';
    try {
      final data = await _graphQl(query, {'id': staffId});
      final staff = data['Staff'] as Map<String, dynamic>?;
      final media = staff?['staffMedia'] as Map<String, dynamic>?;
      return (media?['nodes'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_mapAnime)
          .where((anime) => !anime.isAdult)
          .toList(growable: false);
    } catch (error) {
      if (!_isRetryableAniListFailure(error)) rethrow;
      return _jikanStaffFallback(staffId);
    }
  }

  Future<List<AnimeSummary>> _fallbackCatalogList({
    required String operation,
    required String unavailableMessage,
    required Future<List<AnimeSummary>> Function() kitsuRequest,
    required Future<List<AnimeSummary>> Function() jikanRequest,
    bool preferJikan = false,
  }) async {
    if (preferJikan) {
      try {
        return _uniqueCatalogResults(await jikanRequest());
      } catch (_) {
        // The independent Kitsu backup gets the next bounded attempt.
      }
      try {
        final results = _uniqueCatalogResults(await kitsuRequest());
        _rememberCatalogIdentities(results);
        await _recordCatalogFallback(
          'kitsu-$operation',
          source: CatalogMetadataSource.kitsu,
        );
        return results;
      } catch (_) {
        throw StateError(
          '$unavailableMessage and both read-only backups are temporarily '
          'unavailable. Please try again shortly.',
        );
      }
    }
    try {
      final results = _uniqueCatalogResults(await kitsuRequest());
      _rememberCatalogIdentities(results);
      await _recordCatalogFallback(
        'kitsu-$operation',
        source: CatalogMetadataSource.kitsu,
      );
      return results;
    } catch (_) {
      // The independent Jikan backup gets the next bounded attempt.
    }

    try {
      final results = _uniqueCatalogResults(await jikanRequest());
      _rememberCatalogIdentities(results);
      return results;
    } catch (_) {
      throw StateError(
        '$unavailableMessage and both read-only backups are temporarily '
        'unavailable. Please try again shortly.',
      );
    }
  }

  Future<List<AnimeSummary>> _discoverFallback(
    CatalogFilters filters, {
    required int page,
  }) => _fallbackCatalogList(
    operation: 'discover',
    unavailableMessage: 'Discover',
    preferJikan: true,
    kitsuRequest: () => _kitsu.discover(filters, page: page),
    jikanRequest: () => _jikanDiscoverFallback(filters, page: page),
  );

  Future<AnimeSummary> _jikanDetailsFallback(int aniListId) async {
    final malId = await _resolveMalIdForAniList(aniListId);
    if (malId == null) {
      throw StateError('The second backup could not map this anime.');
    }
    final body = await _jikanGet('anime/$malId/full');
    final resources = _jikanResources(body['data']);
    if (resources.isEmpty) {
      throw StateError('The second backup returned incomplete anime data.');
    }
    final anime = await _mapJikanResource(
      resources.first,
      knownAniListId: aniListId,
    );
    if (anime == null) {
      throw StateError('The second backup returned an unsafe anime mapping.');
    }
    _rememberCatalogIdentities([anime]);
    await _recordCatalogFallback(
      'jikan-details',
      source: CatalogMetadataSource.jikan,
    );
    return anime;
  }

  List<AnimeSummary> _uniqueCatalogResults(Iterable<AnimeSummary> values) {
    final unique = <int, AnimeSummary>{};
    for (final anime in values) {
      if (anime.id <= 0 || anime.isAdult) continue;
      unique.putIfAbsent(anime.id, () => anime);
    }
    return List.unmodifiable(unique.values);
  }

  Future<List<AnimeSummary>> _jikanCatalogFallback({
    required String path,
    required Map<String, dynamic> queryParameters,
    required String diagnosticMode,
    required String unavailableMessage,
    bool allowKitsuIdentityBridge = true,
  }) async {
    try {
      final body = await _jikanGet(path, queryParameters: queryParameters);
      final results = await _mapJikanResources(
        _jikanResources(body['data']),
        allowKitsuIdentityBridge: allowKitsuIdentityBridge,
      );
      _rememberCatalogIdentities(results);
      await _recordCatalogFallback(
        diagnosticMode,
        source: CatalogMetadataSource.jikan,
      );
      return results;
    } catch (_) {
      throw StateError(
        '$unavailableMessage and its read-only backup are temporarily '
        'unavailable. Please try again shortly.',
      );
    }
  }

  Future<List<AnimeSummary>> _jikanDiscoverFallback(
    CatalogFilters filters, {
    required int page,
  }) async {
    try {
      // Jikan does not distinguish AniList's TV_SHORT format from TV. Do not
      // silently fill a TV Short collection with full-length television shows.
      if (filters.format == 'TV_SHORT') {
        await _recordCatalogFallback('jikan-discover-tv-short-unsupported');
        return const [];
      }

      final query = <String, dynamic>{
        'page': page,
        'limit': 25,
        // The toggle is inclusive, not adult-only. Jikan can therefore
        // provide its safe subset during an AniList outage instead of leaving
        // Discover blank; AniList remains authoritative for adult metadata.
        'sfw': true,
      };
      final search = filters.search?.trim();
      final tag = filters.tag?.trim();
      if (search != null && search.isNotEmpty) {
        query['q'] = search;
      }
      final type = _jikanType(filters.format);
      if (type != null) query['type'] = type;
      final status = _jikanStatusFilter(filters.status);
      if (status != null) query['status'] = status;
      if (filters.minimumScore case final score?) {
        query['min_score'] = score / 10;
      }
      final dateRange = _jikanDateRange(filters.season, filters.year);
      if (dateRange case (final start, final end)) {
        query['start_date'] = _isoDate(start);
        query['end_date'] = _isoDate(end);
      }
      final genreIds = <int>{};
      if (filters.genre case final genre?) {
        final genreId = await _jikanGenreId(genre);
        if (genreId == null) {
          await _recordCatalogFallback('jikan-discover-genre-unsupported');
          return const [];
        }
        genreIds.add(genreId);
      }
      if (tag != null && tag.isNotEmpty) {
        // AniList tags do not have a general Jikan equivalent. Only an exact
        // Jikan genre-name match is safe enough to preserve the filter.
        final tagGenreId = await _jikanGenreId(tag);
        if (tagGenreId == null) {
          await _recordCatalogFallback('jikan-discover-tag-unsupported');
          return const [];
        }
        genreIds.add(tagGenreId);
      }
      if (genreIds.isNotEmpty) {
        query['genres'] = genreIds.length == 1
            ? genreIds.single
            : genreIds.join(',');
      }
      final sort = _jikanSort(filters.sort);
      query['order_by'] = sort.$1;
      query['sort'] = sort.$2;

      final body = await _jikanGet('anime', queryParameters: query);
      var results = await _mapJikanResources(_jikanResources(body['data']));
      results = _filterDiscoverFallback(results, filters);
      results = _sortDiscoverResults(results, filters.sort);
      _rememberCatalogIdentities(results);
      await _recordCatalogFallback('jikan-discover');
      return results;
    } catch (_) {
      throw StateError(
        'Discover and its read-only backup are temporarily unavailable. '
        'Please try again shortly.',
      );
    }
  }

  Future<List<AiringScheduleEntry>> _jikanAiringFallback({
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final resources = <int, Map<String, dynamic>>{};
      // Jikan's weekly schedule is paginated. Follow its explicit pagination
      // marker through a small hard bound so a followed show is not limited to
      // the first response page and an unhealthy provider cannot cause an
      // unbounded crawl.
      for (
        var pageNumber = 1;
        pageNumber <= _jikanSchedulePageLimit;
        pageNumber++
      ) {
        final body = await _jikanGet(
          'schedules',
          queryParameters: {
            'page': pageNumber,
            'limit': _jikanSchedulePageSize,
            'sfw': true,
            'kids': false,
            'unapproved': false,
          },
        );
        for (final item in _jikanResources(body['data'])) {
          final malId = _integer(item['mal_id']);
          if (malId != null) resources.putIfAbsent(malId, () => item);
        }
        final pagination = body['pagination'] as Map<String, dynamic>?;
        if (pagination?['has_next_page'] != true) break;
      }

      final entries = <AiringScheduleEntry>[];
      final scheduledItems = <Map<String, dynamic>>[];
      final scheduledTimes = <DateTime>[];
      for (final item in resources.values) {
        final airingAt = _jikanAiringAt(item, from: from, to: to);
        if (airingAt == null) continue;
        scheduledItems.add(item);
        scheduledTimes.add(airingAt);
      }
      final mappedItems = await _mapJikanResourceBatch(scheduledItems);
      for (var index = 0; index < scheduledItems.length; index++) {
        final item = scheduledItems[index];
        final anime = mappedItems[index];
        if (anime == null) continue;
        final episode = _knownJikanEpisode(item, anime);
        if (episode == null) continue;
        entries.add(
          AiringScheduleEntry(
            anime: anime,
            episode: episode,
            airingAt: scheduledTimes[index],
          ),
        );
      }
      entries.sort((left, right) => left.airingAt.compareTo(right.airingAt));
      _rememberCatalogIdentities(entries.map((entry) => entry.anime));
      await _recordCatalogFallback('jikan-airing');
      return List.unmodifiable(entries);
    } catch (_) {
      throw StateError(
        'The airing calendar and its read-only backup are temporarily '
        'unavailable. Please try again shortly.',
      );
    }
  }

  Future<List<AnimeSummary>> _jikanStudioFallback(int studioId) async {
    final name = _knownStudioNames[studioId];
    if (name == null || name.isEmpty) {
      // AniList and MAL/Jikan do not share studio IDs. Without a previously
      // mapped name, returning unrelated studio titles would be worse than an
      // honest empty collection. This branch is only reachable through a
      // stale/deep link because cold backup details expose no studio links.
      await _recordCatalogFallback('jikan-studio-safe-empty');
      return const [];
    }
    try {
      final lookup = await _jikanGet(
        'producers',
        queryParameters: {'q': name, 'limit': 10},
      );
      final producer = _bestJikanNamedMatch(
        _jikanResources(lookup['data']),
        name,
        nameKeys: const ['title'],
      );
      final producerId = _integer(producer?['mal_id']);
      if (producerId == null) return const [];
      final body = await _jikanGet(
        'anime',
        queryParameters: {
          'producers': producerId,
          'order_by': 'popularity',
          'sort': 'asc',
          'limit': 25,
          'sfw': true,
        },
      );
      final results = await _mapJikanResources(_jikanResources(body['data']));
      _rememberCatalogIdentities(results);
      await _recordCatalogFallback('jikan-studio');
      return results;
    } catch (_) {
      throw StateError(
        'Studio titles and their read-only backup are temporarily unavailable. '
        'Please try again shortly.',
      );
    }
  }

  Future<List<AnimeSummary>> _jikanStaffFallback(int staffId) async {
    final name = _knownStaffNames[staffId];
    if (name == null || name.isEmpty) {
      await _recordCatalogFallback('jikan-staff-safe-empty');
      return const [];
    }
    try {
      final lookup = await _jikanGet(
        'people',
        queryParameters: {'q': name, 'limit': 10},
      );
      final person = _bestJikanNamedMatch(
        _jikanResources(lookup['data']),
        name,
        nameKeys: const ['name'],
      );
      final personId = _integer(person?['mal_id']);
      if (personId == null) return const [];
      final body = await _jikanGet('people/$personId/full');
      final data = body['data'];
      final resources = <int, Map<String, dynamic>>{};
      if (data is Map<String, dynamic>) {
        for (final group in ['anime', 'voices']) {
          for (final item in _jikanResources(data[group])) {
            final anime = item['anime'];
            if (anime is! Map<String, dynamic>) continue;
            final malId = _integer(anime['mal_id']);
            if (malId != null) resources.putIfAbsent(malId, () => anime);
          }
        }
      }
      final results = await _mapJikanResources(resources.values.toList());
      _rememberCatalogIdentities(results);
      await _recordCatalogFallback('jikan-staff');
      return results;
    } catch (_) {
      throw StateError(
        'Staff titles and their read-only backup are temporarily unavailable. '
        'Please try again shortly.',
      );
    }
  }

  Future<Map<String, dynamic>> _jikanGet(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final query = queryParameters ?? const <String, dynamic>{};
    final cacheKey =
        'jikan-catalog:${Uri(path: path, queryParameters: query.map((key, value) => MapEntry(key, '$value')))}';
    try {
      final cached = await TetoTvDatabase.instance.cachedJson(cacheKey);
      if (cached != null) return cached;
    } catch (_) {
      // Unit tests and unsupported platforms may not provide sqflite.
    }
    try {
      final response = await _jikanDio.get<Map<String, dynamic>>(
        path,
        queryParameters: query,
      );
      final body = response.data ?? const <String, dynamic>{};
      try {
        await TetoTvDatabase.instance.cacheJson(cacheKey, body);
      } catch (_) {
        // Read-only fallback caching is best effort.
      }
      return body;
    } catch (_) {
      try {
        final stale = await TetoTvDatabase.instance.cachedJson(
          cacheKey,
          allowExpired: true,
          maxStaleAge: _fallbackMaxStaleAge,
        );
        if (stale != null) return stale;
      } catch (_) {
        // Preserve the backup provider failure below.
      }
      rethrow;
    }
  }

  Future<List<AnimeSummary>> _mapJikanResources(
    List<Map<String, dynamic>> resources, {
    bool allowKitsuIdentityBridge = true,
  }) async {
    final unique = <int, AnimeSummary>{};
    final mapped = await _mapJikanResourceBatch(
      resources,
      allowKitsuIdentityBridge: allowKitsuIdentityBridge,
    );
    for (final anime in mapped) {
      if (anime != null) unique.putIfAbsent(anime.id, () => anime);
    }
    return List.unmodifiable(unique.values);
  }

  Future<List<AnimeSummary?>> _mapJikanResourceBatch(
    List<Map<String, dynamic>> resources, {
    bool allowKitsuIdentityBridge = true,
  }) async {
    final mapped = <AnimeSummary?>[];
    for (
      var start = 0;
      start < resources.length;
      start += _jikanMappingConcurrency
    ) {
      final proposedEnd = start + _jikanMappingConcurrency;
      final end = proposedEnd < resources.length
          ? proposedEnd
          : resources.length;
      mapped.addAll(
        await Future.wait(
          resources
              .sublist(start, end)
              .map(
                (resource) => _mapJikanResource(
                  resource,
                  allowKitsuIdentityBridge: allowKitsuIdentityBridge,
                ),
              ),
        ),
      );
    }
    return List.unmodifiable(mapped);
  }

  Future<AnimeSummary?> _mapJikanResource(
    Map<String, dynamic> resource, {
    int? knownAniListId,
    bool allowKitsuIdentityBridge = true,
  }) async {
    final malId = _integer(resource['mal_id']);
    final title = _firstTitle([
      resource['title_english']?.toString(),
      resource['title']?.toString(),
      resource['title_japanese']?.toString(),
    ]);
    if (malId == null || malId <= 0 || title == 'Untitled') return null;
    if (_isJikanAdult(resource)) return null;
    final aniListId =
        knownAniListId ??
        await _resolveAniListIdForMal(
          malId,
          title: title,
          allowKitsuIdentityBridge: allowKitsuIdentityBridge,
        );
    if (aniListId == null || aniListId <= 0) return null;
    final identity = AnimeSummary(
      id: aniListId,
      idMal: malId,
      title: title,
      titleEnglish: resource['title_english']?.toString().trim(),
      titleRomaji: resource['title']?.toString().trim(),
      description: '',
      episodes: null,
      score: null,
      metadataSource: CatalogMetadataSource.jikan,
    );
    return _mergeJikanAnime(identity, resource);
  }

  Future<int?> _resolveAniListIdForMal(
    int malId, {
    required String title,
    bool allowKitsuIdentityBridge = true,
  }) async {
    final known = _knownAniListIdByMalId[malId];
    if (known != null) return known;

    if (allowKitsuIdentityBridge) {
      try {
        final mapped = await _kitsu.search(title);
        // A title-only match can select a remake, sequel, or unrelated title.
        // Accept only Kitsu's explicit mapping to this exact MAL identifier.
        final match = mapped.where((item) => item.idMal == malId).firstOrNull;
        if (match != null) {
          _rememberCatalogIdentities([match]);
          return match.id;
        }
      } catch (_) {
        // The independent crosswalk below remains available.
      }
    }
    // AniZip is an ID crosswalk, not a metadata source. It keeps Jikan's
    // metadata path independent from Kitsu during a cold AniList outage.
    final network = await _aniZipIdentity(malId: malId);
    return network?.$1;
  }

  Future<int?> _resolveMalIdForAniList(int aniListId) async {
    final known = _knownMalIdByAniListId[aniListId];
    if (known != null) return known;
    final network = await _aniZipIdentity(aniListId: aniListId);
    return network?.$2;
  }

  Future<(int, int)?> _aniZipIdentity({int? malId, int? aniListId}) async {
    if ((malId == null) == (aniListId == null)) return null;
    try {
      final response = await _aniZipDio.get<Map<String, dynamic>>(
        'mappings',
        queryParameters: malId != null
            ? {'mal_id': malId}
            : {'anilist_id': aniListId},
      );
      final body = response.data ?? const <String, dynamic>{};
      final mappedAniListId = _integer(body['anilist_id']);
      final mappedMalId = _integer(body['mal_id']);
      if (mappedAniListId == null ||
          mappedAniListId <= 0 ||
          mappedMalId == null ||
          mappedMalId <= 0 ||
          (malId != null && mappedMalId != malId) ||
          (aniListId != null && mappedAniListId != aniListId)) {
        return null;
      }
      _rememberCatalogIdentity(mappedAniListId, mappedMalId);
      return (mappedAniListId, mappedMalId);
    } catch (_) {
      return null;
    }
  }

  void _rememberCatalogIdentities(Iterable<AnimeSummary> values) {
    for (final anime in values) {
      final malId = anime.idMal;
      if (anime.id > 0 && malId != null && malId > 0) {
        _knownAniListIdByMalId[malId] = anime.id;
        _knownMalIdByAniListId[anime.id] = malId;
      }
    }
  }

  void _rememberCatalogIdentity(int aniListId, int malId) {
    _knownAniListIdByMalId[malId] = aniListId;
    _knownMalIdByAniListId[aniListId] = malId;
  }

  AnimeSummary _mergeJikanAnime(
    AnimeSummary mapped,
    Map<String, dynamic> resource,
  ) {
    final images = resource['images'];
    final jpg = images is Map<String, dynamic>
        ? images['jpg'] as Map<String, dynamic>?
        : null;
    final genres = <String>{
      ...mapped.genres,
      for (final key in ['genres', 'themes', 'demographics'])
        ..._jikanResources(resource[key])
            .map((item) => item['name']?.toString().trim())
            .whereType<String>()
            .where((value) => value.isNotEmpty),
    };
    final aired = resource['aired'] as Map<String, dynamic>?;
    final start = DateTime.tryParse(aired?['from']?.toString() ?? '');
    final englishTitle = resource['title_english']?.toString().trim();
    final synopsis = _plainText(resource['synopsis']?.toString() ?? '');
    final jikanCover = jpg?['large_image_url']?.toString().trim();
    final trailer = resource['trailer'] as Map<String, dynamic>?;
    final trailerImages = trailer?['images'] as Map<String, dynamic>?;
    return AnimeSummary(
      id: mapped.id,
      idMal: mapped.idMal,
      title: mapped.title,
      titleEnglish: englishTitle == null || englishTitle.isEmpty
          ? mapped.titleEnglish
          : englishTitle,
      titleRomaji: mapped.titleRomaji,
      description: synopsis.isEmpty ? mapped.description : synopsis,
      episodes: _integer(resource['episodes']) ?? mapped.episodes,
      score: (resource['score'] as num?)?.toDouble() ?? mapped.score,
      coverImageUrl: jikanCover == null || jikanCover.isEmpty
          ? mapped.coverImageUrl
          : jikanCover,
      bannerImageUrl: mapped.bannerImageUrl,
      trailer:
          AnimeTrailer.tryCreate(
            provider: 'youtube',
            videoId: trailer?['youtube_id'],
            thumbnailUrl:
                trailerImages?['maximum_image_url'] ??
                trailerImages?['large_image_url'] ??
                trailerImages?['image_url'],
          ) ??
          mapped.trailer,
      genres: List.unmodifiable(genres),
      synonyms: mapped.synonyms,
      format: _jikanFormat(resource['type']?.toString()) ?? mapped.format,
      status: _jikanStatus(resource['status']?.toString()) ?? mapped.status,
      season: resource['season']?.toString().toUpperCase() ?? mapped.season,
      seasonYear:
          _integer(resource['year']) ?? start?.year ?? mapped.seasonYear,
      durationMinutes:
          _jikanDurationMinutes(resource['duration']?.toString()) ??
          mapped.durationMinutes,
      nextAiringEpisode: mapped.nextAiringEpisode,
      isAdult: mapped.isAdult,
      relatedAnime: mapped.relatedAnime,
      studios: mapped.studios,
      staff: mapped.staff,
      characters: mapped.characters,
      metadataSource: CatalogMetadataSource.jikan,
    );
  }

  List<Map<String, dynamic>> _jikanResources(dynamic value) {
    if (value is Map<String, dynamic>) return [value];
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  Future<int?> _jikanGenreId(String genre) async {
    final body = await _jikanGet('genres/anime');
    final normalized = _normalizeCatalogName(genre);
    for (final item in _jikanResources(body['data'])) {
      if (_normalizeCatalogName(item['name']?.toString() ?? '') == normalized) {
        return _integer(item['mal_id']);
      }
    }
    return null;
  }

  Map<String, dynamic>? _bestJikanNamedMatch(
    List<Map<String, dynamic>> values,
    String expected, {
    required List<String> nameKeys,
  }) {
    final normalized = _normalizeCatalogName(expected);
    if (normalized.isEmpty) return null;
    final matches = values
        .where(
          (item) => nameKeys.any(
            (key) =>
                _normalizeCatalogName(item[key]?.toString() ?? '') ==
                normalized,
          ),
        )
        .take(2)
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  DateTime? _jikanAiringAt(
    Map<String, dynamic> item, {
    required DateTime from,
    required DateTime to,
  }) {
    final broadcast = item['broadcast'] as Map<String, dynamic>?;
    final weekday = _jikanWeekday(broadcast?['day']?.toString());
    final time = broadcast?['time']?.toString().split(':');
    if (weekday == null || time == null || time.length < 2) return null;
    final hour = int.tryParse(time[0]);
    final minute = int.tryParse(time[1]);
    if (hour == null || minute == null) return null;
    final offset = _jikanTimezoneOffset(broadcast?['timezone']?.toString());
    var localDay = DateTime.utc(
      from.toUtc().year,
      from.toUtc().month,
      from.toUtc().day,
    ).subtract(const Duration(days: 1));
    final lastDay = to.toUtc().add(const Duration(days: 1));
    while (localDay.isBefore(lastDay)) {
      if (localDay.weekday == weekday) {
        final utc = DateTime.utc(
          localDay.year,
          localDay.month,
          localDay.day,
          hour,
          minute,
        ).subtract(offset);
        if (!utc.isBefore(from.toUtc()) && utc.isBefore(to.toUtc())) {
          return utc;
        }
      }
      localDay = localDay.add(const Duration(days: 1));
    }
    return null;
  }

  int? _knownJikanEpisode(Map<String, dynamic> item, AnimeSummary anime) {
    final mappedEpisode = anime.nextAiringEpisode;
    if (mappedEpisode != null && mappedEpisode > 0) return mappedEpisode;
    // A single-episode title has an unambiguous episode number. For series,
    // deriving an episode from weeks since the start date fails across delays,
    // double broadcasts, recaps, and hiatuses, so omit it rather than claim a
    // guessed episode is authoritative.
    final total = _integer(item['episodes']);
    return total == 1 ? 1 : null;
  }

  bool _isJikanAdult(Map<String, dynamic> item) {
    final rating = _normalizeCatalogName(item['rating']?.toString() ?? '');
    if (rating.startsWith('rx ') ||
        rating == 'rx' ||
        rating.contains('hentai') ||
        rating.contains('explicit sex')) {
      return true;
    }
    const blocked = {'hentai', 'erotica', 'explicit sex'};
    for (final key in ['genres', 'themes', 'demographics']) {
      for (final value in _jikanResources(item[key])) {
        final name = _normalizeCatalogName(value['name']?.toString() ?? '');
        if (blocked.contains(name)) return true;
      }
    }
    return false;
  }

  int? _integer(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  String _normalizeCatalogName(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  String? _jikanType(String? format) => switch (format) {
    'TV' || 'TV_SHORT' => 'tv',
    'MOVIE' => 'movie',
    'SPECIAL' => 'special',
    'OVA' => 'ova',
    'ONA' => 'ona',
    'MUSIC' => 'music',
    _ => null,
  };

  String? _jikanStatusFilter(String? status) => switch (status) {
    'RELEASING' => 'airing',
    'FINISHED' || 'CANCELLED' => 'complete',
    'NOT_YET_RELEASED' || 'HIATUS' => 'upcoming',
    _ => null,
  };

  (DateTime, DateTime)? _jikanDateRange(String? season, int? year) {
    if (year == null) return null;
    return switch (season) {
      'WINTER' => (DateTime.utc(year), DateTime.utc(year, 3, 31)),
      'SPRING' => (DateTime.utc(year, 4), DateTime.utc(year, 6, 30)),
      'SUMMER' => (DateTime.utc(year, 7), DateTime.utc(year, 9, 30)),
      'FALL' => (DateTime.utc(year, 10), DateTime.utc(year, 12, 31)),
      _ => (DateTime.utc(year), DateTime.utc(year, 12, 31)),
    };
  }

  (String, String) _jikanSort(String sort) => switch (sort) {
    'SCORE_DESC' => ('score', 'desc'),
    'START_DATE_DESC' => ('start_date', 'desc'),
    'TITLE_ENGLISH' => ('title', 'asc'),
    'FAVOURITES_DESC' => ('favorites', 'desc'),
    // Jikan popularity is a rank where 1 is the most popular title.
    _ => ('popularity', 'asc'),
  };

  List<AnimeSummary> _filterDiscoverFallback(
    List<AnimeSummary> values,
    CatalogFilters filters,
  ) {
    final genre = filters.genre?.trim().toLowerCase();
    final tag = filters.tag?.trim().toLowerCase();
    return values
        .where((anime) {
          if (!filters.includeAdult && anime.isAdult) return false;
          if (genre != null &&
              genre.isNotEmpty &&
              !anime.genres.any((item) => item.toLowerCase() == genre)) {
            return false;
          }
          if (tag != null &&
              tag.isNotEmpty &&
              !anime.genres.any((item) => item.toLowerCase() == tag)) {
            return false;
          }
          if (filters.format != null && anime.format != filters.format) {
            return false;
          }
          if (filters.status != null && anime.status != filters.status) {
            return false;
          }
          if (filters.season != null && anime.season != filters.season) {
            return false;
          }
          if (filters.year != null && anime.seasonYear != filters.year) {
            return false;
          }
          if (filters.minimumScore case final minimum?) {
            if (anime.score == null || anime.score! * 10 < minimum) {
              return false;
            }
          }
          return true;
        })
        .toList(growable: false);
  }

  String? _jikanFormat(String? value) => switch (value?.toLowerCase()) {
    'tv' => 'TV',
    'movie' => 'MOVIE',
    'special' || 'tv special' => 'SPECIAL',
    'ova' => 'OVA',
    'ona' => 'ONA',
    'music' => 'MUSIC',
    _ => null,
  };

  String? _jikanStatus(String? value) {
    final normalized = value?.toLowerCase() ?? '';
    if (normalized.contains('currently airing')) return 'RELEASING';
    if (normalized.contains('finished airing')) return 'FINISHED';
    if (normalized.contains('not yet aired')) return 'NOT_YET_RELEASED';
    return null;
  }

  int? _jikanDurationMinutes(String? value) {
    final match = RegExp(
      r'(\d+)\s*min',
      caseSensitive: false,
    ).firstMatch(value ?? '');
    return int.tryParse(match?.group(1) ?? '');
  }

  String _isoDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  int? _jikanWeekday(String? value) =>
      switch (value?.toLowerCase().replaceAll('s', '')) {
        'monday' => DateTime.monday,
        'tuesday' => DateTime.tuesday,
        'wednesday' => DateTime.wednesday,
        'thursday' => DateTime.thursday,
        'friday' => DateTime.friday,
        'saturday' => DateTime.saturday,
        'sunday' => DateTime.sunday,
        _ => null,
      };

  Duration _jikanTimezoneOffset(String? value) {
    final normalized = value?.trim().toLowerCase() ?? '';
    if (normalized == 'utc' || normalized == 'etc/utc') return Duration.zero;
    if (normalized == 'asia/tokyo' || normalized == 'jst') {
      return const Duration(hours: 9);
    }
    final match = RegExp(
      r'(?:gmt|utc)([+-])(\d{1,2})(?::?(\d{2}))?',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (match != null) {
      final sign = match.group(1) == '-' ? -1 : 1;
      final hours = int.tryParse(match.group(2) ?? '') ?? 0;
      final minutes = int.tryParse(match.group(3) ?? '') ?? 0;
      return Duration(minutes: sign * (hours * 60 + minutes));
    }
    // Jikan schedules are Japanese broadcast schedules; use JST when an old
    // response omits the otherwise standard `Asia/Tokyo` timezone field.
    return const Duration(hours: 9);
  }

  Future<List<AnimeSummary>> franchise(int mediaId) async {
    final root = await details(mediaId);
    final values = <int, AnimeSummary>{root.id: root};
    for (final relation in root.relatedAnime) {
      values[relation.anime.id] = relation.anime;
    }
    final directIds = root.relatedAnime
        .where(
          (item) =>
              const ['SEQUEL', 'PREQUEL', 'PARENT'].contains(item.relationType),
        )
        .map((item) => item.anime.id)
        .take(8);
    final expanded = await Future.wait(directIds.map(details));
    for (final anime in expanded) {
      values[anime.id] = anime;
      for (final relation in anime.relatedAnime) {
        if (const [
          'SEQUEL',
          'PREQUEL',
          'PARENT',
        ].contains(relation.relationType)) {
          values[relation.anime.id] = relation.anime;
        }
      }
    }
    final result = values.values.toList();
    result.sort((a, b) {
      final year = (a.seasonYear ?? 9999).compareTo(b.seasonYear ?? 9999);
      if (year != 0) return year;
      return a.id.compareTo(b.id);
    });
    return result;
  }

  Future<List<AnimeSummary>> _mediaPage(
    String query,
    Map<String, dynamic> variables, {
    bool useStaleOnError = true,
  }) async {
    final data = await _graphQl(
      query,
      variables,
      useStaleOnError: useStaleOnError,
    );
    final pageData = data['Page'] as Map<String, dynamic>?;
    final media = pageData?['media'] as List<dynamic>? ?? const [];
    final results = media
        .whereType<Map<String, dynamic>>()
        .map(_mapAnime)
        .toList(growable: false);
    _rememberCatalogIdentities(results);
    return results;
  }

  Future<Map<String, dynamic>> _graphQl(
    String query,
    Map<String, dynamic> variables, {
    bool useStaleOnError = true,
  }) async {
    final cacheKey =
        'anilist:${jsonEncode({'query': query, 'variables': variables})}';
    try {
      final cached = await TetoTvDatabase.instance.cachedJson(cacheKey);
      if (cached != null) return cached;
    } catch (_) {
      // Unit tests and unsupported platforms may not provide sqflite.
    }
    Map<String, dynamic> body;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '',
        data: {'query': query, 'variables': variables},
      );
      body = response.data ?? const {};
    } on DioException catch (error, stackTrace) {
      final failure = _aniListFailureFromDio(error);
      if (useStaleOnError && failure.retryable) {
        final stale = await _staleGraphQlData(cacheKey, 'saved-network');
        if (stale != null) return stale;
      }
      Error.throwWithStackTrace(failure, stackTrace);
    }
    if (body['errors'] case final List<dynamic> errors when errors.isNotEmpty) {
      final failure = _aniListFailureFromGraphQl(errors);
      if (useStaleOnError && failure.retryable) {
        final stale = await _staleGraphQlData(cacheKey, 'saved-graphql');
        if (stale != null) return stale;
      }
      throw failure;
    }
    final data = body['data'] as Map<String, dynamic>? ?? const {};
    try {
      await TetoTvDatabase.instance.cacheJson(cacheKey, data);
    } catch (_) {
      // Catalog caching is a best-effort performance optimization.
    }
    return data;
  }

  AniListCatalogException _aniListFailureFromDio(DioException error) {
    final status = error.response?.statusCode;
    final message =
        _graphQlErrorMessage(error.response?.data) ??
        _safeAniListFailureMessage(status);
    final retryableTransport = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      _ => false,
    };
    final retryableMessage = _isRetryableAniListMessage(message);
    final clientFailure =
        status != null &&
        status >= 400 &&
        status <= 499 &&
        !_isRetryableStatus(status);
    return AniListCatalogException(
      message,
      retryable:
          retryableMessage ||
          _isRetryableStatus(status) ||
          (retryableTransport && !clientFailure),
    );
  }

  AniListCatalogException _aniListFailureFromGraphQl(List<dynamic> errors) {
    final first = errors.first;
    final error = first is Map ? first : const <String, dynamic>{};
    final message = error['message']?.toString().trim();
    final status = _integer(error['status']);
    final safeMessage = message == null || message.isEmpty
        ? 'AniList request failed.'
        : message;
    final retryableMessage = _isRetryableAniListMessage(safeMessage);
    final clientFailure =
        status != null &&
        status >= 400 &&
        status <= 499 &&
        !_isRetryableStatus(status);
    return AniListCatalogException(
      safeMessage,
      retryable:
          retryableMessage || (_isRetryableStatus(status) && !clientFailure),
    );
  }

  bool _isRetryableStatus(int? status) =>
      status == 408 ||
      status == 425 ||
      status == 429 ||
      (status != null && status >= 500 && status <= 599);

  bool _isRetryableAniListMessage(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('temporarily disabled') ||
        normalized.contains('temporarily unavailable') ||
        normalized.contains('service unavailable') ||
        normalized.contains('internal server error') ||
        normalized.contains('rate limit') ||
        normalized.contains('timed out') ||
        normalized.contains('timeout');
  }

  String _safeAniListFailureMessage(int? status) => switch (status) {
    401 || 403 => 'AniList rejected this request.',
    404 => 'Anime not found.',
    400 || 422 => 'AniList could not process this request.',
    _ => 'AniList is temporarily unavailable.',
  };

  Future<Map<String, dynamic>?> _staleGraphQlData(
    String cacheKey,
    String mode,
  ) async {
    try {
      final stale = await TetoTvDatabase.instance.cachedJson(
        cacheKey,
        allowExpired: true,
        maxStaleAge: _fallbackMaxStaleAge,
      );
      if (stale == null) return null;
      await _recordCatalogFallback(mode);
      return stale;
    } catch (_) {
      // Preserve the original AniList failure when local cache access fails.
      return null;
    }
  }

  Future<void> _recordCatalogFallback(
    String mode, {
    CatalogMetadataSource? source,
  }) async {
    // Never store the GraphQL query, variables, search term, media ID, URL,
    // response payload or account state. A fixed mode is enough to prove that
    // read-only fallback resilience was used in a shared diagnostic report.
    try {
      await TetoTvDatabase.instance.recordDiagnosticEvent(
        category: 'catalog-fallback',
        message: 'Read-only catalog fallback used',
        details: {
          'mode': mode,
          'service': (source ?? _fallbackSourceForMode(mode)).name,
        },
      );
    } catch (_) {
      // A diagnostic write can never invalidate a successful catalog fallback.
    }
  }

  CatalogMetadataSource _fallbackSourceForMode(String mode) {
    if (mode.startsWith('kitsu-')) return CatalogMetadataSource.kitsu;
    if (mode.startsWith('jikan-')) return CatalogMetadataSource.jikan;
    return CatalogMetadataSource.aniList;
  }

  AnimeSummary _mapAnime(Map<String, dynamic> item) {
    final title = item['title'] as Map<String, dynamic>?;
    final cover = item['coverImage'] as Map<String, dynamic>?;
    final score = item['averageScore'] as num?;
    final airing = item['nextAiringEpisode'] as Map<String, dynamic>?;
    final trailer = item['trailer'] as Map<String, dynamic>?;
    final titleEnglish = title?['english'] as String?;
    final titleRomaji = title?['romaji'] as String?;
    final userPreferred = title?['userPreferred'] as String?;
    final studios = _mapStudios(item['studios']);
    final staff = _mapStaff(item['staff']);
    for (final studio in studios) {
      _knownStudioNames[studio.id] = studio.name;
    }
    for (final person in staff) {
      _knownStaffNames[person.id] = person.name;
    }
    return AnimeSummary(
      id: item['id'] as int,
      idMal: item['idMal'] as int?,
      title: _firstTitle([titleEnglish, titleRomaji, userPreferred]),
      titleEnglish: titleEnglish,
      titleRomaji: titleRomaji,
      description: _plainText(item['description'] as String? ?? ''),
      episodes: item['episodes'] as int?,
      score: score == null ? null : score.toDouble() / 10,
      coverImageUrl: cover?['extraLarge'] as String?,
      bannerImageUrl: item['bannerImage'] as String?,
      trailer: AnimeTrailer.tryCreate(
        provider: trailer?['site'],
        videoId: trailer?['id'],
        thumbnailUrl: trailer?['thumbnail'],
      ),
      genres: (item['genres'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      synonyms: (item['synonyms'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      format: item['format'] as String?,
      status: item['status'] as String?,
      season: item['season'] as String?,
      seasonYear: item['seasonYear'] as int?,
      durationMinutes: item['duration'] as int?,
      nextAiringEpisode: airing?['episode'] as int?,
      isAdult: item['isAdult'] == true,
      relatedAnime: _mapRelations(item['relations']),
      studios: studios,
      staff: staff,
      characters: _mapCharacters(item['characters']),
    );
  }

  List<AnimeStudio> _mapStudios(dynamic data) {
    if (data is! Map<String, dynamic>) return const [];
    return (data['nodes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (item) =>
              AnimeStudio(id: item['id'] as int, name: item['name'] as String),
        )
        .toList(growable: false);
  }

  AnimePerson _mapPerson(Map<String, dynamic> item) {
    final name = item['name'] as Map<String, dynamic>?;
    final image = item['image'] as Map<String, dynamic>?;
    return AnimePerson(
      id: item['id'] as int,
      name: name?['full'] as String? ?? 'Unknown',
      imageUrl: image?['large'] as String?,
    );
  }

  List<AnimePerson> _mapStaff(dynamic data) {
    if (data is! Map<String, dynamic>) return const [];
    return (data['nodes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_mapPerson)
        .toList(growable: false);
  }

  List<AnimeCharacter> _mapCharacters(dynamic data) {
    if (data is! Map<String, dynamic>) return const [];
    return (data['edges'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((edge) {
          final node = edge['node'] as Map<String, dynamic>;
          final name = node['name'] as Map<String, dynamic>?;
          final image = node['image'] as Map<String, dynamic>?;
          final voices = (edge['voiceActors'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>();
          return AnimeCharacter(
            id: node['id'] as int,
            name: name?['full'] as String? ?? 'Unknown',
            imageUrl: image?['large'] as String?,
            role: edge['role'] as String?,
            voiceActor: voices.isEmpty ? null : _mapPerson(voices.first),
          );
        })
        .toList(growable: false);
  }

  List<RelatedAnime> _mapRelations(dynamic data) {
    if (data is! Map<String, dynamic>) return const [];
    final edges = data['edges'];
    if (edges is! List) return const [];
    final related = edges
        .whereType<Map<String, dynamic>>()
        .map((edge) {
          final node = edge['node'];
          if (node is! Map<String, dynamic> || node['type'] != 'ANIME') {
            return null;
          }
          return RelatedAnime(
            anime: _mapAnime(node),
            relationType:
                edge['relationType']?.toString().replaceAll('_', ' ') ??
                'RELATED',
          );
        })
        .whereType<RelatedAnime>()
        .toList();
    related.sort((a, b) {
      final relation = _relationPriority(
        a.relationType,
      ).compareTo(_relationPriority(b.relationType));
      if (relation != 0) return relation;
      final year = (a.anime.seasonYear ?? 9999).compareTo(
        b.anime.seasonYear ?? 9999,
      );
      if (year != 0) return year;
      return a.anime.title.toLowerCase().compareTo(b.anime.title.toLowerCase());
    });
    return List.unmodifiable(related);
  }

  int _relationPriority(String relationType) => switch (relationType) {
    'SEQUEL' => 0,
    'PREQUEL' => 1,
    'PARENT' => 2,
    'SIDE STORY' => 3,
    'SPIN OFF' => 4,
    'SOURCE' || 'ADAPTATION' => 5,
    'ALTERNATIVE' => 6,
    'SUMMARY' => 7,
    'CHARACTER' => 8,
    _ => 9,
  };

  String _firstTitle(List<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return 'Untitled';
  }

  String? _graphQlErrorMessage(dynamic body) {
    if (body is! Map) return null;
    final errors = body['errors'];
    if (errors is! List || errors.isEmpty) return null;
    final first = errors.first;
    if (first is! Map) return null;
    final message = first['message']?.toString().trim();
    return message == null || message.isEmpty ? null : message;
  }

  String _plainText(String value) {
    return value
        .replaceAll(RegExp('<br\\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp('<[^>]+>'), '')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&#039;', "'")
        .trim();
  }
}

bool _isRetryableAniListFailure(Object error) =>
    error is AniListCatalogException && error.retryable;

bool _isIllegalDiscoverCombination(Object error) {
  final message = switch (error) {
    AniListCatalogException(:final message) => message.toLowerCase(),
    StateError(:final message) => message.toString().toLowerCase(),
    _ => '',
  };
  return message.contains('illegal operation') &&
      message.contains('value combination');
}

List<AnimeSummary> _sortDiscoverResults(
  List<AnimeSummary> values,
  String sort,
) {
  final results = List<AnimeSummary>.of(values);
  int compareNullableNum(num? left, num? right, {required bool descending}) {
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return descending ? right.compareTo(left) : left.compareTo(right);
  }

  switch (sort) {
    case 'SCORE_DESC':
      results.sort(
        (a, b) => compareNullableNum(a.score, b.score, descending: true),
      );
      break;
    case 'START_DATE_DESC':
      results.sort(
        (a, b) =>
            compareNullableNum(a.seasonYear, b.seasonYear, descending: true),
      );
      break;
    case 'TITLE_ENGLISH':
      results.sort(
        (a, b) => (a.titleEnglish ?? a.title).toLowerCase().compareTo(
          (b.titleEnglish ?? b.title).toLowerCase(),
        ),
      );
      break;
    default:
      // Popularity, trending, and favourites do not exist on AnimeSummary.
      // Preserve AniList's fallback order for those choices.
      break;
  }
  return results;
}
