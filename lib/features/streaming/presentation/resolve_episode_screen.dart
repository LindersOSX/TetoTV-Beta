import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/core/diagnostics/anonymous_crash_reporter.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/local_media/application/library_episode_source_service.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/downloads/application/downloaded_episode_source_service.dart';
import 'package:anime_tv/features/downloads/application/offline_catalog_providers.dart';
import 'package:anime_tv/features/downloads/data/android_direct_peer_download_worker.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/downloaded_episode_asset.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/player/presentation/library_tv_player_screen.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/debrid_resolver_factory.dart';
import 'package:anime_tv/features/streaming/application/debrid_token_service.dart';
import 'package:anime_tv/features/streaming/application/episode_release_search_cache.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/data/direct_torrent_stream_resolver.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:crypto/crypto.dart';

export 'package:anime_tv/features/streaming/application/episode_release_search_cache.dart'
    show configuredReleaseSourceProvider;

typedef DebridStreamResolverFactory =
    StreamResolver Function({
      required DebridService service,
      required String token,
      required ReleaseSource source,
    });

final debridStreamResolverFactoryProvider =
    Provider<DebridStreamResolverFactory>((_) {
      return createDebridStreamResolver;
    });

typedef DirectTorrentStreamResolverFactory =
    StreamResolver Function({required ReleaseSource source});

final directTorrentStreamResolverFactoryProvider =
    Provider<DirectTorrentStreamResolverFactory>((_) {
      return ({required ReleaseSource source}) =>
          DirectTorrentStreamResolver(source);
    });

typedef DirectTorrentCapabilityReader =
    Future<DirectTorrentCapability> Function();

final directTorrentCapabilityReaderProvider =
    Provider<DirectTorrentCapabilityReader>((_) {
      return AndroidTvBridge.instance.getDirectTorrentCapability;
    });

String offlineDownloadPreparationMessage(Object error) {
  if (error is DebridProviderFailure ||
      error is DebridCacheMissException ||
      error is DebridCleanupFailureException) {
    return error.toString();
  }
  if (error is TimeoutException) {
    return 'The source provider took too long to prepare this download. Try again shortly.';
  }
  return 'This source could not be prepared for download. Try another source or check your streaming accounts.';
}

/// Provider availability, cache misses, throttling, and cleanup confirmation
/// failures are expected operational playback outcomes. They remain in the
/// bounded provider/playback diagnostics, but must not be mislabeled as an app
/// process crash by the anonymous handled-error reporter.
bool shouldRecordResolveCrashReport(Object error) =>
    error is! DebridProviderFailure &&
    error is! DebridCacheMissException &&
    error is! DebridCleanupFailureException;

String offlineDownloadPreparationReasonCode(Object error) {
  if (error is RealDebridException) {
    return 'real_debrid_${error.kind.name}';
  }
  if (error is DebridProviderFailure) {
    return 'debrid_${error.failureCategory.name}';
  }
  if (error is DebridCacheMissException) return 'debrid_cache_miss';
  if (error is DebridCleanupFailureException) return 'debrid_cleanup';
  if (error is TimeoutException) return 'timeout';
  if (error is FormatException) return 'invalid_response';
  return 'unexpected';
}

final webStreamPreflightProvider = Provider<WebStreamPreflight>(
  (_) => const WebStreamValidator().validate,
);

String _opaqueWebStreamIdentity(WebStreamResult stream) => sha256
    .convert(
      utf8.encode('${webStreamProviderIdentity(stream)}\u0000${stream.uri}'),
    )
    .toString();

String _boundedDiagnosticField(Object? value) {
  final safe = '${value ?? 'unknown'}'
      .replaceAll(RegExp(r'[^A-Za-z0-9._:-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  return safe.length <= 80 ? safe : safe.substring(0, 80);
}

typedef LibraryPlaybackRouteOpener =
    Future<LibraryPlaybackResult?> Function(
      BuildContext context,
      LibraryPlaybackRequest request, {
      required bool automatic,
    });

final libraryPlaybackRouteOpenerProvider = Provider<LibraryPlaybackRouteOpener>(
  (_) => _openLibraryPlaybackRoute,
);

Future<LibraryPlaybackResult?> _openLibraryPlaybackRoute(
  BuildContext context,
  LibraryPlaybackRequest request, {
  required bool automatic,
}) async {
  LibraryPlaybackResult? result;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      settings: const RouteSettings(name: 'library-episode-player'),
      builder: (_) => LibraryTvPlayerScreen(
        request: request,
        onPlaybackFinished: (value) => result = value,
        autoCloseOnPreparationFailure: automatic,
      ),
    ),
  );
  return result;
}

enum LibraryPlaybackRecoveryAction { finish, retryCompatibility, advanceSource }

LibraryPlaybackRecoveryAction libraryPlaybackRecoveryAction({
  required LibraryPlaybackResult? result,
  required bool supportsCompatibilityTranscode,
  required bool usedCompatibilityStream,
}) {
  if (result == null || !result.failed) {
    return LibraryPlaybackRecoveryAction.finish;
  }
  if (result.failureStage == LibraryPlaybackFailureStage.preparation) {
    return LibraryPlaybackRecoveryAction.advanceSource;
  }
  if (supportsCompatibilityTranscode && !usedCompatibilityStream) {
    return LibraryPlaybackRecoveryAction.retryCompatibility;
  }
  return LibraryPlaybackRecoveryAction.advanceSource;
}

class _LibraryPlaybackStartupException implements Exception {
  const _LibraryPlaybackStartupException();

  @override
  String toString() => 'Private library playback failed to start.';
}

typedef SeriesPreferencesWriter =
    Future<void> Function(int mediaId, SeriesPlaybackPreferences preferences);
typedef SeriesPreferencesReader =
    Future<SeriesPlaybackPreferences> Function(int mediaId);
typedef ResolveDeviceProfileReader = Future<TvDeviceProfile> Function();
typedef ResolveFailureCountsReader =
    Future<Map<String, int>> Function(String deviceKey);

final seriesPreferencesReaderProvider = Provider<SeriesPreferencesReader>(
  (_) => TetoTvDatabase.instance.seriesPreferences,
);

final seriesPreferencesWriterProvider = Provider<SeriesPreferencesWriter>(
  (_) => TetoTvDatabase.instance.saveSeriesPreferences,
);

final resolveDeviceProfileReaderProvider = Provider<ResolveDeviceProfileReader>(
  (_) => AndroidTvBridge.instance.getDeviceProfile,
);

final resolveFailureCountsReaderProvider = Provider<ResolveFailureCountsReader>(
  (_) => TetoTvDatabase.instance.failureCounts,
);

int tvPlaybackCompatibilityRank(
  ReleaseCandidate release, {
  TvDeviceProfile? device,
  int previousFailures = 0,
}) {
  return tvPlaybackCompatibilityScore(
    release,
    device: device,
    previousFailures: previousFailures,
  );
}

bool isTvSafeRelease(ReleaseCandidate release) =>
    tvPlaybackCompatibilityRank(release) == 0;

String debridCacheExhaustedMessage(DebridService service, int attempted) {
  final releases = attempted == 1 ? 'release' : '$attempted releases';
  return 'No instantly cached ${service.displayName} stream was found after '
      'checking $releases. TetoTV did not leave an uncached cloud download '
      'running.';
}

bool releaseMatchesStreamFilters(
  ReleaseCandidate release, {
  String language = 'all',
  String quality = 'any',
  String codec = 'any',
  String hdr = 'any',
  bool allowBatch = true,
}) {
  return automaticReleaseMatchesFilters(
    release,
    language: language,
    quality: quality,
    codec: codec,
    hdr: hdr,
    allowBatch: allowBatch,
  );
}

int compareStreamReleases(
  ReleaseCandidate left,
  ReleaseCandidate right, {
  TvDeviceProfile? device,
  Map<String, int> failureCounts = const {},
  String sortMode = 'compatibility',
  String? preferredProvider,
  String? preferredReleaseGroup,
  PlaybackAudioPreference? preferredAudio,
  DebridStreamSort? rankingPreference,
}) {
  return compareAutomaticStreamReleases(
    left,
    right,
    device: device,
    failureCounts: failureCounts,
    sortMode: sortMode,
    preferredProvider: preferredProvider,
    preferredReleaseGroup: preferredReleaseGroup,
    preferredAudio: preferredAudio,
    rankingPreference: rankingPreference,
  );
}

int webStreamQualityRank(WebStreamResult stream) =>
    automaticWebStreamQualityRank(stream);

int compareWebStreamsByQuality(WebStreamResult left, WebStreamResult right) {
  return compareAutomaticWebStreamsByQuality(left, right);
}

int compareWebStreamsByAudioAndQuality(
  WebStreamResult left,
  WebStreamResult right,
  PlaybackAudioPreference preferredAudio,
) {
  return compareAutomaticWebStreamsByAudioAndQuality(
    left,
    right,
    preferredAudio,
  );
}

Iterable<String> _localStreamSearchTerms(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .map((term) => term.trim())
    .where((term) => term.isNotEmpty);

bool releaseMatchesLocalStreamSearch(ReleaseCandidate release, String query) {
  final terms = _localStreamSearchTerms(query);
  if (terms.isEmpty) return true;
  final searchable = [
    release.releaseName,
    release.provider,
    release.sourceId,
    release.quality,
    release.codec,
    release.sizeLabel,
    release.isDubbed ? 'dub dubbed dual audio' : 'sub subtitled',
    if (release.hasSubtitles) 'subtitles captions',
    if (release.isHdr) 'hdr',
    if (release.isBatch) 'batch',
    if (release.seeders > 0) '${release.seeders} seeders',
  ].whereType<String>().join(' ').toLowerCase();
  return terms.every(searchable.contains);
}

bool webStreamMatchesLocalSearch(WebStreamResult stream, String query) {
  final terms = _localStreamSearchTerms(query);
  if (terms.isEmpty) return true;
  final searchable = [
    stream.title,
    stream.providerName,
    stream.providerId,
    stream.quality,
    stream.subtitleLanguage,
    stream.uri.host,
    switch (stream.effectiveAudioCapability) {
      WebStreamAudioCapability.sub => 'sub subtitled',
      WebStreamAudioCapability.dub => 'dub dubbed english audio',
      WebStreamAudioCapability.subAndDub => 'sub dub dubbed dual multi audio',
      WebStreamAudioCapability.unknown => 'audio unknown',
    },
    if (stream.subtitleUri != null) 'subtitles captions',
  ].whereType<String>().join(' ').toLowerCase();
  return terms.every(searchable.contains);
}

bool libraryStreamMatchesLocalSearch(
  LibraryEpisodeSource source,
  String query,
) {
  final terms = _localStreamSearchTerms(query);
  if (terms.isEmpty) return true;
  final searchable = [
    source.title,
    source.subtitle,
    source.origin.name,
    'local library your media',
  ].join(' ').toLowerCase();
  return terms.every(searchable.contains);
}

bool downloadedStreamMatchesLocalSearch(
  DownloadedEpisodeAsset source,
  String query,
) {
  final terms = _localStreamSearchTerms(query);
  if (terms.isEmpty) return true;
  final job = source.job;
  final searchable = [
    job.seriesTitle,
    job.episodeTitle,
    job.sourceLabel,
    job.providerName,
    job.quality,
    job.audioLabel,
    'download downloaded offline local episode ${job.episode}',
  ].whereType<String>().join(' ').toLowerCase();
  return terms.every(searchable.contains);
}

/// A stable, episode-scoped revision for reacting to finished downloads.
///
/// Progress updates for unrelated, queued, or failed jobs intentionally do
/// not rebuild the source picker. A completed matching row does, including
/// changes made while this screen is already open.
String completedDownloadRevisionForEpisode(
  DownloadManagerState state, {
  required int anilistMediaId,
  required int episode,
  int? malMediaId,
  Iterable<String> seriesTitles = const [],
}) {
  final revisions = <String>[
    for (final job in state.jobs)
      if (job.status == DownloadJobStatus.completed &&
          downloadedJobMatchesEpisodeIdentity(
            job,
            anilistMediaId: anilistMediaId,
            malMediaId: malMediaId,
            episode: episode,
            seriesTitles: seriesTitles,
          ))
        '${job.id}|${job.updatedAt.microsecondsSinceEpoch}|'
            '${job.relativePath}|${job.expectedBytes}|${job.receivedBytes}',
  ]..sort();
  return '${state.initialized}|${revisions.join(';')}';
}

/// External caption sidecars are not yet materialized by the offline worker.
/// Block these sources instead of saving an apparently subtitled video that
/// becomes unwatchable without its remote VTT/ASS file.
bool webStreamRequiresExternalSubtitleDownload(WebStreamResult stream) =>
    stream.subtitleUri != null;

/// Ranks automatic next-episode web candidates without changing the manual
/// picker order. The viewer's audio choice remains authoritative; within the
/// matching audio class, the exact provider used by the previous episode wins.
int compareAutoplayWebStreams(
  WebStreamResult left,
  WebStreamResult right, {
  required PlaybackAudioPreference preferredAudio,
  String? preferredWebProviderId,
  int? preferredQualityHeight,
  WebStreamQualityPreference qualityPreference =
      WebStreamQualityPreference.bestAvailable,
}) {
  return compareAutomaticAutoplayWebStreams(
    left,
    right,
    preferredAudio: preferredAudio,
    preferredWebProviderId: preferredWebProviderId,
    preferredQualityHeight: preferredQualityHeight,
    qualityPreference: qualityPreference,
  );
}

/// Automatic next-episode release affinity is deliberately stricter than the
/// manual picker preference: same provider or stable source + author/group,
/// then provider/source, author-only, and finally the existing global rank.
int compareAutoplayReleases(
  ReleaseCandidate left,
  ReleaseCandidate right, {
  TvDeviceProfile? device,
  Map<String, int> failureCounts = const {},
  String sortMode = 'compatibility',
  String? preferredProvider,
  String? preferredAuthor,
  String? preferredSourceId,
  String? existingPreferredProvider,
  String? existingPreferredReleaseGroup,
  PlaybackAudioPreference? preferredAudio,
  DebridStreamSort? rankingPreference,
  int? preferredQualityHeight,
}) {
  return compareAutomaticAutoplayReleases(
    left,
    right,
    device: device,
    failureCounts: failureCounts,
    sortMode: sortMode,
    preferredProvider: preferredProvider,
    preferredAuthor: preferredAuthor,
    preferredSourceId: preferredSourceId,
    existingPreferredProvider: existingPreferredProvider,
    existingPreferredReleaseGroup: existingPreferredReleaseGroup,
    preferredAudio: preferredAudio,
    rankingPreference: rankingPreference,
    preferredQualityHeight: preferredQualityHeight,
  );
}

String? _normalizedProviderHint(String? value) =>
    _boundedHint(value, maxLength: 160)?.toLowerCase();

String? _normalizedAuthorHint(String? value) {
  final hint = _boundedHint(value, maxLength: 96);
  if (hint == null) return null;
  final extracted = releaseGroupKey(hint);
  if (extracted != null) return extracted;
  final normalized = hint
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return normalized.isEmpty ? null : normalized;
}

String? _boundedHint(String? value, {required int maxLength}) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed.length > maxLength) {
    return null;
  }
  return trimmed;
}

T _enumByName<T extends Enum>(List<T> values, String name, T fallback) {
  return values.where((value) => value.name == name).firstOrNull ?? fallback;
}

class _AutoplayCandidateTier {
  const _AutoplayCandidateTier({
    this.releases = const [],
    this.web = const [],
    this.library = const [],
    this.waiting = false,
  });

  final List<ReleaseCandidate> releases;
  final List<WebStreamResult> web;
  final List<LibraryEpisodeSource> library;
  final bool waiting;
}

class ResolveEpisodeScreen extends ConsumerStatefulWidget {
  const ResolveEpisodeScreen({
    required this.episode,
    this.preferredProvider,
    this.preferredAuthor,
    this.preferredSourceId,
    this.preferredWebProviderId,
    this.preferredQualityHeight,
    this.preferredAudio,
    this.watchPartyFollow = false,
    this.watchPartySourceClass,
    this.watchPartySourceFingerprint,
    this.watchPartySourceKey,
    this.clock = DateTime.now,
    super.key,
  });

  final EpisodeReference episode;
  final String? preferredProvider;
  final String? preferredAuthor;
  final String? preferredSourceId;
  final String? preferredWebProviderId;
  final int? preferredQualityHeight;
  final PlaybackAudioPreference? preferredAudio;
  final bool watchPartyFollow;
  final String? watchPartySourceClass;
  final String? watchPartySourceFingerprint;
  final String? watchPartySourceKey;
  final DateTime Function() clock;

  @override
  ConsumerState<ResolveEpisodeScreen> createState() =>
      _ResolveEpisodeScreenState();
}

class _ResolveEpisodeScreenState extends ConsumerState<ResolveEpisodeScreen> {
  final _magnetController = TextEditingController();
  final _streamSearchController = TextEditingController();
  final _streamSearchFocusNode = FocusNode(debugLabel: 'stream-picker.search');
  bool _loadingAccount = true;
  bool _loadingReleases = false;
  bool _resolving = false;
  bool _showManual = false;
  bool _showAdvancedFilters = false;
  String _streamSearchQuery = '';
  double _progress = 0;
  String _status = 'Preparing…';
  String? _error;
  List<ReleaseCandidate> _releases = const [];
  List<WebStreamResult> _webStreams = const [];
  List<WebProviderFailure> _webFailures = const [];
  List<ReleaseSourceFailure> _releaseFailures = const [];
  List<LibraryEpisodeSource> _librarySources = const [];
  DownloadedEpisodeAsset? _downloadedAsset;
  List<String> _libraryFailures = const [];
  int _debridSourcesCompleted = 0;
  int _debridSourcesTotal = 0;
  int _webProvidersCompleted = 0;
  int _webProvidersTotal = 0;
  List<String> _pendingDebridSources = const [];
  List<String> _pendingWebProviders = const [];
  int _releaseSearchGeneration = 0;
  int _downloadedAssetRefreshGeneration = 0;
  Set<DebridService> _connectedServices = const {};
  DebridService _debridService = DebridService.realDebrid;
  _StreamLanguageFilter _languageFilter = _StreamLanguageFilter.dub;
  _StreamQualityFilter _qualityFilter = _StreamQualityFilter.any;
  _StreamCodecFilter _codecFilter = _StreamCodecFilter.any;
  _StreamHdrFilter _hdrFilter = _StreamHdrFilter.any;
  _StreamSortMode _sortMode = _StreamSortMode.compatibility;
  bool _allowBatchStreams = true;
  SeriesPlaybackPreferences _seriesPreferences =
      const SeriesPlaybackPreferences();
  TvDeviceProfile _deviceProfile = const TvDeviceProfile.unknown();
  Map<String, int> _failureCounts = const {};
  ReleaseCandidate? _lastAttemptedRelease;
  int _resolveAttempt = 0;
  int _libraryResolveAttempt = 0;
  final Set<String> _failedResolveHashes = {};
  final Set<String> _failedAutoplayWebStreams = {};
  final Set<String> _failedAutoPickLibrarySources = {};
  DateTime? _automaticResolveDeadline;
  bool _autoPlayStarted = false;
  bool _webSearchFinished = false;
  bool _webSearchEnabled = false;
  bool _debridSearchFinished = false;
  bool _debridSearchEnabled = false;
  bool _librarySearchEnabled = false;
  bool _librarySearchFinished = true;
  bool _autoplayDebridExhausted = false;
  bool _autoplayBudgetExhausted = false;
  bool _preferredWebWaitExpired = false;
  bool _autoPickEnabledForOpen = false;
  bool _autoPickManualFallback = false;
  String? _autoPickNotice;
  bool _autoplayManualFallback = false;
  bool _returningFromResolver = false;
  bool _watchPartyDifferentSourceNotified = false;
  bool _directTorrentSupported = false;
  bool _preparingDownload = false;
  Timer? _preferredWebWaitTimer;
  Timer? _autoPickDeadlineTimer;

