// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_parse_support.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:sqflite/sqflite.dart';

typedef MangaDatabaseProvider = Future<DatabaseExecutor> Function();

enum StoredMangaSourceKind { repository, opds1, opds2 }

enum MangaLibraryStatus { planToRead, reading, completed, onHold, dropped }

enum MangaDownloadJobStatus {
  queued,
  resolving,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
  needsReauthorization,
}

class StoredMangaSource {
  const StoredMangaSource({
    required this.id,
    required this.uri,
    required this.name,
    required this.kind,
    required this.updatedAt,
    this.enabled = true,
  });

  final String id;
  final Uri uri;
  final String name;
  final StoredMangaSourceKind kind;
  final bool enabled;
  final DateTime updatedAt;
}

class MangaCatalogCacheRecord {
  MangaCatalogCacheRecord({
    required this.sourceId,
    required Map<String, Object?> payload,
    required this.fetchedAt,
  }) : payload = Map<String, Object?>.unmodifiable(payload);

  final String sourceId;

  /// Normalized catalog metadata only. Page lists, page URLs, request headers,
  /// cookies, and credentials are rejected before this map reaches SQLite.
  final Map<String, Object?> payload;
  final DateTime fetchedAt;
}

class MangaLibraryEntry {
  MangaLibraryEntry({
    required this.ownerKey,
    required this.sourceId,
    required this.entryId,
    required this.title,
    required Map<String, Object?> metadata,
    required this.updatedAt,
    this.coverUri,
    this.category = '',
    this.status = MangaLibraryStatus.planToRead,
    this.chapterCheckedAt,
    this.chapterUpdatedAt,
    this.newChapterCount = 0,
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  final String ownerKey;
  final String sourceId;
  final String entryId;
  final String title;
  final Map<String, Object?> metadata;
  final Uri? coverUri;
  final DateTime updatedAt;
  final String category;
  final MangaLibraryStatus status;
  final DateTime? chapterCheckedAt;
  final DateTime? chapterUpdatedAt;
  final int newChapterCount;
}

class MangaReadingProgress {
  const MangaReadingProgress({
    required this.ownerKey,
    required this.sourceId,
    required this.entryId,
    required this.chapterId,
    required this.pageIndex,
    required this.pageOffset,
    required this.completed,
    required this.updatedAt,
    this.chapterNumber,
    this.pageCount,
    this.bookmarked = false,
  });

  final String ownerKey;
  final String sourceId;
  final String entryId;
  final String chapterId;
  final double? chapterNumber;
  final int pageIndex;
  final double pageOffset;
  final int? pageCount;
  final bool completed;
  final bool bookmarked;
  final DateTime updatedAt;
}

/// Public chapter metadata only; never a chapter/page URL or request header.
class MangaChapterSnapshot {
  const MangaChapterSnapshot({
    required this.chapterId,
    required this.title,
    required this.ordinal,
    this.chapterNumber,
    this.publishedAt,
    this.firstSeenAt,
    this.lastSeenAt,
    this.available = true,
    this.isNew = false,
  });
  final String chapterId;
  final String title;
  final int ordinal;
  final double? chapterNumber;
  final DateTime? publishedAt;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;
  final bool available;
  final bool isNew;
}

class MangaChapterSnapshotUpdate {
  const MangaChapterSnapshotUpdate({
    required this.addedChapterIds,
    required this.checkedAt,
  });
  final List<String> addedChapterIds;
  final DateTime checkedAt;
}

class MangaDownloadJob {
  const MangaDownloadJob({
    required this.id,
    required this.sourceId,
    required this.entryId,
    required this.chapterId,
    required this.seriesTitle,
    required this.chapterLabel,
    required this.status,
    required this.relativeDirectory,
    required this.completedPages,
    required this.receivedBytes,
    required this.queuePosition,
    required this.retryCount,
    required this.createdAt,
    required this.updatedAt,
    this.pageCount,
    this.manifestFingerprint,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final String sourceId;
  final String entryId;
  final String chapterId;
  final String seriesTitle;
  final String chapterLabel;
  final MangaDownloadJobStatus status;
  final String relativeDirectory;
  final int? pageCount;
  final int completedPages;
  final int receivedBytes;
  final String? manifestFingerprint;
  final int queuePosition;
  final int retryCount;
  final String? errorCode;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class MangaDownloadPage {
  const MangaDownloadPage({
    required this.jobId,
    required this.pageIndex,
    required this.relativePath,
    required this.mimeType,
    required this.byteLength,
    required this.sha256,
    this.stableKeyHash,
  });

  final String jobId;
  final int pageIndex;
  final String? stableKeyHash;
  final String relativePath;
  final String mimeType;
  final int byteLength;
  final String sha256;
}

/// Typed persistence for the optional public manga reader.
///
/// This class uses the manga tables already owned by [TetoTvDatabase]. It does
/// not create or migrate tables. Secrets are delegated to protected storage,
/// and no public method accepts a page URL or HTTP request header.
class MangaStore {
  MangaStore({
    MangaDatabaseProvider? databaseProvider,
    MangaSourceCredentialStore? credentials,
  }) : _databaseProvider =
           databaseProvider ?? (() async => TetoTvDatabase.instance.database),
       _credentials = credentials;

  final MangaDatabaseProvider _databaseProvider;
  final MangaSourceCredentialStore? _credentials;

  /// All work uses the same SQLite transaction. Nested calls reuse its executor.
  Future<T> transaction<T>(Future<T> Function(MangaStore store) action) async {
    final db = await _databaseProvider();
    if (db is Database) {
      return db.transaction(
        (tx) => action(MangaStore(databaseProvider: () async => tx)),
      );
    }
    return action(this);
  }

  Future<void> upsertSource(StoredMangaSource value) async {
    _validateSource(value);
    final db = await _databaseProvider();
    final row = <String, Object?>{
      'id': value.id,
      'url': value.uri.toString(),
      'name': value.name,
      'kind': _sourceKindValue(value.kind),
      'enabled': value.enabled ? 1 : 0,
      'updated_at': _epoch(value.updatedAt, 'source.updatedAt'),
    };
    final changed = await db.update(
      'manga_sources',
      row,
      where: 'id = ?',
      whereArgs: <Object?>[value.id],
    );
    if (changed == 0) await db.insert('manga_sources', row);
  }

  Future<StoredMangaSource?> source(String sourceId) async {
    final id = _sourceId(sourceId);
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_sources',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : _sourceFromRow(rows.single);
  }

  Future<List<StoredMangaSource>> sources({bool includeDisabled = true}) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_sources',
      where: includeDisabled ? null : 'enabled = 1',
      orderBy: 'name COLLATE NOCASE ASC, id ASC',
      limit: 512,
    );
    return rows.map(_sourceFromRow).toList(growable: false);
  }

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final id = _sourceId(sourceId);
    final db = await _databaseProvider();
    await db.update(
      'manga_sources',
      <String, Object?>{
        'enabled': enabled ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  Future<void> deleteSource(String sourceId) async {
    final id = _sourceId(sourceId);
    await _credentials?.delete(id);
    final db = await _databaseProvider();
    if (db is Database) {
      await db.transaction((transaction) => _deleteSourceRows(transaction, id));
    } else {
      await _deleteSourceRows(db, id);
    }
  }

  Future<void> putCache(MangaCatalogCacheRecord value) async {
    final id = _sourceId(value.sourceId);
    final payload = _encodeSafeMap(
      value.payload,
      field: 'cache.payload',
      maximumBytes: 2 * 1024 * 1024,
    );
    final db = await _databaseProvider();
    await db.insert('manga_source_cache', <String, Object?>{
      'source_id': id,
      'payload_json': payload,
      'fetched_at': _epoch(value.fetchedAt, 'cache.fetchedAt'),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<MangaCatalogCacheRecord?> cache(String sourceId) async {
    final id = _sourceId(sourceId);
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_source_cache',
      where: 'source_id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return MangaCatalogCacheRecord(
      sourceId: id,
      payload: _decodeSafeMap(
        _rowString(row, 'payload_json'),
        field: 'cache.payload',
        maximumBytes: 2 * 1024 * 1024,
      ),
      fetchedAt: _date(row, 'fetched_at'),
    );
  }

  Future<void> deleteCache(String sourceId) async {
    final db = await _databaseProvider();
    await db.delete(
      'manga_source_cache',
      where: 'source_id = ?',
      whereArgs: <Object?>[_sourceId(sourceId)],
    );
  }

  Future<void> upsertLibraryEntry(MangaLibraryEntry value) async {
    _validateLibraryEntry(value);
    final db = await _databaseProvider();
    await db.insert('manga_library_entries', <String, Object?>{
      'owner_key': value.ownerKey,
      'source_id': value.sourceId,
      'entry_id': value.entryId,
      'title': value.title,
      'metadata_json': _encodeSafeMap(
        value.metadata,
        field: 'library.metadata',
        maximumBytes: 1024 * 1024,
      ),
      'cover_url': value.coverUri?.toString(),
      'updated_at': _epoch(value.updatedAt, 'library.updatedAt'),
      'category': value.category,
      'reading_status': value.status.name,
      'chapter_checked_at': value.chapterCheckedAt?.millisecondsSinceEpoch,
      'chapter_updated_at': value.chapterUpdatedAt?.millisecondsSinceEpoch,
      'new_chapter_count': value.newChapterCount,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<MangaLibraryEntry?> libraryEntry({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    final owner = _boundedText(ownerKey, 'library.ownerKey', 128);
    final source = _sourceId(sourceId);
    final entry = _boundedText(entryId, 'library.entryId', 512);
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_library_entries',
      where: 'owner_key = ? AND source_id = ? AND entry_id = ?',
      whereArgs: <Object?>[owner, source, entry],
      limit: 1,
    );
    return rows.isEmpty ? null : _libraryFromRow(rows.single);
  }

  Future<List<MangaLibraryEntry>> libraryEntries(
    String ownerKey, {
    int limit = 500,
  }) async {
    final owner = _boundedText(ownerKey, 'library.ownerKey', 128);
    final boundedLimit = limit.clamp(1, 500);
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_library_entries',
      where: 'owner_key = ?',
      whereArgs: <Object?>[owner],
      orderBy: 'updated_at DESC, title COLLATE NOCASE ASC',
      limit: boundedLimit,
    );
    return rows.map(_libraryFromRow).toList(growable: false);
  }

  /// Update sweeps page through stable extension identities, independently of
  /// the library UI's 500-row cap. Legacy catalog sources use `source.*`, not
  /// the reserved `extension.*` namespace. Callers still validate entry kind.
  /// [remaining] includes the returned rows and uses the same cursor predicate.
  Future<({List<MangaLibraryEntry> entries, int remaining})>
  extensionLibraryUpdatePage(
    String ownerKey, {
    String? afterSourceId,
    String? afterEntryId,
    int limit = 100,
  }) async {
    final owner = _boundedText(ownerKey, 'library.ownerKey', 128);
    if ((afterSourceId == null) != (afterEntryId == null)) {
      throw const FormatException(
        'A complete library update cursor is required.',
      );
    }
    final cursorSource = afterSourceId == null
        ? null
        : _sourceId(afterSourceId);
    final cursorEntry = afterEntryId == null
        ? null
        : _boundedText(afterEntryId, 'library.entryId', 512);
    final where =
        "owner_key = ? AND source_id GLOB 'extension.*'${cursorSource == null ? '' : ' AND (source_id > ? OR (source_id = ? AND entry_id > ?))'}";
    final args = <Object?>[
      owner,
      if (cursorSource != null) ...[cursorSource, cursorSource, cursorEntry],
    ];
    final db = await _databaseProvider();
    final count = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM manga_library_entries WHERE $where',
      args,
    );
    final rows = await db.query(
      'manga_library_entries',
      where: where,
      whereArgs: args,
      orderBy: 'source_id ASC, entry_id ASC',
      limit: limit.clamp(1, 100),
    );
    return (
      entries: rows.map(_libraryFromRow).toList(growable: false),
      remaining: (count.single['count']! as num).toInt(),
    );
  }

  Future<void> deleteLibraryEntry({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    final db = await _databaseProvider();
    await db.delete(
      'manga_library_entries',
      where: 'owner_key = ? AND source_id = ? AND entry_id = ?',
      whereArgs: <Object?>[
        _boundedText(ownerKey, 'library.ownerKey', 128),
        _sourceId(sourceId),
        _boundedText(entryId, 'library.entryId', 512),
      ],
    );
  }

  Future<void> setLibraryOrganization({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String category,
    required MangaLibraryStatus status,
  }) async {
    _category(category);
    final db = await _databaseProvider();
    await db.update(
      'manga_library_entries',
      {'category': category, 'reading_status': status.name},
      where: _titleWhere,
      whereArgs: _titleArgs(ownerKey, sourceId, entryId),
    );
  }

  Future<void> upsertProgress(MangaReadingProgress value) async {
    _validateProgress(value);
    await transaction((store) async {
      final db = await store._databaseProvider();
      final old = await store.chapterProgress(
        ownerKey: value.ownerKey,
        sourceId: value.sourceId,
        entryId: value.entryId,
        chapterId: value.chapterId,
      );
      if (old != null && old.updatedAt.isAfter(value.updatedAt)) return;
      final row = _progressToRow(value)
        ..['completed'] = value.completed || (old?.completed ?? false) ? 1 : 0
        ..['bookmarked'] = value.bookmarked || (old?.bookmarked ?? false)
            ? 1
            : 0;
      await db.insert(
        'manga_chapter_progress',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final latest = await store.progress(
        ownerKey: value.ownerKey,
        sourceId: value.sourceId,
        entryId: value.entryId,
      );
      if (latest == null || !latest.updatedAt.isAfter(value.updatedAt)) {
        await db.insert(
          'manga_reading_progress',
          Map<String, Object?>.from(row)..remove('bookmarked'),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<MangaReadingProgress?> progress({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_reading_progress',
      where: 'owner_key = ? AND source_id = ? AND entry_id = ?',
      whereArgs: <Object?>[
        _boundedText(ownerKey, 'progress.ownerKey', 128),
        _sourceId(sourceId),
        _boundedText(entryId, 'progress.entryId', 512),
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : _progressFromRow(rows.single);
  }

  Future<List<MangaReadingProgress>> recentProgress(
    String ownerKey, {
    int limit = 100,
  }) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_reading_progress',
      where: 'owner_key = ?',
      whereArgs: <Object?>[_boundedText(ownerKey, 'progress.ownerKey', 128)],
      orderBy: 'updated_at DESC',
      limit: limit.clamp(1, 500),
    );
    return rows.map(_progressFromRow).toList(growable: false);
  }

  /// One bounded query for library sorting/filtering, without per-title reads.
  Future<List<MangaReadingProgress>> latestProgressForOwner(String ownerKey) =>
      recentProgress(ownerKey, limit: 500);

  /// Complete bounded backup/history query; never silently applies UI limits.
  Future<List<MangaReadingProgress>> chapterHistoryForOwner(String ownerKey) =>
      _historyForOwner(ownerKey, 'manga_chapter_progress');

  /// Latest pointers for all titles, including unsaved titles, for backups.
  Future<List<MangaReadingProgress>> latestHistoryForOwner(String ownerKey) =>
      _historyForOwner(ownerKey, 'manga_reading_progress');

  Future<List<MangaReadingProgress>> _historyForOwner(
    String ownerKey,
    String table,
  ) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      table,
      where: 'owner_key = ?',
      whereArgs: [_boundedText(ownerKey, 'progress.ownerKey', 128)],
      orderBy: 'source_id ASC, entry_id ASC, chapter_id ASC',
      limit: 50001,
    );
    if (rows.length > 50000) {
      throw StateError(
        'This profile exceeds the backup chapter-history limit.',
      );
    }
    return rows.map(_progressFromRow).toList(growable: false);
  }

  Future<MangaReadingProgress?> chapterProgress({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String chapterId,
  }) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_chapter_progress',
      where: '$_titleWhere AND chapter_id = ?',
      whereArgs: [
        ..._titleArgs(ownerKey, sourceId, entryId),
        _boundedText(chapterId, 'chapter.id', 512),
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : _progressFromRow(rows.single);
  }

  Future<List<MangaReadingProgress>> chapterProgressForEntry({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_chapter_progress',
      where: _titleWhere,
      whereArgs: _titleArgs(ownerKey, sourceId, entryId),
      orderBy: 'chapter_number ASC, chapter_id ASC',
      limit: 10001,
    );
    if (rows.length > 10000) {
      throw StateError('This title exceeds the chapter-history limit.');
    }
    return rows.map(_progressFromRow).toList(growable: false);
  }

  Future<void> setChapterRead({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String chapterId,
    required bool completed,
    double? chapterNumber,
    DateTime? updatedAt,
  }) => _setChapterFlag(
    ownerKey: ownerKey,
    sourceId: sourceId,
    entryId: entryId,
    chapterId: chapterId,
    completed: completed,
    chapterNumber: chapterNumber,
    updatedAt: updatedAt,
  );

  Future<void> setChapterBookmark({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String chapterId,
    required bool bookmarked,
    double? chapterNumber,
    DateTime? updatedAt,
  }) => _setChapterFlag(
    ownerKey: ownerKey,
    sourceId: sourceId,
    entryId: entryId,
    chapterId: chapterId,
    bookmarked: bookmarked,
    chapterNumber: chapterNumber,
    updatedAt: updatedAt,
  );

  Future<void> _setChapterFlag({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String chapterId,
    bool? completed,
    bool? bookmarked,
    double? chapterNumber,
    DateTime? updatedAt,
  }) => transaction((store) async {
    final old = await store.chapterProgress(
      ownerKey: ownerKey,
      sourceId: sourceId,
      entryId: entryId,
      chapterId: chapterId,
    );
    final value = MangaReadingProgress(
      ownerKey: ownerKey,
      sourceId: sourceId,
      entryId: entryId,
      chapterId: chapterId,
      chapterNumber: old?.chapterNumber ?? chapterNumber,
      pageIndex: old?.pageIndex ?? 0,
      pageOffset: old?.pageOffset ?? 0,
      pageCount: old?.pageCount,
      completed: completed ?? old?.completed ?? false,
      bookmarked: bookmarked ?? old?.bookmarked ?? false,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
    );
    _validateProgress(value);
    if (old != null && old.updatedAt.isAfter(value.updatedAt)) return;
    final db = await store._databaseProvider();
    await db.insert(
      'manga_chapter_progress',
      _progressToRow(value),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (completed != null) {
      await db.update(
        'manga_reading_progress',
        {'completed': completed ? 1 : 0},
        where: '$_titleWhere AND chapter_id = ?',
        whereArgs: [..._titleArgs(ownerKey, sourceId, entryId), chapterId],
      );
    }
  });

  /// Exact, validated restore for an explicitly confirmed backup/migration.
  /// Normal reader checkpoints must use [upsertProgress] instead.
  Future<void> restoreChapterProgress(
    MangaReadingProgress value, {
    bool latest = false,
  }) async {
    _validateProgress(value);
    await transaction((store) async {
      final db = await store._databaseProvider();
      final row = _progressToRow(value);
      await db.insert(
        'manga_chapter_progress',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (latest) {
        await db.insert(
          'manga_reading_progress',
          Map<String, Object?>.from(row)..remove('bookmarked'),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<MangaChapterSnapshot>> chapterSnapshots({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    bool includeUnavailable = true,
  }) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_chapter_snapshots',
      where: '$_titleWhere${includeUnavailable ? '' : ' AND available = 1'}',
      whereArgs: _titleArgs(ownerKey, sourceId, entryId),
      orderBy: 'ordinal ASC, chapter_id ASC',
      limit: 10001,
    );
    if (rows.length > 10000) {
      throw StateError('This title exceeds the chapter-snapshot limit.');
    }
    return rows.map(_snapshotFromRow).toList(growable: false);
  }

  /// First successful check establishes a baseline, not thousands of "new"
  /// chapters. Later absent chapters are retained as unavailable, never erased.
  Future<MangaChapterSnapshotUpdate> replaceChapterSnapshot({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required List<MangaChapterSnapshot> chapters,
    required DateTime checkedAt,
  }) async {
    if (chapters.length > 10000) {
      throw const FormatException('Too many chapter snapshots.');
    }
    final ids = <String>{};
    for (final chapter in chapters) {
      _validateSnapshot(chapter);
      if (!ids.add(chapter.chapterId)) {
        throw const FormatException('Duplicate chapter identity.');
      }
    }
    _epoch(checkedAt, 'snapshot.checkedAt');
    return transaction((store) async {
      final db = await store._databaseProvider();
      final entry = await store.libraryEntry(
        ownerKey: ownerKey,
        sourceId: sourceId,
        entryId: entryId,
      );
      if (entry == null) {
        throw StateError(
          'Save the title to your library before tracking updates.',
        );
      }
      if (entry.chapterCheckedAt?.isAfter(checkedAt) == true) {
        return MangaChapterSnapshotUpdate(
          addedChapterIds: const [],
          checkedAt: entry.chapterCheckedAt!,
        );
      }
      final previous = {
        for (final item in await store.chapterSnapshots(
          ownerKey: ownerKey,
          sourceId: sourceId,
          entryId: entryId,
        ))
          item.chapterId: item,
      };
      final added = <String>[];
      await db.update(
        'manga_chapter_snapshots',
        {'available': 0},
        where: _titleWhere,
        whereArgs: _titleArgs(ownerKey, sourceId, entryId),
      );
      for (final item in chapters) {
        final old = previous[item.chapterId];
        final isNew = old?.isNew ?? entry.chapterCheckedAt != null;
        if (old == null && entry.chapterCheckedAt != null) {
          added.add(item.chapterId);
        }
        await db.insert('manga_chapter_snapshots', {
          ..._snapshotToRow(item, ownerKey, sourceId, entryId, checkedAt),
          'first_seen_at':
              (old?.firstSeenAt ?? checkedAt).millisecondsSinceEpoch,
          'last_seen_at': checkedAt.millisecondsSinceEpoch,
          'available': 1,
          'is_new': isNew ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      final count = await db.rawQuery(
        'SELECT count(*) AS count FROM manga_chapter_snapshots WHERE $_titleWhere AND available = 1 AND is_new = 1',
        _titleArgs(ownerKey, sourceId, entryId),
      );
      await db.update(
        'manga_library_entries',
        {
          'chapter_checked_at': checkedAt.millisecondsSinceEpoch,
          'chapter_updated_at': added.isNotEmpty
              ? checkedAt.millisecondsSinceEpoch
              : entry.chapterUpdatedAt?.millisecondsSinceEpoch,
          'new_chapter_count': count.single['count'],
        },
        where: _titleWhere,
        whereArgs: _titleArgs(ownerKey, sourceId, entryId),
      );
      return MangaChapterSnapshotUpdate(
        addedChapterIds: List.unmodifiable(added),
        checkedAt: checkedAt,
      );
    });
  }

  Future<void> restoreChapterSnapshot({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required MangaChapterSnapshot chapter,
    required DateTime fallbackTime,
  }) async {
    _titleArgs(ownerKey, sourceId, entryId);
    _validateSnapshot(chapter);
    final db = await _databaseProvider();
    await db.insert(
      'manga_chapter_snapshots',
      _snapshotToRow(chapter, ownerKey, sourceId, entryId, fallbackTime),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> acknowledgeChapterUpdates({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) => transaction((store) async {
    final db = await store._databaseProvider();
    final args = _titleArgs(ownerKey, sourceId, entryId);
    await db.update(
      'manga_chapter_snapshots',
      {'is_new': 0},
      where: _titleWhere,
      whereArgs: args,
    );
    await db.update(
      'manga_library_entries',
      {'new_chapter_count': 0},
      where: _titleWhere,
      whereArgs: args,
    );
  });

  Future<void> deleteProgress({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    await transaction((store) async {
      final db = await store._databaseProvider();
      final args = _titleArgs(ownerKey, sourceId, entryId);
      await db.delete(
        'manga_reading_progress',
        where: _titleWhere,
        whereArgs: args,
      );
      await db.delete(
        'manga_chapter_progress',
        where: _titleWhere,
        whereArgs: args,
      );
    });
  }

  Future<void> upsertDownloadJob(MangaDownloadJob value) async {
    _validateJob(value);
    final db = await _databaseProvider();
    final row = _jobToRow(value);
    final changed = await db.update(
      'manga_download_jobs',
      row,
      where: 'id = ?',
      whereArgs: <Object?>[value.id],
    );
    if (changed == 0) await db.insert('manga_download_jobs', row);
  }

  Future<MangaDownloadJob?> downloadJob(String jobId) async {
    final id = _boundedText(jobId, 'download.id', 128);
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_download_jobs',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : _jobFromRow(rows.single);
  }

  Future<List<MangaDownloadJob>> downloadJobs({
    MangaDownloadJobStatus? status,
    int limit = 500,
  }) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_download_jobs',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null
          ? null
          : <Object?>[_downloadStatusValue(status)],
      orderBy: 'queue_position ASC, created_at ASC',
      limit: limit.clamp(1, 500),
    );
    return rows.map(_jobFromRow).toList(growable: false);
  }

  Future<void> deleteDownloadJob(String jobId) async {
    final db = await _databaseProvider();
    await db.delete(
      'manga_download_jobs',
      where: 'id = ?',
      whereArgs: <Object?>[_boundedText(jobId, 'download.id', 128)],
    );
  }

  /// Maintenance must account for the whole durable queue, not the UI's first
  /// page: storage quotas, restart recovery and source deletion use this API.
  Future<List<MangaDownloadJob>> allDownloadJobs() async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_download_jobs',
      orderBy: 'queue_position ASC, created_at ASC',
    );
    return rows.map(_jobFromRow).toList(growable: false);
  }

  Future<void> upsertDownloadPage(MangaDownloadPage value) async {
    _validatePage(value);
    final db = await _databaseProvider();
    final row = <String, Object?>{
      'job_id': value.jobId,
      'page_index': value.pageIndex,
      'stable_key_hash': value.stableKeyHash,
      'relative_path': value.relativePath,
      'mime_type': value.mimeType,
      'byte_length': value.byteLength,
      'sha256': value.sha256,
    };
    final changed = await db.update(
      'manga_download_pages',
      row,
      where: 'job_id = ? AND page_index = ?',
      whereArgs: <Object?>[value.jobId, value.pageIndex],
    );
    if (changed == 0) await db.insert('manga_download_pages', row);
  }

  Future<MangaDownloadPage?> downloadPage(String jobId, int pageIndex) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_download_pages',
      where: 'job_id = ? AND page_index = ?',
      whereArgs: <Object?>[
        _boundedText(jobId, 'page.jobId', 128),
        _boundedInt(pageIndex, 'page.index', 0, 999),
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : _pageFromRow(rows.single);
  }

  Future<List<MangaDownloadPage>> downloadPages(String jobId) async {
    final db = await _databaseProvider();
    final rows = await db.query(
      'manga_download_pages',
      where: 'job_id = ?',
      whereArgs: <Object?>[_boundedText(jobId, 'page.jobId', 128)],
      orderBy: 'page_index ASC',
      limit: 1000,
    );
    return rows.map(_pageFromRow).toList(growable: false);
  }

  Future<void> deleteDownloadPage(String jobId, int pageIndex) async {
    final db = await _databaseProvider();
    await db.delete(
      'manga_download_pages',
      where: 'job_id = ? AND page_index = ?',
      whereArgs: <Object?>[
        _boundedText(jobId, 'page.jobId', 128),
        _boundedInt(pageIndex, 'page.index', 0, 999),
      ],
    );
  }
}

Future<void> _deleteSourceRows(DatabaseExecutor db, String id) async {
  // Not every source-owned table has a source FK, so remove those rows
  // explicitly before the source/cache cascade runs.
  await db.delete(
    'manga_download_jobs',
    where: 'source_id = ?',
    whereArgs: <Object?>[id],
  );
  await db.delete(
    'manga_reading_progress',
    where: 'source_id = ?',
    whereArgs: <Object?>[id],
  );
  await db.delete(
    'manga_chapter_progress',
    where: 'source_id = ?',
    whereArgs: [id],
  );
  await db.delete(
    'manga_chapter_snapshots',
    where: 'source_id = ?',
    whereArgs: [id],
  );
  await db.delete(
    'manga_library_entries',
    where: 'source_id = ?',
    whereArgs: <Object?>[id],
  );
  await db.delete('manga_sources', where: 'id = ?', whereArgs: <Object?>[id]);
}

void _validateSource(StoredMangaSource value) {
  _sourceId(value.id);
  requireMangaPublicHttpsUri(value.uri.toString(), field: 'source.uri');
  _boundedText(value.name, 'source.name', 256);
  _epoch(value.updatedAt, 'source.updatedAt');
}

StoredMangaSource _sourceFromRow(Map<String, Object?> row) {
  final source = StoredMangaSource(
    id: _sourceId(_rowString(row, 'id')),
    uri: requireMangaPublicHttpsUri(
      _rowString(row, 'url'),
      field: 'source.uri',
    ),
    name: _boundedText(_rowString(row, 'name'), 'source.name', 256),
    kind: _sourceKind(_rowString(row, 'kind')),
    enabled: _rowBool(row, 'enabled'),
    updatedAt: _date(row, 'updated_at'),
  );
  _validateSource(source);
  return source;
}

void _validateLibraryEntry(MangaLibraryEntry value) {
  _boundedText(value.ownerKey, 'library.ownerKey', 128);
  _sourceId(value.sourceId);
  _boundedText(value.entryId, 'library.entryId', 512);
  _boundedText(value.title, 'library.title', 1024);
  _encodeSafeMap(
    value.metadata,
    field: 'library.metadata',
    maximumBytes: 1024 * 1024,
  );
  _validateLibraryCatalogPath(value.metadata);
  if (value.coverUri != null) {
    requireMangaPersistablePublicHttpsUri(
      value.coverUri.toString(),
      field: 'library.coverUri',
    );
  }
  _epoch(value.updatedAt, 'library.updatedAt');
  _category(value.category);
  if (value.chapterCheckedAt != null) {
    _epoch(value.chapterCheckedAt!, 'library.chapterCheckedAt');
  }
  if (value.chapterUpdatedAt != null) {
    _epoch(value.chapterUpdatedAt!, 'library.chapterUpdatedAt');
  }
  _boundedInt(value.newChapterCount, 'library.newChapterCount', 0, 10000);
}

void _validateLibraryCatalogPath(Map<String, Object?> metadata) {
  final raw = metadata['catalogPath'];
  if (raw == null) return;
  if (raw is! List || raw.isEmpty || raw.length > 32) {
    throw const FormatException('library.catalogPath is invalid.');
  }
  for (final value in raw) {
    if (value is! String) {
      throw const FormatException('library.catalogPath is invalid.');
    }
    requireMangaPersistablePublicHttpsUri(value, field: 'library.catalogPath');
  }
}

MangaLibraryEntry _libraryFromRow(Map<String, Object?> row) {
  final cover = row['cover_url'];
  final entry = MangaLibraryEntry(
    ownerKey: _boundedText(
      _rowString(row, 'owner_key'),
      'library.ownerKey',
      128,
    ),
    sourceId: _sourceId(_rowString(row, 'source_id')),
    entryId: _boundedText(_rowString(row, 'entry_id'), 'library.entryId', 512),
    title: _boundedText(_rowString(row, 'title'), 'library.title', 1024),
    metadata: _decodeSafeMap(
      _rowString(row, 'metadata_json'),
      field: 'library.metadata',
      maximumBytes: 1024 * 1024,
    ),
    coverUri: cover == null
        ? null
        : requireMangaPersistablePublicHttpsUri(
            cover,
            field: 'library.coverUri',
          ),
    updatedAt: _date(row, 'updated_at'),
    category: row['category'] as String? ?? '',
    status: MangaLibraryStatus.values.byName(
      row['reading_status'] as String? ?? 'planToRead',
    ),
    chapterCheckedAt: row['chapter_checked_at'] == null
        ? null
        : _date(row, 'chapter_checked_at'),
    chapterUpdatedAt: row['chapter_updated_at'] == null
        ? null
        : _date(row, 'chapter_updated_at'),
    newChapterCount: row['new_chapter_count'] == null
        ? 0
        : _rowInt(row, 'new_chapter_count'),
  );
  _validateLibraryEntry(entry);
  return entry;
}

void _validateProgress(MangaReadingProgress value) {
  _boundedText(value.ownerKey, 'progress.ownerKey', 128);
  _sourceId(value.sourceId);
  _boundedText(value.entryId, 'progress.entryId', 512);
  _boundedText(value.chapterId, 'progress.chapterId', 512);
  if (value.chapterNumber != null &&
      (!value.chapterNumber!.isFinite || value.chapterNumber! < 0)) {
    throw const FormatException('progress.chapterNumber is invalid.');
  }
  _boundedInt(value.pageIndex, 'progress.pageIndex', 0, 999);
  if (!value.pageOffset.isFinite ||
      value.pageOffset < 0 ||
      value.pageOffset > 1) {
    throw const FormatException('progress.pageOffset is invalid.');
  }
  if (value.pageCount != null) {
    _boundedInt(value.pageCount!, 'progress.pageCount', 1, 1000);
    if (value.pageIndex >= value.pageCount!) {
      throw const FormatException('progress.pageIndex exceeds pageCount.');
    }
  }
  _epoch(value.updatedAt, 'progress.updatedAt');
}

MangaReadingProgress _progressFromRow(Map<String, Object?> row) {
  final progress = MangaReadingProgress(
    ownerKey: _rowString(row, 'owner_key'),
    sourceId: _rowString(row, 'source_id'),
    entryId: _rowString(row, 'entry_id'),
    chapterId: _rowString(row, 'chapter_id'),
    chapterNumber: (row['chapter_number'] as num?)?.toDouble(),
    pageIndex: _rowInt(row, 'page_index'),
    pageOffset: _rowNum(row, 'page_offset').toDouble(),
    pageCount: row['page_count'] == null ? null : _rowInt(row, 'page_count'),
    completed: _rowBool(row, 'completed'),
    bookmarked: row['bookmarked'] == null ? false : _rowBool(row, 'bookmarked'),
    updatedAt: _date(row, 'updated_at'),
  );
  _validateProgress(progress);
  return progress;
}

const _titleWhere = 'owner_key = ? AND source_id = ? AND entry_id = ?';

List<Object?> _titleArgs(String owner, String source, String entry) => [
  _boundedText(owner, 'title.ownerKey', 128),
  _sourceId(source),
  _boundedText(entry, 'title.entryId', 512),
];

void _category(String value) {
  if (value.isNotEmpty) _boundedText(value, 'library.category', 80);
}

Map<String, Object?> _progressToRow(MangaReadingProgress value) => {
  'owner_key': value.ownerKey,
  'source_id': value.sourceId,
  'entry_id': value.entryId,
  'chapter_id': value.chapterId,
  'chapter_number': value.chapterNumber,
  'page_index': value.pageIndex,
  'page_offset': value.pageOffset,
  'page_count': value.pageCount,
  'completed': value.completed ? 1 : 0,
  'bookmarked': value.bookmarked ? 1 : 0,
  'updated_at': value.updatedAt.millisecondsSinceEpoch,
};

void _validateSnapshot(MangaChapterSnapshot value) {
  _boundedText(value.chapterId, 'snapshot.chapterId', 512);
  _boundedText(value.title, 'snapshot.title', 512);
  _boundedInt(value.ordinal, 'snapshot.ordinal', 0, 99999);
  if (value.chapterNumber != null &&
      (!value.chapterNumber!.isFinite || value.chapterNumber! < 0)) {
    throw const FormatException('snapshot.chapterNumber is invalid.');
  }
  for (final date in [value.publishedAt, value.firstSeenAt, value.lastSeenAt]) {
    if (date != null) _epoch(date, 'snapshot.timestamp');
  }
}

Map<String, Object?> _snapshotToRow(
  MangaChapterSnapshot value,
  String owner,
  String source,
  String entry,
  DateTime fallback,
) => {
  'owner_key': owner,
  'source_id': source,
  'entry_id': entry,
  'chapter_id': value.chapterId,
  'title': value.title,
  'chapter_number': value.chapterNumber,
  'ordinal': value.ordinal,
  'published_at': value.publishedAt?.millisecondsSinceEpoch,
  'first_seen_at': (value.firstSeenAt ?? fallback).millisecondsSinceEpoch,
  'last_seen_at': (value.lastSeenAt ?? fallback).millisecondsSinceEpoch,
  'available': value.available ? 1 : 0,
  'is_new': value.isNew ? 1 : 0,
};

MangaChapterSnapshot _snapshotFromRow(Map<String, Object?> row) {
  final result = MangaChapterSnapshot(
    chapterId: _rowString(row, 'chapter_id'),
    title: _rowString(row, 'title'),
    ordinal: _rowInt(row, 'ordinal'),
    chapterNumber: (row['chapter_number'] as num?)?.toDouble(),
    publishedAt: row['published_at'] == null
        ? null
        : _date(row, 'published_at'),
    firstSeenAt: _date(row, 'first_seen_at'),
    lastSeenAt: _date(row, 'last_seen_at'),
    available: _rowBool(row, 'available'),
    isNew: _rowBool(row, 'is_new'),
  );
  _validateSnapshot(result);
  return result;
}

void _validateJob(MangaDownloadJob value) {
  _boundedText(value.id, 'download.id', 128);
  _sourceId(value.sourceId);
  _boundedText(value.entryId, 'download.entryId', 512);
  _boundedText(value.chapterId, 'download.chapterId', 512);
  _boundedText(value.seriesTitle, 'download.seriesTitle', 1024);
  _boundedText(value.chapterLabel, 'download.chapterLabel', 512);
  _safeRelativePath(value.relativeDirectory, 'download.relativeDirectory');
  if (value.pageCount != null) {
    _boundedInt(value.pageCount!, 'download.pageCount', 1, 1000);
  }
  _boundedInt(value.completedPages, 'download.completedPages', 0, 1000);
  if (value.pageCount != null && value.completedPages > value.pageCount!) {
    throw const FormatException('download.completedPages exceeds pageCount.');
  }
  if (value.receivedBytes < 0 ||
      value.queuePosition < 0 ||
      value.retryCount < 0) {
    throw const FormatException('Manga download counters cannot be negative.');
  }
  if (value.manifestFingerprint != null) {
    _sha256(value.manifestFingerprint!, 'download.manifestFingerprint');
  }
  if (value.errorCode != null) {
    _boundedText(value.errorCode!, 'download.errorCode', 128);
  }
  if (value.errorMessage != null) {
    _boundedText(value.errorMessage!, 'download.errorMessage', 1024);
  }
  _epoch(value.createdAt, 'download.createdAt');
  _epoch(value.updatedAt, 'download.updatedAt');
}

Map<String, Object?> _jobToRow(MangaDownloadJob value) => <String, Object?>{
  'id': value.id,
  'source_id': value.sourceId,
  'entry_id': value.entryId,
  'chapter_id': value.chapterId,
  'series_title': value.seriesTitle,
  'chapter_label': value.chapterLabel,
  'status': _downloadStatusValue(value.status),
  'relative_dir': value.relativeDirectory,
  'page_count': value.pageCount,
  'completed_pages': value.completedPages,
  'received_bytes': value.receivedBytes,
  'manifest_fingerprint': value.manifestFingerprint,
  'queue_position': value.queuePosition,
  'retry_count': value.retryCount,
  'error_code': value.errorCode,
  'error_message': value.errorMessage,
  'created_at': value.createdAt.millisecondsSinceEpoch,
  'updated_at': value.updatedAt.millisecondsSinceEpoch,
};

MangaDownloadJob _jobFromRow(Map<String, Object?> row) {
  final job = MangaDownloadJob(
    id: _rowString(row, 'id'),
    sourceId: _rowString(row, 'source_id'),
    entryId: _rowString(row, 'entry_id'),
    chapterId: _rowString(row, 'chapter_id'),
    seriesTitle: _rowString(row, 'series_title'),
    chapterLabel: _rowString(row, 'chapter_label'),
    status: _downloadStatus(_rowString(row, 'status')),
    relativeDirectory: _rowString(row, 'relative_dir'),
    pageCount: row['page_count'] == null ? null : _rowInt(row, 'page_count'),
    completedPages: _rowInt(row, 'completed_pages'),
    receivedBytes: _rowInt(row, 'received_bytes'),
    manifestFingerprint: row['manifest_fingerprint'] as String?,
    queuePosition: _rowInt(row, 'queue_position'),
    retryCount: _rowInt(row, 'retry_count'),
    errorCode: row['error_code'] as String?,
    errorMessage: row['error_message'] as String?,
    createdAt: _date(row, 'created_at'),
    updatedAt: _date(row, 'updated_at'),
  );
  _validateJob(job);
  return job;
}

void _validatePage(MangaDownloadPage value) {
  _boundedText(value.jobId, 'page.jobId', 128);
  _boundedInt(value.pageIndex, 'page.index', 0, 999);
  if (value.stableKeyHash != null) {
    _sha256(value.stableKeyHash!, 'page.stableKeyHash');
  }
  _safeRelativePath(value.relativePath, 'page.relativePath');
  if (!_imageMimeTypes.contains(value.mimeType.toLowerCase())) {
    throw const FormatException('page.mimeType is not a supported image type.');
  }
  if (value.byteLength <= 0) {
    throw const FormatException('page.byteLength must be positive.');
  }
  _sha256(value.sha256, 'page.sha256');
}

MangaDownloadPage _pageFromRow(Map<String, Object?> row) {
  final page = MangaDownloadPage(
    jobId: _rowString(row, 'job_id'),
    pageIndex: _rowInt(row, 'page_index'),
    stableKeyHash: row['stable_key_hash'] as String?,
    relativePath: _rowString(row, 'relative_path'),
    mimeType: _rowString(row, 'mime_type'),
    byteLength: _rowInt(row, 'byte_length'),
    sha256: _rowString(row, 'sha256'),
  );
  _validatePage(page);
  return page;
}

String _encodeSafeMap(
  Map<String, Object?> value, {
  required String field,
  required int maximumBytes,
}) {
  final String encoded;
  try {
    encoded = jsonEncode(value);
  } on JsonUnsupportedObjectError {
    throw FormatException('$field must contain JSON values only.');
  }
  if (utf8.encode(encoded).length > maximumBytes) {
    throw FormatException('$field exceeds the storage limit.');
  }
  _decodeSafeMap(encoded, field: field, maximumBytes: maximumBytes);
  return encoded;
}

Map<String, Object?> _decodeSafeMap(
  String encoded, {
  required String field,
  required int maximumBytes,
}) {
  if (utf8.encode(encoded).length > maximumBytes) {
    throw FormatException('$field exceeds the storage limit.');
  }
  final decoded = decodeBoundedJson(
    encoded,
    MangaParseLimits(
      maxPayloadCharacters: maximumBytes,
      maxNodes: 20000,
      maxDepth: 24,
    ),
    format: field,
  );
  final map = requiredStringMap(decoded, field: field);
  _rejectSensitivePersistence(map, path: field);
  return _freezeMap(map);
}

void _rejectSensitivePersistence(Object? value, {required String path}) {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      final normalized = entry.key.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (_secretMapKeys.contains(normalized) ||
          normalized.endsWith('headers') ||
          (normalized.contains('page') &&
              (normalized.contains('url') ||
                  normalized.contains('href') ||
                  normalized.contains('link')))) {
        throw FormatException('$path contains non-persistable request data.');
      }
      if ((normalized == 'pages' || normalized == 'readingorder') &&
          _containsHttpUri(entry.value)) {
        throw FormatException('$path contains non-persistable page URLs.');
      }
      _rejectSensitivePersistence(entry.value, path: '$path.${entry.key}');
    }
  } else if (value is List<Object?>) {
    for (var index = 0; index < value.length; index++) {
      _rejectSensitivePersistence(value[index], path: '$path[$index]');
    }
  }
}

bool _containsHttpUri(Object? value) {
  if (value is String) {
    final uri = Uri.tryParse(value.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }
  if (value is List) return value.any(_containsHttpUri);
  if (value is Map) return value.values.any(_containsHttpUri);
  return false;
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(<String, Object?>{
      for (final entry in source.entries) entry.key: _freezeJson(entry.value),
    });

Object? _freezeJson(Object? value) {
  if (value is Map<String, Object?>) return _freezeMap(value);
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  return value;
}

String _sourceId(String value) {
  final id = value.trim();
  if (id != value || !_sourceIdPattern.hasMatch(id)) {
    throw const FormatException('source.id is invalid.');
  }
  return id;
}

String _boundedText(String value, String field, int maximum) {
  final text = value.trim();
  if (text != value ||
      text.isEmpty ||
      text.length > maximum ||
      text.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw FormatException('$field is invalid.');
  }
  return text;
}

int _boundedInt(int value, String field, int minimum, int maximum) {
  if (value < minimum || value > maximum) {
    throw FormatException('$field is outside its supported range.');
  }
  return value;
}

int _epoch(DateTime value, String field) {
  final epoch = value.millisecondsSinceEpoch;
  if (epoch < 0) throw FormatException('$field cannot predate Unix epoch.');
  return epoch;
}

String _safeRelativePath(String value, String field) {
  final path = _boundedText(value, field, 1024);
  if (path.startsWith('/') ||
      path.startsWith('\\') ||
      path.startsWith('~') ||
      path.contains('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path) ||
      path
          .split('/')
          .any(
            (segment) =>
                segment.isEmpty ||
                segment == '.' ||
                segment == '..' ||
                segment.contains(':'),
          )) {
    throw FormatException('$field must be an app-relative path.');
  }
  return path;
}

String _sha256(String value, String field) {
  final normalized = value.toLowerCase();
  if (!_sha256Pattern.hasMatch(normalized)) {
    throw FormatException('$field must be a SHA-256 hex digest.');
  }
  return normalized;
}

StoredMangaSourceKind _sourceKind(String value) => switch (value) {
  'repository' => StoredMangaSourceKind.repository,
  'opds1' => StoredMangaSourceKind.opds1,
  'opds2' => StoredMangaSourceKind.opds2,
  _ => throw const FormatException('Stored manga source kind is invalid.'),
};

String _sourceKindValue(StoredMangaSourceKind value) => switch (value) {
  StoredMangaSourceKind.repository => 'repository',
  StoredMangaSourceKind.opds1 => 'opds1',
  StoredMangaSourceKind.opds2 => 'opds2',
};

MangaDownloadJobStatus _downloadStatus(String value) => switch (value) {
  'queued' => MangaDownloadJobStatus.queued,
  'resolving' => MangaDownloadJobStatus.resolving,
  'downloading' => MangaDownloadJobStatus.downloading,
  'paused' => MangaDownloadJobStatus.paused,
  'completed' => MangaDownloadJobStatus.completed,
  'failed' => MangaDownloadJobStatus.failed,
  'cancelled' => MangaDownloadJobStatus.cancelled,
  'needs_reauthorization' => MangaDownloadJobStatus.needsReauthorization,
  _ => throw const FormatException('Stored manga download status is invalid.'),
};

String _downloadStatusValue(MangaDownloadJobStatus value) => switch (value) {
  MangaDownloadJobStatus.queued => 'queued',
  MangaDownloadJobStatus.resolving => 'resolving',
  MangaDownloadJobStatus.downloading => 'downloading',
  MangaDownloadJobStatus.paused => 'paused',
  MangaDownloadJobStatus.completed => 'completed',
  MangaDownloadJobStatus.failed => 'failed',
  MangaDownloadJobStatus.cancelled => 'cancelled',
  MangaDownloadJobStatus.needsReauthorization => 'needs_reauthorization',
};

String _rowString(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is! String) throw FormatException('Stored $key is invalid.');
  return value;
}

int _rowInt(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  throw FormatException('Stored $key is invalid.');
}

num _rowNum(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is num && value.isFinite) return value;
  throw FormatException('Stored $key is invalid.');
}

bool _rowBool(Map<String, Object?> row, String key) {
  final value = _rowInt(row, key);
  if (value != 0 && value != 1) {
    throw FormatException('Stored $key is invalid.');
  }
  return value == 1;
}

DateTime _date(Map<String, Object?> row, String key) {
  final value = _rowInt(row, key);
  if (value < 0) throw FormatException('Stored $key is invalid.');
  return DateTime.fromMillisecondsSinceEpoch(value);
}

const Set<String> _secretMapKeys = <String>{
  'authorization',
  'cookie',
  'cookies',
  'header',
  'headers',
  'requestheader',
  'requestheaders',
  'token',
  'accesstoken',
  'refreshtoken',
  'apikey',
  'password',
  'secret',
};
const Set<String> _imageMimeTypes = <String>{
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
};
final RegExp _sourceIdPattern = RegExp(
  r'^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$',
);
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
