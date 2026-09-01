import 'dart:convert';

import 'package:anime_tv/features/manga/manga_source_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('manga public HTTPS policy', () {
    test('rebases relative references and removes fragments', () {
      final resolved = resolveMangaPublicHttpsReference(
        Uri.parse('https://catalog.example/opds/root.json'),
        '../covers/one.jpg#preview',
        field: 'cover',
      );

      expect(resolved.toString(), 'https://catalog.example/covers/one.jpg');
    });

    test('rejects credentials, insecure URLs, and private targets', () {
      for (final value in <String>[
        'http://catalog.example/opds',
        'https://user:secret@catalog.example/opds',
        'https://127.0.0.1/opds',
        'https://192.168.1.4/opds',
        'https://catalog.local/opds',
        r'..\private\catalog.json',
      ]) {
        expect(
          () => resolveMangaPublicHttpsReference(
            Uri.parse('https://catalog.example/root.json'),
            value,
            field: 'catalog',
          ),
          throwsFormatException,
          reason: value,
        );
      }
    });

    test('rejects credential-bearing URLs at the persistence boundary', () {
      for (final value in <String>[
        'https://images.example/cover.jpg?token=secret',
        'https://images.example/cover.jpg?api_key=secret',
        'https://images.example/cover.jpg?X-Amz-Signature=secret',
        'https://images.example/cover.jpg?sig=secret',
      ]) {
        expect(
          () => requireMangaPersistablePublicHttpsUri(value, field: 'cover'),
          throwsFormatException,
          reason: value,
        );
      }

      expect(
        requireMangaPersistablePublicHttpsUri(
          'https://images.example/cover.jpg?width=800&format=webp',
          field: 'cover',
        ).toString(),
        'https://images.example/cover.jpg?width=800&format=webp',
      );
    });
  });

  group('OPDS 1 parser', () {
    const parser = Opds1CatalogParser();
    final documentUri = Uri.parse('https://catalog.example/opds/root.xml');

    test('parses acquisition and navigation entries with relative links', () {
      final feed = parser.parse(_opds1Feed, documentUri: documentUri);

      expect(feed.protocol, MangaSourceProtocol.opds1);
      expect(feed.title, 'Test library');
      expect(feed.numberOfItems, 2);
      expect(feed.publications, hasLength(1));
      expect(feed.navigation, hasLength(1));
      expect(feed.links.single.uri.toString(), documentUri.toString());

      final publication = feed.publications.single;
      expect(publication.identifier, 'urn:book:1');
      expect(publication.title, 'Volume One');
      expect(publication.authors.single.name, 'Example Author');
      expect(publication.languages, <String>['en']);
      expect(publication.subjects, <String>['Adventure']);
      expect(publication.acquisitionLinks, hasLength(1));
      expect(
        publication.images.single.uri.toString(),
        'https://catalog.example/covers/one.jpg',
      );
      expect(
        feed.navigation.single.links.single.uri.toString(),
        'https://catalog.example/opds/popular.xml',
      );
    });

    test('rejects entities and unsafe linked resources', () {
      expect(
        () => parser.parse(
          '<!DOCTYPE feed [<!ENTITY x "bad">]><feed><title>&x;</title></feed>',
          documentUri: documentUri,
        ),
        throwsFormatException,
      );
      expect(
        () => parser.parse(
          _opds1Feed.replaceFirst(
            '../books/one.cbz',
            'http://catalog.example/books/one.cbz',
          ),
          documentUri: documentUri,
        ),
        throwsFormatException,
      );
    });

    test('enforces the configured entry bound', () {
      const bounded = Opds1CatalogParser(
        limits: MangaParseLimits(maxEntries: 1),
      );
      expect(
        () => bounded.parse(_opds1Feed, documentUri: documentUri),
        throwsFormatException,
      );
    });
  });

  group('OPDS 2 parser', () {
    const parser = Opds2CatalogParser();
    final documentUri = Uri.parse('https://catalog.example/opds/root.json');

    test('parses publications, navigation, groups, and localized text', () {
      final feed = parser.parse(_opds2Feed, documentUri: documentUri);

      expect(feed.protocol, MangaSourceProtocol.opds2);
      expect(feed.title, 'JSON library');
      expect(feed.numberOfItems, 1);
      expect(feed.navigation.single.title, 'Popular');
      expect(feed.publications.single.title, 'Volume Two');
      expect(feed.publications.single.authors.single.name, 'Writer');
      expect(feed.publications.single.languages, <String>['en', 'ja']);
      expect(feed.publications.single.subjects, <String>['Fantasy']);
      expect(
        feed.publications.single.images.single.uri.toString(),
        'https://catalog.example/images/two.jpg',
      );
      expect(
        feed.publications.single.acquisitionLinks.single.uri.toString(),
        'https://cdn.example/books/two.cbz',
      );
      expect(feed.groups.single.title, 'Recently added');
    });

    test('rejects unsafe URLs and oversized documents', () {
      final unsafe = _opds2Feed.replaceFirst(
        'https://cdn.example/books/two.cbz',
        'https://10.0.0.2/books/two.cbz',
      );
      expect(
        () => parser.parse(unsafe, documentUri: documentUri),
        throwsFormatException,
      );

      const bounded = Opds2CatalogParser(
        limits: MangaParseLimits(maxPayloadCharacters: 64),
      );
      expect(
        () => bounded.parse(_opds2Feed, documentUri: documentUri),
        throwsFormatException,
      );
    });

    test('enforces a shared entry bound across nested groups', () {
      const bounded = Opds2CatalogParser(
        limits: MangaParseLimits(maxEntries: 2),
      );
      expect(
        () => bounded.parse(_opds2Feed, documentUri: documentUri),
        throwsFormatException,
      );
    });
  });

  group('TetoTV manga repository v1 parser', () {
    const parser = TetoMangaRepositoryParser();
    final documentUri = Uri.parse(
      'https://repositories.example/tetotv/manga.json',
    );

    test('parses declarative OPDS sources without credential material', () {
      final repository = parser.parse(
        _repositoryManifest,
        documentUri: documentUri,
      );

      expect(repository.id, 'example.library');
      expect(repository.sources, hasLength(2));
      expect(
        repository.icon.toString(),
        'https://repositories.example/icon.png',
      );
      expect(repository.sources.first.protocol, MangaSourceProtocol.opds2);
      expect(
        repository.sources.first.entryPoint.toString(),
        'https://repositories.example/tetotv/catalog/v2.json',
      );
      expect(
        repository.sources.first.authentication.kind,
        MangaSourceAuthenticationKind.apiKey,
      );
      expect(repository.sources.first.authentication.headerName, 'X-API-Key');
      expect(repository.sources.last.protocol, MangaSourceProtocol.opds1);
    });

    test('rejects executable fields and unsupported source protocols', () {
      final executable = _manifestMap();
      (executable['sources']! as List<Object?>).first = <String, Object?>{
        ...((executable['sources']! as List<Object?>).first
            as Map<String, Object?>),
        'script': 'alert(1)',
      };
      expect(
        () => parser.parse(jsonEncode(executable), documentUri: documentUri),
        throwsFormatException,
      );

      final apk = _manifestMap();
      ((apk['sources']! as List<Object?>).first
              as Map<String, Object?>)['protocol'] =
          'mihon-apk';
      expect(
        () => parser.parse(jsonEncode(apk), documentUri: documentUri),
        throwsFormatException,
      );
    });

    test('rejects duplicate ids, unsafe endpoints, and embedded secrets', () {
      final duplicate = _manifestMap();
      final sources = duplicate['sources']! as List<Object?>;
      (sources.last as Map<String, Object?>)['id'] = 'opds-json';
      expect(
        () => parser.parse(jsonEncode(duplicate), documentUri: documentUri),
        throwsFormatException,
      );

      final unsafe = _manifestMap();
      ((unsafe['sources']! as List<Object?>).first
              as Map<String, Object?>)['entryPoint'] =
          'http://catalog.example/opds';
      expect(
        () => parser.parse(jsonEncode(unsafe), documentUri: documentUri),
        throwsFormatException,
      );

      final secret = _manifestMap();
      ((secret['sources']! as List<Object?>).first
          as Map<String, Object?>)['authentication'] = <String, Object?>{
        'type': 'apiKey',
        'headerName': 'X-API-Key',
        'value': 'must-not-be-in-a-manifest',
      };
      expect(
        () => parser.parse(jsonEncode(secret), documentUri: documentUri),
        throwsFormatException,
      );
    });
  });
}

