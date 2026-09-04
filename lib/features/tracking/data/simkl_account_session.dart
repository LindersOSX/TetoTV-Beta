import 'dart:convert';

import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/tracking/data/simkl_api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef SimklCacheScopeLoader = Future<String?> Function();

abstract interface class SimklPersistentCache {
  Future<Map<String, dynamic>?> load(String scope);

  Future<void> save(String scope, Map<String, dynamic> payload);

  Future<void> remove(String scope);
}

class TetoTvSimklPersistentCache implements SimklPersistentCache {
  TetoTvSimklPersistentCache(this._database);

  final TetoTvDatabase _database;

  @override
  Future<Map<String, dynamic>?> load(String scope) => _database.cachedJson(
    _key(scope),
    allowExpired: true,
    maxStaleAge: const Duration(days: 90),
  );

  @override
  Future<void> save(String scope, Map<String, dynamic> payload) => _database
      .cacheJson(_key(scope), payload, maxAge: const Duration(days: 90));

  @override
  Future<void> remove(String scope) => _database.removeCachedJson(_key(scope));

  String _key(String scope) => 'simkl_account_sync_v1:$scope';
}

final simklAccountSessionRegistryProvider =
    Provider<SimklAccountSessionRegistry>((ref) {
      final registry = SimklAccountSessionRegistry(
        persistentCache: TetoTvSimklPersistentCache(
          ref.watch(tetoTvDatabaseProvider),
        ),
      );
      ref.onDispose(registry.clear);
      return registry;
    });

