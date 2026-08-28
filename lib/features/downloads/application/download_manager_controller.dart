// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:anime_tv/features/downloads/data/adaptive_offline_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/android_direct_peer_download_worker.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/downloaded_episode_asset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final downloadRepositoryProvider = Provider<DownloadRepository>(
  (ref) => DownloadRepository(),
);

final offlineDownloadStorageProvider = Provider<OfflineDownloadStorage>(
  (ref) => OfflineDownloadStorage(),
);

final downloadTransferClientProvider = Provider<DownloadTransferClient>(
  (ref) => AdaptiveOfflineDownloadTransferClient(),
);

final directPeerDownloadWorkerProvider = Provider<DirectPeerDownloadWorker>(
  (ref) => AndroidDirectPeerDownloadWorker(),
);

final downloadManagerProvider =
    StateNotifierProvider<DownloadManagerController, DownloadManagerState>((
      ref,
    ) {
      return DownloadManagerController(
        repository: ref.watch(downloadRepositoryProvider),
        storage: ref.watch(offlineDownloadStorageProvider),
        transferClient: ref.watch(downloadTransferClientProvider),
        directPeerWorker: ref.watch(directPeerDownloadWorkerProvider),
        keepAlive: ref.watch(offlineDownloadKeepAliveProvider),
      );
    });

const _ephemeralAuthorizationMarker = 'ephemeral-request-headers';

class DownloadManagerState {
  DownloadManagerState({
    List<DownloadJob> jobs = const [],
    this.initialized = false,
    this.loading = false,
    this.activeJobId,
    this.storageUsedBytes = 0,
    this.errorMessage,
  }) : jobs = List.unmodifiable(jobs);

  final List<DownloadJob> jobs;
  final bool initialized;
  final bool loading;
  final String? activeJobId;
  final int storageUsedBytes;
  final String? errorMessage;

  DownloadManagerState copyWith({
    List<DownloadJob>? jobs,
    bool? initialized,
    bool? loading,
    String? activeJobId,
    bool clearActiveJobId = false,
    int? storageUsedBytes,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) => DownloadManagerState(
    jobs: jobs ?? this.jobs,
    initialized: initialized ?? this.initialized,
    loading: loading ?? this.loading,
    activeJobId: clearActiveJobId ? null : activeJobId ?? this.activeJobId,
    storageUsedBytes: storageUsedBytes ?? this.storageUsedBytes,
    errorMessage: clearErrorMessage ? null : errorMessage ?? this.errorMessage,
  );

  DownloadJob? job(String id) {
    for (final job in jobs) {
      if (job.id == id) return job;
    }
    return null;
  }
}

enum _RequestedStop { pause, cancel, delete }

/// Persistent, sequential download queue.
///
/// Only HTTPS transfers run in this Dart worker. A direct-peer request is
/// persisted as unsupported until the native foreground worker exists, which
/// prevents a misleading success state or an unannounced privacy fallback.
class DownloadManagerController extends StateNotifier<DownloadManagerState> {
  DownloadManagerController({
    required DownloadRepository repository,
    required OfflineDownloadStorage storage,
    required DownloadTransferClient transferClient,
    DirectPeerDownloadWorker directPeerWorker =
        const UnsupportedDirectPeerDownloadWorker(),
    OfflineDownloadKeepAlive keepAlive = const NoopOfflineDownloadKeepAlive(),
    bool autoInitialize = true,
    DateTime Function()? now,
    Random? random,
  }) : _repository = repository,
       _storage = storage,
       _transferClient = transferClient,
       _directPeerWorker = directPeerWorker,
       _keepAlive = keepAlive,
       _now = now ?? (() => DateTime.now().toUtc()),
       _random = random ?? Random.secure(),
       super(DownloadManagerState()) {
    if (autoInitialize) unawaited(initialize());
  }

  final DownloadRepository _repository;
  final OfflineDownloadStorage _storage;
  final DownloadTransferClient _transferClient;
  final DirectPeerDownloadWorker _directPeerWorker;
  final OfflineDownloadKeepAlive _keepAlive;
  final DateTime Function() _now;
  final Random _random;
  final Map<String, Map<String, String>> _ephemeralHeaders = {};
  final Map<String, Object> _directPeerCapabilities = {};
  final Map<String, DownloadCancellationToken> _cancellations = {};
  final Map<String, Completer<void>> _activeRuns = {};
  final Map<String, _RequestedStop> _requestedStops = {};
  final Map<String, Timer> _progressPersistence = {};
  Future<void>? _initializing;
  bool _pumping = false;
  bool _disposed = false;

