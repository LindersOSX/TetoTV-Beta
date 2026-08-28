import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

abstract interface class DirectTorrentPlatformClient {
  Future<DirectTorrentCapability> capability();

  Future<DirectTorrentNativeSession> start({
    required String requestId,
    required String magnet,
    required int episode,
    int? season,
    int? preferredFileIndex,
  });

  Future<bool> cancelStart(String requestId);

  Future<bool> stop(String sessionId);
}

class AndroidDirectTorrentPlatformClient
    implements DirectTorrentPlatformClient {
  const AndroidDirectTorrentPlatformClient();

  @override
  Future<DirectTorrentCapability> capability() =>
      AndroidTvBridge.instance.getDirectTorrentCapability();

  @override
  Future<DirectTorrentNativeSession> start({
    required String requestId,
    required String magnet,
    required int episode,
    int? season,
    int? preferredFileIndex,
  }) => AndroidTvBridge.instance.startDirectTorrent(
    requestId: requestId,
    magnet: magnet,
    episode: episode,
    season: season,
    preferredFileIndex: preferredFileIndex,
  );

  @override
  Future<bool> cancelStart(String requestId) =>
      AndroidTvBridge.instance.cancelDirectTorrentStart(requestId);

  @override
  Future<bool> stop(String sessionId) =>
      AndroidTvBridge.instance.stopDirectTorrent(sessionId);
}

/// Exact capability registry used by the typed player route. An arbitrary
/// loopback URL is never accepted merely because it points at localhost.
class DirectTorrentPlaybackRegistry {
  DirectTorrentPlaybackRegistry._();

  static final instance = DirectTorrentPlaybackRegistry._();

  final Map<Uri, String> _sessions = {};

  bool ownsUri(Uri uri) => _sessions.containsKey(uri);

  void register(DirectTorrentNativeSession session) {
    _sessions[session.uri] = session.sessionId;
  }

  void unregister(Uri uri, String sessionId) {
    if (_sessions[uri] == sessionId) _sessions.remove(uri);
  }
}

class DirectTorrentPlaybackLease implements PlaybackResourceLease {
  DirectTorrentPlaybackLease({
    required DirectTorrentNativeSession session,
    required DirectTorrentPlatformClient platform,
    DirectTorrentPlaybackRegistry? registry,
  }) : _session = session,
       // Keep the public named argument readable while the client stays private.
       // ignore: prefer_initializing_formals
       _platform = platform,
       _registry = registry ?? DirectTorrentPlaybackRegistry.instance {
    _registry.register(session);
  }

  final DirectTorrentNativeSession _session;
  final DirectTorrentPlatformClient _platform;
  final DirectTorrentPlaybackRegistry _registry;
  Future<void>? _closing;

  Uri get uri => _session.uri;

  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    _registry.unregister(_session.uri, _session.sessionId);
    await _platform.stop(_session.sessionId);
  }
}

class DirectTorrentStreamResolver implements StreamResolver {
  DirectTorrentStreamResolver(
    this._releaseSource, {
    DirectTorrentPlatformClient platform =
        const AndroidDirectTorrentPlatformClient(),
  }) : // Keep the public named argument stable for tests and dependency injection.
       // ignore: prefer_initializing_formals
       _platform = platform;

  final ReleaseSource _releaseSource;
  final DirectTorrentPlatformClient _platform;
  static int _requestSequence = 0;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) {
    late final StreamController<StreamResolution> controller;
    var cancelled = false;
    var delivered = false;
    var requestId = '';
    DirectTorrentPlaybackLease? lease;

    Future<void> run() async {
      try {
        final capability = await _platform.capability();
        if (cancelled) return;
        if (!capability.supported) {
          throw StateError(
            'Direct torrent playback is unavailable on this device.',
          );
        }
        final releases = await _releaseSource.search(episode);
        if (cancelled) return;
        if (releases.isEmpty) {
          throw StateError('No torrent releases were found for this episode.');
        }
        final selected = releases.first;
        requestId = _newRequestId();
        if (cancelled) return;
        final session = await _platform.start(
          requestId: requestId,
          magnet: selected.magnetUri,
          episode: episode.episode,
          season: catalogSeasonNumber(episode),
          preferredFileIndex: selected.preferredFileIndex,
        );
        if (cancelled) {
          await _platform.stop(session.sessionId);
          return;
        }
        final activeLease = DirectTorrentPlaybackLease(
          session: session,
          platform: _platform,
        );
        lease = activeLease;
        final ready = StreamReady(
          uri: session.uri,
          displayName: session.selectedBasename,
          mediaContentType: session.mimeType,
          playbackLease: activeLease,
          isDirectTorrent: true,
          providerId: 'direct-torrent',
          providerName: 'Direct torrent',
        );
        try {
          verifyPlaybackEpisodeIdentity(
            episode: episode,
            stream: ready,
            release: selected,
          );
        } on EpisodeIdentityMismatchException {
          await activeLease.close();
          lease = null;
          rethrow;
        }
        delivered = true;
        controller.add(ready);
        await controller.close();
      } catch (error, stackTrace) {
        if (!cancelled) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      }
    }

    controller = StreamController<StreamResolution>(
      sync: true,
      onListen: () => unawaited(run()),
      onCancel: () async {
        cancelled = true;
        if (delivered) return;
        final activeLease = lease;
        if (activeLease != null) {
          await activeLease.close();
        } else if (requestId.isNotEmpty) {
          await _platform.cancelStart(requestId);
        }
      },
    );
    return controller.stream;
  }

  static String _newRequestId() {
    _requestSequence = (_requestSequence + 1) & 0x7fffffff;
    return 'tetotv-${DateTime.now().microsecondsSinceEpoch}-$_requestSequence';
  }
}
