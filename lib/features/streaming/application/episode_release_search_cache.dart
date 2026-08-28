import 'dart:async';

import 'package:anime_tv/core/config/app_config.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/data/hosted_release_source.dart';
import 'package:anime_tv/features/streaming/data/stremio_torrent_release_source.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final configuredReleaseSourceProvider = Provider<ReleaseSource?>((ref) {
  final userSources = ref.watch(userTorrentSourcesControllerProvider);
  final sources = <ReleaseSource>[
    for (final manifestUrl in userSources.manifestUrls)
      StremioTorrentReleaseSource(manifestUrl: manifestUrl),
    if (AppConfig.hasReleaseResolver)
      HostedReleaseSource(baseUrl: AppConfig.releaseResolverBaseUrl),
  ];
  return sources.isEmpty ? null : CompositeReleaseSource(sources);
});

final episodeReleaseSearchCacheProvider = Provider<EpisodeReleaseSearchCache>((
  ref,
) {
  final cache = EpisodeReleaseSearchCache(
    ref.watch(configuredReleaseSourceProvider),
  );
  ref.onDispose(() => unawaited(cache.dispose()));
  return cache;
});

/// Shares one bounded torrent-source search between the details screen,
/// autoplay preparation and the visible resolver.
///
/// Completed snapshots remain reusable briefly, while an in-flight search is
/// kept alive for a short handoff grace after its last observer goes away.
class EpisodeReleaseSearchCache {
  EpisodeReleaseSearchCache(
    this._source, {
    this.completedTtl = const Duration(minutes: 5),
    this.zeroListenerGrace = const Duration(seconds: 3),
    this.maxSessions = 12,
    DateTime Function()? clock,
  }) : assert(maxSessions > 0),
       _clock = clock ?? DateTime.now;

  final ReleaseSource? _source;
  final Duration completedTtl;
  final Duration zeroListenerGrace;
  final int maxSessions;
  final DateTime Function() _clock;
  final Map<String, _SharedReleaseSearchSession> _sessions = {};

  Stream<ReleaseSearchProgress> watch(
    EpisodeReference episode, {
    bool refresh = false,
  }) {
    final key = _episodeSearchKey(episode);
    final existing = _sessions[key];
    final expired =
        existing != null &&
        existing.isComplete &&
        _clock().difference(existing.completedAt ?? existing.startedAt) >
            completedTtl;
    final replace =
        existing == null ||
        existing.wasAbandoned ||
        expired ||
        (refresh && existing.isComplete);
    final session = replace ? _start(key, episode) : existing;
    return session.stream;
  }

  ReleaseSearchProgress? snapshot(EpisodeReference episode) =>
      _sessions[_episodeSearchKey(episode)]?.latest;

  Future<void> dispose() async {
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    await Future.wait([for (final session in sessions) session.dispose()]);
  }

  _SharedReleaseSearchSession _start(String key, EpisodeReference episode) {
    _evictForStart();
    final session = _SharedReleaseSearchSession(
      zeroListenerGrace: zeroListenerGrace,
      clock: _clock,
    );
    _sessions[key] = session;
    final source = _source;
    final stream = switch (source) {
      null => Stream.value(const ReleaseSearchProgress()),
      CompositeReleaseSource() => source.searchIncrementally(episode),
      _ => searchReleaseSourcesIncrementally([source], episode),
    };
    unawaited(session.run(stream).whenComplete(_prune));
    return session;
  }

  void _evictForStart() {
    if (_sessions.length < maxSessions) return;
    final candidates = _sessions.entries.toList(growable: false)
      ..sort((left, right) {
        int evictionRank(_SharedReleaseSearchSession session) {
          if (session.isComplete) return 0;
          if (session.listenerCount == 0) return 1;
          return 2;
        }

        final rank = evictionRank(
          left.value,
        ).compareTo(evictionRank(right.value));
        if (rank != 0) return rank;
        return left.value.startedAt.compareTo(right.value.startedAt);
      });
    final oldest = candidates.first;
    _sessions.remove(oldest.key);
    unawaited(oldest.value.dispose());
  }

  void _prune() {
    if (_sessions.length <= maxSessions) return;
    final completed =
        _sessions.entries
            .where((entry) => entry.value.isComplete)
            .toList(growable: false)
          ..sort((left, right) {
            final leftAt = left.value.completedAt ?? left.value.startedAt;
            final rightAt = right.value.completedAt ?? right.value.startedAt;
            return leftAt.compareTo(rightAt);
          });
    for (final entry in completed) {
      if (_sessions.length <= maxSessions) break;
      _sessions.remove(entry.key);
    }
  }
}

String _episodeSearchKey(EpisodeReference episode) => [
  episode.anilistMediaId,
  episode.malMediaId ?? 0,
  episode.episode,
  episode.year ?? 0,
  episode.title.trim().toLowerCase(),
].join(':');

class _SharedReleaseSearchSession {
  _SharedReleaseSearchSession({
    required this.zeroListenerGrace,
    required this.clock,
  }) : startedAt = clock();

  final Duration zeroListenerGrace;
  final DateTime Function() clock;
  final DateTime startedAt;
  final StreamController<ReleaseSearchProgress> _updates =
      StreamController<ReleaseSearchProgress>.broadcast(sync: true);
  StreamSubscription<ReleaseSearchProgress>? _sourceSubscription;
  Timer? _zeroListenerTimer;
  Completer<void>? _completion;
  int _listenerCount = 0;

  int get listenerCount => _listenerCount;

  ReleaseSearchProgress? latest;
  DateTime? completedAt;
  bool isComplete = false;
  bool wasAbandoned = false;

  Stream<ReleaseSearchProgress> get stream => Stream.multi((listener) {
    _listenerCount++;
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = null;
    final snapshot = latest;
    if (snapshot != null) listener.add(snapshot);
    final subscription = _updates.stream.listen(
      listener.add,
      onError: listener.addError,
      onDone: listener.close,
    );
    listener.onCancel = () async {
      await subscription.cancel();
      if (_listenerCount > 0) _listenerCount--;
      _scheduleAbandonment();
    };
  });

  Future<void> run(Stream<ReleaseSearchProgress> source) {
    final completion = _completion = Completer<void>();
    _sourceSubscription = source.listen(
      (progress) {
        latest = progress;
        if (!_updates.isClosed) _updates.add(progress);
      },
      onError: (Object error, StackTrace stack) {
        if (!_updates.isClosed) _updates.addError(error, stack);
      },
      onDone: _finish,
    );
    _scheduleAbandonment();
    return completion.future;
  }

  void _scheduleAbandonment() {
    if (isComplete || _listenerCount != 0 || _sourceSubscription == null) {
      return;
    }
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = Timer(zeroListenerGrace, () async {
      if (isComplete || _listenerCount != 0) return;
      wasAbandoned = true;
      await _sourceSubscription?.cancel();
      await _finish();
    });
  }

  Future<void> _finish() async {
    if (isComplete) return;
    isComplete = true;
    completedAt = clock();
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = null;
    if (!_updates.isClosed) await _updates.close();
    final completion = _completion;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  Future<void> dispose() async {
    if (isComplete) return;
    wasAbandoned = true;
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = null;
    await _sourceSubscription?.cancel();
    await _finish();
  }
}
