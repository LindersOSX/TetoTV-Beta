import 'dart:math' as math;

import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:flutter/foundation.dart';

/// The direction in which logical pages advance.
enum MangaReadingOrder { rightToLeft, leftToRight }

/// Whether the paged reader displays one page or a two-page spread.
enum MangaSpreadPreference { automatic, singlePage, doublePage }

enum MangaFoldOrientation { vertical, horizontal }

/// Pure geometry derived from a platform display feature.
///
/// The presentation layer can map a separating Flutter display feature into
/// this object without making the layout engine depend on a device API.
@immutable
class MangaFoldGeometry {
  const MangaFoldGeometry({
    required this.orientation,
    required this.separating,
    required this.firstPaneExtent,
    required this.secondPaneExtent,
    this.gutterExtent = 0,
  }) : assert(firstPaneExtent >= 0),
       assert(secondPaneExtent >= 0),
       assert(gutterExtent >= 0);

  final MangaFoldOrientation orientation;
  final bool separating;
  final double firstPaneExtent;
  final double secondPaneExtent;
  final double gutterExtent;
}

/// Viewport information used by automatic spread selection.
@immutable
class MangaSpreadDecisionInput {
  const MangaSpreadDecisionInput({
    required this.viewportWidth,
    required this.viewportHeight,
    this.preference = MangaSpreadPreference.automatic,
    this.fold,
    this.allowSpreads = true,
    this.minimumAutomaticPageExtent = 320,
    this.minimumAutomaticAspectRatio = 1.2,
  }) : assert(viewportWidth > 0),
       assert(viewportHeight > 0),
       assert(minimumAutomaticPageExtent > 0),
       assert(minimumAutomaticAspectRatio > 0);

  final double viewportWidth;
  final double viewportHeight;
  final MangaSpreadPreference preference;
  final MangaFoldGeometry? fold;

  /// False for continuous vertical/webtoon presentation.
  final bool allowSpreads;
  final double minimumAutomaticPageExtent;
  final double minimumAutomaticAspectRatio;
}

/// Returns whether a paged reader should create two-page spreads.
bool shouldUseMangaDoublePages(MangaSpreadDecisionInput input) {
  if (!input.allowSpreads) {
    return false;
  }
  switch (input.preference) {
    case MangaSpreadPreference.singlePage:
      return false;
    case MangaSpreadPreference.doublePage:
      return true;
    case MangaSpreadPreference.automatic:
      final fold = input.fold;
      if (fold != null && fold.separating) {
        if (fold.orientation == MangaFoldOrientation.horizontal) {
          return false;
        }
        return fold.firstPaneExtent >= input.minimumAutomaticPageExtent &&
            fold.secondPaneExtent >= input.minimumAutomaticPageExtent;
      }

      final halfWidth = input.viewportWidth / 2;
      return input.viewportWidth / input.viewportHeight >=
              input.minimumAutomaticAspectRatio &&
          halfWidth >= input.minimumAutomaticPageExtent;
  }
}

/// A physical spread. [leftPage] and [rightPage] describe screen placement;
/// [pagesInReadingOrder] always follows the chapter's logical page order.
@immutable
class MangaPageSpread {
  MangaPageSpread._({
    required this.index,
    required this.leftPage,
    required this.rightPage,
    required Iterable<MangaReaderPage> pagesInReadingOrder,
  }) : pagesInReadingOrder = List<MangaReaderPage>.unmodifiable(
         pagesInReadingOrder,
       );

  final int index;
  final MangaReaderPage? leftPage;
  final MangaReaderPage? rightPage;
  final List<MangaReaderPage> pagesInReadingOrder;

  bool get isSingleton => pagesInReadingOrder.length == 1;
  bool get isWideSingleton =>
      isSingleton && pagesInReadingOrder.single.isWide();
  int get anchorPageIndex => pagesInReadingOrder.first.index;

  bool containsPageIndex(int pageIndex) =>
      pagesInReadingOrder.any((page) => page.index == pageIndex);
}

