// The public constructor uses descriptive parameter names while the retained
// dependencies stay private.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/episode_release_search_cache.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final episodeDiscoveryPrefetchControllerProvider =
    Provider<EpisodeDiscoveryPrefetchController>((ref) {
      final controller = EpisodeDiscoveryPrefetchController(
        releaseSearch: ref.watch(episodeReleaseSearchCacheProvider),
        webSearch: ref.watch(webStreamAggregatorProvider),
      );
      ref.onDispose(() => unawaited(controller.dispose()));
      return controller;
    });

typedef EpisodeDiscoveryPrefetcher =
    EpisodeDiscoveryPrefetchHandle Function(
      EpisodeReference episode, {
      required SettingsPreferences preferences,
    });

final episodeDiscoveryPrefetcherProvider = Provider<EpisodeDiscoveryPrefetcher>(
  (ref) => ref.watch(episodeDiscoveryPrefetchControllerProvider).prefetch,
);

/// Warms only source discovery. It never creates a debrid download and never
/// opens a playback-proxy session merely because a details page is visible.
/// The resolver and next-episode preparer reuse the shared search snapshots.
class EpisodeDiscoveryPrefetchController {
  EpisodeDiscoveryPrefetchController({
    required EpisodeReleaseSearchCache releaseSearch,
    required WebStreamAggregator webSearch,
  }) : _releaseSearch = releaseSearch.watch,
       _webSearch = webSearch.watchSearchIncrementally;

  EpisodeDiscoveryPrefetchController.withWatchers({
    required Stream<ReleaseSearchProgress> Function(EpisodeReference episode)
    releaseSearch,
    required Stream<WebStreamSearchProgress> Function(EpisodeReference episode)
    webSearch,
  }) : _releaseSearch = releaseSearch,
       _webSearch = webSearch;

  final Stream<ReleaseSearchProgress> Function(EpisodeReference episode)
  _releaseSearch;
  final Stream<WebStreamSearchProgress> Function(EpisodeReference episode)
  _webSearch;
  final Map<String, _PrefetchOperation> _inFlight = {};

  EpisodeDiscoveryPrefetchHandle prefetch(
    EpisodeReference episode, {
    required SettingsPreferences preferences,
  }) {
    final key = _key(episode, preferences);
    final existing = _inFlight[key];
    if (existing != null) return existing.handle;
    final operation = _PrefetchOperation();
    _inFlight[key] = operation;
    operation.start(
      _run(episode, preferences, operation),
      onComplete: () {
        if (identical(_inFlight[key], operation)) _inFlight.remove(key);
      },
    );
    return operation.handle;
  }

  Future<void> _run(
    EpisodeReference episode,
    SettingsPreferences preferences,
    _PrefetchOperation operation,
  ) async {
    Future<void> releaseSearch() {
      if (!preferences.debridStreamsEnabled &&
          !preferences.directTorrentStreamingEnabled) {
        return Future<void>.value();
      }
      return operation.observe<ReleaseSearchProgress>(
        _releaseSearch(episode),
        isComplete: (progress) => progress.isComplete,
      );
    }

    Future<void> webSearch() {
      if (!preferences.webStreamsEnabled) return Future<void>.value();
      return operation.observe<WebStreamSearchProgress>(
        _webSearch(episode),
        isComplete: (progress) => progress.isComplete,
      );
    }

    await Future.wait([releaseSearch(), webSearch()]);
  }

  Future<void> dispose() async {
    final operations = _inFlight.values.toSet().toList(growable: false);
    _inFlight.clear();
    await Future.wait([for (final operation in operations) operation.cancel()]);
  }
}

class EpisodeDiscoveryPrefetchHandle {
  const EpisodeDiscoveryPrefetchHandle({
    required this.done,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  const EpisodeDiscoveryPrefetchHandle._(this.done, this._cancel);

  factory EpisodeDiscoveryPrefetchHandle.completed([Future<void>? work]) {
    final done = work ?? Future<void>.value();
    return EpisodeDiscoveryPrefetchHandle._(done, () async {});
  }

  final Future<void> done;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

class _PrefetchOperation {
  final Completer<void> _cancelled = Completer<void>();
  late final EpisodeDiscoveryPrefetchHandle handle;
  late final Future<void> _done;

  void start(Future<void> work, {required void Function() onComplete}) {
    _done = work.catchError((_) {}).whenComplete(onComplete);
    handle = EpisodeDiscoveryPrefetchHandle._(_done, cancel);
  }

  Future<void> observe<T>(
    Stream<T> stream, {
    required bool Function(T value) isComplete,
  }) async {
    if (_cancelled.isCompleted) return;
    final done = Completer<void>();
    late final StreamSubscription<T> subscription;
    subscription = stream.listen(
      (value) {
        if (isComplete(value) && !done.isCompleted) done.complete();
      },
      onError: (_, _) {
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    unawaited(
      _cancelled.future.then((_) {
        if (!done.isCompleted) done.complete();
      }),
    );
    try {
      await done.future;
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> cancel() async {
    if (!_cancelled.isCompleted) _cancelled.complete();
    await _done;
  }
}

String _key(EpisodeReference episode, SettingsPreferences preferences) => [
  episode.anilistMediaId,
  episode.malMediaId ?? 0,
  episode.episode,
  preferences.debridStreamsEnabled ? 1 : 0,
  preferences.directTorrentStreamingEnabled ? 1 : 0,
  preferences.webStreamsEnabled ? 1 : 0,
].join(':');
