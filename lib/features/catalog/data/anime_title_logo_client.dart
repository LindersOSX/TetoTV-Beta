import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:dio/dio.dart';

abstract interface class AnimeTitleLogoCacheStore {
  Future<Map<String, dynamic>?> read(String key, {bool allowExpired = false});

  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    required Duration maxAge,
  });
}

class TetoTvAnimeTitleLogoCacheStore implements AnimeTitleLogoCacheStore {
  const TetoTvAnimeTitleLogoCacheStore();

  @override
  Future<Map<String, dynamic>?> read(String key, {bool allowExpired = false}) =>
      TetoTvDatabase.instance.cachedJson(
        key,
        allowExpired: allowExpired,
        maxStaleAge: allowExpired ? const Duration(days: 90) : null,
      );

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    required Duration maxAge,
  }) => TetoTvDatabase.instance.cacheJson(key, value, maxAge: maxAge);
}

/// Resolves transparent anime title artwork without making details dependent
/// on a single artwork service.
///
/// AniZip is used as the AniList -> TVDB crosswalk and can itself expose a
/// TVDB ClearLogo. Fanart.tv is then an optional higher-coverage fallback when
/// the app is built with `--dart-define=FANART_TV_API_KEY=...`.
class AnimeTitleLogoClient {
  AnimeTitleLogoClient({
    Dio? aniZipDio,
    Dio? fanartDio,
    AnimeTitleLogoCacheStore? cacheStore,
    String? fanartApiKey,
    String? fanartClientKey,
  }) : _aniZipDio = aniZipDio ?? _defaultAniZipDio(),
       _fanartDio = fanartDio ?? _defaultFanartDio(),
       _cacheStore = cacheStore ?? const TetoTvAnimeTitleLogoCacheStore(),
       _fanartApiKey = (fanartApiKey ?? _compiledFanartApiKey).trim(),
       _fanartClientKey = (fanartClientKey ?? _compiledFanartClientKey).trim();

  static const _compiledFanartApiKey = String.fromEnvironment(
    'FANART_TV_API_KEY',
  );
  static const _compiledFanartClientKey = String.fromEnvironment(
    'FANART_TV_CLIENT_KEY',
  );
  // V7 invalidates device-side misses from the first ClearLogo rollout. That
  // release could silently retain a transport/CDN failure as text for hours,
  // making newly available artwork look permanently unsupported.
  static const _cacheSchema = 7;
  static const _positiveCacheAge = Duration(days: 14);
  static const _negativeCacheAge = Duration(hours: 12);
  static const maximumMetadataResponseBytes = 8 * 1024 * 1024;

  final Dio _aniZipDio;
  final Dio _fanartDio;
  final AnimeTitleLogoCacheStore _cacheStore;
  final String _fanartApiKey;
  final String _fanartClientKey;
  final Map<({int aniListId, String language}), Future<AnimeTitleLogo?>>
  _pending = {};

  Future<AnimeTitleLogo?> lookup(
    int aniListId, {
    String preferredLanguage = 'en',
  }) {
    if (aniListId <= 0) return Future.value();
    final language = _normalizeRequestedLanguage(preferredLanguage);
    final request = (aniListId: aniListId, language: language);
    return _pending.putIfAbsent(
      request,
      () => _lookup(aniListId, preferredLanguage: language).whenComplete(() {
        // Do not return the removed Future from this callback. `whenComplete`
        // adopts a Future returned by its action, and returning this same
        // in-flight lookup would make it wait on itself forever.
        _pending.remove(request);
      }),
    );
  }