/// Stable reading position used when spread geometry changes at runtime.
@immutable
class MangaPageAnchor {
  MangaPageAnchor({
    required String pageId,
    required this.pageIndex,
    this.fractionWithinPage = 0,
  }) : pageId = pageId.trim() {
    if (this.pageId.isEmpty) {
      throw ArgumentError.value(pageId, 'pageId', 'Page ID is required.');
    }
    if (pageIndex < 0) {
      throw ArgumentError.value(pageIndex, 'pageIndex');
    }
    if (!fractionWithinPage.isFinite ||
        fractionWithinPage < 0 ||
        fractionWithinPage > 1) {
      throw ArgumentError.value(
        fractionWithinPage,
        'fractionWithinPage',
        'Must be between zero and one.',
      );
    }
  }

  final String pageId;
  final int pageIndex;
  final double fractionWithinPage;
}

/// Immutable page-to-spread mapping for one chapter and viewport state.
@immutable
class MangaSpreadLayout {
  MangaSpreadLayout._({
    required this.readingOrder,
    required this.usesDoublePages,
    required this.gutterExtent,
    required Iterable<MangaPageSpread> spreads,
  }) : spreads = List<MangaPageSpread>.unmodifiable(spreads),
       _spreadByPageIndex = <int, int>{
         for (final spread in spreads)
           for (final page in spread.pagesInReadingOrder)
             page.index: spread.index,
       },
       _pageById = <String, MangaReaderPage>{
         for (final spread in spreads)
           for (final page in spread.pagesInReadingOrder) page.id: page,
       },
       _pageByIndex = <int, MangaReaderPage>{
         for (final spread in spreads)
           for (final page in spread.pagesInReadingOrder) page.index: page,
       };

  final MangaReadingOrder readingOrder;
  final bool usesDoublePages;
  final double gutterExtent;
  final List<MangaPageSpread> spreads;
  final Map<int, int> _spreadByPageIndex;
  final Map<String, MangaReaderPage> _pageById;
  final Map<int, MangaReaderPage> _pageByIndex;

  MangaPageSpread spreadForPage(int pageIndex) =>
      spreads[spreadIndexForPage(pageIndex)];

  int spreadIndexForPage(int pageIndex) {
    final result = _spreadByPageIndex[pageIndex];
    if (result == null) {
      throw RangeError.index(pageIndex, _spreadByPageIndex, 'pageIndex');
    }
    return result;
  }

  MangaPageAnchor anchorForPage(
    int pageIndex, {
    double fractionWithinPage = 0,
  }) {
    final page = _pageByIndex[pageIndex];
    if (page == null) {
      throw RangeError.index(pageIndex, _pageByIndex, 'pageIndex');
    }
    return MangaPageAnchor(
      pageId: page.id,
      pageIndex: page.index,
      fractionWithinPage: fractionWithinPage,
    );
  }

  MangaPageAnchor anchorForSpread(
    int spreadIndex, {
    int? activePageIndex,
    double fractionWithinPage = 0,
  }) {
    final spread = spreads[spreadIndex];
    final activePage = activePageIndex == null
        ? null
        : _pageByIndex[activePageIndex];
    final page =
        activePage != null && spread.containsPageIndex(activePage.index)
        ? activePage
        : spread.pagesInReadingOrder.first;
    return MangaPageAnchor(
      pageId: page.id,
      pageIndex: page.index,
      fractionWithinPage: fractionWithinPage,
    );
  }

  /// Finds the new spread for an anchor captured from a previous layout.
  ///
  /// The stable page ID wins. The bounded logical index is a fallback for a
  /// refreshed chapter whose page IDs changed while its order stayed stable.
  int spreadIndexForAnchor(MangaPageAnchor anchor) {
    final exactPage = _pageById[anchor.pageId];
    if (exactPage != null) {
      return spreadIndexForPage(exactPage.index);
    }
    final boundedPageIndex = anchor.pageIndex.clamp(0, _pageByIndex.length - 1);
    return spreadIndexForPage(boundedPageIndex);
  }

