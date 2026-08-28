import 'dart:async';

import 'package:anime_tv/core/diagnostics/anonymous_crash_reporter.dart';
import 'package:anime_tv/core/telemetry/anonymous_usage_reporter.dart';
import 'package:anime_tv/core/diagnostics/playback_diagnostic_recorder.dart';
import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/player/application/audio_track_selector.dart';
import 'package:anime_tv/features/player/application/external_player_proxy_lease_keeper.dart';
import 'package:anime_tv/features/player/application/library_playback_session.dart';
import 'package:anime_tv/features/player/application/playback_audio_diagnostics.dart';
import 'package:anime_tv/features/catalog/application/filler_episode_providers.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/player/application/filler_episode_navigation.dart';
import 'package:anime_tv/features/player/application/next_episode_prewarm_policy.dart';
import 'package:anime_tv/features/player/application/skip_segment_service.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/player/presentation/filler_skip_notification.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:anime_tv/features/player/presentation/player_failover_coordinator.dart';
import 'package:anime_tv/features/player/presentation/player_failover_notification.dart';
import 'package:anime_tv/features/player/presentation/player_presentation_palette.dart';
import 'package:anime_tv/features/player/presentation/player_stream_source_picker.dart';
import 'package:anime_tv/features/player/presentation/teto_player_chrome.dart';
import 'package:anime_tv/features/player/presentation/watch_party_player_status.dart';
import 'package:anime_tv/features/player/presentation/watch_party_player_dialog.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/debrid_resolver_factory.dart';
import 'package:anime_tv/features/streaming/application/debrid_token_service.dart';
import 'package:anime_tv/features/streaming/application/next_episode_preparation_controller.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/tracking/application/tracking_sync_service.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_media_follower.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_playback_coordinator.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
// media_kit_video has no public Android surface-detach API. The concrete
// controller is needed to drain its wid listener before Player.dispose marks
// the native player disposed.
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';

const tetoTvVideoControllerConfiguration = VideoControllerConfiguration(
  enableHardwareAcceleration: true,
  // Start on MediaCodec because Android TV devices consistently render it
  // more smoothly than libmpv's auto-safe probing path. TetoTV's decoded-
  // format and frame-drop watchdogs still move incompatible streams to the
  // software decoder automatically.
  vo: 'gpu',
  hwdec: 'mediacodec',
  androidAttachSurfaceAfterVideoParameters: true,
);

// Native playback commands normally complete immediately, but a broken
// platform callback must not keep an engine handoff or route disposal pending
// forever. New mutations are already closed before either drain begins.
const _playerMutationReleaseTimeout = Duration(seconds: 5);

enum PlaybackDecoderMode { hardwareSafe, hardwareDirect, software }

String _mpvColor(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

typedef _PlaybackMenuResult = ({String type, Object value});

String hwdecForPlaybackMode(PlaybackDecoderMode mode) => switch (mode) {
  PlaybackDecoderMode.hardwareSafe => 'mediacodec',
  PlaybackDecoderMode.hardwareDirect => 'mediacodec',
  PlaybackDecoderMode.software => 'no',
};

String playbackDecoderLabel(PlaybackDecoderMode mode) => switch (mode) {
  PlaybackDecoderMode.hardwareSafe => 'Automatic (adaptive)',
  PlaybackDecoderMode.hardwareDirect => 'Hardware direct',
  PlaybackDecoderMode.software => 'Software compatibility',
};

bool isH264TenBitVideoProfile({
  String? codec,
  String? profile,
  String? format,
  String? pixelFormat,
  String? hardwarePixelFormat,
}) {
  final description = [
    codec,
    profile,
    format,
    pixelFormat,
    hardwarePixelFormat,
  ].whereType<String>().join(' ').toLowerCase();
  final isH264 =
      description.contains('h264') ||
      description.contains('h.264') ||
      description.contains('avc');
  final isTenBit = RegExp(
    r'(?:high[ ._-]?10|hi10p|10[ ._-]?bit|yuv\d+p10|p010)',
  ).hasMatch(description);
  return isH264 && isTenBit;
}

bool resumeSeekNeedsRetry(Duration target, Duration actual) =>
    target > const Duration(seconds: 15) &&
    actual + const Duration(seconds: 5) < target;

/// Keeps an inherited checkpoint authoritative until MPV actually reaches it.
/// A decoder or host can fail while ordinary playback has already advanced
/// several seconds; recovery must not mistake that progress for a successful
/// resume seek and silently restart far behind the saved checkpoint.
Duration effectivePlayerResumePosition({
  required Duration position,
  Duration? pendingResume,
}) {
  if (pendingResume != null &&
      !playerResumeTargetReached(target: pendingResume, actual: position)) {
    return pendingResume;
  }
  return position;
}

/// Avoids clamping an inherited checkpoint to a transient startup duration.
/// Library sessions accept an unknown duration, but clamp progress when a
/// positive duration is supplied. Some demuxers briefly expose a partial
/// duration before the inherited seek completes.
Duration effectivePlayerProgressDuration({
  required Duration duration,
  required Duration effectivePosition,
  Duration? pendingResume,
}) {
  if (pendingResume != null &&
      duration > Duration.zero &&
      duration < effectivePosition) {
    return Duration.zero;
  }
  return duration;
}

bool playerResumeTargetReached({
  required Duration target,
  required Duration actual,
  Duration tolerance = const Duration(seconds: 2),
}) => actual + tolerance >= target;

/// Detects the terminal jump some network demuxers emit when a response ends
/// early. In that failure mode MPV reports both position and duration as the
/// exact duration even though the last playable frame was far from the end.
///
/// Natural completion is accepted when playback was already close to the end.
/// An explicit, recently committed seek to the end is also accepted so a
/// viewer dragging the scrubber fully right never causes an automatic source
/// switch.
bool shouldFailOverPrematureNetworkCompletion({
  required bool isNetworkStream,
  required Duration position,
  required Duration duration,
  required Duration lastPlayablePosition,
  required DateTime completedAt,
  DateTime? lastCommittedEndSeekAt,
  Duration? lastCommittedEndSeekTarget,
  Duration naturalEndWindow = const Duration(seconds: 20),
  Duration recentEndSeekWindow = const Duration(seconds: 12),
  Duration endSeekTolerance = const Duration(seconds: 2),
}) {
  if (!isNetworkStream || duration <= Duration.zero || position != duration) {
    return false;
  }

  final naturalEndStart = duration > naturalEndWindow
      ? duration - naturalEndWindow
      : Duration.zero;
  if (lastPlayablePosition >= naturalEndStart) return false;

  final seekAt = lastCommittedEndSeekAt;
  final seekTarget = lastCommittedEndSeekTarget;
  if (seekAt != null && seekTarget != null) {
    final seekAge = completedAt.difference(seekAt);
    final endSeekStart = duration > endSeekTolerance
        ? duration - endSeekTolerance
        : Duration.zero;
    if (!seekAge.isNegative &&
        seekAge <= recentEndSeekWindow &&
        seekTarget >= endSeekStart) {
      return false;
    }
  }

  return true;
}

/// MPV is the single playback engine for every supported stream class.
bool preferMpvForInitialStream(StreamReady stream) => true;

/// Provisional scene-preview seeks are safe only when every byte is already on
/// the device. Seeking a web, debrid, torrent, Plex, or Jellyfin stream while a
/// thumb is still moving can leave multiple HTTP ranges active and exhaust a
/// provider/proxy request budget. Network playback therefore seeks once, when
/// the viewer releases the thumb or D-pad key.
bool supportsProvisionalSeekPreview(StreamReady stream) {
  if (stream.isDownloaded) return true;
  final scheme = stream.uri.scheme.toLowerCase();
  return scheme == 'file' || scheme == 'content';
}

typedef ExternalPlayerTarget = ({Uri? uri, String? localPath});

/// Returns only media that can be handed to another app without disclosing a
/// private-server credential or provider request header.
///
/// File paths are restricted twice: this Flutter boundary accepts only a
/// completed TetoTV download under `offline_downloads`, then Android resolves
/// and verifies the canonical path again before granting temporary read
/// access through FileProvider.
ExternalPlayerTarget? externalPlayerTargetForStream(StreamReady stream) {
  if (stream.isDirectTorrent || stream.headers.isNotEmpty) return null;
  final uri = stream.uri;
  if (uri.userInfo.isNotEmpty || uri.hasFragment) return null;
  final mediaType = stream.mediaContentType
      ?.split(';')
      .first
      .trim()
      .toLowerCase();
  final downloadedHls =
      stream.isDownloaded &&
      (uri.path.toLowerCase().endsWith('.m3u8') ||
          const {
            'application/vnd.apple.mpegurl',
            'application/x-mpegurl',
            'application/mpegurl',
          }.contains(mediaType));
  // A completed offline HLS episode is a private bundle. Android's external
  // handoff currently grants one file only, so another app could open the
  // playlist but not its sibling segments. Keep this source in TetoTV/MPV.
  if (downloadedHls) return null;
  switch (uri.scheme.toLowerCase()) {
    case 'http':
    case 'https':
      return uri.host.isEmpty ? null : (uri: uri, localPath: null);
    case 'content':
      return uri.authority.isEmpty ? null : (uri: uri, localPath: null);
    case 'file':
      if (!stream.isDownloaded || uri.hasQuery) return null;
      final path = uri.path;
      return _isTetoOfflineDownloadPath(path)
          ? (uri: null, localPath: path)
          : null;
    case '':
      if (!stream.isDownloaded || uri.hasQuery) return null;
      final path = uri.toString();
      return _isTetoOfflineDownloadPath(path)
          ? (uri: null, localPath: path)
          : null;
    default:
      return null;
  }
}

/// Library sessions are private by default. Only device/local/downloaded
/// providers may leave TetoTV; Plex, Jellyfin, and unknown private servers
/// must stay in-app so their authenticated proxy details cannot leak.
bool externalPlayerLibraryProviderAllowed(String? providerId) {
  if (providerId == null) return true;
  final normalized = providerId.trim().toLowerCase();
  return normalized.contains('device') ||
      normalized.contains('local') ||
      normalized.contains('download');
}

bool configuredExternalPlayerEligible({
  required SettingsPreferences preferences,
  required bool watchPartyActive,
  required StreamReady stream,
  String? libraryProviderId,
}) {
  return preferences.externalPlayerEnabled &&
      preferences.preferredPlayer == PreferredPlayer.external &&
      normalizeExternalPlayerPackageName(
            preferences.selectedExternalPlayerPackage,
          ) !=
          null &&
      !watchPartyActive &&
      externalPlayerLibraryProviderAllowed(libraryProviderId) &&
      externalPlayerTargetForStream(stream) != null;
}

bool _isTetoOfflineDownloadPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.isNotEmpty &&
      RegExp(r'(^|/)offline_downloads/[^/]+').hasMatch(normalized);
}

/// Watch Party guests follow the host timeline and never expose a local skip
/// action. Hosts and standalone viewers remain eligible even with a hidden
/// transport HUD.
bool playerCanUseSkipMarkers({required bool guestControlsLocked}) =>
    !guestControlsLocked;

bool isLikelyVideoDecodeFailure(String message) {
  final value = message.toLowerCase();
  return const [
    'mediacodec',
    'could not open codec',
    'failed to initialize a decoder',
    'decoder for codec',
    'unsupported codec',
    'video decoder',
    'video codec',
    'failed to decode',
    'hardware decoding',
    'video output',
    'surface',
  ].any(value.contains);
}

bool automaticDecoderFailureNeedsLibraryRecovery({
  required bool automatic,
  required bool hasLibrarySession,
  required Object error,
}) =>
    automatic &&
    hasLibrarySession &&
    classifyLibraryPlaybackStartupFailure(error) != null;

Duration? playerSeekOffsetForKey(
  LogicalKeyboardKey key, {
  int backSeconds = 10,
  int forwardSeconds = 10,
}) {
  if (key == LogicalKeyboardKey.keyJ || key == LogicalKeyboardKey.mediaRewind) {
    return Duration(seconds: -backSeconds);
  }
  if (key == LogicalKeyboardKey.keyL ||
      key == LogicalKeyboardKey.mediaFastForward) {
    return Duration(seconds: forwardSeconds);
  }
  return null;
}

String _formatPlayerDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '${value.inMinutes}:$seconds';
}

class TvPlayerScreen extends ConsumerStatefulWidget {
  const TvPlayerScreen({
    required this.source,
    required this.title,
    required this.debridService,
    required this.launch,
    this.subtitle,
    this.anilistMediaId,
    this.malMediaId,
    this.episode,
    this.coverImageUrl,
    this.libraryPlayback,
    this.onLibraryEpisodeHandoff,
    super.key,
  });

  final String source;
  final String title;
  final DebridService debridService;
  final PlaybackLaunch launch;
  final String? subtitle;
  final int? anilistMediaId;
  final int? malMediaId;
  final int? episode;
  final String? coverImageUrl;
  final LibraryPlaybackSession? libraryPlayback;
  final Future<bool> Function(LibraryPlaybackRequest request)?
  onLibraryEpisodeHandoff;

  @override
  ConsumerState<TvPlayerScreen> createState() => _TvPlayerScreenRouterState();
}

class _TvPlayerScreenRouterState extends ConsumerState<TvPlayerScreen> {
  late String _activeSource;
  late PlaybackLaunch _activeLaunch;
  Duration? _resumeOverride;
  late final WatchPartyPlaybackCoordinator _watchPartyPlayback;
  late final WatchPartyController _watchPartyController;
  late final WatchPartyPlaybackAffinityController _watchPartyAffinity;
  late final AnonymousUsageReporter _anonymousUsageReporter;
  final Object _watchPartyAffinityOwner = Object();
  final Object _anonymousUsageOwner = Object();
  int _watchPartyAffinityRevision = 0;

  bool get _isLibraryPlayback => widget.libraryPlayback != null;
  int? get _anilistMediaId => _isLibraryPlayback
      ? null
      : widget.anilistMediaId ?? _activeLaunch.episode.anilistMediaId;
  int? get _malMediaId => _isLibraryPlayback
      ? null
      : widget.malMediaId ?? _activeLaunch.episode.malMediaId;
  int? get _episodeNumber => _isLibraryPlayback
      ? null
      : widget.episode ?? _activeLaunch.episode.episode;
  String? get _coverImageUrl =>
      widget.coverImageUrl ?? _activeLaunch.episode.coverImageUrl;

  @override
  void initState() {
    super.initState();
    _anonymousUsageReporter = ref.read(anonymousUsageReporterProvider);
    _anonymousUsageReporter.beginStreaming(_anonymousUsageOwner);
    _activeSource = widget.source;
    _activeLaunch = widget.launch;
    _watchPartyAffinity = ref.read(watchPartyPlaybackAffinityProvider.notifier);
    _scheduleWatchPartyAffinity();
    final libraryResume = widget.libraryPlayback?.request.initialPosition;
    if (libraryResume != null && libraryResume > Duration.zero) {
      _resumeOverride = libraryResume;
    }
    final libraryRequest = widget.libraryPlayback?.request;
    final libraryWatchIdentity = libraryRequest?.watchPartyIdentity;
    _watchPartyPlayback = libraryRequest == null
        ? WatchPartyPlaybackCoordinator(
            episode: _activeLaunch.episode,
            release: _activeLaunch.selectedRelease,
            requestedAudio: _activeLaunch.requestedAudio,
          )
        : libraryWatchIdentity != null
        ? WatchPartyPlaybackCoordinator.publicCatalogEpisode(
            anilistMediaId: libraryWatchIdentity.anilistMediaId,
            episode: libraryWatchIdentity.episode,
            title: libraryWatchIdentity.title,
          )
        : WatchPartyPlaybackCoordinator.privateMedia(
            checkpointKey: libraryRequest.checkpointKey,
            timelineIdentity: libraryRequest.timelineIdentity,
            displayTitle: libraryRequest.watchPartyDisplayTitle,
          );
    _watchPartyController = ref.read(watchPartyControllerProvider.notifier);
    unawaited(
      _watchPartyController.attachPlayback(
        port: _watchPartyPlayback,
        media: _watchPartyPlayback.media,
      ),
    );
  }

  @override
  void dispose() {
    _anonymousUsageReporter.endStreaming(_anonymousUsageOwner);
    _watchPartyAffinityRevision++;
    unawaited(
      Future<void>(() {
        _watchPartyAffinity.unbind(_watchPartyAffinityOwner);
      }),
    );
    unawaited(() async {
      try {
        await _watchPartyController.detachPlayback(_watchPartyPlayback);
      } finally {
        await _watchPartyPlayback.dispose();
      }
    }());
    unawaited(_activeLaunch.stream.playbackLease?.close());
    super.dispose();
  }

  Future<void> _adoptPlaybackStream(
    StreamReady stream,
    ReleaseCandidate release,
  ) async {
    final previous = _activeLaunch.stream;
    _activeSource = stream.uri.toString();
    _activeLaunch = PlaybackLaunch(
      stream: stream,
      episode: _activeLaunch.episode,
      selectedRelease: release,
      requestedAudio: _activeLaunch.requestedAudio,
      alternatives: _activeLaunch.alternatives
          .where((candidate) => candidate.infoHash != release.infoHash)
          .toList(growable: false),
      directAlternatives: _activeLaunch.directAlternatives
          .where((option) => option.stream.uri != stream.uri)
          .toList(growable: false),
    );
    _watchPartyPlayback.updateMedia(
      episode: _activeLaunch.episode,
      release: release,
      requestedAudio: _activeLaunch.requestedAudio,
    );
    _scheduleWatchPartyAffinity();
    if (!identical(previous.playbackLease, stream.playbackLease)) {
      try {
        await previous.playbackLease?.close();
      } catch (_) {
        // The new stream already owns playback. Expiry remains a safe
        // backstop if a platform request prevents immediate proxy teardown.
      }
    }
  }

