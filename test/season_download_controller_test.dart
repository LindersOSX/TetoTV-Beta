import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/downloads/application/season_download_controller.dart';
import 'package:anime_tv/features/downloads/application/season_download_source_resolver.dart';
import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:anime_tv/features/downloads/domain/season_download_plan.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'season work is sequential, skips duplicates, and continues on misses',
    () async {
      final resolver = _FakeResolver(missingEpisodes: {3});
      final enqueued = <OfflineDownloadRequest>[];
      final metadata = <OfflineEpisodeMetadata>[];
      var pins = 0;
      final controller = SeasonDownloadController.withActions(
        initializeDownloads: () async {},
        existingEpisodes: (_) async => {2},
        enqueueDownload: (request) async => enqueued.add(request),
        pinCatalog: (_) async => pins++,
        saveEpisodeMetadata: (value) async => metadata.add(value),
        sourceResolver: resolver,
        clock: () => DateTime.utc(2026, 8, 24),
      );
      addTearDown(controller.dispose);

      final result = await controller.start(_plan(episodeCount: 4));
      expect(result, SeasonDownloadStartResult.started);
      await _waitFor(() => !controller.state.isRunning);

      expect(resolver.maxConcurrent, 1);
      expect(resolver.seenEpisodes, [1, 3, 4]);
      expect(resolver.receivedAffinities[1].webProviderId, 'provider-1');
      expect(enqueued.map((request) => request.episode), [1, 4]);
      expect(metadata.map((value) => value.episode), [1, 4]);
      expect(pins, 1);
      expect(controller.state.phase, SeasonDownloadPhase.partial);
      expect(controller.state.queued, 2);
      expect(controller.state.skipped, 1);
      expect(controller.state.failed, 1);
    },
  );

  test(
    'unavailable direct capability rejects before background work starts',
    () async {
      final resolver = _FakeResolver(directAvailable: false);
      var initialized = false;
      final controller = SeasonDownloadController.withActions(
        initializeDownloads: () async => initialized = true,
        existingEpisodes: (_) async => {},
        enqueueDownload: (_) async {},
        pinCatalog: (_) async {},
        saveEpisodeMetadata: (_) async {},
        sourceResolver: resolver,
      );
      addTearDown(controller.dispose);

      final result = await controller.start(
        _plan(source: SeasonDownloadSourcePolicy.directTorrent),
      );

      expect(result, SeasonDownloadStartResult.directUnavailable);
      expect(initialized, isFalse);
      expect(controller.state.phase, SeasonDownloadPhase.idle);
    },
  );

  test('busy download queue rejects before source discovery starts', () async {
    final resolver = _FakeResolver();
    var initialized = false;
    final controller = SeasonDownloadController.withActions(
      initializeDownloads: () async => initialized = true,
      queueAvailable: () async => false,
      existingEpisodes: (_) async => {},
      enqueueDownload: (_) async {},
      pinCatalog: (_) async {},
      saveEpisodeMetadata: (_) async {},
      sourceResolver: resolver,
    );
    addTearDown(controller.dispose);

    final result = await controller.start(_plan());

    expect(result, SeasonDownloadStartResult.queueBusy);
    expect(initialized, isFalse);
    expect(resolver.seenEpisodes, isEmpty);
    expect(controller.state.phase, SeasonDownloadPhase.idle);
  });

  test('cancelling season discovery prevents later episode enqueues', () async {
    final resolver = _BlockingResolver();
    final enqueued = <OfflineDownloadRequest>[];
    final controller = SeasonDownloadController.withActions(
      initializeDownloads: () async {},
      existingEpisodes: (_) async => {},
      enqueueDownload: (request) async => enqueued.add(request),
      pinCatalog: (_) async {},
      saveEpisodeMetadata: (_) async {},
      sourceResolver: resolver,
    );
    addTearDown(controller.dispose);

    await controller.start(_plan(episodeCount: 4));
    await resolver.started.future;
    controller.cancel();
    resolver.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.state.isRunning, isFalse);
    expect(enqueued, isEmpty);
    expect(resolver.seenEpisodes, [1]);
  });

  test('cancelling a season also cancels its active transfer', () async {
    final enqueueStarted = Completer<void>();
    final releaseEnqueue = Completer<void>();
    var cancelCalls = 0;
    final controller = SeasonDownloadController.withActions(
      initializeDownloads: () async {},
      existingEpisodes: (_) async => {},
      enqueueDownload: (_) async {
        if (!enqueueStarted.isCompleted) enqueueStarted.complete();
        await releaseEnqueue.future;
      },
      cancelActiveDownload: () async {
        cancelCalls++;
        if (!releaseEnqueue.isCompleted) releaseEnqueue.complete();
      },
      pinCatalog: (_) async {},
      saveEpisodeMetadata: (_) async {},
      sourceResolver: _FakeResolver(),
    );
    addTearDown(controller.dispose);

    await controller.start(_plan(episodeCount: 2));
    await enqueueStarted.future;
    controller.cancel();
    await _waitFor(() => cancelCalls == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.state.phase, SeasonDownloadPhase.idle);
    expect(controller.state.queued, 0);
    expect(cancelCalls, 1);
  });

  test('a slow cancel clear cannot erase the next season plan', () async {
    final resolver = _BlockingResolver();
    final clearStarted = Completer<void>();
    final releaseClear = Completer<void>();
    final operations = <String>[];
    final controller = SeasonDownloadController.withActions(
      initializeDownloads: () async {},
      existingEpisodes: (_) async => {},
      enqueueDownload: (_) async {},
      pinCatalog: (_) async {},
      saveEpisodeMetadata: (_) async {},
      sourceResolver: resolver,
      persistPendingPlan: (plan) async {
        operations.add('save:${plan.episodeCount}');
      },
      clearPendingPlan: () async {
        operations.add('clear:start');
        if (!clearStarted.isCompleted) clearStarted.complete();
        await releaseClear.future;
        operations.add('clear:end');
      },
    );
    addTearDown(controller.dispose);

    await controller.start(_plan(episodeCount: 4));
    await resolver.started.future;
    controller.cancel();
    await clearStarted.future;
    resolver.release.complete();

    final nextStart = controller.start(_plan(episodeCount: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      operations,
      ['save:4', 'clear:start'],
      reason: 'the replacement save must wait for cancellation cleanup',
    );

    releaseClear.complete();
    expect(await nextStart, SeasonDownloadStartResult.started);
    expect(operations.take(3), ['save:4', 'clear:start', 'clear:end']);
    expect(operations[3], 'save:2');
  });

  test('terminal Debrid cleanup failure aborts the whole season', () async {
    final resolver = _TerminalResolver();
    final enqueued = <OfflineDownloadRequest>[];
    final controller = SeasonDownloadController.withActions(
      initializeDownloads: () async {},
      existingEpisodes: (_) async => {},
      enqueueDownload: (request) async => enqueued.add(request),
      pinCatalog: (_) async {},
      saveEpisodeMetadata: (_) async {},
      sourceResolver: resolver,
    );
    addTearDown(controller.dispose);

    await controller.start(_plan(episodeCount: 4));
    await _waitFor(() => !controller.state.isRunning);

    expect(controller.state.phase, SeasonDownloadPhase.failed);
    expect(enqueued, isEmpty);
    expect(resolver.seenEpisodes, [1]);
  });

  test('failed transfer is unavailable instead of counted as queued', () async {
    final metadata = <OfflineEpisodeMetadata>[];
    final controller = SeasonDownloadController.withActions(
      initializeDownloads: () async {},
      existingEpisodes: (_) async => {},
      enqueueDownload: (_) async => throw Exception('transfer failed'),
      pinCatalog: (_) async {},
      saveEpisodeMetadata: (value) async => metadata.add(value),
      sourceResolver: _FakeResolver(),
    );
    addTearDown(controller.dispose);

    await controller.start(_plan(episodeCount: 1));
    await _waitFor(() => !controller.state.isRunning);

    expect(controller.state.phase, SeasonDownloadPhase.failed);
    expect(controller.state.queued, 0);
    expect(controller.state.failed, 1);
    expect(metadata, isEmpty);
  });

  test(
    'restores a pending season and skips episodes already durable',
    () async {
      final resolver = _FakeResolver();
      var queueChecks = 0;
      var resumeWaits = 0;
      var clears = 0;
      final controller = SeasonDownloadController.withActions(
        initializeDownloads: () async {},
        queueAvailable: () async => ++queueChecks >= 2,
        existingEpisodes: (_) async => {1},
        enqueueDownload: (_) async {},
        pinCatalog: (_) async {},
        saveEpisodeMetadata: (_) async {},
        sourceResolver: resolver,
        restorePendingPlan: () async => _plan(episodeCount: 3),
        clearPendingPlan: () async => clears++,
        resumeDelay: (_) async => resumeWaits++,
      );
      addTearDown(controller.dispose);

      await controller.restorePending();
      expect(controller.state.phase, SeasonDownloadPhase.preparing);
      await _waitFor(() => !controller.state.isRunning);

      expect(resumeWaits, 1);
      expect(resolver.seenEpisodes, [2, 3]);
      expect(controller.state.skipped, 1);
      expect(controller.state.phase, SeasonDownloadPhase.completed);
      expect(clears, 1);
    },
  );

  test(
    'persists before starting and retains interrupted season work',
    () async {
      final persisted = <SeasonDownloadPlan>[];
      var clears = 0;
      final controller = SeasonDownloadController.withActions(
        initializeDownloads: () async {},
        existingEpisodes: (_) async => {},
        enqueueDownload: (_) async {},
        pinCatalog: (_) async {},
        saveEpisodeMetadata: (_) async {},
        sourceResolver: _TerminalResolver(),
        persistPendingPlan: (plan) async => persisted.add(plan),
        clearPendingPlan: () async => clears++,
      );
      addTearDown(controller.dispose);

      final result = await controller.start(_plan(episodeCount: 3));
      expect(result, SeasonDownloadStartResult.started);
      expect(persisted, hasLength(1));
      await _waitFor(() => !controller.state.isRunning);

      expect(controller.state.phase, SeasonDownloadPhase.failed);
      expect(clears, 0, reason: 'unfinished work must remain resumable');
    },
  );

  test(
    'refuses to start when the durable season request cannot be saved',
    () async {
      final resolver = _FakeResolver();
      final controller = SeasonDownloadController.withActions(
        initializeDownloads: () async {},
        existingEpisodes: (_) async => {},
        enqueueDownload: (_) async {},
        pinCatalog: (_) async {},
        saveEpisodeMetadata: (_) async {},
        sourceResolver: resolver,
        persistPendingPlan: (_) async => throw Exception('disk full'),
      );
      addTearDown(controller.dispose);

      final result = await controller.start(_plan());

      expect(result, SeasonDownloadStartResult.storageUnavailable);
      expect(controller.state.phase, SeasonDownloadPhase.failed);
      expect(resolver.seenEpisodes, isEmpty);
    },
  );

  test('one background lease protects the complete season pass', () async {
    final keepAlive = _RecordingKeepAlive();
    final activeDuringEnqueue = <int>[];
    final controller = SeasonDownloadController.withActions(
      initializeDownloads: () async {},
      existingEpisodes: (_) async => {},
      enqueueDownload: (_) async {
        activeDuringEnqueue.add(keepAlive.active);
      },
      pinCatalog: (_) async {},
      saveEpisodeMetadata: (_) async {},
      sourceResolver: _FakeResolver(),
      keepAlive: keepAlive,
    );
    addTearDown(controller.dispose);

    await controller.start(_plan(episodeCount: 3));
    await _waitFor(
      () => !controller.state.isRunning && keepAlive.releases == 1,
    );

    expect(activeDuringEnqueue, [1, 1, 1]);
    expect(keepAlive.acquires, 1);
    expect(keepAlive.releases, 1);
  });
}