/// Owns one in-memory session per credential set while persistent snapshots are
/// scoped only by a verified, non-secret SIMKL profile identity.
class SimklAccountSessionRegistry {
  SimklAccountSessionRegistry({
    required this.persistentCache,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : now = now ?? DateTime.now,
       delay = delay ?? Future<void>.delayed;

  final SimklPersistentCache persistentCache;
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
  final Map<String, SimklAccountSession> _sessions = {};

  SimklAccountSession session({
    required String accessToken,
    required String clientId,
    required String appVersion,
    required SimklCacheScopeLoader cacheScopeLoader,
    Dio? dio,
    SimklPostScheduler? postScheduler,
  }) {
    // This digest exists only in process memory. Persistent keys are produced
    // from the verified profile identity and never from a credential.
    final memoryKey = sha256
        .convert(utf8.encode('$clientId\u0000$appVersion\u0000$accessToken'))
        .toString();
    return _sessions.putIfAbsent(
      memoryKey,
      () => SimklAccountSession(
        client: SimklApiClient(
          accessToken: accessToken,
          clientId: clientId,
          appVersion: appVersion,
          dio: dio,
          postScheduler: postScheduler,
        ),
        persistentCache: persistentCache,
        cacheScopeLoader: cacheScopeLoader,
        now: now,
        delay: delay,
      ),
    );
  }

  void clear() {
    for (final session in _sessions.values) {
      session.invalidate();
    }
    _sessions.clear();
  }

  Future<void> clearPersistent(String? scope) async {
    await clearPersistentScopes([scope]);
  }

  Future<void> clearPersistentScopes(Iterable<String?> scopes) async {
    clear();
    final safeScopes = scopes.map(_safeScope).whereType<String>().toSet();
    await Future.wait([
      for (final scope in safeScopes) persistentCache.remove(scope),
    ]);
  }
}

/// Shared, single-flight SIMKL reads for one verified account.
///
/// The first library read performs one full anime pull. Later reads reuse the
/// durable snapshot and check `/sync/activities` no more than once every 20
/// minutes. Ordinary changes are merged from a timestamped delta; removals are
/// reconciled against SIMKL's compact current-ID response.
class SimklAccountSession {
  SimklAccountSession({
    required this.client,
    required this.persistentCache,
    required this.cacheScopeLoader,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  static const activityCadence = Duration(minutes: 20);
  static const _transientRetryDelay = Duration(seconds: 1);
  static const _transientBackoff = Duration(minutes: 1);
  static const _maximumTransientAttempts = 5;
  static const _maximumTransientDelay = Duration(seconds: 60);

  final SimklApiClient client;
  final SimklPersistentCache persistentCache;
  final SimklCacheScopeLoader cacheScopeLoader;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  String? _scope;
  bool _persistentLoaded = false;
  Future<void>? _persistentLoadRequest;
  SimklActivitySnapshot? _activities;
  SimklActivitySnapshot? _pendingActivities;
  String? _animeDeltaFrom;
  bool _animeRemovalDirty = false;
  DateTime? _lastActivityCheck;
  List<SimklAnimeListEntry>? _anime;
  SimklUserProfile? _profile;
  bool _animeDirty = true;
  bool _profileDirty = true;
  DateTime? _libraryRetryAfter;
  DateTime? _profileRetryAfter;
  Future<void>? _activityRequest;
  Future<List<SimklAnimeListEntry>>? _animeRequest;
  Future<SimklUserProfile>? _profileRequest;
  bool _invalidated = false;

  /// Prevents an in-flight request from restoring account data after the
  /// account has been disconnected or the owning registry has been disposed.
  void invalidate() => _invalidated = true;

  Future<List<SimklAnimeListEntry>> animeLibrary() async {
    await _loadPersistent();
    if (_scope == null && _profile == null) await profile();
    if (_anime == null) return _loadAnimeSingleFlight();
    await _checkActivities();
    final cached = _anime;
    if (cached != null &&
        (!_animeDirty ||
            (_libraryRetryAfter?.isAfter(_now().toUtc()) ?? false))) {
      return cached;
    }
    final active = _animeRequest;
    if (active != null) return active;
    final request = _refreshAnime();
    _animeRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_animeRequest, request)) _animeRequest = null;
    }
  }

  Future<SimklUserProfile> profile() async {
    await _loadPersistent();
    if (_profile == null) return _loadProfileSingleFlight();
    await _checkActivities();
    final cached = _profile;
    if (cached != null &&
        (!_profileDirty ||
            (_profileRetryAfter?.isAfter(_now().toUtc()) ?? false))) {
      return cached;
    }
    return _loadProfileSingleFlight();
  }

  Future<SimklAnimeListEntry?> animeByIds(SimklMediaIds ids) async {
    for (final row in await animeLibrary()) {
      if (_matches(row, ids)) return row;
    }
    return null;
  }

  Future<List<SimklAnimeListEntry>> _loadAnimeSingleFlight() async {
    final active = _animeRequest;
    if (active != null) return active;
    final request = _refreshAnime();
    _animeRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_animeRequest, request)) _animeRequest = null;
    }
  }

  Future<SimklUserProfile> _loadProfileSingleFlight() async {
    final active = _profileRequest;
    if (active != null) return active;
    final request = _refreshProfile();
    _profileRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_profileRequest, request)) _profileRequest = null;
    }
  }

  Future<void> addWatchedEpisodes({
    required SimklMediaIds ids,
    required List<int> episodeNumbers,
    required int completedEpisodes,
  }) async {
    final actualStatus = await client.markAnimeEpisodesWatchedByIds(
      ids: ids,
      episodeNumbers: episodeNumbers,
    );
    final changed = _replaceMatching(ids, (row) {
      final progress = row.progress > completedEpisodes
          ? row.progress
          : completedEpisodes;
      return _copyEntry(
        row,
        status: actualStatus,
        progress: progress,
        watchedEpisodeNumbers: {
          if (row.watchedEpisodeNumbers.isEmpty && row.progress > 0)
            for (var episode = 1; episode <= row.progress; episode++) episode
          else
            ...row.watchedEpisodeNumbers,
          ...episodeNumbers,
        },
      );
    });
    if (!changed) {
      // History can add a title that was not in the prior library. Force the
      // next user-visible read through activities so the delta supplies its
      // canonical SIMKL ID, title, and status without inventing metadata.
      _animeDirty = true;
      _lastActivityCheck = null;
    }
    await _savePersistent();
  }

  Future<String> setStatus({
    required SimklMediaIds ids,
    required String status,
  }) async {
    final actual = await client.setAnimeStatus(ids: ids, status: status);
    final changed = _replaceMatching(
      ids,
      (row) => _copyEntry(row, status: actual),
    );
    if (!changed) {
      _animeDirty = true;
      _lastActivityCheck = null;
    }
    await _savePersistent();
    return actual;
  }

  Future<void> remove(SimklMediaIds ids) async {
    await client.removeAnime(ids);
    final rows = _anime;
    if (rows != null) {
      _anime = List.unmodifiable([
        for (final row in rows)
          if (!_matches(row, ids)) row,
      ]);
      _animeDirty = false;
    }
    await _savePersistent();
  }

  Future<void> _loadPersistent() {
    if (_persistentLoaded) return Future<void>.value();
    final active = _persistentLoadRequest;
    if (active != null) return active;
    final request = _readPersistent();
    _persistentLoadRequest = request;
    return request.whenComplete(() {
      if (identical(_persistentLoadRequest, request)) {
        _persistentLoadRequest = null;
      }
    });
  }

  Future<void> _readPersistent() async {
    final requestedScope = _safeScope(await cacheScopeLoader());
    _scope = requestedScope;
    if (requestedScope == null) {
      _persistentLoaded = true;
      return;
    }
    final value = await persistentCache.load(requestedScope);
    _persistentLoaded = true;
    if (value == null || value['schema'] != 2) return;
    final checkedAt = DateTime.tryParse(value['checkedAt']?.toString() ?? '');
    final activitiesValue = value['activities'];
    final profile = SimklUserProfile.fromJson(value['profile']);
    final rowsValue = value['anime'];
    final rows = <SimklAnimeListEntry>[];
    if (rowsValue is List) {
      for (final item in rowsValue) {
        final row = SimklAnimeListEntry.fromJson(item);
        if (row != null) rows.add(row);
      }
      _anime = List.unmodifiable(rows);
      _animeDirty = false;
    }
    if (activitiesValue is Map) {
      _activities = SimklActivitySnapshot.fromJson(
        Map<String, dynamic>.from(activitiesValue),
      );
    }
    if (_anime != null && _activities == null) {
      // A library without its committed activity watermark cannot be merged
      // safely: adopting the next activities response as a baseline would
      // make an incomplete or interrupted snapshot appear current. Discard
      // only the library so the next read performs the documented full pull.
      _anime = null;
      _animeDirty = true;
    }
    if (profile != null) {
      _profile = profile;
      _profileDirty = false;
    }
    _lastActivityCheck = checkedAt?.toUtc();
  }

  Future<void> _checkActivities() async {
    final checkedAt = _lastActivityCheck;
    final now = _now().toUtc();
    if (checkedAt != null && now.difference(checkedAt) < activityCadence) {
      return;
    }
    final active = _activityRequest;
    if (active != null) return active;
    final request = () async {
      final previous = _activities;
      late final SimklActivitySnapshot latest;
      try {
        latest = await _readWithTransientRetry(client.activities);
      } on SimklApiException catch (error) {
        if (!_isTransient(error) || (_anime == null && _profile == null)) {
          rethrow;
        }
        // Keep a durable stale snapshot usable during a brief outage and do
        // not let three simultaneous status shelves hammer the API.
        _lastActivityCheck = now;
        return;
      }
      if (previous == null) {
        final hasCachedAnime = _anime != null;
        final hasCachedProfile = _profile != null;
        if (hasCachedAnime || hasCachedProfile) {
          // A resource restored without its committed watermark cannot adopt
          // today's activities as proof that the older value is current.
          // Refresh it authoritatively, then commit the new watermark.
          _animeDirty = hasCachedAnime;
          _profileDirty = hasCachedProfile;
          _animeDeltaFrom = null;
          _animeRemovalDirty = false;
          _pendingActivities = latest;
        } else {
          // A resource with no local snapshot will do its own initial load; it
          // must not hold an unrelated resource's activity commit open.
          _animeDirty = false;
          _profileDirty = false;
          _activities = latest;
        }
      } else {
        final animeChanged =
            _anime != null && latest.animeAll != previous.animeAll;
        final removalChanged =
            _anime != null &&
            latest.animeRemovedFromList != previous.animeRemovedFromList;
        final settingsChanged =
            _profile != null && latest.settingsAll != previous.settingsAll;
        if (animeChanged || removalChanged) {
          _animeDirty = true;
          _animeDeltaFrom = previous.all;
          _animeRemovalDirty = removalChanged;
        }
        if (settingsChanged) {
          _profileDirty = true;
        }
        if (animeChanged || removalChanged || settingsChanged) {
          // Keep the prior committed watermark until every corresponding
          // delta has succeeded. A crash or failed request will therefore
          // repeat the safe delta instead of silently skipping it.
          _pendingActivities = latest;
        } else {
          _activities = latest;
          _pendingActivities = null;
        }
      }
      _lastActivityCheck = now;
      await _savePersistent();
    }();
    _activityRequest = request;
    try {
      await request;
    } finally {
      if (identical(_activityRequest, request)) _activityRequest = null;
    }
  }

  Future<List<SimklAnimeListEntry>> _refreshAnime() async {
    final cached = _anime;
    try {
      if (cached == null) {
        // Phase 1: one full pull, followed by the bootstrap watermark.
        final rows = await _readWithTransientRetry(() => client.animeLibrary());
        final latest = await _readWithTransientRetry(client.activities);
        _anime = List.unmodifiable(rows);
        _activities = latest;
        _pendingActivities = null;
        _animeDeltaFrom = null;
        _animeRemovalDirty = false;
        _lastActivityCheck = _now().toUtc();
      } else {
        final pending = _pendingActivities;
        if (pending == null) return cached;
        var rows = cached;
        if (pending.animeAll != _activities?.animeAll) {
          final since = _animeDeltaFrom;
          final changed = await _readWithTransientRetry(
            () => client.animeLibrary(dateFrom: since),
          );
          rows = since == null ? changed : _mergeAnime(rows, changed);
        }
        if (_animeRemovalDirty) {
          final currentIds = await _readWithTransientRetry(
            client.animeLibraryIds,
          );
          rows = List.unmodifiable([
            for (final row in rows)
              if (currentIds.contains(row.simklId)) row,
          ]);
        }
        _anime = List.unmodifiable(rows);
        _commitAnimeActivities(pending);
      }
      _animeDirty = false;
      _libraryRetryAfter = null;
      await _savePersistent();
      return _anime!;
    } on SimklApiException catch (error) {
      if (!_isTransient(error) || cached == null) rethrow;
      _libraryRetryAfter = _now().toUtc().add(_transientBackoff);
      return cached;
    }
  }

  Future<SimklUserProfile> _refreshProfile() async {
    try {
      final value = await _readWithTransientRetry(client.profile);
      _profile = value;
      _profileDirty = false;
      _profileRetryAfter = null;
      _scope ??= _profileScope(value);
      final pending = _pendingActivities;
      if (pending != null) {
        _commitProfileActivities(pending);
      } else if (_activities == null) {
        // Bootstrap the activity watermark immediately after the initial
        // authoritative profile read. A profile-only snapshot cannot safely
        // determine whether a later cached name or avatar is still current.
        _activities = await _readWithTransientRetry(client.activities);
        _lastActivityCheck = _now().toUtc();
      }
      await _savePersistent();
      return value;
    } on SimklApiException catch (error) {
      final cached = _profile;
      if (!_isTransient(error) || cached == null) rethrow;
      _profileRetryAfter = _now().toUtc().add(_transientBackoff);
      return cached;
    }
  }

  Future<T> _readWithTransientRetry<T>(Future<T> Function() operation) async {
    var delay = _transientRetryDelay;
    for (var attempt = 1; ; attempt++) {
      try {
        return await operation();
      } on SimklApiException catch (error) {
        if (!_isTransient(error) || attempt >= _maximumTransientAttempts) {
          rethrow;
        }
        var wait = delay;
        if (error is SimklRateLimitException &&
            error.retryAfter != null &&
            error.retryAfter! > wait) {
          wait = error.retryAfter!;
        }
        if (wait > _maximumTransientDelay) wait = _maximumTransientDelay;
        await _delay(wait);
        final doubledSeconds = delay.inSeconds * 2;
        delay = Duration(
          seconds: doubledSeconds > _maximumTransientDelay.inSeconds
              ? _maximumTransientDelay.inSeconds
              : doubledSeconds,
        );
      }
    }
  }

  void _commitAnimeActivities(SimklActivitySnapshot latest) {
    final previous = _activities;
    _activities = SimklActivitySnapshot(
      all: latest.all,
      animeAll: latest.animeAll,
      animeRemovedFromList: latest.animeRemovedFromList,
      settingsAll: previous?.settingsAll,
    );
    _animeDeltaFrom = null;
    _animeRemovalDirty = false;
    if (_profile == null || !_profileDirty) {
      _activities = latest;
      _pendingActivities = null;
    }
  }

  void _commitProfileActivities(SimklActivitySnapshot latest) {
    final previous = _activities;
    _activities = SimklActivitySnapshot(
      all: _anime != null && _animeDirty ? previous?.all : latest.all,
      animeAll: _anime != null && _animeDirty
          ? previous?.animeAll
          : latest.animeAll,
      animeRemovedFromList: _anime != null && _animeDirty
          ? previous?.animeRemovedFromList
          : latest.animeRemovedFromList,
      settingsAll: latest.settingsAll,
    );
    if (_anime == null || !_animeDirty) {
      _activities = latest;
      _pendingActivities = null;
    }
  }

  bool _replaceMatching(
    SimklMediaIds ids,
    SimklAnimeListEntry Function(SimklAnimeListEntry) replace,
  ) {
    final rows = _anime;
    if (rows == null) return false;
    var changed = false;
    _anime = List.unmodifiable([
      for (final row in rows)
        if (_matches(row, ids)) ...[replace(row)] else ...[row],
    ]);
    for (final row in rows) {
      if (_matches(row, ids)) {
        changed = true;
        break;
      }
    }
    return changed;
  }

  Future<void> _savePersistent() async {
    if (_invalidated) return;
    _scope ??= _profile == null ? null : _profileScope(_profile!);
    final scope = _scope;
    if (scope == null) return;
    await persistentCache.save(scope, {
      'schema': 2,
      // A pending watermark exists only in memory. Persisting a recent check
      // beside the older committed watermark could hide an interrupted delta
      // for a full cadence after restart, so force an immediate recheck.
      'checkedAt': _pendingActivities == null
          ? _lastActivityCheck?.toUtc().toIso8601String()
          : null,
      'activities': _activities?.toJson(),
      'profile': _profile?.toJson(),
      'anime': _anime == null
          ? null
          : [for (final row in _anime!) row.toJson()],
    });
    // A save already handed to the database cannot be cancelled. If cleanup
    // raced it, remove the just-written row once the write completes.
    if (_invalidated) await persistentCache.remove(scope);
  }
}

