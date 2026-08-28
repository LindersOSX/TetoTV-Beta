import 'package:anime_tv/features/auth/presentation/anilist_pairing_screen.dart';
import 'package:anime_tv/features/auth/presentation/all_debrid_pairing_screen.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/auth/presentation/premiumize_pairing_screen.dart';
import 'package:anime_tv/features/auth/presentation/real_debrid_pairing_screen.dart';
import 'package:anime_tv/features/auth/presentation/torbox_pairing_screen.dart';
import 'package:anime_tv/features/catalog/presentation/anime_details_screen.dart';
import 'package:anime_tv/features/catalog/presentation/search_screen.dart';
import 'package:anime_tv/features/catalog/presentation/discover_screen.dart';
import 'package:anime_tv/features/catalog/presentation/airing_calendar_screen.dart';
import 'package:anime_tv/features/catalog/presentation/franchise_screen.dart';
import 'package:anime_tv/features/catalog/presentation/credits_screen.dart';
import 'package:anime_tv/features/catalog/presentation/catalog_collection_screen.dart';
import 'package:anime_tv/features/catalog/presentation/trailer_player_screen.dart';
import 'package:anime_tv/features/discord/presentation/discord_device_pairing_screen.dart';
import 'package:anime_tv/features/downloads/domain/downloaded_episode_asset.dart';
import 'package:anime_tv/features/downloads/presentation/download_manager_screen.dart';
import 'package:anime_tv/features/home/presentation/home_screen.dart';
import 'package:anime_tv/features/local_media/presentation/local_media_screen.dart';
import 'package:anime_tv/features/marketplace/presentation/marketplace_screen.dart';
import 'package:anime_tv/features/marketplace/data/web_playback_proxy.dart';
import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:anime_tv/features/settings/presentation/device_setup_screen.dart';
import 'package:anime_tv/features/settings/presentation/diagnostics_screen.dart';
import 'package:anime_tv/features/settings/presentation/initial_setup_screen.dart';
import 'package:anime_tv/features/settings/presentation/phone_setup_screen.dart';
import 'package:anime_tv/features/settings/presentation/privacy_screen.dart';
import 'package:anime_tv/features/settings/presentation/setup_method_screen.dart';
import 'package:anime_tv/features/settings/presentation/third_party_notices_screen.dart';
import 'package:anime_tv/features/settings/presentation/theme_studio_screen.dart';
import 'package:anime_tv/features/tracking/presentation/my_list_screen.dart';
import 'package:anime_tv/features/watch_together/presentation/watch_together_screen.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/data/direct_torrent_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/presentation/resolve_episode_screen.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

