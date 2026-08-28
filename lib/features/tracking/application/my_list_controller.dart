import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/data/anilist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/myanimelist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum MyListSort { title, score, lastUpdated, startDate }

typedef TrackingRepositoryFactory =
    TrackingRepository Function(TrackingProvider provider, String accessToken);

final trackingRepositoryFactoryProvider = Provider<TrackingRepositoryFactory>(
  (_) => trackingRepository,
);

extension MyListSortLabel on MyListSort {
  String get displayName => switch (this) {
    MyListSort.title => 'Title',
    MyListSort.score => 'Score',
    MyListSort.lastUpdated => 'Last updated',
    MyListSort.startDate => 'Start date',
  };
}

final myListSortProvider =
    StateNotifierProvider<MyListSortController, MyListSort>((ref) {
      final controller = MyListSortController(ref.watch(secureStorageProvider));
      Future.microtask(controller.load);
      return controller;
    });

class MyListSortController extends StateNotifier<MyListSort> {
  MyListSortController(this._storage) : super(MyListSort.title);

  static const _key = 'my_list_sort';
  final FlutterSecureStorage _storage;

  Future<void> load() async {
    try {
      final saved = await _storage.read(key: _key);
      state = MyListSort.values.firstWhere(
        (value) => value.name == saved,
        orElse: () => MyListSort.title,
      );
    } catch (_) {
      // Title ordering remains a safe default.
    }
  }

  Future<void> setSort(MyListSort value) async {
    state = value;
    try {
      await _storage.write(key: _key, value: value.name);
    } catch (_) {
      // Keep the current session preference if storage is unavailable.
    }
  }
}

List<HomeTrackedAnime> sortMyListItems(
  Iterable<HomeTrackedAnime> source,
  MyListSort sort,
) {
  final items = source.toList(growable: false);
  int compareNullable(Comparable<dynamic>? left, Comparable<dynamic>? right) {
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return right.compareTo(left);
  }

  items.sort((left, right) {
    final result = switch (sort) {
      MyListSort.title => left.tracked.title.toLowerCase().compareTo(
        right.tracked.title.toLowerCase(),
      ),
      MyListSort.score => compareNullable(
        left.tracked.score,
        right.tracked.score,
      ),
      MyListSort.lastUpdated => compareNullable(
        left.tracked.updatedAt,
        right.tracked.updatedAt,
      ),
      MyListSort.startDate => compareNullable(
        left.tracked.startDate,
        right.tracked.startDate,
      ),
    };
    if (result != 0) return result;
    return left.tracked.title.toLowerCase().compareTo(
      right.tracked.title.toLowerCase(),
    );
  });
  return items;
}

final trackingListProvider = FutureProvider.autoDispose
    .family<TrackingListResult, TrackingListStatus>((ref, status) async {
      final tokenService = ref.watch(trackingTokenServiceProvider);
      final providerItems = await Future.wait([
        for (final provider in TrackingProvider.values)
          () async {
            String? token;
            try {
              token = await tokenService.accessToken(provider);
            } catch (error) {
              // Keep the other tracker usable if this provider cannot refresh.
              return _TrackingProviderListResult.failed(provider, error);
            }
            if (token == null || token.isEmpty) {
              return _TrackingProviderListResult.disconnected(provider);
            }
            final repository = ref.read(trackingRepositoryFactoryProvider)(
              provider,
              token,
            );
            try {
              final entries = await repository.list(status);
              return _TrackingProviderListResult.succeeded(
                provider,
                entries
                    .map(
                      (tracked) => HomeTrackedAnime(
                        tracked: tracked,
                        provider: provider,
                        anilistId: provider == TrackingProvider.anilist
                            ? tracked.mediaId
                            : null,
                        coverImageUrl: tracked.coverImageUrl,
                      ),
                    )
                    .toList(growable: false),
              );
            } catch (error) {
              // One disconnected or temporarily unavailable tracker should not
              // hide the other tracker's list.
              return _TrackingProviderListResult.failed(provider, error);
            }
          }(),
      ]);
      final items = providerItems
          .expand((result) => result.items)
          .toList(growable: false);
      items.sort(
        (left, right) => left.tracked.title.compareTo(right.tracked.title),
      );
      return TrackingListResult(
        items: items,
        attempted: {
          for (final result in providerItems)
            if (result.attempted) result.provider,
        },
        failures: {
          for (final result in providerItems)
            if (result.failure != null) result.provider: result.failure!,
        },
      );
    });

