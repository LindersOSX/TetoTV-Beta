import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/player/application/library_playback_proxy.dart';
import 'package:anime_tv/features/player/application/library_playback_session.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

/// Full-screen playback for local files and private Plex/Jellyfin libraries.
///
/// This typed route deliberately accepts private playback only through a
/// [LibraryPlaybackRequest]. A request opened from the unified catalog may
/// carry a sanitized public episode identity for Previous/Next and skip timing,
/// while tracker progress, AniList checkpoints, and private source details
/// remain outside that capability.
class LibraryTvPlayerScreen extends StatefulWidget {
  const LibraryTvPlayerScreen({
    required this.request,
    this.playbackProxy = const LibraryPlaybackProxy(),
    this.onPlaybackFinished,
    this.autoCloseOnPreparationFailure = false,
    super.key,
  });

  final LibraryPlaybackRequest request;
  final LibraryPlaybackProxy playbackProxy;
  final ValueChanged<LibraryPlaybackResult>? onPlaybackFinished;
  final bool autoCloseOnPreparationFailure;

  @override
  State<LibraryTvPlayerScreen> createState() => _LibraryTvPlayerScreenState();
}

class _LibraryTvPlayerScreenState extends State<LibraryTvPlayerScreen> {
  late Future<_PreparedLibraryPlayback?> _preparation;
  late LibraryPlaybackRequest _currentRequest;
  _PreparedLibraryPlayback? _active;
  int _preparationRevision = 0;
  int? _reportedPreparationFailureRevision;

  @override
  void initState() {
    super.initState();
    _currentRequest = widget.request;
    _beginPreparation();
  }

  @override
  void didUpdateWidget(covariant LibraryTvPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.request, widget.request) &&
        identical(oldWidget.playbackProxy, widget.playbackProxy)) {
      return;
    }
    _finishActive();
    _currentRequest = widget.request;
    _beginPreparation();
  }

  @override
  void dispose() {
    _preparationRevision++;
    _finishActive();
    super.dispose();
  }

  void _beginPreparation() {
    final revision = ++_preparationRevision;
    _preparation = _prepare(_currentRequest, widget.playbackProxy, revision);
  }

  Future<bool> _adoptPreparedNextEpisode(LibraryPlaybackRequest request) async {
    if (!mounted) return false;
    _finishActive();
    setState(() {
      _currentRequest = request;
      _beginPreparation();
    });
    return true;
  }

  Future<_PreparedLibraryPlayback?> _prepare(
    LibraryPlaybackRequest request,
    LibraryPlaybackProxy playbackProxy,
    int revision,
  ) async {
    late final LibraryPlaybackRequest protected;
    try {
      protected = await playbackProxy.protect(request);
    } catch (_) {
      if (mounted && revision == _preparationRevision) {
        _reportPreparationFailure(request, revision);
      }
      rethrow;
    }
    if (!mounted || revision != _preparationRevision) {
      await protected.playbackLease?.close();
      return null;
    }
    final prepared = _PreparedLibraryPlayback(
      request: protected,
      session: LibraryPlaybackSession(protected),
    );
    _active = prepared;
    return prepared;
  }

  void _reportPreparationFailure(LibraryPlaybackRequest request, int revision) {
    if (_reportedPreparationFailureRevision == revision) return;
    _reportedPreparationFailureRevision = revision;
    final result = LibraryPlaybackResult(
      position: request.initialPosition,
      duration: Duration.zero,
      reason: LibraryPlaybackEndReason.failed,
      started: false,
      error: 'Private media could not be prepared safely.',
      failureStage: LibraryPlaybackFailureStage.preparation,
    );
    final callback = widget.onPlaybackFinished;
    if (callback != null) {
      try {
        callback(result);
      } catch (_) {
        // Route observers cannot change the safe preparation error state.
      }
    }
    if (!widget.autoCloseOnPreparationFailure) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _preparationRevision) return;
      unawaited(Navigator.of(context).maybePop());
    });
  }

  void _finishActive() {
    final active = _active;
    _active = null;
    if (active == null) return;
    final callback = widget.onPlaybackFinished;
    unawaited(
      active.session.finish(onResult: callback).whenComplete(() async {
        await active.request.playbackLease?.close();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _finishActive();
      },
      child: FutureBuilder<_PreparedLibraryPlayback?>(
        future: _preparation,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _LibraryPlaybackPreparationError(
              onBack: () => Navigator.of(context).maybePop(),
            );
          }
          final prepared = snapshot.data;
          if (prepared == null) return const _LibraryPlaybackPreparing();
          final request = prepared.request;
          final launch = libraryPlaybackLaunchForRequest(request);
          return TvPlayerScreen(
            key: ValueKey('library-player-${request.checkpointKey}'),
            source: request.source.toString(),
            title: request.title,
            // Library mode never invokes a debrid resolver. This value exists
            // only for the legacy anime-player constructor while the typed
            // session is the authoritative capability boundary.
            debridService: DebridService.realDebrid,
            launch: launch,
            subtitle: request.externalSubtitle,
            coverImageUrl: request.artworkUrl,
            libraryPlayback: prepared.session,
            onLibraryEpisodeHandoff: _adoptPreparedNextEpisode,
          );
        },
      ),
    );
  }
}

class _PreparedLibraryPlayback {
  const _PreparedLibraryPlayback({
    required this.request,
    required this.session,
  });

  final LibraryPlaybackRequest request;
  final LibraryPlaybackSession session;
}

class _LibraryPlaybackPreparing extends StatelessWidget {
  const _LibraryPlaybackPreparing();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: CircularProgressIndicator()),
  );
}

class _LibraryPlaybackPreparationError extends StatelessWidget {
  const _LibraryPlaybackPreparationError({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Private media could not be prepared safely.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 24),
          FilledButton(
            autofocus: true,
            onPressed: onBack,
            child: const Text('Go back'),
          ),
        ],
      ),
    ),
  );
}

@visibleForTesting
PlaybackLaunch libraryPlaybackLaunchForRequest(LibraryPlaybackRequest request) {
  final publicIdentity = request.watchPartyIdentity;
  final digest = sha256
      .convert(
        utf8.encode(
          'tetotv-library-launch-v1\u001f${request.timelineIdentity}',
        ),
      )
      .toString();
  final stream = StreamReady(
    uri: request.source,
    displayName: request.releaseName,
    headers: request.headers,
    externalSubtitle: request.externalSubtitle == null
        ? null
        : Uri.tryParse(request.externalSubtitle!),
    mediaContentType: request.mediaContentType,
    subtitleContentType: request.subtitleContentType,
    playbackLease: request.playbackLease,
    providerId: request.sourceProviderId,
    providerName: request.sourceProviderName,
  );
  return PlaybackLaunch(
    stream: stream,
    episode: EpisodeReference(
      anilistMediaId: publicIdentity?.anilistMediaId ?? 0,
      title: publicIdentity?.title ?? request.title,
      episode: publicIdentity?.episode ?? 1,
      episodeCount: publicIdentity?.episodeCount,
      coverImageUrl: request.artworkUrl,
      startFromBeginning: true,
    ),
    selectedRelease: ReleaseCandidate(
      infoHash: digest,
      magnetUri: '',
      releaseName: request.releaseName,
      seeders: 0,
      sourceId: request.sourceProviderId,
      provider: request.sourceProviderName,
    ),
    requestedAudio: request.requestedAudio,
  );
}
