import 'package:anime_tv/features/manga/data/manga_store.dart';

/// Shared by library and chapter browser. A deliberate in-progress chapter wins;
/// otherwise continue forward from the latest chapter, then fill earlier gaps.
String? selectMangaContinueChapter({
  required List<String> orderedChapterIds,
  required Iterable<MangaReadingProgress> history,
  MangaReadingProgress? lastRead,
}) {
  final available = orderedChapterIds.toSet();
  final byId = {for (final row in history) row.chapterId: row};
  final unfinished =
      history
          .where(
            (row) =>
                !row.completed &&
                available.contains(row.chapterId) &&
                ((row.pageCount ?? 0) > 0 ||
                    row.pageIndex > 0 ||
                    row.pageOffset > 0 ||
                    lastRead?.chapterId == row.chapterId),
          )
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  if (unfinished.isNotEmpty) return unfinished.first.chapterId;
  final lastIndex = orderedChapterIds.indexOf(lastRead?.chapterId ?? '');
  for (final id in orderedChapterIds.skip(lastIndex + 1)) {
    if (!(byId[id]?.completed ?? false)) return id;
  }
  for (final id in orderedChapterIds) {
    if (!(byId[id]?.completed ?? false)) return id;
  }
  return null;
}