  /// Normalizes an old anchor to a page that exists in this layout.
  MangaPageAnchor resolveAnchor(MangaPageAnchor anchor) {
    final exactPage = _pageById[anchor.pageId];
    final page =
        exactPage ??
        _pageByIndex[anchor.pageIndex.clamp(0, _pageByIndex.length - 1)]!;
    return MangaPageAnchor(
      pageId: page.id,
      pageIndex: page.index,
      fractionWithinPage: anchor.fractionWithinPage,
    );
  }
}

class MangaSpreadLayoutEngine {
  const MangaSpreadLayoutEngine();

  MangaSpreadLayout build({
    required List<MangaReaderPage> pages,
    required MangaReadingOrder readingOrder,
    required MangaSpreadDecisionInput decision,
    bool coverStartsAlone = true,
    double widePageAspectRatio = 1.15,
    double pageGutterExtent = 12,
  }) {
    if (pages.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'Pages cannot be empty.');
    }
    if (!widePageAspectRatio.isFinite || widePageAspectRatio <= 1) {
      throw ArgumentError.value(widePageAspectRatio, 'widePageAspectRatio');
    }
    if (!pageGutterExtent.isFinite || pageGutterExtent < 0) {
      throw ArgumentError.value(pageGutterExtent, 'pageGutterExtent');
    }
    for (var index = 0; index < pages.length; index += 1) {
      if (pages[index].index != index) {
        throw ArgumentError.value(
          pages[index].index,
          'pages',
          'Page indexes must be contiguous and in reading order.',
        );
      }
    }

    final useDoublePages = shouldUseMangaDoublePages(decision);
    final fold = decision.fold;
    final gutterExtent =
        fold != null &&
            fold.separating &&
            fold.orientation == MangaFoldOrientation.vertical
        ? math.max(pageGutterExtent, fold.gutterExtent)
        : pageGutterExtent;
    final spreads = <MangaPageSpread>[];
    var pageIndex = 0;
    while (pageIndex < pages.length) {
      final first = pages[pageIndex];
      final mustStandAlone =
          !useDoublePages ||
          first.isWide(minimumAspectRatio: widePageAspectRatio) ||
          (coverStartsAlone && (pageIndex == 0 || first.isCover));
      if (mustStandAlone || pageIndex + 1 >= pages.length) {
        spreads.add(
          _singletonSpread(
            index: spreads.length,
            page: first,
            readingOrder: readingOrder,
          ),
        );
        pageIndex += 1;
        continue;
      }

      final second = pages[pageIndex + 1];
      if (second.isWide(minimumAspectRatio: widePageAspectRatio) ||
          (coverStartsAlone && second.isCover)) {
        spreads.add(
          _singletonSpread(
            index: spreads.length,
            page: first,
            readingOrder: readingOrder,
          ),
        );
        pageIndex += 1;
        continue;
      }

      final leftPage = readingOrder == MangaReadingOrder.leftToRight
          ? first
          : second;
      final rightPage = readingOrder == MangaReadingOrder.leftToRight
          ? second
          : first;
      spreads.add(
        MangaPageSpread._(
          index: spreads.length,
          leftPage: leftPage,
          rightPage: rightPage,
          pagesInReadingOrder: <MangaReaderPage>[first, second],
        ),
      );
      pageIndex += 2;
    }

    return MangaSpreadLayout._(
      readingOrder: readingOrder,
      usesDoublePages: useDoublePages,
      gutterExtent: gutterExtent,
      spreads: spreads,
    );
  }

  MangaPageSpread _singletonSpread({
    required int index,
    required MangaReaderPage page,
    required MangaReadingOrder readingOrder,
  }) {
    return MangaPageSpread._(
      index: index,
      leftPage: readingOrder == MangaReadingOrder.leftToRight ? page : null,
      rightPage: readingOrder == MangaReadingOrder.rightToLeft ? page : null,
      pagesInReadingOrder: <MangaReaderPage>[page],
    );
  }
}
