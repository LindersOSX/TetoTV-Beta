// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/application/offline_catalog_providers.dart';
import 'package:anime_tv/features/downloads/application/offline_catalog_snapshot_service.dart';
import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:anime_tv/features/downloads/application/season_download_source_resolver.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/season_download_plan_store.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SeasonDownloadPhase {
  idle,
  preparing,
  running,
  completed,
  partial,
  failed,
}

enum SeasonDownloadStartResult {
  started,
  alreadyRunning,
  queueBusy,
  directUnavailable,
  storageUnavailable,
}

class SeasonDownloadState {
  const SeasonDownloadState({
    this.phase = SeasonDownloadPhase.idle,
    this.mediaId,
    this.total = 0,
    this.processed = 0,
    this.queued = 0,
    this.skipped = 0,
    this.failed = 0,
    this.eventId = 0,
  });

  final SeasonDownloadPhase phase;
  final int? mediaId;
  final int total;
  final int processed;
  final int queued;
  final int skipped;
  final int failed;
  final int eventId;

  bool get isRunning =>
      phase == SeasonDownloadPhase.preparing ||
      phase == SeasonDownloadPhase.running;

  double get progress => total <= 0 ? 0 : (processed / total).clamp(0, 1);

  String get compactLabel {
    if (phase == SeasonDownloadPhase.preparing) return 'Preparing downloads…';
    if (phase == SeasonDownloadPhase.running) {
      return 'Preparing $processed of $total';
    }
    return 'Download season';
  }

  String get completionMessage {
    if (phase == SeasonDownloadPhase.completed) {
      return queued == 0
          ? 'Every episode is already in Downloads.'
          : '$queued episode${queued == 1 ? '' : 's'} added to Downloads.';
    }
    if (phase == SeasonDownloadPhase.partial) {
      return '$queued queued, $failed unavailable, $skipped already added.';
    }
    return 'No downloadable episodes were found.';
  }

  SeasonDownloadState copyWith({
    SeasonDownloadPhase? phase,
    int? mediaId,
    int? total,
    int? processed,
    int? queued,
    int? skipped,
    int? failed,
    int? eventId,
  }) => SeasonDownloadState(
    phase: phase ?? this.phase,
    mediaId: mediaId ?? this.mediaId,
    total: total ?? this.total,
    processed: processed ?? this.processed,
    queued: queued ?? this.queued,
    skipped: skipped ?? this.skipped,
    failed: failed ?? this.failed,
    eventId: eventId ?? this.eventId,
  );
}

final seasonDownloadControllerProvider =
    StateNotifierProvider<SeasonDownloadController, SeasonDownloadState>((ref) {
      final controller = SeasonDownloadController(
        downloadManager: ref.watch(downloadManagerProvider.notifier),
        repository: ref.watch(downloadRepositoryProvider),
        catalogSnapshots: ref.watch(offlineCatalogSnapshotServiceProvider),
        sourceResolver: ref.watch(seasonEpisodeDownloadResolverProvider),
        keepAlive: ref.watch(offlineDownloadKeepAliveProvider),
        onCatalogChanged: () {
          ref.invalidate(offlineCatalogSnapshotsProvider);
        },
      );
      // Season preparation is a durable queue operation. Restore it eagerly
      // as soon as the provider is mounted instead of waiting for the viewer
      // to revisit the same details page.
      unawaited(controller.restorePending());
      return controller;
    });

class SeasonDownloadController extends StateNotifier<SeasonDownloadState> {
  factory SeasonDownloadController({
    required DownloadManagerController downloadManager,
    required DownloadRepository repository,
    required OfflineCatalogSnapshotService catalogSnapshots,
    required SeasonEpisodeDownloadResolver sourceResolver,
    OfflineDownloadKeepAlive keepAlive = const NoopOfflineDownloadKeepAlive(),
    void Function()? onCatalogChanged,
    DateTime Function()? clock,
  }) {
    String? activeSeasonJobId;
    final planStore = SeasonDownloadPlanStore(repository: repository);
    return SeasonDownloadController.withActions(
      initializeDownloads: downloadManager.initialize,
      queueAvailable: () async {
        await downloadManager.initialize();
        return downloadManager.state.initialized &&
            !downloadManager.state.jobs.any(
              (job) =>
                  job.status == DownloadJobStatus.queued || job.status.isActive,
            );
      },
      existingEpisodes: (mediaId) async {
        final jobs = await repository.listJobs();
        return {
          for (final job in jobs)
            if (job.anilistMediaId == mediaId && _countsAsAdded(job.status))
              job.episode,
        };
      },
      enqueueDownload: (request) async {
        final job = await downloadManager.enqueue(request);
        activeSeasonJobId = job.id;
        try {
          // Resolve the next provider/source only after this transfer settles.
          // This keeps short-lived Debrid and web URLs fresh and bounds
          // provider-side work to one episode at a time.
          final status = await downloadManager.waitUntilSettled(job.id);
          if (status != DownloadJobStatus.completed) {
            final latest = downloadManager.state.job(job.id);
            throw _SeasonDownloadTransferFailure(
              abortBatch:
                  status == DownloadJobStatus.unsupported ||
                  (latest?.errorCode?.contains('storage') ?? false),
            );
          }
        } finally {
          if (activeSeasonJobId == job.id) activeSeasonJobId = null;
        }
      },
      cancelActiveDownload: () async {
        final id = activeSeasonJobId;
        if (id != null) await downloadManager.cancel(id);
      },
      pinCatalog: (anime) async {
        await catalogSnapshots.pin(anime);
        onCatalogChanged?.call();
      },
      persistPendingPlan: planStore.save,
      restorePendingPlan: planStore.load,
      clearPendingPlan: planStore.clear,
      saveEpisodeMetadata: repository.upsertEpisodeMetadata,
      sourceResolver: sourceResolver,
      keepAlive: keepAlive,
      clock: clock,
    );
  }

