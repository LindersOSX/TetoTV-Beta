import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:anime_tv/core/preferences/caption_language.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/data/public_https_dio.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_js/quickjs/quickjs_runtime2.dart';

const seanimeProviderRuntimeLimit = Duration(milliseconds: 10500);
const seanimeHlsEnrichmentBudget = Duration(milliseconds: 700);
const seanimeMaximumExternalAudioTracks = 8;

abstract interface class WebStreamingProvider {
  String get id;
  String get name;
  Future<List<WebStreamResult>> streams(
    EpisodeReference episode, {
    WebProviderCancellation? cancellation,
  });
}

class WebProviderSearchCancelled implements Exception {
  const WebProviderSearchCancelled();

  @override
  String toString() => 'Web provider search cancelled.';
}

/// Cooperative cancellation shared by the provider worker pool and the
/// isolate-backed Seanime runtime. Listeners run synchronously so navigation
/// can request a graceful QuickJS shutdown before another screen starts
/// discovery.
class WebProviderCancellation {
  final Set<void Function()> _listeners = {};
  final Completer<void> _cancelledSignal = Completer<void>();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledSignal.future;

  void throwIfCancelled() {
    if (_cancelled) throw const WebProviderSearchCancelled();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void Function() addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

class SeanimeJavascriptProvider implements WebStreamingProvider {
  const SeanimeJavascriptProvider(
    this.addon, {
    this.validateResultTarget = validatePublicNetworkTarget,
    this.preferredSubtitleLanguage = 'eng',
    this.preferredAudio,
  });

  static Future<String>? _domRuntimeSource;

  final InstalledStreamingAddon addon;
  final Future<void> Function(Uri uri) validateResultTarget;
  final String preferredSubtitleLanguage;
  final PlaybackAudioPreference? preferredAudio;

  @override
  String get id => addon.manifest.id;

  @override
  String get name => addon.manifest.name;

  String? get version => addon.manifest.version;

  String? get repositoryHost =>
      safePublicHttpsUri(addon.manifest.repositoryUrl)?.host;

  String get executableHost =>
      (addon.manifest.payloadUri ?? addon.manifest.manifestUri).host;

  @override
  Future<List<WebStreamResult>> streams(
    EpisodeReference episode, {
    WebProviderCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final domRuntime = await (_domRuntimeSource ??= rootBundle.loadString(
      'assets/addon_runtime/linkedom.js',
      cache: true,
    ));
    cancellation?.throwIfCancelled();
    final raw = await _runProviderIsolate(
      {
        'id': addon.manifest.id,
        'name': addon.manifest.name,
        'payload': addon.payload,
        'userConfig': addon.manifest.userConfigDefaults,
        'domRuntime': domRuntime,
        'title': episode.title,
        'titles': seanimeProviderSearchTitles(episode),
        'synonyms': seanimeProviderMediaSynonyms(episode),
        'titleEnglish': episode.titleEnglish,
        'titleRomaji': episode.titleRomaji,
        'titleNative': episode.titleNative,
        'status': episode.status,
        'format': episode.format,
        'episodeCount': episode.episodeCount,
        'absoluteSeasonOffset': episode.absoluteSeasonOffset,
        'isAdult': episode.isAdult,
        'episode': episode.episode,
        'anilistId': episode.anilistMediaId,
        'malId': episode.malMediaId,
        'year': episode.year,
        'requestedSeason': catalogSeasonNumber(episode),
        'preferredSubtitleLanguage': preferredSubtitleLanguage,
        'preferredAudioMode': preferredAudio?.name ?? 'all',
      },
      timeout: seanimeProviderRuntimeLimit,
      cancellation: cancellation,
    );
    cancellation?.throwIfCancelled();
    final expandedRaw = await expandHlsVariantsWithinBudget(raw, cancellation);
    cancellation?.throwIfCancelled();
    final results = <WebStreamResult>[];
    final publicHosts = <String, bool>{};
    var resultTargetFailureReason = 'unsafe_target';
    Future<bool> allowed(Uri uri) async {
      cancellation?.throwIfCancelled();
      final known = publicHosts[uri.host];
      if (known != null) return known;
      try {
        await validateResultTarget(uri);
        cancellation?.throwIfCancelled();
        publicHosts[uri.host] = true;
        return true;
      } on FormatException {
        publicHosts[uri.host] = false;
        return false;
      } catch (_) {
        // DNS lookup/timeout/socket failures are transient network outcomes,
        // not proof that a provider returned a private target. Keeping this
        // distinction prevents one connectivity failure from permanently
        // blocking an otherwise safe extension.
        resultTargetFailureReason = 'network';
        publicHosts[uri.host] = false;
        return false;
      }
    }

    for (final item in expandedRaw) {
      cancellation?.throwIfCancelled();
      final uri = safePublicHttpsUri(item['url']);
      if (uri == null || !await allowed(uri)) continue;
      final candidateSubtitle = safePublicHttpsUri(item['subtitleUrl']);
      final subtitle =
          candidateSubtitle != null && await allowed(candidateSubtitle)
          ? candidateSubtitle
          : null;
      final headers = sanitizeAddonHeaders(
        item['headers'],
        maximumValueLength: 1024,
      );
      final externalAudioTracks = await normalizeSeanimeExternalAudioTracks(
        item['externalAudioTracks'],
        primaryUri: uri,
        primaryHeaders: headers,
        isAllowed: allowed,
        cancellation: cancellation,
      );
      final reportedAudio = webStreamAudioCapabilityFromWire(item);
      final legacyDubbed = item['isDubbed'] == true;
      final audioCapability = reportedAudio != WebStreamAudioCapability.unknown
          ? reportedAudio
          : legacyDubbed
          ? WebStreamAudioCapability.dub
          : item.containsKey('audioCapability')
          ? WebStreamAudioCapability.unknown
          : null;
      final matchedEpisodeNumber = _positiveProviderInt(
        item['matchedEpisodeNumber'],
      );
      final matchedSeasonNumber = _positiveProviderInt(
        item['matchedSeasonNumber'],
      );
      final matchedSeriesTitle = _boundedProviderTitle(
        item['matchedSeriesTitle'],
      );
      results.add(
        WebStreamResult(
          providerId: id,
          providerName: name,
          title: '${item['title'] ?? name}',
          uri: uri,
          quality: item['quality']?.toString(),
          headers: headers,
          subtitleUri: subtitle,
          subtitleLanguage: item['subtitleLanguage'] as String?,
          externalAudioTracks: externalAudioTracks,
          isDubbed: audioCapability?.supportsDub ?? legacyDubbed,
          audioCapability: audioCapability,
          audioLanguages: webStreamAudioLanguagesFromWire(item),
          matchedEpisodeNumber: matchedEpisodeNumber,
          matchedSeasonNumber: matchedSeasonNumber,
          matchedSeriesTitle: matchedSeriesTitle,
        ),
      );
    }
    if (results.isEmpty && raw.isNotEmpty) {
      throw StateError(
        'NO_STREAM: Provider streams failed URL or network safety validation. '
        '[stage=stream_extraction; reason=$resultTargetFailureReason]',
      );
    }
    return results;
  }
}

/// Sandboxed adapter for Seanime's public `manga-provider` contract.
///
/// It intentionally shares the same isolate, QuickJS heap, network policy,
/// redirect validation, and bounded compatibility surface as video providers,
/// while exposing only search, chapter, and page operations to manga code.
class SeanimeJavascriptMangaProvider {
  const SeanimeJavascriptMangaProvider(
    this.addon, {
    this.validateResultTarget = validatePublicNetworkTarget,
  });

  static Future<String>? _domRuntimeSource;

  final InstalledStreamingAddon addon;
  final Future<void> Function(Uri uri) validateResultTarget;

  String get id => addon.manifest.id;
  String get name => addon.manifest.name;
  String get language => addon.manifest.locale;

  Future<List<MangaExtensionTitle>> search(
    String query, {
    int? year,
    WebProviderCancellation? cancellation,
  }) async {
    final normalized = _boundedMangaProviderString(
      query,
      field: 'Manga query',
      maximum: 240,
    );
    final raw = await _runMangaOperation('manga-search', <String, Object?>{
      'query': normalized,
      'year': year,
    }, cancellation: cancellation);
    final allowedHosts = <String, bool>{};
    final output = <MangaExtensionTitle>[];
    for (final item in raw.take(120)) {
      final mangaId = _optionalMangaProviderString(item['id'], maximum: 2048);
      final title = _optionalMangaProviderString(item['title'], maximum: 512);
      if (mangaId == null || title == null) continue;
      Uri? image;
      final candidate = safePublicHttpsUri(item['image']);
      if (candidate != null &&
          await _mangaResultTargetAllowed(
            candidate,
            allowedHosts,
            cancellation,
          )) {
        image = candidate;
      }
      final synonyms = <String>[];
      final rawSynonyms = item['synonyms'];
      if (rawSynonyms is Iterable) {
        for (final value in rawSynonyms.take(32)) {
          final synonym = _optionalMangaProviderString(value, maximum: 256);
          if (synonym != null &&
              !synonyms.any(
                (current) => current.toLowerCase() == synonym.toLowerCase(),
              )) {
            synonyms.add(synonym);
          }
        }
      }
      output.add(
        MangaExtensionTitle(
          providerId: id,
          providerName: name,
          language: language,
          id: mangaId,
          title: title,
          synonyms: synonyms,
          year: _boundedMangaYear(item['year']),
          image: image,
          imageHeaders: image == null
              ? const <String, String>{}
              : sanitizeAddonHeaders(
                  item['imageHeaders'],
                  maximumValueLength: 1024,
                ),
        ),
      );
    }
    return List<MangaExtensionTitle>.unmodifiable(output);
  }

  Future<List<MangaExtensionChapter>> findChapters(
    String mangaId, {
    WebProviderCancellation? cancellation,
  }) async {
    final raw = await _runMangaOperation('manga-chapters', <String, Object?>{
      'mangaId': _boundedMangaProviderString(
        mangaId,
        field: 'Manga identifier',
        maximum: 2048,
      ),
    }, cancellation: cancellation);
    final output = <MangaExtensionChapter>[];
    for (final item in raw.take(1000)) {
      final chapterId = _optionalMangaProviderString(item['id'], maximum: 2048);
      final chapter = _optionalMangaProviderString(
        item['chapter'],
        maximum: 80,
      );
      if (chapterId == null || chapter == null) continue;
      final title =
          _optionalMangaProviderString(item['title'], maximum: 512) ??
          'Chapter $chapter';
      final rawIndex = item['index'];
      final index = rawIndex is num && rawIndex.isFinite
          ? rawIndex.toInt().clamp(0, 999)
          : output.length;
      final url = safePublicHttpsUri(item['url']);
      output.add(
        MangaExtensionChapter(
          id: chapterId,
          title: title,
          chapter: chapter,
          index: index,
          url: url,
          scanlator: _optionalMangaProviderString(
            item['scanlator'],
            maximum: 160,
          ),
          language: _optionalMangaProviderString(item['language'], maximum: 32),
          rating: _boundedMangaRating(item['rating']),
          updatedAt: _boundedMangaDate(item['updatedAt']),
        ),
      );
    }
    output.sort((left, right) {
      final byNumber = (left.chapterNumber ?? left.index.toDouble()).compareTo(
        right.chapterNumber ?? right.index.toDouble(),
      );
      return byNumber != 0 ? byNumber : left.index.compareTo(right.index);
    });
    return List<MangaExtensionChapter>.unmodifiable(output);
  }

  Future<List<MangaExtensionPage>> findChapterPages(
    String chapterId, {
    WebProviderCancellation? cancellation,
  }) async {
    final raw = await _runMangaOperation('manga-pages', <String, Object?>{
      'chapterId': _boundedMangaProviderString(
        chapterId,
        field: 'Chapter identifier',
        maximum: 2048,
      ),
    }, cancellation: cancellation);
    final allowedHosts = <String, bool>{};
    final output = <MangaExtensionPage>[];
    for (final item in raw.take(1000)) {
      cancellation?.throwIfCancelled();
      final uri = safePublicHttpsUri(item['url']);
      if (uri == null ||
          !await _mangaResultTargetAllowed(uri, allowedHosts, cancellation)) {
        continue;
      }
      final rawIndex = item['index'];
      final index = rawIndex is num && rawIndex.isFinite
          ? rawIndex.toInt().clamp(0, 999)
          : output.length;
      output.add(
        MangaExtensionPage(
          uri: uri,
          index: index,
          headers: sanitizeAddonHeaders(
            item['headers'],
            maximumValueLength: 1024,
          ),
        ),
      );
    }
    output.sort((left, right) => left.index.compareTo(right.index));
    if (output.isEmpty && raw.isNotEmpty) {
      throw StateError('Manga pages failed URL or network safety validation.');
    }
    return List<MangaExtensionPage>.unmodifiable(output);
  }

  Future<List<Map<String, dynamic>>> _runMangaOperation(
    String operation,
    Map<String, Object?> arguments, {
    WebProviderCancellation? cancellation,
  }) async {
    if (!addon.enabled || !addon.manifest.isMangaProvider) {
      throw const FormatException('This is not an enabled manga provider.');
    }
    cancellation?.throwIfCancelled();
    final domRuntime = await (_domRuntimeSource ??= rootBundle.loadString(
      'assets/addon_runtime/linkedom.js',
      cache: true,
    ));
    cancellation?.throwIfCancelled();
    return _runProviderIsolate(
      <String, Object?>{
        'id': id,
        'name': name,
        'payload': addon.payload,
        'userConfig': addon.manifest.userConfigDefaults,
        'domRuntime': domRuntime,
        'operation': operation,
        ...arguments,
      },
      timeout: seanimeProviderRuntimeLimit,
      cancellation: cancellation,
    );
  }

  Future<bool> _mangaResultTargetAllowed(
    Uri uri,
    Map<String, bool> cache,
    WebProviderCancellation? cancellation,
  ) async {
    cancellation?.throwIfCancelled();
    final key =
        '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}';
    final known = cache[key];
    if (known != null) return known;
    try {
      await validateResultTarget(uri);
      cancellation?.throwIfCancelled();
      cache[key] = true;
      return true;
    } on WebProviderSearchCancelled {
      rethrow;
    } catch (_) {
      cancellation?.throwIfCancelled();
      cache[key] = false;
      return false;
    }
  }
}

String _boundedMangaProviderString(
  Object? value, {
  required String field,
  required int maximum,
}) {
  final parsed = _optionalMangaProviderString(value, maximum: maximum);
  if (parsed == null) throw FormatException('$field is invalid.');
  return parsed;
}

String? _optionalMangaProviderString(Object? value, {required int maximum}) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty ||
      text.length > maximum ||
      text.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
    return null;
  }
  return text;
}

int? _boundedMangaYear(Object? value) {
  final parsed = switch (value) {
    final int item => item,
    final num item when item.isFinite => item.toInt(),
    final String item => int.tryParse(item.trim()),
    _ => null,
  };
  return parsed != null && parsed >= 1000 && parsed <= 3000 ? parsed : null;
}

double? _boundedMangaRating(Object? value) {
  final parsed = switch (value) {
    final num item when item.isFinite => item.toDouble(),
    final String item => double.tryParse(item.trim()),
    _ => null,
  };
  return parsed != null && parsed >= 0 && parsed <= 100 ? parsed : null;
}

DateTime? _boundedMangaDate(Object? value) {
  if (value is! String || value.length > 80) return null;
  final parsed = DateTime.tryParse(value.trim());
  return parsed?.toUtc();
}

int? _positiveProviderInt(Object? value) {
  final parsed = switch (value) {
    int item => item,
    num item when item.isFinite && item == item.roundToDouble() => item.toInt(),
    String item => int.tryParse(item.trim()),
    _ => null,
  };
  return parsed != null && parsed > 0 && parsed <= 9999 ? parsed : null;
}

String? _boundedProviderTitle(Object? value) {
  final title = value is String ? value.trim() : '';
  return title.length >= 2 && title.length <= 200 ? title : null;
}

String? _boundedProviderTrackText(Object? value) {
  if (value is! String) return null;
  final text = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'[\u202a-\u202e\u2066-\u2069]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.isNotEmpty && text.length <= 80 ? text : null;
}

final class _SeanimeExternalAudioCandidate {
  const _SeanimeExternalAudioCandidate({
    required this.uri,
    required this.headers,
    this.label,
    this.language,
  });

  final Uri uri;
  final String? label;
  final String? language;
  final Map<String, String> headers;
}

Object? _firstProviderMapValue(Map<Object?, Object?> raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value != null) return value;
  }
  return null;
}

String _seanimeExternalAudioCandidateFingerprint(
  _SeanimeExternalAudioCandidate candidate,
) => jsonEncode({
  'url': candidate.uri.toString(),
  'language': candidate.language ?? '',
  'headers': _rawWebStreamHeaderFingerprint(candidate.headers),
});

List<_SeanimeExternalAudioCandidate> _parseSeanimeExternalAudioCandidates(
  Object? raw,
) {
  if (raw is! List) return const [];
  final result = <_SeanimeExternalAudioCandidate>[];
  final seen = <String>{};
  for (final value in raw.take(seanimeMaximumExternalAudioTracks)) {
    final map = value is Map
        ? value.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    final rawUrl = value is String
        ? value
        : _firstProviderMapValue(map, const [
            'url',
            'file',
            'src',
            'link',
            'href',
            'uri',
            'manifest',
            'playlist',
            'streamUrl',
            'hls',
          ]);
    final uri = safePublicHttpsUri(rawUrl);
    if (uri == null) continue;
    final rawLanguage = _boundedProviderTrackText(
      _firstProviderMapValue(map, const [
        'language',
        'lang',
        'locale',
        'audioLanguage',
      ]),
    );
    final canonicalLanguage = canonicalCaptionLanguageCode(rawLanguage);
    final label = _boundedProviderTrackText(
      _firstProviderMapValue(map, const [
            'label',
            'name',
            'title',
            'quality',
          ]) ??
          rawLanguage,
    );
    final headers = sanitizeAddonHeaders(
      _firstProviderMapValue(map, const ['headers', 'requestHeaders']),
      maximumValueLength: 1024,
    );
    final candidate = _SeanimeExternalAudioCandidate(
      uri: uri,
      label: label,
      language: canonicalLanguage.isEmpty ? null : canonicalLanguage,
      headers: headers,
    );
    if (seen.add(_seanimeExternalAudioCandidateFingerprint(candidate))) {
      result.add(candidate);
    }
  }
  return List.unmodifiable(result);
}

Map<String, String> _mergeSeanimeExternalAudioHeaders(
  Map<String, String> inherited,
  Map<String, String> explicit,
) {
  final entries = <String, MapEntry<String, String>>{};
  for (final entry in inherited.entries) {
    entries[entry.key.toLowerCase()] = entry;
  }
  for (final entry in explicit.entries) {
    entries[entry.key.toLowerCase()] = entry;
  }
  return sanitizeAddonHeaders(
    Map<String, String>.fromEntries(entries.values),
    maximumValueLength: 1024,
  );
}

/// Normalizes optional Seanime audio sidecars at the add-on boundary.
///
/// The JavaScript adapter emits at most eight explicit audio references. Each
/// URL still crosses the same public-HTTPS/DNS policy as the primary video.
/// Invalid sidecars are omitted independently so they can never hide an
/// otherwise playable primary stream. Primary credentials are inherited only
/// for the same origin; a track's own bounded headers remain scoped to the URL
/// the provider explicitly supplied and will be re-checked on proxy redirects.
Future<List<WebExternalAudioTrack>> normalizeSeanimeExternalAudioTracks(
  Object? raw, {
  required Uri primaryUri,
  required Map<String, String> primaryHeaders,
  required Future<bool> Function(Uri uri) isAllowed,
  WebProviderCancellation? cancellation,
}) async {
  final result = <WebExternalAudioTrack>[];
  for (final candidate in _parseSeanimeExternalAudioCandidates(raw)) {
    cancellation?.throwIfCancelled();
    var allowed = false;
    try {
      allowed = await isAllowed(candidate.uri);
    } on WebProviderSearchCancelled {
      rethrow;
    } catch (_) {
      // Optional audio must fail independently from the primary video.
      continue;
    }
    cancellation?.throwIfCancelled();
    if (!allowed) continue;
    final inheritedHeaders = sanitizeAddonHeaders(
      primaryHeaders,
      stripCredentials: !_sameOrigin(primaryUri, candidate.uri),
      maximumValueLength: 1024,
    );
    result.add(
      WebExternalAudioTrack(
        uri: candidate.uri,
        label: candidate.label,
        language: candidate.language,
        headers: _mergeSeanimeExternalAudioHeaders(
          inheritedHeaders,
          candidate.headers,
        ),
      ),
    );
  }
  return List.unmodifiable(result);
}

String _rawSeanimeExternalAudioFingerprint(Object? raw) => jsonEncode([
  for (final candidate in _parseSeanimeExternalAudioCandidates(raw))
    {
      'url': candidate.uri.toString(),
      'language': candidate.language ?? '',
      'headers': _rawWebStreamHeaderFingerprint(candidate.headers),
    },
]);

bool isSeanimeProviderNoMatch(Object error) {
  final explicitlyNoMatch = error.toString().contains('NO_MATCH:');
  final details = seanimeProviderFailureDetails(error);
  // Current TetoTV runtimes attach the last bounded stage/reason marker. A
  // genuine empty search is a normal no-match; a marker such as network,
  // http_5xx, or runtime_api means the provider never completed the search
  // and must remain a runtime failure. Marker-free legacy providers retain
  // their historical no-match behavior.
  if (details == null) return explicitlyNoMatch;
  final neutralAvailability =
      details.reason == 'empty_result' || details.reason == 'empty_sources';
  final neutralStage = const {
    'search',
    'title_matching',
    'episode_lookup',
    'episodes',
    'server_lookup',
  }.contains(details.stage);
  return neutralAvailability && neutralStage;
}

/// Ordered title queries for older Seanime providers that inspect only
/// `SearchOptions.query` instead of the richer `SearchOptions.media` object.
List<String> seanimeProviderSearchTitles(EpisodeReference episode) {
  // Most English-language streaming sites index either the licensed English
  // title or the Romaji title, even when the user chose a native display
  // title. Try those canonical aliases first, then the display title and the
  // remaining catalog synonyms. Each alias also gets one conservative ASCII
  // punctuation variant so punctuation-bearing titles do not collapse to an
  // incomplete word inside older provider search code.
  final values = <String?>[
    episode.titleEnglish,
    episode.titleRomaji,
    episode.titleNative,
    episode.title,
    ...episode.alternativeTitles,
  ];
  // A plain title can occasionally identify a different work even though its
  // punctuation-bearing Romaji alias is exact. When two canonical aliases
  // collapse to the same conservative ASCII query, try the more specific
  // punctuation-bearing alias first. Unrelated English/Romaji titles retain
  // their original English-first order.
  final canonical = <({String title, int index})>[];
  for (final (index, value) in values.indexed) {
    final title = value?.trim();
    if (title == null || title.isEmpty) continue;
    canonical.add((title: title, index: index));
  }
  final groupFirstIndex = <String, int>{};
  for (final entry in canonical) {
    final key = _providerAliasGroupKey(entry.title);
    groupFirstIndex.putIfAbsent(key, () => entry.index);
  }
  canonical.sort((left, right) {
    final leftAscii = _providerAliasGroupKey(left.title);
    final rightAscii = _providerAliasGroupKey(right.title);
    final groupOrder = groupFirstIndex[leftAscii]!.compareTo(
      groupFirstIndex[rightAscii]!,
    );
    if (groupOrder != 0) return groupOrder;
    if (leftAscii == rightAscii) {
      final leftSpecific = left.title.toLowerCase() != leftAscii;
      final rightSpecific = right.title.toLowerCase() != rightAscii;
      if (leftSpecific != rightSpecific) return leftSpecific ? -1 : 1;
    }
    return left.index.compareTo(right.index);
  });
  final seen = <String>{};
  final result = <String>[];
  for (final entry in canonical) {
    final title = entry.title;
    for (final candidate in [title, _providerAsciiTitleVariant(title)]) {
      if (candidate.isEmpty || !seen.add(candidate.toLowerCase())) continue;
      result.add(candidate);
      if (result.length == 8) return result;
    }
  }
  return result;
}

