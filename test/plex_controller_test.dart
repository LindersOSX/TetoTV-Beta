import 'dart:typed_data';

import 'package:anime_tv/features/local_media/application/plex_controller.dart';
import 'package:anime_tv/features/local_media/data/plex_client.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('connect validates Plex and persists only the secure session', () async {
    final client = _FakePlexClient();
    final controller = PlexController(storage, client);
    addTearDown(controller.dispose);

    await controller.connect(
      address: 'https://plex.example.com/base',
      token: _token,
    );

    expect(controller.state.busy, isFalse);
    expect(controller.state.connection?.serverName, 'Living Room Plex');
    expect(controller.state.libraries, hasLength(2));
    final saved = await storage.readAll();
    expect(saved['local_media_plex_access_token'], _token);
    expect(saved['local_media_plex_base_url'], 'https://plex.example.com/base');
    expect(saved['local_media_plex_client_identifier'], hasLength(48));
    expect(saved.values, isNot(contains('X-Plex-Token=$_token')));
  });

  test(
    'restores, browses libraries through episodes, and appends pages',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
        'local_media_plex_server_name': 'Living Room Plex',
        'local_media_plex_machine_identifier': 'machine-12345678',
        'local_media_plex_server_version': '1.41.4',
      });
      final client = _FakePlexClient();
      final controller = PlexController(storage, client);
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.connection?.accessToken, _token);
      expect(controller.state.libraries, hasLength(2));

      await controller.openLibrary(client.librariesValue[1]);
      expect(controller.state.items.map((item) => item.title), [
        'Show One',
        'Show Two',
      ]);
      expect(controller.state.totalCount, 3);
      expect(controller.state.nextOffset, 2);

      await controller.loadMore();
      expect(client.libraryStarts, [0, 2]);
      expect(controller.state.items.map((item) => item.title), [
        'Show One',
        'Show Two',
        'Show Three',
      ]);

      await controller.openFolder(controller.state.items.first);
      expect(controller.state.items.single.type, PlexMediaType.season);
      await controller.openFolder(controller.state.items.single);
      final episode = controller.state.items.single;
      expect(episode.type, PlexMediaType.episode);
      expect(controller.playbackUri(episode).query, isEmpty);
      expect(controller.playbackHeaders()['X-Plex-Token'], _token);
      expect(controller.playbackHeaders(), isNot(contains('Accept')));

      await controller.goUp();
      expect(controller.state.items.single.type, PlexMediaType.season);
      await controller.goUp();
      expect(controller.state.items.first.type, PlexMediaType.show);
      await controller.goUp();
      expect(controller.state.locations, isEmpty);
      expect(controller.state.libraries, hasLength(2));
    },
  );

  test('empty malformed pages stop pagination instead of looping', () async {
    final client = _FakePlexClient(stalledPage: true);
    final controller = PlexController(storage, client);
    addTearDown(controller.dispose);
    await controller.connect(
      address: 'https://plex.example.com',
      token: _token,
    );

    await controller.openLibrary(client.librariesValue[1]);

    expect(controller.state.items, isEmpty);
    expect(controller.state.nextOffset, controller.state.totalCount);
    await controller.loadMore();
    expect(client.libraryStarts, [0]);
  });

  test(
    'hydrates a playable search result and keeps server resume time',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
      });
      final client = _FakePlexClient();
      final controller = PlexController(storage, client);
      addTearDown(controller.dispose);
      await controller.load();
      const searchResult = PlexMediaItem(
        ratingKey: 'episode-search',
        key: '/library/metadata/episode-search',
        title: 'Search Episode',
        type: PlexMediaType.episode,
        viewOffsetMilliseconds: 42_000,
      );

      final playable = await controller.preparePlayableItem(searchResult);

      expect(playable.isPlayable, isTrue);
      expect(client.metadataRequests, ['episode-search']);
      expect(
        controller.serverResumePosition(searchResult),
        const Duration(seconds: 42),
      );
    },
  );

  test(
    'disconnect removes the Plex token but preserves device identity',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
        'local_media_plex_server_name': 'Living Room Plex',
        'local_media_plex_machine_identifier': 'machine-12345678',
        'local_media_plex_server_version': '1.41.4',
      });
      final controller = PlexController(storage, _FakePlexClient());
      addTearDown(controller.dispose);

      await controller.disconnect();

      final saved = await storage.readAll();
      expect(saved['local_media_plex_access_token'], isNull);
      expect(saved['local_media_plex_base_url'], isNull);
      expect(saved['local_media_plex_client_identifier'], _clientIdentifier);
      expect(controller.state.connection, isNull);
    },
  );

  test(
    'episode matching surfaces Plex when every alias search fails',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
      });
      final client = _FailingSearchPlexClient();
      final controller = PlexController(storage, client);
      addTearDown(controller.dispose);
      await controller.load();

      await expectLater(
        controller.findEpisodeMatches(
          const EpisodeReference(
            anilistMediaId: 123,
            title: 'Example Show',
            titleEnglish: 'Example Show English',
            episode: 1,
          ),
        ),
        throwsA(
          isA<PlexException>().having(
            (error) => error.message,
            'message',
            contains('unavailable'),
          ),
        ),
      );
      expect(client.searchCalls, greaterThan(0));
    },
  );

  test(
    'one successful Plex alias preserves matches from partial failures',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
      });
      final client = _PartiallyFailingSearchPlexClient();
      final controller = PlexController(storage, client);
      addTearDown(controller.dispose);
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 123,
          title: 'Example Show',
          titleEnglish: 'Example Show English',
          titleRomaji: 'Example Show Romaji',
          episode: 1,
        ),
      );

      expect(client.searchCalls, greaterThan(1));
      expect(matches.map((item) => item.ratingKey), ['episode-match']);
    },
  );

  test(
    'episode matching hydrates shells and removes dead Plex results',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
      });
      final client = _HydratingSearchPlexClient();
      final controller = PlexController(storage, client);
      addTearDown(controller.dispose);
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 123,
          title: 'Example Show',
          episode: 1,
        ),
      );

      expect(matches.map((item) => item.ratingKey), ['playable-shell']);
      expect(matches.single.isPlayable, isTrue);
      expect(
        client.metadataRequests,
        containsAll(['playable-shell', 'dead-shell']),
      );
    },
  );

  test('bounded Plex aliases search concurrently', () async {
    FlutterSecureStorage.setMockInitialValues({
      'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
      'local_media_plex_access_token': _token,
      'local_media_plex_client_identifier': _clientIdentifier,
    });
    final client = _ConcurrentSearchPlexClient();
    final controller = PlexController(storage, client);
    addTearDown(controller.dispose);
    await controller.load();

    final matches = await controller.findEpisodeMatches(
      const EpisodeReference(
        anilistMediaId: 123,
        title: 'Example Show',
        titleEnglish: 'English Example',
        titleRomaji: 'Romaji Example',
        alternativeTitles: ['Alternate Example'],
        episode: 1,
      ),
    );

    expect(matches, isEmpty);
    expect(client.searchCalls, inInclusiveRange(4, 10));
    expect(client.maxInFlight, greaterThan(1));
  });

  test(
    'Plex hierarchy deterministically enriches an earlier direct hit',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
      });
      final client = _EnrichingEpisodePlexClient();
      final controller = PlexController(storage, client);
      addTearDown(controller.dispose);
      await controller.load();

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 105334,
          title: 'Fruits Basket',
          year: 2019,
          episode: 1,
        ),
      );

      expect(matches, hasLength(1));
      expect(matches.single.seriesYear, 2019);
      expect(matches.single.seriesProviderIds['tmdb'], '79141');
      expect(matches.single.isPlayable, isTrue);
    },
  );

  test(
    'Plex prioritizes the expected season beyond the first twelve',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
        'local_media_plex_access_token': _token,
        'local_media_plex_client_identifier': _clientIdentifier,
      });
      final client = _AdaptiveSeasonPlexClient();
      final controller = PlexController(storage, client);
      addTearDown(controller.dispose);
      await controller.load();
      client.lookupRequests = 0;

      final matches = await controller.findEpisodeMatches(
        const EpisodeReference(
          anilistMediaId: 12345,
          title: 'Adaptive Show Season 20',
          episode: 1,
        ),
      );

      expect(client.requestedSeasons.first, 'adaptive-season-20');
      expect(matches.map((item) => item.ratingKey), ['adaptive-episode-20-01']);
      expect(client.lookupRequests, lessThanOrEqualTo(24));
    },
  );

  test('Plex episode lookup never exceeds its global request budget', () async {
    FlutterSecureStorage.setMockInitialValues({
      'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
      'local_media_plex_access_token': _token,
      'local_media_plex_client_identifier': _clientIdentifier,
    });
    final client = _BudgetedLookupPlexClient();
    final controller = PlexController(storage, client);
    addTearDown(controller.dispose);
    await controller.load();
    client.lookupRequests = 0;

    final matches = await controller.findEpisodeMatches(
      const EpisodeReference(
        anilistMediaId: 12345,
        title: 'Budget Show',
        episode: 999,
      ),
    );

    expect(matches, isEmpty);
    expect(client.lookupRequests, 24);
  });

  test('Plex episode traversal paginates past one hundred children', () async {
    FlutterSecureStorage.setMockInitialValues({
      'local_media_plex_base_url': 'http://192.168.1.25:32400/plex',
      'local_media_plex_access_token': _token,
      'local_media_plex_client_identifier': _clientIdentifier,
    });
    final client = _PaginatedEpisodePlexClient();
    final controller = PlexController(storage, client);
    addTearDown(controller.dispose);
    await controller.load();

    final matches = await controller.findEpisodeMatches(
      const EpisodeReference(
        anilistMediaId: 12345,
        title: 'Long Running Show',
        episode: 101,
      ),
    );

    expect(client.episodeStarts, [0, 100]);
    expect(matches.map((item) => item.ratingKey), ['plex-episode-00000101']);
  });
}