  SeasonDownloadController.withActions({
    required Future<void> Function() initializeDownloads,
    Future<bool> Function()? queueAvailable,
    required Future<Set<int>> Function(int mediaId) existingEpisodes,
    required Future<void> Function(OfflineDownloadRequest request)
    enqueueDownload,
    required Future<void> Function(AnimeSummary anime) pinCatalog,
    required Future<void> Function(OfflineEpisodeMetadata metadata)
    saveEpisodeMetadata,
    required SeasonEpisodeDownloadResolver sourceResolver,
    OfflineDownloadKeepAlive keepAlive = const NoopOfflineDownloadKeepAlive(),
    Future<void> Function()? cancelActiveDownload,
    Future<void> Function(SeasonDownloadPlan plan)? persistPendingPlan,
    Future<SeasonDownloadPlan?> Function()? restorePendingPlan,
    Future<void> Function()? clearPendingPlan,
    Future<void> Function(Duration delay)? resumeDelay,
    DateTime Function()? clock,
  }) : _initializeDownloads = initializeDownloads,
       _queueAvailable = queueAvailable ?? _alwaysAvailable,
       _existingEpisodes = existingEpisodes,
       _enqueueDownload = enqueueDownload,
       _pinCatalog = pinCatalog,
       _saveEpisodeMetadata = saveEpisodeMetadata,
       _sourceResolver = sourceResolver,
       _keepAlive = keepAlive,
       _cancelActiveDownload = cancelActiveDownload ?? _noopAsync,
       _persistPendingPlan = persistPendingPlan ?? _ignorePersistedPlan,
       _restorePendingPlan = restorePendingPlan ?? _noPersistedPlan,
       _clearPendingPlan = clearPendingPlan ?? _noopAsync,
       _resumeDelay = resumeDelay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now,
       super(const SeasonDownloadState());

  final Future<void> Function() _initializeDownloads;
  final Future<bool> Function() _queueAvailable;
  final Future<Set<int>> Function(int mediaId) _existingEpisodes;
  final Future<void> Function(OfflineDownloadRequest request) _enqueueDownload;
  final Future<void> Function(AnimeSummary anime) _pinCatalog;
  final Future<void> Function(OfflineEpisodeMetadata metadata)
  _saveEpisodeMetadata;
  final SeasonEpisodeDownloadResolver _sourceResolver;
  final OfflineDownloadKeepAlive _keepAlive;
  final Future<void> Function() _cancelActiveDownload;
  final Future<void> Function(SeasonDownloadPlan plan) _persistPendingPlan;
  final Future<SeasonDownloadPlan?> Function() _restorePendingPlan;
  final Future<void> Function() _clearPendingPlan;
  final Future<void> Function(Duration delay) _resumeDelay;
  final DateTime Function() _clock;
  int _generation = 0;
  Future<void>? _restoreOperation;
  Future<void> _planStorageTail = Future<void>.value();

  Future<bool> directTorrentAvailable() =>
      _sourceResolver.directTorrentAvailable();

  /// Loads the single durable season request and schedules its continuation.
  ///
  /// The returned future completes after the plan is read, not after every
  /// episode finishes. This lets the UI immediately observe [isRunning] while
  /// a recovered individual transfer drains from the persistent queue.
  Future<void> restorePending() {
    final current = _restoreOperation;
    if (current != null) return current;
    final operation = _loadPendingPlan();
    _restoreOperation = operation;
    return operation;
  }

