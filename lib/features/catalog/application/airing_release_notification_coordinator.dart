import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The current AniList/MAL calendar exposes normal Japanese airtimes but no
/// independently verified English-dub release timestamps.
///
/// Keep this false until TetoTV has a release-data source which explicitly
/// marks entries as dubs. Never infer a dub from a title, installed provider,
/// or multi-audio playback result.
const verifiedDubReleaseNotificationScheduleAvailable = false;

typedef EpisodeReleaseNotificationSync =
    Future<int> Function(Iterable<EpisodeReleaseNotification> notifications);

final episodeReleaseNotificationSyncProvider =
    Provider<EpisodeReleaseNotificationSync>((_) {
      return AndroidTvBridge.instance.syncEpisodeReleaseNotifications;
    });

/// Keeps Android's background alarms aligned with the viewer's followed
/// Calendar. AlarmManager owns delivery after this completes, so minimizing
/// TetoTV does not prevent the notification.
final airingReleaseNotificationCoordinatorProvider = FutureProvider<void>((
  ref,
) async {
  final preferences = ref.watch(settingsPreferencesProvider);
  if (!preferences.loaded) return;
  final sync = ref.watch(episodeReleaseNotificationSyncProvider);

  if (!preferences.subEpisodeNotificationsEnabled &&
      !preferences.dubEpisodeNotificationsEnabled) {
    await sync(const []);
    return;
  }

  // Dub-only mode intentionally schedules nothing until verified dub timing
  // exists. In particular, normal AniList airtimes must never be relabeled as
  // English dub releases.
  if (!preferences.subEpisodeNotificationsEnabled &&
      !verifiedDubReleaseNotificationScheduleAvailable) {
    await sync(const []);
    return;
  }

  final schedule = ref.watch(airingWeekProvider);
  final tracking = ref.watch(trackingHomeProvider);
  final entries = schedule.valueOrNull;
  final trackingData = tracking.valueOrNull;
  if (entries == null || trackingData == null) {
    // Keep previously scheduled alarms during a transient catalog/tracker
    // failure. A later successful refresh atomically replaces them.
    return;
  }

  final plan = buildEpisodeReleaseNotificationPlan(
    scheduledEntries: entries,
    followed: [...trackingData.watching, ...trackingData.planToWatch],
    includeSimulcast: preferences.subEpisodeNotificationsEnabled,
    includeDub: preferences.dubEpisodeNotificationsEnabled,
    // No verified dub feed is configured yet. This remains a separate input
    // so adding one later cannot accidentally reinterpret normal airings.
    verifiedDubEntries: const [],
    now: DateTime.now(),
  );
  await sync(plan);
});

List<EpisodeReleaseNotification> buildEpisodeReleaseNotificationPlan({
  required Iterable<AiringScheduleEntry> scheduledEntries,
  required Iterable<HomeTrackedAnime> followed,
  required bool includeSimulcast,
  required bool includeDub,
  Iterable<AiringScheduleEntry> verifiedDubEntries = const [],
  DateTime? now,
}) {
  final threshold = now ?? DateTime.now();
  final followedItems = followed.toList(growable: false);
  final planned = <String, EpisodeReleaseNotification>{};

  void addEntries(
    Iterable<AiringScheduleEntry> entries,
    EpisodeReleaseNotificationKind kind,
  ) {
    for (final entry in entries) {
      if (!entry.airingAt.isAfter(threshold) ||
          !_isFollowed(entry.anime, followedItems)) {
        continue;
      }
      final key = '${entry.anime.id}:${entry.episode}:${kind.name}';
      planned.putIfAbsent(
        key,
        () => EpisodeReleaseNotification(
          mediaId: entry.anime.id,
          episode: entry.episode,
          title: _notificationTitle(entry.anime),
          releaseAt: entry.airingAt,
          kind: kind,
        ),
      );
    }
  }

  if (includeSimulcast) {
    addEntries(scheduledEntries, EpisodeReleaseNotificationKind.simulcast);
  }
  if (includeDub) {
    // Only explicitly verified dub entries enter this branch.
    addEntries(verifiedDubEntries, EpisodeReleaseNotificationKind.dub);
  }
  final result = planned.values.toList(growable: false)
    ..sort((left, right) => left.releaseAt.compareTo(right.releaseAt));
  return List.unmodifiable(result);
}

bool _isFollowed(AnimeSummary anime, List<HomeTrackedAnime> followed) {
  final normalized = _normalizedTitle(anime.title);
  return followed.any((item) {
    if (item.provider == TrackingProvider.anilist &&
        (item.anilistId ?? item.tracked.mediaId) == anime.id) {
      return true;
    }
    if (item.provider == TrackingProvider.myAnimeList &&
        anime.idMal == item.tracked.mediaId) {
      return true;
    }
    return _normalizedTitle(item.tracked.title) == normalized;
  });
}

String _notificationTitle(AnimeSummary anime) {
  final english = anime.titleEnglish?.trim();
  if (english != null && english.isNotEmpty) return english;
  return anime.title.trim().isEmpty ? 'Anime' : anime.title.trim();
}

String _normalizedTitle(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
