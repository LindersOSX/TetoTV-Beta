import 'package:anime_tv/features/catalog/data/anilist_catalog_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/downloads/application/offline_catalog_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final catalogClientProvider = Provider<AniListCatalogClient>(
  (_) => AniListCatalogClient(),
);

final trendingAnimeProvider = FutureProvider<List<AnimeSummary>>(
  (ref) => _withOfflineCatalogFallback(
    ref,
    () => ref.watch(catalogClientProvider).trending(),
  ),
);

final seasonalAnimeProvider = FutureProvider<List<AnimeSummary>>(
  (ref) => _withOfflineCatalogFallback(
    ref,
    () => ref.watch(catalogClientProvider).seasonal(),
  ),
);

final animeDetailsProvider = FutureProvider.family<AnimeSummary, int>((
  ref,
  id,
) async {
  try {
    return await ref.watch(catalogClientProvider).details(id);
  } catch (error, stackTrace) {
    try {
      final saved = await ref
          .watch(offlineCatalogSnapshotServiceProvider)
          .load(id);
      if (saved != null) return saved.anime;
    } catch (_) {
      // Preserve the real catalog failure below.
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
});

final franchiseProvider = FutureProvider.family<List<AnimeSummary>, int>(
  (ref, id) => ref.watch(catalogClientProvider).franchise(id),
);

final studioAnimeProvider = FutureProvider.family<List<AnimeSummary>, int>(
  (ref, id) => ref.watch(catalogClientProvider).studioAnime(id),
);

final staffAnimeProvider = FutureProvider.family<List<AnimeSummary>, int>(
  (ref, id) => ref.watch(catalogClientProvider).staffAnime(id),
);

final airingWeekProvider = FutureProvider<List<AiringScheduleEntry>>((ref) {
  final now = DateTime.now();
  final from = DateTime(now.year, now.month, now.day);
  return ref
      .watch(catalogClientProvider)
      .airingSchedule(from: from, to: from.add(const Duration(days: 7)));
});

/// Returns search results for [query].
///
/// Invalidate this provider to trigger a fresh network request.
final searchAnimeProvider = FutureProvider.family<List<AnimeSummary>, String>((
  ref,
  query,
) async {
  final trimmed = query.trim();
  if (trimmed.length < 2) return const <AnimeSummary>[];
  try {
    return await ref.watch(catalogClientProvider).search(trimmed);
  } catch (error, stackTrace) {
    try {
      final saved = await ref
          .watch(offlineCatalogSnapshotServiceProvider)
          .list();
      return searchOfflineAnime(saved.map((item) => item.anime), trimmed);
    } catch (_) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
});

Future<List<AnimeSummary>> _withOfflineCatalogFallback(
  Ref ref,
  Future<List<AnimeSummary>> Function() network,
) async {
  try {
    return await network();
  } catch (error, stackTrace) {
    try {
      final saved = await ref
          .watch(offlineCatalogSnapshotServiceProvider)
          .list();
      final safeCatalog = saved
          .map((item) => item.anime)
          .where((anime) => !anime.isAdult)
          .toList(growable: false);
      if (safeCatalog.isNotEmpty) {
        return List.unmodifiable(safeCatalog);
      }
    } catch (_) {
      // Preserve the real catalog failure below.
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

List<AnimeSummary> searchOfflineAnime(
  Iterable<AnimeSummary> catalog,
  String query,
) {
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
  if (terms.isEmpty) return const [];
  final matches = catalog
      .where((anime) {
        if (anime.isAdult) return false;
        final searchable = [
          anime.title,
          anime.titleEnglish,
          anime.titleRomaji,
          ...anime.synonyms,
        ].whereType<String>().join(' ').toLowerCase();
        return terms.every(searchable.contains);
      })
      .toList(growable: false);
  return List.unmodifiable(matches);
}