String _providerAliasGroupKey(String value) {
  final ascii = _providerAsciiTitleVariant(value).toLowerCase();
  return ascii.isEmpty ? value.trim().toLowerCase() : ascii;
}

String _providerAsciiTitleVariant(String value) {
  final withoutDecorativeSymbols = value
      .replaceAll(RegExp(r'[\u2600-\u27ff\u2b00-\u2bff]'), ' ')
      .replaceAll(RegExp(r"[\u2018\u2019\u201a\u201b\u2032\u2035]"), "'")
      .replaceAll(RegExp(r'[\u2010-\u2015\u2212]'), '-')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return withoutDecorativeSymbols;
}

/// Full bounded alias set for Seanime's `Media.synonyms`. This is separate
/// from the eight actual search attempts because providers may inspect a
/// later or service-specific alias themselves.
List<String> seanimeProviderMediaSynonyms(EpisodeReference episode) {
  final values = <String?>[
    episode.titleEnglish,
    episode.titleRomaji,
    episode.titleNative,
    ...episode.alternativeTitles,
  ];
  final primary = episode.title.trim().toLowerCase();
  final seen = <String>{primary};
  final result = <String>[];
  for (final value in values) {
    final title = value?.trim();
    if (title == null || title.isEmpty || !seen.add(title.toLowerCase())) {
      continue;
    }
    result.add(title);
    if (result.length == 32) break;
  }
  return result;
}

bool isSeanimeProviderNoStream(Object error) =>
    error.toString().contains('NO_STREAM:');

class SeanimeProviderFailureDetails {
  const SeanimeProviderFailureDetails({
    required this.stage,
    required this.reason,
  });

  final String stage;
  final String reason;
}

const _providerFailureStages = {
  'search',
  'title_matching',
  'episode_lookup',
  'server_lookup',
  'stream_extraction',
  // Accepted only for diagnostic compatibility with pre-2.0.18 providers.
  'episodes',
  'server',
  'runtime',
};
const _providerFailureReasons = {
  'timeout',
  'request_limit',
  'response_limit',
  'redirect_limit',
  'invalid_payload',
  'empty_sources',
  'unsafe_target',
  'invalid_response',
  'network',
  'runtime_api',
  'provider_error',
  'empty_result',
};

// Keep these patterns deliberately narrow. A third-party payload frequently
// throws TypeErrors containing "undefined" or "is not a function" when its
// upstream HTML/JSON shape changes; those are provider failures, not evidence
// that TetoTV's compatibility runtime is missing an API. These two patterns
// are also injected into the JavaScript runner below so the pure Dart tests
// exercise the same classification contract on platforms without QuickJS.
const _missingRuntimeReferencePattern =
    r'(?:referenceerror\s*:\s*)?(?:fetch|Request|Response|Headers|URL|URLSearchParams|TextEncoder|TextDecoder|DOMParser|document|Doc|LoadDoc|Buffer|CryptoJS|crypto(?:\.subtle)?|atob|btoa|setTimeout|clearTimeout|\$sleep|\$getUserPreference|\$)\s+is not defined\b';
const _missingRuntimeApiPattern =
    r'(?:\b(?:fetch|Request|Response|Headers|URL|URLSearchParams|TextEncoder|TextDecoder|DOMParser|document|Doc|LoadDoc|Buffer|CryptoJS|crypto(?:\.subtle)?|atob|btoa|setTimeout|clearTimeout)|\$(?:sleep|getUserPreference)?)(?:.{0,80})\b(?:is not a function|is undefined|is not defined)\b';

/// Classifies a provider-thrown message without retaining or exposing it.
///
/// Public for platform-independent contract tests. Callers must persist only
/// the returned bounded reason code, never [errorText].
String classifySeanimeProviderFailureReason(String errorText) {
  final message = errorText.toLowerCase();
  if (RegExp(r'timeout|timed out|deadline|aborted').hasMatch(message)) {
    return 'timeout';
  }
  if (RegExp(r'network request limit|request budget').hasMatch(message)) {
    return 'request_limit';
  }
  if (RegExp(
    r'total response limit|response budget|response is too large',
  ).hasMatch(message)) {
    return 'response_limit';
  }
  if (RegExp(r'redirect limit|too many redirects').hasMatch(message)) {
    return 'redirect_limit';
  }
  if (RegExp(
    r'invalid provider request|configured addon payload|invalid payload',
  ).hasMatch(message)) {
    return 'invalid_payload';
  }
  final http = RegExp(
    r'(?:http|status|returned|failed)\D{0,12}([1-5][0-9]{2})',
  ).firstMatch(message);
  if (http != null) return 'http_${http.group(1)}';
  if (RegExp(
    r'\b(?:no anime|no titles?|no results?|no matches?|no episodes?)\s+(?:was\s+|were\s+)?found\b',
  ).hasMatch(message)) {
    return 'empty_result';
  }
  if (RegExp(
    r'\b(?:selected\s+|requested\s+)?server\s+(?:was\s+)?not found\b|\bno providers found for server\b',
  ).hasMatch(message)) {
    return 'empty_sources';
  }
  if (RegExp(
    r'no source|no stream|video source|empty source|unable to find a valid source',
  ).hasMatch(message)) {
    return 'empty_sources';
  }
  if (RegExp(
    r'public https|safety|unsafe|private address|not permitted',
  ).hasMatch(message)) {
    return 'unsafe_target';
  }
  if (RegExp(
    r'json|parse|unexpected token|invalid response',
  ).hasMatch(message)) {
    return 'invalid_response';
  }
  if (RegExp(
    r'network|socket|dns|connection|fetch failed|host lookup',
  ).hasMatch(message)) {
    return 'network';
  }
  if (RegExp(
        _missingRuntimeReferencePattern,
        caseSensitive: false,
      ).hasMatch(errorText) ||
      RegExp(
        _missingRuntimeApiPattern,
        caseSensitive: false,
      ).hasMatch(errorText)) {
    return 'runtime_api';
  }
  return 'provider_error';
}

/// Reads only the bounded, runtime-generated failure marker. Provider error
/// text is deliberately excluded so URLs, search terms, cookies, and tokens
/// cannot be copied into diagnostics through a thrown third-party error.
SeanimeProviderFailureDetails? seanimeProviderFailureDetails(Object error) {
  final match = RegExp(
    r'\[stage=([a-z_]+);\s*reason=([a-z0-9_]+)\]',
  ).firstMatch(error.toString());
  if (match == null) return null;
  final stage = match.group(1)!;
  final reason = match.group(2)!;
  if (!_providerFailureStages.contains(stage)) return null;
  if (!_providerFailureReasons.contains(reason) &&
      !RegExp(r'^http_[1-5][0-9]{2}$').hasMatch(reason)) {
    return null;
  }
  return SeanimeProviderFailureDetails(stage: stage, reason: reason);
}

String _providerReasonCopy(String reason) => switch (reason) {
  'timeout' => 'the provider timed out',
  'request_limit' => 'the provider exceeded its bounded request budget',
  'response_limit' => 'the provider exceeded its bounded response budget',
  'redirect_limit' => 'the upstream exceeded the safe redirect limit',
  'invalid_payload' => 'the provider returned an invalid payload',
  'empty_sources' || 'empty_result' => 'the upstream returned no sources',
  'unsafe_target' => 'the returned address failed network safety checks',
  'invalid_response' => 'the upstream response format changed',
  'network' => 'the provider could not reach its upstream service',
  'runtime_api' => 'the provider uses an unsupported runtime API',
  final String value when value.startsWith('http_') =>
    'the upstream returned HTTP ${value.substring(5)}',
  _ => 'the provider reported an error',
};

/// Converts provider/runtime failures into bounded user-facing copy without
/// leaking Dart's implementation prefix (`Bad state:`) into the stream UI.
String seanimeProviderFailureMessage(Object error) {
  var value = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  final details = seanimeProviderFailureDetails(error);
  value = value.replaceAll(
    RegExp(r'\s*\[stage=[a-z_]+;\s*reason=[a-z0-9_]+\]\s*'),
    '',
  );
  final implementationPrefix = RegExp(
    r'^(?:Bad state|StateError|Exception):\s*',
    caseSensitive: false,
  );
  while (implementationPrefix.hasMatch(value)) {
    value = value.replaceFirst(implementationPrefix, '').trimLeft();
  }
  if (value.startsWith('NO_STREAM:')) {
    final reason = details == null
        ? 'It may need an update or a different server.'
        : 'Reason: ${_providerReasonCopy(details.reason)}.';
    value = switch (details?.stage) {
      'search' => 'This provider could not complete its title search. $reason',
      'title_matching' =>
        'This provider searched successfully but could not match the title. '
            '$reason',
      'episode_lookup' || 'episodes' =>
        'This provider matched the title but could not load its episodes. '
            '$reason',
      'server_lookup' || 'server' =>
        'This provider found the episode but could not resolve a server. '
            '$reason',
      'stream_extraction' =>
        'This provider resolved a server but could not extract a playable '
            'stream. $reason',
      _ =>
        'This provider found the episode but could not return a '
            'compatible stream. $reason',
    };
  } else if (value.startsWith('NO_MATCH:')) {
    value = details != null && details.reason != 'empty_result'
        ? 'This provider could not complete its ${details.stage} request. '
              'Reason: ${_providerReasonCopy(details.reason)}.'
        : value.toLowerCase().contains('episode')
        ? 'This provider matched the title but has no matching episode.'
        : 'This provider has no matching title.';
  }
  return value.length > 180 ? '${value.substring(0, 180)}…' : value;
}

/// Stable, redacted provider provenance for diagnostic events and health
/// records. Only manifest-derived IDs/versions/hosts and runtime-generated
/// enums are included; full URLs and provider exception text are omitted.
String seanimeProviderDiagnosticMessage(
  SeanimeJavascriptProvider provider,
  Object error,
) {
  final details = seanimeProviderFailureDetails(error);
  String field(Object? value, {int maximum = 80}) {
    final safe = '${value ?? 'unknown'}'
        .replaceAll(RegExp(r'[^A-Za-z0-9._:-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return safe.length <= maximum ? safe : safe.substring(0, maximum);
  }

  return [
    'provider=${field(provider.id)}',
    'version=${field(provider.version)}',
    'repositoryHost=${field(provider.repositoryHost)}',
    'executableHost=${field(provider.executableHost)}',
    'stage=${field(details?.stage ?? 'runtime')}',
    'reason=${field(details?.reason ?? (error is TimeoutException ? 'timeout' : 'provider_error'))}',
  ].join(' ');
}

class HlsStreamVariant {
  const HlsStreamVariant({
    required this.uri,
    required this.quality,
    this.bandwidth,
  });

  final Uri uri;
  final String quality;
  final int? bandwidth;
}

class HlsMasterPlaylistInspection {
  const HlsMasterPlaylistInspection({
    required this.variants,
    required this.audioCapability,
    required this.hasAlternateAudio,
    this.audioLanguages = const [],
  });

  final List<HlsStreamVariant> variants;
  final WebStreamAudioCapability audioCapability;

  /// True when the master owns audio renditions that would be lost by handing
  /// MPV one child video playlist instead of the original master playlist.
  final bool hasAlternateAudio;
  final List<String> audioLanguages;
}

HlsMasterPlaylistInspection inspectHlsMasterPlaylist(
  String source,
  Uri masterUri,
) {
  final variants = parseHlsMasterPlaylist(source, masterUri);
  final referencedAudioGroups = <String>{};
  final audioRenditions = <Map<String, String>>[];
  for (final rawLine in const LineSplitter().convert(source)) {
    final line = rawLine.trim();
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      final group = _hlsAttributes(
        line.substring('#EXT-X-STREAM-INF:'.length),
      )['AUDIO']?.trim();
      if (group != null && group.isNotEmpty) referencedAudioGroups.add(group);
      continue;
    }
    if (!line.startsWith('#EXT-X-MEDIA:')) continue;
    final attributes = _hlsAttributes(line.substring('#EXT-X-MEDIA:'.length));
    if (attributes['TYPE']?.toUpperCase() == 'AUDIO') {
      audioRenditions.add(attributes);
    }
  }

  final languages = <String>{};
  for (final rendition in audioRenditions) {
    final group = rendition['GROUP-ID']?.trim();
    if (referencedAudioGroups.isNotEmpty &&
        (group == null || !referencedAudioGroups.contains(group))) {
      continue;
    }
    final language = _normalizedHlsAudioLanguage(
      rendition['LANGUAGE'] ?? rendition['NAME'],
    );
    if (language != null) languages.add(language);
  }
  final hasEnglish = languages.contains('eng');
  final hasJapanese = languages.contains('jpn');
  final audioCapability = hasEnglish && hasJapanese
      ? WebStreamAudioCapability.subAndDub
      : hasEnglish
      ? WebStreamAudioCapability.dub
      : hasJapanese
      ? WebStreamAudioCapability.sub
      : WebStreamAudioCapability.unknown;
  return HlsMasterPlaylistInspection(
    variants: variants,
    audioCapability: audioCapability,
    hasAlternateAudio: audioRenditions.isNotEmpty,
    audioLanguages: List.unmodifiable(languages),
  );
}

String? _normalizedHlsAudioLanguage(String? value) {
  final normalized = value
      ?.trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z]+'), ' ')
      .trim();
  if (normalized == null || normalized.isEmpty) return null;
  final canonical = canonicalCaptionLanguageCode(normalized);
  return preferredCaptionLanguageOptions.any(
        (option) => option.code == canonical,
      )
      ? canonical
      : null;
}

List<HlsStreamVariant> parseHlsMasterPlaylist(String source, Uri masterUri) {
  if (!source.contains('#EXT-X-STREAM-INF')) return const [];
  final lines = const LineSplitter().convert(source);
  final variants = <String, HlsStreamVariant>{};
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    final attributes = _hlsAttributes(
      line.substring('#EXT-X-STREAM-INF:'.length),
    );
    String? location;
    while (++index < lines.length) {
      final candidate = lines[index].trim();
      if (candidate.isEmpty) continue;
      if (candidate.startsWith('#')) break;
      location = candidate;
      break;
    }
    if (location == null) continue;
    final uri = safePublicHttpsUri(masterUri.resolve(location).toString());
    if (uri == null) continue;
    final resolution = attributes['RESOLUTION'];
    final height = resolution == null
        ? null
        : int.tryParse(resolution.split('x').last);
    final bandwidth = int.tryParse(
      attributes['AVERAGE-BANDWIDTH'] ?? attributes['BANDWIDTH'] ?? '',
    );
    final name = attributes['NAME']?.trim();
    final quality = height != null && height > 0
        ? '${height}p'
        : name?.isNotEmpty == true
        ? name!
        : bandwidth != null
        ? '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps'
        : 'Variant';
    variants.putIfAbsent(
      uri.toString(),
      () => HlsStreamVariant(uri: uri, quality: quality, bandwidth: bandwidth),
    );
    if (variants.length >= 20) break;
  }
  final result = variants.values.toList();
  result.sort((left, right) {
    final leftHeight = int.tryParse(
      RegExp(r'\d+').firstMatch(left.quality)?.group(0) ?? '',
    );
    final rightHeight = int.tryParse(
      RegExp(r'\d+').firstMatch(right.quality)?.group(0) ?? '',
    );
    final resolution = (rightHeight ?? 0).compareTo(leftHeight ?? 0);
    if (resolution != 0) return resolution;
    return (right.bandwidth ?? 0).compareTo(left.bandwidth ?? 0);
  });
  return result;
}

List<Map<String, dynamic>> expandHlsResultVariants(
  Map<String, dynamic> item,
  String playlist,
  Uri masterUri,
) {
  final title = '${item['title'] ?? 'Auto'}';
  final inspection = inspectHlsMasterPlaylist(playlist, masterUri);
  final detected = inspection.audioCapability;
  final annotatedMaster = <String, dynamic>{
    ...item,
    if (inspection.audioLanguages.isNotEmpty)
      'audioLanguages': inspection.audioLanguages,
    if (detected != WebStreamAudioCapability.unknown)
      'audioCapability': switch (detected) {
        WebStreamAudioCapability.subAndDub => 'sub_and_dub',
        WebStreamAudioCapability.dub => 'dub',
        WebStreamAudioCapability.sub => 'sub',
        WebStreamAudioCapability.unknown => 'unknown',
      },
  };
  return [
    if (inspection.hasAlternateAudio ||
        detected != WebStreamAudioCapability.unknown)
      annotatedMaster,
    // An alternate-audio HLS master must stay intact. A child video variant
    // does not carry the master's audio rendition list and can otherwise turn
    // a dual-audio stream into silent or apparently Sub-only playback.
    if (!inspection.hasAlternateAudio)
      for (final variant in inspection.variants)
        {
          ...item,
          'url': variant.uri.toString(),
          'quality': variant.quality,
          'title': _variantTitle(title, variant.quality),
          // A master playlist may point directly at a different origin without
          // an HTTP redirect. Apply the same allowlist used for cross-origin
          // redirects so addon credentials and custom secrets never reach that
          // variant host.
          'headers': _sameOrigin(masterUri, variant.uri)
              ? item['headers']
              : sanitizeAddonHeaders(item['headers'], stripCredentials: true),
        },
  ];
}

Map<String, String> _hlsAttributes(String value) {
  final result = <String, String>{};
  final expression = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  for (final match in expression.allMatches(value)) {
    var attribute = match.group(2)?.trim() ?? '';
    if (attribute.length >= 2 &&
        attribute.startsWith('"') &&
        attribute.endsWith('"')) {
      attribute = attribute.substring(1, attribute.length - 1);
    }
    result[match.group(1)!] = attribute;
  }
  return result;
}

typedef HlsInspectionLoader =
    Future<List<Map<String, dynamic>>> Function(
      Map<String, dynamic> item,
      WebProviderCancellation? cancellation,
    );

/// Adds optional HLS quality/audio metadata without holding playable provider
/// results hostage to another network round trip.
///
/// The provider runtime is deliberately shorter than the worker-pool deadline,
/// and this enrichment receives only the small remaining reserve. Timeout or
/// inspection failures return the original streams. A real parent
/// cancellation still propagates so leaving the resolver stops all work.
Future<List<Map<String, dynamic>>> expandHlsVariantsWithinBudget(
  List<Map<String, dynamic>> raw,
  WebProviderCancellation? cancellation, {
  Duration budget = seanimeHlsEnrichmentBudget,
  HlsInspectionLoader? inspectItem,
}) async {
  final original = mergeDuplicateWebStreamItems(
    raw,
  ).take(120).toList(growable: false);
  // A provider may label its HLS master as a concrete resolution even though
  // the manifest still owns switchable English/Japanese audio renditions.
  // Inspect every bounded HLS candidate rather than only Auto/Adaptive labels;
  // otherwise those masters retain the provider's generic Sub label.
  // Enrichment is optional: the original streams remain usable even when a
  // master cannot be inspected. Deduplicate mirrors before doing I/O and run
  // the small bounded set together. The previous three sequential batches
  // could consume nearly the provider's entire worker deadline after the
  // provider had already returned valid streams.
  final hlsCandidates = selectHlsInspectionCandidates(raw);
  cancellation?.throwIfCancelled();
  if (hlsCandidates.isEmpty || budget <= Duration.zero) return original;

  final enrichmentCancellation = WebProviderCancellation();
  final removeParentListener =
      cancellation?.addListener(enrichmentCancellation.cancel) ?? () {};
  final loader = inspectItem ?? _hlsVariantsForItem;
  try {
    final groups = await Future.wait(
      hlsCandidates.map((item) => loader(item, enrichmentCancellation)),
    ).timeout(budget);
    cancellation?.throwIfCancelled();
    final result = original.toList(growable: true);
    for (var index = 0; index < groups.length; index++) {
      final variants = groups[index];
      final candidate = hlsCandidates[index];
      final replacesCandidate = variants.any(
        (item) => '${item['url'] ?? ''}' == '${candidate['url'] ?? ''}',
      );
      if (replacesCandidate) {
        final candidateKey = _rawWebStreamPlaybackIdentity(candidate);
        result.removeWhere(
          (item) => _rawWebStreamPlaybackIdentity(item) == candidateKey,
        );
      }
      result.addAll(variants);
    }
    return mergeDuplicateWebStreamItems(
      result,
    ).take(120).toList(growable: false);
  } on TimeoutException {
    enrichmentCancellation.cancel();
    cancellation?.throwIfCancelled();
    return original;
  } on WebProviderSearchCancelled {
    if (cancellation?.isCancelled == true) rethrow;
    return original;
  } catch (_) {
    if (cancellation?.isCancelled == true) {
      throw const WebProviderSearchCancelled();
    }
    return original;
  } finally {
    removeParentListener();
  }
}

int _rawAudioCapabilityScore(Object? value) =>
    switch (webStreamAudioCapabilityFromWire(value)) {
      WebStreamAudioCapability.subAndDub => 3,
      WebStreamAudioCapability.dub || WebStreamAudioCapability.sub => 2,
      WebStreamAudioCapability.unknown => 0,
    };

String? _webStreamAudioCapabilityWireValue(
  WebStreamAudioCapability capability,
) => switch (capability) {
  WebStreamAudioCapability.subAndDub => 'sub_and_dub',
  WebStreamAudioCapability.dub => 'dub',
  WebStreamAudioCapability.sub => 'sub',
  WebStreamAudioCapability.unknown => null,
};

/// Deduplicates only playback-equivalent provider results.
///
/// A shared URL is not proof of dual audio: providers can use mode-specific
/// headers, cookies, subtitles, or opaque session state. Exclusive Sub and Dub
/// results therefore stay separate unless the provider independently labels a
/// result as dual audio.
List<Map<String, dynamic>> mergeDuplicateWebStreamItems(
  Iterable<Map<String, dynamic>> items,
) {
  final unique = <String, Map<String, dynamic>>{};
  for (final item in items) {
    final capability = webStreamAudioCapabilityFromWire(item);
    final key = _rawWebStreamPlaybackIdentity(item);
    final existing = unique[key];
    if (existing == null) {
      unique[key] = item;
      continue;
    }

    final winner =
        _rawAudioCapabilityScore(item) > _rawAudioCapabilityScore(existing)
        ? item
        : existing;
    final languages = <String>{
      ...webStreamAudioLanguagesFromWire(existing),
      ...webStreamAudioLanguagesFromWire(item),
    }.take(24).toList(growable: false);
    final wireValue = _webStreamAudioCapabilityWireValue(capability);
    unique[key] = <String, dynamic>{
      ...winner,
      'audioCapability': ?wireValue,
      if (languages.isNotEmpty) 'audioLanguages': languages,
    };
  }
  return unique.values.toList(growable: false);
}

String _rawWebStreamPlaybackIdentity(Map<String, dynamic> item) => [
  '${item['url'] ?? ''}',
  '${item['quality'] ?? ''}',
  webStreamAudioCapabilityFromWire(item).name,
  _rawWebStreamHeaderFingerprint(item['headers']),
  '${item['subtitleUrl'] ?? ''}',
  '${item['subtitleLanguage'] ?? ''}',
  _rawSeanimeExternalAudioFingerprint(item['externalAudioTracks']),
].join('|');

String _rawWebStreamHeaderFingerprint(Object? raw) {
  final headers = sanitizeAddonHeaders(raw);
  final entries = headers.entries.toList(growable: false)
    ..sort(
      (left, right) =>
          left.key.toLowerCase().compareTo(right.key.toLowerCase()),
    );
  return entries
      .map((entry) => '${entry.key.toLowerCase()}:${entry.value}')
      .join('\n');
}