class TrackingListResult {
  const TrackingListResult({
    required this.items,
    this.attempted = const {},
    this.failures = const {},
  });

  final List<HomeTrackedAnime> items;
  final Set<TrackingProvider> attempted;
  final Map<TrackingProvider, Object> failures;

  bool get hasFailures => failures.isNotEmpty;

  bool get allAttemptedFailed =>
      attempted.isNotEmpty && failures.length == attempted.length;

  String get failedProviderNames => failures.keys
      .map((provider) => provider.displayName)
      .join(failures.length == 2 ? ' and ' : ', ');
}

class _TrackingProviderListResult {
  const _TrackingProviderListResult({
    required this.provider,
    required this.attempted,
    required this.items,
    this.failure,
  });

  factory _TrackingProviderListResult.disconnected(TrackingProvider provider) =>
      _TrackingProviderListResult(
        provider: provider,
        attempted: false,
        items: const [],
      );

  factory _TrackingProviderListResult.succeeded(
    TrackingProvider provider,
    List<HomeTrackedAnime> items,
  ) => _TrackingProviderListResult(
    provider: provider,
    attempted: true,
    items: items,
  );

  factory _TrackingProviderListResult.failed(
    TrackingProvider provider,
    Object failure,
  ) => _TrackingProviderListResult(
    provider: provider,
    attempted: true,
    items: const [],
    failure: failure,
  );

  final TrackingProvider provider;
  final bool attempted;
  final List<HomeTrackedAnime> items;
  final Object? failure;
}

final trackingStatusControllerProvider =
    StateNotifierProvider<TrackingStatusController, AsyncValue<void>>(
      (ref) => TrackingStatusController(ref),
    );

class TrackingStatusController extends StateNotifier<AsyncValue<void>> {
  TrackingStatusController(this._ref) : super(const AsyncData(null));

  final Ref _ref;

