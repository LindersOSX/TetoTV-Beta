import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/application/filler_episode_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_franchise_context.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:anime_tv/features/catalog/presentation/anime_title_logo_view.dart';
import 'package:anime_tv/features/downloads/application/season_download_controller.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/downloads/presentation/season_download_dialog.dart';
import 'package:anime_tv/features/player/application/filler_episode_navigation.dart';
import 'package:anime_tv/features/player/presentation/filler_skip_notification.dart';
import 'package:anime_tv/features/catalog/presentation/trailer_player_screen.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/episode_discovery_prefetch_controller.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/presentation/catalog_tracking_action.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_public_identity_provider.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

final _fillerLookupForAnimeProvider = FutureProvider.autoDispose
    .family<FillerEpisodeLookup, AnimeSummary>((ref, anime) {
      return ref
          .watch(fillerEpisodeRepositoryProvider)
          .lookup(FillerSeriesIdentity.fromAnime(anime));
    });

int effectiveCompletedEpisodeProgress({
  required int trackedProgress,
  int? localEpisode,
  bool localCompleted = false,
}) {
  final localProgress = localCompleted ? (localEpisode ?? 0) : 0;
  return localProgress > trackedProgress ? localProgress : trackedProgress;
}

class AnimeDetailsScreen extends ConsumerWidget {
  const AnimeDetailsScreen({required this.animeId, super.key});

  final int animeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(animeDetailsProvider(animeId));
    return Scaffold(
      body: details.when(
        loading: () => Center(
          child: CircularProgressIndicator(
            color: context.appPalette.secondaryAccent,
          ),
        ),
        error: (error, _) => _DetailsError(
          message: error.toString(),
          onBack: context.pop,
          onRetry: () => ref.invalidate(animeDetailsProvider(animeId)),
        ),
        data: (anime) => _DetailsContent(anime: anime),
      ),
    );
  }
}

class _DetailsContent extends ConsumerStatefulWidget {
  const _DetailsContent({required this.anime});

  final AnimeSummary anime;

  @override
  ConsumerState<_DetailsContent> createState() => _DetailsContentState();
}

class _DetailsContentState extends ConsumerState<_DetailsContent> {
  static const _episodePrefetchDebounce = Duration(milliseconds: 300);

  int? _selectedEpisode;
  bool _savingSkipFiller = false;
  int? _activePrefetchEpisode;
  int? _lastCompletedPrefetchEpisode;
  int? _requestedPrefetchEpisode;
  bool _initialPrefetchStarted = false;
  bool _initialPrefetchScheduled = false;
  bool _startingWatchParty = false;
  final FocusNode _watchPartyFocusNode = FocusNode(
    debugLabel: 'episode.watch-together',
  );
  final FocusNode _skipFillerFocusNode = FocusNode(
    debugLabel: 'episode.skip-filler',
  );
  final FocusNode _previousEpisodeFocusNode = FocusNode(
    debugLabel: 'episode.previous',
  );
  final FocusNode _nextEpisodeFocusNode = FocusNode(debugLabel: 'episode.next');
  final FocusNode _backFocusNode = FocusNode(debugLabel: 'anime-details.back');
  Timer? _prefetchDebounce;
  EpisodeDiscoveryPrefetchHandle? _activePrefetch;
  Future<void> _prefetchCancellation = Future<void>.value();
  int _prefetchGeneration = 0;

  AnimeSummary get anime => widget.anime;

