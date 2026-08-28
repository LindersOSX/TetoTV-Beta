import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/local_media/application/local_media_controller.dart';
import 'package:anime_tv/features/local_media/application/plex_controller.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final libraryEpisodeSourceServiceProvider = Provider<LibraryEpisodeSourceService>(
  (ref) => LibraryEpisodeSourceService(
    ref.read(localMediaControllerProvider.notifier),
    ref.read(plexControllerProvider.notifier),
    () =>
        ref.read(localMediaControllerProvider).loaded &&
        ref.read(plexControllerProvider).loaded,
    () => ref.read(localMediaControllerProvider).connection != null,
    () => ref.read(plexControllerProvider).connection != null,
    () {
      final connection = ref.read(localMediaControllerProvider).connection;
      return connection == null
          ? ''
          : '${connection.baseUri}\u001f${connection.userId}';
    },
    () {
      final connection = ref.read(plexControllerProvider).connection;
      return connection == null
          ? ''
          : '${connection.baseUri}\u001f${connection.machineIdentifier ?? ''}';
    },
  ),
);

class LibraryEpisodeSearchResult {
  const LibraryEpisodeSearchResult({
    required this.sources,
    this.unavailableServers = const [],
  });

  final List<LibraryEpisodeSource> sources;
  final List<String> unavailableServers;
}

/// Bridges connected private libraries into the ordinary episode picker.
///
/// Searches send only bounded title strings to the viewer's own server. Public
/// catalog IDs, tracking state and stream credentials never cross this layer.
class LibraryEpisodeSourceService {
  const LibraryEpisodeSourceService(
    this._localMedia,
    this._plex,
    this._connectionsLoaded,
    this._jellyfinConnected,
    this._plexConnected,
    this._jellyfinScope,
    this._plexScope,
  );

  final LocalMediaController _localMedia;
  final PlexController _plex;
  final bool Function() _connectionsLoaded;
  final bool Function() _jellyfinConnected;
  final bool Function() _plexConnected;
  final String Function() _jellyfinScope;
  final String Function() _plexScope;

  /// True when at least one private source can be searched without opening a
  /// picker. Persisted device documents count only as candidates;
  /// [watchSearch] still requires an exact title-and-episode filename match.
  bool get hasConnectedServer =>
      _jellyfinConnected() ||
      _plexConnected() ||
      _localDocuments().any(isSafeLocalVideoDocument);

  Future<void> loadConnections() async {
    if (_connectionsLoaded()) return;
    await Future.wait([_localMedia.load(), _plex.load()]);
  }

  Future<LibraryEpisodeSearchResult> search(EpisodeReference episode) async {
    var latest = const LibraryEpisodeSearchResult(sources: []);
    await for (final result in watchSearch(episode)) {
      latest = result;
    }
    return latest;
  }

