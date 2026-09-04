import 'dart:async';

import 'package:dio/dio.dart';

typedef SimklClock = DateTime Function();
typedef SimklDelay = Future<void> Function(Duration duration);

final SimklPostScheduler _defaultSimklPostScheduler = SimklPostScheduler();

/// A conservative app-wide lane for SIMKL's one-POST-per-second budget.
///
/// The default [SimklApiClient] instances share one scheduler, so accidentally
/// rebuilding a repository cannot create parallel writes. A dedicated
/// scheduler can be injected by tests.
class SimklPostScheduler {
  SimklPostScheduler({SimklClock? now, SimklDelay? delay})
    : _now = now ?? DateTime.now,
      _delay = delay ?? Future<void>.delayed;

  static const _minimumInterval = Duration(seconds: 1);
  final SimklClock _now;
  final SimklDelay _delay;
  Future<void> _tail = Future<void>.value();
  DateTime? _lastStartedAt;

  Future<T> schedule<T>(Future<T> Function() operation) {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    return () async {
      await previous;
      try {
        final last = _lastStartedAt;
        if (last != null) {
          final remaining = _minimumInterval - _now().difference(last);
          if (remaining > Duration.zero) await _delay(remaining);
        }
        _lastStartedAt = _now();
        return await operation();
      } finally {
        release.complete();
      }
    }();
  }
}

/// A canonical SIMKL anime identifier.
///
/// This intentionally cannot be substituted with the app's generic AniList or
/// MAL `mediaId`. A future crosswalk must produce this type only after it has
/// verified the canonical SIMKL record.
final class SimklAnimeId {
  SimklAnimeId(int value) : value = _positive(value, 'value');

  final int value;
}

enum SimklAccountPlan { free, pro, vip, unknown }

class SimklUserProfile {
  const SimklUserProfile({
    required this.username,
    required this.plan,
    this.avatarUrl,
    this.accountId,
    this.timezone,
  });

  final String username;
  final String? avatarUrl;
  final int? accountId;
  final String? timezone;
  final SimklAccountPlan plan;

  Map<String, Object?> toJson() => {
    'username': username,
    'avatarUrl': avatarUrl,
    'accountId': accountId,
    'timezone': timezone,
    'plan': plan.name,
  };

  static SimklUserProfile? fromJson(Object? value) {
    final data = _map(value);
    final username = _nonEmpty(data?['username']);
    if (username == null || username.length > 80) return null;
    return SimklUserProfile(
      username: username,
      avatarUrl: _safeAvatar(data?['avatarUrl']),
      accountId: _optionalPositive(data?['accountId']),
      timezone: _nonEmpty(data?['timezone']),
      plan:
          SimklAccountPlan.values
              .where((item) => item.name == data?['plan'])
              .firstOrNull ??
          SimklAccountPlan.unknown,
    );
  }
}

class SimklMediaIds {
  SimklMediaIds({this.simkl, this.anilist, this.mal}) {
    if (toJson().isEmpty) {
      throw ArgumentError(
        'At least one SIMKL-compatible media ID is required.',
      );
    }
  }

  final int? simkl;
  final int? anilist;
  final int? mal;

  Map<String, dynamic> toJson() => {
    if (simkl != null) 'simkl': _positive(simkl!, 'simkl'),
    if (anilist != null) 'anilist': '${_positive(anilist!, 'anilist')}',
    if (mal != null) 'mal': '${_positive(mal!, 'mal')}',
  };
}

class SimklAnimeListEntry {
  const SimklAnimeListEntry({
    required this.simklId,
    required this.title,
    required this.status,
    required this.progress,
    this.anilistId,
    this.malId,
    this.totalEpisodes,
    this.posterPath,
    this.slug,
    this.score,
    this.updatedAt,
    this.watchedEpisodeNumbers = const <int>{},
  });

  final int simklId;
  final int? anilistId;
  final int? malId;
  final String title;
  final String status;
  final int progress;
  final int? totalEpisodes;
  final String? posterPath;
  final String? slug;
  final double? score;
  final DateTime? updatedAt;
  final Set<int> watchedEpisodeNumbers;

  int get contiguousProgress {
    if (watchedEpisodeNumbers.isEmpty) return progress;
    var value = 0;
    while (watchedEpisodeNumbers.contains(value + 1)) {
      value++;
    }
    return value;
  }