const _token = 'plex-access-token-123456';
const _clientIdentifier = 'tetotv-client-123456';

class _FakePlexClient extends PlexClient {
  _FakePlexClient({this.stalledPage = false});

  final bool stalledPage;
  final libraryStarts = <int>[];
  final metadataRequests = <String>[];

  final librariesValue = const [
    PlexLibrary(key: '1', title: 'Movies', type: PlexMediaType.movie),
    PlexLibrary(key: '2', title: 'TV Shows', type: PlexMediaType.show),
  ];

  @override
  Future<PlexServerIdentity> serverIdentity(PlexConnection connection) async =>
      const PlexServerIdentity(
        name: 'Living Room Plex',
        machineIdentifier: 'machine-12345678',
        version: '1.41.4',
      );

  @override
  Future<List<PlexLibrary>> libraries(PlexConnection connection) async =>
      librariesValue;

  @override
  Future<PlexPage<PlexMediaItem>> libraryItems(
    PlexConnection connection,
    PlexLibrary library, {
    int start = 0,
    int size = 100,
  }) async {
    libraryStarts.add(start);
    if (stalledPage) {
      return const PlexPage(
        items: [],
        totalCount: 10,
        offset: 0,
        nextOffset: 0,
      );
    }
    if (library.isMovieLibrary) {
      return const PlexPage(
        items: [_movie],
        totalCount: 1,
        offset: 0,
        nextOffset: 1,
      );
    }
    return start == 0
        ? const PlexPage(
            items: [_showOne, _showTwo],
            totalCount: 3,
            offset: 0,
            nextOffset: 2,
          )
        : const PlexPage(
            items: [_showThree],
            totalCount: 3,
            offset: 2,
            nextOffset: 3,
          );
  }

