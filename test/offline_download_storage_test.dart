import 'dart:io';

import 'package:anime_tv/features/downloads/data/hls_offline_download_transfer_client.dart';
import 'package:anime_tv/features/downloads/data/offline_download_storage.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory temporary;
  late OfflineDownloadStorage storage;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tetotv-downloads-');
    storage = OfflineDownloadStorage(resolveRoot: () async => temporary);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('allocates stable show season episode and job paths', () {
    final request = OfflineDownloadRequest(
      anilistMediaId: 42,
      episode: 3,
      seriesTitle: 'Example',
      sourceLabel: 'Debrid',
      transport: DownloadTransport.https,
      sourceUri: Uri.parse('https://cdn.example.test/video.mp4'),
    );

    final relative = storage.allocateRelativePath(request, 'job/unsafe:value');

    expect(
      relative,
      'shows/anilist-0000000042/season-0001/'
      'episode-0003/jobunsafevalue/media.mp4',
    );
    expect(storage.allocateRelativePath(request, 'job/unsafe:value'), relative);
    expect(relative, isNot(contains('..')));
    expect(relative, isNot(contains(request.seriesTitle)));
  });

  test('keeps different jobs isolated inside one episode folder', () {
    final request = OfflineDownloadRequest(
      anilistMediaId: 123456,
      episode: 12,
      seriesTitle: 'Example',
      sourceLabel: 'Web',
      transport: DownloadTransport.https,
      sourceUri: Uri.parse('https://cdn.example.test/video.mkv'),
    );

    final first = storage.allocateRelativePath(request, 'download-one');
    final second = storage.allocateRelativePath(request, 'download-two');

    expect(
      path.dirname(first),
      'shows/anilist-0000123456/season-0001/'
      'episode-0012/download-one',
    );
    expect(path.basename(first), 'media.mkv');
    expect(first, isNot(second));
  });

  test('structured download cleanup preserves sibling episodes', () async {
    final episodeOne = _structuredJob(episode: 1, id: 'job-one');
    final episodeTwo = _structuredJob(episode: 2, id: 'job-two');
    for (final job in [episodeOne, episodeTwo]) {
      final partial = await storage.preparePartFile(job);
      await partial.writeAsBytes(List<int>.filled(8, job.episode));
      await storage.finalize(job, expectedBytes: 8);
    }

    await storage.deleteJobFiles(episodeOne);

    expect(await (await storage.finalFile(episodeOne)).exists(), isFalse);
    expect(await (await storage.finalFile(episodeTwo)).exists(), isTrue);
    expect(
      await Directory(
        path.join(
          temporary.path,
          'shows',
          'anilist-0000000042',
          'season-0001',
          'episode-0001',
        ),
      ).exists(),
      isFalse,
    );
    expect(
      await Directory(
        path.join(
          temporary.path,
          'shows',
          'anilist-0000000042',
          'season-0001',
          'episode-0002',
        ),
      ).exists(),
      isTrue,
    );
  });

  test('persisted legacy paths still finalize verify and delete', () async {
    final legacy = _job();
    final partial = await storage.preparePartFile(legacy);
    await partial.writeAsBytes(List<int>.filled(16, 7), flush: true);

    await storage.finalize(legacy, expectedBytes: 16);

    expect(await storage.completedArtifactIsValid(legacy), isTrue);
    expect(
      (await storage.finalFile(legacy)).path,
      path.join(temporary.path, '42', 'episode-3-job.mkv'),
    );
    await storage.deleteJobFiles(legacy);
    expect(await (await storage.finalFile(legacy)).exists(), isFalse);
  });

  test('rejects traversal outside app-private root', () async {
    expect(
      () => storage.resolveFile('../secret.mkv'),
      throwsA(isA<OfflineDownloadStorageException>()),
    );
    expect(
      () => storage.resolveFile('/absolute/file.mkv'),
      throwsA(isA<OfflineDownloadStorageException>()),
    );
  });

  test('validates and atomically promotes partial file', () async {
    final job = _job();
    final partial = await storage.preparePartFile(job);
    await partial.writeAsBytes(List<int>.filled(64, 7), flush: true);

    expect(
      () => storage.finalize(job, expectedBytes: 63),
      throwsA(
        isA<OfflineDownloadStorageException>().having(
          (error) => error.code,
          'code',
          'size_mismatch',
        ),
      ),
    );

    final completed = await storage.finalize(job, expectedBytes: 64);

    expect(await completed.length(), 64);
    expect(await partial.exists(), isFalse);
    expect(await storage.usedBytes(), 64);
  });

  test(
    'delete removes completed and partial files and updates usage',
    () async {
      final job = _job();
      final partial = await storage.preparePartFile(job);
      await partial.writeAsBytes(List<int>.filled(8, 1));
      await storage.finalize(job, expectedBytes: 8);
      final anotherPart = await storage.preparePartFile(job);
      await anotherPart.writeAsBytes(List<int>.filled(4, 1));
      final validator = File('${anotherPart.path}.validator');
      await validator.writeAsString('etag\n"private-validator"');

      await storage.deleteJobFiles(job);

      expect(await storage.usedBytes(), 0);
      expect(await (await storage.finalFile(job)).exists(), isFalse);
      expect(await (await storage.partFile(job)).exists(), isFalse);
      expect(await validator.exists(), isFalse);
    },
  );

  test(
    'allocates, verifies, and cleans a complete offline HLS bundle',
    () async {
      final request = OfflineDownloadRequest(
        anilistMediaId: 42,
        episode: 3,
        seriesTitle: 'Example',
        sourceLabel: 'Web',
        transport: DownloadTransport.https,
        sourceUri: Uri.parse('https://cdn.example.test/master.m3u8'),
        mimeType: 'application/vnd.apple.mpegurl',
        fileExtension: 'm3u8',
      );
      expect(
        storage.allocateRelativePath(request, 'hls-job'),
        'shows/anilist-0000000042/season-0001/'
        'episode-0003/hls-job/media.m3u8',
      );

      final job = _hlsJob();
      final partial = await storage.partFile(job);
      final segments = hlsSegmentDirectoryForPartialFile(partial);
      await segments.create(recursive: true);
      final segment = File(path.join(segments.path, 'segment-0000.ts'));
      await segment.writeAsBytes(List<int>.filled(32, 7), flush: true);
      final playlist = await storage.finalFile(job);
      await playlist.parent.create(recursive: true);
      await playlist.writeAsString(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:6\n'
        '#EXTINF:6,\n'
        '${path.basename(segments.path)}/segment-0000.ts\n'
        '#EXT-X-ENDLIST\n',
        flush: true,
      );

      expect(await storage.completedArtifactIsValid(job), isTrue);
      expect(await storage.usedBytes(), greaterThan(32));

      await segment.delete();
      expect(await storage.completedArtifactIsValid(job), isFalse);
      await segment.writeAsBytes(List<int>.filled(32, 7), flush: true);

      await storage.deleteJobFiles(job);
      expect(await playlist.exists(), isFalse);
      expect(await segments.exists(), isFalse);
      expect(await storage.usedBytes(), 0);
    },
  );

  test(
    'structurally valid HLS survives legacy transfer-byte metadata',
    () async {
      final legacy = _hlsJob().copyWith(expectedBytes: 32, receivedBytes: 32);
      final partial = await storage.partFile(legacy);
      final segments = hlsSegmentDirectoryForPartialFile(partial);
      await segments.create(recursive: true);
      await File(
        path.join(segments.path, 'segment-0000.ts'),
      ).writeAsBytes(List<int>.filled(32, 7), flush: true);
      final playlist = await storage.finalFile(legacy);
      await playlist.parent.create(recursive: true);
      await playlist.writeAsString(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:6\n'
        '#EXTINF:6,\n'
        '${path.basename(segments.path)}/segment-0000.ts\n'
        '#EXT-X-ENDLIST\n',
        flush: true,
      );

      expect(await storage.completedArtifactSize(legacy), greaterThan(32));
      expect(await storage.completedArtifactIsValid(legacy), isTrue);
    },
  );

  test('unsafe HLS bundle is isolated as invalid', () async {
    final job = _hlsJob();
    final partial = await storage.partFile(job);
    final segments = hlsSegmentDirectoryForPartialFile(partial);
    await segments.create(recursive: true);
    await Directory(path.join(segments.path, 'unexpected')).create();
    final playlist = await storage.finalFile(job);
    await playlist.parent.create(recursive: true);
    await playlist.writeAsString(
      '#EXTM3U\n'
      '#EXTINF:6,\n'
      '${path.basename(segments.path)}/unexpected\n'
      '#EXT-X-ENDLIST\n',
      flush: true,
    );

    expect(await storage.completedArtifactIsValid(job), isFalse);
  });
}

