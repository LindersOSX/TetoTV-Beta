import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_models.dart';
import 'package:anime_tv/features/streaming/data/premiumize_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const episode = EpisodeReference(
    anilistMediaId: 1,
    title: 'Show',
    episode: 2,
  );
  final release = ReleaseCandidate(
    infoHash: 'hash',
    magnetUri: 'magnet:?xt=urn:btih:hash',
    releaseName: 'Show batch',
    seeders: 12,
    sourceId: 'test',
    isBatch: true,
  );

  test('uses directdl for a cached magnet and selects the episode', () async {
    final resolver = PremiumizeStreamResolver(
      _CachedPremiumizeClient(),
      SingleReleaseSource(release),
    );

    final states = await resolver.resolve(episode).toList();

    expect(states, hasLength(1));
    expect(
      states.single,
      isA<StreamReady>()
          .having(
            (state) => state.debridService,
            'service',
            DebridService.premiumize,
          )
          .having((state) => state.displayName, 'file', contains('02')),
    );
  });

  test(
    'rejects an uncached magnet without creating a cloud transfer',
    () async {
      final client = _QueuedPremiumizeClient();
      final resolver = PremiumizeStreamResolver(
        client,
        SingleReleaseSource(release),
        pollInterval: Duration.zero,
      );

      await expectLater(
        resolver.resolve(episode).drain<void>(),
        throwsA(
          isA<DebridCacheMissException>()
              .having(
                (error) => error.service,
                'service',
                DebridService.premiumize,
              )
              .having(
                (error) => error.toString(),
                'message',
                contains('did not create'),
              ),
        ),
      );

      expect(client.createCalls, 0);
      expect(client.directCalls, 0);
    },
  );

  test('does not queue after an authentication failure', () async {
    final client = _AuthenticationFailureClient();
    final resolver = PremiumizeStreamResolver(
      client,
      SingleReleaseSource(release),
    );

    await expectLater(
      resolver.resolve(episode).toList(),
      throwsA(isA<PremiumizeException>()),
    );
    expect(client.createCalls, 0);
  });

  test('file selection ignores an addon index for another episode', () {
    final selected = selectPremiumizeEpisodeFile(
      [_file('Episode 01.mkv', 100), _file('Episode 02.mkv', 200)],
      1,
      preferredFileIndex: 1,
    );

    expect(selected.name, 'Episode 01.mkv');
  });

  test('file selection keeps repeated episode numbers in the right season', () {
    final selected = selectPremiumizeEpisodeFile(
      [_file('Show S01E01.mkv', 200), _file('Show S02E01.mkv', 100)],
      1,
      requestedSeason: 2,
      preferredFileIndex: 0,
    );

    expect(selected.name, 'Show S02E01.mkv');
  });

  test('rejects a cached result that explicitly names another episode', () {
    final resolver = PremiumizeStreamResolver(
      _AmbiguousPremiumizeClient(),
      const SingleReleaseSource(
        ReleaseCandidate(
          infoHash: 'wrong-episode',
          magnetUri: 'magnet:?xt=urn:btih:wrong-episode',
          releaseName: 'Show Episode 7',
          seeders: 1,
          sourceId: 'test',
        ),
      ),
    );

    expectLater(
      resolver.resolve(episode).drain<void>(),
      throwsA(isA<EpisodeIdentityMismatchException>()),
    );
  });
}

PremiumizeFile _file(String name, int size) => PremiumizeFile(
  name: name,
  size: size,
  link: Uri.parse('https://cdn.premiumize.test/$name'),
);

class _CachedPremiumizeClient extends PremiumizeClient {
  _CachedPremiumizeClient() : super(token: 'test');

  @override
  Future<bool> isCached(String source) async => true;

  @override
  Future<List<PremiumizeFile>> directDownload(String source) async => [
    _file('Show - 01.mkv', 100),
    _file('Show - 02.mkv', 200),
  ];
}

class _QueuedPremiumizeClient extends PremiumizeClient {
  _QueuedPremiumizeClient() : super(token: 'test');

  int createCalls = 0;
  int directCalls = 0;

  @override
  Future<bool> isCached(String source) async => false;

  @override
  Future<List<PremiumizeFile>> directDownload(String source) async {
    directCalls++;
    throw const PremiumizeException('Not cached', code: 'not_found');
  }

  @override
  Future<PremiumizeTransferCreation> createTransfer(String source) async {
    createCalls++;
    return const PremiumizeTransferCreation(id: 'transfer-1', name: 'Show');
  }
}

class _AuthenticationFailureClient extends PremiumizeClient {
  _AuthenticationFailureClient() : super(token: 'test');

  int createCalls = 0;

  @override
  Future<bool> isCached(String source) async => true;

  @override
  Future<List<PremiumizeFile>> directDownload(String source) async =>
      throw const PremiumizeException(
        'Invalid key',
        code: 'authentication_failed',
      );

  @override
  Future<PremiumizeTransferCreation> createTransfer(String source) async {
    createCalls++;
    return const PremiumizeTransferCreation(id: 'unexpected', name: 'bad');
  }
}

class _AmbiguousPremiumizeClient extends PremiumizeClient {
  _AmbiguousPremiumizeClient() : super(token: 'test');

  @override
  Future<bool> isCached(String source) async => true;

  @override
  Future<List<PremiumizeFile>> directDownload(String source) async => [
    _file('video.mkv', 200),
  ];
}
