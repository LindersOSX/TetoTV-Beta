import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/domain/manga_tracking_models.dart';
import 'package:dio/dio.dart';

abstract interface class MangaTrackingClient {
  Future<String> accountId();
  Future<List<MangaTrackingSearchResult>> search(String query);
  Future<MangaTrackingSearchResult> details(int mediaId);
  Future<int> currentProgress(int mediaId);
  Future<void> updateProgress(int mediaId, int completedChapters);
  void close();
}

typedef MangaTrackingClientFactory =
    MangaTrackingClient Function(TrackingProvider provider, String accessToken);

/// A shared lane prevents fresh token-bound clients from bypassing pacing.
class MangaTrackingRequestLane {
  MangaTrackingRequestLane({
    this.minimumInterval = const Duration(seconds: 2),
    Future<void> Function(Duration)? wait,
    DateTime Function()? now,
  }) : _wait = wait ?? Future<void>.delayed,
       _now = now ?? DateTime.now;
  final Duration minimumInterval;
  final Future<void> Function(Duration) _wait;
  final DateTime Function() _now;
  Future<void> _tail = Future<void>.value();
  DateTime? _lastStart;
  DateTime? _blockedUntil;

  void deferFor(Duration delay) {
    final until = _now().add(delay);
    if (_blockedUntil == null || until.isAfter(_blockedUntil!)) {
      _blockedUntil = until;
    }
  }

  Future<T> run<T>(Future<T> Function() request) {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    return () async {
      await previous;
      try {
        final last = _lastStart;
        if (last != null) {
          final delay = minimumInterval - _now().difference(last);
          if (delay > Duration.zero) await _wait(delay);
        }
        final blocked = _blockedUntil;
        if (blocked != null) {
          final delay = blocked.difference(_now());
          if (delay > Duration.zero) await _wait(delay);
        }
        _lastStart = _now();
        return await request();
      } finally {
        release.complete();
      }
    }();
  }
}

