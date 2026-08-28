import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/data/anilist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/myanimelist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final trackingHomeProvider = FutureProvider<TrackingHomeData>((ref) async {
  final tokenService = ref.watch(trackingTokenServiceProvider);
  const homeStatuses = [
    TrackingListStatus.watching,
    TrackingListStatus.planToWatch,
    TrackingListStatus.completed,
  ];
  final all = <TrackingListStatus, List<HomeTrackedAnime>>{
    for (final status in homeStatuses) status: [],
  };

  final providerResults = await Future.wait([
    for (final provider in TrackingProvider.values)
      _loadProviderHomeData(
        provider: provider,
        tokenService: tokenService,
        statuses: homeStatuses,
      ),
  ]);
  for (final providerData in providerResults) {
    for (final entry in providerData.entries) {
      all[entry.key]!.addAll(entry.value);
    }
  }

  return TrackingHomeData(
    watching: _deduplicate(all[TrackingListStatus.watching]!),
    planToWatch: _deduplicate(all[TrackingListStatus.planToWatch]!),
    completed: _deduplicate(all[TrackingListStatus.completed]!),
  );
});

Future<Map<TrackingListStatus, List<HomeTrackedAnime>>> _loadProviderHomeData({
  required TrackingProvider provider,
  required TrackingTokenService tokenService,
  required List<TrackingListStatus> statuses,
}) async {
  String? token;
  try {
    token = await tokenService.accessToken(provider);
  } catch (_) {
    // One expired or temporarily unreachable provider must not prevent the
    // other linked tracker from populating the home screen.
    return const {};
  }
  if (token == null || token.isEmpty) return const {};
  final repository = switch (provider) {
    TrackingProvider.anilist => AniListTrackingRepository(accessToken: token),
    TrackingProvider.myAnimeList => MyAnimeListTrackingRepository(
      accessToken: token,
    ),
  };
  final lists = await Future.wait([
    for (final status in statuses)
      () async {
        try {
          final tracked = await repository.list(status);
          return MapEntry(status, [
            for (final anime in tracked.take(20))
              HomeTrackedAnime(
                tracked: anime,
                provider: provider,
                anilistId: provider == TrackingProvider.anilist
                    ? anime.mediaId
                    : null,
                coverImageUrl: anime.coverImageUrl,
              ),
          ]);
        } catch (_) {
          // A single unavailable status should not hide the provider's other
          // shelves or data from the other connected tracker.
          return MapEntry(status, const <HomeTrackedAnime>[]);
        }
      }(),
  ]);
  return Map.fromEntries(lists);
}

typedef LinkedTrackingProgressIds = ({int? anilistMediaId, int? malMediaId});

/// Hydrates the exact series progress from every linked tracker.
///
/// This intentionally queries the individual list entry rather than relying
/// on Home's capped shelves, so On Hold/Dropped titles and entries beyond the
/// first twenty still resume at the correct next episode.
final linkedTrackingProgressProvider = FutureProvider.autoDispose
    .family<int, LinkedTrackingProgressIds>((ref, ids) async {
      final tokenService = ref.watch(trackingTokenServiceProvider);
      final requests = <Future<int>>[
        if (ids.anilistMediaId case final mediaId?)
          _loadLinkedProgress(
            provider: TrackingProvider.anilist,
            mediaId: mediaId,
            tokenService: tokenService,
          ),
        if (ids.malMediaId case final mediaId?)
          _loadLinkedProgress(
            provider: TrackingProvider.myAnimeList,
            mediaId: mediaId,
            tokenService: tokenService,
          ),
      ];
      if (requests.isEmpty) return 0;
      final values = await Future.wait(requests);
      return values.fold<int>(0, (highest, value) {
        return value > highest ? value : highest;
      });
    });

Future<int> _loadLinkedProgress({
  required TrackingProvider provider,
  required int mediaId,
  required TrackingTokenService tokenService,
}) async {
  try {
    final token = await tokenService.accessToken(provider);
    if (token == null || token.isEmpty) return 0;
    final repository = switch (provider) {
      TrackingProvider.anilist => AniListTrackingRepository(accessToken: token),
      TrackingProvider.myAnimeList => MyAnimeListTrackingRepository(
        accessToken: token,
      ),
    };
    return await repository.currentProgress(mediaId) ?? 0;
  } catch (_) {
    // One temporarily unavailable tracker must not hide the other provider's
    // progress or the local completion fallback.
    return 0;
  }
}

class TrackingHomeData {
  const TrackingHomeData({
    required this.watching,
    required this.planToWatch,
    required this.completed,
  });

  final List<HomeTrackedAnime> watching;
  final List<HomeTrackedAnime> planToWatch;
  final List<HomeTrackedAnime> completed;

  /// Returns the highest known episode from either linked tracker.
  ///
  /// Shelf scanning is an immediate fallback while the exact linked-account
  /// progress provider is loading.
  int progressFor({required int anilistMediaId, int? malMediaId}) {
    var progress = 0;
    for (final item in [...watching, ...planToWatch, ...completed]) {
      final matches =
          item.anilistId == anilistMediaId ||
          (malMediaId != null &&
              item.provider == TrackingProvider.myAnimeList &&
              item.tracked.mediaId == malMediaId);
      if (matches && item.tracked.progress > progress) {
        progress = item.tracked.progress;
      }
    }
    return progress;
  }
}

class HomeTrackedAnime {
  const HomeTrackedAnime({
    required this.tracked,
    required this.provider,
    required this.anilistId,
    required this.coverImageUrl,
  });

  final TrackedAnime tracked;
  final TrackingProvider provider;
  final int? anilistId;
  final String? coverImageUrl;
}

List<HomeTrackedAnime> _deduplicate(List<HomeTrackedAnime> items) {
  final unique = <String, HomeTrackedAnime>{};
  for (final item in items) {
    final key =
        item.anilistId?.toString() ?? item.tracked.title.toLowerCase().trim();
    unique.putIfAbsent(key, () => item);
  }
  return unique.values.toList(growable: false);
}