bool isHlsInspectionCandidate(Map<String, dynamic> item) {
  final url = '${item['url'] ?? ''}'.toLowerCase();
  final declaredType = [
    item['streamType'],
    item['type'],
  ].whereType<Object>().join(' ').trim().toLowerCase();
  final normalizedType = declaredType.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  return url.contains('.m3u8') ||
      RegExp(r'(^|\s)(hls|m3u8)(\s|$)').hasMatch(normalizedType) ||
      normalizedType.contains('mpegurl');
}

/// Selects a small, unique set of safe HLS request variants for optional
/// metadata inspection. Providers commonly repeat one master under several
/// labels; independently authorized header variants must remain distinct.
List<Map<String, dynamic>> selectHlsInspectionCandidates(
  Iterable<Map<String, dynamic>> items, {
  int maximum = 4,
}) {
  if (maximum <= 0) return const [];
  final selected = <String, Map<String, dynamic>>{};
  for (final item in items) {
    if (!isHlsInspectionCandidate(item)) continue;
    final uri = safePublicHttpsUri(item['url']);
    if (uri == null) continue;
    final key = webPlaybackVariantKey(
      providerIdentity: 'hls-inspection',
      uri: uri,
      audioCapability: WebStreamAudioCapability.unknown,
      headers: sanitizeAddonHeaders(item['headers']),
    );
    final sidecarAwareKey =
        '$key|${_rawSeanimeExternalAudioFingerprint(item['externalAudioTracks'])}';
    selected.putIfAbsent(sidecarAwareKey, () => item);
    if (selected.length >= maximum) break;
  }
  return selected.values.toList(growable: false);
}

bool _isTransientHlsInspectionStatus(int status) =>
    status >= 500 && status <= 599;

bool _isTransientHlsInspectionFailure(Object error) {
  if (error is TimeoutException || error is SocketException) return true;
  if (error is! DioException) return false;
  final status = error.response?.statusCode;
  if (status != null && _isTransientHlsInspectionStatus(status)) return true;
  if (error.error is TimeoutException || error.error is SocketException) {
    return true;
  }
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError ||
    // `_safeAddonRequest` uses cancellation for its bounded overall deadline.
    // A real provider-search cancellation is rethrown before this is consulted.
    DioExceptionType.cancel => true,
    _ => false,
  };
}

/// Runs one HLS metadata request and, at most once, retries a transient
/// network/timeout/5xx outcome. The provider cancellation signal always wins
/// over the retry so leaving the resolver cannot start another request.
Future<T> runHlsInspectionWithTransientRetry<T>(
  Future<T> Function(int attempt) operation, {
  required bool Function(T result) shouldRetryResult,
  WebProviderCancellation? cancellation,
  Duration retryDelay = const Duration(milliseconds: 120),
}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    cancellation?.throwIfCancelled();
    try {
      final result = await operation(attempt);
      cancellation?.throwIfCancelled();
      if (attempt == 0 && shouldRetryResult(result)) {
        await _waitForHlsInspectionRetry(retryDelay, cancellation);
        continue;
      }
      return result;
    } catch (error, stackTrace) {
      cancellation?.throwIfCancelled();
      if (attempt == 0 && _isTransientHlsInspectionFailure(error)) {
        await _waitForHlsInspectionRetry(retryDelay, cancellation);
        continue;
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
  throw StateError('Unreachable HLS inspection retry state.');
}

Future<void> _waitForHlsInspectionRetry(
  Duration delay,
  WebProviderCancellation? cancellation,
) async {
  if (delay <= Duration.zero) {
    cancellation?.throwIfCancelled();
    return;
  }
  if (cancellation == null) {
    await Future<void>.delayed(delay);
    return;
  }
  await Future.any<void>([
    Future<void>.delayed(delay),
    cancellation.whenCancelled,
  ]);
  cancellation.throwIfCancelled();
}

Future<List<Map<String, dynamic>>> _hlsVariantsForItem(
  Map<String, dynamic> item,
  WebProviderCancellation? cancellation,
) async {
  cancellation?.throwIfCancelled();
  final uri = safePublicHttpsUri(item['url']);
  if (uri == null) return const [];
  try {
    final response = await runHlsInspectionWithTransientRetry(
      (attempt) => _safeAddonRequest(
        {
          'url': uri.toString(),
          'options': {
            'method': 'GET',
            'headers': item['headers'] is Map ? item['headers'] : const {},
          },
        },
        connectTimeout: Duration(seconds: attempt == 0 ? 3 : 2),
        receiveTimeout: Duration(seconds: attempt == 0 ? 3 : 2),
        overallTimeout: Duration(seconds: attempt == 0 ? 4 : 3),
        maximumResponseBytes: 512 * 1024,
        cancellation: cancellation,
      ),
      shouldRetryResult: (response) =>
          _isTransientHlsInspectionStatus(response['status'] as int? ?? 0),
      cancellation: cancellation,
    );
    final status = response['status'] as int? ?? 0;
    if (status < 200 || status >= 300) return const [];
    final effectiveHeaders = response['requestHeaders'];
    return expandHlsResultVariants(
      {...item, if (effectiveHeaders is Map) 'headers': effectiveHeaders},
      '${response['body'] ?? ''}',
      Uri.parse('${response['url'] ?? uri}'),
    );
  } on WebProviderSearchCancelled {
    rethrow;
  } catch (_) {
    cancellation?.throwIfCancelled();
    // A media playlist, unavailable master, or failed variant lookup leaves
    // the original Auto stream intact and selectable.
    return const [];
  }
}

String _variantTitle(String original, String quality) {
  final auto = RegExp(r'\b(auto|adaptive|unknown)\b', caseSensitive: false);
  return auto.hasMatch(original)
      ? original.replaceFirst(auto, quality)
      : '$original / $quality';
}

Future<List<Map<String, dynamic>>> _runProviderIsolate(
  Map<String, Object?> input, {
  required Duration timeout,
  WebProviderCancellation? cancellation,
}) async {
  cancellation?.throwIfCancelled();
  final responses = ReceivePort();
  final errors = ReceivePort();
  final completed = Completer<List<Map<String, dynamic>>>();
  final isolateStopped = Completer<void>();
  Isolate? isolate;
  SendPort? controlPort;
  var cancellationRequested = false;
  StreamSubscription<dynamic>? responseSubscription;
  StreamSubscription<dynamic>? errorSubscription;
  Timer? deadline;
  void Function()? removeCancellationListener;
  try {
    removeCancellationListener = cancellation?.addListener(() {
      cancellationRequested = true;
      controlPort?.send('cancel');
      if (!completed.isCompleted) {
        completed.completeError(const WebProviderSearchCancelled());
      }
    });
    isolate = await Isolate.spawn<List<Object?>>(
      _providerIsolateEntry,
      [responses.sendPort, input],
      onError: errors.sendPort,
      onExit: responses.sendPort,
      errorsAreFatal: true,
      paused: true,
      debugName: 'TetoTV provider ${input['id']}',
    );
    responseSubscription = responses.listen((dynamic message) {
      if (message == null) {
        if (!isolateStopped.isCompleted) isolateStopped.complete();
        if (!completed.isCompleted) {
          completed.completeError(
            StateError('Provider worker exited before returning a result.'),
          );
        }
        return;
      }
      if (message is! Map) return;
      final workerControl = message['control'];
      if (workerControl is SendPort) {
        controlPort = workerControl;
        if (cancellationRequested) controlPort!.send('cancel');
        return;
      }
      if (completed.isCompleted) return;
      if (message['cancelled'] == true) {
        completed.completeError(const WebProviderSearchCancelled());
        return;
      }
      if (message['ok'] != true) {
        completed.completeError(
          StateError('${message['error'] ?? 'Provider failed'}'),
        );
        return;
      }
      final raw = message['result'];
      final result = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            result.add(item.map((key, value) => MapEntry('$key', value)));
          }
        }
      }
      completed.complete(result);
    });
    errorSubscription = errors.listen((dynamic message) {
      if (completed.isCompleted) return;
      final error = message is List && message.isNotEmpty
          ? message.first
          : message;
      completed.completeError(StateError('$error'));
    });
    deadline = Timer(timeout, () {
      if (!completed.isCompleted) {
        cancellationRequested = true;
        controlPort?.send('cancel');
        completed.completeError(
          TimeoutException(
            'Provider exceeded its ${timeout.inSeconds}-second runtime limit.',
            timeout,
          ),
        );
      }
    });
    final pauseCapability = isolate.pauseCapability;
    if (pauseCapability != null) isolate.resume(pauseCapability);
    return await completed.future;
  } finally {
    removeCancellationListener?.call();
    deadline?.cancel();
    // Let the worker unwind _executeProvider's finally block and free its
    // native QuickJS heap. A forced kill remains a bounded fallback for a
    // wedged native call, but is no longer the normal cancellation path.
    if (!isolateStopped.isCompleted) {
      cancellationRequested = true;
      controlPort?.send('cancel');
      try {
        // The native bytecode deadline is six seconds. Waiting beyond it lets
        // even a worker currently stuck in synchronous JavaScript unwind and
        // dispose its 48 MiB-bounded heap before forced termination.
        await isolateStopped.future.timeout(const Duration(milliseconds: 7500));
      } on TimeoutException {
        isolate?.kill(priority: Isolate.immediate);
        try {
          await isolateStopped.future.timeout(
            const Duration(milliseconds: 250),
          );
        } on TimeoutException {
          // The isolate is already kill-requested; closing local ports below
          // prevents this search from retaining any Dart-side resources.
        }
      }
    }
    await responseSubscription?.cancel();
    await errorSubscription?.cancel();
    responses.close();
    errors.close();
  }
}

void _providerIsolateEntry(List<Object?> message) {
  final port = message[0] as SendPort;
  final rawInput = message[1] as Map;
  final input = rawInput.map<String, Object?>(
    (key, value) => MapEntry('$key', value),
  );
  final cancellation = WebProviderCancellation();
  final controls = ReceivePort();
  final controlSubscription = controls.listen((dynamic command) {
    if (command == 'cancel') cancellation.cancel();
  });
  port.send({'control': controls.sendPort});
  unawaited(() async {
    try {
      final result = await _executeProvider(input, cancellation: cancellation);
      if (cancellation.isCancelled) {
        port.send({'cancelled': true});
      } else {
        port.send({'ok': true, 'result': result});
      }
    } on WebProviderSearchCancelled {
      port.send({'cancelled': true});
    } catch (error) {
      port.send({'ok': false, 'error': error.toString()});
    } finally {
      await controlSubscription.cancel();
      controls.close();
    }
  }());
}

