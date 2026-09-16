import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/public_https_dio.dart';
import 'package:anime_tv/features/marketplace/data/typescript_compiler.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/domain/repository_format.dart';
import 'package:dio/dio.dart';

class MarketplaceClient {
  MarketplaceClient(
    this._store, {
    Dio? dio,
    AddonTypescriptCompiler? typescriptCompiler,
    Future<void> Function(Uri uri)? targetValidator,
  }) : _typescriptCompiler = typescriptCompiler ?? AddonTypescriptCompiler(),
       _targetValidator = targetValidator ?? validatePublicNetworkTarget,
       _dio =
           dio ??
           createPinnedPublicHttpsDio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 12),
               responseType: ResponseType.plain,
               followRedirects: false,
               headers: const {'User-Agent': 'TetoTV/1 marketplace'},
             ),
           );

  static const _maxCatalogBytes = 2 * 1024 * 1024;
  static const _maxManifestBytes = 256 * 1024;
  static const _maxPayloadBytes = 768 * 1024;
  static const _maxRedirects = 5;
  static const _downloadDeadline = Duration(seconds: 24);

  final AddonStore _store;
  final AddonTypescriptCompiler _typescriptCompiler;
  final Future<void> Function(Uri uri) _targetValidator;
  final Dio _dio;

  Future<List<MarketplaceAddon>> catalog(
    AddonRepository repository, {
    bool refresh = false,
  }) async {
    if (!refresh) {
      final cached = await _store.cachedCatalogEntry(repository.url);
      if (cached != null) {
        return _parseCachedCatalog(cached, repository.url);
      }
    }
    final uri = safePublicHttpsUri(repository.url);
    if (uri == null) {
      throw const FormatException('Repository must use a public HTTPS URL.');
    }
    final compatibility = inspectExtensionRepositoryUri(uri);
    if (compatibility.isRejected) {
      throw FormatException(compatibility.rejectionMessage!);
    }
    try {
      final download = await _getText(uri, maximumBytes: _maxCatalogBytes);
      final parsed = _parseCatalog(
        download.body,
        repository.url,
        resourceBaseUri: download.effectiveUri,
      );
      await _store.cacheCatalog(
        repository.url,
        download.body,
        resourceBaseUri: download.effectiveUri,
      );
      return parsed;
    } catch (_) {
      final cached = await _store.cachedCatalogEntry(repository.url);
      if (cached != null) {
        return _parseCachedCatalog(cached, repository.url);
      }
      rethrow;
    }
  }

  Future<InstalledStreamingAddon> downloadAddon(
    MarketplaceAddon summary,
  ) async {
    final complete = await manifest(summary);
    if (!complete.isCompatible ||
        (complete.payloadUri == null && complete.inlinePayload == null)) {
      throw const FormatException(
        'This addon is not a compatible JavaScript or TypeScript provider.',
      );
    }
    final downloadedSource =
        complete.inlinePayload ??
        (await _getText(
          complete.payloadUri!,
          maximumBytes: _maxPayloadBytes,
        )).body;
    final source = applyAddonConfigDefaults(
      downloadedSource,
      complete.userConfigDefaults,
    );
    final payload = complete.isTypescript
        ? await _typescriptCompiler.compile(source)
        : source;
    if (!_looksLikeProvider(payload)) {
      throw const FormatException(
        'The addon payload does not expose a Provider class.',
      );
    }
    final now = DateTime.now();
    return InstalledStreamingAddon(
      manifest: complete,
      payload: payload,
      enabled: true,
      installedAt: now,
      updatedAt: now,
    );
  }

  Future<MarketplaceAddon> manifest(MarketplaceAddon summary) async {
    final manifestDownload = await _getText(
      summary.manifestUri,
      maximumBytes: _maxManifestBytes,
    );
    final decoded = jsonDecode(manifestDownload.body);
    return validateAndMergeMarketplaceManifest(
      summary,
      decoded,
      resourceBaseUri: manifestDownload.effectiveUri,
    );
  }

  Future<({String body, Uri effectiveUri})> _getText(
    Uri uri, {
    required int maximumBytes,
  }) async {
    if (safePublicHttpsUri(uri.toString()) == null) {
      throw const FormatException('Only public HTTPS resources are allowed.');
    }
    final clock = Stopwatch()..start();
    final visited = <String>{};
    var current = uri;
    for (var redirectCount = 0; ; redirectCount++) {
      final canonical = current.toString();
      if (!visited.add(canonical)) {
        throw const FormatException('Marketplace redirect loop detected.');
      }
      await _targetValidator(current);
      final remaining = _downloadDeadline - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Marketplace download exceeded its deadline.',
          _downloadDeadline,
        );
      }
      final cancelToken = CancelToken();
      late final Timer deadlineTimer;
      deadlineTimer = Timer(
        remaining,
        () => cancelToken.cancel('Marketplace download deadline exceeded.'),
      );
      Response<ResponseBody> response;
      try {
        response = await _dio.get<ResponseBody>(
          current.toString(),
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (_) => true,
          ),
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error) && clock.elapsed >= _downloadDeadline) {
          throw TimeoutException(
            'Marketplace download exceeded its deadline.',
            _downloadDeadline,
          );
        }
        rethrow;
      } finally {
        deadlineTimer.cancel();
      }
      final status = response.statusCode ?? 0;
      if (_isMarketplaceRedirectStatus(status)) {
        await _discardMarketplaceBody(response.data);
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.trim().isEmpty) {
          throw FormatException(
            'Marketplace redirect HTTP $status did not include a location.',
          );
        }
        if (redirectCount >= _maxRedirects) {
          throw const FormatException(
            'Marketplace resource exceeded its redirect limit.',
          );
        }
        final redirected = safePublicHttpsUri(
          current.resolve(location).toString(),
        );
        if (redirected == null) {
          throw const FormatException(
            'Marketplace redirect must use public HTTPS.',
          );
        }
        current = redirected;
        continue;
      }
      if (status < 200 || status >= 300) {
        await _discardMarketplaceBody(response.data);
        throw FormatException(
          'Marketplace resource request failed with HTTP $status.',
        );
      }
      final body = response.data;
      if (body == null) {
        throw const FormatException('The downloaded resource is empty.');
      }
      final bodyRemaining = _downloadDeadline - clock.elapsed;
      if (bodyRemaining <= Duration.zero) {
        throw TimeoutException(
          'Marketplace download exceeded its deadline.',
          _downloadDeadline,
        );
      }
      final data = await _readMarketplaceBody(body, maximumBytes).timeout(
        bodyRemaining,
        onTimeout: () {
          cancelToken.cancel('Marketplace download deadline exceeded.');
          throw TimeoutException(
            'Marketplace download exceeded its deadline.',
            _downloadDeadline,
          );
        },
      );
      return (body: data, effectiveUri: current);
    }
  }

  List<MarketplaceAddon> _parseCatalog(
    String payload,
    String repositoryUrl, {
    Uri? resourceBaseUri,
  }) {
    return parseMarketplaceCatalog(
      payload,
      repositoryUrl: repositoryUrl,
      resourceBaseUri: resourceBaseUri,
    );
  }

  List<MarketplaceAddon> _parseCachedCatalog(
    CachedMarketplaceCatalog cached,
    String repositoryUrl,
  ) {
    final cachedBase = safePublicHttpsUri(cached.resourceBaseUrl);
    return _parseCatalog(
      cached.payload,
      repositoryUrl,
      resourceBaseUri: cachedBase,
    );
  }
}