class _RecordingKeepAlive implements OfflineDownloadKeepAlive {
  var active = 0;
  var acquires = 0;
  var releases = 0;

  @override
  Future<OfflineDownloadKeepAliveLease> acquire() async {
    active++;
    acquires++;
    return _RecordingKeepAliveLease(this);
  }
}

class _RecordingKeepAliveLease implements OfflineDownloadKeepAliveLease {
  _RecordingKeepAliveLease(this.owner);

  final _RecordingKeepAlive owner;
  bool released = false;

  @override
  Future<void> release() async {
    if (released) return;
    released = true;
    owner.active--;
    owner.releases++;
  }
}

class _FakeResolver implements SeasonEpisodeDownloadResolver {
  _FakeResolver({this.missingEpisodes = const {}, this.directAvailable = true});

  final Set<int> missingEpisodes;
  final bool directAvailable;
  final List<int> seenEpisodes = [];
  final List<SeasonDownloadAffinity> receivedAffinities = [];
  var active = 0;
  var maxConcurrent = 0;

  @override
  Future<bool> directTorrentAvailable() async => directAvailable;

  @override
  Future<ResolvedSeasonDownload?> resolve({
    required SeasonDownloadPlan plan,
    required EpisodeReference episode,
    required SeasonDownloadAffinity affinity,
  }) async {
    active++;
    if (active > maxConcurrent) maxConcurrent = active;
    seenEpisodes.add(episode.episode);
    receivedAffinities.add(affinity);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    active--;
    if (missingEpisodes.contains(episode.episode)) return null;
    return ResolvedSeasonDownload(
      request: OfflineDownloadRequest(
        anilistMediaId: episode.anilistMediaId,
        episode: episode.episode,
        seriesTitle: episode.title,
        sourceLabel: 'Provider',
        transport: DownloadTransport.https,
        sourceUri: Uri.parse(
          'https://cdn.example.test/episode-${episode.episode}.mp4',
        ),
      ),
      affinity: SeasonDownloadAffinity(
        webProviderId: affinity.webProviderId ?? 'provider-1',
      ),
    );
  }
}