  Map<String, Object?> toJson() => {
    'simklId': simklId,
    'anilistId': anilistId,
    'malId': malId,
    'title': title,
    'status': status,
    'progress': progress,
    'totalEpisodes': totalEpisodes,
    'posterPath': posterPath,
    'slug': slug,
    'score': score,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'watchedEpisodeNumbers': watchedEpisodeNumbers.toList()..sort(),
  };

  static SimklAnimeListEntry? fromJson(Object? value) {
    final data = _map(value);
    final simklId = _flexiblePositive(data?['simklId']);
    final title = _nonEmpty(data?['title']);
    final status = _optionalListStatus(data?['status']);
    final progress = _nonNegative(data?['progress']);
    final watchedEpisodeNumbers = _positiveIntegerSet(
      data?['watchedEpisodeNumbers'],
    );
    if (simklId == null ||
        title == null ||
        title.length > 500 ||
        status == null ||
        progress == null) {
      return null;
    }
    return SimklAnimeListEntry(
      simklId: simklId,
      anilistId: _flexiblePositive(data?['anilistId']),
      malId: _flexiblePositive(data?['malId']),
      title: title,
      status: status,
      progress: progress,
      totalEpisodes: _nonNegative(data?['totalEpisodes']),
      posterPath: _safePosterPath(data?['posterPath']),
      slug: _safeSlug(data?['slug']),
      score: _score(data?['score']),
      updatedAt: _date(data?['updatedAt']),
      watchedEpisodeNumbers: watchedEpisodeNumbers,
    );
  }
}

class SimklActivitySnapshot {
  const SimklActivitySnapshot({
    this.all,
    this.animeAll,
    this.animeRemovedFromList,
    this.settingsAll,
  });

  final String? all;
  final String? animeAll;
  final String? animeRemovedFromList;
  final String? settingsAll;

  Map<String, Object?> toJson() => {
    'all': all,
    'animeAll': animeAll,
    'animeRemovedFromList': animeRemovedFromList,
    'settingsAll': settingsAll,
  };

  factory SimklActivitySnapshot.fromJson(Map<String, dynamic> value) =>
      SimklActivitySnapshot(
        all: _timestamp(value['all']),
        animeAll: _timestamp(value['animeAll']),
        animeRemovedFromList: _timestamp(value['animeRemovedFromList']),
        settingsAll: _timestamp(value['settingsAll']),
      );
}

class SimklApiException implements Exception {
  const SimklApiException({
    required this.statusCode,
    required this.code,
    this.retryable = false,
  });

  final int? statusCode;
  final String code;
  final bool retryable;

  @override
  String toString() => 'SIMKL request failed ($code).';
}

class SimklRateLimitException extends SimklApiException {
  const SimklRateLimitException({required this.retryAfter})
    : super(statusCode: 429, code: 'rate_limited', retryable: true);

  final Duration? retryAfter;
}

class SimklUnresolvedIdentityException extends SimklApiException {
  const SimklUnresolvedIdentityException()
    : super(statusCode: 201, code: 'canonical_id_not_found');
}

