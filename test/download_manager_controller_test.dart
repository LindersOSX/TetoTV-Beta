import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/application/downloaded_episode_source_service.dart';
import 'package:anime_tv/features/downloads/application/offline_download_keep_alive.dart';
import 'package:anime_tv/features/downloads/data/dio_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/downloaded_episode_asset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporary;
  late Database database;
  late DownloadRepository repository;
  late OfflineDownloadStorage storage;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tetotv-manager-');
    database = await databaseFactoryFfi.openDatabase(
      '${temporary.path}${Platform.pathSeparator}downloads.db',
      options: OpenDatabaseOptions(
        version: 8,
        onCreate: (db, _) => createOfflineDownloadTables(db),
      ),
    );
    repository = DownloadRepository.forDatabase(database);
    storage = OfflineDownloadStorage(
      resolveRoot: () async => Directory(
        '${temporary.path}${Platform.pathSeparator}offline_downloads',
      ),
    );
    DownloadedPlaybackRegistry.instance.clearForTesting();
  });

  tearDown(() async {
    DownloadedPlaybackRegistry.instance.clearForTesting();
    await database.close();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('completed HTTPS job is persisted and issued as a safe asset', () async {
    final controller = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: _ImmediateTransferClient(totalBytes: 32),
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    final job = await controller.enqueue(_request());
    await _waitFor(
      () => controller.state.job(job.id)?.status == DownloadJobStatus.completed,
    );

    final persisted = await repository.job(job.id);
    expect(persisted?.receivedBytes, 32);
    expect(persisted?.sourceUri, isNull);
    expect(await (await storage.finalFile(persisted!)).length(), 32);
    final service = DownloadedEpisodeSourceService(
      repository: repository,
      storage: storage,
    );
    final asset = await service.completedEpisode(10, 1);
    expect(asset, isNotNull);
    expect(
      DownloadedPlaybackRegistry.instance.ownsUri(asset!.playbackUri),
      isTrue,
    );
    expect(
      DownloadedPlaybackRegistry.instance.ownsUri(
        Uri.file('${temporary.path}/untrusted.mkv'),
      ),
      isFalse,
    );
  });

  test('an active transfer owns and releases a background lease', () async {
    final keepAlive = _RecordingKeepAlive();
    final controller = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: _ImmediateTransferClient(totalBytes: 32),
      keepAlive: keepAlive,
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    final job = await controller.enqueue(_request());
    await _waitFor(
      () =>
          controller.state.job(job.id)?.status == DownloadJobStatus.completed &&
          keepAlive.releases == 1,
    );

    expect(keepAlive.acquires, 1);
    expect(keepAlive.releases, 1);
    expect(keepAlive.maximumActive, 1);
  });

  test(
    'completed lookup falls back to an older valid legacy artifact',
    () async {
      final olderAt = DateTime.utc(2026, 8, 23);
      final newerAt = DateTime.utc(2026, 8, 24);
      final older = DownloadJob(
        id: 'older-valid',
        anilistMediaId: 10,
        episode: 1,
        seriesTitle: 'Example',
        sourceLabel: 'Older download',
        transport: DownloadTransport.https,
        status: DownloadJobStatus.completed,
        // This is the pre-structured-layout path used by existing installs.
        relativePath: '10/episode-1-older-valid.mkv',
        expectedBytes: 12,
        receivedBytes: 12,
        queuePosition: 0,
        createdAt: olderAt,
        updatedAt: olderAt,
      );
      final newer = DownloadJob(
        id: 'newer-missing',
        anilistMediaId: 10,
        episode: 1,
        seriesTitle: 'Example',
        sourceLabel: 'Newer download',
        transport: DownloadTransport.https,
        status: DownloadJobStatus.completed,
        relativePath:
            'shows/anilist-0000000010/season-0001/'
            'episode-0001/newer-missing/media.mkv',
        expectedBytes: 12,
        receivedBytes: 12,
        queuePosition: 1,
        createdAt: newerAt,
        updatedAt: newerAt,
      );
      await repository.upsertJobs([older, newer]);
      final legacyFile = await storage.finalFile(older);
      await legacyFile.parent.create(recursive: true);
      await legacyFile.writeAsBytes(List<int>.filled(12, 1), flush: true);

      final service = DownloadedEpisodeSourceService(
        repository: repository,
        storage: storage,
      );
      final episodeAsset = await service.completedEpisode(10, 1);
      final mediaAssets = await service.completedEpisodesForMedia(10);

      expect(episodeAsset?.job.id, older.id);
      expect(episodeAsset?.file.path, legacyFile.path);
      expect(mediaAssets.map((asset) => asset.job.id), [older.id]);
    },
  );

  test(
    'completed lookup keeps an offline source across catalog ID changes',
    () async {
      final now = DateTime.utc(2026, 8, 24);
      final downloaded = DownloadJob(
        id: 'lucky-star-download',
        anilistMediaId: 1887,
        malMediaId: 1887,
        episode: 1,
        seriesTitle: 'Lucky☆Star',
        sourceLabel: 'Season download',
        transport: DownloadTransport.https,
        status: DownloadJobStatus.completed,
        relativePath:
            'shows/anilist-0000001887/season-0001/'
            'episode-0001/lucky-star-download/media.mkv',
        expectedBytes: 12,
        receivedBytes: 12,
        queuePosition: 0,
        createdAt: now,
        updatedAt: now,
      );
      await repository.upsertJob(downloaded);
      final file = await storage.finalFile(downloaded);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(12, 1), flush: true);

      final service = DownloadedEpisodeSourceService(
        repository: repository,
        storage: storage,
      );
      final byMal = await service.completedEpisode(
        9001887,
        1,
        malMediaId: 1887,
        seriesTitles: const ['Lucky Star'],
      );
      final byTitle = await service.completedEpisode(
        9001888,
        1,
        seriesTitles: const ['Lucky Star'],
      );
      final wrongEpisode = await service.completedEpisode(
        9001888,
        2,
        seriesTitles: const ['Lucky Star'],
      );

      expect(byMal?.job.id, downloaded.id);
      expect(byTitle?.job.id, downloaded.id);
      expect(wrongEpisode, isNull);
    },
  );

  test('pause keeps partial data and resume continues the same job', () async {
    final transfer = _BlockingFirstTransferClient(totalBytes: 20);
    final controller = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: transfer,
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    final job = await controller.enqueue(_request());
    await transfer.firstStarted.future;
    await controller.pause(job.id);
    await _waitFor(
      () => controller.state.job(job.id)?.status == DownloadJobStatus.paused,
    );
    expect(await storage.partLength(job), greaterThan(0));

    await controller.resume(job.id);
    await _waitFor(
      () => controller.state.job(job.id)?.status == DownloadJobStatus.completed,
    );

    expect(transfer.calls, 2);
    expect(await (await storage.finalFile(job)).length(), 20);
  });

  test(
    'cancel removes partial data and delete removes the database row',
    () async {
      final transfer = _BlockingFirstTransferClient(totalBytes: 20);
      final controller = DownloadManagerController(
        repository: repository,
        storage: storage,
        transferClient: transfer,
        autoInitialize: false,
      );
      addTearDown(controller.dispose);

      final job = await controller.enqueue(_request());
      await transfer.firstStarted.future;
      await controller.cancel(job.id);

      expect(controller.state.job(job.id)?.status, DownloadJobStatus.cancelled);
      expect(controller.state.job(job.id)?.sourceUri, isNull);
      expect((await repository.job(job.id))?.sourceUri, isNull);
      expect(await storage.partLength(job), 0);
      await controller.delete(job.id);
      expect(controller.state.job(job.id), isNull);
      expect(await repository.job(job.id), isNull);
    },
  );

  test('failed transfer retries from its partial file', () async {
    final transfer = _FailOnceTransferClient(totalBytes: 18);
    final controller = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: transfer,
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    final job = await controller.enqueue(_request());
    await _waitFor(
      () => controller.state.job(job.id)?.status == DownloadJobStatus.failed,
    );
    final failedBytes = await storage.partLength(job);
    expect(failedBytes, greaterThan(0));

    await controller.retry(job.id);
    await _waitFor(
      () => controller.state.job(job.id)?.status == DownloadJobStatus.completed,
    );

    expect(controller.state.job(job.id)?.retryCount, 1);
    expect(await (await storage.finalFile(job)).length(), 18);
  });

  test('direct peer defaults to explicit unsupported state', () async {
    final controller = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: _ImmediateTransferClient(totalBytes: 8),
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    final job = await controller.enqueue(_request(direct: true));
    await _waitFor(
      () =>
          controller.state.job(job.id)?.status == DownloadJobStatus.unsupported,
    );

    expect(
      controller.state.job(job.id)?.errorCode,
      'direct_peer_worker_unavailable',
    );
  });

  test('injected direct peer worker consumes ephemeral capability', () async {
    final worker = _FakeDirectPeerWorker();
    final controller = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: _ImmediateTransferClient(totalBytes: 8),
      directPeerWorker: worker,
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    final capability = Object();
    final job = await controller.enqueue(
      _request(direct: true, capability: capability),
    );
    await _waitFor(
      () => controller.state.job(job.id)?.status == DownloadJobStatus.completed,
    );

    expect(worker.seenCapability, same(capability));
    expect(await (await storage.finalFile(job)).length(), 12);
    final persisted = await repository.job(job.id);
    expect(persisted?.sourceUri, isNull);
  });

  test('direct peer pause and resume retains its process capability', () async {
    final worker = _BlockingFirstDirectPeerWorker();
    final controller = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: _ImmediateTransferClient(totalBytes: 8),
      directPeerWorker: worker,
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    final capability = Object();
    final job = await controller.enqueue(
      _request(direct: true, capability: capability),
    );
    await worker.firstStarted.future;
    await controller.pause(job.id);
    expect(controller.state.job(job.id)?.status, DownloadJobStatus.paused);

    await controller.resume(job.id);
    await _waitFor(
      () => controller.state.job(job.id)?.status == DownloadJobStatus.completed,
    );

    expect(worker.calls, 2);
    expect(worker.seenCapabilities, everyElement(same(capability)));
  });

  test(
    'process restart recovers an active job and resumes its part file',
    () async {
      final now = DateTime.utc(2026, 8, 24);
      final persisted = DownloadJob(
        id: 'restored',
        anilistMediaId: 10,
        episode: 1,
        seriesTitle: 'Example',
        sourceLabel: 'Debrid',
        transport: DownloadTransport.https,
        status: DownloadJobStatus.downloading,
        sourceUri: Uri.parse('https://cdn.example.test/episode.mkv'),
        relativePath: '10/restored.mkv',
        expectedBytes: 14,
        receivedBytes: 0,
        queuePosition: 0,
        createdAt: now,
        updatedAt: now,
      );
      await repository.upsertJob(persisted);
      final partial = await storage.preparePartFile(persisted);
      await partial.writeAsBytes(List<int>.filled(6, 1));
      final controller = DownloadManagerController(
        repository: repository,
        storage: storage,
        transferClient: _ImmediateTransferClient(totalBytes: 14),
        autoInitialize: false,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await _waitFor(
        () =>
            controller.state.job('restored')?.status ==
            DownloadJobStatus.completed,
      );

      expect(await (await storage.finalFile(persisted)).length(), 14);
    },
  );

  test('process restart never reuses lost private request headers', () async {
    final transfer = _BlockingFirstTransferClient(totalBytes: 20);
    final first = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: transfer,
      autoInitialize: false,
    );
    final job = await first.enqueue(
      _request(requestHeaders: const {'Authorization': 'private'}),
    );
    await transfer.firstStarted.future;
    await first.pause(job.id);
    first.dispose();

    final restored = DownloadManagerController(
      repository: repository,
      storage: storage,
      transferClient: _ImmediateTransferClient(totalBytes: 20),
      autoInitialize: false,
    );
    addTearDown(restored.dispose);
    await restored.initialize();

    expect(restored.state.job(job.id)?.status, DownloadJobStatus.unsupported);
    expect(
      restored.state.job(job.id)?.errorCode,
      'source_reresolution_required',
    );
    expect(
      restored.state.job(job.id)?.errorMessage,
      isNot(contains('private')),
    );
  });

  test(
    'process restart recovers a promoted authorized file before its marker',
    () async {
      final now = DateTime.utc(2026, 8, 24);
      final persisted = DownloadJob(
        id: 'promoted-authorized',
        anilistMediaId: 10,
        episode: 1,
        seriesTitle: 'Example',
        sourceLabel: 'Private web source',
        transport: DownloadTransport.https,
        status: DownloadJobStatus.downloading,
        sourceUri: Uri.parse('https://cdn.example.test/private.mkv'),
        relativePath: '10/promoted-authorized.mkv',
        expectedBytes: 12,
        receivedBytes: 12,
        remoteTransferId: 'ephemeral-request-headers',
        queuePosition: 0,
        createdAt: now,
        updatedAt: now,
      );
      await repository.upsertJob(persisted);
      final completed = await storage.finalFile(persisted);
      await completed.parent.create(recursive: true);
      await completed.writeAsBytes(List<int>.filled(12, 1), flush: true);
      final controller = DownloadManagerController(
        repository: repository,
        storage: storage,
        transferClient: _ImmediateTransferClient(totalBytes: 12),
        autoInitialize: false,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      final recovered = controller.state.job(persisted.id);
      expect(recovered?.status, DownloadJobStatus.completed);
      expect(recovered?.sourceUri, isNull);
      expect(recovered?.remoteTransferId, isNull);
    },
  );

  test('failed restoration can be retried without losing the queue', () async {
    var attempts = 0;
    final transientRepository = DownloadRepository(
      openDatabase: () async {
        attempts++;
        if (attempts == 1) throw StateError('temporary database failure');
        return database;
      },
    );
    final controller = DownloadManagerController(
      repository: transientRepository,
      storage: storage,
      transferClient: _ImmediateTransferClient(totalBytes: 8),
      autoInitialize: false,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.state.initialized, isFalse);
    expect(controller.state.errorMessage, isNotNull);

    await controller.initialize();
    expect(controller.state.initialized, isTrue);
    expect(controller.state.errorMessage, isNull);
    expect(attempts, greaterThanOrEqualTo(2));
  });
}

OfflineDownloadRequest _request({
  bool direct = false,
  Object? capability,
  Map<String, String> requestHeaders = const {},
}) {
  return OfflineDownloadRequest(
    anilistMediaId: 10,
    episode: 1,
    seriesTitle: 'Example',
    sourceLabel: direct ? 'Direct torrent' : 'Debrid',
    transport: direct ? DownloadTransport.directPeer : DownloadTransport.https,
    sourceUri: direct
        ? null
        : Uri.parse('https://cdn.example.test/episode.mkv'),
    directPeerCapability: capability,
    requestHeaders: requestHeaders,
    fileExtension: 'mkv',
  );
}

Future<void> _waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Download state did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _ImmediateTransferClient implements DownloadTransferClient {
  _ImmediateTransferClient({required this.totalBytes});

  final int totalBytes;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  }) async {
    final existing = await partialFile.exists()
        ? await partialFile.length()
        : 0;
    await partialFile.writeAsBytes(
      List<int>.filled(totalBytes - existing, 1),
      mode: FileMode.append,
      flush: true,
    );
    onProgress(
      DownloadTransferProgress(
        receivedBytes: totalBytes,
        totalBytes: totalBytes,
        speedBytesPerSecond: 100,
      ),
    );
    return DownloadTransferResult(
      receivedBytes: totalBytes,
      totalBytes: totalBytes,
      mimeType: 'video/x-matroska',
    );
  }
}

