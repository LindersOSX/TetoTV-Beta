import 'dart:convert';

import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart'
    show safePublicHttpsUri;

/// Bounds apply before decoding and to all JSON values, including unknown keys.
abstract final class AniyomiRepositoryLimits {
  static const maxPayloadBytes = 2 * 1024 * 1024;
  static const maxExtensions = 4096;
  static const maxSourcesPerExtension = 256;
  static const maxSources = 16384;
  static const maxStringLength = 4096;
  static const maxDepth = 24;
  static const maxNodes = 150000;
}

/// Parses catalog data only. It does not download, trust, install, or execute
/// extension APKs. The network caller must additionally pin public DNS results
/// and revalidate redirects; static URL validation cannot prevent DNS rebinding.
///
/// Supported: legacy anime/manga indexes and metadata; canonical inline JSON
/// stores for both media kinds.
/// Protobuf, gzip and delegated stores are explicitly unsupported here.
/// Schema snapshot: aniyomiorg/aniyomi commit
/// 4b5b90a3749b2c0504d4ffdd9416051d4730226c, MangaExtensionApi.kt and
/// data/.../extension/anime/model/NetworkAnimeExtensionStore.kt.
AniyomiRepositoryDocument parseAniyomiRepository(
  String payload, {
  required Uri repositoryUri,
  required AniyomiMediaKind kind,
}) => _Parser(kind, _publicUrl(repositoryUri.toString())).parse(payload);

final class _Parser {
  _Parser(this.kind, this.repositoryUri);

  final AniyomiMediaKind kind;
  final Uri repositoryUri;
  final _packages = <String>{};
  final _sourceIds = <String>{};
  var _sourceCount = 0;

  AniyomiRepositoryDocument parse(String payload) {
    final path = repositoryUri.path.toLowerCase();
    if (path.endsWith('.pb') || path.endsWith('.gz')) {
      _fail(
        AniyomiRepositoryParseError.unsupportedFormat,
        'Protobuf and compressed Aniyomi indexes are not supported.',
      );
    }
    final decoded = _decodeBounded(payload);
    if (decoded is List) {
      return AniyomiRepositoryDocument(
        kind: kind,
        repositoryUri: repositoryUri,
        format: AniyomiRepositoryFormat.legacyIndex,
        extensions: _entries(decoded, legacy: true),
      );
    }
    final object = _object(decoded, 'repository');
    if (object.containsKey('meta')) {
      final metadata = _legacyMetadata(_object(object['meta'], 'meta'));
      if (object['index_v2'] != null) {
        _publicUrl(_string(object['index_v2'], 'index_v2', max: 2048));
        _fail(
          AniyomiRepositoryParseError.delegatedIndex,
          'Delegated Aniyomi index_v2 stores are not supported.',
        );
      }
      return AniyomiRepositoryDocument(
        kind: kind,
        repositoryUri: repositoryUri,
        format: AniyomiRepositoryFormat.legacyMetadata,
        metadata: metadata,
        extensions: const [],
        legacyIndexUri: _publicUrl(
          repositoryUri.resolve('index.min.json').toString(),
        ),
      );
    }
    final contact = _object(object['contact'], 'contact');
    final metadata = AniyomiRepositoryMetadata(
      name: _string(object['name'], 'name', max: 256),
      shortName: _string(object['badgeLabel'], 'badgeLabel', max: 256),
      websiteUri: _publicUrl(_string(contact['website'], 'website', max: 2048)),
      signingKeyFingerprint: _fingerprint(object['signingKey']),
    );
    if (contact['discord'] != null) {
      _publicUrl(_string(contact['discord'], 'discord', max: 2048));
    }
    if (object['extensionListUrl'] != null) {
      _publicUrl(
        _string(object['extensionListUrl'], 'extensionListUrl', max: 2048),
      );
      _fail(
        AniyomiRepositoryParseError.delegatedIndex,
        'Delegated Aniyomi extension lists are not supported.',
      );
    }
    final list = _object(object['extensionList'], 'extensionList');
    return AniyomiRepositoryDocument(
      kind: kind,
      repositoryUri: repositoryUri,
      format: AniyomiRepositoryFormat.animeStore,
      metadata: metadata,
      extensions: _entries(
        _list(list['extensions'], 'extensions'),
        legacy: false,
      ),
    );
  }