  Future<AnimeTitleLogo?> _lookup(
    int aniListId, {
    required String preferredLanguage,
  }) async {
    final languageKey = preferredLanguage == 'en' ? '' : ':$preferredLanguage';
    final cacheKey = 'title-logo:v$_cacheSchema$languageKey:anilist:$aniListId';
    final cached = await _readCache(cacheKey);
    if (cached.found) {
      _recordTitleLogoDiagnostic(
        aniListId: aniListId,
        language: preferredLanguage,
        stage: 'cache',
        outcome: cached.logo == null ? 'negative_hit' : 'positive_hit',
        source: cached.logo?.source,
      );
      return cached.logo;
    }

    try {
      final response = await _aniZipDio.get<Object?>(
        'mappings',
        queryParameters: {'anilist_id': aniListId},
        // Decode this response ourselves. Some CDN/device combinations expose
        // AniZip's JSON document as text, while others let Dio turn it into a
        // map. Explicit plain-text handling keeps both paths deterministic and
        // lets us reject unexpectedly large metadata before parsing it.
        options: Options(responseType: ResponseType.plain),
      );
      final body = decodeMetadataResponse(response.data);
      if (body == null) throw const FormatException('Invalid AniZip response.');
      final tvdbId = _positiveInt(_map(body['mappings'])?['thetvdb_id']);
      var logo = parseAniZipLogo(
        body,
        tvdbId: tvdbId,
        preferredLanguage: preferredLanguage,
      );
      _recordTitleLogoDiagnostic(
        aniListId: aniListId,
        language: preferredLanguage,
        stage: 'anizip',
        outcome: logo != null
            ? 'candidate'
            : tvdbId == null
            ? 'mapping_missing'
            : 'logo_missing',
        source: logo?.source,
      );
      // Fanart is the preferred logo source, while AniZip remains the
      // crosswalk and an outage-safe fallback. Always ask Fanart when the
      // release has a project key; otherwise a matching but lower-resolution
      // AniZip logo would permanently prevent an HD clear-logo lookup.
      if (tvdbId != null && _fanartApiKey.isNotEmpty) {
        try {
          logo = _preferLogo(
            logo,
            await _lookupFanart(tvdbId, preferredLanguage: preferredLanguage),
            preferredLanguage: preferredLanguage,
          );
        } catch (_) {
          // Keep a safe AniZip fallback when optional Fanart lookup fails.
          if (logo == null) rethrow;
        }
      }
      await _writeCache(cacheKey, logo);
      _recordTitleLogoDiagnostic(
        aniListId: aniListId,
        language: preferredLanguage,
        stage: 'complete',
        outcome: logo == null ? 'text_fallback' : 'logo_ready',
        source: logo?.source,
      );
      return logo;
    } catch (error) {
      _recordTitleLogoDiagnostic(
        aniListId: aniListId,
        language: preferredLanguage,
        stage: 'lookup',
        outcome: 'failed',
        reason: _safeTitleLogoFailureReason(error),
      );
      // Artwork is decorative. A stale safe URL is better than blocking or
      // replacing the normal text title when either metadata service is down.
      final stale = await _readCache(cacheKey, allowExpired: true);
      return stale.logo;
    }
  }

  Future<AnimeTitleLogo?> _lookupFanart(
    int tvdbId, {
    required String preferredLanguage,
  }) async {
    final response = await _fanartDio.get<Object?>(
      'tv/$tvdbId',
      queryParameters: {
        'api_key': _fanartApiKey,
        if (_fanartClientKey.isNotEmpty) 'client_key': _fanartClientKey,
      },
    );
    final body = _map(response.data);
    return body == null
        ? null
        : parseFanartLogo(
            body,
            tvdbId: tvdbId,
            preferredLanguage: preferredLanguage,
          );
  }

  Future<_CachedLogo> _readCache(
    String cacheKey, {
    bool allowExpired = false,
  }) async {
    try {
      final cached = await _cacheStore.read(
        cacheKey,
        allowExpired: allowExpired,
      );
      if (cached == null || cached['schema'] != _cacheSchema) {
        return const _CachedLogo.missing();
      }
      if (cached['found'] != true) return const _CachedLogo.negative();
      final value = _map(cached['logo']);
      final logo = value == null ? null : AnimeTitleLogo.fromJson(value);
      return logo == null
          ? const _CachedLogo.missing()
          : _CachedLogo.positive(logo);
    } catch (_) {
      return const _CachedLogo.missing();
    }
  }

  Future<void> _writeCache(String cacheKey, AnimeTitleLogo? logo) async {
    try {
      await _cacheStore.write(cacheKey, {
        'schema': _cacheSchema,
        'found': logo != null,
        if (logo != null) 'logo': logo.toJson(),
      }, maxAge: logo == null ? _negativeCacheAge : _positiveCacheAge);
    } catch (_) {
      // A cache write must never make show details fail.
    }
  }

