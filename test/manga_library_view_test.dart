import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/presentation/manga_library_view.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final when = DateTime.utc(2026, 9, 5);
  MangaLibraryEntry entry(
    String id, {
    String category = '',
    int updates = 0,
    MangaLibraryStatus status = MangaLibraryStatus.planToRead,
  }) => MangaLibraryEntry(
    ownerKey: 'owner',
    sourceId: 'source',
    entryId: id,
    title: id,
    metadata: const {},
    updatedAt: when,
    category: category,
    newChapterCount: updates,
    status: status,
  );
  final entries = [
    entry('Beta', category: 'Favorites', updates: 2),
    entry('Alpha', status: MangaLibraryStatus.reading),
    entry('Gamma'),
  ];
  test(
    'library search filters category, status, updates without changing source data',
    () {
      final found = filterMangaLibrary(
        entries: entries,
        progress: const [],
        downloads: const [],
        query: '  bETA ',
        category: 'Favorites',
        updatesOnly: true,
      );
      expect(found.map((e) => e.entryId), ['Beta']);
      expect(entries.first.entryId, 'Beta');
      expect(
        filterMangaLibrary(
          entries: entries,
          progress: const [],
          downloads: const [],
          status: MangaLibraryStatus.reading,
        ).single.entryId,
        'Alpha',
      );
    },
  );
  test('library recently-read sorting uses the selected profile history', () {
    final progress = [
      MangaReadingProgress(
        ownerKey: 'owner',
        sourceId: 'source',
        entryId: 'Gamma',
        chapterId: 'chapter',
        pageIndex: 2,
        pageOffset: .4,
        completed: false,
        updatedAt: when,
      ),
    ];
    final found = filterMangaLibrary(
      entries: entries,
      progress: progress,
      downloads: const [],
      sort: MangaLibrarySort.recentlyRead,
    );
    expect(found.map((e) => e.entryId), ['Gamma', 'Alpha', 'Beta']);
    expect(
      filterMangaLibrary(
        entries: entries,
        progress: progress,
        downloads: const [],
        downloadedOnly: true,
      ),
      isEmpty,
    );
  });
  MangaExtensionChapter chapter(String number, int index) =>
      MangaExtensionChapter(
        id: '$number-$index',
        title: 'Chapter $number',
        chapter: number,
        index: index,
      );
  test(
    'numeric chapters sort in reading order without mutating provider data',
    () {
      final input = [chapter('10', 0), chapter('2', 1), chapter('1', 2)];
      expect(orderedMangaChapters(input).map((c) => c.chapter), [
        '1',
        '2',
        '10',
      ]);
      expect(input.first.chapter, '10');
    },
  );
  test('specials and duplicate chapter variants retain source ordering', () {
    expect(
      orderedMangaChapters([
        chapter('Extra', 2),
        chapter('1', 0),
        chapter('2', 1),
      ]).map((c) => c.chapter),
      ['1', '2', 'Extra'],
    );
    expect(
      orderedMangaChapters([
        chapter('1', 2),
        chapter('2', 0),
        chapter('1', 1),
      ]).map((c) => c.index),
      [0, 1, 2],
    );
  });
}