  List<AniyomiRepositoryExtension> _entries(
    List<dynamic> entries, {
    required bool legacy,
  }) {
    if (entries.length > AniyomiRepositoryLimits.maxExtensions) {
      _limit('Too many Aniyomi extensions.');
    }
    final extensions = <AniyomiRepositoryExtension>[];
    for (final raw in entries) {
      final item = _object(raw, 'extension');
      if (!legacy && kind == AniyomiMediaKind.manga) {
        _reserveInlineMangaSources(item['sources']);
      }
      try {
        extensions.add(_extension(item, legacy));
      } on AniyomiRepositoryParseException catch (error) {
        // Canonical Manga catalogs may contain stale entries whose required
        // APK/icon URLs are unsafe for TetoTV to fetch. Drop only that entry;
        // every structural, identity and limit failure remains fatal.
        if (legacy ||
            kind != AniyomiMediaKind.manga ||
            error.code != AniyomiRepositoryParseError.unsafeResource) {
          rethrow;
        }
      }
    }
    return extensions;
  }

  void _reserveInlineMangaSources(Object? raw) {
    final entries = _list(raw, 'sources');
    if (entries.length > AniyomiRepositoryLimits.maxSourcesPerExtension) {
      _limit('Too many sources in an Aniyomi extension.');
    }
    _sourceCount += entries.length;
    if (_sourceCount > AniyomiRepositoryLimits.maxSources) {
      _limit('Too many Aniyomi source identities.');
    }
  }

  AniyomiRepositoryExtension _extension(
    Map<String, dynamic> item,
    bool legacy,
  ) {
    final packageName = _string(
      item[legacy ? 'pkg' : 'packageName'],
      'packageName',
      max: 200,
    );
    if (!RegExp(
      r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
    ).hasMatch(packageName)) {
      _invalid('Invalid Android extension package name.');
    }
    final packageKey = packageName.toLowerCase();
    final name = _string(item['name'], 'name', max: 256);
    final versionName = _string(
      item[legacy ? 'version' : 'versionName'],
      'versionName',
      max: 80,
    );
    final versionCode = _positiveInteger(item[legacy ? 'code' : 'versionCode']);
    final extensionLib = legacy
        ? _legacyLibrary(versionName)
        : _library(item['extensionLib']);
    late final Uri apkUri;
    late final Uri iconUri;
    void parseRequiredResources() {
      if (legacy) {
        final filename = _string(item['apk'], 'apk', max: 255);
        if (!RegExp(
              r'^[A-Za-z0-9][A-Za-z0-9._-]*\.apk$',
              caseSensitive: false,
            ).hasMatch(filename) ||
            filename.contains('..')) {
          _unsafe('Invalid Aniyomi APK filename.');
        }
        apkUri = _publicUrl(repositoryUri.resolve('apk/$filename').toString());
        iconUri = _publicUrl(
          repositoryUri.resolve('icon/$packageName.png').toString(),
        );
      } else {
        final resources = _object(item['resources'], 'resources');
        apkUri = _publicUrl(_string(resources['apkUrl'], 'apkUrl', max: 2048));
        iconUri = _publicUrl(
          _string(resources['iconUrl'], 'iconUrl', max: 2048),
        );
      }
    }

    // Required fetch targets are staged ahead of identity checks only for the
    // canonical Manga store. That makes dropping an unsafe entry independent
    // of whether an otherwise valid duplicate appears before or after it.
    if (!legacy && kind == AniyomiMediaKind.manga) {
      parseRequiredResources();
    }
    if (_packages.contains(packageKey)) {
      _invalid('Duplicate or ambiguous Aniyomi package identity.');
    }
    final sources = _sources(item['sources'], legacy: legacy);
    final languages = sources.map((source) => source.language).toSet();
    final language = legacy
        ? _language(item['lang'])
        : languages.length == 1
        ? languages.single
        : 'all';
    final warning = legacy
        ? _legacyWarning(item['nsfw'])
        : _warning(item['contentWarning']);
    final isTorrent = legacy ? false : _optionalBool(item['isTorrent']);
    if (legacy || kind != AniyomiMediaKind.manga) {
      parseRequiredResources();
    }
    final extension = AniyomiRepositoryExtension(
      kind: kind,
      packageName: packageName,
      name: name,
      versionName: versionName,
      versionCode: versionCode,
      extensionLib: extensionLib,
      apkUri: apkUri,
      iconUri: iconUri,
      language: language,
      isNsfw: warning,
      isTorrent: isTorrent,
      sources: sources,
    );
    // Only publish identities after required APK/icon URLs have passed the
    // public-HTTPS policy. A skipped unsafe entry must not reserve identities
    // and make a later safe entry look like a duplicate.
    _packages.add(packageKey);
    _sourceIds.addAll(sources.map((source) => source.id));
    return extension;
  }