  static AnimeTitleLogo? parseAniZipLogo(
    Map<String, dynamic> body, {
    int? tvdbId,
    String preferredLanguage = 'en',
  }) {
    final normalizedPreference = _normalizeRequestedLanguage(preferredLanguage);
    final candidates = _list(body['images'])
        .map(_map)
        .whereType<Map<String, dynamic>>()
        .where(
          (image) =>
              image['coverType']?.toString().toLowerCase() == 'clearlogo',
        )
        .map((image) {
          final url = Uri.tryParse(image['url']?.toString() ?? '');
          if (!isSafeAnimeTitleLogoUri(url)) return null;
          final language = _artworkLanguage(image);
          if (!_matchesRequestedLanguage(language, normalizedPreference)) {
            return null;
          }
          return (
            url: url!,
            language: language,
            score:
                _languagePreference(language, normalizedPreference) * 1000000 +
                _imagePreference(url) * 1000 +
                _artworkLikes(image),
          );
        })
        .whereType<({Uri url, String? language, int score})>()
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) => right.score.compareTo(left.score));
    return AnimeTitleLogo(
      url: candidates.first.url,
      source: AnimeTitleLogoSource.aniZip,
      tvdbId: tvdbId,
      languageCode: candidates.first.language,
    );
  }

  /// Decodes the small AniZip mapping document regardless of whether the
  /// transport returned a JSON map, UTF-8 bytes, or JSON text.
  ///
  /// The byte limit prevents a malformed endpoint response from allocating an
  /// unbounded JSON object on TV hardware. Already-decoded maps are retained
  /// for injected clients and backwards-compatible cache/test callers.
  static Map<String, dynamic>? decodeMetadataResponse(Object? value) {
    if (value is Map) return _map(value);

    List<int> bytes;
    if (value is String) {
      if (value.length > maximumMetadataResponseBytes) return null;
      bytes = utf8.encode(value);
    } else if (value is List<int>) {
      bytes = value;
    } else {
      return null;
    }
    if (bytes.isEmpty || bytes.length > maximumMetadataResponseBytes) {
      return null;
    }
    try {
      return _map(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      return null;
    }
  }

  static AnimeTitleLogo? parseFanartLogo(
    Map<String, dynamic> body, {
    required int tvdbId,
    String preferredLanguage = 'en',
  }) {
    final normalizedPreference = _normalizeRequestedLanguage(preferredLanguage);
    final candidates =
        <
          ({Uri url, AnimeTitleLogoSource source, String? language, int score})
        >[];
    for (final entry in const <(String, AnimeTitleLogoSource)>[
      ('hdtvlogo', AnimeTitleLogoSource.fanartTvHd),
      ('clearlogo', AnimeTitleLogoSource.fanartTv),
    ]) {
      final sourceScore = entry.$2 == AnimeTitleLogoSource.fanartTvHd ? 2 : 1;
      candidates.addAll(
        _list(body[entry.$1])
            .map(_map)
            .whereType<Map<String, dynamic>>()
            .map((item) {
              final url = Uri.tryParse(item['url']?.toString() ?? '');
              if (!isSafeAnimeTitleLogoUri(url)) return null;
              final language = _artworkLanguage(item);
              if (!_matchesRequestedLanguage(language, normalizedPreference)) {
                return null;
              }
              return (
                url: url!,
                source: entry.$2,
                language: language,
                score:
                    _languagePreference(language, normalizedPreference) *
                        1000000000 +
                    sourceScore * 1000000 +
                    _artworkLikes(item),
              );
            })
            .whereType<
              ({
                Uri url,
                AnimeTitleLogoSource source,
                String? language,
                int score,
              })
            >(),
      );
    }
    if (candidates.isNotEmpty) {
      candidates.sort((left, right) => right.score.compareTo(left.score));
      final selected = candidates.first;
      return AnimeTitleLogo(
        url: selected.url,
        source: selected.source,
        tvdbId: tvdbId,
        languageCode: selected.language,
      );
    }
    return null;
  }

  static Dio _defaultAniZipDio() => Dio(
    BaseOptions(
      baseUrl: 'https://api.ani.zip/',
      connectTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 10),
      headers: const {'Accept': 'application/json'},
    ),
  );

  static Dio _defaultFanartDio() => Dio(
    BaseOptions(
      baseUrl: 'https://webservice.fanart.tv/v3.2/',
      connectTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      headers: const {'Accept': 'application/json'},
    ),
  );
}

