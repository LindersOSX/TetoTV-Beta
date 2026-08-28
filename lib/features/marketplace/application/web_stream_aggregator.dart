import 'dart:async';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/episode_identity_guard.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const defaultWebProviderDeadline = Duration(seconds: 20);
const defaultMaxConcurrentWebProviders = 2;

/// Carries only audio capability a provider explicitly reported into the
/// playback launch. A legacy unlabeled result remains unknown instead of
/// being mistaken for a Sub-only source merely because `isDubbed` is false.
ReleaseAudioIntent releaseAudioIntentForWebStream(WebStreamResult result) {
  final reported = result.audioCapability;
  if (reported == null) {
    return result.isDubbed
        ? ReleaseAudioIntent.dub
        : ReleaseAudioIntent.unknown;
  }
  return switch (reported) {
    WebStreamAudioCapability.sub => ReleaseAudioIntent.sub,
    WebStreamAudioCapability.dub => ReleaseAudioIntent.dub,
    WebStreamAudioCapability.subAndDub => ReleaseAudioIntent.multi,
    WebStreamAudioCapability.unknown => ReleaseAudioIntent.unknown,
  };
}

final webStreamAggregatorProvider = Provider<WebStreamAggregator>(
  (ref) => WebStreamAggregator(ref.watch(addonStoreProvider)),
);

class WebStreamSearchProgress {
  const WebStreamSearchProgress({
    this.aggregation = const WebStreamAggregation(),
    this.completedProviders = 0,
    this.totalProviders = 0,
    this.pendingProviderNames = const [],
  });

  final WebStreamAggregation aggregation;
  final int completedProviders;
  final int totalProviders;
  final List<String> pendingProviderNames;

  bool get isComplete => completedProviders >= totalProviders;
}

class WebStreamAggregator {
  WebStreamAggregator(
    this._store, {
    this.providerDeadline = defaultWebProviderDeadline,
    this.maxConcurrentProviders = defaultMaxConcurrentWebProviders,
    this.sharedSessionGrace = const Duration(seconds: 2),
  });

  final AddonStore _store;
  final Duration providerDeadline;
  final int maxConcurrentProviders;
  final Duration sharedSessionGrace;
  final Map<String, _SharedWebSearchSession> _sharedSessions = {};

  /// Replays and shares one provider search per episode across resolver and
  /// player routes. A route replacement therefore transfers observation of
  /// the existing bounded worker pool instead of starting another QuickJS
  /// wave while the old route is winding down.
  Stream<WebStreamSearchProgress> watchSearchIncrementally(
    EpisodeReference episode, {
    bool refresh = false,
  }) {
    final key = _episodeSearchKey(episode);
    final existing = _sharedSessions[key];
    final expired =
        existing != null &&
        existing.isComplete &&
        DateTime.now().difference(existing.startedAt) >
            const Duration(minutes: 2);
    final shouldReplace =
        existing == null ||
        existing.wasAbandoned ||
        expired ||
        (refresh && existing.isComplete);
    final session = shouldReplace
        ? _startSharedSession(key, episode)
        : existing;
    return session.stream;
  }

  _SharedWebSearchSession _startSharedSession(
    String key,
    EpisodeReference episode,
  ) {
    final session = _SharedWebSearchSession(
      zeroListenerGrace: sharedSessionGrace,
    );
    _sharedSessions[key] = session;
    unawaited(
      session.run(searchIncrementally(episode)).whenComplete(_pruneSessions),
    );
    return session;
  }

  void _pruneSessions() {
    if (_sharedSessions.length <= 8) return;
    final completed =
        _sharedSessions.entries
            .where((entry) => entry.value.isComplete)
            .toList()
          ..sort(
            (left, right) =>
                left.value.startedAt.compareTo(right.value.startedAt),
          );
    for (final entry in completed) {
      if (_sharedSessions.length <= 8) break;
      _sharedSessions.remove(entry.key);
    }
  }

