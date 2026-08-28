import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';

class PremiumizeStreamResolver implements StreamResolver {
  PremiumizeStreamResolver(
    this._client,
    this._releaseSource, {
    this.pollInterval = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 20),
  });

  final PremiumizeClient _client;
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
    if (!await _client.isCached(release.magnetUri)) {
      throw const DebridCacheMissException(
        DebridService.premiumize,
        detail:
            'This release is not cached on Premiumize. TetoTV did not create '
            'a cloud transfer.',
      );
    }
    final files = await _client.directDownload(release.magnetUri);
    final selected = selectPremiumizeEpisodeFile(
      files,
      episode.episode,
      requestedSeason: catalogSeasonNumber(episode),
      preferredFileIndex: release.preferredFileIndex,
    );
    final ready = StreamReady(
      uri: selected.link,
      displayName: selected.name,
      debridService: DebridService.premiumize,
    );
    verifyPlaybackEpisodeIdentity(
      episode: episode,
      stream: ready,
      release: release,
    );
    yield ready;
  }
}

PremiumizeFile selectPremiumizeEpisodeFile(
  List<PremiumizeFile> files,
  int episode, {
  int? requestedSeason,
  int? preferredFileIndex,
}) {
  final playable = files.where((file) => file.isPlayable).toList();
  if (playable.isEmpty) {
    throw StateError('The Premiumize transfer contains no supported videos.');
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