Future<List<Map<String, dynamic>>> _executeProvider(
  Map<String, Object?> input, {
  required WebProviderCancellation cancellation,
}) async {
  final runtime = QuickJsRuntime2(
    timeout: 6000,
    memoryLimit: 48 * 1024 * 1024,
    stackSize: 512 * 1024,
  );
  var disposed = false;
  final runtimeStartedAt = DateTime.now();
  const runtimeNetworkWindow = Duration(milliseconds: 9500);
  final completed = Completer<List<Map<String, dynamic>>>();
  var latestProgress = const <Map<String, dynamic>>[];
  final networkBudget = AddonRuntimeNetworkBudget();
  final cookieJar = AddonRuntimeCookieJar();
  final sleepTimers = <String, Timer>{};
  final clearedSleepIds = <String>{};

  List<Map<String, dynamic>> projectedRuntimeResult(dynamic data) {
    final streams = <Map<String, dynamic>>[];
    final maximumItems = switch (input['operation']) {
      'manga-search' => 120,
      'manga-chapters' || 'manga-pages' => 1000,
      _ => 80,
    };
    if (data is List) {
      for (final item in data.take(maximumItems)) {
        if (item is Map) {
          streams.add(item.map((key, value) => MapEntry('$key', value)));
        }
      }
    }
    return streams;
  }

  runtime.onMessage('TetoNetwork', (dynamic request) {
    unawaited(() async {
      final id = request is Map ? '${request['id'] ?? ''}' : '';
      var acquired = false;
      try {
        await networkBudget.acquire();
        acquired = true;
        final remaining =
            runtimeNetworkWindow - DateTime.now().difference(runtimeStartedAt);
        if (remaining <= Duration.zero) {
          throw TimeoutException('Provider runtime deadline exceeded.');
        }
        const perRequestCeiling = Duration(seconds: 6);
        final requestBudget = remaining < perRequestCeiling
            ? remaining
            : perRequestCeiling;
        final response = await _safeAddonRequest(
          request,
          maximumOverallTimeout: requestBudget,
          cancellation: cancellation,
          cookieJar: cookieJar,
        );
        final bodyByteLength = response['bodyByteLength'];
        if (bodyByteLength is int) {
          networkBudget.recordResponseBytes(bodyByteLength);
        } else {
          // Compatibility fallback for an injected/older request adapter.
          networkBudget.recordResponse('${response['body'] ?? ''}');
        }
        if (!disposed) {
          runtime.evaluate(
            '__tetoNetworkFinish(${jsonEncode(id)}, ${jsonEncode(response)});',
          );
          await runtime.dispatch();
        }
      } catch (error) {
        if (!disposed) {
          runtime.evaluate(
            '__tetoNetworkFail(${jsonEncode(id)}, ${jsonEncode(_safeError(error))});',
          );
          await runtime.dispatch();
        }
      } finally {
        if (acquired) networkBudget.release();
      }
    }());
  });
  runtime.onMessage('TetoDone', (dynamic value) {
    if (completed.isCompleted) return;
    if (value is! Map || value['ok'] != true) {
      completed.completeError(
        StateError(
          value is Map
              ? '${value['error'] ?? 'Provider failed'}'
              : 'Provider failed',
        ),
      );
      return;
    }
    completed.complete(projectedRuntimeResult(value['result']));
  });
  runtime.onMessage('TetoProgress', (dynamic value) {
    if (completed.isCompleted || value is! Map || value['ok'] != true) return;
    final streams = projectedRuntimeResult(value['result']);
    if (streams.isNotEmpty) latestProgress = streams;
  });
  runtime.onMessage('TetoSleep', (dynamic request) {
    if (disposed || cancellation.isCancelled || request is! Map) return;
    final id = '${request['id'] ?? ''}';
    if (!_isValidAddonSleepId(id) || sleepTimers.containsKey(id)) return;
    if (clearedSleepIds.remove(id)) return;
    if (sleepTimers.length >= 64) {
      runtime.evaluate('__tetoSleepFinish(${jsonEncode(id)});');
      unawaited(runtime.dispatch());
      return;
    }
    final remaining =
        runtimeNetworkWindow - DateTime.now().difference(runtimeStartedAt);
    final duration = addonSleepDuration(
      request['milliseconds'],
      remaining: remaining,
    );
    void finish() {
      sleepTimers.remove(id);
      if (disposed || cancellation.isCancelled) return;
      runtime.evaluate('__tetoSleepFinish(${jsonEncode(id)});');
      unawaited(runtime.dispatch());
    }

    if (duration <= Duration.zero) {
      sleepTimers[id] = Timer(Duration.zero, finish);
    } else {
      sleepTimers[id] = Timer(duration, finish);
    }
  });
  runtime.onMessage('TetoClearSleep', (dynamic request) {
    if (disposed || request is! Map) return;
    final id = '${request['id'] ?? ''}';
    if (!_isValidAddonSleepId(id)) return;
    final timer = sleepTimers.remove(id);
    if (timer != null) {
      timer.cancel();
      return;
    }
    if (clearedSleepIds.length < 64) clearedSleepIds.add(id);
  });

  try {
    cancellation.throwIfCancelled();
    final bootstrap = runtime.evaluate(_networkBootstrap);
    if (bootstrap.isError) throw StateError(bootstrap.stringResult);
    cancellation.throwIfCancelled();
    final domRuntime = runtime.evaluate(
      input['domRuntime']! as String,
      sourceUrl: 'asset://linkedom.js',
    );
    if (domRuntime.isError) throw StateError(domRuntime.stringResult);
    cancellation.throwIfCancelled();
    final compatibility = runtime.evaluate(_seanimeCompatibilityBootstrap);
    if (compatibility.isError) throw StateError(compatibility.stringResult);
    cancellation.throwIfCancelled();
    final preferences = runtime.evaluate(
      'globalThis.__tetoUserPreferences = Object.freeze('
      '${jsonEncode(input['userConfig'] ?? const <String, String>{})});',
      sourceUrl: 'tetotv://provider-preferences.js',
    );
    if (preferences.isError) throw StateError(preferences.stringResult);
    cancellation.throwIfCancelled();
    final payload = input['payload']! as String;
    final provider = runtime.evaluate(
      payload,
      sourceUrl: 'addon://${input['id']}/provider.js',
    );
    if (provider.isError) throw StateError(provider.stringResult);
    cancellation.throwIfCancelled();
    final invocationSource = input['operation'] == null
        ? '''
      (async function() {
        try {
          const provider = new Provider();
          const providerCall = async callback => {
            try {
              return await callback();
            } finally {
              // `$sleep` is synchronous in Seanime's provider contract. Flush
              // unawaited compatibility sleeps even when the provider method
              // throws before the next fetch can observe the sleep barrier.
              await __tetoAwaitSleeps();
            }
          };
          let settings = typeof provider.getSettings === 'function'
            ? ((await providerCall(() => provider.getSettings())) || {}) : {};
          const titles = ${jsonEncode((input['titles'] as List?) ?? const [])}
            .filter(Boolean).filter((title, index, all) =>
              all.findIndex(other => String(other).toLowerCase() === String(title).toLowerCase()) === index
            ).slice(0, 8);
          const episodeNumber = ${input['episode']};
          const requestedSeason = ${input['requestedSeason'] ?? 'null'};
          const preferredSubtitleLanguage = ${jsonEncode(input['preferredSubtitleLanguage'] ?? 'eng')};
          const preferredAudioMode = ${jsonEncode(input['preferredAudioMode'] ?? 'all')};
          // Match Seanime's documented provider contract exactly. Providers
          // are allowed to branch on these sentinel values when catalog
          // metadata is unavailable.
          const releaseYear = ${input['year'] ?? 0};
          const media = {
            id: ${input['anilistId']},
            status: ${jsonEncode(input['status'] ?? 'NOT_YET_RELEASED')},
            format: ${jsonEncode(input['format'] ?? 'TV')},
            romajiTitle: ${jsonEncode(input['titleRomaji'])} || titles[0] || '',
            episodeCount: ${input['episodeCount'] ?? -1},
            synonyms: ${jsonEncode((input['synonyms'] as List?) ?? const [])},
            isAdult: ${input['isAdult'] == true},
          };
          const absoluteSeasonOffset = ${input['absoluteSeasonOffset'] ?? 'null'};
          if (Number.isInteger(absoluteSeasonOffset) &&
              absoluteSeasonOffset > 0 && absoluteSeasonOffset <= 100000) {
            media.absoluteSeasonOffset = absoluteSeasonOffset;
          }
          // Canonical Seanime names stay authoritative. Read-only aliases
          // cover older community providers without changing the object shape
          // expected by current SearchOptions implementations.
          Object.defineProperties(media, {
            anilistId: {value: media.id, enumerable: false},
            aniListId: {value: media.id, enumerable: false},
            idAniList: {value: media.id, enumerable: false},
          });
          const englishTitle = ${jsonEncode(input['titleEnglish'])};
          const nativeTitle = ${jsonEncode(input['titleNative'])};
          if (englishTitle) media.englishTitle = englishTitle;
          if (nativeTitle) media.nativeTitle = nativeTitle;
          Object.defineProperties(media, {
            title: {value: titles[0] || media.romajiTitle, enumerable: false},
            titleRomaji: {value: media.romajiTitle, enumerable: false},
            titleEnglish: {value: englishTitle || undefined, enumerable: false},
            titleNative: {value: nativeTitle || undefined, enumerable: false},
          });
          const malMediaId = ${input['malId'] ?? 'null'};
          if (malMediaId != null) {
            media.idMal = malMediaId;
            Object.defineProperties(media, {
              malId: {value: malMediaId, enumerable: false},
              idMAL: {value: malMediaId, enumerable: false},
            });
          }
          if (releaseYear > 0) {
            media.startDate = {year: releaseYear};
          }
          const enabledSetting = value => value === true || value === 1 ||
            ['true', 'yes', '1', 'on'].includes(String(value || '').trim().toLowerCase());
          const serverName = server => server && typeof server === 'object'
            ? String(server.name || server.label || server.id || server.value || 'Default')
            : String(server || 'Default');
          const serverValue = server => server && typeof server === 'object'
            ? (server.value || server.id || server.name || server.label) : server;
          const boundedServerList = value => {
            if (!Array.isArray(value)) return [];
            const output = [];
            const seen = new Set();
            for (const server of value) {
              const key = (String(serverValue(server) || '') + '|' +
                serverName(server)).trim().toLowerCase();
              if (!key || seen.has(key)) continue;
              seen.add(key);
              output.push(server);
              if (output.length >= 48) break;
            }
            return output;
          };
          const configuredServers = settings.episodeServers || settings.servers;
          const configuredServerList = boundedServerList(configuredServers);
          const serverAudioLabel = server => String(serverName(server) || '')
            .toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, ' ').trim();
          const serverSupportsDub = server => {
            const label = serverAudioLabel(server);
            const compact = label.replace(/ /g, '');
            return /(^| )dub(bed)?( |\$)/.test(label) ||
              compact.includes('dualaudio') || compact.includes('multiaudio') ||
              compact.includes('subanddub') || compact.includes('dubandsub') ||
              label === 'both';
          };
          const serverIsDubOnly = server => {
            const label = serverAudioLabel(server);
            const compact = label.replace(/ /g, '');
            if (compact.includes('dualaudio') || compact.includes('multiaudio') ||
                compact.includes('subanddub') || compact.includes('dubandsub') ||
                label === 'both') return false;
            return /(^| )dub(bed)?( |\$)/.test(label);
          };
          const dubSettingKeys = [
            'supportsDub', 'supportsDubbed', 'hasDub', 'supportsDubAudio',
            'supportsEnglishDub', 'dubSupported', 'isDubAvailable', 'hasDubbed',
          ];
          const hasDubSettingDeclaration = dubSettingKeys.some(key =>
            Object.prototype.hasOwnProperty.call(settings, key)
          );
          const hasDubServerMarker = configuredServerList.some(serverSupportsDub);
          const supportsDub = dubSettingKeys.some(key => enabledSetting(settings[key])) ||
            hasDubServerMarker;
          // Current Seanime providers explicitly declare supportsDub. A
          // bounded compatibility probe covers older providers that accept a
          // dub SearchOption without declaring the capability. Never probe a
          // provider that explicitly opted out, and never treat the requested
          // flag itself as proof that the returned stream is dubbed.
          const preferredDub = preferredAudioMode === 'dub';
          const modes = supportsDub
            ? (preferredDub
                ? [{dub: true, undeclaredDubProbe: false},
                   {dub: false, undeclaredDubProbe: false}]
                : [{dub: false, undeclaredDubProbe: false},
                   {dub: true, undeclaredDubProbe: false}])
            : (!hasDubSettingDeclaration && !hasDubServerMarker &&
                preferredAudioMode !== 'sub')
              ? (preferredDub
                  ? [{dub: true, undeclaredDubProbe: true},
                     {dub: false, undeclaredDubProbe: false}]
                  : [{dub: false, undeclaredDubProbe: false},
                     {dub: true, undeclaredDubProbe: true}])
              : [{dub: false, undeclaredDubProbe: false}];
          const output = [];
          const errors = [];
          let foundTitle = false;
          let foundEpisode = false;
          let foundServer = false;
          let searchAttempts = 0;
          let successfulSearchCalls = 0;
          let episodeLookupAttempts = 0;
          let successfulEpisodeLookups = 0;
          // Keep letters and numbers from native-script aliases. The older
          // ASCII-only normalization reduced Japanese titles to an empty
          // string, so an otherwise exact native-title provider could never
          // pass title matching.
          const normalize = value => String(value || '').toLowerCase()
            .normalize('NFKD')
            .replace(/[\\u0300-\\u036f]/g, '')
            .replace(/[\\u0000-\\u002f\\u003a-\\u0040\\u005b-\\u0060\\u007b-\\u00bf\\u2000-\\u206f\\u3000-\\u303f\\uff00-\\uff65]+/g, ' ')
            .replace(/\\s+/g, ' ').trim();
          const explicitSeason = value => {
            const text = String(value || '');
            if (globalThis.\$scannerUtils &&
                typeof globalThis.\$scannerUtils.extractSeasonNumber === 'function') {
              const scanned = Number(globalThis.\$scannerUtils.extractSeasonNumber(text));
              if (Number.isFinite(scanned) && scanned > 0) return scanned;
            }
            const direct = /\\bseason\\s*([0-9]{1,3})\\b/i.exec(text);
            if (direct) return Number(direct[1]);
            const ordinal = /\\b([0-9]{1,3})(?:st|nd|rd|th)?\\s+season\\b/i.exec(text);
            return ordinal ? Number(ordinal[1]) : null;
          };
          const score = (candidate, query) => {
            const a = normalize(candidate); const b = normalize(query);
            if (!a || !b) return 0;
            const candidateSeason = explicitSeason(candidate);
            const querySeason = explicitSeason(query);
            // An unnumbered result is season 1 for matching purposes. This
            // rejects "Title Season 2" for an unnumbered catalog entry, and
            // rejects a bare parent-series result for a numbered sequel.
            if ((candidateSeason || 1) !== (querySeason || 1)) return -1000;
            if (a === b) return 1000;
            if (a.startsWith(b) || b.startsWith(a)) return 700;
            if (a.includes(b) || b.includes(a)) return 500;
            const left = new Set(a.split(' ').filter(x => x.length > 1));
            const right = new Set(b.split(' ').filter(x => x.length > 1));
            const overlap = Array.from(left).filter(word => right.has(word)).length;
            const denominator = Math.max(left.size, right.size, 1);
            return overlap >= 2 && overlap / denominator >= 0.6
              ? 300 + Math.round((overlap / denominator) * 100)
              : overlap * 20;
          };
          const listFrom = (value, keys, depth, maximum) => {
            const level = Number(depth || 0);
            const requestedLimit = Number(maximum || 200);
            const limit = Number.isFinite(requestedLimit)
              ? Math.max(1, Math.min(4096, Math.floor(requestedLimit))) : 200;
            if (Array.isArray(value)) return value.slice(0, limit);
            if (!value || typeof value !== 'object' || level >= 3) return [];
            for (const key of keys) {
              if (Array.isArray(value[key])) return value[key].slice(0, limit);
              if (value[key] && typeof value[key] === 'object') {
                const nested = listFrom(value[key], keys, level + 1, limit);
                if (nested.length) return nested;
              }
            }
            for (const wrapper of ['data', 'result', 'response', 'payload']) {
              if (value[wrapper] && typeof value[wrapper] === 'object') {
                const nested = listFrom(value[wrapper], keys, level + 1, limit);
                if (nested.length) return nested;
              }
            }
            const mapped = Object.values(value);
            if (mapped.length && mapped.length <= limit &&
                mapped.every(item => item && typeof item === 'object')) {
              return mapped;
            }
            return [];
          };
          const episodeNumberOf = item => {
            if (!item || typeof item !== 'object') return NaN;
            const explicit = [
              item.number, item.episodeNumber, item.episode_number,
              item.episodeNum, item.episode, item.ep, item.num, item.index,
            ];
            for (const raw of explicit) {
              if (raw == null || raw === '') continue;
              const direct = Number(raw);
              if (Number.isFinite(direct)) return direct;
              const text = String(raw);
              const seasonEpisode = text.match(/s\\d{1,3}\\s*e([0-9]+(?:\\.[0-9]+)?)/i);
              if (seasonEpisode) return Number(seasonEpisode[1]);
              const embedded = text.match(/(?:episode|ep|e)\\s*[-_.:#]?\\s*([0-9]+(?:\\.[0-9]+)?)/i);
              if (embedded) return Number(embedded[1]);
            }
            const values = [item.title, item.name, item.label, item.url, item.id];
            for (const raw of values) {
              const text = String(raw || '');
              let match = text.match(/s\\d{1,3}\\s*e([0-9]+(?:\\.[0-9]+)?)/i);
              if (!match) match = text.match(/(?:episode|ep|e)\\s*[-_.:#]?\\s*([0-9]+(?:\\.[0-9]+)?)/i);
              if (!match) match = text.match(/(?:^|[\\/_-])([0-9]+(?:\\.[0-9]+)?)(?:\$|[/?#._-])/);
              if (match) return Number(match[1]);
            }
            return NaN;
          };
          // Playback identity must use only provider-owned episode fields or
          // explicit episode syntax. A numeric URL/id segment can help legacy
          // lookup, but is not trustworthy enough to reject playback.
          const explicitEpisodeNumberOf = item => {
            if (!item || typeof item !== 'object') return NaN;
            const values = [
              item.number, item.episodeNumber, item.episode_number,
              item.episodeNum, item.episode, item.ep, item.num,
            ];
            for (const raw of values) {
              if (raw == null || raw === '') continue;
              const direct = Number(raw);
              if (Number.isInteger(direct) && direct > 0) return direct;
              const text = String(raw);
              let match = text.match(/s\\d{1,3}\\s*e([0-9]+)/i);
              if (!match) {
                match = text.match(/(?:episode|ep|e)\\s*[-_.:#]?\\s*([0-9]+)/i);
              }
              if (match) return Number(match[1]);
            }
            for (const raw of [item.title, item.name, item.label]) {
              const text = String(raw || '');
              let match = text.match(/s\\d{1,3}\\s*e([0-9]+)/i);
              if (!match) {
                match = text.match(/(?:episode|ep|e)\\s*[-_.:#]?\\s*([0-9]+)/i);
              }
              if (match) return Number(match[1]);
            }
            return NaN;
          };
          const seasonNumberOf = item => {
            if (!item || typeof item !== 'object') return NaN;
            const explicit = [
              item.seasonNumber, item.season_number, item.season,
              item.seasonNum, item.seasonIndex,
            ];
            for (const raw of explicit) {
              const direct = Number(raw);
              if (Number.isInteger(direct) && direct > 0) return direct;
              const match = String(raw || '').match(/(?:season|s)\\s*0*(\\d{1,3})/i);
              if (match) return Number(match[1]);
            }
            for (const raw of [item.title, item.name, item.label, item.id]) {
              const match = String(raw || '').match(/(?:^|[^a-z0-9])s0*(\\d{1,3})\\s*e\\d+/i);
              if (match) return Number(match[1]);
            }
            return NaN;
          };
          const valueFrom = (item, keys) => {
            if (!item || typeof item !== 'object') return undefined;
            for (const key of keys) {
              const value = item[key];
              if (value != null && value !== '') return value;
            }
            return undefined;
          };
          const candidateKey = item => {
            const identity = valueFrom(item, [
              'id', 'animeId', 'mediaId', 'providerId', 'slug', 'url', 'link',
            ]);
            if (identity != null) return String(identity).slice(0, 512);
            try { return String(JSON.stringify(item)).slice(0, 512); }
            catch (_) { return candidateTitle(item).slice(0, 512); }
          };
          const candidateTitle = item => String(valueFrom(item, [
            'title', 'name', 'englishTitle', 'romajiTitle', 'nativeTitle',
            'titleNative', 'label',
          ]) || '');
          const candidateSeasonOf = item => {
            const structured = seasonNumberOf(item);
            if (Number.isInteger(structured) && structured > 0) {
              return structured;
            }
            for (const raw of [
              item && item.title, item && item.name, item && item.label,
              item && item.id, item && item.slug, item && item.url,
              item && item.link,
            ]) {
              const parsed = explicitSeason(raw);
              if (Number.isInteger(parsed) && parsed > 0) return parsed;
            }
            return null;
          };
          const candidateYearOf = item => {
            const raw = valueFrom(item, [
              'year', 'releaseYear', 'startYear', 'airedYear', 'startDate',
            ]);
            const direct = raw && typeof raw === 'object' ? Number(raw.year) : Number(raw);
            if (Number.isFinite(direct) && direct > 0) return direct;
            if (globalThis.\$scannerUtils &&
                typeof globalThis.\$scannerUtils.extractYear === 'function') {
              const fromTitle = Number(globalThis.\$scannerUtils.extractYear(candidateTitle(item)));
              if (Number.isFinite(fromTitle) && fromTitle > 0) return fromTitle;
            }
            return null;
          };
          const providerReason = error => {
            const message = String(error && error.message || error || '').toLowerCase();
            if (/timeout|timed out|deadline|aborted/.test(message)) return 'timeout';
            if (/network request limit|request budget/.test(message)) return 'request_limit';
            if (/total response limit|response budget|response is too large/.test(message)) return 'response_limit';
            if (/redirect limit|too many redirects/.test(message)) return 'redirect_limit';
            if (/invalid provider request|configured addon payload|invalid payload/.test(message)) return 'invalid_payload';
            const http = message.match(/(?:http|status|returned|failed)\\D{0,12}([1-5][0-9]{2})/);
            if (http) return 'http_' + http[1];
            // These common empty-result phrases describe title or episode
            // availability, not a broken runtime, and therefore must not open
            // the provider circuit breaker.
            if (/\\b(?:no anime|no titles?|no results?|no matches?|no episodes?)\\s+(?:was\\s+|were\\s+)?found\\b/.test(message)) return 'empty_result';
            // A provider can legitimately have an episode record but no
            // configured playback server for it. Keep that visible at the
            // server stage while classifying it as source availability rather
            // than a provider crash.
            if (/\\b(?:selected\\s+|requested\\s+)?server\\s+(?:was\\s+)?not found\\b|\\bno providers found for server\\b/.test(message)) return 'empty_sources';
            if (/no source|no stream|video source|empty source|unable to find a valid source/.test(message)) return 'empty_sources';
            if (/public https|safety|unsafe|private address|not permitted/.test(message)) return 'unsafe_target';
            if (/json|parse|unexpected token|invalid response/.test(message)) return 'invalid_response';
            if (/network|socket|dns|connection|fetch failed|host lookup/.test(message)) return 'network';
            const missingRuntimeReference = new RegExp(
              ${jsonEncode(_missingRuntimeReferencePattern)}, 'i'
            );
            const missingRuntimeApi = new RegExp(
              ${jsonEncode(_missingRuntimeApiPattern)}, 'i'
            );
            if (missingRuntimeReference.test(message) || missingRuntimeApi.test(message)) {
              return 'runtime_api';
            }
            return 'provider_error';
          };
          const isSearchArgumentShapeError = error => {
            const message = String(error && error.message || error || '');
            return /argument|expected(?: an?)? (?:string|object)|cannot read (?:properties|property) of (?:undefined|null)|(?:undefined|null) is not an object|(?:replace|trim|tolowercase) is not a function|cannot convert (?:undefined|null)/i
              .test(message);
          };
          const toHttps = (value, bases) => {
            if (typeof value !== 'string' || !value.trim()) return null;
            const raw = value.trim();
            try {
              const direct = new URL(raw);
              if (direct.protocol === 'https:') return direct.toString();
            } catch (_) {}
            for (const base of bases) {
              if (typeof base !== 'string' || !base.startsWith('https://')) continue;
              try {
                const absolute = new URL(raw, base);
                if (absolute.protocol === 'https:') return absolute.toString();
              } catch (_) {}
            }
            return null;
          };
          const subtitleLanguageAliases = {
            ara: ['ara', 'ar', 'arabic'], ben: ['ben', 'bn', 'bengali', 'bangla'],
            bul: ['bul', 'bg', 'bulgarian'], cat: ['cat', 'ca', 'catalan'],
            ces: ['ces', 'cze', 'cs', 'czech'], dan: ['dan', 'da', 'danish'],
            deu: ['deu', 'ger', 'de', 'german', 'deutsch'],
            ell: ['ell', 'gre', 'el', 'greek'], eng: ['eng', 'en', 'english'],
            fas: ['fas', 'per', 'fa', 'persian', 'farsi'],
            fil: ['fil', 'tl', 'filipino', 'tagalog'], fin: ['fin', 'fi', 'finnish'],
            fra: ['fra', 'fre', 'fr', 'french'], heb: ['heb', 'he', 'iw', 'hebrew'],
            hin: ['hin', 'hi', 'hindi'], hrv: ['hrv', 'hr', 'croatian'],
            hun: ['hun', 'hu', 'hungarian'], ind: ['ind', 'id', 'indonesian'],
            ita: ['ita', 'it', 'italian'], jpn: ['jpn', 'ja', 'jp', 'japanese'],
            kor: ['kor', 'ko', 'korean'], msa: ['msa', 'may', 'ms', 'malay'],
            nld: ['nld', 'dut', 'nl', 'dutch'],
            nor: ['nor', 'no', 'nb', 'nn', 'norwegian'],
            pol: ['pol', 'pl', 'polish'], por: ['por', 'pt', 'portuguese'],
            ron: ['ron', 'rum', 'ro', 'romanian'], rus: ['rus', 'ru', 'russian'],
            slk: ['slk', 'slo', 'sk', 'slovak'], slv: ['slv', 'sl', 'slovenian'],
            spa: ['spa', 'es', 'spanish'], srp: ['srp', 'sr', 'serbian'],
            swe: ['swe', 'sv', 'swedish'], tam: ['tam', 'ta', 'tamil'],
            tel: ['tel', 'te', 'telugu'], tha: ['tha', 'th', 'thai'],
            tur: ['tur', 'tr', 'turkish'], ukr: ['ukr', 'uk', 'ukrainian'],
            urd: ['urd', 'ur', 'urdu'], vie: ['vie', 'vi', 'vietnamese'],
            zho: ['zho', 'chi', 'zh', 'chinese', 'mandarin'],
          };
          const preferredSubtitleTrack = tracks => {
            if (!tracks.length) return null;
            const aliases = subtitleLanguageAliases[preferredSubtitleLanguage] ||
              [preferredSubtitleLanguage];
            return tracks.find(track => {
              const value = normalize(track && (track.language || track.lang || track.label || track.name));
              const words = new Set(value.split(' ').filter(Boolean));
              return aliases.some(alias => value === alias || words.has(alias));
            }) || tracks[0];
          };
          const trackIsAudio = track => {
            if (!track || typeof track !== 'object') return false;
            const kind = normalize(
              track.type || track.kind || track.codecType || track.trackType
            );
            return kind === 'audio' || kind.includes('audio');
          };
          const explicitTrackEntries = (item, keys) => {
            if (!item || typeof item !== 'object') return [];
            const output = [];
            const append = value => {
              if (output.length >= 64 || value == null) return;
              if (typeof value === 'string') {
                output.push(value);
                return;
              }
              if (value && typeof value === 'object' && !Array.isArray(value) &&
                  valueFrom(value, [
                    'url', 'file', 'src', 'link', 'href', 'uri', 'manifest',
                    'playlist', 'streamUrl', 'hls',
                  ]) != null) {
                output.push(value);
                return;
              }
              for (const entry of listFrom(
                value,
                keys.concat(['items', 'tracks', 'sources']),
                0,
                64,
              )) {
                output.push(entry);
                if (output.length >= 64) break;
              }
            };
            for (const key of keys) append(item[key]);
            return output.slice(0, 64);
          };
          const audioTrackEntriesWithin = item => {
            const explicitKeys = [
              'externalAudioTracks', 'audioTracks', 'availableAudioTracks',
              'audioStreams', 'audios',
            ];
            const output = explicitTrackEntries(item, explicitKeys);
            for (const track of listFrom(
              item && item.tracks,
              ['tracks', 'items'],
              0,
              64,
            )) {
              if (trackIsAudio(track)) output.push(track);
              if (output.length >= 64) break;
            }
            return output.slice(0, 64);
          };
          const subtitleTrackEntriesWithin = item => {
            const output = explicitTrackEntries(item, ['subtitles', 'captions']);
            for (const track of listFrom(
              item && item.tracks,
              ['tracks', 'items'],
              0,
              64,
            )) {
              // Untyped generic tracks retain legacy subtitle compatibility;
              // entries explicitly identified as audio never cross into CC.
              if (!trackIsAudio(track)) output.push(track);
              if (output.length >= 64) break;
            }
            return output.slice(0, 64);
          };
          const boundedTrackText = value => {
            if (typeof value !== 'string') return null;
            const text = value.replace(/[\\u0000-\\u001f\\u007f]/g, ' ')
              .replace(/[\\u202a-\\u202e\\u2066-\\u2069]/g, '')
              .replace(/\\s+/g, ' ').trim();
            return text ? text.slice(0, 80) : null;
          };
          const boundedExternalAudioHeaders = value => {
            if (!value || typeof value !== 'object' || Array.isArray(value)) {
              return null;
            }
            const output = {};
            for (const [rawName, rawValue] of Object.entries(value).slice(0, 24)) {
              const name = String(rawName || '').trim();
              if (!name || name.length > 80 ||
                  !/^[!#\$%&'*+.^_`|~0-9A-Za-z-]+\$/.test(name) ||
                  !['string', 'number', 'boolean'].includes(typeof rawValue)) {
                continue;
              }
              const headerValue = String(rawValue).trim();
              if (!headerValue || headerValue.length > 1024 ||
                  /[\\u0000-\\u001f\\u007f]/.test(headerValue)) {
                continue;
              }
              output[name] = headerValue;
            }
            return Object.keys(output).length ? output : null;
          };
          const externalAudioTracksOf = (source, resolved, bases) => {
            const output = [];
            const seen = new Set();
            const candidates = audioTrackEntriesWithin(source)
              .concat(audioTrackEntriesWithin(resolved))
              .slice(0, 64);
            for (const rawTrack of candidates) {
              const track = typeof rawTrack === 'string'
                ? {url: rawTrack} : rawTrack;
              if (!track || typeof track !== 'object') continue;
              const rawUrl = valueFrom(track, [
                'url', 'file', 'src', 'link', 'href', 'uri', 'manifest',
                'playlist', 'streamUrl', 'hls',
              ]);
              if (typeof rawTrack === 'string') {
                const location = rawTrack.trim();
                const looksLikeLocation = /^(?:https:)?\\/\\//i.test(location) ||
                  /^(?:\\.\\.?\\/|\\/)/.test(location) ||
                  /[/?#]/.test(location) ||
                  /\\.(?:m3u8|mpd|aac|m4a|mp3|opus|ogg|flac|wav|ac3|eac3)(?:\$|[?#])/i
                    .test(location);
                if (!looksLikeLocation) continue;
              }
              const audioUrl = toHttps(rawUrl, bases);
              if (!audioUrl) continue;
              const language = boundedTrackText(valueFrom(track, [
                'language', 'lang', 'locale', 'audioLanguage',
              ]));
              const label = boundedTrackText(valueFrom(track, [
                'label', 'name', 'title', 'quality',
              ])) || language;
              const headers = boundedExternalAudioHeaders(
                track.headers || track.requestHeaders
              );
              const marker = audioUrl + '|' + String(language || '') + '|' +
                String(label || '') + '|' + JSON.stringify(headers || {});
              if (seen.has(marker)) continue;
              seen.add(marker);
              const normalizedTrack = {url: audioUrl};
              if (label) normalizedTrack.label = label;
              if (language) normalizedTrack.language = language;
              if (headers) normalizedTrack.headers = headers;
              output.push(normalizedTrack);
              if (output.length >= $seanimeMaximumExternalAudioTracks) break;
            }
            return output;
          };
          const audioEvidenceText = (value, depth) => {
            const level = Number(depth || 0);
            if (value == null || level > 4) return '';
            if (Array.isArray(value)) {
              return value.slice(0, 32)
                .map(item => audioEvidenceText(item, level + 1)).join(' ');
            }
            if (typeof value === 'object') {
              return Object.entries(value).slice(0, 32).map(([key, item]) =>
                item === true ? key : audioEvidenceText(item, level + 1)
              ).join(' ');
            }
            return String(value);
          };
          const audioSupportFromMetadata = item => {
            if (!item || typeof item !== 'object') return 0;
            const values = [
              'audioCapability', 'audioMode', 'languageMode',
              'audioLanguage', 'audioLanguages', 'availableAudioLanguages',
              'subOrDub', 'sub_or_dub',
            ].map(key => item[key]).filter(value => value != null && value !== '');
            const text = normalize(values.map(value => audioEvidenceText(value)).join(' '));
            const compact = text.replace(/ /g, '');
            if (item.multiAudio === true || item.dualAudio === true ||
                item.supportsSubAndDub === true || text === 'both' ||
                compact.includes('dualaudio') || compact.includes('multiaudio') ||
                compact.includes('subanddub') || compact.includes('dubandsub') ||
                compact === 'subdub' || compact === 'dubsub') {
              return 3;
            }
            const words = new Set(text.split(' ').filter(Boolean));
            const subtitleContext = ['subtitle', 'subtitles', 'caption', 'captions']
              .some(word => words.has(word));
            let support = 0;
            if (['sub', 'subbed', 'subtitle', 'subtitles', 'subtitled']
                .some(word => words.has(word)) || item.isSubbed === true ||
                item.subbed === true || item.sub === true ||
                item.supportsSub === true || item.hasSub === true ||
                item.hasJapaneseAudio === true || item.hasOriginalAudio === true) {
              support |= 1;
            }
            if (['dub', 'dubbed'].some(word => words.has(word)) ||
                item.isDubbed === true || item.dubbed === true ||
                item.dub === true || item.supportsDub === true ||
                item.hasDub === true || item.hasEnglishAudio === true) {
              support |= 2;
            }
            if (!subtitleContext &&
                ['en', 'eng', 'english'].some(word => words.has(word))) {
              support |= 2;
            }
            if (!subtitleContext &&
                ['ja', 'jp', 'jpn', 'japanese'].some(word => words.has(word))) {
              support |= 1;
            }
            return support;
          };
          const audioSupportFromTracks = item => {
            if (!item || typeof item !== 'object') return 0;
            let support = 0;
            for (const track of audioTrackEntriesWithin(item)) {
              const text = normalize(typeof track === 'string' ? track :
                track && (track.language || track.lang || track.label || track.name));
              const words = new Set(text.split(' ').filter(Boolean));
              if (['en', 'eng', 'english', 'dub', 'dubbed'].some(word => words.has(word))) {
                support |= 2;
              }
              if (['ja', 'jp', 'jpn', 'japanese', 'sub', 'subbed'].some(word => words.has(word))) {
                support |= 1;
              }
            }
            return support;
          };
          const audioLanguagesWithin = item => {
            if (!item || typeof item !== 'object') return [];
            const output = [];
            const add = value => {
              if (typeof value === 'string' && value.trim()) {
                output.push(value.trim().slice(0, 80));
              }
            };
            const addValue = value => {
              if (Array.isArray(value)) {
                for (const entry of value.slice(0, 24)) addValue(entry);
                return;
              }
              if (value && typeof value === 'object') {
                add(value.language || value.lang || value.label || value.name);
                return;
              }
              add(value);
            };
            addValue(item.audioLanguage);
            addValue(item.audioLanguages);
            addValue(item.availableAudioLanguages);
            for (const track of audioTrackEntriesWithin(item)) {
              addValue(track);
            }
            return output.slice(0, 24);
          };
          const sourceAudioLocale = item => {
            if (!item || typeof item !== 'object') return null;
            const explicit = valueFrom(item, [
              'audioLanguage', 'audioLang', 'audioLocale',
            ]);
            const raw = String(explicit || valueFrom(item, [
              'label', 'quality', 'title', 'name',
            ]) || '').trim();
            // A leading BCP-47/ISO language token is stream-specific evidence.
            // Do not scan arbitrary words later in the label: "1080p English
            // subtitles" describes captions, not the audio feed.
            const match = /^([a-z]{2,3})(?:[-_]([a-z]{2}))?(?=\\s|\\(|\\[|_|-|\$)/i.exec(raw);
            if (!match) return null;
            const language = match[1].toLowerCase();
            const known = new Set([
              'ar', 'ara', 'bn', 'ben', 'bg', 'bul', 'ca', 'cat',
              'cs', 'ces', 'cze', 'da', 'dan', 'de', 'deu', 'ger',
              'el', 'ell', 'gre', 'en', 'eng', 'es', 'spa', 'fa',
              'fas', 'per', 'fi', 'fin', 'fil', 'tl', 'fr', 'fra',
              'fre', 'he', 'heb', 'hi', 'hin', 'hr', 'hrv', 'hu',
              'hun', 'id', 'ind', 'it', 'ita', 'ja', 'jp', 'jpn',
              'ko', 'kor', 'ms', 'msa', 'may', 'nl', 'nld', 'dut',
              'no', 'nb', 'nn', 'nor', 'pl', 'pol', 'pt', 'por',
              'ro', 'ron', 'rum', 'ru', 'rus', 'sk', 'slk', 'slo',
              'sl', 'slv', 'sr', 'srp', 'sv', 'swe', 'ta', 'tam',
              'te', 'tel', 'th', 'tha', 'tr', 'tur', 'uk', 'ukr',
              'ur', 'urd', 'vi', 'vie', 'zh', 'zho', 'chi',
            ]);
            if (!known.has(language)) return null;
            return match[2]
              ? language + '-' + match[2].toUpperCase()
              : language;
          };
          const audioSupportFromSourceLabel = item => {
            const locale = sourceAudioLocale(item);
            if (locale) {
              const primary = locale.split('-')[0];
              return ['ja', 'jp', 'jpn'].includes(primary) ? 1 : 2;
            }
            const raw = String(valueFrom(item, [
              'audioLabel', 'label', 'quality', 'title', 'name',
            ]) || '').trim();
            const first = normalize(raw).split(' ').filter(Boolean)[0] || '';
            if (['japanese', 'sub', 'subbed'].includes(first)) return 1;
            if (['english', 'dub', 'dubbed'].includes(first)) return 2;
            return 0;
          };
          const audioLanguagesOf = (source, resolved, selectedResult) =>
            (sourceAudioLocale(source) ? [sourceAudioLocale(source)] : [])
              .concat(audioLanguagesWithin(source))
              .concat(audioLanguagesWithin(resolved))
              .concat(audioLanguagesWithin(selectedResult))
              .slice(0, 24);
          const capabilityFromSupport = support => support === 3
            ? 'sub_and_dub' : support === 2 ? 'dub' : support === 1 ? 'sub' : null;
          const capabilityWithin = item => capabilityFromSupport(
            audioSupportFromMetadata(item) | audioSupportFromTracks(item)
          );
          const audioCapabilityOf = (
            source, resolved, selectedResult, requestedDub, selectedServerName
          ) => {
            // Stream-level evidence is more specific than a title-wide mode.
            // This keeps a real Sub-only/Dub-only variant exclusive even when
            // its provider also offers the other language elsewhere.
            const sourceCapability = capabilityWithin(source);
            if (sourceCapability) return sourceCapability;
            const sourceLabelCapability = capabilityFromSupport(
              audioSupportFromSourceLabel(source)
            );
            if (sourceLabelCapability) return sourceLabelCapability;
            const resolvedCapability = capabilityWithin(resolved);
            if (resolvedCapability) return resolvedCapability;

            // A server label is stream-specific and must not be hidden by a
            // title-wide stale `subOrDub` value from an older extension.
            const serverCapability = capabilityWithin({
              audioCapability: selectedServerName,
            });
            if (serverCapability) return serverCapability;

            const releaseHint = [
              valueFrom(source, ['title', 'label', 'name']),
              valueFrom(resolved, ['title', 'label', 'name']),
              selectedServerName,
            ].map(normalize).filter(Boolean).join(' ');
            if (/multi audio|dual audio|sub and dub|dub and sub/.test(releaseHint)) {
              return 'sub_and_dub';
            }
            const providerCapability = capabilityWithin(selectedResult);
            if (providerCapability) return providerCapability;
            return requestedDub ? 'dub' : 'sub';
          };
          let providerRequiresLegacySearch = false;
          const cleanEmptyLegacyProbedModes = new Set();
          let providerSearchRuntimeFailed = false;
          let settingsRefreshedAfterLookup = false;
          for (const mode of modes) {
            // A stream with independent dual-audio evidence already satisfies
            // either picker mode. Do not repeat the provider's title, episode,
            // and server work solely to request the opposite flag.
            if (output.some(item => item.audioCapability === 'sub_and_dub')) break;
            if (providerSearchRuntimeFailed) break;
            const dub = mode.dub;
            const undeclaredDubProbe = mode.undeclaredDubProbe;
            // Do not stack the undeclared-Dub compatibility probe on top of
            // a legacy-signature fallback. Explicitly Dub-capable legacy
            // providers still receive their declared second audio mode.
            if (undeclaredDubProbe && providerRequiresLegacySearch) break;
            const candidates = new Map();
            const modeTitles = undeclaredDubProbe ? titles.slice(0, 1) : titles;
            const addMatches = (matches, title) => {
              matches.slice(0, 40).forEach((item, index) => {
                if (!item || typeof item !== 'object') return;
                const candidateName = candidateTitle(item);
                const titleSeason = explicitSeason(candidateName);
                const structuredSeason = candidateSeasonOf(item);
                // Alias scoring is intentionally broad, but it must not let a
                // bare/native alias erase the catalog's numbered-season
                // identity. Provider-owned title/season fields or an exact
                // catalog ID are independent corroboration; another query
                // alias is not.
                if (requestedSeason != null &&
                    ((titleSeason != null && titleSeason !== requestedSeason) ||
                     (structuredSeason != null && structuredSeason !== requestedSeason))) {
                  return;
                }
                const titleScore = titles.reduce(
                  (best, alias) => Math.max(best, score(candidateName, alias)),
                  score(candidateName, title),
                );
                const mediaId = valueFrom(item, ['anilistId', 'aniListId', 'idAniList']);
                const idBonus = Number(mediaId) === media.id ? 2000 : 0;
                if (requestedSeason != null && requestedSeason > 1 &&
                    titleSeason == null && structuredSeason == null && idBonus === 0) {
                  return;
                }
                const candidateYear = candidateYearOf(item);
                if (titleScore < 0) return;
                if (idBonus === 0 && titleScore < 300) return;
                let yearPenalty = 0;
                if (releaseYear > 0 && candidateYear != null &&
                    candidateYear !== releaseYear) {
                  const exactAlias = titles.find(alias =>
                    normalize(candidateName) === normalize(alias)
                  );
                  const candidateSeason = explicitSeason(candidateName);
                  const aliasSeason = exactAlias == null
                    ? null : explicitSeason(exactAlias);
                  const exactNumberedSeason = candidateSeason != null &&
                    aliasSeason != null && candidateSeason === aliasSeason;
                  const explicitDubMetadata = (
                    audioSupportFromMetadata(item) | audioSupportFromTracks(item)
                  ) & 2;
                  const corroboratedDubReleaseYear = exactAlias != null &&
                    explicitDubMetadata !== 0 &&
                    Math.abs(candidateYear - releaseYear) === 1;
                  // Provider franchise years are common for an explicitly
                  // numbered season. A one-year dub release difference is
                  // accepted only when the result itself carries Dub audio
                  // evidence. Bare exact-title remakes stay rejected unless
                  // the exact AniList identity corroborates the result.
                  if (idBonus === 0 && !exactNumberedSeason &&
                      !corroboratedDubReleaseYear) {
                    return;
                  }
                  yearPenalty = Math.min(
                    240,
                    40 + Math.abs(candidateYear - releaseYear) * 20,
                  );
                }
                const providerOrderBonus = Math.max(0, 39 - index);
                const points = titleScore + idBonus + providerOrderBonus - yearPenalty;
                const key = candidateKey(item);
                const existing = candidates.get(key);
                if (!existing || points > existing.points) {
                  candidates.set(key, {item, points});
                }
              });
            };
            let canonicalCleanEmpty = true;
            let canonicalQueriesCompleted = 0;
            let canonicalShapeFailure = false;
            let canonicalSearchFailure = false;
            let runLegacySearch = providerRequiresLegacySearch;
            if (!providerRequiresLegacySearch) {
              for (const title of modeTitles) {
                const searchInput = {
                  query: title,
                  dub,
                  year: releaseYear,
                  media,
                  opts: {dub, year: releaseYear, media},
                };
                searchAttempts += 1;
                try {
                  const rawMatches = await providerCall(
                    () => provider.search(searchInput)
                  );
                  successfulSearchCalls += 1;
                  canonicalQueriesCompleted += 1;
                  const matches = listFrom(
                    rawMatches,
                    ['results', 'items', 'data', 'matches'],
                  );
                  if (matches.length) canonicalCleanEmpty = false;
                  addMatches(matches, title);
                } catch (error) {
                  errors.push({stage: 'search', reason: providerReason(error)});
                  canonicalShapeFailure = isSearchArgumentShapeError(error);
                  canonicalSearchFailure = !canonicalShapeFailure;
                  if (canonicalShapeFailure) providerRequiresLegacySearch = true;
                  if (canonicalSearchFailure) providerSearchRuntimeFailed = true;
                  break;
                }
                if (Array.from(candidates.values())
                    .some(item => item.points >= 1000)) break;
              }
              const allCanonicalAliasesCleanEmpty = canonicalCleanEmpty &&
                canonicalQueriesCompleted === modeTitles.length;
              if (canonicalShapeFailure) {
                runLegacySearch = true;
              } else if (!canonicalSearchFailure &&
                  allCanonicalAliasesCleanEmpty &&
                  !cleanEmptyLegacyProbedModes.has(dub)) {
                // A few old providers accept the object without throwing but
                // read it as a string and silently return no results. Probe
                // the best alias once per supported audio mode, never once
                // per alias. This lets an explicitly Dub-capable legacy
                // provider return an empty Sub result and a valid Dub result.
                cleanEmptyLegacyProbedModes.add(dub);
                runLegacySearch = true;
              }
            }
            // A proven string-signature provider gets one call per supported
            // audio mode. Clean-empty compatibility probes are bounded to at
            // most one Sub plus one Dub call and are never attempted after a
            // network/runtime error.
            if (runLegacySearch && !canonicalSearchFailure && modeTitles.length) {
              searchAttempts += 1;
              try {
                const title = modeTitles[0];
                const legacyOptions = {dub, year: releaseYear, media};
                const rawMatches = await providerCall(
                  () => provider.search(title, legacyOptions)
                );
                successfulSearchCalls += 1;
                const matches = listFrom(
                  rawMatches,
                  ['results', 'items', 'data', 'matches'],
                );
                if (matches.length) providerRequiresLegacySearch = true;
                addMatches(matches, title);
              } catch (error) {
                const reason = providerReason(error);
                errors.push({stage: 'search', reason});
                if (reason !== 'empty_result' && reason !== 'empty_sources') {
                  providerSearchRuntimeFailed = true;
                }
              }
            }
            const rankedCandidates = Array.from(candidates.values())
              .sort((left, right) => right.points - left.points)
              .slice(0, 4);
            if (!rankedCandidates.length) continue;
            foundTitle = true;
            let selected = null;
            let episode = null;
            for (const candidate of rankedCandidates) {
              let episodes = listFrom(candidate.item, ['episodes'], 0, 4096);
              if (episodes.length) successfulEpisodeLookups += 1;
              const identifier = valueFrom(candidate.item, [
                'id', 'animeId', 'mediaId', 'providerId', 'slug', 'url', 'link',
              ]);
              if (!episodes.length && identifier != null) {
                episodeLookupAttempts += 1;
                try {
                  const rawEpisodes = await providerCall(
                    () => provider.findEpisodes(identifier)
                  );
                  successfulEpisodeLookups += 1;
                  episodes = listFrom(rawEpisodes, [
                    'episodes', 'items', 'results', 'data', 'entries',
                  ], 0, 4096);
                } catch (error) {
                  errors.push({stage: 'episode_lookup', reason: providerReason(error)});
                  // A bounded object-shape retry covers providers that adopted
                  // search-result objects before Seanime standardized the ID
                  // argument. Network failures are never repeated.
                  const message = String(error && error.message || error);
                  if (/argument|undefined|null|property|object|expected/i.test(message)) {
                    episodeLookupAttempts += 1;
                    try {
                      const rawEpisodes = await providerCall(
                        () => provider.findEpisodes(candidate.item)
                      );
                      successfulEpisodeLookups += 1;
                      episodes = listFrom(rawEpisodes, [
                        'episodes', 'items', 'results', 'data', 'entries',
                      ], 0, 4096);
                    } catch (fallbackError) {
                      errors.push({
                        stage: 'episode_lookup',
                        reason: providerReason(fallbackError),
                      });
                    }
                  }
                }
              }
              episode = episodes.find(
                item => Math.abs(episodeNumberOf(item) - episodeNumber) < 0.01
              );
              if (!episode && episodes.length === 1 && episodeNumber === 1) {
                episode = episodes[0];
              }
              if (episode) {
                selected = candidate;
                break;
              }
            }
            if (!selected || !episode) continue;
            foundEpisode = true;
            if (!settingsRefreshedAfterLookup &&
                typeof provider.getSettings === 'function') {
              settingsRefreshedAfterLookup = true;
              try {
                const refreshed = await providerCall(() => provider.getSettings());
                if (refreshed && typeof refreshed === 'object') {
                  settings = Object.assign({}, settings, refreshed);
                }
              } catch (error) {
                errors.push({stage: 'server_lookup', reason: providerReason(error)});
              }
            }
            const activeConfiguredServers =
              settings.episodeServers || settings.servers || configuredServers;
            let servers = boundedServerList(activeConfiguredServers);
            if (!servers.length) servers = ['default'];
            const dubbedServers = servers.filter(serverIsDubOnly);
            if (supportsDub && dubbedServers.length) {
              servers = dub ? dubbedServers : servers.filter(server => !serverIsDubOnly(server));
            }
            // Providers commonly mutate instance headers/cookies while
            // resolving a server. Resolve in manifest order on the one
            // Provider instance so those stateful calls cannot race and so
            // stream ordering remains deterministic.
            let successfulServers = 0;
            for (const server of servers) {
              const outputBeforeServer = output.length;
              let resolved = null;
              try {
                try {
                  resolved = await providerCall(
                    () => provider.findEpisodeServer(episode, serverValue(server))
                  );
                } catch (error) {
                  const message = String(error && error.message || error);
                  errors.push({stage: 'server_lookup', reason: providerReason(error)});
                  // Seanime's current contract passes the episode object. A
                  // small number of legacy providers expect its ID instead;
                  // retry only argument-shape errors so network failures are
                  // not repeated three times.
                  if (/argument|undefined|null|property|\\bid\\b|object/i.test(message)) {
                    try {
                      resolved = await providerCall(
                        () => provider.findEpisodeServer(
                          episode.id || episode.url || episode,
                          serverValue(server),
                        )
                      );
                    } catch (fallbackError) {
                      errors.push({
                        stage: 'server_lookup',
                        reason: providerReason(fallbackError),
                      });
                    }
                  }
                }
                if (!resolved) continue;
                foundServer = true;
                const effectiveServer = resolved.server != null &&
                    String(resolved.server).trim()
                  ? resolved.server : server;
                const resolvedHeaders = resolved &&
                  (resolved.headers || resolved.requestHeaders || resolved.responseHeaders);
                const serverHeaders = resolvedHeaders && typeof resolvedHeaders === 'object'
                  ? resolvedHeaders : {};
                let sources = listFrom(resolved, [
                  'videoSources', 'sources', 'streams', 'videos', 'links',
                ]);
                if (!sources.length && (typeof resolved === 'string' || resolved.url || resolved.file || resolved.src || resolved.link)) {
                  sources = [resolved];
                }
                for (const rawSource of sources.slice(0, 20)) {
                  const source = typeof rawSource === 'string' ? {url: rawSource} : rawSource;
                  if (!source || typeof source !== 'object') continue;
                  const bases = [source.baseUrl, resolved.baseUrl, resolved.url, episode.url, selected.item.url];
                  const url = toHttps(
                    source.url || source.file || source.src || source.link ||
                      source.href || source.uri || source.manifest ||
                      source.playlist || source.streamUrl || source.hls,
                    bases,
                  );
                  if (!url) continue;
                  const subtitles = subtitleTrackEntriesWithin(source)
                    .concat(subtitleTrackEntriesWithin(resolved))
                    .slice(0, 64);
                  const preferredSubtitle = preferredSubtitleTrack(subtitles);
                  const subtitleUrl = preferredSubtitle && toHttps(
                    preferredSubtitle.url || preferredSubtitle.file ||
                      preferredSubtitle.src || preferredSubtitle.link ||
                      preferredSubtitle.href || preferredSubtitle.uri ||
                      preferredSubtitle.subtitleUrl,
                    bases,
                  );
                  const externalAudioTracks = externalAudioTracksOf(
                    source,
                    resolved,
                    bases,
                  );
                  const explicitDubSelection =
                    /dub/i.test(String(selected.item.subOrDub || '')) ||
                    /dub/i.test(serverName(effectiveServer));
                  const audioCapability = audioCapabilityOf(
                    source,
                    resolved,
                    selected.item,
                    (!undeclaredDubProbe && dub) || explicitDubSelection,
                    serverName(effectiveServer),
                  );
                  // A provider that omits Dub capability metadata might ignore
                  // the probe flag and return its ordinary Sub feed. Keep only
                  // probe results with independent result/server/track evidence
                  // so the request flag can never mislabel a stream.
                  if (undeclaredDubProbe && audioCapability !== 'dub' &&
                      audioCapability !== 'sub_and_dub') {
                    continue;
                  }
                  output.push({
                    title: serverName(effectiveServer) + ' / ' +
                      String(source.quality || source.label || 'Auto'),
                    quality: String(source.quality || source.label || 'Auto'),
                    url,
                    // Preserve a bounded explicit media type so Dart can
                    // inspect signed/extensionless HLS master URLs.
                    streamType: String(
                      source.streamType || source.type || source.format || source.mimeType ||
                      resolved.streamType || resolved.type || resolved.format || resolved.mimeType || ''
                    ).slice(0, 64),
                    headers: Object.assign({}, serverHeaders, source.headers || {}),
                    subtitleUrl,
                    subtitleLanguage: preferredSubtitle && String(
                      preferredSubtitle.language || preferredSubtitle.lang ||
                        preferredSubtitle.label || preferredSubtitleLanguage
                    ),
                    externalAudioTracks,
                    audioCapability,
                    audioLanguages: audioLanguagesOf(
                      source,
                      resolved,
                      selected.item,
                    ),
                    matchedEpisodeNumber: explicitEpisodeNumberOf(episode),
                    matchedSeasonNumber: seasonNumberOf(episode),
                    matchedSeriesTitle: candidateTitle(selected.item),
                  });
                }
              } catch (error) {
                errors.push({
                  stage: resolved ? 'stream_extraction' : 'server_lookup',
                  reason: providerReason(error),
                });
              }
              if (output.length > outputBeforeServer) {
                sendMessage('TetoProgress', JSON.stringify({
                  ok: true,
                  result: output.slice(0, 80),
                }));
                successfulServers += 1;
                // Keep multiple mirrors/qualities without spending the entire
                // provider deadline walking dozens of already-working hosts.
                if (successfulServers >= 8) break;
              }
            }
          }
          if (!output.length) {
            const lastFailureAt = stage => {
              for (let index = errors.length - 1; index >= 0; index -= 1) {
                if (errors[index].stage === stage) return errors[index];
              }
              return {stage, reason: 'provider_error'};
            };
            if (!foundTitle && searchAttempts > 0 && successfulSearchCalls === 0) {
              const failure = lastFailureAt('search');
              const marker = ' [stage=' + failure.stage + '; reason=' + failure.reason + ']';
              throw new Error('NO_STREAM: Provider search could not complete.' + marker);
            }
            if (!foundEpisode && episodeLookupAttempts > 0 && successfulEpisodeLookups === 0) {
              const failure = lastFailureAt('episode_lookup');
              const marker = ' [stage=' + failure.stage + '; reason=' + failure.reason + ']';
              throw new Error('NO_STREAM: Provider episode lookup could not complete.' + marker);
            }
            const failure = foundServer
              ? (() => {
                  const extracted = lastFailureAt('stream_extraction');
                  return extracted.reason === 'provider_error'
                    ? {stage: 'stream_extraction', reason: 'empty_result'}
                    : extracted;
                })()
              : foundEpisode
                ? lastFailureAt('server_lookup')
                : foundTitle
                  ? lastFailureAt('episode_lookup')
                  : {stage: 'title_matching', reason: 'empty_result'};
            const marker = ' [stage=' + failure.stage + '; reason=' + failure.reason + ']';
            if (!foundTitle) throw new Error('NO_MATCH: This provider has no matching title. [stage=title_matching; reason=empty_result]');
            if (!foundEpisode) throw new Error('NO_MATCH: This provider has no matching episode. [stage=episode_lookup; reason=empty_result]');
            throw new Error('NO_STREAM: The provider found the episode but returned no compatible stream.' + marker);
          }
          sendMessage('TetoDone', JSON.stringify({ok: true, result: output}));
        } catch (error) {
          sendMessage('TetoDone', JSON.stringify({ok: false, error: String(error && error.message || error)}));
        }
      })();
    '''
        : _mangaProviderInvocationSource(input);
    final invocation = runtime.evaluate(
      invocationSource,
      sourceUrl: 'tetotv://provider-runner.js',
    );
    if (invocation.isError) throw StateError(invocation.stringResult);
    await runtime.dispatch();
    return await Future.any<List<Map<String, dynamic>>>([
      completed.future,
      cancellation.whenCancelled.then<List<Map<String, dynamic>>>(
        (_) => throw const WebProviderSearchCancelled(),
      ),
    ]).timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        cancellation.throwIfCancelled();
        // A declared Sub/Dub provider may return the preferred mode and then
        // stall while checking the opposite mode. Preserve already-projected
        // results rather than turning that valid provider into a total
        // timeout. The worker is still disposed immediately in finally.
        if (latestProgress.isNotEmpty) return latestProgress;
        throw TimeoutException('Provider runtime deadline exceeded.');
      },
    );
  } finally {
    disposed = true;
    for (final timer in sleepTimers.values) {
      timer.cancel();
    }
    sleepTimers.clear();
    clearedSleepIds.clear();
    runtime.dispose();
  }
}

