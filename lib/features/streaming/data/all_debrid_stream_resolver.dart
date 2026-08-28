import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

class AllDebridStreamResolver implements StreamResolver {
  AllDebridStreamResolver(
    this._client,
    this._releaseSource, {
    this.pollInterval = const Duration(seconds: 3),
    this.timeout = const Duration(minutes: 30),
  });

  final AllDebridClient _client;
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
        if (a.isBatch != b.isBatch) return a.isBatch ? 1 : -1;
        return b.seeders.compareTo(a.seeders);
      });
    final release = ranked.first;
    final upload = await _client.uploadMagnet(release.magnetUri);
    var keepMagnet = false;
    try {
      // AllDebrid no longer exposes a separate cache endpoint. Its documented
      // upload result is the earliest authoritative signal: ready=true is an
      // instant cache hit. A miss is deleted immediately and never polled.
      if (!upload.ready) {
        throw const DebridCacheMissException(
          DebridService.allDebrid,
          detail:
              'This release is not instantly cached on AllDebrid. TetoTV '
              'stopped it immediately instead of leaving a cloud download '
              'running.',
        );
      }
      final files = await _client.magnetFiles(upload.id);
      final selected = selectAllDebridEpisodeFile(
        files,
        episode.episode,
        requestedSeason: catalogSeasonNumber(episode),
        preferredFileIndex: release.preferredFileIndex,
      );
      final uri = await _client.unlock(selected.link);
      final ready = StreamReady(
        uri: uri,
        displayName: selected.name,
        debridService: DebridService.allDebrid,
      );
      verifyPlaybackEpisodeIdentity(
        episode: episode,
        stream: ready,
        release: release,
      );
      keepMagnet = true;
      yield ready;
    } finally {
      if (!keepMagnet) {
        try {
          await _client.deleteMagnet(upload.id);
        } catch (error) {
          throw DebridCleanupFailureException(
            DebridService.allDebrid,
            cause: error,
          );
        }
      }
    }
  }
}

AllDebridTorrentFile selectAllDebridEpisodeFile(
  List<AllDebridTorrentFile> files,
  int episode, {
  int? requestedSeason,
  int? preferredFileIndex,
}) {
  final playable = files.where((file) => file.isPlayable).toList();
  if (playable.isEmpty) {
    throw StateError(
      'The AllDebrid torrent contains no supported video files.',
    );
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
