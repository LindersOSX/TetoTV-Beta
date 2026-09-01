import 'package:anime_tv/features/manga/data/manga_parse_support.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';

/// Parses TetoTV's deliberately data-only repository format.
///
/// Version 1 can point at OPDS catalogs and describe authentication metadata,
/// but it has no executable payload, script, package, or embedded credential
/// fields. Unknown keys fail closed instead of being silently activated later.
class TetoMangaRepositoryParser {
  const TetoMangaRepositoryParser({this.limits = const MangaParseLimits()});

  final MangaParseLimits limits;

  MangaRepositoryManifest parse(String payload, {required Uri documentUri}) {
    final safeDocumentUri = requireMangaPublicHttpsUri(
      documentUri.toString(),
      field: 'Repository document URL',
    );
    final decoded = decodeBoundedJson(
      payload,
      limits,
      format: 'TetoTV manga repository',
    );
    final root = requiredStringMap(decoded, field: 'repository');
    requireOnlyKeys(root, _rootKeys, field: 'repository');

    if (root['format'] != MangaRepositoryManifest.format) {
      throw const FormatException(
        'repository.format must be "tetotv-manga-repository".',
      );
    }
    if (root['schemaVersion'] is! int ||
        root['schemaVersion'] != MangaRepositoryManifest.schemaVersion) {
      throw const FormatException(
        'Only manga repository schemaVersion 1 is supported.',
      );
    }

    final rawSources = optionalObjectList(
      root['sources'],
      field: 'repository.sources',
      maximum: limits.maxSources,
    );
    if (rawSources.isEmpty) {
      throw const FormatException('repository.sources must not be empty.');
    }
    final sourceIds = <String>{};
    final sources = <MangaSourceDescriptor>[];
    for (var index = 0; index < rawSources.length; index++) {
      final source = _parseSource(
        rawSources[index],
        index: index,
        documentUri: safeDocumentUri,
      );
      if (!sourceIds.add(source.id)) {
        throw FormatException('Duplicate manga source id "${source.id}".');
      }
      sources.add(source);
    }

    return MangaRepositoryManifest(
      id: _requiredIdentifier(root['id'], field: 'repository.id'),
      name: requiredText(
        root['name'],
        field: 'repository.name',
        maxCharacters: limits.maxShortTextCharacters,
      ),
      description: optionalText(
        root['description'],
        field: 'repository.description',
        maxCharacters: limits.maxLongTextCharacters,
      ),
      documentUri: safeDocumentUri,
      homepage: _optionalUri(
        root['homepage'],
        documentUri: safeDocumentUri,
        field: 'repository.homepage',
      ),
      icon: _optionalUri(
        root['icon'],
        documentUri: safeDocumentUri,
        field: 'repository.icon',
      ),
      sources: sources,
    );
  }

  MangaSourceDescriptor _parseSource(
    Object? value, {
    required int index,
    required Uri documentUri,
  }) {
    final field = 'repository.sources[$index]';
    final source = requiredStringMap(value, field: field);
    requireOnlyKeys(source, _sourceKeys, field: field);
    final protocolText = requiredText(
      source['protocol'],
      field: '$field.protocol',
      maxCharacters: 32,
    );
    final protocol = switch (protocolText) {
      'opds1' => MangaSourceProtocol.opds1,
      'opds2' => MangaSourceProtocol.opds2,
      _ => throw FormatException('$field.protocol must be "opds1" or "opds2".'),
    };

    return MangaSourceDescriptor(
      id: _requiredIdentifier(source['id'], field: '$field.id'),
      name: requiredText(
        source['name'],
        field: '$field.name',
        maxCharacters: limits.maxShortTextCharacters,
      ),
      description: optionalText(
        source['description'],
        field: '$field.description',
        maxCharacters: limits.maxLongTextCharacters,
      ),
      protocol: protocol,
      entryPoint: resolveMangaPublicHttpsReference(
        documentUri,
        source['entryPoint'],
        field: '$field.entryPoint',
      ),
      homepage: _optionalUri(
        source['homepage'],
        documentUri: documentUri,
        field: '$field.homepage',
      ),
      icon: _optionalUri(
        source['icon'],
        documentUri: documentUri,
        field: '$field.icon',
      ),
      authentication: _parseAuthentication(
        source['authentication'],
        field: '$field.authentication',
      ),
      languages: _parseLanguages(
        source['languages'],
        field: '$field.languages',
      ),
      contentRatings: _parseEnumList(
        source['contentRatings'],
        field: '$field.contentRatings',
        allowed: _contentRatings,
        fallback: const <String>['unknown'],
      ),
      capabilities: _parseEnumList(
        source['capabilities'],
        field: '$field.capabilities',
        allowed: _capabilities,
        fallback: const <String>['browse'],
      ),
    );
  }

