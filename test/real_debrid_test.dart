import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_models.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Real-Debrid torrent selection', () {
    test('selects the video matching the requested episode in a batch', () {
      final selected = selectEpisodeFile(const [
        RealDebridTorrentFile(
          id: 1,
          path: '/Show - 01.mkv',
          bytes: 900,
          selected: false,
        ),
        RealDebridTorrentFile(
          id: 2,
          path: '/Show - 02.mkv',
          bytes: 950,
          selected: false,
        ),
        RealDebridTorrentFile(
          id: 3,
          path: '/cover.jpg',
          bytes: 20,
          selected: false,
        ),
      ], 2);

      expect(selected.id, 2);
    });

    test('falls back to the largest playable file', () {
      final selected = selectEpisodeFile(const [
        RealDebridTorrentFile(
          id: 10,
          path: '/feature-a.mkv',
          bytes: 400,
          selected: false,
        ),
        RealDebridTorrentFile(
          id: 11,
          path: '/feature-b.mp4',
          bytes: 800,
          selected: false,
        ),
      ], 12);

      expect(selected.id, 11);
    });

    test('ignores a Stremio file index that identifies another episode', () {
      final selected = selectEpisodeFile(
        const [
          RealDebridTorrentFile(
            id: 1,
            path: '/Episode 01.mkv',
            bytes: 900,
            selected: false,
          ),
          RealDebridTorrentFile(
            id: 2,
            path: '/Episode 02.mkv',
            bytes: 1000,
            selected: false,
          ),
        ],
        1,
        preferredFileIndex: 1,
      );

      expect(selected.id, 1);
    });

    test('honors a Stremio file index when filenames are ambiguous', () {
      final selected = selectEpisodeFile(
        const [
          RealDebridTorrentFile(
            id: 1,
            path: '/feature-a.mkv',
            bytes: 900,
            selected: false,
          ),
          RealDebridTorrentFile(
            id: 2,
            path: '/feature-b.mkv',
            bytes: 1000,
            selected: false,
          ),
        ],
        1,
        preferredFileIndex: 0,
      );

      expect(selected.id, 1);
    });

    test('keeps repeated episode numbers in the requested season', () {
      final selected = selectEpisodeFile(
        const [
          RealDebridTorrentFile(
            id: 1,
            path: '/Show S01E01.mkv',
            bytes: 1000,
            selected: false,
          ),
          RealDebridTorrentFile(
            id: 2,
            path: '/Show S02E01.mkv',
            bytes: 900,
            selected: false,
          ),
        ],
        1,
        requestedSeason: 2,
        preferredFileIndex: 0,
      );

      expect(selected.id, 2);
    });

    test('maps a downloaded batch episode to its corresponding link', () {
      final link = selectEpisodeDownloadLink(
        const RealDebridTorrentInfo(
          id: 'batch',
          filename: 'Show batch',
          status: 'downloaded',
          progress: 100,
          files: [
            RealDebridTorrentFile(
              id: 10,
              path: '/Show - 01.mkv',
              bytes: 900,
              selected: true,
            ),
            RealDebridTorrentFile(
              id: 11,
              path: '/cover.jpg',
              bytes: 20,
              selected: false,
            ),
            RealDebridTorrentFile(
              id: 12,
              path: '/Show - 02.mkv',
              bytes: 950,
              selected: true,
            ),
          ],
          links: [
            'https://rd.example/episode-1',
            'https://rd.example/episode-2',
          ],
        ),
        2,
      );

      expect(link, 'https://rd.example/episode-2');
    });

    test('maps a cross-season episode to its corresponding link', () {
      final link = selectEpisodeDownloadLink(
        const RealDebridTorrentInfo(
          id: 'cross-season-batch',
          filename: 'Show complete',
          status: 'downloaded',
          progress: 100,
          files: [
            RealDebridTorrentFile(
              id: 20,
              path: '/Show S01E01.mkv',
              bytes: 1000,
              selected: true,
            ),
            RealDebridTorrentFile(
              id: 21,
              path: '/Show S02E01.mkv',
              bytes: 900,
              selected: true,
            ),
          ],
          links: [
            'https://rd.example/season-1-episode-1',
            'https://rd.example/season-2-episode-1',
          ],
        ),
        1,
        requestedSeason: 2,
        preferredFileIndex: 0,
      );

      expect(link, 'https://rd.example/season-2-episode-1');
    });
  });

  group('Real-Debrid API failures', () {
    test('classifies code 35 as a safe release-specific failure', () {
      final error = RealDebridException.fromApi(code: 35, httpStatus: 403);

      expect(error.kind, RealDebridFailureKind.releaseUnavailable);
      expect(error.isCandidateSpecific, isTrue);
      expect(error.isTerminalAccountFailure, isFalse);
      expect(error.toString(), isNot(contains('infringing_file')));
      expect(error.toString(), contains('different release'));
    });

    test('classifies invalid authorization as terminal', () {
      final error = RealDebridException.fromApi(code: 8, httpStatus: 401);

      expect(error.kind, RealDebridFailureKind.authorization);
      expect(error.isTerminalAccountFailure, isTrue);
      expect(error.toString(), contains('Reconnect'));
    });

    test('does not fan out account-capacity or rate-limit failures', () {
      final activeDownloads = RealDebridException.fromApi(code: 21);
      final tooManyRequests = RealDebridException.fromApi(code: 34);

      expect(activeDownloads.kind, RealDebridFailureKind.account);
      expect(activeDownloads.isTerminalAccountFailure, isTrue);
      expect(activeDownloads.canTryAnotherRelease, isFalse);
      expect(tooManyRequests.kind, RealDebridFailureKind.rateLimited);
      expect(tooManyRequests.canTryAnotherRelease, isFalse);
    });

    test('HTTP 429 overrides a release-shaped API error', () {
      final error = RealDebridException.fromApi(
        code: 35,
        httpStatus: 429,
        retryAfter: const Duration(seconds: 12),
      );

      expect(error.kind, RealDebridFailureKind.rateLimited);
      expect(error.canTryAnotherRelease, isFalse);
      expect(error.retryAfter, const Duration(seconds: 12));
    });

    test('shared gate honors Retry-After and blocks another client', () async {
      var now = DateTime.utc(2026, 8, 24, 12);
      final gate = RealDebridRateLimitGate(now: () => now);
      final pacer = RealDebridRequestPacer(minimumInterval: Duration.zero);
      var requestCount = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.real-debrid.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestCount++;
              if (requestCount == 1) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                    response: Response<Map<String, dynamic>>(
                      requestOptions: options,
                      statusCode: 429,
                      data: const {
                        'error_code': 34,
                        'error': 'too_many_requests',
                      },
                      headers: Headers.fromMap(const {
                        'retry-after': ['7'],
                      }),
                    ),
                  ),
                );
                return;
              }
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 201,
                  data: const {'id': 'torrent-id'},
                ),
              );
            },
          ),
        );
      final first = RealDebridClient(
        token: 'first',
        dio: dio,
        rateLimitGate: gate,
        requestPacer: pacer,
      );
      final second = RealDebridClient(
        token: 'second',
        dio: dio,
        rateLimitGate: gate,
        requestPacer: pacer,
      );

      await expectLater(
        first.addMagnet('magnet:?xt=urn:btih:first'),
        throwsA(
          isA<RealDebridException>()
              .having(
                (error) => error.kind,
                'kind',
                RealDebridFailureKind.rateLimited,
              )
              .having(
                (error) => error.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              ),
        ),
      );
      await expectLater(
        second.addMagnet('magnet:?xt=urn:btih:second'),
        throwsA(
          isA<RealDebridException>().having(
            (error) => error.kind,
            'kind',
            RealDebridFailureKind.rateLimited,
          ),
        ),
      );
      expect(requestCount, 1, reason: 'the second call must stay local');

      now = now.add(const Duration(seconds: 8));
      expect(
        await second.addMagnet('magnet:?xt=urn:btih:second'),
        'torrent-id',
      );
      expect(requestCount, 2);
    });

    test('shared pacer spaces addMagnet calls across clients', () async {
      var now = DateTime.utc(2026, 8, 24, 12);
      final waits = <Duration>[];
      final pacer = RealDebridRequestPacer(
        now: () => now,
        minimumInterval: const Duration(milliseconds: 1250),
        delay: (duration) async {
          waits.add(duration);
          now = now.add(duration);
        },
      );
      final gate = RealDebridRateLimitGate(now: () => now);
      var requestCount = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.real-debrid.test'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestCount++;
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 201,
                  data: {'id': 'torrent-$requestCount'},
                ),
              );
            },
          ),
        );
      final first = RealDebridClient(
        token: 'first',
        dio: dio,
        rateLimitGate: gate,
        requestPacer: pacer,
      );
      final second = RealDebridClient(
        token: 'second',
        dio: dio,
        rateLimitGate: gate,
        requestPacer: pacer,
      );

      expect(
        await Future.wait([
          first.addMagnet('magnet:?xt=urn:btih:first'),
          second.addMagnet('magnet:?xt=urn:btih:second'),
        ]),
        ['torrent-1', 'torrent-2'],
      );
      expect(requestCount, 2);
      expect(waits, [const Duration(milliseconds: 1250)]);
    });

    test('shared gate bounds excessive and malformed Retry-After values', () {
      final now = DateTime.utc(2026, 8, 24, 12);
      final excessive = RealDebridRateLimitGate(now: () => now);
      final malformed = RealDebridRateLimitGate(now: () => now);

      expect(excessive.register('9999'), const Duration(minutes: 2));
      expect(malformed.register('not-a-date'), const Duration(seconds: 30));
    });
  });

  group('Real-Debrid cached-preferred resolution', () {
    test(
      'rate limiting stops before account lookup or torrent cleanup',
      () async {
        final client = _FakeRealDebridClient(
          const [],
          addMagnetError: RealDebridException.fromApi(code: 34),
        );
        final resolver = RealDebridStreamResolver(
          client,
          const _ReleaseSource(),
          pollInterval: Duration.zero,
        );

        await expectLater(
          resolver.resolve(_episode).drain<void>(),
          throwsA(
            isA<RealDebridException>().having(
              (error) => error.kind,
              'kind',
              RealDebridFailureKind.rateLimited,
            ),
          ),
        );
        expect(client.reuseLookupHashes, isEmpty);
        expect(client.infoCalls, 0);
        expect(client.deleteCalls, 0);
      },
    );

    test(
      'reuses a previously downloaded matching torrent after code 35',
      () async {
        final downloaded = _torrentInfo(
          status: 'downloaded',
          progress: 100,
          selected: true,
          links: const ['https://rd.example/episode-2'],
        );
        final client = _FakeRealDebridClient(
          [downloaded],
          addMagnetError: RealDebridException.fromApi(code: 35),
          existingTorrent: downloaded,
        );
        final resolver = RealDebridStreamResolver(
          client,
          const _ReleaseSource(),
          pollInterval: Duration.zero,
        );

        final states = await resolver.resolve(_episode).toList();

        expect(states.single, isA<StreamReady>());
        expect(client.reuseLookupHashes, [
          '0123456789abcdef0123456789abcdef01234567',
        ]);
        expect(
          client.deletedTorrentIds,
          isEmpty,
          reason: 'a reused account torrent is not owned by this attempt',
        );
        expect(client.unrestrictCalls, 1);
      },
    );

    test('reuses a matching active account torrent after code 33', () async {
      final active = _torrentInfo(status: 'waiting_files_selection');
      final downloaded = _torrentInfo(
        status: 'downloaded',
        progress: 100,
        selected: true,
        links: const ['https://rd.example/episode-2'],
      );
      final client = _FakeRealDebridClient(
        [active, downloaded],
        addMagnetError: RealDebridException.fromApi(code: 33),
        existingTorrent: active,
      );
      final resolver = RealDebridStreamResolver(
        client,
        const _ReleaseSource(),
        pollInterval: Duration.zero,
      );

      final states = await resolver.resolve(_episode).toList();

      expect(states.single, isA<StreamReady>());
      expect(client.reuseDownloadedOnly, [isFalse]);
      expect(client.deletedTorrentIds, isEmpty);
    });

    test(
      'leaves a reused account torrent untouched when it is not ready',
      () async {
        final active = _torrentInfo(status: 'queued');
        final client = _FakeRealDebridClient(
          [active],
          addMagnetError: RealDebridException.fromApi(code: 33),
          existingTorrent: active,
        );
        final resolver = RealDebridStreamResolver(
          client,
          const _ReleaseSource(),
          pollInterval: Duration.zero,
        );

        await expectLater(
          resolver.resolve(_episode).drain<void>(),
          throwsA(
            isA<DebridCacheMissException>().having(
              (error) => error.toString(),
              'message',
              allOf(contains('left it unchanged'), isNot(contains('removed'))),
            ),
          ),
        );
        expect(client.deletedTorrentIds, isEmpty);
      },
    );

    test(
      'plays an instantly cached torrent without reporting download work',
      () async {
        final client = _FakeRealDebridClient([
          _torrentInfo(status: 'waiting_files_selection'),
          _torrentInfo(
            status: 'downloaded',
            progress: 100,
            selected: true,
            links: const ['https://rd.example/episode-2'],
          ),
        ]);
        final resolver = RealDebridStreamResolver(
          client,
          const _ReleaseSource(),
          pollInterval: Duration.zero,
        );

        final states = await resolver.resolve(_episode).toList();

        expect(states, hasLength(1));
        expect(
          states.single,
          isA<StreamReady>()
              .having(
                (state) => state.debridService,
                'service',
                DebridService.realDebrid,
              )
              .having(
                (state) => state.uri,
                'URI',
                Uri.parse('https://cdn.example/episode.mkv'),
              ),
        );
        expect(client.selectedFileIds, [2]);
        expect(client.deletedTorrentIds, isEmpty);
        expect(client.unrestrictCalls, 1);
      },
    );

    test(
      'removes an owned cached torrent rejected for the wrong episode',
      () async {
        final info = RealDebridTorrentInfo(
          id: 'torrent-id',
          filename: 'Example Episode 7',
          status: 'downloaded',
          progress: 100,
          files: const [
            RealDebridTorrentFile(
              id: 1,
              path: '/video.mkv',
              bytes: 1000,
              selected: true,
            ),
          ],
          links: const ['https://rd.example/video'],
        );
        final client = _FakeRealDebridClient([info]);
        final resolver = RealDebridStreamResolver(
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
          resolver.resolve(_episode).drain<void>(),
          throwsA(isA<EpisodeIdentityMismatchException>()),
        );
        expect(client.deletedTorrentIds, ['torrent-id']);
      },
    );

    test(
      'removes an uncached torrent as soon as it enters the queue',
      () async {
        final client = _FakeRealDebridClient([
          _torrentInfo(status: 'waiting_files_selection'),
          _torrentInfo(status: 'queued'),
        ]);
        final resolver = RealDebridStreamResolver(
          client,
          const _ReleaseSource(),
          pollInterval: Duration.zero,
        );

        await expectLater(
          resolver.resolve(_episode).drain<void>(),
          throwsA(
            isA<DebridCacheMissException>()
                .having(
                  (error) => error.service,
                  'service',
                  DebridService.realDebrid,
                )
                .having(
                  (error) => error.toString(),
                  'message',
                  allOf(contains('not ready'), contains('cancelled')),
                ),
          ),
        );

        expect(client.selectedFileIds, [2]);
        expect(client.deletedTorrentIds, ['torrent-id']);
        expect(client.unrestrictCalls, 0);
        expect(client.infoCalls, 2, reason: 'uncached work must not be polled');
      },
    );

    test(
      'selects files only once while Real-Debrid applies the selection',
      () async {
        final client = _FakeRealDebridClient([
          _torrentInfo(status: 'waiting_files_selection'),
          _torrentInfo(status: 'waiting_files_selection'),
          _torrentInfo(status: 'queued'),
        ]);
        final resolver = RealDebridStreamResolver(
          client,
          const _ReleaseSource(),
          pollInterval: Duration.zero,
        );

        await expectLater(
          resolver.resolve(_episode).drain<void>(),
          throwsA(isA<DebridCacheMissException>()),
        );

        expect(client.selectCalls, 1);
        expect(client.selectedFileIds, [2]);
        expect(client.deletedTorrentIds, ['torrent-id']);
      },
    );

    test(
      'cleanup failure is terminal and names the provider dashboard',
      () async {
        final client = _FakeRealDebridClient([
          _torrentInfo(status: 'waiting_files_selection'),
          _torrentInfo(status: 'downloading'),
        ], failDelete: true);
        final resolver = RealDebridStreamResolver(
          client,
          const _ReleaseSource(),
          pollInterval: Duration.zero,
        );

        await expectLater(
          resolver.resolve(_episode).drain<void>(),
          throwsA(
            isA<DebridCleanupFailureException>()
                .having(
                  (error) => error.service,
                  'service',
                  DebridService.realDebrid,
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
      },
    );
  });

  test('parses premium account state', () {
    final account = RealDebridAccount.fromJson({
      'id': 42,
      'username': 'tv-user',
      'type': 'premium',
      'expiration': DateTime.now()
          .add(const Duration(days: 10))
          .toUtc()
          .toIso8601String(),
    });

    expect(account.username, 'tv-user');
    expect(account.isPremium, isTrue);
  });
}

const _episode = EpisodeReference(
  anilistMediaId: 42,
  title: 'Example',
  episode: 2,
);

RealDebridTorrentInfo _torrentInfo({
  required String status,
  double progress = 0,
  bool selected = false,
  List<String> links = const [],
}) => RealDebridTorrentInfo(
  id: 'torrent-id',
  filename: 'Example batch',
  status: status,
  progress: progress,
  files: [
    RealDebridTorrentFile(
      id: 1,
      path: '/Example - 01.mkv',
      bytes: 1000,
      selected: selected,
    ),
    RealDebridTorrentFile(
      id: 2,
      path: '/Example - 02.mkv',
      bytes: 1100,
      selected: selected,
    ),
  ],
  links: links,
);

class _ReleaseSource implements ReleaseSource {
  const _ReleaseSource();

  @override
  String get id => 'test';

  @override
  Future<List<ReleaseCandidate>> search(
    EpisodeReference episode,
  ) async => const [
    ReleaseCandidate(
      infoHash: '0123456789abcdef0123456789abcdef01234567',
      magnetUri: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
      releaseName: 'Example batch',
      seeders: 100,
      sourceId: 'test',
      isBatch: true,
    ),
  ];
}

class _FakeRealDebridClient extends RealDebridClient {
  _FakeRealDebridClient(
    this.infos, {
    this.failDelete = false,
    this.addMagnetError,
    this.existingTorrent,
  }) : super(token: 'test');

  final List<RealDebridTorrentInfo> infos;
  final bool failDelete;
  final RealDebridException? addMagnetError;
  final RealDebridTorrentInfo? existingTorrent;
  final List<int> selectedFileIds = [];
  final List<String> deletedTorrentIds = [];
  final List<String> reuseLookupHashes = [];
  final List<bool> reuseDownloadedOnly = [];
  int infoCalls = 0;
  int unrestrictCalls = 0;
  int deleteCalls = 0;
  int selectCalls = 0;

  @override
  Future<String> addMagnet(String magnetUri) async {
    final error = addMagnetError;
    if (error != null) throw error;
    return 'torrent-id';
  }

  @override
  Future<RealDebridTorrentInfo?> findAccountTorrentByHash(
    String infoHash, {
    int limit = 100,
    bool downloadedOnly = false,
  }) async {
    reuseLookupHashes.add(infoHash);
    reuseDownloadedOnly.add(downloadedOnly);
    return existingTorrent;
  }

  @override
  Future<RealDebridTorrentInfo> torrentInfo(String id) async {
    final index = infoCalls.clamp(0, infos.length - 1);
    infoCalls++;
    return infos[index];
  }

  @override
  Future<void> selectFiles(String id, Iterable<int> fileIds) async {
    selectCalls++;
    selectedFileIds.addAll(fileIds);
  }

  @override
  Future<void> deleteTorrent(String id) async {
    deleteCalls++;
    if (failDelete) throw StateError('cleanup unavailable');
    deletedTorrentIds.add(id);
  }

  @override
  Future<RealDebridUnrestrictedLink> unrestrict(String link) async {
    unrestrictCalls++;
    return RealDebridUnrestrictedLink(
      download: Uri(scheme: 'https', host: 'cdn.example', path: '/episode.mkv'),
      filename: 'Example - 02.mkv',
    );
  }
}