  @override
  void didUpdateWidget(covariant TvPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.episode != widget.episode ||
        oldWidget.launch.selectedRelease.infoHash !=
            widget.launch.selectedRelease.infoHash) {
      final previousLease = _activeLaunch.stream.playbackLease;
      _activeSource = widget.source;
      _activeLaunch = widget.launch;
      _watchPartyPlayback.updateMedia(
        episode: _activeLaunch.episode,
        release: _activeLaunch.selectedRelease,
        requestedAudio: _activeLaunch.requestedAudio,
      );
      _scheduleWatchPartyAffinity();
      if (!identical(previousLease, _activeLaunch.stream.playbackLease)) {
        unawaited(previousLease?.close());
      }
      _resumeOverride = null;
    }
  }

  void _scheduleWatchPartyAffinity() {
    final release = _activeLaunch.selectedRelease;
    final stream = _activeLaunch.stream;
    final affinity = widget.libraryPlayback != null
        ? const WatchPartyPlaybackAffinity()
        : WatchPartyPlaybackAffinity(
            preferredProvider: release.provider,
            preferredAuthor: releaseGroupKey(release.releaseName),
            preferredSourceId: release.sourceId,
            preferredWebProviderId: stream.providerId,
            preferredQualityHeight: releaseQualityHeight(release),
            preferredAudio:
                _activeLaunch.requestedAudio ??
                releaseExplicitAudioPreference(release),
          );
    final revision = ++_watchPartyAffinityRevision;
    unawaited(
      Future<void>(() {
        if (!mounted || revision != _watchPartyAffinityRevision) return;
        _watchPartyAffinity.bind(_watchPartyAffinityOwner, affinity);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MpvTvPlayerScreen(
      source: _activeSource,
      title: widget.title,
      debridService: widget.debridService,
      launch: _activeLaunch,
      watchPartyPlayback: _watchPartyPlayback,
      libraryPlayback: widget.libraryPlayback,
      onLibraryEpisodeHandoff: widget.onLibraryEpisodeHandoff,
      subtitle:
          _activeLaunch.stream.externalSubtitle?.toString() ?? widget.subtitle,
      anilistMediaId: _anilistMediaId,
      malMediaId: _malMediaId,
      episode: _episodeNumber,
      coverImageUrl: _coverImageUrl,
      initialPosition: _resumeOverride,
      onStreamAdopted: _adoptPlaybackStream,
    );
  }
}

class MpvTvPlayerScreen extends ConsumerStatefulWidget {
  const MpvTvPlayerScreen({
    required this.source,
    required this.title,
    required this.debridService,
    required this.launch,
    this.watchPartyPlayback,
    this.libraryPlayback,
    this.onLibraryEpisodeHandoff,
    required this.onStreamAdopted,
    this.initialPosition,
    this.subtitle,
    this.anilistMediaId,
    this.malMediaId,
    this.episode,
    this.coverImageUrl,
    super.key,
  });

  final String source;
  final String title;
  final DebridService debridService;
  final PlaybackLaunch launch;
  final WatchPartyPlaybackCoordinator? watchPartyPlayback;
  final LibraryPlaybackSession? libraryPlayback;
  final Future<bool> Function(LibraryPlaybackRequest request)?
  onLibraryEpisodeHandoff;
  final Future<void> Function(StreamReady stream, ReleaseCandidate release)
  onStreamAdopted;
  final Duration? initialPosition;
  final String? subtitle;
  final int? anilistMediaId;
  final int? malMediaId;
  final int? episode;
  final String? coverImageUrl;

  @override
  ConsumerState<MpvTvPlayerScreen> createState() => _MpvTvPlayerScreenState();
}

class _MpvTvPlayerScreenState extends ConsumerState<MpvTvPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  late final TetoTvDatabase _database;
  late final PlaybackDiagnosticSessionRecorder _playbackDiagnostics;
  late final NextEpisodePreparationController _nextEpisodePreparation;
  late final WatchPartyPlaybackEngineHandle _watchPartyHandle;
  late final WatchPartyPlaybackCoordinator _watchPartyPlayback;
  late final WatchPartyPlayerRouteHandoffController _watchPartyRouteHandoff;
  late final bool _ownsWatchPartyPlayback;
  final Object _watchPartyRouteHandoffOwner = Object();

  Map<String, String> get _httpHeaders => {
    'Accept': '*/*',
    'User-Agent': 'TetoTV/1.10 Android libmpv',
    ..._currentStream.headers,
  };
  final _playerRootFocus = FocusNode(debugLabel: 'player.root');
  final _transportFocusScope = FocusScopeNode(
    debugLabel: 'player.transport.scope',
  );
  final _playControlFocus = FocusNode(debugLabel: 'player.play');
  final _progressControlFocus = FocusNode(debugLabel: 'player.progress');
  final _skipControlFocus = FocusNode(debugLabel: 'player.skip-segment');
  final _watchTogetherFocus = FocusNode(debugLabel: 'player.watch-together');
  final _playbackSpeedFocus = FocusNode(debugLabel: 'player.playback-speed');
  final _hiddenHudDpadSeek = HiddenPlayerDpadSeekRepeater();
  Timer? _controlsTimer;
  Timer? _videoWatchdog;
  Timer? _performanceWatchdog;
  StreamSubscription<Duration>? _progressSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<String>? _errorSubscription;
  bool _controlsVisible = true;
  bool _progressScrubActive = false;
  int _hudAutoHideHoldCount = 0;
  int _positionEventGeneration = 0;
  bool _progressHandled = false;
  bool _completionHandled = false;
  bool _libraryCompletionThresholdHandled = false;
  final PlayerHandoffGate _episodeHandoff = PlayerHandoffGate();
  final PlayerFailoverNoticeGate _failoverNoticeGate =
      PlayerFailoverNoticeGate();
  final PlaybackAudioDiagnosticEventGate _audioDiagnosticEventGate =
      PlaybackAudioDiagnosticEventGate();
  bool _preferredAudioSelected = false;
  bool _mediaOpenInProgress = false;
  int _mediaOpenVerifications = 0;
  int _mediaOpenRevision = 0;
  bool _preferredSubtitleSelected = false;
  String? _trackMessage;
  String? _playbackError;
  StreamSubscription<void>? _completedSubscription;
  List<SkipSegment> _skips = const [];
  Timer? _skipLoadTimer;
  Duration? _skipDurationCandidate;
  bool _skipLoadInFlight = false;
  bool _skipLoadComplete = false;
  int _skipLoadAttempts = 0;
  int _skipDurationRestarts = 0;
  int _skipLoadGeneration = 0;
  SkipSegment? _activeSkip;
  bool _canSkipNow = false;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  bool _videoFrameSeen = false;
  bool _softwareFallbackUsed = false;
  bool _changingDecoder = false;
  int _watchdogAttempts = 0;
  int _lastDroppedFrames = 0;
  int _highDropSamples = 0;
  bool _checkingPerformance = false;
  bool _checkingDecodedVideo = false;
  bool _playbackPersistenceReady = false;
  PlaybackDecoderMode _decoderMode = PlaybackDecoderMode.hardwareSafe;
  BoxFit _videoFit = BoxFit.contain;
  double _playbackRate = 1;
  double _subtitleSize = 34;
  int _subtitlePosition = 100;
  int _subtitleDelayMs = 0;
  int _audioDelayMs = 0;
  bool _highContrastSubtitles = false;
  late String _source;
  late ReleaseCandidate _currentRelease;
  late StreamReady _currentStream;
  List<PlaybackStreamOption> _directStreamOptions = const [];
  StreamSubscription<WebStreamSearchProgress>? _sourceDiscoverySubscription;
  final Set<String> _failedDirectStreamKeys = {};
  final Set<ReleaseCandidate> _attemptedReleaseAlternatives = {};
  bool _failingOver = false;
  bool _prewarming = false;
  bool _prewarmed = false;
  final NextEpisodePrewarmRetryPolicy _prewarmRetry =
      NextEpisodePrewarmRetryPolicy();
  late NextEpisodePrewarmSettingsKey _prewarmSettingsKey;
  bool _preserveNextEpisodePreparation = false;
  DateTime _lastCheckpointSave = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastMediaSessionUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<MediaAction>? _mediaActionSubscription;
  SeriesPlaybackPreferences _seriesPreferences =
      const SeriesPlaybackPreferences();
  bool _seriesPreferencesReady = false;
  PlaybackAudioPreference _audioPreference = PlaybackAudioPreference.dub;
  late PlaybackAudioPreference? _requestedAudio;
  Uint8List? _seekPreview;
  Duration? _seekPreviewPosition;
  Timer? _seekPreviewTimer;
  Duration? _queuedSeekTarget;
  bool _queuedSeekCapturePreview = false;
  int _queuedSeekGeneration = 0;
  Completer<void>? _seekDrainCompleter;
  final Set<Future<void>> _trickplayOperations = <Future<void>>{};
  int _trickplayGeneration = 0;
  Future<bool>? _skipSeekOperation;
  bool _skipInProgress = false;
  int _seekBackSeconds = 10;
  int _seekForwardSeconds = 10;
  Color _captionTextColor = Colors.white;
  Color _captionBackgroundColor = Colors.transparent;
  final PlayerSkipAutoFocusGate _skipAutoFocusGate = PlayerSkipAutoFocusGate();
  final Set<String> _consumedSkipSegments = {};
  final Set<String> _diagnosticActivatedSkipKeys = {};
  bool _allowExit = false;
  bool _confirmingExit = false;
  TapDownDetails? _touchDoubleTapDetails;
  bool _reportedPlaybackSuccess = false;
  bool _engineHandoffInProgress = false;
  bool _handoffAttemptActive = false;
  bool _handoffReleaseFailed = false;
  bool _playerReleasedForHandoff = false;
  bool _nativePlaybackStateClearedForHandoff = false;
  bool _routePopScheduled = false;
  bool _libraryStartupFailureExitScheduled = false;
  Duration? _pendingHandoffPosition;
  final PlayerReleaseCoordinator _handoffRelease = PlayerReleaseCoordinator();
  final Set<Future<void>> _playerMutationOperations = <Future<void>>{};
  Duration? _pendingInheritedResume;
  bool _lastResumeSeekSucceeded = true;
  Duration _lastPlayablePosition = Duration.zero;
  DateTime? _lastCommittedEndSeekAt;
  Duration? _lastCommittedEndSeekTarget;
  String? _watchPartyStatus;
  bool _watchPartyActive = false;
  int? _watchPartyWatchingCount;
  bool _guestControlsLocked = false;
  DateTime _lastGuestControlNotice = DateTime.fromMillisecondsSinceEpoch(0);
  int _diagnosticStreamOpenAttempt = 0;
  int _diagnosticConfirmedOpenAttempt = -1;
  int _diagnosticFallbackAttempt = 0;
  int _diagnosticWorkingOpenAttempt = -1;
  String? _diagnosticDecodedVideoSignature;
  Duration _lastDiagnosticPosition = Duration.zero;
  Duration _lastDiagnosticDuration = Duration.zero;
  PlaybackDiagnosticOutcome? _diagnosticLastOutcome;

  bool get _hasUntriedDirectStream => hasUntriedDirectWebStream(
    current: _currentStream,
    options: _directStreamOptions,
    currentFallbackProviderId: _currentRelease.sourceId,
    failedStreamKeys: _failedDirectStreamKeys,
  );
  PlaybackAudioPreference get _effectiveAudioPreference =>
      preferredAudioPreferenceForRelease(
        release: _currentRelease,
        globalPreference: _audioPreference,
        requestedAudio: _requestedAudio,
        seriesAudioLanguage: _seriesPreferences.audioLanguage,
        seriesOverride: _seriesPreferences.audioPreferenceSet,
      );
  String get _effectiveAudioLanguage => _seriesPreferences.audioPreferenceSet
      ? _seriesPreferences.audioLanguage
      : _effectiveAudioPreference.audioLanguage;
  bool get _animeFeaturesEnabled => widget.libraryPlayback == null;
  ExternalPlayerTarget? get _externalPlayerTarget {
    if (_watchPartyActive ||
        !ref.read(settingsPreferencesProvider).externalPlayerEnabled ||
        !externalPlayerLibraryProviderAllowed(
          widget.libraryPlayback?.request.sourceProviderId,
        )) {
      return null;
    }
    return externalPlayerTargetForStream(_currentStream);
  }

  /// A private-library stream may still have a verified public catalog
  /// identity when it was opened from the unified episode picker. That
  /// identity is sufficient for episode navigation and community skip timing,
  /// but never enables tracker writes, anime checkpoints, or provider
  /// discovery for the private stream itself.
  LibraryWatchPartyIdentity? get _libraryCatalogIdentity =>
      widget.libraryPlayback?.request.watchPartyIdentity;
  bool get _catalogEpisodeFeaturesEnabled =>
      _animeFeaturesEnabled ||
      widget.libraryPlayback?.request.isolation.nextEpisodeEnabled == true;
  bool get _skipSegmentFeaturesEnabled =>
      _animeFeaturesEnabled ||
      widget.libraryPlayback?.request.isolation.aniSkipEnabled == true;
  int? get _catalogAnilistMediaId => _animeFeaturesEnabled
      ? widget.anilistMediaId
      : _libraryCatalogIdentity?.anilistMediaId;
  int? get _catalogMalMediaId => _animeFeaturesEnabled
      ? widget.malMediaId
      : widget.launch.episode.malMediaId;
  int? get _catalogEpisodeNumber =>
      _animeFeaturesEnabled ? widget.episode : _libraryCatalogIdentity?.episode;

  PlaybackDiagnosticSourceKind get _diagnosticSourceKind {
    final libraryProvider = widget.libraryPlayback?.request.sourceProviderId
        .trim()
        .toLowerCase();
    if (libraryProvider != null) {
      if (libraryProvider.contains('plex')) {
        return PlaybackDiagnosticSourceKind.plex;
      }
      if (libraryProvider.contains('jellyfin')) {
        return PlaybackDiagnosticSourceKind.jellyfin;
      }
      if (libraryProvider.contains('device') ||
          libraryProvider.contains('local')) {
        return PlaybackDiagnosticSourceKind.local;
      }
      return PlaybackDiagnosticSourceKind.privateLibrary;
    }
    return _currentStream.isWebStream
        ? PlaybackDiagnosticSourceKind.web
        : PlaybackDiagnosticSourceKind.torrent;
  }

  PlaybackDiagnosticDecoder get _diagnosticDecoder => switch (_decoderMode) {
    PlaybackDecoderMode.hardwareSafe =>
      PlaybackDiagnosticDecoder.hardwareAdaptive,
    PlaybackDecoderMode.hardwareDirect =>
      PlaybackDiagnosticDecoder.hardwareDirect,
    PlaybackDecoderMode.software =>
      PlaybackDiagnosticDecoder.softwareCompatibility,
  };

  String? get _diagnosticQuality {
    final height = releaseQualityHeight(_currentRelease);
    return height > 0 ? '${height}p' : null;
  }

  PlaybackDiagnosticAudioIntent get _diagnosticRequestedAudio {
    if (_seriesPreferences.audioPreferenceSet) {
      return playbackDiagnosticAudioIntent(
        playbackAudioPreferenceForLanguage(_seriesPreferences.audioLanguage),
      );
    }
    return playbackDiagnosticAudioIntent(_effectiveAudioPreference);
  }

  PlaybackDiagnosticAudioPreferenceSource
  get _diagnosticAudioPreferenceSource =>
      playbackDiagnosticAudioPreferenceSource(
        release: _currentRelease,
        seriesOverride: _seriesPreferences.audioPreferenceSet,
        requestedAudio: _requestedAudio,
      );

  void _recordDiagnosticAudioTrackSelected({
    required AudioTrack track,
    required Iterable<AudioTrack> tracks,
    required bool preferenceMatched,
  }) {
    if (!_audioDiagnosticEventGate.shouldRecord(
      mediaRevision: _mediaOpenRevision,
      track: track,
      preferenceMatched: preferenceMatched,
    )) {
      return;
    }
    unawaited(
      _playbackDiagnostics.audioTrackSelected(
        requestedAudio: _diagnosticRequestedAudio,
        selectedAudioLanguage: playbackDiagnosticAudioLanguage(track),
        audioPreferenceSource: _diagnosticAudioPreferenceSource,
        audioTrackCount: playbackDiagnosticAudioTrackCount(tracks),
        preferenceMatched: preferenceMatched,
      ),
    );
  }

  void _recordDiagnosticSourceSelected({required bool automatic}) {
    final sourceKind = _diagnosticSourceKind;
    unawaited(
      _playbackDiagnostics.sourceSelected(
        sourceKind: sourceKind,
        quality: _diagnosticQuality,
        automatic: automatic,
        cached: sourceKind == PlaybackDiagnosticSourceKind.torrent
            ? !_currentStream.isDirectTorrent
            : null,
        requestedAudio: _diagnosticRequestedAudio,
        sourceAudioCapability: playbackDiagnosticAudioCapability(
          _currentRelease,
        ),
        audioPreferenceSource: _diagnosticAudioPreferenceSource,
      ),
    );
  }

  void _recordDiagnosticDecoderSelected({
    required bool automatic,
    String? reasonCode,
    String? decoderName,
    bool includeCurrentCodec = false,
  }) {
    unawaited(
      _playbackDiagnostics.decoderSelected(
        decoder: _diagnosticDecoder,
        automatic: automatic,
        codec: includeCurrentCodec ? _player.state.track.video.codec : null,
        decoderName: decoderName,
        reasonCode: reasonCode,
      ),
    );
  }

  void _recordDiagnosticOutcome(
    PlaybackDiagnosticOutcome outcome, {
    String? reasonCode,
  }) {
    _diagnosticLastOutcome = outcome;
    final currentPosition = _player.state.position;
    final currentDuration = _player.state.duration;
    final diagnosticPosition = currentPosition > Duration.zero
        ? currentPosition
        : _lastDiagnosticPosition;
    final diagnosticDuration = currentDuration > Duration.zero
        ? currentDuration
        : _lastDiagnosticDuration;
    unawaited(
      _playbackDiagnostics.finalOutcome(
        outcome: outcome,
        reasonCode: reasonCode,
        position: diagnosticPosition,
        duration: diagnosticDuration,
      ),
    );
  }

  void _recordDiagnosticWorkingOutcome() {
    // Video parameters may arrive while Player.open is still completing. Do
    // not let that asynchronous event put "working" ahead of the corresponding
    // verified stream-open result in the serialized diagnostic timeline.
    if (_diagnosticConfirmedOpenAttempt != _diagnosticStreamOpenAttempt) return;
    if (_diagnosticWorkingOpenAttempt == _diagnosticStreamOpenAttempt) return;
    _diagnosticWorkingOpenAttempt = _diagnosticStreamOpenAttempt;
    _recordDiagnosticOutcome(PlaybackDiagnosticOutcome.working);
  }

  void _recordDiagnosticStreamOpenResult({
    required int attempt,
    required bool succeeded,
    String? reasonCode,
  }) {
    unawaited(
      _playbackDiagnostics.streamOpened(
        sourceKind: _diagnosticSourceKind,
        succeeded: succeeded,
        codec: _player.state.track.video.codec,
        reasonCode: reasonCode,
        attempt: attempt,
      ),
    );
    if (!succeeded) return;
    _diagnosticConfirmedOpenAttempt = attempt;
    if (_videoFrameSeen) _recordDiagnosticWorkingOutcome();
  }

  bool get _hasNextEpisodeControl =>
      _catalogEpisodeFeaturesEnabled &&
      _catalogAnilistMediaId != null &&
      _catalogAnilistMediaId! > 0 &&
      _catalogEpisodeNumber != null &&
      _catalogEpisodeNumber! > 0;

  bool get _hasPreviousEpisodeControl => _hasNextEpisodeControl;

  bool get _previousEpisodeControlEnabled =>
      _hasPreviousEpisodeControl &&
      !_episodeHandoff.isEntered &&
      playerPreviousEpisodeAvailable(_catalogEpisodeNumber);

  bool get _nextEpisodeControlEnabled {
    if (!_hasNextEpisodeControl || _episodeHandoff.isEntered) return false;
    final episodeCount = widget.launch.episode.episodeCount;
    return episodeCount == null || _catalogEpisodeNumber! < episodeCount;
  }

  Future<void> _bootstrapPlayback() async {
    Duration? resume = widget.initialPosition;
    try {
      final appearance = ref.read(settingsPreferencesProvider);
      _audioPreference = appearance.preferredAudio;
      _seekBackSeconds = appearance.seekBackSeconds;
      _seekForwardSeconds = appearance.seekForwardSeconds;
      _captionTextColor = Color(appearance.captionTextColor);
      _captionBackgroundColor = Color(appearance.captionBackgroundColor);
      if (_catalogAnilistMediaId case final mediaId?) {
        _seriesPreferences = await _database.seriesPreferences(mediaId);
        _seriesPreferencesReady = true;
        if (_seriesPreferences.audioPreferenceSet) {
          _audioPreference =
              playbackAudioPreferenceForLanguage(
                _seriesPreferences.audioLanguage,
              ) ??
              _audioPreference;
        }
        _decoderMode = switch (_seriesPreferences.decoder) {
          'hardware-direct' => PlaybackDecoderMode.hardwareDirect,
          'software' => PlaybackDecoderMode.software,
          _ => PlaybackDecoderMode.hardwareSafe,
        };
        _videoFit = switch (_seriesPreferences.videoFit) {
          'cover' => BoxFit.cover,
          'fill' => BoxFit.fill,
          _ => BoxFit.contain,
        };
        _subtitleSize = _seriesPreferences.subtitleSize == 34
            ? appearance.captionTextSize
            : _seriesPreferences.subtitleSize;
        _subtitlePosition = _seriesPreferences.subtitlePosition;
        _subtitleDelayMs = _seriesPreferences.subtitleDelayMs;
        _audioDelayMs = _seriesPreferences.audioDelayMs;
        _highContrastSubtitles = _seriesPreferences.highContrastSubtitles;
        if (_animeFeaturesEnabled &&
            resume == null &&
            !widget.launch.episode.startFromBeginning &&
            widget.episode != null) {
          final checkpoint = await _database.checkpoint(
            mediaId,
            widget.episode!,
          );
          if (checkpoint != null &&
              !checkpoint.completed &&
              checkpoint.position > const Duration(seconds: 15) &&
              checkpoint.progress < .95) {
            resume = checkpoint.position;
          }
        }
      }
      if (_decoderMode == PlaybackDecoderMode.hardwareSafe &&
          releaseRequiresSoftwareDecoder(_currentRelease)) {
        _decoderMode = PlaybackDecoderMode.software;
        _softwareFallbackUsed = true;
      }
      if (!_seriesPreferences.subtitlePreferenceSet) {
        _applyAutomaticSubtitleDefaultForRelease(_currentRelease);
      }
      _watchPartyPlayback.updateRequestedAudio(_effectiveAudioPreference);
      if (!mounted || _engineHandoffInProgress) return;
      if (await _openConfiguredDefaultPlayer(appearance, resume: resume)) {
        return;
      }
      if (!mounted || _engineHandoffInProgress) return;
      _recordDiagnosticSourceSelected(
        automatic: widget.launch.episode.autoPlay,
      );
      _recordDiagnosticDecoderSelected(
        automatic: true,
        reasonCode: _softwareFallbackUsed ? 'codec_compatibility' : null,
      );
      try {
        await _openMedia(
          resume: resume,
          propagateFailure: true,
          requireDecodedVideo: _animeFeaturesEnabled,
        );
      } catch (error) {
        if (!mounted || _engineHandoffInProgress) return;
        await _tryNextStream(error.toString());
        return;
      }
      if (resume != null && mounted && !_engineHandoffInProgress) {
        _showTrackMessage(
          _lastResumeSeekSucceeded
              ? 'Resumed at ${_formatPlayerDuration(resume)}'
              : 'Could not restore the saved position',
        );
      }
    } finally {
      _playbackPersistenceReady = true;
    }
  }

  @override
  void initState() {
    super.initState();
    final initialParty = ref.read(watchPartyControllerProvider);
    _watchPartyStatus = watchPartyPlayerStatus(initialParty);
    _watchPartyActive = initialParty.isActive;
    _watchPartyWatchingCount = initialParty.isActive
        ? watchPartyViewerCount(initialParty)
        : null;
    _guestControlsLocked = initialParty.guestPlaybackControlsLocked;
    ref.listenManual(watchPartyControllerProvider, (_, next) {
      final status = watchPartyPlayerStatus(next);
      final locked = next.guestPlaybackControlsLocked;
      final active = next.isActive;
      final watchingCount = next.isActive ? watchPartyViewerCount(next) : null;
      if (!mounted ||
          status == _watchPartyStatus &&
              locked == _guestControlsLocked &&
              active == _watchPartyActive &&
              watchingCount == _watchPartyWatchingCount) {
        return;
      }
      final becameLocked = locked && !_guestControlsLocked;
      final activityChanged = active != _watchPartyActive;
      if (locked) {
        _hiddenHudDpadSeek.cancel();
        _trickplayGeneration++;
      }
      setState(() {
        _watchPartyStatus = status;
        _watchPartyActive = active;
        _watchPartyWatchingCount = watchingCount;
        _guestControlsLocked = locked;
        if (locked) {
          _queuedSeekTarget = null;
          _queuedSeekCapturePreview = false;
          _queuedSeekGeneration = 0;
        }
      });
      if (activityChanged) {
        if (active && _playbackRate != 1) {
          unawaited(_resetPlaybackRateForWatchParty());
        }
        _maybePrewarmNextEpisode(
          position: _player.state.position,
          duration: _player.state.duration,
        );
      }
      if (becameLocked) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_guestControlsLocked) return;
          _showControls();
          _watchTogetherFocus.requestFocus();
          _showGuestControlLockMessage();
        });
      }
    });
    // Final checkpoints and preferences are written during State.dispose,
    // after Riverpod has invalidated ConsumerState.ref.
    _database = ref.read(tetoTvDatabaseProvider);
    _nextEpisodePreparation = ref.read(
      nextEpisodePreparationControllerProvider,
    );
    _prewarmSettingsKey = NextEpisodePrewarmSettingsKey.fromSettings(
      ref.read(settingsPreferencesProvider),
    );
    ref.listenManual(settingsPreferencesProvider, (_, next) {
      final key = NextEpisodePrewarmSettingsKey.fromSettings(next);
      if (key == _prewarmSettingsKey) return;
      _prewarmSettingsKey = key;
      _invalidateNextEpisodePreparation();
    });
    _source = widget.source;
    _currentRelease = widget.launch.selectedRelease;
    _currentStream = widget.launch.stream;
    _requestedAudio = widget.launch.requestedAudio;
    _playbackDiagnostics = PlaybackDiagnosticSessionRecorder(
      database: _database,
    );
    _pendingInheritedResume = widget.initialPosition;
    _directStreamOptions = mergePlaybackStreamOptions([
      PlaybackStreamOption(stream: _currentStream, release: _currentRelease),
      ...widget.launch.directAlternatives.where(
        (option) => playbackEpisodeIdentityIsCompatible(
          episode: widget.launch.episode,
          stream: option.stream,
          release: option.release,
        ),
      ),
    ], const []);
    _ownsWatchPartyPlayback = widget.watchPartyPlayback == null;
    final libraryPlayback = widget.libraryPlayback;
    final libraryWatchIdentity = libraryPlayback?.request.watchPartyIdentity;
    _watchPartyPlayback =
        widget.watchPartyPlayback ??
        (libraryPlayback == null
            ? WatchPartyPlaybackCoordinator(
                episode: widget.launch.episode,
                release: widget.launch.selectedRelease,
                requestedAudio: widget.launch.requestedAudio,
              )
            : libraryWatchIdentity != null
            ? WatchPartyPlaybackCoordinator.publicCatalogEpisode(
                anilistMediaId: libraryWatchIdentity.anilistMediaId,
                episode: libraryWatchIdentity.episode,
                title: libraryWatchIdentity.title,
              )
            : WatchPartyPlaybackCoordinator.privateMedia(
                checkpointKey: libraryPlayback.request.checkpointKey,
                timelineIdentity: libraryPlayback.request.timelineIdentity,
                displayTitle: libraryPlayback.request.watchPartyDisplayTitle,
              ));
    _player = Player(
      configuration: const PlayerConfiguration(
        title: 'TetoTV',
        // Debrid streams are seekable HTTP sources; a 48 MiB cache keeps
        // playback smooth without starving low-memory Fire TV devices.
        bufferSize: 48 * 1024 * 1024,
        libass: true,
        libassAndroidFont: 'assets/fonts/NotoSans-Regular.ttf',
        libassAndroidFontName: 'Noto Sans',
      ),
    );
    _controller = VideoController(
      _player,
      configuration: tetoTvVideoControllerConfiguration,
    );
    _watchPartyHandle = _watchPartyPlayback.bindEngine(
      engine: 'mpv',
      play: () => _trackPlayerMutation(() async {
        if (_playerReleasedForHandoff) return;
        await _player.play();
      }),
      pause: () => _trackPlayerMutation(() async {
        if (_playerReleasedForHandoff) return;
        await _player.pause();
      }),
      seekTo: (position) => _trackPlayerMutation(() async {
        if (_playerReleasedForHandoff) return;
        _pendingInheritedResume = null;
        _trickplayGeneration++;
        await _player.seek(position);
        _recordCommittedSeek(position);
      }),
    );
    _watchPartyRouteHandoff = ref.read(watchPartyPlayerRouteHandoffProvider)
      ..bind(
        _watchPartyRouteHandoffOwner,
        () => _prepareForEngineHandoff(_effectiveHandoffPosition()),
      );
    _progressSubscription = _player.stream.position.listen(_onPosition);
    _durationSubscription = _player.stream.duration.listen((duration) {
      if (duration > Duration.zero) _lastDiagnosticDuration = duration;
      if (_skipSegmentFeaturesEnabled) {
        _scheduleSkipSegmentLoad(duration);
      }
      _reportLibraryPlayback();
      _publishWatchPartyPlayback();
    });
    _tracksSubscription = _player.stream.tracks.listen(_onTracksChanged);
    _errorSubscription = _player.stream.error.listen((message) {
      // Reopening MPV can briefly replay the error which caused the reopen.
      // The in-flight mutation owns that result; starting source failover at
      // the same time races two opens against one native player.
      if (_changingDecoder ||
          _mediaOpenInProgress ||
          _mediaOpenVerifications > 0 ||
          _engineHandoffInProgress) {
        return;
      }
      // Plex/Jellyfin can replace an unsupported audio or video codec with a
      // compatibility stream. Prefer that typed recovery over reopening the
      // same private source with a video-only decoder change.
      if (widget.libraryPlayback != null &&
          _handleLibraryStartupFailure(message)) {
        return;
      }
      if (isLikelyVideoDecodeFailure(message) &&
          !_softwareFallbackUsed &&
          !_hasUntriedDirectStream) {
        unawaited(_restartWithSoftwareDecoder(message));
        return;
      }
      if (widget.libraryPlayback != null) {
        _showLibraryRuntimeError();
        return;
      }
      unawaited(_tryNextStream(message));
    });
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (completed) _handlePlaybackCompleted();
    });
    _videoParamsSubscription = _player.stream.videoParams.listen((params) {
      if (params.w == null || params.h == null) return;
      _videoFrameSeen = true;
      if (!_reportedPlaybackSuccess) {
        _reportedPlaybackSuccess = true;
        unawaited(_recordEngineSuccess());
      }
      final diagnosticSignature = '$_mediaOpenRevision:${_decoderMode.name}';
      if (_diagnosticDecodedVideoSignature != diagnosticSignature) {
        _diagnosticDecodedVideoSignature = diagnosticSignature;
        _recordDiagnosticDecoderSelected(
          automatic: true,
          reasonCode: 'decoded_video_observed',
          includeCurrentCodec: true,
        );
      }
      _recordDiagnosticWorkingOutcome();
      _videoWatchdog?.cancel();
      debugPrint('\n--- PLAYBACK DIAGNOSTICS ---');
      debugPrint('Resolution: ${params.w}x${params.h}');
      debugPrint('Pixel format: ${params.pixelformat ?? "unknown"}');
      debugPrint('Hardware Pixel format: ${params.hwPixelformat ?? "unknown"}');
      debugPrint('Color matrix: ${params.colormatrix ?? "unknown"}');
      debugPrint('Color levels (range): ${params.colorlevels ?? "unknown"}');
      debugPrint('Primaries (HDR/SDR): ${params.primaries ?? "unknown"}');
      debugPrint('Gamma: ${params.gamma ?? "unknown"}');
      debugPrint(
        'Video Codec: ${_player.state.track.video.codec ?? "unknown"}',
      );
      debugPrint(
        'Audio Codec: ${_player.state.track.audio.codec ?? "unknown"}',
      );
      debugPrint('Player/Backend: media_kit (libmpv)');
      debugPrint('VO/hwdec: gpu / ${hwdecForPlaybackMode(_decoderMode)}');
      debugPrint('----------------------------\n');
      unawaited(_matchContentFrameRate());
      unawaited(_inspectDecodedVideo(params));
    });
    _playingSubscription = _player.stream.playing.listen((_) {
      _reportLibraryPlayback(force: true);
      _publishWatchPartyPlayback();
      unawaited(_updateMediaSession(force: true));
    });
    _mediaActionSubscription = AndroidTvBridge.instance.mediaActions.listen(
      _handleMediaAction,
    );
    unawaited(_bootstrapPlayback());
    if (_skipSegmentFeaturesEnabled) {
      _scheduleSkipSegmentLoad(_player.state.duration);
    }
    if (_animeFeaturesEnabled) {
      unawaited(_startWebSourceDiscovery());
    }
    _scheduleControlsHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _playControlFocus.requestFocus();
      if (_currentStream.externalSubtitleRejected) {
        _showTrackMessage(
          'External subtitles were blocked because they were unsafe or unsupported.',
        );
      }
    });
  }

  bool get _canApplyTrackSelection =>
      mounted && !_engineHandoffInProgress && !_playerReleasedForHandoff;

  void _onTracksChanged(Tracks tracks) {
    unawaited(_runTrackedTrackSelection(tracks));
  }

  Future<void> _runTrackedTrackSelection(Tracks tracks) async {
    try {
      await _trackPlayerMutation(() => _selectPreferredTracks(tracks));
    } catch (error, stackTrace) {
      if (_canApplyTrackSelection) {
        debugPrint('MPV track selection failed: $error\n$stackTrace');
      }
    }
  }

  Future<void> _applyPreferredAudio(Tracks tracks) async {
    if (_preferredAudioSelected ||
        _mediaOpenInProgress ||
        !_canApplyTrackSelection) {
      return;
    }
    final mediaRevision = _mediaOpenRevision;
    final device = await AndroidTvBridge.instance.getDeviceProfile();
    // Device-profile lookup crosses the platform channel. The player route can
    // begin an engine handoff while it is pending, so never resume against a
    // player whose release has already started.
    if (_preferredAudioSelected ||
        _mediaOpenInProgress ||
        mediaRevision != _mediaOpenRevision ||
        !_canApplyTrackSelection) {
      return;
    }
    final preferred = _seriesPreferences.audioPreferenceSet
        ? preferredAudioTrackForLanguage(
            tracks.audio,
            language: _seriesPreferences.audioLanguage,
            preferSurround: device.hasHdmiAudio,
            // A demuxer may announce its default track before publishing the
            // rest. Do not lock a temporary fallback.
            allowFallback: false,
          )
        : preferredAudioTrack(
            tracks.audio,
            preference: _effectiveAudioPreference,
            preferSurround: device.hasHdmiAudio,
            allowFallback: false,
          );
    if (preferred == null || !_canApplyTrackSelection) return;
    final matchesPreference = _seriesPreferences.audioPreferenceSet
        ? playerTrackMatchesAudioLanguage(
            preferred,
            _seriesPreferences.audioLanguage,
          )
        : playerTrackMatchesAudioPreference(
            preferred,
            _effectiveAudioPreference,
          );
    if (mediaRevision != _mediaOpenRevision || _mediaOpenInProgress) return;
    await _player.setAudioTrack(preferred);
    if (mediaRevision != _mediaOpenRevision ||
        _mediaOpenInProgress ||
        !_canApplyTrackSelection) {
      return;
    }
    _recordDiagnosticAudioTrackSelected(
      track: preferred,
      tracks: tracks.audio,
      preferenceMatched: matchesPreference,
    );
    // A failed engine command must remain retryable on the next track snapshot.
    _preferredAudioSelected = matchesPreference;
    _showTrackMessage(
      'Preferred audio: '
      '${preferred.title ?? preferred.language ?? _effectiveAudioPreference.displayName}',
    );
  }

  Future<void> _selectPreferredTracks(Tracks tracks) async {
    await _applyPreferredAudio(tracks);
    if (!_canApplyTrackSelection ||
        _preferredSubtitleSelected ||
        !_seriesPreferences.subtitleEnabled) {
      return;
    }
    final language = _seriesPreferences.subtitleLanguage.toLowerCase();
    final matches =
        tracks.subtitle
            .where((track) => track.id != 'auto' && track.id != 'no')
            .where(
              (track) =>
                  playerTrackLanguageScore(
                    language: track.language,
                    title: track.title,
                    preferredLanguage: language,
                    subtitle: true,
                  ) >
                  0,
            )
            .toList(growable: false)
          ..sort(
            (a, b) =>
                playerTrackLanguageScore(
                  language: b.language,
                  title: b.title,
                  preferredLanguage: language,
                  subtitle: true,
                ).compareTo(
                  playerTrackLanguageScore(
                    language: a.language,
                    title: a.title,
                    preferredLanguage: language,
                    subtitle: true,
                  ),
                ),
          );
    final preferred = matches.firstOrNull;
    if (preferred == null || !_canApplyTrackSelection) return;
    await _player.setSubtitleTrack(preferred);
    if (!_canApplyTrackSelection) return;
    // Keep this retryable if libmpv rejected the command while its demuxer was
    // still publishing tracks.
    _preferredSubtitleSelected = true;
  }

  void _applyAutomaticSubtitleDefaultForRelease(ReleaseCandidate release) {
    if (_seriesPreferences.subtitlePreferenceSet) return;
    _seriesPreferences = _seriesPreferences.copyWith(
      subtitleEnabled: subtitlesEnabledForAudioPreference(
        release,
        _effectiveAudioPreference,
      ),
    );
  }

  void _onPosition(Duration position) {
    if (position > Duration.zero) _lastDiagnosticPosition = position;
    final duration = _player.state.duration;
    if (duration <= Duration.zero || position != duration) {
      _lastPlayablePosition = position;
    }
    _positionEventGeneration++;
    final pendingResume = _pendingInheritedResume;
    if (pendingResume != null &&
        playerResumeTargetReached(target: pendingResume, actual: position)) {
      _pendingInheritedResume = null;
    }
    final effectivePosition = effectivePlayerResumePosition(
      position: position,
      pendingResume: _pendingInheritedResume,
    );
    // A scene-preview seek is provisional until the thumb is released. Do not
    // checkpoint it, update trackers, or fan it out to Watch Party guests.
    if (_progressScrubActive) return;
    _reportLibraryPlayback(position: effectivePosition);
    _publishWatchPartyPlayback(position: position);
    if (_skipSegmentFeaturesEnabled) _checkSkips(position);
    if (_playbackPersistenceReady) {
      unawaited(_persistPlayback(effectivePosition));
      unawaited(_updateMediaSession());
    }
    if (_skipSegmentFeaturesEnabled) _scheduleSkipSegmentLoad(duration);
    if (duration.inSeconds <= 0) return;
    final completionThreshold = ref
        .read(settingsPreferencesProvider)
        .trackerUpdateThreshold;
    final libraryPlayback = widget.libraryPlayback;
    if (!_libraryCompletionThresholdHandled &&
        libraryPlayback != null &&
        trackerUpdateThresholdReached(
          position: effectivePosition,
          duration: duration,
          threshold: completionThreshold,
        )) {
      _libraryCompletionThresholdHandled = true;
      libraryPlayback.markCompleted(
        position: effectivePosition,
        duration: duration,
        playing: _player.state.playing,
      );
    }
    _maybePrewarmNextEpisode(position: position, duration: duration);
    if (_progressHandled || widget.episode == null) return;
    if (widget.anilistMediaId == null && widget.malMediaId == null) return;
    if (!trackerUpdateThresholdReached(
      position: position,
      duration: duration,
      threshold: completionThreshold,
    )) {
      return;
    }
    _progressHandled = true;
    unawaited(_syncProgress());
  }

  void _reportLibraryPlayback({Duration? position, bool force = false}) {
    final effectivePosition = effectivePlayerResumePosition(
      position: position ?? _player.state.position,
      pendingResume: _pendingInheritedResume,
    );
    final effectiveDuration = effectivePlayerProgressDuration(
      duration: _player.state.duration,
      effectivePosition: effectivePosition,
      pendingResume: _pendingInheritedResume,
    );
    widget.libraryPlayback?.report(
      position: effectivePosition,
      duration: effectiveDuration,
      playing: _player.state.playing,
      force: force,
    );
  }

  void _publishWatchPartyPlayback({Duration? position}) {
    if (_engineHandoffInProgress || _playerReleasedForHandoff) return;
    final duration = _player.state.duration;
    _watchPartyPlayback.publish(
      _watchPartyHandle,
      position: position ?? _player.state.position,
      duration: duration,
      playing: _player.state.playing,
      ready: _playbackPersistenceReady && duration > Duration.zero,
    );
  }

  void _checkSkips(Duration position) {
    final active = activeSkipSegmentAt(
      segments: _skips,
      position: position,
      consumed: _consumedSkipSegments,
    );
    if (!playerCanUseSkipMarkers(guestControlsLocked: _guestControlsLocked)) {
      if (active != null) {
        final key = 'guest:${active.kind.name}:${active.start.inMilliseconds}';
        if (_diagnosticActivatedSkipKeys.add(key)) {
          _recordSkipSegmentActionDiagnostic(
            status: 'suppressed_for_guest',
            segment: active,
            automatic: false,
            position: position,
          );
        }
      }
      if (_canSkipNow || _activeSkip != null) {
        final skipHadFocus = _skipControlFocus.hasFocus;
        setState(() {
          _canSkipNow = false;
          _activeSkip = null;
        });
        _recoverFocusAfterSkipDismissed(skipHadFocus: skipHadFocus);
      }
      return;
    }
    if (active != null) {
      final settings = ref.read(settingsPreferencesProvider);
      final autoSkip = shouldAutomaticallySkipSegment(
        active,
        autoSkipIntros: settings.autoSkipIntros,
        autoSkipOutros: settings.autoSkipOutros,
      );
      final key = skipSegmentKey(active);
      if (_diagnosticActivatedSkipKeys.add('host:$key')) {
        _recordSkipSegmentActionDiagnostic(
          status: 'marker_activated',
          segment: active,
          automatic: autoSkip,
          position: position,
        );
      }
      if (autoSkip && !_skipInProgress && _consumedSkipSegments.add(key)) {
        if (mounted) {
          final skipHadFocus = _skipControlFocus.hasFocus;
          setState(() {
            _activeSkip = null;
            _canSkipNow = false;
          });
          _recoverFocusAfterSkipDismissed(skipHadFocus: skipHadFocus);
        }
        unawaited(_autoSkipSegment(active));
        return;
      }
    }
    final canSkip = active != null;
    if (_canSkipNow != canSkip) {
      final skipHadFocus = !canSkip && _skipControlFocus.hasFocus;
      setState(() {
        _canSkipNow = canSkip;
        _activeSkip = active;
      });
      if (canSkip) {
        _focusSkipOnce(active);
      } else {
        _recoverFocusAfterSkipDismissed(skipHadFocus: skipHadFocus);
      }
    } else if (!identical(_activeSkip, active)) {
      final skipHadFocus = active == null && _skipControlFocus.hasFocus;
      setState(() => _activeSkip = active);
      if (active != null) {
        _focusSkipOnce(active);
      } else {
        _recoverFocusAfterSkipDismissed(skipHadFocus: skipHadFocus);
      }
    }
  }

  void _recoverFocusAfterSkipDismissed({required bool skipHadFocus}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _engineHandoffInProgress) return;
      switch (playerSkipDismissFocusTarget(
        skipHadFocus: skipHadFocus,
        skipStillAvailable: _skipFocusAvailable,
        controlsVisible: _controlsVisible,
        guestControlsLocked: _guestControlsLocked,
      )) {
        case PlayerSkipDismissFocusTarget.none:
          return;
        case PlayerSkipDismissFocusTarget.playerRoot:
          _playerRootFocus.requestFocus();
        case PlayerSkipDismissFocusTarget.playControl:
          _playControlFocus.requestFocus();
        case PlayerSkipDismissFocusTarget.watchPartyControl:
          _watchTogetherFocus.requestFocus();
      }
    });
  }

  Future<void> _autoSkipSegment(SkipSegment segment) async {
    final segmentKey = skipSegmentKey(segment);
    if (_skipInProgress ||
        _engineHandoffInProgress ||
        _blockGuestLocalControl(notify: false)) {
      _consumedSkipSegments.remove(segmentKey);
      return;
    }
    _skipInProgress = true;
    final target = safeSkipSegmentTarget(
      requested: segment.end,
      duration: _player.state.duration,
    );
    _recordSkipSegmentActionDiagnostic(
      status: 'automatic_action_started',
      segment: segment,
      automatic: true,
      position: _player.state.position,
      target: target,
    );
    try {
      final duration = _player.state.duration;
      final wasPlaying = _player.state.playing;
      final succeeded = await _seekForSkip(target);
      if (!succeeded) throw StateError('skip seek failed');
      _recordSkipSegmentActionDiagnostic(
        status: 'seek_succeeded',
        segment: segment,
        automatic: true,
        position: _player.state.position,
        target: target,
        seekSucceeded: true,
      );
      if (mounted && !_engineHandoffInProgress) {
        _showTrackMessage(
          segment.kind == SkipSegmentKind.opening
              ? 'Intro skipped'
              : 'Outro skipped',
        );
      }
      if (!wasPlaying &&
          segment.kind == SkipSegmentKind.ending &&
          skipSegmentReachesPlaybackEnd(
            requestedEnd: segment.end,
            duration: duration,
          )) {
        _handlePlaybackCompleted();
      }
    } catch (_) {
      _recordSkipSegmentActionDiagnostic(
        status: 'seek_failed',
        segment: segment,
        automatic: true,
        position: _player.state.position,
        target: target,
        seekSucceeded: false,
      );
      _consumedSkipSegments.remove(segmentKey);
      if (mounted && !_engineHandoffInProgress) {
        _showTrackMessage('Could not skip this segment');
      }
    } finally {
      _skipInProgress = false;
      if (mounted && !_engineHandoffInProgress) {
        _checkSkips(_player.state.position);
      }
    }
  }

  void _focusSkipOnce(SkipSegment segment) {
    final key = skipSegmentKey(segment);
    if (!shouldAutoFocusSkipAction(
      controlsVisible: _controlsVisible,
      transportFocused: _transportFocusScope.hasFocus,
      playerRouteIsCurrent: ModalRoute.of(context)?.isCurrent ?? true,
      handoffInProgress: _engineHandoffInProgress,
    )) {
      return;
    }
    if (!_skipAutoFocusGate.claim(key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _activeSkip == segment &&
          shouldAutoFocusSkipAction(
            controlsVisible: _controlsVisible,
            transportFocused: _transportFocusScope.hasFocus,
            playerRouteIsCurrent: ModalRoute.of(context)?.isCurrent ?? true,
            handoffInProgress: _engineHandoffInProgress,
          )) {
        _skipControlFocus.requestFocus();
      }
    });
  }

  void _scheduleSkipSegmentLoad(Duration duration) {
    if (!_skipSegmentFeaturesEnabled) return;
    if (_skipLoadInFlight ||
        _engineHandoffInProgress ||
        duration <= Duration.zero) {
      return;
    }
    if (_skipLoadComplete) {
      final completedDuration = _skipDurationCandidate;
      if (_skips.isNotEmpty ||
          completedDuration == null ||
          skipSegmentLookupDurationsEquivalent(completedDuration, duration)) {
        return;
      }
      // A Web/HLS demuxer can publish a short provisional duration, then its
      // complete VOD duration later. Reopen an empty/partial lookup when that
      // happens even if the provisional request returned a clean no-match. Do
      // not use the wider marker-acceptance tolerance for this decision.
      _skipLoadComplete = false;
      _skipLoadAttempts = 0;
      _skipDurationRestarts = 0;
    }
    final previous = _skipDurationCandidate;
    _skipDurationCandidate = duration;
    if (previous != null &&
        (previous - duration).abs() <= const Duration(seconds: 1) &&
        _skipLoadTimer?.isActive == true) {
      return;
    }
    _skipLoadTimer?.cancel();
    final generation = _skipLoadGeneration;
    _skipLoadTimer = Timer(const Duration(milliseconds: 1200), () {
      if (generation != _skipLoadGeneration) return;
      unawaited(_loadSkipSegments(duration, generation: generation));
    });
  }

  Future<int?> _resolveSkipMalMediaId() async {
    if (!_skipSegmentFeaturesEnabled) return null;
    final known = _catalogMalMediaId ?? widget.launch.episode.malMediaId;
    if (known != null && known > 0) return known;
    final anilistId =
        _catalogAnilistMediaId ?? widget.launch.episode.anilistMediaId;
    if (anilistId <= 0) return null;
    try {
      return (await ref.read(catalogClientProvider).details(anilistId)).idMal;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSkipSegments(
    Duration duration, {
    required int generation,
  }) async {
    if (_skipLoadComplete ||
        _skipLoadInFlight ||
        generation != _skipLoadGeneration ||
        _engineHandoffInProgress ||
        !mounted) {
      return;
    }
    _skipLoadInFlight = true;
    _skipLoadAttempts++;
    var externalFailed = false;
    var externalStatus = 'not_requested';
    var externalProbeCount = 0;
    var externalDurationFallbackUsed = false;
    var externalRuntimeProbesExhausted = false;
    try {
      final episode = _catalogEpisodeNumber ?? widget.launch.episode.episode;
      final malMediaId = await _resolveSkipMalMediaId();
      final Future<List<SkipSegment>> externalFuture;
      if (malMediaId == null || episode <= 0) {
        externalStatus = 'catalog_mapping_unavailable';
        externalFuture = Future<List<SkipSegment>>.value(const <SkipSegment>[]);
      } else {
        externalStatus = 'requested';
        externalFuture = AniSkipClient()
            .lookup(
              malMediaId: malMediaId,
              episode: episode,
              episodeDuration: duration,
              allowRuntimeFallback: _currentStream.isWebStream,
            )
            .then((result) {
              externalProbeCount = result.probeCount;
              externalDurationFallbackUsed = result.usedDurationFallback;
              externalRuntimeProbesExhausted =
                  _currentStream.isWebStream &&
                  result.segments.isEmpty &&
                  result.runtimeFallbackSearchComplete;
              externalStatus = result.segments.isEmpty
                  ? externalRuntimeProbesExhausted
                        ? 'no_match_after_nearby_runtimes'
                        : 'no_match'
                  : result.usedDurationFallback
                  ? 'found_nearby_runtime'
                  : 'found';
              return result.segments;
            })
            .catchError((_) {
              externalFailed = true;
              externalStatus = 'request_failed';
              return const <SkipSegment>[];
            });
      }
      if (malMediaId == null && _skipSegmentFeaturesEnabled) {
        externalFailed = true;
      }
      final embedded = await _embeddedChapterSkipsWithRetry(duration);
      if (generation != _skipLoadGeneration) return;
      if (mounted && !_engineHandoffInProgress && embedded.isNotEmpty) {
        setState(() => _skips = embedded);
        _publishWatchPartyTimelineAnchors();
        _checkSkips(_player.state.position);
      }
      final external = await externalFuture;
      if (!mounted ||
          generation != _skipLoadGeneration ||
          _engineHandoffInProgress) {
        return;
      }
      final currentDuration = _player.state.duration;
      // HLS/Web manifests often refine their duration for several seconds
      // after MPV opens them. AniSkip already tolerates small container and
      // credit differences, so do not discard valid markers merely because a
      // Web playlist settled a few seconds away from the first duration event.
      if (!skipSegmentDurationsCompatible(duration, currentDuration)) {
        _skipDurationCandidate = currentDuration;
        _recordSkipSegmentDiagnostic(
          status: 'duration_changed',
          externalStatus: externalStatus,
          embeddedCount: embedded.length,
          externalCount: external.length,
          requestedDuration: duration,
          currentDuration: currentDuration,
          communityProbeCount: externalProbeCount,
          durationFallbackUsed: externalDurationFallbackUsed,
        );
        if (_skipDurationRestarts++ < 8) {
          _skipLoadAttempts = (_skipLoadAttempts - 1).clamp(0, 4);
        }
        return;
      }
      setState(() => _skips = mergeSkipSegments(embedded, external));
      _publishWatchPartyTimelineAnchors();
      _checkSkips(_player.state.position);
      _skipLoadComplete = skipSegmentLookupIsComplete(
        isWebStream: _currentStream.isWebStream,
        externalFailed: externalFailed,
        hasMarkers: _skips.isNotEmpty,
        attempts: _skipLoadAttempts,
        runtimeProbesExhausted: externalRuntimeProbesExhausted,
      );
      _recordSkipSegmentDiagnostic(
        status: _skips.isEmpty ? 'no_markers' : 'markers_ready',
        externalStatus: externalStatus,
        embeddedCount: embedded.length,
        externalCount: external.length,
        requestedDuration: duration,
        currentDuration: currentDuration,
        communityProbeCount: externalProbeCount,
        durationFallbackUsed: externalDurationFallbackUsed,
      );
    } catch (_) {
      if (generation != _skipLoadGeneration) return;
      // Chapter and community skip data are optional playback enhancements.
      externalFailed = true;
      _recordSkipSegmentDiagnostic(
        status: 'load_failed',
        externalStatus: externalStatus,
        embeddedCount: 0,
        externalCount: 0,
        requestedDuration: duration,
        currentDuration: _player.state.duration,
      );
    } finally {
      if (generation == _skipLoadGeneration) {
        _skipLoadInFlight = false;
        if (mounted && !_skipLoadComplete && _skipLoadAttempts < 4) {
          _scheduleSkipSegmentLoad(_player.state.duration);
        }
      }
    }
  }

  void _resetSkipSegmentsForSourceChange() {
    final skipHadFocus = _skipControlFocus.hasFocus;
    _skipLoadGeneration++;
    _skipLoadTimer?.cancel();
    _skipLoadInFlight = false;
    _skipLoadComplete = false;
    _skipLoadAttempts = 0;
    _skipDurationRestarts = 0;
    _skipDurationCandidate = null;
    _consumedSkipSegments.clear();
    _diagnosticActivatedSkipKeys.clear();
    _skipAutoFocusGate.reset();
    setState(() {
      _skips = const [];
      _activeSkip = null;
      _canSkipNow = false;
    });
    _watchPartyPlayback.updateTimelineAnchors(const []);
    _publishWatchPartyPlayback();
    _recoverFocusAfterSkipDismissed(skipHadFocus: skipHadFocus);
    _scheduleSkipSegmentLoad(_player.state.duration);
  }

  void _recordSkipSegmentDiagnostic({
    required String status,
    required String externalStatus,
    required int embeddedCount,
    required int externalCount,
    required Duration requestedDuration,
    required Duration currentDuration,
    int communityProbeCount = 0,
    bool durationFallbackUsed = false,
  }) {
    unawaited(
      _database.recordDiagnosticEvent(
        category: 'player-skip-segments',
        message: 'Skip segment lookup',
        details: <String, Object?>{
          'status': status,
          'source_kind': _diagnosticSourceKind.name,
          'catalog_mapping_available':
              externalStatus != 'catalog_mapping_unavailable',
          'attempt': _skipLoadAttempts,
          'embedded_marker_count': embeddedCount,
          'community_marker_count': externalCount,
          'community_status': externalStatus,
          'community_probe_count': communityProbeCount,
          'duration_fallback_used': durationFallbackUsed,
          'requested_duration_ms': requestedDuration.inMilliseconds.clamp(
            0,
            const Duration(hours: 24).inMilliseconds,
          ),
          'current_duration_ms': currentDuration.inMilliseconds.clamp(
            0,
            const Duration(hours: 24).inMilliseconds,
          ),
        },
      ),
    );
  }

  void _recordSkipSegmentActionDiagnostic({
    required String status,
    required SkipSegment segment,
    required bool automatic,
    required Duration position,
    Duration? target,
    bool? seekSucceeded,
  }) {
    unawaited(
      _database.recordDiagnosticEvent(
        category: 'player-skip-segments',
        message: 'Skip segment action',
        details: <String, Object?>{
          'status': status,
          'source_kind': _diagnosticSourceKind.name,
          'segment_kind': segment.kind.name,
          'marker_source': segment.source.name,
          'automatic': automatic,
          'seek_succeeded': ?seekSucceeded,
          'watch_party_active': _watchPartyActive,
          'guest_controls_locked': _guestControlsLocked,
          'controls_visible': _controlsVisible,
          'marker_count': _skips.length.clamp(0, 32),
          'matching_marker_count': _skips
              .where((candidate) => candidate.kind == segment.kind)
              .length
              .clamp(0, 16),
          'position_ms': position.inMilliseconds.clamp(
            0,
            const Duration(hours: 24).inMilliseconds,
          ),
          'marker_start_ms': segment.start.inMilliseconds.clamp(
            0,
            const Duration(hours: 24).inMilliseconds,
          ),
          'marker_end_ms': segment.end.inMilliseconds.clamp(
            0,
            const Duration(hours: 24).inMilliseconds,
          ),
          'target_ms': ?target?.inMilliseconds.clamp(
            0,
            const Duration(hours: 24).inMilliseconds,
          ),
          'duration_ms': _player.state.duration.inMilliseconds.clamp(
            0,
            const Duration(hours: 24).inMilliseconds,
          ),
        },
      ),
    );
  }

  void _publishWatchPartyTimelineAnchors() {
    SkipSegment? firstOf(SkipSegmentKind kind) => _skips
        .where((segment) => segment.kind == kind)
        .fold<SkipSegment?>(
          null,
          (current, candidate) =>
              current == null || candidate.start < current.start
              ? candidate
              : current,
        );

    final anchors = <WatchPartyTimelineAnchor>[];
    void add(
      SkipSegmentKind segmentKind,
      WatchPartyTimelineAnchorKind startKind,
      WatchPartyTimelineAnchorKind endKind,
    ) {
      final segment = firstOf(segmentKind);
      if (segment == null) return;
      anchors
        ..add(
          WatchPartyTimelineAnchor(kind: startKind, position: segment.start),
        )
        ..add(WatchPartyTimelineAnchor(kind: endKind, position: segment.end));
    }

    add(
      SkipSegmentKind.recap,
      WatchPartyTimelineAnchorKind.recapStart,
      WatchPartyTimelineAnchorKind.recapEnd,
    );
    add(
      SkipSegmentKind.opening,
      WatchPartyTimelineAnchorKind.openingStart,
      WatchPartyTimelineAnchorKind.openingEnd,
    );
    add(
      SkipSegmentKind.ending,
      WatchPartyTimelineAnchorKind.endingStart,
      WatchPartyTimelineAnchorKind.endingEnd,
    );
    _watchPartyPlayback.updateTimelineAnchors(anchors);
    _publishWatchPartyPlayback();
  }

  Future<List<SkipSegment>> _embeddedChapterSkipsWithRetry(
    Duration duration,
  ) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      if (_engineHandoffInProgress) return const [];
      final segments = await _embeddedChapterSkips(duration);
      if (segments.isNotEmpty) return segments;
      if (attempt < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    return const [];
  }

  Future<List<SkipSegment>> _embeddedChapterSkips(Duration duration) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return const [];
    try {
      final count = int.tryParse(
        await platform.getProperty('chapter-list/count'),
      );
      if (count == null || count <= 0 || count > 100) return const [];
      final chapters = <MediaChapter>[];
      for (var index = 0; index < count; index++) {
        final title = await platform.getProperty('chapter-list/$index/title');
        final seconds = double.tryParse(
          await platform.getProperty('chapter-list/$index/time'),
        );
        if (seconds == null || seconds < 0) continue;
        chapters.add(
          MediaChapter(
            title: title,
            start: Duration(milliseconds: (seconds * 1000).round()),
          ),
        );
      }
      return skipSegmentsFromChapters(chapters, duration);
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _openPreparedNextEpisode(
    StateController<Set<int>> unavailableNoticeController,
  ) async {
    final mediaId = _catalogAnilistMediaId;
    final currentEpisode = _catalogEpisodeNumber;
    if (mediaId == null || currentEpisode == null) return false;
    final preparation = ref.read(nextEpisodePreparationControllerProvider);
    final prepared = await preparation.take(
      mediaId,
      currentEpisode,
      currentRequest: _nextEpisodePreparationRequest(),
    );
    if (prepared == null) return false;
    if (!prepared.hasCompatibleEpisodeIdentity) {
      // Keep the current engine alive and return to ordinary next-episode
      // resolution. This is the last in-memory boundary before handoff, so a
      // stale or malformed prepared candidate cannot make the router reject
      // playback only after the current player has already been released.
      await prepared.close();
      return false;
    }
    final privateRequest = prepared.privateLibraryRequest;
    if (privateRequest != null && widget.onLibraryEpisodeHandoff == null) {
      await prepared.close();
      return false;
    }
    if (!mounted || _engineHandoffInProgress) {
      await prepared.close();
      return true;
    }
    final requestedEpisode = currentEpisode + 1;
    if (prepared.fillerDecision.dataUnavailable &&
        consumeFillerUnavailableNotice(unavailableNoticeController, mediaId)) {
      showFillerDataUnavailableNotice(context, episode: requestedEpisode);
    }
    unawaited(showFillerSkipNotification(context, prepared.fillerDecision));
    if (!mounted || _engineHandoffInProgress) {
      await prepared.close();
      return true;
    }
    final handoffPosition = _effectiveHandoffPosition();
    if (!await _prepareForEngineHandoff(handoffPosition)) {
      await prepared.close();
      return true;
    }
    if (!mounted) {
      await prepared.close();
      return true;
    }
    _preserveNextEpisodePreparation = true;
    if (privateRequest != null) {
      try {
        final adopted = await widget.onLibraryEpisodeHandoff!(privateRequest);
        if (adopted) return true;
      } catch (_) {
        // The current engine is already released. Cleanup and close the route
        // rather than allowing a private request to fall into public routing.
      }
      _preserveNextEpisodePreparation = false;
      await prepared.close();
      if (mounted) _popPlayerRouteAfterHandoff(Navigator.of(context));
      return true;
    }
    try {
      final navigation = GoRouter.of(context).pushReplacement<void>(
        preparedNextEpisodePlayerLocation(prepared),
        extra: prepared.launch,
      );
      unawaited(
        navigation.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) async {
            _preserveNextEpisodePreparation = false;
            await prepared.close();
            if (mounted) _popPlayerRouteAfterHandoff(Navigator.of(context));
          },
        ),
      );
    } catch (_) {
      _preserveNextEpisodePreparation = false;
      await prepared.close();
      if (mounted) _popPlayerRouteAfterHandoff(Navigator.of(context));
    }
    return true;
  }

  Map<String, String> _episodeResolveQuery(AnimeSummary details, int episode) {
    final mediaId = _catalogAnilistMediaId ?? details.id;
    final malMediaId = _catalogMalMediaId ?? details.idMal;
    final preferredProvider = _animeFeaturesEnabled
        ? _currentRelease.provider?.trim()
        : null;
    final preferredSourceId = _animeFeaturesEnabled
        ? _currentRelease.sourceId.trim()
        : '';
    final preferredAuthor = _animeFeaturesEnabled
        ? releaseGroupKey(_currentRelease.releaseName)
        : null;
    final preferredWebProviderId = _animeFeaturesEnabled
        ? _currentStream.providerId?.trim()
        : null;
    final preferredQualityHeight = _animeFeaturesEnabled
        ? releaseQualityHeight(_currentRelease)
        : 0;
    return {
      'anilistId': mediaId.toString(),
      'title': details.title,
      'synonyms': details.synonyms.join('|'),
      'episode': episode.toString(),
      'autoplay': '1',
      'preferredAudio': _effectiveAudioPreference.name,
      if (preferredProvider != null && preferredProvider.isNotEmpty)
        'preferredProvider': preferredProvider,
      if (preferredSourceId.isNotEmpty) 'preferredSourceId': preferredSourceId,
      if (preferredAuthor != null && preferredAuthor.isNotEmpty)
        'preferredAuthor': preferredAuthor,
      if (preferredWebProviderId != null && preferredWebProviderId.isNotEmpty)
        'preferredWebProviderId': preferredWebProviderId,
      if (preferredQualityHeight > 0)
        'preferredQualityHeight': preferredQualityHeight.toString(),
      if (details.seasonYear != null) 'year': details.seasonYear.toString(),
      if (details.coverImageUrl != null) 'cover': details.coverImageUrl!,
      if (malMediaId != null) 'malId': malMediaId.toString(),
      if (details.titleEnglish != null) 'titleEnglish': details.titleEnglish!,
      if (details.titleRomaji != null) 'titleRomaji': details.titleRomaji!,
      if (details.status != null) 'status': details.status!,
      if (details.format != null) 'format': details.format!,
      if (details.episodes != null) 'episodeCount': details.episodes.toString(),
      if (details.isAdult) 'isAdult': '1',
    };
  }

  Future<bool> _replaceWithResolvedEpisode({
    required AnimeSummary details,
    required int episode,
    required Duration handoffPosition,
  }) async {
    final query = _episodeResolveQuery(details, episode);
    if (!await _prepareForEngineHandoff(handoffPosition)) return false;
    if (!mounted) return false;
    try {
      final navigation = GoRouter.of(context).pushReplacement<void>(
        Uri(path: '/resolve', queryParameters: query).toString(),
      );
      unawaited(
        navigation.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (mounted) _popPlayerRouteAfterHandoff(Navigator.of(context));
          },
        ),
      );
    } catch (_) {
      // Playback is already released. Fall back to the normal player-route
      // pop instead of leaving a hidden, non-interactive screen behind.
      if (mounted) _popPlayerRouteAfterHandoff(Navigator.of(context));
    }
    return true;
  }

  Future<void> _playPreviousEpisode() async {
    if (_blockGuestLocalControl()) return;
    final mediaId = _catalogAnilistMediaId;
    final currentEpisode = _catalogEpisodeNumber;
    if (!mounted ||
        mediaId == null ||
        currentEpisode == null ||
        currentEpisode <= 1) {
      return;
    }
    if (!_episodeHandoff.tryEnter()) return;
    setState(() {});
    try {
      final details = await ref.read(animeDetailsProvider(mediaId).future);
      if (!mounted) return;
      final previousEpisode = currentEpisode - 1;
      if (!isEpisodeAvailableForPlayback(details, previousEpisode)) return;
      await _replaceWithResolvedEpisode(
        details: details,
        episode: previousEpisode,
        // Moving backward is not completion. Preserve the current checkpoint
        // instead of marking this episode watched as Next Episode does.
        handoffPosition: _effectiveHandoffPosition(),
      );
    } catch (_) {
      // Keep the current player active when catalog metadata or navigation is
      // unavailable. A later manual Previous action may retry safely.
    } finally {
      if (!_engineHandoffInProgress) {
        _episodeHandoff.leave();
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _playNextEpisode() async {
    if (_blockGuestLocalControl()) return;
    final mediaId = _catalogAnilistMediaId;
    final currentEpisode = _catalogEpisodeNumber;
    if (!mounted || mediaId == null || currentEpisode == null) {
      return;
    }
    if (!_episodeHandoff.tryEnter()) return;
    setState(() {});
    try {
      final unavailableNoticeController = ref.read(
        fillerUnavailableNotifiedSeriesProvider.notifier,
      );
      if (await _openPreparedNextEpisode(unavailableNoticeController)) return;
      if (!mounted) return;
      final fillerRepository = ref.read(fillerEpisodeRepositoryProvider);
      final skipFillerEpisodes = _seriesPreferences.skipFillerEpisodes;
      final details = await ref.read(animeDetailsProvider(mediaId).future);
      if (!mounted) return;
      final requestedEpisode = currentEpisode + 1;
      if (!isEpisodeAvailableForPlayback(details, requestedEpisode)) {
        return; // No more episodes
      }
      final totalEpisodes = episodeNavigationCeiling(
        requestedEpisode: requestedEpisode,
        declaredTotalEpisodes: details.episodes,
        nextAiringEpisode: details.nextAiringEpisode,
      );
      final decision = await resolveFillerEpisodeNavigation(
        repository: fillerRepository,
        identity: FillerSeriesIdentity.fromAnime(details),
        requestedEpisode: requestedEpisode,
        totalEpisodes: totalEpisodes,
        skipEnabled: skipFillerEpisodes,
      );
      if (!mounted) return;
      final nextEp = decision.episode;
      if (nextEp != null && !isEpisodeAvailableForPlayback(details, nextEp)) {
        return;
      }
      if (decision.dataUnavailable &&
          consumeFillerUnavailableNotice(
            unavailableNoticeController,
            mediaId,
          )) {
        showFillerDataUnavailableNotice(context, episode: requestedEpisode);
      }
      unawaited(showFillerSkipNotification(context, decision));
      if (!mounted || nextEp == null) return;
      if (!mounted) return;
      await _replaceWithResolvedEpisode(
        details: details,
        episode: nextEp,
        handoffPosition: _effectiveHandoffPosition(),
      );
    } catch (_) {
      // Completion remains on the current player when the next episode cannot
      // be prepared. A later manual Next action may retry the handoff.
    } finally {
      if (!_engineHandoffInProgress) {
        _episodeHandoff.leave();
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _syncProgress() async {
    if (!_animeFeaturesEnabled || widget.episode == null) return;
    try {
      final synced = await ref
          .read(trackingSyncServiceProvider)
          .syncEpisode(
            completedEpisodes: widget.episode!,
            anilistMediaId: widget.anilistMediaId,
            malMediaId: widget.malMediaId,
          );
      if (!mounted) return;
      ref.invalidate(
        linkedTrackingProgressProvider((
          anilistMediaId: widget.anilistMediaId,
          malMediaId: widget.malMediaId,
        )),
      );
      if (synced) {
        ref.invalidate(trackingHomeProvider);
      }
    } catch (_) {}
  }

  Future<void> _openCurrentMedia({required bool play}) async {
    final revision = ++_mediaOpenRevision;
    _mediaOpenInProgress = true;
    _preferredAudioSelected = false;
    try {
      await _player.open(Media(_source, httpHeaders: _httpHeaders), play: play);
    } finally {
      if (revision == _mediaOpenRevision) {
        _mediaOpenInProgress = false;
      }
    }
    if (revision != _mediaOpenRevision || !_canApplyTrackSelection) return;
    try {
      // Track events can arrive before Player.open completes. Re-read the
      // settled snapshot here so an early selection cannot be overwritten by
      // MPV finishing the open with the container's default track.
      await _applyPreferredAudio(_player.state.tracks);
    } catch (error, stackTrace) {
      if (_canApplyTrackSelection) {
        debugPrint('MPV startup audio selection failed: $error\n$stackTrace');
      }
    }
  }

  Future<void> _openMedia({
    Duration? resume,
    bool propagateFailure = false,
    bool requireDecodedVideo = false,
  }) => _trackPlayerMutation(() async {
    _mediaOpenVerifications++;
    _completionHandled = false;
    _libraryCompletionThresholdHandled = false;
    _resetCompletionObservation(resume ?? Duration.zero);
    final diagnosticOpenAttempt = ++_diagnosticStreamOpenAttempt;
    final persistenceWasReady = _playbackPersistenceReady;
    if (resume != null) _playbackPersistenceReady = false;
    // Watchdogs from the previous candidate must not inspect or mutate a
    // newly opening source. Verified opens restart fresh watchdogs below.
    _videoWatchdog?.cancel();
    _performanceWatchdog?.cancel();
    if (requireDecodedVideo) {
      // A retry can reuse this screen after the previous media already
      // rendered. Only a frame from this open attempt may satisfy readiness.
      _videoFrameSeen = false;
    }
    try {
      await _configureNativePlayback();
      await _openCurrentMedia(play: true);
      await _applySubtitle();
      if (resume != null) {
        _lastResumeSeekSucceeded = await _restoreResumePosition(resume);
      }
      if (!mounted || _engineHandoffInProgress) return;
      if (requireDecodedVideo) {
        final readinessRevision = _mediaOpenRevision;
        final mediaReady = await waitForPlayerMediaReadiness(
          hasDecodedVideo: () =>
              _videoFrameSeen && _mediaOpenRevision == readinessRevision,
          isActive: () =>
              mounted &&
              !_engineHandoffInProgress &&
              _mediaOpenRevision == readinessRevision,
        );
        if (!mediaReady) {
          // Route disposal and an intentional player handoff are cancellation,
          // not evidence that the candidate itself failed. A competing media
          // revision remains a real rejected attempt and must not be adopted.
          if (!mounted || _engineHandoffInProgress) return;
          throw const PlayerMediaReadinessException();
        }
      }
      _recordDiagnosticStreamOpenResult(
        attempt: diagnosticOpenAttempt,
        succeeded: true,
      );
      _startVideoWatchdog();
      _startPerformanceWatchdog();
    } catch (error, stackTrace) {
      final reasonCode = playbackDiagnosticFailureReasonCode(error);
      _recordDiagnosticStreamOpenResult(
        attempt: diagnosticOpenAttempt,
        succeeded: false,
        reasonCode: reasonCode,
      );
      if (_handleLibraryStartupFailure(error)) return;
      if (propagateFailure) rethrow;
      _recordDiagnosticOutcome(
        PlaybackDiagnosticOutcome.failed,
        reasonCode: reasonCode,
      );
      if (mounted && !_engineHandoffInProgress) {
        unawaited(
          recordAnonymousHandledError(
            area: AnonymousErrorArea.playback,
            error: error,
            stack: stackTrace,
          ),
        );
        setState(() => _playbackError = error.toString());
      }
    } finally {
      if (persistenceWasReady) _playbackPersistenceReady = true;
      _mediaOpenVerifications--;
    }
  });

  Future<void> _trackPlayerMutation(Future<void> Function() action) async {
    if (_engineHandoffInProgress) return;
    final operation = action();
    _playerMutationOperations.add(operation);
    try {
      await operation;
    } finally {
      _playerMutationOperations.remove(operation);
    }
  }

  void _handlePlaybackCompleted() {
    if (_completionHandled || _engineHandoffInProgress) return;
    final duration = _player.state.duration;
    final position = _player.state.position;
    final lastPlayablePosition = _lastPlayablePosition;
    if (_animeFeaturesEnabled &&
        shouldFailOverPrematureNetworkCompletion(
          isNetworkStream: _currentPlaybackUsesNetwork,
          position: position,
          duration: duration,
          lastPlayablePosition: lastPlayablePosition,
          completedAt: DateTime.now(),
          lastCommittedEndSeekAt: _lastCommittedEndSeekAt,
          lastCommittedEndSeekTarget: _lastCommittedEndSeekTarget,
        )) {
      unawaited(
        _tryNextStream(
          'The network stream ended unexpectedly before the episode finished.',
          resumePosition: lastPlayablePosition,
        ),
      );
      return;
    }
    _completionHandled = true;
    _recordDiagnosticOutcome(PlaybackDiagnosticOutcome.completed);
    final libraryPlayback = widget.libraryPlayback;
    if (libraryPlayback != null) {
      libraryPlayback.markCompleted(
        position: _player.state.duration,
        duration: _player.state.duration,
      );
      // Guests wait for the host's media transition. Popping their private
      // player here races the Watch Party route follower at episode end.
      if (_blockGuestLocalControl(notify: false)) return;
      if (_catalogEpisodeFeaturesEnabled &&
          _seriesPreferences.autoplayNextEpisode) {
        unawaited(_completeCatalogLinkedLibraryPlayback());
      } else {
        unawaited(_returnToStreamPicker());
      }
      return;
    }
    if (!_progressHandled &&
        widget.episode != null &&
        (widget.anilistMediaId != null || widget.malMediaId != null)) {
      _progressHandled = true;
      unawaited(_syncProgress());
    }
    unawaited(_offerNextEpisode());
  }

  Future<void> _completeCatalogLinkedLibraryPlayback() async {
    await _playNextEpisode();
    // A failed catalog lookup or a final episode must retain the established
    // library behavior: close back to the unified picker rather than leaving
    // an ended player on screen. A successful handoff owns route teardown.
    if (mounted && !_engineHandoffInProgress) {
      await _returnToStreamPicker();
    }
  }

  Future<bool> _seekForSkip(
    Duration target, {
    bool supersedeInheritedResume = false,
  }) {
    if (_engineHandoffInProgress || _blockGuestLocalControl(notify: false)) {
      return Future<bool>.value(false);
    }
    late final Future<bool> operation;
    operation =
        (() async {
          try {
            if (supersedeInheritedResume) _pendingInheritedResume = null;
            _trickplayGeneration++;
            await _player.seek(target);
            _recordCommittedSeek(target);
            return true;
          } catch (_) {
            return false;
          }
        })().whenComplete(() {
          if (identical(_skipSeekOperation, operation)) {
            _skipSeekOperation = null;
          }
        });
    _skipSeekOperation = operation;
    return operation;
  }

  Future<void> _waitForPlayerMutations() async {
    while (_playerMutationOperations.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_playerMutationOperations));
    }
  }

  Future<bool> _restoreResumePosition(Duration resume) async {
    if (_player.state.duration <= Duration.zero) {
      try {
        await _player.stream.duration
            .firstWhere((duration) => duration > Duration.zero)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Some streams do not expose duration until after their first seek.
      }
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_engineHandoffInProgress) return false;
      try {
        await _player.seek(resume);
      } catch (_) {
        // Network demuxers can reject seeks until their index is available.
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!resumeSeekNeedsRetry(resume, _player.state.position)) {
        _recordCommittedSeek(resume);
        _pendingInheritedResume = null;
        return true;
      }
    }
    return false;
  }

  Duration _effectiveHandoffPosition() {
    return effectivePlayerResumePosition(
      position: _player.state.position,
      pendingResume: _pendingInheritedResume,
    );
  }

  bool get _currentPlaybackUsesNetwork {
    if (_currentStream.isDownloaded) return false;
    final scheme = _currentStream.uri.scheme.toLowerCase();
    return _currentStream.isWebStream ||
        _currentStream.debridService != null ||
        _currentStream.isDirectTorrent ||
        scheme == 'http' ||
        scheme == 'https';
  }

  void _resetCompletionObservation(Duration position) {
    _lastPlayablePosition = position.isNegative ? Duration.zero : position;
    _lastCommittedEndSeekAt = null;
    _lastCommittedEndSeekTarget = null;
  }

  void _recordCommittedSeek(Duration target) {
    final duration = _player.state.duration;
    final safeTarget = target.isNegative ? Duration.zero : target;
    if (duration <= Duration.zero) {
      _lastPlayablePosition = safeTarget;
      _lastCommittedEndSeekAt = null;
      _lastCommittedEndSeekTarget = null;
      return;
    }

    const endTolerance = Duration(seconds: 2);
    final endStart = duration > endTolerance
        ? duration - endTolerance
        : Duration.zero;
    if (safeTarget >= endStart) {
      _lastCommittedEndSeekAt = DateTime.now();
      _lastCommittedEndSeekTarget = safeTarget;
      return;
    }

    _lastPlayablePosition = safeTarget;
    _lastCommittedEndSeekAt = null;
    _lastCommittedEndSeekTarget = null;
  }

  Future<void> _configureNativePlayback() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final properties = <String, String>{
      'hwdec': hwdecForPlaybackMode(_decoderMode),
      'hwdec-software-fallback': '1',
      'vd-lavc-check-hw-profile': 'yes',
      'framedrop': 'vo',
      'demuxer-lavf-probesize': '67108864',
      'demuxer-lavf-analyzeduration': '10',
      'network-timeout': '20',
      'cache': 'yes',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': '2',
      'cache-secs': '45',
      'demuxer-readahead-secs': '20',
      'demuxer-max-bytes': '${48 * 1024 * 1024}',
      'demuxer-max-back-bytes': '${8 * 1024 * 1024}',
      'video-sync': 'audio',
      'interpolation': 'no',
      'deband': 'no',
      'scale': 'bilinear',
      'cscale': 'bilinear',
      'dscale': 'bilinear',
      'sub-pos': '$_subtitlePosition',
      'sub-delay': '${_subtitleDelayMs / 1000}',
      'audio-delay': '${_audioDelayMs / 1000}',
      'sub-border-size': _highContrastSubtitles ? '4' : '2.5',
      'sub-color': _mpvColor(_captionTextColor),
      'sub-back-color': _mpvColor(
        _highContrastSubtitles
            ? const Color(0xDD000000)
            : _captionBackgroundColor,
      ),
    };
    for (final property in properties.entries) {
      try {
        await platform.setProperty(property.key, property.value);
      } catch (_) {
        // libmpv builds vary slightly; unsupported tuning must not block play.
      }
    }
    await _configureNativeAudioPreference(platform);
  }

  Future<void> _configureNativeAudioPreference(NativePlayer platform) async {
    final properties = mpvPreferredAudioStartupProperties(
      _effectiveAudioLanguage,
    );
    for (final property in properties.entries) {
      try {
        await platform.setProperty(property.key, property.value);
      } catch (_) {
        // Language tags are advisory. Title-based late selection below still
        // handles containers whose MPV build rejects an optional property.
      }
    }
  }

  Future<void> _applyPlayerTuning() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final properties = <String, String>{
      'sub-scale': '${_subtitleSize / 34}',
      'sub-pos': '$_subtitlePosition',
      'sub-delay': '${_subtitleDelayMs / 1000}',
      'audio-delay': '${_audioDelayMs / 1000}',
      'sub-border-size': _highContrastSubtitles ? '4' : '2.5',
      'sub-color': _mpvColor(_captionTextColor),
      'sub-back-color': _mpvColor(
        _highContrastSubtitles
            ? const Color(0xDD000000)
            : _captionBackgroundColor,
      ),
    };
    for (final property in properties.entries) {
      try {
        await platform.setProperty(property.key, property.value);
      } catch (_) {
        // Keep playback alive on mpv builds missing an optional property.
      }
    }
  }

  Future<void> _applySubtitle() async {
    final libraryTracks =
        widget.libraryPlayback?.request.externalSubtitleTracks ?? const [];
    if (libraryTracks.isNotEmpty) {
      try {
        final preferred = libraryTracks.first;
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(
            preferred.uri.toString(),
            title: preferred.label,
            language: preferred.language,
          ),
        );
        final platform = _player.platform;
        if (platform is NativePlayer) {
          for (final track in libraryTracks.skip(1)) {
            await platform.command([
              'sub-add',
              track.uri.toString(),
              'auto',
              track.label,
              track.language ?? 'auto',
            ]);
          }
        }
      } catch (_) {
        if (mounted && !_engineHandoffInProgress) {
          _showTrackMessage('External captions could not be loaded');
        }
      }
    }
    final subtitle =
        _currentStream.externalSubtitle?.toString() ?? widget.subtitle;
    if (libraryTracks.isEmpty && subtitle != null && subtitle.isNotEmpty) {
      try {
        if (subtitle.startsWith('asset:///')) {
          final assetKey = subtitle.substring('asset:///'.length);
          final data = await rootBundle.loadString(assetKey);
          await _player.setSubtitleTrack(
            SubtitleTrack.data(data, title: 'Bundled styled subtitles'),
          );
        } else {
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(subtitle, title: 'External subtitles'),
          );
        }
      } catch (_) {
        if (mounted && !_engineHandoffInProgress) {
          _showTrackMessage('External captions could not be loaded');
        }
      }
    }
    if (!_seriesPreferences.subtitleEnabled) {
      // Register a safe external track before disabling display. libmpv keeps
      // it in the selectable track list, so Dub-by-default playback can still
      // turn CC on later instead of incorrectly reporting no captions.
      await _player.setSubtitleTrack(SubtitleTrack.no());
    }
  }

  Future<void> _persistPlayback(Duration position, {bool force = false}) async {
    if (!_playbackPersistenceReady) return;
    final effectivePosition = effectivePlayerResumePosition(
      position: position,
      pendingResume: _pendingInheritedResume,
    );
    if (widget.libraryPlayback != null) {
      _reportLibraryPlayback(position: effectivePosition, force: force);
      return;
    }
    final mediaId = widget.anilistMediaId;
    final episode = widget.episode;
    if (mediaId == null || episode == null) return;
    var now = DateTime.now();
    if (!force &&
        now.difference(_lastCheckpointSave) < const Duration(seconds: 10)) {
      return;
    }
    final duration = effectivePlayerProgressDuration(
      duration: _player.state.duration,
      effectivePosition: effectivePosition,
      pendingResume: _pendingInheritedResume,
    );
    if (duration <= Duration.zero) return;
    if (!now.isAfter(_lastCheckpointSave)) {
      now = _lastCheckpointSave.add(const Duration(milliseconds: 1));
    }
    _lastCheckpointSave = now;
    final completed =
        effectivePosition.inMilliseconds / duration.inMilliseconds >= .93;
    await _database.saveCheckpoint(
      PlaybackCheckpoint(
        anilistMediaId: mediaId,
        malMediaId: widget.malMediaId,
        episode: episode,
        title: widget.launch.episode.title,
        coverImageUrl: widget.coverImageUrl,
        position: completed ? duration : effectivePosition,
        duration: duration,
        updatedAt: now,
        completed: completed,
      ),
    );
    if ((force || completed) && mounted) {
      ref.invalidate(recentPlaybackProvider);
      ref.invalidate(latestPlaybackProvider(mediaId));
    }
    if (!completed && effectivePosition > const Duration(seconds: 30)) {
      await AndroidTvBridge.instance.publishWatchNext(
        mediaId: mediaId,
        episode: episode,
        title: widget.launch.episode.title,
        posterUrl: widget.coverImageUrl,
        position: effectivePosition,
        duration: duration,
      );
    } else if (completed) {
      await AndroidTvBridge.instance.removeWatchNext(mediaId);
    }
  }

  Future<void> _updateMediaSession({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastMediaSessionUpdate) < const Duration(seconds: 5)) {
      return;
    }
    _lastMediaSessionUpdate = now;
    await AndroidTvBridge.instance.updateMediaSession(
      title: widget.launch.episode.title,
      episode: _catalogEpisodeNumber ?? 1,
      position: _player.state.position,
      duration: _player.state.duration,
      playing: _player.state.playing,
      artworkUrl: widget.coverImageUrl,
      seekBackSeconds: _seekBackSeconds,
      seekForwardSeconds: _seekForwardSeconds,
      playbackRate: _playbackRate,
    );
  }

  void _handleMediaAction(MediaAction action) {
    if (_engineHandoffInProgress) return;
    if (_blockGuestLocalControl()) return;
    switch (action.action) {
      case 'play':
        unawaited(_player.play());
      case 'pause':
        unawaited(_player.pause());
      case 'seekTo':
        unawaited(_seekTo(Duration(milliseconds: action.value ?? 0)));
      case 'seekBy':
        unawaited(_seekBy(Duration(milliseconds: action.value ?? 0)));
      case 'next':
        unawaited(_playNextEpisode());
      case 'previous':
        unawaited(_seekBy(-_player.state.position));
    }
  }

  Future<void> _matchContentFrameRate() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    for (final property in const ['container-fps', 'estimated-vf-fps']) {
      try {
        final value = await platform.getProperty(property);
        final fps = double.tryParse(value);
        if (fps != null && fps >= 20 && fps <= 120) {
          await AndroidTvBridge.instance.setPreferredFrameRate(fps);
          return;
        }
      } catch (_) {
        // Try the next libmpv property.
      }
    }
  }

  Future<StreamReady?> _resolveRelease(
    ReleaseCandidate release,
    EpisodeReference episode, {
    DebridTokenService? tokenService,
  }) async {
    if (!mounted || _engineHandoffInProgress) return null;
    final DebridTokenService capturedTokenService =
        tokenService ?? ref.read(debridTokenServiceProvider);
    String? token;
    try {
      token = await capturedTokenService.accessToken(widget.debridService);
    } catch (_) {
      throw DebridProviderAccessException(
        widget.debridService,
        detail:
            'Your ${widget.debridService.displayName} connection could not be '
            'refreshed. Reconnect it in Accounts, then try again.',
      );
    }
    if (!mounted || _engineHandoffInProgress) return null;
    if (token == null || token.isEmpty) {
      throw DebridProviderAccessException(widget.debridService);
    }
    final source = SingleReleaseSource(release);
    final resolver = createDebridStreamResolver(
      service: widget.debridService,
      token: token,
      source: source,
    );
    await for (final resolution in resolver.resolve(episode)) {
      if (!mounted || _engineHandoffInProgress) {
        if (resolution case final StreamReady ready) {
          await ready.playbackLease?.close();
        }
        return null;
      }
      if (resolution is StreamReady) {
        try {
          verifyPlaybackEpisodeIdentity(
            episode: episode,
            stream: resolution,
            release: release,
          );
        } on EpisodeIdentityMismatchException {
          await resolution.playbackLease?.close();
          rethrow;
        }
        if (!mounted || _engineHandoffInProgress) {
          await resolution.playbackLease?.close();
          return null;
        }
        return resolution;
      }
    }
    return null;
  }

  Future<void> _tryNextStream(
    String reason, {
    bool notify = true,
    Duration? resumePosition,
  }) async {
    if (!mounted || _engineHandoffInProgress || _failingOver) return;
    // Private-library recovery is owned by the typed library route. Falling
    // through to anime provider discovery here could mix a private Plex,
    // Jellyfin, or device-file session with an unrelated catalog episode.
    if (widget.libraryPlayback != null) return;
    final failoverReasonCode = playbackDiagnosticFailureReasonCode(reason);
    unawaited(
      _playbackDiagnostics.fallbackAttempted(
        fallbackKind: PlaybackDiagnosticFallbackKind.source,
        sourceKind: _diagnosticSourceKind,
        decoder: _diagnosticDecoder,
        codec: _player.state.track.video.codec,
        reasonCode: failoverReasonCode,
        attempt: ++_diagnosticFallbackAttempt,
      ),
    );
    _failingOver = true;
    final position = resumePosition ?? _effectiveHandoffPosition();
    final tokenService = ref.read(debridTokenServiceProvider);
    Object? terminalFailure;
    try {
      final classOrder = playerFailoverClassOrder(
        currentIsWeb: _currentStream.isWebStream,
      );
      final profile = await AndroidTvBridge.instance.getDeviceProfile();
      if (!mounted || _engineHandoffInProgress) return;
      await _database.recordStreamFailure(
        deviceKey: profile.key,
        infoHash: _currentRelease.infoHash,
        reason: reason,
      );
      if (!mounted || _engineHandoffInProgress) return;
      Future<bool> tryReleaseCandidates(
        Iterable<ReleaseCandidate> candidates,
      ) async {
        for (final candidate in candidates.take(12)) {
          _attemptedReleaseAlternatives.add(candidate);
          final previousSource = _source;
          final previousRelease = _currentRelease;
          final previousStream = _currentStream;
          final previousPreferences = _seriesPreferences;
          final previousAudioSelected = _preferredAudioSelected;
          final previousSubtitleSelected = _preferredSubtitleSelected;
          final previousSoftwareFallbackUsed = _softwareFallbackUsed;
          final previousDecoderMode = _decoderMode;
          final previousVideoFrameSeen = _videoFrameSeen;
          StreamReady? resolvedStream;
          try {
            final ready = await _resolveRelease(
              candidate,
              widget.launch.episode,
              tokenService: tokenService,
            );
            resolvedStream = ready;
            if (!mounted || _engineHandoffInProgress) {
              await resolvedStream?.playbackLease?.close();
              return false;
            }
            if (ready == null) continue;
            _source = ready.uri.toString();
            _currentRelease = candidate;
            _currentStream = ready;
            _applyAutomaticSubtitleDefaultForRelease(candidate);
            _preferredAudioSelected = false;
            _preferredSubtitleSelected = false;
            _softwareFallbackUsed = false;
            _decoderMode = releaseRequiresSoftwareDecoder(candidate)
                ? PlaybackDecoderMode.software
                : PlaybackDecoderMode.hardwareSafe;
            _softwareFallbackUsed =
                _decoderMode == PlaybackDecoderMode.software;
            _videoFrameSeen = false;
            _recordDiagnosticSourceSelected(automatic: true);
            _recordDiagnosticDecoderSelected(
              automatic: true,
              reasonCode: 'source_fallback',
            );
            await _openMedia(
              resume: position,
              propagateFailure: true,
              requireDecodedVideo: true,
            );
            if (!mounted || _engineHandoffInProgress) {
              await ready.playbackLease?.close();
              return false;
            }
            await widget.onStreamAdopted(ready, candidate);
            _invalidateNextEpisodePreparation();
            _resetSkipSegmentsForSourceChange();
            setState(() => _playbackError = null);
            if (notify) {
              _showAutomaticFailoverNotice(reason, ready, candidate);
            }
            return true;
          } catch (error) {
            // Resolution may fail before `_currentStream` points at the new
            // candidate. Close only the lease created by this attempt; the
            // previous playing stream still owns its lease until adoption.
            await resolvedStream?.playbackLease?.close();
            if (!mounted || _engineHandoffInProgress) return false;
            _source = previousSource;
            _currentRelease = previousRelease;
            _currentStream = previousStream;
            _seriesPreferences = previousPreferences;
            _preferredAudioSelected = previousAudioSelected;
            _preferredSubtitleSelected = previousSubtitleSelected;
            _softwareFallbackUsed = previousSoftwareFallbackUsed;
            _decoderMode = previousDecoderMode;
            _videoFrameSeen = previousVideoFrameSeen;
            if (isTerminalDebridFailoverFailure(error)) {
              terminalFailure = error;
              return false;
            }
            // Continue only through candidate-specific/cache-miss failures.
          }
        }
        return false;
      }

      final currentQualityHeight = releaseQualityHeight(_currentRelease);
      await _waitForInFlightDirectDiscovery();
      if (!mounted || _engineHandoffInProgress) return;
      final allDirectCandidates = _remainingDirectFailoverCandidates();
      final allReleaseCandidates = _remainingReleaseFailoverCandidates();
      final audioRankTiers = playerFailoverAudioRankTiers([
        for (final option in allDirectCandidates)
          releaseAudioPreferenceRank(option.release, _effectiveAudioPreference),
        for (final candidate in allReleaseCandidates)
          releaseAudioPreferenceRank(candidate, _effectiveAudioPreference),
      ]);
      for (final audioRank in audioRankTiers) {
        for (final sameQuality in playerFailoverSameQualityTiers(
          currentQualityHeight: currentQualityHeight,
        )) {
          final directCandidates = allDirectCandidates.where(
            (option) =>
                releaseAudioPreferenceRank(
                      option.release,
                      _effectiveAudioPreference,
                    ) ==
                    audioRank &&
                playerFailoverCandidateIsInQualityTier(
                  candidateQualityHeight: releaseQualityHeight(option.release),
                  currentQualityHeight: currentQualityHeight,
                  sameQuality: sameQuality,
                ),
          );
          final releaseCandidates = allReleaseCandidates.where(
            (candidate) =>
                releaseAudioPreferenceRank(
                      candidate,
                      _effectiveAudioPreference,
                    ) ==
                    audioRank &&
                playerFailoverCandidateIsInQualityTier(
                  candidateQualityHeight: releaseQualityHeight(candidate),
                  currentQualityHeight: currentQualityHeight,
                  sameQuality: sameQuality,
                ),
          );
          for (final streamClass in classOrder) {
            final opened = switch (streamClass) {
              PlayerFailoverClass.directWeb => await _switchToNextDirectStream(
                position,
                candidates: directCandidates,
                failoverReason: reason,
                notify: notify,
              ),
              PlayerFailoverClass.debrid =>
                playerFailoverClassIsAvailable(
                      streamClass,
                      debridAvailable: terminalFailure == null,
                    )
                    ? await tryReleaseCandidates(releaseCandidates)
                    : false,
            };
            if (opened) return;
            if (!mounted || _engineHandoffInProgress) return;
          }
        }
      }
      if (mounted && !_engineHandoffInProgress) {
        final message =
            terminalFailure?.toString() ??
            'Every compatible stream failed. $reason';
        if (_currentStream.providerId case final providerId?) {
          await _database.recordProviderFailure(providerId, message);
        } else {
          final device = await AndroidTvBridge.instance.getDeviceProfile();
          await _database.recordPlayerFailure(device.key, 'mpv');
        }
        await _database.recordDiagnosticEvent(
          category: 'player-mpv',
          message: message,
        );
        _recordDiagnosticOutcome(
          PlaybackDiagnosticOutcome.failed,
          reasonCode: terminalFailure == null
              ? 'all_fallbacks_failed'
              : playbackDiagnosticFailureReasonCode(terminalFailure),
        );
        if (mounted) setState(() => _playbackError = message);
      }
    } finally {
      _failingOver = false;
    }
  }

  Future<bool> _switchToNextDirectStream(
    Duration position, {
    Iterable<PlaybackStreamOption>? candidates,
    Object? failoverReason,
    bool notify = true,
  }) async {
    if (!mounted || _engineHandoffInProgress) {
      return false;
    }
    if (_currentStream.isWebStream) {
      _failedDirectStreamKeys.add(
        playbackStreamReadyAttemptKey(
          _currentStream,
          fallbackProviderId: _currentRelease.sourceId,
        ),
      );
    }
    final opened = await openFirstViablePlayerCandidate(
      candidates: candidates ?? _remainingDirectFailoverCandidates(),
      resumePosition: position,
      isActive: () => mounted && !_engineHandoffInProgress,
      attempt: (candidate, resumePosition) async {
        _failedDirectStreamKeys.add(playbackStreamOptionAttemptKey(candidate));
        final previousSource = _source;
        final previousRelease = _currentRelease;
        final previousStream = _currentStream;
        final previousPreferences = _seriesPreferences;
        final previousAudioSelected = _preferredAudioSelected;
        final previousSubtitleSelected = _preferredSubtitleSelected;
        final previousSoftwareFallbackUsed = _softwareFallbackUsed;
        final previousDecoderMode = _decoderMode;
        final previousVideoFrameSeen = _videoFrameSeen;
        PlaybackStreamOption? preparedOption;
        try {
          final option = await _preflightDirectStream(candidate, silent: true);
          preparedOption = option;
          if (!mounted || _engineHandoffInProgress) {
            await option?.stream.playbackLease?.close();
            return false;
          }
          if (option == null) return false;
          if (validatedRedirectWasAlreadyAttempted(
            requested: candidate,
            validated: option,
            attemptedStreamKeys: _failedDirectStreamKeys,
          )) {
            await option.stream.playbackLease?.close();
            return false;
          }
          _failedDirectStreamKeys.add(playbackStreamOptionAttemptKey(option));
          _currentStream = option.stream;
          _currentRelease = option.release;
          _source = option.stream.uri.toString();
          _applyAutomaticSubtitleDefaultForRelease(option.release);
          _preferredAudioSelected = false;
          _preferredSubtitleSelected = false;
          _softwareFallbackUsed = false;
          _decoderMode = releaseRequiresSoftwareDecoder(option.release)
              ? PlaybackDecoderMode.software
              : PlaybackDecoderMode.hardwareSafe;
          _softwareFallbackUsed = _decoderMode == PlaybackDecoderMode.software;
          _videoFrameSeen = false;
          _recordDiagnosticSourceSelected(automatic: true);
          _recordDiagnosticDecoderSelected(
            automatic: true,
            reasonCode: 'source_fallback',
          );
          await _openMedia(
            resume: resumePosition,
            propagateFailure: true,
            requireDecodedVideo: true,
          );
          if (!mounted || _engineHandoffInProgress) {
            await option.stream.playbackLease?.close();
            return false;
          }
          await widget.onStreamAdopted(option.stream, option.release);
          _invalidateNextEpisodePreparation();
          _resetSkipSegmentsForSourceChange();
          preparedOption = null;
          setState(() => _playbackError = null);
          if (notify) {
            _showAutomaticFailoverNotice(
              failoverReason,
              option.stream,
              option.release,
            );
          }
          return true;
        } catch (_) {
          await preparedOption?.stream.playbackLease?.close();
          if (!mounted || _engineHandoffInProgress) rethrow;
          _source = previousSource;
          _currentRelease = previousRelease;
          _currentStream = previousStream;
          _seriesPreferences = previousPreferences;
          _preferredAudioSelected = previousAudioSelected;
          _preferredSubtitleSelected = previousSubtitleSelected;
          _softwareFallbackUsed = previousSoftwareFallbackUsed;
          _decoderMode = previousDecoderMode;
          _videoFrameSeen = previousVideoFrameSeen;
          rethrow;
        }
      },
    );
    return opened != null;
  }

  Future<void> _waitForInFlightDirectDiscovery() async {
    if (_remainingDirectFailoverCandidates().isNotEmpty) {
      return;
    }
    await _startWebSourceDiscovery();
    if (!mounted || _engineHandoffInProgress) return;
    await waitForPlayerFailoverCandidates(
      snapshot: _remainingDirectFailoverCandidates,
      isActive: () => mounted && !_engineHandoffInProgress,
    );
  }

  List<ReleaseCandidate> _remainingReleaseFailoverCandidates() {
    final candidates = widget.launch.alternatives
        .where(
          (candidate) =>
              !_attemptedReleaseAlternatives.contains(candidate) &&
              !assessEpisodeIdentityLabel(
                label: candidate.releaseName,
                requestedEpisode: widget.launch.episode.episode,
                requestedSeason: catalogSeasonNumber(widget.launch.episode),
              ).isMismatch,
        )
        .toList();
    return rankAutomaticPlayerFailoverCandidates(
      candidates: candidates,
      audioRank: (candidate) =>
          releaseAudioPreferenceRank(candidate, _effectiveAudioPreference),
      qualityRank: (candidate) => automaticQualityAffinityRank(
        releaseQualityHeight(candidate),
        releaseQualityHeight(_currentRelease),
      ),
      affinityRank: _releaseFailoverAffinity,
    );
  }

  List<PlaybackStreamOption> _remainingDirectFailoverCandidates() {
    final candidates = _directStreamOptions
        .where(
          (option) =>
              option.stream.isWebStream &&
              !_failedDirectStreamKeys.contains(
                playbackStreamOptionAttemptKey(option),
              ),
        )
        .toList();
    final currentProvider = _currentStream.providerId?.trim().toLowerCase();
    int affinityRank(PlaybackStreamOption option) {
      final provider = option.stream.providerId?.trim().toLowerCase();
      final providerRank =
          provider != null && provider.isNotEmpty && provider == currentProvider
          ? 0
          : 1;
      return (providerRank * 4) + _releaseFailoverAffinity(option.release);
    }

    return rankAutomaticPlayerFailoverCandidates(
      candidates: candidates,
      audioRank: (option) =>
          releaseAudioPreferenceRank(option.release, _effectiveAudioPreference),
      qualityRank: (option) => automaticQualityAffinityRank(
        releaseQualityHeight(option.release),
        releaseQualityHeight(_currentRelease),
      ),
      affinityRank: affinityRank,
    );
  }

  int _releaseFailoverAffinity(ReleaseCandidate candidate) {
    final currentProvider = _currentRelease.provider?.trim().toLowerCase();
    final candidateProvider = candidate.provider?.trim().toLowerCase();
    final sameProvider =
        currentProvider != null &&
        currentProvider.isNotEmpty &&
        candidateProvider == currentProvider;
    final sameSource =
        _currentRelease.sourceId.trim().toLowerCase() ==
        candidate.sourceId.trim().toLowerCase();
    final currentAuthor = releaseGroupKey(_currentRelease.releaseName);
    final sameAuthor =
        currentAuthor != null &&
        releaseGroupKey(candidate.releaseName) == currentAuthor;
    if ((sameProvider || sameSource) && sameAuthor) return 0;
    if (sameProvider || sameSource) return 1;
    if (sameAuthor) return 2;
    return 3;
  }

  Future<void> _retryCurrentStream() async {
    final position = _effectiveHandoffPosition();
    if (mounted) setState(() => _playbackError = null);
    unawaited(
      _playbackDiagnostics.fallbackAttempted(
        fallbackKind: PlaybackDiagnosticFallbackKind.retry,
        sourceKind: _diagnosticSourceKind,
        decoder: _diagnosticDecoder,
        codec: _player.state.track.video.codec,
        reasonCode: 'user_retry',
        attempt: ++_diagnosticFallbackAttempt,
      ),
    );
    try {
      await _openMedia(
        resume: position,
        propagateFailure: true,
        requireDecodedVideo: _animeFeaturesEnabled,
      );
      _showTrackMessage('Stream restarted');
    } catch (error) {
      if (mounted) setState(() => _playbackError = error.toString());
    }
  }

  Future<void> _returnToStreamPicker() async {
    final navigator = Navigator.of(context);
    final position = _effectiveHandoffPosition();
    _pendingHandoffPosition = position;
    if (!await _prepareForEngineHandoff(position)) return;
    _popPlayerRouteAfterHandoff(navigator);
  }

  bool _handleLibraryStartupFailure(
    Object error, {
    bool allowAfterStartup = false,
  }) {
    final session = widget.libraryPlayback;
    if (session == null) return false;
    if (_libraryStartupFailureExitScheduled) return true;
    final failure = classifyLibraryPlaybackStartupFailure(error);
    if (failure == null) return false;

    // A decoder error immediately after a saved-position seek is still a
    // startup failure. Compare against the request's resume point rather than
    // absolute media time so a resumed episode can use the server fallback.
    final startupBoundary =
        session.request.initialPosition + const Duration(seconds: 10);
    if (!allowAfterStartup &&
        _reportedPlaybackSuccess &&
        _player.state.position > startupBoundary) {
      return false;
    }

    _libraryStartupFailureExitScheduled = true;
    session.markFailed(failure);
    final diagnosticReasonCode = playbackDiagnosticFailureReasonCode(error);
    unawaited(
      _playbackDiagnostics.fallbackAttempted(
        fallbackKind: PlaybackDiagnosticFallbackKind.libraryCompatibility,
        sourceKind: _diagnosticSourceKind,
        decoder: _diagnosticDecoder,
        codec: _player.state.track.video.codec,
        reasonCode: diagnosticReasonCode,
        attempt: ++_diagnosticFallbackAttempt,
      ),
    );
    _recordDiagnosticOutcome(
      PlaybackDiagnosticOutcome.failed,
      reasonCode: diagnosticReasonCode,
    );
    unawaited(
      _database.recordDiagnosticEvent(
        category: 'player-mpv',
        severity: 'error',
        message: 'Private library playback could not start',
        details: {'failureKind': failure.diagnosticCode},
      ),
    );
    unawaited(_returnToStreamPicker());
    return true;
  }

  void _showLibraryRuntimeError() {
    if (!mounted || _engineHandoffInProgress) return;
    _recordDiagnosticOutcome(
      PlaybackDiagnosticOutcome.failed,
      reasonCode: 'library_runtime',
    );
    unawaited(
      _database.recordDiagnosticEvent(
        category: 'player-mpv',
        severity: 'error',
        message: 'Private library playback stopped after startup',
        details: const {'failureKind': 'runtime'},
      ),
    );
    setState(() {
      _playbackError =
          'Your private media stream stopped unexpectedly. '
          'Retry it or choose another source.';
    });
  }

  void _popPlayerRouteAfterHandoff(NavigatorState navigator) {
    if (!mounted || _routePopScheduled) return;
    _routePopScheduled = true;
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted) unawaited(navigator.maybePop());
    });
  }

  Future<void> _recordEngineSuccess() async {
    if (_currentStream.providerId case final providerId?) {
      await _database.recordProviderSuccess(providerId);
      return;
    }
    final device = await AndroidTvBridge.instance.getDeviceProfile();
    await _database.recordPlayerSuccess(device.key, 'mpv');
  }

  Future<void> _detachAndroidVideoOutputBeforeRelease() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      final platformController = await _controller.platform.future;
      if (platformController is! AndroidVideoController) return;

      // SurfaceProducer sends an asynchronous wid=0 update when Flutter
      // unmounts the Texture. AndroidVideoController's listener seeks after
      // applying that update, so allowing it to run after Player.dispose()
      // produces "[Player] has been disposed". Stop future producers first,
      // detach while the Player is alive, then use the controller's own lock
      // as the completion barrier for every listener already in flight.
      platformController.wid.removeListener(platformController.widListener);
      await platformController.videoParamsSubscription?.cancel();
      platformController.videoParamsSubscription = null;
      platformController.wid.value = 0;
      await platformController.widListener();
    } catch (_) {
      // Decoder release remains authoritative if an already-broken video
      // output cannot finish its best-effort surface detach.
    }
  }

  Future<bool> _prepareForEngineHandoff(Duration position) async {
    if (_handoffAttemptActive) return false;
    _handoffAttemptActive = true;
    _handoffReleaseFailed = false;
    _pendingHandoffPosition ??= position;
    _engineHandoffInProgress = true;
    _hiddenHudDpadSeek.cancel();
    _controlsTimer?.cancel();
    _videoWatchdog?.cancel();
    _performanceWatchdog?.cancel();
    _seekPreviewTimer?.cancel();
    _trickplayGeneration++;
    if (mounted) setState(() => _controlsVisible = false);

    try {
      // Remove the texture from the widget tree before stopping libmpv.
      // Starting another native engine while mpv still owns its Surface/audio
      // session can terminate the process on resource-constrained TV firmware.
      await WidgetsBinding.instance.endOfFrame;
      await _waitForPlayerMutations().timeout(_playerMutationReleaseTimeout);
      _videoWatchdog?.cancel();
      _performanceWatchdog?.cancel();
      _queuedSeekTarget = null;
      _queuedSeekCapturePreview = false;
      _queuedSeekGeneration = 0;
      await _waitForSeekDrain();
      final skipSeek = _skipSeekOperation;
      if (skipSeek != null) await skipSeek;
      final trickplayOperations = List<Future<void>>.of(_trickplayOperations);
      if (trickplayOperations.isNotEmpty) {
        await Future.wait(trickplayOperations);
      }
    } catch (_) {
      // A failed in-flight command has already completed. Continue to the
      // authoritative native release instead of leaving a broken decoder up.
    }
    try {
      await _persistPlayback(position, force: true);
    } catch (_) {
      // A failed checkpoint must not strand the user in the old engine.
    }
    try {
      await _saveSeriesPreferences();
    } catch (_) {
      // Preferences are best effort; decoder ownership still has to end.
    }
    try {
      await _progressSubscription?.cancel();
      await _durationSubscription?.cancel();
      await _tracksSubscription?.cancel();
      await _errorSubscription?.cancel();
      await _completedSubscription?.cancel();
      await _videoParamsSubscription?.cancel();
      await _playingSubscription?.cancel();
      await _mediaActionSubscription?.cancel();
      await _sourceDiscoverySubscription?.cancel();
    } catch (_) {
      // Stream callbacks guard on _engineHandoffInProgress. Native release is
      // still the authoritative safety boundary if a Dart cancellation fails.
    }
    final released = await _handoffRelease.release(() async {
      try {
        await _player.stop();
      } catch (_) {
        // dispose() is authoritative and may still release a backend whose
        // explicit stop command failed during a decoder error.
      }
      await _detachAndroidVideoOutputBeforeRelease();
      await _player.dispose();
      _playerReleasedForHandoff = true;
    });
    if (!released) {
      _handoffAttemptActive = false;
      _handoffReleaseFailed = true;
      if (mounted) {
        setState(() {
          _trackMessage =
              'Could not release the player safely. Press Exit to retry.';
        });
      }
      return false;
    }
    try {
      await AndroidTvBridge.instance.clearMediaSession();
      await AndroidTvBridge.instance.clearPreferredFrameRate();
    } catch (_) {
      // The decoder is already released; platform-session cleanup is best
      // effort and must not reopen the old engine.
    }
    _nativePlaybackStateClearedForHandoff = true;
    _handoffAttemptActive = false;
    return mounted;
  }

  void _showAutomaticFailoverNotice(
    Object? reason,
    StreamReady stream,
    ReleaseCandidate release,
  ) {
    showPlayerFailoverNotice(
      context,
      gate: _failoverNoticeGate,
      destination: playerFailoverDestination(
        isWebStream: stream.isWebStream,
        providerName: stream.providerName ?? release.provider,
        quality: release.quality,
      ),
      reason: reason,
    );
  }

  NextEpisodePreparationRequest _nextEpisodePreparationRequest() {
    if (widget.libraryPlayback != null) {
      return NextEpisodePreparationRequest.catalogLinkedLibrary(
        episode: widget.launch.episode,
        seriesPreferences: _seriesPreferences,
        debridService: widget.debridService,
        requestedAudio: widget.libraryPlayback!.request.requestedAudio,
        preferredOrigin:
            switch (widget.libraryPlayback!.request.sourceProviderId) {
              'library-device' => LibraryEpisodeOrigin.device,
              'library-jellyfin' => LibraryEpisodeOrigin.jellyfin,
              'library-plex' => LibraryEpisodeOrigin.plex,
              _ => null,
            },
      );
    }
    return NextEpisodePreparationRequest(
      currentLaunch: PlaybackLaunch(
        stream: _currentStream,
        episode: widget.launch.episode,
        selectedRelease: _currentRelease,
        requestedAudio: _requestedAudio,
        alternatives: widget.launch.alternatives,
        directAlternatives: _directStreamOptions,
      ),
      seriesPreferences: _seriesPreferences,
      debridService: widget.debridService,
    );
  }

  void _maybePrewarmNextEpisode({
    required Duration position,
    required Duration duration,
  }) {
    if (!mounted ||
        !_catalogEpisodeFeaturesEnabled ||
        _guestControlsLocked ||
        _engineHandoffInProgress ||
        _currentStream.isDirectTorrent ||
        _catalogEpisodeNumber == null ||
        !shouldPrepareNextEpisode(position: position, duration: duration)) {
      return;
    }
    if (_prewarmed) {
      if (_nextEpisodePreparation.hasReady(_nextEpisodePreparationRequest())) {
        return;
      }
      _prewarmed = false;
      _prewarmRetry.resetGeneration();
    }
    if (_prewarming || !_prewarmRetry.canAttempt(DateTime.now())) return;
    unawaited(_prewarmNextEpisode());
  }

  void _invalidateNextEpisodePreparation() {
    _prewarmRetry.resetGeneration();
    _prewarming = false;
    _prewarmed = false;
    _maybePrewarmNextEpisode(
      position: _player.state.position,
      duration: _player.state.duration,
    );
  }

  Future<void> _prewarmNextEpisode() async {
    if (!mounted ||
        !_catalogEpisodeFeaturesEnabled ||
        _guestControlsLocked ||
        _engineHandoffInProgress ||
        _prewarming ||
        _prewarmed ||
        _catalogEpisodeNumber == null) {
      return;
    }
    final generation = _prewarmRetry.generation;
    _prewarming = true;
    final preparation = ref.read(nextEpisodePreparationControllerProvider);
    try {
      final outcome = await preparation.warmWithOutcome(
        _nextEpisodePreparationRequest(),
      );
      final prepared = outcome.prepared;
      if (!mounted ||
          _engineHandoffInProgress ||
          !_prewarmRetry.isCurrent(generation)) {
        return;
      }
      _prewarmed = prepared != null;
      if (prepared == null) {
        if (outcome.isTerminal) {
          _prewarmRetry.recordTerminal(generation);
        } else {
          _prewarmRetry.recordFailure(generation, DateTime.now());
        }
      } else {
        _prewarmRetry.recordSuccess(generation);
      }
    } catch (_) {
      // Prewarming is intentionally invisible and never blocks playback.
      if (mounted && _prewarmRetry.isCurrent(generation)) {
        _prewarmRetry.recordFailure(generation, DateTime.now());
      }
    } finally {
      if (mounted && _prewarmRetry.isCurrent(generation)) {
        _prewarming = false;
      }
    }
  }

  Future<void> _saveSeriesPreferences() async {
    final mediaId = _catalogAnilistMediaId;
    if (mediaId == null || !_seriesPreferencesReady) return;
    final audio = _player.state.track.audio;
    final subtitle = _player.state.track.subtitle;
    // Some dual-audio containers label a stream (for example, "English
    // Dub") without setting its ISO language field. Persist the normalized
    // title in that case so the next episode does not silently fall back to
    // the previous Japanese preference.
    final audioLanguage = persistedPlayerAudioLanguage(
      storedLanguage: _seriesPreferences.audioLanguage,
      audioPreferenceSet: _seriesPreferences.audioPreferenceSet,
      observedLanguage: audio.language,
      observedTitle: audio.title,
    );
    final subtitleLanguage = canonicalPlayerLanguage(
      subtitle.language ?? subtitle.title,
    );
    _seriesPreferences = _seriesPreferences.copyWith(
      audioLanguage: audioLanguage,
      subtitleLanguage: subtitleLanguage.isEmpty
          ? _seriesPreferences.subtitleLanguage
          : subtitleLanguage,
      subtitleEnabled: subtitle.id != 'no',
      subtitlePreferenceSet: true,
      subtitleSize: _subtitleSize,
      subtitlePosition: _subtitlePosition,
      subtitleDelayMs: _subtitleDelayMs,
      audioDelayMs: _audioDelayMs,
      decoder: switch (_decoderMode) {
        PlaybackDecoderMode.hardwareDirect => 'hardware-direct',
        PlaybackDecoderMode.software => 'software',
        _ => 'hardware-safe',
      },
      videoFit: switch (_videoFit) {
        BoxFit.cover => 'cover',
        BoxFit.fill => 'fill',
        _ => 'contain',
      },
      highContrastSubtitles: _highContrastSubtitles,
    );
    if (_animeFeaturesEnabled) {
      final releaseGroup = releaseGroupKey(_currentRelease.releaseName);
      _seriesPreferences = _seriesPreferences.copyWith(
        preferredReleaseProvider: _currentRelease.provider,
        clearPreferredReleaseProvider: _currentRelease.provider == null,
        preferredReleaseGroup: releaseGroup,
        clearPreferredReleaseGroup: releaseGroup == null,
      );
    }
    await _database.saveSeriesPreferences(mediaId, _seriesPreferences);
  }

  Future<void> _saveDecoderPreference() async {
    final mediaId = _catalogAnilistMediaId;
    if (mediaId == null) return;
    _seriesPreferences = _seriesPreferences.copyWith(
      decoder: switch (_decoderMode) {
        PlaybackDecoderMode.hardwareDirect => 'hardware-direct',
        PlaybackDecoderMode.software => 'software',
        _ => 'hardware-safe',
      },
    );
    await _database.saveSeriesPreferences(mediaId, _seriesPreferences);
  }

  Future<void> _offerNextEpisode() async {
    if (_blockGuestLocalControl(notify: false)) return;
    if (!_catalogEpisodeFeaturesEnabled) return;
    if (!mounted ||
        _catalogEpisodeNumber == null ||
        _catalogAnilistMediaId == null) {
      return;
    }
    try {
      await _persistPlayback(_player.state.duration, force: true);
    } catch (_) {
      // Completion still needs to remain usable when checkpoint storage or the
      // platform watch-next provider is temporarily unavailable.
    }
    if (!mounted || _engineHandoffInProgress) return;
    if (!_seriesPreferences.autoplayNextEpisode) return;
    await _playNextEpisode();
  }

  void _startVideoWatchdog() {
    _videoWatchdog?.cancel();
    _watchdogAttempts = 0;
    _scheduleVideoWatchdogCheck();
  }

  void _scheduleVideoWatchdogCheck() {
    _videoWatchdog = Timer(const Duration(seconds: 8), () {
      if (!mounted || _videoFrameSeen || _changingDecoder) {
        return;
      }
      _watchdogAttempts++;
      if ((_player.state.buffering ||
              _player.state.position < const Duration(seconds: 2)) &&
          _watchdogAttempts < 4) {
        _scheduleVideoWatchdogCheck();
        return;
      }
      if (_hasUntriedDirectStream || _softwareFallbackUsed) {
        if (_handleLibraryStartupFailure(
          'No video frames were rendered.',
          allowAfterStartup: true,
        )) {
          return;
        }
        unawaited(_tryNextStream('No video frames were rendered.'));
      } else {
        unawaited(
          _restartWithSoftwareDecoder('No video frames were rendered.'),
        );
      }
    });
  }

  Future<void> _restartWithSoftwareDecoder(Object reason) => _switchDecoder(
    PlaybackDecoderMode.software,
    automatic: true,
    reason: reason.toString(),
  );

  void _startPerformanceWatchdog() {
    _performanceWatchdog?.cancel();
    _lastDroppedFrames = 0;
    _highDropSamples = 0;
    _performanceWatchdog = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_checkPlaybackPerformance()),
    );
  }

  Future<String?> _optionalNativeProperty(
    NativePlayer platform,
    String name,
  ) async {
    try {
      final value = await platform.getProperty(name);
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> _inspectDecodedVideo(VideoParams params) async {
    if (_checkingDecodedVideo ||
        _changingDecoder ||
        _decoderMode == PlaybackDecoderMode.software) {
      return;
    }
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    _checkingDecodedVideo = true;
    try {
      final values = await Future.wait([
        _optionalNativeProperty(platform, 'current-tracks/video/codec'),
        _optionalNativeProperty(platform, 'current-tracks/video/codec-profile'),
        _optionalNativeProperty(platform, 'current-tracks/video/format-name'),
        _optionalNativeProperty(platform, 'video-dec-params/pixelformat'),
        _optionalNativeProperty(platform, 'hwdec-current'),
      ]);
      final hardwareDecoder = values[4];
      if (hardwareDecoder == null || hardwareDecoder == 'no') return;
      if (isH264TenBitVideoProfile(
        codec: values[0] ?? _player.state.track.video.codec,
        profile: values[1],
        format: values[2],
        pixelFormat: values[3] ?? params.pixelformat,
        hardwarePixelFormat: params.hwPixelformat,
      )) {
        await _switchDecoder(
          PlaybackDecoderMode.software,
          automatic: true,
          reason: '10-bit H.264 detected; corrected video mode enabled',
        );
      }
    } finally {
      _checkingDecodedVideo = false;
    }
  }

  Future<void> _checkPlaybackPerformance() async {
    if (_checkingPerformance ||
        _changingDecoder ||
        !_player.state.playing ||
        _player.state.buffering) {
      return;
    }
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    _checkingPerformance = true;
    try {
      final value = await platform.getProperty('frame-drop-count');
      final dropped = int.tryParse(value) ?? _lastDroppedFrames;
      final delta = dropped >= _lastDroppedFrames
          ? dropped - _lastDroppedFrames
          : dropped;
      _lastDroppedFrames = dropped;
      _highDropSamples = delta >= 10 ? _highDropSamples + 1 : 0;
      if (_highDropSamples < 2) return;
      _highDropSamples = 0;
      if (_hasUntriedDirectStream) {
        await _tryNextStream(
          'This stream is dropping too many frames on this device.',
        );
      } else if (_decoderMode != PlaybackDecoderMode.software) {
        await _switchDecoder(
          PlaybackDecoderMode.software,
          automatic: true,
          reason: 'Playback was dropping frames; compatibility mode enabled',
        );
      } else {
        const reason =
            'This stream is dropping too many frames on this device.';
        if (_handleLibraryStartupFailure(reason, allowAfterStartup: true)) {
          return;
        }
        await _tryNextStream(reason);
      }
    } catch (_) {
      // Frame statistics are optional across libmpv builds.
    } finally {
      _checkingPerformance = false;
    }
  }

  Future<void> _switchDecoder(
    PlaybackDecoderMode mode, {
    bool automatic = false,
    String? reason,
  }) => _trackPlayerMutation(() async {
    if (_changingDecoder || mode == _decoderMode) return;
    final diagnosticReasonCode = automatic
        ? playbackDiagnosticFailureReasonCode(reason)
        : 'user_decoder_change';
    if (automatic) {
      unawaited(
        _playbackDiagnostics.fallbackAttempted(
          fallbackKind: PlaybackDiagnosticFallbackKind.decoder,
          sourceKind: _diagnosticSourceKind,
          decoder: switch (mode) {
            PlaybackDecoderMode.hardwareSafe =>
              PlaybackDiagnosticDecoder.hardwareAdaptive,
            PlaybackDecoderMode.hardwareDirect =>
              PlaybackDiagnosticDecoder.hardwareDirect,
            PlaybackDecoderMode.software =>
              PlaybackDiagnosticDecoder.softwareCompatibility,
          },
          codec: _player.state.track.video.codec,
          reasonCode: diagnosticReasonCode,
          attempt: ++_diagnosticFallbackAttempt,
        ),
      );
    }
    _changingDecoder = true;
    _decoderMode = mode;
    _recordDiagnosticDecoderSelected(
      automatic: automatic,
      reasonCode: diagnosticReasonCode,
    );
    _softwareFallbackUsed = mode == PlaybackDecoderMode.software;
    _videoWatchdog?.cancel();
    final position = _effectiveHandoffPosition();
    final wasPlaying = _player.state.playing;
    final diagnosticOpenAttempt = ++_diagnosticStreamOpenAttempt;
    final persistenceWasReady = _playbackPersistenceReady;
    _playbackPersistenceReady = false;
    try {
      _resetCompletionObservation(position);
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('hwdec', hwdecForPlaybackMode(mode));
        await platform.setProperty('hwdec-software-fallback', '1');
        await _configureNativeAudioPreference(platform);
      }
      _preferredAudioSelected = false;
      _preferredSubtitleSelected = false;
      _videoFrameSeen = false;
      await _openCurrentMedia(play: automatic || wasPlaying);
      _recordDiagnosticStreamOpenResult(
        attempt: diagnosticOpenAttempt,
        succeeded: true,
      );
      if (position > Duration.zero) await _restoreResumePosition(position);
      await _applySubtitle();
      await _applyPlayerTuning();
      await _saveDecoderPreference();
      _startVideoWatchdog();
      _startPerformanceWatchdog();
      if (mounted) {
        setState(() => _playbackError = null);
        _showTrackMessage(
          automatic
              ? reason ??
                    'Video failed to start; software compatibility enabled'
              : '${playbackDecoderLabel(mode)} enabled',
        );
      }
    } catch (error) {
      final failureReasonCode = playbackDiagnosticFailureReasonCode(error);
      _recordDiagnosticStreamOpenResult(
        attempt: diagnosticOpenAttempt,
        succeeded: false,
        reasonCode: failureReasonCode,
      );
      if (automaticDecoderFailureNeedsLibraryRecovery(
            automatic: automatic,
            hasLibrarySession: widget.libraryPlayback != null,
            error: error,
          ) &&
          _handleLibraryStartupFailure(error)) {
        return;
      }
      _recordDiagnosticOutcome(
        PlaybackDiagnosticOutcome.failed,
        reasonCode: failureReasonCode,
      );
      if (mounted) setState(() => _playbackError = error.toString());
    } finally {
      if (persistenceWasReady) _playbackPersistenceReady = true;
      _changingDecoder = false;
    }
  });

  Future<void> _retryPlayback() => _trackPlayerMutation(() async {
    final position = _effectiveHandoffPosition();
    final wasPlaying = _player.state.playing;
    unawaited(
      _playbackDiagnostics.fallbackAttempted(
        fallbackKind: PlaybackDiagnosticFallbackKind.retry,
        sourceKind: _diagnosticSourceKind,
        decoder: _diagnosticDecoder,
        codec: _player.state.track.video.codec,
        reasonCode: 'user_retry',
        attempt: ++_diagnosticFallbackAttempt,
      ),
    );
    final diagnosticOpenAttempt = ++_diagnosticStreamOpenAttempt;
    final persistenceWasReady = _playbackPersistenceReady;
    _playbackPersistenceReady = false;
    setState(() => _playbackError = null);
    try {
      _videoFrameSeen = false;
      _resetCompletionObservation(position);
      await _configureNativePlayback();
      await _openCurrentMedia(play: wasPlaying);
      _recordDiagnosticStreamOpenResult(
        attempt: diagnosticOpenAttempt,
        succeeded: true,
      );
      if (position > Duration.zero) await _restoreResumePosition(position);
      await _applySubtitle();
      await _applyPlayerTuning();
      _startVideoWatchdog();
      _startPerformanceWatchdog();
      _showTrackMessage('Stream restarted');
    } catch (error) {
      final reasonCode = playbackDiagnosticFailureReasonCode(error);
      _recordDiagnosticStreamOpenResult(
        attempt: diagnosticOpenAttempt,
        succeeded: false,
        reasonCode: reasonCode,
      );
      _recordDiagnosticOutcome(
        PlaybackDiagnosticOutcome.failed,
        reasonCode: reasonCode,
      );
      if (mounted) setState(() => _playbackError = error.toString());
    } finally {
      if (persistenceWasReady) _playbackPersistenceReady = true;
    }
  });

  Stream<WebStreamSearchProgress> _webSourceSearch({bool refresh = false}) =>
      ref
          .read(webStreamAggregatorProvider)
          .watchSearchIncrementally(widget.launch.episode, refresh: refresh);

  Future<void> _startWebSourceDiscovery({bool restart = false}) async {
    if (!_animeFeaturesEnabled) return;
    if (!mounted || _engineHandoffInProgress) return;
    final webStreamsEnabled = ref
        .read(settingsPreferencesProvider)
        .webStreamsEnabled;
    final aggregator = ref.read(webStreamAggregatorProvider);
    final episode = widget.launch.episode;
    if (!webStreamsEnabled) return;
    if (_sourceDiscoverySubscription != null && !restart) return;
    await _sourceDiscoverySubscription?.cancel();
    if (!mounted || _engineHandoffInProgress) return;
    _sourceDiscoverySubscription = aggregator
        .watchSearchIncrementally(episode)
        .listen((progress) {
          if (!mounted || _engineHandoffInProgress) return;
          _mergeDirectStreamOptions(
            progress.aggregation.streams.map(playbackOptionForWebStream),
          );
        }, onError: (_) {});
  }

  void _mergeDirectStreamOptions(Iterable<PlaybackStreamOption> options) {
    final merged = mergePlaybackStreamOptions(
      _directStreamOptions,
      options.where(
        (option) => playbackEpisodeIdentityIsCompatible(
          episode: widget.launch.episode,
          stream: option.stream,
          release: option.release,
        ),
      ),
    );
    final before = _directStreamOptions
        .map(playbackStreamOptionAttemptKey)
        .join('\n');
    final after = merged.map(playbackStreamOptionAttemptKey).join('\n');
    if (before == after) return;
    setState(() => _directStreamOptions = merged);
  }

  Future<PlaybackStreamOption?> _preflightDirectStream(
    PlaybackStreamOption option, {
    bool silent = false,
  }) async {
    if (!mounted || _engineHandoffInProgress) return null;
    if (!option.stream.isWebStream) return option;
    if (!silent) {
      _showTrackMessage('Checking ${playbackStreamOptionLabel(option)}...');
    }
    try {
      final validated = await const WebStreamValidator().validate(
        option.stream.uri,
        option.stream.headers,
        subtitleUri: option.stream.externalSubtitle,
      );
      if (!mounted || _engineHandoffInProgress) {
        await validated.session?.close();
        return null;
      }
      final validatedOption = PlaybackStreamOption(
        stream: StreamReady(
          uri: validated.uri,
          displayName: option.stream.displayName,
          headers: validated.headers,
          externalSubtitle: validated.subtitleUri,
          mediaContentType: validated.contentType,
          subtitleContentType: validated.subtitleContentType,
          externalSubtitleRejected: validated.subtitleRejected,
          playbackLease: validated.session,
          providerId: option.stream.providerId,
          providerName: option.stream.providerName,
          providerEpisodeIdentity: option.stream.providerEpisodeIdentity,
        ),
        release: option.release,
      );
      return validatedOption;
    } catch (error) {
      if (!mounted || _engineHandoffInProgress) return null;
      _failedDirectStreamKeys.add(playbackStreamOptionAttemptKey(option));
      if (!silent) {
        _showTrackMessage(
          'That source is unavailable: '
          "${error.toString().replaceFirst('FormatException: ', '')}",
        );
      }
      return null;
    }
  }

  Future<void> _openStreamSourcePicker() async {
    if (_blockGuestLocalControl()) return;
    _controlsTimer?.cancel();
    final selected = await _withHudAutoHideSuspended(
      () => showPlayerStreamSourcePicker(
        context: context,
        initialOptions: _directStreamOptions,
        selectedUri: _currentStream.uri,
        selectedStreamKey: playbackStreamReadyAttemptKey(
          _currentStream,
          fallbackProviderId: _currentRelease.sourceId,
        ),
        onOptionsChanged: (options) {
          if (mounted) setState(() => _directStreamOptions = options);
        },
        discover:
            (_currentStream.isWebStream || _currentStream.isDirectTorrent) &&
                ref.read(settingsPreferencesProvider).webStreamsEnabled
            ? _webSourceSearch
            : null,
      ),
    );
    if (!mounted) return;
    if (_blockGuestLocalControl()) {
      _showControls(focusControls: true);
      return;
    }
    if (selected == null ||
        playbackStreamOptionAttemptKey(selected) ==
            playbackStreamReadyAttemptKey(
              _currentStream,
              fallbackProviderId: _currentRelease.sourceId,
            )) {
      _showControls();
      return;
    }

    final option = await _preflightDirectStream(selected);
    if (!mounted) {
      await option?.stream.playbackLease?.close();
      return;
    }
    if (option == null) {
      _showControls();
      return;
    }
    final resume = _effectiveHandoffPosition();
    final previousSource = _source;
    final previousStream = _currentStream;
    final previousRelease = _currentRelease;
    final previousPreferences = _seriesPreferences;
    final previousDirectStreamOptions = _directStreamOptions;
    final previousDecoderMode = _decoderMode;
    final previousSoftwareFallbackUsed = _softwareFallbackUsed;
    final previousVideoFrameSeen = _videoFrameSeen;
    final selectedProvider = playbackStreamOptionProviderIdentity(option);
    final previousProvider = playbackStreamOptionProviderIdentity(
      PlaybackStreamOption(stream: previousStream, release: previousRelease),
    );
    _failedDirectStreamKeys.clear();
    _currentStream = option.stream;
    _source = option.stream.uri.toString();
    _currentRelease = option.release;
    _applyAutomaticSubtitleDefaultForRelease(option.release);
    _directStreamOptions = mergePlaybackStreamOptions(
      [option],
      _directStreamOptions.where((candidate) {
        final provider = playbackStreamOptionProviderIdentity(candidate);
        if (provider == selectedProvider &&
            (candidate.stream.uri == selected.stream.uri ||
                candidate.stream.uri == option.stream.uri)) {
          return false;
        }
        if (provider == previousProvider &&
            candidate.stream.uri == previousStream.uri) {
          return false;
        }
        return true;
      }),
    );
    _preferredAudioSelected = false;
    _preferredSubtitleSelected = false;
    _softwareFallbackUsed = false;
    _decoderMode = releaseRequiresSoftwareDecoder(option.release)
        ? PlaybackDecoderMode.software
        : PlaybackDecoderMode.hardwareSafe;
    _softwareFallbackUsed = _decoderMode == PlaybackDecoderMode.software;
    _videoFrameSeen = false;
    unawaited(
      _playbackDiagnostics.fallbackAttempted(
        fallbackKind: PlaybackDiagnosticFallbackKind.source,
        sourceKind: _diagnosticSourceKind,
        decoder: _diagnosticDecoder,
        codec: _player.state.track.video.codec,
        reasonCode: 'manual_source_change',
        attempt: ++_diagnosticFallbackAttempt,
      ),
    );
    _recordDiagnosticSourceSelected(automatic: false);
    _recordDiagnosticDecoderSelected(
      automatic: true,
      reasonCode: 'manual_source_change',
    );
    if (mounted) setState(() => _playbackError = null);
    try {
      await _openMedia(
        resume: resume,
        propagateFailure: true,
        requireDecodedVideo: true,
      );
      if (!mounted || _engineHandoffInProgress) {
        await option.stream.playbackLease?.close();
        return;
      }
      await widget.onStreamAdopted(option.stream, option.release);
      _invalidateNextEpisodePreparation();
      _resetSkipSegmentsForSourceChange();
    } catch (_) {
      await option.stream.playbackLease?.close();
      _source = previousSource;
      _currentStream = previousStream;
      _currentRelease = previousRelease;
      _seriesPreferences = previousPreferences;
      _directStreamOptions = previousDirectStreamOptions;
      _decoderMode = previousDecoderMode;
      _softwareFallbackUsed = previousSoftwareFallbackUsed;
      _videoFrameSeen = previousVideoFrameSeen;
      if (mounted && !_engineHandoffInProgress) {
        await _openMedia(resume: resume);
        _showTrackMessage(
          'That source could not start. Restored the previous stream.',
        );
      }
      return;
    }
    if (option.stream.externalSubtitleRejected) {
      _showTrackMessage(
        'Playing without the unsafe or unsupported external subtitles.',
      );
    }
    _showTrackMessage('Playing ${playbackStreamOptionLabel(option)}');
    _showControls();
  }

  // TODO: Remove after older persisted player-route labels are migrated.
  // ignore: unused_element
  static String _streamOptionLabel(PlaybackStreamOption option) {
    final quality = option.release.quality?.trim();
    final provider =
        option.stream.providerName ??
        option.release.provider ??
        option.release.sourceId;
    return [
      if (quality != null && quality.isNotEmpty) quality,
      provider,
    ].join(' • ');
  }

  Future<void> _openPlaybackMenu() async {
    if (_blockGuestLocalControl()) return;
    _controlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = true);
    final result = await _withHudAutoHideSuspended(
      () => showDialog<_PlaybackMenuResult>(
        context: context,
        barrierColor: const Color(0xD9000000),
        builder: (context) => _PlaybackOptionsDialog(
          decoderMode: _decoderMode,
          videoFit: _videoFit,
          playbackRate: _playbackRate,
          playbackSpeedEnabled: !_watchPartyActive,
          subtitleSize: _subtitleSize,
          subtitlePosition: _subtitlePosition,
          subtitleDelayMs: _subtitleDelayMs,
          audioDelayMs: _audioDelayMs,
          highContrastSubtitles: _highContrastSubtitles,
          hasAlternateStreams: widget.launch.alternatives.any(
            (candidate) => !_attemptedReleaseAlternatives.contains(candidate),
          ),
          hasDirectSources:
              _currentStream.isWebStream || _currentStream.isDirectTorrent,
          canOpenExternally: _externalPlayerTarget != null,
        ),
      ),
    );
    if (!mounted) return;
    if (_blockGuestLocalControl()) {
      _showControls(focusControls: true);
      return;
    }
    if (result == null) {
      _scheduleControlsHide();
      return;
    }
    switch (result.type) {
      case 'decoder':
        await _switchDecoder(result.value as PlaybackDecoderMode);
      case 'fit':
        setState(() => _videoFit = result.value as BoxFit);
        _showTrackMessage(_fitLabel(_videoFit));
      case 'rate':
        await _setPlaybackRate(result.value as double);
      case 'external':
        await _openExternalPlayer();
      case 'subtitleSize':
        setState(() => _subtitleSize = result.value as double);
        _showTrackMessage('Subtitle size ${_subtitleSize.round()}');
      case 'subtitlePosition':
        setState(() => _subtitlePosition = result.value as int);
        _showTrackMessage('Subtitle position $_subtitlePosition%');
      case 'subtitleDelay':
        setState(() => _subtitleDelayMs = result.value as int);
        _showTrackMessage('Subtitle delay ${_subtitleDelayMs}ms');
      case 'audioDelay':
        setState(() => _audioDelayMs = result.value as int);
        _showTrackMessage('Audio delay ${_audioDelayMs}ms');
      case 'contrast':
        setState(() => _highContrastSubtitles = result.value as bool);
        _showTrackMessage(
          _highContrastSubtitles
              ? 'High contrast subtitles on'
              : 'High contrast subtitles off',
        );
      case 'nextStream':
        await _tryNextStream('Stream changed manually.', notify: false);
      case 'sources':
        await _openStreamSourcePicker();
      case 'retry':
        await _retryPlayback();
    }
    if (!mounted) return;
    await _applyPlayerTuning();
    if (!mounted) return;
    await _saveSeriesPreferences();
    if (!mounted) return;
    _scheduleControlsHide();
  }

  Future<void> _openPlaybackSpeedPicker() async {
    if (_blockGuestLocalControl()) return;
    if (_watchPartyActive) {
      _showTrackMessage('Playback speed stays at 1x during a Watch Party');
      return;
    }
    _controlsTimer?.cancel();
    final selected = await _withHudAutoHideSuspended(
      () => showPlayerPlaybackSpeedPicker(
        context: context,
        current: _playbackRate,
      ),
    );
    if (!mounted) return;
    if (selected != null) await _setPlaybackRate(selected);
    _showControls();
  }

  Future<void> _openExternalPlayer() async {
    final target = _externalPlayerTarget;
    if (target == null) {
      _showTrackMessage('External playback is unavailable for this source');
      return;
    }
    final wasPlaying = _player.state.playing;
    var pausedForHandoff = false;
    try {
      if (wasPlaying) {
        await _player.pause();
        pausedForHandoff = true;
      }
      final opened = await AndroidTvBridge.instance.openExternalPlayer(
        uri: target.uri,
        localPath: target.localPath,
        mediaContentType: _currentStream.mediaContentType,
        packageName:
            ref.read(settingsPreferencesProvider).preferredPlayer ==
                PreferredPlayer.external
            ? ref
                  .read(settingsPreferencesProvider)
                  .selectedExternalPlayerPackage
            : null,
      );
      if (!opened) {
        throw PlatformException(
          code: 'EXTERNAL_PLAYER_OPEN',
          message: 'The external player did not open.',
        );
      }
      if (mounted) _showTrackMessage('Opened in external player');
    } on PlatformException catch (error) {
      if (error.code == 'EXTERNAL_PLAYER_MISSING') {
        unawaited(
          ref
              .read(settingsPreferencesProvider.notifier)
              .fallBackToMpvAndClearExternalPlayer(),
        );
      }
      if (pausedForHandoff) {
        try {
          await _player.play();
        } catch (_) {}
      }
      if (!mounted) return;
      _showTrackMessage(
        error.code == 'EXTERNAL_PLAYER_MISSING'
            ? 'No compatible external player is installed'
            : 'Could not open an external player',
      );
    } catch (_) {
      if (pausedForHandoff) {
        try {
          await _player.play();
        } catch (_) {}
      }
      if (mounted) _showTrackMessage('Could not open an external player');
    }
  }

  Future<bool> _openConfiguredDefaultPlayer(
    SettingsPreferences preferences, {
    required Duration? resume,
  }) async {
    if (!configuredExternalPlayerEligible(
      preferences: preferences,
      watchPartyActive: _watchPartyActive,
      stream: _currentStream,
      libraryProviderId: widget.libraryPlayback?.request.sourceProviderId,
    )) {
      return false;
    }
    final target = externalPlayerTargetForStream(_currentStream)!;
    final navigator = Navigator.of(context);
    var retainedProxyLease = false;
    try {
      retainedProxyLease = await ExternalPlayerProxyLeaseKeeper.instance
          .retainForHandoff(target.uri);
      final opened = await AndroidTvBridge.instance.openExternalPlayer(
        uri: target.uri,
        localPath: target.localPath,
        mediaContentType: _currentStream.mediaContentType,
        packageName: preferences.selectedExternalPlayerPackage,
      );
      if (!opened) {
        if (retainedProxyLease) {
          await ExternalPlayerProxyLeaseKeeper.instance.release();
        }
        return false;
      }
      if (!mounted) return true;
      final released = await _prepareForEngineHandoff(resume ?? Duration.zero);
      if (released) _popPlayerRouteAfterHandoff(navigator);
      return true;
    } on PlatformException catch (error) {
      if (retainedProxyLease) {
        await ExternalPlayerProxyLeaseKeeper.instance.release();
      }
      if (error.code == 'EXTERNAL_PLAYER_MISSING') {
        await ref
            .read(settingsPreferencesProvider.notifier)
            .fallBackToMpvAndClearExternalPlayer();
      }
      if (mounted) {
        _showTrackMessage(
          error.code == 'EXTERNAL_PLAYER_MISSING'
              ? 'Default player is unavailable — using MPV'
              : 'That app could not open this stream — using MPV',
        );
      }
      return false;
    } catch (_) {
      if (retainedProxyLease) {
        await ExternalPlayerProxyLeaseKeeper.instance.release();
      }
      if (mounted) _showTrackMessage('External player failed — using MPV');
      return false;
    }
  }

  Future<void> _setPlaybackRate(double rate) async {
    if (_watchPartyActive || !playerPlaybackSpeedValues.contains(rate)) return;
    await _player.setRate(rate);
    if (!mounted) return;
    setState(() => _playbackRate = rate);
    unawaited(_updateMediaSession(force: true));
    _showTrackMessage('Playback speed ${playerPlaybackSpeedLabel(rate)}');
  }

  Future<void> _resetPlaybackRateForWatchParty() async {
    await _player.setRate(1);
    if (!mounted || _playbackRate == 1) return;
    setState(() => _playbackRate = 1);
    unawaited(_updateMediaSession(force: true));
    _showTrackMessage('Playback speed reset to 1x for Watch Party sync');
  }

  Future<void> _openWatchParty() async {
    _controlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = true);
    await _withHudAutoHideSuspended(() => showWatchPartyPlayerDialog(context));
    if (!mounted) return;
    _showControls();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controlsVisible) _watchTogetherFocus.requestFocus();
    });
  }

  void _cycleFit() {
    if (_blockGuestLocalControl()) return;
    final next = switch (_videoFit) {
      BoxFit.contain => BoxFit.cover,
      BoxFit.cover => BoxFit.fill,
      _ => BoxFit.contain,
    };
    setState(() => _videoFit = next);
    unawaited(_saveSeriesPreferences());
    _showTrackMessage(_fitLabel(next));
  }

  static String _fitLabel(BoxFit fit) => switch (fit) {
    BoxFit.cover => 'Picture: Fill screen',
    BoxFit.fill => 'Picture: Stretch',
    _ => 'Picture: Fit',
  };

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (_engineHandoffInProgress) {
      _hiddenHudDpadSeek.cancel();
      return KeyEventResult.handled;
    }

    if (_hiddenHudDpadSeek.handleKeyEvent(
      event: event,
      controlsVisible: _controlsVisible,
      enabled: !_guestControlsLocked,
      onSeek: (key, {required bool repeated}) {
        final seconds = key == LogicalKeyboardKey.arrowLeft
            ? -_seekBackSeconds
            : _seekForwardSeconds;
        unawaited(
          _seekBy(Duration(seconds: seconds), capturePreview: !repeated),
        );
      },
      onBlocked: _showGuestControlLockMessage,
    )) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (event is KeyDownEvent && _controlsVisible) {
      if (key == LogicalKeyboardKey.arrowUp &&
          _canSkipNow &&
          _activeSkip != null &&
          !_skipControlFocus.hasPrimaryFocus) {
        // The skip action floats above the transport row. Give every control
        // the same one-press route to it instead of requiring the viewer to
        // traverse horizontally to the far edge of the HUD first.
        _skipControlFocus.requestFocus();
        _showControls();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown &&
          _skipControlFocus.hasPrimaryFocus) {
        _playControlFocus.requestFocus();
        _showControls();
        return KeyEventResult.handled;
      }
    }
    if (consumeHiddenPlayerHudDownRepeat(
      key: key,
      isRepeat: event is KeyRepeatEvent,
      controlsVisible: _controlsVisible,
    )) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        key == LogicalKeyboardKey.arrowDown &&
        _controlsVisible) {
      _hideControls();
      return KeyEventResult.handled;
    }
    final directionalKey =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    final controlsWereHidden = !_controlsVisible;
    _showControls(focusControls: controlsWereHidden && directionalKey);
    if (!node.hasPrimaryFocus &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      return KeyEventResult.ignored;
    }
    if (node.hasPrimaryFocus && directionalKey) {
      _showControls(focusControls: true);
      return KeyEventResult.handled;
    }
    if (playerSeekOffsetForKey(
          key,
          backSeconds: _seekBackSeconds,
          forwardSeconds: _seekForwardSeconds,
        )
        case final offset?) {
      _seekBy(offset);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.keyK) {
      _playOrPauseLocal();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      unawaited(_openSubtitleTrackPicker());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyI && _canSkipNow) {
      _skipCurrentSegment();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.gameButtonY) {
      unawaited(_openPlaybackMenu());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      if (_blockGuestLocalControl()) return KeyEventResult.handled;
      if (_softwareFallbackUsed) {
        _showTrackMessage('Compatibility decoder is already enabled');
      } else {
        unawaited(
          _switchDecoder(
            PlaybackDecoderMode.software,
            reason: 'User selected the compatibility decoder.',
          ),
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyA ||
        key == LogicalKeyboardKey.gameButtonX) {
      _cycleFit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _seekBy(Duration offset, {bool capturePreview = true}) async {
    if (_engineHandoffInProgress || _blockGuestLocalControl()) return;
    // Invalidate a delayed screenshot as soon as a newer seek is requested,
    // not only after the newer seek finishes. Otherwise the old capture can
    // race the decoder and be shown with a stale timestamp.
    final generation = ++_trickplayGeneration;
    _queuedSeekTarget = playerSeekTarget(
      position: _queuedSeekTarget ?? _player.state.position,
      offset: offset,
      duration: _player.state.duration,
    );
    _queuedSeekCapturePreview = capturePreview;
    _queuedSeekGeneration = generation;
    await _drainSeekQueue();
  }

  Future<void> _seekTo(Duration target, {bool capturePreview = true}) async {
    if (_engineHandoffInProgress || _blockGuestLocalControl()) return;
    final generation = ++_trickplayGeneration;
    _queuedSeekTarget = playerScrubTarget(
      target: target,
      duration: _player.state.duration,
    );
    _queuedSeekCapturePreview = capturePreview;
    _queuedSeekGeneration = generation;
    await _drainSeekQueue();
  }

  Future<void> _drainSeekQueue() async {
    final activeDrain = _seekDrainCompleter;
    if (activeDrain != null) {
      await activeDrain.future;
      // A target can arrive after the active loop observed an empty queue but
      // before its completer was cleared. Start a new drain instead of leaving
      // that final touch/D-pad commit stranded indefinitely.
      if (_queuedSeekTarget != null) await _drainSeekQueue();
      return;
    }
    final drain = Completer<void>();
    _seekDrainCompleter = drain;
    try {
      while (_queuedSeekTarget != null) {
        if (_guestControlsLocked) {
          _queuedSeekTarget = null;
          _queuedSeekCapturePreview = false;
          _queuedSeekGeneration = 0;
          break;
        }
        final target = _queuedSeekTarget!;
        final capturePreview = _queuedSeekCapturePreview;
        final seekGeneration = _queuedSeekGeneration;
        _queuedSeekTarget = null;
        _queuedSeekCapturePreview = false;
        _queuedSeekGeneration = 0;
        _pendingInheritedResume = null;
        await _player.seek(target);
        _recordCommittedSeek(target);
        if (!_engineHandoffInProgress && capturePreview) {
          final operation = _captureTrickplay(target, seekGeneration);
          _trickplayOperations.add(operation);
          unawaited(
            operation.whenComplete(() {
              _trickplayOperations.remove(operation);
            }),
          );
        }
      }
    } catch (_) {
      _queuedSeekTarget = null;
      _queuedSeekCapturePreview = false;
      _queuedSeekGeneration = 0;
      if (mounted && !_engineHandoffInProgress) {
        _showTrackMessage('Could not seek to that position');
      }
    } finally {
      if (identical(_seekDrainCompleter, drain)) {
        _seekDrainCompleter = null;
      }
      if (!drain.isCompleted) drain.complete();
    }
  }

  Future<void> _waitForSeekDrain() async {
    final drain = _seekDrainCompleter;
    if (drain != null) await drain.future;
  }

  Future<void> _captureTrickplay(Duration target, int generation) async {
    try {
      // media_kit can complete seek before the newly decoded frame reaches
      // MPV's screenshot surface. Give it one short frame window, then keep
      // only the newest request so rapid scrubbing cannot display an older
      // scene with the latest timestamp.
      await Future<void>.delayed(const Duration(milliseconds: 70));
      if (!mounted || generation != _trickplayGeneration) return;
      final bytes = await _player.screenshot(format: 'image/jpeg');
      if (!mounted ||
          generation != _trickplayGeneration ||
          _engineHandoffInProgress ||
          bytes == null ||
          bytes.isEmpty) {
        return;
      }
      _seekPreviewTimer?.cancel();
      setState(() {
        _seekPreview = bytes;
        _seekPreviewPosition = target;
      });
      _seekPreviewTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _seekPreview = null);
      });
    } catch (_) {
      // Some protected video surfaces do not permit screenshots.
    }
  }

  Future<void> _openAudioTrackPicker() async {
    if (_blockGuestLocalControl()) return;
    _controlsTimer?.cancel();
    final expectsMultipleAudio = releaseAdvertisesMultipleAudio(
      _currentRelease.releaseName,
    );
    if (expectsMultipleAudio) {
      _showTrackMessage('Checking every embedded audio track…');
    }
    final tracks = await _withHudAutoHideSuspended(
      () => waitForStableTrackSnapshot<List<AudioTrack>>(
        read: () async {
          if (!mounted || _engineHandoffInProgress) return const <AudioTrack>[];
          return _player.state.tracks.audio
              .where((track) => track.id != 'auto' && track.id != 'no')
              .toList(growable: false);
        },
        signature: mediaKitAudioTrackSignature,
        hasTracks: (tracks) => tracks.isNotEmpty,
        // A stable first track is not proof that demuxing is finished. Always
        // use the short bounded window for a possible second track; release
        // names advertising dual audio receive the longer window below.
        isComplete: (tracks) => tracks.length >= 2,
        maximumWait: expectsMultipleAudio
            ? const Duration(seconds: 5)
            : const Duration(seconds: 2),
      ),
    );
    if (!mounted || _engineHandoffInProgress) return;
    if (_blockGuestLocalControl()) {
      _showControls(focusControls: true);
      return;
    }
    if (tracks.isEmpty) {
      _showTrackMessage('This file has no selectable embedded audio tracks');
      return;
    }
    _controlsTimer?.cancel();
    final currentId = _player.state.track.audio.id;
    final selectedId = await _withHudAutoHideSuspended(
      () => showPlayerTrackPicker<String>(
        context: context,
        title: tracks.length == 1
            ? expectsMultipleAudio
                  ? 'Audio track (only 1 detected)'
                  : 'Audio track (1 found)'
            : 'Audio tracks (${tracks.length} found)',
        icon: Icons.audiotrack_rounded,
        selectedValue: currentId,
        options: tracks
            .map(
              (track) => PlayerTrackOption<String>(
                value: track.id,
                label: track.title ?? track.language ?? 'Track ${track.id}',
                detail: mediaKitAudioTrackDetail(track),
                icon: Icons.surround_sound_rounded,
              ),
            )
            .toList(growable: false),
      ),
    );
    if (!mounted) return;
    if (_blockGuestLocalControl()) {
      _showControls(focusControls: true);
      return;
    }
    if (selectedId == null) {
      _showControls();
      return;
    }
    final selected = tracks.firstWhere((track) => track.id == selectedId);
    final previousAudioLanguage = _seriesPreferences.audioLanguage;
    final previousAudioPreferenceSet = _seriesPreferences.audioPreferenceSet;
    _preferredAudioSelected = true;
    await _player.setAudioTrack(selected);
    final selectedLanguage = persistedPlayerAudioLanguage(
      storedLanguage: _seriesPreferences.audioLanguage,
      audioPreferenceSet: _seriesPreferences.audioPreferenceSet,
      observedLanguage: selected.language,
      observedTitle: selected.title,
      manualSelection: true,
    );
    _seriesPreferences = _seriesPreferences.copyWith(
      audioLanguage: selectedLanguage,
      audioPreferenceSet: true,
    );
    _watchPartyPlayback.updateRequestedAudio(_effectiveAudioPreference);
    _publishWatchPartyPlayback();
    await _saveSeriesPreferences();
    _recordDiagnosticAudioTrackSelected(
      track: selected,
      tracks: tracks,
      preferenceMatched: playerTrackMatchesAudioLanguage(
        selected,
        _seriesPreferences.audioLanguage,
      ),
    );
    if (playerAudioIntentChanged(
      previousLanguage: previousAudioLanguage,
      previousPreferenceSet: previousAudioPreferenceSet,
      nextLanguage: _seriesPreferences.audioLanguage,
      nextPreferenceSet: _seriesPreferences.audioPreferenceSet,
    )) {
      _invalidateNextEpisodePreparation();
    }
    _showTrackMessage(
      'Audio: ${selected.title ?? selected.language ?? 'Track ${selected.id}'}',
    );
    _showControls();
  }

  Future<void> _skipCurrentSegment() async {
    if (_skipInProgress ||
        _engineHandoffInProgress ||
        _blockGuestLocalControl()) {
      return;
    }
    final segment = _activeSkip;
    if (segment == null) return;
    _skipInProgress = true;
    final target = safeSkipSegmentTarget(
      requested: segment.end,
      duration: _player.state.duration,
    );
    final segmentKey = skipSegmentKey(segment);
    _consumedSkipSegments.add(segmentKey);
    _recordSkipSegmentActionDiagnostic(
      status: 'manual_action_started',
      segment: segment,
      automatic: false,
      position: _player.state.position,
      target: target,
    );
    if (mounted) {
      final skipHadFocus = _skipControlFocus.hasFocus;
      setState(() {
        _activeSkip = null;
        _canSkipNow = false;
      });
      _recoverFocusAfterSkipDismissed(skipHadFocus: skipHadFocus);
    }
    try {
      final duration = _player.state.duration;
      final wasPlaying = _player.state.playing;
      final succeeded = await _seekForSkip(
        target,
        supersedeInheritedResume: true,
      );
      if (!succeeded) throw StateError('skip seek failed');
      _recordSkipSegmentActionDiagnostic(
        status: 'seek_succeeded',
        segment: segment,
        automatic: false,
        position: _player.state.position,
        target: target,
        seekSucceeded: true,
      );
      if (mounted && !_engineHandoffInProgress) {
        _showTrackMessage(segment.actionLabel.replaceFirst('Skip', 'Skipped'));
      }
      if (!wasPlaying &&
          segment.kind == SkipSegmentKind.ending &&
          skipSegmentReachesPlaybackEnd(
            requestedEnd: segment.end,
            duration: duration,
          )) {
        _handlePlaybackCompleted();
      }
    } catch (_) {
      _recordSkipSegmentActionDiagnostic(
        status: 'seek_failed',
        segment: segment,
        automatic: false,
        position: _player.state.position,
        target: target,
        seekSucceeded: false,
      );
      _consumedSkipSegments.remove(segmentKey);
      if (mounted && !_engineHandoffInProgress) {
        _showTrackMessage('Could not skip this segment');
      }
    } finally {
      _skipInProgress = false;
      if (mounted && !_engineHandoffInProgress) {
        _checkSkips(_player.state.position);
      }
    }
  }

  Future<void> _openSubtitleTrackPicker() async {
    if (_blockGuestLocalControl()) return;
    _controlsTimer?.cancel();
    _showTrackMessage('Checking embedded and external captions…');
    final discovered = await _withHudAutoHideSuspended(
      () => waitForStableTrackSnapshot<List<SubtitleTrack>>(
        read: () async {
          if (!mounted || _engineHandoffInProgress) {
            return const <SubtitleTrack>[];
          }
          return _player.state.tracks.subtitle
              .where((track) => track.id != 'auto' && track.id != 'no')
              .toList(growable: false);
        },
        signature: mediaKitSubtitleTrackSignature,
        hasTracks: (tracks) => tracks.isNotEmpty,
        maximumWait:
            _currentStream.externalSubtitle != null || widget.subtitle != null
            ? const Duration(seconds: 4)
            : const Duration(seconds: 3),
      ),
    );
    if (!mounted || _engineHandoffInProgress) return;
    if (_blockGuestLocalControl()) {
      _showControls(focusControls: true);
      return;
    }
    // media_kit can select a URI subtitle before it adds that external track
    // to the demuxer's published list. Keep the selected track visible in the
    // picker instead of incorrectly presenting only "Off".
    final current = _player.state.track.subtitle;
    final embedded = <SubtitleTrack>[
      ...discovered,
      if (current.id != 'auto' &&
          current.id != 'no' &&
          !discovered.any((track) => track.id == current.id))
        current,
    ];
    final tracks = <SubtitleTrack>[SubtitleTrack.no(), ...embedded];
    _controlsTimer?.cancel();
    final currentId = _player.state.track.subtitle.id;
    final selectedId = await _withHudAutoHideSuspended(
      () => showPlayerTrackPicker<String>(
        context: context,
        title: 'Closed captions',
        icon: Icons.closed_caption_rounded,
        selectedValue: currentId,
        options: tracks
            .map(
              (track) => PlayerTrackOption<String>(
                value: track.id,
                label: track.id == 'no'
                    ? 'Off'
                    : track.title ?? track.language ?? 'Track ${track.id}',
                detail: track.id == 'no'
                    ? 'Disable captions'
                    : playerTrackMatchesLanguage(
                        language: track.language,
                        title: track.title,
                        preferredLanguage: 'eng',
                      )
                    ? 'English'
                    : track.language,
                icon: track.id == 'no'
                    ? Icons.closed_caption_disabled_rounded
                    : Icons.closed_caption_rounded,
              ),
            )
            .toList(growable: false),
      ),
    );
    if (!mounted) return;
    if (_blockGuestLocalControl()) {
      _showControls(focusControls: true);
      return;
    }
    if (selectedId == null) {
      _showControls();
      return;
    }
    final selected = tracks.firstWhere((track) => track.id == selectedId);
    _preferredSubtitleSelected = true;
    final selectedLanguage = canonicalPlayerTrackLanguage(
      language: selected.language,
      title: selected.title,
    );
    _seriesPreferences = _seriesPreferences.copyWith(
      subtitleLanguage: selectedLanguage.isEmpty
          ? _seriesPreferences.subtitleLanguage
          : selectedLanguage,
      subtitleEnabled: selected.id != 'no',
      subtitlePreferenceSet: true,
    );
    await _player.setSubtitleTrack(selected);
    await _saveSeriesPreferences();
    _showTrackMessage(
      selected.id == 'no'
          ? 'Subtitles: Off'
          : 'Subtitles: '
                '${selected.title ?? selected.language ?? 'Track ${selected.id}'}',
    );
    _showControls();
  }

  void _showTrackMessage(String message) {
    if (!mounted) return;
    setState(() => _trackMessage = message);
    Timer(const Duration(seconds: 2), () {
      if (mounted && _trackMessage == message) {
        setState(() => _trackMessage = null);
      }
    });
  }

  void _showGuestControlLockMessage() {
    final now = DateTime.now();
    if (now.difference(_lastGuestControlNotice) < const Duration(seconds: 2)) {
      return;
    }
    _lastGuestControlNotice = now;
    _showTrackMessage(
      'Only the host can control playback while you are synced',
    );
  }

  bool _blockGuestLocalControl({bool notify = true}) {
    if (!_guestControlsLocked) return false;
    if (notify) _showGuestControlLockMessage();
    return true;
  }

  void _playOrPauseLocal() {
    if (_blockGuestLocalControl()) return;
    unawaited(_player.playOrPause());
  }

  bool get _skipFocusAvailable =>
      !_guestControlsLocked && _canSkipNow && _activeSkip != null;

  void _requestPrimaryPlayerFocus() {
    if (_skipFocusAvailable) {
      _skipControlFocus.requestFocus();
    } else if (_guestControlsLocked) {
      _watchTogetherFocus.requestFocus();
    } else {
      _playControlFocus.requestFocus();
    }
  }

  void _showControls({bool focusControls = false}) {
    _hiddenHudDpadSeek.cancel();
    final wasHidden = !_controlsVisible;
    if (mounted && wasHidden) setState(() => _controlsVisible = true);
    if (focusControls || (wasHidden && _skipFocusAvailable)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _requestPrimaryPlayerFocus();
      });
    }
    _scheduleControlsHide();
  }

  void _handlePlayerHudInteraction() {
    if (_engineHandoffInProgress) return;
    _showControls();
  }

  bool get _hudAutoHideSuspended =>
      _progressScrubActive || _hudAutoHideHoldCount > 0;

  Future<T> _withHudAutoHideSuspended<T>(Future<T> Function() operation) async {
    _hudAutoHideHoldCount += 1;
    _controlsTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    try {
      return await operation();
    } finally {
      if (_hudAutoHideHoldCount > 0) _hudAutoHideHoldCount -= 1;
      if (mounted && _controlsVisible && !_hudAutoHideSuspended) {
        _scheduleControlsHide();
      }
    }
  }

  void _handleProgressScrubInteraction(bool active) {
    if (_progressScrubActive == active) return;
    _progressScrubActive = active;
    _controlsTimer?.cancel();
    if (active) {
      if (mounted && !_controlsVisible) setState(() => _controlsVisible = true);
      return;
    }
    // Preview seeks deliberately suppress persistent and synchronized side
    // effects. Commit after the final seek drains; if MPV emits that final
    // position itself, its newer event generation already owns the commit.
    unawaited(_commitProgressScrubPosition(_positionEventGeneration));
    if (mounted && _controlsVisible) _scheduleControlsHide();
  }

  Future<void> _commitProgressScrubPosition(int observedGeneration) async {
    await _waitForSeekDrain();
    if (!mounted ||
        _engineHandoffInProgress ||
        _progressScrubActive ||
        _positionEventGeneration != observedGeneration) {
      return;
    }
    _onPosition(_player.state.position);
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (_hudAutoHideSuspended) return;
    _controlsTimer = Timer(playerControlsIdleTimeout, () {
      if (mounted && !_hudAutoHideSuspended) _hideControls();
    });
  }

  void _hideControls() {
    _controlsTimer?.cancel();
    if (_hudAutoHideSuspended) return;
    if (mounted && _controlsVisible) {
      setState(() => _controlsVisible = false);
    }
    if (_skipFocusAvailable) {
      _skipControlFocus.requestFocus();
    } else {
      _playerRootFocus.requestFocus();
    }
  }

  void _handleSurfaceTap() {
    if (_engineHandoffInProgress) return;
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  void _handleSurfaceDoubleTap() {
    if (_engineHandoffInProgress) return;
    final details = _touchDoubleTapDetails;
    if (details == null || !mounted) return;
    final width = MediaQuery.sizeOf(context).width;
    final x = details.localPosition.dx;
    if (x < width / 3) {
      unawaited(_seekBy(Duration(seconds: -_seekBackSeconds)));
    } else if (x > width * 2 / 3) {
      unawaited(_seekBy(Duration(seconds: _seekForwardSeconds)));
    } else {
      _playOrPauseLocal();
    }
    _showControls();
  }

  Future<void> _confirmExit() async {
    if (_confirmingExit || _routePopScheduled || !mounted) return;
    if (_engineHandoffInProgress) {
      if (_handoffAttemptActive || !_handoffReleaseFailed) return;
      final navigator = Navigator.of(context);
      final position = _pendingHandoffPosition ?? Duration.zero;
      if (await _prepareForEngineHandoff(position)) {
        _popPlayerRouteAfterHandoff(navigator);
      }
      return;
    }
    _confirmingExit = true;
    // The HUD idle timer belongs to the player route, not the modal. If it
    // fires while the confirmation is open it hides the controls and requests
    // the video surface focus through the dialog on some Android TV devices.
    _controlsTimer?.cancel();
    final wasPlaying = _player.state.playing;
    final shouldTemporarilyPause = wasPlaying && !_guestControlsLocked;
    bool? exit;
    try {
      if (shouldTemporarilyPause) {
        // A decoder that is already failing may reject pause. Exiting must
        // remain reachable even in that state, so the dialog is independent
        // of a successful pause acknowledgement.
        try {
          await _player.pause();
        } catch (_) {}
      }
      if (!mounted) return;
      exit = await _withHudAutoHideSuspended(
        () => showPlayerExitConfirmation(context),
      );
    } catch (_) {
      // A transient route/dialog failure must not permanently consume Back.
      exit = false;
    } finally {
      _confirmingExit = false;
    }
    if (!mounted) return;
    if (exit == true) {
      final navigator = Navigator.of(context);
      final position = _effectiveHandoffPosition();
      _pendingHandoffPosition = position;
      if (await _prepareForEngineHandoff(position)) {
        _popPlayerRouteAfterHandoff(navigator);
      }
    } else {
      if (shouldTemporarilyPause) {
        try {
          await _player.play();
        } catch (_) {
          // Keep the player screen responsive if a broken decoder cannot resume.
        }
      }
      if (mounted) _showControls(focusControls: true);
    }
  }

  @override
  void dispose() {
    if (_diagnosticLastOutcome != PlaybackDiagnosticOutcome.failed &&
        _diagnosticLastOutcome != PlaybackDiagnosticOutcome.completed) {
      _recordDiagnosticOutcome(
        _reportedPlaybackSuccess
            ? PlaybackDiagnosticOutcome.exitedAfterStart
            : PlaybackDiagnosticOutcome.exitedBeforeStart,
      );
    }
    _watchPartyRouteHandoff.unbind(_watchPartyRouteHandoffOwner);
    _watchPartyPlayback.unbindEngine(_watchPartyHandle);
    if (_ownsWatchPartyPlayback) unawaited(_watchPartyPlayback.dispose());
    _skipLoadTimer?.cancel();
    _durationSubscription?.cancel();
    if (!_preserveNextEpisodePreparation && _catalogEpisodeNumber != null) {
      final request = _nextEpisodePreparationRequest();
      unawaited(
        _nextEpisodePreparation.abandon(
          request.mediaId,
          request.currentEpisode,
          currentRequest: request,
        ),
      );
    }
    if (!_engineHandoffInProgress && !_playerReleasedForHandoff) {
      unawaited(_persistPlayback(_effectiveHandoffPosition(), force: true));
      unawaited(_saveSeriesPreferences());
    }
    if (!_nativePlaybackStateClearedForHandoff) {
      unawaited(AndroidTvBridge.instance.clearMediaSession());
      unawaited(AndroidTvBridge.instance.clearPreferredFrameRate());
    }
    _controlsTimer?.cancel();
    _hiddenHudDpadSeek.dispose();
    _videoWatchdog?.cancel();
    _performanceWatchdog?.cancel();
    _seekPreviewTimer?.cancel();
    _trickplayGeneration++;
    if (!_engineHandoffInProgress) {
      _progressSubscription?.cancel();
      _tracksSubscription?.cancel();
      _errorSubscription?.cancel();
      _completedSubscription?.cancel();
      _videoParamsSubscription?.cancel();
      _playingSubscription?.cancel();
      _mediaActionSubscription?.cancel();
      _sourceDiscoverySubscription?.cancel();
    }
    // Unexpected route disposal does not pass through the awaited handoff
    // path. Close the mutation gate before releasing libmpv and join any
    // already-running async track callback inside the release coordinator.
    _engineHandoffInProgress = true;
    _playerRootFocus.dispose();
    _transportFocusScope.dispose();
    _playControlFocus.dispose();
    _progressControlFocus.dispose();
    _skipControlFocus.dispose();
    _watchTogetherFocus.dispose();
    _playbackSpeedFocus.dispose();
    if (!_playerReleasedForHandoff) {
      unawaited(
        _handoffRelease.release(() async {
          try {
            await _waitForPlayerMutations().timeout(
              _playerMutationReleaseTimeout,
            );
            final trickplayOperations = List<Future<void>>.of(
              _trickplayOperations,
            );
            if (trickplayOperations.isNotEmpty) {
              await Future.wait(trickplayOperations);
            }
          } catch (_) {
            // A failed command or screenshot is already terminal. Decoder
            // disposal remains authoritative during unexpected route teardown.
          }
          try {
            await _player.stop();
          } catch (_) {
            // dispose() is still authoritative for a failed decoder.
          }
          await _detachAndroidVideoOutputBeforeRelease();
          await _player.dispose();
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final watchPartyEnabled = ref.watch(
      settingsPreferencesProvider.select(
        (preferences) => preferences.showWatchTogether,
      ),
    );
    return PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_confirmExit());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _playerRootFocus,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleSurfaceTap,
            onDoubleTapDown: (details) => _touchDoubleTapDetails = details,
            onDoubleTap: _handleSurfaceDoubleTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!_engineHandoffInProgress)
                  Video(
                    controller: _controller,
                    controls: NoVideoControls,
                    fit: _videoFit,
                    subtitleViewConfiguration: SubtitleViewConfiguration(
                      style: TextStyle(
                        color: _captionTextColor,
                        fontSize: _subtitleSize,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(
                            color: Colors.black,
                            blurRadius: 5,
                            offset: Offset(2, 2),
                          ),
                        ],
                        backgroundColor: _highContrastSubtitles
                            ? const Color(0xDD000000)
                            : _captionBackgroundColor,
                      ),
                    ),
                  )
                else
                  const ColoredBox(
                    key: ValueKey('mpv-engine-handoff-shield'),
                    color: Colors.black,
                  ),
                if (!_engineHandoffInProgress)
                  StreamBuilder<bool>(
                    stream: _player.stream.buffering,
                    initialData: _player.state.buffering,
                    builder: (context, snapshot) {
                      if (snapshot.data != true) return const SizedBox.shrink();
                      return Center(
                        child: CircularProgressIndicator(
                          color: palette.secondaryAccent,
                        ),
                      );
                    },
                  ),
                if (!_engineHandoffInProgress)
                  Positioned(
                    left: 34,
                    right: 34,
                    top: 28,
                    child: StreamBuilder<bool>(
                      stream: _player.stream.playing,
                      initialData: _player.state.playing,
                      builder: (context, snapshot) {
                        if (snapshot.data == true) {
                          return const SizedBox.shrink();
                        }
                        return Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                shadows: const [
                                  Shadow(color: Colors.black, blurRadius: 12),
                                ],
                              ),
                        );
                      },
                    ),
                  ),
                if (!_engineHandoffInProgress)
                  ExcludeFocus(
                    excluding: !_controlsVisible,
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: FocusScope(
                          node: _transportFocusScope,
                          child: _UnifiedMpvPlayerChrome(
                            player: _player,
                            title: widget.title,
                            streamLabel:
                                _currentStream.providerName ??
                                '${widget.debridService.displayName} stream',
                            decoderMode: _decoderMode,
                            partyStatus: _watchPartyStatus,
                            watchingCount: _watchPartyWatchingCount,
                            playbackControlsLocked: _guestControlsLocked,
                            playFocusNode: _playControlFocus,
                            progressFocusNode: _progressControlFocus,
                            seekBackSeconds: _seekBackSeconds,
                            seekForwardSeconds: _seekForwardSeconds,
                            onSeek: _seekTo,
                            onSeekPreview:
                                supportsProvisionalSeekPreview(_currentStream)
                                ? (target) {
                                    unawaited(_seekTo(target));
                                  }
                                : null,
                            onRewind: () =>
                                _seekBy(Duration(seconds: -_seekBackSeconds)),
                            onPlayPause: _playOrPauseLocal,
                            onForward: () =>
                                _seekBy(Duration(seconds: _seekForwardSeconds)),
                            onPreviousEpisode: _hasPreviousEpisodeControl
                                ? () => unawaited(_playPreviousEpisode())
                                : null,
                            previousEpisodeEnabled:
                                _previousEpisodeControlEnabled,
                            onNextEpisode: _hasNextEpisodeControl
                                ? () => unawaited(_playNextEpisode())
                                : null,
                            nextEpisodeEnabled: _nextEpisodeControlEnabled,
                            onAudio: _openAudioTrackPicker,
                            onSubtitles: _openSubtitleTrackPicker,
                            onFit: _cycleFit,
                            playbackRate: _playbackRate,
                            onPlaybackSpeed: _openPlaybackSpeedPicker,
                            playbackSpeedFocusNode: _playbackSpeedFocus,
                            playbackSpeedEnabled: !_watchPartyActive,
                            onSources:
                                _animeFeaturesEnabled &&
                                    (_currentStream.isWebStream ||
                                        _currentStream.isDirectTorrent)
                                ? _openStreamSourcePicker
                                : null,
                            onWatchTogether: watchPartyEnabled
                                ? _openWatchParty
                                : null,
                            watchTogetherFocusNode: _watchTogetherFocus,
                            onInteraction: _handlePlayerHudInteraction,
                            onScrubInteractionChanged:
                                _handleProgressScrubInteraction,
                            onOptions: _openPlaybackMenu,
                            onDismiss: _hideControls,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!_guestControlsLocked && _canSkipNow && _activeSkip != null)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    right: MediaQuery.sizeOf(context).width < 720 ? 18 : 38,
                    bottom: playerSkipOverlayBottomInset(
                      viewport: MediaQuery.sizeOf(context),
                      controlsVisible: _controlsVisible,
                      safeAreaBottom: MediaQuery.paddingOf(context).bottom,
                      textScaleFactor: MediaQuery.textScalerOf(
                        context,
                      ).scale(1),
                      expandedHeader:
                          _watchPartyStatus != null ||
                          _watchPartyWatchingCount != null,
                    ),
                    child: TetoSkipSegmentOverlay(
                      focusNode: _skipControlFocus,
                      label: _activeSkip!.actionLabel,
                      onPressed: () {
                        _handlePlayerHudInteraction();
                        unawaited(_skipCurrentSegment());
                      },
                    ),
                  ),
                if (_playbackError case final error?)
                  Positioned(
                    left: 34,
                    right: 34,
                    bottom: 110,
                    child: _PlaybackError(
                      message: error,
                      controlsLocked: _guestControlsLocked,
                      onRetry: () => unawaited(_retryCurrentStream()),
                      onNextStream: _animeFeaturesEnabled
                          ? () => unawaited(
                              _tryNextStream(
                                'Selected after failure',
                                notify: false,
                              ),
                            )
                          : null,
                      onChooseStream: () => unawaited(_returnToStreamPicker()),
                    ),
                  ),
                if (_trackMessage case final message?)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: palette.playerSurface(
                          defaultColor: const Color(0xEE0A0A0A),
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        message,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                if (_seekPreview case final preview?)
                  Positioned(
                    left: playerSeekPreviewLeft(
                      viewportWidth: MediaQuery.sizeOf(context).width,
                      position: _seekPreviewPosition ?? Duration.zero,
                      duration: _player.state.duration,
                    ),
                    bottom: playerSeekPreviewBottom(
                      viewportWidth: MediaQuery.sizeOf(context).width,
                      viewportHeight: MediaQuery.sizeOf(context).height,
                    ),
                    child: Container(
                      width: 210,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: palette.playerSurface(
                          defaultColor: Colors.black,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: palette.accentBright),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Image.memory(
                              preview,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _formatPlayerDuration(
                              _seekPreviewPosition ?? Duration.zero,
                            ),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
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
}

class _UnifiedMpvPlayerChrome extends StatelessWidget {
  const _UnifiedMpvPlayerChrome({
    required this.player,
    required this.title,
    required this.streamLabel,
    required this.decoderMode,
    this.partyStatus,
    this.watchingCount,
    required this.playbackControlsLocked,
    required this.playFocusNode,
    required this.progressFocusNode,
    required this.seekBackSeconds,
    required this.seekForwardSeconds,
    required this.onSeek,
    this.onSeekPreview,
    required this.onRewind,
    required this.onPlayPause,
    required this.onForward,
    this.onPreviousEpisode,
    this.previousEpisodeEnabled = true,
    this.onNextEpisode,
    this.nextEpisodeEnabled = true,
    required this.onAudio,
    required this.onSubtitles,
    required this.onFit,
    required this.playbackRate,
    required this.onPlaybackSpeed,
    required this.playbackSpeedFocusNode,
    required this.playbackSpeedEnabled,
    this.onSources,
    this.onWatchTogether,
    required this.watchTogetherFocusNode,
    required this.onInteraction,
    required this.onScrubInteractionChanged,
    required this.onOptions,
    required this.onDismiss,
  });

  final Player player;
  final String title;
  final String streamLabel;
  final PlaybackDecoderMode decoderMode;
  final String? partyStatus;
  final int? watchingCount;
  final bool playbackControlsLocked;
  final FocusNode playFocusNode;
  final FocusNode progressFocusNode;
  final int seekBackSeconds;
  final int seekForwardSeconds;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration>? onSeekPreview;
  final VoidCallback onRewind;
  final VoidCallback onPlayPause;
  final VoidCallback onForward;
  final VoidCallback? onPreviousEpisode;
  final bool previousEpisodeEnabled;
  final VoidCallback? onNextEpisode;
  final bool nextEpisodeEnabled;
  final VoidCallback onAudio;
  final VoidCallback onSubtitles;
  final VoidCallback onFit;
  final double playbackRate;
  final VoidCallback onPlaybackSpeed;
  final FocusNode playbackSpeedFocusNode;
  final bool playbackSpeedEnabled;
  final VoidCallback? onSources;
  final VoidCallback? onWatchTogether;
  final FocusNode watchTogetherFocusNode;
  final VoidCallback onInteraction;
  final ValueChanged<bool> onScrubInteractionChanged;
  final VoidCallback onOptions;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, positionSnapshot) => StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: player.state.duration,
        builder: (context, durationSnapshot) => StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, playingSnapshot) => TetoPlayerChrome(
            engineKey: 'mpv',
            engineLabel: 'MPV - ${playbackDecoderLabel(decoderMode)}',
            partyStatus: partyStatus,
            watchingCount: watchingCount,
            playbackControlsLocked: playbackControlsLocked,
            title: title,
            streamLabel: streamLabel,
            position: positionSnapshot.data ?? Duration.zero,
            duration: durationSnapshot.data ?? Duration.zero,
            isPlaying: playingSnapshot.data ?? false,
            playFocusNode: playFocusNode,
            progressFocusNode: progressFocusNode,
            seekBackSeconds: seekBackSeconds,
            seekForwardSeconds: seekForwardSeconds,
            onSeek: onSeek,
            onSeekPreview: onSeekPreview,
            onRewind: onRewind,
            onPlayPause: onPlayPause,
            onForward: onForward,
            onPreviousEpisode: onPreviousEpisode,
            previousEpisodeEnabled: previousEpisodeEnabled,
            onNextEpisode: onNextEpisode,
            nextEpisodeEnabled: nextEpisodeEnabled,
            onAudio: onAudio,
            onSubtitles: onSubtitles,
            onPicture: onFit,
            onPlaybackSpeed: onPlaybackSpeed,
            playbackSpeed: playbackRate,
            playbackSpeedFocusNode: playbackSpeedFocusNode,
            playbackSpeedEnabled: playbackSpeedEnabled,
            onSources: onSources,
            onWatchTogether: onWatchTogether,
            watchTogetherFocusNode: watchTogetherFocusNode,
            onInteraction: onInteraction,
            onScrubInteractionChanged: onScrubInteractionChanged,
            onOptions: onOptions,
            onDismiss: onDismiss,
          ),
        ),
      ),
    );
  }
}