  static const _maxAutomaticResolveCandidates = 8;
  static const _automaticResolveTimeBudget = Duration(seconds: 45);
  static const _preferredWebProviderWaitBudget = Duration(seconds: 12);

  bool get _hasDebrid =>
      ref.read(settingsPreferencesProvider).debridStreamsEnabled &&
      _connectedServices.contains(_debridService);

  bool get _directTorrentEnabled =>
      ref.read(settingsPreferencesProvider).directTorrentStreamingEnabled &&
      _directTorrentSupported;

  bool get _canPlayTorrentReleases => _hasDebrid || _directTorrentEnabled;

  /// Existing Debrid playback remains the default whenever it is connected.
  /// Direct peer playback is used only when the user explicitly opted in and
  /// there is no usable Debrid account.
  bool get _useDirectTorrent => !_hasDebrid && _directTorrentEnabled;

  SettingsPreferences get _streamPreferences =>
      ref.read(settingsPreferencesProvider);

  bool get _autoPickActive =>
      _autoPickEnabledForOpen && !_autoPickManualFallback;

  bool get _automaticSelectionActive =>
      widget.episode.autoPlay || _autoPickActive;

  /// Keeps one visual shell mounted while cached-release/Web candidates hand
  /// off through microtasks. The individual attempt flags briefly become
  /// false between candidates; rendering the picker/search state in that gap
  /// caused a full-screen flash on TVs.
  bool get _stableResolveShellVisible {
    if (_resolving) return true;
    if (_error != null ||
        _autoPickManualFallback ||
        _autoplayManualFallback ||
        _autoplayBudgetExhausted) {
      return false;
    }
    // Auto Pick owns the opening from the moment account/preferences loading
    // completes. Keeping this shell mounted while discovery chooses its first
    // priority tier prevents a one-frame flash of the manual picker.
    if (_autoPickActive &&
        (_loadingReleases || _autoPlayStarted || _automaticDiscoveryPending)) {
      return true;
    }
    final attemptedCandidate =
        _failedResolveHashes.isNotEmpty ||
        _failedAutoplayWebStreams.isNotEmpty ||
        _failedAutoPickLibrarySources.isNotEmpty;
    return attemptedCandidate &&
        (_automaticSelectionActive ||
            _automaticDiscoveryPending ||
            _lastAttemptedRelease != null);
  }

  bool get _automaticAllowsDebrid =>
      !_autoPickActive ||
      _streamPreferences.effectiveAutoPickSourcePriority.contains(
        AutoPickSourcePriority.debrid,
      );

  bool get _automaticAllowsWeb =>
      !_autoPickActive ||
      _streamPreferences.effectiveAutoPickSourcePriority.contains(
        AutoPickSourcePriority.web,
      );

  bool get _automaticAllowsLibrary =>
      _autoPickActive &&
      _streamPreferences.effectiveAutoPickSourcePriority.contains(
        AutoPickSourcePriority.yourMedia,
      );

  bool get _automaticDebridSearchPending =>
      _automaticAllowsDebrid &&
      !_autoplayDebridExhausted &&
      _debridSearchEnabled &&
      !_debridSearchFinished;

  bool get _automaticWebSearchPending =>
      _automaticAllowsWeb && _webSearchEnabled && !_webSearchFinished;

  bool get _automaticLibrarySearchPending =>
      _automaticAllowsLibrary &&
      _librarySearchEnabled &&
      !_librarySearchFinished;

  bool get _automaticDiscoveryPending =>
      _automaticDebridSearchPending ||
      _automaticWebSearchPending ||
      _automaticLibrarySearchPending;

  WatchPartySourceClass? get _hostSourceClass =>
      switch (widget.watchPartySourceClass) {
        'torrent' => WatchPartySourceClass.torrent,
        'web' => WatchPartySourceClass.web,
        _ => null,
      };

  String? get _hostSourceFingerprint {
    final value = widget.watchPartySourceFingerprint;
    return value != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(value)
        ? value
        : null;
  }

  String? get _hostSourceKey {
    final value = widget.watchPartySourceKey;
    return value != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(value)
        ? value
        : null;
  }

  int get _autoPickFailedAttemptCount =>
      _failedResolveHashes.length +
      _failedAutoplayWebStreams.length +
      _failedAutoPickLibrarySources.length;

  int get _autoPickRemainingAttemptBudget =>
      (_maxAutomaticResolveCandidates - _autoPickFailedAttemptCount).clamp(
        0,
        _maxAutomaticResolveCandidates,
      );

  DebridStreamSort get _debridRanking => switch (_sortMode) {
    _StreamSortMode.compatibility => DebridStreamSort.bestQuality,
    _StreamSortMode.seeders => DebridStreamSort.mostSeeded,
    _StreamSortMode.largest => DebridStreamSort.largestSize,
    _StreamSortMode.size => DebridStreamSort.smallestSize,
  };

  PlaybackAudioPreference get _preferredAudio =>
      widget.preferredAudio ??
      effectivePlaybackAudioPreference(
        globalPreference: ref.read(settingsPreferencesProvider).preferredAudio,
        seriesAudioLanguage: _seriesPreferences.audioLanguage,
        seriesOverride: _seriesPreferences.audioPreferenceSet,
      );

  bool get _offlineDownloadsEnabled =>
      ref.read(settingsPreferencesProvider).offlineDownloadsEnabled;

