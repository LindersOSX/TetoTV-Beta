import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'anime_title_logo_client.dart';

/// Loads optional, language-tagged show descriptions for display only.
///
/// AniList, Kitsu, and Jikan expose an English synopsis for the catalog paths
/// used by TetoTV. AniZip supplies the stable AniList -> TMDB crosswalk, while
/// TMDB's public language-specific title page supplies the translated summary.
/// A missing translation or any transport failure returns null so callers keep
/// the already-loaded catalog synopsis.
class LocalizedAnimeDescriptionClient {
  LocalizedAnimeDescriptionClient({
    Dio? aniZipDio,
    Dio? tmdbDio,
    AnimeTitleLogoCacheStore? cacheStore,
    DateTime Function()? clock,
    Duration requestTimeout = const Duration(seconds: 12),
  }) : _aniZipDio = aniZipDio ?? _defaultAniZipDio(),
       _tmdbDio = tmdbDio ?? _defaultTmdbDio(),
       _cache = cacheStore ?? const TetoTvAnimeTitleLogoCacheStore(),
       _clock = clock ?? DateTime.now,
       _requestTimeout = requestTimeout,
       _ownsAniZipDio = aniZipDio == null,
       _ownsTmdbDio = tmdbDio == null {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
  }

  static const maximumMappingResponseBytes = 8 * 1024 * 1024;
  static const maximumPageResponseBytes = 2 * 1024 * 1024;
  static const maximumDescriptionLength = 5000;
  static const _cacheSchema = 1;
  static const _positiveCacheAge = Duration(days: 7);
  static const _negativeCacheAge = Duration(hours: 12);
  static const _tmdbLocales = <String, String>{
    'es': 'es-ES',
    'pt': 'pt-BR',
    'fr': 'fr-FR',
    'hi': 'hi-IN',
    'de': 'de-DE',
  };

  final Dio _aniZipDio;
  final Dio _tmdbDio;
  final AnimeTitleLogoCacheStore _cache;
  final DateTime Function() _clock;
  final Duration _requestTimeout;
  final bool _ownsAniZipDio;
  final bool _ownsTmdbDio;
  final Map<({int aniListId, String language}), Future<String?>> _pending = {};
  final Set<CancelToken> _activeRequests = {};
  bool _disposed = false;

  Future<String?> lookup(
    int aniListId,
    String language, {
    CancelToken? cancelToken,
  }) async {
    final normalizedLanguage = _normalizeLanguage(language);
    if (_disposed ||
        cancelToken?.isCancelled == true ||
        aniListId <= 0 ||
        !_tmdbLocales.containsKey(normalizedLanguage)) {
      return null;
    }
    final request = (aniListId: aniListId, language: normalizedLanguage);
    final work = _pending.putIfAbsent(request, () {
      final future = _load(aniListId, normalizedLanguage);
      unawaited(
        future.whenComplete(() {
          if (identical(_pending[request], future)) _pending.remove(request);
        }),
      );
      return future;
    });
    try {
      return cancelToken == null
          ? await work
          : await Future.any<String?>([
              work,
              cancelToken.whenCancel.then<String?>((_) => null),
            ]);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in _activeRequests.toList(growable: false)) {
      request.cancel();
    }
    _activeRequests.clear();
    _pending.clear();
    if (_ownsAniZipDio) _aniZipDio.close(force: true);
    if (_ownsTmdbDio) _tmdbDio.close(force: true);
  }