bool _isMarketplaceRedirectStatus(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

Future<void> _discardMarketplaceBody(ResponseBody? body) async {
  if (body == null) return;
  final subscription = body.stream.listen(null);
  await subscription.cancel();
}

Future<String> _readMarketplaceBody(ResponseBody body, int maximumBytes) async {
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in body.stream) {
    length += chunk.length;
    if (length > maximumBytes) {
      throw const FormatException('The downloaded resource is too large.');
    }
    bytes.add(chunk);
  }
  final data = utf8.decode(bytes.takeBytes(), allowMalformed: false);
  if (data.isEmpty) {
    throw const FormatException('The downloaded resource is empty.');
  }
  return data;
}

/// Parses both Seanime's canonical top-level list and common named wrappers
/// used by independently maintained repositories. The executable manifest is
/// still fetched and validated separately, so accepting a wrapper does not
/// weaken the repository/code trust boundary.
List<MarketplaceAddon> parseMarketplaceCatalog(
  String payload, {
  required String repositoryUrl,
  Uri? resourceBaseUri,
}) {
  if (utf8.encode(payload).length > MarketplaceClient._maxCatalogBytes) {
    throw const FormatException('Repository catalog is too large.');
  }
  final decoded = jsonDecode(payload);
  final compatibility = inspectExtensionRepositoryJson(decoded);
  if (compatibility.isRejected) {
    throw FormatException(compatibility.rejectionMessage!);
  }
  final entries = switch (decoded) {
    final List<dynamic> values => values,
    final Map<dynamic, dynamic> wrapper => _catalogEntriesFromWrapper(wrapper),
    _ => null,
  };
  if (entries == null) {
    throw const FormatException(
      'Repository catalog must be a JSON list or contain an addons/providers list.',
    );
  }
  final addons = <MarketplaceAddon>[];
  for (final entry in entries.take(1000)) {
    final addon = MarketplaceAddon.tryParse(
      entry,
      repositoryUrl: repositoryUrl,
      resourceBaseUri: resourceBaseUri,
    );
    if (addon != null && addon.isExecutableProvider) {
      // Keep same-ID variants until every configured repository has been
      // collected. The controller performs the status/version/provenance
      // comparison once; first-entry-wins here allowed an older or broken
      // entry to hide a maintained variant in the same catalog.
      addons.add(addon);
    }
  }
  return List.unmodifiable(addons);
}

