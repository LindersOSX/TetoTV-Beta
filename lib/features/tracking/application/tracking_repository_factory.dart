import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/settings/application/simkl_account_controller.dart';
import 'package:anime_tv/features/tracking/data/anilist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/myanimelist_tracking_repository.dart';
import 'package:anime_tv/features/tracking/data/simkl_account_session.dart';
import 'package:anime_tv/features/tracking/data/simkl_tracking_repository.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef TrackingRepositoryFactory =
    TrackingRepository Function(TrackingProvider provider, String accessToken);

final trackingRepositoryFactoryProvider = Provider<TrackingRepositoryFactory>((
  ref,
) {
  final storage = ref.watch(secureStorageProvider);
  final tokenService = ref.watch(trackingTokenServiceProvider);
  final simklSessions = ref.watch(simklAccountSessionRegistryProvider);
  return (provider, accessToken) => trackingRepository(
    provider,
    accessToken,
    simklClientIdLoader: () => storage.read(key: simklClientIdStorageKey),
    simklSessionRegistry: simklSessions,
    simklCacheScopeLoader: () => tokenService.verifiedActiveProfileId(
      TrackingProvider.simkl,
      accessToken,
    ),
  );
});

TrackingRepository trackingRepository(
  TrackingProvider provider,
  String accessToken, {
  SimklClientIdLoader? simklClientIdLoader,
  SimklAppVersionLoader? simklAppVersionLoader,
  SimklAccountSessionRegistry? simklSessionRegistry,
  SimklCacheScopeLoader? simklCacheScopeLoader,
}) => switch (provider) {
  TrackingProvider.anilist => AniListTrackingRepository(
    accessToken: accessToken,
  ),
  TrackingProvider.myAnimeList => MyAnimeListTrackingRepository(
    accessToken: accessToken,
  ),
  TrackingProvider.simkl => SimklTrackingRepository(
    accessToken: accessToken,
    clientIdLoader: simklClientIdLoader ?? () async => null,
    sessionRegistry:
        simklSessionRegistry ??
        (throw ArgumentError('SIMKL needs a shared account session registry.')),
    cacheScopeLoader: simklCacheScopeLoader ?? () async => null,
    appVersionLoader: simklAppVersionLoader,
  ),
};