final appRouter = GoRouter(
  errorBuilder: (context, state) => const _InvalidRouteScreen(),
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(
      path: '/setup',
      builder: (context, state) => InitialSetupScreen(
        returnToMethodChoice:
            state.uri.queryParameters['from'] == 'method-choice',
      ),
    ),
    GoRoute(
      path: SetupMethodScreen.routePath,
      builder: (context, state) => SetupMethodScreen(
        focusPhoneOnReady: state.uri.queryParameters['focus'] == 'phone',
      ),
    ),
    GoRoute(
      path: PhoneSetupScreen.routePath,
      builder: (context, state) => const PhoneSetupScreen(),
    ),
    GoRoute(
      path: '/my-list',
      builder: (context, state) => const MyListScreen(),
    ),
    GoRoute(
      path: '/search',
      builder: (context, state) =>
          SearchScreen(initialQuery: state.uri.queryParameters['q']),
    ),
    GoRoute(
      path: '/discover',
      builder: (context, state) => const DiscoverScreen(),
    ),
    GoRoute(
      path: '/calendar',
      builder: (context, state) => const AiringCalendarScreen(),
    ),
    GoRoute(
      path: TrailerPlayerScreen.routePath,
      builder: (context, state) => state.extra is TrailerPlaybackRequest
          ? TrailerPlayerScreen(request: state.extra! as TrailerPlaybackRequest)
          : const _InvalidRouteScreen(),
    ),
    GoRoute(
      path: '/anime/:id',
      builder: (context, state) {
        final id = positiveRouteInt(state.pathParameters['id']);
        return id == null
            ? const _InvalidRouteScreen()
            : AnimeDetailsScreen(animeId: id);
      },
    ),
    GoRoute(
      path: '/anime/:id/franchise',
      builder: (context, state) {
        final id = positiveRouteInt(state.pathParameters['id']);
        return id == null
            ? const _InvalidRouteScreen()
            : FranchiseScreen(mediaId: id);
      },
    ),
    GoRoute(
      path: '/anime/:id/credits',
      builder: (context, state) {
        final id = positiveRouteInt(state.pathParameters['id']);
        return id == null
            ? const _InvalidRouteScreen()
            : CreditsScreen(mediaId: id);
      },
    ),
    GoRoute(
      path: '/studio/:id',
      builder: (context, state) {
        final id = positiveRouteInt(state.pathParameters['id']);
        return id == null
            ? const _InvalidRouteScreen()
            : CatalogCollectionScreen(
                id: id,
                name: state.uri.queryParameters['name'] ?? 'Studio',
                type: CatalogCollectionType.studio,
              );
      },
    ),
    GoRoute(
      path: '/staff/:id',
      builder: (context, state) {
        final id = positiveRouteInt(state.pathParameters['id']);
        return id == null
            ? const _InvalidRouteScreen()
            : CatalogCollectionScreen(
                id: id,
                name: state.uri.queryParameters['name'] ?? 'Staff member',
                type: CatalogCollectionType.staff,
              );
      },
    ),
    GoRoute(
      path: '/pair/anilist',
      builder: (context, state) =>
          const TrackingPairingScreen(provider: TrackingProvider.anilist),
    ),
    GoRoute(
      path: '/pair/myanimelist',
      builder: (context, state) =>
          const TrackingPairingScreen(provider: TrackingProvider.myAnimeList),
    ),
    GoRoute(
      path: '/pair/realdebrid',
      builder: (context, state) => const RealDebridPairingScreen(),
    ),
    GoRoute(
      path: '/pair/torbox',
      builder: (context, state) => const TorBoxPairingScreen(),
    ),
    GoRoute(
      path: '/pair/alldebrid',
      builder: (context, state) => const AllDebridPairingScreen(),
    ),
    GoRoute(
      path: '/pair/premiumize',
      builder: (context, state) => const PremiumizePairingScreen(),
    ),
    GoRoute(
      path: '/pair/discord',
      builder: (context, state) => const DiscordDevicePairingScreen(),
    ),
    GoRoute(
      path: '/settings/accounts',
      builder: (context, state) => AccountsScreen(
        openTracking: state.uri.queryParameters['section'] == 'tracking',
      ),
    ),
    GoRoute(
      path: '/settings/device-setup',
      builder: (context, state) => const DeviceSetupScreen(),
    ),
    GoRoute(
      path: '/settings/diagnostics',
      builder: (context, state) => const DiagnosticsScreen(),
    ),
    GoRoute(
      path: '/settings/privacy',
      builder: (context, state) => const PrivacyScreen(),
    ),
    GoRoute(
      path: '/settings/notices',
      builder: (context, state) => const ThirdPartyNoticesScreen(),
    ),
    GoRoute(
      path: ThemeStudioScreen.routePath,
      builder: (context, state) => const ThemeStudioScreen(),
    ),
    GoRoute(
      path: '/settings/marketplace',
      builder: (context, state) => const MarketplaceScreen(),
    ),
    GoRoute(
      path: '/downloads',
      builder: (context, state) => const DownloadManagerScreen(),
    ),
    GoRoute(
      path: '/library',
      redirect: (context, state) => '/settings/local-media',
    ),
    GoRoute(
      path: '/settings/local-media',
      builder: (context, state) => const LocalMediaScreen(managementOnly: true),
    ),
    GoRoute(
      path: '/watch-together',
      builder: (context, state) => WatchTogetherScreen(
        initialRoomCode: state.uri.queryParameters['room'],
      ),
    ),
    GoRoute(
      path: '/resolve',
      builder: (context, state) {
        final query = state.uri.queryParameters;
        final episode = resolveEpisodeReferenceFromQuery(query);
        if (episode == null) {
          return const _InvalidRouteScreen();
        }
        return ResolveEpisodeScreen(
          preferredProvider: query['preferredProvider'],
          preferredAuthor: query['preferredAuthor'],
          preferredSourceId: query['preferredSourceId'],
          preferredWebProviderId: query['preferredWebProviderId'],
          preferredQualityHeight: int.tryParse(
            query['preferredQualityHeight'] ?? '',
          ),
          preferredAudio: _routeAudioPreference(query['preferredAudio']),
          watchPartyFollow: query['watchPartyFollow'] == '1',
          watchPartySourceClass: query['watchPartySourceClass'],
          watchPartySourceFingerprint: query['watchPartySourceFingerprint'],
          watchPartySourceKey: query['watchPartySourceKey'],
          episode: episode,
        );
      },
    ),
    GoRoute(
      path: '/player',
      builder: (context, state) {
        final query = state.uri.queryParameters;
        final source = query['source'];
        final service = DebridService.fromSlug(query['debrid']);
        final resolved = state.extra;
        final validTypedStream = isValidTypedPlayerLaunch(
          source: source,
          service: service,
          resolved: resolved,
        );
        if (!isAllowedTypedPlayerSource(source) || !validTypedStream) {
          return const DebridOnlyPlaybackScreen();
        }
        final launch = resolved as PlaybackLaunch;
        return TvPlayerScreen(
          launch: launch,
          source: launch.stream.uri.toString(),
          subtitle: query['subtitle'],
          title: query['title'] ?? 'Anime playback',
          debridService: service ?? DebridService.realDebrid,
          anilistMediaId: launch.episode.anilistMediaId,
          malMediaId: launch.episode.malMediaId,
          episode: launch.episode.episode,
          coverImageUrl: launch.episode.coverImageUrl,
        );
      },
    ),
  ],
);