bool _matches(SimklAnimeListEntry row, SimklMediaIds ids) =>
    (ids.simkl != null && row.simklId == ids.simkl) ||
    (ids.anilist != null && row.anilistId == ids.anilist) ||
    (ids.mal != null && row.malId == ids.mal);

SimklAnimeListEntry _copyEntry(
  SimklAnimeListEntry row, {
  String? status,
  int? progress,
  Set<int>? watchedEpisodeNumbers,
}) => SimklAnimeListEntry(
  simklId: row.simklId,
  anilistId: row.anilistId,
  malId: row.malId,
  title: row.title,
  status: status ?? row.status,
  progress: progress ?? row.progress,
  totalEpisodes: row.totalEpisodes,
  posterPath: row.posterPath,
  slug: row.slug,
  score: row.score,
  updatedAt: row.updatedAt,
  watchedEpisodeNumbers: watchedEpisodeNumbers ?? row.watchedEpisodeNumbers,
);

bool _isTransient(SimklApiException error) {
  final status = error.statusCode;
  return error.retryable ||
      status == 429 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504;
}

List<SimklAnimeListEntry> _mergeAnime(
  List<SimklAnimeListEntry> cached,
  List<SimklAnimeListEntry> changed,
) {
  if (changed.isEmpty) return cached;
  final replacements = {for (final row in changed) row.simklId: row};
  final merged = <SimklAnimeListEntry>[
    for (final row in cached) replacements.remove(row.simklId) ?? row,
    ...replacements.values,
  ];
  return List.unmodifiable(merged);
}

String? _safeScope(String? value) {
  final scope = value?.trim();
  if (scope == null || !RegExp(r'^[a-z0-9][a-z0-9_-]{0,99}$').hasMatch(scope)) {
    return null;
  }
  return scope;
}

String simklProfileCacheScope(String username) {
  final digest = sha256.convert(
    utf8.encode('simkl:${username.toLowerCase().trim()}'),
  );
  return 'simkl-${digest.toString().substring(0, 20)}';
}

String _profileScope(SimklUserProfile profile) =>
    simklProfileCacheScope(profile.username);
