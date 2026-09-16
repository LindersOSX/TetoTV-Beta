import 'dart:convert';

import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:crypto/crypto.dart';

/// A read-only preview. Only unambiguous chapter-number matches are suggested;
/// two translations/editions sharing a number are never guessed into a match.
class MangaSourceMigrationPlan {
  MangaSourceMigrationPlan._({
    required this.source,
    required this.target,
    required List<MangaChapterSnapshot> targetChapters,
    required Map<String, String> chapterMatches,
    required List<String> unmatchedChapterIds,
    required this._fingerprint,
  }) : targetChapters = List.unmodifiable(targetChapters),
       chapterMatches = Map.unmodifiable(chapterMatches),
       unmatchedChapterIds = List.unmodifiable(unmatchedChapterIds);

  final MangaLibraryEntry source;
  final MangaLibraryEntry target;
  final List<MangaChapterSnapshot> targetChapters;
  final Map<String, String> chapterMatches;
  final List<String> unmatchedChapterIds;
  final String _fingerprint;
}

class MangaSourceMigrationResult {
  const MangaSourceMigrationResult({
    required this.copiedChapters,
    required this.unmatchedChapters,
  });
  final int copiedChapters;
  final int unmatchedChapters;

  /// Migration copies matched data. The source title/history is deliberately
  /// retained, so an unmatched chapter can never be silently lost.
  bool get originalRetained => true;
}

class MangaLibraryService {
  const MangaLibraryService(this.store);
  final MangaStore store;

  Future<MangaSourceMigrationPlan> previewSourceMigration({
    required MangaLibraryEntry source,
    required MangaLibraryEntry target,
    required List<MangaChapterSnapshot> targetChapters,
    Map<String, String>? confirmedChapterMatches,
  }) async {
    if (source.ownerKey != target.ownerKey ||
        (source.sourceId == target.sourceId &&
            source.entryId == target.entryId)) {
      throw const FormatException(
        'Choose a different title source in the same profile.',
      );
    }
    final stored = await store.libraryEntry(
      ownerKey: source.ownerKey,
      sourceId: source.sourceId,
      entryId: source.entryId,
    );
    if (stored == null) {
      throw StateError('The source title is no longer in your library.');
    }
    if (targetChapters.length > 10000 ||
        targetChapters.map((chapter) => chapter.chapterId).toSet().length !=
            targetChapters.length) {
      throw const FormatException('The target chapter list is invalid.');
    }
    final progress = await store.chapterProgressForEntry(
      ownerKey: source.ownerKey,
      sourceId: source.sourceId,
      entryId: source.entryId,
    );
    final oldSnapshots = await store.chapterSnapshots(
      ownerKey: source.ownerKey,
      sourceId: source.sourceId,
      entryId: source.entryId,
    );
    final oldNumbers = {
      for (final chapter in oldSnapshots)
        chapter.chapterId: chapter.chapterNumber,
    };
    final fromByNumber = <double, List<String>>{};
    final toByNumber = <double, List<String>>{};
    for (final chapter in progress) {
      final number = chapter.chapterNumber ?? oldNumbers[chapter.chapterId];
      if (number != null) (fromByNumber[number] ??= []).add(chapter.chapterId);
    }
    for (final chapter in targetChapters) {
      if (chapter.chapterNumber != null) {
        (toByNumber[chapter.chapterNumber!] ??= []).add(chapter.chapterId);
      }
    }
    final matches = confirmedChapterMatches == null
        ? <String, String>{
            for (final entry in fromByNumber.entries)
              if (entry.value.length == 1 && toByNumber[entry.key]?.length == 1)
                entry.value.single: toByNumber[entry.key]!.single,
          }
        : Map<String, String>.from(confirmedChapterMatches);
    final fromIds = progress.map((item) => item.chapterId).toSet();
    final toIds = targetChapters.map((item) => item.chapterId).toSet();
    if (matches.keys.any((key) => !fromIds.contains(key)) ||
        matches.values.any((key) => !toIds.contains(key)) ||
        matches.values.toSet().length != matches.length) {
      throw const FormatException(
        'Chapter matches must identify distinct chapters in both sources.',
      );
    }
    return MangaSourceMigrationPlan._(
      source: stored,
      target: target,
      targetChapters: targetChapters,
      chapterMatches: matches,
      unmatchedChapterIds: fromIds
          .where((id) => !matches.containsKey(id))
          .toList(),
      fingerprint: await _migrationFingerprint(store, stored, target),
    );
  }

