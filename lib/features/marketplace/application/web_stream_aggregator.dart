import 'dart:async';
import 'dart:math' as math;

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

var _webProviderSearchDiagnosticSequence = 0;
final String _webProviderSearchDiagnosticBootNonce = (() {
  final random = math.Random.secure();
  return List<String>.generate(
    3,
    (_) => random.nextInt(0x10000).toRadixString(16).padLeft(4, '0'),
    growable: false,
  ).join();
})();

/// Returns a media-free correlation ID that remains unique across process
/// restarts while the bounded diagnostic history is retained.
String nextWebProviderSearchDiagnosticSessionId() =>
    'provider-search-$_webProviderSearchDiagnosticBootNonce-'
    '${++_webProviderSearchDiagnosticSequence}';

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
    this.diagnosticSessionId = '',
  });

  final WebStreamAggregation aggregation;
  final int completedProviders;
  final int totalProviders;
  final List<String> pendingProviderNames;
  final String diagnosticSessionId;

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
    final obsoleteSessions = _sharedSessions.entries
        .where(
          (entry) =>
              entry.key != key &&
              !entry.value.isComplete &&
              !entry.value.wasAbandoned,
        )
        .map((entry) => entry.value)
        .toList(growable: false);
    final session = shouldReplace
        ? _startSharedSession(key, episode, obsoleteSessions: obsoleteSessions)
        : existing;
    if (!shouldReplace && obsoleteSessions.isNotEmpty) {
      // A retained route can still be mounted briefly after navigation. Only
      // the foreground episode should own provider runtimes, even when this
      // call reattaches to an already-running session for that episode.
      for (final obsolete in obsoleteSessions) {
        unawaited(obsolete.cancel());
      }
    }
    return session.stream;
  }

  _SharedWebSearchSession _startSharedSession(
    String key,
    EpisodeReference episode, {
    List<_SharedWebSearchSession> obsoleteSessions = const [],
  }) {
    final session = _SharedWebSearchSession(
      zeroListenerGrace: sharedSessionGrace,
    );
    session.prepare();
    _sharedSessions[key] = session;
    unawaited(
      _runSharedSession(
        session,
        episode,
        obsoleteSessions: obsoleteSessions,
      ).whenComplete(_pruneSessions),
    );
    return session;
  }

  Future<void> _runSharedSession(
    _SharedWebSearchSession session,
    EpisodeReference episode, {
    required List<_SharedWebSearchSession> obsoleteSessions,
  }) async {
    try {
      // Route replacements and rapid Watch Party episode changes can leave
      // the prior resolver mounted for a few frames. Finish cancelling that
      // search before starting another provider wave so the two episodes do
      // not compete for QuickJS runtimes and network capacity.
      await Future.wait(obsoleteSessions.map((obsolete) => obsolete.cancel()));
      if (session.isComplete) return;
      await session.run(searchIncrementally(episode));
    } catch (error, stackTrace) {
      await session.fail(error, stackTrace);
    }
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
    final diagnosticSessionId = nextWebProviderSearchDiagnosticSessionId();
    final health = await _store.providerHealth();
    final installedAddons = await _store.installedAddons();
    final enabledAddons = installedAddons
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
        diagnosticSessionId: diagnosticSessionId,
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
    _recordProviderSearchSummary(
      webProviderSearchSummaryDiagnosticDetails(
        phase: 'start',
        diagnosticSessionId: diagnosticSessionId,
        installedProviders: installedAddons.length,
        enabledProviders: enabledAddons.length,
        searchableProviders: providers.length,
        blockedProviders: blockedProviders,
        completedProviders: blockedProviders,
        returnedProviders: 0,
        returnedResults: 0,
      ),
    );
    var recordedInitialProgress = false;
    var lastProgressMilestone = blockedProviders;
    var terminalSummaryRecorded = false;
    var lastCompletedProviders = blockedProviders;
    var lastAggregation = WebStreamAggregation(
      failures: List.unmodifiable(availabilityFailures),
    );
    try {
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
            diagnosticSessionId: diagnosticSessionId,
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
            diagnosticSessionId: diagnosticSessionId,
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
        final aggregation = mergeWebProviderOutcomes([
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
        ]);
        final completedProviders =
            progress.completedProviders + blockedProviders;
        final isComplete = completedProviders >= enabledAddons.length;
        final returnedProviders = aggregation.streams
            .map(webStreamProviderIdentity)
            .toSet()
            .length;
        final shouldRecordProgress =
            !isComplete &&
            (!recordedInitialProgress ||
                completedProviders - lastProgressMilestone >= 4);
        if (shouldRecordProgress || isComplete) {
          final phase = isComplete ? 'final' : 'progress';
          _recordProviderSearchSummary(
            webProviderSearchSummaryDiagnosticDetails(
              phase: phase,
              diagnosticSessionId: diagnosticSessionId,
              installedProviders: installedAddons.length,
              enabledProviders: enabledAddons.length,
              searchableProviders: providers.length,
              blockedProviders: blockedProviders,
              completedProviders: completedProviders,
              returnedProviders: returnedProviders,
              returnedResults: aggregation.streams.length,
              failureReasonCounts: webProviderFailureReasonCounts(
                aggregation.failures,
              ),
            ),
          );
          if (!isComplete) {
            recordedInitialProgress = true;
            lastProgressMilestone = completedProviders;
          } else {
            terminalSummaryRecorded = true;
          }
        }
        lastCompletedProviders = completedProviders;
        lastAggregation = aggregation;
        yield WebStreamSearchProgress(
          aggregation: aggregation,
          completedProviders: completedProviders,
          totalProviders: enabledAddons.length,
          pendingProviderNames: progress.pendingProviderNames,
          diagnosticSessionId: diagnosticSessionId,
        );
      }
    } catch (_) {
      terminalSummaryRecorded = true;
      _recordProviderSearchSummary(
        webProviderSearchSummaryDiagnosticDetails(
          phase: 'error',
          diagnosticSessionId: diagnosticSessionId,
          installedProviders: installedAddons.length,
          enabledProviders: enabledAddons.length,
          searchableProviders: providers.length,
          blockedProviders: blockedProviders,
          completedProviders: lastCompletedProviders,
          returnedProviders: lastAggregation.streams
              .map(webStreamProviderIdentity)
              .toSet()
              .length,
          returnedResults: lastAggregation.streams.length,
          failureReasonCounts: webProviderFailureReasonCounts(
            lastAggregation.failures,
          ),
        ),
      );
      rethrow;
    } finally {
      if (!terminalSummaryRecorded) {
        _recordProviderSearchSummary(
          webProviderSearchSummaryDiagnosticDetails(
            phase: 'canceled',
            diagnosticSessionId: diagnosticSessionId,
            installedProviders: installedAddons.length,
            enabledProviders: enabledAddons.length,
            searchableProviders: providers.length,
            blockedProviders: blockedProviders,
            completedProviders: lastCompletedProviders,
            returnedProviders: lastAggregation.streams
                .map(webStreamProviderIdentity)
                .toSet()
                .length,
            returnedResults: lastAggregation.streams.length,
            failureReasonCounts: webProviderFailureReasonCounts(
              lastAggregation.failures,
            ),
          ),
        );
      }
    }
  }

  void _recordProviderSearchSummary(Map<String, Object?> details) {
    unawaited(_persistProviderSearchSummary(details));
  }

  Future<void> _persistProviderSearchSummary(
    Map<String, Object?> details,
  ) async {
    try {
      await _store.database.recordDiagnosticEvent(
        category: 'provider-search',
        severity: 'info',
        message: 'Web provider discovery summary',
        details: details,
      );
    } catch (_) {
      // Diagnostics are best-effort and must never affect provider discovery.
    }
  }

  void _recordProviderSearchOutcome(
    WebStreamingProvider provider, {
    required String diagnosticSessionId,
    required String status,
    required int count,
    required String stage,
    required String reason,
  }) {
    unawaited(
      _persistProviderSearchOutcome(
        provider,
        diagnosticSessionId: diagnosticSessionId,
        status: status,
        count: count,
        stage: stage,
        reason: reason,
      ),
    );
  }

  Future<void> _persistProviderSearchOutcome(
    WebStreamingProvider provider, {
    required String diagnosticSessionId,
    required String status,
    required int count,
    required String stage,
    required String reason,
  }) async {
    try {
      await _store.database.recordDiagnosticEvent(
        category: 'provider-search',
        severity: status == 'failed' || status == 'unavailable'
            ? 'warning'
            : 'info',
        message: webProviderSearchDiagnosticMessage(
          provider,
          status: status,
          count: count,
          stage: stage,
          reason: reason,
        ),
        details: webProviderSearchOutcomeDiagnosticDetails(diagnosticSessionId),
      );
    } catch (_) {
      // Diagnostics are best-effort and must never affect provider discovery.
    }
  }
}