  /// Emits a cumulative, deterministically sorted snapshot whenever one media
  /// server completes. A sleeping Plex server therefore cannot hide an exact
  /// Jellyfin match (or vice versa) while the other request is still pending.
  Stream<LibraryEpisodeSearchResult> watchSearch(
    EpisodeReference episode,
  ) async* {
    final sources = <String, LibraryEpisodeSource>{};
    final unavailable = <String>{};
    final controller = StreamController<LibraryEpisodeSearchResult>();

    void emit() {
      final sorted = sources.values.toList(growable: false)
        ..sort((left, right) {
          final origin = left.origin.index.compareTo(right.origin.index);
          if (origin != 0) return origin;
          final title = left.title.toLowerCase().compareTo(
            right.title.toLowerCase(),
          );
          return title != 0 ? title : left.stableKey.compareTo(right.stableKey);
        });
      controller.add(
        LibraryEpisodeSearchResult(
          sources: List.unmodifiable(sorted),
          unavailableServers: List.unmodifiable(unavailable.toList()..sort()),
        ),
      );
    }

    final tasks = <Future<void>>[];
    for (final document in _localDocuments()) {
      if (!localDocumentMatchesEpisode(document: document, episode: episode)) {
        continue;
      }
      final source = LibraryEpisodeSource.device(
        document: document,
        episode: episode,
        stableKey: 'device:${_localMedia.checkpointId(document.uri)}',
      );
      sources.putIfAbsent(source.stableKey, () => source);
    }
    if (_jellyfinConnected()) {
      tasks.add(
        _localMedia
            .findEpisodeMatches(episode)
            .then<void>((items) {
              for (final item in items) {
                if (!jellyfinItemMatchesEpisode(item: item, episode: episode)) {
                  continue;
                }
                final source = LibraryEpisodeSource.jellyfin(item);
                if (!source.isPlayableCandidate) continue;
                sources.putIfAbsent(source.stableKey, () => source);
              }
              emit();
            })
            .onError((_, _) {
              unavailable.add('Jellyfin');
              emit();
            }),
      );
    }
    if (_plexConnected()) {
      tasks.add(
        _plex
            .findEpisodeMatches(episode)
            .then<void>((items) {
              for (final item in items) {
                if (!plexItemMatchesEpisode(item: item, episode: episode)) {
                  continue;
                }
                final source = LibraryEpisodeSource.plex(item);
                if (!source.isPlayableCandidate) continue;
                sources.putIfAbsent(source.stableKey, () => source);
              }
              emit();
            })
            .onError((_, _) {
              unavailable.add('Plex');
              emit();
            }),
      );
    }
    if (tasks.isEmpty) {
      final localSources = sources.values.toList(growable: false);
      yield LibraryEpisodeSearchResult(sources: localSources);
      unawaited(controller.close());
      return;
    }
    if (sources.isNotEmpty) emit();
    unawaited(Future.wait(tasks).whenComplete(controller.close));
    yield* controller.stream;
  }