bool _isValidAddonSleepId(String value) =>
    value.length <= 32 &&
    RegExp(r'^(?:sleep|timer)-[0-9]{1,12}$').hasMatch(value);

String _mangaProviderInvocationSource(Map<String, Object?> input) {
  final operation = jsonEncode(input['operation']);
  final query = jsonEncode(input['query']);
  final year = input['year'] is int ? input['year'] : null;
  final mangaId = jsonEncode(input['mangaId']);
  final chapterId = jsonEncode(input['chapterId']);
  return '''
    (async function() {
      try {
        const provider = new Provider();
        const providerCall = async callback => {
          try {
            return await callback();
          } finally {
            await __tetoAwaitSleeps();
          }
        };
        const boundedString = (value, maximum) =>
          typeof value === 'string' && value.length <= maximum ? value : null;
        const boundedNumber = value =>
          typeof value === 'number' && Number.isFinite(value) ? value : null;
        const projectHeaders = value => {
          if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
          const projected = {};
          let count = 0;
          let inspected = 0;
          let total = 0;
          for (const rawKey of Object.keys(value)) {
            inspected += 1;
            if (inspected > 64) break;
            if (count >= 24) break;
            const rawValue = value[rawKey];
            if (typeof rawValue !== 'string' &&
                typeof rawValue !== 'number' &&
                typeof rawValue !== 'boolean') continue;
            const key = String(rawKey);
            const headerValue = String(rawValue);
            if (!key || key.length > 80 || headerValue.length > 1024) continue;
            total += key.length + headerValue.length;
            if (total > 16 * 1024) break;
            projected[key] = headerValue;
            count += 1;
          }
          return projected;
        };
        const projectResult = (operation, value) => {
          if (!Array.isArray(value)) return [];
          const maximum = operation === 'manga-search' ? 120 : 1000;
          const projected = [];
          for (const item of value.slice(0, maximum)) {
            if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
            if (operation === 'manga-search') {
              const synonyms = Array.isArray(item.synonyms)
                ? item.synonyms.slice(0, 32)
                    .map(value => boundedString(value, 256))
                    .filter(value => value != null)
                : [];
              projected.push({
                id: boundedString(item.id, 2048),
                title: boundedString(item.title, 512),
                synonyms: synonyms,
                year: boundedNumber(item.year) ?? boundedString(item.year, 16),
                image: boundedString(item.image, 2048),
                // Current community extensions use both `headers` (the
                // original Seanime shape) and `imageHeaders` (the explicit
                // TetoTV shape). Preserve both, with the artwork-specific
                // values taking precedence, then apply Dart's header policy.
                imageHeaders: projectHeaders(Object.assign(
                  {},
                  item.headers && typeof item.headers === 'object' ? item.headers : {},
                  item.requestHeaders && typeof item.requestHeaders === 'object' ? item.requestHeaders : {},
                  item.imageHeaders && typeof item.imageHeaders === 'object' ? item.imageHeaders : {},
                )),
              });
            } else if (operation === 'manga-chapters') {
              projected.push({
                id: boundedString(item.id, 2048),
                url: boundedString(item.url, 2048),
                title: boundedString(item.title, 512),
                chapter: boundedString(item.chapter, 80),
                index: boundedNumber(item.index),
                scanlator: boundedString(item.scanlator, 160),
                language: boundedString(item.language, 32),
                rating: boundedNumber(item.rating) ?? boundedString(item.rating, 32),
                updatedAt: boundedString(item.updatedAt, 80),
              });
            } else {
              projected.push({
                url: boundedString(item.url, 2048),
                index: boundedNumber(item.index),
                headers: projectHeaders(item.headers),
              });
            }
          }
          return projected;
        };
        const operation = $operation;
        let result;
        if (operation === 'manga-search') {
          if (typeof provider.search !== 'function') {
            throw new Error('Manga provider does not implement search');
          }
          const options = {query: $query};
          const year = ${year ?? 'null'};
          if (year != null) options.year = year;
          result = await providerCall(() => provider.search(options));
        } else if (operation === 'manga-chapters') {
          if (typeof provider.findChapters !== 'function') {
            throw new Error('Manga provider does not implement findChapters');
          }
          result = await providerCall(() => provider.findChapters($mangaId));
        } else if (operation === 'manga-pages') {
          if (typeof provider.findChapterPages !== 'function') {
            throw new Error('Manga provider does not implement findChapterPages');
          }
          result = await providerCall(() => provider.findChapterPages($chapterId));
        } else {
          throw new Error('Unsupported manga provider operation');
        }
        result = projectResult(operation, result);
        const payload = JSON.stringify({ok: true, result: result});
        if (payload.length > 4 * 1024 * 1024) {
          throw new Error('Manga provider output exceeded its safe size limit');
        }
        sendMessage('TetoDone', payload);
      } catch (error) {
        const message = String(
          error && error.message || error || 'Manga provider failed'
        ).slice(0, 512);
        sendMessage('TetoDone', JSON.stringify({
          ok: false,
          error: message,
        }));
      }
    })();
  ''';
}