  @override
  Future<PlexPage<PlexMediaItem>> children(
    PlexConnection connection,
    PlexMediaItem item, {
    int start = 0,
    int size = 100,
  }) async => item.type == PlexMediaType.show
      ? const PlexPage(
          items: [_season],
          totalCount: 1,
          offset: 0,
          nextOffset: 1,
        )
      : const PlexPage(
          items: [_episode],
          totalCount: 1,
          offset: 0,
          nextOffset: 1,
        );

  @override
  Uri playbackUri(
    PlexConnection connection,
    PlexMediaItem item, {
    PlexMediaPart? part,
  }) => Uri.parse('${connection.baseUri}/library/parts/500/file.mkv');

  @override
  Map<String, String> authenticatedHeaders(PlexConnection connection) => {
    'X-Plex-Client-Identifier': connection.clientIdentifier,
    'X-Plex-Token': connection.accessToken,
  };

  @override
  Future<Uint8List> imageBytes(PlexConnection connection, Uri uri) async =>
      Uint8List.fromList(const [1]);

  @override
  Future<PlexMediaItem> metadata(
    PlexConnection connection,
    PlexMediaItem item,
  ) async {
    metadataRequests.add(item.ratingKey);
    return PlexMediaItem(
      ratingKey: item.ratingKey,
      key: item.key,
      title: item.title,
      type: item.type,
      viewOffsetMilliseconds: item.viewOffsetMilliseconds,
      parts: const [PlexMediaPart(key: '/library/parts/search/file.mkv')],
    );
  }
}