  Future<LibraryPlaybackRequest> preparePlayback(
    LibraryEpisodeSource source, {
    LibraryWatchPartyIdentity? watchPartyIdentity,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
    bool forceCompatibility = false,
  }) async {
    if (!source.isPlayableCandidate) {
      throw StateError(
        'The private-library episode is not currently playable.',
      );
    }
    final localDocument = source.localDocument;
    if (localDocument != null) {
      if (forceCompatibility) {
        throw StateError(
          'A local device file has no media-server compatibility stream.',
        );
      }
      return prepareLocalVideo(
        localDocument,
        watchPartyIdentity: watchPartyIdentity,
        requestedAudio: requestedAudio,
      );
    }
    final jellyfin = source.jellyfinItem;
    if (jellyfin != null) {
      final sessionId = _localMedia.createPlaybackSessionId();
      final plan = forceCompatibility
          ? _localMedia.compatibilityPlaybackPlan(
              jellyfin,
              playSessionId: sessionId,
              preferredSubtitleLanguage: preferredSubtitleLanguage,
              requestedAudio: requestedAudio,
            )
          : _localMedia.playbackPlan(
              jellyfin,
              playSessionId: sessionId,
              preferredSubtitleLanguage: preferredSubtitleLanguage,
              requestedAudio: requestedAudio,
            );
      final identity = _digest(
        'jellyfin\u001f${_jellyfinScope()}\u001f${source.stableKey}',
      );
      var resume = await _localMedia.resumePosition(_checkpointUri(identity));
      final serverResume = _localMedia.serverResumePosition(jellyfin);
      if (serverResume > resume) resume = serverResume;
      final writeback = _LibrarySourceWriteback(
        saveLocal: (position) =>
            _localMedia.saveResumePosition(_checkpointUri(identity), position),
        writeServer: (position, paused) => _localMedia.reportPlaybackProgress(
          jellyfin,
          playSessionId: sessionId,
          position: position,
          paused: paused,
          playMethod: plan.method,
        ),
      );
      return LibraryPlaybackRequest(
        source: plan.uri,
        title: jellyfin.displayTitle,
        releaseName: jellyfin.seriesName?.isNotEmpty == true
            ? '${jellyfin.seriesName} — ${jellyfin.displayTitle}'
            : jellyfin.displayTitle,
        streamLabel:
            'Jellyfin • ${jellyfin.secondaryLabel}'
            '${plan.isTranscode ? ' • compatibility stream' : ''}',
        sourceProviderId: source.providerId,
        sourceProviderName: source.providerName,
        checkpointKey: 'local:$identity',
        timelineIdentity: identity,
        headers: plan.headers,
        artworkUrl: _localMedia.imageUri(jellyfin)?.toString(),
        externalSubtitle: plan.externalSubtitleUri?.toString(),
        externalSubtitleTracks: plan.externalSubtitleTracks
            .map(
              (track) => LibraryExternalSubtitleTrack(
                uri: track.uri,
                label: track.label,
                language: track.language,
                contentType: track.contentType,
              ),
            )
            .toList(growable: false),
        mediaContentType: plan.mediaContentType,
        subtitleContentType: plan.subtitleContentType,
        initialPosition: resume,
        requestedAudio: requestedAudio,
        onStarted: (position) => _localMedia.reportPlaybackStarted(
          jellyfin,
          playSessionId: sessionId,
          position: position,
          playMethod: plan.method,
        ),
        onProgress: writeback.handle,
        onFinished: (result) async {
          if (result.completed) {
            await _localMedia.clearResumePosition(_checkpointUri(identity));
          } else {
            await _localMedia.saveResumePosition(
              _checkpointUri(identity),
              result.position,
            );
          }
          if (result.started) {
            await _localMedia.reportPlaybackStopped(
              jellyfin,
              playSessionId: sessionId,
              position: result.position,
              playMethod: plan.method,
            );
          }
        },
        isCompatibilityStream: plan.isTranscode,
        watchPartyIdentity: watchPartyIdentity,
      );
    }

    final plexItem = source.plexItem;
    if (plexItem == null) {
      throw StateError('The private-library source is no longer available.');
    }
    final playable = await _plex.preparePlayableItem(plexItem);
    final sessionId = _localMedia.createPlaybackSessionId();
    final uri = forceCompatibility
        ? _plex.compatibilityPlaybackUri(playable, sessionId: sessionId)
        : _plex.playbackUri(playable);
    final identity = _digest(
      'plex\u001f${_plexScope()}\u001f${source.stableKey}',
    );
    var resume = await _localMedia.resumePosition(_checkpointUri(identity));
    final serverResume = _plex.serverResumePosition(playable);
    if (serverResume > resume) resume = serverResume;
    final writeback = _LibrarySourceWriteback(
      saveLocal: (position) =>
          _localMedia.saveResumePosition(_checkpointUri(identity), position),
      writeServer: (position, paused) =>
          _plex.reportTimeline(playable, position: position, playing: !paused),
    );
    final series = playable.grandparentTitle?.trim();
    return LibraryPlaybackRequest(
      source: uri,
      title: playable.displayTitle,
      releaseName: series?.isNotEmpty == true
          ? '$series — ${playable.displayTitle}'
          : playable.displayTitle,
      streamLabel:
          'Plex • ${playable.secondaryLabel}'
          '${forceCompatibility ? ' • compatibility stream' : ''}',
      sourceProviderId: source.providerId,
      sourceProviderName: source.providerName,
      checkpointKey: 'local:$identity',
      timelineIdentity: identity,
      headers: _plex.playbackHeaders(),
      artworkUrl: _plex.imageUri(playable)?.toString(),
      initialPosition: resume,
      requestedAudio: requestedAudio,
      onStarted: (position) =>
          _plex.reportTimeline(playable, position: position, playing: true),
      onProgress: writeback.handle,
      onFinished: (result) async {
        if (result.completed) {
          await _localMedia.clearResumePosition(_checkpointUri(identity));
        } else {
          await _localMedia.saveResumePosition(
            _checkpointUri(identity),
            result.position,
          );
        }
        if (result.started) {
          await _plex.reportTimeline(
            playable,
            position: result.position,
            playing: false,
          );
        }
      },
      isCompatibilityStream: forceCompatibility,
      watchPartyIdentity: watchPartyIdentity,
    );
  }