/// Minimal authenticated SIMKL surface kept isolated until end-to-end media-ID
/// mapping is available.
///
/// Every POST shares one serialized one-request-per-second lane. Writes are
/// never retried automatically: callers can surface the failure without
/// risking an accidental duplicate history mutation.
class SimklApiClient {
  SimklApiClient({
    required String accessToken,
    required String clientId,
    required String appVersion,
    String appName = 'tetotv',
    Dio? dio,
    SimklPostScheduler? postScheduler,
  }) : _accessToken = _credential(accessToken, 'accessToken', maximum: 4096),
       _clientId = _credential(clientId, 'clientId', maximum: 512),
       _appName = _validatedAppName(appName),
       _appVersion = _validatedVersion(appVersion),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: 'https://api.simkl.com',
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 20),
               followRedirects: false,
               maxRedirects: 0,
             ),
           ),
       _postScheduler = postScheduler ?? _defaultSimklPostScheduler;

  final Dio _dio;
  final String _accessToken;
  final String _clientId;
  final String _appName;
  final String _appVersion;
  final SimklPostScheduler _postScheduler;

  /// Loads the official `/users/settings` profile, including its avatar.
  ///
  /// Call only after sign-in or after `/sync/activities` reports that the
  /// settings timestamp changed; SIMKL asks clients not to poll this endpoint.
  Future<SimklUserProfile> profile() => _postScheduler.schedule(() async {
    final response = await _post<Map<String, dynamic>>('/users/settings');
    final data = response.data;
    final user = _map(data?['user']);
    final account = _map(data?['account']);
    final username = _nonEmpty(user?['name']);
    if (username == null) {
      throw const SimklApiException(
        statusCode: 200,
        code: 'invalid_profile_response',
      );
    }
    return SimklUserProfile(
      username: username,
      avatarUrl: _safeAvatar(user?['avatar']),
      accountId: _optionalPositive(account?['id']),
      timezone: _nonEmpty(account?['timezone']),
      plan: _plan(account?['type']),
    );
  });

  /// Returns the small activity watermark used to gate later sync reads.
  Future<SimklActivitySnapshot> activities() async {
    final response = await _get<Map<String, dynamic>>('/sync/activities');
    final data = response.data;
    final anime = _map(data?['anime']);
    final settings = _map(data?['settings']);
    final all = _timestamp(data?['all']);
    if (data == null ||
        anime == null ||
        settings == null ||
        !data.containsKey('all') ||
        !anime.containsKey('all') ||
        !anime.containsKey('removed_from_list') ||
        !settings.containsKey('all') ||
        !_nullableTimestamp(data['all']) ||
        !_nullableTimestamp(anime['all']) ||
        !_nullableTimestamp(anime['removed_from_list']) ||
        !_nullableTimestamp(settings['all'])) {
      throw const SimklApiException(
        statusCode: 200,
        code: 'invalid_activities_response',
      );
    }
    return SimklActivitySnapshot(
      all: all,
      animeAll: _timestamp(anime['all']),
      animeRemovedFromList: _timestamp(anime['removed_from_list']),
      settingsAll: _timestamp(settings['all']),
    );
  }

  /// Loads every anime status in one request. Continuous refreshes must be
  /// gated by [activities]; [SimklAccountSession] owns that policy.
  Future<List<SimklAnimeListEntry>> animeLibrary({String? dateFrom}) async {
    final since = dateFrom == null ? null : _requiredTimestamp(dateFrom);
    final response = await _get<Map<String, dynamic>>(
      '/sync/all-items/anime',
      queryParameters: {
        'language': 'en',
        'extended': 'full',
        'episode_watched_at': 'yes',
        'include_all_episodes': 'yes',
        'date_from': ?since,
      },
    );
    final data = response.data;
    final rows = data?['anime'];
    if (since != null && data != null && !data.containsKey('anime')) {
      return const [];
    }
    if (data == null || !data.containsKey('anime') || rows is! List) {
      throw const SimklApiException(
        statusCode: 200,
        code: 'invalid_list_response',
      );
    }
    final result = <SimklAnimeListEntry>[];
    for (final value in rows) {
      final row = _map(value);
      final show = _map(row?['show']);
      final ids = _map(show?['ids']);
      final simklId = _flexiblePositive(ids?['simkl']);
      final title = _nonEmpty(show?['title']);
      final returnedStatus = _optionalListStatus(row?['status']);
      final watchedEpisodeNumbers = _watchedEpisodes(row?['seasons']);
      if (simklId == null || title == null || returnedStatus == null) {
        throw const SimklApiException(
          statusCode: 200,
          code: 'invalid_list_response',
        );
      }
      result.add(
        SimklAnimeListEntry(
          simklId: simklId,
          anilistId: _flexiblePositive(ids?['anilist']),
          malId: _flexiblePositive(ids?['mal']),
          title: title,
          status: returnedStatus,
          progress: _nonNegative(row?['watched_episodes_count']) ?? 0,
          totalEpisodes: _nonNegative(row?['total_episodes_count']),
          posterPath: _safePosterPath(show?['poster']),
          slug: _safeSlug(ids?['slug']),
          score: _score(row?['user_rating']),
          updatedAt:
              _date(row?['last_watched_at']) ??
              _date(row?['added_to_watchlist_at']),
          watchedEpisodeNumbers: watchedEpisodeNumbers,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// Loads the authoritative current SIMKL IDs for deletion reconciliation.
  Future<Set<int>> animeLibraryIds() async {
    final response = await _get<Map<String, dynamic>>(
      '/sync/all-items/anime',
      queryParameters: const {'language': 'en', 'extended': 'simkl_ids_only'},
    );
    final data = response.data;
    final rows = data?['anime'];
    if (data == null || !data.containsKey('anime') || rows is! List) {
      throw const SimklApiException(
        statusCode: 200,
        code: 'invalid_ids_response',
      );
    }
    final result = <int>{};
    for (final value in rows) {
      final row = _map(value);
      final show = _map(row?['show']);
      final ids = _map(show?['ids']) ?? _map(row?['ids']);
      final simklId = _flexiblePositive(ids?['simkl']);
      if (simklId == null) {
        throw const SimklApiException(
          statusCode: 200,
          code: 'invalid_ids_response',
        );
      }
      result.add(simklId);
    }
    return Set.unmodifiable(result);
  }

  /// Marks one sequential anime episode using an explicit canonical SIMKL ID.
  Future<String> markAnimeEpisodeWatched({
    required SimklAnimeId animeId,
    required int episodeNumber,
    DateTime? watchedAt,
  }) => markAnimeEpisodeWatchedByIds(
    ids: SimklMediaIds(simkl: animeId.value),
    episodeNumber: episodeNumber,
    watchedAt: watchedAt,
  );

  Future<String> markAnimeEpisodeWatchedByIds({
    required SimklMediaIds ids,
    required int episodeNumber,
    DateTime? watchedAt,
  }) => markAnimeEpisodesWatchedByIds(
    ids: ids,
    episodeNumbers: [episodeNumber],
    watchedAt: watchedAt,
  );

  Future<String> markAnimeEpisodesWatchedByIds({
    required SimklMediaIds ids,
    required List<int> episodeNumbers,
    DateTime? watchedAt,
  }) => _postScheduler.schedule(() async {
    if (episodeNumbers.isEmpty || episodeNumbers.length > 250) {
      throw ArgumentError.value(
        episodeNumbers.length,
        'episodeNumbers',
        'Send between 1 and 250 episodes per request.',
      );
    }
    final episodes = [
      for (final number in episodeNumbers)
        <String, dynamic>{
          'number': _positive(number, 'episodeNumber'),
          if (watchedAt != null)
            'watched_at': watchedAt.toUtc().toIso8601String(),
        },
    ];
    final response = await _post<Map<String, dynamic>>(
      '/sync/history',
      data: {
        // Anime-native AniList/MAL identities belong in SIMKL's anime bucket.
        // The history-removal endpoint is the exception and uses `shows`.
        'anime': [
          {'ids': ids.toJson(), 'episodes': episodes},
        ],
      },
    );
    _validateMutation(
      response.data,
      successKey: 'added',
      code: 'invalid_history_response',
    );
    return _actualHistoryStatus(
      response.data,
      code: 'invalid_history_response',
    );
  });

  Future<String> setAnimeStatus({
    required SimklMediaIds ids,
    required String status,
  }) => _postScheduler.schedule(() async {
    const allowed = {'watching', 'plantowatch', 'completed', 'dropped', 'hold'};
    if (!allowed.contains(status)) {
      throw ArgumentError.value(status, 'status', 'Unknown SIMKL list status.');
    }
    final response = await _post<Map<String, dynamic>>(
      '/sync/add-to-list',
      data: {
        'anime': [
          {'to': status, 'ids': ids.toJson()},
        ],
      },
    );
    return _actualAddedStatus(
      response.data,
      code: 'invalid_list_update_response',
    );
  });

  Future<void> removeAnime(SimklMediaIds ids) =>
      _postScheduler.schedule(() async {
        final response = await _post<Map<String, dynamic>>(
          '/sync/history/remove',
          data: {
            // Whole-title removal is normalized through the shows bucket,
            // including anime, by SIMKL's history removal API.
            'shows': [
              {'ids': ids.toJson()},
            ],
          },
        );
        _validateMutation(
          response.data,
          successKey: 'deleted',
          code: 'invalid_list_remove_response',
        );
      });

  Future<Response<T>> _get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      return await _dio.get<T>(
        path,
        queryParameters: {
          ...?queryParameters,
          'client_id': _clientId,
          'app-name': _appName,
          'app-version': _appVersion,
        },
        options: _requestOptions((status) => status == 200),
      );
    } on DioException catch (error) {
      throw _requestException(error);
    }
  }

  Future<Response<T>> _post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      return await _dio.post<T>(
        path,
        data: data,
        queryParameters: {
          ...?queryParameters,
          'client_id': _clientId,
          'app-name': _appName,
          'app-version': _appVersion,
        },
        options: _requestOptions(
          (status) => status == 200 || status == 201,
          contentType: true,
        ),
      );
    } on DioException catch (error) {
      throw _requestException(error);
    }
  }

  Options _requestOptions(
    bool Function(int?) validateStatus, {
    bool contentType = false,
  }) => Options(
    followRedirects: false,
    maxRedirects: 0,
    validateStatus: validateStatus,
    headers: {
      'Accept': 'application/json',
      if (contentType) 'Content-Type': 'application/json',
      'User-Agent': '$_appName/$_appVersion',
      'Authorization': 'Bearer $_accessToken',
    },
  );

  SimklApiException _requestException(DioException error) {
    final status = error.response?.statusCode;
    if (status == 429) {
      return SimklRateLimitException(
        retryAfter: _retryAfter(error.response?.headers.value('retry-after')),
      );
    }
    return SimklApiException(
      statusCode: status,
      code: _errorCode(error.response?.data),
      retryable:
          status == null &&
          switch (error.type) {
            DioExceptionType.connectionTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.receiveTimeout ||
            DioExceptionType.connectionError ||
            DioExceptionType.unknown => true,
            DioExceptionType.badCertificate ||
            DioExceptionType.badResponse ||
            DioExceptionType.cancel ||
            DioExceptionType.transformTimeout => false,
          },
    );
  }
}

