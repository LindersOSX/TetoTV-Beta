import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_models.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'resolves an instant cache hit without polling download progress',
    () async {
      final client = _FakeAllDebridClient();
      final release = ReleaseCandidate(
        infoHash: 'hash',
        magnetUri: 'magnet:?xt=urn:btih:hash',
        releaseName: 'Show batch',
        seeders: 20,
        sourceId: 'test',
        isBatch: true,
      );
      final resolver = AllDebridStreamResolver(
        client,
        SingleReleaseSource(release),
        pollInterval: Duration.zero,
      );

      final states = await resolver
          .resolve(
            const EpisodeReference(
              anilistMediaId: 1,
              title: 'Show',
              episode: 2,
            ),
          )
          .toList();

      expect(states, hasLength(1));
      expect(
        states.single,
        isA<StreamReady>()
            .having(
              (state) => state.debridService,
              'service',
              DebridService.allDebrid,
            )
            .having((state) => state.displayName, 'file', contains('02')),
      );
      expect(client.statusCalls, 0);
      expect(client.deletedIds, isEmpty);
    },
  );

  test('deletes an uncached magnet immediately and never polls it', () async {
    final client = _UncachedAllDebridClient();
    final resolver = AllDebridStreamResolver(
      client,
      SingleReleaseSource(
        const ReleaseCandidate(
          infoHash: 'hash',
          magnetUri: 'magnet:?xt=urn:btih:hash',
          releaseName: 'Uncached',
          seeders: 1,
          sourceId: 'test',
        ),
      ),
    );

    await expectLater(
      resolver
          .resolve(
            const EpisodeReference(
              anilistMediaId: 1,
              title: 'Show',
              episode: 1,
            ),
          )
          .drain<void>(),
      throwsA(
        isA<DebridCacheMissException>()
            .having(
              (error) => error.service,
              'service',
              DebridService.allDebrid,
            )
            .having(
              (error) => error.toString(),
              'message',
              contains('stopped'),
            ),
      ),
    );
    expect(client.statusCalls, 0);
    expect(client.filesCalls, 0);
    expect(client.deletedIds, [42]);
  });

  test(
    'an AllDebrid cleanup failure is terminal and names the dashboard',
    () async {
      final client = _UncachedAllDebridClient(failDelete: true);
      final resolver = AllDebridStreamResolver(
        client,
        const SingleReleaseSource(
          ReleaseCandidate(
            infoHash: 'hash',
            magnetUri: 'magnet:?xt=urn:btih:hash',
            releaseName: 'Uncached',
            seeders: 1,
            sourceId: 'test',
          ),
        ),
      );

      await expectLater(
        resolver
            .resolve(
              const EpisodeReference(
                anilistMediaId: 1,
                title: 'Show',
                episode: 1,
              ),
            )
            .drain<void>(),
        throwsA(
          isA<DebridCleanupFailureException>()
              .having(
                (error) => error.service,
                'service',
                DebridService.allDebrid,
              )
              .having(
                (error) => error.toString(),
                'message',
                allOf(
                  contains('Automatic failover stopped'),
                  contains('dashboard'),
                ),
              ),
        ),
      );
      expect(client.deleteCalls, 1);
      expect(client.deletedIds, isEmpty);
    },
  );

  test('file selection ignores an addon index for another episode', () {
    final selected = selectAllDebridEpisodeFile(
      const [
        AllDebridTorrentFile(
          name: 'Episode 01.mkv',
          size: 100,
          link: 'https://redirect.test/1',
        ),
        AllDebridTorrentFile(
          name: 'Episode 02.mkv',
          size: 200,
          link: 'https://redirect.test/2',
        ),
      ],
      1,
      preferredFileIndex: 1,
    );

    expect(selected.name, 'Episode 01.mkv');
  });

  test('file selection keeps repeated episode numbers in the right season', () {
    final selected = selectAllDebridEpisodeFile(
      const [
        AllDebridTorrentFile(
          name: 'Show S01E01.mkv',
          size: 200,
          link: 'https://redirect.test/s1e1',
        ),
        AllDebridTorrentFile(
          name: 'Show S02E01.mkv',
          size: 100,
          link: 'https://redirect.test/s2e1',
        ),
      ],
      1,
      requestedSeason: 2,
      preferredFileIndex: 0,
    );

    expect(selected.name, 'Show S02E01.mkv');
  });

  test('deletes a ready magnet rejected for the wrong episode', () async {
    final client = _AmbiguousAllDebridClient();
    final resolver = AllDebridStreamResolver(
      client,
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

    await expectLater(
      resolver
          .resolve(
            const EpisodeReference(
              anilistMediaId: 1,
              title: 'Show',
              episode: 2,
            ),
          )
          .drain<void>(),
      throwsA(isA<EpisodeIdentityMismatchException>()),
    );
    expect(client.deletedIds, [42]);
  });
}

class _FakeAllDebridClient extends AllDebridClient {
  _FakeAllDebridClient({this.failDelete = false}) : super(token: 'test');

  final bool failDelete;
  int statusCalls = 0;
  int deleteCalls = 0;
  final List<int> deletedIds = [];

  @override
  Future<AllDebridMagnetUpload> uploadMagnet(String magnetUri) async =>
      const AllDebridMagnetUpload(id: 42, ready: true);

  @override
  Future<AllDebridMagnetStatus> magnetStatus(int id) async {
    statusCalls++;
    return AllDebridMagnetStatus(
      id: id,
      status: 'Ready',
      statusCode: 4,
      downloaded: 200,
      size: 200,
    );
  }

  @override
  Future<void> deleteMagnet(int id) async {
    deleteCalls++;
    if (failDelete) throw StateError('cleanup unavailable');
    deletedIds.add(id);
  }

  @override
  Future<List<AllDebridTorrentFile>> magnetFiles(int id) async => const [
    AllDebridTorrentFile(
      name: 'Show - 01.mkv',
      size: 100,
      link: 'https://redirect.test/1',
    ),
    AllDebridTorrentFile(
      name: 'Show - 02.mkv',
      size: 200,
      link: 'https://redirect.test/2',
    ),
  ];

  @override
  Future<Uri> unlock(String link) async =>
      Uri.parse('https://cdn.alldebrid.test/02.mkv');
}

class _UncachedAllDebridClient extends _FakeAllDebridClient {
  _UncachedAllDebridClient({super.failDelete});

  int filesCalls = 0;

  @override
  Future<AllDebridMagnetUpload> uploadMagnet(String magnetUri) async =>
      const AllDebridMagnetUpload(id: 42, ready: false);

  @override
  Future<List<AllDebridTorrentFile>> magnetFiles(int id) async {
    filesCalls++;
    return super.magnetFiles(id);
  }
}

class _AmbiguousAllDebridClient extends _FakeAllDebridClient {
  @override
  Future<List<AllDebridTorrentFile>> magnetFiles(int id) async => const [
    AllDebridTorrentFile(
      name: 'video.mkv',
      size: 200,
      link: 'https://redirect.test/video',
    ),
  ];
}
