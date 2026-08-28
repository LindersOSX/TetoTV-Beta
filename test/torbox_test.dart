import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_models.dart';
import 'package:anime_tv/features/streaming/data/torbox_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a ready TorBox torrent and its playable files', () {
    final torrent = TorBoxTorrent.fromJson({
      'id': 42,
      'name': 'Example',
      'download_state': 'cached',
      'progress': 100,
      'download_finished': true,
      'cached': true,
      'files': [
        {'id': 10, 'short_name': 'Example - 01.mkv', 'size': 900},
        {'id': 11, 'short_name': 'Example - 02.mkv', 'size': 950},
        {'id': 12, 'short_name': 'cover.jpg', 'size': 20},
      ],
    });

    expect(torrent.isReady, isTrue);
    expect(torrent.progress, 1);
    expect(torrent.files.where((file) => file.isPlayable), hasLength(2));
  });

  test('ignores a Stremio file index for another TorBox episode', () {
    const files = [
      TorBoxFile(id: 10, name: 'Example - 01.mkv', size: 900),
      TorBoxFile(id: 11, name: 'Example - 02.mkv', size: 950),
    ];

    final selected = selectTorBoxEpisodeFile(files, 1, preferredFileIndex: 1);

    expect(selected.id, 10);
  });

  test('falls back to episode matching for TorBox batches', () {
    const files = [
      TorBoxFile(id: 10, name: 'Example - 01.mkv', size: 900),
      TorBoxFile(id: 11, name: 'Example - 02.mkv', size: 950),
    ];

    expect(selectTorBoxEpisodeFile(files, 2).id, 11);
  });

  test('keeps repeated episode numbers in the requested season', () {
    const files = [
      TorBoxFile(id: 10, name: 'Example S01E01.mkv', size: 1000),
      TorBoxFile(id: 11, name: 'Example S02E01.mkv', size: 900),
    ];

    final selected = selectTorBoxEpisodeFile(
      files,
      1,
      requestedSeason: 2,
      preferredFileIndex: 0,
    );

    expect(selected.id, 11);
  });

  test('maps an atomic TorBox create cache miss without a precheck', () async {
    final client = _FakeTorBoxClient(
      createError: const TorBoxException(
        'Torrent is not cached.',
        code: 'DOWNLOAD_NOT_CACHED',
      ),
    );
    final resolver = TorBoxStreamResolver(
      client,
      const SingleReleaseSource(_torBoxRelease),
    );

    await expectLater(
      resolver.resolve(_torBoxEpisode).drain<void>(),
      throwsA(
        isA<DebridCacheMissException>().having(
          (error) => error.service,
          'service',
          DebridService.torBox,
        ),
      ),
    );
    expect(client.cacheCheckCalls, 0);
    expect(client.createCalls, 1);
    expect(client.addOnlyIfCachedValues, [isTrue]);
    expect(client.deletedIds, isEmpty);
  });

  test(
    'plays a TorBox cache hit and does not report download progress',
    () async {
      final client = _FakeTorBoxClient();
      final resolver = TorBoxStreamResolver(
        client,
        const SingleReleaseSource(_torBoxRelease),
        pollInterval: Duration.zero,
      );

      final states = await resolver.resolve(_torBoxEpisode).toList();

      expect(states, hasLength(1));
      expect(
        states.single,
        isA<StreamReady>().having(
          (state) => state.debridService,
          'service',
          DebridService.torBox,
        ),
      );
      expect(client.createCalls, 1);
      expect(client.addOnlyIfCachedValues, [isTrue]);
      expect(client.cacheCheckCalls, 0);
      expect(client.deletedIds, isEmpty);
    },
  );

  test('deletes a TorBox item when a cached result becomes stale', () async {
    final client = _FakeTorBoxClient(downloadState: 'downloading');
    final resolver = TorBoxStreamResolver(
      client,
      const SingleReleaseSource(_torBoxRelease),
      pollInterval: Duration.zero,
    );

    await expectLater(
      resolver.resolve(_torBoxEpisode).drain<void>(),
      throwsA(isA<DebridCacheMissException>()),
    );
    expect(client.createCalls, 1);
    expect(client.deletedIds, [42]);
  });

  test('deletes a ready TorBox item rejected for the wrong episode', () async {
    final client = _AmbiguousTorBoxClient();
    final resolver = TorBoxStreamResolver(
      client,
      const SingleReleaseSource(
        ReleaseCandidate(
          infoHash: 'wrong-episode',
          magnetUri: 'magnet:?xt=urn:btih:wrong-episode',
          releaseName: 'Example Episode 7',
          seeders: 1,
          sourceId: 'test',
        ),
      ),
      pollInterval: Duration.zero,
    );

    await expectLater(
      resolver.resolve(_torBoxEpisode).drain<void>(),
      throwsA(isA<EpisodeIdentityMismatchException>()),
    );
    expect(client.deletedIds, [42]);
  });

  test(
    'a TorBox cleanup failure is terminal and names the dashboard',
    () async {
      final client = _FakeTorBoxClient(
        downloadState: 'downloading',
        failDelete: true,
      );
      final resolver = TorBoxStreamResolver(
        client,
        const SingleReleaseSource(_torBoxRelease),
        pollInterval: Duration.zero,
      );

      await expectLater(
        resolver.resolve(_torBoxEpisode).drain<void>(),
        throwsA(
          isA<DebridCleanupFailureException>()
              .having((error) => error.service, 'service', DebridService.torBox)
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
}

const _torBoxEpisode = EpisodeReference(
  anilistMediaId: 1,
  title: 'Example',
  episode: 2,
);

const _torBoxRelease = ReleaseCandidate(
  infoHash: '0123456789abcdef0123456789abcdef01234567',
  magnetUri: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
  releaseName: 'Example batch',
  seeders: 20,
  sourceId: 'test',
  isBatch: true,
);

class _FakeTorBoxClient extends TorBoxClient {
  _FakeTorBoxClient({
    this.createError,
    this.downloadState = 'cached',
    this.failDelete = false,
  }) : super(token: 'test');

  final TorBoxException? createError;
  final String downloadState;
  final bool failDelete;
  int cacheCheckCalls = 0;
  int createCalls = 0;
  int deleteCalls = 0;
  final List<bool> addOnlyIfCachedValues = [];
  final List<int> deletedIds = [];

  @override
  Future<bool> isTorrentCached(String infoHash) async {
    cacheCheckCalls++;
    return true;
  }

  @override
  Future<int> createTorrent(
    String magnetUri, {
    required bool addOnlyIfCached,
  }) async {
    createCalls++;
    addOnlyIfCachedValues.add(addOnlyIfCached);
    if (createError case final error?) throw error;
    return 42;
  }

  @override
  Future<TorBoxTorrent> torrentInfo(
    int torrentId, {
    bool bypassCache = true,
  }) async => TorBoxTorrent(
    id: 42,
    name: 'Example batch',
    downloadState: downloadState,
    progress: 1,
    downloadFinished: downloadState == 'cached',
    cached: downloadState == 'cached',
    files: const [
      TorBoxFile(id: 10, name: 'Example - 01.mkv', size: 100),
      TorBoxFile(id: 11, name: 'Example - 02.mkv', size: 200),
    ],
  );

  @override
  Future<Uri> requestDownloadLink({
    required int torrentId,
    required int fileId,
  }) async => Uri.parse('https://cdn.torbox.test/episode.mkv');

  @override
  Future<void> deleteTorrent(int torrentId) async {
    deleteCalls++;
    if (failDelete) throw StateError('cleanup unavailable');
    deletedIds.add(torrentId);
  }
}

class _AmbiguousTorBoxClient extends _FakeTorBoxClient {
  @override
  Future<TorBoxTorrent> torrentInfo(
    int torrentId, {
    bool bypassCache = true,
  }) async => const TorBoxTorrent(
    id: 42,
    name: 'Example Episode 7',
    downloadState: 'cached',
    progress: 1,
    downloadFinished: true,
    cached: true,
    files: [TorBoxFile(id: 10, name: 'video.mkv', size: 200)],
  );
}