class AddonRuntimeNetworkBudget {
  AddonRuntimeNetworkBudget({
    this.maximumRequests = 64,
    this.maximumConcurrentRequests = 8,
    this.maximumResponseBytes = 16 * 1024 * 1024,
  });

  final int maximumRequests;
  final int maximumConcurrentRequests;
  final int maximumResponseBytes;

  final List<Completer<void>> _waiters = [];
  var _requestCount = 0;
  var _activeRequests = 0;
  var _responseBytes = 0;

  Future<void> acquire() async {
    _requestCount++;
    if (_requestCount > maximumRequests) {
      throw const FormatException(
        'Provider exceeded its network request limit.',
      );
    }
    if (_responseBytes >= maximumResponseBytes) {
      throw const FormatException(
        'Provider exceeded its total response limit.',
      );
    }
    if (_activeRequests < maximumConcurrentRequests) {
      _activeRequests++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    if (_responseBytes >= maximumResponseBytes) {
      release();
      throw const FormatException(
        'Provider exceeded its total response limit.',
      );
    }
  }

  void recordResponse(String value) {
    recordResponseBytes(utf8.encode(value).length);
  }

  void recordResponseBytes(int byteLength) {
    if (byteLength < 0) {
      throw const FormatException('Provider response length is invalid.');
    }
    _responseBytes += byteLength;
    if (_responseBytes > maximumResponseBytes) {
      throw const FormatException(
        'Provider exceeded its total response limit.',
      );
    }
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    if (_activeRequests > 0) _activeRequests--;
  }
}

const _forbiddenAddonHeaders = {
  'connection',
  'content-length',
  'host',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};

// Cross-origin redirects must not forward arbitrary addon-supplied headers.
// API credentials use many non-standard names (X-Api-Key, X-Auth-Token,
// provider-specific headers, and so on), so a credential denylist will always
// be incomplete. Keep only the small set needed for ordinary media requests.
const _crossOriginSafeAddonHeaders = {
  'accept',
  'accept-language',
  'content-type',
  'origin',
  'range',
  'referer',
  'sec-fetch-dest',
  'sec-fetch-mode',
  'sec-fetch-site',
  'user-agent',
};

// Fetch Metadata values are deliberately finite. Besides keeping the values
// browser-shaped, this prevents a newly allowlisted cross-origin header from
// becoming an arbitrary provider-controlled data channel.
const _addonFetchMetadataValues = <String, Set<String>>{
  'sec-fetch-dest': {'audio', 'empty', 'video'},
  'sec-fetch-mode': {'cors', 'navigate', 'no-cors', 'same-origin'},
  'sec-fetch-site': {'cross-site', 'none', 'same-origin', 'same-site'},
};

/// Sanitizes headers originating in untrusted add-on code before either the
/// Dart HTTP stack or a native player sees them. Hop-by-hop framing headers
/// and control characters are never forwarded.
Map<String, String> sanitizeAddonHeaders(
  Object? raw, {
  String? defaultUserAgent,
  bool stripCredentials = false,
  int maximumValueLength = 4096,
}) {
  final result = <String, String>{};
  final seen = <String>{};
  if (defaultUserAgent != null) {
    result['User-Agent'] = defaultUserAgent;
    seen.add('user-agent');
  }
  if (raw is! Map) return Map.unmodifiable(result);
  var totalLength = defaultUserAgent?.length ?? 0;
  for (final entry in raw.entries.take(24)) {
    final key = '${entry.key}'.trim();
    final lower = key.toLowerCase();
    var value = '${entry.value}'.trim();
    final allowedFetchMetadataValues = _addonFetchMetadataValues[lower];
    if (allowedFetchMetadataValues != null) {
      value = value.toLowerCase();
      if (!allowedFetchMetadataValues.contains(value)) continue;
    }
    if (key.isEmpty ||
        key.length > 80 ||
        !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(key) ||
        _forbiddenAddonHeaders.contains(lower) ||
        (stripCredentials && !_crossOriginSafeAddonHeaders.contains(lower)) ||
        seen.contains(lower) ||
        (lower == 'origin' && !_isSafeAddonMediaOrigin(value)) ||
        value.length > maximumValueLength ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      continue;
    }
    totalLength += key.length + value.length;
    if (totalLength > 16 * 1024) break;
    seen.add(lower);
    result[key] = value;
  }
  return Map.unmodifiable(result);
}

/// Allows an add-on supplied Origin only when it is already a canonical,
/// public-looking HTTPS origin. TetoTV never invents an Origin and never
/// forwards credentials with it; this only preserves metadata some media CDNs
/// require after a cross-origin manifest redirect.
bool _isSafeAddonMediaOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host.endsWith('.local')) return false;
  // Literal addresses can reveal or target a private network. Public media
  // providers use hostnames; the proxy independently validates their DNS.
  if (InternetAddress.tryParse(host) != null) return false;
  return host.contains('.');
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme == right.scheme &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

Future<Map<String, Object?>> _safeAddonRequest(
  dynamic raw, {
  Duration connectTimeout = const Duration(seconds: 6),
  Duration receiveTimeout = const Duration(seconds: 8),
  Duration? overallTimeout,
  Duration? maximumOverallTimeout,
  int maximumResponseBytes = 2 * 1024 * 1024,
  WebProviderCancellation? cancellation,
  AddonRuntimeCookieJar? cookieJar,
}) async {
  cancellation?.throwIfCancelled();
  if (raw is! Map) throw const FormatException('Invalid provider request.');
  final uri = safePublicHttpsUri(raw['url']);
  if (uri == null) {
    throw const FormatException('Provider requests must use public HTTPS.');
  }
  var currentUri = uri;
  await validatePublicNetworkTarget(currentUri);
  cancellation?.throwIfCancelled();
  final options = raw['options'] is Map ? raw['options'] as Map : const {};
  final abortSignal = options['signal'];
  if (addonRuntimeAbortSignalIsAborted(abortSignal)) {
    throw const HttpException('Provider request was aborted.');
  }
  final requestedTimeout = addonRequestTimeout(
    options['timeout'],
    abortSignal: abortSignal,
    maximum: maximumOverallTimeout ?? const Duration(seconds: 12),
  );
  final effectiveOverallTimeout = overallTimeout == null
      ? requestedTimeout
      : requestedTimeout < overallTimeout
      ? requestedTimeout
      : overallTimeout;
  final method = '${options['method'] ?? 'GET'}'.toUpperCase();
  if (!const {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  }.contains(method)) {
    throw const FormatException(
      'The provider request uses an unsupported HTTP method.',
    );
  }
  final redirectMode = '${options['redirect'] ?? 'follow'}'.toLowerCase();
  if (!const {'follow', 'manual', 'error'}.contains(redirectMode)) {
    throw const FormatException('Invalid provider redirect mode.');
  }
  final credentialsMode = '${options['credentials'] ?? 'same-origin'}'
      .toLowerCase();
  if (!const {'omit', 'same-origin', 'include'}.contains(credentialsMode)) {
    throw const FormatException('Invalid provider credentials mode.');
  }
  var headers = Map<String, String>.from(
    sanitizeAddonHeaders(
      options['headers'],
      defaultUserAgent: 'TetoTV addon runtime',
    ),
  );
  String? body;
  final rawBody = options['body'];
  if (rawBody != null) {
    body = rawBody is String ? rawBody : jsonEncode(rawBody);
    if (rawBody is! String &&
        !headers.keys.any(
          (key) => key.toLowerCase() == HttpHeaders.contentTypeHeader,
        )) {
      headers[HttpHeaders.contentTypeHeader] = 'application/json';
    }
  }
  headers = Map.unmodifiable(headers);
  if (body != null && utf8.encode(body).length > 128 * 1024) {
    throw const FormatException('Provider request body is too large.');
  }
  final dio = createPinnedPublicHttpsDio(
    BaseOptions(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      followRedirects: false,
    ),
  );
  final cancelToken = CancelToken();
  final removeCancellationListener = cancellation?.addListener(
    () => cancelToken.cancel(const WebProviderSearchCancelled()),
  );
  final overallDeadline = Timer(
    effectiveOverallTimeout,
    () => cancelToken.cancel('Provider request deadline exceeded.'),
  );
  Response<ResponseBody>? response;
  var responseBody = AddonRuntimeResponseBody.empty();
  var currentMethod = method;
  var redirected = false;
  var lastRequestHeaders = headers;
  try {
    for (var redirect = 0; ; redirect++) {
      cancellation?.throwIfCancelled();
      final requestHeaders = Map<String, String>.from(headers);
      final cookiesAllowed =
          credentialsMode == 'include' ||
          (credentialsMode == 'same-origin' && _sameOrigin(uri, currentUri));
      if (cookiesAllowed) cookieJar?.apply(currentUri, requestHeaders);
      lastRequestHeaders = Map.unmodifiable(requestHeaders);
      response = await dio.request<ResponseBody>(
        currentUri.toString(),
        data: body,
        cancelToken: cancelToken,
        options: Options(
          method: currentMethod,
          headers: lastRequestHeaders,
          responseType: ResponseType.stream,
        ),
      );
      final status = response.statusCode ?? 0;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (cookiesAllowed) cookieJar?.capture(currentUri, response.headers);
      if (!_isAddonRedirectStatus(status) || location == null) break;
      if (redirectMode == 'manual') break;
      if (redirectMode == 'error') {
        throw const HttpException(
          'Provider request received a redirect in error mode.',
        );
      }
      if (redirect >= 4) {
        throw const HttpException('Provider request exceeded redirect limit.');
      }
      await _discardAddonResponseBody(response.data);
      final redirectUri = safePublicHttpsUri(
        currentUri.resolve(location).toString(),
      );
      if (redirectUri == null) {
        throw const FormatException('Provider redirect was not public HTTPS.');
      }
      if (!_sameOrigin(currentUri, redirectUri)) {
        headers = sanitizeAddonHeaders(
          headers,
          defaultUserAgent: 'TetoTV addon runtime',
          stripCredentials: true,
        );
      }
      if ((status == 303 &&
              currentMethod != 'GET' &&
              currentMethod != 'HEAD') ||
          ((status == 301 || status == 302) && currentMethod == 'POST')) {
        currentMethod = 'GET';
        body = null;
        headers = Map.unmodifiable(
          Map<String, String>.from(headers)..removeWhere(
            (key, _) => key.toLowerCase() == HttpHeaders.contentTypeHeader,
          ),
        );
      }
      currentUri = redirectUri;
      redirected = true;
      await validatePublicNetworkTarget(currentUri);
      cancellation?.throwIfCancelled();
    }
    responseBody = await readBoundedAddonRuntimeResponseBody(
      response.data,
      maximumResponseBytes,
    );
  } finally {
    overallDeadline.cancel();
    removeCancellationListener?.call();
    dio.close(force: true);
  }
  final rawResponseHeaders = sanitizeAddonResponseHeaders(response.headers.map);
  final responseHeaders = Map<String, String>.unmodifiable({
    for (final entry in rawResponseHeaders.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.first,
  });
  return {
    'status': response.statusCode ?? 0,
    'statusText': response.statusMessage ?? '',
    'method': currentMethod,
    'url': currentUri.toString(),
    'ok': (response.statusCode ?? 0) >= 200 && (response.statusCode ?? 0) < 300,
    'redirected': redirected,
    'contentType': response.headers.value(HttpHeaders.contentTypeHeader) ?? '',
    'contentLength': responseBody.bytes.length,
    ...addonRuntimeResponseBodyWireFields(responseBody),
    // HLS expansion must reuse the post-redirect header set. In particular,
    // credentials supplied for one origin cannot follow a master-playlist
    // redirect and then leak to that other origin's variant URLs.
    'requestHeaders': lastRequestHeaders,
    'headers': responseHeaders,
    'rawHeaders': rawResponseHeaders,
    'cookies': _addonResponseCookies(response.headers),
  };
}

/// Seanime FetchOptions.timeout is expressed in seconds. Keep every request
/// inside both its requested budget and TetoTV's remaining provider deadline.
Duration addonRequestTimeout(
  Object? raw, {
  Object? abortSignal,
  Duration maximum = const Duration(seconds: 12),
}) {
  final numeric = raw is num ? raw.toDouble() : double.tryParse('$raw');
  var requested = numeric != null && numeric.isFinite && numeric > 0
      ? Duration(milliseconds: (numeric * 1000).round())
      : maximum;
  final abortMilliseconds = addonRuntimeAbortSignalTimeoutMilliseconds(
    abortSignal,
  );
  if (abortMilliseconds != null) {
    final signalDuration = Duration(milliseconds: abortMilliseconds);
    if (signalDuration < requested) requested = signalDuration;
  }
  const minimum = Duration(milliseconds: 100);
  if (maximum <= Duration.zero) return minimum;
  if (requested < minimum) return minimum < maximum ? minimum : maximum;
  return requested > maximum ? maximum : requested;
}

/// Reads only the private, numeric field emitted by TetoTV's AbortSignal shim.
/// Arbitrary signal fields cannot extend the Dart-side hard deadline.
int? addonRuntimeAbortSignalTimeoutMilliseconds(Object? raw) {
  if (raw is! Map) return null;
  final value = raw['__tetoTimeoutMilliseconds'];
  final numeric = value is num ? value.toDouble() : double.tryParse('$value');
  if (numeric == null || !numeric.isFinite || numeric <= 0) return null;
  return numeric.ceil().clamp(1, 12000);
}

bool addonRuntimeAbortSignalIsAborted(Object? raw) =>
    raw is Map && raw['aborted'] == true;

/// Seanime's `$sleep(milliseconds)` is synchronous from a provider author's
/// perspective, but TetoTV implements it as a host-backed promise barrier so a
/// sleeping addon does not block cancellation or the Dart isolate. Individual
/// waits are clamped while the aggregate provider runtime remains protected by
/// its normal deadline.
Duration addonSleepDuration(
  Object? raw, {
  required Duration remaining,
  Duration maximum = const Duration(seconds: 1),
}) {
  final numeric = raw is num ? raw.toDouble() : double.tryParse('$raw');
  if (numeric == null || !numeric.isFinite || numeric <= 0) {
    return Duration.zero;
  }
  if (remaining <= Duration.zero || maximum <= Duration.zero) {
    return Duration.zero;
  }
  final requested = Duration(milliseconds: numeric.ceil());
  final bounded = requested > maximum ? maximum : requested;
  return bounded > remaining ? remaining : bounded;
}

bool _isAddonRedirectStatus(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

/// Bounds response metadata before it crosses from an untrusted server into
/// the provider VM. Multiple values remain separate to match Seanime's
/// `rawHeaders` contract; [FetchResponse.headers] uses the first value.
Map<String, List<String>> sanitizeAddonResponseHeaders(
  Object? raw, {
  int maximumValueLength = 4096,
}) {
  if (raw is! Map) return const {};
  final result = <String, List<String>>{};
  final seen = <String>{};
  var totalLength = 0;
  for (final entry in raw.entries.take(48)) {
    final key = '${entry.key}'.trim();
    final lower = key.toLowerCase();
    if (key.isEmpty ||
        key.length > 80 ||
        !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(key) ||
        seen.contains(lower)) {
      continue;
    }
    final sourceValues = entry.value is Iterable
        ? (entry.value as Iterable)
        : [entry.value];
    final values = <String>[];
    for (final rawValue in sourceValues.take(16)) {
      final value = '$rawValue'.trim();
      if (value.length > maximumValueLength ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        continue;
      }
      totalLength += key.length + value.length;
      if (totalLength > 32 * 1024) break;
      values.add(value);
    }
    if (values.isEmpty) continue;
    seen.add(lower);
    result[key] = List.unmodifiable(values);
    if (totalLength > 32 * 1024) break;
  }
  return Map.unmodifiable(result);
}

Map<String, String> _addonResponseCookies(Headers headers) {
  return parseAddonResponseCookies(
    headers.map[HttpHeaders.setCookieHeader] ?? const [],
  );
}

/// Invocation-local cookie storage for providers using Fetch
/// `credentials: include` or the default same-origin mode.
///
/// The jar accepts an RFC-style parent-domain attribute only when the response
/// host domain-matches it, and sends it only to matching HTTPS hosts and paths.
/// Since the app intentionally carries no public-suffix database, a domain
/// cookie is additionally pinned to the host which set it and that host's
/// descendants. This prevents `Domain=co.uk`-style sibling credential leaks
/// while retaining providers that set `.example.com` from `api.example.com`.
/// It has no persistence path and is discarded with each provider invocation.
/// Public solely so its security contract can be tested without QuickJS.
class AddonRuntimeCookieJar {
  static const _maximumCookies = 32;

  final LinkedHashMap<String, _StoredAddonCookie> _cookies = LinkedHashMap();
  var _sequence = 0;

  void capture(Uri uri, Headers headers) {
    if (!_isSecureAddonCookieUri(uri)) return;
    final values = headers.map.entries
        .where(
          (entry) => entry.key.toLowerCase() == HttpHeaders.setCookieHeader,
        )
        .expand((entry) => entry.value)
        .take(_maximumCookies);
    for (final raw in values) {
      if (raw.length > 8192) continue;
      try {
        final cookie = Cookie.fromSetCookieValue(raw);
        final name = cookie.name.trim();
        final requestHost = uri.host.toLowerCase();
        final rawDomain = cookie.domain?.trim();
        final hostOnly = rawDomain == null || rawDomain.isEmpty;
        final domain = hostOnly
            ? requestHost
            : _normalizeAddonCookieDomain(rawDomain);
        final path = _normalizeAddonCookiePath(cookie.path, uri);
        if (name.isEmpty ||
            name.length > 256 ||
            !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name) ||
            cookie.value.length > 4096 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(cookie.value) ||
            domain == null ||
            path == null ||
            (!hostOnly &&
                !addonRuntimeCookieDomainMatches(requestHost, domain))) {
          continue;
        }
        final key = _addonCookieStorageKey(
          name: name,
          domain: domain,
          sourceHost: requestHost,
          path: path,
          hostOnly: hostOnly,
        );
        if (cookie.maxAge != null && cookie.maxAge! <= 0) {
          _cookies.remove(key);
          continue;
        }
        final now = DateTime.now();
        final maxAge = cookie.maxAge;
        final expires = maxAge != null
            ? now.add(Duration(seconds: maxAge.clamp(1, 315360000)))
            : cookie.expires;
        if (expires != null && !expires.isAfter(now)) {
          _cookies.remove(key);
          continue;
        }
        // Updating a cookie makes it the newest bounded entry.
        _cookies.remove(key);
        _cookies[key] = _StoredAddonCookie(
          name: name,
          value: cookie.value,
          domain: domain,
          sourceHost: requestHost,
          hostOnly: hostOnly,
          path: path,
          expires: expires,
          sequence: _sequence++,
        );
        while (_cookies.length > _maximumCookies) {
          _cookies.remove(_cookies.keys.first);
        }
      } on FormatException {
        // A malformed cookie cannot suppress an otherwise valid response.
      }
    }
  }

  void apply(Uri uri, Map<String, String> headers) {
    if (!_isSecureAddonCookieUri(uri) || _cookies.isEmpty) return;
    final now = DateTime.now();
    final matching = <_StoredAddonCookie>[];
    final expired = <String>[];
    for (final entry in _cookies.entries) {
      final cookie = entry.value;
      if (cookie.expires != null && !cookie.expires!.isAfter(now)) {
        expired.add(entry.key);
        continue;
      }
      final hostMatches = cookie.hostOnly
          ? uri.host.toLowerCase() == cookie.domain
          : addonRuntimeCookieDomainMatches(uri.host, cookie.domain) &&
                addonRuntimeCookieDomainMatches(uri.host, cookie.sourceHost);
      if (!hostMatches ||
          !addonRuntimeCookiePathMatches(uri.path, cookie.path)) {
        continue;
      }
      matching.add(cookie);
    }
    for (final key in expired) {
      _cookies.remove(key);
    }
    if (matching.isEmpty) return;
    // RFC 6265 recommends longer (more specific) paths first. Preserve
    // creation order for otherwise equivalent cookies.
    matching.sort((left, right) {
      final byPath = right.path.length.compareTo(left.path.length);
      return byPath != 0 ? byPath : left.sequence.compareTo(right.sequence);
    });
    final values = matching
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .toList(growable: false);
    final existingKey = headers.keys.cast<String?>().firstWhere(
      (key) => key?.toLowerCase() == HttpHeaders.cookieHeader,
      orElse: () => null,
    );
    final existing = existingKey == null ? null : headers[existingKey];
    final combined = [
      if (existing != null && existing.trim().isNotEmpty) existing.trim(),
      ...values,
    ].join('; ');
    if (combined.length > 4096) return;
    if (existingKey != null) headers.remove(existingKey);
    headers[HttpHeaders.cookieHeader] = combined;
  }
}

class _StoredAddonCookie {
  const _StoredAddonCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.sourceHost,
    required this.hostOnly,
    required this.path,
    required this.sequence,
    this.expires,
  });

  final String name;
  final String value;
  final String domain;
  final String sourceHost;
  final bool hostOnly;
  final String path;
  final int sequence;
  final DateTime? expires;
}