void _validateMutation(
  Object? value, {
  required String successKey,
  required String code,
}) {
  final data = _map(value);
  final result = _map(data?[successKey]);
  final notFound = _map(data?['not_found']);
  if (result == null || notFound == null) {
    throw SimklApiException(statusCode: 201, code: code);
  }
  if (_nonEmptyList(notFound['movies']) ||
      _nonEmptyList(notFound['shows']) ||
      _nonEmptyList(notFound['anime']) ||
      _nonEmptyList(notFound['episodes'])) {
    throw const SimklUnresolvedIdentityException();
  }
}

String _actualAddedStatus(Object? value, {required String code}) {
  final data = _map(value);
  final added = _map(data?['added']);
  final notFound = _map(data?['not_found']);
  if (added == null || notFound == null) {
    throw SimklApiException(statusCode: 201, code: code);
  }
  if (_nonEmptyList(notFound['movies']) ||
      _nonEmptyList(notFound['shows']) ||
      _nonEmptyList(notFound['anime'])) {
    throw const SimklUnresolvedIdentityException();
  }

  final rows = <Object?>[];
  for (final key in const ['movies', 'shows', 'anime']) {
    final bucket = added[key];
    if (bucket == null) continue;
    if (bucket is! List) {
      throw SimklApiException(statusCode: 201, code: code);
    }
    rows.addAll(bucket);
  }
  if (rows.length != 1) {
    throw SimklApiException(statusCode: 201, code: code);
  }
  final actual = _optionalListStatus(_map(rows.single)?['to']);
  if (actual == null) {
    throw SimklApiException(statusCode: 201, code: code);
  }
  return actual;
}