  PlaybackAudioPreference? get _requestedAudioFromFilter =>
      switch (_languageFilter) {
        _StreamLanguageFilter.all => null,
        _StreamLanguageFilter.sub => PlaybackAudioPreference.sub,
        _StreamLanguageFilter.dub => PlaybackAudioPreference.dub,
      };

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      settingsPreferencesProvider.select(
        (preferences) => preferences.offlineDownloadsEnabled,
      ),
      (previous, next) {
        if (previous == next) return;
        unawaited(_refreshDownloadedAsset());
      },
    );
    ref.listenManual(
      downloadManagerProvider.select(
        (state) => completedDownloadRevisionForEpisode(
          state,
          anilistMediaId: widget.episode.anilistMediaId,
          episode: widget.episode.episode,
          malMediaId: widget.episode.malMediaId,
          seriesTitles: {
            widget.episode.title,
            ?widget.episode.titleEnglish,
            ?widget.episode.titleRomaji,
            ...widget.episode.alternativeTitles,
          },
        ),
      ),
      (previous, next) {
        if (previous == next) return;
        unawaited(_refreshDownloadedAsset());
      },
    );
    unawaited(_initialize());
  }

  Future<DownloadedEpisodeAsset?> _refreshDownloadedAsset() async {
    final generation = ++_downloadedAssetRefreshGeneration;
    if (!_offlineDownloadsEnabled) {
      if (mounted && _downloadedAsset != null) {
        setState(() => _downloadedAsset = null);
      }
      return null;
    }
    DownloadedEpisodeAsset? asset;
    try {
      asset = await ref
          .read(downloadedEpisodeSourceServiceProvider)
          .completedEpisode(
            widget.episode.anilistMediaId,
            widget.episode.episode,
            malMediaId: widget.episode.malMediaId,
            seriesTitles: {
              widget.episode.title,
              ?widget.episode.titleEnglish,
              ?widget.episode.titleRomaji,
              ...widget.episode.alternativeTitles,
            },
          );
    } catch (_) {
      asset = null;
    }
    if (!mounted || generation != _downloadedAssetRefreshGeneration) {
      return _downloadedAsset;
    }
    final changed =
        asset?.job.id != _downloadedAsset?.job.id ||
        asset?.job.updatedAt != _downloadedAsset?.job.updatedAt;
    if (changed || (asset != null && _error != null)) {
      setState(() {
        _downloadedAsset = asset;
        // A valid local copy is a complete playable result even when every
        // network provider failed earlier in this search.
        if (asset != null) _error = null;
      });
    }
    return asset;
  }

  Future<void> _initialize() async {
    await Future.wait([
      ref.read(userTorrentSourcesControllerProvider.notifier).load(),
      ref.read(settingsPreferencesProvider.notifier).load(),
      ref.read(libraryEpisodeSourceServiceProvider).loadConnections(),
    ]);
    if (!mounted) return;
    final tokenService = ref.read(debridTokenServiceProvider);
    final readSeriesPreferences = ref.read(seriesPreferencesReaderProvider);
    final readDeviceProfile = ref.read(resolveDeviceProfileReaderProvider);
    final readFailureCounts = ref.read(resolveFailureCountsReaderProvider);
    final readDirectTorrentCapability = ref.read(
      directTorrentCapabilityReaderProvider,
    );
    final globalPreferences = ref.read(settingsPreferencesProvider);
    final preferredDebrid = globalPreferences.debridProvider;
    final services = DebridService.values;
    final tokensAndProfile = await Future.wait<Object?>([
      for (final service in services) _usableToken(tokenService, service),
      readDeviceProfile(),
      readSeriesPreferences(
        widget.episode.anilistMediaId,
      ).catchError((_) => const SeriesPlaybackPreferences()),
      readDirectTorrentCapability().catchError(
        (_) => const DirectTorrentCapability.unsupported(),
      ),
    ]);
    final tokens = [
      for (var index = 0; index < services.length; index++)
        tokensAndProfile[index] as String?,
    ];
    final profile = tokensAndProfile[services.length] as TvDeviceProfile;
    final preferences =
        tokensAndProfile[services.length + 1] as SeriesPlaybackPreferences;
    final directTorrentCapability =
        tokensAndProfile[services.length + 2] as DirectTorrentCapability;
    Map<String, int> failures = const {};
    try {
      failures = await readFailureCounts(profile.key);
    } catch (_) {
      // Compatibility history improves sorting but is never required to find
      // or play a stream. A local database problem must not block discovery.
    }
    final connected = <DebridService>{
      for (var index = 0; index < services.length; index++)
        if (tokens[index]?.isNotEmpty == true) services[index],
    };
    if (!mounted) return;
    setState(() {
      _connectedServices = connected;
      if (connected.contains(preferredDebrid)) {
        _debridService = preferredDebrid;
      } else if (!connected.contains(_debridService) && connected.isNotEmpty) {
        _debridService = connected.first;
      }
      _loadingAccount = false;
      _deviceProfile = profile;
      _failureCounts = failures;
      _seriesPreferences = preferences;
      _directTorrentSupported = directTorrentCapability.supported;
      _autoPickEnabledForOpen = globalPreferences.autoPickSourceEnabled;
      // The global choice is authoritative for automatic next-episode
      // playback. Previously every series started with its own default and a
      // failover candidate could silently overwrite it, causing dub/sub flips.
      _languageFilter = _preferredAudio == PlaybackAudioPreference.dub
          ? _StreamLanguageFilter.dub
          : _StreamLanguageFilter.sub;
      _qualityFilter = _enumByName(
        _StreamQualityFilter.values,
        preferences.preferredQuality,
        _StreamQualityFilter.any,
      );
      _codecFilter = _enumByName(
        _StreamCodecFilter.values,
        preferences.preferredCodec,
        _StreamCodecFilter.any,
      );
      _hdrFilter = _enumByName(
        _StreamHdrFilter.values,
        preferences.preferredHdrMode,
        _StreamHdrFilter.any,
      );
      _sortMode = _pickerSortMode(globalPreferences.debridStreamSort);
      _allowBatchStreams = preferences.allowBatchStreams;
    });
    final downloadedAsset = await _refreshDownloadedAsset();
    if (!mounted) return;
    if (downloadedAsset != null &&
        (widget.episode.autoPlay || _autoPickActive)) {
      await _openDownloadedSource(downloadedAsset);
      return;
    }
    await _loadConfiguredReleases();
  }

  Future<String?> _usableToken(
    DebridTokenService tokenService,
    DebridService service,
  ) async {
    try {
      return await tokenService.accessToken(service);
    } catch (_) {
      // Expired or unrefreshable credentials are not a connected service.
      // Resolution will remain available as soon as the user reconnects.
      return null;
    }
  }

  Future<void> _openSourceSettings(String route) async {
    await context.push(route);
    if (!mounted) return;
    setState(() => _loadingAccount = true);
    await _initialize();
  }

  Future<void> _loadConfiguredReleases({bool refreshWeb = false}) async {
    if (_loadingReleases) return;
    _preferredWebWaitTimer?.cancel();
    _preferredWebWaitTimer = null;
    _autoPickDeadlineTimer?.cancel();
    _autoPickDeadlineTimer = null;
    final preferences = ref.read(settingsPreferencesProvider);
    final source = ref.read(configuredReleaseSourceProvider);
    final releaseSearchCache = ref.read(episodeReleaseSearchCacheProvider);
    final librarySourceService = ref.read(libraryEpisodeSourceServiceProvider);
    final shouldSearchDebrid = source != null && _canPlayTorrentReleases;
    final shouldSearchLibrary = librarySourceService.hasConnectedServer;
    var debridSearchFinished = !shouldSearchDebrid;
    final generation = ++_releaseSearchGeneration;
    setState(() {
      _loadingReleases = true;
      _status = 'Searching enabled stream sources…';
      _error = null;
      _releases = const [];
      _webStreams = const [];
      _webFailures = const [];
      _releaseFailures = const [];
      _librarySources = const [];
      _libraryFailures = const [];
      _debridSourcesCompleted = 0;
      _debridSourcesTotal = 0;
      _webProvidersCompleted = 0;
      _webProvidersTotal = 0;
      _pendingDebridSources = const [];
      _pendingWebProviders = const [];
      _debridSearchEnabled = shouldSearchDebrid;
      _debridSearchFinished = !shouldSearchDebrid;
      _webSearchEnabled = preferences.webStreamsEnabled;
      _webSearchFinished = !preferences.webStreamsEnabled;
      _librarySearchEnabled = shouldSearchLibrary;
      _librarySearchFinished = !shouldSearchLibrary;
      _autoplayDebridExhausted = false;
      _autoplayBudgetExhausted = false;
      _preferredWebWaitExpired = false;
      _autoPlayStarted = false;
      _automaticResolveDeadline = null;
      _autoPickNotice = null;
      _failedResolveHashes.clear();
      _failedAutoplayWebStreams.clear();
      _failedAutoPickLibrarySources.clear();
    });
    if (_autoPickActive) {
      _automaticResolveDeadline = widget.clock().add(
        _automaticResolveTimeBudget,
      );
      _autoPickDeadlineTimer = Timer(_automaticResolveTimeBudget, () {
        if (!mounted || generation != _releaseSearchGeneration) return;
        _finishAutoPickWithManualFallback();
      });
    }
    if ((widget.episode.autoPlay && preferences.webStreamsEnabled) ||
        _autoPickActive) {
      _preferredWebWaitTimer = Timer(_preferredWebProviderWaitBudget, () {
        if (!mounted || generation != _releaseSearchGeneration) return;
        _preferredWebWaitExpired = true;
        if (_autoPlayStarted || _resolving) return;
        _tryStartAutoPlay(
          generation: generation,
          allowWebFallback: _debridSearchFinished,
        );
      });
    }

    void finishVisibleSearchIfReady() {
      if (!mounted ||
          generation != _releaseSearchGeneration ||
          (_debridSearchEnabled && !_debridSearchFinished) ||
          (_webSearchEnabled && !_webSearchFinished) ||
          (_librarySearchEnabled && !_librarySearchFinished)) {
        return;
      }
      setState(() {
        _loadingReleases = false;
        if (_downloadedAsset == null &&
            _releases.isEmpty &&
            _webStreams.isEmpty &&
            _librarySources.isEmpty) {
          if (!preferences.debridStreamsEnabled &&
              !preferences.directTorrentStreamingEnabled &&
              !preferences.webStreamsEnabled &&
              !shouldSearchLibrary) {
            _error = 'No stream source is enabled.';
          } else if (_releaseFailures.isNotEmpty && _hasFailedWebProviders) {
            _error = 'No enabled source completed successfully.';
          } else {
            _error = 'No playable streams were returned for this episode.';
          }
        }
      });
    }

    Future<void> loadDebridSources() async {
      if (!shouldSearchDebrid) return;
      try {
        final progressStream = releaseSearchCache.watch(
          widget.episode,
          refresh: refreshWeb,
        );
        await for (final progress in progressStream) {
          if (!mounted || generation != _releaseSearchGeneration) return;
          setState(() {
            _releases = progress.candidates;
            _releaseFailures = progress.failures;
            _debridSourcesCompleted = progress.completedSources;
            _debridSourcesTotal = progress.totalSources;
            _pendingDebridSources = progress.pendingSourceIds;
            if (progress.isComplete) {
              debridSearchFinished = true;
              _debridSearchFinished = true;
            }
          });
          finishVisibleSearchIfReady();
          _tryStartAutoPlay(
            generation: generation,
            allowWebFallback: debridSearchFinished,
          );
          // Wait for all configured sources to finish their concurrent search
          // before starting cache checks. This avoids spending debrid requests
          // on the first source's result while better-ranked duplicates are
          // still arriving from the remaining repositories.
        }
      } finally {
        debridSearchFinished = true;
        _debridSearchFinished = true;
        finishVisibleSearchIfReady();
        _tryStartAutoPlay(generation: generation, allowWebFallback: true);
      }
    }

    Future<void> loadWebProviders() async {
      if (!preferences.webStreamsEnabled) return;
      try {
        await for (final progress
            in ref
                .read(webStreamAggregatorProvider)
                .watchSearchIncrementally(
                  widget.episode,
                  refresh: refreshWeb,
                )) {
          if (!mounted || generation != _releaseSearchGeneration) return;
          setState(() {
            _webStreams = progress.aggregation.streams;
            _webFailures = progress.aggregation.failures;
            _webProvidersCompleted = progress.completedProviders;
            _webProvidersTotal = progress.totalProviders;
            _pendingWebProviders = progress.pendingProviderNames;
            if (progress.isComplete) _webSearchFinished = true;
          });
          finishVisibleSearchIfReady();
          _tryStartAutoPlay(
            generation: generation,
            allowWebFallback: debridSearchFinished,
          );
        }
      } catch (error) {
        if (!mounted || generation != _releaseSearchGeneration) return;
        setState(() {
          _webFailures = [
            WebProviderFailure(
              providerName: 'Web providers',
              message: error.toString(),
            ),
          ];
        });
      } finally {
        if (mounted && generation == _releaseSearchGeneration) {
          _webSearchFinished = true;
          finishVisibleSearchIfReady();
          _tryStartAutoPlay(
            generation: generation,
            allowWebFallback: debridSearchFinished,
          );
        }
      }
    }

    Future<void> loadLibrarySources() async {
      if (!shouldSearchLibrary) return;
      try {
        await for (final result in librarySourceService.watchSearch(
          widget.episode,
        )) {
          if (!mounted || generation != _releaseSearchGeneration) return;
          setState(() {
            _librarySources = result.sources;
            _libraryFailures = result.unavailableServers;
          });
          finishVisibleSearchIfReady();
          _tryStartAutoPlay(
            generation: generation,
            allowWebFallback: debridSearchFinished,
          );
        }
      } catch (_) {
        if (!mounted || generation != _releaseSearchGeneration) return;
        setState(() => _libraryFailures = const ['Connected media server']);
      } finally {
        if (mounted && generation == _releaseSearchGeneration) {
          setState(() => _librarySearchFinished = true);
          finishVisibleSearchIfReady();
          _tryStartAutoPlay(
            generation: generation,
            allowWebFallback: debridSearchFinished,
          );
        }
      }
    }

    try {
      await Future.wait([
        loadDebridSources(),
        loadWebProviders(),
        loadLibrarySources(),
      ]);
      if (!mounted || generation != _releaseSearchGeneration) return;
      setState(() {
        _loadingReleases = false;
        if (_downloadedAsset == null &&
            _releases.isEmpty &&
            _webStreams.isEmpty &&
            _librarySources.isEmpty) {
          if (!preferences.debridStreamsEnabled &&
              !preferences.directTorrentStreamingEnabled &&
              !preferences.webStreamsEnabled &&
              !shouldSearchLibrary) {
            // USB/internal storage remains available in the source picker.
            _error = null;
          } else if (_releaseFailures.isNotEmpty && _hasFailedWebProviders) {
            _error = 'No enabled source completed successfully.';
          } else {
            _error = 'No playable streams were returned for this episode.';
          }
        }
      });
      _tryStartAutoPlay(generation: generation, allowWebFallback: true);
    } catch (error) {
      if (mounted && generation == _releaseSearchGeneration) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _releaseSearchGeneration) {
        setState(() => _loadingReleases = false);
      }
    }
  }

  Future<void> _resolve(
    ReleaseSource source, {
    required ReleaseCandidate selected,
  }) async {
    if (_resolving) return;
    final attempt = ++_resolveAttempt;
    final useDirectTorrent = _useDirectTorrent;
    final requestedAudio = _requestedAudioFromFilter;
    setState(() {
      _resolving = true;
      _progress = 0;
      _status = useDirectTorrent
          ? 'Connecting to torrent peers…'
          : 'Checking ${_debridService.displayName} for an instantly cached '
                'release…';
      _error = null;
      _lastAttemptedRelease = selected;
    });
    try {
      late final StreamResolver resolver;
      if (useDirectTorrent) {
        resolver = ref.read(directTorrentStreamResolverFactoryProvider)(
          source: source,
        );
      } else {
        String? token;
        try {
          token = await ref
              .read(debridTokenServiceProvider)
              .accessToken(_debridService);
        } catch (_) {
          throw DebridProviderAccessException(
            _debridService,
            detail:
                'Your ${_debridService.displayName} connection could not be '
                'refreshed. Reconnect it in Accounts, then try again.',
          );
        }
        if (!mounted || attempt != _resolveAttempt) return;
        if (token == null || token.isEmpty) {
          setState(
            () =>
                _connectedServices = {..._connectedServices}
                  ..remove(_debridService),
          );
          throw DebridProviderAccessException(_debridService);
        }
        resolver = ref.read(debridStreamResolverFactoryProvider)(
          service: _debridService,
          token: token,
          source: source,
        );
      }
      await for (final state in resolver.resolve(widget.episode)) {
        if (!mounted || attempt != _resolveAttempt) {
          if (state case final StreamReady ready) {
            await ready.playbackLease?.close();
          }
          return;
        }
        switch (state) {
          case StreamCaching():
            setState(() {
              _progress = state.progress;
              _status = state.progress <= 0
                  ? 'Selecting the episode file…'
                  : '${useDirectTorrent ? 'Direct torrent' : _debridService.displayName} '
                        'is caching… '
                        '${(state.progress * 100).round()}%';
            });
          case StreamReady():
            try {
              verifyPlaybackEpisodeIdentity(
                episode: widget.episode,
                stream: state,
                release: selected,
              );
            } on EpisodeIdentityMismatchException {
              await state.playbackLease?.close();
              rethrow;
            }
            if (!mounted || attempt != _resolveAttempt) {
              await state.playbackLease?.close();
              return;
            }
            final playerUri = Uri(
              path: '/player',
              queryParameters: {
                'source': state.uri.toString(),
                'title':
                    '${widget.episode.title} • Episode '
                    '${widget.episode.episode}',
                'anilistId': '${widget.episode.anilistMediaId}',
                if (widget.episode.malMediaId != null)
                  'malId': '${widget.episode.malMediaId}',
                'episode': '${widget.episode.episode}',
                'watchPartyTargetSourceKey': ?_hostSourceKey,
                if (state.debridService != null)
                  'debrid': state.debridService!.slug,
              },
            );
            final seenAlternativeHashes = <String>{
              selected.infoHash.toLowerCase(),
            };
            final alternatives = state.isDirectTorrent
                ? const <ReleaseCandidate>[]
                : (_releases
                      .where(
                        (item) => seenAlternativeHashes.add(
                          item.infoHash.toLowerCase(),
                        ),
                      )
                      .toList(growable: false)
                    ..sort((left, right) {
                      return compareAutoplayReleases(
                        left,
                        right,
                        device: _deviceProfile,
                        failureCounts: _failureCounts,
                        sortMode: 'compatibility',
                        preferredProvider: selected.provider,
                        preferredAuthor: releaseGroupKey(selected.releaseName),
                        preferredSourceId: selected.sourceId,
                        existingPreferredProvider:
                            _seriesPreferences.preferredReleaseProvider,
                        existingPreferredReleaseGroup:
                            _seriesPreferences.preferredReleaseGroup,
                        preferredAudio: _preferredAudio,
                        rankingPreference: _debridRanking,
                        preferredQualityHeight: releaseQualityHeight(selected),
                      );
                    }));
            final directAlternatives =
                _autoplayWebCandidates(
                      _webStreams,
                      preferredQualityHeight: releaseQualityHeight(selected),
                    )
                    .where((stream) => stream.uri != state.uri)
                    .map(
                      (stream) => PlaybackStreamOption(
                        stream: _readyForWebStream(stream),
                        release: _releaseForWebStream(stream),
                      ),
                    )
                    .toList(growable: false);
            _prepareExactWatchPartySourceHandoff(selected);
            context.pushReplacement(
              playerUri.toString(),
              extra: PlaybackLaunch(
                stream: state,
                episode: widget.episode,
                selectedRelease: selected,
                requestedAudio: requestedAudio,
                alternatives: alternatives,
                directAlternatives: directAlternatives,
              ),
            );
            return;
        }
      }
    } catch (error, stackTrace) {
      if (mounted && attempt == _resolveAttempt) {
        _failedResolveHashes.add(selected.infoHash.toLowerCase());
        if (error case final RealDebridException realDebridError) {
          unawaited(
            _recordRealDebridFailure(realDebridError, selected.sourceId),
          );
        }
        int compareRecovery(ReleaseCandidate left, ReleaseCandidate right) =>
            compareAutoplayReleases(
              left,
              right,
              device: _deviceProfile,
              failureCounts: _failureCounts,
              sortMode: 'compatibility',
              preferredProvider: selected.provider,
              preferredAuthor: releaseGroupKey(selected.releaseName),
              preferredSourceId: selected.sourceId,
              existingPreferredProvider:
                  _seriesPreferences.preferredReleaseProvider,
              existingPreferredReleaseGroup:
                  _seriesPreferences.preferredReleaseGroup,
              preferredAudio: _preferredAudio,
              rankingPreference: _debridRanking,
              preferredQualityHeight: releaseQualityHeight(selected),
            );
        final manuallyRanked = _filteredAndSortedReleases(_releases)
          ..sort(compareRecovery);
        final failOpen =
            _releases
                .where((item) => !manuallyRanked.contains(item))
                .toList(growable: false)
              ..sort(compareRecovery);
        final recoveryPool = <ReleaseCandidate>[...manuallyRanked, ...failOpen];
        final next = recoveryPool
            .where(
              (item) =>
                  !_failedResolveHashes.contains(item.infoHash.toLowerCase()),
            )
            .firstOrNull;
        final terminalProviderFailure = isTerminalDebridFailoverFailure(error);
        if (_autoPickActive && terminalProviderFailure) {
          // A provider-wide Debrid failure cannot be fixed by another torrent,
          // but an allowed Web candidate may still be usable.
          _autoplayDebridExhausted = true;
        }
        final withinFailoverBudget =
            (_autoPickActive
                ? _autoPickFailedAttemptCount < _maxAutomaticResolveCandidates
                : _failedResolveHashes.length <
                      _maxAutomaticResolveCandidates) &&
            (_automaticResolveDeadline == null ||
                widget.clock().isBefore(_automaticResolveDeadline!));
        final automaticTier = _autoPickActive ? _autoPickCandidateTier() : null;
        final hasAutomaticCandidate = automaticTier == null
            ? _releases.any(
                    (item) => !_failedResolveHashes.contains(
                      item.infoHash.toLowerCase(),
                    ),
                  ) ||
                  _webStreams.any(
                    (stream) => !_failedAutoplayWebStreams.contains(
                      _webStreamKey(stream),
                    ),
                  )
            : automaticTier.releases.isNotEmpty ||
                  automaticTier.web.isNotEmpty ||
                  automaticTier.library.isNotEmpty;
        final discoveryPending = _autoPickActive
            ? _automaticDiscoveryPending
            : (_debridSearchEnabled && !_debridSearchFinished) ||
                  (_webSearchEnabled && !_webSearchFinished);
        if (_automaticSelectionActive &&
            (!terminalProviderFailure || _autoPickActive) &&
            withinFailoverBudget &&
            (hasAutomaticCandidate || discoveryPending)) {
          setState(() {
            _resolving = false;
            _autoPlayStarted = false;
            _status = discoveryPending
                ? 'That release failed. Waiting for other sources…'
                : 'That release failed. Trying another stream…';
            _error = null;
          });
          Future<void>.microtask(
            () => _tryStartAutoPlay(
              generation: _releaseSearchGeneration,
              allowWebFallback: _debridSearchFinished,
            ),
          );
          return;
        }
        if (!widget.episode.autoPlay &&
            !_autoPickActive &&
            !terminalProviderFailure &&
            next != null &&
            withinFailoverBudget) {
          setState(() {
            _resolving = false;
            _status = 'That release failed. Trying another release…';
          });
          unawaited(
            Future<void>.microtask(
              () => _resolve(_SelectedReleaseSource(next), selected: next),
            ),
          );
          return;
        }
        if (widget.episode.autoPlay &&
            !terminalProviderFailure &&
            !_debridSearchFinished &&
            withinFailoverBudget) {
          setState(() {
            _resolving = false;
            _autoPlayStarted = false;
            _status = 'That release failed. Waiting for other sources…';
            _error = null;
          });
          return;
        }
        if (widget.episode.autoPlay) {
          _autoplayDebridExhausted = true;
          final webCandidates = _webSearchEnabled
              ? _autoplayWebCandidates(_webStreams)
              : const <WebStreamResult>[];
          if (_webSearchEnabled &&
              (!_webSearchFinished || webCandidates.isNotEmpty)) {
            setState(() {
              _resolving = false;
              _autoPlayStarted = false;
              _status = _webSearchFinished
                  ? '${useDirectTorrent ? 'Direct torrent' : 'Debrid'} releases failed. Trying a web stream…'
                  : '${useDirectTorrent ? 'Direct torrent' : 'Debrid'} releases failed. Waiting for web providers…';
              _error = null;
            });
            if (_webSearchFinished) {
              Future<void>.microtask(
                () => _tryStartAutoPlay(
                  generation: _releaseSearchGeneration,
                  allowWebFallback: true,
                ),
              );
            }
            return;
          }
        }
        if (_autoPickActive) {
          _finishAutoPickWithManualFallback();
          return;
        }
        if (shouldRecordResolveCrashReport(error)) {
          unawaited(
            recordAnonymousHandledError(
              area: AnonymousErrorArea.playback,
              error: error,
              stack: stackTrace,
            ),
          );
        }
        final errorMessage = switch (error) {
          DebridCacheMissException() => debridCacheExhaustedMessage(
            _debridService,
            _failedResolveHashes.length,
          ),
          RealDebridException(canTryAnotherRelease: true) =>
            _exhaustedReleaseMessage(_failedResolveHashes.length),
          DebridProviderFailure(
            failureCategory: DebridFailureCategory.releaseUnavailable,
          ) =>
            _exhaustedReleaseMessage(_failedResolveHashes.length),
          _ => error.toString().replaceFirst('Bad state: ', ''),
        };
        setState(() {
          _error = errorMessage;
          _status = 'Could not resolve this episode';
        });
      }
    } finally {
      if (mounted && attempt == _resolveAttempt) {
        setState(() => _resolving = false);
      }
    }
  }

  void _tryStartAutoPlay({
    required int generation,
    required bool allowWebFallback,
  }) {
    if (!mounted ||
        generation != _releaseSearchGeneration ||
        !_automaticSelectionActive ||
        _autoPlayStarted ||
        _resolving) {
      return;
    }

    if (widget.watchPartyFollow && _hostSourceFingerprint != null) {
      if (_tryStartExactWatchPartySource()) return;
      if (_automaticDiscoveryPending && !_preferredWebWaitExpired) return;
      _notifyWatchPartyDifferentSource();
    }

    final tier = _automaticCandidateTier();
    if (tier.waiting) return;

    if (_autoPickActive) {
      final started = _tryStartAutoPickSourceClass(tier);
      if (!started && !_automaticDiscoveryPending) {
        _finishAutoPickWithManualFallback();
      }
      return;
    }

    final preferredWebProviderId = _boundedHint(
      widget.preferredWebProviderId,
      maxLength: 160,
    );
    if (widget.episode.autoPlay && preferredWebProviderId != null) {
      final exactWebCandidates = _autoplayWebCandidates(
        tier.web.where(
          (stream) =>
              stream.providerId == preferredWebProviderId &&
              webStreamAudioPreferenceRank(stream, _preferredAudio) == 0,
        ),
      );
      if (exactWebCandidates.isNotEmpty) {
        // The matching provider may finish before the rest of discovery. Try
        // only its streams now; if preflight rejects all of them, wait for the
        // full provider set before choosing a different source.
        _startAutoplayWeb(exactWebCandidates);
        return;
      }
      if (!_webSearchFinished && !_preferredWebWaitExpired) return;
    }

    final allowNonPreferredFallback =
        _autoPickActive || allowWebFallback || _preferredWebWaitExpired;

    // Preserve the current source once inside the active strict/fail-open
    // tier, regardless of the viewer's global class preference. If that one
    // exact candidate fails, the normal Web/Debrid priority chooses the next
    // class instead of exhausting unrelated candidates from the old class.
    if (widget.episode.autoPlay &&
        !_autoplayDebridExhausted &&
        _canPlayTorrentReleases) {
      final exactReleaseCandidates = _exactAutoplayReleaseCandidates(
        tier.releases,
      );
      if (exactReleaseCandidates.isNotEmpty) {
        _startAutoplayRelease(exactReleaseCandidates);
        return;
      }
    }

    // A saved Web-first preference is allowed to start as soon as a usable
    // Web result arrives. Cross-class audio ranks are compared first, so a
    // matching Dub/Sub Debrid result still beats a mismatched Web result.
    if (_streamPreferences.streamSourcePriority ==
        StreamSourcePriority.webFirst) {
      final started = _tryStartRankedSourceClass(tier);
      if (started) return;
      if (_automaticWebSearchPending && !_preferredWebWaitExpired) {
        return;
      }
    }

    if (!allowNonPreferredFallback) return;
    final started = _tryStartRankedSourceClass(tier);
    if (!started && _autoPickActive && !_automaticDiscoveryPending) {
      _finishAutoPickWithManualFallback();
    }
  }

  bool _tryStartExactWatchPartySource() {
    final fingerprint = _hostSourceFingerprint;
    final sourceClass = _hostSourceClass;
    if (fingerprint == null || sourceClass == null) return false;
    bool matchesHostDescriptor(ReleaseCandidate release) {
      final descriptor = WatchPartySourceDescriptor.tryForRelease(
        release,
        requestedAudio: _preferredAudio,
      );
      return descriptor?.sourceClass == sourceClass &&
          descriptor?.fingerprint == fingerprint;
    }

    if (sourceClass == WatchPartySourceClass.torrent &&
        _canPlayTorrentReleases) {
      final exact = _releases
          .where(
            (release) =>
                !_failedResolveHashes.contains(
                  release.infoHash.toLowerCase(),
                ) &&
                matchesHostDescriptor(release),
          )
          .toList(growable: false);
      if (exact.isNotEmpty) {
        _startAutoplayRelease(exact);
        return true;
      }
    }
    if (sourceClass == WatchPartySourceClass.web && _webSearchEnabled) {
      final exact = _webStreams
          .where(
            (stream) =>
                !_failedAutoplayWebStreams.contains(_webStreamKey(stream)) &&
                matchesHostDescriptor(_releaseForWebStream(stream)),
          )
          .toList(growable: false);
      if (exact.isNotEmpty) {
        _startAutoplayWeb(exact);
        return true;
      }
    }
    return false;
  }

  void _notifyWatchPartyDifferentSource() {
    if (_watchPartyDifferentSourceNotified) return;
    _watchPartyDifferentSourceNotified = true;
    ref
        .read(watchPartyControllerProvider.notifier)
        .notifyDifferentSourceFallback(targetSourceKey: _hostSourceKey);
  }

  void _prepareExactWatchPartySourceHandoff(ReleaseCandidate release) {
    final targetSourceKey = _hostSourceKey;
    final fingerprint = _hostSourceFingerprint;
    final sourceClass = _hostSourceClass;
    if (!widget.watchPartyFollow ||
        targetSourceKey == null ||
        fingerprint == null ||
        sourceClass == null) {
      return;
    }
    final descriptor = WatchPartySourceDescriptor.tryForRelease(
      release,
      requestedAudio: _preferredAudio,
    );
    if (descriptor?.sourceClass != sourceClass ||
        descriptor?.fingerprint != fingerprint) {
      return;
    }
    ref
        .read(watchPartyControllerProvider.notifier)
        .prepareExactSourceHandoff(targetSourceKey: targetSourceKey);
  }

  bool _tryStartRankedSourceClass(_AutoplayCandidateTier tier) {
    final releases = tier.releases;
    final web = tier.web;
    final priority = _streamPreferences.streamSourcePriority;

    if (releases.isEmpty && web.isEmpty) return false;
    if (releases.isEmpty) {
      final webAudio = webStreamAudioPreferenceRank(web.first, _preferredAudio);
      if (_automaticDebridSearchPending &&
          !_preferredWebWaitExpired &&
          (priority == StreamSourcePriority.debridFirst || webAudio > 0)) {
        return false;
      }
      _startAutoplayWeb(web);
      return true;
    }
    if (web.isEmpty) {
      final releaseAudio = releaseAudioPreferenceRank(
        releases.first,
        _preferredAudio,
      );
      if (_automaticWebSearchPending &&
          !_preferredWebWaitExpired &&
          (priority == StreamSourcePriority.webFirst || releaseAudio > 0)) {
        return false;
      }
      _startAutoplayRelease(releases);
      return true;
    }

    final sourceOrder = compareStreamSourceClasses(
      StreamSourceClass.debrid,
      StreamSourceClass.web,
      priority,
      leftAudioRank: releaseAudioPreferenceRank(
        releases.first,
        _preferredAudio,
      ),
      rightAudioRank: webStreamAudioPreferenceRank(web.first, _preferredAudio),
    );
    if (sourceOrder <= 0) {
      _startAutoplayRelease(releases);
    } else {
      _startAutoplayWeb(web);
    }
    return true;
  }

  bool _tryStartAutoPickSourceClass(_AutoplayCandidateTier tier) {
    final preferences = _streamPreferences;
    for (final source in preferences.effectiveAutoPickSourcePriority) {
      switch (source) {
        case AutoPickSourcePriority.debrid:
          if (tier.releases.isNotEmpty) {
            _startAutoplayRelease(tier.releases);
            return true;
          }
        case AutoPickSourcePriority.web:
          if (tier.web.isNotEmpty) {
            _startAutoplayWeb(tier.web);
            return true;
          }
        case AutoPickSourcePriority.yourMedia:
          if (tier.library.isNotEmpty) {
            _startAutoplayLibrary(tier.library);
            return true;
          }
      }
    }
    return false;
  }

  _AutoplayCandidateTier _autoplayCandidateTier() {
    final releases = !_autoplayDebridExhausted && _canPlayTorrentReleases
        ? _autoplayReleaseCandidates(_releases)
              .where(
                (release) => !_failedResolveHashes.contains(
                  release.infoHash.toLowerCase(),
                ),
              )
              .toList(growable: false)
        : const <ReleaseCandidate>[];
    final web = _webSearchEnabled
        ? _autoplayWebCandidates(_webStreams)
        : const <WebStreamResult>[];
    final strictReleases = releases
        .where(
          (release) => automaticReleaseMatchesFilters(
            release,
            language: _languageFilter.name,
            quality: _qualityFilter.name,
            codec: _codecFilter.name,
            hdr: _hdrFilter.name,
            allowBatch: _allowBatchStreams,
          ),
        )
        .toList(growable: false);
    final strictWeb = web
        .where(
          (stream) => automaticWebStreamMatchesFilters(
            stream,
            language: _languageFilter.name,
            quality: _qualityFilter.name,
          ),
        )
        .toList(growable: false);
    if (strictReleases.isNotEmpty || strictWeb.isNotEmpty) {
      return _AutoplayCandidateTier(releases: strictReleases, web: strictWeb);
    }
    final discoveryPending =
        (_debridSearchEnabled && !_debridSearchFinished) ||
        (_webSearchEnabled && !_webSearchFinished);
    if (discoveryPending && !_preferredWebWaitExpired) {
      return const _AutoplayCandidateTier(waiting: true);
    }
    return _AutoplayCandidateTier(releases: releases, web: web);
  }

  _AutoplayCandidateTier _automaticCandidateTier() {
    if (!_autoPickActive) return _autoplayCandidateTier();
    return _autoPickCandidateTier();
  }

  _AutoplayCandidateTier _autoPickCandidateTier() {
    final releases =
        _automaticAllowsDebrid &&
            !_autoplayDebridExhausted &&
            _canPlayTorrentReleases
        ? _autoplayReleaseCandidates(
            _releases.where(_autoPickReleaseAudioAllowed),
          )
        : const <ReleaseCandidate>[];
    final web = _automaticAllowsWeb
        ? _autoplayWebCandidates(
            _webStreams.where(_autoPickWebStreamAudioAllowed),
          )
        : const <WebStreamResult>[];
    final library = _automaticAllowsLibrary && _librarySearchFinished
        ? unambiguousLibraryAutoPickSources(
                sources: _librarySources,
                episode: widget.episode,
              )
              .where(
                (source) =>
                    !_failedAutoPickLibrarySources.contains(source.stableKey),
              )
              .toList(growable: false)
        : const <LibraryEpisodeSource>[];

    final preferences = _streamPreferences;
    final qualityPriority = preferences.effectiveAutoPickQualityPriority;
    final sourcePriority = preferences.effectiveAutoPickSourcePriority;
    final libraryPriority = sourcePriority.indexOf(
      AutoPickSourcePriority.yourMedia,
    );
    // Library sources do not currently expose trustworthy audio-track
    // metadata, and Plex/device files may not expose a resolution either.
    // Keep that unknown metadata behind all configured network tiers in the
    // migrated default order. Moving Local sources earlier is an explicit opt-in
    // to let an exact local episode win at that source-priority position.
    final libraryWasPromoted =
        libraryPriority >= 0 && libraryPriority < sourcePriority.length - 1;
    final discoveryPending = _automaticDiscoveryPending;
    final canWaitForHigherPriority =
        discoveryPending && !_preferredWebWaitExpired;

    for (final quality in qualityPriority) {
      final targetHeight = quality.targetHeight;
      if (targetHeight == null) continue;
      final qualityReleases = releases
          .where((release) => releaseQualityHeight(release) == targetHeight)
          .toList(growable: false);
      final qualityWeb = web
          .where((stream) => webStreamQualityHeight(stream) == targetHeight)
          .toList(growable: false);
      final qualityLibrary = libraryWasPromoted
          ? library
          : const <LibraryEpisodeSource>[];

      if (qualityReleases.isEmpty &&
          qualityWeb.isEmpty &&
          qualityLibrary.isEmpty) {
        if (canWaitForHigherPriority &&
            (releases.isNotEmpty || web.isNotEmpty || library.isNotEmpty)) {
          return const _AutoplayCandidateTier(waiting: true);
        }
        continue;
      }

      // If the first source class for this exact quality is still searching,
      // briefly wait instead of allowing result arrival order to defeat the
      // user's explicit source priority. The bounded wait timer then fails
      // open to already-discovered candidates.
      if (canWaitForHigherPriority) {
        for (final source in sourcePriority) {
          final hasCandidates = switch (source) {
            AutoPickSourcePriority.debrid => qualityReleases.isNotEmpty,
            AutoPickSourcePriority.web => qualityWeb.isNotEmpty,
            AutoPickSourcePriority.yourMedia => qualityLibrary.isNotEmpty,
          };
          if (hasCandidates) break;
          final sourcePending = switch (source) {
            AutoPickSourcePriority.debrid => _automaticDebridSearchPending,
            AutoPickSourcePriority.web => _automaticWebSearchPending,
            AutoPickSourcePriority.yourMedia => _automaticLibrarySearchPending,
          };
          if (sourcePending) {
            return const _AutoplayCandidateTier(waiting: true);
          }
        }
      }

      return _AutoplayCandidateTier(
        releases: qualityReleases,
        web: qualityWeb,
        library: qualityLibrary,
      );
    }
    // In the default Debrid -> Web -> Local sources order, an exact library item
    // is the safe final fallback only after every configured/audio-matching
    // network tier is exhausted. Library Auto Pick waits for every connected
    // server so a fast first result cannot win before a conflicting remake or
    // season arrives; the manual picker remains progressively populated.
    if (_automaticDebridSearchPending || _automaticWebSearchPending) {
      return const _AutoplayCandidateTier(waiting: true);
    }
    if (library.isNotEmpty) return _AutoplayCandidateTier(library: library);
    if (_automaticLibrarySearchPending) {
      return const _AutoplayCandidateTier(waiting: true);
    }
    return const _AutoplayCandidateTier();
  }

  bool _autoPickReleaseAudioAllowed(ReleaseCandidate release) {
    final preferences = _streamPreferences;
    return switch (preferences.autoPickAudio) {
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

  bool _autoPickWebStreamAudioAllowed(WebStreamResult stream) {
    final preferences = _streamPreferences;
    return switch (preferences.autoPickAudio) {
      AutoPickAudio.any => true,
      AutoPickAudio.dubOnly => stream.supportsDubAudio,
      AutoPickAudio.subOnly => stream.supportsSubAudio,
    };
  }

  void _finishAutoPickWithManualFallback({String? notice}) {
    if (!_autoPickActive || !mounted) return;
    _autoPickDeadlineTimer?.cancel();
    _autoPickDeadlineTimer = null;
    final preferences = _streamPreferences;
    final quality = preferences.effectiveAutoPickQualityPriority
        .map((item) => item.displayName)
        .join(' → ');
    final audio = switch (preferences.autoPickAudio) {
      AutoPickAudio.any => 'Any audio',
      AutoPickAudio.dubOnly => 'Dub',
      AutoPickAudio.subOnly => 'Sub',
    };
    final source = preferences.effectiveAutoPickSourcePriority
        .map((item) => item.displayName)
        .join(' → ');
    final rules = [quality, audio, source].join(' + ');
    final fallbackNotice =
        notice ??
        (_autoPickFailedAttemptCount > 0
            ? 'Sources matching Auto Pick ($rules) failed to start. '
                  'Choose another source below.'
            : 'No source matched Auto Pick: $rules. '
                  'Choose from the full list below.');
    // Invalidate an in-flight Debrid resolver. Web preflights use the
    // cancellation guard in [_openWebStream] so provider discovery may keep
    // feeding the now-visible manual picker.
    _resolveAttempt++;
    _libraryResolveAttempt++;
    setState(() {
      _autoPickManualFallback = true;
      _autoPickNotice = fallbackNotice;
      if (widget.episode.autoPlay) _autoplayManualFallback = true;
      _autoPlayStarted = false;
      _resolving = false;
      _status = 'Choose a stream';
      _error = null;
    });
  }

  void _startAutoplayRelease(List<ReleaseCandidate> candidates) {
    _autoPlayStarted = true;
    unawaited(
      _resolveCandidate(
        candidates.first,
        continueAutomaticSequence: _failedResolveHashes.isNotEmpty,
      ),
    );
  }

  void _startAutoplayWeb(List<WebStreamResult> candidates) {
    _autoPlayStarted = true;
    _automaticResolveDeadline ??= widget.clock().add(
      _automaticResolveTimeBudget,
    );
    unawaited(_openWebStream(candidates.first, autoplayCandidates: candidates));
  }

  void _startAutoplayLibrary(List<LibraryEpisodeSource> candidates) {
    if (candidates.isEmpty || _autoPickRemainingAttemptBudget <= 0) {
      _finishAutoPickWithManualFallback();
      return;
    }
    _autoPlayStarted = true;
    _automaticResolveDeadline ??= widget.clock().add(
      _automaticResolveTimeBudget,
    );
    unawaited(_openLibrarySource(candidates.first, automatic: true));
  }

  List<ReleaseCandidate> _autoplayReleaseCandidates(
    Iterable<ReleaseCandidate> input, {
    int? preferredQualityHeight,
  }) {
    return rankAutomaticAutoplayReleases(
      input.where(
        (release) =>
            !_failedResolveHashes.contains(release.infoHash.toLowerCase()) &&
            _releaseMatchesEpisodeIdentity(release),
      ),
      language: _languageFilter.name,
      quality: _qualityFilter.name,
      codec: _codecFilter.name,
      hdr: _hdrFilter.name,
      allowBatch: _allowBatchStreams,
      preferredAudio: _preferredAudio,
      rankingPreference: _debridRanking,
      device: _deviceProfile,
      failureCounts: _failureCounts,
      sortMode: _sortMode.name,
      preferredProvider: widget.preferredProvider,
      preferredAuthor: widget.preferredAuthor,
      preferredSourceId: widget.preferredSourceId,
      existingPreferredProvider: _seriesPreferences.preferredReleaseProvider,
      existingPreferredReleaseGroup: _seriesPreferences.preferredReleaseGroup,
      preferredQualityHeight:
          preferredQualityHeight ?? widget.preferredQualityHeight,
    );
  }

  List<ReleaseCandidate> _exactAutoplayReleaseCandidates(
    Iterable<ReleaseCandidate> input,
  ) {
    final provider = _normalizedProviderHint(widget.preferredProvider);
    final sourceId = _boundedHint(widget.preferredSourceId, maxLength: 160);
    final author = _normalizedAuthorHint(widget.preferredAuthor);
    if (provider == null && sourceId == null) return const [];
    final ranked = _autoplayReleaseCandidates(input);
    if (ranked.isEmpty) return const [];
    final minimumSafety = ranked
        .map(
          (release) => automaticPlaybackSafetyScore(
            release,
            device: _deviceProfile,
            previousFailures:
                _failureCounts[release.infoHash.toLowerCase()] ?? 0,
          ),
        )
        .reduce((left, right) => left < right ? left : right);
    final identityMatches = ranked
        .where(
          (release) =>
              !_failedResolveHashes.contains(release.infoHash.toLowerCase()) &&
              ((provider != null &&
                      _normalizedProviderHint(release.provider) == provider) ||
                  (sourceId != null && release.sourceId == sourceId)) &&
              automaticPlaybackSafetyScore(
                    release,
                    device: _deviceProfile,
                    previousFailures:
                        _failureCounts[release.infoHash.toLowerCase()] ?? 0,
                  ) ==
                  minimumSafety &&
              releaseAudioPreferenceRank(release, _preferredAudio) == 0,
        )
        .toList(growable: false);
    if (author == null) return identityMatches;
    return identityMatches
        .where((release) => releaseGroupKey(release.releaseName) == author)
        .toList(growable: false);
  }

  List<WebStreamResult> _autoplayWebCandidates(
    Iterable<WebStreamResult> input, {
    int? preferredQualityHeight,
  }) {
    return rankAutomaticAutoplayWebStreams(
      input.where(
        (stream) =>
            !_failedAutoplayWebStreams.contains(_webStreamKey(stream)) &&
            _webStreamMatchesEpisodeIdentity(stream),
      ),
      language: _languageFilter.name,
      quality: _qualityFilter.name,
      preferredAudio: _preferredAudio,
      preferredWebProviderId: widget.preferredWebProviderId,
      preferredQualityHeight:
          preferredQualityHeight ?? widget.preferredQualityHeight,
      qualityPreference: _streamPreferences.webStreamQuality,
    );
  }

  String _webStreamKey(WebStreamResult stream) =>
      _opaqueWebStreamIdentity(stream);

  List<WebStreamResult> _filteredWebStreams(
    Iterable<WebStreamResult> input, {
    bool ignoreOptionalFilters = false,
  }) {
    final result = input.where((stream) {
      if (!_webStreamMatchesEpisodeIdentity(stream)) return false;
      if (!ignoreOptionalFilters &&
          !webStreamMatchesAudioFilter(stream, _languageFilter.name)) {
        return false;
      }
      final quality = (stream.quality ?? stream.title).toLowerCase();
      if (ignoreOptionalFilters) return true;
      return switch (_qualityFilter) {
        _StreamQualityFilter.any => true,
        _StreamQualityFilter.p2160 =>
          quality.contains('2160') || quality.contains('4k'),
        _StreamQualityFilter.p1080 => quality.contains('1080'),
        _StreamQualityFilter.p720 => quality.contains('720'),
      };
    }).toList();
    result.sort(
      (left, right) => compareWebStreamCandidates(
        left,
        right,
        quality: _streamPreferences.webStreamQuality,
        preferredAudio: _preferredAudio,
      ),
    );
    return _providerFairManualWebStreams(result);
  }

  bool get _hasFailedWebProviders => _webFailures.any(
    (failure) =>
        failure.status == WebProviderFailureStatus.failed ||
        failure.status == WebProviderFailureStatus.unavailable,
  );

  List<WebStreamResult> _providerFairManualWebStreams(
    List<WebStreamResult> ranked,
  ) {
    final buckets = <String, List<WebStreamResult>>{};
    for (final stream in ranked) {
      final provider = stream.providerId.trim().isEmpty
          ? stream.providerName.trim().toLowerCase()
          : stream.providerId.trim().toLowerCase();
      buckets.putIfAbsent(provider, () => []).add(stream);
    }
    final ordered = buckets.values.toList(growable: false);
    final longest = ordered.fold<int>(
      0,
      (length, bucket) => bucket.length > length ? bucket.length : length,
    );
    return [
      for (var offset = 0; offset < longest; offset++)
        for (final bucket in ordered)
          if (offset < bucket.length) bucket[offset],
    ];
  }

  ReleaseCandidate _releaseForWebStream(WebStreamResult stream) {
    return ReleaseCandidate(
      infoHash: watchPartyWebReleaseIdentity(
        providerId: stream.providerId,
        uri: stream.uri,
      ),
      magnetUri: '',
      releaseName: '${stream.providerName} / ${stream.title}',
      seeders: 0,
      sourceId: 'web:${stream.providerId}',
      quality: stream.quality,
      provider: stream.providerName,
      isDubbed: stream.supportsDubAudio,
      audioIntent: releaseAudioIntentForWebStream(stream),
      hasSubtitles: stream.subtitleUri != null,
    );
  }

  StreamReady _readyForWebStream(
    WebStreamResult stream, {
    Uri? validatedUri,
    Map<String, String>? validatedHeaders,
    Uri? validatedSubtitleUri,
    String? mediaContentType,
    String? subtitleContentType,
    bool externalSubtitleRejected = false,
    PlaybackResourceLease? playbackLease,
  }) {
    final release = _releaseForWebStream(stream);
    return StreamReady(
      uri: validatedUri ?? stream.uri,
      displayName: release.releaseName,
      headers: validatedHeaders ?? stream.headers,
      externalSubtitle: validatedUri == null
          ? stream.subtitleUri
          : validatedSubtitleUri,
      mediaContentType: mediaContentType,
      subtitleContentType: subtitleContentType,
      externalSubtitleRejected: externalSubtitleRejected,
      playbackLease: playbackLease,
      providerId: stream.providerId,
      providerName: '${stream.providerName} web stream',
      providerEpisodeIdentity: ProviderEpisodeIdentity.fromFields(
        episodeNumber: stream.matchedEpisodeNumber,
        seasonNumber: stream.matchedSeasonNumber,
        seriesTitle: stream.matchedSeriesTitle,
      ),
    );
  }

  Future<bool> _confirmSourceDownload({
    required String source,
    required String details,
  }) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.download_for_offline_rounded),
            title: const Text('Download this episode?'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Text(
                '$source\n\n$details\n\nThe episode will appear in Download '
                'Manager and, once finished, as the first source for this '
                'episode.',
              ),
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _confirmDirectPeerDownload({bool debridFailed = false}) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.public_rounded),
            title: const Text('Download from public torrent peers?'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Text(
                '${debridFailed ? 'Your Debrid service could not prepare this release. ' : ''}'
                'A direct torrent download makes your public IP address '
                'visible to peers and trackers and may upload data while the '
                'download runs. Only continue for content you are legally '
                'allowed to access.',
              ),
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.public_rounded),
                label: const Text('Download directly'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<StreamReady> _prepareDebridDownload(ReleaseCandidate release) async {
    String? token;
    try {
      token = await ref
          .read(debridTokenServiceProvider)
          .accessToken(_debridService);
    } catch (_) {
      throw DebridProviderAccessException(_debridService);
    }
    if (token == null || token.isEmpty) {
      throw DebridProviderAccessException(_debridService);
    }
    final resolver = ref.read(debridStreamResolverFactoryProvider)(
      service: _debridService,
      token: token,
      source: _SelectedReleaseSource(release),
    );
    await for (final result
        in resolver
            .resolve(widget.episode)
            .timeout(const Duration(seconds: 60))) {
      if (result case final StreamReady ready) {
        if (ready.uri.scheme.toLowerCase() != 'https' ||
            ready.uri.host.isEmpty ||
            ready.uri.userInfo.isNotEmpty ||
            ready.uri.hasFragment) {
          await ready.playbackLease?.close();
          throw const FormatException(
            'The Debrid service did not return a downloadable HTTPS source.',
          );
        }
        return ready;
      }
    }
    throw StateError('The Debrid service returned no download source.');
  }

  Future<void> _downloadRelease(ReleaseCandidate release) async {
    if (!_offlineDownloadsEnabled) return;
    if (_preparingDownload) return;
    final details = [
      releaseAudioPickerLabel(release),
      release.quality,
      release.provider,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' • ');
    if (!await _confirmSourceDownload(
      source: release.releaseName.replaceAll('\n', ' • '),
      details: details.isEmpty ? 'Torrent source' : details,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _preparingDownload = true);
    _recordDownloadPreparationDiagnostic(
      sourceKind: 'torrent',
      stage: 'source_resolution',
      outcome: 'started',
    );
    StreamReady? debridReady;
    try {
      if (_hasDebrid) {
        try {
          debridReady = await _prepareDebridDownload(release);
          if (!mounted) return;
          await _enqueueOfflineDownload(
            OfflineDownloadRequest(
              anilistMediaId: widget.episode.anilistMediaId,
              malMediaId: widget.episode.malMediaId,
              episode: widget.episode.episode,
              seriesTitle: widget.episode.title,
              episodeTitle: 'Episode ${widget.episode.episode}',
              sourceLabel: release.releaseName,
              transport: DownloadTransport.https,
              sourceUri: debridReady.uri,
              providerId: _debridService.slug,
              providerName: _debridService.displayName,
              quality: release.quality,
              audioLabel: releaseAudioPickerLabel(release),
              mimeType: debridReady.mediaContentType,
              fileExtension: _offlineFileExtension(
                debridReady.uri,
                debridReady.mediaContentType,
              ),
              requestHeaders: debridReady.headers,
            ),
          );
          _recordDownloadPreparationDiagnostic(
            sourceKind: 'torrent',
            stage: 'queue_enqueue',
            outcome: 'succeeded',
            transport: 'debrid_https',
          );
          return;
        } catch (error) {
          if (isTerminalDebridFailoverFailure(error)) rethrow;
          if (!_directTorrentEnabled) rethrow;
          if (!await _confirmDirectPeerDownload(debridFailed: true)) return;
        } finally {
          await debridReady?.playbackLease?.close();
        }
      } else {
        if (!_directTorrentEnabled) {
          throw StateError(
            'Connect a Debrid service or enable Direct peer torrents in Settings.',
          );
        }
        if (!await _confirmDirectPeerDownload()) return;
      }
      if (!mounted) return;
      await _enqueueOfflineDownload(
        OfflineDownloadRequest(
          anilistMediaId: widget.episode.anilistMediaId,
          malMediaId: widget.episode.malMediaId,
          episode: widget.episode.episode,
          seriesTitle: widget.episode.title,
          episodeTitle: 'Episode ${widget.episode.episode}',
          sourceLabel: release.releaseName,
          transport: DownloadTransport.directPeer,
          providerId: release.sourceId,
          providerName: release.provider ?? 'Direct torrent',
          quality: release.quality,
          audioLabel: releaseAudioPickerLabel(release),
          mimeType: 'video/x-matroska',
          fileExtension: 'mkv',
          directPeerCapability: DirectPeerDownloadCapability(
            magnet: release.magnetUri,
            episode: widget.episode.episode,
            preferredFileIndex: release.preferredFileIndex,
          ),
        ),
      );
      _recordDownloadPreparationDiagnostic(
        sourceKind: 'torrent',
        stage: 'queue_enqueue',
        outcome: 'succeeded',
        transport: 'direct_peer',
      );
    } catch (error) {
      _recordDownloadPreparationDiagnostic(
        sourceKind: 'torrent',
        stage: 'source_resolution',
        outcome: 'failed',
        reasonCode: offlineDownloadPreparationReasonCode(error),
      );
      if (mounted) {
        _showDownloadMessage(offlineDownloadPreparationMessage(error));
      }
    } finally {
      if (mounted) setState(() => _preparingDownload = false);
    }
  }

  Future<void> _downloadWebStream(WebStreamResult stream) async {
    if (!_offlineDownloadsEnabled) return;
    if (_preparingDownload) return;
    if (webStreamRequiresExternalSubtitleDownload(stream)) {
      _showDownloadMessage(
        'This source uses separate captions that cannot be saved in this beta. Choose another source.',
      );
      return;
    }
    final details = [
      stream.providerName,
      stream.effectiveAudioCapability.pickerLabel,
      stream.quality,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' • ');
    if (!await _confirmSourceDownload(source: stream.title, details: details)) {
      return;
    }
    if (!mounted) return;
    setState(() => _preparingDownload = true);
    _recordDownloadPreparationDiagnostic(
      sourceKind: 'web',
      stage: 'stream_preflight',
      outcome: 'started',
    );
    ValidatedWebStream? validation;
    try {
      validation = await ref.read(webStreamPreflightProvider)(
        stream.uri,
        stream.headers,
        subtitleUri: stream.subtitleUri,
      );
      if (!mounted) return;
      await _enqueueOfflineDownload(
        OfflineDownloadRequest(
          anilistMediaId: widget.episode.anilistMediaId,
          malMediaId: widget.episode.malMediaId,
          episode: widget.episode.episode,
          seriesTitle: widget.episode.title,
          episodeTitle: 'Episode ${widget.episode.episode}',
          sourceLabel: stream.title,
          transport: DownloadTransport.https,
          sourceUri: stream.uri,
          providerId: stream.providerId,
          providerName: stream.providerName,
          quality: stream.quality,
          audioLabel: stream.effectiveAudioCapability.pickerLabel,
          mimeType: validation.contentType,
          fileExtension: _offlineFileExtension(
            stream.uri,
            validation.contentType,
          ),
          requestHeaders: sanitizeWebStreamHeaders(stream.headers),
        ),
      );
      _recordDownloadPreparationDiagnostic(
        sourceKind: 'web',
        stage: 'queue_enqueue',
        outcome: 'succeeded',
        transport: 'https',
      );
    } catch (error) {
      _recordDownloadPreparationDiagnostic(
        sourceKind: 'web',
        stage: 'stream_preflight',
        outcome: 'failed',
        reasonCode: offlineDownloadPreparationReasonCode(error),
      );
      if (mounted) {
        _showDownloadMessage(
          'This web source could not be prepared for download. Try another source.',
        );
      }
    } finally {
      await validation?.session?.close();
      if (mounted) setState(() => _preparingDownload = false);
    }
  }

  Future<void> _enqueueOfflineDownload(OfflineDownloadRequest request) async {
    final job = await ref
        .read(downloadManagerProvider.notifier)
        .enqueue(request);
    unawaited(_saveOfflineEpisodeMetadata(job));
    if (!mounted) return;
    _showDownloadMessage(
      'Episode ${widget.episode.episode} was added to Download Manager.',
      showManager: true,
    );
  }

  Future<void> _saveOfflineEpisodeMetadata(DownloadJob job) async {
    try {
      await ref
          .read(downloadRepositoryProvider)
          .upsertEpisodeMetadata(
            OfflineEpisodeMetadata(
              anilistMediaId: widget.episode.anilistMediaId,
              episode: widget.episode.episode,
              duration: null,
              metadata: {
                'title': 'Episode ${widget.episode.episode}',
                'sourceLabel': job.sourceLabel,
                if (job.providerName != null) 'provider': job.providerName,
                if (job.quality != null) 'quality': job.quality,
                if (job.audioLabel != null) 'audio': job.audioLabel,
              },
              updatedAt: DateTime.now().toUtc(),
            ),
          );
      AnimeSummary anime;
      try {
        anime = await ref.read(
          animeDetailsProvider(widget.episode.anilistMediaId).future,
        );
      } catch (_) {
        anime = AnimeSummary(
          id: widget.episode.anilistMediaId,
          idMal: widget.episode.malMediaId,
          title: widget.episode.title,
          titleEnglish: widget.episode.titleEnglish,
          titleRomaji: widget.episode.titleRomaji,
          description: 'Saved for offline playback.',
          episodes: widget.episode.episodeCount,
          score: null,
          coverImageUrl: widget.episode.coverImageUrl,
          synonyms: widget.episode.alternativeTitles,
          format: widget.episode.format,
          status: widget.episode.status,
          seasonYear: widget.episode.year,
          isAdult: widget.episode.isAdult,
        );
      }
      await ref.read(offlineCatalogSnapshotServiceProvider).pin(anime);
      ref.invalidate(offlineCatalogSnapshotsProvider);
    } catch (_) {
      // A download remains playable even if optional catalog artwork or
      // episode metadata cannot be cached on the first attempt.
    }
  }

  void _showDownloadMessage(String message, {bool showManager = false}) {
    if (!mounted) return;
    final router = GoRouter.maybeOf(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: showManager
            ? SnackBarAction(
                label: 'OPEN',
                onPressed: () => router?.push('/downloads'),
              )
            : null,
      ),
    );
  }

  void _recordDownloadPreparationDiagnostic({
    required String sourceKind,
    required String stage,
    required String outcome,
    String? transport,
    String? reasonCode,
  }) {
    unawaited(
      TetoTvDatabase.instance.recordDiagnosticEvent(
        category: 'download',
        message: 'Offline download preparation',
        severity: outcome == 'failed' ? 'warning' : 'info',
        details: {
          'source_kind': sourceKind,
          'stage': stage,
          'outcome': outcome,
          'transport': ?transport,
          'reason': ?reasonCode,
        },
      ),
    );
  }

  String _offlineFileExtension(Uri uri, String? mimeType) {
    final mime = mimeType?.toLowerCase().split(';').first.trim();
    if (mime == 'application/vnd.apple.mpegurl' ||
        mime == 'application/x-mpegurl' ||
        uri.path.toLowerCase().endsWith('.m3u8')) {
      // The offline transfer writes a sanitized local playlist plus sibling
      // media resources. Keeping the .m3u8 extension lets MPV resolve those
      // relative references without exposing the upstream playlist.
      return 'm3u8';
    }
    if (mime == 'video/mp4') return 'mp4';
    if (mime == 'video/webm') return 'webm';
    if (mime == 'video/mp2t') return 'ts';
    if (mime == 'video/x-matroska') return 'mkv';
    final match = RegExp(r'\.([A-Za-z0-9]{2,5})$').firstMatch(uri.path);
    final extension = match?.group(1)?.toLowerCase();
    return const {'mkv', 'mp4', 'webm', 'm4v', 'ts'}.contains(extension)
        ? extension!
        : 'mkv';
  }

  Future<void> _openDownloadedSource(DownloadedEpisodeAsset asset) async {
    if (!mounted || _resolving) return;
    setState(() {
      _resolving = true;
      _status = 'Opening downloaded episode…';
      _error = null;
    });
    try {
      if (!await asset.file.exists() || await asset.file.length() <= 0) {
        throw const FileSystemException('Downloaded episode is unavailable.');
      }
      if (!mounted) return;
      final launch = downloadedEpisodePlaybackLaunch(
        asset: asset,
        episode: widget.episode,
        requestedAudio: _requestedAudioFromFilter,
      );
      final playerUri = Uri(
        path: '/player',
        queryParameters: {
          'source': launch.stream.uri.toString(),
          'title': launch.stream.displayName,
          'anilistId': '${widget.episode.anilistMediaId}',
          if (widget.episode.malMediaId != null)
            'malId': '${widget.episode.malMediaId}',
          'episode': '${widget.episode.episode}',
          'watchPartyTargetSourceKey': ?_hostSourceKey,
        },
      );
      context.pushReplacement(playerUri.toString(), extra: launch);
    } on FileSystemException {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _downloadedAsset = null;
        _error = 'The downloaded episode is missing or incomplete.';
      });
      unawaited(_loadConfiguredReleases());
    }
  }

  Future<void> _openLibrarySource(
    LibraryEpisodeSource source, {
    bool automatic = false,
  }) async {
    if (_resolving) return;
    final generation = _releaseSearchGeneration;
    final requestedAudio = _requestedAudioFromFilter;
    if (automatic) {
      final deadlineExpired =
          _automaticResolveDeadline != null &&
          !widget.clock().isBefore(_automaticResolveDeadline!);
      if (!_autoPickActive ||
          _failedAutoPickLibrarySources.contains(source.stableKey) ||
          _autoPickRemainingAttemptBudget <= 0 ||
          deadlineExpired) {
        _finishAutoPickWithManualFallback();
        return;
      }
    }
    final attempt = ++_libraryResolveAttempt;
    setState(() {
      _resolving = true;
      _status = 'Opening ${source.origin.name} local source…';
      _error = null;
    });
    var retryAutomaticSelection = false;
    try {
      final service = ref.read(libraryEpisodeSourceServiceProvider);
      var request = await service.preparePlayback(
        source,
        watchPartyIdentity: _libraryWatchPartyIdentity,
        preferredSubtitleLanguage: _seriesPreferences.subtitleLanguage,
        requestedAudio: requestedAudio,
      );
      if (!mounted ||
          generation != _releaseSearchGeneration ||
          attempt != _libraryResolveAttempt ||
          (automatic && !_autoPickActive)) {
        return;
      }
      if (automatic) {
        // Unlike network streams, the private-library player is pushed above
        // this resolver. Stop the selection deadline while playback is active
        // so it cannot reveal a stale manual fallback underneath the player.
        _autoPickDeadlineTimer?.cancel();
        _autoPickDeadlineTimer = null;
      }
      var result = await _openLibraryPlayer(request, automatic: automatic);
      var recovery = libraryPlaybackRecoveryAction(
        result: result,
        supportsCompatibilityTranscode: source.supportsCompatibilityTranscode,
        usedCompatibilityStream: request.isCompatibilityStream,
      );
      if (recovery == LibraryPlaybackRecoveryAction.retryCompatibility) {
        if (!mounted ||
            generation != _releaseSearchGeneration ||
            attempt != _libraryResolveAttempt ||
            (automatic && !_autoPickActive)) {
          return;
        }
        setState(() {
          _status = 'Trying a compatible stream from the media server…';
          _error = null;
        });
        request = await service.preparePlayback(
          source,
          watchPartyIdentity: _libraryWatchPartyIdentity,
          preferredSubtitleLanguage: _seriesPreferences.subtitleLanguage,
          requestedAudio: requestedAudio,
          forceCompatibility: true,
        );
        if (!mounted ||
            generation != _releaseSearchGeneration ||
            attempt != _libraryResolveAttempt ||
            (automatic && !_autoPickActive)) {
          return;
        }
        result = await _openLibraryPlayer(request, automatic: automatic);
        recovery = libraryPlaybackRecoveryAction(
          result: result,
          supportsCompatibilityTranscode: source.supportsCompatibilityTranscode,
          // This came from the explicit compatibility branch. A failed retry
          // is terminal even if a lightweight service double omits the marker.
          usedCompatibilityStream: true,
        );
      }
      if (recovery == LibraryPlaybackRecoveryAction.finish && automatic) {
        _finishAutoPickWithManualFallback(
          notice: result?.completed == true
              ? 'Playback finished. Choose another source below.'
              : 'Playback closed. Choose a source below to play again.',
        );
        return;
      }
      if (recovery == LibraryPlaybackRecoveryAction.advanceSource) {
        throw const _LibraryPlaybackStartupException();
      }
    } catch (error, stackTrace) {
      if (!mounted ||
          generation != _releaseSearchGeneration ||
          attempt != _libraryResolveAttempt) {
        return;
      }
      if (automatic) {
        _failedAutoPickLibrarySources.add(source.stableKey);
        unawaited(
          recordAnonymousHandledError(
            area: AnonymousErrorArea.playback,
            error: error,
            stack: stackTrace,
          ),
        );
        final withinBudget =
            _autoPickFailedAttemptCount < _maxAutomaticResolveCandidates &&
            (_automaticResolveDeadline == null ||
                widget.clock().isBefore(_automaticResolveDeadline!));
        final remainingTier = _autoPickCandidateTier();
        final hasRemainingCandidate =
            remainingTier.releases.isNotEmpty ||
            remainingTier.web.isNotEmpty ||
            remainingTier.library.isNotEmpty;
        if (withinBudget &&
            (hasRemainingCandidate ||
                remainingTier.waiting ||
                _automaticDiscoveryPending)) {
          setState(() {
            _resolving = false;
            _autoPlayStarted = false;
            _status = _automaticDiscoveryPending
                ? 'That media item failed. Waiting for other sources…'
                : 'That media item failed. Trying another stream…';
            _error = null;
          });
          retryAutomaticSelection = true;
        } else {
          _finishAutoPickWithManualFallback();
        }
      } else {
        setState(() {
          _error =
              'This private-library episode could not be prepared. Refresh '
              'the media source and try again.';
        });
      }
    } finally {
      if (mounted &&
          generation == _releaseSearchGeneration &&
          attempt == _libraryResolveAttempt &&
          _resolving) {
        setState(() => _resolving = false);
      }
    }
    if (retryAutomaticSelection && mounted) {
      Future<void>.microtask(
        () => _tryStartAutoPlay(
          generation: generation,
          allowWebFallback: _debridSearchFinished,
        ),
      );
    }
  }

  Future<LibraryPlaybackResult?> _openLibraryPlayer(
    LibraryPlaybackRequest request, {
    required bool automatic,
  }) => ref.read(libraryPlaybackRouteOpenerProvider)(
    context,
    request,
    automatic: automatic,
  );

  LibraryWatchPartyIdentity get _libraryWatchPartyIdentity =>
      LibraryWatchPartyIdentity(
        anilistMediaId: widget.episode.anilistMediaId,
        episode: widget.episode.episode,
        title: widget.episode.title,
        episodeCount: widget.episode.episodeCount,
      );

  Future<void> _openWebStream(
    WebStreamResult stream, {
    List<WebStreamResult>? autoplayCandidates,
  }) async {
    if (!mounted || _resolving) return;
    // WidgetRef belongs to this route and becomes invalid as soon as the
    // resolver is replaced. Capture the long-lived dependencies before the
    // asynchronous preflight so a late completion never reads a disposed ref.
    final preflight = ref.read(webStreamPreflightProvider);
    final addonStore = ref.read(addonStoreProvider);
    final preferredAudio = _preferredAudio;
    final requestedAudio = _requestedAudioFromFilter;
    final hasConnectedDebrid = _hasDebrid;
    final fallbackDebridService = _debridService;
    final episode = widget.episode;
    final generation = _releaseSearchGeneration;
    final automatic = autoplayCandidates != null;
    bool autoPickCancelled() =>
        automatic && _autoPickEnabledForOpen && _autoPickManualFallback;
    final availableBudget = automatic
        ? (_autoPickActive
              ? _autoPickRemainingAttemptBudget
              : (_maxAutomaticResolveCandidates -
                        _failedAutoplayWebStreams.length)
                    .clamp(0, _maxAutomaticResolveCandidates))
        : 1;
    if (automatic && availableBudget <= 0) {
      if (_autoPickActive) {
        _finishAutoPickWithManualFallback();
        return;
      }
      setState(() {
        _resolving = false;
        _loadingReleases = false;
        _autoPlayStarted = true;
        _autoplayBudgetExhausted = true;
        _status = 'Automatic stream checks exhausted';
        _error = 'No playable stream passed the bounded preflight checks.';
      });
      return;
    }
    final seen = <String>{};
    final candidates = <WebStreamResult>[];
    for (final candidate in autoplayCandidates ?? [stream]) {
      final key = _webStreamKey(candidate);
      if (_failedAutoplayWebStreams.contains(key) || !seen.add(key)) continue;
      candidates.add(candidate);
      if (candidates.length >= availableBudget) break;
    }
    if (candidates.isEmpty) {
      if (automatic) {
        _autoPlayStarted = false;
        if (_autoPickActive && !_automaticDiscoveryPending) {
          _finishAutoPickWithManualFallback();
        }
      }
      return;
    }
    final discoveredStreams = [..._webStreams];
    setState(() {
      _resolving = true;
      _status = 'Checking ${stream.providerName} stream…';
      _error = null;
    });
    Object? lastError;
    for (final candidate in candidates) {
      if (!mounted ||
          generation != _releaseSearchGeneration ||
          autoPickCancelled()) {
        return;
      }
      if (automatic &&
          _automaticResolveDeadline != null &&
          !widget.clock().isBefore(_automaticResolveDeadline!)) {
        break;
      }
      setState(() => _status = 'Checking ${candidate.providerName} stream…');
      ValidatedWebStream? validated;
      var leaseTransferred = false;
      try {
        validated = await preflight(
          candidate.uri,
          candidate.headers,
          subtitleUri: candidate.subtitleUri,
        );
        try {
          await addonStore.recordProviderSuccess(candidate.providerId);
        } catch (_) {
          // Provider health accounting is best-effort and never gates play.
        }
        if (!mounted ||
            generation != _releaseSearchGeneration ||
            autoPickCancelled()) {
          await validated.session?.close();
          return;
        }
        final release = _releaseForWebStream(candidate);
        final alternativeHashes = <String>{release.infoHash.toLowerCase()};
        final debridAlternatives = hasConnectedDebrid
            ? _autoplayReleaseCandidates(
                    _releases,
                    preferredQualityHeight: releaseQualityHeight(release),
                  )
                  .where(
                    (alternative) =>
                        !_failedResolveHashes.contains(
                          alternative.infoHash.toLowerCase(),
                        ) &&
                        alternativeHashes.add(
                          alternative.infoHash.toLowerCase(),
                        ),
                  )
                  .toList(growable: false)
            : const <ReleaseCandidate>[];
        await _rememberStreamSelection(release);
        if (!mounted ||
            generation != _releaseSearchGeneration ||
            autoPickCancelled()) {
          await validated.session?.close();
          return;
        }
        final ready = _readyForWebStream(
          candidate,
          validatedUri: validated.uri,
          validatedHeaders: validated.headers,
          validatedSubtitleUri: validated.subtitleUri,
          mediaContentType: validated.contentType,
          subtitleContentType: validated.subtitleContentType,
          externalSubtitleRejected: validated.subtitleRejected,
          playbackLease: validated.session,
        );
        verifyPlaybackEpisodeIdentity(
          episode: episode,
          stream: ready,
          release: release,
        );
        final alternativeSeen = <String>{};
        final directAlternatives = <WebStreamResult>[];
        for (final alternative in [...discoveredStreams, ...candidates]) {
          final key = _webStreamKey(alternative);
          if (alternative.uri == candidate.uri || !alternativeSeen.add(key)) {
            continue;
          }
          directAlternatives.add(alternative);
        }
        directAlternatives.sort(
          (left, right) => compareAutoplayWebStreams(
            left,
            right,
            preferredAudio: preferredAudio,
            preferredWebProviderId: candidate.providerId,
            preferredQualityHeight: webStreamQualityHeight(candidate),
            qualityPreference: _streamPreferences.webStreamQuality,
          ),
        );
        final playerUri = Uri(
          path: '/player',
          queryParameters: {
            'source': validated.uri.toString(),
            'title': '${episode.title} / Episode ${episode.episode}',
            'anilistId': '${episode.anilistMediaId}',
            if (episode.malMediaId != null) 'malId': '${episode.malMediaId}',
            'episode': '${episode.episode}',
            'watchPartyTargetSourceKey': ?_hostSourceKey,
            if (debridAlternatives.isNotEmpty)
              'debrid': fallbackDebridService.slug,
          },
        );
        setState(() => _resolving = false);
        _prepareExactWatchPartySourceHandoff(release);
        context.pushReplacement(
          playerUri.toString(),
          extra: PlaybackLaunch(
            stream: ready,
            episode: episode,
            selectedRelease: release,
            requestedAudio: requestedAudio,
            alternatives: debridAlternatives,
            directAlternatives: directAlternatives
                .map(
                  (alternative) => PlaybackStreamOption(
                    stream: _readyForWebStream(alternative),
                    release: _releaseForWebStream(alternative),
                  ),
                )
                .toList(growable: false),
          ),
        );
        leaseTransferred = true;
        return;
      } catch (error, stackTrace) {
        if (!leaseTransferred) {
          await validated?.session?.close();
        }
        final failureReason = error is EpisodeIdentityMismatchException
            ? error.reasonCode
            : error is TimeoutException
            ? 'timeout'
            : 'validation_failed';
        final safeFailure = error is EpisodeIdentityMismatchException
            ? error
            : StateError('Web stream preflight failed ($failureReason).');
        lastError = safeFailure;
        if (automatic) {
          _failedAutoplayWebStreams.add(_webStreamKey(candidate));
        }
        unawaited(
          recordAnonymousHandledError(
            area: AnonymousErrorArea.playback,
            error: safeFailure,
            stack: stackTrace,
          ),
        );
        try {
          await addonStore.recordProviderFailure(
            candidate.providerId,
            safeFailure,
          );
        } catch (_) {
          // Provider health accounting is best-effort.
        }
        try {
          await TetoTvDatabase.instance.recordDiagnosticEvent(
            category: 'stream-preflight',
            message:
                'provider=${_boundedDiagnosticField(candidate.providerId)} '
                'stage=preflight status=failed reason=$failureReason',
          );
        } catch (_) {
          // Local diagnostics must never stop deterministic failover.
        }
      }
    }
    if (!mounted ||
        generation != _releaseSearchGeneration ||
        autoPickCancelled()) {
      return;
    }
    if (automatic && _automaticDebridSearchPending) {
      setState(() {
        _resolving = false;
        _autoPlayStarted = false;
        _status = _useDirectTorrent
            ? 'Web streams failed. Waiting for torrent sources…'
            : 'Web streams failed. Waiting for Debrid sources…';
        _error = null;
      });
      return;
    }
    final automaticBudgetExpired =
        automatic &&
        ((_automaticResolveDeadline != null &&
                !widget.clock().isBefore(_automaticResolveDeadline!)) ||
            (_autoPickActive
                ? _autoPickFailedAttemptCount >= _maxAutomaticResolveCandidates
                : _failedAutoplayWebStreams.length >=
                      _maxAutomaticResolveCandidates));
    if (automaticBudgetExpired) {
      if (_autoPickActive) {
        _finishAutoPickWithManualFallback();
        return;
      }
      setState(() {
        _resolving = false;
        _loadingReleases = false;
        _autoPlayStarted = true;
        _autoplayBudgetExhausted = true;
        _status = 'Automatic stream checks timed out';
        _error = (lastError ?? 'No playable stream passed preflight in time.')
            .toString()
            .replaceFirst('FormatException: ', '');
      });
      return;
    }
    if (automatic && _automaticWebSearchPending && !_preferredWebWaitExpired) {
      setState(() {
        _resolving = false;
        _autoPlayStarted = false;
        _status = 'Waiting for the remaining web providers…';
        _error = null;
      });
      return;
    }
    final remainingTier = _autoPickActive ? _autoPickCandidateTier() : null;
    final canRetryDebrid = remainingTier == null
        ? !_autoplayDebridExhausted &&
              _releases.any(
                (release) => !_failedResolveHashes.contains(
                  release.infoHash.toLowerCase(),
                ),
              )
        : remainingTier.releases.isNotEmpty;
    final canRetryWeb =
        remainingTier?.web.isNotEmpty ??
        _autoplayWebCandidates(_webStreams).isNotEmpty;
    final canRetryLibrary = remainingTier?.library.isNotEmpty ?? false;
    if (automatic && (canRetryDebrid || canRetryWeb || canRetryLibrary)) {
      setState(() {
        _resolving = false;
        _autoPlayStarted = false;
        _status = 'Trying another stream…';
        _error = null;
      });
      Future<void>.microtask(
        () => _tryStartAutoPlay(generation: generation, allowWebFallback: true),
      );
      return;
    }
    if (_autoPickActive) {
      _finishAutoPickWithManualFallback();
      return;
    }
    setState(() {
      _resolving = false;
      if (automatic) {
        // Once the preferred-provider discovery window has elapsed, an
        // exhausted candidate set is terminal even if unrelated providers
        // remain hung. Keep autoplay out of the manual picker and make Retry
        // start a genuinely fresh provider session.
        _loadingReleases = false;
        _autoplayBudgetExhausted = true;
        _autoPlayStarted = true;
      }
      _status = 'Stream check failed';
      _error = (lastError ?? 'No playable web stream passed preflight.')
          .toString()
          .replaceFirst('FormatException: ', '');
    });
  }

  void _resolveManual() {
    final magnet = _magnetController.text.trim();
    if (!magnet.startsWith('magnet:?')) {
      setState(() => _error = 'Enter a valid magnet URI.');
      return;
    }
    final source = _ManualReleaseSource(magnet);
    _beginResolveSequence();
    _resolve(source, selected: source.candidate(widget.episode));
  }

  Future<void> _resolveCandidate(
    ReleaseCandidate candidate, {
    bool continueAutomaticSequence = false,
  }) async {
    if (!_canPlayTorrentReleases) {
      await context.push('/settings/accounts');
      if (!mounted) return;
      await _initialize();
      return;
    }
    if (!continueAutomaticSequence) _beginResolveSequence();
    await _rememberStreamSelection(candidate);
    if (!mounted) return;
    await _resolve(_SelectedReleaseSource(candidate), selected: candidate);
  }

  void _beginResolveSequence() {
    _failedResolveHashes.clear();
    _automaticResolveDeadline ??= widget.clock().add(
      _automaticResolveTimeBudget,
    );
  }

  String _exhaustedReleaseMessage(int attempted) {
    final subject = attempted == 1
        ? 'the selected release'
        : '$attempted different releases';
    return 'Real-Debrid could not provide $subject. Choose another authorized '
        'source or try again later.';
  }

  Future<void> _recordRealDebridFailure(
    RealDebridException error,
    String sourceId,
  ) async {
    try {
      await TetoTvDatabase.instance.recordDiagnosticEvent(
        category: 'debrid-resolution',
        message: 'Real-Debrid resolution failure',
        details: {
          'service': DebridService.realDebrid.slug,
          'kind': error.kind.name,
          if (error.code != null) 'code': error.code,
          'sourceId': _safeDiagnosticSourceId(sourceId),
        },
      );
    } catch (_) {
      // Diagnostics are best-effort and must never block failover.
    }
  }

  String _safeDiagnosticSourceId(String sourceId) {
    if (sourceId.contains('://')) return 'external-source';
    final withoutHashes = sourceId.replaceAll(
      RegExp(r'[a-f0-9]{32,64}', caseSensitive: false),
      'redacted',
    );
    return withoutHashes
        .replaceAll(RegExp(r'[^a-zA-Z0-9:._-]'), '_')
        .substring(0, withoutHashes.length.clamp(0, 64));
  }

  List<ReleaseCandidate> _filteredAndSortedReleases(
    Iterable<ReleaseCandidate> releases, {
    bool ignoreOptionalFilters = false,
  }) {
    final filtered = releases.where((release) {
      return _releaseMatchesEpisodeIdentity(release) &&
          releaseMatchesStreamFilters(
            release,
            language: ignoreOptionalFilters ? 'all' : _languageFilter.name,
            quality: ignoreOptionalFilters ? 'any' : _qualityFilter.name,
            codec: ignoreOptionalFilters ? 'any' : _codecFilter.name,
            hdr: ignoreOptionalFilters ? 'any' : _hdrFilter.name,
            allowBatch: ignoreOptionalFilters || _allowBatchStreams,
          );
    }).toList();
    filtered.sort(
      (left, right) => compareStreamReleases(
        left,
        right,
        device: _deviceProfile,
        failureCounts: _failureCounts,
        sortMode: _sortMode.name,
        preferredProvider: _seriesPreferences.preferredReleaseProvider,
        preferredReleaseGroup: _seriesPreferences.preferredReleaseGroup,
        preferredAudio: _preferredAudio,
        rankingPreference: _debridRanking,
      ),
    );
    return filtered;
  }

  bool _releaseMatchesEpisodeIdentity(ReleaseCandidate release) =>
      !assessEpisodeIdentityLabel(
        label: release.releaseName,
        requestedEpisode: widget.episode.episode,
        requestedSeason: catalogSeasonNumber(widget.episode),
      ).isMismatch;

  bool _webStreamMatchesEpisodeIdentity(WebStreamResult stream) {
    final explicit = assessExplicitProviderEpisodeIdentity(
      episode: widget.episode,
      episodeNumber: stream.matchedEpisodeNumber,
      seasonNumber: stream.matchedSeasonNumber,
      seriesTitle: stream.matchedSeriesTitle,
    );
    if (explicit.isMatch) return true;
    if (explicit.isMismatch) return false;
    return !assessEpisodeIdentityLabel(
      label: stream.title,
      requestedEpisode: widget.episode.episode,
      requestedSeason: catalogSeasonNumber(widget.episode),
    ).isMismatch;
  }

  Future<void> _rememberPickerPreferences() async {
    final writePreferences = ref.read(seriesPreferencesWriterProvider);
    if (_languageFilter != _StreamLanguageFilter.all) {
      unawaited(
        ref
            .read(settingsPreferencesProvider.notifier)
            .setPreferredAudio(
              _languageFilter == _StreamLanguageFilter.dub
                  ? PlaybackAudioPreference.dub
                  : PlaybackAudioPreference.sub,
            ),
      );
    }
    _seriesPreferences = _seriesPreferences.copyWith(
      preferredStreamLanguage: _languageFilter.name,
      preferredQuality: _qualityFilter.name,
      preferredCodec: _codecFilter.name,
      preferredHdrMode: _hdrFilter.name,
      allowBatchStreams: _allowBatchStreams,
      streamSortMode: _sortMode.name,
    );
    try {
      await writePreferences(widget.episode.anilistMediaId, _seriesPreferences);
    } catch (_) {
      // A local preference write must never block stream selection.
    }
  }

  Future<void> _rememberStreamSelection(ReleaseCandidate candidate) async {
    final writePreferences = ref.read(seriesPreferencesWriterProvider);
    _seriesPreferences = _seriesPreferences.copyWith(
      preferredReleaseProvider: candidate.provider,
      clearPreferredReleaseProvider: candidate.provider == null,
      preferredReleaseGroup: releaseGroupKey(candidate.releaseName),
      clearPreferredReleaseGroup:
          releaseGroupKey(candidate.releaseName) == null,
    );
    try {
      await writePreferences(widget.episode.anilistMediaId, _seriesPreferences);
    } catch (_) {
      // A local preference write must never block playback.
    }
  }

  void _updatePicker(VoidCallback update) {
    setState(update);
    unawaited(_rememberPickerPreferences());
  }

  /// Watch Together followers can enter this route with pushReplacement,
  /// leaving no route beneath it. Keep repeated Back activations idempotent
  /// and always provide a deterministic root destination.
  void _returnFromResolver() {
    if (!mounted || _returningFromResolver) return;
    _returningFromResolver = true;
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }
    if (widget.watchPartyFollow) {
      router.go('/watch-together');
      return;
    }
    final mediaId = widget.episode.anilistMediaId;
    router.go(mediaId > 0 ? '/anime/$mediaId' : '/');
  }

  void _updateStreamSort(_StreamSortMode value) {
    _updatePicker(() => _sortMode = value);
    unawaited(
      ref
          .read(settingsPreferencesProvider.notifier)
          .setDebridStreamSort(_debridRanking),
    );
  }

  String get _sourceSearchStatus {
    final progress = <String>[];
    if (_debridSourcesTotal > 0) {
      progress.add(
        '${_useDirectTorrent ? 'Torrent' : 'Debrid'} '
        '$_debridSourcesCompleted/$_debridSourcesTotal',
      );
    }
    if (_webProvidersTotal > 0) {
      progress.add('Web $_webProvidersCompleted/$_webProvidersTotal');
    }
    if (_librarySearchEnabled) {
      progress.add(
        _librarySearchFinished ? 'Local sources ready' : 'Local sources',
      );
    }
    final pending = [..._pendingDebridSources, ..._pendingWebProviders];
    final pendingLabel = pending.take(3).join(', ');
    final remaining = pending.length - 3;
    final detail = pendingLabel.isEmpty
        ? ''
        : ' • Waiting for $pendingLabel${remaining > 0 ? ' +$remaining' : ''}';
    return '${progress.isEmpty ? 'Starting providers' : progress.join(' • ')}$detail';
  }

  @override
  void dispose() {
    _releaseSearchGeneration++;
    _preferredWebWaitTimer?.cancel();
    _autoPickDeadlineTimer?.cancel();
    _magnetController.dispose();
    _streamSearchController.dispose();
    _streamSearchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        minimum: context.responsiveScreenPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _BackButton(onPressed: _returnFromResolver),
                const SizedBox(width: 18),
                Expanded(
                  child: Text(
                    '${widget.episode.title} • Episode '
                    '${widget.episode.episode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ],
            ),
            Expanded(child: Center(child: _body(context))),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loadingAccount) {
      return CircularProgressIndicator(
        color: context.appPalette.secondaryAccent,
      );
    }
    if (_stableResolveShellVisible) {
      return SizedBox(
        key: const ValueKey('resolve-opening-shell'),
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_download_rounded,
              size: 68,
              color: context.appPalette.secondaryAccent,
            ),
            const SizedBox(height: 20),
            Text(_status, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 18),
            LinearProgressIndicator(
              value: _progress <= 0 ? null : _progress,
              minHeight: 6,
              backgroundColor: context.appPalette.primaryText.withValues(
                alpha: .12,
              ),
              color: context.appPalette.accentBright,
            ),
            const SizedBox(height: 12),
            Text(
              'Cached releases normally complete in a few seconds.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    if (_loadingReleases &&
        !_autoPickManualFallback &&
        ((_downloadedAsset == null &&
                _releases.isEmpty &&
                _webStreams.isEmpty &&
                _librarySources.isEmpty) ||
            (_automaticSelectionActive && !_autoPlayStarted))) {
      return SizedBox(
        key: const ValueKey('resolve-search-shell'),
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: context.appPalette.secondaryAccent,
            ),
            const SizedBox(height: 22),
            Text(_status, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _sourceSearchStatus,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    // This must remain reactive while the picker is open. The master
    // Downloads switch can change from Settings without recreating this
    // route; watching it here removes/restores long-press download actions
    // immediately even when there is no completed local asset to refresh.
    final sourcePreferences = ref.watch(settingsPreferencesProvider);
    final everyDiscoveredWebStreamFailed =
        _webStreams.isNotEmpty &&
        _webStreams.every(
          (stream) => _failedAutoplayWebStreams.contains(_webStreamKey(stream)),
        );
    final autoplayFallbacksExhausted =
        _autoplayBudgetExhausted ||
        (_autoplayDebridExhausted &&
            (!_webSearchEnabled ||
                (_webSearchFinished &&
                    (_webStreams.isEmpty || everyDiscoveredWebStreamFailed))));
    final autoplayHasNoResult =
        widget.episode.autoPlay &&
        !_autoplayManualFallback &&
        !_loadingReleases &&
        !_resolving &&
        ((_downloadedAsset == null &&
                _releases.isEmpty &&
                _webStreams.isEmpty &&
                _librarySources.isEmpty) ||
            autoplayFallbacksExhausted ||
            (_webSearchFinished &&
                everyDiscoveredWebStreamFailed &&
                _releases.isEmpty));
    if (autoplayHasNoResult) {
      return _Message(
        icon: Icons.error_outline_rounded,
        title: 'No playable stream found',
        body: widget.watchPartyFollow
            ? 'The host changed episodes, but TetoTV could not choose a '
                  'playable source automatically. Choose a source manually '
                  'or retry; you remain in the Watch Party.'
            : _error ??
                  'Automatic playback checked every available source. Try the '
                      'search again or go back to the episode page.',
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionButton(
              label: 'Back',
              icon: Icons.arrow_back_rounded,
              onPressed: _returnFromResolver,
            ),
            const SizedBox(width: 12),
            if (widget.watchPartyFollow) ...[
              _ActionButton(
                label: 'Choose source',
                icon: Icons.list_rounded,
                onPressed: () => setState(() {
                  _autoplayManualFallback = true;
                  _autoPlayStarted = false;
                }),
              ),
              const SizedBox(width: 12),
            ],
            _ActionButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onPressed: () {
                setState(() => _autoplayManualFallback = false);
                _loadConfiguredReleases(refreshWeb: true);
              },
            ),
          ],
        ),
      );
    }
    if (widget.episode.autoPlay && _autoPlayStarted) {
      return SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: context.appPalette.secondaryAccent,
            ),
            const SizedBox(height: 22),
            Text(
              'Opening the selected stream…',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (!_showManual &&
        (_downloadedAsset != null ||
            _canPlayTorrentReleases ||
            _webStreams.isNotEmpty ||
            _librarySources.isNotEmpty)) {
      final filtered = _filteredAndSortedReleases(_releases)
          .where(
            (release) =>
                releaseMatchesLocalStreamSearch(release, _streamSearchQuery),
          )
          .toList(growable: false);
      final filteredWeb = _filteredWebStreams(_webStreams)
          .where(
            (stream) => webStreamMatchesLocalSearch(stream, _streamSearchQuery),
          )
          .toList(growable: false);
      final filteredLibrary = _librarySources
          .where(
            (source) =>
                libraryStreamMatchesLocalSearch(source, _streamSearchQuery),
          )
          .toList(growable: false);
      final filteredDownload = switch (_downloadedAsset) {
        final download?
            when sourcePreferences.offlineDownloadsEnabled &&
                downloadedStreamMatchesLocalSearch(
                  download,
                  _streamSearchQuery,
                ) =>
          download,
        _ => null,
      };
      return _StreamPicker(
        releases: filtered,
        totalCount: _releases.length,
        webStreams: filteredWeb,
        webTotalCount: _webStreams.length,
        librarySources: filteredLibrary,
        libraryTotalCount: _librarySources.length,
        downloadedSource: filteredDownload,
        hasDownloadedSource:
            sourcePreferences.offlineDownloadsEnabled &&
            _downloadedAsset != null,
        libraryFailures: _libraryFailures,
        libraryEnabled: _librarySearchEnabled,
        failedWebProviders: _webFailures
            .where(
              (failure) =>
                  failure.status == WebProviderFailureStatus.failed ||
                  failure.status == WebProviderFailureStatus.unavailable,
            )
            .length,
        webFailures: _webFailures,
        failedDebridSources: _releaseFailures.length,
        isSearching: _loadingReleases,
        searchStatus: _sourceSearchStatus,
        debridEnabled: _canPlayTorrentReleases,
        directTorrentMode: _useDirectTorrent,
        webEnabled: sourcePreferences.webStreamsEnabled,
        connectedServices: _connectedServices,
        selectedService: _debridService,
        onServiceChanged: (value) => setState(() => _debridService = value),
        filter: _languageFilter,
        onFilterChanged: (value) =>
            _updatePicker(() => _languageFilter = value),
        qualityFilter: _qualityFilter,
        onQualityChanged: (value) =>
            _updatePicker(() => _qualityFilter = value),
        codecFilter: _codecFilter,
        onCodecChanged: (value) => _updatePicker(() => _codecFilter = value),
        hdrFilter: _hdrFilter,
        onHdrChanged: (value) => _updatePicker(() => _hdrFilter = value),
        sortMode: _sortMode,
        onSortChanged: _updateStreamSort,
        sourcePriority: sourcePreferences.streamSourcePriority,
        showAdvancedFilters: _showAdvancedFilters,
        onAdvancedFiltersChanged: (value) =>
            setState(() => _showAdvancedFilters = value),
        allowBatchStreams: _allowBatchStreams,
        onBatchChanged: (value) =>
            _updatePicker(() => _allowBatchStreams = value),
        onSelected: _resolveCandidate,
        onReleaseDownload: sourcePreferences.offlineDownloadsEnabled
            ? _downloadRelease
            : null,
        onWebSelected: _openWebStream,
        onWebDownload: sourcePreferences.offlineDownloadsEnabled
            ? _downloadWebStream
            : null,
        onLibrarySelected: _openLibrarySource,
        onDownloadedSelected: _openDownloadedSource,
        autoPickNotice: _autoPickNotice,
        error: _error,
        onRetry: _lastAttemptedRelease == null
            ? null
            : () => _resolveCandidate(_lastAttemptedRelease!),
        onRefresh: () => _loadConfiguredReleases(refreshWeb: true),
        searchController: _streamSearchController,
        searchFocusNode: _streamSearchFocusNode,
        searchQuery: _streamSearchQuery,
        onSearchChanged: (value) => setState(() {
          _streamSearchQuery = value.trim();
        }),
        onSearchCleared: () => setState(() {
          _streamSearchController.clear();
          _streamSearchQuery = '';
        }),
      );
    }
    if (_downloadedAsset == null &&
        !_canPlayTorrentReleases &&
        _webStreams.isEmpty &&
        _librarySources.isEmpty) {
      final localOnly =
          _librarySearchEnabled &&
          !sourcePreferences.debridStreamsEnabled &&
          !sourcePreferences.directTorrentStreamingEnabled &&
          !sourcePreferences.webStreamsEnabled;
      final localUnavailable = localOnly && _libraryFailures.isNotEmpty;
      final directTorrentUnavailable =
          sourcePreferences.directTorrentStreamingEnabled &&
          !_directTorrentSupported;
      return _Message(
        icon: localOnly ? Icons.video_library_outlined : Icons.stream_rounded,
        title: localUnavailable
            ? 'A local media server is unavailable'
            : localOnly
            ? 'This episode is not in your local sources'
            : 'No stream source is ready',
        body: localUnavailable
            ? 'TetoTV could not search ${_libraryFailures.join(' or ')}. '
                  'Check the connection in Media sources and try again.'
            : localOnly
            ? 'TetoTV checked the connected Jellyfin/Plex libraries using '
                  'the catalog title aliases and exact episode number. Check '
                  'Media sources in Settings if the library name needs attention.'
            : directTorrentUnavailable
            ? 'Direct torrent playback is unavailable on this device or CPU. '
                  'Connect a supported debrid service instead.'
            : sourcePreferences.webStreamsEnabled
            ? 'Connect a supported debrid service, or install a compatible Web '
                  'Stream provider from Marketplace.'
            : 'Connect a supported debrid service, or explicitly enable Direct '
                  'torrent in Streaming sources. Direct peer playback is off by '
                  'default and shows a privacy warning before it is enabled.',
        action: _ActionButton(
          label: localOnly
              ? 'Manage media sources'
              : directTorrentUnavailable
              ? 'Open accounts'
              : sourcePreferences.webStreamsEnabled
              ? 'Open marketplace'
              : 'Open accounts',
          icon: localOnly
              ? Icons.video_library_rounded
              : Icons.settings_rounded,
          onPressed: () => _openSourceSettings(
            localOnly
                ? '/settings/local-media'
                : directTorrentUnavailable
                ? '/settings/accounts'
                : sourcePreferences.webStreamsEnabled
                ? '/settings/marketplace'
                : '/settings/accounts',
          ),
        ),
      );
    }
    return _manualPanel(context);
  }

  Widget _manualPanel(BuildContext context) {
    final palette = context.appPalette;
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(
        top: 12,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Container(
        width: 780,
        padding: const EdgeInsets.all(30),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: palette.primaryText.withValues(alpha: .08)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _releases.isNotEmpty ? 'Paste a magnet' : 'Add a release',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              _releases.isNotEmpty
                  ? 'Use a magnet for content you are authorized to access.'
                  : ref.read(configuredReleaseSourceProvider) != null
                  ? 'Automatic matching did not return a playable stream. '
                        'You can provide a magnet manually.'
                  : 'No torrent source is configured. Add a source manifest '
                        'in Marketplace, or paste a magnet for content you are '
                        'authorized to access.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              Text(error, style: const TextStyle(color: Color(0xFFFF929B))),
            ],
            const SizedBox(height: 20),
            if (_releases.isNotEmpty) ...[
              _ActionButton(
                label: 'Back to streams',
                icon: Icons.view_list_rounded,
                onPressed: () => setState(() => _showManual = false),
              ),
              const SizedBox(height: 14),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final input = TvTextInput(
                  controller: _magnetController,
                  autofocus: true,
                  labelText: 'Magnet URI',
                  hintText: 'Select to type or paste a magnet link',
                  keyboardTitle: 'Enter magnet URI',
                  onSubmitted: (_) => _resolveManual(),
                );
                final action = _ActionButton(
                  label: _useDirectTorrent
                      ? 'Play direct torrent'
                      : 'Send to ${_debridService.displayName}',
                  icon: Icons.play_arrow_rounded,
                  onPressed: _resolveManual,
                );
                if (constraints.maxWidth < 600) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      input,
                      const SizedBox(height: 10),
                      Align(alignment: Alignment.centerRight, child: action),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: input),
                    const SizedBox(width: 14),
                    action,
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectedReleaseSource implements ReleaseSource {
  const _SelectedReleaseSource(this.release);

  final ReleaseCandidate release;

  @override
  String get id => release.sourceId;

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async => [
    release,
  ];
}

enum _StreamLanguageFilter { all, sub, dub }

enum _StreamQualityFilter { any, p2160, p1080, p720 }

enum _StreamCodecFilter { any, h264, hevc, av1 }

enum _StreamHdrFilter { any, sdr, hdr }

enum _StreamSortMode { compatibility, seeders, largest, size }

_StreamSortMode _pickerSortMode(DebridStreamSort preference) =>
    switch (preference) {
      DebridStreamSort.bestQuality => _StreamSortMode.compatibility,
      DebridStreamSort.mostSeeded => _StreamSortMode.seeders,
      DebridStreamSort.largestSize => _StreamSortMode.largest,
      DebridStreamSort.smallestSize => _StreamSortMode.size,
    };

class _StreamPicker extends StatelessWidget {
  const _StreamPicker({
    required this.releases,
    required this.totalCount,
    required this.webStreams,
    required this.webTotalCount,
    required this.librarySources,
    required this.libraryTotalCount,
    required this.downloadedSource,
    required this.hasDownloadedSource,
    required this.libraryFailures,
    required this.libraryEnabled,
    required this.failedWebProviders,
    required this.webFailures,
    required this.failedDebridSources,
    required this.isSearching,
    required this.searchStatus,
    required this.debridEnabled,
    required this.directTorrentMode,
    required this.webEnabled,
    required this.connectedServices,
    required this.selectedService,
    required this.onServiceChanged,
    required this.filter,
    required this.onFilterChanged,
    required this.qualityFilter,
    required this.onQualityChanged,
    required this.codecFilter,
    required this.onCodecChanged,
    required this.hdrFilter,
    required this.onHdrChanged,
    required this.sortMode,
    required this.onSortChanged,
    required this.sourcePriority,
    required this.showAdvancedFilters,
    required this.onAdvancedFiltersChanged,
    required this.allowBatchStreams,
    required this.onBatchChanged,
    required this.onSelected,
    required this.onReleaseDownload,
    required this.onWebSelected,
    required this.onWebDownload,
    required this.onLibrarySelected,
    required this.onDownloadedSelected,
    required this.autoPickNotice,
    required this.error,
    required this.onRetry,
    required this.onRefresh,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onSearchCleared,
  });

  final List<ReleaseCandidate> releases;
  final int totalCount;
  final List<WebStreamResult> webStreams;
  final int webTotalCount;
  final List<LibraryEpisodeSource> librarySources;
  final int libraryTotalCount;
  final DownloadedEpisodeAsset? downloadedSource;
  final bool hasDownloadedSource;
  final List<String> libraryFailures;
  final bool libraryEnabled;
  final int failedWebProviders;
  final List<WebProviderFailure> webFailures;
  final int failedDebridSources;
  final bool isSearching;
  final String searchStatus;
  final bool debridEnabled;
  final bool directTorrentMode;
  final bool webEnabled;
  final Set<DebridService> connectedServices;
  final DebridService selectedService;
  final ValueChanged<DebridService> onServiceChanged;
  final _StreamLanguageFilter filter;
  final ValueChanged<_StreamLanguageFilter> onFilterChanged;
  final _StreamQualityFilter qualityFilter;
  final ValueChanged<_StreamQualityFilter> onQualityChanged;
  final _StreamCodecFilter codecFilter;
  final ValueChanged<_StreamCodecFilter> onCodecChanged;
  final _StreamHdrFilter hdrFilter;
  final ValueChanged<_StreamHdrFilter> onHdrChanged;
  final _StreamSortMode sortMode;
  final ValueChanged<_StreamSortMode> onSortChanged;
  final StreamSourcePriority sourcePriority;
  final bool showAdvancedFilters;
  final ValueChanged<bool> onAdvancedFiltersChanged;
  final bool allowBatchStreams;
  final ValueChanged<bool> onBatchChanged;
  final ValueChanged<ReleaseCandidate> onSelected;
  final ValueChanged<ReleaseCandidate>? onReleaseDownload;
  final ValueChanged<WebStreamResult> onWebSelected;
  final ValueChanged<WebStreamResult>? onWebDownload;
  final ValueChanged<LibraryEpisodeSource> onLibrarySelected;
  final ValueChanged<DownloadedEpisodeAsset> onDownloadedSelected;
  final String? autoPickNotice;
  final String? error;
  final VoidCallback? onRetry;
  final VoidCallback onRefresh;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchCleared;

  List<Widget> get _debridSlivers => releases.isEmpty
      ? const []
      : [
          SliverToBoxAdapter(
            child: _StreamSectionHeader(
              icon: directTorrentMode
                  ? Icons.download_for_offline_outlined
                  : Icons.cloud_done_rounded,
              title: directTorrentMode
                  ? 'DIRECT TORRENT STREAMS'
                  : 'DEBRID STREAMS',
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
            sliver: SliverList.builder(
              itemCount: releases.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final index = releases.indexWhere(
                  (release) =>
                      'debrid:${release.infoHash.toLowerCase()}' == key.value,
                );
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                final release = releases[index];
                return Padding(
                  key: ValueKey('debrid:${release.infoHash.toLowerCase()}'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ReleaseCard(
                    release: release,
                    recommended: index == 0,
                    onPressed: () => onSelected(release),
                    onLongPress: onReleaseDownload == null
                        ? null
                        : () => onReleaseDownload!(release),
                  ),
                );
              },
            ),
          ),
        ];

  List<Widget> get _webSlivers => webStreams.isEmpty
      ? const []
      : [
          const SliverToBoxAdapter(
            child: _StreamSectionHeader(
              icon: Icons.language_rounded,
              title: 'WEB STREAMS',
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
            sliver: SliverList.builder(
              itemCount: webStreams.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final index = webStreams.indexWhere(
                  (stream) =>
                      'web:${_opaqueWebStreamIdentity(stream)}' == key.value,
                );
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                final stream = webStreams[index];
                return Padding(
                  key: ValueKey('web:${_opaqueWebStreamIdentity(stream)}'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _WebStreamCard(
                    stream: stream,
                    onPressed: () => onWebSelected(stream),
                    onLongPress: onWebDownload == null
                        ? null
                        : () => onWebDownload!(stream),
                  ),
                );
              },
            ),
          ),
        ];

  List<Widget> get _librarySlivers => librarySources.isEmpty
      ? const []
      : [
          const SliverToBoxAdapter(
            child: _StreamSectionHeader(
              icon: Icons.video_library_rounded,
              title: 'LOCAL SOURCES',
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
            sliver: SliverList.builder(
              itemCount: librarySources.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final index = librarySources.indexWhere(
                  (source) => 'library:${source.stableKey}' == key.value,
                );
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                final source = librarySources[index];
                return Padding(
                  key: ValueKey('library:${source.stableKey}'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _LibraryStreamCard(
                    source: source,
                    ambiguous: librarySources.length > 1,
                    onPressed: () => onLibrarySelected(source),
                  ),
                );
              },
            ),
          ),
        ];

  List<Widget> get _downloadedSlivers => downloadedSource == null
      ? const []
      : [
          const SliverToBoxAdapter(
            child: _StreamSectionHeader(
              icon: Icons.download_done_rounded,
              title: 'AVAILABLE OFFLINE',
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
            sliver: SliverToBoxAdapter(
              child: _DownloadedStreamCard(
                source: downloadedSource!,
                onPressed: () => onDownloadedSelected(downloadedSource!),
              ),
            ),
          ),
        ];

  List<Widget> get _orderedStreamSlivers => switch (sourcePriority) {
    StreamSourcePriority.debridFirst => [
      ..._downloadedSlivers,
      ..._librarySlivers,
      ..._debridSlivers,
      ..._webSlivers,
      ..._emptyResultSlivers,
    ],
    StreamSourcePriority.webFirst => [
      ..._downloadedSlivers,
      ..._librarySlivers,
      ..._webSlivers,
      ..._debridSlivers,
      ..._emptyResultSlivers,
    ],
  };

  List<Widget> get _emptyResultSlivers =>
      releases.isNotEmpty ||
          webStreams.isNotEmpty ||
          librarySources.isNotEmpty ||
          downloadedSource != null
      ? const []
      : [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    searchQuery.isEmpty
                        ? Icons.filter_alt_off_rounded
                        : Icons.search_off_rounded,
                    size: 30,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    searchQuery.isEmpty
                        ? 'No streams match the selected filters.'
                        : 'No streams match this search.',
                  ),
                  if (searchQuery.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _CompactAction(
                      icon: Icons.clear_rounded,
                      label: 'Clear search',
                      onPressed: onSearchCleared,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ];

  KeyEventResult _handleSearchNavigation(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final scope = FocusScope.of(context);
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      // RIGHT always exits the text input toward the adjacent primary filter
      // row. Reading-order fallback also covers the compact stacked header,
      // where there is no geometrically-right control.
      if (!scope.focusInDirection(TraversalDirection.right)) {
        scope.nextFocus();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      // DOWN leaves the search field for the closest visible row below it:
      // stream results on TV layouts, or primary filters on compact layouts.
      // Never let EditableText consume the key as cursor navigation.
      if (!scope.focusInDirection(TraversalDirection.down)) {
        scope.nextFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final orderedWebFailures = webFailures.toList(growable: false)
      ..sort((left, right) {
        int severity(WebProviderFailureStatus status) => switch (status) {
          WebProviderFailureStatus.failed => 0,
          WebProviderFailureStatus.unavailable => 1,
          WebProviderFailureStatus.paused => 2,
          WebProviderFailureStatus.noMatch => 3,
          WebProviderFailureStatus.advisory => 4,
        };
        final rank = severity(left.status).compareTo(severity(right.status));
        if (rank != 0) return rank;
        final provider = left.providerName.toLowerCase().compareTo(
          right.providerName.toLowerCase(),
        );
        return provider != 0
            ? provider
            : (left.providerId ?? '').compareTo(right.providerId ?? '');
      });
    final sourceIssueCount =
        failedWebProviders + failedDebridSources + libraryFailures.length;
    final providerNoticeCount = webFailures
        .where(
          (failure) =>
              failure.status == WebProviderFailureStatus.noMatch ||
              failure.status == WebProviderFailureStatus.advisory ||
              failure.status == WebProviderFailureStatus.paused,
        )
        .length;
    final sourceIssueDetails = [
      for (final failure in orderedWebFailures)
        '${failure.providerName}: ${failure.message}',
      if (failedDebridSources > 0)
        '$failedDebridSources ${directTorrentMode ? 'torrent manifest' : 'Debrid source'}(s) did not return a result.',
      for (final server in libraryFailures) '$server was unavailable.',
    ].join('\n');
    final providerStatusItems = [
      for (final failure in orderedWebFailures.take(4))
        '${failure.providerName}: ${switch (failure.status) {
          WebProviderFailureStatus.noMatch => 'no match',
          WebProviderFailureStatus.advisory => 'repository warning',
          WebProviderFailureStatus.unavailable => 'unavailable',
          WebProviderFailureStatus.paused => 'paused',
          WebProviderFailureStatus.failed => 'error',
        }}',
      if (orderedWebFailures.length > 4)
        '+${orderedWebFailures.length - 4} more',
    ];
    final activeAdvancedFilters = [
      qualityFilter != _StreamQualityFilter.any,
      codecFilter != _StreamCodecFilter.any,
      hdrFilter != _StreamHdrFilter.any,
      !allowBatchStreams,
      sortMode != _StreamSortMode.compatibility,
    ].where((active) => active).length;
    return SizedBox(
      width: 1260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final summaryParts = <String>[
                debridEnabled
                    ? directTorrentMode
                          ? '$totalCount Direct torrent'
                          : '$totalCount Debrid'
                    : 'Torrent releases off',
                webEnabled ? '$webTotalCount Web' : 'Web off',
                if (libraryEnabled) '$libraryTotalCount Local',
                if (hasDownloadedSource) '1 Offline',
                if (sourceIssueCount > 0) '$sourceIssueCount issue(s)',
                if (providerNoticeCount > 0) '$providerNoticeCount notice(s)',
              ];
              final summary = summaryParts.join(' • ');
              final heading = SizedBox(
                width: constraints.maxWidth >= 1080 ? 270 : 220,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose your stream',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
              final search = Focus(
                key: const ValueKey('stream-picker-search-navigation'),
                canRequestFocus: false,
                onKeyEvent: (node, event) =>
                    _handleSearchNavigation(context, event),
                child: TvTextInput(
                  key: const ValueKey('stream-picker-search-input'),
                  controller: searchController,
                  focusNode: searchFocusNode,
                  labelText: 'Search sources',
                  hintText: 'Release, group, quality, codec…',
                  keyboardTitle: 'Search this stream list',
                  onChanged: onSearchChanged,
                  onSubmitted: onSearchChanged,
                ),
              );
              final controls = _StreamPickerPrimaryControls(
                filter: filter,
                onFilterChanged: onFilterChanged,
                showAdvancedFilters: showAdvancedFilters,
                activeAdvancedFilters: activeAdvancedFilters,
                onAdvancedFiltersChanged: onAdvancedFiltersChanged,
                onRefresh: onRefresh,
              );
              if (constraints.maxWidth < 820) {
                return Column(
                  key: const ValueKey('stream-picker-header-stacked'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    const SizedBox(height: 10),
                    search,
                    const SizedBox(height: 8),
                    controls,
                  ],
                );
              }
              return Row(
                key: const ValueKey('stream-picker-header-row'),
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  heading,
                  const SizedBox(width: 12),
                  Expanded(child: search),
                  const SizedBox(width: 10),
                  controls,
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          if (debridEnabled && connectedServices.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final service in DebridService.values.where(
                  connectedServices.contains,
                ))
                  _FilterButton(
                    label: service.shortName,
                    selected: selectedService == service,
                    onPressed: () => onServiceChanged(service),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (isSearching) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: palette.secondaryAccent.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: palette.secondaryAccent.withValues(alpha: .2),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.secondaryAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$searchStatus • Available results can be selected now.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.primaryText.withValues(alpha: .7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (showAdvancedFilters) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: palette.primaryText.withValues(alpha: .08),
                ),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const _FilterLabel('QUALITY'),
                  for (final value in _StreamQualityFilter.values)
                    _FilterButton(
                      label: switch (value) {
                        _StreamQualityFilter.any => 'ANY',
                        _StreamQualityFilter.p2160 => '4K',
                        _StreamQualityFilter.p1080 => '1080P',
                        _StreamQualityFilter.p720 => '720P',
                      },
                      selected: qualityFilter == value,
                      onPressed: () => onQualityChanged(value),
                    ),
                  const _FilterLabel('CODEC'),
                  for (final value in _StreamCodecFilter.values)
                    _FilterButton(
                      label: switch (value) {
                        _StreamCodecFilter.any => 'ANY',
                        _StreamCodecFilter.h264 => 'H.264',
                        _StreamCodecFilter.hevc => 'HEVC',
                        _StreamCodecFilter.av1 => 'AV1',
                      },
                      selected: codecFilter == value,
                      onPressed: () => onCodecChanged(value),
                    ),
                  const _FilterLabel('COLOR'),
                  for (final value in _StreamHdrFilter.values)
                    _FilterButton(
                      label: value.name.toUpperCase(),
                      selected: hdrFilter == value,
                      onPressed: () => onHdrChanged(value),
                    ),
                  _FilterButton(
                    label: allowBatchStreams ? 'BATCHES ON' : 'BATCHES OFF',
                    selected: allowBatchStreams,
                    onPressed: () => onBatchChanged(!allowBatchStreams),
                  ),
                  const _FilterLabel('SORT'),
                  for (final value in _StreamSortMode.values)
                    _FilterButton(
                      label: switch (value) {
                        _StreamSortMode.compatibility => 'BEST',
                        _StreamSortMode.seeders => 'SEEDERS',
                        _StreamSortMode.largest => 'LARGEST',
                        _StreamSortMode.size => 'SMALLEST',
                      },
                      selected: sortMode == value,
                      onPressed: () => onSortChanged(value),
                    ),
                ],
              ),
            ),
          ],
          if (autoPickNotice case final notice?) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('stream-picker-auto-pick-notice'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: palette.secondaryAccent.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: palette.secondaryAccent.withValues(alpha: .22),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 17,
                    color: palette.secondaryAccent,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      notice,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.primaryText.withValues(alpha: .76),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (error case final message?) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1117),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: palette.accentBright.withValues(alpha: .65),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFFF929B),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Could not start this stream: $message',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFFFC4C9)),
                    ),
                  ),
                  if (onRetry case final retry?) ...[
                    const SizedBox(width: 16),
                    _CompactAction(
                      icon: Icons.refresh_rounded,
                      label: 'Retry',
                      onPressed: retry,
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (providerStatusItems.isNotEmpty) ...[
            const SizedBox(height: 8),
            Semantics(
              label: sourceIssueDetails,
              child: Container(
                key: const ValueKey('stream-picker-provider-status'),
                width: double.infinity,
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: palette.surfaceRaised.withValues(alpha: .7),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: sourceIssueCount > 0
                        ? const Color(0xFFFFC16B).withValues(alpha: .28)
                        : palette.primaryText.withValues(alpha: .09),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      sourceIssueCount > 0
                          ? Icons.info_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 15,
                      color: sourceIssueCount > 0
                          ? const Color(0xFFFFC16B)
                          : palette.mutedText,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'PROVIDERS • ${providerStatusItems.join(' • ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.primaryText.withValues(alpha: .7),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (sourceIssueDetails.isNotEmpty && providerStatusItems.isEmpty)
            Semantics(
              label: sourceIssueDetails,
              child: const SizedBox.shrink(),
            ),
          const SizedBox(height: 18),
          Expanded(child: CustomScrollView(slivers: _orderedStreamSlivers)),
        ],
      ),
    );
  }
}

class _StreamPickerPrimaryControls extends StatefulWidget {
  const _StreamPickerPrimaryControls({
    required this.filter,
    required this.onFilterChanged,
    required this.showAdvancedFilters,
    required this.activeAdvancedFilters,
    required this.onAdvancedFiltersChanged,
    required this.onRefresh,
  });

  final _StreamLanguageFilter filter;
  final ValueChanged<_StreamLanguageFilter> onFilterChanged;
  final bool showAdvancedFilters;
  final int activeAdvancedFilters;
  final ValueChanged<bool> onAdvancedFiltersChanged;
  final VoidCallback onRefresh;

  @override
  State<_StreamPickerPrimaryControls> createState() =>
      _StreamPickerPrimaryControlsState();
}

class _StreamPickerPrimaryControlsState
    extends State<_StreamPickerPrimaryControls> {
  late final List<FocusNode> _focusNodes = [
    FocusNode(debugLabel: 'stream-picker.all'),
    FocusNode(debugLabel: 'stream-picker.sub'),
    FocusNode(debugLabel: 'stream-picker.dub'),
    FocusNode(debugLabel: 'stream-picker.filters'),
    FocusNode(debugLabel: 'stream-picker.refresh'),
  ];

  @override
  void dispose() {
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleHorizontalNavigation(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => 0,
    };
    final target = index + delta;
    if (delta == 0 || target < 0 || target >= _focusNodes.length) {
      return KeyEventResult.ignored;
    }
    _focusNodes[target].requestFocus();
    return KeyEventResult.handled;
  }

  Widget _orderedControl(int index, Widget child) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(index.toDouble()),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controls = <Widget>[
      for (final value in _StreamLanguageFilter.values)
        _FilterButton(
          key: ValueKey('stream-picker-${value.name}'),
          label: switch (value) {
            _StreamLanguageFilter.all => 'ALL',
            _StreamLanguageFilter.sub => 'SUB',
            _StreamLanguageFilter.dub => 'DUB',
          },
          selected: widget.filter == value,
          onPressed: () => widget.onFilterChanged(value),
          focusNode: _focusNodes[value.index],
          onKeyEvent: (node, event) =>
              _handleHorizontalNavigation(value.index, event),
        ),
      _CompactIconAction(
        key: const ValueKey('stream-picker-filters'),
        icon: widget.showAdvancedFilters
            ? Icons.tune_rounded
            : Icons.tune_outlined,
        label: widget.activeAdvancedFilters == 0
            ? (widget.showAdvancedFilters ? 'Hide filters' : 'More filters')
            : 'Filters (${widget.activeAdvancedFilters})',
        badge: widget.activeAdvancedFilters,
        onPressed: () =>
            widget.onAdvancedFiltersChanged(!widget.showAdvancedFilters),
        focusNode: _focusNodes[3],
        onKeyEvent: (node, event) => _handleHorizontalNavigation(3, event),
      ),
      _CompactIconAction(
        key: const ValueKey('stream-picker-refresh'),
        icon: Icons.refresh_rounded,
        label: 'Refresh',
        onPressed: widget.onRefresh,
        focusNode: _focusNodes[4],
        onKeyEvent: (node, event) => _handleHorizontalNavigation(4, event),
      ),
    ];
    final controlRow = Row(
      key: const ValueKey('stream-picker-primary-controls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < controls.length; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          _orderedControl(index, controls[index]),
        ],
      ],
    );
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 420) return controlRow;
          return SingleChildScrollView(
            key: const ValueKey('stream-picker-primary-controls-scroll'),
            scrollDirection: Axis.horizontal,
            child: controlRow,
          );
        },
      ),
    );
  }
}

class _StreamSectionHeader extends StatelessWidget {
  const _StreamSectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.appPalette.accentBright),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: context.appPalette.primaryText.withValues(alpha: .7),
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadedStreamCard extends StatelessWidget {
  const _DownloadedStreamCard({required this.source, required this.onPressed});

  final DownloadedEpisodeAsset source;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final job = source.job;
    return TvFocusable(
      key: const ValueKey('stream-picker-downloaded-source'),
      onPressed: onPressed,
      autofocus: true,
      borderRadius: BorderRadius.circular(18),
      focusScale: 1.015,
      child: Container(
        height: 104,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: const Color(0xFF67D49B).withValues(alpha: .45),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF67D49B).withValues(alpha: .18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.offline_pin_rounded,
                color: Color(0xFF67D49B),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.episodeTitle?.trim().isNotEmpty == true
                        ? job.episodeTitle!
                        : 'Downloaded episode ${job.episode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    [
                      'Available offline',
                      job.quality,
                      job.audioLabel,
                      job.providerName,
                    ].whereType<String>().join(' • '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.play_arrow_rounded,
              color: palette.primaryText.withValues(alpha: .8),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryStreamCard extends StatelessWidget {
  const _LibraryStreamCard({
    required this.source,
    required this.ambiguous,
    required this.onPressed,
  });

  final LibraryEpisodeSource source;
  final bool ambiguous;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final icon = switch (source.origin) {
      LibraryEpisodeOrigin.device => Icons.video_file_rounded,
      LibraryEpisodeOrigin.jellyfin => Icons.live_tv_rounded,
      LibraryEpisodeOrigin.plex => Icons.connected_tv_rounded,
    };
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(18),
      focusScale: 1.015,
      child: Container(
        height: 104,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.primaryText.withValues(alpha: .08)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.secondaryAccent.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: palette.secondaryAccent),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${source.subtitle}'
                    '${ambiguous ? ' • Multiple exact matches; choose manually' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: palette.primaryText.withValues(alpha: .7),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebStreamCard extends StatelessWidget {
  const _WebStreamCard({
    required this.stream,
    required this.onPressed,
    required this.onLongPress,
  });

  final WebStreamResult stream;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return TvFocusable(
      onPressed: onPressed,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(18),
      focusScale: 1.015,
      child: Container(
        height: 104,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        decoration: BoxDecoration(
          color: context.appPalette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: context.appPalette.primaryText.withValues(alpha: .08),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.play_circle_outline_rounded),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stream.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${stream.providerName} / '
                    '${stream.effectiveAudioCapability.pickerLabel}'
                    '${stream.quality == null ? '' : ' / ${stream.quality}'}'
                    '${stream.subtitleUri == null ? '' : ' / English captions'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: palette.primaryText.withValues(alpha: .7),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({
    required this.release,
    required this.onPressed,
    required this.onLongPress,
    required this.recommended,
  });

  final ReleaseCandidate release;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return TvFocusable(
      onPressed: onPressed,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(18),
      focusScale: 1.015,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final compactMetadata = <String>[
            releaseAudioPickerLabel(release),
            release.provider ?? '',
            release.seeders > 0 ? '${release.seeders} seeders' : '',
            release.sizeLabel ?? '',
          ].where((label) => label.isNotEmpty).join(' • ');
          return Container(
            height: 126,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : 22,
              vertical: 17,
            ),
            color: palette.surface,
            child: Row(
              children: [
                Container(
                  width: compact ? 64 : 92,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [palette.accent, palette.secondaryAccent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      release.quality?.toUpperCase() ?? 'AUTO',
                      style: TextStyle(
                        color: contrastForeground(palette.accent),
                        fontSize: compact ? 15 : 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: compact ? 12 : 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        release.releaseName.replaceAll('\n', ' • '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: compact ? 6 : 9),
                      if (compact)
                        Text(
                          compactMetadata,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (recommended)
                              const _MetaPill(
                                label: 'RECOMMENDED',
                                color: Color(0xFF67D49B),
                              ),
                            _MetaPill(
                              label: releaseAudioPickerLabel(release),
                              color: release.isDubbed
                                  ? const Color(0xFFFFB86C)
                                  : palette.secondaryAccent,
                            ),
                            if (isTvSafeRelease(release))
                              const _MetaPill(
                                label: 'TV SAFE',
                                color: Color(0xFF67D49B),
                              ),
                            if (release.hasSubtitles && release.isDubbed)
                              _MetaPill(
                                label: 'SUBTITLES',
                                color: palette.secondaryAccent,
                              ),
                            if (release.codec case final codec?)
                              _MetaPill(label: codec),
                            if (release.isHdr)
                              const _MetaPill(
                                label: 'HDR',
                                color: Color(0xFFFFD166),
                              ),
                            if (release.isBatch)
                              const _MetaPill(label: 'BATCH'),
                          ],
                        ),
                    ],
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 18),
                  SizedBox(
                    width: 190,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          [
                            if (release.seeders > 0)
                              '● ${release.seeders} seeders',
                            if (release.sizeLabel != null) release.sizeLabel!,
                          ].join('  •  '),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 7),
                        Text(
                          release.provider ?? 'User source',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.mutedText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 18),
                ] else
                  const SizedBox(width: 10),
                Icon(
                  Icons.play_circle_fill_rounded,
                  color: palette.accentBright,
                  size: compact ? 24 : 34,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    this.onKeyEvent,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return TvFocusable(
      onPressed: onPressed,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      borderRadius: BorderRadius.circular(999),
      focusScale: 1.03,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? palette.accentBright : palette.surface,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: selected
                ? contrastForeground(palette.accentBright)
                : palette.primaryText,
          ),
        ),
      ),
    );
  }
}

class _FilterLabel extends StatelessWidget {
  const _FilterLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 7, right: 1),
    child: Text(
      label,
      style: TextStyle(
        color: context.appPalette.mutedText,
        fontSize: 10,
        fontWeight: FontWeight.w900,
        letterSpacing: 1,
      ),
    ),
  );
}

class _CompactAction extends StatelessWidget {
  const _CompactAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(10),
      focusScale: 1.03,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: context.appPalette.surface,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 7),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    );
  }
}