  Future<void> initialize() {
    final current = _initializing;
    if (current != null) return current;
    final operation = _initialize();
    _initializing = operation;
    return operation.whenComplete(() {
      if (identical(_initializing, operation)) _initializing = null;
    });
  }

  Future<void> _initialize() async {
    if (state.initialized || _disposed) return;
    state = state.copyWith(loading: true, clearErrorMessage: true);
    try {
      final restored = await _repository.listJobs();
      final recovered = <DownloadJob>[];
      for (final persisted in restored) {
        try {
          recovered.add(await _recoverPersistedJob(persisted));
        } catch (_) {
          // One damaged row or filesystem artifact must not prevent every
          // other download from being restored.
          recovered.add(
            persisted.copyWith(
              status: DownloadJobStatus.failed,
              errorCode: 'download_recovery_failed',
              errorMessage: 'This download could not be restored safely.',
              speedBytesPerSecond: 0,
              updatedAt: _now(),
            ),
          );
        }
      }
      await _repository.upsertJobs(recovered);
      final usedBytes = await _storage.usedBytes();
      if (_disposed) return;
      state = state.copyWith(
        jobs: _ordered(recovered),
        initialized: true,
        loading: false,
        storageUsedBytes: usedBytes,
        clearErrorMessage: true,
      );
      unawaited(_pump());
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(
        loading: false,
        initialized: false,
        errorMessage: 'Downloads could not be restored.',
      );
    }
  }

  Future<DownloadJob> _recoverPersistedJob(DownloadJob persisted) async {
    var job = persisted;
    final completedFile = await _storage.finalFile(job);
    final completedArtifactValid = await _storage.completedArtifactIsValid(job);

    // Check the final artifact before the ephemeral-authorization marker. A
    // process can die after the atomic rename but before the database commit;
    // that completed local file no longer needs its private request headers.
    if (completedArtifactValid) {
      final length = await _storage.completedArtifactSize(job);
      return job.copyWith(
        status: DownloadJobStatus.completed,
        expectedBytes: length,
        receivedBytes: length,
        speedBytesPerSecond: 0,
        clearSourceUri: true,
        clearRemoteTransferId: true,
        clearErrorCode: true,
        clearErrorMessage: true,
        updatedAt:
            job.status == DownloadJobStatus.completed &&
                job.expectedBytes == length &&
                job.receivedBytes == length &&
                job.sourceUri == null &&
                job.remoteTransferId == null
            ? job.updatedAt
            : _now(),
      );
    }

    if (job.remoteTransferId == _ephemeralAuthorizationMarker &&
        job.status != DownloadJobStatus.cancelled &&
        job.status != DownloadJobStatus.unsupported) {
      return job.copyWith(
        status: DownloadJobStatus.unsupported,
        errorCode: 'source_reresolution_required',
        errorMessage: 'Re-select this source to authorize the download again.',
        speedBytesPerSecond: 0,
        updatedAt: _now(),
      );
    }

    if (job.status == DownloadJobStatus.completed) {
      return job.copyWith(
        status: DownloadJobStatus.failed,
        errorCode: 'invalid_completed_artifact',
        errorMessage: 'The downloaded episode is missing or incomplete.',
        updatedAt: _now(),
        speedBytesPerSecond: 0,
      );
    }

    if (await completedFile.exists()) {
      // A final playlist/file that cannot be verified would block a later
      // atomic promotion. Remove only that invalid final file; resumable HLS
      // segment checkpoints remain beside it for an explicit retry.
      try {
        await completedFile.delete();
      } on FileSystemException {
        // The job is marked failed even if storage is temporarily unavailable.
      }
      return job.copyWith(
        status: DownloadJobStatus.failed,
        errorCode: 'invalid_completed_artifact',
        errorMessage: 'The downloaded episode is missing or incomplete.',
        speedBytesPerSecond: 0,
        updatedAt: _now(),
      );
    }

    final partialLength = await _storage.partLength(job);
    final recoveredStatus = job.status.isActive
        ? DownloadJobStatus.queued
        : job.status;
    return job.copyWith(
      status: recoveredStatus,
      receivedBytes: partialLength,
      speedBytesPerSecond: 0,
      updatedAt: recoveredStatus == job.status ? job.updatedAt : _now(),
    );
  }

