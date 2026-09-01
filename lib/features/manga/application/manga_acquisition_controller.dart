import 'dart:async';

import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:anime_tv/features/manga/application/manga_dependencies.dart';
import 'package:anime_tv/features/manga/data/manga_acquisition_service.dart';
import 'package:anime_tv/features/manga/data/manga_local_storage.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Public dependency names stay readable while the implementation fields stay
// private and immutable.
// ignore_for_file: prefer_initializing_formals

final mangaAcquisitionServiceProvider = FutureProvider<MangaAcquisitionService>(
  (ref) async {
    final store = ref.watch(mangaStoreProvider);
    final credentials = ref.watch(mangaSourceCredentialStoreProvider);
    final keepAlive = ref.watch(offlineDownloadKeepAliveProvider);
    final storageRoots = await ref.watch(mangaStorageRootsProvider.future);
    return MangaAcquisitionService(
      store: store,
      storageRoots: storageRoots,
      credentials: credentials,
      keepAlive: keepAlive,
    );
  },
);

final mangaAcquisitionControllerProvider =
    StateNotifierProvider<MangaAcquisitionController, MangaAcquisitionState>((
      ref,
    ) {
      final controller = MangaAcquisitionController(
        service: ref.watch(mangaAcquisitionServiceProvider.future),
      );
      Future<void>.microtask(controller.initialize);
      return controller;
    });

@immutable
class MangaAcquisitionState {
  MangaAcquisitionState({
    this.isInitializing = true,
    Iterable<MangaDownloadJob> jobs = const <MangaDownloadJob>[],
    Map<String, MangaAcquisitionProgress> progress =
        const <String, MangaAcquisitionProgress>{},
    this.error,
  }) : jobs = List<MangaDownloadJob>.unmodifiable(jobs),
       progress = Map<String, MangaAcquisitionProgress>.unmodifiable(progress);

  final bool isInitializing;
  final List<MangaDownloadJob> jobs;
  final Map<String, MangaAcquisitionProgress> progress;
  final String? error;

  MangaDownloadJob? job(String jobId) {
    for (final job in jobs) {
      if (job.id == jobId) return job;
    }
    return null;
  }

  MangaAcquisitionState copyWith({
    bool? isInitializing,
    Iterable<MangaDownloadJob>? jobs,
    Map<String, MangaAcquisitionProgress>? progress,
    String? error,
    bool clearError = false,
  }) => MangaAcquisitionState(
    isInitializing: isInitializing ?? this.isInitializing,
    jobs: jobs ?? this.jobs,
    progress: progress ?? this.progress,
    error: clearError ? null : error ?? this.error,
  );
}

/// Application-facing coordinator for the developer-only manga downloader.
///
/// Acquisition requests and their credential capabilities remain only in this
/// process. State exposed to widgets contains safe progress and SQLite-backed
/// metadata, never page URLs or request headers.
class MangaAcquisitionController extends StateNotifier<MangaAcquisitionState> {
  MangaAcquisitionController({required Future<MangaAcquisitionService> service})
    : _service = service,
      super(MangaAcquisitionState());

  final Future<MangaAcquisitionService> _service;
  final Map<String, MangaAcquisitionRequest> _retryCapabilities =
      <String, MangaAcquisitionRequest>{};
  final Map<String, StreamSubscription<MangaAcquisitionProgress>>
  _subscriptions = <String, StreamSubscription<MangaAcquisitionProgress>>{};
  final Set<String> _jobDiscoveryRefreshes = <String>{};
  Future<void>? _initialization;
  var _disposed = false;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<MangaAcquisitionOperation> start(
    MangaAcquisitionRequest request,
  ) async {
    await initialize();
    final service = await _service;
    _retryCapabilities[request.jobId] = request;
    final operation = service.start(request);
    _observe(operation);
    return operation;
  }

  Future<MangaAcquisitionOperation> retry(
    MangaAcquisitionRequest request,
  ) async {
    await initialize();
    final service = await _service;
    _retryCapabilities[request.jobId] = request;
    final operation = service.retry(request);
    _observe(operation);
    return operation;
  }

  /// Retries a transfer only while its ephemeral request is still in memory.
  /// After process restart the UI must acquire a fresh source capability and
  /// call [retry] with that new request.
  Future<MangaAcquisitionOperation> retryInSession(String jobId) async {
    final request = _retryCapabilities[jobId];
    if (request == null) {
      throw const MangaAcquisitionException(
        MangaAcquisitionFailureCode.invalidRequest,
        'Reconnect to the manga source before retrying this download.',
      );
    }
    return retry(request);
  }

  Future<void> cancel(String jobId) async {
    final service = await _service;
    final operation = service.activeOperation(jobId);
    await service.cancel(jobId);
    if (operation != null) {
      try {
        await operation.completed;
      } catch (_) {
        // The durable row is refreshed below with its cancelled state.
      }
    }
    await refresh();
  }