  List<AniyomiRepositorySource> _sources(Object? raw, {required bool legacy}) {
    if (raw == null && legacy) return const [];
    final entries = _list(raw, 'sources');
    if (entries.length > AniyomiRepositoryLimits.maxSourcesPerExtension) {
      _limit('Too many sources in an Aniyomi extension.');
    }
    final localSourceIds = <String>{};
    return entries.map((raw) {
      if (legacy || kind != AniyomiMediaKind.manga) {
        if (++_sourceCount > AniyomiRepositoryLimits.maxSources) {
          _limit('Too many Aniyomi source identities.');
        }
      }
      final source = _object(raw, 'source');
      final id = _exactLong(source['id'], 'source id');
      if (_sourceIds.contains(id) || !localSourceIds.add(id)) {
        _invalid('Duplicate Aniyomi source identity.');
      }
      final home = source[legacy ? 'baseUrl' : 'homeUrl'];
      Uri? homeUri;
      if (home != null && home != '') {
        final value = _string(home, 'source URL', max: 2048);
        try {
          homeUri = _publicUrl(value);
        } on AniyomiRepositoryParseException catch (error) {
          if (legacy ||
              kind != AniyomiMediaKind.manga ||
              error.code != AniyomiRepositoryParseError.unsafeResource) {
            rethrow;
          }
        }
      }
      if (!legacy && source['mirrorUrls'] != null) {
        final mirrors = _list(source['mirrorUrls'], 'mirrorUrls');
        if (mirrors.length > 32) _limit('Too many source mirror URLs.');
        for (final mirror in mirrors) {
          final value = _string(mirror, 'mirrorUrl', max: 2048);
          try {
            _publicUrl(value);
          } on AniyomiRepositoryParseException catch (error) {
            if (kind != AniyomiMediaKind.manga ||
                error.code != AniyomiRepositoryParseError.unsafeResource) {
              rethrow;
            }
          }
        }
      }
      return AniyomiRepositorySource(
        kind: kind,
        id: id,
        name: !legacy && kind == AniyomiMediaKind.manga
            ? _displayName(source['name'], 'source name', max: 256)
            : _string(source['name'], 'source name', max: 256),
        language: _language(
          source[legacy ? 'lang' : 'language'],
          allowOther: !legacy && kind == AniyomiMediaKind.manga,
        ),
        homeUri: homeUri,
      );
    }).toList();
  }
}

AniyomiRepositoryMetadata _legacyMetadata(Map<String, dynamic> meta) =>
    AniyomiRepositoryMetadata(
      name: _string(meta['name'], 'repository name', max: 256),
      shortName: meta['shortName'] == null
          ? null
          : _string(meta['shortName'], 'shortName', max: 256),
      websiteUri: _publicUrl(_string(meta['website'], 'website', max: 2048)),
      signingKeyFingerprint: _fingerprint(meta['signingKeyFingerprint']),
    );

Object? _decodeBounded(String payload) {
  if (payload.length > AniyomiRepositoryLimits.maxPayloadBytes ||
      utf8.encode(payload).length > AniyomiRepositoryLimits.maxPayloadBytes) {
    _limit('Aniyomi repository payload exceeds the size limit.');
  }
  final trimmed = payload.trim();
  if (trimmed.isEmpty ||
      !(trimmed.startsWith('[') || trimmed.startsWith('{'))) {
    _fail(
      AniyomiRepositoryParseError.unsupportedFormat,
      'Only uncompressed JSON Aniyomi repositories are supported.',
    );
  }
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (final char in trimmed.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == 92) {
        escaped = true;
      } else if (char == 34) {
        quoted = false;
      }
    } else if (char == 34) {
      quoted = true;
    } else if (char == 91 || char == 123) {
      if (++depth > AniyomiRepositoryLimits.maxDepth) {
        _limit('Aniyomi repository JSON is too deeply nested.');
      }
    } else if (char == 93 || char == 125) {
      depth--;
    }
  }
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    _invalid('Malformed Aniyomi repository JSON.');
  }
  var nodes = 0;
  void inspect(Object? value) {
    if (++nodes > AniyomiRepositoryLimits.maxNodes) {
      _limit('Aniyomi repository has too many JSON values.');
    }
    if (value is String &&
        value.length > AniyomiRepositoryLimits.maxStringLength) {
      _limit('Aniyomi repository contains an oversized string.');
    }
    if (value is List) {
      for (final child in value) {
        inspect(child);
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        inspect(entry.key);
        inspect(entry.value);
      }
    }
  }

  inspect(decoded);
  return decoded;
}

Map<String, dynamic> _object(Object? value, String field) {
  if (value is! Map<String, dynamic>) _invalid('$field must be a JSON object.');
  return value;
}

List<dynamic> _list(Object? value, String field) {
  if (value is! List) _invalid('$field must be a JSON list.');
  return value;
}

String _string(Object? value, String field, {required int max}) {
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    _invalid('$field must be a nonempty plain string.');
  }
  if (value.length > max) _limit('$field exceeds its size limit.');
  return value;
}

String _displayName(Object? value, String field, {required int max}) {
  if (value is! String || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    _invalid('$field must be a nonempty plain string.');
  }
  if (value.length > max) _limit('$field exceeds its size limit.');
  final normalized = value.trim();
  if (normalized.isEmpty) {
    _invalid('$field must be a nonempty plain string.');
  }
  return normalized;
}

