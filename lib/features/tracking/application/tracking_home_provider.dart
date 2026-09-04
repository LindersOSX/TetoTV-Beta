import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/application/tracking_repository_factory.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final trackingHomeProvider = FutureProvider<TrackingHomeData>((ref) async {
  final tokenService = ref.watch(trackingTokenServiceProvider);
  final repositoryFactory = ref.watch(trackingRepositoryFactoryProvider);
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
        repositoryFactory: repositoryFactory,
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
  required TrackingRepositoryFactory repositoryFactory,
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
  final repository = repositoryFactory(provider, token);
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
                anilistId:
                    anime.anilistId ??
                    (provider == TrackingProvider.anilist
                        ? anime.mediaId
                        : null),
                malId:
                    anime.malId ??
                    (provider == TrackingProvider.myAnimeList
                        ? anime.mediaId
                        : null),
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
      final repositoryFactory = ref.watch(trackingRepositoryFactoryProvider);
      final requests = <Future<int>>[
        if (ids.anilistMediaId case final mediaId?)
          _loadLinkedProgress(
            provider: TrackingProvider.anilist,
            mediaId: mediaId,
            tokenService: tokenService,
            repositoryFactory: repositoryFactory,
          ),
        if (ids.malMediaId case final mediaId?)
          _loadLinkedProgress(
            provider: TrackingProvider.myAnimeList,
            mediaId: mediaId,
            tokenService: tokenService,
            repositoryFactory: repositoryFactory,
          ),
        if (ids.anilistMediaId != null || ids.malMediaId != null)
          _loadSimklProgress(
            ids: ids,
            tokenService: tokenService,
            repositoryFactory: repositoryFactory,
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
  required TrackingRepositoryFactory repositoryFactory,
}) async {
  try {
    final token = await tokenService.accessToken(provider);
    if (token == null || token.isEmpty) return 0;
    final repository = repositoryFactory(provider, token);
    return await repository.currentProgress(mediaId) ?? 0;
  } catch (_) {
    // One temporarily unavailable tracker must not hide the other provider's
    // progress or the local completion fallback.
    return 0;
  }
}

Future<int> _loadSimklProgress({
  required LinkedTrackingProgressIds ids,
  required TrackingTokenService tokenService,
  required TrackingRepositoryFactory repositoryFactory,
}) async {
  try {
    final token = await tokenService.accessToken(TrackingProvider.simkl);
    if (token == null || token.isEmpty) return 0;
    final repository = repositoryFactory(TrackingProvider.simkl, token);
    final externalRepository = switch (repository) {
      ExternalIdTrackingRepository value => value,
      _ => null,
    };
    if (externalRepository == null) return 0;
    return await externalRepository.currentProgressByIds(
          TrackingMediaIds(
            anilistId: ids.anilistMediaId,
            malId: ids.malMediaId,
          ),
        ) ??
        0;
  } catch (_) {
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
      final matches = matchesTrackingIds(
        item,
        anilistId: anilistMediaId,
        malId: malMediaId,
      );
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
    this.malId,
    required this.coverImageUrl,
    this.simklSourceUrl,
  });

  final TrackedAnime tracked;
  final TrackingProvider provider;
  final int? anilistId;
  final int? malId;
  final String? coverImageUrl;
  final String? simklSourceUrl;

  String? get effectiveSimklSourceUrl =>
      simklSourceUrl ??
      (provider == TrackingProvider.simkl ? tracked.sourceUrl : null);

  HomeTrackedAnime withSimklSourceUrl(String sourceUrl) => HomeTrackedAnime(
    tracked: tracked,
    provider: provider,
    anilistId: anilistId,
    malId: malId,
    coverImageUrl: coverImageUrl,
    simklSourceUrl: sourceUrl,
  );
}

List<HomeTrackedAnime> _deduplicate(List<HomeTrackedAnime> items) {
  final unique = <String, HomeTrackedAnime>{};
  for (final item in items) {
    final key = item.anilistId != null
        ? 'anilist:${item.anilistId}'
        : item.malId != null
        ? 'mal:${item.malId}'
        : '${item.provider.slug}:${item.tracked.mediaId}:${item.tracked.title.toLowerCase().trim()}';
    final existing = unique[key];
    if (existing == null) {
      unique[key] = item;
      continue;
    }
    final sourceUrl =
        existing.effectiveSimklSourceUrl ?? item.effectiveSimklSourceUrl;
    if (sourceUrl != null && existing.effectiveSimklSourceUrl == null) {
      unique[key] = existing.withSimklSourceUrl(sourceUrl);
    }
  }
  return unique.values.toList(growable: false);
}

bool matchesTrackingIds(
  HomeTrackedAnime item, {
  required int anilistId,
  int? malId,
}) {
  final itemAnilistId =
      item.anilistId ??
      (item.provider == TrackingProvider.anilist ? item.tracked.mediaId : null);
  if (itemAnilistId == anilistId) return true;
  final itemMalId =
      item.malId ??
      (item.provider == TrackingProvider.myAnimeList
          ? item.tracked.mediaId
          : null);
  return malId != null && itemMalId == malId;
}