  Future<void> update(HomeTrackedAnime item, TrackingListStatus status) async {
    if (status == item.tracked.status) return;
    state = const AsyncLoading();
    try {
      final token = await _ref
          .read(trackingTokenServiceProvider)
          .accessToken(item.provider);
      if (!mounted) return;
      if (token == null || token.isEmpty) {
        throw StateError('${item.provider.displayName} is not connected.');
      }
      await _ref
          .read(trackingRepositoryFactoryProvider)(item.provider, token)
          .updateStatus(mediaId: item.tracked.mediaId, status: status);
      if (!mounted) return;
      _ref.invalidate(trackingListProvider(item.tracked.status));
      _ref.invalidate(trackingListProvider(status));
      _ref.invalidate(trackingHomeProvider);
      state = const AsyncData(null);
    } catch (error, stackTrace) {
      if (mounted) state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> remove(HomeTrackedAnime item) async {
    state = const AsyncLoading();
    try {
      final token = await _ref
          .read(trackingTokenServiceProvider)
          .accessToken(item.provider);
      if (!mounted) return;
      if (token == null || token.isEmpty) {
        throw StateError('${item.provider.displayName} is not connected.');
      }
      await _ref
          .read(trackingRepositoryFactoryProvider)(item.provider, token)
          .removeFromList(mediaId: item.tracked.mediaId);
      if (!mounted) return;
      _ref.invalidate(trackingListProvider(item.tracked.status));
      _ref.invalidate(trackingHomeProvider);
      state = const AsyncData(null);
    } catch (error, stackTrace) {
      if (mounted) state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  /// Adds or updates a catalog title on every connected tracker for which the
  /// catalog supplied a real provider media ID.
  ///
  /// Search/Home results are AniList catalog entries and may not already have
  /// a [HomeTrackedAnime] row. Keeping this operation here prevents the UI
  /// from fabricating list entries merely to call [update].
  Future<CatalogTrackingUpdateResult> updateCatalogStatus({
    required int anilistId,
    required int? malId,
    required TrackingListStatus status,
  }) =>
      _changeCatalogStatus(anilistId: anilistId, malId: malId, status: status);

  Future<CatalogTrackingUpdateResult> removeCatalogStatus({
    required int anilistId,
    required int? malId,
  }) => _changeCatalogStatus(anilistId: anilistId, malId: malId);

  Future<CatalogTrackingUpdateResult> _changeCatalogStatus({
    required int anilistId,
    required int? malId,
    TrackingListStatus? status,
  }) async {
    state = const AsyncLoading();
    final updated = <TrackingProvider>{};
    final missingMediaId = <TrackingProvider>{};
    final failures = <TrackingProvider, Object>{};
    var connectedProviders = 0;

    try {
      for (final provider in TrackingProvider.values) {
        String? token;
        try {
          token = await _ref
              .read(trackingTokenServiceProvider)
              .accessToken(provider);
        } catch (error) {
          failures[provider] = error;
          continue;
        }
        if (token == null || token.isEmpty) continue;
        connectedProviders++;

        final mediaId = switch (provider) {
          TrackingProvider.anilist => anilistId > 0 ? anilistId : null,
          TrackingProvider.myAnimeList =>
            malId != null && malId > 0 ? malId : null,
        };
        if (mediaId == null) {
          missingMediaId.add(provider);
          continue;
        }

        try {
          final repository = _ref.read(trackingRepositoryFactoryProvider)(
            provider,
            token,
          );
          if (status == null) {
            await repository.removeFromList(mediaId: mediaId);
          } else {
            await repository.updateStatus(mediaId: mediaId, status: status);
          }
          updated.add(provider);
        } catch (error) {
          failures[provider] = error;
        }
      }

      if (updated.isEmpty) {
        if (connectedProviders == 0 && failures.isEmpty) {
          throw StateError(
            'Connect AniList or MAL in Settings before changing a show status.',
          );
        }
        if (connectedProviders > 0 &&
            missingMediaId.length == connectedProviders &&
            failures.isEmpty) {
          throw StateError(
            'This title is missing the media ID required by the connected tracker.',
          );
        }
        final names = failures.keys
            .map((provider) => provider.displayName)
            .join(failures.length == 2 ? ' and ' : ', ');
        throw StateError(
          names.isEmpty
              ? 'The connected tracker could not change this title.'
              : 'Could not change $names. Reconnect it in Settings and try again.',
        );
      }

      for (final listStatus in TrackingListStatus.values) {
        _ref.invalidate(trackingListProvider(listStatus));
      }
      _ref.invalidate(trackingHomeProvider);
      state = const AsyncData(null);
      return CatalogTrackingUpdateResult(
        updated: Set.unmodifiable(updated),
        missingMediaId: Set.unmodifiable(missingMediaId),
        failures: Map.unmodifiable(failures),
      );
    } catch (error, stackTrace) {
      if (mounted) state = AsyncError(error, stackTrace);
      rethrow;
    }
  }
}

class CatalogTrackingUpdateResult {
  const CatalogTrackingUpdateResult({
    required this.updated,
    required this.missingMediaId,
    required this.failures,
  });

  final Set<TrackingProvider> updated;
  final Set<TrackingProvider> missingMediaId;
  final Map<TrackingProvider, Object> failures;

  bool get isPartial => missingMediaId.isNotEmpty || failures.isNotEmpty;

  String get updatedProviderNames => updated
      .map((provider) => provider.displayName)
      .join(updated.length == 2 ? ' and ' : ', ');
}

TrackingRepository trackingRepository(
  TrackingProvider provider,
  String accessToken,
) => switch (provider) {
  TrackingProvider.anilist => AniListTrackingRepository(
    accessToken: accessToken,
  ),
  TrackingProvider.myAnimeList => MyAnimeListTrackingRepository(
    accessToken: accessToken,
  ),
};