  Future<void> _loadPendingPlan() async {
    SeasonDownloadPlan? plan;
    try {
      plan = await _restorePendingPlan();
    } catch (_) {
      return;
    }
    if (plan == null || !mounted || state.isRunning) return;
    final generation = ++_generation;
    state = SeasonDownloadState(
      phase: SeasonDownloadPhase.preparing,
      mediaId: plan.anime.id,
      total: plan.episodeCount,
      eventId: state.eventId,
    );
    unawaited(_resumePersistedPlan(plan, generation));
  }

  Future<void> _resumePersistedPlan(
    SeasonDownloadPlan plan,
    int generation,
  ) async {
    try {
      if (plan.sourcePolicy == SeasonDownloadSourcePolicy.directTorrent &&
          !await directTorrentAvailable()) {
        if (_isCurrent(generation)) {
          state = state.copyWith(
            phase: SeasonDownloadPhase.failed,
            eventId: state.eventId + 1,
          );
        }
        return;
      }
      while (_isCurrent(generation) && !await _queueAvailable()) {
        // An individual episode was durable before process death and is being
        // restored by DownloadManager. Wait for it to settle, then derive the
        // remaining episode set from the database instead of duplicating it.
        await _resumeDelay(const Duration(seconds: 2));
      }
      if (!_isCurrent(generation)) return;
      await _run(plan, generation);
    } catch (_) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        phase: SeasonDownloadPhase.failed,
        eventId: state.eventId + 1,
      );
    }
  }

  Future<SeasonDownloadStartResult> start(SeasonDownloadPlan plan) async {
    await restorePending();
    if (state.isRunning) return SeasonDownloadStartResult.alreadyRunning;
    if (!await _queueAvailable()) return SeasonDownloadStartResult.queueBusy;
    if (plan.sourcePolicy == SeasonDownloadSourcePolicy.directTorrent &&
        !await directTorrentAvailable()) {
      return SeasonDownloadStartResult.directUnavailable;
    }
    try {
      // Persist before starting unawaited work. If Android reclaims the app in
      // the following frame, the next launch can still resolve the first (or
      // next) episode from fresh provider URLs.
      await _serializePlanStorage(() => _persistPendingPlan(plan));
    } catch (_) {
      state = SeasonDownloadState(
        phase: SeasonDownloadPhase.failed,
        mediaId: plan.anime.id,
        total: plan.episodeCount,
        // The caller reports this immediate start failure. Reserve eventId
        // changes for asynchronous season outcomes so details does not show a
        // second, misleading completion snackbar.
        eventId: state.eventId,
      );
      return SeasonDownloadStartResult.storageUnavailable;
    }
    final generation = ++_generation;
    state = SeasonDownloadState(
      phase: SeasonDownloadPhase.preparing,
      mediaId: plan.anime.id,
      total: plan.episodeCount,
      eventId: state.eventId,
    );
    unawaited(_run(plan, generation));
    return SeasonDownloadStartResult.started;
  }

  void cancel() {
    if (!state.isRunning) return;
    _generation++;
    state = SeasonDownloadState(
      phase: SeasonDownloadPhase.idle,
      mediaId: state.mediaId,
      total: state.total,
      processed: state.processed,
      queued: state.queued,
      skipped: state.skipped,
      failed: state.failed,
      eventId: state.eventId + 1,
    );
    unawaited(_cancelActiveDownload());
    // Queue the clear before returning. A new start serializes its save behind
    // this operation, so a slow cancellation cleanup can never erase the new
    // season plan after it has been persisted.
    unawaited(_serializePlanStorage(_clearPendingPlan));
  }

  Future<void> _run(SeasonDownloadPlan plan, int generation) async {
    final keepAliveLease = await acquireOfflineDownloadKeepAliveSafely(
      _keepAlive,
    );
    try {
      await _runWhileProtected(plan, generation);
    } finally {
      await releaseOfflineDownloadKeepAliveSafely(keepAliveLease);
    }
  }

  Future<void> _runWhileProtected(
    SeasonDownloadPlan plan,
    int generation,
  ) async {
    try {
      await _initializeDownloads();
      try {
        await _pinCatalog(plan.anime);
      } catch (_) {
        // Artwork and catalog pinning are helpful but never block the videos.
      }
      final alreadyAdded = {...await _existingEpisodes(plan.anime.id)};
      if (!_isCurrent(generation)) return;
      var queued = 0;
      var skipped = 0;
      var failed = 0;
      var affinity = const SeasonDownloadAffinity();
      state = state.copyWith(phase: SeasonDownloadPhase.running);

      for (
        var episodeNumber = 1;
        episodeNumber <= plan.episodeCount;
        episodeNumber++
      ) {
        if (!_isCurrent(generation)) return;
        if (alreadyAdded.contains(episodeNumber)) {
          skipped++;
          state = state.copyWith(
            processed: episodeNumber,
            queued: queued,
            skipped: skipped,
            failed: failed,
          );
          continue;
        }
        ResolvedSeasonDownload? resolved;
        try {
          resolved = await _sourceResolver.resolve(
            plan: plan,
            episode: seasonEpisodeReference(plan, episodeNumber),
            affinity: affinity,
          );
          if (!_isCurrent(generation)) {
            await resolved?.close?.call();
            return;
          }
          if (resolved == null) {
            failed++;
          } else {
            try {
              await _enqueueDownload(resolved.request);
              if (!_isCurrent(generation)) return;
              affinity = resolved.affinity;
              alreadyAdded.add(episodeNumber);
              queued++;
              try {
                await _saveEpisodeMetadata(
                  OfflineEpisodeMetadata(
                    anilistMediaId: plan.anime.id,
                    episode: episodeNumber,
                    metadata: {
                      'title': 'Episode $episodeNumber',
                      'quality': resolved.request.quality,
                      'audio': resolved.request.audioLabel,
                    },
                    duration: _episodeDuration(plan.anime.durationMinutes),
                    updatedAt: _clock().toUtc(),
                  ),
                );
              } catch (_) {
                // The video is already durable in the queue. Missing optional
                // episode text must not misreport that successful enqueue.
              }
            } finally {
              await resolved.close?.call();
            }
          }
        } catch (error) {
          await resolved?.close?.call();
          if (!_isCurrent(generation)) return;
          if (isTerminalDebridFailoverFailure(error)) rethrow;
          failed++;
          if (error is _SeasonDownloadTransferFailure && error.abortBatch) {
            state = state.copyWith(
              processed: episodeNumber,
              queued: queued,
              skipped: skipped,
              failed: failed,
            );
            rethrow;
          }
        }
        state = state.copyWith(
          processed: episodeNumber,
          queued: queued,
          skipped: skipped,
          failed: failed,
        );
      }
      if (!_isCurrent(generation)) return;
      final phase = failed == 0
          ? SeasonDownloadPhase.completed
          : queued > 0 || skipped > 0
          ? SeasonDownloadPhase.partial
          : SeasonDownloadPhase.failed;
      state = state.copyWith(phase: phase, eventId: state.eventId + 1);
      // A full pass has now accounted for every episode. Partial means some
      // providers had no result, not that the season loop was abandoned.
      // Interrupted/terminal failures reach the catch below and retain the
      // plan for the next launch instead.
      try {
        await _serializePlanStorage(_clearPendingPlan);
      } catch (_) {
        // Completed downloads remain valid. A stale plan is harmless: the
        // next launch skips every durable episode and clears it again.
      }
    } catch (_) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        phase: SeasonDownloadPhase.failed,
        eventId: state.eventId + 1,
      );
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _serializePlanStorage(Future<void> Function() operation) {
    final scheduled = _planStorageTail.then<void>((_) => operation());
    // Keep the sequencing tail successful even when this caller needs to
    // observe a storage error. Later cleanup/save operations must still run.
    _planStorageTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }
}