class _FailingSearchPlexClient extends _FakePlexClient {
  int searchCalls = 0;

  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async {
    searchCalls++;
    throw const PlexException('Plex is offline.');
  }
}

class _PartiallyFailingSearchPlexClient extends _FakePlexClient {
  int searchCalls = 0;

  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async {
    searchCalls++;
    if (searchCalls != 1) {
      throw const PlexException('One alias failed.');
    }
    return const [
      PlexMediaItem(
        ratingKey: 'episode-match',
        key: '/library/metadata/episode-match',
        title: 'Pilot',
        type: PlexMediaType.episode,
        grandparentTitle: 'Example Show',
        index: 1,
        parts: [PlexMediaPart(key: '/library/parts/match/file.mkv')],
      ),
    ];
  }
}

class _ConcurrentSearchPlexClient extends _FakePlexClient {
  int searchCalls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async {
    searchCalls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return const [];
    } finally {
      inFlight--;
    }
  }
}

class _HydratingSearchPlexClient extends _FakePlexClient {
  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async => const [
    PlexMediaItem(
      ratingKey: 'playable-shell',
      key: '/library/metadata/playable-shell',
      title: 'Pilot',
      type: PlexMediaType.episode,
      grandparentTitle: 'Example Show',
      index: 1,
    ),
    PlexMediaItem(
      ratingKey: 'dead-shell',
      key: '/library/metadata/dead-shell',
      title: 'Pilot',
      type: PlexMediaType.episode,
      grandparentTitle: 'Example Show',
      index: 1,
    ),
  ];

  @override
  Future<PlexMediaItem> metadata(
    PlexConnection connection,
    PlexMediaItem item,
  ) async {
    metadataRequests.add(item.ratingKey);
    if (item.ratingKey == 'dead-shell') {
      return item;
    }
    return PlexMediaItem(
      ratingKey: item.ratingKey,
      key: item.key,
      title: item.title,
      type: item.type,
      grandparentTitle: item.grandparentTitle,
      index: item.index,
      parts: const [
        PlexMediaPart(key: '/library/parts/playable-shell/file.mkv'),
      ],
    );
  }
}

class _PaginatedEpisodePlexClient extends _FakePlexClient {
  final episodeStarts = <int>[];

  static const _show = PlexMediaItem(
    ratingKey: 'plex-show-pagination',
    key: '/library/metadata/plex-show-pagination/children',
    title: 'Long Running Show',
    type: PlexMediaType.show,
  );
  static const _longSeason = PlexMediaItem(
    ratingKey: 'plex-season-pagination',
    key: '/library/metadata/plex-season-pagination/children',
    title: 'Season 1',
    type: PlexMediaType.season,
    parentIndex: 1,
  );

  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async => const [_show];