class _PlaybackOptionsDialog extends StatelessWidget {
  const _PlaybackOptionsDialog({
    required this.decoderMode,
    required this.videoFit,
    required this.playbackRate,
    required this.playbackSpeedEnabled,
    required this.subtitleSize,
    required this.subtitlePosition,
    required this.subtitleDelayMs,
    required this.audioDelayMs,
    required this.highContrastSubtitles,
    required this.hasAlternateStreams,
    required this.hasDirectSources,
    required this.canOpenExternally,
  });

  final PlaybackDecoderMode decoderMode;
  final BoxFit videoFit;
  final double playbackRate;
  final bool playbackSpeedEnabled;
  final double subtitleSize;
  final int subtitlePosition;
  final int subtitleDelayMs;
  final int audioDelayMs;
  final bool highContrastSubtitles;
  final bool hasAlternateStreams;
  final bool hasDirectSources;
  final bool canOpenExternally;

  void _close(BuildContext context, String type, Object value) {
    Navigator.of(context).pop<_PlaybackMenuResult>((type: type, value: value));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 900),
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: palette.playerSurface(),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.accent.withValues(alpha: .55)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune_rounded, color: palette.accentBright),
                    const SizedBox(width: 9),
                    Text(
                      'Playback options',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Spacer(),
                    Text(
                      'Changes apply immediately',
                      style: TextStyle(color: palette.mutedText, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _OptionSection(
                  title: 'DECODER',
                  children: [
                    for (final mode in PlaybackDecoderMode.values)
                      _OptionChip(
                        label: playbackDecoderLabel(mode),
                        selected: decoderMode == mode,
                        autofocus: decoderMode == mode,
                        onPressed: () => _close(context, 'decoder', mode),
                      ),
                    _OptionChip(
                      label: 'Restart stream',
                      icon: Icons.refresh_rounded,
                      onPressed: () => _close(context, 'retry', true),
                    ),
                    if (hasAlternateStreams)
                      _OptionChip(
                        label: 'Try next stream',
                        icon: Icons.swap_horiz_rounded,
                        onPressed: () => _close(context, 'nextStream', true),
                      ),
                    if (hasDirectSources)
                      _OptionChip(
                        label: 'Sources & quality',
                        icon: Icons.video_library_rounded,
                        onPressed: () => _close(context, 'sources', true),
                      ),
                    if (canOpenExternally)
                      _OptionChip(
                        label: 'Open externally',
                        icon: Icons.open_in_new_rounded,
                        onPressed: () => _close(context, 'external', true),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _OptionSection(
                  title: 'PICTURE',
                  children: [
                    _OptionChip(
                      label: 'Fit',
                      selected: videoFit == BoxFit.contain,
                      onPressed: () => _close(context, 'fit', BoxFit.contain),
                    ),
                    _OptionChip(
                      label: 'Fill screen',
                      selected: videoFit == BoxFit.cover,
                      onPressed: () => _close(context, 'fit', BoxFit.cover),
                    ),
                    _OptionChip(
                      label: 'Stretch',
                      selected: videoFit == BoxFit.fill,
                      onPressed: () => _close(context, 'fit', BoxFit.fill),
                    ),
                  ],
                ),
                if (playbackSpeedEnabled) ...[
                  const SizedBox(height: 12),
                  _OptionSection(
                    title: 'SPEED',
                    children: [
                      for (final rate in playerPlaybackSpeedValues)
                        _OptionChip(
                          label: playerPlaybackSpeedLabel(rate),
                          selected: playbackRate == rate,
                          onPressed: () => _close(context, 'rate', rate),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                _OptionSection(
                  title: 'SUBTITLE SIZE',
                  children: [
                    for (final size in const [28.0, 34.0, 42.0, 50.0])
                      _OptionChip(
                        label: switch (size) {
                          28 => 'Small',
                          34 => 'Medium',
                          42 => 'Large',
                          _ => 'Extra large',
                        },
                        selected: subtitleSize == size,
                        onPressed: () => _close(context, 'subtitleSize', size),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _OptionSection(
                  title: 'SUBTITLE STYLE',
                  children: [
                    for (final position in const [78, 90, 100])
                      _OptionChip(
                        label: switch (position) {
                          78 => 'Higher',
                          90 => 'Raised',
                          _ => 'Bottom',
                        },
                        selected: subtitlePosition == position,
                        onPressed: () =>
                            _close(context, 'subtitlePosition', position),
                      ),
                    _OptionChip(
                      label: highContrastSubtitles
                          ? 'High contrast on'
                          : 'High contrast off',
                      selected: highContrastSubtitles,
                      onPressed: () =>
                          _close(context, 'contrast', !highContrastSubtitles),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _OptionSection(
                  title: 'SYNC',
                  children: [
                    for (final delay in const [-500, -250, 0, 250, 500])
                      _OptionChip(
                        label: 'Subs ${delay > 0 ? '+' : ''}${delay}ms',
                        selected: subtitleDelayMs == delay,
                        onPressed: () =>
                            _close(context, 'subtitleDelay', delay),
                      ),
                    for (final delay in const [-250, 0, 250])
                      _OptionChip(
                        label: 'Audio ${delay > 0 ? '+' : ''}${delay}ms',
                        selected: audioDelayMs == delay,
                        onPressed: () => _close(context, 'audioDelay', delay),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionSection extends StatelessWidget {
  const _OptionSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final label = Text(
          title,
          style: TextStyle(
            color: palette.mutedText,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.1,
          ),
        );
        final options = Wrap(spacing: 7, runSpacing: 7, children: children);
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [label, const SizedBox(height: 7), options],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 112, child: label),
            Expanded(child: options),
          ],
        );
      },
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.onPressed,
    this.icon,
    this.selected = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool selected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final foreground = selected
        ? palette.playerPrimaryActionText()
        : palette.playerPrimaryText();
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      focusScale: 1.025,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        color: selected ? palette.accent : palette.playerSelectableSurface(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final value?) ...[
              Icon(value, size: 16),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({
    required this.message,
    required this.controlsLocked,
    required this.onRetry,
    required this.onNextStream,
    required this.onChooseStream,
  });

  final String message;
  final bool controlsLocked;
  final VoidCallback onRetry;
  final VoidCallback? onNextStream;
  final VoidCallback onChooseStream;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final errorAccent = palette.usesDefaultPlayerPalette
        ? const Color(0xFFFF929B)
        : palette.accentBright;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        decoration: BoxDecoration(
          color: palette.playerRaisedSurface(
            defaultColor: const Color(0xEE391D29),
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: errorAccent),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded, color: errorAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (controlsLocked)
              Text(
                'The host controls playback. Open Watch Party or Exit.',
                style: TextStyle(color: palette.mutedText),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _RecoveryAction(
                    label: 'Retry stream',
                    icon: Icons.refresh_rounded,
                    primary: true,
                    onPressed: onRetry,
                  ),
                  if (onNextStream case final callback?)
                    _RecoveryAction(
                      label: 'Next stream',
                      icon: Icons.skip_next_rounded,
                      onPressed: callback,
                    ),
                  _RecoveryAction(
                    label: 'Choose stream',
                    icon: Icons.list_rounded,
                    onPressed: onChooseStream,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryAction extends StatelessWidget {
  const _RecoveryAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final foreground = primary
        ? palette.playerPrimaryActionText()
        : palette.playerPrimaryText();
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: primary
              ? palette.accent
              : palette.playerSelectableSurface(
                  defaultColor: const Color(0xFF202026),
                ),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: palette.playerPrimaryText().withValues(alpha: .12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: foreground),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DebridOnlyPlaybackScreen extends StatelessWidget {
  const DebridOnlyPlaybackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      backgroundColor: palette.playerBackground(),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 68, color: palette.secondaryAccent),
            const SizedBox(height: 18),
            const Text(
              'Playback blocked',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 620,
              child: Text(
                'TetoTV only accepts streams resolved through a connected '
                'supported debrid account.',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.mutedText, fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
