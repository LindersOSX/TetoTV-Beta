import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/data/anilist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/myanimelist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  test('maps all tracker list states to AniList values', () {
    expect(anilistStatus(TrackingListStatus.watching), 'CURRENT');
    expect(anilistStatus(TrackingListStatus.planToWatch), 'PLANNING');
    expect(anilistStatus(TrackingListStatus.completed), 'COMPLETED');
    expect(anilistStatus(TrackingListStatus.dropped), 'DROPPED');
    expect(anilistStatus(TrackingListStatus.onHold), 'PAUSED');
  });

  test('maps all tracker list states to MyAnimeList values', () {
    expect(myAnimeListStatus(TrackingListStatus.watching), 'watching');
    expect(myAnimeListStatus(TrackingListStatus.planToWatch), 'plan_to_watch');
    expect(myAnimeListStatus(TrackingListStatus.completed), 'completed');
    expect(myAnimeListStatus(TrackingListStatus.dropped), 'dropped');
    expect(myAnimeListStatus(TrackingListStatus.onHold), 'on_hold');
  });

  test(
    'status updater remains alive without a UI state subscription',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(
        trackingStatusControllerProvider.notifier,
      );
      await container.pump();

      expect(notifier.mounted, isTrue);
    },
  );
}
