import 'dart:math';
import 'dart:typed_data';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/local_media/data/plex_client.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/local_media/domain/plex_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _plexBaseUrlKey = 'local_media_plex_base_url';
const _plexAccessTokenKey = 'local_media_plex_access_token';
const _plexClientIdentifierKey = 'local_media_plex_client_identifier';
const _plexServerNameKey = 'local_media_plex_server_name';
const _plexMachineIdentifierKey = 'local_media_plex_machine_identifier';
const _plexServerVersionKey = 'local_media_plex_server_version';
const _episodeLookupRequestLimit = 24;
const _episodeLookupContainerPageLimit = 3;
const _episodeLookupSeasonLimitPerSeries = 6;

final plexClientProvider = Provider<PlexClient>((_) => PlexClient());

final plexControllerProvider = StateNotifierProvider<PlexController, PlexState>(
  (ref) {
    final controller = PlexController(
      ref.watch(secureStorageProvider),
      ref.watch(plexClientProvider),
    );
    Future.microtask(controller.load);
    return controller;
  },
);

class PlexLocation {
  PlexLocation.library(PlexLibrary value)
    : library = value,
      item = null,
      label = value.title;

  PlexLocation.item(PlexMediaItem value)
    : item = value,
      library = null,
      label = value.title;

  final PlexLibrary? library;
  final PlexMediaItem? item;
  final String label;
}

class PlexState {
  const PlexState({
    this.loaded = false,
    this.busy = false,
    this.connection,
    this.libraries = const [],
    this.items = const [],
    this.locations = const [],
    this.totalCount = 0,
    this.nextOffset = 0,
    this.message,
  });

  final bool loaded;
  final bool busy;
  final PlexConnection? connection;
  final List<PlexLibrary> libraries;
  final List<PlexMediaItem> items;
  final List<PlexLocation> locations;
  final int totalCount;
  final int nextOffset;
  final String? message;

  PlexState copyWith({
    bool? loaded,
    bool? busy,
    Object? connection = _unset,
    List<PlexLibrary>? libraries,
    List<PlexMediaItem>? items,
    List<PlexLocation>? locations,
    int? totalCount,
    int? nextOffset,
    Object? message = _unset,
  }) => PlexState(
    loaded: loaded ?? this.loaded,
    busy: busy ?? this.busy,
    connection: identical(connection, _unset)
        ? this.connection
        : connection as PlexConnection?,
    libraries: libraries ?? this.libraries,
    items: items ?? this.items,
    locations: locations ?? this.locations,
    totalCount: totalCount ?? this.totalCount,
    nextOffset: nextOffset ?? this.nextOffset,
    message: identical(message, _unset) ? this.message : message as String?,
  );
}

const _unset = Object();

class _EpisodeLookupBudget {
  _EpisodeLookupBudget() : remaining = _episodeLookupRequestLimit;

  int remaining;

  bool claim() {
    if (remaining <= 0) return false;
    remaining--;
    return true;
  }
}

class PlexController extends StateNotifier<PlexState> {
  PlexController(this._storage, this._client) : super(const PlexState());