bool _isSecureAddonCookieUri(Uri uri) =>
    uri.scheme.toLowerCase() == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

String? _normalizeAddonCookieDomain(String raw) {
  final domain = raw.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  if (domain.isEmpty ||
      domain.length > 253 ||
      domain.endsWith('.') ||
      InternetAddress.tryParse(domain) != null ||
      !RegExp(
        r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
      ).hasMatch(domain)) {
    return null;
  }
  return domain;
}

String? _normalizeAddonCookiePath(String? raw, Uri requestUri) {
  final value = raw?.trim();
  if (value != null &&
      value.startsWith('/') &&
      value.length <= 1024 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return value;
  }
  final requestPath = requestUri.path;
  if (!requestPath.startsWith('/') || requestPath == '/') return '/';
  final lastSlash = requestPath.lastIndexOf('/');
  return lastSlash <= 0 ? '/' : requestPath.substring(0, lastSlash);
}

String _addonCookieStorageKey({
  required String name,
  required String domain,
  required String sourceHost,
  required String path,
  required bool hostOnly,
}) =>
    '${hostOnly ? 'h' : 'd'}\u0001$sourceHost\u0001$domain\u0001$path\u0001$name';

/// RFC-style cookie domain-match used by the invocation-local runtime jar.
/// Parent domains are accepted, while unrelated/lookalike hosts and IP suffix
/// matches are rejected.
bool addonRuntimeCookieDomainMatches(String requestHost, String cookieDomain) {
  final host = requestHost.trim().toLowerCase().replaceFirst(
    RegExp(r'\.$'),
    '',
  );
  final domain = cookieDomain.trim().toLowerCase().replaceFirst(
    RegExp(r'^\.'),
    '',
  );
  if (host.isEmpty || domain.isEmpty) return false;
  if (host == domain) return true;
  if (!domain.contains('.')) return false;
  if (InternetAddress.tryParse(host) != null ||
      InternetAddress.tryParse(domain) != null) {
    return false;
  }
  return host.endsWith('.$domain');
}

/// RFC-style cookie path-match: `/foo` matches `/foo` and `/foo/bar`, but not
/// `/foobar`. Invalid/relative request paths are treated as `/`.
bool addonRuntimeCookiePathMatches(String requestPath, String cookiePath) {
  final request = requestPath.startsWith('/') ? requestPath : '/';
  final cookie = cookiePath.startsWith('/') ? cookiePath : '/';
  if (request == cookie) return true;
  if (!request.startsWith(cookie)) return false;
  if (cookie.endsWith('/')) return true;
  return request.length > cookie.length && request[cookie.length] == '/';
}

/// Parses only bounded, syntactically safe cookie name/value pairs. Cookie
/// attributes stay out of the provider-facing record, matching Seanime.
Map<String, String> parseAddonResponseCookies(Iterable<String> values) {
  final result = <String, String>{};
  for (final raw in values) {
    if (result.length >= 64) break;
    if (raw.length > 8192) continue;
    try {
      final cookie = Cookie.fromSetCookieValue(raw);
      if (cookie.name.isEmpty ||
          cookie.name.length > 256 ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(cookie.name) ||
          cookie.value.length > 4096 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(cookie.value)) {
        continue;
      }
      result[cookie.name] = cookie.value;
    } on FormatException {
      // Ignore a malformed cookie without hiding the otherwise valid response.
    }
  }
  return Map.unmodifiable(result);
}

/// Bounded response bytes plus the legacy UTF-8 text projection used by
/// FetchResponse.text()/json(). Raw bytes remain authoritative for
/// FetchResponse.body and are never reconstructed from a lossy String.
class AddonRuntimeResponseBody {
  const AddonRuntimeResponseBody({required this.bytes, required this.text});

  AddonRuntimeResponseBody.empty() : bytes = Uint8List(0), text = '';

  final Uint8List bytes;
  final String text;
}

Future<AddonRuntimeResponseBody> readBoundedAddonRuntimeResponseBody(
  ResponseBody? body,
  int maximumBytes,
) async {
  if (maximumBytes < 0) {
    throw const FormatException('Provider response limit is invalid.');
  }
  if (body == null) return AddonRuntimeResponseBody.empty();
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in body.stream) {
    length += chunk.length;
    if (length > maximumBytes) {
      throw const FormatException('Provider response is too large.');
    }
    bytes.add(chunk);
  }
  final value = bytes.takeBytes();
  return AddonRuntimeResponseBody(
    bytes: value,
    text: utf8.decode(value, allowMalformed: true),
  );
}

/// JSON-safe transport fields for the isolate/QuickJS boundary. Base64 adds
/// no authority and is decoded only inside the bounded provider runtime.
Map<String, Object> addonRuntimeResponseBodyWireFields(
  AddonRuntimeResponseBody body,
) => Map.unmodifiable({
  'body': body.text,
  'bodyBase64': base64Encode(body.bytes),
  'bodyByteLength': body.bytes.length,
});

Future<void> _discardAddonResponseBody(ResponseBody? body) async {
  if (body == null) return;
  final subscription = body.stream.listen((_) {});
  await subscription.cancel();
}

String _safeError(Object error) {
  final value = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
  return value.length > 180 ? '${value.substring(0, 180)}…' : value;
}

const _networkBootstrap = r'''
  const __tetoPending = Object.create(null);
  let __tetoRequestId = 0;
  async function fetch(url, options) {
    // Official Seanime providers call `$sleep(ms)` without awaiting it. Treat
    // those calls as a barrier before the next request so rate-limit pacing is
    // preserved without synchronously blocking QuickJS.
    if (typeof __tetoAwaitSleeps === 'function') await __tetoAwaitSleeps();
    return new Promise((resolve, reject) => {
      const id = String(++__tetoRequestId);
      __tetoPending[id] = {resolve, reject};
      let requestUrl = String(url);
      const seanimeProxy = 'http://127.0.0.1:43211/api/v1/proxy?url=';
      if (requestUrl.startsWith(seanimeProxy)) {
        try { requestUrl = decodeURIComponent(requestUrl.slice(seanimeProxy.length)); } catch (_) {}
      }
      sendMessage('TetoNetwork', JSON.stringify({id, url: requestUrl, options: options || {}}));
    });
  }
  function __tetoCreateFetchResponse(response) {
    const headers = Object.assign({}, response.headers || {});
    const headerValue = name => {
      const target = String(name).toLowerCase();
      for (const key of Object.keys(headers)) {
        if (key.toLowerCase() === target) return headers[key];
      }
      return null;
    };
    // Preserve Seanime's plain header record while remaining friendly to
    // providers written against the browser Headers API.
    Object.defineProperty(headers, 'get', {
      configurable: true,
      enumerable: false,
      value: headerValue,
    });
    const bodyText = String(response.body || '');
    const encodedBody = String(response.bodyBase64 || '');
    const declaredBodyLength = Number(response.bodyByteLength || 0);
    if (!Number.isFinite(declaredBodyLength) || declaredBodyLength < 0 ||
        declaredBodyLength > 2 * 1024 * 1024 ||
        encodedBody.length > 2796204) {
      throw new Error('Provider response exceeds its byte limit');
    }
    const binaryBody = atob(encodedBody);
    if (binaryBody.length !== declaredBodyLength) {
      throw new Error('Provider response byte payload is invalid');
    }
    const body = new Uint8Array(binaryBody.length);
    for (let index = 0; index < binaryBody.length; index++) {
      body[index] = binaryBody.charCodeAt(index) & 255;
    }
    // Preserve the most common legacy direct-body coercion without changing
    // the byte-indexable Seanime contract used by Uint8Array.from().
    Object.defineProperty(body, 'toString', {
      configurable: true,
      enumerable: false,
      value: () => bodyText,
    });
    let parsedJson = null;
    try { parsedJson = bodyText ? JSON.parse(bodyText) : null; } catch (_) {}
    return {
      ok: response.ok === true || (response.status >= 200 && response.status < 300),
      status: response.status,
      statusText: String(response.statusText || ''),
      method: String(response.method || 'GET'),
      rawHeaders: Object.assign({}, response.rawHeaders || {}),
      url: String(response.url || ''),
      headers,
      cookies: Object.assign({}, response.cookies || {}),
      redirected: response.redirected === true,
      contentType: String(response.contentType || headerValue('content-type') || ''),
      contentLength: Number(response.contentLength || 0),
      body,
      bodyText,
      // Seanime's extension FetchResponse intentionally exposes synchronous
      // body readers. `await response.text()` still works because awaiting a
      // non-Promise value is valid JavaScript.
      text: () => bodyText,
      json: () => parsedJson,
      arrayBuffer: () => body.buffer.slice(
        body.byteOffset, body.byteOffset + body.byteLength
      ),
    };
  }
  function __tetoNetworkFinish(id, response) {
    const pending = __tetoPending[id]; if (!pending) return;
    delete __tetoPending[id];
    pending.resolve(__tetoCreateFetchResponse(response));
  }
  function __tetoNetworkFail(id, message) {
    const pending = __tetoPending[id]; if (!pending) return;
    delete __tetoPending[id]; pending.reject(new Error(message));
  }
  function atob(value) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
    let output = '', buffer = 0, bits = 0;
    value = String(value).replace(/[^A-Za-z0-9+/=]/g, '');
    for (let i = 0; i < value.length; i++) {
      const n = chars.indexOf(value[i]); if (n < 0 || n === 64) break;
      buffer = (buffer << 6) | n; bits += 6;
      if (bits >= 8) { bits -= 8; output += String.fromCharCode((buffer >> bits) & 255); }
    }
    return output;
  }
  function btoa(value) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
    let output = '', index = 0;
    value = String(value);
    while (index < value.length) {
      const a = value.charCodeAt(index++) & 255;
      const b = index < value.length ? value.charCodeAt(index++) & 255 : NaN;
      const c = index < value.length ? value.charCodeAt(index++) & 255 : NaN;
      output += chars[a >> 2];
      output += chars[((a & 3) << 4) | (b >> 4)];
      output += Number.isNaN(b) ? '=' : chars[((b & 15) << 2) | (c >> 6)];
      output += Number.isNaN(c) ? '=' : chars[c & 63];
    }
    return output;
  }
''';

