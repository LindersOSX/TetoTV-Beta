// The public constructor uses descriptive injection names while its retained
// dependencies stay private.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/application/filler_episode_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:anime_tv/features/downloads/application/downloaded_episode_source_service.dart';
import 'package:anime_tv/features/local_media/application/library_episode_source_service.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/player/application/filler_episode_navigation.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/debrid_resolver_factory.dart';
import 'package:anime_tv/features/streaming/application/debrid_token_service.dart';
import 'package:anime_tv/features/streaming/application/episode_release_search_cache.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef AnimeDetailsLoader = Future<AnimeSummary> Function(int mediaId);
typedef ReleaseSearchWatcher =
    Stream<ReleaseSearchProgress> Function(EpisodeReference episode);
typedef WebSearchWatcher =
    Stream<WebStreamSearchProgress> Function(EpisodeReference episode);
typedef DebridTokenReader = Future<String?> Function(DebridService service);
typedef DeviceProfileReader = Future<TvDeviceProfile> Function();
typedef PlaybackFailureCountsReader =
    Future<Map<String, int>> Function(String deviceKey);
typedef LibraryNextEpisodePreparer =
    Future<LibraryPlaybackRequest?> Function({
      required EpisodeReference episode,
      required LibraryEpisodeOrigin? preferredOrigin,
      required String preferredSubtitleLanguage,
      required PlaybackAudioPreference? requestedAudio,
    });
typedef DownloadedNextEpisodePreparer =
    Future<PlaybackLaunch?> Function({
      required EpisodeReference episode,
      required PlaybackAudioPreference? requestedAudio,
    });
typedef NextEpisodeDebridResolverFactory =
    StreamResolver Function({
      required DebridService service,
      required String token,
      required ReleaseSource source,
    });

final nextEpisodePreparationControllerProvider =
    Provider<NextEpisodePreparationController>((ref) {
      final libraryService = ref.watch(libraryEpisodeSourceServiceProvider);
      final downloadedEpisodes = ref.watch(
        downloadedEpisodeSourceServiceProvider,
      );
      final controller = NextEpisodePreparationController(
        loadDetails: (mediaId) =>
            ref.read(animeDetailsProvider(mediaId).future),
        fillerRepository: ref.watch(fillerEpisodeRepositoryProvider),
        releaseSearch: ref.watch(episodeReleaseSearchCacheProvider).watch,
        webSearch: ref
            .watch(webStreamAggregatorProvider)
            .watchSearchIncrementally,
        readDebridToken: ref.watch(debridTokenServiceProvider).accessToken,
        readSettings: () => ref.read(settingsPreferencesProvider),
        readDeviceProfile: AndroidTvBridge.instance.getDeviceProfile,
        readFailureCounts: TetoTvDatabase.instance.failureCounts,
        prepareDownloadedEpisode:
            ({required episode, required requestedAudio}) async {
              final asset = await downloadedEpisodes.completedEpisode(
                episode.anilistMediaId,
                episode.episode,
              );
              return asset == null
                  ? null
                  : downloadedEpisodePlaybackLaunch(
                      asset: asset,
                      episode: episode,
                      requestedAudio: requestedAudio,
                    );
            },
        prepareLibraryEpisode:
            ({
              required episode,
              required preferredOrigin,
              required preferredSubtitleLanguage,
              required requestedAudio,
            }) async {
              await libraryService.loadConnections();
              final result = await libraryService.search(episode);
              final candidates = unambiguousLibraryAutoPickSources(
                sources: result.sources,
                episode: episode,
              ).toList(growable: false);
              if (preferredOrigin != null) {
                candidates.sort((left, right) {
                  final leftPreferred = left.origin == preferredOrigin ? 0 : 1;
                  final rightPreferred = right.origin == preferredOrigin
                      ? 0
                      : 1;
                  final preferred = leftPreferred.compareTo(rightPreferred);
                  if (preferred != 0) return preferred;
                  return left.stableKey.compareTo(right.stableKey);
                });
              }
              for (final source in candidates.take(3)) {
                try {
                  return await libraryService.preparePlayback(
                    source,
                    watchPartyIdentity: LibraryWatchPartyIdentity(
                      anilistMediaId: episode.anilistMediaId,
                      episode: episode.episode,
                      title: episode.title,
                      episodeCount: episode.episodeCount,
                    ),
                    preferredSubtitleLanguage: preferredSubtitleLanguage,
                    requestedAudio: requestedAudio,
                  );
                } catch (_) {
                  // One stale server item cannot block another exact private
                  // source. Private identifiers and errors stay in this
                  // in-memory preparation boundary.
                }
              }
              return null;
            },
      );
      ref.onDispose(() => unawaited(controller.dispose()));
      return controller;
    });

@immutable
class NextEpisodePreparationRequest {
  const NextEpisodePreparationRequest({
    required this.currentLaunch,
    required this.seriesPreferences,
    required this.debridService,
    this.catalogLinkedLibrary = false,
    this.preferredLibraryOrigin,
  });

  /// Builds a neutral request for a catalog-linked private-library episode.
  ///
  /// The placeholder contains only the public [episode] identity. Private
  /// Jellyfin/Plex URLs, provider IDs, release groups, filenames, and headers
  /// cannot enter public source ranking or preparation-slot comparisons.
  factory NextEpisodePreparationRequest.catalogLinkedLibrary({
    required EpisodeReference episode,
    required SeriesPlaybackPreferences seriesPreferences,
    required DebridService debridService,
    LibraryEpisodeOrigin? preferredOrigin,
    PlaybackAudioPreference? requestedAudio,
  }) {
    // Rebuild the identity instead of retaining the player episode object:
    // a library-backed player may use a private artwork URL. Only fields that
    // are safe, immutable catalog identifiers belong in shared prewarm state.
    final publicEpisode = EpisodeReference(
      anilistMediaId: episode.anilistMediaId,
      malMediaId: episode.malMediaId,
      title: episode.title,
      episode: episode.episode,
      episodeCount: episode.episodeCount,
    );
    return NextEpisodePreparationRequest(
      currentLaunch: PlaybackLaunch(
        stream: StreamReady(
          uri: Uri.https('catalog.invalid', '/tetotv/episode'),
          displayName: 'Catalog episode',
        ),
        episode: publicEpisode,
        selectedRelease: const ReleaseCandidate(
          infoHash: 'catalog-public-identity',
          magnetUri: '',
          releaseName: 'Catalog episode',
          seeders: 0,
          sourceId: 'catalog',
        ),
        requestedAudio: requestedAudio,
      ),
      seriesPreferences: seriesPreferences,
      debridService: debridService,
      catalogLinkedLibrary: true,
      preferredLibraryOrigin: preferredOrigin,
    );
  }

  final PlaybackLaunch currentLaunch;
  final SeriesPlaybackPreferences seriesPreferences;
  final DebridService debridService;
  final bool catalogLinkedLibrary;
  final LibraryEpisodeOrigin? preferredLibraryOrigin;

  int get mediaId => currentLaunch.episode.anilistMediaId;
  int get currentEpisode => currentLaunch.episode.episode;
}