String _actualHistoryStatus(Object? value, {required String code}) {
  final added = _map(_map(value)?['added']);
  final statuses = added?['statuses'];
  if (statuses is! List || statuses.length != 1) {
    throw SimklApiException(statusCode: 201, code: code);
  }
  final response = _map(_map(statuses.single)?['response']);
  final actual = _optionalListStatus(response?['status']);
  if (actual == null) {
    throw SimklApiException(statusCode: 201, code: code);
  }
  return actual;
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
  return value;
}

int? _optionalPositive(Object? value) {
  if (value is! num || !value.isFinite || value.toInt() <= 0) return null;
  return value.toInt();
}

int? _flexiblePositive(Object? value) {
  if (value is num && value.isFinite && value.toInt() > 0) {
    return value.toInt();
  }
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

int? _nonNegative(Object? value) {
  if (value is! num || !value.isFinite || value.toInt() < 0) return null;
  return value.toInt();
}

Set<int> _positiveIntegerSet(Object? value) {
  if (value is! List) return const <int>{};
  final result = <int>{};
  for (final item in value) {
    final number = _optionalPositive(item);
    if (number != null) result.add(number);
  }
  return Set.unmodifiable(result);
}

Set<int> _watchedEpisodes(Object? value) {
  if (value == null) return const <int>{};
  if (value is! List) {
    throw const SimklApiException(
      statusCode: 200,
      code: 'invalid_list_response',
    );
  }
  final result = <int>{};
  for (final seasonValue in value) {
    final season = _map(seasonValue);
    final episodes = season?['episodes'];
    if (season == null || episodes is! List) {
      throw const SimklApiException(
        statusCode: 200,
        code: 'invalid_list_response',
      );
    }
    for (final episodeValue in episodes) {
      final number = _optionalPositive(_map(episodeValue)?['number']);
      if (number == null) {
        throw const SimklApiException(
          statusCode: 200,
          code: 'invalid_list_response',
        );
      }
      result.add(number);
    }
  }
  return Set.unmodifiable(result);
}

double? _score(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final score = value.toDouble();
  return score >= 0 && score <= 10 ? score : null;
}

DateTime? _date(Object? value) {
  if (value is! String || value.length > 64) return null;
  return DateTime.tryParse(value)?.toLocal();
}

String? _timestamp(Object? value) {
  final source = _nonEmpty(value);
  if (source == null || source.length > 64) return null;
  return DateTime.tryParse(source) == null ? null : source;
}

String _requiredTimestamp(String value) {
  final timestamp = _timestamp(value);
  if (timestamp == null) {
    throw ArgumentError.value(value, 'dateFrom', 'Use an ISO 8601 timestamp.');
  }
  return timestamp;
}

bool _nullableTimestamp(Object? value) =>
    value == null || _timestamp(value) != null;

String? _optionalListStatus(Object? value) {
  if (value == null) return null;
  final status = _nonEmpty(value);
  return const {
        'watching',
        'plantowatch',
        'completed',
        'dropped',
        'hold',
      }.contains(status)
      ? status
      : null;
}

String? _safePosterPath(Object? value) {
  final path = _nonEmpty(value);
  if (path == null ||
      path.length > 128 ||
      !RegExp(r'^[0-9A-Za-z_-]+/[0-9A-Za-z_-]+$').hasMatch(path)) {
    return null;
  }
  return path;
}

String? _safeSlug(Object? value) {
  final slug = _nonEmpty(value);
  if (slug == null ||
      slug.length > 160 ||
      !RegExp(r'^[0-9A-Za-z]+(?:-[0-9A-Za-z]+)*$').hasMatch(slug)) {
    return null;
  }
  return slug;
}

String _credential(String value, String name, {required int maximum}) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximum ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
    throw ArgumentError.value('', name, 'Must be a bounded non-empty value.');
  }
  return normalized;
}