  @override
  void dispose() {
    _prefetchGeneration++;
    _prefetchDebounce?.cancel();
    _cancelActivePrefetch();
    _watchPartyFocusNode.dispose();
    _skipFillerFocusNode.dispose();
    _previousEpisodeFocusNode.dispose();
    _nextEpisodeFocusNode.dispose();
    _backFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final displayTitle = anime.displayTitle(titlePreference);
    final franchiseContext = animeFranchiseContextLabel(
      anime: anime,
      titlePreference: titlePreference,
    );
    final isUnreleased = animeAiringStatusLabel(anime.status) == 'UNRELEASED';
    final knownEpisodes = (anime.episodes != null && anime.episodes! > 0)
        ? anime.episodes!
        : ((anime.nextAiringEpisode ?? 1) - 1).clamp(1, 999);

    final tracking = ref.watch(trackingHomeProvider).valueOrNull;
    final linkedProgress = ref
        .watch(
          linkedTrackingProgressProvider((
            anilistMediaId: anime.id,
            malMediaId: anime.idMal,
          )),
        )
        .valueOrNull;
    final localPlayback = ref
        .watch(latestPlaybackProvider(anime.id))
        .valueOrNull;
    final seriesPreferences = ref.watch(
      seriesPlaybackPreferencesProvider(anime.id),
    );
    final skipFillerEpisodes =
        seriesPreferences.valueOrNull?.skipFillerEpisodes ?? false;
    final settings = ref.watch(settingsPreferencesProvider);
    final seasonDownload = ref.watch(seasonDownloadControllerProvider);
    ref.listen<SeasonDownloadState>(seasonDownloadControllerProvider, (
      previous,
      next,
    ) {
      if (!settings.offlineDownloadsEnabled ||
          next.mediaId != anime.id ||
          next.eventId == (previous?.eventId ?? 0) ||
          next.phase == SeasonDownloadPhase.idle ||
          next.isRunning) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(next.completionMessage),
          action: _downloadsSnackBarAction(),
        ),
      );
    });
    final watchParty = ref.watch(watchPartyControllerProvider);
    ref
        .read(watchPartyClientProvider)
        .setPublicIdentity(ref.watch(watchPartyPublicIdentityProvider));
    final fillerIndicatorLookup =
        seriesPreferences.hasValue &&
            !skipFillerEpisodes &&
            settings.showFillerIndicators
        ? ref.watch(_fillerLookupForAnimeProvider(anime)).valueOrNull
        : null;
    final canShowFillerIndicators = fillerIndicatorLookup?.canAutoSkip == true;
    final shelfProgress =
        tracking?.progressFor(
          anilistMediaId: anime.id,
          malMediaId: anime.idMal,
        ) ??
        0;
    final trackedProgress =
        linkedProgress != null && linkedProgress > shelfProgress
        ? linkedProgress
        : shelfProgress;
    final progress = effectiveCompletedEpisodeProgress(
      trackedProgress: trackedProgress,
      localEpisode: localPlayback?.episode,
      localCompleted: localPlayback?.completed == true,
    );

    final localResume =
        localPlayback != null &&
        !localPlayback.completed &&
        localPlayback.position > const Duration(seconds: 15) &&
        localPlayback.episode > progress;
    final targetEpisode = (localResume ? localPlayback.episode : (progress + 1))
        .clamp(1, knownEpisodes);
    final guestPartyMedia = watchParty.session?.role == WatchPartyRole.guest
        ? watchParty.snapshot?.media
        : null;
    final guestPartyEpisode = guestPartyMedia?.anilistId == anime.id
        ? guestPartyMedia?.episode
        : null;
    final guestInWatchParty = watchParty.session?.role == WatchPartyRole.guest;
    final selectedEpisode =
        (guestPartyEpisode ?? _selectedEpisode ?? targetEpisode).clamp(
          1,
          knownEpisodes,
        );
    _scheduleEpisodePrefetch(selectedEpisode);
    final onDownloadSeason = !settings.offlineDownloadsEnabled || isUnreleased
        ? null
        : seasonDownload.isRunning
        ? seasonDownload.mediaId == anime.id
              ? () {
                  ref.read(seasonDownloadControllerProvider.notifier).cancel();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Stopped preparing the remaining season downloads.',
                      ),
                    ),
                  );
                }
              : () => context.push('/downloads')
        : () => unawaited(_startSeasonDownload(knownEpisodes));
    final downloadSeasonLabel = seasonDownload.isRunning
        ? seasonDownload.mediaId == anime.id
              ? 'Cancel season download'
              : 'View downloads'
        : 'Download season';
    _EpisodeActions episodeActions({
      required bool autofocusPrimary,
    }) => _EpisodeActions(
      isAvailable: !isUnreleased,
      autofocusPrimary: autofocusPrimary,
      selectedEpisode: selectedEpisode,
      resumeEpisode: targetEpisode,
      totalEpisodes: knownEpisodes,
      hasProgress: progress > 0 || localResume,
      resumePosition: localResume ? localPlayback.position : null,
      resumeIsFiller:
          canShowFillerIndicators &&
          fillerIndicatorLookup!.isConfirmedFiller(targetEpisode),
      selectedIsFiller:
          canShowFillerIndicators &&
          fillerIndicatorLookup!.isConfirmedFiller(selectedEpisode),
      guestInWatchParty: guestInWatchParty,
      onDecrease: !guestInWatchParty && !isUnreleased && selectedEpisode > 1
          ? () => setState(() => _selectedEpisode = selectedEpisode - 1)
          : null,
      onIncrease:
          !guestInWatchParty && !isUnreleased && selectedEpisode < knownEpisodes
          ? () => setState(() => _selectedEpisode = selectedEpisode + 1)
          : null,
      onPlayFromBeginning: isUnreleased || guestInWatchParty
          ? null
          : () => unawaited(
              _openEpisodeWithFillerCheck(
                anime,
                selectedEpisode,
                knownEpisodes,
                restart: true,
              ),
            ),
      onResume: isUnreleased || guestInWatchParty
          ? null
          : () => unawaited(
              _openEpisodeWithFillerCheck(anime, targetEpisode, knownEpisodes),
            ),
      onPlaySelected: isUnreleased || guestInWatchParty
          ? null
          : () => unawaited(
              _openEpisodeWithFillerCheck(
                anime,
                selectedEpisode,
                knownEpisodes,
              ),
            ),
      onManageList: () =>
          manageCatalogTrackingStatus(context: context, ref: ref, anime: anime),
      skipFillerEpisodes: skipFillerEpisodes,
      onToggleSkipFiller:
          !isUnreleased && !_savingSkipFiller && seriesPreferences.hasValue
          ? () => unawaited(_setSkipFillerEpisodes(!skipFillerEpisodes))
          : null,
      watchPartyState: watchParty,
      watchPartyStarting: _startingWatchParty || watchParty.isBusy,
      watchPartyFocusNode: _watchPartyFocusNode,
      skipFillerFocusNode: _skipFillerFocusNode,
      previousEpisodeFocusNode: _previousEpisodeFocusNode,
      nextEpisodeFocusNode: _nextEpisodeFocusNode,
      showWatchPartyAction: settings.showWatchTogether,
      onWatchPartyPressed: watchParty.session?.role == WatchPartyRole.guest
          ? () => unawaited(
              ref.read(watchPartyControllerProvider.notifier).leave(),
            )
          : watchParty.isActive
          ? null
          : !isUnreleased && !_startingWatchParty && !watchParty.isBusy
          ? () => unawaited(_startWatchParty())
          : null,
    );
    final onFranchise = anime.relatedAnime.isEmpty
        ? null
        : () => context.push('/anime/${anime.id}/franchise');
    final onCredits =
        anime.studios.isEmpty && anime.staff.isEmpty && anime.characters.isEmpty
        ? null
        : () => context.push('/anime/${anime.id}/credits');
    final onTrailer = anime.trailer == null
        ? null
        : () => context.push(
            TrailerPlayerScreen.routePath,
            extra: TrailerPlaybackRequest(
              title: anime.displayTitle(titlePreference),
              trailer: anime.trailer!,
            ),
          );
    final hasInformationActions =
        onTrailer != null ||
        onFranchise != null ||
        onCredits != null ||
        onDownloadSeason != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        NetworkArtwork(
          url: anime.bannerImageUrl ?? anime.coverImageUrl,
          cacheWidth: 1000,
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xF5000000), Color(0xB8000000), Color(0xFA000000)],
              stops: [0, .52, 1],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        SafeArea(
          minimum: context.responsiveScreenPadding,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final useCompactLayout =
                  constraints.maxWidth < 700 ||
                  constraints.maxHeight > constraints.maxWidth ||
                  (constraints.maxWidth < 900 && constraints.maxHeight < 520);
              if (useCompactLayout) {
                final portrait = constraints.maxHeight > constraints.maxWidth;
                final posterWidth =
                    (constraints.maxWidth * (portrait ? .24 : .18))
                        .clamp(112.0, portrait ? 320.0 : 168.0)
                        .toDouble();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _DetailsBack(
                          onPressed: context.pop,
                          autofocus: true,
                          focusNode: _backFocusNode,
                        ),
                        const Spacer(),
                        _EpisodeCounterBadge(
                          selectedEpisode: selectedEpisode,
                          totalEpisodes: knownEpisodes,
                          compact: true,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  key: const ValueKey('anime-details-poster'),
                                  width: posterWidth,
                                  height: posterWidth * 1.5,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        NetworkArtwork(
                                          url: anime.coverImageUrl,
                                          cacheWidth: 240,
                                        ),
                                        if (animeAiringStatusLabel(
                                              anime.status,
                                            ) !=
                                            null)
                                          Positioned(
                                            left: 7,
                                            top: 7,
                                            child: PosterAiringStatusBadge(
                                              status: anime.status,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    key: const ValueKey('anime-details-info'),
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      AnimeTitleLogoView(
                                        aniListId: anime.id,
                                        fallbackTitle: displayTitle,
                                        maxWidth: constraints.maxWidth,
                                        maxHeight: 88,
                                        maxTextLines: 4,
                                        logoContextLabel: franchiseContext,
                                        logoContextStyle: TextStyle(
                                          color:
                                              context.appPalette.accentBright,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: .9,
                                        ),
                                        logoContextMaxLines: 1,
                                        textStyle: Theme.of(
                                          context,
                                        ).textTheme.headlineSmall,
                                      ),
                                      if (anime.status case final status?) ...[
                                        const SizedBox(height: 9),
                                        Text(
                                          'Status: ${status.replaceAll('_', ' ')}',
                                          style: TextStyle(
                                            color: context.appPalette.mutedText,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _MetadataRow(anime: anime),
                            const SizedBox(height: 12),
                            _MediaFactsRow(anime: anime),
                            const SizedBox(height: 16),
                            Text(
                              anime.description.isEmpty
                                  ? 'No synopsis is available.'
                                  : anime.description,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 18),
                            episodeActions(autofocusPrimary: false),
                            if (hasInformationActions) ...[
                              const SizedBox(height: 12),
                              _InformationActions(
                                onTrailer: onTrailer,
                                onFranchise: onFranchise,
                                onCredits: onCredits,
                                onDownloadSeason: onDownloadSeason,
                                downloadSeasonLabel: downloadSeasonLabel,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }
              final wide = constraints.maxWidth >= 1500;
              final spacious = constraints.maxWidth >= 1080;
              final columnGap = wide ? 48.0 : (spacious ? 30.0 : 20.0);
              // On a television the poster is the visual anchor for this
              // screen. Deriving it from the canvas height keeps it close to
              // 60% of the visible TV image at both 1080p and smaller 16:9
              // resolutions instead of shrinking it at logical resolutions
              // reported by some TV devices.
              final targetPosterWidth =
                  MediaQuery.sizeOf(context).height * .60 / 1.5;
              final actionWidth = wide
                  ? (constraints.maxWidth * .29).clamp(500.0, 560.0).toDouble()
                  : spacious
                  ? (constraints.maxWidth * .285).clamp(350.0, 390.0).toDouble()
                  : 252.0;
              final minimumInfoWidth = wide
                  ? 440.0
                  : (spacious ? 320.0 : 250.0);
              final minimumPosterWidth = wide
                  ? 340.0
                  : (spacious ? 255.0 : 175.0);
              final maximumPosterWidth =
                  (constraints.maxWidth -
                          actionWidth -
                          (columnGap * 2) -
                          minimumInfoWidth)
                      .clamp(minimumPosterWidth, double.infinity)
                      .toDouble();
              final posterWidth = targetPosterWidth
                  .clamp(minimumPosterWidth, maximumPosterWidth)
                  .toDouble();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _DetailsBack(
                        onPressed: context.pop,
                        autofocus: isUnreleased,
                        focusNode: _backFocusNode,
                      ),
                      const Spacer(),
                      _EpisodeCounterBadge(
                        selectedEpisode: selectedEpisode,
                        totalEpisodes: knownEpisodes,
                        large: wide,
                      ),
                    ],
                  ),
                  SizedBox(height: wide ? 38 : 14),
                  Expanded(
                    child: Center(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            key: const ValueKey('anime-details-poster'),
                            width: posterWidth,
                            child: AspectRatio(
                              aspectRatio: 2 / 3,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: .2),
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(19),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      NetworkArtwork(
                                        url: anime.coverImageUrl,
                                        cacheWidth: wide
                                            ? 680
                                            : (spacious ? 540 : 360),
                                      ),
                                      if (animeAiringStatusLabel(
                                            anime.status,
                                          ) !=
                                          null)
                                        Positioned(
                                          left: wide ? 18 : 9,
                                          top: wide ? 18 : 9,
                                          child: PosterAiringStatusBadge(
                                            status: anime.status,
                                          ),
                                        ),
                                      if (anime.score != null ||
                                          anime.seasonYear != null ||
                                          anime.durationMinutes != null)
                                        Positioned(
                                          left: wide ? 18 : 9,
                                          right: wide ? 18 : 9,
                                          bottom: wide ? 18 : 9,
                                          child: PosterMetadataOverlay(
                                            score: anime.score,
                                            releaseYear: anime.seasonYear,
                                            durationMinutes:
                                                anime.durationMinutes,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: columnGap),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Column(
                                key: const ValueKey('anime-details-info'),
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AnimeTitleLogoView(
                                    aniListId: anime.id,
                                    fallbackTitle: displayTitle,
                                    maxWidth: constraints.maxWidth,
                                    maxHeight: wide
                                        ? 108
                                        : (spacious ? 88 : 72),
                                    logoContextLabel: franchiseContext,
                                    logoContextStyle: TextStyle(
                                      color: context.appPalette.accentBright,
                                      fontSize: wide ? 16 : 13,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1,
                                    ),
                                    logoContextMaxLines: 1,
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .displaySmall
                                        ?.copyWith(
                                          fontSize: wide
                                              ? 58
                                              : (spacious ? 44 : 34),
                                          height: 1,
                                          fontWeight: FontWeight.w900,
                                        ),
                                  ),
                                  SizedBox(height: wide ? 20 : 10),
                                  _MetadataRow(anime: anime),
                                  SizedBox(height: wide ? 18 : 10),
                                  _MediaFactsRow(anime: anime),
                                  SizedBox(height: wide ? 24 : 12),
                                  Text(
                                    anime.description.isEmpty
                                        ? 'No synopsis is available.'
                                        : anime.description,
                                    maxLines: wide ? 8 : (spacious ? 7 : 5),
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(
                                          color: context.appPalette.primaryText,
                                          fontSize: wide ? 18 : 15,
                                          height: 1.48,
                                        ),
                                  ),
                                  if (anime.status case final status?) ...[
                                    SizedBox(height: wide ? 20 : 10),
                                    Text(
                                      'Status:  ${status.replaceAll('_', ' ')}',
                                      style: TextStyle(
                                        color: context.appPalette.accentBright,
                                        fontSize: wide ? 17 : 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                  if (hasInformationActions) ...[
                                    SizedBox(height: wide ? 22 : 6),
                                    _InformationActions(
                                      onTrailer: onTrailer,
                                      onFranchise: onFranchise,
                                      onCredits: onCredits,
                                      onDownloadSeason: onDownloadSeason,
                                      downloadSeasonLabel: downloadSeasonLabel,
                                      large: wide,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          SizedBox(width: columnGap),
                          SizedBox(
                            width: actionWidth,
                            child: episodeActions(autofocusPrimary: true),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _startSeasonDownload(int episodeCount) async {
    final controller = ref.read(seasonDownloadControllerProvider.notifier);
    final directAvailable = await controller.directTorrentAvailable();
    if (!mounted) return;
    final selection = await showSeasonDownloadDialog(
      context,
      directTorrentAvailable: directAvailable,
    );
    if (!mounted || selection == null) return;
    if (selection.sourcePolicy == SeasonDownloadSourcePolicy.directTorrent &&
        !await confirmDirectSeasonDownload(context)) {
      return;
    }
    if (!mounted) return;
    final settings = ref.read(settingsPreferencesProvider);
    final result = await controller.start(
      SeasonDownloadPlan(
        anime: anime,
        episodeCount: episodeCount,
        quality: selection.quality,
        sourcePolicy: selection.sourcePolicy,
        preferredAudio: settings.preferredAudio,
      ),
    );
    if (!mounted) return;
    final message = switch (result) {
      SeasonDownloadStartResult.started =>
        'Season download started. Keep TetoTV open until it finishes.',
      SeasonDownloadStartResult.alreadyRunning =>
        'Another season is already being prepared.',
      SeasonDownloadStartResult.queueBusy =>
        'Finish or cancel current downloads before starting a season.',
      SeasonDownloadStartResult.directUnavailable =>
        'Direct torrent downloads are unavailable on this device.',
      SeasonDownloadStartResult.storageUnavailable =>
        'TetoTV could not save this season request. Check app storage and try again.',
    };
    final snackBar = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: result == SeasonDownloadStartResult.started
            ? const Duration(seconds: 5)
            : const Duration(seconds: 4),
        action: result == SeasonDownloadStartResult.started
            ? _downloadsSnackBarAction()
            : null,
      ),
    );
    if (result == SeasonDownloadStartResult.started) {
      Timer(const Duration(seconds: 5), snackBar.close);
    }
  }

  SnackBarAction? _downloadsSnackBarAction() {
    // A SnackBar is owned by the app-level ScaffoldMessenger and can remain
    // visible after this details route has been removed. Capture the router
    // while this State still has a live context instead of resolving it from
    // that stale context when the delayed action is pressed.
    final router = GoRouter.maybeOf(context);
    if (router == null) return null;
    return SnackBarAction(
      label: 'Downloads',
      onPressed: () => router.push('/downloads'),
    );
  }

  Future<void> _setSkipFillerEpisodes(bool enabled) async {
    if (_savingSkipFiller) return;
    setState(() => _savingSkipFiller = true);
    final preferences = ref
        .read(seriesPlaybackPreferencesProvider(anime.id))
        .valueOrNull;
    final writePreferences = ref.read(seriesPlaybackPreferencesWriterProvider);
    try {
      if (preferences == null) {
        throw StateError('Series preferences are not ready.');
      }
      await writePreferences(
        anime.id,
        preferences.copyWith(skipFillerEpisodes: enabled),
      );
      if (!mounted) return;
      ref.invalidate(seriesPlaybackPreferencesProvider(anime.id));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Skip filler preference could not be saved.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingSkipFiller = false);
    }
  }

  Future<void> _startWatchParty() async {
    final party = ref.read(watchPartyControllerProvider);
    if (_startingWatchParty || party.isActive || party.isBusy) {
      return;
    }
    final restoreFocus = _watchPartyFocusNode.hasFocus;
    setState(() => _startingWatchParty = true);
    ref
        .read(watchPartyClientProvider)
        .setPublicIdentity(ref.read(watchPartyPublicIdentityProvider));
    var created = false;
    try {
      created = await ref.read(watchPartyControllerProvider.notifier).create();
    } finally {
      if (mounted) {
        setState(() => _startingWatchParty = false);
        if (created && restoreFocus) {
          _restoreFocusAfterWatchPartyCreation();
        }
      }
    }
  }

  void _restoreFocusAfterWatchPartyCreation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final node in <FocusNode>[
        _nextEpisodeFocusNode,
        _previousEpisodeFocusNode,
        _skipFillerFocusNode,
        _backFocusNode,
      ]) {
        final nodeContext = node.context;
        if (node.canRequestFocus &&
            nodeContext != null &&
            nodeContext.mounted) {
          node.requestFocus();
          Scrollable.ensureVisible(
            nodeContext,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
          );
          return;
        }
      }
    });
  }

  void _scheduleEpisodePrefetch(int episode) {
    if (_requestedPrefetchEpisode == episode) return;
    _requestedPrefetchEpisode = episode;
    _prefetchGeneration++;
    _cancelActivePrefetch();
    _prefetchDebounce?.cancel();
    _prefetchDebounce = null;
    if (_lastCompletedPrefetchEpisode == episode) return;

    // Warm the initially selected episode as soon as details render. Later
    // episode changes are debounced so holding a remote button only searches
    // for the episode where the user stops.
    if (!_initialPrefetchStarted) {
      if (_initialPrefetchScheduled) return;
      _initialPrefetchScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initialPrefetchScheduled = false;
        if (!mounted) return;
        final requestedEpisode = _requestedPrefetchEpisode;
        if (requestedEpisode == null) return;
        _startEpisodePrefetch(requestedEpisode);
      });
      return;
    }

    _prefetchDebounce = Timer(_episodePrefetchDebounce, () {
      _prefetchDebounce = null;
      if (!mounted || _requestedPrefetchEpisode != episode) return;
      _startEpisodePrefetch(episode);
    });
  }

  void _startEpisodePrefetch(int episode) {
    if (!mounted ||
        _activePrefetchEpisode == episode ||
        _lastCompletedPrefetchEpisode == episode) {
      return;
    }
    _initialPrefetchStarted = true;
    _activePrefetchEpisode = episode;
    final generation = _prefetchGeneration;
    final cancellation = _prefetchCancellation;
    unawaited(
      _startEpisodePrefetchAfterCancellation(
        anime,
        episode,
        generation,
        cancellation,
      ),
    );
  }

  Future<void> _startEpisodePrefetchAfterCancellation(
    AnimeSummary anime,
    int episode,
    int generation,
    Future<void> cancellation,
  ) async {
    await cancellation;
    if (!mounted ||
        generation != _prefetchGeneration ||
        _requestedPrefetchEpisode != episode) {
      return;
    }
    await _prefetchEpisode(anime, episode, generation);
    if (mounted &&
        generation == _prefetchGeneration &&
        _activePrefetch == null &&
        _activePrefetchEpisode == episode) {
      _activePrefetchEpisode = null;
    }
  }

  void _cancelActivePrefetch() {
    final handle = _activePrefetch;
    _activePrefetch = null;
    _activePrefetchEpisode = null;
    if (handle == null) return;
    final previousCancellation = _prefetchCancellation;
    _prefetchCancellation = () async {
      await previousCancellation;
      try {
        await handle.cancel();
      } catch (_) {
        // Discovery warming is fail-open and cancellation must not block the
        // latest episode from starting.
      }
    }();
  }

  Future<void> _prefetchEpisode(
    AnimeSummary anime,
    int episode,
    int generation,
  ) async {
    final settingsController = ref.read(settingsPreferencesProvider.notifier);
    final torrentSourcesController = ref.read(
      userTorrentSourcesControllerProvider.notifier,
    );
    final alternativeTitles = <String?>{
      anime.titleEnglish,
      anime.titleRomaji,
      ...anime.synonyms,
    }.whereType<String>().toSet()..remove(anime.title);
    final reference = EpisodeReference(
      anilistMediaId: anime.id,
      malMediaId: anime.idMal,
      year: anime.seasonYear,
      title: anime.title,
      alternativeTitles: alternativeTitles.toList(growable: false),
      titleEnglish: anime.titleEnglish,
      titleRomaji: anime.titleRomaji,
      status: anime.status,
      format: anime.format,
      episodeCount: anime.episodes,
      isAdult: anime.isAdult,
      coverImageUrl: anime.coverImageUrl,
      episode: episode,
    );
    try {
      var preferences = ref.read(settingsPreferencesProvider);
      if (!preferences.loaded) {
        await settingsController.load();
        if (!mounted ||
            generation != _prefetchGeneration ||
            _requestedPrefetchEpisode != episode) {
          return;
        }
        preferences = ref.read(settingsPreferencesProvider);
      }
      // Start Web providers and already-restored torrent sources only after
      // encrypted opt-in/opt-out choices have finished loading.
      final initialHandle = ref.read(episodeDiscoveryPrefetcherProvider)(
        reference,
        preferences: preferences,
      );
      if (!mounted || generation != _prefetchGeneration) {
        await initialHandle.cancel();
        return;
      }
      _adoptPrefetch(initialHandle, episode, generation);
      if ((!preferences.debridStreamsEnabled &&
              !preferences.directTorrentStreamingEnabled) ||
          ref.read(userTorrentSourcesControllerProvider).loaded) {
        return;
      }
      await torrentSourcesController.load();
      if (!mounted ||
          generation != _prefetchGeneration ||
          _requestedPrefetchEpisode != episode) {
        return;
      }
      final refreshedHandle = ref.read(episodeDiscoveryPrefetcherProvider)(
        reference,
        preferences: ref.read(settingsPreferencesProvider),
      );
      if (!mounted || generation != _prefetchGeneration) {
        await refreshedHandle.cancel();
        return;
      }
      _adoptPrefetch(refreshedHandle, episode, generation);
    } catch (_) {
      // Discovery warming is deliberately invisible and fail-open.
    }
  }

  void _adoptPrefetch(
    EpisodeDiscoveryPrefetchHandle handle,
    int episode,
    int generation,
  ) {
    final previous = _activePrefetch;
    _activePrefetch = handle;
    _activePrefetchEpisode = episode;
    if (previous != null && !identical(previous, handle)) {
      unawaited(previous.cancel());
    }
    unawaited(
      handle.done.whenComplete(() {
        if (mounted &&
            generation == _prefetchGeneration &&
            identical(_activePrefetch, handle)) {
          _activePrefetch = null;
          _activePrefetchEpisode = null;
          _lastCompletedPrefetchEpisode = episode;
        }
      }),
    );
  }

  Future<void> _openEpisodeWithFillerCheck(
    AnimeSummary anime,
    int requestedEpisode,
    int totalEpisodes, {
    bool restart = false,
  }) async {
    var skipEnabled = false;
    final preferencesFuture = ref.read(
      seriesPlaybackPreferencesProvider(anime.id).future,
    );
    final fillerRepository = ref.read(fillerEpisodeRepositoryProvider);
    final unavailableNoticeController = ref.read(
      fillerUnavailableNotifiedSeriesProvider.notifier,
    );
    try {
      skipEnabled = (await preferencesFuture).skipFillerEpisodes;
    } catch (_) {
      // Persistence errors must not prevent an explicitly requested episode
      // from playing. The default is deliberately fail-open.
    }
    if (!mounted) return;
    final decision = await resolveFillerEpisodeNavigation(
      repository: fillerRepository,
      identity: FillerSeriesIdentity.fromAnime(anime),
      requestedEpisode: requestedEpisode,
      totalEpisodes: totalEpisodes,
      skipEnabled: skipEnabled,
    );
    if (!mounted) return;
    if (decision.dataUnavailable &&
        consumeFillerUnavailableNotice(unavailableNoticeController, anime.id)) {
      showFillerDataUnavailableNotice(context, episode: requestedEpisode);
    }
    await showFillerSkipNotification(context, decision);
    if (!mounted || decision.episode == null) return;
    _openEpisode(context, anime, decision.episode!, restart: restart);
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.anime});

  final AnimeSummary anime;

  @override
  Widget build(BuildContext context) {
    final values = <String>[
      if (anime.format case final format?) format.replaceAll('_', ' '),
      ...anime.genres.take(3),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        for (final value in values)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .36),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: .12)),
            ),
            child: Text(
              value,
              style: TextStyle(
                color: context.appPalette.primaryText,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

class _EpisodeCounterBadge extends StatelessWidget {
  const _EpisodeCounterBadge({
    required this.selectedEpisode,
    required this.totalEpisodes,
    this.large = false,
    this.compact = false,
  });

  final int selectedEpisode;
  final int totalEpisodes;
  final bool large;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 20 : (compact ? 10 : 14),
        vertical: large ? 11 : (compact ? 7 : 8),
      ),
      decoration: BoxDecoration(
        color: const Color(0xD9111111),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: .16)),
      ),
      child: Text(
        compact
            ? 'EP $selectedEpisode / $totalEpisodes'
            : 'EPISODE $selectedEpisode OF $totalEpisodes',
        style: TextStyle(
          color: context.appPalette.primaryText,
          fontSize: large ? 15 : (compact ? 10 : 12),
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _MediaFactsRow extends StatelessWidget {
  const _MediaFactsRow({required this.anime});

  final AnimeSummary anime;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final large = width >= 1500;
    return Wrap(
      spacing: large ? 22 : 14,
      runSpacing: 8,
      children: [
        if (anime.seasonYear case final year?)
          _MediaFact(
            icon: Icons.calendar_today_outlined,
            label: '$year',
            large: large,
          ),
        if (anime.durationMinutes case final minutes?)
          _MediaFact(
            icon: Icons.schedule_rounded,
            label: '${minutes}m',
            large: large,
          ),
        if (anime.score case final score?)
          _MediaFact(
            icon: Icons.star_border_rounded,
            label: '${score.toStringAsFixed(1)} / 10',
            large: large,
            accent: true,
          ),
      ],
    );
  }
}

class _MediaFact extends StatelessWidget {
  const _MediaFact({
    required this.icon,
    required this.label,
    required this.large,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final bool large;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: large ? 22 : 17,
          color: accent
              ? context.appPalette.accentBright
              : context.appPalette.mutedText,
        ),
        SizedBox(width: large ? 8 : 5),
        Text(
          label,
          style: TextStyle(
            color: context.appPalette.primaryText,
            fontSize: large ? 17 : 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _InformationActions extends StatelessWidget {
  const _InformationActions({
    required this.onTrailer,
    required this.onFranchise,
    required this.onCredits,
    required this.onDownloadSeason,
    required this.downloadSeasonLabel,
    this.large = false,
  });

  final VoidCallback? onTrailer;
  final VoidCallback? onFranchise;
  final VoidCallback? onCredits;
  final VoidCallback? onDownloadSeason;
  final String downloadSeasonLabel;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Wrap(
        key: const ValueKey('anime-details-information-actions'),
        spacing: 10,
        runSpacing: 8,
        children: [
          if (onTrailer != null)
            _InformationButton(
              key: const ValueKey('anime-details-watch-trailer'),
              label: 'Watch trailer',
              icon: Icons.play_circle_outline_rounded,
              onPressed: onTrailer!,
              large: large,
            ),
          if (onCredits != null)
            _InformationButton(
              label: 'Cast & crew',
              icon: Icons.groups_rounded,
              onPressed: onCredits!,
              large: large,
            ),
          if (onFranchise != null)
            _InformationButton(
              label: 'Related series',
              icon: Icons.account_tree_rounded,
              onPressed: onFranchise!,
              large: large,
            ),
          if (onDownloadSeason != null)
            _InformationButton(
              key: const ValueKey('anime-details-download-season'),
              label: downloadSeasonLabel,
              icon: Icons.download_for_offline_rounded,
              onPressed: onDownloadSeason!,
              large: large,
            ),
        ],
      ),
    );
  }
}

class _InformationButton extends StatelessWidget {
  const _InformationButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.large,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onPressed: onPressed,
      focusScale: 1.025,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: large ? 58 : 42,
        padding: EdgeInsets.symmetric(horizontal: large ? 20 : 13),
        decoration: BoxDecoration(
          color: const Color(0xEE171717),
          border: Border.all(color: Colors.white.withValues(alpha: .15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: large ? 23 : 18),
            SizedBox(width: large ? 10 : 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: large ? 16 : 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SizedBox(width: large ? 12 : 7),
            Icon(Icons.chevron_right_rounded, size: large ? 22 : 17),
          ],
        ),
      ),
    );
  }
}

class _EpisodeActions extends StatelessWidget {
  const _EpisodeActions({
    required this.isAvailable,
    required this.autofocusPrimary,
    required this.selectedEpisode,
    required this.resumeEpisode,
    required this.totalEpisodes,
    required this.hasProgress,
    required this.guestInWatchParty,
    required this.resumePosition,
    required this.resumeIsFiller,
    required this.selectedIsFiller,
    required this.onDecrease,
    required this.onIncrease,
    required this.onPlayFromBeginning,
    required this.onResume,
    required this.onPlaySelected,
    required this.onManageList,
    required this.skipFillerEpisodes,
    required this.onToggleSkipFiller,
    required this.watchPartyState,
    required this.watchPartyStarting,
    required this.watchPartyFocusNode,
    required this.skipFillerFocusNode,
    required this.previousEpisodeFocusNode,
    required this.nextEpisodeFocusNode,
    required this.showWatchPartyAction,
    required this.onWatchPartyPressed,
  });

  final bool isAvailable;
  final bool autofocusPrimary;
  final int selectedEpisode;
  final int resumeEpisode;
  final int totalEpisodes;
  final bool hasProgress;
  final bool guestInWatchParty;
  final Duration? resumePosition;
  final bool resumeIsFiller;
  final bool selectedIsFiller;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final VoidCallback? onPlayFromBeginning;
  final VoidCallback? onResume;
  final VoidCallback? onPlaySelected;
  final VoidCallback onManageList;
  final bool skipFillerEpisodes;
  final VoidCallback? onToggleSkipFiller;
  final WatchPartyState watchPartyState;
  final bool watchPartyStarting;
  final FocusNode watchPartyFocusNode;
  final FocusNode skipFillerFocusNode;
  final FocusNode previousEpisodeFocusNode;
  final FocusNode nextEpisodeFocusNode;
  final bool showWatchPartyAction;
  final VoidCallback? onWatchPartyPressed;

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.sizeOf(context).width >= 1500;
    return Container(
      key: const ValueKey('episode-actions-panel'),
      width: double.infinity,
      padding: EdgeInsets.all(large ? 22 : 8),
      decoration: BoxDecoration(
        color: const Color(0xF5111111),
        borderRadius: BorderRadius.circular(large ? 20 : 14),
        border: Border.all(color: Colors.white.withValues(alpha: .18)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!guestInWatchParty) ...[
            _EpisodeActionButton(
              key: const ValueKey('episode-action-resume'),
              label: !isAvailable
                  ? 'Not released yet'
                  : resumePosition == null
                  ? (hasProgress ? 'Resume' : 'Start watching')
                  : 'Resume at ${_formatDuration(resumePosition!)}',
              trailing: isAvailable ? 'EP-$resumeEpisode' : null,
              badge: resumeIsFiller ? 'FILLER' : null,
              icon: Icons.play_arrow_rounded,
              primary: true,
              autofocus: isAvailable && autofocusPrimary,
              onPressed: onResume,
              large: large,
            ),
            SizedBox(height: large ? 14 : 6),
            _EpisodeActionButton(
              key: const ValueKey('episode-action-restart'),
              label: 'Play from beginning',
              icon: Icons.replay_rounded,
              onPressed: onPlayFromBeginning,
              large: large,
            ),
            SizedBox(height: large ? 14 : 6),
            _EpisodeActionButton(
              key: const ValueKey('episode-action-selected'),
              label: 'Play selected',
              trailing: 'EP-$selectedEpisode',
              badge: selectedIsFiller ? 'FILLER' : null,
              icon: Icons.skip_next_rounded,
              onPressed: onPlaySelected,
              large: large,
            ),
            SizedBox(height: large ? 14 : 6),
          ],
          _EpisodeActionButton(
            key: const ValueKey('episode-action-manage-list'),
            label: 'My List status',
            icon: Icons.playlist_add_check_rounded,
            trailingIcon: Icons.arrow_drop_down_rounded,
            onPressed: onManageList,
            large: large,
          ),
          SizedBox(height: large ? 14 : 6),
          _EpisodeToggleButton(
            key: const ValueKey('episode-action-skip-filler'),
            value: skipFillerEpisodes,
            onPressed: onToggleSkipFiller,
            focusNode: skipFillerFocusNode,
            large: large,
          ),
          if (showWatchPartyAction) ...[
            SizedBox(height: large ? 14 : 6),
            _EpisodeWatchPartyAction(
              key: const ValueKey('episode-action-watch-together'),
              state: watchPartyState,
              starting: watchPartyStarting,
              focusNode: watchPartyFocusNode,
              onPressed: onWatchPartyPressed,
              fallbackEpisode: selectedEpisode,
              large: large,
            ),
          ],
          SizedBox(height: large ? 22 : 7),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'EPISODE',
              style: TextStyle(
                color: context.appPalette.mutedText,
                fontSize: large ? 13 : 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
          ),
          SizedBox(height: large ? 10 : 5),
          Container(
            height: large ? 68 : 44,
            decoration: BoxDecoration(
              color: const Color(0xFF191919),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: .14)),
            ),
            child: Row(
              children: [
                _EpisodeStepButton(
                  key: const ValueKey('episode-step-previous'),
                  icon: Icons.remove_rounded,
                  label: 'Previous episode',
                  onPressed: onDecrease,
                  focusNode: previousEpisodeFocusNode,
                ),
                Expanded(
                  child: Text(
                    'Episode $selectedEpisode of $totalEpisodes',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: large ? 16 : 13,
                    ),
                  ),
                ),
                _EpisodeStepButton(
                  key: const ValueKey('episode-step-next'),
                  icon: Icons.add_rounded,
                  label: 'Next episode',
                  onPressed: onIncrease,
                  focusNode: nextEpisodeFocusNode,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeWatchPartyAction extends StatelessWidget {
  const _EpisodeWatchPartyAction({
    super.key,
    required this.state,
    required this.starting,
    required this.focusNode,
    required this.onPressed,
    required this.fallbackEpisode,
    required this.large,
  });

  final WatchPartyState state;
  final bool starting;
  final FocusNode focusNode;
  final VoidCallback? onPressed;
  final int fallbackEpisode;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    final participants =
        state.snapshot?.participants ?? const <WatchPartyParticipant>[];
    final participantCount = watchPartyViewerCount(state);
    final active = session != null;
    final isGuest = session?.role == WatchPartyRole.guest;
    final enabled = !active && onPressed != null && !starting;
    final media = state.snapshot?.media ?? state.attachedMedia;
    final episode = media?.episode ?? fallbackEpisode;
    final semanticsLabel = active
        ? 'Watch Party room ${session.roomCode}, '
              '$participantCount ${participantCount == 1 ? 'person' : 'people'}. '
              '${isGuest ? 'Leave Party available' : 'Host room active'}'
        : starting
        ? 'Starting Watch Party room'
        : 'Start Watch Party';
    final content = Container(
      height: large ? 76 : 42,
      padding: EdgeInsets.symmetric(horizontal: large ? 22 : 13),
      color: const Color(0xFF1B1B1B),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final iconWidth = large ? 29.0 : 19.0;
          final leadingGap = large ? 16.0 : 8.0;
          final itemGap = large ? 12.0 : 6.0;
          final avatarDimension = large ? 36.0 : 25.0;
          final preferredAvatarWidth = large ? 120.0 : 81.0;
          final leaveWidth = large ? 108.0 : 70.0;
          final reservedForLeave = isGuest && onPressed != null
              ? itemGap + leaveWidth
              : 0.0;
          final activeContentWidth =
              constraints.maxWidth - iconWidth - leadingGap - reservedForLeave;
          final minimumMediaWidth = large ? 100.0 : 66.0;
          final availableAvatarWidth =
              activeContentWidth - minimumMediaWidth - itemGap;
          final avatarWidth = availableAvatarWidth
              .clamp(avatarDimension, preferredAvatarWidth)
              .toDouble();
          return Row(
            children: [
              if (starting)
                SizedBox.square(
                  dimension: large ? 27 : 18,
                  child: const CircularProgressIndicator(strokeWidth: 2.5),
                )
              else
                Icon(
                  active
                      ? Icons.groups_rounded
                      : Icons.person_add_alt_1_rounded,
                  size: large ? 29 : 19,
                  color: active
                      ? context.appPalette.accentBright
                      : context.appPalette.primaryText,
                ),
              SizedBox(width: leadingGap),
              if (active) ...[
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          session.roomCode,
                          key: const ValueKey('episode-watch-party-room-code'),
                          maxLines: 1,
                          style: TextStyle(
                            color: context.appPalette.accentBright,
                            fontSize: large ? 19 : 14,
                            fontWeight: FontWeight.w900,
                            letterSpacing: large ? 2.4 : 1.5,
                          ),
                        ),
                      ),
                      Text(
                        media == null
                            ? 'Episode $episode'
                            : '${media.title} • Episode $episode',
                        key: const ValueKey('episode-watch-party-media'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.appPalette.mutedText,
                          fontSize: large ? 11 : 8,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: itemGap),
                SizedBox(
                  width: avatarWidth,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _EpisodeWatchPartyAvatars(
                      participants: participants,
                      large: large,
                    ),
                  ),
                ),
                if (isGuest && onPressed != null) ...[
                  SizedBox(width: itemGap),
                  SizedBox(
                    width: leaveWidth,
                    child: TvFocusable(
                      key: const ValueKey('episode-watch-party-leave'),
                      focusNode: focusNode,
                      onPressed: onPressed!,
                      focusScale: 1.02,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        height: large ? 44 : 30,
                        alignment: Alignment.center,
                        color: context.appPalette.selectableSurface,
                        child: Text(
                          'Leave Party',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: large ? 12 : 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ] else
                Expanded(
                  child: Text(
                    starting ? 'Starting…' : 'Start Watch Party',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.appPalette.primaryText,
                      fontSize: large ? 18 : 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (active) {
      return Semantics(
        container: true,
        label: semanticsLabel,
        excludeSemantics: !isGuest,
        child: content,
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticsLabel,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: enabled || starting
          ? TvFocusable(
              focusNode: focusNode,
              onPressed: enabled ? onPressed! : () {},
              focusScale: 1.025,
              borderRadius: BorderRadius.circular(10),
              child: Opacity(opacity: starting ? .72 : 1, child: content),
            )
          : Opacity(opacity: starting ? .72 : .42, child: content),
    );
  }
}

class _EpisodeWatchPartyAvatars extends StatelessWidget {
  const _EpisodeWatchPartyAvatars({
    required this.participants,
    required this.large,
  });

  final List<WatchPartyParticipant> participants;
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) return const SizedBox.shrink();
    final avatarDimension = large ? 36.0 : 25.0;
    final gap = large ? 6.0 : 3.0;
    final preferredCapacity = large ? 5 : 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        final capacity = constraints.maxWidth.isFinite
            ? ((constraints.maxWidth + gap) ~/ (avatarDimension + gap)).clamp(
                1,
                preferredCapacity,
              )
            : preferredCapacity;
        final hasOverflow = participants.length > capacity;
        // Even the narrow guest card must show a real participant rather than
        // replacing every profile photo with only a "+N" counter.
        final showOverflow = hasOverflow && capacity > 1;
        final profileCount = showOverflow ? capacity - 1 : capacity;
        final visible = participants.take(profileCount).toList(growable: false);
        return Semantics(
          container: true,
          label: '${participants.length} people in this Watch Party room',
          child: Row(
            key: const ValueKey('episode-watch-party-avatars'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < visible.length; index++) ...[
                if (index > 0) SizedBox(width: gap),
                _EpisodeWatchPartyAvatar(
                  key: ValueKey('episode-watch-party-avatar-$index'),
                  participant: visible[index],
                  large: large,
                ),
              ],
              if (showOverflow) ...[
                if (visible.isNotEmpty) SizedBox(width: gap),
                _EpisodeWatchPartyOverflowAvatar(
                  key: const ValueKey('episode-watch-party-avatar-overflow'),
                  count: participants.length - profileCount,
                  large: large,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _EpisodeWatchPartyAvatar extends StatelessWidget {
  const _EpisodeWatchPartyAvatar({
    super.key,
    required this.participant,
    required this.large,
  });

  final WatchPartyParticipant participant;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final dimension = large ? 36.0 : 25.0;
    final safeIdentity = WatchPartyPublicIdentity.tryCreate(
      displayName: participant.displayName,
      avatarUrl: participant.avatarUrl,
    );
    final displayName = safeIdentity?.displayName;
    final avatarUrl = safeIdentity?.avatarUrl;
    return Semantics(
      image: true,
      label: displayName ?? 'Watch Party participant',
      excludeSemantics: true,
      child: Container(
        width: dimension,
        height: dimension,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: context.appPalette.accent.withValues(alpha: .25),
          border: Border.all(color: Colors.white.withValues(alpha: .28)),
        ),
        clipBehavior: Clip.antiAlias,
        child: avatarUrl == null
            ? Center(
                child: Text(
                  _watchPartyInitial(displayName ?? ''),
                  style: TextStyle(
                    color: context.appPalette.accentBright,
                    fontSize: large ? 13 : 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              )
            : NetworkArtwork(
                url: avatarUrl,
                icon: Icons.person_rounded,
                cacheWidth: large ? 96 : 64,
              ),
      ),
    );
  }
}

class _EpisodeWatchPartyOverflowAvatar extends StatelessWidget {
  const _EpisodeWatchPartyOverflowAvatar({
    super.key,
    required this.count,
    required this.large,
  });

  final int count;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final dimension = large ? 36.0 : 25.0;
    return Container(
      width: dimension,
      height: dimension,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.appPalette.selectableSurface,
        border: Border.all(color: Colors.white.withValues(alpha: .18)),
      ),
      child: Text(
        '+$count',
        style: TextStyle(
          color: context.appPalette.primaryText,
          fontSize: large ? 11 : 8,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

String _watchPartyInitial(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first).toUpperCase();
}

class _EpisodeToggleButton extends StatelessWidget {
  const _EpisodeToggleButton({
    super.key,
    required this.value,
    required this.onPressed,
    required this.focusNode,
    required this.large,
  });

  final bool value;
  final VoidCallback? onPressed;
  final FocusNode focusNode;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final content = Container(
      height: large ? 76 : 42,
      padding: EdgeInsets.symmetric(horizontal: large ? 22 : 13),
      color: const Color(0xFF1B1B1B),
      child: Row(
        children: [
          Icon(Icons.fast_forward_rounded, size: large ? 29 : 19),
          SizedBox(width: large ? 16 : 8),
          Expanded(
            child: Text(
              'Skip filler',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.appPalette.primaryText,
                fontSize: large ? 18 : 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value ? 'ON' : 'OFF',
            style: TextStyle(
              color: value
                  ? context.appPalette.accentBright
                  : context.appPalette.mutedText,
              fontSize: large ? 14 : 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(width: large ? 12 : 7),
          Icon(
            value ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
            color: value
                ? context.appPalette.accentBright
                : context.appPalette.mutedText,
            size: large ? 36 : 27,
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      toggled: value,
      label: 'Skip filler',
      child: enabled
          ? TvFocusable(
              focusNode: focusNode,
              focusScale: 1.025,
              borderRadius: BorderRadius.circular(10),
              onPressed: onPressed!,
              child: content,
            )
          : Opacity(opacity: .52, child: content),
    );
  }
}

class _EpisodeActionButton extends StatelessWidget {
  const _EpisodeActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.trailing,
    this.badge,
    this.trailingIcon,
    this.primary = false,
    this.autofocus = false,
    this.large = false,
  });

  final String label;
  final String? trailing;
  final String? badge;
  final IconData? trailingIcon;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool autofocus;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final content = Container(
      height: large ? 76 : 42,
      padding: EdgeInsets.symmetric(horizontal: large ? 22 : 13),
      color: primary ? context.appPalette.accent : const Color(0xFF1B1B1B),
      child: Row(
        children: [
          Icon(icon, size: large ? 29 : 19),
          SizedBox(width: large ? 16 : 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.appPalette.primaryText,
                fontSize: large ? 18 : 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (badge case final value?) ...[
            Container(
              margin: EdgeInsets.only(right: large ? 12 : 7),
              padding: EdgeInsets.symmetric(
                horizontal: large ? 9 : 6,
                vertical: large ? 5 : 3,
              ),
              decoration: BoxDecoration(
                color: context.appPalette.accent.withValues(alpha: .24),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                value,
                style: TextStyle(
                  color: context.appPalette.accentBright,
                  fontSize: large ? 11 : 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .7,
                ),
              ),
            ),
          ],
          if (trailing case final value?)
            Text(
              value,
              style: TextStyle(
                color: Colors.white70,
                fontSize: large ? 14 : 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          if (trailingIcon case final value?) ...[
            if (trailing != null) SizedBox(width: large ? 10 : 6),
            Icon(value, size: large ? 25 : 19, color: Colors.white70),
          ],
        ],
      ),
    );
    if (!enabled) {
      return Semantics(
        button: true,
        enabled: false,
        child: Opacity(opacity: .38, child: content),
      );
    }
    return TvFocusable(
      autofocus: autofocus,
      focusScale: 1.025,
      borderRadius: BorderRadius.circular(10),
      onPressed: onPressed!,
      child: content,
    );
  }
}

class _EpisodeStepButton extends StatelessWidget {
  const _EpisodeStepButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.focusNode,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      width: 48,
      height: 48,
      child: Icon(icon, size: 22),
    );
    if (onPressed == null) {
      return Semantics(
        label: label,
        button: true,
        enabled: false,
        child: Opacity(opacity: .32, child: content),
      );
    }
    return Semantics(
      label: label,
      button: true,
      enabled: true,
      child: TvFocusable(
        focusNode: focusNode,
        focusScale: 1.04,
        borderRadius: BorderRadius.circular(9),
        onPressed: onPressed!,
        child: content,
      ),
    );
  }
}

class _DetailsBack extends StatelessWidget {
  const _DetailsBack({
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
  });

  final VoidCallback onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TvFocusable(
        autofocus: autofocus,
        focusNode: focusNode,
        onPressed: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: const ColoredBox(
          color: Color(0xCC111111),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_rounded, size: 20),
                SizedBox(width: 8),
                Text('Back'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailsError extends StatelessWidget {
  const _DetailsError({
    required this.message,
    required this.onBack,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onBack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.all(42),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailsBack(onPressed: onBack, autofocus: true),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    size: 66,
                    color: context.appPalette.mutedText,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Could not load anime',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(message, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 20),
                  TvFocusable(
                    onPressed: onRetry,
                    child: ColoredBox(
                      color: context.appPalette.primaryText,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 11,
                        ),
                        child: Text(
                          'Retry',
                          style: TextStyle(
                            color: context.appPalette.background,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

void _openEpisode(
  BuildContext context,
  AnimeSummary anime,
  int episode, {
  bool restart = false,
}) {
  final alternativeTitles = <String?>{
    anime.titleEnglish,
    anime.titleRomaji,
    ...anime.synonyms,
  }.whereType<String>().toSet()..remove(anime.title);
  context.push(
    Uri(
      path: '/resolve',
      queryParameters: {
        'anilistId': '${anime.id}',
        if (anime.idMal != null) 'malId': '${anime.idMal}',
        'title': anime.title,
        'episode': '$episode',
        if (anime.seasonYear != null) 'year': '${anime.seasonYear}',
        if (anime.coverImageUrl != null) 'cover': anime.coverImageUrl!,
        if (restart) 'restart': '1',
        if (alternativeTitles.isNotEmpty)
          'synonyms': alternativeTitles.join('|'),
        if (anime.titleEnglish != null) 'titleEnglish': anime.titleEnglish!,
        if (anime.titleRomaji != null) 'titleRomaji': anime.titleRomaji!,
        if (anime.status != null) 'status': anime.status!,
        if (anime.format != null) 'format': anime.format!,
        if (anime.episodes != null) 'episodeCount': '${anime.episodes}',
        if (anime.isAdult) 'isAdult': '1',
      },
    ).toString(),
  );
}