/// Fixed official endpoints only. The official MAL OpenAPI document uses PATCH
/// /manga/{id}/my_list_status (despite its older *_put operation ID/curl sample):
/// https://myanimelist.net/apiconfig/references/api/v2
/// AniList MANGA + chapter progress schema:
/// https://docs.anilist.co/guide/graphql/queries/media
/// https://docs.anilist.co/reference/mutation
/// https://docs.anilist.co/guide/rate-limiting
class OfficialMangaTrackingClient implements MangaTrackingClient {
  OfficialMangaTrackingClient({
    required this.provider,
    required String accessToken,
    Dio? dio,
    MangaTrackingRequestLane? lane,
  }) : _token = accessToken,
       _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 12))),
       _lane = lane ?? MangaTrackingRequestLane() {
    if (!supportsMangaTracking(provider) ||
        accessToken.isEmpty ||
        accessToken.length > 16384 ||
        accessToken.contains(RegExp(r'[\r\n]'))) {
      throw const MangaTrackingException(
        'Connect AniList or MAL to track manga.',
        requiresReconnect: true,
      );
    }
  }
  final TrackingProvider provider;
  final String _token;
  final Dio _dio;
  final MangaTrackingRequestLane _lane;
  bool get _anilist => provider == TrackingProvider.anilist;

  @override
  Future<String> accountId() async {
    final body = _anilist
        ? await _graphql('query { Viewer { id } }', const {})
        : await _request('GET', '/users/@me');
    final raw = _anilist ? _map(body['Viewer'])['id'] : body['id'];
    return mangaTrackingInt(raw, 1, 2147483647).toString();
  }

  @override
  Future<List<MangaTrackingSearchResult>> search(String query) async {
    final text = mangaTrackingText(query, 160);
    if (text.length < 2) {
      throw const MangaTrackingException(
        'Enter at least two characters to search manga.',
      );
    }
    final body = _anilist
        ? await _graphql(
            r'''
query ($search: String!) {
  Page(page: 1, perPage: 20) {
    media(search: $search, type: MANGA) {
      id type format chapters title { userPreferred english romaji native }
    }
  }
}
''',
            {'search': text},
          )
        : await _request(
            'GET',
            '/manga',
            query: {
              'q': text,
              'limit': 20,
              'fields': 'media_type,num_chapters',
            },
          );
    final raw = _anilist ? _map(body['Page'])['media'] : body['data'];
    if (raw is! List || raw.length > 20) throw _invalidResponse;
    final results = <MangaTrackingSearchResult>[];
    for (final item in raw) {
      try {
        results.add(_record(_anilist ? _map(item) : _map(_map(item)['node'])));
      } on FormatException {
        // A malformed search row never becomes an implicit title match.
      } on MangaTrackingException {
        // Reject anime/mixed-type rows even if an upstream query is malformed.
      } on TypeError {
        // Wrongly typed optional fields are not safe selectable records.
      }
    }
    return List.unmodifiable(results);
  }

  @override
  Future<MangaTrackingSearchResult> details(int mediaId) async {
    mangaTrackingInt(mediaId, 1, 2147483647);
    final body = _anilist
        ? await _graphql(
            r'''
query ($id: Int!) {
  Media(id: $id, type: MANGA) {
    id type format chapters title { userPreferred english romaji native }
  }
}
''',
            {'id': mediaId},
          )
        : await _request(
            'GET',
            '/manga/$mediaId',
            query: const {'fields': 'media_type,num_chapters'},
          );
    final record = _record(_anilist ? _map(body['Media']) : body);
    if (record.mediaId != mediaId) throw _invalidResponse;
    return record;
  }

  @override
  Future<int> currentProgress(int mediaId) async {
    mangaTrackingInt(mediaId, 1, 2147483647);
    final body = _anilist
        ? await _graphql(
            r'''
query ($id: Int!) {
  Media(id: $id, type: MANGA) { id type mediaListEntry { progress } }
}
''',
            {'id': mediaId},
          )
        : await _request(
            'GET',
            '/manga/$mediaId',
            query: const {'fields': 'my_list_status'},
          );
    final media = _anilist ? _map(body['Media']) : body;
    if (media['id'] != mediaId || (_anilist && media['type'] != 'MANGA')) {
      throw _invalidResponse;
    }
    final raw = _anilist ? media['mediaListEntry'] : media['my_list_status'];
    if (raw == null) return 0;
    final status = _map(raw);
    return mangaTrackingInt(
      status[_anilist ? 'progress' : 'num_chapters_read'],
      0,
      100000,
    );
  }

  @override
  Future<void> updateProgress(int mediaId, int completedChapters) async {
    mangaTrackingInt(mediaId, 1, 2147483647);
    mangaTrackingInt(completedChapters, 1, 100000);
    final body = _anilist
        ? await _graphql(
            r'''
mutation ($id: Int!, $progress: Int!) {
  SaveMediaListEntry(mediaId: $id, progress: $progress) { mediaId progress }
}
''',
            {'id': mediaId, 'progress': completedChapters},
          )
        : await _request(
            'PATCH',
            '/manga/$mediaId/my_list_status',
            data: {'num_chapters_read': completedChapters},
            form: true,
          );
    final saved = _anilist ? _map(body['SaveMediaListEntry']) : body;
    if ((_anilist && saved['mediaId'] != mediaId) ||
        mangaTrackingInt(
              saved[_anilist ? 'progress' : 'num_chapters_read'],
              0,
              100000,
            ) <
            completedChapters) {
      throw _invalidResponse;
    }
  }

  MangaTrackingSearchResult _record(Map<String, dynamic> row) {
    if (_anilist && row['type'] != 'MANGA') throw _invalidResponse;
    final title = _anilist ? _map(row['title']) : null;
    final name = _anilist
        ? [
                title!['userPreferred'],
                title['english'],
                title['romaji'],
                title['native'],
              ]
              .whereType<String>()
              .where((value) => value.trim().isNotEmpty)
              .firstOrNull
        : row['title'];
    if (name is! String) throw _invalidResponse;
    final count = row[_anilist ? 'chapters' : 'num_chapters'];
    final format = row[_anilist ? 'format' : 'media_type'];
    if (format != null && format is! String) throw _invalidResponse;
    return MangaTrackingSearchResult(
      provider: provider,
      mediaId: mangaTrackingInt(row['id'], 1, 2147483647),
      title: name,
      format: format as String?,
      totalChapters: count == null || count == 0
          ? null
          : mangaTrackingInt(count, 1, 100000),
    );
  }

  Future<Map<String, dynamic>> _graphql(
    String query,
    Map<String, Object> variables,
  ) async {
    final body = await _request(
      'POST',
      '',
      data: {'query': query, 'variables': variables},
    );
    if (body['errors'] case final List errors when errors.isNotEmpty) {
      final statuses = errors.whereType<Map>().map((error) => error['status']);
      if (statuses.contains(401) || statuses.contains(403)) {
        throw _authorizationError;
      }
      if (statuses.contains(429)) {
        _lane.deferFor(const Duration(minutes: 1));
        throw const MangaTrackingException(
          'Manga tracking is rate limited. It will retry later.',
          retryable: true,
          retryAfter: Duration(minutes: 1),
        );
      }
      throw _invalidResponse;
    }
    return _map(body['data']);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object>? query,
    Object? data,
    bool form = false,
  }) => _lane.run(() async {
    final uri = _anilist
        ? Uri.https('graphql.anilist.co', '/')
        : Uri.https(
            'api.myanimelist.net',
            '/v2$path',
            query?.map((key, value) => MapEntry(key, value.toString())),
          );
    final cancellation = CancelToken();
    try {
      return await () async {
        final response = await _dio.requestUri<ResponseBody>(
          uri,
          data: data,
          cancelToken: cancellation,
          options: Options(
            method: method,
            responseType: ResponseType.stream,
            followRedirects: false,
            maxRedirects: 0,
            sendTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (_) => true,
            contentType: form
                ? Headers.formUrlEncodedContentType
                : Headers.jsonContentType,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Bearer $_token',
            },
          ),
        );
        final body = response.data;
        if (body == null) throw _invalidResponse;
        final status = response.statusCode ?? 0;
        if (status != 200) {
          await body.stream.listen((_) {}).cancel();
          if (status == 401 || status == 403) throw _authorizationError;
          if (status == 429) {
            final retry = _retryAfter(response.headers);
            _lane.deferFor(retry);
            throw MangaTrackingException(
              'Manga tracking is rate limited. It will retry later.',
              retryable: true,
              retryAfter: retry,
            );
          }
          if (status >= 500 || status == 408) throw _networkError;
          throw const MangaTrackingException(
            'The manga tracker rejected this request. Check the linked record.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in body.stream.timeout(
          const Duration(seconds: 20),
        )) {
          if (bytes.length + chunk.length > 256 * 1024) throw _invalidResponse;
          bytes.addAll(chunk);
        }
        return _map(jsonDecode(utf8.decode(bytes)));
      }().timeout(const Duration(seconds: 30));
    } on DioException catch (error) {
      if (error.response?.statusCode == 401 ||
          error.response?.statusCode == 403) {
        throw _authorizationError;
      }
      throw _networkError;
    } on TimeoutException {
      throw _networkError;
    } on SocketException {
      throw _networkError;
    } on FormatException {
      throw _invalidResponse;
    } on TypeError {
      throw _invalidResponse;
    } finally {
      // Cancels headers and body work on timeouts/oversized or rejected replies.
      // No exception or log includes the token or upstream response text.
      cancellation.cancel();
    }
  });

  @override
  void close() => _dio.close(force: true);
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw _invalidResponse;
  }
  return Map<String, dynamic>.from(value);
}

Duration _retryAfter(Headers headers) {
  final value = headers.value('retry-after');
  int? seconds = int.tryParse(value ?? '');
  if (seconds == null && value != null) {
    try {
      seconds = HttpDate.parse(
        value,
      ).difference(DateTime.now().toUtc()).inSeconds;
    } on FormatException {
      // AniList also exposes an absolute reset timestamp.
    }
  }
  final reset = int.tryParse(headers.value('x-ratelimit-reset') ?? '');
  seconds ??= reset == null
      ? 60
      : reset - DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return Duration(seconds: seconds.clamp(1, 86400));
}

const _invalidResponse = MangaTrackingException(
  'The manga tracker returned an invalid response.',
);
const _authorizationError = MangaTrackingException(
  'Reconnect the linked manga tracking account in Settings.',
  requiresReconnect: true,
);
const _networkError = MangaTrackingException(
  'Manga tracking is temporarily unavailable. Progress is saved for retry.',
  retryable: true,
);
