import 'dart:async';

import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

class RealDebridStreamResolver implements StreamResolver {
  RealDebridStreamResolver(
    this._client,
    this._releaseSource, {
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(seconds: 20),
  });

  final RealDebridClient _client;
  final ReleaseSource _releaseSource;
  final Duration pollInterval;
  final Duration timeout;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    final releases = await _releaseSource.search(episode);
    if (releases.isEmpty) {
      throw StateError('No releases found for episode ${episode.episode}.');
    }
    final ranked = [...releases]
      ..sort((a, b) {
        final singleEpisodeBias = a.isBatch == b.isBatch
            ? 0
            : a.isBatch
            ? 1
            : -1;
        return singleEpisodeBias != 0
            ? singleEpisodeBias
            : b.seeders.compareTo(a.seeders);
      });

    final selectedRelease = ranked.first;
    String? torrentId;
    var ownsTorrent = false;
    var keepTorrent = false;
    try {
      try {
        torrentId = await _client.addMagnet(selectedRelease.magnetUri);
        ownsTorrent = true;
      } on RealDebridException catch (error) {
        // Only release-specific duplicate/unavailable responses may be
        // recovered by inspecting an existing account torrent. Provider-wide
        // rate limits stop here instead of generating lookup or failover
        // traffic for more candidates.
        if (!error.isCandidateSpecific ||
            (error.code != 33 && error.code != 35)) {
          rethrow;
        }
        final existing = await _client.findAccountTorrentByHash(
          selectedRelease.infoHash,
          downloadedOnly: error.code == 35,
        );
        if (existing == null) rethrow;
        torrentId = existing.id;
      }
      var info = await _client.torrentInfo(torrentId);
      final deadline = DateTime.now().add(timeout);
      var selectedFiles = false;
      while (DateTime.now().isBefore(deadline)) {
        if (info.hasFailed) {
          throw const RealDebridException(
            'This release could not be prepared by Real-Debrid. TetoTV can '
            'try a different release.',
            kind: RealDebridFailureKind.releaseUnavailable,
          );
        }
        if (info.isDownloaded) break;
        if (info.needsFileSelection && !selectedFiles) {
          // Real-Debrid has no supported preflight cache endpoint. Selecting
          // the requested file is the earliest supported readiness check and
          // may briefly start provider-side work. Inspect immediately and
          // remove every non-ready torrent below instead of waiting on it.
          final file = selectEpisodeFile(
            info.files,
            episode.episode,
            requestedSeason: catalogSeasonNumber(episode),
            preferredFileIndex: selectedRelease.preferredFileIndex,
          );
          await _client.selectFiles(torrentId, [file.id]);
          selectedFiles = true;
          info = await _client.torrentInfo(torrentId);
          continue;
        }

        // A cached torrent should become ready immediately. Queued or active
        // download states mean the cache claim was stale; delete it instead of
        // silently using the user's Real-Debrid account as a downloader.
        if (info.isDownloadActivity) {
          throw _notCachedException(ownedByAttempt: ownsTorrent);
        }
        // Magnet metadata may take a moment to resolve before file selection.
        // Once selection happened, any non-ready state gets only this short,
        // bounded cache-check window and is then removed in finally.
        await Future<void>.delayed(pollInterval);
        info = await _client.torrentInfo(torrentId);
      }

      if (!info.isDownloaded) {
        throw selectedFiles
            ? _notCachedException(ownedByAttempt: ownsTorrent)
            : const RealDebridException(
                'Real-Debrid could not verify this torrent quickly enough. '
                'TetoTV did not leave a server download running.',
                kind: RealDebridFailureKind.releaseUnavailable,
              );
      }
      if (info.links.isEmpty) {
        throw StateError('Real-Debrid returned no downloadable video link.');
      }

      final episodeFile = selectEpisodeFile(
        info.files,
        episode.episode,
        requestedSeason: catalogSeasonNumber(episode),
        preferredFileIndex: selectedRelease.preferredFileIndex,
      );
      final link = selectEpisodeDownloadLink(
        info,
        episode.episode,
        requestedSeason: catalogSeasonNumber(episode),
        preferredFileIndex: selectedRelease.preferredFileIndex,
      );
      final unrestricted = await _client.unrestrict(link);
      final ready = StreamReady(
        uri: unrestricted.download,
        // Preserve the provider's selected torrent-file identity. Some CDN
        // responses rename every file to a generic value such as video.mkv,
        // which would otherwise discard the strongest episode evidence.
        displayName: _basenameOrFallback(
          episodeFile.path,
          unrestricted.filename,
        ),
        debridService: DebridService.realDebrid,
      );
      // Validate while this attempt still owns cleanup. If the selected file
      // is ambiguous but the release explicitly names another episode, the
      // finally block removes the provider-side item instead of retaining a
      // source that TetoTV will reject later in the playback pipeline.
      verifyPlaybackEpisodeIdentity(
        episode: episode,
        stream: ready,
        release: selectedRelease,
      );
      keepTorrent = true;
      yield ready;
    } finally {
      if (torrentId != null && ownsTorrent && !keepTorrent) {
        try {
          await _client.deleteTorrent(torrentId);
        } catch (error) {
          throw DebridCleanupFailureException(
            DebridService.realDebrid,
            cause: error,
          );
        }
      }
    }
  }
}

