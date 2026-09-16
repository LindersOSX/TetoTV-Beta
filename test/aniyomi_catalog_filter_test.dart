import 'package:anime_tv/features/aniyomi/domain/aniyomi_catalog_filter.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('regional language groups do not alter catalog metadata', () {
    final brazilian = _extension('pt-BR');
    final portugal = _extension('pt_PT');
    final catalog = [brazilian, portugal, _extension('en')];
    expect(aniyomiCatalogLanguages(catalog, mangaEnabled: true), ['en', 'pt']);
    expect(filterAniyomiCatalog(catalog, mangaEnabled: true, language: 'PT'), [
      brazilian,
      portugal,
    ]);
    expect(brazilian.language, 'pt-BR');
    expect(portugal.language, 'pt_PT');
  });

  test(
    'multilingual sources expose explicit languages without inventing any',
    () {
      final multilingual = _extension(
        'all',
        sourceLanguages: ['en', 'es', 'all'],
      );
      final unspecified = _extension('all', sourceLanguages: ['all']);
      final catalog = [multilingual, unspecified, _extension('fr')];
      expect(aniyomiCatalogLanguages(catalog, mangaEnabled: true), [
        'all',
        'en',
        'es',
        'fr',
      ]);
      expect(
        filterAniyomiCatalog(catalog, mangaEnabled: true, language: 'en'),
        [multilingual],
      );
      expect(
        filterAniyomiCatalog(catalog, mangaEnabled: true, language: 'all'),
        [multilingual, unspecified],
      );
      expect(
        filterAniyomiCatalog(catalog, mangaEnabled: true, language: 'hi'),
        isEmpty,
      );
      expect(filterAniyomiCatalog(catalog, mangaEnabled: true), catalog);
    },
  );

  test('manga opt-out applies to options and filtered results', () {
    final manga = _extension('ja', kind: AniyomiMediaKind.manga);
    final anime = _extension('en');
    final catalog = [manga, anime];
    expect(aniyomiCatalogLanguages(catalog, mangaEnabled: false), ['en']);
    expect(filterAniyomiCatalog(catalog, mangaEnabled: false), [anime]);
    expect(
      filterAniyomiCatalog(catalog, mangaEnabled: false, language: 'ja'),
      isEmpty,
    );
    expect(aniyomiCatalogLanguages(catalog, mangaEnabled: true), ['en', 'ja']);
    expect(filterAniyomiCatalog(catalog, mangaEnabled: true), [manga, anime]);
  });

  test('search combines with language and keeps original ordering', () {
    final first = _extension('en', name: 'Example One');
    final second = _extension('es', name: 'Example Two');
    final third = _extension('en', name: 'Another');
    final catalog = List<AniyomiRepositoryExtension>.unmodifiable([
      first,
      second,
      third,
    ]);
    expect(
      filterAniyomiCatalog(
        catalog,
        mangaEnabled: true,
        language: 'en',
        query: '  eXample  ',
      ),
      [first],
    );
    expect(filterAniyomiCatalog(catalog, mangaEnabled: true), [
      first,
      second,
      third,
    ]);
  });

  test('source language tags can be searched inside multilingual APKs', () {
    final extension = _extension('all', sourceLanguages: ['pt-BR', 'en']);
    expect(
      filterAniyomiCatalog(
        [extension],
        mangaEnabled: true,
        language: 'pt',
        query: 'pt-BR',
      ),
      [extension],
    );
  });

  test('empty, unknown, future tags and case aliases remain usable', () {
    expect(aniyomiCatalogLanguageCode(''), 'unknown');
    expect(aniyomiCatalogLanguageCode('unknown'), 'unknown');
    expect(aniyomiCatalogLanguageCode('MULTI'), 'all');
    expect(aniyomiCatalogLanguageCode('  ZH_hant '), 'zh');
    final future = _extension('xx');
    expect(filterAniyomiCatalog([future], mangaEnabled: true, language: 'XX'), [
      future,
    ]);
  });
}

AniyomiRepositoryExtension _extension(
  String language, {
  String name = 'Fixture',
  AniyomiMediaKind kind = AniyomiMediaKind.anime,
  List<String> sourceLanguages = const [],
}) => AniyomiRepositoryExtension(
  kind: kind,
  packageName: 'test.fixture.extension',
  name: name,
  versionName: '1.0',
  versionCode: 1,
  extensionLib: '14',
  apkUri: Uri.parse('https://catalog.example.test/fixture.apk'),
  iconUri: Uri.parse('https://catalog.example.test/icon.png'),
  language: language,
  isNsfw: false,
  isTorrent: false,
  sources: [
    for (var i = 0; i < sourceLanguages.length; i++)
      AniyomiRepositorySource(
        kind: kind,
        id: '$i',
        name: 'Fixture source $i',
        language: sourceLanguages[i],
      ),
  ],
);