  Future<MangaReaderRequest?> openCompleted(String jobId) async =>
      (await _service).openCompleted(jobId);

  Future<void> delete(String jobId) async {
    final service = await _service;
    await service.delete(jobId);
    _retryCapabilities.remove(jobId);
    await _subscriptions.remove(jobId)?.cancel();
    if (!_disposed) {
      final nextProgress = Map<String, MangaAcquisitionProgress>.of(
        state.progress,
      )..remove(jobId);
      state = state.copyWith(progress: nextProgress, clearError: true);
    }
    await refresh();
  }

  /// Must be called before deleting a manga source row so its downloaded page
  /// directories can still be resolved and removed safely.
  Future<int> removeDownloadsForSource(String sourceId) async {
    final service = await _service;
    final durableJobs = await service.jobs();
    final affectedJobIds = <String>{
      for (final job in <MangaDownloadJob>[...state.jobs, ...durableJobs])
        if (_belongsToSourceTree(job.sourceId, sourceId)) job.id,
      for (final entry in _retryCapabilities.entries)
        if (_belongsToSourceTree(entry.value.sourceId, sourceId)) entry.key,
    };
    final removed = await service.deleteDownloadsForSource(sourceId);
    for (final jobId in affectedJobIds) {
      _retryCapabilities.remove(jobId);
      await _subscriptions.remove(jobId)?.cancel();
    }
    if (!_disposed) {
      final nextProgress = Map<String, MangaAcquisitionProgress>.of(
        state.progress,
      )..removeWhere((jobId, _) => affectedJobIds.contains(jobId));
      state = state.copyWith(progress: nextProgress, clearError: true);
    }
    await refresh();
    return removed;
  }

  Future<void> refresh() async {
    final service = await _service;
    final jobs = await service.jobs();
    if (!_disposed) {
      state = state.copyWith(
        isInitializing: false,
        jobs: jobs,
        clearError: true,
      );
    }
  }

  void clearError() {
    if (!_disposed) state = state.copyWith(clearError: true);
  }

  Future<void> _initialize() async {
    try {
      final service = await _service;
      final jobs = await service.recoverStaleJobs();
      if (!_disposed) {
        state = state.copyWith(
          isInitializing: false,
          jobs: jobs,
          clearError: true,
        );
      }
    } catch (error) {
      if (!_disposed) {
        state = state.copyWith(
          isInitializing: false,
          error: _safeAcquisitionError(error),
        );
      }
    }
  }

  void _observe(MangaAcquisitionOperation operation) {
    final jobId = operation.request.jobId;
    unawaited(_subscriptions.remove(jobId)?.cancel());
    _setProgress(operation.currentProgress);
    _subscriptions[jobId] = operation.progress.listen(
      _setProgress,
      onError: (Object error, StackTrace stackTrace) {
        if (!_disposed) {
          state = state.copyWith(error: _safeAcquisitionError(error));
        }
      },
    );
    unawaited(_observeCompletion(operation));
  }

  void _setProgress(MangaAcquisitionProgress progress) {
    if (_disposed) return;
    state = state.copyWith(
      progress: <String, MangaAcquisitionProgress>{
        ...state.progress,
        progress.jobId: progress,
      },
      clearError: true,
    );
    if (progress.phase != MangaAcquisitionPhase.queued &&
        state.job(progress.jobId) == null &&
        _jobDiscoveryRefreshes.add(progress.jobId)) {
      unawaited(_refreshDiscoveredJob(progress.jobId));
    }
  }

  Future<void> _refreshDiscoveredJob(String jobId) async {
    try {
      await refresh();
    } catch (error) {
      if (!_disposed) {
        state = state.copyWith(error: _safeAcquisitionError(error));
      }
    } finally {
      _jobDiscoveryRefreshes.remove(jobId);
    }
  }

  Future<void> _observeCompletion(MangaAcquisitionOperation operation) async {
    try {
      await operation.completed;
    } catch (error) {
      if (!_disposed) {
        state = state.copyWith(error: _safeAcquisitionError(error));
      }
    } finally {
      await _subscriptions.remove(operation.request.jobId)?.cancel();
      try {
        await refresh();
      } catch (error) {
        if (!_disposed) {
          state = state.copyWith(error: _safeAcquisitionError(error));
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _jobDiscoveryRefreshes.clear();
    _retryCapabilities.clear();
    super.dispose();
  }
}

String _safeAcquisitionError(Object error) => switch (error) {
  MangaAcquisitionException(:final message) => message,
  _ => 'The manga download list could not be updated.',
};

bool _belongsToSourceTree(String candidate, String root) =>
    candidate == root || candidate.startsWith('$root.child.');
