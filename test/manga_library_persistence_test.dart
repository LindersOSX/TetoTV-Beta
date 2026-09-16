import 'dart:io';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/data/manga_library_service.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database database;
  late MangaStore store;
  final now = DateTime.utc(2026, 9, 5);
  MangaLibraryEntry library({
    String source = 'source-a',
    String entry = 'book-a',
  }) => MangaLibraryEntry(
    ownerKey: 'profile',
    sourceId: source,
    entryId: entry,
    title: 'A manga',
    metadata: const {},
    updatedAt: now,
    category: 'Favorites',
    status: MangaLibraryStatus.reading,
  );
  MangaReadingProgress progress(
    String chapter, {
    int page = 3,
    int seconds = 0,
    bool read = false,
  }) => MangaReadingProgress(
    ownerKey: 'profile',
    sourceId: 'source-a',
    entryId: 'book-a',
    chapterId: chapter,
    chapterNumber: double.tryParse(chapter.replaceAll('chapter-', '')),
    pageIndex: page,
    pageOffset: .3,
    pageCount: 20,
    completed: read,
    updatedAt: now.add(Duration(seconds: seconds)),
  );

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: configureTetoTvDatabase,
        onCreate: (db, _) => createMangaTables(db),
        version: 1,
      ),
    );
    store = MangaStore(databaseProvider: () async => database);
  });
  tearDown(() async => database.close());

  test(
    'v13 migration preserves old latest rows and backfills complete chapter state',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'manga-schema-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final path = '${temporary.path}/legacy.db';
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 13,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE manga_library_entries(owner_key TEXT, source_id TEXT, entry_id TEXT, title TEXT, metadata_json TEXT, cover_url TEXT, updated_at INTEGER, PRIMARY KEY(owner_key,source_id,entry_id))',
            );
            await db.execute(
              'CREATE TABLE manga_reading_progress(owner_key TEXT, source_id TEXT, entry_id TEXT, chapter_id TEXT, chapter_number REAL, page_index INTEGER, page_offset REAL, page_count INTEGER, completed INTEGER, updated_at INTEGER, PRIMARY KEY(owner_key,source_id,entry_id))',
            );
            await db.insert('manga_library_entries', {
              'owner_key': 'profile',
              'source_id': 'source-a',
              'entry_id': 'book-a',
              'title': 'Legacy title',
              'metadata_json': '{}',
              'updated_at': 1,
            });
            await db.insert('manga_reading_progress', {
              'owner_key': 'profile',
              'source_id': 'source-a',
              'entry_id': 'book-a',
              'chapter_id': 'chapter-4',
              'chapter_number': 4.5,
              'page_index': 12,
              'page_offset': .75,
              'page_count': 30,
              'completed': 1,
              'updated_at': 2,
            });
          },
        ),
      );
      await legacy.close();
      final upgraded = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: tetoTvDatabaseSchemaVersion,
          onUpgrade: upgradeTetoTvDatabaseSchema,
        ),
      );
      addTearDown(upgraded.close);
      final old = await upgraded.query('manga_reading_progress');
      final chapters = await upgraded.query('manga_chapter_progress');
      expect(old, hasLength(1));
      expect(chapters.single, containsPair('bookmarked', 0));
      for (final item in old.single.entries) {
        expect(chapters.single[item.key], item.value);
      }
      expect(
        (await upgraded.query('manga_library_entries')).single,
        containsPair('title', 'Legacy title'),
      );
      await createMangaTables(upgraded);
      expect(await upgraded.query('manga_chapter_progress'), hasLength(1));
    },
  );

  test(
    'chapters retain independent positions and stale saves do not replace latest',
    () async {
      await store.upsertProgress(progress('chapter-1', seconds: 1));
      await store.upsertProgress(progress('chapter-2', page: 7, seconds: 3));
      await store.upsertProgress(progress('chapter-1', page: 4, seconds: 2));
      expect(
        (await store.chapterProgressForEntry(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        )).map((item) => item.pageIndex),
        [4, 7],
      );
      expect(
        (await store.progress(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ))!.chapterId,
        'chapter-2',
      );
      await store.upsertProgress(progress('chapter-1', page: 1, seconds: 1));
      expect(
        (await store.chapterProgress(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
          chapterId: 'chapter-1',
        ))!.pageIndex,
        4,
      );
    },
  );

  test(
    'reader checkpoints keep completion/bookmarks until explicit unread/unbookmark',
    () async {
      await store.upsertProgress(progress('chapter-1', read: true));
      await store.setChapterBookmark(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapterId: 'chapter-1',
        bookmarked: true,
        updatedAt: now.add(const Duration(seconds: 1)),
      );
      await store.upsertProgress(progress('chapter-1', page: 1, seconds: 2));
      var saved = (await store.chapterProgress(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapterId: 'chapter-1',
      ))!;
      expect(saved.completed, isTrue);
      expect(saved.bookmarked, isTrue);
      await store.setChapterRead(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapterId: 'chapter-1',
        completed: false,
        updatedAt: now.add(const Duration(seconds: 3)),
      );
      await store.setChapterBookmark(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapterId: 'chapter-1',
        bookmarked: false,
        updatedAt: now.add(const Duration(seconds: 4)),
      );
      saved = (await store.chapterProgress(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapterId: 'chapter-1',
      ))!;
      expect(saved.completed, isFalse);
      expect(saved.bookmarked, isFalse);
      expect(saved.pageIndex, 1);
      expect(
        (await store.progress(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ))!.completed,
        isFalse,
      );
    },
  );

  test(
    'flags for unopened chapters do not jump the latest reader position',
    () async {
      await store.upsertProgress(progress('chapter-1'));
      await store.setChapterRead(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapterId: 'chapter-8',
        completed: true,
      );
      expect(
        (await store.progress(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ))!.chapterId,
        'chapter-1',
      );
      expect(
        (await store.chapterProgress(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
          chapterId: 'chapter-8',
        ))!.completed,
        isTrue,
      );
      expect(
        await store.chapterProgress(
          ownerKey: 'other-profile',
          sourceId: 'source-a',
          entryId: 'book-a',
          chapterId: 'chapter-8',
        ),
        isNull,
      );
    },
  );

  test(
    'snapshot baseline, new updates, stale checks, unavailable retention and acknowledgment',
    () async {
      await store.upsertLibraryEntry(library());
      const one = MangaChapterSnapshot(
        chapterId: 'chapter-1',
        title: 'One',
        ordinal: 0,
        chapterNumber: 1,
      );
      const two = MangaChapterSnapshot(
        chapterId: 'chapter-2',
        title: 'Two',
        ordinal: 1,
        chapterNumber: 2,
      );
      final first = await store.replaceChapterSnapshot(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapters: [one],
        checkedAt: now,
      );
      expect(first.addedChapterIds, isEmpty);
      final next = await store.replaceChapterSnapshot(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapters: [two],
        checkedAt: now.add(const Duration(hours: 1)),
      );
      expect(next.addedChapterIds, ['chapter-2']);
      final saved = await store.libraryEntry(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
      );
      expect(saved!.newChapterCount, 1);
      expect(saved.category, 'Favorites');
      expect(
        saved.chapterUpdatedAt?.toUtc(),
        now.add(const Duration(hours: 1)),
      );
      final snapshots = await store.chapterSnapshots(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
      );
      expect(snapshots, hasLength(2));
      expect(snapshots.first.available, isFalse);
      await store.replaceChapterSnapshot(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapters: [one],
        checkedAt: now,
      );
      expect(
        (await store.chapterSnapshots(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
          includeUnavailable: false,
        )).single.chapterId,
        'chapter-2',
      );
      await store.acknowledgeChapterUpdates(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
      );
      expect(
        (await store.libraryEntry(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ))!.newChapterCount,
        0,
      );
      await store.setLibraryOrganization(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        category: 'Later',
        status: MangaLibraryStatus.onHold,
      );
      expect(
        (await store.libraryEntry(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ))!.status,
        MangaLibraryStatus.onHold,
      );
    },
  );

  test(
    'snapshot duplicate validation and transaction failure preserve all existing state',
    () async {
      await store.upsertLibraryEntry(library());
      const chapter = MangaChapterSnapshot(
        chapterId: 'chapter-1',
        title: 'One',
        ordinal: 0,
      );
      await expectLater(
        store.replaceChapterSnapshot(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
          chapters: [chapter, chapter],
          checkedAt: now,
        ),
        throwsFormatException,
      );
      await expectLater(
        store.transaction((transaction) async {
          await transaction.upsertProgress(progress('chapter-1'));
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect(
        await store.chapterProgressForEntry(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ),
        isEmpty,
      );
      expect(
        await store.progress(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ),
        isNull,
      );
    },
  );

  test(
    'migration matches unique chapter numbers, requires confirmation, retains source',
    () async {
      await store.upsertLibraryEntry(library());
      await store.upsertProgress(progress('chapter-1', read: true));
      await store.upsertProgress(progress('chapter-2', seconds: 1));
      await store.upsertProgress(progress('chapter-3', seconds: 2));
      final service = MangaLibraryService(store);
      final plan = await service.previewSourceMigration(
        source: library(),
        target: library(source: 'source-b', entry: 'book-b'),
        targetChapters: const [
          MangaChapterSnapshot(
            chapterId: 'new-1',
            title: 'First',
            ordinal: 0,
            chapterNumber: 1,
          ),
          MangaChapterSnapshot(
            chapterId: 'new-2-a',
            title: 'Translation A',
            ordinal: 1,
            chapterNumber: 2,
          ),
          MangaChapterSnapshot(
            chapterId: 'new-2-b',
            title: 'Translation B',
            ordinal: 2,
            chapterNumber: 2,
          ),
          MangaChapterSnapshot(
            chapterId: 'new-3',
            title: 'Third',
            ordinal: 3,
            chapterNumber: 3,
          ),
        ],
      );
      expect(plan.chapterMatches, {'chapter-1': 'new-1', 'chapter-3': 'new-3'});
      expect(plan.unmatchedChapterIds, ['chapter-2']);
      await expectLater(
        service.confirmSourceMigration(plan, confirmed: false),
        throwsStateError,
      );
      expect(
        await store.libraryEntry(
          ownerKey: 'profile',
          sourceId: 'source-b',
          entryId: 'book-b',
        ),
        isNull,
      );
      final result = await service.confirmSourceMigration(
        plan,
        confirmed: true,
      );
      expect(result.copiedChapters, 2);
      expect(result.originalRetained, isTrue);
      expect(
        await store.chapterProgressForEntry(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
        ),
        hasLength(3),
      );
      expect(
        (await store.progress(
          ownerKey: 'profile',
          sourceId: 'source-b',
          entryId: 'book-b',
        ))!.chapterId,
        'new-3',
      );
      expect(
        (await store.libraryEntry(
          ownerKey: 'profile',
          sourceId: 'source-b',
          entryId: 'book-b',
        ))!.category,
        'Favorites',
      );
    },
  );

  test(
    'migration rejects stale previews and rolls back an invalid target snapshot',
    () async {
      await store.upsertLibraryEntry(library());
      await store.upsertProgress(progress('chapter-1'));
      final service = MangaLibraryService(store);
      final target = library(source: 'source-b', entry: 'book-b');
      final stale = await service.previewSourceMigration(
        source: library(),
        target: target,
        targetChapters: const [
          MangaChapterSnapshot(
            chapterId: 'new-1',
            title: 'One',
            ordinal: 0,
            chapterNumber: 1,
          ),
        ],
      );
      await store.setChapterBookmark(
        ownerKey: 'profile',
        sourceId: 'source-a',
        entryId: 'book-a',
        chapterId: 'chapter-1',
        bookmarked: true,
      );
      await expectLater(
        service.confirmSourceMigration(stale, confirmed: true),
        throwsStateError,
      );
      final invalid = await service.previewSourceMigration(
        source: library(),
        target: target,
        targetChapters: const [
          MangaChapterSnapshot(
            chapterId: 'new-1',
            title: '',
            ordinal: 0,
            chapterNumber: 1,
          ),
        ],
      );
      await expectLater(
        service.confirmSourceMigration(invalid, confirmed: true),
        throwsFormatException,
      );
      expect(
        await store.libraryEntry(
          ownerKey: 'profile',
          sourceId: 'source-b',
          entryId: 'book-b',
        ),
        isNull,
      );
      expect(
        (await store.chapterProgress(
          ownerKey: 'profile',
          sourceId: 'source-a',
          entryId: 'book-a',
          chapterId: 'chapter-1',
        ))!.bookmarked,
        isTrue,
      );
    },
  );

  test('maintenance sees download jobs beyond the 500-item UI page', () async {
    await database.transaction((tx) async {
      for (var i = 0; i < 503; i++) {
        await tx.insert('manga_download_jobs', {
          'id': 'job-$i',
          'source_id': 'source-a',
          'entry_id': 'book-a',
          'chapter_id': 'chapter-$i',
          'series_title': 'Manga',
          'chapter_label': 'Chapter $i',
          'status': 'completed',
          'relative_dir': 'manga/job-$i',
          'page_count': 1,
          'completed_pages': 1,
          'received_bytes': 100,
          'queue_position': i,
          'retry_count': 0,
          'created_at': 1,
          'updated_at': 1,
        });
      }
    });
    expect(await store.downloadJobs(), hasLength(500));
    expect(await store.allDownloadJobs(), hasLength(503));
  });

  test(
    'owner backup history is complete past UI limits and bounded without truncation',
    () async {
      for (final table in [
        'manga_chapter_progress',
        'manga_reading_progress',
      ]) {
        await database.execute('''
        WITH RECURSIVE entries(n) AS (
          SELECT 0 UNION ALL SELECT n + 1 FROM entries WHERE n < 502
        )
        INSERT INTO $table(owner_key, source_id, entry_id, chapter_id, updated_at)
        SELECT 'profile', 'source-a', 'book-' || n, 'chapter-1', n FROM entries
      ''');
      }
      expect(await store.latestProgressForOwner('profile'), hasLength(500));
      expect(await store.latestHistoryForOwner('profile'), hasLength(503));
      expect(await store.chapterHistoryForOwner('profile'), hasLength(503));
      expect(await store.chapterHistoryForOwner('other-profile'), isEmpty);
      for (final table in [
        'manga_chapter_progress',
        'manga_reading_progress',
      ]) {
        await database.execute('''
        WITH RECURSIVE entries(n) AS (
          SELECT 503 UNION ALL SELECT n + 1 FROM entries WHERE n < 50000
        )
        INSERT INTO $table(owner_key, source_id, entry_id, chapter_id, updated_at)
        SELECT 'profile', 'source-a', 'book-' || n, 'chapter-1', n FROM entries
      ''');
      }
      await expectLater(
        store.chapterHistoryForOwner('profile'),
        throwsStateError,
      );
      await expectLater(
        store.latestHistoryForOwner('profile'),
        throwsStateError,
      );
      expect(await store.latestHistoryForOwner('other-profile'), isEmpty);
    },
  );
}
