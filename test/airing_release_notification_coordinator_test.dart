import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/catalog/application/airing_release_notification_coordinator.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const followedAnime = AnimeSummary(
    id: 42,
    idMal: 420,
    title: 'Romaji title',
    titleEnglish: 'English title',
    description: '',
    episodes: 12,
    score: 8,
  );
  const unrelatedAnime = AnimeSummary(
    id: 99,
    title: 'Unrelated',
    description: '',
    episodes: 12,
    score: 8,
  );
  const followed = HomeTrackedAnime(
    tracked: TrackedAnime(
      mediaId: 42,
      title: 'Romaji title',
      status: TrackingListStatus.watching,
      progress: 1,
    ),
    provider: TrackingProvider.anilist,
    anilistId: 42,
    coverImageUrl: null,
  );

  test('plans only future followed Calendar airings as simulcasts', () {
    final now = DateTime.utc(2026, 8, 24, 12);
    final plan = buildEpisodeReleaseNotificationPlan(
      scheduledEntries: [
        AiringScheduleEntry(
          anime: followedAnime,
          episode: 2,
          airingAt: now.add(const Duration(hours: 2)),
        ),
        AiringScheduleEntry(
          anime: unrelatedAnime,
          episode: 3,
          airingAt: now.add(const Duration(hours: 3)),
        ),
        AiringScheduleEntry(
          anime: followedAnime,
          episode: 1,
          airingAt: now.subtract(const Duration(minutes: 1)),
        ),
      ],
      followed: const [followed],
      includeSimulcast: true,
      includeDub: false,
      now: now,
    );

    expect(plan, hasLength(1));
    expect(plan.single.mediaId, 42);
    expect(plan.single.episode, 2);
    expect(plan.single.title, 'English title');
    expect(plan.single.kind, EpisodeReleaseNotificationKind.simulcast);
  });

  test('never relabels a normal airing as a dub', () {
    final now = DateTime.utc(2026, 8, 24, 12);
    final normal = AiringScheduleEntry(
      anime: followedAnime,
      episode: 2,
      airingAt: now.add(const Duration(hours: 2)),
    );
    final plan = buildEpisodeReleaseNotificationPlan(
      scheduledEntries: [normal],
      followed: const [followed],
      includeSimulcast: false,
      includeDub: true,
      now: now,
    );

    expect(plan, isEmpty);
    expect(verifiedDubReleaseNotificationScheduleAvailable, isFalse);
  });

  test('accepts dub entries only through the verified-dub input', () {
    final now = DateTime.utc(2026, 8, 24, 12);
    final dub = AiringScheduleEntry(
      anime: followedAnime,
      episode: 2,
      airingAt: now.add(const Duration(days: 2)),
    );
    final plan = buildEpisodeReleaseNotificationPlan(
      scheduledEntries: const [],
      verifiedDubEntries: [dub],
      followed: const [followed],
      includeSimulcast: false,
      includeDub: true,
      now: now,
    );

    expect(plan, hasLength(1));
    expect(plan.single.kind, EpisodeReleaseNotificationKind.dub);
  });
}
