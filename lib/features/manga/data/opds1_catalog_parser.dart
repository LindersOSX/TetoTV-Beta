import 'package:anime_tv/features/manga/data/manga_parse_support.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';
import 'package:xml/xml.dart';

class Opds1CatalogParser {
  const Opds1CatalogParser({this.limits = const MangaParseLimits()});

  final MangaParseLimits limits;

  MangaCatalogFeed parse(String payload, {required Uri documentUri}) {
    final safeDocumentUri = requireMangaPublicHttpsUri(
      documentUri.toString(),
      field: 'OPDS document URL',
    );
    requireBoundedPayload(payload, limits, format: 'OPDS 1');
    if (RegExp(
      r'<!\s*(doctype|entity)',
      caseSensitive: false,
    ).hasMatch(payload)) {
      throw const FormatException('OPDS 1 DTDs and entities are not allowed.');
    }
    if (RegExp(r'<[A-Za-z_:]').allMatches(payload).length > limits.maxNodes) {
      throw const FormatException('OPDS 1 document has too many elements.');
    }

    final XmlDocument document;
    try {
      document = XmlDocument.parse(payload);
    } on XmlParserException catch (error) {
      throw FormatException('Invalid OPDS 1 XML: ${error.message}');
    }
    _validateTree(document);

    final root = document.rootElement;
    if (root.name.local != 'feed' ||
        root.name.namespaceUri != 'http://www.w3.org/2005/Atom') {
      throw const FormatException('OPDS 1 root element must be an Atom feed.');
    }

    final entries = _children(root, 'entry').toList(growable: false);
    if (entries.length > limits.maxEntries) {
      throw const FormatException('OPDS 1 feed contains too many entries.');
    }

    var linkCount = 0;
    List<MangaCatalogLink> linksFor(XmlElement element, String field) {
      final parsed = <MangaCatalogLink>[];
      for (final link in _children(element, 'link')) {
        linkCount += 1;
        if (linkCount > limits.maxLinks) {
          throw const FormatException('OPDS 1 feed contains too many links.');
        }
        parsed.add(_parseLink(link, safeDocumentUri, field));
      }
      return parsed;
    }

    final publications = <MangaPublication>[];
    final navigation = <MangaNavigationItem>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final field = 'entries[$index]';
      final links = linksFor(entry, '$field.links');
      final title = _requiredChildText(entry, 'title', '$field.title');
      final identifier = _optionalChildText(entry, 'id', '$field.id');
      final subtitle = _optionalChildText(entry, 'subtitle', '$field.subtitle');
      if (!links.any((link) => link.isAcquisition)) {
        navigation.add(
          MangaNavigationItem(
            identifier: identifier,
            title: title,
            subtitle: subtitle,
            links: links,
          ),
        );
        continue;
      }

      final authors = _children(entry, 'author').toList(growable: false);
      if (authors.length > limits.maxContributorsPerPublication) {
        throw FormatException('$field.authors contains too many items.');
      }
      final languages = _directChildTexts(entry, 'language', '$field.language');
      final subjects = <String>[];
      for (final category in _children(entry, 'category')) {
        final term = optionalText(
          category.getAttribute('term'),
          field: '$field.category.term',
          maxCharacters: limits.maxShortTextCharacters,
        );
        if (term != null) subjects.add(term);
      }
      if (subjects.length > limits.maxListItemsPerField) {
        throw FormatException('$field.categories contains too many items.');
      }

      publications.add(
        MangaPublication(
          identifier: identifier,
          title: title,
          subtitle: subtitle,
          description:
              _optionalChildText(
                entry,
                'summary',
                '$field.summary',
                long: true,
              ) ??
              _optionalChildText(
                entry,
                'content',
                '$field.content',
                long: true,
              ),
          modified: _optionalChildDate(entry, 'updated', '$field.updated'),
          authors: <MangaContributor>[
            for (
              var authorIndex = 0;
              authorIndex < authors.length;
              authorIndex++
            )
              _parseAuthor(
                authors[authorIndex],
                '$field.authors[$authorIndex]',
              ),
          ],
          languages: languages,
          subjects: subjects,
          links: links,
          images: links.where((link) => link.isCover),
        ),
      );
    }