@immutable
class PreparedNextEpisode {
  const PreparedNextEpisode({
    required this.launch,
    required this.fillerDecision,
    required this.fallbackDebridService,
    required this.preparedAt,
    this.privateLibraryRequest,
  });

  final PlaybackLaunch launch;
  final FillerEpisodeNavigationDecision fillerDecision;
  final DebridService fallbackDebridService;
  final DateTime preparedAt;
  final LibraryPlaybackRequest? privateLibraryRequest;

  bool get isPrivateLibrary => privateLibraryRequest != null;

  /// Final in-memory check used immediately before the current player gives
  /// up its engine. Private-library placeholders have no public filename and
  /// therefore remain compatible/unknown until their typed handoff adopts
  /// the already matched library request.
  bool get hasCompatibleEpisodeIdentity => playbackEpisodeIdentityIsCompatible(
    episode: launch.episode,
    stream: launch.stream,
    release: launch.selectedRelease,
  );

  Future<void> close() async {
    final privateLease = privateLibraryRequest?.playbackLease;
    final launchLease = launch.stream.playbackLease;
    if (privateLease != null) await privateLease.close();
    if (launchLease != null && !identical(launchLease, privateLease)) {
      await launchLease.close();
    }
  }
}

enum NextEpisodePreparationTerminalReason {
  noNextEpisode,
  noPlayableNonFillerEpisode,
}

@immutable
class NextEpisodePreparationOutcome {
  const NextEpisodePreparationOutcome({this.prepared, this.terminalReason});

  final PreparedNextEpisode? prepared;
  final NextEpisodePreparationTerminalReason? terminalReason;

  bool get isTerminal => terminalReason != null;
}

bool shouldPrepareNextEpisode({
  required Duration position,
  required Duration duration,
}) =>
    duration > Duration.zero &&
    position > Duration.zero &&
    duration - position <= const Duration(minutes: 10);

bool isEpisodeAvailableForPlayback(AnimeSummary details, int episode) {
  if (episode <= 0) return false;
  if (details.episodes case final total? when total > 0 && episode > total) {
    return false;
  }
  if (details.nextAiringEpisode case final nextAiring?
      when episode >= nextAiring) {
    return false;
  }
  return true;
}

String preparedNextEpisodePlayerLocation(
  PreparedNextEpisode prepared, {
  String? watchPartyTargetSourceKey,
}) {
  if (prepared.isPrivateLibrary) {
    throw StateError(
      'Private-library playback must use the typed in-memory player route.',
    );
  }
  final launch = prepared.launch;
  final stream = launch.stream;
  return Uri(
    path: '/player',
    queryParameters: {
      'source': stream.uri.toString(),
      'title': '${launch.episode.title} • Episode ${launch.episode.episode}',
      'anilistId': '${launch.episode.anilistMediaId}',
      if (launch.episode.malMediaId != null)
        'malId': '${launch.episode.malMediaId}',
      'episode': '${launch.episode.episode}',
      if (stream.debridService case final service?) 'debrid': service.slug,
      if (stream.isWebStream && launch.alternatives.isNotEmpty)
        'debrid': prepared.fallbackDebridService.slug,
      'watchPartyTargetSourceKey': ?watchPartyTargetSourceKey,
    },
  ).toString();
}

/// Owns a ready-to-play next episode until the player atomically takes it.
///
/// Discovery starts ten minutes before completion. A successful result holds
/// its debrid URL or proxy lease, so the completion path can replace the
/// player route directly without showing the resolver/loading screen.
class NextEpisodePreparationController {
  NextEpisodePreparationController({
    required AnimeDetailsLoader loadDetails,
    required FillerEpisodeRepository fillerRepository,
    required ReleaseSearchWatcher releaseSearch,
    required WebSearchWatcher webSearch,
    required DebridTokenReader readDebridToken,
    required SettingsPreferences Function() readSettings,
    DeviceProfileReader? readDeviceProfile,
    PlaybackFailureCountsReader? readFailureCounts,
    DownloadedNextEpisodePreparer? prepareDownloadedEpisode,
    LibraryNextEpisodePreparer? prepareLibraryEpisode,
    NextEpisodeDebridResolverFactory resolverFactory =
        createDebridStreamResolver,
    WebStreamPreflight? webPreflight,
    this.discoveryBudget = const Duration(seconds: 60),
    this.resolutionTimeout = const Duration(seconds: 20),
    this.preparedTtl = const Duration(minutes: 30),
    DateTime Function()? clock,
  }) : _loadDetails = loadDetails,
       _fillerRepository = fillerRepository,
       _releaseSearch = releaseSearch,
       _webSearch = webSearch,
       _readDebridToken = readDebridToken,
       _readSettings = readSettings,
       _readDeviceProfile =
           readDeviceProfile ?? (() async => const TvDeviceProfile.unknown()),
       _readFailureCounts = readFailureCounts ?? ((_) async => const {}),
       _prepareDownloadedEpisode = prepareDownloadedEpisode,
       _prepareLibraryEpisode = prepareLibraryEpisode,
       _resolverFactory = resolverFactory,
       _webPreflight = webPreflight ?? const WebStreamValidator().validate,
       _clock = clock ?? DateTime.now;

  final AnimeDetailsLoader _loadDetails;
  final FillerEpisodeRepository _fillerRepository;
  final ReleaseSearchWatcher _releaseSearch;
  final WebSearchWatcher _webSearch;
  final DebridTokenReader _readDebridToken;
  final SettingsPreferences Function() _readSettings;
  final DeviceProfileReader _readDeviceProfile;
  final PlaybackFailureCountsReader _readFailureCounts;
  final DownloadedNextEpisodePreparer? _prepareDownloadedEpisode;
  final LibraryNextEpisodePreparer? _prepareLibraryEpisode;
  final NextEpisodeDebridResolverFactory _resolverFactory;
  final WebStreamPreflight _webPreflight;
  final DateTime Function() _clock;
  final Duration discoveryBudget;
  final Duration resolutionTimeout;
  final Duration preparedTtl;
  final Map<String, _PreparationSlot> _slots = {};
  bool _disposed = false;

  Future<PreparedNextEpisode?> warm(NextEpisodePreparationRequest request) =>
      warmWithOutcome(request).then((outcome) => outcome.prepared);

  Future<NextEpisodePreparationOutcome> warmWithOutcome(
    NextEpisodePreparationRequest request,
  ) {
    if (_disposed) return Future.value(const NextEpisodePreparationOutcome());
    final settings = _readSettings();
    final key = _key(request.mediaId, request.currentEpisode);
    final existing = _slots[key];
    if (existing != null && existing.matches(request, settings)) {
      return existing.future;
    }
    final slot = _PreparationSlot(request: request, settings: settings);
    if (existing != null) existing.cancel();
    _slots[key] = slot;
    slot.future =
        (() async {
          // Replacement is serialized per episode. The previous resolver and any
          // debrid account cleanup finish before a changed source/audio request
          // may start another operation.
          if (existing != null) await _closeSlot(existing);
          if (_disposed || slot.cancelled || !identical(_slots[key], slot)) {
            return const NextEpisodePreparationOutcome();
          }
          return _prepare(request, settings, slot);
        })().then<NextEpisodePreparationOutcome>(
          (outcome) async {
            if (_disposed || slot.cancelled || !identical(_slots[key], slot)) {
              await outcome.prepared?.close();
              return const NextEpisodePreparationOutcome();
            }
            final prepared = outcome.prepared;
            if (prepared == null) {
              _slots.remove(key);
              return outcome;
            }
            slot.prepared = prepared;
            slot.expiry = Timer(
              preparedTtl,
              () => unawaited(_discard(key, slot)),
            );
            return outcome;
          },
          onError: (Object error, StackTrace stackTrace) {
            if (identical(_slots[key], slot)) _slots.remove(key);
            slot.cancel();
            Error.throwWithStackTrace(error, stackTrace);
          },
        );
    return slot.future;
  }