class _BlockingResolver implements SeasonEpisodeDownloadResolver {
  final started = Completer<void>();
  final release = Completer<void>();
  final seenEpisodes = <int>[];

  @override
  Future<bool> directTorrentAvailable() async => true;

  @override
  Future<ResolvedSeasonDownload?> resolve({
    required SeasonDownloadPlan plan,
    required EpisodeReference episode,
    required SeasonDownloadAffinity affinity,
  }) async {
    seenEpisodes.add(episode.episode);
    if (!started.isCompleted) started.complete();
    await release.future;
    return ResolvedSeasonDownload(
      request: OfflineDownloadRequest(
        anilistMediaId: episode.anilistMediaId,
        episode: episode.episode,
        seriesTitle: episode.title,
        sourceLabel: 'Provider',
        transport: DownloadTransport.https,
        sourceUri: Uri.parse('https://cdn.example.test/episode.mp4'),
      ),
      affinity: affinity,
    );
  }
}

class _TerminalResolver implements SeasonEpisodeDownloadResolver {
  final seenEpisodes = <int>[];

  @override
  Future<bool> directTorrentAvailable() async => true;

  @override
  Future<ResolvedSeasonDownload?> resolve({
    required SeasonDownloadPlan plan,
    required EpisodeReference episode,
    required SeasonDownloadAffinity affinity,
  }) async {
    seenEpisodes.add(episode.episode);
    throw const DebridCleanupFailureException(DebridService.realDebrid);
  }
}

SeasonDownloadPlan _plan({
  int episodeCount = 2,
  SeasonDownloadSourcePolicy source = SeasonDownloadSourcePolicy.automatic,
}) => SeasonDownloadPlan(
  anime: AnimeSummary(
    id: 10,
    title: 'Example',
    description: '',
    episodes: episodeCount,
    score: null,
  ),
  episodeCount: episodeCount,
  quality: SeasonDownloadQuality.p1080,
  sourcePolicy: source,
  preferredAudio: PlaybackAudioPreference.dub,
);

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Season download did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
