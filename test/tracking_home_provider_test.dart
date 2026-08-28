import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('episode progress hydrates from the highest linked tracker', () {
    const anilist = HomeTrackedAnime(
      tracked: TrackedAnime(
        mediaId: 101,
        title: 'Example',
        status: TrackingListStatus.watching,
        progress: 4,
      ),
      provider: TrackingProvider.anilist,
      anilistId: 101,
      coverImageUrl: null,
    );
    const mal = HomeTrackedAnime(
      tracked: TrackedAnime(
        mediaId: 202,
        title: 'Example',
        status: TrackingListStatus.watching,
        progress: 7,
      ),
      provider: TrackingProvider.myAnimeList,
      anilistId: null,
      coverImageUrl: null,
    );
    const data = TrackingHomeData(
      watching: [anilist, mal],
      planToWatch: [],
      completed: [],
    );

    expect(data.progressFor(anilistMediaId: 101, malMediaId: 202), 7);
  });

  test('completed and planning shelves remain compatibility fallbacks', () {
    const completed = HomeTrackedAnime(
      tracked: TrackedAnime(
        mediaId: 202,
        title: 'Finished show',
        status: TrackingListStatus.completed,
        progress: 12,
      ),
      provider: TrackingProvider.myAnimeList,
      anilistId: null,
      coverImageUrl: null,
    );
    const data = TrackingHomeData(
      watching: [],
      planToWatch: [],
      completed: [completed],
    );

    expect(data.progressFor(anilistMediaId: 101, malMediaId: 202), 12);
  });
}
