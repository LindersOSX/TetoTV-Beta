import 'package:anime_tv/features/manga/data/manga_parse_support.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';

class Opds2CatalogParser {
  const Opds2CatalogParser({this.limits = const MangaParseLimits()});

  final MangaParseLimits limits;

  MangaCatalogFeed parse(String payload, {required Uri documentUri}) {
    final safeDocumentUri = requireMangaPublicHttpsUri(
      documentUri.toString(),
      field: 'OPDS document URL',
    );
    final decoded = decodeBoundedJson(payload, limits, format: 'OPDS 2');
    final root = requiredStringMap(decoded, field: 'feed');
    final metadata = requiredStringMap(
      root['metadata'],
      field: 'feed.metadata',
    );
    final context = _Opds2Context(limits, safeDocumentUri);

    final numberOfItems = _optionalNonNegativeInteger(
      metadata['numberOfItems'],
      field: 'feed.metadata.numberOfItems',
    );

    return MangaCatalogFeed(
      protocol: MangaSourceProtocol.opds2,
      documentUri: safeDocumentUri,
      identifier: context.optionalLocalizedText(
        metadata['identifier'],
        field: 'feed.metadata.identifier',
      ),
      title: context.requiredLocalizedText(
        metadata['title'],
        field: 'feed.metadata.title',
      ),
      subtitle: context.optionalLocalizedText(
        metadata['subtitle'],
        field: 'feed.metadata.subtitle',
      ),
      modified: optionalDateTime(
        metadata['modified'],
        field: 'feed.metadata.modified',
      ),
      numberOfItems: numberOfItems,
      links: context.parseLinks(root['links'], field: 'feed.links'),
      publications: context.parsePublications(
        root['publications'],
        field: 'feed.publications',
      ),
      navigation: context.parseNavigation(
        root['navigation'],
        field: 'feed.navigation',
      ),
      groups: context.parseGroups(root['groups'], field: 'feed.groups'),
      facets: context.parseGroups(root['facets'], field: 'feed.facets'),
    );
  }
}

class _Opds2Context {
  _Opds2Context(this.limits, this.documentUri);

  final MangaParseLimits limits;
  final Uri documentUri;
  var _links = 0;
  var _entries = 0;