String _language(Object? value, {bool allowOther = false}) {
  final language = _string(value, 'language', max: 35);
  final normalized = language.toLowerCase().replaceAll('_', '-');
  if (allowOther && normalized == 'other') return normalized;
  if (!RegExp(r'^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})*$').hasMatch(language)) {
    _invalid('Invalid Aniyomi source language.');
  }
  return normalized;
}

String _fingerprint(Object? value) {
  final fingerprint = _string(value, 'signing fingerprint', max: 64);
  if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(fingerprint)) {
    _invalid('Invalid advisory SHA-256 signing fingerprint.');
  }
  return fingerprint.toLowerCase();
}

String _library(Object? value) {
  final library = _string(value, 'extensionLib', max: 20);
  if (!RegExp(r'^[1-9][0-9]*(?:\.[0-9]+)?$').hasMatch(library)) {
    _invalid('Invalid Aniyomi extension library version.');
  }
  return library;
}

String _legacyLibrary(String version) {
  final split = version.lastIndexOf('.');
  if (split <= 0 ||
      !RegExp(r'^[0-9]+$').hasMatch(version.substring(split + 1))) {
    _invalid('Invalid legacy Aniyomi extension version.');
  }
  return _library(version.substring(0, split));
}

String _exactLong(Object? value, String field) {
  // Even integral doubles are rejected: any earlier precision loss is unknown.
  if (value is! int && value is! String) {
    _invalid('$field must be an exact integer.');
  }
  final text = value.toString();
  if (!RegExp(r'^-?(?:0|[1-9][0-9]{0,18})$').hasMatch(text) || text == '-0') {
    _invalid('$field must be a canonical signed-64-bit decimal integer.');
  }
  final integer = BigInt.parse(text);
  if (integer < BigInt.parse('-9223372036854775808') ||
      integer > BigInt.parse('9223372036854775807')) {
    _invalid('$field is outside the signed-64-bit range.');
  }
  return integer.toString();
}

int _positiveInteger(Object? value) {
  final integer = int.parse(_exactLong(value, 'versionCode'));
  if (integer < 1) _invalid('versionCode must be positive.');
  return integer;
}

bool _legacyWarning(Object? value) {
  if (value is! int || (value != 0 && value != 1)) {
    _invalid('Invalid nsfw flag.');
  }
  return value == 1;
}

bool _warning(Object? value) => switch (value) {
  'SAFE' || 'CONTENT_WARNING_SAFE' || 1 => false,
  // Unspecified content is conservatively not treated as verified safe.
  'UNSPECIFIED' || 'CONTENT_WARNING_UNSPECIFIED' || 0 => true,
  'MIXED' || 'CONTENT_WARNING_MIXED' || 2 => true,
  'NSFW' || 'CONTENT_WARNING_NSFW' || 3 => true,
  _ => _invalid('Invalid Aniyomi contentWarning.'),
};

bool _optionalBool(Object? value) {
  if (value == null) return false;
  if (value is! bool) _invalid('isTorrent must be a boolean.');
  return value;
}

Uri _publicUrl(String value) {
  if (value.length > 2048 ||
      value.trim() != value ||
      RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value)) {
    _unsafe('Aniyomi resources must use plain public HTTPS URLs.');
  }
  final uri = safePublicHttpsUri(value);
  if (uri == null || value.contains('#')) {
    _unsafe('Aniyomi resources must use public HTTPS URLs without fragments.');
  }
  // Inspect the original path, before Uri normalizes literal dot segments.
  final beforeQuery = value.split('?').first;
  final pathStart = beforeQuery.indexOf('/', 'https://'.length);
  final suffix = pathStart < 0 ? '' : beforeQuery.substring(pathStart);
  for (final segment in suffix.split('/')) {
    String decoded;
    try {
      decoded = Uri.decodeComponent(segment);
    } on FormatException {
      _unsafe('Malformed URL path encoding in Aniyomi resource.');
    } on ArgumentError {
      _unsafe('Malformed URL path encoding in Aniyomi resource.');
    }
    if (decoded == '.' ||
        decoded == '..' ||
        decoded.contains('%') ||
        decoded.contains('/') ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(decoded)) {
      _unsafe('Ambiguous or traversing Aniyomi resource path.');
    }
  }
  return uri;
}

Never _limit(String message) =>
    _fail(AniyomiRepositoryParseError.limitExceeded, message);
Never _invalid(String message) =>
    _fail(AniyomiRepositoryParseError.invalidDocument, message);
Never _unsafe(String message) =>
    _fail(AniyomiRepositoryParseError.unsafeResource, message);
Never _fail(AniyomiRepositoryParseError code, String message) =>
    throw AniyomiRepositoryParseException(code, message);
