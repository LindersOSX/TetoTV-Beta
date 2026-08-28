import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/local_media/data/jellyfin_client.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _jellyfinBaseUrlKey = 'local_media_jellyfin_base_url';
const _jellyfinServerNameKey = 'local_media_jellyfin_server_name';
const _jellyfinServerVersionKey = 'local_media_jellyfin_server_version';
const _jellyfinUserIdKey = 'local_media_jellyfin_user_id';
const _jellyfinUsernameKey = 'local_media_jellyfin_username';
const _jellyfinAccessTokenKey = 'local_media_jellyfin_access_token';
const _jellyfinDeviceIdKey = 'local_media_jellyfin_device_id';
const _recentLocalDocumentKey = 'local_media_recent_document';
const _localDocumentIndexKey = 'local_media_document_index_v2';
const _localResumePrefix = 'local_media_resume_';
const _episodeLookupRequestLimit = 24;
const _episodeLookupContainerPageLimit = 3;
const _episodeLookupSeasonLimitPerSeries = 6;

/// A season-sized, explicitly granted local index without broad storage
/// access. Newest selections are first and duplicate content URIs collapse.
const maxPersistedLocalDocuments = 24;

final jellyfinClientProvider = Provider<JellyfinClient>(
  (_) => JellyfinClient(),
);

final localMediaControllerProvider =
    StateNotifierProvider<LocalMediaController, LocalMediaState>((ref) {
      final controller = LocalMediaController(
        ref.watch(secureStorageProvider),
        ref.watch(jellyfinClientProvider),
        AndroidTvBridge.instance,
      );
      Future.microtask(controller.load);
      return controller;
    });

class JellyfinBreadcrumb {
  const JellyfinBreadcrumb({required this.id, required this.name});

  final String id;
  final String name;
}

class LocalMediaState {
  const LocalMediaState({
    this.loaded = false,
    this.busy = false,
    this.connection,
    this.items = const [],
    this.breadcrumbs = const [],
    this.totalCount = 0,
    this.nextStartIndex = 0,
    this.localDocuments = const [],
    this.recentLocalDocument,
    this.message,
  });

  final bool loaded;
  final bool busy;
  final JellyfinConnection? connection;
  final List<JellyfinMediaItem> items;
  final List<JellyfinBreadcrumb> breadcrumbs;
  final int totalCount;
  final int nextStartIndex;
  final List<LocalMediaDocument> localDocuments;
  final LocalMediaDocument? recentLocalDocument;
  final String? message;