  /// Synchronous readiness probe for player progress/resume callbacks. It
  /// prevents a local `_prewarmed` flag from outliving this controller's
  /// lease TTL while keeping ownership inside the controller.
  bool hasReady(NextEpisodePreparationRequest request) {
    if (_disposed) return false;
    final key = _key(request.mediaId, request.currentEpisode);
    final slot = _slots[key];
    if (slot == null || !slot.matches(request, _readSettings())) return false;
    final prepared = slot.prepared;
    if (prepared == null) return false;
    if (_clock().difference(prepared.preparedAt) > preparedTtl) {
      unawaited(_discard(key, slot));
      return false;
    }
    return true;
  }

  /// Takes ownership of a prepared launch. If preparation is nearly complete,
  /// completion may wait briefly rather than showing a resolver route.
  Future<PreparedNextEpisode?> take(
    int mediaId,
    int currentEpisode, {
    required NextEpisodePreparationRequest currentRequest,
    Duration wait = const Duration(seconds: 2),
  }) async {
    final key = _key(mediaId, currentEpisode);
    final slot = _slots[key];
    if (slot == null) return null;
    if (!slot.matches(currentRequest, _readSettings())) {
      await _cancelSlot(key, slot);
      return null;
    }
    PreparedNextEpisode? prepared = slot.prepared;
    if (prepared == null && wait > Duration.zero) {
      try {
        prepared = (await slot.future.timeout(wait)).prepared;
      } catch (_) {
        await _cancelSlot(key, slot);
        return null;
      }
    }
    if (prepared == null || !identical(_slots[key], slot)) return null;
    if (_clock().difference(prepared.preparedAt) > preparedTtl) {
      await _discard(key, slot);
      return null;
    }
    _slots.remove(key);
    slot.expiry?.cancel();
    slot.transferred = true;
    return prepared;
  }

  /// Atomically transfers a locally prepared launch for an exact public
  /// media/episode target.
  ///
  /// This is intentionally identity-only: Watch Together followers learn the
  /// public AniList/episode target from the room, then look for a matching
  /// launch that this device prepared itself. Stream URLs, request headers,
  /// and playback leases never cross the room protocol. A target or settings
  /// mismatch leaves the slot untouched so its owning player can still use or
  /// abandon it.
  Future<PreparedNextEpisode?> takePreparedTarget({
    required int mediaId,
    required int episode,
    Duration wait = const Duration(seconds: 2),
  }) async {
    if (_disposed || mediaId <= 0 || episode <= 0) return null;
    final settings = _readSettings();
    final candidates =
        _slots.entries
            .where(
              (entry) =>
                  entry.value.request.mediaId == mediaId &&
                  entry.value.request.currentEpisode < episode &&
                  entry.value.matchesSettings(settings),
            )
            .toList(growable: false)
          ..sort(
            (left, right) => right.value.request.currentEpisode.compareTo(
              left.value.request.currentEpisode,
            ),
          );
    if (candidates.isEmpty) return null;

    final waitBudget = wait.isNegative ? Duration.zero : wait;
    final waitClock = Stopwatch()..start();
    for (final candidate in candidates) {
      final key = candidate.key;
      final slot = candidate.value;
      PreparedNextEpisode? prepared = slot.prepared;
      if (prepared == null) {
        final remaining = waitBudget - waitClock.elapsed;
        if (remaining <= Duration.zero) continue;
        try {
          prepared = (await slot.future.timeout(remaining)).prepared;
        } catch (_) {
          // This observer does not own the slot. A timeout, cancellation, or
          // provider error must not cancel another player's preparation.
          continue;
        }
      }
      if (prepared == null || !identical(_slots[key], slot)) continue;
      // A private request is owned by the catalog-linked library player which
      // prepared it. The app-wide Watch Party follower must resolve its own
      // local source instead of moving a URL/header capability through a
      // public router handoff.
      if (prepared.isPrivateLibrary) continue;
      if (prepared.launch.episode.anilistMediaId != mediaId ||
          prepared.launch.episode.episode != episode) {
        continue;
      }
      if (!slot.matchesSettings(_readSettings())) return null;
      if (_clock().difference(prepared.preparedAt) > preparedTtl) {
        await _discard(key, slot);
        return null;
      }
      _slots.remove(key);
      slot.expiry?.cancel();
      slot.transferred = true;
      return prepared;
    }
    return null;
  }

  /// Cancels preparation owned by a player that is genuinely leaving.
  /// A stale screen cannot cancel a slot that a newer source already replaced.
  Future<void> abandon(
    int mediaId,
    int currentEpisode, {
    required NextEpisodePreparationRequest currentRequest,
  }) async {
    final key = _key(mediaId, currentEpisode);
    final slot = _slots[key];
    if (slot == null || !slot.matchesRequest(currentRequest)) return;
    if (!identical(_slots[key], slot)) return;
    _slots.remove(key);
    slot.cancel();
    await _closeSlot(slot);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final entries = _slots.entries.toList(growable: false);
    for (final entry in entries) {
      entry.value.cancel();
    }
    _slots.clear();
    await Future.wait([for (final entry in entries) _closeSlot(entry.value)]);
  }