  /// The UI must show the target and matched/unmatched counts before confirming.
  /// Its protected identity must already have been selected/written separately;
  /// this method never accepts or stores a raw extension identity or URL.
  Future<MangaSourceMigrationResult> confirmSourceMigration(
    MangaSourceMigrationPlan plan, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      throw StateError('Source migration requires explicit confirmation.');
    }
    return store.transaction((transaction) async {
      if (await _migrationFingerprint(transaction, plan.source, plan.target) !=
          plan._fingerprint) {
        throw StateError(
          'Library data changed. Preview the source migration again.',
        );
      }
      final source = plan.source;
      final target = plan.target;
      final currentTarget = await transaction.libraryEntry(
        ownerKey: target.ownerKey,
        sourceId: target.sourceId,
        entryId: target.entryId,
      );
      if (currentTarget == null) {
        await transaction.upsertLibraryEntry(
          MangaLibraryEntry(
            ownerKey: target.ownerKey,
            sourceId: target.sourceId,
            entryId: target.entryId,
            title: target.title,
            metadata: target.metadata,
            coverUri: target.coverUri,
            updatedAt: target.updatedAt,
            category: source.category,
            status: source.status,
          ),
        );
      }
      await transaction.replaceChapterSnapshot(
        ownerKey: target.ownerKey,
        sourceId: target.sourceId,
        entryId: target.entryId,
        chapters: plan.targetChapters,
        checkedAt: DateTime.now().toUtc(),
      );
      final progress = await transaction.chapterProgressForEntry(
        ownerKey: source.ownerKey,
        sourceId: source.sourceId,
        entryId: source.entryId,
      );
      final latest = await transaction.progress(
        ownerKey: source.ownerKey,
        sourceId: source.sourceId,
        entryId: source.entryId,
      );
      final targetLatest = await transaction.progress(
        ownerKey: target.ownerKey,
        sourceId: target.sourceId,
        entryId: target.entryId,
      );
      var copied = 0;
      for (final chapter in progress) {
        final matchedId = plan.chapterMatches[chapter.chapterId];
        if (matchedId == null) continue;
        final existing = await transaction.chapterProgress(
          ownerKey: target.ownerKey,
          sourceId: target.sourceId,
          entryId: target.entryId,
          chapterId: matchedId,
        );
        if (existing != null &&
            !existing.updatedAt.isBefore(chapter.updatedAt)) {
          continue;
        }
        final targetChapter = plan.targetChapters.firstWhere(
          (item) => item.chapterId == matchedId,
        );
        await transaction.restoreChapterProgress(
          MangaReadingProgress(
            ownerKey: target.ownerKey,
            sourceId: target.sourceId,
            entryId: target.entryId,
            chapterId: matchedId,
            chapterNumber: targetChapter.chapterNumber,
            pageIndex: chapter.pageIndex,
            pageOffset: chapter.pageOffset,
            pageCount: chapter.pageCount,
            completed: chapter.completed,
            bookmarked: chapter.bookmarked,
            updatedAt: chapter.updatedAt,
          ),
          latest:
              latest?.chapterId == chapter.chapterId &&
              (targetLatest == null ||
                  targetLatest.updatedAt.isBefore(chapter.updatedAt)),
        );
        copied++;
      }
      return MangaSourceMigrationResult(
        copiedChapters: copied,
        unmatchedChapters: plan.unmatchedChapterIds.length,
      );
    });
  }
}

Future<String> _migrationFingerprint(
  MangaStore store,
  MangaLibraryEntry source,
  MangaLibraryEntry target,
) async {
  final rows = <Object?>[];
  for (final identity in [source, target]) {
    final entry = await store.libraryEntry(
      ownerKey: identity.ownerKey,
      sourceId: identity.sourceId,
      entryId: identity.entryId,
    );
    rows.add(
      entry == null
          ? null
          : [
              entry.title,
              entry.updatedAt.millisecondsSinceEpoch,
              entry.category,
              entry.status.name,
              entry.metadata,
              entry.chapterCheckedAt?.millisecondsSinceEpoch,
              entry.newChapterCount,
            ],
    );
    rows.add([
      for (final progress in await store.chapterProgressForEntry(
        ownerKey: identity.ownerKey,
        sourceId: identity.sourceId,
        entryId: identity.entryId,
      ))
        [
          progress.chapterId,
          progress.pageIndex,
          progress.pageOffset,
          progress.pageCount,
          progress.completed,
          progress.bookmarked,
          progress.updatedAt.millisecondsSinceEpoch,
        ],
    ]);
  }
  return sha256.convert(utf8.encode(jsonEncode(rows))).toString();
}