String _episodeSearchKey(EpisodeReference episode) {
  if (episode.anilistMediaId > 0) {
    return 'anilist:${episode.anilistMediaId}:${episode.episode}';
  }
  if ((episode.malMediaId ?? 0) > 0) {
    return 'mal:${episode.malMediaId}:${episode.episode}';
  }
  return [
    'title',
    episode.title.trim().toLowerCase(),
    episode.year ?? 0,
    episode.episode,
  ].join(':');
}

class _SharedWebSearchSession {
  _SharedWebSearchSession({required this.zeroListenerGrace});

  final startedAt = DateTime.now();
  final Duration zeroListenerGrace;
  final StreamController<WebStreamSearchProgress> _updates =
      StreamController<WebStreamSearchProgress>.broadcast(sync: true);
  WebStreamSearchProgress? _latest;
  StreamSubscription<WebStreamSearchProgress>? _sourceSubscription;
  Timer? _zeroListenerTimer;
  final Completer<void> _completion = Completer<void>();
  int _listenerCount = 0;
  bool _prepared = false;
  bool isComplete = false;
  bool wasAbandoned = false;

  void prepare() {
    if (_prepared || isComplete) return;
    _prepared = true;
    _scheduleAbandonedCancellation();
  }

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
    if (isComplete) return _completion.future;
    _prepared = true;
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
    return _completion.future;
  }

  Future<void> cancel() async {
    if (isComplete) return _completion.future;
    wasAbandoned = true;
    try {
      await _sourceSubscription?.cancel();
    } catch (_) {
      // Cancellation is best effort; the shared stream must still close so a
      // replacement episode can begin instead of hanging behind stale work.
    } finally {
      await _finish();
    }
  }

  Future<void> fail(Object error, StackTrace stackTrace) async {
    if (isComplete) return;
    if (!_updates.isClosed) _updates.addError(error, stackTrace);
    await _finish();
  }

  void _scheduleAbandonedCancellation() {
    if (isComplete || _listenerCount != 0 || !_prepared) {
      return;
    }
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = Timer(zeroListenerGrace, () async {
      if (isComplete || _listenerCount != 0) return;
      await cancel();
    });
  }

  Future<void> _finish() async {
    if (isComplete) return;
    isComplete = true;
    _zeroListenerTimer?.cancel();
    _zeroListenerTimer = null;
    if (!_updates.isClosed) await _updates.close();
    if (!_completion.isCompleted) _completion.complete();
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
Map<String, Object?> webProviderSearchSummaryDiagnosticDetails({
  required String phase,
  required String diagnosticSessionId,
  required int installedProviders,
  required int enabledProviders,
  required int searchableProviders,
  required int blockedProviders,
  required int completedProviders,
  required int returnedProviders,
  required int returnedResults,
  Map<String, int> failureReasonCounts = const {},
}) {
  final safeReasons = <String, int>{};
  for (final entry in failureReasonCounts.entries) {
    final reason = _safeWebProviderFailureReason(entry.key);
    safeReasons.update(
      reason,
      (count) => count + entry.value.clamp(0, 9999),
      ifAbsent: () => entry.value.clamp(0, 9999),
    );
  }
  return {
    'session_id': _safeWebProviderDiagnosticSessionId(diagnosticSessionId),
    'phase': _safeWebProviderDiagnosticPhase(phase),
    'state': <Map<String, Object>>[
      {
        'kind': 'installed_providers',
        'count': installedProviders.clamp(0, 9999),
      },
      {'kind': 'enabled_providers', 'count': enabledProviders.clamp(0, 9999)},
      {
        'kind': 'searchable_providers',
        'count': searchableProviders.clamp(0, 9999),
      },
      {'kind': 'blocked_providers', 'count': blockedProviders.clamp(0, 9999)},
      {
        'kind': 'completed_providers',
        'count': completedProviders.clamp(0, 9999),
      },
      {'kind': 'returned_providers', 'count': returnedProviders.clamp(0, 9999)},
      {'kind': 'returned_results', 'count': returnedResults.clamp(0, 99999)},
    ],
    if (safeReasons.isNotEmpty)
      'reason': <Map<String, Object>>[
        for (final entry in safeReasons.entries)
          {'reason_code': entry.key, 'count': entry.value},
      ],
  };
}

Map<String, int> webProviderFailureReasonCounts(
  Iterable<WebProviderFailure> failures,
) {
  final counts = <String, int>{};
  for (final failure in failures) {
    final reason = _safeWebProviderFailureReason(
      failure.reason ?? 'unspecified',
    );
    counts.update(reason, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}

Map<String, Object?> webProviderVisibilityDiagnosticDetails({
  required String phase,
  required String diagnosticSessionId,
  required int rawProviders,
  required int rawResults,
  required int visibleProviders,
  required int visibleResults,
  required String audioFilter,
  required String qualityFilter,
  int rawUnknownAudioResults = 0,
  int rawSubAudioResults = 0,
  int rawDubAudioResults = 0,
  int rawDualAudioResults = 0,
  int strictAudioMatches = 0,
  int unknownAudioFallbacks = 0,
}) => {
  'session_id': _safeWebProviderDiagnosticSessionId(diagnosticSessionId),
  'phase': _safeWebProviderDiagnosticPhase(phase),
  'state': <Map<String, Object>>[
    {'kind': 'raw_providers', 'count': rawProviders.clamp(0, 9999)},
    {'kind': 'raw_results', 'count': rawResults.clamp(0, 99999)},
    {'kind': 'visible_providers', 'count': visibleProviders.clamp(0, 9999)},
    {'kind': 'visible_results', 'count': visibleResults.clamp(0, 99999)},
    {
      'kind': 'raw_audio_unknown_results',
      'count': rawUnknownAudioResults.clamp(0, 99999),
    },
    {
      'kind': 'raw_audio_sub_results',
      'count': rawSubAudioResults.clamp(0, 99999),
    },
    {
      'kind': 'raw_audio_dub_results',
      'count': rawDubAudioResults.clamp(0, 99999),
    },
    {
      'kind': 'raw_audio_dual_results',
      'count': rawDualAudioResults.clamp(0, 99999),
    },
    {
      'kind': 'strict_audio_matches',
      'count': strictAudioMatches.clamp(0, 99999),
    },
    {
      'kind': 'unknown_audio_fallbacks',
      'count': unknownAudioFallbacks.clamp(0, 99999),
    },
  ],
  'audio_mode': const {'all', 'sub', 'dub'}.contains(audioFilter)
      ? audioFilter
      : 'unknown',
  'quality': const {'any', 'p2160', 'p1080', 'p720'}.contains(qualityFilter)
      ? qualityFilter
      : 'unknown',
};

Map<String, Object?> webProviderSearchOutcomeDiagnosticDetails(
  String diagnosticSessionId,
) => {'session_id': _safeWebProviderDiagnosticSessionId(diagnosticSessionId)};

String _safeWebProviderDiagnosticSessionId(String value) =>
    RegExp(r'^provider-search-[0-9a-f]{12}-[0-9]+$').hasMatch(value)
    ? value
    : 'provider-search-unknown';

String _safeWebProviderDiagnosticPhase(String value) =>
    const {
      'start',
      'progress',
      'final',
      'filter_changed',
      'canceled',
      'error',
    }.contains(value)
    ? value
    : 'unknown';

String _safeWebProviderFailureReason(String value) {
  if (RegExp(r'^http_[1-5][0-9]{2}$').hasMatch(value)) return value;
  return const {
        'timeout',
        'empty_sources',
        'unsafe_target',
        'invalid_response',
        'network',
        'runtime_api',
        'provider_error',
        'empty_result',
        'episode_identity_mismatch',
        'health_quarantine',
        'incompatible_runtime',
        'reported_broken',
        'deprecated',
        'unavailable',
        'unspecified',
      }.contains(value)
      ? value
      : 'other';
}

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
  final providerCancellation = WebProviderCancellation();
  final removeParentCancellationListener = cancellation.addListener(
    providerCancellation.cancel,
  );
  try {
    cancellation.throwIfCancelled();
    final providerSearch = provider
        .streams(episode, cancellation: providerCancellation)
        .timeout(
          deadline,
          onTimeout: () {
            // The worker-pool deadline must also stop this provider's isolate
            // and network work. The parent token belongs to every provider,
            // so cancelling it here would incorrectly discard valid peers.
            providerCancellation.cancel();
            throw TimeoutException(
              'Provider exceeded its discovery deadline.',
              deadline,
            );
          },
        );
    final streams = await Future.any<List<WebStreamResult>>([
      providerSearch,
      cancellation.whenCancelled.then<List<WebStreamResult>>(
        (_) => throw const WebProviderSearchCancelled(),
      ),
    ]);
    cancellation.throwIfCancelled();
    if (streams.isEmpty) {
      _invokeWebProviderSuccess(onSuccess, provider, const []);
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
      _invokeWebProviderFailure(
        onFailure,
        provider,
        const _EpisodeIdentityNoMatch(),
        true,
      );
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
    _invokeWebProviderSuccess(onSuccess, provider, compatible);
    return _WebProviderOutcome(providerId: provider.id, streams: compatible);
  } catch (error) {
    if (error is WebProviderSearchCancelled || cancellation.isCancelled) {
      return _WebProviderOutcome(providerId: provider.id, cancelled: true);
    }
    final noMatch = isSeanimeProviderNoMatch(error);
    final details = seanimeProviderFailureDetails(error);
    final seanime = provider is SeanimeJavascriptProvider ? provider : null;
    _invokeWebProviderFailure(onFailure, provider, error, noMatch);
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
  } finally {
    removeParentCancellationListener();
  }
}

void _invokeWebProviderSuccess(
  WebProviderSuccessCallback? callback,
  WebStreamingProvider provider,
  List<WebStreamResult> streams,
) {
  if (callback == null) return;
  unawaited(
    Future<void>.sync(() => callback(provider, streams)).catchError((_) {}),
  );
}

void _invokeWebProviderFailure(
  WebProviderFailureCallback? callback,
  WebStreamingProvider provider,
  Object error,
  bool noMatch,
) {
  if (callback == null) return;
  unawaited(
    Future<void>.sync(
      () => callback(provider, error, noMatch),
    ).catchError((_) {}),
  );
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
