import 'package:anime_tv/features/manga/application/manga_continue_policy.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MangaReadingProgress row(
    String id, {
    bool read = false,
    int page = 0,
    int time = 1,
  }) => MangaReadingProgress(
    ownerKey: 'owner',
    sourceId: 'source',
    entryId: 'entry',
    chapterId: id,
    pageIndex: page,
    pageOffset: 0,
    completed: read,
    updatedAt: DateTime.utc(2026, 9, time),
  );
  test('new title starts at first chapter', () {
    expect(
      selectMangaContinueChapter(
        orderedChapterIds: ['1', '2', '3'],
        history: [],
      ),
      '1',
    );
  });
  test('continue advances from last finished chapter before older gaps', () {
    final last = row('2', read: true);
    expect(
      selectMangaContinueChapter(
        orderedChapterIds: ['1', '2', '3'],
        history: [last],
        lastRead: last,
      ),
      '3',
    );
  });
  test('newest unfinished chapter with real progress wins', () {
    final active = row('1', page: 3, time: 2);
    final last = row('2', read: true, time: 3);
    expect(
      selectMangaContinueChapter(
        orderedChapterIds: ['1', '2', '3'],
        history: [active, last, row('3', time: 4)],
        lastRead: last,
      ),
      '1',
    );
  });
  test('bookmarked unread chapter does not steal Continue', () {
    final last = row('1', read: true);
    expect(
      selectMangaContinueChapter(
        orderedChapterIds: ['1', '2', '3'],
        history: [last, row('3', time: 3)],
        lastRead: last,
      ),
      '2',
    );
  });
  test('completed final chapter falls back to earlier unread gaps', () {
    final last = row('3', read: true);
    expect(
      selectMangaContinueChapter(
        orderedChapterIds: ['1', '2', '3'],
        history: [last, row('1', read: true)],
        lastRead: last,
      ),
      '2',
    );
  });
  test('unavailable chapters are never selected', () {
    final last = row('gone', page: 5);
    expect(
      selectMangaContinueChapter(
        orderedChapterIds: ['2'],
        history: [last],
        lastRead: last,
      ),
      '2',
    );
  });
  test('all read and empty catalogs have no Continue target', () {
    expect(
      selectMangaContinueChapter(
        orderedChapterIds: ['1', '2'],
        history: [row('1', read: true), row('2', read: true)],
      ),
      isNull,
    );
    expect(
      selectMangaContinueChapter(orderedChapterIds: [], history: []),
      isNull,
    );
  });
}