List<dynamic>? _catalogEntriesFromWrapper(
  Map<dynamic, dynamic> wrapper, {
  int depth = 0,
}) {
  if (depth >= 8) return null;
  for (final key in const [
    'addons',
    'providers',
    'extensions',
    'items',
    'results',
    'entries',
  ]) {
    final value = wrapper[key];
    if (value is List) return value;
    if (value is Map) {
      final mapped = _catalogEntriesFromMapValues(value);
      if (mapped != null) return mapped;
    }
  }
  for (final key in const ['data', 'marketplace', 'catalog', 'result']) {
    final value = wrapper[key];
    if (value is List) return value;
    if (value is Map) {
      final nested = _catalogEntriesFromWrapper(value, depth: depth + 1);
      if (nested != null) return nested;
      final mapped = _catalogEntriesFromMapValues(value);
      if (mapped != null) return mapped;
    }
  }
  return null;
}

/// Some community catalogs key entries by extension ID instead of using a
/// JSON array. Accept only maps whose bounded values look like actual manifest
/// summaries; arbitrary metadata maps are not reinterpreted as executable
/// add-ons.
List<dynamic>? _catalogEntriesFromMapValues(Map<dynamic, dynamic> value) {
  if (value.isEmpty || value.length > 1000) return null;
  final entries = <Map<String, Object?>>[];
  for (final entry in value.entries) {
    if (entry.value is! Map) return null;
    final normalized = (entry.value as Map).map<String, Object?>(
      (key, item) => MapEntry('$key', item),
    );
    final hasInnerIdentity = const [
      'id',
      'extensionId',
      'identifier',
    ].any((key) => normalized[key] is String);
    final mapKey = '${entry.key}'.trim();
    if (!hasInnerIdentity &&
        RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(mapKey)) {
      normalized['id'] = mapKey;
    }
    entries.add(normalized);
  }
  if (entries.isEmpty || entries.length != value.length) return null;
  final hasManifestSummary = entries.any(
    (entry) => const [
      'manifestURI',
      'manifestUri',
      'manifestURL',
      'manifestUrl',
      'manifest',
    ].any((key) => entry[key] is String),
  );
  return hasManifestSummary ? entries : null;
}

/// Seanime add-on IDs are case-sensitive in JavaScript only by convention.
/// Repositories in the wild already contain casing-only catalog/manifest
/// drift (for example `fixtureCase` versus `fixturecase`). Treating that as the same
/// identity keeps the original repository provenance while avoiding a false
/// install rejection.
MarketplaceAddon validateAndMergeMarketplaceManifest(
  MarketplaceAddon summary,
  Object? decoded, {
  Uri? resourceBaseUri,
}) {
  final manifestValue = _unwrapMarketplaceManifest(decoded);
  final manifest = MarketplaceAddon.tryParse(
    manifestValue,
    repositoryUrl: summary.repositoryUrl,
    resourceBaseUri: resourceBaseUri ?? summary.manifestUri,
  );
  if (manifest == null || !marketplaceAddonIdsMatch(manifest.id, summary.id)) {
    throw const FormatException(
      'The addon manifest is invalid or its ID changed.',
    );
  }
  if (manifest.type.isNotEmpty && manifest.type != summary.type) {
    throw const FormatException(
      'The addon manifest changed its provider type.',
    );
  }
  return summary.mergeManifest(manifest);
}

