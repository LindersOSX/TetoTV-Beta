import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'catalog status updates every connected tracker using provider IDs',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.anilist.tokenStorageKey: 'anilist-token',
        TrackingProvider.myAnimeList.tokenStorageKey: 'mal-token',
      });
      final repositories = <TrackingProvider, _RecordingRepository>{};
      final container = ProviderContainer(
        overrides: [
          trackingRepositoryFactoryProvider.overrideWithValue((provider, _) {
            return repositories.putIfAbsent(provider, _RecordingRepository.new);
          }),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(trackingStatusControllerProvider.notifier)
          .updateCatalogStatus(
            anilistId: 101,
            malId: 202,
            status: TrackingListStatus.planToWatch,
          );

      expect(result.updated, TrackingProvider.values.toSet());
      expect(repositories[TrackingProvider.anilist]!.statusUpdates, [
        (mediaId: 101, status: TrackingListStatus.planToWatch),
      ]);
      expect(repositories[TrackingProvider.myAnimeList]!.statusUpdates, [
        (mediaId: 202, status: TrackingListStatus.planToWatch),
      ]);
    },
  );

  test('catalog status explains when no tracker is connected', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(trackingStatusControllerProvider.notifier)
          .updateCatalogStatus(
            anilistId: 101,
            malId: 202,
            status: TrackingListStatus.planToWatch,
          ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Connect AniList or MAL'),
        ),
      ),
    );
  });

  test(
    'catalog removal deletes the title from every connected tracker',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.anilist.tokenStorageKey: 'anilist-token',
        TrackingProvider.myAnimeList.tokenStorageKey: 'mal-token',
      });
      final repositories = <TrackingProvider, _RecordingRepository>{};
      final container = ProviderContainer(
        overrides: [
          trackingRepositoryFactoryProvider.overrideWithValue((provider, _) {
            return repositories.putIfAbsent(provider, _RecordingRepository.new);
          }),
        ],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(trackingStatusControllerProvider.notifier)
          .removeCatalogStatus(anilistId: 303, malId: 404);

      expect(result.updated, TrackingProvider.values.toSet());
      expect(repositories[TrackingProvider.anilist]!.removals, [303]);
      expect(repositories[TrackingProvider.myAnimeList]!.removals, [404]);
    },
  );
}

class _RecordingRepository implements TrackingRepository {
  final statusUpdates = <({int mediaId, TrackingListStatus status})>[];
  final removals = <int>[];

  @override
  Future<int?> currentProgress(int mediaId) async => null;

  @override
  Future<List<TrackedAnime>> list(TrackingListStatus status) async => const [];

  @override
  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  }) async {}

  @override
  Future<void> removeFromList({required int mediaId}) async {
    removals.add(mediaId);
  }

  @override
  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    statusUpdates.add((mediaId: mediaId, status: status));
  }
}