  Future<DownloadJob> enqueue(OfflineDownloadRequest request) async {
    await initialize();
    final jobs = await enqueueAll([request]);
    return jobs.single;
  }

  Future<List<DownloadJob>> enqueueAll(
    Iterable<OfflineDownloadRequest> requests,
  ) async {
    await initialize();
    if (!state.initialized) {
      throw StateError('Downloads are unavailable until restoration succeeds.');
    }
    final values = requests.toList(growable: false);
    if (values.isEmpty) return const [];
    var queuePosition = state.jobs.fold<int>(
      -1,
      (maximum, job) => max(maximum, job.queuePosition),
    );
    final created = <DownloadJob>[];
    for (final request in values) {
      final now = _now();
      final id = _newId(now);
      queuePosition++;
      final relativePath = _storage.allocateRelativePath(request, id);
      final job = DownloadJob(
        id: id,
        anilistMediaId: request.anilistMediaId,
        malMediaId: request.malMediaId,
        episode: request.episode,
        seriesTitle: request.seriesTitle,
        episodeTitle: request.episodeTitle,
        sourceLabel: request.sourceLabel,
        transport: request.transport,
        status: DownloadJobStatus.queued,
        sourceUri: request.sourceUri,
        providerId: request.providerId,
        providerName: request.providerName,
        relativePath: relativePath,
        quality: request.quality,
        audioLabel: request.audioLabel,
        mimeType: request.mimeType,
        expectedBytes: request.expectedBytes,
        remoteTransferId: request.requestHeaders.isNotEmpty
            ? _ephemeralAuthorizationMarker
            : null,
        queuePosition: queuePosition,
        createdAt: now,
        updatedAt: now,
      );
      if (request.requestHeaders.isNotEmpty) {
        _ephemeralHeaders[id] = request.requestHeaders;
      }
      if (request.directPeerCapability case final capability?) {
        _directPeerCapabilities[id] = capability;
      }
      created.add(job);
    }
    await _repository.upsertJobs(created);
    if (!_disposed) {
      state = state.copyWith(
        jobs: _ordered([...state.jobs, ...created]),
        clearErrorMessage: true,
      );
      unawaited(_pump());
    }
    return created;
  }

  Future<void> pause(String id) async {
    final job = state.job(id);
    if (job == null || !job.status.canPause) return;
    final activeRun = _activeRuns[id]?.future;
    if (_activeRuns.containsKey(id)) {
      _requestedStops[id] = _RequestedStop.pause;
      _cancellations[id]?.cancel();
    }
    await activeRun;
    final latest = state.job(id) ?? job;
    await _replaceAndPersist(
      latest.copyWith(
        status: DownloadJobStatus.paused,
        speedBytesPerSecond: 0,
        updatedAt: _now(),
      ),
    );
  }

  Future<void> resume(String id) async {
    final job = state.job(id);
    if (job == null || job.status != DownloadJobStatus.paused) return;
    await _replaceAndPersist(
      job.copyWith(
        status: DownloadJobStatus.queued,
        speedBytesPerSecond: 0,
        clearErrorCode: true,
        clearErrorMessage: true,
        updatedAt: _now(),
      ),
    );
    unawaited(_pump());
  }

