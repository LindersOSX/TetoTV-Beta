import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const repository = 'https://example.com/marketplace/main.json';

  group('synthetic user-supplied catalog shapes', () {
    String fixture(String name) =>
        File('test/fixtures/marketplace/$name').readAsStringSync();

    test('catalog retains advisory working and broken status', () {
      const source = 'https://catalog.example/status/marketplace.json';
      final catalog = parseMarketplaceCatalog(
        fixture('status_catalog_excerpt.json'),
        repositoryUrl: source,
      );

      expect(catalog.map((addon) => addon.id), [
        'fixture-broken-en',
        'fixture-working-en',
      ]);
      expect(catalog.map((addon) => addon.locale), ['en', 'en']);
      expect(catalog.first.reportedWorking, isFalse);
      expect(catalog.first.reportedBroken, isTrue);
      expect(catalog.last.reportedWorking, isTrue);
      expect(catalog.last.lastWorkingVersion, '3.10.2');
    });

    test('catalog keeps status unknown when it is absent', () {
      const source = 'https://catalog.example/locales/marketplace.json';
      final catalog = parseMarketplaceCatalog(
        fixture('locale_catalog_excerpt.json'),
        repositoryUrl: source,
      );

      expect(catalog, hasLength(2));
      expect(catalog.map((addon) => addon.locale), ['es', 'en']);
      expect(catalog.every((addon) => addon.reportedWorking == null), isTrue);
      expect(catalog.every((addon) => !addon.reportedBroken), isTrue);
    });

    test('catalog accepts casing drift without changing visible ID', () {
      const source = 'https://catalog.example/case/marketplace.json';
      final catalog = parseMarketplaceCatalog(
        fixture('case_drift_catalog_excerpt.json'),
        repositoryUrl: source,
      );

      expect(catalog, hasLength(2));
      expect(catalog.first.id, 'fixtureCase');
      expect(catalog.first.isCompatible, isTrue);
    });

    test(
      'non-stream catalog is valid but contains no online-stream providers',
      () {
        const source = 'https://catalog.example/non-stream/marketplace.json';
        final catalog = parseMarketplaceCatalog(
          fixture('non_stream_catalog_excerpt.json'),
          repositoryUrl: source,
        );

        expect(catalog, isEmpty);
      },
    );
  });

  test('language browsing works across synthetic catalogs', () {
    final statusCatalog = parseMarketplaceCatalog(
      File(
        'test/fixtures/marketplace/status_catalog_excerpt.json',
      ).readAsStringSync(),
      repositoryUrl: 'https://catalog.example/status/marketplace.json',
    );
    final localeCatalog = parseMarketplaceCatalog(
      File(
        'test/fixtures/marketplace/locale_catalog_excerpt.json',
      ).readAsStringSync(),
      repositoryUrl: 'https://catalog.example/locales/marketplace.json',
    );
    final combined = [...statusCatalog, ...localeCatalog];

    expect(marketplaceCatalogLanguages(combined), ['en', 'es']);
    expect(
      filterAndSortMarketplaceCatalog(
        combined,
        languageCode: 'es',
      ).map((addon) => addon.id),
      ['fixture-es'],
    );
    expect(
      filterAndSortMarketplaceCatalog(
        combined,
        sort: MarketplaceCatalogSort.language,
      ).map((addon) => addon.name),
      [
        'Example English Provider A',
        'Example English Provider B',
        'Example English Provider C',
        'Example Spanish Provider',
      ],
    );
  });

  test('accepts casing-only catalog and manifest ID drift', () {
    final catalog = parseMarketplaceCatalog(
      jsonEncode([
        {
          'id': 'fixtureCase',
          'name': 'Example Case Provider',
          'manifestURI': 'https://catalog.example/case/manifest.json',
          'type': 'onlinestream-provider',
          'language': 'javascript',
        },
      ]),
      repositoryUrl: repository,
    );
    final merged = validateAndMergeMarketplaceManifest(catalog.single, {
      'id': 'fixturecase',
      'name': 'Example Case Provider',
      'manifestURI': 'https://catalog.example/case/manifest.json',
      'payloadURI': 'https://runtime.example/case/provider.ts',
      'type': 'onlinestream-provider',
      'language': 'typescript',
    });

    expect(catalog, hasLength(1));
    expect(merged.id, 'fixtureCase');
    expect(merged.language, 'typescript');
    expect(merged.isCompatible, isTrue);
  });

  test('does not accept a genuinely different manifest identity', () {
    final summary = parseMarketplaceCatalog(
      jsonEncode([
        {
          'id': 'trusted-provider',
          'name': 'Trusted Provider',
          'manifestURI': 'https://example.com/provider/manifest.json',
          'type': 'onlinestream-provider',
          'language': 'javascript',
        },
      ]),
      repositoryUrl: repository,
    ).single;

    expect(
      () => validateAndMergeMarketplaceManifest(summary, {
        'id': 'different-provider',
        'name': 'Different Provider',
        'manifestURI': 'https://example.com/provider/manifest.json',
        'payloadURI': 'https://example.com/provider/provider.js',
        'type': 'onlinestream-provider',
        'language': 'javascript',
      }),
      throwsFormatException,
    );
  });

  test('adapts common wrapped catalogs and URI/language aliases', () {
    final catalog = parseMarketplaceCatalog(
      jsonEncode({
        'data': {
          'providers': [
            {
              'id': 'wrapped-provider',
              'name': 'Wrapped Provider',
              'manifestUrl': 'https://example.com/wrapped/manifest.json',
              'payloadUrl': 'https://example.com/wrapped/provider.js',
              'type': 'onlinestream-provider',
              'language': 'js',
              'locale': 'en',
            },
            {
              'id': 'not-a-stream-provider',
              'name': 'UI plugin',
              'manifestURI': 'https://example.com/plugin/manifest.json',
              'type': 'plugin',
              'language': 'javascript',
            },
          ],
        },
      }),
      repositoryUrl: repository,
    );

    expect(catalog, hasLength(1));
    expect(catalog.single.id, 'wrapped-provider');
    expect(catalog.single.language, 'javascript');
    expect(catalog.single.locale, 'en');
    expect(
      catalog.single.manifestUri,
      Uri.parse('https://example.com/wrapped/manifest.json'),
    );
    expect(
      catalog.single.payloadUri,
      Uri.parse('https://example.com/wrapped/provider.js'),
    );
  });

  test('adapts a bounded ID-keyed catalog map', () {
    final catalog = parseMarketplaceCatalog(
      jsonEncode({
        'marketplace': {
          'extensions': {
            'mapped-provider': {
              'identifier': 'mapped-provider',
              'title': 'Mapped provider',
              'manifest': './mapped/manifest.json',
              'kind': 'anime_stream_provider',
              'runtime': 'js',
            },
          },
        },
      }),
      repositoryUrl: repository,
    );

    expect(catalog, hasLength(1));
    expect(catalog.single.id, 'mapped-provider');
    expect(
      catalog.single.manifestUri,
      Uri.parse('https://example.com/marketplace/mapped/manifest.json'),
    );
  });

  test('unwraps a manifest and preserves catalog-only executable fields', () {
    final summary = parseMarketplaceCatalog(
      jsonEncode([
        {
          'id': 'wrapped-manifest-provider',
          'name': 'Catalog name',
          'description': 'Catalog description',
          'author': 'Catalog author',
          'manifestURI': 'https://example.com/provider/manifest.json',
          'payloadURI': 'https://example.com/provider/provider.js',
          'type': 'onlinestream-provider',
          'language': 'javascript',
          'lang': 'en',
          'workingTag': true,
        },
      ]),
      repositoryUrl: repository,
    ).single;

    final merged = validateAndMergeMarketplaceManifest(summary, {
      'data': {
        'provider': {
          'id': 'WRAPPED-MANIFEST-PROVIDER',
          'name': 'Manifest name',
          'description': '',
          'author': 'Unknown',
          'manifestURI': './manifest.json',
        },
      },
    });

    expect(merged.name, 'Manifest name');
    expect(merged.description, 'Catalog description');
    expect(merged.author, 'Catalog author');
    expect(merged.language, 'javascript');
    expect(merged.type, 'onlinestream-provider');
    expect(merged.reportedWorking, isTrue);
    expect(
      merged.payloadUri,
      Uri.parse('https://example.com/provider/provider.js'),
    );
    expect(merged.isCompatible, isTrue);
  });

  test('still rejects catalogs without a bounded provider list', () {
    expect(
      () => parseMarketplaceCatalog(
        jsonEncode({
          'metadata': {'name': 'not a catalog'},
        }),
        repositoryUrl: repository,
      ),
      throwsFormatException,
    );
  });

  test('rejects wrappers nested beyond the compatibility depth bound', () {
    Object nested = <String, Object?>{'providers': <Object?>[]};
    for (var depth = 0; depth < 9; depth++) {
      nested = <String, Object?>{'data': nested};
    }

    expect(
      () => parseMarketplaceCatalog(
        jsonEncode(nested),
        repositoryUrl: repository,
      ),
      throwsFormatException,
    );
  });
}