String _validatedAppName(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'appName', 'Use a lowercase app slug.');
  }
  return normalized;
}

String _validatedVersion(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'appVersion', 'Use a bounded version.');
  }
  return normalized;
}

Map<String, dynamic>? _map(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

SimklAccountPlan _plan(Object? value) => switch (_nonEmpty(value)) {
  'free' => SimklAccountPlan.free,
  'pro' => SimklAccountPlan.pro,
  'vip' => SimklAccountPlan.vip,
  _ => SimklAccountPlan.unknown,
};

String? _safeAvatar(Object? value) {
  final source = _nonEmpty(value);
  final uri = source == null ? null : Uri.tryParse(source);
  final host = uri?.host.toLowerCase();
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 443) ||
      !(host == 'simkl.in' || host!.endsWith('.simkl.in')) ||
      !uri.path.startsWith('/avatars/')) {
    return null;
  }
  return uri.toString();
}

bool _nonEmptyList(Object? value) => value is List && value.isNotEmpty;

Duration? _retryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  if (seconds == null || seconds < 0 || seconds > 3600) return null;
  return Duration(seconds: seconds);
}

String _errorCode(Object? value) {
  final code = _nonEmpty(_map(value)?['error']);
  return code != null && RegExp(r'^[a-z0-9_]{1,80}$').hasMatch(code)
      ? code
      : 'request_failed';
}