class _RecordingKeepAlive implements OfflineDownloadKeepAlive {
  var acquires = 0;
  var releases = 0;
  var active = 0;
  var maximumActive = 0;

  @override
  Future<OfflineDownloadKeepAliveLease> acquire() async {
    acquires++;
    active++;
    if (active > maximumActive) maximumActive = active;
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
    owner.releases++;
    owner.active--;
  }
}

class _BlockingFirstTransferClient implements DownloadTransferClient {
  _BlockingFirstTransferClient({required this.totalBytes});

  final int totalBytes;
  final firstStarted = Completer<void>();
  var calls = 0;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  }) async {
    calls++;
    if (calls == 1) {
      await partialFile.writeAsBytes(List<int>.filled(5, 1), flush: true);
      onProgress(
        DownloadTransferProgress(
          receivedBytes: 5,
          totalBytes: totalBytes,
          speedBytesPerSecond: 10,
        ),
      );
      if (!firstStarted.isCompleted) firstStarted.complete();
      final cancelled = Completer<void>();
      cancellation.whenCancelled(() {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      await cancelled.future;
      throw const DownloadTransferCancelled();
    }
    return _ImmediateTransferClient(totalBytes: totalBytes).download(
      job: job,
      partialFile: partialFile,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }
}

class _FailOnceTransferClient implements DownloadTransferClient {
  _FailOnceTransferClient({required this.totalBytes});

  final int totalBytes;
  var calls = 0;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
    Map<String, String> requestHeaders = const {},
  }) async {
    calls++;
    if (calls == 1) {
      await partialFile.writeAsBytes(List<int>.filled(6, 1), flush: true);
      onProgress(
        DownloadTransferProgress(
          receivedBytes: 6,
          totalBytes: totalBytes,
          speedBytesPerSecond: 10,
        ),
      );
      throw const DownloadTransferException('network_test', 'Try again.');
    }
    return _ImmediateTransferClient(totalBytes: totalBytes).download(
      job: job,
      partialFile: partialFile,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }
}

class _FakeDirectPeerWorker implements DirectPeerDownloadWorker {
  Object? seenCapability;

  @override
  bool get isAvailable => true;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required Object capability,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
  }) async {
    seenCapability = capability;
    await partialFile.writeAsBytes(List<int>.filled(12, 1), flush: true);
    onProgress(
      const DownloadTransferProgress(
        receivedBytes: 12,
        totalBytes: 12,
        speedBytesPerSecond: 12,
      ),
    );
    return const DownloadTransferResult(receivedBytes: 12, totalBytes: 12);
  }
}

class _BlockingFirstDirectPeerWorker implements DirectPeerDownloadWorker {
  final firstStarted = Completer<void>();
  final seenCapabilities = <Object>[];
  var calls = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<DownloadTransferResult> download({
    required DownloadJob job,
    required Object capability,
    required File partialFile,
    required DownloadCancellationToken cancellation,
    required void Function(DownloadTransferProgress progress) onProgress,
  }) async {
    calls++;
    seenCapabilities.add(capability);
    if (calls == 1) {
      await partialFile.writeAsBytes(List<int>.filled(5, 1), flush: true);
      onProgress(
        const DownloadTransferProgress(
          receivedBytes: 5,
          totalBytes: 12,
          speedBytesPerSecond: 5,
        ),
      );
      firstStarted.complete();
      final cancelled = Completer<void>();
      cancellation.whenCancelled(() => cancelled.complete());
      await cancelled.future;
      throw const DownloadTransferCancelled();
    }
    final existing = await partialFile.length();
    await partialFile.writeAsBytes(
      List<int>.filled(12 - existing, 1),
      mode: FileMode.append,
      flush: true,
    );
    return const DownloadTransferResult(receivedBytes: 12, totalBytes: 12);
  }
}