Object? _unwrapMarketplaceManifest(Object? value, {int depth = 0}) {
  if (value is! Map || depth >= 4) return value;
  final normalized = value.map((key, item) => MapEntry('$key', item));
  final hasIdentity =
      normalized['id'] is String && normalized['name'] is String;
  final hasManifestUri = const [
    'manifestURI',
    'manifestUri',
    'manifestURL',
    'manifestUrl',
    'manifest',
  ].any((key) => normalized[key] is String);
  if (hasIdentity && hasManifestUri) return normalized;
  for (final key in const [
    'manifest',
    'addon',
    'extension',
    'provider',
    'data',
  ]) {
    final nested = normalized[key];
    if (nested is Map) {
      final unwrapped = _unwrapMarketplaceManifest(nested, depth: depth + 1);
      if (unwrapped is Map) return unwrapped;
    }
  }
  return normalized;
}

bool _looksLikeProvider(String payload) {
  if (utf8.encode(payload).length > MarketplaceClient._maxPayloadBytes) {
    return false;
  }
  final source = _javascriptWithoutCommentsAndStrings(payload);
  if (RegExp(r'\b(?:class|function)\s+Provider\b').hasMatch(source)) {
    return true;
  }
  if (RegExp(
    r'\b(?:const|let|var)\s+Provider\s*=\s*(?:class|function)\b',
  ).hasMatch(source)) {
    return true;
  }
  // Some bundled providers keep an implementation-specific class name and
  // export it into Seanime's required global at the end of the payload.
  return RegExp(
    r'\b(?:globalThis|window|self)\s*\.\s*Provider\s*=\s*'
    r'(?:class\b|function\b|[A-Za-z_$][A-Za-z0-9_$]*)',
  ).hasMatch(source);
}

/// Removes trivia that could otherwise make a comment or string containing
/// `class Provider` pass install-time shape validation. This is deliberately
/// only a compatibility preflight; the executable still runs solely inside
/// TetoTV's bounded provider sandbox.
String _javascriptWithoutCommentsAndStrings(String source) {
  final output = StringBuffer();
  var index = 0;
  String? quote;
  var escaped = false;
  var lineComment = false;
  var blockComment = false;
  while (index < source.length) {
    final current = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';
    if (lineComment) {
      if (current == '\n' || current == '\r') {
        lineComment = false;
        output.write(current);
      } else {
        output.write(' ');
      }
      index++;
      continue;
    }
    if (blockComment) {
      if (current == '*' && next == '/') {
        output.write('  ');
        index += 2;
        blockComment = false;
      } else {
        output.write(current == '\n' || current == '\r' ? current : ' ');
        index++;
      }
      continue;
    }
    if (quote != null) {
      output.write(current == '\n' || current == '\r' ? current : ' ');
      if (escaped) {
        escaped = false;
      } else if (current == r'\') {
        escaped = true;
      } else if (current == quote) {
        quote = null;
      }
      index++;
      continue;
    }
    if (current == '/' && next == '/') {
      output.write('  ');
      index += 2;
      lineComment = true;
      continue;
    }
    if (current == '/' && next == '*') {
      output.write('  ');
      index += 2;
      blockComment = true;
      continue;
    }
    if (current == "'" || current == '"' || current == '`') {
      quote = current;
      output.write(' ');
      index++;
      continue;
    }
    output.write(current);
    index++;
  }
  return output.toString();
}

String applyAddonConfigDefaults(String source, Map<String, String> defaults) {
  var encodedLength = 0;
  final output = StringBuffer();

  void writeBounded(String value) {
    encodedLength += utf8.encode(value).length;
    if (encodedLength > MarketplaceClient._maxPayloadBytes) {
      throw const FormatException('The configured addon payload is too large.');
    }
    output.write(value);
  }

  final placeholder = RegExp(r'\{\{([A-Za-z0-9._-]+)\}\}');
  var cursor = 0;
  for (final match in placeholder.allMatches(source)) {
    writeBounded(source.substring(cursor, match.start));
    final key = match.group(1)!;
    writeBounded(defaults[key] ?? match.group(0)!);
    cursor = match.end;
  }
  writeBounded(source.substring(cursor));
  return output.toString();
}
