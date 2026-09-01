import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_spread_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reader request capabilities', () {
    test('keeps HTTPS headers ephemeral and redacted', () {
      final resource = MangaRemotePageResource(
        uri: Uri.parse('https://reader.example/chapter/page-1.jpg'),
        headers: const <String, String>{'Authorization': 'Bearer secret'},
      );

      expect(resource.headers['Authorization'], 'Bearer secret');
      expect(resource.toString(), isNot(contains('Bearer secret')));
      expect(
        () => resource.headers['Authorization'] = 'changed',
        throwsUnsupportedError,
      );
    });

    test('rejects unsafe remote URLs and headers', () {
      expect(
        () => MangaRemotePageResource(
          uri: Uri.parse('http://reader.example/page.jpg'),
        ),
        throwsArgumentError,
      );
      expect(
        () => MangaRemotePageResource(
          uri: Uri.parse('https://user:secret@reader.example/page.jpg'),
        ),
        throwsArgumentError,
      );
      expect(
        () => MangaRemotePageResource(
          uri: Uri.parse('https://reader.example/page.jpg'),
          headers: const <String, String>{'Authorization': 'ok\r\nbad: yes'},
        ),
        throwsArgumentError,
      );
    });

    test('local page capability accepts only normalized relative paths', () {
      final resource = MangaTrustedLocalPageResource(
        area: MangaLocalStorageArea.downloadedPages,
        relativePath: 'series-id/chapter-id/0001.webp',
      );

      expect(resource.relativePath, 'series-id/chapter-id/0001.webp');
      for (final path in <String>[
        '../secret.jpg',
        '/absolute/page.jpg',
        r'series\page.jpg',
        'series//page.jpg',
        'C:/page.jpg',
      ]) {
        expect(
          () => MangaTrustedLocalPageResource(
            area: MangaLocalStorageArea.downloadedPages,
            relativePath: path,
          ),
          throwsArgumentError,
          reason: path,
        );
      }
    });

    test(
      'request requires stable unique pages in contiguous reading order',
      () {
        final request = _request(_pages(3));
        expect(request.pages.map((page) => page.index), <int>[0, 1, 2]);

        expect(
          () => _request(<MangaReaderPage>[
            _page(0, id: 'same'),
            _page(1, id: 'same'),
          ]),
          throwsArgumentError,
        );
        expect(
          () => _request(<MangaReaderPage>[_page(1)]),
          throwsArgumentError,
        );
      },
    );
  });

  group('spread decision', () {
    test('automatic uses landscape space but not a narrow portrait', () {
      expect(
        shouldUseMangaDoublePages(
          const MangaSpreadDecisionInput(
            viewportWidth: 1920,
            viewportHeight: 1080,
          ),
        ),
        isTrue,
      );
      expect(
        shouldUseMangaDoublePages(
          const MangaSpreadDecisionInput(
            viewportWidth: 800,
            viewportHeight: 1280,
          ),
        ),
        isFalse,
      );
    });

    test('open vertical fold uses both panes and contributes hinge gutter', () {
      const decision = MangaSpreadDecisionInput(
        viewportWidth: 1450,
        viewportHeight: 1000,
        fold: MangaFoldGeometry(
          orientation: MangaFoldOrientation.vertical,
          separating: true,
          firstPaneExtent: 700,
          secondPaneExtent: 710,
          gutterExtent: 40,
        ),
      );
      expect(shouldUseMangaDoublePages(decision), isTrue);

      final layout = const MangaSpreadLayoutEngine().build(
        pages: _pages(4),
        readingOrder: MangaReadingOrder.rightToLeft,
        decision: decision,
        pageGutterExtent: 12,
      );
      expect(layout.gutterExtent, 40);
    });

    test('horizontal or undersized separating folds stay single in auto', () {
      for (final fold in <MangaFoldGeometry>[
        const MangaFoldGeometry(
          orientation: MangaFoldOrientation.horizontal,
          separating: true,
          firstPaneExtent: 600,
          secondPaneExtent: 600,
        ),
        const MangaFoldGeometry(
          orientation: MangaFoldOrientation.vertical,
          separating: true,
          firstPaneExtent: 250,
          secondPaneExtent: 250,
        ),
      ]) {
        expect(
          shouldUseMangaDoublePages(
            MangaSpreadDecisionInput(
              viewportWidth: 1600,
              viewportHeight: 900,
              fold: fold,
            ),
          ),
          isFalse,
        );
      }
    });

    test('explicit and continuous-mode choices win', () {
      expect(
        shouldUseMangaDoublePages(
          const MangaSpreadDecisionInput(
            viewportWidth: 600,
            viewportHeight: 1200,
            preference: MangaSpreadPreference.doublePage,
          ),
        ),
        isTrue,
      );
      expect(
        shouldUseMangaDoublePages(
          const MangaSpreadDecisionInput(
            viewportWidth: 2000,
            viewportHeight: 1000,
            preference: MangaSpreadPreference.doublePage,
            allowSpreads: false,
          ),
        ),
        isFalse,
      );
    });
  });

  group('spread layout', () {
    const engine = MangaSpreadLayoutEngine();
    const doublePages = MangaSpreadDecisionInput(
      viewportWidth: 1920,
      viewportHeight: 1080,
      preference: MangaSpreadPreference.doublePage,
    );

    test('keeps the cover and odd final page alone', () {
      final pages = _pages(6, cover: true);
      final layout = engine.build(
        pages: pages,
        readingOrder: MangaReadingOrder.leftToRight,
        decision: doublePages,
      );

      expect(
        layout.spreads.map(
          (spread) =>
              spread.pagesInReadingOrder.map((page) => page.index).toList(),
        ),
        <List<int>>[
          <int>[0],
          <int>[1, 2],
          <int>[3, 4],
          <int>[5],
        ],
      );
    });

    test('places paired pages physically for LTR and RTL reading', () {
      final pages = _pages(2);
      final ltr = engine.build(
        pages: pages,
        readingOrder: MangaReadingOrder.leftToRight,
        decision: doublePages,
        coverStartsAlone: false,
      );
      final rtl = engine.build(
        pages: pages,
        readingOrder: MangaReadingOrder.rightToLeft,
        decision: doublePages,
        coverStartsAlone: false,
      );

      expect(ltr.spreads.single.leftPage!.index, 0);
      expect(ltr.spreads.single.rightPage!.index, 1);
      expect(rtl.spreads.single.leftPage!.index, 1);
      expect(rtl.spreads.single.rightPage!.index, 0);
      expect(
        rtl.spreads.single.pagesInReadingOrder.map((page) => page.index),
        <int>[0, 1],
      );
    });

    test('wide pages remain single and do not consume a neighbor', () {
      final pages = <MangaReaderPage>[
        _page(0),
        _page(1, width: 1800, height: 1000),
        _page(2),
        _page(3),
      ];
      final layout = engine.build(
        pages: pages,
        readingOrder: MangaReadingOrder.rightToLeft,
        decision: doublePages,
        coverStartsAlone: false,
      );

      expect(
        layout.spreads.map(
          (spread) =>
              spread.pagesInReadingOrder.map((page) => page.index).toList(),
        ),
        <List<int>>[
          <int>[0],
          <int>[1],
          <int>[2, 3],
        ],
      );
      expect(layout.spreads[1].isWideSingleton, isTrue);
    });

    test('single mode creates one spread for every page', () {
      final layout = engine.build(
        pages: _pages(4),
        readingOrder: MangaReadingOrder.rightToLeft,
        decision: const MangaSpreadDecisionInput(
          viewportWidth: 1920,
          viewportHeight: 1080,
          preference: MangaSpreadPreference.singlePage,
        ),
      );

      expect(layout.usesDoublePages, isFalse);
      expect(layout.spreads, hasLength(4));
      expect(layout.spreads.every((spread) => spread.isSingleton), isTrue);
    });

    test('anchor preserves the active page across layout changes', () {
      final pages = _pages(7, cover: true);
      final doubleLayout = engine.build(
        pages: pages,
        readingOrder: MangaReadingOrder.rightToLeft,
        decision: doublePages,
      );
      final singleLayout = engine.build(
        pages: pages,
        readingOrder: MangaReadingOrder.rightToLeft,
        decision: const MangaSpreadDecisionInput(
          viewportWidth: 800,
          viewportHeight: 1280,
          preference: MangaSpreadPreference.singlePage,
        ),
      );
      final oldSpread = doubleLayout.spreadIndexForPage(4);
      final anchor = doubleLayout.anchorForSpread(
        oldSpread,
        activePageIndex: 4,
        fractionWithinPage: 0.35,
      );

      expect(singleLayout.spreadIndexForAnchor(anchor), 4);
      expect(singleLayout.resolveAnchor(anchor).pageId, 'page-4');
      expect(singleLayout.resolveAnchor(anchor).fractionWithinPage, 0.35);
      expect(
        doubleLayout.spreadIndexForAnchor(
          singleLayout.anchorForPage(4, fractionWithinPage: 0.35),
        ),
        oldSpread,
      );
    });

    test('missing stable page ID falls back to a bounded logical index', () {
      final layout = engine.build(
        pages: _pages(4),
        readingOrder: MangaReadingOrder.leftToRight,
        decision: doublePages,
        coverStartsAlone: false,
      );

      expect(
        layout.spreadIndexForAnchor(
          MangaPageAnchor(pageId: 'removed', pageIndex: 99),
        ),
        1,
      );
      expect(
        layout
            .resolveAnchor(MangaPageAnchor(pageId: 'removed', pageIndex: 99))
            .pageIndex,
        3,
      );
    });
  });
}

MangaReaderRequest _request(List<MangaReaderPage> pages) {
  return MangaReaderRequest(
    sourceId: 'source',
    publicationId: 'publication',
    chapterId: 'chapter',
    seriesTitle: 'Series',
    chapterTitle: 'Chapter 1',
    pages: pages,
  );
}

List<MangaReaderPage> _pages(int count, {bool cover = false}) {
  return List<MangaReaderPage>.generate(
    count,
    (index) => _page(index, isCover: cover && index == 0),
  );
}

MangaReaderPage _page(
  int index, {
  String? id,
  int? width,
  int? height,
  bool isCover = false,
}) {
  return MangaReaderPage(
    id: id ?? 'page-$index',
    index: index,
    resource: MangaTrustedLocalPageResource(
      area: MangaLocalStorageArea.downloadedPages,
      relativePath: 'series/chapter/$index.jpg',
    ),
    pixelWidth: width,
    pixelHeight: height,
    isCover: isCover,
  );
}