  MangaSourceAuthentication _parseAuthentication(
    Object? value, {
    required String field,
  }) {
    if (value == null) return const MangaSourceAuthentication();
    final authentication = requiredStringMap(value, field: field);
    requireOnlyKeys(authentication, _authenticationKeys, field: field);
    final type = requiredText(
      authentication['type'],
      field: '$field.type',
      maxCharacters: 32,
    );
    final kind = switch (type) {
      'none' => MangaSourceAuthenticationKind.none,
      'basic' => MangaSourceAuthenticationKind.basic,
      'bearer' => MangaSourceAuthenticationKind.bearer,
      'apiKey' => MangaSourceAuthenticationKind.apiKey,
      _ => throw FormatException('$field.type is not supported.'),
    };
    final headerName = optionalText(
      authentication['headerName'],
      field: '$field.headerName',
      maxCharacters: 128,
    );
    if (kind == MangaSourceAuthenticationKind.apiKey) {
      if (headerName == null || !_headerName.hasMatch(headerName)) {
        throw FormatException('$field.headerName is required for apiKey auth.');
      }
      if (_blockedHeaders.contains(headerName.toLowerCase())) {
        throw FormatException('$field.headerName is reserved.');
      }
    } else if (headerName != null) {
      throw FormatException('$field.headerName is only valid for apiKey auth.');
    }
    return MangaSourceAuthentication(kind: kind, headerName: headerName);
  }

  List<String> _parseLanguages(Object? value, {required String field}) {
    final languages = _parseStringList(value, field: field);
    for (final language in languages) {
      if (!_languageTag.hasMatch(language)) {
        throw FormatException('$field contains an invalid language tag.');
      }
    }
    return languages;
  }

  List<String> _parseEnumList(
    Object? value, {
    required String field,
    required Set<String> allowed,
    required List<String> fallback,
  }) {
    if (value == null) return fallback;
    final result = _parseStringList(value, field: field);
    if (result.isEmpty) throw FormatException('$field must not be empty.');
    for (final item in result) {
      if (!allowed.contains(item)) {
        throw FormatException('$field contains unsupported value "$item".');
      }
    }
    return result;
  }

  List<String> _parseStringList(Object? value, {required String field}) {
    final items = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxListItemsPerField,
    );
    final seen = <String>{};
    final result = <String>[];
    for (var index = 0; index < items.length; index++) {
      final item = requiredText(
        items[index],
        field: '$field[$index]',
        maxCharacters: 128,
      );
      if (!seen.add(item)) throw FormatException('$field contains duplicates.');
      result.add(item);
    }
    return result;
  }

  Uri? _optionalUri(
    Object? value, {
    required Uri documentUri,
    required String field,
  }) {
    if (value == null) return null;
    return resolveMangaPublicHttpsReference(documentUri, value, field: field);
  }

  String _requiredIdentifier(Object? value, {required String field}) {
    final identifier = requiredText(value, field: field, maxCharacters: 128);
    if (!_identifier.hasMatch(identifier)) {
      throw FormatException('$field is not a valid stable identifier.');
    }
    return identifier;
  }
}

const Set<String> _rootKeys = <String>{
  'format',
  'schemaVersion',
  'id',
  'name',
  'description',
  'homepage',
  'icon',
  'sources',
};

const Set<String> _sourceKeys = <String>{
  'id',
  'name',
  'description',
  'protocol',
  'entryPoint',
  'homepage',
  'icon',
  'authentication',
  'languages',
  'contentRatings',
  'capabilities',
};

const Set<String> _authenticationKeys = <String>{'type', 'headerName'};
const Set<String> _contentRatings = <String>{
  'safe',
  'suggestive',
  'adult',
  'unknown',
};
const Set<String> _capabilities = <String>{
  'browse',
  'search',
  'download',
  'progressSync',
  'pageStreaming',
};
const Set<String> _blockedHeaders = <String>{
  'authorization',
  'cookie',
  'host',
  'origin',
  'referer',
  'proxy-authorization',
  'proxy-connection',
  'transfer-encoding',
};

final RegExp _identifier = RegExp(r'^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$');
final RegExp _languageTag = RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$');
final RegExp _headerName = RegExp(r"^[!#\$%&'*+.^_`|~0-9A-Za-z-]+$");
