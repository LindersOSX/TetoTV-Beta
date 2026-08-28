import 'dart:async';

import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

class TorBoxStreamResolver implements StreamResolver {
  TorBoxStreamResolver(
    this._client,
    this._releaseSource, {
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(seconds: 20),
  });

  final TorBoxClient _client;
  final ReleaseSource _releaseSource;
  final Duration pollInterval;
  final Duration timeout;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    final releases = await _releaseSource.search(episode);
    if (releases.isEmpty) {
      throw StateError('No releases found for episode ${episode.episode}.');
    }
    final release = releases.first;
    int? torrentId;
    var keepTorrent = false;
    try {
      try {
        // TorBox makes the cache decision atomically with creation. A
        // separate checkcached request has a race where the cache can expire
        // before this request and start an unwanted server download.
        torrentId = await _client.createTorrent(
          release.magnetUri,
          addOnlyIfCached: true,
        );
      } on TorBoxException catch (error) {
        if (error.code?.toUpperCase() == 'DOWNLOAD_NOT_CACHED') {
          throw const DebridCacheMissException(
            DebridService.torBox,
            detail:
                'This release is not cached on TorBox. TorBox did not add it '
                'to your cloud download queue.',
          );
        }
        rethrow;
      }
      final deadline = DateTime.now().add(timeout);
      TorBoxTorrent? torrent;

      while (DateTime.now().isBefore(deadline)) {
        torrent = await _client.torrentInfo(torrentId);
        if (torrent.hasFailed) {
          throw StateError('TorBox torrent failed: ${torrent.downloadState}.');
        }
        if (torrent.isReady) break;
        if (torrent.isDownloadActivity) {
          throw const DebridCacheMissException(
            DebridService.torBox,
            detail:
                'TorBox reported a stale cache result. TetoTV stopped the '
                'cloud download instead of waiting for it.',
          );
        }
        await Future<void>.delayed(pollInterval);
      }

      if (torrent == null || !torrent.isReady) {
        throw const DebridCacheMissException(
          DebridService.torBox,
          detail:
              'TorBox did not make this cached release ready quickly enough. '
              'TetoTV did not leave a cloud download running.',
        );
      }
      final file = selectTorBoxEpisodeFile(
        torrent.files,
        episode.episode,
        requestedSeason: catalogSeasonNumber(episode),
        preferredFileIndex: release.preferredFileIndex,
      );
      final uri = await _client.requestDownloadLink(
        torrentId: torrentId,
        fileId: file.id,
      );
      final ready = StreamReady(
        uri: uri,
        displayName: file.name,
        debridService: DebridService.torBox,
      );
      verifyPlaybackEpisodeIdentity(
        episode: episode,
        stream: ready,
        release: release,
      );
      keepTorrent = true;
      yield ready;
    } finally {
      if (torrentId != null && !keepTorrent) {
        try {
          await _client.deleteTorrent(torrentId);
        } catch (error) {
          throw DebridCleanupFailureException(
            DebridService.torBox,
            cause: error,
          );
        }
      }
    }
  }
}

TorBoxFile selectTorBoxEpisodeFile(
  List<TorBoxFile> files,
  int episode, {
  int? requestedSeason,
  int? preferredFileIndex,
}) {
  final playable = files.where((file) => file.isPlayable).toList();
  if (playable.isEmpty) {
    throw StateError('The TorBox torrent contains no supported video files.');
  }
  final selectedIndex = selectEpisodeFileIndex(
    labels: files.map((file) => file.name).toList(growable: false),
    playable: files.map((file) => file.isPlayable).toList(growable: false),
    sizes: files.map((file) => file.size).toList(growable: false),
    requestedEpisode: episode,
    requestedSeason: requestedSeason,
    preferredFileIndex: preferredFileIndex,
  );
  return files[selectedIndex];
}