void _recordTitleLogoDiagnostic({
  required int aniListId,
  required String language,
  required String stage,
  required String outcome,
  AnimeTitleLogoSource? source,
  String? reason,
}) {
  unawaited(
    TetoTvDatabase.instance.recordDiagnosticEvent(
      category: 'title-logo',
      message: 'Title logo lookup',
      details: {
        'anilist_id': aniListId,
        'language': language,
        'stage': stage,
        'outcome': outcome,
        'source': ?source?.name,
        'reason': ?reason,
        'fanart_configured': AnimeTitleLogoClient._compiledFanartApiKey
            .trim()
            .isNotEmpty,
      },
    ),
  );
}

String _safeTitleLogoFailureReason(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    return status == null ? 'network' : 'http_$status';
  }
  if (error is FormatException) return 'invalid_metadata';
  if (error is TimeoutException) return 'timeout';
  return 'unexpected';
}

class _CachedLogo {
  const _CachedLogo._({required this.found, this.logo});
  const _CachedLogo.missing() : this._(found: false);
  const _CachedLogo.negative() : this._(found: true);
  const _CachedLogo.positive(AnimeTitleLogo logo)
    : this._(found: true, logo: logo);

  final bool found;
  final AnimeTitleLogo? logo;
}

Map<String, dynamic>? _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}

List<Object?> _list(Object? value) => value is List ? value : const [];

int? _positiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

int _imagePreference(Uri uri) {
  final path = uri.path.toLowerCase();
  if (path.endsWith('.png')) return 3;
  if (path.endsWith('.webp')) return 2;
  return 1;
}

AnimeTitleLogo? _preferLogo(
  AnimeTitleLogo? current,
  AnimeTitleLogo? candidate, {
  required String preferredLanguage,
}) {
  if (current == null) return candidate;
  if (candidate == null) return current;
  if (current.languageCode == null && candidate.languageCode == null) {
    return current;
  }
  final currentScore =
      _languagePreference(current.languageCode, preferredLanguage) * 10 +
      _logoSourcePreference(current.source);
  final candidateScore =
      _languagePreference(candidate.languageCode, preferredLanguage) * 10 +
      _logoSourcePreference(candidate.source);
  return candidateScore > currentScore ? candidate : current;
}

int _logoSourcePreference(AnimeTitleLogoSource source) => switch (source) {
  AnimeTitleLogoSource.fanartTvHd => 3,
  AnimeTitleLogoSource.fanartTv => 2,
  AnimeTitleLogoSource.aniZip => 1,
};

int _languagePreference(String? language, String preferredLanguage) =>
    switch (language) {
      final value when value == preferredLanguage => 3,
      null => 2,
      _ => 0,
    };

bool _matchesRequestedLanguage(String? language, String preferredLanguage) =>
    language == preferredLanguage ||
    (preferredLanguage == 'en' && language == null);

String _normalizeRequestedLanguage(String value) {
  final normalized = _normalizeArtworkLanguage(value);
  return normalized == null || normalized.isEmpty ? 'en' : normalized;
}

int _artworkLikes(Map<String, dynamic> item) =>
    int.tryParse(item['likes']?.toString() ?? '') ?? 0;

String? _artworkLanguage(Map<String, dynamic> item) {
  for (final key in const [
    'lang',
    'language',
    'languageCode',
    'language_code',
    'iso639_1',
    'iso_639_1',
  ]) {
    final normalized = _normalizeArtworkLanguage(item[key]);
    if (normalized != null) return normalized;
  }
  return null;
}

String? _normalizeArtworkLanguage(Object? value) {
  if (value is Map) {
    for (final key in const ['iso_639_1', 'iso639_1', 'code', 'name']) {
      final normalized = _normalizeArtworkLanguage(value[key]);
      if (normalized != null) return normalized;
    }
    return null;
  }
  var normalized = value?.toString().trim().toLowerCase() ?? '';
  if (normalized.isEmpty || normalized == '00' || normalized == 'none') {
    return null;
  }
  normalized = normalized.split(RegExp('[-_]')).first;
  return switch (normalized) {
    'eng' || 'english' => 'en',
    'jpn' || 'japanese' => 'ja',
    _ => normalized.length <= 12 ? normalized : null,
  };
}
