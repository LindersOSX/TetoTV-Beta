import 'package:anime_tv/features/streaming/application/episode_release_search_cache.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'details and resolver observers share one release-source request',
    () async {
      final source = _CountingSource();
      final cache = EpisodeReleaseSearchCache(
        source,
        zeroListenerGrace: Duration.zero,
      );
      const episode = EpisodeReference(
        anilistMediaId: 1,
        title: 'Show',
        episode: 4,
      );

      final first = cache.watch(episode).toList();
      final second = cache.watch(episode).toList();
      final results = await Future.wait([first, second]);

      expect(source.searchCount, 1);
      expect(results[0].last.candidates.single.infoHash, 'shared');
      expect(results[1].last.candidates.single.infoHash, 'shared');
      expect(cache.snapshot(episode)?.candidates.single.infoHash, 'shared');
    },
  );
}

class _CountingSource implements ReleaseSource {
  int searchCount = 0;

  @override
  String get id => 'counting';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async {
    searchCount++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return const [
      ReleaseCandidate(
        infoHash: 'shared',
        magnetUri: 'magnet:?xt=urn:btih:shared',
        releaseName: 'Shared result',
        seeders: 1,
        sourceId: 'counting',
      ),
    ];
  }
}
