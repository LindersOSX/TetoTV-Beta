import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final tetoTvDatabaseProvider = Provider<TetoTvDatabase>(
  (_) => TetoTvDatabase.instance,
);

final recentPlaybackProvider = FutureProvider<List<PlaybackCheckpoint>>((ref) {
  return ref.watch(tetoTvDatabaseProvider).recentHistory();
});

final latestPlaybackProvider = FutureProvider.family<PlaybackCheckpoint?, int>((
  ref,
  mediaId,
) {
  return ref.watch(tetoTvDatabaseProvider).latestCheckpoint(mediaId);
});

final seriesPlaybackPreferencesProvider =
    FutureProvider.family<SeriesPlaybackPreferences, int>((ref, mediaId) {
      return ref.watch(tetoTvDatabaseProvider).seriesPreferences(mediaId);
    });

typedef SeriesPlaybackPreferencesWriter =
    Future<void> Function(int mediaId, SeriesPlaybackPreferences preferences);

final seriesPlaybackPreferencesWriterProvider =
    Provider<SeriesPlaybackPreferencesWriter>((ref) {
      final database = ref.watch(tetoTvDatabaseProvider);
      return database.saveSeriesPreferences;
    });

final dismissedContinueWatchingProvider = FutureProvider<Set<int>>((ref) {
  return ref.watch(tetoTvDatabaseProvider).dismissedContinueWatchingIds();
});