EpisodeReference seasonEpisodeReference(SeasonDownloadPlan plan, int episode) {
  final anime = plan.anime;
  final alternatives = <String>{
    if (anime.titleEnglish?.trim().isNotEmpty == true) anime.titleEnglish!,
    if (anime.titleRomaji?.trim().isNotEmpty == true) anime.titleRomaji!,
    ...anime.synonyms.where((title) => title.trim().isNotEmpty),
  }..remove(anime.title);
  return EpisodeReference(
    anilistMediaId: anime.id,
    malMediaId: anime.idMal,
    year: anime.seasonYear,
    title: anime.title,
    alternativeTitles: alternatives.toList(growable: false),
    titleEnglish: anime.titleEnglish,
    titleRomaji: anime.titleRomaji,
    status: anime.status,
    format: anime.format,
    episodeCount: plan.episodeCount,
    isAdult: anime.isAdult,
    coverImageUrl: anime.coverImageUrl,
    episode: episode,
  );
}

bool _countsAsAdded(DownloadJobStatus status) => switch (status) {
  DownloadJobStatus.queued ||
  DownloadJobStatus.resolving ||
  DownloadJobStatus.downloading ||
  DownloadJobStatus.paused ||
  DownloadJobStatus.completed => true,
  DownloadJobStatus.failed ||
  DownloadJobStatus.cancelled ||
  DownloadJobStatus.unsupported => false,
};

Duration? _episodeDuration(int? minutes) =>
    minutes != null && minutes > 0 ? Duration(minutes: minutes) : null;

Future<void> _noopAsync() async {}

Future<void> _ignorePersistedPlan(SeasonDownloadPlan _) async {}

Future<SeasonDownloadPlan?> _noPersistedPlan() async => null;

Future<bool> _alwaysAvailable() async => true;

final class _SeasonDownloadTransferFailure implements Exception {
  const _SeasonDownloadTransferFailure({required this.abortBatch});

  final bool abortBatch;
}