EpisodeReference? resolveEpisodeReferenceFromQuery(Map<String, String> query) {
  final anilistMediaId = positiveRouteInt(query['anilistId']);
  final episodeValue = query['episode'];
  final episode = episodeValue == null ? 1 : positiveRouteInt(episodeValue);
  if (anilistMediaId == null || episode == null) return null;
  return EpisodeReference(
    anilistMediaId: anilistMediaId,
    malMediaId: positiveRouteInt(query['malId']),
    year: positiveRouteInt(query['year']),
    title: query['title'] ?? 'Anime',
    episode: episode,
    alternativeTitles:
        query['synonyms']
            ?.split('|')
            .where((value) => value.isNotEmpty)
            .toList(growable: false) ??
        const [],
    titleEnglish: query['titleEnglish'],
    titleRomaji: query['titleRomaji'],
    status: query['status'],
    format: query['format'],
    episodeCount: positiveRouteInt(query['episodeCount']),
    isAdult: query['isAdult'] == '1',
    coverImageUrl: query['cover'],
    startFromBeginning: query['restart'] == '1',
    autoPlay: query['autoplay'] == '1',
  );
}

int? positiveRouteInt(String? value) {
  final parsed = int.tryParse(value ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

PlaybackAudioPreference? _routeAudioPreference(String? value) {
  for (final preference in PlaybackAudioPreference.values) {
    if (preference.name == value) return preference;
  }
  return null;
}

/// Only public debrid HTTPS URLs and live, app-issued proxy capabilities may
/// cross the typed player route. Arbitrary loopback URLs remain invalid even
/// when a caller manages to construct a [PlaybackLaunch].
bool isAllowedTypedPlayerSource(
  String? source, {
  bool Function(Uri uri)? ownsProxyUri,
  bool Function(Uri uri)? ownsDirectTorrentUri,
  bool Function(Uri uri)? ownsDownloadedUri,
}) {
  final uri = Uri.tryParse(source ?? '');
  if (uri == null || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
    return false;
  }
  if (uri.scheme == 'https' && uri.host.isNotEmpty) return true;
  if ((ownsProxyUri ?? WebPlaybackProxy.instance.isOwnedPlaybackProxyUri)(
    uri,
  )) {
    return true;
  }
  if ((ownsDirectTorrentUri ?? DirectTorrentPlaybackRegistry.instance.ownsUri)(
    uri,
  )) {
    return true;
  }
  return (ownsDownloadedUri ?? DownloadedPlaybackRegistry.instance.ownsUri)(
    uri,
  );
}

/// Verifies that `/player` navigation carries the exact typed launch object
/// that produced its URL. A web launch may name a connected debrid service
/// only when it also carries unresolved debrid fallbacks for that service.
bool isValidTypedPlayerLaunch({
  required String? source,
  required DebridService? service,
  required Object? resolved,
}) {
  if (resolved is! PlaybackLaunch || resolved.stream.uri.toString() != source) {
    return false;
  }
  if (!playbackEpisodeIdentityIsCompatible(
    episode: resolved.episode,
    stream: resolved.stream,
    release: resolved.selectedRelease,
  )) {
    return false;
  }
  if (resolved.stream.debridService != null) {
    return resolved.stream.debridService == service;
  }
  if (resolved.stream.isDirectTorrent) {
    return service == null &&
        resolved.stream.playbackLease is DirectTorrentPlaybackLease &&
        resolved.stream.providerId == 'direct-torrent';
  }
  if (resolved.stream.isDownloaded) {
    return service == null &&
        resolved.stream.providerId == 'offline-download' &&
        resolved.stream.headers.isEmpty &&
        resolved.stream.playbackLease == null;
  }
  return resolved.stream.isWebStream &&
      resolved.stream.providerId?.isNotEmpty == true &&
      (service == null || resolved.alternatives.isNotEmpty);
}

class _InvalidRouteScreen extends StatelessWidget {
  const _InvalidRouteScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link_off_rounded, size: 56),
                const SizedBox(height: 16),
                Text(
                  'This link is invalid or incomplete.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  autofocus: true,
                  onPressed: () => context.go('/'),
                  icon: const Icon(Icons.home_rounded),
                  label: const Text('Go home'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