  LocalMediaState copyWith({
    bool? loaded,
    bool? busy,
    Object? connection = _unset,
    List<JellyfinMediaItem>? items,
    List<JellyfinBreadcrumb>? breadcrumbs,
    int? totalCount,
    int? nextStartIndex,
    List<LocalMediaDocument>? localDocuments,
    Object? recentLocalDocument = _unset,
    Object? message = _unset,
  }) => LocalMediaState(
    loaded: loaded ?? this.loaded,
    busy: busy ?? this.busy,
    connection: identical(connection, _unset)
        ? this.connection
        : connection as JellyfinConnection?,
    items: items ?? this.items,
    breadcrumbs: breadcrumbs ?? this.breadcrumbs,
    totalCount: totalCount ?? this.totalCount,
    nextStartIndex: nextStartIndex ?? this.nextStartIndex,
    localDocuments: localDocuments ?? this.localDocuments,
    recentLocalDocument: identical(recentLocalDocument, _unset)
        ? this.recentLocalDocument
        : recentLocalDocument as LocalMediaDocument?,
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

class LocalMediaController extends StateNotifier<LocalMediaState> {
  LocalMediaController(this._storage, this._client, this._bridge)
    : super(const LocalMediaState());

  final FlutterSecureStorage _storage;
  final JellyfinClient _client;
  final AndroidTvBridge _bridge;
  int _generation = 0;

  LocalMediaDocument? get recentLocalDocument => state.recentLocalDocument;
  List<LocalMediaDocument> get localDocuments => state.localDocuments;

  Future<void> load() async {
    final generation = ++_generation;
    try {
      final values = await Future.wait([
        _storage.read(key: _jellyfinBaseUrlKey),
        _storage.read(key: _jellyfinServerNameKey),
        _storage.read(key: _jellyfinServerVersionKey),
        _storage.read(key: _jellyfinUserIdKey),
        _storage.read(key: _jellyfinUsernameKey),
        _storage.read(key: _jellyfinAccessTokenKey),
        _storage.read(key: _jellyfinDeviceIdKey),
        _storage.read(key: _localDocumentIndexKey),
        _storage.read(key: _recentLocalDocumentKey),
      ]);
      if (generation != _generation) return;
      final baseUri = normalizeJellyfinServerUri(values[0] ?? '');
      final connection =
          baseUri == null ||
              values[3]?.isNotEmpty != true ||
              values[4]?.isNotEmpty != true ||
              values[5]?.isNotEmpty != true ||
              values[6]?.isNotEmpty != true
          ? null
          : JellyfinConnection(
              baseUri: baseUri,
              serverName: values[1]?.trim().isNotEmpty == true
                  ? values[1]!.trim()
                  : 'Jellyfin',
              serverVersion: values[2]?.trim().isNotEmpty == true
                  ? values[2]!.trim()
                  : 'unknown',
              userId: values[3]!,
              username: values[4]!,
              accessToken: values[5]!,
              deviceId: values[6]!,
            );
      final documents = _decodeDocumentIndex(
        indexValue: values[7],
        legacyValue: values[8],
      );
      state = state.copyWith(
        loaded: true,
        connection: connection,
        localDocuments: documents,
        recentLocalDocument: documents.firstOrNull,
        message: null,
      );
      await _repairDocumentIndex(
        documents,
        hadIndexValue: values[7] != null,
        hadLegacyValue: values[8] != null,
      );
      if (connection != null) await refresh();
    } catch (_) {
      if (generation != _generation) return;
      state = state.copyWith(
        loaded: true,
        message: 'Saved local-media settings could not be loaded.',
      );
    }
  }

  Future<LocalMediaDocument?> pickLocalVideo() async {
    if (state.busy) return null;
    state = state.copyWith(busy: true, message: null);
    try {
      final document = await _bridge.pickLocalVideo();
      if (document == null) return null;
      if (!isSafeLocalVideoDocument(document)) {
        throw const FormatException(
          'Android returned invalid local-video metadata.',
        );
      }
      final documents = _dedupeAndCapDocuments([
        document,
        ...state.localDocuments,
      ]);
      if (document.persistedReadPermission) {
        await _persistDocumentIndex(documents);
      }
      state = state.copyWith(
        localDocuments: documents,
        recentLocalDocument: document,
      );
      if (!document.persistedReadPermission) {
        state = state.copyWith(
          message: 'This file provider grants access only until TetoTV closes.',
        );
      }
      return document;
    } catch (error) {
      state = state.copyWith(message: _friendlyError(error));
      return null;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> connect({
    required String address,
    required String username,
    required String password,
  }) async {
    if (state.busy) return;
    final baseUri = normalizeJellyfinServerUri(address);
    if (baseUri == null) {
      state = state.copyWith(
        message:
            'Use an HTTPS Jellyfin address, or an HTTP address on your private network.',
      );
      return;
    }
    final generation = ++_generation;
    state = state.copyWith(busy: true, message: 'Connecting to Jellyfin…');
    try {
      final deviceId = await _deviceId();
      final connection = await _client.authenticate(
        baseUri: baseUri,
        username: username,
        password: password,
        deviceId: deviceId,
      );
      if (generation != _generation) return;
      await _persistConnection(connection);
      state = state.copyWith(
        busy: false,
        connection: connection,
        items: const [],
        breadcrumbs: const [],
        totalCount: 0,
        nextStartIndex: 0,
        message: 'Connected to ${connection.serverName}.',
      );
      await refresh();
    } catch (error) {
      if (generation != _generation) return;
      state = state.copyWith(message: _friendlyError(error));
    } finally {
      if (generation == _generation) state = state.copyWith(busy: false);
    }
  }

  Future<void> disconnect() async {
    ++_generation;
    final connection = state.connection;
    if (connection != null) {
      try {
        await _client.logout(connection);
      } catch (_) {
        // Local unlink must remain available while the server is offline.
      }
    }
    await Future.wait([
      for (final key in const [
        _jellyfinBaseUrlKey,
        _jellyfinServerNameKey,
        _jellyfinServerVersionKey,
        _jellyfinUserIdKey,
        _jellyfinUsernameKey,
        _jellyfinAccessTokenKey,
      ])
        _storage.delete(key: key),
    ]);
    state = state.copyWith(
      busy: false,
      connection: null,
      items: const [],
      breadcrumbs: const [],
      totalCount: 0,
      nextStartIndex: 0,
      message: 'Jellyfin disconnected.',
    );
  }

  Future<void> refresh() => _loadItems(
    parentId: state.breadcrumbs.isEmpty ? null : state.breadcrumbs.last.id,
    breadcrumbs: state.breadcrumbs,
  );

  Future<void> loadMore() {
    if (state.nextStartIndex >= state.totalCount) return Future.value();
    return _loadItems(
      parentId: state.breadcrumbs.isEmpty ? null : state.breadcrumbs.last.id,
      breadcrumbs: state.breadcrumbs,
      append: true,
    );
  }

  Future<void> openFolder(JellyfinMediaItem item) {
    if (!item.isFolder) return Future.value();
    return _loadItems(
      parentId: item.id,
      breadcrumbs: [
        ...state.breadcrumbs,
        JellyfinBreadcrumb(id: item.id, name: item.name),
      ],
    );
  }

  Future<void> goUp() {
    if (state.breadcrumbs.isEmpty) return Future.value();
    final breadcrumbs = state.breadcrumbs.sublist(
      0,
      state.breadcrumbs.length - 1,
    );
    return _loadItems(
      parentId: breadcrumbs.isEmpty ? null : breadcrumbs.last.id,
      breadcrumbs: breadcrumbs,
    );
  }

  Future<List<JellyfinMediaItem>> search(String query) async {
    final connection = state.connection;
    if (connection == null) return const [];
    return _client.search(connection, query);
  }

  Future<List<JellyfinMediaItem>> _boundedChildItems(
    JellyfinConnection connection,
    String parentId, {
    required _EpisodeLookupBudget budget,
    int maximumPages = _episodeLookupContainerPageLimit,
    int maximumItems = 300,
  }) async {
    var startIndex = 0;
    final items = <JellyfinMediaItem>[];
    for (var pageNumber = 0; pageNumber < maximumPages; pageNumber++) {
      if (!budget.claim()) break;
      final page = await _client.items(
        connection,
        parentId: parentId,
        startIndex: startIndex,
      );
      final available = maximumItems - items.length;
      if (available <= 0) break;
      items.addAll(page.items.take(available));
      if (items.length >= maximumItems) break;
      final next = page.nextStartIndex;
      if (next <= startIndex || next >= page.totalCount) break;
      startIndex = next;
    }
    return List.unmodifiable(items);
  }

  Future<List<JellyfinMediaItem>> findEpisodeMatches(
    EpisodeReference episode,
  ) async {
    final connection = state.connection;
    if (connection == null) return const [];
    final results = <String, JellyfinMediaItem>{};
    final series = <String, JellyfinMediaItem>{};
    final budget = _EpisodeLookupBudget();

    void addResult(JellyfinMediaItem candidate) {
      final existing = results[candidate.id];
      if (existing == null) {
        results[candidate.id] = candidate;
        return;
      }
      // Search often returns the playable episode before hierarchy traversal
      // supplies its authoritative parent IDs/year. Preserve the playable
      // shell and deterministically enrich it instead of keeping arrival order.
      results[candidate.id] = existing.withSeriesProviderIds(
        {...existing.seriesProviderIds, ...candidate.seriesProviderIds},
        productionYear:
            candidate.seriesProductionYear ?? existing.seriesProductionYear,
      );
    }

    final searchTermSet = <String>{};
    for (final title in libraryCatalogHierarchySearchTerms(episode)) {
      searchTermSet
        ..add(title)
        // Jellyfin's metadata providers may normalize decorative punctuation.
        ..add(normalizeLibraryTitle(title));
      if (searchTermSet.length >= 10) break;
    }
    final searchTerms = searchTermSet.take(10).toList(growable: false);

    Future<List<JellyfinMediaItem>?> searchAlias(String title) async {
      if (!budget.claim()) return null;
      try {
        return await _client.search(connection, title, limit: 40);
      } catch (_) {
        return null;
      }
    }

    final searches = await Future.wait(searchTerms.map(searchAlias));
    var successfulSearches = 0;
    for (final items in searches) {
      if (items == null) continue;
      successfulSearches++;
      for (final item in items) {
        if (jellyfinItemMatchesEpisode(item: item, episode: episode) &&
            _isPlayableJellyfinCandidate(item)) {
          addResult(item);
        } else if (item.type == 'Series' &&
            librarySeriesMayContainEpisode(
              serverSeriesTitle: item.name,
              episode: episode,
              serverYear: item.productionYear,
              providerIds: item.providerIds,
            )) {
          series.putIfAbsent(item.id, () => item);
        }
      }
    }
    if (searchTerms.isNotEmpty && successfulSearches == 0) {
      throw const JellyfinException(
        'Jellyfin search is currently unavailable.',
      );
    }

    // Jellyfin search commonly returns the matched Series but not episodes
    // whose individual names do not contain the show title. Traverse a small,
    // exact-title set so the unified picker can still find those episodes
    // without scanning the viewer's whole private library.
    for (final show in series.values.take(3)) {
      List<JellyfinMediaItem> children;
      try {
        children = await _boundedChildItems(
          connection,
          show.id,
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
          productionYear: show.productionYear,
        );
        if (jellyfinItemMatchesEpisode(item: candidate, episode: episode) &&
            _isPlayableJellyfinCandidate(candidate)) {
          addResult(candidate);
        }
      }
      final expectedSeason = libraryCatalogSeasonHint(episode);
      final allSeasons = children
          .where((item) => item.type == 'Season')
          .toList(growable: false);
      final exactSeasons = expectedSeason == null
          ? const <JellyfinMediaItem>[]
          : allSeasons
                .where((item) => _jellyfinSeasonNumber(item) == expectedSeason)
                .toList(growable: false);
      final orderedSeasons = <JellyfinMediaItem>[
        ...exactSeasons,
        ...allSeasons.where((item) => !exactSeasons.contains(item)),
      ];
      for (final season in orderedSeasons.take(
        _episodeLookupSeasonLimitPerSeries,
      )) {
        if (budget.remaining <= 0) break;
        try {
          final episodes = await _boundedChildItems(
            connection,
            season.id,
            budget: budget,
          );
          for (final item in episodes) {
            final candidate = item.withSeriesProviderIds(
              show.providerIds,
              productionYear: show.productionYear,
            );
            if (jellyfinItemMatchesEpisode(item: candidate, episode: episode) &&
                _isPlayableJellyfinCandidate(candidate)) {
              addResult(candidate);
            }
          }
        } catch (_) {
          // One unreadable season must not hide another exact local match.
        }
      }
    }
    return List.unmodifiable(results.values.take(12));
  }

  static bool _isPlayableJellyfinCandidate(JellyfinMediaItem item) =>
      item.isPlayable && RegExp(r'^[A-Za-z0-9_-]{8,160}$').hasMatch(item.id);

  static int? _jellyfinSeasonNumber(JellyfinMediaItem item) {
    final indexed = item.episodeNumber;
    if (indexed != null && indexed >= 0 && indexed <= 1000) return indexed;
    final normalized = normalizeLibraryTitle(item.name);
    if (normalized == 'special' || normalized == 'specials') return 0;
    final match = RegExp(r'^season (\d{1,3})$').firstMatch(normalized);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  Uri streamUri(JellyfinMediaItem item) {
    final connection = state.connection;
    if (connection == null) {
      throw const JellyfinException('Connect Jellyfin before playing media.');
    }
    return _client.streamUri(connection, item);
  }

  JellyfinPlaybackPlan playbackPlan(
    JellyfinMediaItem item, {
    required String playSessionId,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
  }) {
    final connection = state.connection;
    if (connection == null) {
      throw const JellyfinException('Connect Jellyfin before playing media.');
    }
    return _client.playbackPlan(
      connection,
      item,
      playSessionId: playSessionId,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      requestedAudio: requestedAudio,
    );
  }

  JellyfinPlaybackPlan compatibilityPlaybackPlan(
    JellyfinMediaItem item, {
    required String playSessionId,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
  }) {
    final connection = state.connection;
    if (connection == null) {
      throw const JellyfinException('Connect Jellyfin before playing media.');
    }
    return _client.compatibilityPlaybackPlan(
      connection,
      item,
      playSessionId: playSessionId,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      requestedAudio: requestedAudio,
    );
  }

  Uri? imageUri(JellyfinMediaItem item) {
    final connection = state.connection;
    return connection == null ? null : _client.imageUri(connection, item);
  }

  Map<String, String> playbackHeaders() {
    final connection = state.connection;
    return connection == null ? const {} : _client.playbackHeaders(connection);
  }

  Future<Uint8List> imageBytes(Uri uri) {
    final connection = state.connection;
    if (connection == null) {
      throw const JellyfinException('Connect Jellyfin before loading artwork.');
    }
    return _client.imageBytes(connection, uri);
  }

  Duration serverResumePosition(JellyfinMediaItem item) => item.resumePosition;

  String createPlaybackSessionId() {
    final random = Random.secure();
    return List<int>.generate(
      24,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> reportPlaybackStarted(
    JellyfinMediaItem item, {
    required String playSessionId,
    required Duration position,
    JellyfinPlayMethod playMethod = JellyfinPlayMethod.directPlay,
  }) async {
    final connection = state.connection;
    if (connection == null) return;
    try {
      await _client.reportPlaybackStarted(
        connection,
        item,
        playSessionId: playSessionId,
        position: position,
        playMethod: playMethod,
      );
    } catch (_) {
      // Server progress is best effort and must never block local playback.
    }
  }

  Future<void> reportPlaybackStopped(
    JellyfinMediaItem item, {
    required String playSessionId,
    required Duration position,
    JellyfinPlayMethod playMethod = JellyfinPlayMethod.directPlay,
  }) async {
    final connection = state.connection;
    if (connection == null) return;
    try {
      await _client.reportPlaybackStopped(
        connection,
        item,
        playSessionId: playSessionId,
        position: position,
        playMethod: playMethod,
      );
    } catch (_) {
      // A temporarily offline server cannot turn a successful play into an
      // app error. The encrypted local checkpoint remains available.
    }
  }

  Future<void> reportPlaybackProgress(
    JellyfinMediaItem item, {
    required String playSessionId,
    required Duration position,
    bool paused = false,
    JellyfinPlayMethod playMethod = JellyfinPlayMethod.directPlay,
  }) async {
    final connection = state.connection;
    if (connection == null) return;
    try {
      await _client.reportPlaybackProgress(
        connection,
        item,
        playSessionId: playSessionId,
        position: position,
        paused: paused,
        playMethod: playMethod,
      );
    } catch (_) {
      // Progress reporting is deliberately best effort. Playback stays usable
      // when a home server sleeps or the network changes mid-stream.
    }
  }

  Future<Duration> resumePosition(Uri uri) async {
    final value = await _storage.read(key: _resumeKey(uri));
    return Duration(
      milliseconds: (int.tryParse(value ?? '') ?? 0).clamp(0, 1 << 53),
    );
  }

  Future<void> saveResumePosition(Uri uri, Duration position) async {
    if (position < const Duration(seconds: 5)) return;
    await _storage.write(
      key: _resumeKey(uri),
      value: position.inMilliseconds.toString(),
    );
  }

  Future<void> clearResumePosition(Uri uri) =>
      _storage.delete(key: _resumeKey(uri));

  String checkpointId(Uri uri) =>
      sha256.convert(utf8.encode(uri.toString())).toString();

  Future<void> _loadItems({
    required String? parentId,
    required List<JellyfinBreadcrumb> breadcrumbs,
    bool append = false,
  }) async {
    final connection = state.connection;
    if (connection == null || state.busy) return;
    final generation = ++_generation;
    state = state.copyWith(busy: true, message: 'Loading Jellyfin library…');
    try {
      final page = await _client.items(
        connection,
        parentId: parentId,
        startIndex: append ? state.nextStartIndex : 0,
      );
      if (generation != _generation) return;
      state = state.copyWith(
        items: append
            ? List.unmodifiable([...state.items, ...page.items])
            : page.items,
        breadcrumbs: List.unmodifiable(breadcrumbs),
        totalCount: page.totalCount,
        nextStartIndex: page.nextStartIndex,
        message: page.items.isEmpty ? 'This Jellyfin folder is empty.' : null,
      );
    } catch (error) {
      if (generation != _generation) return;
      state = state.copyWith(message: _friendlyError(error));
    } finally {
      if (generation == _generation) state = state.copyWith(busy: false);
    }
  }

  Future<String> _deviceId() async {
    final saved = await _storage.read(key: _jellyfinDeviceIdKey);
    if (saved?.isNotEmpty == true) return saved!;
    final random = Random.secure();
    final value = List<int>.generate(
      24,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _jellyfinDeviceIdKey, value: value);
    return value;
  }

  Future<void> _persistConnection(JellyfinConnection connection) async {
    await Future.wait([
      _storage.write(
        key: _jellyfinBaseUrlKey,
        value: connection.baseUri.toString(),
      ),
      _storage.write(key: _jellyfinServerNameKey, value: connection.serverName),
      _storage.write(
        key: _jellyfinServerVersionKey,
        value: connection.serverVersion,
      ),
      _storage.write(key: _jellyfinUserIdKey, value: connection.userId),
      _storage.write(key: _jellyfinUsernameKey, value: connection.username),
      _storage.write(
        key: _jellyfinAccessTokenKey,
        value: connection.accessToken,
      ),
      _storage.write(key: _jellyfinDeviceIdKey, value: connection.deviceId),
    ]);
  }

  static List<LocalMediaDocument> _decodeDocumentIndex({
    required String? indexValue,
    required String? legacyValue,
  }) {
    final candidates = <LocalMediaDocument>[];
    if (indexValue != null) {
      try {
        final decoded = jsonDecode(indexValue);
        if (decoded is Map &&
            decoded['version'] == 2 &&
            decoded['documents'] is List) {
          for (final value in decoded['documents'] as List) {
            final document = _decodeDocumentMap(value);
            if (document != null) candidates.add(document);
          }
        }
      } catch (_) {
        // A malformed index is repaired from any valid legacy entry below.
      }
    }
    if (legacyValue != null) {
      try {
        final document = _decodeDocumentMap(jsonDecode(legacyValue));
        if (document != null) candidates.add(document);
      } catch (_) {
        // Corrupt legacy data fails closed and is removed during repair.
      }
    }
    return _dedupeAndCapDocuments(candidates, requirePersisted: true);
  }

  static LocalMediaDocument? _decodeDocumentMap(Object? value) {
    try {
      if (value is! Map) return null;
      final rawName = value['name'];
      if (rawName is! String ||
          rawName.trim().isEmpty ||
          rawName.trim().length > 300) {
        return null;
      }
      final document = LocalMediaDocument.fromMap(
        value.cast<Object?, Object?>(),
      );
      return isSafeLocalVideoDocument(
            document,
            requirePersistedPermission: true,
          )
          ? document
          : null;
    } catch (_) {
      return null;
    }
  }

  static List<LocalMediaDocument> _dedupeAndCapDocuments(
    Iterable<LocalMediaDocument> documents, {
    bool requirePersisted = false,
  }) {
    final seen = <String>{};
    final result = <LocalMediaDocument>[];
    for (final document in documents) {
      if (!isSafeLocalVideoDocument(
            document,
            requirePersistedPermission: requirePersisted,
          ) ||
          !seen.add(document.uri.toString())) {
        continue;
      }
      result.add(document);
      if (result.length == maxPersistedLocalDocuments) break;
    }
    return List.unmodifiable(result);
  }

  Future<void> _repairDocumentIndex(
    List<LocalMediaDocument> documents, {
    required bool hadIndexValue,
    required bool hadLegacyValue,
  }) async {
    if (!hadIndexValue && !hadLegacyValue) return;
    try {
      await _persistDocumentIndex(documents);
      if (hadLegacyValue) {
        await _storage.delete(key: _recentLocalDocumentKey);
      }
    } catch (_) {
      // Keep the valid in-memory index even if encrypted storage is full.
    }
  }

  Future<void> _persistDocumentIndex(
    Iterable<LocalMediaDocument> documents,
  ) async {
    final durable = _dedupeAndCapDocuments(documents, requirePersisted: true);
    if (durable.isEmpty) {
      await _storage.delete(key: _localDocumentIndexKey);
      return;
    }
    await _storage.write(
      key: _localDocumentIndexKey,
      value: jsonEncode({
        'version': 2,
        'documents': durable.map(_encodeDocument).toList(growable: false),
      }),
    );
  }

  static Map<String, Object?> _encodeDocument(LocalMediaDocument document) => {
    'uri': document.uri.toString(),
    'name': document.name,
    if (document.mimeType != null) 'mimeType': document.mimeType,
    if (document.size != null) 'size': document.size,
    'persistedReadPermission': true,
  };

  static String _resumeKey(Uri uri) =>
      '$_localResumePrefix${sha256.convert(utf8.encode(uri.toString()))}';

  static String _friendlyError(Object error) => switch (error) {
    JellyfinException(:final message) => message,
    _ => 'Local media could not be opened on this device.',
  };
}