  @override
  Future<PlexPage<PlexMediaItem>> children(
    PlexConnection connection,
    PlexMediaItem item, {
    int start = 0,
    int size = 100,
  }) async {
    if (item.ratingKey == _show.ratingKey) {
      return const PlexPage(
        items: [_longSeason],
        totalCount: 1,
        offset: 0,
        nextOffset: 1,
      );
    }
    episodeStarts.add(start);
    if (start == 0) {
      return PlexPage(
        items: [
          for (var index = 1; index <= 100; index++)
            PlexMediaItem(
              ratingKey: 'plex-episode-${index.toString().padLeft(8, '0')}',
              key:
                  '/library/metadata/plex-episode-${index.toString().padLeft(8, '0')}',
              title: 'Episode $index',
              type: PlexMediaType.episode,
              grandparentTitle: 'Long Running Show',
              parentIndex: 1,
              index: index,
            ),
        ],
        totalCount: 101,
        offset: 0,
        nextOffset: 100,
      );
    }
    return const PlexPage(
      items: [
        PlexMediaItem(
          ratingKey: 'plex-episode-00000101',
          key: '/library/metadata/plex-episode-00000101',
          title: 'Episode 101',
          type: PlexMediaType.episode,
          grandparentTitle: 'Long Running Show',
          parentIndex: 1,
          index: 101,
          parts: [
            PlexMediaPart(key: '/library/parts/plex-episode-00000101/file.mkv'),
          ],
        ),
      ],
      totalCount: 101,
      offset: 100,
      nextOffset: 101,
    );
  }
}

class _EnrichingEpisodePlexClient extends _FakePlexClient {
  static const _show = PlexMediaItem(
    ratingKey: 'fruits-show',
    key: '/library/metadata/fruits-show/children',
    title: 'Fruits Basket',
    type: PlexMediaType.show,
    year: 2019,
    providerIds: {'tmdb': '79141'},
  );
  static const _season = PlexMediaItem(
    ratingKey: 'fruits-season-1',
    key: '/library/metadata/fruits-season-1/children',
    title: 'Season 1',
    type: PlexMediaType.season,
    index: 1,
  );
  static const _direct = PlexMediaItem(
    ratingKey: 'fruits-episode-1',
    key: '/library/metadata/fruits-episode-1',
    title: 'Episode 1',
    type: PlexMediaType.episode,
    grandparentTitle: 'Fruits Basket',
    parentIndex: 1,
    index: 1,
    parts: [PlexMediaPart(key: '/library/parts/fruits-episode-1/file.mkv')],
  );

  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async => const [_direct, _show];

  @override
  Future<PlexPage<PlexMediaItem>> children(
    PlexConnection connection,
    PlexMediaItem item, {
    int start = 0,
    int size = 100,
  }) async => item.ratingKey == _show.ratingKey
      ? const PlexPage(
          items: [_season],
          totalCount: 1,
          offset: 0,
          nextOffset: 1,
        )
      : const PlexPage(
          items: [_direct],
          totalCount: 1,
          offset: 0,
          nextOffset: 1,
        );
}

class _AdaptiveSeasonPlexClient extends _FakePlexClient {
  int lookupRequests = 0;
  final requestedSeasons = <String>[];

  static const _show = PlexMediaItem(
    ratingKey: 'adaptive-show',
    key: '/library/metadata/adaptive-show/children',
    title: 'Adaptive Show',
    type: PlexMediaType.show,
  );

  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async {
    lookupRequests++;
    return const [_show];
  }

