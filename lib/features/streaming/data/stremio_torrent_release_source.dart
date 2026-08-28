import 'dart:convert';
import 'dart:typed_data';

import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/data/public_https_dio.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';

/// Reads any Stremio-compatible stream add-on that returns torrent info hashes.
///
/// No manifest is bundled or discovered automatically. The user must enter a
/// trusted HTTPS manifest URL explicitly. Debrid credentials are never sent to
/// the add-on; only the selected magnet is passed to the chosen debrid service.
class StremioTorrentReleaseSource implements ReleaseSource {
  StremioTorrentReleaseSource({
    required String manifestUrl,
    Dio? addonDio,
    Dio? kitsuDio,
    Dio? cinemetaDio,
    Future<void> Function(Uri uri)? targetValidator,
  }) : _manifestUri = _validateManifestUrl(manifestUrl),
       _targetValidator = targetValidator ?? validatePublicNetworkTarget,
       _addonDio =
           addonDio ??
           createPinnedPublicHttpsDio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 30),
               followRedirects: false,
               headers: const {
                 'Accept': 'application/json',
                 'User-Agent':
                     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
               },
             ),
           ),
       _kitsuDio =
           kitsuDio ??
           Dio(
             BaseOptions(
               baseUrl: 'https://kitsu.io/api/edge',
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 20),
               headers: const {
                 'Accept': 'application/vnd.api+json',
                 'User-Agent':
                     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
               },
             ),
           ),
       _cinemetaDio =
           cinemetaDio ??
           createPinnedPublicHttpsDio(
             BaseOptions(
               baseUrl: 'https://v3-cinemeta.strem.io',
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 20),
               followRedirects: false,
               headers: const {
                 'Accept': 'application/json',
                 'User-Agent':
                     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
               },
             ),
           );

  final Uri _manifestUri;
  final Dio _addonDio;
  final Dio _kitsuDio;
  final Dio _cinemetaDio;
  final Future<void> Function(Uri uri) _targetValidator;
  final Map<int, String> _kitsuIds = {};
  final Map<int, String> _imdbVideoIds = {};
  Future<_StremioStreamCapability>? _streamCapability;
  static const _maximumStreamResponseBytes = 2 * 1024 * 1024;

  @override
  String get id => 'stremio:${_manifestUri.host}${_manifestUri.path}';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async {
    final capability = await (_streamCapability ??= _loadStreamCapability());
    Object? identifierError;
    var completedRequest = false;
    int? lastHttpStatus;
    Object? lastRequestError;

    if (capability.acceptsPrefix('kitsu')) {
      try {
        final kitsuId = await _resolveKitsuId(episode);
        final videoId = 'kitsu:$kitsuId:${episode.episode}';
        final requests = <({String type, String videoId})>[];
        if (capability.types.contains('anime')) {
          requests.add((type: 'anime', videoId: videoId));
        }
        if (capability.types.contains('series')) {
          requests.add((type: 'series', videoId: videoId));
        }
        final outcome = await _searchRoutes(requests);
        if (outcome.releases.isNotEmpty) return outcome.releases;
        completedRequest |= outcome.completedRequest;
        lastHttpStatus = outcome.lastHttpStatus ?? lastHttpStatus;
        lastRequestError = outcome.lastRequestError ?? lastRequestError;
      } catch (error) {
        identifierError = error;
      }
    }

    // IMDb lookup is intentionally lazy: compatible Kitsu results do not
    // disclose the title to another metadata service or pay its latency cost.
    if (capability.types.contains('series') && capability.acceptsPrefix('tt')) {
      try {
        final outcome = await _searchRoutes([
          (type: 'series', videoId: await _resolveImdbVideoId(episode)),
        ]);
        if (outcome.releases.isNotEmpty) return outcome.releases;
        completedRequest |= outcome.completedRequest;
        lastHttpStatus = outcome.lastHttpStatus ?? lastHttpStatus;
        lastRequestError = outcome.lastRequestError ?? lastRequestError;
      } catch (error) {
        identifierError ??= error;
      }
    }

    if (completedRequest) return const [];
    if (lastHttpStatus != null) {
      throw FormatException(
        'The Stremio add-on could not load streams (HTTP $lastHttpStatus).',
      );
    }
    if (lastRequestError != null) throw lastRequestError;
    if (identifierError != null) throw identifierError;
    throw const FormatException(
      'This Stremio add-on does not advertise a compatible anime stream ID.',
    );
  }

  Future<_StremioRouteOutcome> _searchRoutes(
    List<({String type, String videoId})> requests,
  ) async {
    int? lastHttpStatus;
    Object? lastRequestError;
    var completedRequest = false;
    for (final request in requests) {
      final streamUri = _manifestUri.resolve(
        'stream/${request.type}/${Uri.encodeComponent(request.videoId)}.json',
      );
      try {
        final body = await _getAddonJson(streamUri, responseKind: 'stream');
        completedRequest = true;
        final releases = parseStreams(body, sourceId: id);
        if (releases.isNotEmpty) {
          return _StremioRouteOutcome(
            releases: releases,
            completedRequest: true,
          );
        }
      } on _StremioHttpException catch (error) {
        lastHttpStatus = error.statusCode;
      } catch (error) {
        lastRequestError = error;
      }
    }
    return _StremioRouteOutcome(
      completedRequest: completedRequest,
      lastHttpStatus: lastHttpStatus,
      lastRequestError: lastRequestError,
    );
  }

  Future<String> _resolveImdbVideoId(EpisodeReference episode) async {
    final cached = _imdbVideoIds[episode.anilistMediaId];
    if (cached != null) {
      return _withImdbEpisode(cached, episode.episode);
    }

    final queries = <String>[
      episode.title,
      ...episode.alternativeTitles,
    ].where((value) => value.trim().isNotEmpty).take(3);
    final targets = queries.map(_normalizeTitle).toSet();
    Map<String, dynamic>? best;
    var bestScore = -1;
    for (final query in queries) {
      final body = await _getCinemetaJson(
        '/catalog/series/top/search=${Uri.encodeComponent(query)}.json',
      );
      final metas = body['metas'];
      if (metas is! List<dynamic>) continue;
      for (final value in metas) {
        if (value is! Map<String, dynamic>) continue;
        final id = value['id']?.toString() ?? '';
        if (!RegExp(r'^tt\d+$').hasMatch(id)) continue;
        final title = _normalizeTitle(value['name']?.toString() ?? '');
        var score = targets.contains(title) ? 1000 : 0;
        if (score == 0 &&
            targets.any(
              (target) => title.contains(target) || target.contains(title),
            )) {
          score = 700;
        }
        if (episode.year != null &&
            _releaseYears(value['releaseInfo']).contains(episode.year)) {
          score += 100;
        }
        if (score > bestScore) {
          best = value;
          bestScore = score;
        }
      }
      if (bestScore >= 1100) break;
    }
    final imdbId = best?['id']?.toString();
    if (imdbId == null || bestScore < 700) {
      throw StateError('Could not match this title to an IMDb series ID.');
    }

    final metaBody = await _getCinemetaJson(
      '/meta/series/${Uri.encodeComponent(imdbId)}.json',
    );
    final meta = metaBody['meta'];
    final videos = meta is Map<String, dynamic> ? meta['videos'] : null;
    if (videos is! List<dynamic>) {
      throw StateError('IMDb metadata did not include episode information.');
    }
    final matching = videos
        .whereType<Map<String, dynamic>>()
        .where((video) => _intValue(video['episode']) == episode.episode)
        .where((video) => (_intValue(video['season']) ?? 0) > 0)
        .toList(growable: false);
    if (matching.isEmpty) {
      throw StateError('IMDb metadata did not include this episode.');
    }
    matching.sort((left, right) {
      final leftDistance = _episodeYearDistance(left, episode.year);
      final rightDistance = _episodeYearDistance(right, episode.year);
      final year = leftDistance.compareTo(rightDistance);
      if (year != 0) return year;
      return (_intValue(left['season']) ?? 999).compareTo(
        _intValue(right['season']) ?? 999,
      );
    });
    final selectedId = matching.first['id']?.toString();
    final match = selectedId == null
        ? null
        : RegExp(r'^(tt\d+):(\d+):(\d+)$').firstMatch(selectedId);
    if (match == null) {
      throw StateError('IMDb metadata returned an invalid episode ID.');
    }
    final seriesAndSeason = '${match.group(1)}:${match.group(2)}';
    _imdbVideoIds[episode.anilistMediaId] = seriesAndSeason;
    return _withImdbEpisode(seriesAndSeason, episode.episode);
  }

  String _withImdbEpisode(String seriesAndSeason, int episode) =>
      '$seriesAndSeason:$episode';

  Future<Map<String, dynamic>> _getCinemetaJson(String path) async {
    final uri = Uri.parse('https://v3-cinemeta.strem.io').resolve(path);
    final response = await _cinemetaDio.getUri<dynamic>(
      uri,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.stream,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 600,
      ),
    );
    final status = response.statusCode ?? 500;
    if (status >= 300) {
      throw FormatException('IMDb metadata lookup failed (HTTP $status).');
    }
    return _boundedStreamResponse(response.data);
  }

  Future<_StremioStreamCapability> _loadStreamCapability() async {
    final body = await _getAddonJson(_manifestUri, responseKind: 'manifest');
    return _StremioStreamCapability.fromManifest(body);
  }

  Future<Map<String, dynamic>> _getAddonJson(
    Uri uri, {
    required String responseKind,
  }) async {
    await _targetValidator(uri);
    final response = await _addonDio.getUri<dynamic>(
      uri,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.stream,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 600,
      ),
    );
    final status = response.statusCode ?? 500;
    if (status >= 300 && status < 400) {
      throw const FormatException(
        'Torrent source redirects are not accepted. Enter its final public HTTPS manifest URL.',
      );
    }
    if (status >= 400) throw _StremioHttpException(status);
    final declaredLength = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    if (declaredLength != null &&
        declaredLength > _maximumStreamResponseBytes) {
      throw FormatException(
        'The Stremio add-on returned an oversized $responseKind response.',
      );
    }
    return _boundedStreamResponse(response.data);
  }

  Future<String> _resolveKitsuId(EpisodeReference episode) async {
    final cached = _kitsuIds[episode.anilistMediaId];
    if (cached != null) return cached;

    if (episode.malMediaId != null) {
      try {
        final response = await _kitsuDio.get<dynamic>(
          '/mappings',
          queryParameters: {
            'filter[externalSite]': 'myanimelist/anime',
            'filter[externalId]': episode.malMediaId.toString(),
            'include': 'item',
          },
        );
        final body = response.data;
        if (body is Map<String, dynamic>) {
          final data = body['data'];
          if (data is List<dynamic> && data.isNotEmpty) {
            final first = data.first;
            if (first is Map<String, dynamic>) {
              final item = first['relationships']?['item']?['data'];
              if (item is Map<String, dynamic>) {
                final id = item['id']?.toString();
                if (id != null && id.isNotEmpty) {
                  _kitsuIds[episode.anilistMediaId] = id;
                  return id;
                }
              }
            }
          }
        }
      } catch (_) {
        // Fall back to title search on failure
      }
    }

    final queries = <String>[
      episode.title,
      ...episode.alternativeTitles,
    ].where((value) => value.trim().isNotEmpty);
    final targets = queries.map(_normalizeTitle).toSet();
    Map<String, dynamic>? best;
    var bestScore = -1;

    for (final query in queries.take(3)) {
      final response = await _kitsuDio.get<dynamic>(
        '/anime',
        queryParameters: {'filter[text]': query, 'page[limit]': 10},
      );
      final body = response.data;
      if (body is! Map<String, dynamic>) continue;
      final data = body['data'];
      if (data is! List<dynamic>) continue;
      for (final value in data) {
        if (value is! Map<String, dynamic>) continue;
        final score = _titleScore(value, targets);
        if (score > bestScore) {
          best = value;
          bestScore = score;
        }
      }
      if (bestScore >= 1000) break;
    }

    final kitsuId = best?['id']?.toString();
    if (kitsuId == null || kitsuId.isEmpty || bestScore < 700) {
      throw StateError('Could not match this title to a Kitsu anime ID.');
    }
    _kitsuIds[episode.anilistMediaId] = kitsuId;
    return kitsuId;
  }

  static List<ReleaseCandidate> parseStreams(
    Map<String, dynamic> body, {
    String sourceId = 'stremio',
  }) {
    final values = body['streams'];
    if (values is! List<dynamic>) return const [];
    final candidates = <ReleaseCandidate>[];

    for (final value in values) {
      if (value is! Map<String, dynamic>) continue;
      final infoHash = value['infoHash']?.toString().trim() ?? '';
      if (!RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(infoHash)) continue;

      final name = value['name']?.toString() ?? 'Torrent source';
      final title = value['title']?.toString() ?? name;
      final hints = value['behaviorHints'];
      final filename = hints is Map<String, dynamic>
          ? hints['filename']?.toString()
          : null;
      final searchable = '$name\n$title\n${filename ?? ''}';
      final lower = searchable.toLowerCase();
      final quality = _firstMatch(
        RegExp(r'\b(2160p|4k|1440p|1080p|720p|480p)\b', caseSensitive: false),
        searchable,
      );
      final codecRaw = _firstMatch(
        RegExp(
          r'\b(AV1|HEVC|x265|H[.]?265|x264|H[.]?264)\b',
          caseSensitive: false,
        ),
        searchable,
      );
      final seeders =
          int.tryParse(_firstMatch(RegExp(r'👤\s*(\d+)'), searchable) ?? '') ??
          0;
      final size = _sizeMatch(searchable);
      final provider = _firstMatch(RegExp(r'⚙️\s*([^\r\n]+)'), searchable);
      final isDubbed =
          lower.contains('dubbed') ||
          RegExp(r'(^|[^a-z0-9])dub([^a-z0-9]|$)').hasMatch(lower) ||
          RegExp(r'\b(?:eng|english)\s+audio\b').hasMatch(lower) ||
          lower.contains('dual audio') ||
          lower.contains('dual-audio') ||
          lower.contains('multi audio') ||
          lower.contains('multi-audio');
      final hasSubtitles =
          !isDubbed ||
          lower.contains('multi subs') ||
          lower.contains('multi-subs') ||
          lower.contains('multiple subtitle') ||
          lower.contains('subbed');

      candidates.add(
        ReleaseCandidate(
          infoHash: infoHash.toLowerCase(),
          magnetUri: 'magnet:?xt=urn:btih:${infoHash.toLowerCase()}',
          releaseName: title,
          seeders: seeders,
          // [provider] describes the release/uploader named by the add-on,
          // while sourceId identifies the installed manifest that supplied
          // it. A torrent hash changes every episode and cannot preserve
          // same-source affinity across a series.
          sourceId: sourceId,
          isBatch:
              lower.contains('batch') ||
              RegExp(r'\b\d{1,3}\s*-\s*\d{1,3}\b').hasMatch(lower),
          preferredFileIndex: switch (value['fileIdx']) {
            final int index => index,
            final num index => index.toInt(),
            _ => null,
          },
          quality: quality?.toUpperCase() == '4K'
              ? '4K'
              : quality?.toLowerCase(),
          codec: _normalizeCodec(codecRaw),
          sizeLabel: size,
          provider: provider,
          isDubbed: isDubbed,
          hasSubtitles: hasSubtitles,
          isHdr: lower.contains('hdr') || lower.contains('dolby vision'),
        ),
      );
    }

    return candidates;
  }

  static Uri _validateManifestUrl(String value) {
    final uri = safePublicHttpsUri(value.trim());
    if (uri == null || !uri.path.toLowerCase().endsWith('/manifest.json')) {
      throw ArgumentError.value(
        value,
        'manifestUrl',
        'Use an HTTPS Torrent source manifest URL ending in manifest.json.',
      );
    }
    return uri;
  }

  static Future<Map<String, dynamic>> _boundedStreamResponse(
    Object? value,
  ) async {
    Object? decoded = value;
    if (value is ResponseBody) {
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in value.stream) {
        length += chunk.length;
        if (length > _maximumStreamResponseBytes) {
          throw const FormatException(
            'The Stremio add-on returned an oversized stream response.',
          );
        }
        bytes.add(chunk);
      }
      decoded = jsonDecode(
        utf8.decode(bytes.takeBytes(), allowMalformed: false),
      );
    } else if (value is String) {
      if (utf8.encode(value).length > _maximumStreamResponseBytes) {
        throw const FormatException(
          'The Stremio add-on returned an oversized stream response.',
        );
      }
      decoded = jsonDecode(value);
    }
    if (decoded is! Map) {
      throw const FormatException(
        'The Stremio add-on returned an invalid stream response.',
      );
    }
    return decoded.map((key, item) => MapEntry('$key', item));
  }

  static int _titleScore(Map<String, dynamic> item, Set<String> targets) {
    final attributes = item['attributes'];
    if (attributes is! Map<String, dynamic>) return 0;
    final titles = <String>[
      attributes['canonicalTitle']?.toString() ?? '',
      if (attributes['titles'] case final Map<String, dynamic> values)
        ...values.values.map((value) => value?.toString() ?? ''),
      if (attributes['abbreviatedTitles'] case final List<dynamic> values)
        ...values.map((value) => value?.toString() ?? ''),
    ].map(_normalizeTitle).where((value) => value.isNotEmpty);

    var score = 0;
    for (final title in titles) {
      for (final target in targets) {
        if (title == target) return 1000;
        if (title.contains(target) || target.contains(title)) {
          score = score < 700 ? 700 : score;
        }
      }
    }
    return score;
  }

  static Set<int> _releaseYears(Object? value) => RegExp(r'\b(?:19|20)\d{2}\b')
      .allMatches(value?.toString() ?? '')
      .map((match) {
        return int.parse(match.group(0)!);
      })
      .toSet();

  static int? _intValue(Object? value) => switch (value) {
    final int number => number,
    final num number => number.toInt(),
    _ => int.tryParse(value?.toString() ?? ''),
  };

  static int _episodeYearDistance(Map<String, dynamic> video, int? targetYear) {
    if (targetYear == null) return 0;
    final released = DateTime.tryParse(video['released']?.toString() ?? '');
    return released == null ? 999 : (released.year - targetYear).abs();
  }

  static String _normalizeTitle(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String? _firstMatch(RegExp expression, String value) =>
      expression.firstMatch(value)?.group(1)?.trim();

  static String? _sizeMatch(String value) {
    final match = RegExp(
      r'💾\s*([0-9.]+)\s*(KB|MB|GB|TB)',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return null;
    return '${match.group(1)} ${match.group(2)!.toUpperCase()}';
  }

  static String? _normalizeCodec(String? value) {
    if (value == null) return null;
    final lower = value.toLowerCase();
    if (lower == 'av1') return 'AV1';
    if (lower == 'hevc' || lower.contains('265')) return 'HEVC';
    if (lower.contains('264')) return 'H.264';
    return value.toUpperCase();
  }
}

class _StremioStreamCapability {
  const _StremioStreamCapability({
    required this.types,
    required this.idPrefixes,
  });

  factory _StremioStreamCapability.fromManifest(Map<String, dynamic> body) {
    final manifestTypes = _stringSet(body['types']);
    final manifestPrefixes = _stringSet(body['idPrefixes']);
    final resources = body['resources'];
    if (resources is! List<dynamic>) {
      throw const FormatException(
        'The Torrent source manifest does not declare stream resources.',
      );
    }
    for (final resource in resources) {
      if (resource is String && resource.toLowerCase() == 'stream') {
        return _StremioStreamCapability(
          types: manifestTypes,
          idPrefixes: manifestPrefixes,
        );
      }
      if (resource is Map &&
          resource['name']?.toString().toLowerCase() == 'stream') {
        final resourceTypes = _stringSet(resource['types']);
        final resourcePrefixes = _stringSet(resource['idPrefixes']);
        return _StremioStreamCapability(
          types: resourceTypes.isEmpty ? manifestTypes : resourceTypes,
          idPrefixes: resourcePrefixes.isEmpty
              ? manifestPrefixes
              : resourcePrefixes,
        );
      }
    }
    throw const FormatException(
      'The Torrent source manifest does not declare a stream resource.',
    );
  }

  final Set<String> types;
  final Set<String> idPrefixes;

  bool acceptsPrefix(String prefix) =>
      idPrefixes.isEmpty || idPrefixes.any(prefix.startsWith);

  static Set<String> _stringSet(Object? value) {
    if (value is! List<dynamic>) return const {};
    return value
        .map((item) => item.toString().trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
  }
}

class _StremioHttpException implements Exception {
  const _StremioHttpException(this.statusCode);

  final int statusCode;
}

class _StremioRouteOutcome {
  const _StremioRouteOutcome({
    this.releases = const [],
    required this.completedRequest,
    this.lastHttpStatus,
    this.lastRequestError,
  });

  final List<ReleaseCandidate> releases;
  final bool completedRequest;
  final int? lastHttpStatus;
  final Object? lastRequestError;
}