  Future<NextEpisodePreparationOutcome> _prepare(
    NextEpisodePreparationRequest request,
    SettingsPreferences settings,
    _PreparationSlot slot,
  ) async {
    final details = await _loadDetails(request.mediaId);
    if (_disposed || slot.cancelled) {
      return const NextEpisodePreparationOutcome();
    }
    final requestedEpisode = request.currentEpisode + 1;
    if (!isEpisodeAvailableForPlayback(details, requestedEpisode)) {
      return const NextEpisodePreparationOutcome(
        terminalReason: NextEpisodePreparationTerminalReason.noNextEpisode,
      );
    }
    final totalEpisodes = episodeNavigationCeiling(
      requestedEpisode: requestedEpisode,
      declaredTotalEpisodes: details.episodes,
      nextAiringEpisode: details.nextAiringEpisode,
    );
    final fillerDecision = await resolveFillerEpisodeNavigation(
      repository: _fillerRepository,
      identity: FillerSeriesIdentity.fromAnime(details),
      requestedEpisode: requestedEpisode,
      totalEpisodes: totalEpisodes,
      skipEnabled: request.seriesPreferences.skipFillerEpisodes,
    );
    final episodeNumber = fillerDecision.episode;
    if (_disposed || slot.cancelled) {
      return const NextEpisodePreparationOutcome();
    }
    if (episodeNumber == null) {
      return const NextEpisodePreparationOutcome(
        terminalReason:
            NextEpisodePreparationTerminalReason.noPlayableNonFillerEpisode,
      );
    }
    if (!isEpisodeAvailableForPlayback(details, episodeNumber)) {
      return const NextEpisodePreparationOutcome(
        terminalReason: NextEpisodePreparationTerminalReason.noNextEpisode,
      );
    }
    final episode = _episodeReference(details, episodeNumber);
    if (settings.offlineDownloadsEnabled && _prepareDownloadedEpisode != null) {
      PlaybackLaunch? downloadedLaunch;
      try {
        downloadedLaunch = await _prepareDownloadedEpisode(
          episode: episode,
          requestedAudio: request.currentLaunch.requestedAudio,
        );
      } catch (_) {
        // A stale completed row or missing file falls through to the normal
        // local-library and network source preparation paths.
      }
      if (_disposed || slot.cancelled) {
        await downloadedLaunch?.stream.playbackLease?.close();
        return const NextEpisodePreparationOutcome();
      }
      if (downloadedLaunch != null) {
        return NextEpisodePreparationOutcome(
          prepared: PreparedNextEpisode(
            launch: downloadedLaunch,
            fillerDecision: fillerDecision,
            fallbackDebridService: request.debridService,
            preparedAt: _clock(),
          ),
        );
      }
    }
    if (request.catalogLinkedLibrary && _prepareLibraryEpisode != null) {
      LibraryPlaybackRequest? privateRequest;
      final privatePreparation = _prepareLibraryEpisode(
        episode: episode,
        preferredOrigin: request.preferredLibraryOrigin,
        preferredSubtitleLanguage: request.seriesPreferences.subtitleLanguage,
        requestedAudio: request.currentLaunch.requestedAudio,
      );
      try {
        privateRequest = await privatePreparation.timeout(resolutionTimeout);
      } on TimeoutException {
        // Future.timeout does not cancel its source future. If the private
        // resolver completes later, close its lease instead of orphaning a
        // credential-bearing proxy session that nobody can adopt.
        unawaited(
          privatePreparation.then<void>((lateRequest) async {
            await lateRequest?.playbackLease?.close();
          }, onError: (_) {}),
        );
      } catch (_) {
        // A private server timeout or stale item is a local fallback signal;
        // it must not enter diagnostics or block ordinary source preparation.
      }
      if (_disposed || slot.cancelled) {
        await privateRequest?.playbackLease?.close();
        return const NextEpisodePreparationOutcome();
      }
      if (privateRequest != null) {
        return NextEpisodePreparationOutcome(
          prepared: PreparedNextEpisode(
            launch: _privateLibraryPlaceholderLaunch(
              episode,
              requestedAudio: request.currentLaunch.requestedAudio,
            ),
            privateLibraryRequest: privateRequest,
            fillerDecision: fillerDecision,
            fallbackDebridService: request.debridService,
            preparedAt: _clock(),
          ),
        );
      }
    }
    final discovery = await _discover(episode, settings, slot);
    if (_disposed || slot.cancelled) {
      return const NextEpisodePreparationOutcome();
    }

    final preferredAudio = preferredAudioPreferenceForRelease(
      release: request.currentLaunch.selectedRelease,
      globalPreference: settings.preferredAudio,
      requestedAudio: request.currentLaunch.requestedAudio,
      seriesAudioLanguage: request.seriesPreferences.audioLanguage,
      seriesOverride: request.seriesPreferences.audioPreferenceSet,
    );
    var device = const TvDeviceProfile.unknown();
    var failureCounts = const <String, int>{};
    try {
      device = await _readDeviceProfile();
      if (_disposed || slot.cancelled) {
        return const NextEpisodePreparationOutcome();
      }
      failureCounts = await _readFailureCounts(device.key);
    } catch (_) {
      // Compatibility history is an ordering hint and never blocks playback.
    }
    if (_disposed || slot.cancelled) {
      return const NextEpisodePreparationOutcome();
    }
    final rankedReleases = _rankReleases(
      discovery.releases,
      current: request.currentLaunch.selectedRelease,
      settings: settings,
      seriesPreferences: request.seriesPreferences,
      preferredAudio: preferredAudio,
      device: device,
      failureCounts: failureCounts,
    );
    final rankedWebStreams = _rankWebStreams(
      discovery.webStreams,
      current: request.currentLaunch,
      settings: settings,
      seriesPreferences: request.seriesPreferences,
      preferredAudio: preferredAudio,
    );
    final releases = rankedReleases;
    final webStreams = rankedWebStreams;
    final currentIsWeb = request.currentLaunch.stream.isWebStream;
    final debridService = currentIsWeb
        ? settings.debridProvider
        : request.debridService;

    if (settings.autoPickSourceEnabled) {
      final audioReleases = releases
          .where((release) => _releaseMatchesAutoPickAudio(release, settings))
          .toList(growable: false);
      final audioWebStreams = webStreams
          .where((stream) => _webStreamMatchesAutoPickAudio(stream, settings))
          .toList(growable: false);
      final attemptBudget = _AutoPickPreparationBudget(
        maxAttempts: 8,
        deadline: _clock().add(const Duration(seconds: 45)),
        clock: _clock,
      );

      for (final quality in settings.effectiveAutoPickQualityPriority) {
        final targetHeight = quality.targetHeight;
        if (targetHeight == null) continue;
        final qualityReleases = audioReleases
            .where((release) => releaseQualityHeight(release) == targetHeight)
            .toList(growable: false);
        final qualityWebStreams = audioWebStreams
            .where((stream) => webStreamQualityHeight(stream) == targetHeight)
            .toList(growable: false);

        for (final source in settings.effectiveAutoPickSourcePriority) {
          if (attemptBudget.exhausted) {
            return const NextEpisodePreparationOutcome();
          }
          final launch = switch (source) {
            AutoPickSourcePriority.debrid => await _prepareDebrid(
              episode: episode,
              service: debridService,
              candidates: qualityReleases,
              allReleaseCandidates: qualityReleases,
              webAlternatives: qualityWebStreams,
              requestedAudio: request.currentLaunch.requestedAudio,
              slot: slot,
              attemptBudget: attemptBudget,
            ),
            AutoPickSourcePriority.web => await _prepareWeb(
              episode: episode,
              candidates: qualityWebStreams,
              releaseAlternatives: qualityReleases,
              allWebCandidates: qualityWebStreams,
              requestedAudio: request.currentLaunch.requestedAudio,
              slot: slot,
              attemptBudget: attemptBudget,
            ),
            // Private-library playback uses a LibraryPlaybackRequest rather
            // than a network PlaybackLaunch. The episode resolver performs
            // the same exact-match verification before it auto-opens media.
            AutoPickSourcePriority.yourMedia => null,
          };
          if (launch != null) {
            return NextEpisodePreparationOutcome(
              prepared: PreparedNextEpisode(
                launch: launch,
                fillerDecision: fillerDecision,
                fallbackDebridService: debridService,
                preparedAt: _clock(),
              ),
            );
          }
          if (_disposed || slot.cancelled) {
            return const NextEpisodePreparationOutcome();
          }
        }
      }
      return const NextEpisodePreparationOutcome();
    }

    bool strictRelease(ReleaseCandidate release) =>
        automaticReleaseMatchesFilters(
          release,
          language: preferredAudio.name,
          quality: request.seriesPreferences.preferredQuality,
          codec: request.seriesPreferences.preferredCodec,
          hdr: request.seriesPreferences.preferredHdrMode,
          allowBatch: request.seriesPreferences.allowBatchStreams,
        );
    bool strictWeb(WebStreamResult stream) => automaticWebStreamMatchesFilters(
      stream,
      language: preferredAudio.name,
      quality: request.seriesPreferences.preferredQuality,
    );
    final strictReleases = releases
        .where(strictRelease)
        .toList(growable: false);
    final fallbackReleases = releases
        .where((release) => !strictRelease(release))
        .toList(growable: false);
    final strictWebStreams = webStreams
        .where(strictWeb)
        .toList(growable: false);
    final fallbackWebStreams = webStreams
        .where((stream) => !strictWeb(stream))
        .toList(growable: false);

    final preferredQualityHeight = releaseQualityHeight(
      request.currentLaunch.selectedRelease,
    );
    List<({List<ReleaseCandidate> releases, List<WebStreamResult> webStreams})>
    qualityPools(
      List<ReleaseCandidate> tierReleases,
      List<WebStreamResult> tierWebStreams,
    ) {
      if (preferredQualityHeight <= 0) {
        return [(releases: tierReleases, webStreams: tierWebStreams)];
      }
      final minimumSafety = tierReleases.isEmpty
          ? 0
          : tierReleases
                .map(
                  (release) => automaticPlaybackSafetyScore(
                    release,
                    device: device,
                    previousFailures:
                        failureCounts[release.infoHash.toLowerCase()] ?? 0,
                  ),
                )
                .reduce((left, right) => left < right ? left : right);
      final preferredReleaseHashes = <String>{
        for (final release in tierReleases)
          if (releaseQualityHeight(release) == preferredQualityHeight &&
              automaticPlaybackSafetyScore(
                    release,
                    device: device,
                    previousFailures:
                        failureCounts[release.infoHash.toLowerCase()] ?? 0,
                  ) ==
                  minimumSafety)
            release.infoHash.toLowerCase(),
      };
      final preferredWebKeys = <String>{
        for (final stream in tierWebStreams)
          if (webStreamQualityHeight(stream) == preferredQualityHeight)
            '${stream.providerId}\u0000${stream.uri}',
      };
      if (preferredReleaseHashes.isEmpty && preferredWebKeys.isEmpty) {
        return [(releases: tierReleases, webStreams: tierWebStreams)];
      }
      return [
        (
          releases: tierReleases
              .where(
                (release) => preferredReleaseHashes.contains(
                  release.infoHash.toLowerCase(),
                ),
              )
              .toList(growable: false),
          webStreams: tierWebStreams
              .where(
                (stream) => preferredWebKeys.contains(
                  '${stream.providerId}\u0000${stream.uri}',
                ),
              )
              .toList(growable: false),
        ),
        (
          releases: tierReleases
              .where(
                (release) => !preferredReleaseHashes.contains(
                  release.infoHash.toLowerCase(),
                ),
              )
              .toList(growable: false),
          webStreams: tierWebStreams
              .where(
                (stream) => !preferredWebKeys.contains(
                  '${stream.providerId}\u0000${stream.uri}',
                ),
              )
              .toList(growable: false),
        ),
      ];
    }

    // Strict series filters and device safety lead. Within each filter tier,
    // keep the current normalized quality first, then fail open to every other
    // quality. Provider/source and source-class affinity are applied inside
    // those pools and can never make an unsafe release win.
    for (final pool in [
      ...qualityPools(strictReleases, strictWebStreams),
      ...qualityPools(fallbackReleases, fallbackWebStreams),
    ]) {
      if (pool.releases.isEmpty && pool.webStreams.isEmpty) continue;
      final launch = await _prepareCandidatePool(
        episode: episode,
        debridService: debridService,
        currentLaunch: request.currentLaunch,
        releases: pool.releases,
        webStreams: pool.webStreams,
        allReleases: releases,
        allWebStreams: webStreams,
        preferredAudio: preferredAudio,
        sourcePriority: settings.streamSourcePriority,
        device: device,
        failureCounts: failureCounts,
        slot: slot,
      );
      if (launch != null) {
        return NextEpisodePreparationOutcome(
          prepared: PreparedNextEpisode(
            launch: launch,
            fillerDecision: fillerDecision,
            fallbackDebridService: debridService,
            preparedAt: _clock(),
          ),
        );
      }
      if (_disposed || slot.cancelled) {
        return const NextEpisodePreparationOutcome();
      }
    }
    return const NextEpisodePreparationOutcome();
  }

