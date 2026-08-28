import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:dio/dio.dart';

abstract interface class FillerEpisodeCacheStore {
  Future<Map<String, dynamic>?> read(String key);

  Future<void> write(
    String key,
    Map<String, dynamic> payload, {
    required Duration maxAge,
  });
}

class TetoTvFillerEpisodeCacheStore implements FillerEpisodeCacheStore {
  const TetoTvFillerEpisodeCacheStore();

  @override
  Future<Map<String, dynamic>?> read(String key) =>
      TetoTvDatabase.instance.cachedJson(key);

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> payload, {
    required Duration maxAge,
  }) => TetoTvDatabase.instance.cacheJson(key, payload, maxAge: maxAge);
}

/// Read-only filler metadata backed by Jikan's documented MAL episode API.
///
/// AnimeFillerList is intentionally not scraped here: it has no public API or
/// data license, and its HTML/slug mapping is not a stable application
/// contract. Jikan exposes a typed `filler` value for each MAL episode and
/// documents public read-only access and rate limits.
class JikanFillerEpisodeRepository implements FillerEpisodeRepository {
  JikanFillerEpisodeRepository({
    Dio? dio,
    FillerEpisodeCacheStore? cacheStore,
    this.cacheTtl = const Duration(hours: 24),
    this.minimumRequestInterval = const Duration(milliseconds: 350),
    this.maximumCachedSeries = 24,
    this.maximumConcurrentLookups = 4,
    this.maximumRequestsPerMinute = 60,
    this.maximumPages = 24,
    this.maximumEpisodes = 2400,
    this.maximumResponseBytes = 512 * 1024,
    DateTime Function()? clock,
  }) : assert(maximumCachedSeries > 0),
       assert(maximumConcurrentLookups > 0),
       assert(maximumRequestsPerMinute > 0),
       assert(maximumPages > 0),
       assert(maximumEpisodes > 0),
       assert(maximumResponseBytes > 0),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: 'https://api.jikan.moe/v4/',
               connectTimeout: const Duration(seconds: 6),
               sendTimeout: const Duration(seconds: 6),
               receiveTimeout: const Duration(seconds: 10),
               headers: const {'Accept': 'application/json'},
             ),
           ),
       _cacheStore = cacheStore ?? const TetoTvFillerEpisodeCacheStore(),
       _clock = clock ?? DateTime.now;

  static const _cacheSchema = 1;
  static const _cachePrefix = 'filler:jikan:v1:';
  static const _maximumSearchResults = 8;
  static const _maximumTitleLength = 128;
  static const _maximumEpisodeNumber = 100000;

  final Dio _dio;
  final FillerEpisodeCacheStore _cacheStore;
  final DateTime Function() _clock;
  final Duration cacheTtl;
  final Duration minimumRequestInterval;
  final int maximumCachedSeries;
  final int maximumConcurrentLookups;
  final int maximumRequestsPerMinute;
  final int maximumPages;
  final int maximumEpisodes;
  final int maximumResponseBytes;

  final LinkedHashMap<String, FillerEpisodeLookup> _memoryCache =
      LinkedHashMap<String, FillerEpisodeLookup>();
  final Map<String, Future<FillerEpisodeLookup>> _inFlight = {};
  final Queue<DateTime> _scheduledRequests = Queue<DateTime>();
  DateTime? _nextRequestAt;

  @override
  Future<FillerEpisodeLookup> lookup(
    FillerSeriesIdentity identity, {
    bool forceRefresh = false,
  }) async {
    if (identity.anilistMediaId <= 0 ||
        (identity.malMediaId != null && identity.malMediaId! <= 0)) {
      return FillerEpisodeLookup.unavailable(
        reason: FillerUnavailableReason.invalidIdentity,
      );
    }

    final requestKey = _requestCacheKey(identity);
    final pending = _inFlight[requestKey];
    if (pending != null) return pending;
    if (_inFlight.length >= maximumConcurrentLookups) {
      return FillerEpisodeLookup.unavailable(
        reason: FillerUnavailableReason.boundedLimit,
      );
    }

    final operation = _lookupAfterCache(
      identity,
      requestKey,
      forceRefresh: forceRefresh,
    );
    _inFlight[requestKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[requestKey], operation)) {
        _inFlight.remove(requestKey);
      }
    }
  }

  Future<FillerEpisodeLookup> _lookupAfterCache(
    FillerSeriesIdentity identity,
    String requestKey, {
    required bool forceRefresh,
  }) async {
    if (!forceRefresh) {
      final cached = await _readCache(
        requestKey,
        expectedMalMediaId: identity.malMediaId,
      );
      if (cached != null) return cached;
    }
    return _lookupFromNetwork(identity, requestKey);
  }

  Future<FillerEpisodeLookup> _lookupFromNetwork(
    FillerSeriesIdentity identity,
    String requestKey,
  ) async {
    try {
      final directMalId = identity.malMediaId;
      final resolved = directMalId != null
          ? (malId: directMalId, source: FillerDataSource.jikanMalId)
          : await _resolveMalIdByExactTitle(identity);
      final lookup = await _fetchEpisodes(
        malMediaId: resolved.malId,
        source: resolved.source,
      );
      _putMemory(requestKey, lookup);
      final malKey = _malCacheKey(resolved.malId);
      _putMemory(malKey, lookup);
      final payload = _toCacheJson(lookup);
      try {
        await _cacheStore.write(requestKey, payload, maxAge: cacheTtl);
        if (malKey != requestKey) {
          await _cacheStore.write(malKey, payload, maxAge: cacheTtl);
        }
      } catch (_) {
        // Cache availability must not turn confirmed metadata into a failure.
      }
      return lookup;
    } on _FillerLookupFailure catch (failure) {
      return FillerEpisodeLookup.unavailable(reason: failure.reason);
    } on DioException {
      return FillerEpisodeLookup.unavailable(
        reason: FillerUnavailableReason.network,
      );
    } on FormatException {
      return FillerEpisodeLookup.unavailable(
        reason: FillerUnavailableReason.invalidResponse,
      );
    } catch (_) {
      return FillerEpisodeLookup.unavailable(
        reason: FillerUnavailableReason.unknown,
      );
    }
  }

  Future<({int malId, FillerDataSource source})> _resolveMalIdByExactTitle(
    FillerSeriesIdentity identity,
  ) async {
    final localTitles = identity.titles
        .map(_normalizeTitle)
        .where((title) => title.length >= 2)
        .toSet();
    final query = identity.titles
        .where(
          (title) =>
              title.length <= _maximumTitleLength &&
              _normalizeTitle(title).length >= 2,
        )
        .firstOrNull;
    if (localTitles.isEmpty || query == null) {
      throw const _FillerLookupFailure(
        FillerUnavailableReason.missingMalMapping,
      );
    }

    final body = await _getJson(
      'anime',
      queryParameters: <String, dynamic>{
        'q': query,
        'limit': _maximumSearchResults,
        'sfw': true,
      },
    );
    final rows = body['data'];
    if (rows is! List || rows.length > _maximumSearchResults) {
      throw const _FillerLookupFailure(FillerUnavailableReason.invalidResponse);
    }

    final matches = <int>{};
    for (final value in rows) {
      if (value is! Map) continue;
      final candidate = Map<String, dynamic>.from(value);
      final malId = candidate['mal_id'];
      if (malId is! int || malId <= 0) continue;
      final aliases = _candidateTitles(
        candidate,
      ).map(_normalizeTitle).where((title) => title.isNotEmpty).toSet();
      if (!aliases.any(localTitles.contains)) continue;

      final expectedEpisodes = identity.expectedEpisodes;
      final remoteEpisodes = candidate['episodes'];
      if (expectedEpisodes != null &&
          expectedEpisodes > 0 &&
          remoteEpisodes is int &&
          remoteEpisodes > 0 &&
          remoteEpisodes != expectedEpisodes) {
        continue;
      }
      final expectedYear = identity.seasonYear;
      final remoteYear = candidate['year'];
      if (expectedYear != null &&
          expectedYear > 0 &&
          remoteYear is int &&
          remoteYear > 0 &&
          remoteYear != expectedYear) {
        continue;
      }

      final episodesCorroborate =
          expectedEpisodes != null &&
          expectedEpisodes > 0 &&
          remoteEpisodes is int &&
          remoteEpisodes == expectedEpisodes;
      final yearCorroborates =
          expectedYear != null &&
          expectedYear > 0 &&
          remoteYear is int &&
          remoteYear == expectedYear;
      if (!episodesCorroborate && !yearCorroborates) continue;
      matches.add(malId);
    }

    if (matches.length != 1) {
      throw const _FillerLookupFailure(FillerUnavailableReason.ambiguousTitle);
    }
    return (malId: matches.single, source: FillerDataSource.jikanExactTitle);
  }

  Future<FillerEpisodeLookup> _fetchEpisodes({
    required int malMediaId,
    required FillerDataSource source,
  }) async {
    final fillerEpisodes = <int>{};
    final knownEpisodes = <int>{};
    int? expectedPages;

    for (var page = 1; ; page++) {
      if (page > maximumPages) {
        throw const _FillerLookupFailure(FillerUnavailableReason.boundedLimit);
      }
      final body = await _getJson(
        'anime/$malMediaId/episodes',
        queryParameters: <String, dynamic>{'page': page},
      );
      final pagination = body['pagination'];
      final rows = body['data'];
      if (pagination is! Map || rows is! List) {
        throw const _FillerLookupFailure(
          FillerUnavailableReason.invalidResponse,
        );
      }
      final lastPage = pagination['last_visible_page'];
      final hasNext = pagination['has_next_page'];
      if (lastPage is! int ||
          lastPage <= 0 ||
          lastPage > maximumPages ||
          hasNext is! bool ||
          (expectedPages != null && expectedPages != lastPage) ||
          hasNext != (page < lastPage)) {
        final reason = lastPage is int && lastPage > maximumPages
            ? FillerUnavailableReason.boundedLimit
            : FillerUnavailableReason.invalidResponse;
        throw _FillerLookupFailure(reason);
      }
      expectedPages ??= lastPage;
      if (page > lastPage || rows.length > maximumEpisodes) {
        throw const _FillerLookupFailure(FillerUnavailableReason.boundedLimit);
      }

      for (final value in rows) {
        if (value is! Map) {
          throw const _FillerLookupFailure(
            FillerUnavailableReason.invalidResponse,
          );
        }
        final episode = value['mal_id'];
        final filler = value['filler'];
        if (episode is! int ||
            episode <= 0 ||
            episode > _maximumEpisodeNumber ||
            filler is! bool ||
            !knownEpisodes.add(episode)) {
          throw const _FillerLookupFailure(
            FillerUnavailableReason.invalidResponse,
          );
        }
        if (knownEpisodes.length > maximumEpisodes) {
          throw const _FillerLookupFailure(
            FillerUnavailableReason.boundedLimit,
          );
        }
        if (filler) fillerEpisodes.add(episode);
      }

      if (!hasNext) break;
    }

    if (knownEpisodes.isEmpty) {
      throw const _FillerLookupFailure(FillerUnavailableReason.invalidResponse);
    }
    for (var episode = 1; episode <= knownEpisodes.length; episode++) {
      if (!knownEpisodes.contains(episode)) {
        // The navigation layer uses the count as its confirmed upper bound.
        // A gap would make an unknown episode look canonical, so reject the
        // complete lookup instead of making that inference.
        throw const _FillerLookupFailure(
          FillerUnavailableReason.invalidResponse,
        );
      }
    }
    return FillerEpisodeLookup.confirmed(
      confirmedFillerEpisodes: fillerEpisodes,
      source: source,
      resolvedMalMediaId: malMediaId,
      fetchedAt: _clock().toUtc(),
      knownEpisodeCount: knownEpisodes.length,
    );
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    required Map<String, dynamic> queryParameters,
  }) async {
    await _waitForRateSlot();
    final response = await _dio.get<ResponseBody>(
      path,
      queryParameters: queryParameters,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        receiveDataWhenStatusError: false,
      ),
    );
    final responseBody = response.data;
    if (responseBody == null) {
      throw const _FillerLookupFailure(FillerUnavailableReason.invalidResponse);
    }

    final bytes = BytesBuilder(copy: false);
    var receivedBytes = 0;
    final iterator = StreamIterator<Uint8List>(responseBody.stream);
    try {
      final declaredLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declaredLength != null && declaredLength > maximumResponseBytes) {
        throw const _FillerLookupFailure(FillerUnavailableReason.boundedLimit);
      }
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        if (chunk.length > maximumResponseBytes - receivedBytes) {
          throw const _FillerLookupFailure(
            FillerUnavailableReason.boundedLimit,
          );
        }
        receivedBytes += chunk.length;
        bytes.add(chunk);
      }
    } finally {
      // Cancelling the iterator closes the underlying HTTP response when the
      // byte limit is exceeded or the stream otherwise fails mid-response.
      await iterator.cancel();
    }
    final body = utf8.decode(bytes.takeBytes());
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const _FillerLookupFailure(FillerUnavailableReason.invalidResponse);
    }
    return decoded;
  }

  Future<void> _waitForRateSlot() async {
    final now = _clock();
    final next = _nextRequestAt;
    final scheduled = next != null && next.isAfter(now) ? next : now;
    final minuteAgo = scheduled.subtract(const Duration(minutes: 1));
    while (_scheduledRequests.isNotEmpty &&
        !_scheduledRequests.first.isAfter(minuteAgo)) {
      _scheduledRequests.removeFirst();
    }
    if (_scheduledRequests.length >= maximumRequestsPerMinute) {
      throw const _FillerLookupFailure(FillerUnavailableReason.boundedLimit);
    }
    _scheduledRequests.addLast(scheduled);
    _nextRequestAt = scheduled.add(minimumRequestInterval);
    final wait = scheduled.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  Future<FillerEpisodeLookup?> _readCache(
    String key, {
    required int? expectedMalMediaId,
  }) async {
    final memory = _memoryCache.remove(key);
    if (memory != null) {
      if (_isFresh(memory, expectedMalMediaId: expectedMalMediaId)) {
        _memoryCache[key] = memory;
        return memory;
      }
    }
    try {
      final payload = await _cacheStore.read(key);
      if (payload == null) return null;
      final parsed = _fromCacheJson(
        payload,
        expectedMalMediaId: expectedMalMediaId,
      );
      if (parsed == null) return null;
      _putMemory(key, parsed);
      return parsed;
    } catch (_) {
      return null;
    }
  }

  bool _isFresh(
    FillerEpisodeLookup lookup, {
    required int? expectedMalMediaId,
  }) {
    final fetchedAt = lookup.fetchedAt;
    final malMediaId = lookup.resolvedMalMediaId;
    if (!lookup.canAutoSkip || fetchedAt == null || malMediaId == null) {
      return false;
    }
    if (expectedMalMediaId != null && expectedMalMediaId != malMediaId) {
      return false;
    }
    final now = _clock().toUtc();
    if (fetchedAt.isAfter(now.add(const Duration(minutes: 5)))) return false;
    return now.difference(fetchedAt) <= cacheTtl;
  }

  void _putMemory(String key, FillerEpisodeLookup value) {
    _memoryCache.remove(key);
    _memoryCache[key] = value;
    while (_memoryCache.length > maximumCachedSeries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
  }

  Map<String, dynamic> _toCacheJson(FillerEpisodeLookup lookup) {
    final fillers = lookup.confirmedFillerEpisodes.toList()..sort();
    return <String, dynamic>{
      'schema': _cacheSchema,
      'status': 'confirmed',
      'source': lookup.source?.name,
      'malMediaId': lookup.resolvedMalMediaId,
      'fetchedAt': lookup.fetchedAt?.millisecondsSinceEpoch,
      'knownEpisodeCount': lookup.knownEpisodeCount,
      'fillerEpisodes': fillers,
    };
  }

  FillerEpisodeLookup? _fromCacheJson(
    Map<String, dynamic> payload, {
    required int? expectedMalMediaId,
  }) {
    if (payload['schema'] != _cacheSchema || payload['status'] != 'confirmed') {
      return null;
    }
    final sourceName = payload['source'];
    final source = FillerDataSource.values
        .where((value) => value.name == sourceName)
        .firstOrNull;
    final malMediaId = payload['malMediaId'];
    final fetchedAtMs = payload['fetchedAt'];
    final knownEpisodeCount = payload['knownEpisodeCount'];
    final fillers = payload['fillerEpisodes'];
    if (source == null ||
        malMediaId is! int ||
        malMediaId <= 0 ||
        (expectedMalMediaId != null && malMediaId != expectedMalMediaId) ||
        fetchedAtMs is! int ||
        knownEpisodeCount is! int ||
        knownEpisodeCount <= 0 ||
        knownEpisodeCount > maximumEpisodes ||
        fillers is! List ||
        fillers.length > maximumEpisodes ||
        fillers.length > knownEpisodeCount) {
      return null;
    }
    final fillerSet = <int>{};
    for (final episode in fillers) {
      if (episode is! int ||
          episode <= 0 ||
          episode > _maximumEpisodeNumber ||
          !fillerSet.add(episode)) {
        return null;
      }
    }
    final lookup = FillerEpisodeLookup.confirmed(
      confirmedFillerEpisodes: fillerSet,
      source: source,
      resolvedMalMediaId: malMediaId,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetchedAtMs, isUtc: true),
      knownEpisodeCount: knownEpisodeCount,
    );
    return _isFresh(lookup, expectedMalMediaId: expectedMalMediaId)
        ? lookup
        : null;
  }

  String _requestCacheKey(FillerSeriesIdentity identity) {
    final malMediaId = identity.malMediaId;
    return malMediaId != null
        ? _malCacheKey(malMediaId)
        : '${_cachePrefix}anilist:${identity.anilistMediaId}';
  }

  String _malCacheKey(int malMediaId) => '${_cachePrefix}mal:$malMediaId';
}

Iterable<String> _candidateTitles(Map<String, dynamic> candidate) sync* {
  for (final key in const ['title', 'title_english', 'title_japanese']) {
    final title = candidate[key];
    if (title is String && title.isNotEmpty) yield title;
  }
  final titles = candidate['titles'];
  if (titles is List) {
    for (final value in titles) {
      if (value is Map && value['title'] is String) {
        yield value['title'] as String;
      }
    }
  }
  final synonyms = candidate['title_synonyms'];
  if (synonyms is List) {
    for (final value in synonyms) {
      if (value is String) yield value;
    }
  }
}

String _normalizeTitle(String value) => value
    .toLowerCase()
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

class _FillerLookupFailure implements Exception {
  const _FillerLookupFailure(this.reason);

  final FillerUnavailableReason reason;
}