DownloadJob _job() {
  final now = DateTime.utc(2026, 8, 24);
  return DownloadJob(
    id: 'job',
    anilistMediaId: 42,
    episode: 3,
    seriesTitle: 'Example',
    sourceLabel: 'Debrid',
    transport: DownloadTransport.https,
    status: DownloadJobStatus.downloading,
    sourceUri: Uri.parse('https://cdn.example.test/video.mkv'),
    relativePath: '42/episode-3-job.mkv',
    queuePosition: 0,
    createdAt: now,
    updatedAt: now,
  );
}

DownloadJob _hlsJob() {
  final now = DateTime.utc(2026, 8, 24);
  return DownloadJob(
    id: 'hls-job',
    anilistMediaId: 42,
    episode: 3,
    seriesTitle: 'Example',
    sourceLabel: 'Web',
    transport: DownloadTransport.https,
    status: DownloadJobStatus.completed,
    sourceUri: Uri.parse('https://cdn.example.test/master.m3u8'),
    relativePath: '42/episode-3-hls-job.m3u8',
    mimeType: 'application/vnd.apple.mpegurl',
    queuePosition: 0,
    createdAt: now,
    updatedAt: now,
  );
}

DownloadJob _structuredJob({required int episode, required String id}) {
  final now = DateTime.utc(2026, 8, 24);
  final paddedEpisode = episode.toString().padLeft(4, '0');
  return DownloadJob(
    id: id,
    anilistMediaId: 42,
    episode: episode,
    seriesTitle: 'Example',
    sourceLabel: 'Debrid',
    transport: DownloadTransport.https,
    status: DownloadJobStatus.downloading,
    sourceUri: Uri.parse('https://cdn.example.test/video.mkv'),
    relativePath:
        'shows/anilist-0000000042/season-0001/'
        'episode-$paddedEpisode/$id/media.mkv',
    queuePosition: episode,
    createdAt: now,
    updatedAt: now,
  );
}
