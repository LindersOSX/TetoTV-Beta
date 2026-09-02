import 'dart:io';

import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'runs the Seanime manga provider contract in the sandbox',
    () async {
      final provider = SeanimeJavascriptMangaProvider(
        _mangaAddon('''
        class Provider {
          getSettings() { return {supportsMultiLanguage: true}; }
          async search(opts) {
            return [{
              id: 'frieren',
              title: "Frieren: Beyond Journey's End",
              synonyms: ['Sousou no Frieren'],
              year: opts.year,
              image: 'https://images.example.test/frieren.jpg',
              imageHeaders: {Referer: 'https://reader.example.test/'},
            }];
          }
          async findChapters(id) {
            return [{
              id: id + ':12',
              url: 'https://reader.example.test/manga/' + id,
              title: 'Chapter 12',
              chapter: '12',
              index: 11,
              scanlator: 'Example',
              language: 'en',
            }];
          }
          async findChapterPages(id) {
            return [{
              url: 'https://cdn.example.test/' + encodeURIComponent(id) + '/1.jpg',
              index: 0,
              headers: {Referer: 'https://reader.example.test/'},
            }];
          }
        }
      '''),
        validateResultTarget: (_) async {},
      );

      final results = await provider.search('Frieren', year: 2023);
      expect(results, hasLength(1));
      expect(results.single.id, 'frieren');
      expect(results.single.year, 2023);
      expect(results.single.synonyms, ['Sousou no Frieren']);
      expect(results.single.imageHeaders['Referer'], isNotEmpty);

      final chapters = await provider.findChapters(results.single.id);
      expect(chapters, hasLength(1));
      expect(chapters.single.chapterNumber, 12);
      expect(chapters.single.scanlator, 'Example');

      final pages = await provider.findChapterPages(chapters.single.id);
      expect(pages, hasLength(1));
      expect(pages.single.index, 0);
      expect(pages.single.headers['Referer'], isNotEmpty);
    },
    skip: _windowsQuickJsSkip,
  );

  test(
    'drops unsafe artwork and page targets returned by an extension',
    () async {
      final provider = SeanimeJavascriptMangaProvider(
        _mangaAddon('''
        class Provider {
          async search() {
            return [{id: 'safe-id', title: 'Safe title', image: 'http://example.test/a.jpg'}];
          }
          async findChapters() {
            return [{id: 'chapter-1', title: 'Chapter 1', chapter: '1', index: 0}];
          }
          async findChapterPages() {
            return [{url: 'https://127.0.0.1/private.jpg', index: 0}];
          }
        }
      '''),
        validateResultTarget: (_) async {},
      );

      final results = await provider.search('Safe');
      expect(results.single.image, isNull);
      await expectLater(
        provider.findChapterPages('chapter-1'),
        throwsA(isA<StateError>()),
      );
    },
    skip: _windowsQuickJsSkip,
  );

  test(
    'accepts the chapter shape used by current community providers',
    () async {
      final provider = SeanimeJavascriptMangaProvider(
        _mangaAddon('''
        class Provider {
          async search() { return []; }
          async findChapters() {
            // MangaBuddy's current Seanime provider omits `index` in this
            // otherwise canonical ChapterDetails shape.
            return [
              {id: 'chapter-1', url: 'https://reader.example.test/1', title: 'Chapter 1', chapter: '1'},
              {id: 'chapter-2', url: 'https://reader.example.test/2', title: 'Chapter 2', chapter: '2'},
            ];
          }
          async findChapterPages() { return []; }
        }
      '''),
        validateResultTarget: (_) async {},
      );

      final chapters = await provider.findChapters('fixture');

      expect(chapters.map((chapter) => chapter.id), <String>[
        'chapter-1',
        'chapter-2',
      ]);
      expect(chapters.map((chapter) => chapter.index), <int>[0, 1]);
    },
    skip: _windowsQuickJsSkip,
  );

  test(
    'does not swallow cancellation during result target validation',
    () async {
      final cancellation = WebProviderCancellation();
      final provider = SeanimeJavascriptMangaProvider(
        _mangaAddon('''
        class Provider {
          async search() {
            return [{id: 'fixture', title: 'Fixture', image: 'https://images.example.test/cover.jpg'}];
          }
          async findChapters() { return []; }
          async findChapterPages() { return []; }
        }
      '''),
        validateResultTarget: (_) async => cancellation.cancel(),
      );

      await expectLater(
        provider.search('fixture', cancellation: cancellation),
        throwsA(isA<WebProviderSearchCancelled>()),
      );
    },
    skip: _windowsQuickJsSkip,
  );

  test(
    'bounds manga page output before it leaves the sandbox',
    () async {
      final provider = SeanimeJavascriptMangaProvider(
        _mangaAddon('''
        class Provider {
          async search() { return []; }
          async findChapters() { return []; }
          async findChapterPages() {
            return Array.from({length: 1200}, (_, index) => ({
              url: 'https://cdn.example.test/pages/' + index + '.jpg',
              index: index,
              headers: {},
              ignored: 'x'.repeat(4096),
            }));
          }
        }
      '''),
        validateResultTarget: (_) async {},
      );

      final pages = await provider.findChapterPages('chapter');

      expect(pages, hasLength(1000));
      expect(pages.last.index, 999);
    },
    skip: _windowsQuickJsSkip,
  );

  test('does not run a video extension as a manga provider', () async {
    final addon = _mangaAddon('class Provider {}');
    final video = InstalledStreamingAddon(
      manifest: MarketplaceAddon(
        id: addon.manifest.id,
        name: addon.manifest.name,
        description: '',
        author: 'Test',
        manifestUri: addon.manifest.manifestUri,
        repositoryUrl: addon.manifest.repositoryUrl,
        language: 'javascript',
        type: 'onlinestream-provider',
        locale: 'en',
      ),
      payload: addon.payload,
      enabled: true,
      installedAt: addon.installedAt,
      updatedAt: addon.updatedAt,
    );
    final provider = SeanimeJavascriptMangaProvider(
      video,
      validateResultTarget: (_) async {},
    );
    await expectLater(provider.search('test'), throwsA(isA<FormatException>()));
  });
}

final Object _windowsQuickJsSkip = Platform.isWindows
    ? 'flutter_js loads its bridge from the packaged Windows app.'
    : false;

InstalledStreamingAddon _mangaAddon(String payload) {
  final now = DateTime.utc(2026, 1, 1);
  return InstalledStreamingAddon(
    manifest: MarketplaceAddon(
      id: 'fixture-manga',
      name: 'Fixture Manga',
      description: 'Synthetic test provider',
      author: 'TetoTV tests',
      manifestUri: Uri.parse('https://repo.example.test/manifest.json'),
      repositoryUrl: 'https://repo.example.test/marketplace.json',
      language: 'javascript',
      type: 'manga-provider',
      locale: 'en',
      version: '1.0.0',
      payloadUri: Uri.parse('https://repo.example.test/provider.js'),
    ),
    payload: payload,
    enabled: true,
    installedAt: now,
    updatedAt: now,
  );
}