    final numberOfItemsText = _optionalChildText(
      root,
      'totalResults',
      'feed.totalResults',
    );
    final numberOfItems = numberOfItemsText == null
        ? null
        : int.tryParse(numberOfItemsText);
    if (numberOfItemsText != null &&
        (numberOfItems == null || numberOfItems < 0)) {
      throw const FormatException(
        'feed.totalResults must be a non-negative integer.',
      );
    }

    return MangaCatalogFeed(
      protocol: MangaSourceProtocol.opds1,
      documentUri: safeDocumentUri,
      identifier: _optionalChildText(root, 'id', 'feed.id'),
      title: _requiredChildText(root, 'title', 'feed.title'),
      subtitle: _optionalChildText(root, 'subtitle', 'feed.subtitle'),
      modified: _optionalChildDate(root, 'updated', 'feed.updated'),
      numberOfItems: numberOfItems,
      links: linksFor(root, 'feed.links'),
      publications: publications,
      navigation: navigation,
    );
  }

  MangaCatalogLink _parseLink(
    XmlElement element,
    Uri documentUri,
    String field,
  ) {
    final href = requiredText(
      element.getAttribute('href'),
      field: '$field.href',
      maxCharacters: 2048,
    );
    final relations = _relations(element.getAttribute('rel'));
    return MangaCatalogLink(
      uri: resolveMangaPublicHttpsReference(
        documentUri,
        href,
        field: '$field.href',
      ),
      relations: relations,
      mediaType: optionalText(
        element.getAttribute('type'),
        field: '$field.type',
        maxCharacters: 256,
      ),
      title: optionalText(
        element.getAttribute('title'),
        field: '$field.title',
        maxCharacters: limits.maxShortTextCharacters,
      ),
    );
  }

  MangaContributor _parseAuthor(XmlElement author, String field) {
    return MangaContributor(
      name: _requiredChildText(author, 'name', '$field.name'),
      identifier: _optionalChildText(author, 'uri', '$field.uri'),
    );
  }

  List<String> _directChildTexts(
    XmlElement parent,
    String localName,
    String field,
  ) {
    final elements = _children(parent, localName).toList(growable: false);
    if (elements.length > limits.maxListItemsPerField) {
      throw FormatException('$field contains too many items.');
    }
    return <String>[
      for (var index = 0; index < elements.length; index++)
        requiredText(
          elements[index].innerText,
          field: '$field[$index]',
          maxCharacters: limits.maxShortTextCharacters,
        ),
    ];
  }

  DateTime? _optionalChildDate(
    XmlElement parent,
    String localName,
    String field,
  ) {
    return optionalDateTime(
      _optionalChildText(parent, localName, field),
      field: field,
    );
  }

  String _requiredChildText(
    XmlElement parent,
    String localName,
    String field, {
    bool long = false,
  }) {
    final element = _firstChild(parent, localName);
    return requiredText(
      element?.innerText,
      field: field,
      maxCharacters: long
          ? limits.maxLongTextCharacters
          : limits.maxShortTextCharacters,
    );
  }

  String? _optionalChildText(
    XmlElement parent,
    String localName,
    String field, {
    bool long = false,
  }) {
    final element = _firstChild(parent, localName);
    return optionalText(
      element?.innerText,
      field: field,
      maxCharacters: long
          ? limits.maxLongTextCharacters
          : limits.maxShortTextCharacters,
    );
  }

  void _validateTree(XmlDocument document) {
    var nodes = 0;
    final stack = <(XmlNode, int)>[(document, 0)];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      nodes += 1;
      if (nodes > limits.maxNodes) {
        throw const FormatException('OPDS 1 document has too many nodes.');
      }
      if (current.$2 > limits.maxDepth) {
        throw const FormatException('OPDS 1 document is nested too deeply.');
      }
      for (final child in current.$1.children) {
        stack.add((child, current.$2 + 1));
      }
    }
  }
}

Iterable<XmlElement> _children(XmlElement parent, String localName) =>
    parent.childElements.where((element) => element.name.local == localName);

XmlElement? _firstChild(XmlElement parent, String localName) {
  for (final element in parent.childElements) {
    if (element.name.local == localName) return element;
  }
  return null;
}

Set<String> _relations(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return const <String>{};
  return Set<String>.unmodifiable(
    text.split(RegExp(r'\s+')).where((item) => item.isNotEmpty),
  );
}