  Future<void> retry(
    String id, {
    Uri? refreshedSourceUri,
    Object? directPeerCapability,
  }) async {
    final job = state.job(id);
    if (job == null ||
        (job.status != DownloadJobStatus.failed &&
            job.status != DownloadJobStatus.unsupported)) {
      return;
    }
    if (refreshedSourceUri != null &&
        (refreshedSourceUri.scheme.toLowerCase() != 'https' ||
            refreshedSourceUri.host.isEmpty ||
            refreshedSourceUri.userInfo.isNotEmpty ||
            refreshedSourceUri.fragment.isNotEmpty)) {
      throw ArgumentError.value(refreshedSourceUri, 'refreshedSourceUri');
    }
    if (directPeerCapability != null) {
      _directPeerCapabilities[id] = directPeerCapability;
    }
    if ((refreshedSourceUri != null && refreshedSourceUri != job.sourceUri) ||
        directPeerCapability != null) {
      // A newly resolved source may represent a different rendition or
      // torrent. Never append its bytes to checkpoints from the old source.
      await _storage.deleteJobFiles(job);
    }
    await _replaceAndPersist(
      job.copyWith(
        status: DownloadJobStatus.queued,
        sourceUri: refreshedSourceUri,
        retryCount: job.retryCount + 1,
        speedBytesPerSecond: 0,
        clearErrorCode: true,
        clearErrorMessage: true,
        updatedAt: _now(),
      ),
    );
    unawaited(_pump());
  }

  Future<void> cancel(String id) async {
    final job = state.job(id);
    if (job == null || job.status.isTerminal) return;
    final activeRun = _activeRuns[id]?.future;
    if (_activeRuns.containsKey(id)) {
      _requestedStops[id] = _RequestedStop.cancel;
      _cancellations[id]?.cancel();
    }
    await activeRun;
    final latest = state.job(id) ?? job;
    await _replaceAndPersist(
      latest.copyWith(
        status: DownloadJobStatus.cancelled,
        clearSourceUri: true,
        receivedBytes: 0,
        speedBytesPerSecond: 0,
        clearErrorCode: true,
        clearErrorMessage: true,
        updatedAt: _now(),
      ),
    );
    await _storage.deleteJobFiles(job);
    _ephemeralHeaders.remove(id);
    _directPeerCapabilities.remove(id);
    await refreshStorageUsage();
  }

  Future<void> delete(String id) async {
    final job = state.job(id);
    if (job == null) return;
    final activeRun = _activeRuns[id]?.future;
    if (_activeRuns.containsKey(id)) {
      _requestedStops[id] = _RequestedStop.delete;
      _cancellations[id]?.cancel();
    }
    await activeRun;
    _progressPersistence.remove(id)?.cancel();
    await _storage.deleteJobFiles(job);
    final artworkPaths = await _repository.deleteJobAndPruneMetadata(id);
    for (final relativePath in artworkPaths) {
      await _storage.deleteRelativeArtifact(relativePath);
    }
    _ephemeralHeaders.remove(id);
    _directPeerCapabilities.remove(id);
    DownloadedPlaybackRegistry.instance.unregisterJob(id);
    if (!_disposed) {
      state = state.copyWith(
        jobs: state.jobs.where((value) => value.id != id).toList(),
        clearActiveJobId: state.activeJobId == id,
      );
    }
    await refreshStorageUsage();
  }

  Future<void> refreshStorageUsage() async {
    final bytes = await _storage.usedBytes();
    if (!_disposed) state = state.copyWith(storageUsedBytes: bytes);
  }