class _CompactIconAction extends StatelessWidget {
  const _CompactIconAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.badge = 0,
    this.focusNode,
    this.onKeyEvent,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final int badge;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Tooltip(
      message: label,
      child: TvFocusable(
        onPressed: onPressed,
        focusNode: focusNode,
        onKeyEvent: onKeyEvent,
        borderRadius: BorderRadius.circular(10),
        focusScale: 1.03,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          color: context.appPalette.surface,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(icon, size: 20),
              if (badge > 0)
                Positioned(
                  top: -8,
                  right: -10,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: context.appPalette.accentBright,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$badge',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: contrastForeground(
                          context.appPalette.accentBright,
                        ),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? context.appPalette.mutedText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: resolvedColor.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: resolvedColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: .5,
        ),
      ),
    );
  }
}

class _ManualReleaseSource implements ReleaseSource {
  const _ManualReleaseSource(this.magnet);

  final String magnet;

  @override
  String get id => 'manual';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async {
    return [candidate(episode)];
  }

  ReleaseCandidate candidate(EpisodeReference episode) {
    return ReleaseCandidate(
      infoHash: Uri.parse(magnet).queryParameters['xt'] ?? '',
      magnetUri: magnet,
      releaseName: '${episode.title} Episode ${episode.episode}',
      seeders: 0,
      sourceId: id,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 68, color: context.appPalette.mutedText),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        SizedBox(
          width: 560,
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        const SizedBox(height: 22),
        action,
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: true,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: context.appPalette.surface,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.arrow_back_rounded, size: 20),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final foreground = contrastForeground(context.appPalette.primaryText);
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        color: context.appPalette.primaryText,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: foreground, size: 19),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}