const String _opds1Feed = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:dc="http://purl.org/dc/terms/"
      xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
  <id>urn:feed:test</id>
  <title>Test library</title>
  <updated>2026-08-01T12:00:00Z</updated>
  <opensearch:totalResults>2</opensearch:totalResults>
  <link rel="self" type="application/atom+xml;profile=opds-catalog" href="root.xml" />
  <entry>
    <id>urn:book:1</id>
    <title>Volume One</title>
    <updated>2026-07-01T00:00:00Z</updated>
    <summary>An example volume.</summary>
    <author><name>Example Author</name></author>
    <dc:language>en</dc:language>
    <category term="Adventure" />
    <link rel="http://opds-spec.org/acquisition/open-access"
          type="application/vnd.comicbook+zip" href="../books/one.cbz" />
    <link rel="http://opds-spec.org/image"
          type="image/jpeg" href="../covers/one.jpg#full" />
  </entry>
  <entry>
    <id>urn:navigation:popular</id>
    <title>Popular</title>
    <link rel="subsection"
          type="application/atom+xml;profile=opds-catalog;kind=acquisition"
          href="popular.xml" />
  </entry>
</feed>
''';

final String _opds2Feed = jsonEncode(<String, Object?>{
  'metadata': <String, Object?>{
    'title': <String, Object?>{'en': 'JSON library'},
    'identifier': 'urn:feed:json',
    'modified': '2026-08-02T12:00:00Z',
    'numberOfItems': 1,
  },
  'links': <Object?>[
    <String, Object?>{'rel': 'self', 'href': './root.json'},
  ],
  'navigation': <Object?>[
    <String, Object?>{
      'title': 'Popular',
      'href': './popular.json',
      'type': 'application/opds+json',
    },
  ],
  'publications': <Object?>[
    <String, Object?>{
      'metadata': <String, Object?>{
        'identifier': 'urn:book:2',
        'title': 'Volume Two',
        'description': 'A JSON publication.',
        'author': <Object?>[
          <String, Object?>{'name': 'Writer', 'sortAs': 'Writer'},
        ],
        'language': <String>['en', 'ja'],
        'subject': <Object?>[
          <String, Object?>{'name': 'Fantasy'},
        ],
      },
      'links': <Object?>[
        <String, Object?>{
          'rel': 'http://opds-spec.org/acquisition/open-access',
          'href': 'https://cdn.example/books/two.cbz',
          'type': 'application/vnd.comicbook+zip',
        },
      ],
      'images': <Object?>[
        <String, Object?>{
          'rel': 'cover',
          'href': '../images/two.jpg',
          'type': 'image/jpeg',
        },
      ],
    },
  ],
  'groups': <Object?>[
    <String, Object?>{
      'metadata': <String, Object?>{'title': 'Recently added'},
      'navigation': <Object?>[
        <String, Object?>{'title': 'More', 'href': './recent.json'},
      ],
    },
  ],
});

final String _repositoryManifest = jsonEncode(_manifestMap());

Map<String, Object?> _manifestMap() => <String, Object?>{
  'format': 'tetotv-manga-repository',
  'schemaVersion': 1,
  'id': 'example.library',
  'name': 'Example library connectors',
  'description': 'Connector metadata only.',
  'homepage': 'https://repositories.example/',
  'icon': '../icon.png',
  'sources': <Object?>[
    <String, Object?>{
      'id': 'opds-json',
      'name': 'Example OPDS 2',
      'protocol': 'opds2',
      'entryPoint': './catalog/v2.json',
      'languages': <String>['en-US', 'ja'],
      'contentRatings': <String>['safe'],
      'capabilities': <String>['browse', 'search', 'download'],
      'authentication': <String, Object?>{
        'type': 'apiKey',
        'headerName': 'X-API-Key',
      },
    },
    <String, Object?>{
      'id': 'opds-atom',
      'name': 'Example OPDS 1',
      'protocol': 'opds1',
      'entryPoint': 'https://catalog.example/opds/v1',
      'authentication': <String, Object?>{'type': 'basic'},
    },
  ],
};
