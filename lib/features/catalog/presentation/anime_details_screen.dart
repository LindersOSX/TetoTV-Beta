import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:anime_tv/core/widgets/teto_blur_scope.dart';
import 'dart:async';
import 'dart:ui';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:anime_tv/core/widgets/teto_artwork_scrim.dart';
import 'package:anime_tv/core/widgets/teto_browse_status.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/core/widgets/teto_switch_indicator.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/application/filler_episode_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_franchise_context.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/catalog_episode_metadata.dart';
import 'package:anime_tv/features/catalog/domain/episode_airing_availability.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:anime_tv/features/catalog/presentation/anime_title_logo_view.dart';
import 'package:anime_tv/features/catalog/presentation/episode_browser_dialog.dart';
import 'package:anime_tv/features/catalog/presentation/episode_panel_icon.dart';
import 'package:anime_tv/features/catalog/presentation/localized_anime_description.dart';
import 'package:anime_tv/features/catalog/presentation/localized_episode_airing.dart';
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
import 'package:flutter/services.dart';
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
        loading: () => const TetoBrowseLoading(),
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
  bool _episodeBrowserOpen = false;
  FocusNode? _episodeBrowserRestoreFocusNode;
  Future<Map<int, CatalogEpisodeMetadata>>? _episodeBrowserMetadataFuture;
  final FocusNode _watchPartyFocusNode = FocusNode(
    debugLabel: 'episode.watch-together',
  );
  final FocusNode _skipFillerFocusNode = FocusNode(
    debugLabel: 'episode.skip-filler',
  );
  final FocusNode _browseEpisodesFocusNode = FocusNode(
    debugLabel: 'episode.browse',
  );
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
    _browseEpisodesFocusNode.dispose();
    _backFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final isTelevision = ref.watch(isTelevisionProvider);
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
    final releaseCheckAt = DateTime.now();
    final statusText = _animeDetailsStatusText(context, anime, releaseCheckAt);
    final posterAiringStatus = animeAiringStatusLabel(anime.status);
    final hasFinishedAiring = posterAiringStatus == 'FINISHED';
    final hasAiringSchedule =
        anime.nextAiringAt != null &&
        localizedNextEpisodeCountdown(context, anime, now: releaseCheckAt) !=
            null;
    // Known release states live with the year/runtime/rating. Keep a separate
    // line only for additional airing dates or an unrecognized catalog state.
    final displayedStatusText =
        posterAiringStatus == null || (!hasFinishedAiring && hasAiringSchedule)
        ? statusText
        : null;
    final selectedAvailability = episodeAiringAvailability(
      anime: anime,
      episode: selectedEpisode,
      now: releaseCheckAt,
    );
    final resumeAvailability = episodeAiringAvailability(
      anime: anime,
      episode: targetEpisode,
      now: releaseCheckAt,
    );
    if (selectedAvailability.isAvailable) {
      _scheduleEpisodePrefetch(selectedEpisode);
    } else {
      _suppressEpisodePrefetchForUnavailableSelection();
    }
    final onDownloadSeason = !settings.offlineDownloadsEnabled || isUnreleased
        ? null
        : seasonDownload.isRunning
        ? seasonDownload.mediaId == anime.id
              ? () {
                  ref.read(seasonDownloadControllerProvider.notifier).cancel();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        context.tr(
                          "Stopped preparing the remaining season downloads.",
                        ),
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
    final hasInformationActions = <VoidCallback?>[
      onTrailer,
      onCredits,
      onFranchise,
      onDownloadSeason,
    ].any((action) => action != null);
    _EpisodeActions episodeActions({
      required bool autofocusPrimary,
      required double availableInfoWidth,
      required bool largeInformation,
    }) => _EpisodeActions(
      selectedAvailability: selectedAvailability,
      resumeAvailability: resumeAvailability,
      autofocusPrimary: autofocusPrimary,
      selectedEpisode: selectedEpisode,
      titlePreference: titlePreference,
      resumeEpisode: targetEpisode,
      totalEpisodes: knownEpisodes,
      watchedEpisodes: progress,
      catalogEpisodeCount: anime.episodes,
      informationAction: hasInformationActions
          ? _InformationActions(
              onTrailer: onTrailer,
              onFranchise: onFranchise,
              onCredits: onCredits,
              onDownloadSeason: onDownloadSeason,
              downloadSeasonLabel: downloadSeasonLabel,
              availableWidth: availableInfoWidth,
              large: largeInformation,
            )
          : null,
      hasProgress: progress > 0 || localResume,
      resumeProgress: localResume ? localPlayback.progress : null,
      resumeIsFiller:
          canShowFillerIndicators &&
          fillerIndicatorLookup!.isConfirmedFiller(targetEpisode),
      selectedIsFiller:
          canShowFillerIndicators &&
          fillerIndicatorLookup!.isConfirmedFiller(selectedEpisode),
      guestInWatchParty: guestInWatchParty,
      onBrowseEpisodes: !guestInWatchParty && !isUnreleased
          ? () => _openEpisodeBrowser(
              selectedEpisode: selectedEpisode,
              totalEpisodes: knownEpisodes,
            )
          : null,
      isTelevision: isTelevision,
      onPlayFromBeginning:
          !selectedAvailability.isAvailable || guestInWatchParty
          ? null
          : () => unawaited(
              _openEpisodeWithFillerCheck(
                anime,
                selectedEpisode,
                knownEpisodes,
                restart: true,
              ),
            ),
      onResume: !resumeAvailability.isAvailable || guestInWatchParty
          ? null
          : () => unawaited(
              _openEpisodeWithFillerCheck(anime, targetEpisode, knownEpisodes),
            ),
      onPlaySelected: !selectedAvailability.isAvailable || guestInWatchParty
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
      browseEpisodesFocusNode: _browseEpisodesFocusNode,
      showWatchPartyAction: settings.showWatchTogether,
      onWatchPartyPressed: watchParty.session?.role == WatchPartyRole.guest
          ? () => unawaited(
              ref.read(watchPartyControllerProvider.notifier).leave(),
            )
          : watchParty.isActive
          ? null
          : selectedAvailability.isAvailable &&
                !_startingWatchParty &&
                !watchParty.isBusy
          ? () => unawaited(_startWatchParty())
          : null,
    );
    final detailsContent = Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          enabled: TetoBlurScope.enabledOf(context),
          imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: NetworkArtwork(
            url: anime.coverImageUrl ?? anime.bannerImageUrl,
            cacheWidth: 1200,
          ),
        ),
        const TetoArtworkScrim(),
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
                                        if (posterAiringStatus != null &&
                                            !hasFinishedAiring)
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
                                      if (displayedStatusText
                                          case final status?) ...[
                                        const SizedBox(height: 9),
                                        Text(
                                          context.tr("Status: {value1}", {
                                            'value1': status,
                                          }),
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
                            LocalizedAnimeDescription(
                              aniListId: anime.id,
                              language: settings.interfaceLanguage.code,
                              fallbackDescription: anime.description.isEmpty
                                  ? context.tr("No synopsis is available.")
                                  : anime.description,
                              style: Theme.of(context).textTheme.bodyMedium,
                              maxLines: 5,
                              expandable: true,
                            ),
                            const SizedBox(height: 18),
                            episodeActions(
                              autofocusPrimary: false,
                              availableInfoWidth: constraints.maxWidth,
                              largeInformation: isTelevision,
                            ),
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
              // 66% of the visible TV image at both 1080p and smaller 16:9
              // resolutions instead of shrinking it at logical resolutions
              // reported by some TV devices.
              final targetPosterWidth =
                  MediaQuery.sizeOf(context).height * .66 / 1.5;
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
              final detailsTopInset =
                  constraints.maxHeight *
                  (constraints.maxHeight < 620 ? .04 : (wide ? .10 : .08));
              final contentHeight =
                  constraints.maxHeight - 48 - (wide ? 28 : 10);
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
                    ],
                  ),
                  SizedBox(height: wide ? 28 : 10),
                  Expanded(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(top: 0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(top: detailsTopInset),
                              child: SizedBox(
                                key: const ValueKey('anime-details-poster'),
                                width: posterWidth,
                                child: AspectRatio(
                                  aspectRatio: 2 / 3,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: .2,
                                        ),
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
                                          if (posterAiringStatus != null &&
                                              !hasFinishedAiring)
                                            Positioned(
                                              left: wide ? 18 : 9,
                                              top: wide ? 18 : 9,
                                              child: PosterAiringStatusBadge(
                                                status: anime.status,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: columnGap),
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(top: detailsTopInset),
                                child: Align(
                                  alignment: Alignment.topLeft,
                                  child: Column(
                                    key: const ValueKey('anime-details-info'),
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
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
                                          color:
                                              context.appPalette.accentBright,
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
                                      SizedBox(
                                        height: constraints.maxHeight < 620
                                            ? 12
                                            : 20,
                                      ),
                                      _MetadataRow(anime: anime),
                                      SizedBox(height: wide ? 18 : 14),
                                      _MediaFactsRow(anime: anime),
                                      SizedBox(
                                        height: wide
                                            ? 24
                                            : (constraints.maxHeight < 620
                                                  ? 14
                                                  : 20),
                                      ),
                                      Flexible(
                                        child: LocalizedAnimeDescription(
                                          aniListId: anime.id,
                                          language:
                                              settings.interfaceLanguage.code,
                                          fallbackDescription:
                                              anime.description.isEmpty
                                              ? context.tr(
                                                  "No synopsis is available.",
                                                )
                                              : anime.description,
                                          maxLines: wide
                                              ? 8
                                              : (spacious ? 7 : 5),
                                          expandable: true,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyLarge
                                              ?.copyWith(
                                                color: context
                                                    .appPalette
                                                    .primaryText,
                                                fontSize: wide ? 18 : 13,
                                                height: 1.48,
                                              ),
                                        ),
                                      ),
                                      if (displayedStatusText
                                          case final status?) ...[
                                        SizedBox(height: wide ? 20 : 10),
                                        Text(
                                          context.tr("Status: {value1}", {
                                            'value1': status,
                                          }),
                                          style: TextStyle(
                                            color:
                                                context.appPalette.accentBright,
                                            fontSize: wide ? 17 : 13,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: columnGap),
                            SizedBox(
                              width: actionWidth,
                              height: contentHeight,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: 48 + (wide ? 28 : 10),
                                ),
                                child: Align(
                                  alignment: Alignment.center,
                                  child: SingleChildScrollView(
                                    primary: false,
                                    clipBehavior: Clip.none,
                                    child: episodeActions(
                                      autofocusPrimary: true,
                                      availableInfoWidth: actionWidth,
                                      largeInformation: wide || isTelevision,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
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
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    return PopScope(
      canPop: !_episodeBrowserOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _episodeBrowserOpen) _closeEpisodeBrowser();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: _episodeBrowserOpen,
            child: IgnorePointer(
              ignoring: _episodeBrowserOpen,
              child: Offstage(
                offstage: _episodeBrowserOpen,
                child: TickerMode(
                  enabled: !_episodeBrowserOpen,
                  child: detailsContent,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: ExcludeFocus(
              excluding: !_episodeBrowserOpen,
              child: IgnorePointer(
                ignoring: !_episodeBrowserOpen,
                child: AnimatedSwitcher(
                  key: const ValueKey('episode-browser-transition'),
                  duration: animationsDisabled
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  reverseDuration: animationsDisabled
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    fit: StackFit.expand,
                    children: [...previousChildren, ?currentChild],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, .025),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: _episodeBrowserOpen
                      ? Stack(
                          key: const ValueKey('episode-browser-overlay'),
                          fit: StackFit.expand,
                          children: [
                            // Blur only a small cached artwork layer, never the live
                            // details controls underneath this full-screen browser.
                            RepaintBoundary(
                              key: const ValueKey('episode-browser-backdrop'),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ImageFiltered(
                                    key: const ValueKey(
                                      'episode-browser-artwork-blur',
                                    ),
                                    enabled: TetoBlurScope.enabledOf(context),
                                    imageFilter: ImageFilter.blur(
                                      sigmaX: 2,
                                      sigmaY: 2,
                                    ),
                                    child: NetworkArtwork(
                                      url:
                                          anime.coverImageUrl ??
                                          anime.bannerImageUrl,
                                      cacheWidth: 480,
                                    ),
                                  ),
                                  ColoredBox(
                                    color: context.appPalette.background
                                        .withValues(alpha: .92),
                                  ),
                                ],
                              ),
                            ),
                            SafeArea(
                              minimum: context.responsiveScreenPadding,
                              child: EpisodeBrowserDialog(
                                anime: anime,
                                selectedEpisode: selectedEpisode,
                                totalEpisodes: knownEpisodes,
                                isTelevision: isTelevision,
                                embedded: true,
                                episodeMetadataFuture:
                                    _episodeBrowserMetadataFuture,
                                onClose: _closeEpisodeBrowser,
                                onEpisodeSelected: (episode) =>
                                    _closeEpisodeBrowser(
                                      selectedEpisode: episode,
                                    ),
                              ),
                            ),
                          ],
                        )
                      : const SizedBox.expand(
                          key: ValueKey('episode-browser-overlay-closed'),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
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
      label: context.tr("Downloads"),
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
          SnackBar(
            content: Text(
              context.tr("Skip filler preference could not be saved."),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingSkipFiller = false);
    }
  }

  void _openEpisodeBrowser({
    required int selectedEpisode,
    required int totalEpisodes,
  }) {
    if (_episodeBrowserOpen) return;
    _episodeBrowserRestoreFocusNode = _browseEpisodesFocusNode;
    _episodeBrowserMetadataFuture = ref
        .read(catalogClientProvider)
        .episodeMetadata(anime.id);
    setState(() => _episodeBrowserOpen = true);
  }

  void _closeEpisodeBrowser({int? selectedEpisode}) {
    if (!_episodeBrowserOpen) return;
    final restoreFocusNode = _episodeBrowserRestoreFocusNode;
    setState(() {
      if (selectedEpisode != null) _selectedEpisode = selectedEpisode;
      _episodeBrowserOpen = false;
      _episodeBrowserRestoreFocusNode = null;
      _episodeBrowserMetadataFuture = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || restoreFocusNode == null) return;
      if (restoreFocusNode.canRequestFocus &&
          restoreFocusNode.context != null) {
        restoreFocusNode.requestFocus();
      }
    });
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
        _browseEpisodesFocusNode,
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

  void _suppressEpisodePrefetchForUnavailableSelection() {
    if (_requestedPrefetchEpisode == null &&
        _prefetchDebounce == null &&
        _activePrefetch == null) {
      return;
    }
    _requestedPrefetchEpisode = null;
    _prefetchGeneration++;
    _prefetchDebounce?.cancel();
    _prefetchDebounce = null;
    _cancelActivePrefetch();
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
      anime.titleNative,
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
      titleNative: anime.titleNative,
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
    final availability = episodeAiringAvailability(
      anime: anime,
      episode: requestedEpisode,
    );
    if (!availability.isAvailable) {
      if (mounted && _selectedEpisode != requestedEpisode) {
        setState(() => _selectedEpisode = requestedEpisode);
      }
      return;
    }
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

class _MediaFactsRow extends StatelessWidget {
  const _MediaFactsRow({required this.anime});

  final AnimeSummary anime;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final large = width >= 1500;
    final releaseStatus = animeAiringStatusLabel(anime.status);
    return Wrap(
      spacing: large ? 22 : 14,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
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
        if (releaseStatus != null)
          _ReleaseStatusFact(status: releaseStatus, large: large),
      ],
    );
  }
}

/// Catalog release status, styled to align with the other media facts.
class _ReleaseStatusFact extends StatelessWidget {
  const _ReleaseStatusFact({required this.status, required this.large});

  final String status;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (status) {
      'AIRING' => ('Airing', Icons.sensors_rounded),
      'UNRELEASED' => ('Unreleased', Icons.schedule_rounded),
      _ => ('Finished airing', Icons.check_circle_outline_rounded),
    };
    return Semantics(
      label: context.tr(
        status == 'FINISHED' ? 'Series has finished airing' : label,
      ),
      child: ExcludeSemantics(
        child: KeyedSubtree(
          key: ValueKey('anime-details-${status.toLowerCase()}-status'),
          child: _MediaFact(
            icon: icon,
            label: label,
            large: large,
            accent: true,
          ),
        ),
      ),
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
          context.tr(label),
          style: TextStyle(
            color: context.appPalette.primaryText,
            fontSize: large ? 17 : 13,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
        ),
      ],
    );
  }
}

class _InformationActions extends StatefulWidget {
  const _InformationActions({
    required this.onTrailer,
    required this.onFranchise,
    required this.onCredits,
    required this.onDownloadSeason,
    required this.downloadSeasonLabel,
    required this.availableWidth,
    this.large = false,
  });

  final VoidCallback? onTrailer;
  final VoidCallback? onFranchise;
  final VoidCallback? onCredits;
  final VoidCallback? onDownloadSeason;
  final String downloadSeasonLabel;
  final double availableWidth;

  double preferredButtonWidth(BuildContext context) =>
      _informationButtonSize(context, large: large).width;
  final bool large;

  @override
  State<_InformationActions> createState() => _InformationActionsState();
}

TextStyle _informationButtonTextStyle(
  BuildContext context, {
  required bool large,
}) => Theme.of(context).textTheme.labelLarge!.copyWith(
  color: context.appPalette.primaryText,
  fontSize: large ? 14 : 12,
  fontWeight: FontWeight.w700,
  height: 1.2,
);

Size _informationButtonSize(
  BuildContext context, {
  required bool large,
  double maxWidth = double.infinity,
}) {
  final iconSize = large ? 18.0 : 16.0;
  final fixedWidth = iconSize + 8 + 24 + 2;
  final painter = TextPainter(
    text: TextSpan(
      text: context.tr('More Info'),
      style: _informationButtonTextStyle(context, large: large),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: (maxWidth - fixedWidth).clamp(1.0, double.infinity));
  final size = Size(
    (painter.width + fixedWidth).clamp(0.0, maxWidth),
    (painter.height + 12).clamp(large ? 34.0 : 30.0, double.infinity),
  );
  painter.dispose();
  return size;
}

typedef _InformationAction = ({
  String id,
  String label,
  IconData icon,
  VoidCallback onPressed,
});

class _InformationActionsState extends State<_InformationActions> {
  final GlobalKey _anchorKey = GlobalKey();
  final FocusNode _moreFocusNode = FocusNode(debugLabel: 'anime-details.more');
  bool _menuOpen = false;
  LogicalKeyboardKey? _dismissalKey;

  @override
  void dispose() {
    _moreFocusNode.dispose();
    super.dispose();
  }

  List<_InformationAction> get _actions => [
    if (widget.onTrailer != null)
      (
        id: 'watch-trailer',
        label: 'Watch trailer',
        icon: Icons.play_arrow_rounded,
        onPressed: widget.onTrailer!,
      ),
    if (widget.onCredits != null)
      (
        id: 'cast-crew',
        label: 'Cast & crew',
        icon: Icons.people_outline_rounded,
        onPressed: widget.onCredits!,
      ),
    if (widget.onFranchise != null)
      (
        id: 'related-series',
        label: 'Related series',
        icon: Icons.account_tree_outlined,
        onPressed: widget.onFranchise!,
      ),
    if (widget.onDownloadSeason != null)
      (
        id: 'download-season',
        label: widget.downloadSeasonLabel == 'Cancel season download'
            ? 'Cancel download'
            : widget.downloadSeasonLabel,
        icon: Icons.download_rounded,
        onPressed: widget.onDownloadSeason!,
      ),
  ];

  Future<void> _openMenu() async {
    if (_menuOpen) return;
    _dismissalKey = null;
    final anchor = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(
              context,
              rootNavigator: true,
            ).overlay?.context.findRenderObject()
            as RenderBox?;
    final actions = _actions;
    if (anchor == null || overlay == null || actions.isEmpty) return;
    final anchorRect =
        anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
    setState(() => _menuOpen = true);
    final selected = await showTetoGeneralDialog<int>(
      context: context,
      barrierDismissible: true,
      barrierLabel: context.tr('Close more options'),
      barrierColor: context.appPalette.background.withValues(alpha: .24),
      transitionDuration: TetoUiMotion.duration(context, TetoUiMotion.popup),
      pageBuilder: (_, _, _) => _InformationMenu(
        actions: actions,
        anchor: anchorRect,
        large: widget.large,
        onDismissKey: (key) => _dismissalKey = key,
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        if (TetoUiMotion.reduced(context)) return child;
        final progress = animation.drive(CurveTween(curve: TetoUiMotion.curve));
        return FadeTransition(
          opacity: progress,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -.025),
              end: Offset.zero,
            ).animate(progress),
            child: child,
          ),
        );
      },
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    _moreFocusNode.requestFocus();
    if (selected != null && selected >= 0 && selected < actions.length) {
      // Commit the restored focus before another route takes its focus snapshot.
      // Returning from credits, trailers, or downloads then lands back on More.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      actions[selected].onPressed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.clamp(0.0, widget.availableWidth);
        final size = _informationButtonSize(
          context,
          large: widget.large,
          maxWidth: maxWidth,
        );
        return SizedBox(
          key: _anchorKey,
          width: size.width,
          child: Semantics(
            expanded: _menuOpen,
            child: TvFocusable(
              key: const ValueKey('anime-details-more'),
              focusNode: _moreFocusNode,
              onKeyEvent: (_, event) {
                if (event.logicalKey != _dismissalKey) {
                  return KeyEventResult.ignored;
                }
                // The held closing key belongs to the popup, not the control
                // underneath it. A fresh press after release still navigates.
                if (event is KeyRepeatEvent) return KeyEventResult.handled;
                _dismissalKey = null;
                return event is KeyUpEvent
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored;
              },
              onPressed: () => unawaited(_openMenu()),
              focusScale: 1,
              child: Container(
                key: const ValueKey('anime-details-more-surface'),
                height: size.height,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: TetoBoxStyle.decoration(palette),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.info_rounded,
                      size: widget.large ? 18 : 16,
                      color: palette.accentBright,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        context.tr('More Info'),
                        style: _informationButtonTextStyle(
                          context,
                          large: widget.large,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _InformationMenu extends StatefulWidget {
  const _InformationMenu({
    required this.actions,
    required this.anchor,
    required this.large,
    required this.onDismissKey,
  });

  final List<_InformationAction> actions;
  final Rect anchor;
  final bool large;
  final ValueChanged<LogicalKeyboardKey?> onDismissKey;

  @override
  State<_InformationMenu> createState() => _InformationMenuState();
}

class _InformationMenuState extends State<_InformationMenu> {
  bool _closing = false;
  LogicalKeyboardKey? _closingKey;
  late final List<FocusNode> _nodes = [
    for (final action in widget.actions)
      FocusNode(debugLabel: 'anime-details.more.${action.id}'),
  ];

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _close([int? selected]) {
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    _closing = true;
    Navigator.of(context).pop(selected);
  }

  KeyEventResult _handleKey(int index, KeyEvent event) {
    if (event is KeyUpEvent && event.logicalKey == _closingKey) {
      widget.onDismissKey(null);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _closingKey = event.logicalKey;
      widget.onDismissKey(_closingKey);
      _close();
      return KeyEventResult.handled;
    }
    if (_closing) {
      return KeyEventResult.handled;
    }
    final direction = event.logicalKey == LogicalKeyboardKey.arrowDown
        ? 1
        : event.logicalKey == LogicalKeyboardKey.arrowUp
        ? -1
        : 0;
    if (direction == 0) return KeyEventResult.ignored;
    final next = (index + direction).clamp(0, _nodes.length - 1);
    _nodes[next].requestFocus();
    final nodeContext = _nodes[next].context;
    if (nodeContext != null) {
      Scrollable.ensureVisible(nodeContext, duration: Duration.zero);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final fontSize = widget.large ? 18.0 : 15.0;
    final textStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
      color: palette.primaryText,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
    );
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final safeLeft = padding.left + 16;
        final safeTop = padding.top + 16;
        final safeRight = constraints.maxWidth - padding.right - 16;
        final safeBottom = constraints.maxHeight - padding.bottom - 16;
        final width = (widget.large ? 340.0 : 300.0).clamp(
          0.0,
          (safeRight - safeLeft).clamp(0.0, double.infinity),
        );
        var rowHeight = widget.large ? 56.0 : 48.0;
        // Keep readable labels on accessibility text sizes without enlarging
        // the popup beyond the safe viewport. The list scrolls when necessary.
        final labelWidth = (width - 24 - 24 - 14 - 8 - (widget.large ? 46 : 42))
            .clamp(1.0, double.infinity);
        for (final action in widget.actions) {
          final painter = TextPainter(
            text: TextSpan(text: context.tr(action.label), style: textStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: labelWidth);
          if (painter.height + 24 > rowHeight) {
            rowHeight = painter.height + 24;
          }
          painter.dispose();
        }
        final availableHeight = (safeBottom - safeTop).clamp(
          0.0,
          double.infinity,
        );
        final height =
            (rowHeight * widget.actions.length +
                    (widget.actions.length - 1) * 8 +
                    26)
                .clamp(0.0, availableHeight);
        final left = widget.anchor.left.clamp(
          safeLeft,
          (safeRight - width).clamp(safeLeft, double.infinity),
        );
        final preferredTop = widget.anchor.bottom + 8;
        // Anchor beneath More when possible, otherwise lift the same compact
        // overlay inside the safe screen bounds without moving page content.
        final top = preferredTop.clamp(
          safeTop,
          (safeBottom - height).clamp(safeTop, double.infinity),
        );
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              height: height,
              child: Semantics(
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                label: context.tr('More options'),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    key: const ValueKey('anime-details-more-menu'),
                    padding: const EdgeInsets.all(12),
                    decoration: _episodePanelDecoration(palette),
                    // Let focused rows glow into the panel padding, while
                    // keeping scrolled-off rows inside the rounded housing.
                    clipBehavior: Clip.antiAlias,
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: SingleChildScrollView(
                        clipBehavior: Clip.none,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (
                              var index = 0;
                              index < widget.actions.length;
                              index++
                            ) ...[
                              if (index > 0) const SizedBox(height: 8),
                              FocusTraversalOrder(
                                order: NumericFocusOrder(index.toDouble()),
                                child: TvFocusable(
                                  key: ValueKey(
                                    'anime-details-${widget.actions[index].id}',
                                  ),
                                  focusNode: _nodes[index],
                                  autofocus: index == 0,
                                  focusScale: 1,
                                  onKeyEvent: (_, event) =>
                                      _handleKey(index, event),
                                  onPressed: () => _close(index),
                                  child: Container(
                                    key: ValueKey(
                                      'anime-details-${widget.actions[index].id}-surface',
                                    ),
                                    height: rowHeight,
                                    // Opaque row interiors keep the shared
                                    // outer glow from tinting their contents.
                                    decoration: TetoBoxStyle.decoration(
                                      palette,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          widget.actions[index].icon,
                                          size: widget.large ? 24 : 22,
                                          color: palette.primaryText,
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Text(
                                            context.tr(
                                              widget.actions[index].label,
                                            ),
                                            style: textStyle,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Icon(
                                          Icons.chevron_right_rounded,
                                          size: widget.large ? 22 : 20,
                                          color: palette.mutedText,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// This screen sits over artwork, so its cards let the backdrop show through.
// Keep the text, icons and outer TV focus treatment at full opacity.
BoxDecoration _episodePanelDecoration(AppThemePalette palette) =>
    TetoBoxStyle.translucentPanelDecoration(palette);

double _episodeSecondaryActionHeight(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= 1500 ? 68 : (size.height >= 620 ? 49 : 42);
}

BoxDecoration _episodeControlDecoration(AppThemePalette palette) =>
    TetoBoxStyle.translucentControlDecoration(palette);

class _PersonalWatchProgress extends StatelessWidget {
  const _PersonalWatchProgress({
    required this.watchedEpisodes,
    required this.totalEpisodes,
    required this.large,
    this.informationAction,
  });

  final int watchedEpisodes;
  final int? totalEpisodes;
  final bool large;
  final _InformationActions? informationAction;

  @override
  Widget build(BuildContext context) {
    final total = totalEpisodes != null && totalEpisodes! > 0
        ? totalEpisodes
        : null;
    final watched = total == null
        ? (watchedEpisodes < 0 ? 0 : watchedEpisodes)
        : watchedEpisodes.clamp(0, total);
    final label = total == null
        ? context.tr('Watched {value1} episodes', {'value1': watched})
        : context.tr('Watched {value1} of {value2}', {
            'value1': watched,
            'value2': total,
          });
    final palette = context.appPalette;
    final labelStyle = Theme.of(context).textTheme.labelLarge!.copyWith(
      color: palette.mutedText,
      fontSize: large ? 13 : 11,
      fontWeight: FontWeight.w600,
    );
    final progressLabel = Semantics(
      label: label,
      child: ExcludeSemantics(child: Text(label, style: labelStyle)),
    );
    return Column(
      key: const ValueKey('anime-details-watch-progress'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (informationAction case final action?)
          LayoutBuilder(
            builder: (context, constraints) {
              final painter = TextPainter(
                text: TextSpan(text: label, style: labelStyle),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout();
              final fits =
                  painter.width + 12 + action.preferredButtonWidth(context) <=
                  constraints.maxWidth;
              painter.dispose();
              if (!fits) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    progressLabel,
                    const SizedBox(height: 6),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: action,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: progressLabel),
                  const SizedBox(width: 12),
                  action,
                ],
              );
            },
          )
        else
          progressLabel,
        if (total != null) ...[
          const SizedBox(height: 5),
          ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                key: const ValueKey('anime-details-watched-progress-bar'),
                value: watched / total,
                minHeight: 3,
                backgroundColor: palette.mutedText.withValues(alpha: .16),
                color: palette.accentBright,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _EpisodeActions extends StatelessWidget {
  const _EpisodeActions({
    required this.selectedAvailability,
    required this.resumeAvailability,
    required this.autofocusPrimary,
    required this.selectedEpisode,
    required this.titlePreference,
    required this.resumeEpisode,
    required this.totalEpisodes,
    required this.isTelevision,
    required this.watchedEpisodes,
    required this.catalogEpisodeCount,
    required this.informationAction,
    required this.hasProgress,
    required this.guestInWatchParty,
    required this.resumeProgress,
    required this.resumeIsFiller,
    required this.selectedIsFiller,
    required this.onBrowseEpisodes,
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
    required this.browseEpisodesFocusNode,
    required this.showWatchPartyAction,
    required this.onWatchPartyPressed,
  });

  final EpisodeAiringAvailability selectedAvailability;
  final EpisodeAiringAvailability resumeAvailability;
  final bool autofocusPrimary;
  final int selectedEpisode;
  final TitleLanguagePreference titlePreference;
  final int resumeEpisode;
  final int totalEpisodes;
  final int watchedEpisodes;
  final int? catalogEpisodeCount;
  final _InformationActions? informationAction;
  final bool isTelevision;
  final bool hasProgress;
  final bool guestInWatchParty;
  final double? resumeProgress;
  final bool resumeIsFiller;
  final bool selectedIsFiller;
  final VoidCallback? onBrowseEpisodes;
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
  final FocusNode browseEpisodesFocusNode;
  final bool showWatchPartyAction;
  final VoidCallback? onWatchPartyPressed;

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.sizeOf(context).width >= 1500;
    final roomy = MediaQuery.sizeOf(context).height >= 620;
    return Container(
      key: const ValueKey('episode-actions-panel'),
      width: double.infinity,
      padding: EdgeInsets.all(large ? 16 : (roomy ? 9 : 8)),
      decoration: _episodePanelDecoration(context.appPalette),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PersonalWatchProgress(
            watchedEpisodes: watchedEpisodes,
            totalEpisodes: catalogEpisodeCount,
            large: large,
            informationAction: informationAction,
          ),
          SizedBox(height: large ? 12 : 8),
          if (!guestInWatchParty) ...[
            if (resumeAvailability.isAvailable ||
                selectedAvailability.isAvailable) ...[
              _EpisodeActionButton(
                key: const ValueKey('episode-action-resume'),
                label: !resumeAvailability.isAvailable
                    ? _unavailableEpisodeActionLabel(
                        context,
                        resumeAvailability,
                      )
                    : hasProgress
                    ? context.tr('Resume Eps {value1}', {
                        'value1': resumeEpisode,
                      })
                    : 'Start watching',
                semanticsLabel: resumeAvailability.isAvailable && hasProgress
                    ? context.tr('Resume Episode {value1}', {
                        'value1': resumeEpisode,
                      })
                    : null,
                trailing: resumeAvailability.isAvailable && hasProgress
                    ? context.tr('{value1} of {value2}', {
                        'value1': resumeEpisode,
                        'value2': totalEpisodes,
                      })
                    : null,
                badge: resumeIsFiller ? 'FILLER' : null,
                progress: resumeProgress,
                icon: EpisodePanelGlyph.play,
                primary: true,
                autofocus: resumeAvailability.isAvailable && autofocusPrimary,
                onPressed: onResume,
                large: large,
              ),
              SizedBox(height: large ? 14 : (roomy ? 8 : 6)),
            ],
            if (!selectedAvailability.isAvailable) ...[
              _EpisodeAiringNotice(
                availability: selectedAvailability,
                large: large,
              ),
              SizedBox(height: large ? 14 : (roomy ? 8 : 6)),
            ] else ...[
              if (hasProgress) ...[
                _EpisodeActionButton(
                  key: const ValueKey('episode-action-restart'),
                  label: 'Play from beginning',
                  icon: EpisodePanelGlyph.replay,
                  onPressed: onPlayFromBeginning,
                  large: large,
                ),
                SizedBox(height: large ? 14 : (roomy ? 8 : 6)),
              ],
              if (selectedEpisode != resumeEpisode ||
                  !resumeAvailability.isAvailable) ...[
                _EpisodeActionButton(
                  key: const ValueKey('episode-action-selected'),
                  label: 'Play selected',
                  trailing: 'EP-$selectedEpisode',
                  badge: selectedIsFiller ? 'FILLER' : null,
                  icon: EpisodePanelGlyph.skip,
                  onPressed: onPlaySelected,
                  large: large,
                ),
                SizedBox(height: large ? 14 : (roomy ? 8 : 6)),
              ],
            ],
          ],
          if (onBrowseEpisodes != null) ...[
            SizedBox(height: large ? 14 : (roomy ? 8 : 6)),
            _EpisodeBrowserPrompt(
              isTelevision: isTelevision,
              large: large,
              onPressed: onBrowseEpisodes!,
              focusNode: browseEpisodesFocusNode,
            ),
          ],
          Divider(
            color: TetoBoxStyle.outline(context.appPalette),
            height: large ? 32 : (roomy ? 22 : 18),
          ),
          _EpisodeActionButton(
            key: const ValueKey('episode-action-manage-list'),
            label: 'My List',
            icon: EpisodePanelGlyph.add,
            trailingIcon: EpisodePanelGlyph.next,
            onPressed: onManageList,
            large: large,
          ),
          SizedBox(height: large ? 14 : (roomy ? 8 : 6)),
          _EpisodeToggleButton(
            key: const ValueKey('episode-action-skip-filler'),
            value: skipFillerEpisodes,
            onPressed: onToggleSkipFiller,
            focusNode: skipFillerFocusNode,
            onExitDown: watchPartyState.session?.role == WatchPartyRole.host
                ? () {
                    for (final node in <FocusNode>[browseEpisodesFocusNode]) {
                      if (node.context != null && node.canRequestFocus) {
                        node.requestFocus();
                        return;
                      }
                    }
                  }
                : null,
            large: large,
          ),
          if (showWatchPartyAction) ...[
            SizedBox(height: large ? 14 : (roomy ? 8 : 6)),
            _EpisodeWatchPartyAction(
              key: const ValueKey('episode-action-watch-together'),
              state: watchPartyState,
              starting: watchPartyStarting,
              focusNode: watchPartyFocusNode,
              onPressed: onWatchPartyPressed,
              fallbackEpisode: selectedEpisode,
              titlePreference: titlePreference,
              large: large,
            ),
          ],
        ],
      ),
    );
  }
}

class _EpisodeBrowserPrompt extends StatelessWidget {
  const _EpisodeBrowserPrompt({
    required this.isTelevision,
    required this.large,
    required this.onPressed,
    required this.focusNode,
  });

  final bool isTelevision;
  final bool large;
  final VoidCallback onPressed;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final gestureHint = isTelevision
        ? context.tr('Browse all episodes')
        : context.tr('Swipe up or tap to browse all episodes');
    return Semantics(
      label: gestureHint,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -180) onPressed();
        },
        child: TvFocusable(
          onPressed: onPressed,
          focusNode: focusNode,
          focusScale: 1.018,
          borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
          child: Container(
            key: const ValueKey('episode-browser-prompt'),
            height: large
                ? 68
                : (MediaQuery.sizeOf(context).height >= 620 ? 50 : 44),
            padding: EdgeInsets.symmetric(horizontal: large ? 22 : 13),
            decoration: _episodeControlDecoration(palette),
            child: Row(
              children: [
                EpisodePanelIcon(
                  glyph: EpisodePanelGlyph.browse,
                  color: palette.primaryText,
                  size: large ? 27 : 19,
                ),
                SizedBox(width: large ? 16 : 8),
                Expanded(
                  child: Text(
                    context.tr('Browse all episodes'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.primaryText,
                      fontSize: large ? 18 : 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                EpisodePanelIcon(
                  glyph: EpisodePanelGlyph.next,
                  color: palette.mutedText,
                  size: large ? 25 : 19,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeAiringNotice extends StatelessWidget {
  const _EpisodeAiringNotice({required this.availability, required this.large});

  final EpisodeAiringAvailability availability;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final isSeries =
        availability.kind == EpisodeAiringAvailabilityKind.seriesUnaired;
    final title = isSeries
        ? context.tr('This series has not aired yet.')
        : context.tr('Episode {episode} has not aired yet.', {
            'episode': availability.episode ?? 1,
          });
    final expectedAt = availability.expectedAt;
    final dateLabel = expectedAt == null
        ? null
        : context.tr(
            isSeries
                ? 'Expected premiere date: {date}'
                : 'Expected air date: {date}',
            {'date': TetoLocalizations.of(context).date(expectedAt)},
          );
    return Semantics(
      liveRegion: true,
      label: dateLabel == null ? title : '$title $dateLabel',
      child: Container(
        key: const ValueKey('episode-unavailable-notice'),
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: large ? 18 : 12,
          vertical: large ? 14 : 9,
        ),
        decoration: BoxDecoration(
          color: context.appPalette.accent.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: context.appPalette.accentBright.withValues(alpha: .62),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.schedule_rounded,
              color: context.appPalette.accentBright,
              size: large ? 26 : 19,
            ),
            SizedBox(width: large ? 12 : 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: context.appPalette.primaryText,
                      fontSize: large ? 16 : 12,
                      height: 1.15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (dateLabel != null) ...[
                    SizedBox(height: large ? 6 : 3),
                    Text(
                      dateLabel,
                      style: TextStyle(
                        color: context.appPalette.mutedText,
                        fontSize: large ? 13 : 10,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _unavailableEpisodeActionLabel(
  BuildContext context,
  EpisodeAiringAvailability availability,
) => switch (availability.kind) {
  EpisodeAiringAvailabilityKind.seriesUnaired => context.tr('Not aired yet'),
  EpisodeAiringAvailabilityKind.episodeUnaired => context.tr(
    'Episode {episode} has not aired yet',
    {'episode': availability.episode ?? 1},
  ),
  EpisodeAiringAvailabilityKind.available => context.tr('Start watching'),
};

String? _animeDetailsStatusText(
  BuildContext context,
  AnimeSummary anime,
  DateTime now,
) {
  final rawStatus = anime.status?.trim();
  if (rawStatus == null || rawStatus.isEmpty) return null;
  final status = rawStatus
      .replaceAll(RegExp(r'[\s_-]+'), ' ')
      .toLowerCase()
      .split(' ')
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
  final countdown = localizedNextEpisodeCountdown(context, anime, now: now);
  final nextAiringAt = anime.nextAiringAt;
  if (countdown == null || nextAiringAt == null) return context.tr(status);
  return '${context.tr(status)} · $countdown · ${TetoLocalizations.of(context).date(nextAiringAt)}';
}

class _EpisodeWatchPartyAction extends StatelessWidget {
  const _EpisodeWatchPartyAction({
    super.key,
    required this.state,
    required this.starting,
    required this.focusNode,
    required this.onPressed,
    required this.fallbackEpisode,
    required this.titlePreference,
    required this.large,
  });

  final WatchPartyState state;
  final bool starting;
  final FocusNode focusNode;
  final VoidCallback? onPressed;
  final int fallbackEpisode;
  final TitleLanguagePreference titlePreference;
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
      height: large ? 76 : (MediaQuery.sizeOf(context).height >= 620 ? 49 : 42),
      padding: EdgeInsets.symmetric(horizontal: large ? 22 : 13),
      decoration: _episodeControlDecoration(context.appPalette),
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
                EpisodePanelIcon(
                  glyph: EpisodePanelGlyph.people,
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
                            ? context.tr("Episode {value1}", {
                                'value1': episode,
                              })
                            : context.tr("{value1} • Episode {value2}", {
                                'value1': media.displayTitle(titlePreference),
                                'value2': episode,
                              }),
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
                          context.tr("Leave Party"),
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
                    starting
                        ? context.tr("Starting…")
                        : context.tr("Start Watch Party"),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.appPalette.primaryText,
                      fontSize: large ? 18 : 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              if (!active && !starting)
                EpisodePanelIcon(
                  glyph: EpisodePanelGlyph.next,
                  size: large ? 25 : 19,
                  color: context.appPalette.mutedText,
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
              borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
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
          label: context.tr("{value1} people in this Watch Party room", {
            'value1': participants.length,
          }),
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
    this.onExitDown,
    required this.large,
  });

  final bool value;
  final VoidCallback? onPressed;
  final FocusNode focusNode;
  final VoidCallback? onExitDown;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final content = Container(
      height: large ? 76 : (MediaQuery.sizeOf(context).height >= 620 ? 49 : 42),
      padding: EdgeInsets.symmetric(horizontal: large ? 22 : 13),
      decoration: _episodeControlDecoration(context.appPalette),
      child: Row(
        children: [
          EpisodePanelIcon(
            glyph: EpisodePanelGlyph.skip,
            size: large ? 29 : 19,
            color: context.appPalette.primaryText,
          ),
          SizedBox(width: large ? 16 : 8),
          Expanded(
            child: Text(
              context.tr("Skip filler"),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.appPalette.primaryText,
                fontSize: large ? 18 : 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          TetoSwitchIndicator(value: value, compact: !large),
        ],
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      toggled: value,
      label: context.tr("Skip filler"),
      child: enabled
          ? TvFocusable(
              focusNode: focusNode,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.arrowDown &&
                    onExitDown != null) {
                  onExitDown!();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              focusScale: 1.025,
              borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
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
    this.semanticsLabel,
    this.trailing,
    this.badge,
    this.trailingIcon,
    this.progress,
    this.primary = false,
    this.autofocus = false,
    this.large = false,
  });

  final String label;
  final String? semanticsLabel;
  final String? trailing;
  final String? badge;
  final EpisodePanelGlyph? trailingIcon;
  final double? progress;
  final EpisodePanelGlyph icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool autofocus;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final palette = context.appPalette;
    final showProgress = primary && progress != null && progress! > 0;
    final labelText = Text(
      context.tr(label),
      semanticsLabel: semanticsLabel,
      maxLines: 1,
      softWrap: false,
      overflow: primary ? TextOverflow.visible : TextOverflow.ellipsis,
      style: TextStyle(
        color: palette.primaryText,
        fontSize: large ? 18 : 14,
        fontWeight: FontWeight.w800,
      ),
    );
    final content = Container(
      height: primary
          ? (large ? 82 : (MediaQuery.sizeOf(context).height >= 620 ? 55 : 48))
          : _episodeSecondaryActionHeight(context),
      padding: EdgeInsets.symmetric(horizontal: large ? 22 : 13),
      decoration: primary
          ? BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  palette.accent,
                  Color.alphaBlend(
                    Colors.black.withValues(alpha: .16),
                    palette.accent,
                  ),
                ],
              ),
              borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
              border: Border.all(color: TetoBoxStyle.outline(palette)),
            )
          : _episodeControlDecoration(palette),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            children: [
              EpisodePanelIcon(
                glyph: icon,
                size: large ? 29 : 19,
                color: palette.primaryText,
              ),
              SizedBox(width: large ? 16 : 8),
              Expanded(
                child: primary
                    ? FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: labelText,
                      )
                    : labelText,
              ),
              if (badge case final value?) ...[
                Container(
                  margin: EdgeInsets.only(right: large ? 12 : 7),
                  padding: EdgeInsets.symmetric(
                    horizontal: large ? 9 : 6,
                    vertical: large ? 5 : 3,
                  ),
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: .24),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    value,
                    style: TextStyle(
                      color: palette.accentBright,
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
                    color: palette.primaryText.withValues(alpha: .8),
                    fontSize: large ? 14 : 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              if (trailingIcon case final value?) ...[
                if (trailing != null) SizedBox(width: large ? 10 : 6),
                EpisodePanelIcon(
                  glyph: value,
                  size: large ? 25 : 19,
                  color: palette.mutedText,
                ),
              ],
            ],
          ),
          if (showProgress)
            Positioned(
              left: large ? 68 : 40,
              right: large ? 22 : 13,
              bottom: large ? 9 : 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  key: const ValueKey('episode-resume-progress'),
                  value: progress!.clamp(0.0, 1.0),
                  minHeight: large ? 3 : 2,
                  backgroundColor: palette.primaryText.withValues(alpha: .25),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    palette.primaryText,
                  ),
                ),
              ),
            ),
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
      borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
      onPressed: onPressed!,
      child: content,
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
    return TetoBackButton(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
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
            child: TetoBrowseStatus(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load anime',
              message: message,
              actions: TetoRetryButton(onPressed: onRetry),
            ),
          ),
        ],
      ),
    );
  }
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
    anime.titleNative,
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
        if (anime.titleNative != null) 'titleNative': anime.titleNative!,
        if (anime.status != null) 'status': anime.status!,
        if (anime.format != null) 'format': anime.format!,
        if (anime.episodes != null) 'episodeCount': '${anime.episodes}',
        if (anime.isAdult) 'isAdult': '1',
      },
    ).toString(),
  );
}