  Future<PlaybackLaunch?> _prepareCandidatePool({
    required EpisodeReference episode,
    required DebridService debridService,
    required PlaybackLaunch currentLaunch,
    required List<ReleaseCandidate> releases,
    required List<WebStreamResult> webStreams,
    required List<ReleaseCandidate> allReleases,
    required List<WebStreamResult> allWebStreams,
    required PlaybackAudioPreference preferredAudio,
    required StreamSourcePriority sourcePriority,
    required TvDeviceProfile device,
    required Map<String, int> failureCounts,
    required _PreparationSlot slot,
  }) async {
    final currentIsWeb = currentLaunch.stream.isWebStream;
    final currentWebProvider = currentLaunch.stream.providerId
        ?.trim()
        .toLowerCase();
    final exactWeb = currentIsWeb && currentWebProvider?.isNotEmpty == true
        ? webStreams
              .where(
                (stream) =>
                    stream.providerId.trim().toLowerCase() ==
                        currentWebProvider &&
                    webStreamAudioPreferenceRank(stream, preferredAudio) == 0,
              )
              .take(1)
              .toList(growable: false)
        : const <WebStreamResult>[];
    final minimumDebridSafety = releases.isEmpty
        ? 0
        : releases
              .map(
                (candidate) => automaticPlaybackSafetyScore(
                  candidate,
                  device: device,
                  previousFailures:
                      failureCounts[candidate.infoHash.toLowerCase()] ?? 0,
                ),
              )
              .reduce((left, right) => left < right ? left : right);
    final exactDebrid = !currentIsWeb
        ? releases
              .where(
                (candidate) =>
                    _releaseAffinity(candidate, currentLaunch.selectedRelease) <
                        2 &&
                    automaticPlaybackSafetyScore(
                          candidate,
                          device: device,
                          previousFailures:
                              failureCounts[candidate.infoHash.toLowerCase()] ??
                              0,
                        ) ==
                        minimumDebridSafety &&
                    releaseAudioPreferenceRank(candidate, preferredAudio) == 0,
              )
              .take(1)
              .toList(growable: false)
        : const <ReleaseCandidate>[];

    PlaybackLaunch? exactLaunch;
    if (exactWeb.isNotEmpty) {
      exactLaunch = await _prepareWeb(
        episode: episode,
        candidates: exactWeb,
        releaseAlternatives: allReleases,
        allWebCandidates: allWebStreams,
        requestedAudio: currentLaunch.requestedAudio,
        slot: slot,
      );
    } else if (exactDebrid.isNotEmpty) {
      exactLaunch = await _prepareDebrid(
        episode: episode,
        service: debridService,
        candidates: exactDebrid,
        allReleaseCandidates: allReleases,
        webAlternatives: allWebStreams,
        requestedAudio: currentLaunch.requestedAudio,
        slot: slot,
      );
    }
    if (exactLaunch != null || _disposed || slot.cancelled) return exactLaunch;

    final remainingReleases = releases
        .where(
          (candidate) => !exactDebrid.any(
            (exact) =>
                exact.infoHash.toLowerCase() ==
                candidate.infoHash.toLowerCase(),
          ),
        )
        .toList(growable: false);
    final remainingWebStreams = webStreams
        .where(
          (stream) => !exactWeb.any(
            (exact) =>
                exact.providerId == stream.providerId &&
                exact.uri == stream.uri,
          ),
        )
        .toList(growable: false);
    final classes =
        <StreamSourceClass>[
          if (remainingReleases.isNotEmpty) StreamSourceClass.debrid,
          if (remainingWebStreams.isNotEmpty) StreamSourceClass.web,
        ]..sort((left, right) {
          int audioRank(StreamSourceClass sourceClass) => switch (sourceClass) {
            StreamSourceClass.debrid => releaseAudioPreferenceRank(
              remainingReleases.first,
              preferredAudio,
            ),
            StreamSourceClass.web => webStreamAudioPreferenceRank(
              remainingWebStreams.first,
              preferredAudio,
            ),
          };
          return compareStreamSourceClasses(
            left,
            right,
            sourcePriority,
            leftAudioRank: audioRank(left),
            rightAudioRank: audioRank(right),
          );
        });

    for (final sourceClass in classes) {
      final launch = switch (sourceClass) {
        StreamSourceClass.debrid => await _prepareDebrid(
          episode: episode,
          service: debridService,
          candidates: remainingReleases,
          allReleaseCandidates: allReleases,
          webAlternatives: allWebStreams,
          requestedAudio: currentLaunch.requestedAudio,
          slot: slot,
        ),
        StreamSourceClass.web => await _prepareWeb(
          episode: episode,
          candidates: remainingWebStreams,
          releaseAlternatives: allReleases,
          allWebCandidates: allWebStreams,
          requestedAudio: currentLaunch.requestedAudio,
          slot: slot,
        ),
      };
      if (launch != null || _disposed || slot.cancelled) return launch;
    }
    return null;
  }