  /// Opens Android's Storage Access Framework and prepares the selected file
  /// without exposing its content URI or filename to Watch Together.
  Future<LibraryPlaybackRequest?> chooseLocalVideo({
    LibraryWatchPartyIdentity? watchPartyIdentity,
    PlaybackAudioPreference? requestedAudio,
  }) async {
    final document = await _localMedia.pickLocalVideo();
    if (document == null) return null;
    return prepareLocalVideo(
      document,
      watchPartyIdentity: watchPartyIdentity,
      requestedAudio: requestedAudio,
    );
  }

  Future<LibraryPlaybackRequest> prepareLocalVideo(
    LocalMediaDocument document, {
    LibraryWatchPartyIdentity? watchPartyIdentity,
    PlaybackAudioPreference? requestedAudio,
  }) async {
    final checkpointId = _localMedia.checkpointId(document.uri);
    final resume = await _localMedia.resumePosition(document.uri);
    final writeback = _LibrarySourceWriteback(
      saveLocal: (position) =>
          _localMedia.saveResumePosition(document.uri, position),
    );
    return LibraryPlaybackRequest(
      source: document.uri,
      title: document.name,
      releaseName: document.name,
      streamLabel: 'Local device media',
      sourceProviderId: 'library-device',
      sourceProviderName: 'Local device',
      checkpointKey: 'local:$checkpointId',
      timelineIdentity: checkpointId,
      mediaContentType: document.mimeType,
      initialPosition: resume,
      requestedAudio: requestedAudio,
      onProgress: writeback.handle,
      onFinished: (result) async {
        if (result.completed) {
          await _localMedia.clearResumePosition(document.uri);
        } else {
          await _localMedia.saveResumePosition(document.uri, result.position);
        }
      },
      watchPartyIdentity: watchPartyIdentity,
    );
  }

  List<LocalMediaDocument> _localDocuments() {
    try {
      final documents = _localMedia.localDocuments;
      if (documents.isNotEmpty) return documents;
    } catch (_) {
      // Older lightweight test doubles fall back to the recent getter below.
    }
    try {
      final recent = _localMedia.recentLocalDocument;
      return recent == null ? const [] : [recent];
    } catch (_) {
      // Lightweight test doubles and damaged saved documents fail closed.
      return const [];
    }
  }
}

class _LibrarySourceWriteback {
  _LibrarySourceWriteback({required this.saveLocal, this.writeServer});

  static const _interval = Duration(seconds: 10);

  final Future<void> Function(Duration position) saveLocal;
  final Future<void> Function(Duration position, bool paused)? writeServer;
  DateTime? _lastWrittenAt;
  bool? _lastPlaying;

  Future<void> handle(LibraryPlaybackProgress progress) async {
    final stateChanged = _lastPlaying != progress.playing;
    final elapsed = _lastWrittenAt == null
        ? null
        : progress.sampledAt.difference(_lastWrittenAt!);
    if (!stateChanged &&
        elapsed != null &&
        !elapsed.isNegative &&
        elapsed < _interval) {
      return;
    }
    _lastWrittenAt = progress.sampledAt;
    _lastPlaying = progress.playing;
    await Future.wait<void>([
      saveLocal(progress.position),
      if (writeServer case final callback?)
        callback(progress.position, !progress.playing),
    ]);
  }
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

Uri _checkpointUri(String identity) =>
    Uri(scheme: 'tetotv-library', host: 'checkpoint', path: '/$identity');