  List<MangaCatalogLink> parseLinks(Object? value, {required String field}) {
    final rawLinks = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxLinks,
      allowSingle: true,
    );
    final result = <MangaCatalogLink>[];
    for (var index = 0; index < rawLinks.length; index++) {
      _links += 1;
      if (_links > limits.maxLinks) {
        throw const FormatException('OPDS 2 feed contains too many links.');
      }
      final linkField = '$field[$index]';
      final link = requiredStringMap(rawLinks[index], field: linkField);
      final href = requiredText(
        link['href'],
        field: '$linkField.href',
        maxCharacters: 2048,
      );
      result.add(
        MangaCatalogLink(
          uri: resolveMangaPublicHttpsReference(
            documentUri,
            href,
            field: '$linkField.href',
          ),
          relations: _parseRelations(link['rel'], field: '$linkField.rel'),
          mediaType: optionalText(
            link['type'],
            field: '$linkField.type',
            maxCharacters: 256,
          ),
          title: optionalLocalizedText(
            link['title'],
            field: '$linkField.title',
          ),
          properties: _parseProperties(
            link['properties'],
            field: '$linkField.properties',
          ),
        ),
      );
    }
    return result;
  }

  List<MangaPublication> parsePublications(
    Object? value, {
    required String field,
  }) {
    final rawPublications = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxEntries,
    );
    final result = <MangaPublication>[];
    for (var index = 0; index < rawPublications.length; index++) {
      _countEntry();
      final publicationField = '$field[$index]';
      final publication = requiredStringMap(
        rawPublications[index],
        field: publicationField,
      );
      final metadata = requiredStringMap(
        publication['metadata'],
        field: '$publicationField.metadata',
      );
      result.add(
        MangaPublication(
          identifier: optionalLocalizedText(
            metadata['identifier'],
            field: '$publicationField.metadata.identifier',
          ),
          title: requiredLocalizedText(
            metadata['title'],
            field: '$publicationField.metadata.title',
          ),
          subtitle: optionalLocalizedText(
            metadata['subtitle'],
            field: '$publicationField.metadata.subtitle',
          ),
          description: optionalLocalizedText(
            metadata['description'],
            field: '$publicationField.metadata.description',
            long: true,
          ),
          modified: optionalDateTime(
            metadata['modified'],
            field: '$publicationField.metadata.modified',
          ),
          authors: _parseContributors(
            metadata['author'] ?? metadata['authors'],
            field: '$publicationField.metadata.author',
          ),
          languages: _parseStringList(
            metadata['language'],
            field: '$publicationField.metadata.language',
          ),
          subjects: _parseSubjects(
            metadata['subject'],
            field: '$publicationField.metadata.subject',
          ),
          links: parseLinks(
            publication['links'],
            field: '$publicationField.links',
          ),
          images: parseLinks(
            publication['images'],
            field: '$publicationField.images',
          ),
          readingOrder: parseLinks(
            publication['readingOrder'],
            field: '$publicationField.readingOrder',
          ),
          resources: parseLinks(
            publication['resources'],
            field: '$publicationField.resources',
          ),
        ),
      );
    }
    return result;
  }

  List<MangaNavigationItem> parseNavigation(
    Object? value, {
    required String field,
  }) {
    final rawNavigation = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxEntries,
    );
    final result = <MangaNavigationItem>[];
    for (var index = 0; index < rawNavigation.length; index++) {
      _countEntry();
      final itemField = '$field[$index]';
      final item = requiredStringMap(rawNavigation[index], field: itemField);
      final links = item.containsKey('href')
          ? parseLinks(item, field: '$itemField.link')
          : parseLinks(item['links'], field: '$itemField.links');
      final title =
          optionalLocalizedText(item['title'], field: '$itemField.title') ??
          (links.isEmpty ? null : links.first.title);
      if (title == null) throw FormatException('$itemField.title is required.');
      result.add(
        MangaNavigationItem(
          identifier: optionalLocalizedText(
            item['identifier'],
            field: '$itemField.identifier',
          ),
          title: title,
          subtitle: optionalLocalizedText(
            item['subtitle'],
            field: '$itemField.subtitle',
          ),
          links: links,
        ),
      );
    }
    return result;
  }

  List<MangaCatalogGroup> parseGroups(Object? value, {required String field}) {
    final rawGroups = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxEntries,
    );
    final result = <MangaCatalogGroup>[];
    for (var index = 0; index < rawGroups.length; index++) {
      _countEntry();
      final groupField = '$field[$index]';
      final group = requiredStringMap(rawGroups[index], field: groupField);
      final metadata = group['metadata'] == null
          ? const <String, Object?>{}
          : requiredStringMap(group['metadata'], field: '$groupField.metadata');
      result.add(
        MangaCatalogGroup(
          title: requiredLocalizedText(
            metadata['title'] ?? group['title'],
            field: '$groupField.title',
          ),
          links: parseLinks(group['links'], field: '$groupField.links'),
          publications: parsePublications(
            group['publications'],
            field: '$groupField.publications',
          ),
          navigation: parseNavigation(
            group['navigation'],
            field: '$groupField.navigation',
          ),
        ),
      );
    }
    return result;
  }

  List<MangaContributor> _parseContributors(
    Object? value, {
    required String field,
  }) {
    final items = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxContributorsPerPublication,
      allowSingle: true,
    );
    final result = <MangaContributor>[];
    for (var index = 0; index < items.length; index++) {
      final contributorField = '$field[$index]';
      final item = items[index];
      if (item is String) {
        result.add(
          MangaContributor(
            name: requiredText(
              item,
              field: contributorField,
              maxCharacters: limits.maxShortTextCharacters,
            ),
          ),
        );
        continue;
      }
      final contributor = requiredStringMap(item, field: contributorField);
      result.add(
        MangaContributor(
          name: requiredLocalizedText(
            contributor['name'],
            field: '$contributorField.name',
          ),
          identifier: optionalLocalizedText(
            contributor['identifier'],
            field: '$contributorField.identifier',
          ),
          sortAs: optionalLocalizedText(
            contributor['sortAs'],
            field: '$contributorField.sortAs',
          ),
        ),
      );
    }
    return result;
  }

  List<String> _parseStringList(Object? value, {required String field}) {
    final items = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxListItemsPerField,
      allowSingle: true,
    );
    return <String>[
      for (var index = 0; index < items.length; index++)
        requiredLocalizedText(items[index], field: '$field[$index]'),
    ];
  }

  List<String> _parseSubjects(Object? value, {required String field}) {
    final items = optionalObjectList(
      value,
      field: field,
      maximum: limits.maxListItemsPerField,
      allowSingle: true,
    );
    final subjects = <String>[];
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item is Map) {
        final subject = requiredStringMap(item, field: '$field[$index]');
        subjects.add(
          requiredLocalizedText(subject['name'], field: '$field[$index].name'),
        );
      } else {
        subjects.add(requiredLocalizedText(item, field: '$field[$index]'));
      }
    }
    return subjects;
  }

  String requiredLocalizedText(
    Object? value, {
    required String field,
    bool long = false,
  }) {
    final result = optionalLocalizedText(value, field: field, long: long);
    if (result == null) throw FormatException('$field is required.');
    return result;
  }

  String? optionalLocalizedText(
    Object? value, {
    required String field,
    bool long = false,
  }) {
    if (value == null) return null;
    final maximum = long
        ? limits.maxLongTextCharacters
        : limits.maxShortTextCharacters;
    if (value is String) {
      return optionalText(value, field: field, maxCharacters: maximum);
    }
    if (value is List) {
      if (value.length > limits.maxListItemsPerField) {
        throw FormatException('$field contains too many localized values.');
      }
      for (var index = 0; index < value.length; index++) {
        final candidate = optionalLocalizedText(
          value[index],
          field: '$field[$index]',
          long: long,
        );
        if (candidate != null) return candidate;
      }
      return null;
    }
    if (value is Map) {
      final localized = requiredStringMap(value, field: field);
      if (localized.containsKey('value')) {
        return optionalLocalizedText(
          localized['value'],
          field: '$field.value',
          long: long,
        );
      }
      for (final entry in localized.entries) {
        final candidate = optionalLocalizedText(
          entry.value,
          field: '$field.${entry.key}',
          long: long,
        );
        if (candidate != null) return candidate;
      }
      return null;
    }
    throw FormatException('$field must be text or localized text.');
  }

  Set<String> _parseRelations(Object? value, {required String field}) {
    if (value == null) return const <String>{};
    final relations = <String>{};
    if (value is String) {
      relations.addAll(
        value.trim().split(RegExp(r'\s+')).where((item) => item.isNotEmpty),
      );
    } else if (value is List) {
      if (value.length > limits.maxListItemsPerField) {
        throw FormatException('$field contains too many relations.');
      }
      for (var index = 0; index < value.length; index++) {
        relations.add(
          requiredText(
            value[index],
            field: '$field[$index]',
            maxCharacters: 512,
          ),
        );
      }
    } else {
      throw FormatException('$field must be a string or array.');
    }
    return relations;
  }

  Map<String, Object?> _parseProperties(
    Object? value, {
    required String field,
  }) {
    if (value == null) return const <String, Object?>{};
    return requiredStringMap(value, field: field);
  }

  void _countEntry() {
    _entries += 1;
    if (_entries > limits.maxEntries) {
      throw const FormatException('OPDS 2 feed contains too many entries.');
    }
  }
}

int? _optionalNonNegativeInteger(Object? value, {required String field}) {
  if (value == null) return null;
  if (value is! num || value != value.roundToDouble() || value < 0) {
    throw FormatException('$field must be a non-negative integer.');
  }
  return value.toInt();
}