  Future<_DiscoverySnapshot> _discover(
    EpisodeReference episode,
    SettingsPreferences settings,
    _PreparationSlot slot,
  ) async {
    var releases = const <ReleaseCandidate>[];
    var webStreams = const <WebStreamResult>[];
    final completions = <Future<void>>[];
    final cancelers = <Future<void> Function()>[];

    if (settings.debridStreamsEnabled) {
      final done = Completer<void>();
      late final StreamSubscription<ReleaseSearchProgress> subscription;
      subscription = _releaseSearch(episode).listen(
        (progress) {
          releases = List<ReleaseCandidate>.unmodifiable(progress.candidates);
          if (progress.isComplete && !done.isCompleted) {
            done.complete();
          }
        },
        onError: (_, _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      cancelers.add(subscription.cancel);
      completions.add(done.future);
    }
    if (settings.webStreamsEnabled) {
      final done = Completer<void>();
      late final StreamSubscription<WebStreamSearchProgress> subscription;
      subscription = _webSearch(episode).listen(
        (progress) {
          webStreams = List<WebStreamResult>.unmodifiable(
            progress.aggregation.streams,
          );
          if (progress.isComplete && !done.isCompleted) done.complete();
        },
        onError: (_, _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      cancelers.add(subscription.cancel);
      completions.add(done.future);
    }
    if (completions.isNotEmpty) {
      await Future.any([
        Future.wait(completions),
        Future<void>.delayed(discoveryBudget),
        slot.cancelledFuture,
      ]);
    }
    await Future.wait([for (final cancel in cancelers) cancel()]);
    return _DiscoverySnapshot(releases: releases, webStreams: webStreams);
  }

  Future<PlaybackLaunch?> _prepareDebrid({
    required EpisodeReference episode,
    required DebridService service,
    required List<ReleaseCandidate> candidates,
    required List<ReleaseCandidate> allReleaseCandidates,
    required List<WebStreamResult> webAlternatives,
    required PlaybackAudioPreference? requestedAudio,
    required _PreparationSlot slot,
    _AutoPickPreparationBudget? attemptBudget,
  }) async {
    if (candidates.isEmpty) return null;
    String? token;
    try {
      token = await _readDebridToken(service);
    } catch (_) {
      return null;
    }
    if (token == null || token.isEmpty || _disposed || slot.cancelled) {
      return null;
    }
    for (var index = 0; index < candidates.length && index < 8; index++) {
      if (attemptBudget != null && !attemptBudget.beginAttempt()) break;
      final selected = candidates[index];
      StreamReady? ready;
      try {
        final resolver = _resolverFactory(
          service: service,
          token: token,
          source: SingleReleaseSource(selected),
        );
        ready = await _firstReady(
          resolver.resolve(episode).timeout(resolutionTimeout),
          slot,
        );
        if (_disposed || slot.cancelled) {
          await ready?.playbackLease?.close();
          return null;
        }
        if (ready == null) continue;
        verifyPlaybackEpisodeIdentity(
          episode: episode,
          stream: ready,
          release: selected,
        );
        return PlaybackLaunch(
          stream: ready,
          episode: episode,
          selectedRelease: selected,
          requestedAudio: requestedAudio,
          alternatives: allReleaseCandidates
              .where((candidate) => candidate.infoHash != selected.infoHash)
              .toList(growable: false),
          directAlternatives: webAlternatives
              .map(_optionForWebStream)
              .toList(growable: false),
        );
      } on EpisodeIdentityMismatchException {
        await ready?.playbackLease?.close();
        continue;
      } catch (error) {
        if (isTerminalDebridFailoverFailure(error)) return null;
      }
    }
    return null;
  }

  Future<PlaybackLaunch?> _prepareWeb({
    required EpisodeReference episode,
    required List<WebStreamResult> candidates,
    required List<ReleaseCandidate> releaseAlternatives,
    required List<WebStreamResult> allWebCandidates,
    required PlaybackAudioPreference? requestedAudio,
    required _PreparationSlot slot,
    _AutoPickPreparationBudget? attemptBudget,
  }) async {
    for (var index = 0; index < candidates.length && index < 8; index++) {
      if (attemptBudget != null && !attemptBudget.beginAttempt()) break;
      final candidate = candidates[index];
      ValidatedWebStream? validated;
      try {
        validated = await _webPreflight(
          candidate.uri,
          candidate.headers,
          subtitleUri: candidate.subtitleUri,
        );
        if (_disposed || slot.cancelled) {
          await validated.session?.close();
          return null;
        }
        final release = _releaseForWebStream(candidate);
        final ready = StreamReady(
          uri: validated.uri,
          displayName: release.releaseName,
          headers: validated.headers,
          externalSubtitle: validated.subtitleUri,
          mediaContentType: validated.contentType,
          subtitleContentType: validated.subtitleContentType,
          externalSubtitleRejected: validated.subtitleRejected,
          playbackLease: validated.session,
          providerId: candidate.providerId,
          providerName: '${candidate.providerName} web stream',
          providerEpisodeIdentity: ProviderEpisodeIdentity.fromFields(
            episodeNumber: candidate.matchedEpisodeNumber,
            seasonNumber: candidate.matchedSeasonNumber,
            seriesTitle: candidate.matchedSeriesTitle,
          ),
        );
        verifyPlaybackEpisodeIdentity(
          episode: episode,
          stream: ready,
          release: release,
        );
        return PlaybackLaunch(
          stream: ready,
          episode: episode,
          selectedRelease: release,
          requestedAudio: requestedAudio,
          alternatives: releaseAlternatives,
          directAlternatives: allWebCandidates
              .where((stream) => stream.uri != candidate.uri)
              .map(_optionForWebStream)
              .toList(growable: false),
        );
      } catch (_) {
        await validated?.session?.close();
      }
    }
    return null;
  }

  Future<void> _discard(String key, _PreparationSlot slot) async {
    if (!identical(_slots[key], slot)) return;
    _slots.remove(key);
    slot.cancel();
    await _closeSlot(slot);
  }

  Future<void> _cancelSlot(String key, _PreparationSlot slot) async {
    if (!identical(_slots[key], slot)) return;
    _slots.remove(key);
    slot.cancel();
    try {
      await _closeSlot(slot).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Cleanup retains ownership and continues in the background, but a
      // broken third-party cancellation hook cannot trap the TV UI forever.
    }
  }

  Future<void> _closeSlot(_PreparationSlot slot) async {
    slot.expiry?.cancel();
    if (slot.transferred) return;
    final prepared = slot.prepared;
    if (prepared != null) {
      await prepared.close();
      return;
    }
    try {
      final late = (await slot.future).prepared;
      if (!slot.transferred) await late?.close();
    } catch (_) {}
  }
}

PlaybackLaunch _privateLibraryPlaceholderLaunch(
  EpisodeReference episode, {
  PlaybackAudioPreference? requestedAudio,
}) => PlaybackLaunch(
  stream: StreamReady(
    uri: Uri.https('catalog.invalid', '/tetotv/private-library-prewarm'),
    displayName: 'Prepared private-library episode',
    providerId: 'library-catalog',
    providerName: 'Local library',
  ),
  episode: episode,
  selectedRelease: ReleaseCandidate(
    infoHash: 'catalog-library-${episode.anilistMediaId}-${episode.episode}',
    magnetUri: '',
    releaseName: 'Prepared private-library episode',
    seeders: 0,
    sourceId: 'library-catalog',
    provider: 'Local library',
  ),
  requestedAudio: requestedAudio,
);

bool _releaseMatchesAutoPickAudio(
  ReleaseCandidate release,
  SettingsPreferences settings,
) {
  return switch (settings.autoPickAudio) {
    AutoPickAudio.any => true,
    AutoPickAudio.dubOnly => releaseSupportsAudioPreference(
      release,
      PlaybackAudioPreference.dub,
    ),
    AutoPickAudio.subOnly => releaseSupportsAudioPreference(
      release,
      PlaybackAudioPreference.sub,
    ),
  };
}

bool _webStreamMatchesAutoPickAudio(
  WebStreamResult stream,
  SettingsPreferences settings,
) {
  return switch (settings.autoPickAudio) {
    AutoPickAudio.any => true,
    AutoPickAudio.dubOnly => stream.supportsDubAudio,
    AutoPickAudio.subOnly => stream.supportsSubAudio,
  };
}

class _AutoPickPreparationBudget {
  _AutoPickPreparationBudget({
    required this.maxAttempts,
    required this.deadline,
    required DateTime Function() clock,
  }) : _clock = clock;

  final int maxAttempts;
  final DateTime deadline;
  final DateTime Function() _clock;
  int _attempts = 0;

  bool get exhausted =>
      _attempts >= maxAttempts || !_clock().isBefore(deadline);

  bool beginAttempt() {
    if (exhausted) return false;
    _attempts++;
    return true;
  }
}

class _PreparationSlot {
  _PreparationSlot({required this.request, required this.settings});

  final NextEpisodePreparationRequest request;
  final SettingsPreferences settings;
  late final Future<NextEpisodePreparationOutcome> future;
  final Completer<void> _cancelled = Completer<void>();
  PreparedNextEpisode? prepared;
  Timer? expiry;
  bool transferred = false;

  bool get cancelled => _cancelled.isCompleted;
  Future<void> get cancelledFuture => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  bool matches(
    NextEpisodePreparationRequest other,
    SettingsPreferences otherSettings,
  ) => matchesRequest(other) && matchesSettings(otherSettings);

  bool matchesSettings(SettingsPreferences otherSettings) =>
      settings.preferredAudio == otherSettings.preferredAudio &&
      settings.debridProvider == otherSettings.debridProvider &&
      settings.debridStreamsEnabled == otherSettings.debridStreamsEnabled &&
      settings.webStreamsEnabled == otherSettings.webStreamsEnabled &&
      settings.debridStreamSort == otherSettings.debridStreamSort &&
      settings.streamSourcePriority == otherSettings.streamSourcePriority &&
      settings.webStreamQuality == otherSettings.webStreamQuality &&
      settings.autoPickSourceEnabled == otherSettings.autoPickSourceEnabled &&
      listEquals(
        settings.effectiveAutoPickSourcePriority,
        otherSettings.effectiveAutoPickSourcePriority,
      ) &&
      listEquals(
        settings.effectiveAutoPickQualityPriority,
        otherSettings.effectiveAutoPickQualityPriority,
      ) &&
      settings.autoPickAudio == otherSettings.autoPickAudio;

  bool matchesRequest(NextEpisodePreparationRequest other) =>
      request.currentLaunch.selectedRelease.infoHash ==
          other.currentLaunch.selectedRelease.infoHash &&
      request.currentLaunch.selectedRelease.sourceId ==
          other.currentLaunch.selectedRelease.sourceId &&
      request.currentLaunch.selectedRelease.provider ==
          other.currentLaunch.selectedRelease.provider &&
      request.currentLaunch.stream.uri == other.currentLaunch.stream.uri &&
      request.currentLaunch.stream.providerId ==
          other.currentLaunch.stream.providerId &&
      request.currentLaunch.requestedAudio ==
          other.currentLaunch.requestedAudio &&
      request.seriesPreferences.audioLanguage ==
          other.seriesPreferences.audioLanguage &&
      request.seriesPreferences.audioPreferenceSet ==
          other.seriesPreferences.audioPreferenceSet &&
      request.seriesPreferences.preferredStreamLanguage ==
          other.seriesPreferences.preferredStreamLanguage &&
      request.seriesPreferences.preferredQuality ==
          other.seriesPreferences.preferredQuality &&
      request.seriesPreferences.preferredCodec ==
          other.seriesPreferences.preferredCodec &&
      request.seriesPreferences.preferredHdrMode ==
          other.seriesPreferences.preferredHdrMode &&
      request.seriesPreferences.allowBatchStreams ==
          other.seriesPreferences.allowBatchStreams &&
      request.seriesPreferences.streamSortMode ==
          other.seriesPreferences.streamSortMode &&
      request.seriesPreferences.preferredReleaseProvider ==
          other.seriesPreferences.preferredReleaseProvider &&
      request.seriesPreferences.preferredReleaseGroup ==
          other.seriesPreferences.preferredReleaseGroup &&
      request.seriesPreferences.skipFillerEpisodes ==
          other.seriesPreferences.skipFillerEpisodes &&
      request.catalogLinkedLibrary == other.catalogLinkedLibrary &&
      request.preferredLibraryOrigin == other.preferredLibraryOrigin &&
      request.debridService == other.debridService;
}

Future<StreamReady?> _firstReady(
  Stream<StreamResolution> stream,
  _PreparationSlot slot,
) async {
  final result = Completer<StreamReady?>();
  late final StreamSubscription<StreamResolution> subscription;
  subscription = stream.listen(
    (state) {
      if (slot.cancelled) {
        if (state is StreamReady) unawaited(state.playbackLease?.close());
        if (!result.isCompleted) result.complete();
        return;
      }
      if (state is StreamReady) {
        if (!result.isCompleted) {
          result.complete(state);
        } else {
          unawaited(state.playbackLease?.close());
        }
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!result.isCompleted) result.completeError(error, stackTrace);
    },
    onDone: () {
      if (!result.isCompleted) result.complete();
    },
  );
  unawaited(
    slot.cancelledFuture.then((_) {
      if (!result.isCompleted) result.complete();
    }),
  );
  try {
    return await result.future;
  } finally {
    await subscription.cancel();
  }
}

class _DiscoverySnapshot {
  const _DiscoverySnapshot({required this.releases, required this.webStreams});

  final List<ReleaseCandidate> releases;
  final List<WebStreamResult> webStreams;
}

String _key(int mediaId, int currentEpisode) => '$mediaId:$currentEpisode';

EpisodeReference _episodeReference(AnimeSummary details, int episode) {
  final alternatives = <String?>{
    details.titleEnglish,
    details.titleRomaji,
    ...details.synonyms,
  }.whereType<String>().toSet()..remove(details.title);
  return EpisodeReference(
    anilistMediaId: details.id,
    malMediaId: details.idMal,
    year: details.seasonYear,
    title: details.title,
    episode: episode,
    alternativeTitles: alternatives.toList(growable: false),
    titleEnglish: details.titleEnglish,
    titleRomaji: details.titleRomaji,
    status: details.status,
    format: details.format,
    episodeCount: details.episodes,
    isAdult: details.isAdult,
    coverImageUrl: details.coverImageUrl,
    autoPlay: true,
  );
}

List<ReleaseCandidate> _rankReleases(
  Iterable<ReleaseCandidate> releases, {
  required ReleaseCandidate current,
  required SettingsPreferences settings,
  required SeriesPlaybackPreferences seriesPreferences,
  required PlaybackAudioPreference preferredAudio,
  required TvDeviceProfile device,
  required Map<String, int> failureCounts,
}) {
  return rankAutomaticAutoplayReleases(
    releases,
    language: preferredAudio.name,
    quality: seriesPreferences.preferredQuality,
    codec: seriesPreferences.preferredCodec,
    hdr: seriesPreferences.preferredHdrMode,
    allowBatch: seriesPreferences.allowBatchStreams,
    preferredAudio: preferredAudio,
    rankingPreference: settings.debridStreamSort,
    device: device,
    failureCounts: failureCounts,
    sortMode: seriesPreferences.streamSortMode,
    preferredProvider: current.provider,
    preferredAuthor: releaseGroupKey(current.releaseName),
    preferredSourceId: current.sourceId,
    existingPreferredProvider: seriesPreferences.preferredReleaseProvider,
    existingPreferredReleaseGroup: seriesPreferences.preferredReleaseGroup,
    preferredQualityHeight: releaseQualityHeight(current),
  );
}

int _releaseAffinity(ReleaseCandidate candidate, ReleaseCandidate current) {
  final candidateProvider = candidate.provider?.trim().toLowerCase();
  final currentProvider = current.provider?.trim().toLowerCase();
  final sameProvider =
      candidateProvider != null &&
      candidateProvider.isNotEmpty &&
      currentProvider != null &&
      currentProvider.isNotEmpty &&
      candidateProvider == currentProvider;
  final candidateSource = candidate.sourceId.trim().toLowerCase();
  final currentSource = current.sourceId.trim().toLowerCase();
  final sameSource =
      candidateSource.isNotEmpty &&
      currentSource.isNotEmpty &&
      candidateSource == currentSource;
  final candidateAuthor = releaseGroupKey(candidate.releaseName);
  final currentAuthor = releaseGroupKey(current.releaseName);
  final sameAuthor =
      candidateAuthor != null &&
      candidateAuthor.isNotEmpty &&
      currentAuthor != null &&
      currentAuthor.isNotEmpty &&
      candidateAuthor == currentAuthor;
  if ((sameProvider || sameSource) && sameAuthor) return 0;
  if (sameProvider || sameSource) return 1;
  if (sameAuthor) return 2;
  return 3;
}

List<WebStreamResult> _rankWebStreams(
  Iterable<WebStreamResult> streams, {
  required PlaybackLaunch current,
  required SettingsPreferences settings,
  required SeriesPlaybackPreferences seriesPreferences,
  required PlaybackAudioPreference preferredAudio,
}) {
  return rankAutomaticAutoplayWebStreams(
    streams,
    language: preferredAudio.name,
    quality: seriesPreferences.preferredQuality,
    preferredAudio: preferredAudio,
    qualityPreference: settings.webStreamQuality,
    preferredWebProviderId: current.stream.providerId,
    preferredQualityHeight: releaseQualityHeight(current.selectedRelease),
  );
}

PlaybackStreamOption _optionForWebStream(WebStreamResult result) {
  final release = _releaseForWebStream(result);
  return PlaybackStreamOption(
    stream: StreamReady(
      uri: result.uri,
      displayName: release.releaseName,
      headers: result.headers,
      externalSubtitle: result.subtitleUri,
      providerId: result.providerId,
      providerName: '${result.providerName} web stream',
      providerEpisodeIdentity: ProviderEpisodeIdentity.fromFields(
        episodeNumber: result.matchedEpisodeNumber,
        seasonNumber: result.matchedSeasonNumber,
        seriesTitle: result.matchedSeriesTitle,
      ),
    ),
    release: release,
  );
}

ReleaseCandidate _releaseForWebStream(WebStreamResult result) =>
    ReleaseCandidate(
      infoHash: watchPartyWebReleaseIdentity(
        providerId: result.providerId,
        uri: result.uri,
      ),
      magnetUri: '',
      releaseName: '${result.providerName} / ${result.title}',
      seeders: 0,
      sourceId: 'web:${result.providerId}',
      quality: result.quality,
      provider: result.providerName,
      isDubbed: result.supportsDubAudio,
      audioIntent: releaseAudioIntentForWebStream(result),
      hasSubtitles: result.subtitleUri != null,
    );