  @override
  Future<PlexPage<PlexMediaItem>> children(
    PlexConnection connection,
    PlexMediaItem item, {
    int start = 0,
    int size = 100,
  }) async {
    lookupRequests++;
    if (item.ratingKey == _show.ratingKey) {
      return PlexPage(
        items: [
          for (var season = 1; season <= 20; season++)
            PlexMediaItem(
              ratingKey: 'adaptive-season-$season',
              key: '/library/metadata/adaptive-season-$season/children',
              title: 'Season $season',
              type: PlexMediaType.season,
              index: season,
            ),
        ],
        totalCount: 20,
        offset: 0,
        nextOffset: 20,
      );
    }
    requestedSeasons.add(item.ratingKey);
    return PlexPage(
      items: item.ratingKey == 'adaptive-season-20'
          ? const [
              PlexMediaItem(
                ratingKey: 'adaptive-episode-20-01',
                key: '/library/metadata/adaptive-episode-20-01',
                title: 'Episode 1',
                type: PlexMediaType.episode,
                grandparentTitle: 'Adaptive Show',
                parentIndex: 20,
                index: 1,
                parts: [
                  PlexMediaPart(
                    key: '/library/parts/adaptive-episode-20-01/file.mkv',
                  ),
                ],
              ),
            ]
          : const [],
      totalCount: item.ratingKey == 'adaptive-season-20' ? 1 : 0,
      offset: 0,
      nextOffset: item.ratingKey == 'adaptive-season-20' ? 1 : 0,
    );
  }
}

class _BudgetedLookupPlexClient extends _FakePlexClient {
  int lookupRequests = 0;

  @override
  Future<List<PlexMediaItem>> search(
    PlexConnection connection,
    String query, {
    int limit = 60,
  }) async {
    lookupRequests++;
    return [
      for (var show = 1; show <= 3; show++)
        PlexMediaItem(
          ratingKey: 'budget-show-$show',
          key: '/library/metadata/budget-show-$show/children',
          title: 'Budget Show',
          type: PlexMediaType.show,
        ),
    ];
  }

  @override
  Future<PlexPage<PlexMediaItem>> children(
    PlexConnection connection,
    PlexMediaItem item, {
    int start = 0,
    int size = 100,
  }) async {
    lookupRequests++;
    if (item.type == PlexMediaType.show) {
      return PlexPage(
        items: [
          for (var season = 1; season <= 30; season++)
            PlexMediaItem(
              ratingKey: '${item.ratingKey}-season-$season',
              key:
                  '/library/metadata/${item.ratingKey}-season-$season/children',
              title: 'Season $season',
              type: PlexMediaType.season,
              index: season,
            ),
        ],
        totalCount: 30,
        offset: 0,
        nextOffset: 30,
      );
    }
    return PlexPage(
      items: [
        PlexMediaItem(
          ratingKey: '${item.ratingKey}-episode-$start',
          key: '/library/metadata/${item.ratingKey}-episode-$start',
          title: 'Episode ${start + 1}',
          type: PlexMediaType.episode,
          grandparentTitle: 'Budget Show',
          parentIndex: 1,
          index: start + 1,
        ),
      ],
      totalCount: 1000,
      offset: start,
      nextOffset: start + 1,
    );
  }
}

const _showOne = PlexMediaItem(
  ratingKey: 'show-1',
  key: '/library/metadata/show-1/children',
  title: 'Show One',
  type: PlexMediaType.show,
);
const _showTwo = PlexMediaItem(
  ratingKey: 'show-2',
  key: '/library/metadata/show-2/children',
  title: 'Show Two',
  type: PlexMediaType.show,
);
const _showThree = PlexMediaItem(
  ratingKey: 'show-3',
  key: '/library/metadata/show-3/children',
  title: 'Show Three',
  type: PlexMediaType.show,
);
const _season = PlexMediaItem(
  ratingKey: 'season-1',
  key: '/library/metadata/season-1/children',
  title: 'Season 1',
  type: PlexMediaType.season,
);
const _episode = PlexMediaItem(
  ratingKey: 'episode-1',
  key: '/library/metadata/episode-1',
  title: 'Pilot',
  type: PlexMediaType.episode,
  grandparentTitle: 'Show One',
  parentIndex: 1,
  index: 1,
  parts: [PlexMediaPart(key: '/library/parts/500/file.mkv')],
);
const _movie = PlexMediaItem(
  ratingKey: 'movie-1',
  key: '/library/metadata/movie-1',
  title: 'Movie One',
  type: PlexMediaType.movie,
  parts: [PlexMediaPart(key: '/library/parts/600/file.mkv')],
);