  /// Waits until a queued transfer no longer owns an active or retryable slot.
  ///
  /// Whole-season discovery uses this to resolve signed links just before the
  /// episode is downloaded instead of filling the queue with links that may
  /// expire before their turn.
  Future<DownloadJobStatus?> waitUntilSettled(
    String id, {
    Duration pollInterval = const Duration(milliseconds: 200),
  }) async {
    while (!_disposed) {
      final job = state.job(id);
      if (job == null) return null;
      if (job.status == DownloadJobStatus.completed ||
          job.status == DownloadJobStatus.failed ||
          job.status == DownloadJobStatus.cancelled ||
          job.status == DownloadJobStatus.unsupported) {
        return job.status;
      }
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }

  Future<void> _pump() async {
    if (_pumping || _disposed || !state.initialized) return;
    _pumping = true;
    try {
      while (!_disposed) {
        DownloadJob? next;
        for (final job in state.jobs) {
          if (job.status == DownloadJobStatus.queued) {
            next = job;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _pumping = false;
      if (!_disposed &&
          state.jobs.any((job) => job.status == DownloadJobStatus.queued)) {
        unawaited(_pump());
      }
    }
  }

  Future<void> _run(DownloadJob original) async {
    final current = state.job(original.id);
    if (current == null || current.status != DownloadJobStatus.queued) return;
    if (current.transport == DownloadTransport.https &&
        current.sourceUri == null) {
      await _fail(
        current,
        code: 'source_refresh_required',
        message: 'This download link must be refreshed before retrying.',
      );
      return;
    }

    final keepAliveLease = await acquireOfflineDownloadKeepAliveSafely(
      _keepAlive,
    );
    if (_disposed) {
      await releaseOfflineDownloadKeepAliveSafely(keepAliveLease);
      return;
    }

    final token = DownloadCancellationToken();
    final runCompleted = Completer<void>();
    _activeRuns[current.id] = runCompleted;
    _cancellations[current.id] = token;
    var active = current;
    try {
      active = current.copyWith(
        status: DownloadJobStatus.downloading,
        receivedBytes: await _storage.partLength(current),
        speedBytesPerSecond: 0,
        clearErrorCode: true,
        clearErrorMessage: true,
        updatedAt: _now(),
      );
      await _replaceAndPersist(active, activeJobId: active.id);
      final partial = await _storage.preparePartFile(active);
      void handleProgress(DownloadTransferProgress progress) {
        final latest = state.job(active.id);
        if (_disposed ||
            latest == null ||
            latest.status != DownloadJobStatus.downloading) {
          return;
        }
        active = latest.copyWith(
          expectedBytes: progress.totalBytes,
          receivedBytes: progress.receivedBytes,
          speedBytesPerSecond: progress.speedBytesPerSecond,
          updatedAt: _now(),
        );
        _replaceInMemory(active);
        _scheduleProgressPersistence(active.id);
      }

      final DownloadTransferResult result;
      if (active.transport == DownloadTransport.https) {
        result = await _transferClient.download(
          job: active,
          partialFile: partial,
          cancellation: token,
          requestHeaders: _ephemeralHeaders[active.id] ?? const {},
          onProgress: handleProgress,
        );
      } else {
        final capability = _directPeerCapabilities[active.id];
        if (!_directPeerWorker.isAvailable) {
          throw const DownloadTransferException(
            'direct_peer_worker_unavailable',
            'Direct torrent downloads are unavailable in this build. '
                'Connect a Debrid service and retry from the source picker.',
            retryable: false,
          );
        }
        if (capability == null) {
          throw const DownloadTransferException(
            'direct_peer_reresolution_required',
            'Re-select this torrent source to authorize the direct download.',
            retryable: false,
          );
        }
        result = await _directPeerWorker.download(
          job: active,
          capability: capability,
          partialFile: partial,
          cancellation: token,
          onProgress: handleProgress,
        );
      }
      if (_requestedStops.containsKey(active.id)) return;
      _progressPersistence.remove(active.id)?.cancel();
      final latest = state.job(active.id) ?? active;
      await _storage.finalize(
        latest,
        expectedBytes: result.totalBytes ?? result.receivedBytes,
      );
      final completedBytes = await _storage.completedArtifactSize(latest);
      final completed = latest.copyWith(
        status: DownloadJobStatus.completed,
        expectedBytes: completedBytes,
        receivedBytes: completedBytes,
        speedBytesPerSecond: 0,
        mimeType: result.mimeType,
        clearSourceUri: true,
        clearRemoteTransferId: true,
        clearErrorCode: true,
        clearErrorMessage: true,
        updatedAt: _now(),
      );
      await _replaceAndPersist(completed, clearActiveJobId: true);
      _ephemeralHeaders.remove(active.id);
      _directPeerCapabilities.remove(active.id);
      await refreshStorageUsage();
    } on DownloadTransferCancelled {
      // The public pause/cancel/delete operation has already persisted the
      // intended state. A cancellation without one is treated as recoverable.
      if (!_requestedStops.containsKey(active.id)) {
        final latest = state.job(active.id);
        if (latest != null) {
          await _replaceAndPersist(
            latest.copyWith(
              status: DownloadJobStatus.queued,
              speedBytesPerSecond: 0,
              updatedAt: _now(),
            ),
            clearActiveJobId: true,
          );
        }
      }
    } on DownloadTransferException catch (error) {
      if (!_requestedStops.containsKey(active.id)) {
        final latest = state.job(active.id) ?? active;
        if (error.code == 'direct_peer_worker_unavailable' ||
            !error.retryable) {
          await _unsupported(latest, code: error.code, message: error.message);
        } else {
          await _fail(latest, code: error.code, message: error.message);
        }
      }
    } on OfflineDownloadStorageException catch (error) {
      if (!_requestedStops.containsKey(active.id)) {
        final latest = state.job(active.id) ?? active;
        await _fail(latest, code: error.code, message: error.message);
      }
    } catch (_) {
      if (!_requestedStops.containsKey(active.id)) {
        final latest = state.job(active.id) ?? active;
        await _fail(
          latest,
          code: 'unexpected_download_failure',
          message: 'The download stopped unexpectedly.',
        );
      }
    } finally {
      _progressPersistence.remove(active.id)?.cancel();
      _cancellations.remove(active.id);
      _requestedStops.remove(active.id);
      if (!_disposed && state.activeJobId == active.id) {
        state = state.copyWith(clearActiveJobId: true);
      }
      _activeRuns.remove(active.id);
      await releaseOfflineDownloadKeepAliveSafely(keepAliveLease);
      if (!runCompleted.isCompleted) runCompleted.complete();
    }
  }

  Future<void> _fail(
    DownloadJob job, {
    required String code,
    required String message,
  }) async {
    await _replaceAndPersist(
      job.copyWith(
        status: DownloadJobStatus.failed,
        speedBytesPerSecond: 0,
        errorCode: code,
        errorMessage: _boundedMessage(message),
        updatedAt: _now(),
      ),
      clearActiveJobId: true,
    );
  }

  Future<void> _unsupported(
    DownloadJob job, {
    required String code,
    required String message,
  }) async {
    await _replaceAndPersist(
      job.copyWith(
        status: DownloadJobStatus.unsupported,
        speedBytesPerSecond: 0,
        errorCode: code,
        errorMessage: _boundedMessage(message),
        updatedAt: _now(),
      ),
      clearActiveJobId: true,
    );
  }

  Future<void> _replaceAndPersist(
    DownloadJob job, {
    String? activeJobId,
    bool clearActiveJobId = false,
  }) async {
    await _repository.upsertJob(job);
    if (_disposed) return;
    _replaceInMemory(
      job,
      activeJobId: activeJobId,
      clearActiveJobId: clearActiveJobId,
    );
  }

  void _replaceInMemory(
    DownloadJob job, {
    String? activeJobId,
    bool clearActiveJobId = false,
  }) {
    final jobs = [...state.jobs];
    final index = jobs.indexWhere((value) => value.id == job.id);
    if (index < 0) {
      jobs.add(job);
    } else {
      jobs[index] = job;
    }
    state = state.copyWith(
      jobs: _ordered(jobs),
      activeJobId: activeJobId,
      clearActiveJobId: clearActiveJobId,
      clearErrorMessage: true,
    );
  }

  void _scheduleProgressPersistence(String id) {
    if (_progressPersistence.containsKey(id)) return;
    _progressPersistence[id] = Timer(const Duration(milliseconds: 500), () {
      _progressPersistence.remove(id);
      final latest = state.job(id);
      if (latest != null && latest.status == DownloadJobStatus.downloading) {
        unawaited(_repository.upsertJob(latest));
      }
    });
  }

  String _newId(DateTime now) {
    final random = List.generate(
      3,
      (_) => _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
    ).join();
    return 'dl-${now.microsecondsSinceEpoch}-$random';
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _progressPersistence.values) {
      timer.cancel();
    }
    for (final cancellation in _cancellations.values) {
      cancellation.cancel();
    }
    _progressPersistence.clear();
    _cancellations.clear();
    for (final run in _activeRuns.values) {
      if (!run.isCompleted) run.complete();
    }
    _activeRuns.clear();
    _directPeerCapabilities.clear();
    super.dispose();
  }
}

List<DownloadJob> _ordered(Iterable<DownloadJob> jobs) {
  final result = jobs.toList(growable: false);
  result.sort((left, right) {
    final queue = left.queuePosition.compareTo(right.queuePosition);
    if (queue != 0) return queue;
    final created = left.createdAt.compareTo(right.createdAt);
    if (created != 0) return created;
    return left.id.compareTo(right.id);
  });
  return result;
}

String _boundedMessage(String value) {
  final singleLine = value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  return singleLine.length <= 240 ? singleLine : singleLine.substring(0, 240);
}
