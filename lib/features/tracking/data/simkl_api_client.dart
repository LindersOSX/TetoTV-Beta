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
}

class SimklApiException implements Exception {
  const SimklApiException({required this.statusCode, required this.code});

  final int? statusCode;
  final String code;

  @override
  String toString() => 'SIMKL request failed ($code).';
}

class SimklRateLimitException extends SimklApiException {
  const SimklRateLimitException({required this.retryAfter})
    : super(statusCode: 429, code: 'rate_limited');

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

  /// Marks one sequential anime episode using an explicit canonical SIMKL ID.
  Future<void> markAnimeEpisodeWatched({
    required SimklAnimeId animeId,
    required int episodeNumber,
    DateTime? watchedAt,
  }) => _postScheduler.schedule(() async {
    final episode = <String, dynamic>{
      'number': _positive(episodeNumber, 'episodeNumber'),
      if (watchedAt != null) 'watched_at': watchedAt.toUtc().toIso8601String(),
    };
    final response = await _post<Map<String, dynamic>>(
      '/sync/history',
      data: {
        'anime': [
          {
            'ids': {'simkl': animeId.value},
            // SIMKL documents this flat shorthand for sequential anime.
            'episodes': [episode],
          },
        ],
      },
    );
    final data = response.data;
    final added = _map(data?['added']);
    final notFound = _map(data?['not_found']);
    if (added == null || notFound == null) {
      throw const SimklApiException(
        statusCode: 201,
        code: 'invalid_history_response',
      );
    }
    if (_nonEmptyList(notFound['movies']) ||
        _nonEmptyList(notFound['shows']) ||
        _nonEmptyList(notFound['episodes'])) {
      throw const SimklUnresolvedIdentityException();
    }
  });

  Future<Response<T>> _post<T>(String path, {Object? data}) async {
    try {
      return await _dio.post<T>(
        path,
        data: data,
        queryParameters: {
          'client_id': _clientId,
          'app-name': _appName,
          'app-version': _appVersion,
        },
        options: Options(
          followRedirects: false,
          maxRedirects: 0,
          validateStatus: (status) => status == 200 || status == 201,
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'User-Agent': '$_appName/$_appVersion',
            'Authorization': 'Bearer $_accessToken',
          },
        ),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 429) {
        throw SimklRateLimitException(
          retryAfter: _retryAfter(error.response?.headers.value('retry-after')),
        );
      }
      throw SimklApiException(
        statusCode: status,
        code: _errorCode(error.response?.data),
      );
    }
  }
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
  return value;
}

int? _optionalPositive(Object? value) {
  if (value is! num || !value.isFinite || value.toInt() <= 0) return null;
  return value.toInt();
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
