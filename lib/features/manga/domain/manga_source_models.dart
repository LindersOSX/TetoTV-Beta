enum MangaSourceProtocol { opds1, opds2 }

enum MangaSourceAuthenticationKind { none, basic, bearer, apiKey }

class MangaCatalogLink {
  MangaCatalogLink({
    required this.uri,
    Iterable<String> relations = const <String>[],
    this.mediaType,
    this.title,
    Map<String, Object?> properties = const <String, Object?>{},
  }) : relations = Set<String>.unmodifiable(relations),
       properties = Map<String, Object?>.unmodifiable(properties);

  final Uri uri;
  final Set<String> relations;
  final String? mediaType;
  final String? title;
  final Map<String, Object?> properties;

  bool get isAcquisition => relations.any(
    (relation) =>
        relation == 'http://opds-spec.org/acquisition' ||
        relation.startsWith('http://opds-spec.org/acquisition/'),
  );

  bool get isCover => relations.any(
    (relation) =>
        relation == 'http://opds-spec.org/image' ||
        relation == 'http://opds-spec.org/image/thumbnail' ||
        relation == 'cover' ||
        relation == 'thumbnail',
  );
}

class MangaContributor {
  const MangaContributor({required this.name, this.identifier, this.sortAs});

  final String name;
  final String? identifier;
  final String? sortAs;
}

class MangaPublication {
  MangaPublication({
    required this.title,
    this.identifier,
    this.subtitle,
    this.description,
    this.modified,
    Iterable<MangaContributor> authors = const <MangaContributor>[],
    Iterable<String> languages = const <String>[],
    Iterable<String> subjects = const <String>[],
    Iterable<MangaCatalogLink> links = const <MangaCatalogLink>[],
    Iterable<MangaCatalogLink> images = const <MangaCatalogLink>[],
    Iterable<MangaCatalogLink> readingOrder = const <MangaCatalogLink>[],
    Iterable<MangaCatalogLink> resources = const <MangaCatalogLink>[],
  }) : authors = List<MangaContributor>.unmodifiable(authors),
       languages = List<String>.unmodifiable(languages),
       subjects = List<String>.unmodifiable(subjects),
       links = List<MangaCatalogLink>.unmodifiable(links),
       images = List<MangaCatalogLink>.unmodifiable(images),
       readingOrder = List<MangaCatalogLink>.unmodifiable(readingOrder),
       resources = List<MangaCatalogLink>.unmodifiable(resources);

  final String? identifier;
  final String title;
  final String? subtitle;
  final String? description;
  final DateTime? modified;
  final List<MangaContributor> authors;
  final List<String> languages;
  final List<String> subjects;
  final List<MangaCatalogLink> links;
  final List<MangaCatalogLink> images;
  final List<MangaCatalogLink> readingOrder;
  final List<MangaCatalogLink> resources;

  Iterable<MangaCatalogLink> get acquisitionLinks =>
      links.where((link) => link.isAcquisition);
}

class MangaNavigationItem {
  MangaNavigationItem({
    required this.title,
    this.identifier,
    this.subtitle,
    Iterable<MangaCatalogLink> links = const <MangaCatalogLink>[],
  }) : links = List<MangaCatalogLink>.unmodifiable(links);

  final String? identifier;
  final String title;
  final String? subtitle;
  final List<MangaCatalogLink> links;
}

class MangaCatalogGroup {
  MangaCatalogGroup({
    required this.title,
    Iterable<MangaCatalogLink> links = const <MangaCatalogLink>[],
    Iterable<MangaPublication> publications = const <MangaPublication>[],
    Iterable<MangaNavigationItem> navigation = const <MangaNavigationItem>[],
  }) : links = List<MangaCatalogLink>.unmodifiable(links),
       publications = List<MangaPublication>.unmodifiable(publications),
       navigation = List<MangaNavigationItem>.unmodifiable(navigation);

  final String title;
  final List<MangaCatalogLink> links;
  final List<MangaPublication> publications;
  final List<MangaNavigationItem> navigation;
}

class MangaCatalogFeed {
  MangaCatalogFeed({
    required this.protocol,
    required this.documentUri,
    required this.title,
    this.identifier,
    this.subtitle,
    this.modified,
    this.numberOfItems,
    Iterable<MangaCatalogLink> links = const <MangaCatalogLink>[],
    Iterable<MangaPublication> publications = const <MangaPublication>[],
    Iterable<MangaNavigationItem> navigation = const <MangaNavigationItem>[],
    Iterable<MangaCatalogGroup> groups = const <MangaCatalogGroup>[],
    Iterable<MangaCatalogGroup> facets = const <MangaCatalogGroup>[],
  }) : links = List<MangaCatalogLink>.unmodifiable(links),
       publications = List<MangaPublication>.unmodifiable(publications),
       navigation = List<MangaNavigationItem>.unmodifiable(navigation),
       groups = List<MangaCatalogGroup>.unmodifiable(groups),
       facets = List<MangaCatalogGroup>.unmodifiable(facets);

  final MangaSourceProtocol protocol;
  final Uri documentUri;
  final String? identifier;
  final String title;
  final String? subtitle;
  final DateTime? modified;
  final int? numberOfItems;
  final List<MangaCatalogLink> links;
  final List<MangaPublication> publications;
  final List<MangaNavigationItem> navigation;
  final List<MangaCatalogGroup> groups;
  final List<MangaCatalogGroup> facets;
}

class MangaSourceAuthentication {
  const MangaSourceAuthentication({
    this.kind = MangaSourceAuthenticationKind.none,
    this.headerName,
  });

  final MangaSourceAuthenticationKind kind;
  final String? headerName;
}

class MangaSourceDescriptor {
  MangaSourceDescriptor({
    required this.id,
    required this.name,
    required this.protocol,
    required this.entryPoint,
    this.description,
    this.homepage,
    this.icon,
    this.authentication = const MangaSourceAuthentication(),
    Iterable<String> languages = const <String>[],
    Iterable<String> contentRatings = const <String>[],
    Iterable<String> capabilities = const <String>[],
  }) : languages = List<String>.unmodifiable(languages),
       contentRatings = Set<String>.unmodifiable(contentRatings),
       capabilities = Set<String>.unmodifiable(capabilities);

  final String id;
  final String name;
  final String? description;
  final MangaSourceProtocol protocol;
  final Uri entryPoint;
  final Uri? homepage;
  final Uri? icon;
  final MangaSourceAuthentication authentication;
  final List<String> languages;
  final Set<String> contentRatings;
  final Set<String> capabilities;
}

class MangaRepositoryManifest {
  MangaRepositoryManifest({
    required this.id,
    required this.name,
    required this.documentUri,
    required Iterable<MangaSourceDescriptor> sources,
    this.description,
    this.homepage,
    this.icon,
  }) : sources = List<MangaSourceDescriptor>.unmodifiable(sources);

  static const String format = 'tetotv-manga-repository';
  static const int schemaVersion = 1;

  final String id;
  final String name;
  final String? description;
  final Uri documentUri;
  final Uri? homepage;
  final Uri? icon;
  final List<MangaSourceDescriptor> sources;
}