  Future<String?> _load(int aniListId, String language) async {
    final cacheKey =
        'localized-anime-description:v$_cacheSchema:$language:anilist:$aniListId';
    final cached = await _readCache(cacheKey, aniListId, language);
    if (cached.found) return cached.description;

    final cancel = CancelToken();
    _activeRequests.add(cancel);
    final deadline = Timer(_requestTimeout, cancel.cancel);
    try {
      final mappingResponse = await _aniZipDio.get<ResponseBody>(
        'mappings',
        queryParameters: <String, dynamic>{'anilist_id': aniListId},
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
        ),
      );
      final mappingBody = mappingResponse.data;
      if (mappingResponse.statusCode != 200 || mappingBody == null) {
        throw const FormatException('Localized metadata mapping failed.');
      }
      final mappingBytes = await _readBody(
        mappingBody,
        cancel,
        maximumMappingResponseBytes,
      );
      final document = jsonDecode(utf8.decode(mappingBytes));
      if (document is! Map || document['mappings'] is! Map) {
        throw const FormatException('Invalid localized metadata mapping.');
      }
      final mappings = document['mappings'] as Map;
      if (_positiveInt(mappings['anilist_id']) != aniListId) {
        throw const FormatException('Mismatched localized metadata mapping.');
      }
      final tmdbId = _positiveInt(mappings['themoviedb_id']);
      if (tmdbId == null) {
        await _writeCache(cacheKey, aniListId, language, null);
        return null;
      }
      final mediaPath = _isMovie(mappings['type']) ? 'movie' : 'tv';
      final pageResponse = await _tmdbDio.get<ResponseBody>(
        '$mediaPath/$tmdbId',
        queryParameters: <String, dynamic>{'language': _tmdbLocales[language]},
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          headers: const <String, dynamic>{'Accept': 'text/html'},
        ),
      );
      final pageBody = pageResponse.data;
      if (pageResponse.statusCode != 200 || pageBody == null) {
        throw const FormatException('Localized metadata page failed.');
      }
      final pageBytes = await _readBody(
        pageBody,
        cancel,
        maximumPageResponseBytes,
      );
      final description = parseTmdbDescription(
        utf8.decode(pageBytes),
        expectedLanguage: language,
      );
      await _writeCache(cacheKey, aniListId, language, description);
      return description;
    } catch (_) {
      final stale = await _readCache(
        cacheKey,
        aniListId,
        language,
        allowExpired: true,
      );
      return stale.description;
    } finally {
      deadline.cancel();
      _activeRequests.remove(cancel);
      cancel.cancel();
    }
  }

  Future<_CachedDescription> _readCache(
    String key,
    int aniListId,
    String language, {
    bool allowExpired = false,
  }) async {
    try {
      final value = await _cache
          .read(key, allowExpired: allowExpired)
          .timeout(const Duration(seconds: 2));
      if (value == null ||
          value['schema'] != _cacheSchema ||
          value['anilistId'] != aniListId ||
          value['language'] != language ||
          value['found'] is! bool ||
          value['fetchedAt'] is! int) {
        return const _CachedDescription.missing();
      }
      final found = value['found'] as bool;
      final fetchedAt = value['fetchedAt'] as int;
      final maxAge = found ? _positiveCacheAge : _negativeCacheAge;
      if (!allowExpired && !_isFresh(fetchedAt, maxAge)) {
        return const _CachedDescription.missing();
      }
      if (!found) return const _CachedDescription.negative();
      final description = _sanitizeDescription(value['description']);
      return description == null
          ? const _CachedDescription.missing()
          : _CachedDescription.positive(description);
    } catch (_) {
      return const _CachedDescription.missing();
    }
  }

  Future<void> _writeCache(
    String key,
    int aniListId,
    String language,
    String? description,
  ) async {
    try {
      await _cache
          .write(
            key,
            <String, dynamic>{
              'schema': _cacheSchema,
              'anilistId': aniListId,
              'language': language,
              'found': description != null,
              'description': ?description,
              'fetchedAt': _clock().millisecondsSinceEpoch,
            },
            maxAge: description == null ? _negativeCacheAge : _positiveCacheAge,
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Optional metadata remains usable even when local persistence is busy.
    }
  }

  bool _isFresh(int fetchedAt, Duration maxAge) {
    final age = _clock().millisecondsSinceEpoch - fetchedAt;
    return fetchedAt > 0 && age >= 0 && age < maxAge.inMilliseconds;
  }

  /// Extracts only the language-matched page summary from a bounded TMDB page.
  static String? parseTmdbDescription(
    String page, {
    required String expectedLanguage,
  }) {
    if (page.length > maximumPageResponseBytes) return null;
    final expected = _normalizeLanguage(expectedLanguage);
    if (!_tmdbLocales.containsKey(expected)) return null;
    final htmlTag = RegExp(
      r'<html\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(page)?.group(0);
    final actualLanguage = _normalizeLanguage(
      _attributes(htmlTag)['lang'] ?? '',
    );
    if (actualLanguage != expected) return null;

    for (final match in RegExp(
      r'<meta\b[^>]*>',
      caseSensitive: false,
    ).allMatches(page)) {
      final attributes = _attributes(match.group(0));
      final kind = (attributes['name'] ?? attributes['property'] ?? '')
          .toLowerCase();
      if (kind != 'description' && kind != 'og:description') continue;
      final description = _sanitizeDescription(
        _decodeHtmlEntities(attributes['content'] ?? ''),
      );
      if (description != null) return description;
    }
    return null;
  }

  static Map<String, String> _attributes(String? tag) {
    if (tag == null) return const <String, String>{};
    final result = <String, String>{};
    final expression = RegExp(
      r'''([:\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
      caseSensitive: false,
    );
    for (final match in expression.allMatches(tag)) {
      final name = match.group(1)?.toLowerCase();
      final value = match.group(2) ?? match.group(3);
      if (name != null && value != null) result[name] = value;
    }
    return result;
  }

  static String _decodeHtmlEntities(String value) => value.replaceAllMapped(
    RegExp(r'&(#(?:x[0-9a-f]+|\d+)|[a-z]+);', caseSensitive: false),
    (match) {
      final entity = match.group(1)?.toLowerCase() ?? '';
      final named = const <String, String>{
        'amp': '&',
        'apos': "'",
        'quot': '"',
        'lt': '<',
        'gt': '>',
        'nbsp': ' ',
        'hellip': '…',
        'lsquo': '‘',
        'rsquo': '’',
        'ldquo': '“',
        'rdquo': '”',
        'ndash': '–',
        'mdash': '—',
      }[entity];
      if (named != null) return named;
      if (!entity.startsWith('#')) return match.group(0)!;
      final hexadecimal = entity.startsWith('#x');
      final number = int.tryParse(
        entity.substring(hexadecimal ? 2 : 1),
        radix: hexadecimal ? 16 : 10,
      );
      if (number == null ||
          number <= 0 ||
          number > 0x10ffff ||
          (number >= 0xd800 && number <= 0xdfff)) {
        return match.group(0)!;
      }
      return String.fromCharCode(number);
    },
  );

  static String? _sanitizeDescription(Object? value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    final plain = raw
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (plain.isEmpty ||
        plain.length > maximumDescriptionLength ||
        RegExp(
          r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]',
        ).hasMatch(plain)) {
      return null;
    }
    return plain;
  }

  static Future<Uint8List> _readBody(
    ResponseBody body,
    CancelToken cancel,
    int maximumBytes,
  ) async {
    final bytes = BytesBuilder(copy: false);
    final result = Completer<Uint8List>();
    final subscription = body.stream.listen(
      (chunk) {
        if (cancel.isCancelled || result.isCompleted) return;
        if (bytes.length + chunk.length > maximumBytes) {
          result.completeError(const FormatException('Metadata too large.'));
        } else {
          bytes.add(chunk);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    try {
      return await Future.any<Uint8List>([
        result.future,
        cancel.whenCancel.then<Uint8List>((error) => throw error),
      ]);
    } finally {
      unawaited(subscription.cancel());
    }
  }

  static int? _positiveInt(Object? value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static bool _isMovie(Object? value) =>
      value?.toString().trim().toLowerCase() == 'movie';

  static String _normalizeLanguage(String value) =>
      value.trim().toLowerCase().split(RegExp('[-_]')).first;

  static Dio _defaultAniZipDio() => Dio(
    BaseOptions(
      baseUrl: 'https://api.ani.zip/',
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      headers: const <String, dynamic>{'Accept': 'application/json'},
    ),
  );

  static Dio _defaultTmdbDio() => Dio(
    BaseOptions(
      baseUrl: 'https://www.themoviedb.org/',
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      headers: const <String, dynamic>{
        'Accept': 'text/html',
        'User-Agent': 'TetoTV/2.0 localized-metadata',
      },
    ),
  );
}

class _CachedDescription {
  const _CachedDescription._({required this.found, this.description});

  const _CachedDescription.missing() : this._(found: false);
  const _CachedDescription.negative() : this._(found: true);
  const _CachedDescription.positive(String description)
    : this._(found: true, description: description);

  final bool found;
  final String? description;
}