  Future<WebStreamAggregation> search(EpisodeReference episode) async {
    var result = const WebStreamAggregation();
    await for (final progress in searchIncrementally(episode)) {
      result = progress.aggregation;
    }
    return result;
  }

  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) async* {
    final health = await _store.providerHealth();
    final enabledAddons = (await _store.installedAddons())
        .where((addon) => addon.enabled)
        .toList(growable: false);
    final availabilityFailures = <WebProviderFailure>[];
    final searchable = <InstalledStreamingAddon>[];
    var blockedProviders = 0;
    for (final addon in enabledAddons) {
      final provider = SeanimeJavascriptProvider(addon);
      final failure = installedWebProviderAvailabilityFailure(
        addon,
        health[addon.manifest.id],
      );
      if (failure == null) {
        searchable.add(addon);
        continue;
      }
      availabilityFailures.add(failure);
      _recordProviderSearchOutcome(
        provider,
        status: failure.status.name,
        count: 0,
        stage: failure.stage ?? 'availability',
        reason: failure.reason ?? 'unavailable',
      );
      if (failure.status == WebProviderFailureStatus.advisory) {
        searchable.add(addon);
      } else {
        blockedProviders++;
      }
    }
    final addons = orderInstalledProvidersByHealth(searchable, health);
    final providers = addons.map(SeanimeJavascriptProvider.new).toList();
    await for (final progress in aggregateWebStreamingProvidersIncrementally(
      providers,
      episode,
      deadline: providerDeadline,
      maxConcurrentProviders: maxConcurrentProviders,
      onSuccess: (provider, streams) async {
        final hasStreams = streams.isNotEmpty;
        if (hasStreams) await _store.recordProviderSuccess(provider.id);
        _recordProviderSearchOutcome(
          provider,
          status: hasStreams ? 'success' : 'no_match',
          count: streams.length,
          stage: 'complete',
          reason: hasStreams ? 'streams_returned' : 'empty_result',
        );
      },
      onFailure: (provider, error, noMatch) async {
        final details = seanimeProviderFailureDetails(error);
        final identityNoMatch = error is _EpisodeIdentityNoMatch;
        final stage = identityNoMatch
            ? 'episode_lookup'
            : details?.stage ?? 'runtime';
        final reason = identityNoMatch
            ? 'episode_identity_mismatch'
            : details?.reason ??
                  (error is TimeoutException ? 'timeout' : 'provider_error');
        if (!noMatch) {
          final healthMessage = seanimeProviderFailureMessage(error);
          await _store.recordProviderFailure(
            provider.id,
            healthMessage,
            stage: stage,
            reason: reason,
          );
        }
        _recordProviderSearchOutcome(
          provider,
          status: noMatch ? 'no_match' : 'failed',
          count: 0,
          stage: stage,
          reason: reason,
        );
      },
    )) {
      final providersWithRuntimeStatus = {
        for (final failure in progress.aggregation.failures)
          if (failure.providerId case final id?) id.trim().toLowerCase(),
      };
      yield WebStreamSearchProgress(
        aggregation: mergeWebProviderOutcomes([
          (streams: progress.aggregation.streams, failure: null),
          for (final failure in [
            ...availabilityFailures.where(
              (failure) =>
                  failure.status != WebProviderFailureStatus.advisory ||
                  !providersWithRuntimeStatus.contains(
                    failure.providerId?.trim().toLowerCase(),
                  ),
            ),
            ...progress.aggregation.failures,
          ])
            (streams: const <WebStreamResult>[], failure: failure),
        ]),
        completedProviders: progress.completedProviders + blockedProviders,
        totalProviders: enabledAddons.length,
        pendingProviderNames: progress.pendingProviderNames,
      );
    }
  }

  void _recordProviderSearchOutcome(
    WebStreamingProvider provider, {
    required String status,
    required int count,
    required String stage,
    required String reason,
  }) {
    unawaited(
      _persistProviderSearchOutcome(
        provider,
        status: status,
        count: count,
        stage: stage,
        reason: reason,
      ),
    );
  }

  Future<void> _persistProviderSearchOutcome(
    WebStreamingProvider provider, {
    required String status,
    required int count,
    required String stage,
    required String reason,
  }) async {
    try {
      await _store.database.recordDiagnosticEvent(
        category: 'provider-search',
        message: webProviderSearchDiagnosticMessage(
          provider,
          status: status,
          count: count,
          stage: stage,
          reason: reason,
        ),
      );
    } catch (_) {
      // Diagnostics are best-effort and must never affect provider discovery.
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

class _SharedWebSearchSession {
  _SharedWebSearchSession({required this.zeroListenerGrace});

  final startedAt = DateTime.now();
  final Duration zeroListenerGrace;
  final StreamController<WebStreamSearchProgress> _updates =
      StreamController<WebStreamSearchProgress>.broadcast(sync: true);
  WebStreamSearchProgress? _latest;
  StreamSubscription<WebStreamSearchProgress>? _sourceSubscription;
  Timer? _zeroListenerTimer;
  Completer<void>? _completion;
  int _listenerCount = 0;
  bool isComplete = false;
  bool wasAbandoned = false;

  Stream<WebStreamSearchProgress> get stream => Stream.multi((listener) {
    _listenerCount++;
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = null;
    final latest = _latest;
    if (latest != null) listener.add(latest);
    final subscription = _updates.stream.listen(
      listener.add,
      onError: listener.addError,
      onDone: listener.close,
    );
    listener.onCancel = () async {
      await subscription.cancel();
      if (_listenerCount > 0) _listenerCount--;
      _scheduleAbandonedCancellation();
    };
  });

  Future<void> run(Stream<WebStreamSearchProgress> source) {
    final completion = _completion = Completer<void>();
    _sourceSubscription = source.listen(
      (progress) {
        _latest = progress;
        if (!_updates.isClosed) _updates.add(progress);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_updates.isClosed) _updates.addError(error, stackTrace);
      },
      onDone: _finish,
    );
    _scheduleAbandonedCancellation();
    return completion.future;
  }

  void _scheduleAbandonedCancellation() {
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
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = null;
    if (!_updates.isClosed) await _updates.close();
    final completion = _completion;
    if (completion != null && !completion.isCompleted) completion.complete();
  }
}

List<InstalledStreamingAddon> orderInstalledProvidersByHealth(
  List<InstalledStreamingAddon> addons,
  Map<String, ProviderHealth> health,
) {
  final indexed = addons.indexed
      .map((item) => (index: item.$1, addon: item.$2))
      .toList();
  indexed.sort((left, right) {
    final leftHealth = health[left.addon.manifest.id];
    final rightHealth = health[right.addon.manifest.id];
    final bucket = _providerHealthBucket(
      leftHealth,
    ).compareTo(_providerHealthBucket(rightHealth));
    if (bucket != 0) return bucket;
    if (leftHealth?.lastSuccessAt != null &&
        rightHealth?.lastSuccessAt != null) {
      final recent = rightHealth!.lastSuccessAt!.compareTo(
        leftHealth!.lastSuccessAt!,
      );
      if (recent != 0) return recent;
    }
    final failures = (leftHealth?.consecutiveFailures ?? 0).compareTo(
      rightHealth?.consecutiveFailures ?? 0,
    );
    return failures != 0 ? failures : left.index.compareTo(right.index);
  });
  return indexed.map((item) => item.addon).toList(growable: false);
}

int _providerHealthBucket(ProviderHealth? health) {
  if (health?.lastSuccessAt != null && health!.consecutiveFailures == 0) {
    return 0;
  }
  if (health == null) return 1;
  if (health.consecutiveFailures == 0) return 2;
  return 3;
}

WebProviderFailure? installedWebProviderAvailabilityFailure(
  InstalledStreamingAddon addon,
  ProviderHealth? health,
) {
  final provider = SeanimeJavascriptProvider(addon);
  WebProviderFailure failure({
    required WebProviderFailureStatus status,
    required String message,
    required String reason,
  }) => WebProviderFailure(
    providerName: provider.name,
    providerId: provider.id,
    providerVersion: provider.version,
    repositoryHost: provider.repositoryHost,
    executableHost: provider.executableHost,
    status: status,
    stage: 'availability',
    reason: reason,
    message: message,
  );

  if (!addon.manifest.isCompatible) {
    return failure(
      status: WebProviderFailureStatus.unavailable,
      reason: 'incompatible_runtime',
      message: 'Unavailable because this provider runtime is not supported.',
    );
  }
  final permanentReason =
      health?.lastFailureReason == 'runtime_api' ||
          health?.lastTestReason == 'runtime_api'
      ? 'runtime_api'
      : health?.lastFailureReason == 'unsafe_target' ||
            health?.lastTestReason == 'unsafe_target'
      ? 'unsafe_target'
      : null;
  if (permanentReason != null) {
    return failure(
      status: WebProviderFailureStatus.unavailable,
      reason: permanentReason,
      message: permanentReason == 'runtime_api'
          ? 'Incompatible with the current TetoTV provider runtime. '
                'Update or reset this add-on to test it again.'
          : 'Unavailable because its returned address failed TetoTV network '
                'safety checks.',
    );
  }
  if (health?.isQuarantined == true) {
    final remaining = health!.quarantinedUntil!.difference(DateTime.now());
    final minutes = (remaining.inSeconds / 60).ceil().clamp(1, 30);
    final stage = switch (health.lastFailureStage) {
      'search' || 'title_matching' => 'title search',
      'episode_lookup' => 'episode lookup',
      'server_lookup' => 'server lookup',
      'stream_extraction' => 'stream extraction',
      _ => 'provider',
    };
    return failure(
      status: WebProviderFailureStatus.paused,
      reason: 'health_quarantine',
      message:
          'Temporarily paused for about $minutes more minute(s) after '
          'repeated $stage errors. Use Reset to retry now.',
    );
  }
  if (addon.manifest.reportedBroken) {
    return failure(
      status: WebProviderFailureStatus.advisory,
      reason: 'reported_broken',
      message: 'Its repository currently marks this provider as broken.',
    );
  }
  if (addon.manifest.isDeprecated) {
    return failure(
      status: WebProviderFailureStatus.advisory,
      reason: 'deprecated',
      message: 'Its repository marks this provider as deprecated.',
    );
  }
  return null;
}

/// Bounded provider-only provenance for the explicit diagnostic report. This
/// never receives a catalog title, episode/query, result URL, or exception
/// message; manifest URLs are reduced to their public host by the provider.
String webProviderSearchDiagnosticMessage(
  WebStreamingProvider provider, {
  required String status,
  required int count,
  required String stage,
  required String reason,
}) {
  String field(Object? value, {int maximum = 80}) {
    final safe = '${value ?? 'unknown'}'
        .replaceAll(RegExp(r'[^A-Za-z0-9._:-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return safe.length <= maximum ? safe : safe.substring(0, maximum);
  }

  final seanime = provider is SeanimeJavascriptProvider ? provider : null;
  return [
    'provider=${field(provider.id)}',
    'version=${field(seanime?.version)}',
    'repositoryHost=${field(seanime?.repositoryHost)}',
    'executableHost=${field(seanime?.executableHost)}',
    'stage=${field(stage)}',
    'status=${field(status)}',
    'count=${count.clamp(0, 9999)}',
    'reason=${field(reason)}',
  ].join(' ');
}

typedef WebProviderSuccessCallback =
    FutureOr<void> Function(
      WebStreamingProvider provider,
      List<WebStreamResult> streams,
    );
typedef WebProviderFailureCallback =
    FutureOr<void> Function(
      WebStreamingProvider provider,
      Object error,
      bool noMatch,
    );

/// Searches providers through a small worker pool and emits an accumulated
/// result whenever one finishes. Each provider has its own deadline, so one
/// abandoned or incompatible add-on cannot hold the entire stream picker open
/// or create an unbounded wave of QuickJS runtimes on low-memory TV devices.
Stream<WebStreamSearchProgress> aggregateWebStreamingProvidersIncrementally(
  List<WebStreamingProvider> providers,
  EpisodeReference episode, {
  Duration deadline = defaultWebProviderDeadline,
  int maxConcurrentProviders = defaultMaxConcurrentWebProviders,
  WebProviderSuccessCallback? onSuccess,
  WebProviderFailureCallback? onFailure,
}) {
  final available = List<WebStreamingProvider>.unmodifiable(providers);
  final cancellation = WebProviderCancellation();
  late final StreamController<WebStreamSearchProgress> controller;
  var started = false;

  Future<void> run() async {
    try {
      if (available.isEmpty) {
        if (!cancellation.isCancelled) {
          controller.add(const WebStreamSearchProgress());
        }
        return;
      }

      final concurrency = maxConcurrentProviders.clamp(1, available.length);
      final active = <int, Future<_IndexedWebProviderOutcome>>{};
      final completedIndexes = <int>{};
      var nextIndex = 0;

      void fillWorkers() {
        while (!cancellation.isCancelled &&
            active.length < concurrency &&
            nextIndex < available.length) {
          final index = nextIndex++;
          active[index] = _searchWebProvider(
            available[index],
            episode,
            deadline,
            cancellation: cancellation,
            onSuccess: onSuccess,
            onFailure: onFailure,
          ).then((outcome) => (index: index, outcome: outcome));
        }
      }

      fillWorkers();
      final outcomes = <_WebProviderOutcome>[];
      if (!cancellation.isCancelled) {
        controller.add(
          WebStreamSearchProgress(
            totalProviders: available.length,
            pendingProviderNames: _pendingWebProviderNames(
              completedIndexes,
              available,
            ),
          ),
        );
      }

      while (active.isNotEmpty && !cancellation.isCancelled) {
        final completed = await Future.any(active.values);
        if (cancellation.isCancelled) break;
        active.remove(completed.index);
        completedIndexes.add(completed.index);
        final outcome = completed.outcome;
        if (!outcome.cancelled) outcomes.add(outcome);
        fillWorkers();
        if (cancellation.isCancelled) break;
        controller.add(
          WebStreamSearchProgress(
            aggregation: mergeWebProviderOutcomes(
              outcomes
                  .map((item) => (streams: item.streams, failure: item.failure))
                  .toList(growable: false),
            ),
            completedProviders: outcomes.length,
            totalProviders: available.length,
            pendingProviderNames: _pendingWebProviderNames(
              completedIndexes,
              available,
            ),
          ),
        );
      }
    } catch (error, stackTrace) {
      if (!cancellation.isCancelled && !controller.isClosed) {
        controller.addError(error, stackTrace);
      }
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  controller = StreamController<WebStreamSearchProgress>(
    sync: true,
    onListen: () {
      if (started) return;
      started = true;
      unawaited(run());
    },
    onCancel: cancellation.cancel,
  );
  return controller.stream;
}

typedef _IndexedWebProviderOutcome = ({int index, _WebProviderOutcome outcome});

List<String> _pendingWebProviderNames(
  Set<int> completedIndexes,
  List<WebStreamingProvider> providers,
) => [
  for (var index = 0; index < providers.length; index++)
    if (!completedIndexes.contains(index)) providers[index].name,
];

Future<_WebProviderOutcome> _searchWebProvider(
  WebStreamingProvider provider,
  EpisodeReference episode,
  Duration deadline, {
  required WebProviderCancellation cancellation,
  WebProviderSuccessCallback? onSuccess,
  WebProviderFailureCallback? onFailure,
}) async {
  try {
    cancellation.throwIfCancelled();
    final streams = await Future.any<List<WebStreamResult>>([
      provider.streams(episode, cancellation: cancellation),
      cancellation.whenCancelled.then<List<WebStreamResult>>(
        (_) => throw const WebProviderSearchCancelled(),
      ),
    ]).timeout(deadline);
    cancellation.throwIfCancelled();
    if (streams.isEmpty) {
      try {
        await onSuccess?.call(provider, const []);
      } catch (_) {
        // Health bookkeeping must not turn a normal no-match into a failure.
      }
      final seanime = provider is SeanimeJavascriptProvider ? provider : null;
      return _WebProviderOutcome(
        providerId: provider.id,
        failure: WebProviderFailure(
          providerName: provider.name,
          providerId: provider.id,
          providerVersion: seanime?.version,
          repositoryHost: seanime?.repositoryHost,
          executableHost: seanime?.executableHost,
          status: WebProviderFailureStatus.noMatch,
          stage: 'complete',
          reason: 'empty_result',
          message: 'No matching title or episode from this provider.',
        ),
      );
    }
    final compatible = streams
        .where((stream) => _webStreamMatchesRequestedEpisode(stream, episode))
        .toList(growable: false);
    if (compatible.isEmpty) {
      try {
        await onFailure?.call(provider, const _EpisodeIdentityNoMatch(), true);
      } catch (_) {
        // No-match bookkeeping is best effort and must not block discovery.
      }
      final seanime = provider is SeanimeJavascriptProvider ? provider : null;
      return _WebProviderOutcome(
        providerId: provider.id,
        failure: WebProviderFailure(
          providerName: provider.name,
          providerId: provider.id,
          providerVersion: seanime?.version,
          repositoryHost: seanime?.repositoryHost,
          executableHost: seanime?.executableHost,
          status: WebProviderFailureStatus.noMatch,
          stage: 'episode_lookup',
          reason: 'episode_identity_mismatch',
          message: 'Provider returned a different episode.',
        ),
      );
    }
    try {
      await onSuccess?.call(provider, compatible);
    } catch (_) {
      // Health bookkeeping must not hide a provider's usable streams.
    }
    return _WebProviderOutcome(providerId: provider.id, streams: compatible);
  } catch (error) {
    if (error is WebProviderSearchCancelled || cancellation.isCancelled) {
      return _WebProviderOutcome(providerId: provider.id, cancelled: true);
    }
    final noMatch = isSeanimeProviderNoMatch(error);
    final details = seanimeProviderFailureDetails(error);
    final seanime = provider is SeanimeJavascriptProvider ? provider : null;
    try {
      await onFailure?.call(provider, error, noMatch);
    } catch (_) {
      // Diagnostics are best effort and must never block discovery.
    }
    return _WebProviderOutcome(
      providerId: provider.id,
      failure: WebProviderFailure(
        providerName: provider.name,
        providerId: provider.id,
        providerVersion: seanime?.version,
        repositoryHost: seanime?.repositoryHost,
        executableHost: seanime?.executableHost,
        status: noMatch
            ? WebProviderFailureStatus.noMatch
            : WebProviderFailureStatus.failed,
        stage: details?.stage,
        reason: details?.reason,
        message: noMatch
            ? 'No matching title or episode from this provider.'
            : error is TimeoutException
            ? 'Timed out after ${deadline.inSeconds} seconds.'
            : _shortMessage(error),
      ),
    );
  }
}

/// Internal, bounded signal used only to classify a provider result as a
/// neutral no-match after every returned stream identified another episode.
class _EpisodeIdentityNoMatch implements Exception {
  const _EpisodeIdentityNoMatch();

  @override
  String toString() => 'Provider returned a different episode.';
}

bool _webStreamMatchesRequestedEpisode(
  WebStreamResult stream,
  EpisodeReference episode,
) {
  final explicit = assessExplicitProviderEpisodeIdentity(
    episode: episode,
    episodeNumber: stream.matchedEpisodeNumber,
    seasonNumber: stream.matchedSeasonNumber,
    seriesTitle: stream.matchedSeriesTitle,
  );
  if (explicit.isMatch) return true;
  if (explicit.isMismatch) return false;
  return !assessEpisodeIdentityLabel(
    label: stream.title,
    requestedEpisode: episode.episode,
    requestedSeason: catalogSeasonNumber(episode),
  ).isMismatch;
}

WebStreamAggregation mergeWebProviderOutcomes(
  List<({List<WebStreamResult> streams, WebProviderFailure? failure})> outcomes,
) {
  final unique = <String, WebStreamResult>{};
  final failures = <WebProviderFailure>[];
  for (final outcome in outcomes) {
    if (outcome.failure != null) failures.add(outcome.failure!);
    for (final stream in outcome.streams) {
      // Different providers may intentionally return the same CDN URI with
      // different headers, subtitles, or server identity. Deduplicate only
      // within one provider so provider B is not erased before fair ordering.
      final providerIdentity = webStreamProviderIdentity(stream);
      final key = '$providerIdentity\u0000${stream.uri}';
      final existing = unique[key];
      if (existing == null) {
        unique[key] = stream;
        continue;
      }
      final winner = _compareDuplicateWebStream(stream, existing) < 0
          ? stream
          : existing;
      unique[key] = winner.withAudioCapability(
        mergeWebStreamAudioCapabilities(
          existing.effectiveAudioCapability,
          stream.effectiveAudioCapability,
        ),
      );
    }
  }
  final streams = _providerFairWebStreamOrder(unique.values);
  failures.sort((a, b) {
    final severity = _webProviderFailureSeverity(
      a.status,
    ).compareTo(_webProviderFailureSeverity(b.status));
    if (severity != 0) return severity;
    final provider = _compareWebText(a.providerName, b.providerName);
    if (provider != 0) return provider;
    final id = _compareWebText(a.providerId ?? '', b.providerId ?? '');
    return id != 0 ? id : _compareWebText(a.message, b.message);
  });
  return WebStreamAggregation(streams: streams, failures: failures);
}

int _webProviderFailureSeverity(WebProviderFailureStatus status) =>
    switch (status) {
      WebProviderFailureStatus.failed => 0,
      WebProviderFailureStatus.unavailable => 1,
      WebProviderFailureStatus.paused => 2,
      WebProviderFailureStatus.noMatch => 3,
      WebProviderFailureStatus.advisory => 4,
    };

List<WebStreamResult> _providerFairWebStreamOrder(
  Iterable<WebStreamResult> streams,
) {
  final buckets = <String, List<WebStreamResult>>{};
  for (final stream in streams) {
    final identity = webStreamProviderIdentity(stream);
    buckets.putIfAbsent(identity, () => []).add(stream);
  }
  final orderedBuckets = buckets.values.toList(growable: false)
    ..sort((left, right) {
      final provider = _compareWebText(
        left.first.providerName,
        right.first.providerName,
      );
      return provider != 0
          ? provider
          : _compareWebText(left.first.providerId, right.first.providerId);
    });
  var longest = 0;
  for (final bucket in orderedBuckets) {
    bucket.sort(_compareWithinWebProvider);
    if (bucket.length > longest) longest = bucket.length;
  }
  return [
    for (var offset = 0; offset < longest; offset++)
      for (final bucket in orderedBuckets)
        if (offset < bucket.length) bucket[offset],
  ];
}

int _compareWithinWebProvider(WebStreamResult left, WebStreamResult right) {
  final quality = _webStreamResolution(
    right,
  ).compareTo(_webStreamResolution(left));
  if (quality != 0) return quality;
  final title = _compareWebText(left.title, right.title);
  return title != 0
      ? title
      : _compareWebText(left.uri.toString(), right.uri.toString());
}

int _webStreamResolution(WebStreamResult stream) {
  final value = '${stream.quality ?? ''} ${stream.title}'.toLowerCase();
  if (RegExp(r'\b4k\b').hasMatch(value)) return 2160;
  final heights = RegExp(r'(?<!\d)([1-4]?\d{3}|[2-9]\d{2})p?\b')
      .allMatches(value)
      .map((match) => int.tryParse(match.group(1)!) ?? 0)
      .where((height) => height >= 240 && height <= 4320);
  return heights.isEmpty ? 0 : heights.reduce((a, b) => a > b ? a : b);
}

/// Picks the richer duplicate deterministically so completion timing cannot
/// make the same URI lose required headers or subtitle metadata.
int _compareDuplicateWebStream(WebStreamResult left, WebStreamResult right) {
  final richness = _webStreamRichness(
    right,
  ).compareTo(_webStreamRichness(left));
  if (richness != 0) return richness;
  final provider = _compareWebText(left.providerName, right.providerName);
  if (provider != 0) return provider;
  final providerId = _compareWebText(left.providerId, right.providerId);
  if (providerId != 0) return providerId;
  final title = _compareWebText(left.title, right.title);
  return title != 0
      ? title
      : _compareWebText(left.uri.toString(), right.uri.toString());
}

int _webStreamRichness(WebStreamResult stream) =>
    (stream.quality?.trim().isNotEmpty == true ? 1 : 0) +
    (stream.headers.isNotEmpty ? 1 : 0) +
    (stream.subtitleUri != null ? 1 : 0) +
    (stream.subtitleLanguage?.trim().isNotEmpty == true ? 1 : 0);

int _compareWebText(String left, String right) {
  final normalized = left.toLowerCase().compareTo(right.toLowerCase());
  return normalized != 0 ? normalized : left.compareTo(right);
}

Future<WebStreamAggregation> aggregateWebStreamingProviders(
  List<WebStreamingProvider> providers,
  EpisodeReference episode, {
  Duration deadline = defaultWebProviderDeadline,
  int maxConcurrentProviders = defaultMaxConcurrentWebProviders,
}) async {
  var result = const WebStreamAggregation();
  await for (final progress in aggregateWebStreamingProvidersIncrementally(
    providers,
    episode,
    deadline: deadline,
    maxConcurrentProviders: maxConcurrentProviders,
  )) {
    result = progress.aggregation;
  }
  return result;
}

String _shortMessage(Object error) {
  return seanimeProviderFailureMessage(error);
}

class _WebProviderOutcome {
  const _WebProviderOutcome({
    required this.providerId,
    this.streams = const [],
    this.failure,
    this.cancelled = false,
  });

  final String providerId;
  final List<WebStreamResult> streams;
  final WebProviderFailure? failure;
  final bool cancelled;
}