const _seanimeCompatibilityBootstrap = r'''
  if (typeof console === 'undefined') {
    globalThis.console = {};
  }
  for (const method of ['log', 'info', 'warn', 'error', 'debug', 'trace', 'table', 'assert']) {
    if (typeof globalThis.console[method] !== 'function') {
      globalThis.console[method] = function() {};
    }
  }

  // Marketplace providers are authored against browser/Node runtimes that
  // are not always identical to the embedded QuickJS build. These bounded
  // string polyfills cover common title-normalization calls without exposing
  // filesystem, process, or unrestricted network APIs to third-party code.
  if (typeof String.prototype.normalize !== 'function') {
    Object.defineProperty(String.prototype, 'normalize', {
      value: function() { return String(this); },
      configurable: true,
      writable: true,
    });
  }
  if (typeof String.prototype.replaceAll !== 'function') {
    Object.defineProperty(String.prototype, 'replaceAll', {
      value: function(search, replacement) {
        if (search instanceof RegExp) {
          if (!search.global) throw new TypeError('replaceAll RegExp must be global');
          return String(this).replace(search, replacement);
        }
        return String(this).split(String(search)).join(String(replacement));
      },
      configurable: true,
      writable: true,
    });
  }

  // Working Seanime providers use AbortSignal.timeout(ms) as a request hint.
  // Keep only the bounded timeout/aborted state enumerable so it can cross the
  // JSON bridge; Dart remains the authority for the hard request deadline.
  const __TetoAbortSignal = class AbortSignal {
    constructor(timeoutMilliseconds) {
      const numeric = timeoutMilliseconds == null
        ? Number.NaN : Number(timeoutMilliseconds);
      const bounded = Number.isFinite(numeric)
        ? Math.max(1, Math.min(12000, Math.ceil(numeric)))
        : null;
      Object.defineProperty(this, '__tetoTimeoutMilliseconds', {
        value: bounded,
        enumerable: true,
        configurable: false,
        writable: false,
      });
      this.aborted = false;
    }
    static timeout(milliseconds) {
      return new __TetoAbortSignal(milliseconds);
    }
    throwIfAborted() {
      if (this.aborted) throw new Error('Request aborted');
    }
  };
  if (typeof AbortSignal === 'undefined') {
    globalThis.AbortSignal = __TetoAbortSignal;
  } else if (typeof AbortSignal.timeout !== 'function') {
    Object.defineProperty(AbortSignal, 'timeout', {
      configurable: true,
      value: milliseconds => new __TetoAbortSignal(milliseconds),
    });
  }
  if (typeof AbortController === 'undefined') {
    globalThis.AbortController = class AbortController {
      constructor() { this.signal = new __TetoAbortSignal(null); }
      abort() { this.signal.aborted = true; }
    };
  }

  // Seanime exposes a small Node-compatible Buffer surface to providers.
  // Some marketplace extensions keep this as their base64 fallback even when
  // `atob` is available, so provide the same byte-indexable result and UTF-8
  // decoding behavior without importing Node's much larger runtime.
  if (typeof Buffer === 'undefined') {
    globalThis.Buffer = class Buffer extends Uint8Array {
      static from(value, encoding) {
        if (typeof value === 'string') {
          const normalized = String(encoding || 'utf8').toLowerCase().replace(/[-_]/g, '');
          if (normalized === 'base64') {
            const decoded = atob(value.replace(/-/g, '+').replace(/_/g, '/'));
            const bytes = new Buffer(decoded.length);
            for (let index = 0; index < decoded.length; index++) {
              bytes[index] = decoded.charCodeAt(index) & 255;
            }
            return bytes;
          }
          if (normalized === 'hex') {
            const clean = value.replace(/[^0-9a-f]/gi, '');
            const bytes = new Buffer(Math.floor(clean.length / 2));
            for (let index = 0; index < bytes.length; index++) {
              bytes[index] = parseInt(clean.slice(index * 2, index * 2 + 2), 16);
            }
            return bytes;
          }
          const encoded = unescape(encodeURIComponent(value));
          const bytes = new Buffer(encoded.length);
          for (let index = 0; index < encoded.length; index++) {
            bytes[index] = encoded.charCodeAt(index) & 255;
          }
          return bytes;
        }
        if (value instanceof ArrayBuffer) return new Buffer(new Uint8Array(value));
        if (ArrayBuffer.isView(value)) {
          return new Buffer(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
        }
        return new Buffer(value == null ? 0 : value);
      }

      static alloc(size, fill) {
        const bytes = new Buffer(Math.max(0, Number(size) || 0));
        if (fill != null) bytes.fill(typeof fill === 'number' ? fill : String(fill).charCodeAt(0));
        return bytes;
      }

      equals(other) {
        if (!other || this.length !== other.length) return false;
        for (let index = 0; index < this.length; index++) {
          if (this[index] !== other[index]) return false;
        }
        return true;
      }

      toString(encoding) {
        const normalized = String(encoding || 'utf8').toLowerCase().replace(/[-_]/g, '');
        if (normalized === 'base64') {
          let binary = '';
          for (let index = 0; index < this.length; index++) binary += String.fromCharCode(this[index]);
          return btoa(binary);
        }
        if (normalized === 'hex') {
          return Array.from(this).map(byte => byte.toString(16).padStart(2, '0')).join('');
        }
        let escaped = '';
        for (let index = 0; index < this.length; index++) {
          escaped += '%' + this[index].toString(16).padStart(2, '0');
        }
        try { return decodeURIComponent(escaped); } catch (_) {
          return Array.from(this).map(byte => String.fromCharCode(byte)).join('');
        }
      }
    };
    // Avoid class-field syntax because the packaged QuickJS engine supports a
    // wider range of extension payloads than it does newer JavaScript syntax.
    globalThis.Buffer.poolSize = 8192;
  }

  // Seanime's CryptoJS encoder contract returns byte-indexable data. The
  // bundled CryptoJS implementation returns its native WordArray instead.
  // Decorate that same object rather than replacing it with a plain array so
  // existing CryptoJS AES/encoder calls retain `words`, `sigBytes`, and all
  // WordArray methods while providers can safely use `.length` and `[index]`.
  if (typeof CryptoJS !== 'undefined' && CryptoJS.enc && CryptoJS.enc.Base64 &&
      !CryptoJS.enc.Base64.__tetoByteCompatible) {
    const originalBase64Parse = CryptoJS.enc.Base64.parse;
    CryptoJS.enc.Base64.parse = function(input) {
      const wordArray = originalBase64Parse.call(this, String(input || ''));
      const length = Math.max(0, Number(wordArray.sigBytes) || 0);
      Object.defineProperty(wordArray, 'length', {
        value: length, writable: false, configurable: true, enumerable: false,
      });
      for (let index = 0; index < length; index++) {
        Object.defineProperty(wordArray, index, {
          value: (wordArray.words[index >>> 2] >>> (24 - (index % 4) * 8)) & 255,
          writable: false,
          configurable: true,
          enumerable: true,
        });
      }
      return wordArray;
    };
    Object.defineProperty(CryptoJS.enc.Base64, '__tetoByteCompatible', {
      value: true, enumerable: false,
    });
  }

  if (typeof URLSearchParams === 'undefined') {
    globalThis.URLSearchParams = class URLSearchParams {
      constructor(input, onChange) {
        this.pairs = [];
        this.onChange = typeof onChange === 'function' ? onChange : function() {};
        if (typeof input === 'string') {
          String(input).replace(/^\?/, '').split('&').forEach(part => {
            if (!part) return;
            const split = part.indexOf('=');
            const decode = value => decodeURIComponent(String(value).replace(/\+/g, ' '));
            this.pairs.push([
              decode(split < 0 ? part : part.slice(0, split)),
              decode(split < 0 ? '' : part.slice(split + 1)),
            ]);
          });
        } else if (Array.isArray(input)) {
          input.forEach(entry => this.pairs.push([String(entry[0]), String(entry[1])]));
        } else if (input && typeof input === 'object') {
          Object.keys(input).forEach(key => this.pairs.push([String(key), String(input[key])]));
        }
      }
      changed() { this.onChange(this.toString()); }
      append(key, value) { this.pairs.push([String(key), String(value)]); this.changed(); }
      set(key, value) {
        const target = String(key);
        const next = [];
        let replaced = false;
        this.pairs.forEach(entry => {
          if (entry[0] !== target) next.push(entry);
          else if (!replaced) { next.push([target, String(value)]); replaced = true; }
        });
        if (!replaced) next.push([target, String(value)]);
        this.pairs = next;
        this.changed();
      }
      get(key) {
        const item = this.pairs.find(entry => entry[0] === String(key));
        return item ? item[1] : null;
      }
      getAll(key) {
        return this.pairs.filter(entry => entry[0] === String(key)).map(entry => entry[1]);
      }
      has(key) { return this.pairs.some(entry => entry[0] === String(key)); }
      delete(key) { this.pairs = this.pairs.filter(entry => entry[0] !== String(key)); this.changed(); }
      sort() { this.pairs.sort((left, right) => left[0].localeCompare(right[0])); this.changed(); }
      forEach(callback) { this.pairs.forEach(entry => callback(entry[1], entry[0], this)); }
      entries() { return this.pairs[Symbol.iterator](); }
      keys() { return this.pairs.map(entry => entry[0])[Symbol.iterator](); }
      values() { return this.pairs.map(entry => entry[1])[Symbol.iterator](); }
      [Symbol.iterator]() { return this.entries(); }
      toString() {
        return this.pairs.map(entry => encodeURIComponent(entry[0]) + '=' + encodeURIComponent(entry[1])).join('&');
      }
    };
  }

  if (typeof URL === 'undefined') {
    globalThis.URL = class URL {
      constructor(value, base) {
        const input = String(value || '');
        let absolute = input;
        if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(absolute)) {
          const baseMatch = /^([a-z][a-z0-9+.-]*:)\/\/([^/?#]+)([^?#]*)(?:\?[^#]*)?(?:#.*)?$/i.exec(String(base || ''));
          if (!baseMatch) throw new TypeError('Invalid URL');
          const origin = baseMatch[1] + '//' + baseMatch[2];
          if (absolute.startsWith('//')) absolute = baseMatch[1] + absolute;
          else if (absolute.startsWith('/')) absolute = origin + absolute;
          else if (absolute.startsWith('?') || absolute.startsWith('#')) {
            absolute = origin + (baseMatch[3] || '/') + absolute;
          } else {
            const directory = (baseMatch[3] || '/').replace(/[^/]*$/, '');
            absolute = origin + directory + absolute;
          }
        }
        const match = /^([a-z][a-z0-9+.-]*):\/\/([^/?#]+)([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/i.exec(absolute);
        if (!match) throw new TypeError('Invalid URL');
        this.protocol = match[1] ? match[1] + ':' : '';
        this.host = match[2] || '';
        this.hostname = this.host.replace(/^\[|\]$/g, '').split(':')[0];
        this.port = this.host.includes(':') ? this.host.split(':').pop() : '';
        this.origin = this.protocol && this.host ? this.protocol + '//' + this.host : '';
        const path = (match[3] || '/').split('/').reduce((parts, part) => {
          if (part === '..') parts.pop();
          else if (part !== '.') parts.push(part);
          return parts;
        }, []).join('/');
        this.pathname = path.startsWith('/') ? path : '/' + path;
        this.search = match[4] ? '?' + match[4] : '';
        this.hash = match[5] ? '#' + match[5] : '';
        this.sync = () => {
          this.href = this.origin + this.pathname + this.search + this.hash;
        };
        this.searchParams = new URLSearchParams(match[4] || '', query => {
          this.search = query ? '?' + query : '';
          this.sync();
        });
        this.sync();
      }
      toString() { return this.href; }
      toJSON() { return this.href; }
    };
  }

  function __tetoElements(value) {
    if (value == null) return [];
    if (Array.isArray(value.__tetoNodes)) return value.__tetoNodes.slice();
    if (Array.isArray(value)) return value.filter(Boolean);
    if (typeof value === 'string') return Array.from(__tetoParseDocument(value).children || []);
    if (typeof value.length === 'number' && !value.nodeType) return Array.from(value).filter(Boolean);
    return [value];
  }

  function __tetoUnique(values) {
    return values.filter((value, index, all) => value && all.indexOf(value) === index);
  }

  function __tetoMatches(node, selector) {
    if (!node || node.nodeType !== 1 || typeof node.matches !== 'function') return false;
    try { return node.matches(String(selector || '*')); } catch (_) { return false; }
  }

  function __tetoSelect(root, selector) {
    let query = String(selector || '*');
    let contains = null;
    const match = /:contains\((?:"([^"]*)"|'([^']*)'|([^)]*))\)/.exec(query);
    if (match) {
      contains = match[1] || match[2] || match[3] || '';
      query = query.replace(match[0], '') || '*';
    }
    let results = [];
    try { results = Array.from(root.querySelectorAll(query)); } catch (_) { return []; }
    return contains == null
      ? results
      : results.filter(node => String(node.textContent || '').includes(contains));
  }

  function __tetoSelection(value, previous) {
    const elements = __tetoUnique(__tetoElements(value));
    const selection = {};
    Object.defineProperty(selection, '__tetoNodes', {value: elements, enumerable: false});
    Object.defineProperty(selection, '__tetoPrevious', {value: previous || null, enumerable: false});
    elements.forEach((node, index) => {
      Object.defineProperty(selection, index, {value: node, enumerable: false});
    });
    selection.toArray = () => elements.slice();
    selection.get = index => index == null ? elements.slice() : elements[index < 0 ? elements.length + index : index];
    selection.length = () => elements.length;
    selection.eq = index => __tetoSelection(selection.get(index), selection);
    selection.first = () => selection.eq(0);
    selection.last = () => selection.eq(-1);
    selection.each = callback => {
      elements.forEach((node, index) => {
        const item = __tetoSelection(node, selection);
        callback.call(item, index, item);
      });
      return selection;
    };
    selection.map = callback => elements.map((node, index) => {
      const item = __tetoSelection(node, selection);
      return callback.call(item, index, item);
    });
    selection.text = () => elements.map(node => node.textContent || '').join('');
    selection.html = () => elements[0] ? (elements[0].innerHTML ?? null) : null;
    selection.attr = name => {
      if (!elements[0] || typeof elements[0].getAttribute !== 'function') return undefined;
      const value = elements[0].getAttribute(name);
      return value == null ? undefined : value;
    };
    selection.attrs = () => {
      const result = {};
      Array.from((elements[0] && elements[0].attributes) || []).forEach(attribute => {
        result[attribute.name] = attribute.value;
      });
      return result;
    };
    selection.data = name => {
      if (name != null) {
        return selection.attr('data-' + String(name).replace(/[A-Z]/g, letter => '-' + letter.toLowerCase()));
      }
      const result = {};
      Object.keys(selection.attrs()).filter(key => key.startsWith('data-')).forEach(key => {
        result[key] = selection.attrs()[key];
      });
      return result;
    };
    selection.val = () => elements[0] ? elements[0].value : undefined;
    selection.hasClass = name => !!(elements[0] && elements[0].classList && elements[0].classList.contains(name));
    selection.find = selector => __tetoSelection(
      elements.flatMap(node => __tetoSelect(node, selector)), selection
    );
    selection.children = selector => {
      const children = elements.flatMap(node => Array.from(node.children || []));
      return __tetoSelection(
        selector ? children.filter(node => __tetoMatches(node, selector)) : children,
        selection,
      );
    };
    selection.contents = () => __tetoSelection(
      elements.flatMap(node => Array.from(node.childNodes || [])), selection
    );
    selection.contentsFiltered = selector => String(selector || '')
      ? selection.children(selector)
      : selection.contents();
    selection.parent = selector => {
      const parents = elements.map(node => node.parentElement).filter(Boolean);
      return __tetoSelection(
        selector ? parents.filter(node => __tetoMatches(node, selector)) : parents,
        selection,
      );
    };
    selection.parents = selector => {
      const parents = [];
      elements.forEach(node => {
        for (let parent = node.parentElement; parent; parent = parent.parentElement) {
          if (!selector || __tetoMatches(parent, selector)) parents.push(parent);
        }
      });
      return __tetoSelection(parents, selection);
    };
    selection.parentsUntil = (selector, until) => {
      const parents = [];
      elements.forEach(node => {
        for (let parent = node.parentElement; parent; parent = parent.parentElement) {
          if (__tetoMatches(parent, until || selector)) break;
          if (!until || __tetoMatches(parent, selector)) parents.push(parent);
        }
      });
      return __tetoSelection(parents, selection);
    };
    selection.closest = selector => {
      const matches = [];
      if (!selector) return __tetoSelection(matches, selection);
      elements.forEach(node => {
        for (let current = node; current; current = current.parentElement) {
          if (__tetoMatches(current, selector)) { matches.push(current); break; }
        }
      });
      return __tetoSelection(matches, selection);
    };
    selection.filter = selector => __tetoSelection(elements.filter((node, index) =>
      typeof selector === 'function'
        ? !!selector(index, __tetoSelection(node, selection))
        : __tetoMatches(node, selector)
    ), selection);
    selection.not = selector => __tetoSelection(elements.filter((node, index) =>
      typeof selector === 'function'
        ? !selector(index, __tetoSelection(node, selection))
        : !__tetoMatches(node, selector)
    ), selection);
    selection.is = selector => elements.some((node, index) =>
      typeof selector === 'function'
        ? !!selector(index, __tetoSelection(node, selection))
        : __tetoMatches(node, selector)
    );
    selection.has = selector => __tetoSelection(elements.filter(node =>
      __tetoSelect(node, selector).length > 0
    ), selection);
    const sibling = (direction, selector) => {
      const values = elements.map(node => node[direction]).filter(Boolean);
      return __tetoSelection(
        selector ? values.filter(node => __tetoMatches(node, selector)) : values,
        selection,
      );
    };
    const siblingAll = (direction, selector, until) => {
      const values = [];
      elements.forEach(node => {
        for (let current = node[direction]; current; current = current[direction]) {
          if (until && __tetoMatches(current, until)) break;
          if (!selector || __tetoMatches(current, selector)) values.push(current);
        }
      });
      return __tetoSelection(values, selection);
    };
    selection.next = selector => sibling('nextElementSibling', selector);
    selection.prev = selector => sibling('previousElementSibling', selector);
    selection.nextAll = selector => siblingAll('nextElementSibling', selector);
    selection.prevAll = selector => siblingAll('previousElementSibling', selector);
    selection.nextUntil = (selector, until) => siblingAll(
      'nextElementSibling', until ? selector : null, until || selector
    );
    selection.prevUntil = (selector, until) => siblingAll(
      'previousElementSibling', until ? selector : null, until || selector
    );
    selection.siblings = selector => {
      const values = elements.flatMap(node =>
        Array.from((node.parentElement && node.parentElement.children) || [])
          .filter(sibling => sibling !== node)
      );
      return __tetoSelection(
        selector ? values.filter(node => __tetoMatches(node, selector)) : values,
        selection,
      );
    };
    selection.end = () => previous || __tetoSelection([]);
    return selection;
  }

  function LoadDoc(source) {
    const document = __tetoParseDocument(String(source || ''));
    function loaded(selector) {
      if (typeof selector === 'string') return __tetoSelection(__tetoSelect(document, selector));
      return __tetoSelection(selector);
    }
    loaded.root = () => __tetoSelection(document.documentElement);
    loaded.html = () => document.documentElement ? document.documentElement.outerHTML : '';
    return loaded;
  }

  globalThis.Doc = class Doc {
    constructor(source) {
      const document = __tetoParseDocument(String(source || ''));
      return __tetoSelection(document.documentElement || document);
    }
  };

  globalThis.__isOffline__ = false;
  globalThis.$getUserPreference = key => {
    const preferences = globalThis.__tetoUserPreferences || {};
    const name = String(key || '');
    return Object.prototype.hasOwnProperty.call(preferences, name)
      ? preferences[name]
      : undefined;
  };
  async function _makeRequest(url, options) {
    const response = await fetch(url, options || {});
    const body = await response.text();
    if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
    return {status: response.status, headers: response.headers, body, data: body, text: body, url: response.url};
  }

  const __tetoPendingSleeps = Object.create(null);
  let __tetoSleepId = 0;
  let __tetoSleepTail = Promise.resolve();
  const __tetoMaximumPendingSleeps = 64;
  function __tetoScheduleSleep(kind, milliseconds, callback, args) {
    if (Object.keys(__tetoPendingSleeps).length >= __tetoMaximumPendingSleeps) {
      throw new Error('Provider timer limit exceeded');
    }
    const numeric = Number(milliseconds);
    const duration = Number.isFinite(numeric) && numeric > 0 ? numeric : 0;
    const id = kind + '-' + String(++__tetoSleepId);
    __tetoPendingSleeps[id] = {kind, callback, args: args || []};
    sendMessage('TetoSleep', JSON.stringify({id, milliseconds: duration}));
    return id;
  }
  function $sleep(milliseconds) {
    const numeric = Number(milliseconds);
    if (!Number.isFinite(numeric) || numeric <= 0) return __tetoSleepTail;
    const wait = __tetoSleepTail.then(() => new Promise((resolve, reject) => {
      try {
        __tetoScheduleSleep('sleep', numeric, resolve, []);
      } catch (error) {
        reject(error);
      }
    }));
    // Keep the shared barrier fulfilled even if a future bridge implementation
    // chooses to reject an individual wait.
    __tetoSleepTail = wait.catch(() => {});
    return wait;
  }
  globalThis.setTimeout = function(callback, milliseconds, ...args) {
    if (typeof callback !== 'function') {
      throw new TypeError('setTimeout callback must be a function');
    }
    return __tetoScheduleSleep('timer', milliseconds, callback, args);
  };
  globalThis.clearTimeout = function(id) {
    const key = String(id || '');
    const pending = __tetoPendingSleeps[key];
    if (!pending || pending.kind !== 'timer') return;
    delete __tetoPendingSleeps[key];
    sendMessage('TetoClearSleep', JSON.stringify({id: key}));
  };
  function __tetoSleepFinish(id) {
    const pending = __tetoPendingSleeps[id];
    if (!pending) return;
    delete __tetoPendingSleeps[id];
    try { pending.callback(...pending.args); } catch (_) {}
  }
  async function __tetoAwaitSleeps() {
    let pending;
    do {
      pending = __tetoSleepTail;
      await pending;
    } while (pending !== __tetoSleepTail);
  }

  // Seanime-compatible scanner surface. This is an original, bounded
  // implementation of the public behavior exercised by community providers;
  // it does not embed Seanime source code.
  const __tetoNoiseWords = new Set([
    'the', 'a', 'an', 'of', 'to', 'in', 'for', 'on', 'with', 'at', 'by',
    'from', 'as', 'is', 'it', 'that', 'this', 'be', 'are', 'was', 'were',
    'no', 'wa', 'wo', 'ga', 'ni', 'de', 'ka', 'mo', 'ya', 'e', 'he',
    'anime', 'ova', 'ona', 'oad', 'tv', 'movie', 'nc', 'nced', 'ncop',
    'extras', 'ending', 'opening', 'preview', 'special', 'specials', 'sp',
    'finale', 'season', 'uncensored', 'censored', 'bluray',
  ]);
  const __tetoFormatWords = new Set([
    'ova', 'ona', 'oad', 'oav', 'sp', 'special', 'specials', 'movie',
    'film', 'tv', 'nc', 'nced', 'ncop', 'extras', 'opening', 'ending',
    'preview', 'finale',
  ]);
  // Standalone I and X are deliberately excluded because ordinary titles use
  // them too often for them to be reliable season markers.
  const __tetoRoman = Object.freeze({ii: 2, iii: 3, iv: 4, v: 5, vi: 6, vii: 7, viii: 8, ix: 9, xi: 11, xii: 12, xiii: 13});
  const __tetoOrdinalWords = {first: 1, second: 2, third: 3, fourth: 4, fifth: 5, sixth: 6, seventh: 7, eighth: 8, ninth: 9, tenth: 10};
  const __tetoIsRoman = value => Object.prototype.hasOwnProperty.call(
    __tetoRoman, value
  );

  function __tetoNumber(value, fallback) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? Math.trunc(numeric) : fallback;
  }

  function extractSeasonNumber(value) {
    const text = String(value || '').toLowerCase();
    let match = text.match(/\b(?:season|series)\s*0*([0-9]{1,2})\b/);
    if (match) return Number(match[1]);
    match = text.match(/\bs\s*0*([0-9]{1,2})(?=\b|e[0-9])/);
    if (match) return Number(match[1]);
    match = text.match(/\b([0-9]{1,2})(?:st|nd|rd|th)\s+(?:season|series)\b/);
    if (match) return Number(match[1]);
    match = text.match(/\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+season\b/);
    if (match) return __tetoOrdinalWords[match[1]] || -1;
    match = text.match(/([0-9]{1,2})\s*(?:期|シーズン)/);
    if (match) return Number(match[1]);
    const romanSource = text.replace(
      /\b(?:act|arc|chapter|saga|hen|part|cour)[\s._:-]+(?:ii|iii|iv|v|vi|vii|viii|ix|xi|xii|xiii)\b/g,
      ' ',
    );
    match = romanSource.match(
      /(?:^|[\s.])(ii|iii|iv|v|vi|vii|viii|ix|xi|xii|xiii)(?:\s*$|[:,.'"]|\s+(?:s[0-9]|e[0-9]|part))/,
    );
    if (match) return __tetoRoman[match[1]] || -1;
    match = text.match(/(?:^|\s)([0-9]{1,2})\s*$/);
    if (match && !/(?:part|cour|special|sp|movie|ova|ona|oad)\s*[0-9]{1,2}\s*$/.test(text)) {
      const trailing = Number(match[1]);
      if (trailing >= 2 && trailing <= 10) return trailing;
    }
    return -1;
  }

  function extractPartNumber(value) {
    const text = String(value || '').toLowerCase();
    let match = text.match(/\b(?:part|cour)\s*([0-9]{1,2})\b/);
    if (!match) match = text.match(/\b([0-9]{1,2})(?:st|nd|rd|th)\s+(?:part|cour)\b/);
    if (match) return Number(match[1]);
    match = text.match(/\b(?:part|cour)\s+(ii|iii|iv|v|vi|vii|viii|ix|xi|xii|xiii)\b/);
    return match ? (__tetoRoman[match[1]] || -1) : -1;
  }

  function extractYear(value) {
    const match = String(value || '').match(/(?:\(|\b)(19[0-9]{2}|20[0-9]{2})(?:\)|\b)/);
    return match ? Number(match[1]) : -1;
  }

  function normalizeQuery(value) {
    return String(value || '').toLowerCase()
      // Expand macrons before Unicode decomposition removes their marks.
      .replace(/ō/g, 'ou').replace(/ū/g, 'uu')
      .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
      .replace(/@/g, 'a').replace(/×/g, ' x ')
      .replace(/꞉/g, ':').replace(/＊/g, ' * ')
      .replace(/\bthe animation\b/g, ' ')
      .replace(/\bthe\b/g, ' ').replace(/\bepisode\b/g, ' ')
      .replace(/\boad\b/g, ' ova ').replace(/\boav\b/g, ' ova ')
      .replace(/\bspecials?\b/g, ' sp ').replace(/\(\s*tv\s*\)/g, ' ')
      .replace(/&/g, ' and ')
      // Possessives need a token boundary; deleting the apostrophe first would
      // incorrectly merge e.g. "Magus's" into "maguss".
      .replace(/[’'`]s\b/g, ' ')
      .replace(/[’'`"“”]/g, '')
      .replace(/[^a-z0-9\s]/g, ' ').replace(/\s+/g, ' ').trim();
  }

  function normalizeTitle(value) {
    const original = String(value || '');
    const season = extractSeasonNumber(original);
    const part = extractPartNumber(original);
    const year = extractYear(original);
    // Strip Japanese season suffixes before the ASCII-only query pass turns
    // the suffix into whitespace and leaves a misleading bare number behind.
    const titleForNormalization = original.replace(
      /[0-9]{1,2}\s*(?:期|シーズン)/g,
      ' ',
    );
    let normalized = normalizeQuery(titleForNormalization)
      .replace(/\b(?:season|series)\s*0*[0-9]{1,2}\b/g, ' ')
      .replace(/\bs\s*0*[0-9]{1,2}(?=\b|e[0-9])/g, ' ')
      .replace(/\b[0-9]{1,2}(?:st|nd|rd|th)\s+(?:season|series)\b/g, ' ')
      .replace(/\b(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+season\b/g, ' ')
      .replace(/\b(?:part|cour)\s*(?:[0-9]{1,2}|ii|iii|iv|v|vi|vii|viii|ix|xi|xii|xiii)\b/g, ' ')
      .replace(/\b[0-9]{1,2}(?:st|nd|rd|th)\s+(?:part|cour)\b/g, ' ')
      .replace(/\s+/g, ' ').trim();
    const tokens = normalized ? normalized.split(' ').slice(0, 64) : [];
    let base = tokens.filter(token =>
      !__tetoFormatWords.has(token) && !__tetoIsRoman(token)
    ).join(' ');
    base = base.replace(/\b[0-9]+$/, '').replace(/\s+/g, ' ').trim();
    const denoised = base.split(' ').filter(token => token && !__tetoNoiseWords.has(token)).join(' ');
    return {
      original,
      normalized,
      cleanBaseTitle: base,
      denoisedTitle: denoised,
      tokens,
      season,
      part,
      year,
      isMain: false,
    };
  }

  function getSignificantTokens(value) {
    const tokens = Array.isArray(value) ? value : normalizeTitle(value).tokens;
    return tokens.slice(0, 64).filter(token => String(token).length > 1 && !__tetoNoiseWords.has(String(token).toLowerCase()));
  }

  function compareTitles(left, right) {
    const a = normalizeTitle(left).tokens;
    const b = new Set(normalizeTitle(right).tokens);
    if (!a.length || !b.size) return 0;
    let total = 0; let matched = 0;
    a.forEach(token => {
      const weight = __tetoNoiseWords.has(token) ? 0.3 : (/^(?:19|20)[0-9]{2}$/.test(token) ? 0.5 : 1);
      total += weight;
      if (b.has(token)) matched += weight;
    });
    return total ? matched / total : 0;
  }

  function __tetoSimilarity(left, right) {
    return Math.min(compareTitles(left, right), compareTitles(right, left));
  }

  function sanitizeQuery(value) {
    return String(value || '').replace(/[()[\]{}|"'~*?\\^!]/g, ' ')
      .replace(/\s{2,}/g, ' ').trim();
  }

  function buildSearchQuery(value) {
    const normalized = normalizeTitle(value);
    return sanitizeQuery(normalized.denoisedTitle || normalized.cleanBaseTitle || normalized.normalized);
  }

  function buildAdvancedQuery(values) {
    const unique = [];
    (Array.isArray(values) ? values : []).slice(0, 32).forEach(value => {
      const query = buildSearchQuery(value);
      if (query && !unique.includes(query)) unique.push(query);
    });
    if (!unique.length) return '';
    return unique.length === 1 ? unique[0] : '(' + unique.join(' | ') + ')';
  }

  function __tetoOrdinal(value) {
    const number = Math.abs(value);
    const suffix = number % 100 >= 11 && number % 100 <= 13
      ? 'th' : ({1: 'st', 2: 'nd', 3: 'rd'}[number % 10] || 'th');
    return String(value) + suffix;
  }

  function buildSeasonQuery(title, value) {
    const base = buildSearchQuery(title);
    const season = __tetoNumber(value, -1);
    if (!base || season <= 1) return base;
    return '(' + [base + ' S' + String(season).padStart(2, '0'), base + ' S' + season,
      base + ' Season ' + season, base + ' ' + __tetoOrdinal(season) + ' Season'].join(' | ') + ')';
  }

  function buildPartQuery(title, value) {
    const base = buildSearchQuery(title);
    const part = __tetoNumber(value, -1);
    if (!base || part <= 1) return base;
    const roman = Object.keys(__tetoRoman).find(key => __tetoRoman[key] === part);
    const variants = [base + ' Part ' + part];
    if (roman) variants.push(base + ' Part ' + roman.toUpperCase());
    variants.push(base + ' ' + __tetoOrdinal(part) + ' Cour');
    return '(' + variants.join(' | ') + ')';
  }

  function buildSmartSearchTitles(values) {
    const titles = [];
    const seen = new Set();
    let season = -1; let part = -1;
    const add = value => {
      const title = String(value || '').trim();
      const key = title.toLowerCase();
      if (title && !seen.has(key) && titles.length < 64) {
        seen.add(key); titles.push(title);
      }
    };
    const addNormalizedVariants = value => {
      const normalized = normalizeTitle(value);
      add(sanitizeQuery(
        normalized.denoisedTitle || normalized.cleanBaseTitle || normalized.normalized
      ));
      add(sanitizeQuery(normalized.cleanBaseTitle));
      return normalized;
    };
    (Array.isArray(values) ? values : [values]).slice(0, 32).forEach(value => {
      const original = String(value || '');
      if (!original) return;
      const normalized = addNormalizedVariants(original);
      if (season <= 0 && normalized.season > 0) season = normalized.season;
      if (part <= 0 && normalized.part > 0) part = normalized.part;
      [original.indexOf(':'), original.indexOf(' - ')].forEach(index => {
        if (index >= 5) addNormalizedVariants(original.substring(0, index));
      });
    });
    return {titles, season, part};
  }

  function filterBySimilarity(items, query) {
    return (Array.isArray(items) ? items : []).slice(0, 200).sort((left, right) =>
      __tetoSimilarity(right && (right.title || right.name), query) -
      __tetoSimilarity(left && (left.title || left.name), query)
    );
  }

  function findBestMatch(target, candidates) {
    let best = ''; let score = -1;
    (Array.isArray(candidates) ? candidates : []).slice(0, 200).forEach(candidate => {
      if (typeof candidate !== 'string') return;
      const next = compareTitles(target, candidate);
      if (next > score) { best = candidate; score = next; }
    });
    return best;
  }

  globalThis.$scannerUtils = {
    normalizeTitle,
    extractPartNumber,
    extractSeasonNumber,
    extractYear,
    compareTitles,
    findBestMatch,
    getSignificantTokens,
    buildSearchQuery,
    buildAdvancedQuery,
    sanitizeQuery,
    buildSeasonQuery,
    buildPartQuery,
    buildSmartSearchTitles,
    // Compatibility aliases retained for providers predating the current
    // scanner contract.
    normalizeQuery,
    filterBySimilarity,
    similarity: __tetoSimilarity,
    compareTwoStrings: __tetoSimilarity,
  };

  // A bounded invocation-local store lets providers cache repeated title
  // attempts without persisting third-party data or sharing it across
  // providers. JSON cloning prevents callers from mutating stored values by
  // reference while keeping memory use measurable and bounded.
  function __tetoCreateStore() {
    const entries = Object.create(null);
    let totalSize = 0;
    const keyOf = value => {
      const key = String(value == null ? '' : value);
      if (!key || key.length > 128 || /[\u0000-\u001f]/.test(key)) {
        throw new Error('Store key is invalid');
      }
      return key;
    };
    const encode = value => {
      const encoded = JSON.stringify(value);
      if (encoded === undefined || encoded.length > 131072) {
        throw new Error('Store value exceeds its limit');
      }
      return encoded;
    };
    const decode = encoded => encoded === undefined ? undefined : JSON.parse(encoded);
    const set = (rawKey, value) => {
      const key = keyOf(rawKey);
      const encoded = encode(value);
      if (!Object.prototype.hasOwnProperty.call(entries, key) && Object.keys(entries).length >= 64) {
        throw new Error('Store entry limit exceeded');
      }
      const nextSize = totalSize - (entries[key] ? entries[key].length : 0) + encoded.length;
      if (nextSize > 262144) throw new Error('Store total size limit exceeded');
      entries[key] = encoded; totalSize = nextSize;
    };
    const api = {
      set,
      get(key) { return decode(entries[keyOf(key)]); },
      getUnsafe(key) { return decode(entries[keyOf(key)]); },
      has(key) { return Object.prototype.hasOwnProperty.call(entries, keyOf(key)); },
      getOrSet(key, factory) {
        const normalized = keyOf(key);
        if (Object.prototype.hasOwnProperty.call(entries, normalized)) return decode(entries[normalized]);
        const value = typeof factory === 'function' ? factory() : factory;
        set(normalized, value); return decode(entries[normalized]);
      },
      setIfLessThanLimit(key, value, maximum) {
        const limit = Math.max(0, Math.min(64, __tetoNumber(maximum, 0)));
        if (!api.has(key) && Object.keys(entries).length >= limit) return false;
        set(key, value); return true;
      },
      marshalJSON(value) { return encode(value); },
      unmarshalJSON(value) {
        const decoded = JSON.parse(String(value || '{}'));
        if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded)) return;
        Object.keys(decoded).slice(0, 64).forEach(key => set(key, decoded[key]));
      },
      reset() { Object.keys(entries).forEach(key => delete entries[key]); totalSize = 0; },
      clear() { api.reset(); },
      drop() { api.reset(); },
      remove(key) {
        const normalized = keyOf(key);
        if (entries[normalized]) totalSize -= entries[normalized].length;
        delete entries[normalized];
      },
      keys() { return Object.keys(entries); },
      values() { return Object.keys(entries).map(key => decode(entries[key])); },
      valuesUnsafe() { return api.values(); },
      getAll() {
        const result = Object.create(null);
        Object.keys(entries).forEach(key => { result[key] = decode(entries[key]); });
        return result;
      },
      getAllUnsafe() { return api.getAll(); },
    };
    return Object.freeze(api);
  }
  globalThis.$store = __tetoCreateStore();
  globalThis.$storage = __tetoCreateStore();
''';