String _basenameOrFallback(String path, String fallback) {
  final segments = path.replaceAll('\\', '/').split('/');
  final basename = segments.lastWhere(
    (segment) => segment.trim().isNotEmpty,
    orElse: () => '',
  );
  return basename.trim().isEmpty ? fallback : basename;
}

DebridCacheMissException _notCachedException({
  required bool ownedByAttempt,
}) => DebridCacheMissException(
  DebridService.realDebrid,
  detail: ownedByAttempt
      ? 'This release was not ready in Real-Debrid. TetoTV cancelled and '
            'removed its cache check immediately; trying another release.'
      : 'This matching Real-Debrid account torrent was not ready. TetoTV left '
            'it unchanged and is trying another release.',
);

/// Maps the episode file selected from a downloaded batch to the matching
/// Real-Debrid link. The API returns links in the same order as selected
/// files, which is not necessarily the order of all files in the torrent.
String selectEpisodeDownloadLink(
  RealDebridTorrentInfo info,
  int episode, {
  int? requestedSeason,
  int? preferredFileIndex,
}) {
  if (info.links.isEmpty) {
    throw StateError('Real-Debrid returned no downloadable video link.');
  }
  if (info.links.length == 1) return info.links.single;

  final episodeFile = selectEpisodeFile(
    info.files,
    episode,
    requestedSeason: requestedSeason,
    preferredFileIndex: preferredFileIndex,
  );
  final selectedFiles = info.files.where((file) => file.selected).toList();
  final selectedIndex = selectedFiles.indexWhere(
    (file) => file.id == episodeFile.id,
  );
  if (selectedIndex >= 0 && selectedIndex < info.links.length) {
    return info.links[selectedIndex];
  }

  // Some older API responses omit the selected flag while returning one link
  // per torrent file. Preserve correct batch mapping in that representation.
  if (info.links.length == info.files.length) {
    final fileIndex = info.files.indexWhere(
      (file) => file.id == episodeFile.id,
    );
    if (fileIndex >= 0) return info.links[fileIndex];
  }

  throw const RealDebridException(
    'Real-Debrid did not identify which download belongs to this episode. '
    'Choose another release.',
    kind: RealDebridFailureKind.releaseUnavailable,
  );
}

RealDebridTorrentFile selectEpisodeFile(
  List<RealDebridTorrentFile> files,
  int episode, {
  int? requestedSeason,
  int? preferredFileIndex,
}) {
  final playable = files.where((file) => file.isPlayable).toList();
  if (playable.isEmpty) {
    throw StateError('The torrent contains no supported video files.');
  }
  final selectedIndex = selectEpisodeFileIndex(
    labels: files.map((file) => file.path).toList(growable: false),
    playable: files.map((file) => file.isPlayable).toList(growable: false),
    sizes: files.map((file) => file.bytes).toList(growable: false),
    requestedEpisode: episode,
    requestedSeason: requestedSeason,
    preferredFileIndex: preferredFileIndex,
  );
  return files[selectedIndex];
}