  final FlutterSecureStorage _storage;
  final PlexClient _client;
  int _generation = 0;
  bool _disposed = false;

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  Future<void> load() async {
    final generation = ++_generation;
    try {
      final values = await Future.wait([
        _storage.read(key: _plexBaseUrlKey),
        _storage.read(key: _plexAccessTokenKey),
        _storage.read(key: _plexClientIdentifierKey),
        _storage.read(key: _plexServerNameKey),
        _storage.read(key: _plexMachineIdentifierKey),
        _storage.read(key: _plexServerVersionKey),
      ]);
      if (!_isCurrent(generation)) return;
      final baseUri = normalizePlexServerUri(values[0] ?? '');
      final token = values[1]?.trim() ?? '';
      final clientIdentifier = values[2]?.trim() ?? '';
      final connection =
          baseUri == null || token.length < 8 || clientIdentifier.length < 8
          ? null
          : PlexConnection(
              baseUri: baseUri,
              accessToken: token,
              clientIdentifier: clientIdentifier,
              serverName: values[3],
              machineIdentifier: values[4],
              serverVersion: values[5],
            );
      state = state.copyWith(
        loaded: true,
        connection: connection,
        message: null,
      );
      if (connection != null) await refreshLibraries();
    } catch (_) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        loaded: true,
        message: 'Saved Plex settings could not be loaded.',
      );
    }
  }

  Future<void> connect({required String address, required String token}) async {
    if (_disposed || state.busy) return;
    final baseUri = normalizePlexServerUri(address);
    final cleanToken = token.trim();
    if (baseUri == null) {
      state = state.copyWith(
        message:
            'Use an HTTPS Plex address, or an HTTP address on your private network.',
      );
      return;
    }
    if (cleanToken.length < 8 || cleanToken.length > 4096) {
      state = state.copyWith(message: 'Enter a valid Plex access token.');
      return;
    }
    final generation = ++_generation;
    state = state.copyWith(busy: true, message: 'Connecting to Plex…');
    try {
      final clientIdentifier = await _clientIdentifier();
      if (!_isCurrent(generation)) return;
      var connection = PlexConnection(
        baseUri: baseUri,
        accessToken: cleanToken,
        clientIdentifier: clientIdentifier,
      );
      final identity = await _client.serverIdentity(connection);
      if (!_isCurrent(generation)) return;
      connection = connection.copyWith(
        serverName: identity.name,
        machineIdentifier: identity.machineIdentifier,
        serverVersion: identity.version,
      );
      final libraries = await _client.libraries(connection);
      if (!_isCurrent(generation)) return;
      await _persist(connection);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        busy: false,
        connection: connection,
        libraries: libraries,
        items: const [],
        locations: const [],
        totalCount: libraries.length,
        nextOffset: libraries.length,
        message: 'Connected to ${identity.name}.',
      );
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(message: _friendlyError(error));
    } finally {
      if (_isCurrent(generation)) state = state.copyWith(busy: false);
    }
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    ++_generation;
    await Future.wait([
      for (final key in const [
        _plexBaseUrlKey,
        _plexAccessTokenKey,
        _plexServerNameKey,
        _plexMachineIdentifierKey,
        _plexServerVersionKey,
      ])
        _storage.delete(key: key),
    ]);
    state = state.copyWith(
      busy: false,
      connection: null,
      libraries: const [],
      items: const [],
      locations: const [],
      totalCount: 0,
      nextOffset: 0,
      message: 'Plex disconnected.',
    );
  }

  Future<void> refreshLibraries() async {
    final connection = state.connection;
    if (_disposed || connection == null || state.busy) return;
    final generation = ++_generation;
    state = state.copyWith(busy: true, message: 'Loading Plex libraries…');
    try {
      final libraries = await _client.libraries(connection);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        libraries: libraries,
        items: const [],
        locations: const [],
        totalCount: libraries.length,
        nextOffset: libraries.length,
        message: libraries.isEmpty
            ? 'No movie or TV libraries were found.'
            : null,
      );
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(message: _friendlyError(error));
    } finally {
      if (_isCurrent(generation)) state = state.copyWith(busy: false);
    }
  }

  Future<void> openLibrary(PlexLibrary library) =>
      _loadLocation(locations: [PlexLocation.library(library)], append: false);

  Future<void> refresh() => state.locations.isEmpty
      ? refreshLibraries()
      : _loadLocation(locations: state.locations, append: false);

  Future<void> openFolder(PlexMediaItem item) {
    if (!item.isFolder) return Future.value();
    return _loadLocation(
      locations: [...state.locations, PlexLocation.item(item)],
      append: false,
    );
  }

  Future<void> goUp() {
    if (state.locations.isEmpty) return Future.value();
    if (state.locations.length == 1) return refreshLibraries();
    return _loadLocation(
      locations: state.locations.sublist(0, state.locations.length - 1),
      append: false,
    );
  }

  Future<void> loadMore() {
    if (state.locations.isEmpty || state.nextOffset >= state.totalCount) {
      return Future.value();
    }
    return _loadLocation(locations: state.locations, append: true);
  }

  Future<List<PlexMediaItem>> search(String query) async {
    final connection = state.connection;
    if (_disposed || connection == null) return const [];
    return _client.search(connection, query);
  }

  /// Finds only exact local catalog/episode matches without mutating the
  /// library browser. Traversal is deliberately bounded so a malformed Plex
  /// hierarchy cannot trigger an unbounded request fan-out.
  Future<List<PlexMediaItem>> findEpisodeMatches(
    EpisodeReference episode,
  ) async {
    final connection = state.connection;
    if (_disposed || connection == null) return const [];
    final matches = <String, PlexMediaItem>{};
    final shows = <String, PlexMediaItem>{};
    final budget = _EpisodeLookupBudget();

    void addMatch(PlexMediaItem candidate) {
      final existing = matches[candidate.ratingKey];
      if (existing == null) {
        matches[candidate.ratingKey] = candidate;
        return;
      }
      // Keep the playable search result while merging the authoritative
      // parent identity discovered later through the show hierarchy.
      matches[candidate.ratingKey] = existing.withSeriesProviderIds({
        ...existing.seriesProviderIds,
        ...candidate.seriesProviderIds,
      }, year: candidate.seriesYear ?? existing.seriesYear);
    }

    final searchTermSet = <String>{};
    for (final title in libraryCatalogHierarchySearchTerms(episode)) {
      searchTermSet
        ..add(title)
        ..add(normalizeLibraryTitle(title));
      if (searchTermSet.length >= 10) break;
    }
    final searchTerms = searchTermSet.take(10).toList(growable: false);

    Future<List<PlexMediaItem>?> searchAlias(String title) async {
      if (!budget.claim()) return null;
      try {
        return await _client.search(connection, title, limit: 40);
      } catch (_) {
        return null;
      }
    }

    // Alias searches are independent and bounded to ten. Run them together
    // so one dead request does not serialize several network timeouts before
    // another alias can return the exact episode.
    final searchResults = await Future.wait(searchTerms.map(searchAlias));
    var successfulSearches = 0;
    for (final values in searchResults) {
      if (values == null) continue;
      successfulSearches++;
      for (final item in values) {
        if (plexItemMatchesEpisode(item: item, episode: episode)) {
          addMatch(item);
        } else if (item.type == PlexMediaType.show &&
            librarySeriesMayContainEpisode(
              serverSeriesTitle: item.title,
              episode: episode,
              serverYear: item.year,
              providerIds: item.providerIds,
            )) {
          shows.putIfAbsent(item.ratingKey, () => item);
        }
      }
    }
    if (searchTerms.isNotEmpty && successfulSearches == 0) {
      // A clean empty result means Plex answered at least one bounded alias
      // search. If every request failed, surface the server as unavailable so
      // the picker does not misreport an outage as "episode not found".
      throw const PlexException('Plex search is currently unavailable.');
    }

    for (final show in shows.values.take(3)) {
      List<PlexMediaItem> children;
      try {
        children = await _boundedChildren(
          connection,
          show,
          budget: budget,
          maximumPages: 2,
          maximumItems: 200,
        );
      } catch (_) {
        continue;
      }
      for (final item in children) {
        final candidate = item.withSeriesProviderIds(
          show.providerIds,
          year: show.year,
        );
        if (plexItemMatchesEpisode(item: candidate, episode: episode)) {
          addMatch(candidate);
        }
      }
      final expectedSeason = libraryCatalogSeasonHint(episode);
      final allSeasons = children
          .where((item) => item.type == PlexMediaType.season)
          .toList(growable: false);
      final exactSeasons = expectedSeason == null
          ? const <PlexMediaItem>[]
          : allSeasons
                .where((item) => _plexSeasonNumber(item) == expectedSeason)
                .toList(growable: false);
      final orderedSeasons = <PlexMediaItem>[
        ...exactSeasons,
        ...allSeasons.where((item) => !exactSeasons.contains(item)),
      ];
      for (final season in orderedSeasons.take(
        _episodeLookupSeasonLimitPerSeries,
      )) {
        if (budget.remaining <= 0) break;
        try {
          final episodes = await _boundedChildren(
            connection,
            season,
            budget: budget,
          );
          for (final item in episodes) {
            final candidate = item.withSeriesProviderIds(
              show.providerIds,
              year: show.year,
            );
            if (plexItemMatchesEpisode(item: candidate, episode: episode)) {
              addMatch(candidate);
            }
          }
        } catch (_) {
          // One unreadable season must not hide exact matches from another.
        }
      }
    }
    final playable = await Future.wait(
      matches.values.take(12).map((item) async {
        if (!item.isPlayable && !budget.claim()) return null;
        try {
          return await preparePlayableItem(item);
        } catch (_) {
          // Search can return an episode shell whose media was deleted,
          // unavailable, or no longer readable. Do not expose a dead card.
          return null;
        }
      }),
    );
    return List.unmodifiable(playable.whereType<PlexMediaItem>());
  }

  Future<List<PlexMediaItem>> _boundedChildren(
    PlexConnection connection,
    PlexMediaItem parent, {
    required _EpisodeLookupBudget budget,
    int maximumPages = _episodeLookupContainerPageLimit,
    int maximumItems = 300,
  }) async {
    var start = 0;
    final items = <PlexMediaItem>[];
    for (var pageNumber = 0; pageNumber < maximumPages; pageNumber++) {
      if (!budget.claim()) break;
      final page = await _client.children(
        connection,
        parent,
        start: start,
        size: 100,
      );
      final available = maximumItems - items.length;
      if (available <= 0) break;
      items.addAll(page.items.take(available));
      if (items.length >= maximumItems) break;
      final next = page.nextOffset;
      if (next <= start || next >= page.totalCount) break;
      start = next;
    }
    return List.unmodifiable(items);
  }

  static int? _plexSeasonNumber(PlexMediaItem item) {
    final indexed = item.index ?? item.parentIndex;
    if (indexed != null && indexed >= 0 && indexed <= 1000) return indexed;
    final normalized = normalizeLibraryTitle(item.title);
    if (normalized == 'special' || normalized == 'specials') return 0;
    final match = RegExp(r'^season (\d{1,3})$').firstMatch(normalized);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  Future<PlexMediaItem> preparePlayableItem(PlexMediaItem item) async {
    final connection = state.connection;
    if (connection == null) {
      throw const PlexException('Connect Plex before playing media.');
    }
    if (item.type != PlexMediaType.movie &&
        item.type != PlexMediaType.episode) {
      throw const PlexException('Choose a Plex movie or episode to play.');
    }
    if (item.isPlayable) {
      try {
        // This validates the same-origin part identity in addition to merely
        // checking that Plex returned a non-empty Part list.
        _client.playbackUri(connection, item);
        return item;
      } catch (_) {
        // Search metadata can be stale. Rehydrate it once before rejecting it.
      }
    }
    final hydrated = (await _client.metadata(
      connection,
      item,
    )).withSeriesProviderIds(item.seriesProviderIds, year: item.seriesYear);
    if (!hydrated.isPlayable) {
      throw const PlexException('Plex did not provide a playable media part.');
    }
    _client.playbackUri(connection, hydrated);
    return hydrated;
  }

  Uri playbackUri(PlexMediaItem item) {
    final connection = state.connection;
    if (connection == null) {
      throw const PlexException('Connect Plex before playing media.');
    }
    return _client.playbackUri(connection, item);
  }

  Uri compatibilityPlaybackUri(
    PlexMediaItem item, {
    required String sessionId,
  }) {
    final connection = state.connection;
    if (connection == null) {
      throw const PlexException('Connect Plex before playing media.');
    }
    return _client.compatibilityPlaybackUri(
      connection,
      item,
      sessionId: sessionId,
    );
  }

  Uri? imageUri(PlexMediaItem item) {
    final connection = state.connection;
    return connection == null ? null : _client.imageUri(connection, item);
  }

  Uri? libraryImageUri(PlexLibrary library) {
    final connection = state.connection;
    return connection == null
        ? null
        : _client.libraryImageUri(connection, library);
  }

  Map<String, String> playbackHeaders() {
    final connection = state.connection;
    return connection == null
        ? const {}
        : _client.authenticatedHeaders(connection);
  }

  Duration serverResumePosition(PlexMediaItem item) => Duration(
    milliseconds: (item.viewOffsetMilliseconds ?? 0).clamp(0, 1 << 53),
  );

  Future<void> reportTimeline(
    PlexMediaItem item, {
    required Duration position,
    required bool playing,
  }) async {
    final connection = state.connection;
    if (_disposed || connection == null) return;
    try {
      await _client.reportTimeline(
        connection,
        item,
        position: position,
        playing: playing,
      );
    } catch (_) {
      // Plex timeline reporting is best effort. Local playback and the
      // encrypted device checkpoint remain authoritative while offline.
    }
  }

  Future<Uint8List> imageBytes(Uri uri) {
    final connection = state.connection;
    if (connection == null) {
      throw const PlexException('Connect Plex before loading artwork.');
    }
    return _client.imageBytes(connection, uri);
  }

  Future<void> _loadLocation({
    required List<PlexLocation> locations,
    required bool append,
  }) async {
    final connection = state.connection;
    if (_disposed || connection == null || state.busy || locations.isEmpty) {
      return;
    }
    final generation = ++_generation;
    state = state.copyWith(busy: true, message: 'Loading Plex library…');
    try {
      final last = locations.last;
      final start = append ? state.nextOffset : 0;
      final page = last.library != null
          ? await _client.libraryItems(connection, last.library!, start: start)
          : await _client.children(connection, last.item!, start: start);
      if (!_isCurrent(generation)) return;
      final nextOffset =
          page.nextOffset <= start && page.totalCount > page.nextOffset
          ? page.totalCount
          : page.nextOffset;
      state = state.copyWith(
        items: append
            ? List.unmodifiable([...state.items, ...page.items])
            : page.items,
        locations: List.unmodifiable(locations),
        totalCount: page.totalCount,
        nextOffset: nextOffset,
        message: page.items.isEmpty ? 'This Plex folder is empty.' : null,
      );
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(message: _friendlyError(error));
    } finally {
      if (_isCurrent(generation)) state = state.copyWith(busy: false);
    }
  }

  Future<String> _clientIdentifier() async {
    final saved = await _storage.read(key: _plexClientIdentifierKey);
    if (saved?.isNotEmpty == true) return saved!;
    final random = Random.secure();
    final value = List<int>.generate(
      24,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _plexClientIdentifierKey, value: value);
    return value;
  }

  Future<void> _persist(PlexConnection connection) => Future.wait([
    _storage.write(key: _plexBaseUrlKey, value: connection.baseUri.toString()),
    _storage.write(key: _plexAccessTokenKey, value: connection.accessToken),
    _storage.write(
      key: _plexClientIdentifierKey,
      value: connection.clientIdentifier,
    ),
    _storage.write(
      key: _plexServerNameKey,
      value: connection.serverName ?? 'Plex Media Server',
    ),
    _storage.write(
      key: _plexMachineIdentifierKey,
      value: connection.machineIdentifier ?? '',
    ),
    _storage.write(
      key: _plexServerVersionKey,
      value: connection.serverVersion ?? 'unknown',
    ),
  ]);

  static String _friendlyError(Object error) => switch (error) {
    PlexException(:final message) => message,
    _ => 'TetoTV could not open that Plex server.',
  };
}
