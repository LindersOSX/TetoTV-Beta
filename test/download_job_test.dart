import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download job survives SQLite serialization with progress', () {
    final now = DateTime.utc(2026, 8, 24, 12);
    final job = DownloadJob(
      id: 'download-1',
      anilistMediaId: 123,
      malMediaId: 456,
      episode: 7,
      seriesTitle: 'Example',
      episodeTitle: 'Episode title',
      sourceLabel: 'Real-Debrid 1080p',
      transport: DownloadTransport.https,
      status: DownloadJobStatus.downloading,
      sourceUri: Uri.parse('https://downloads.example.test/file.mkv'),
      providerId: 'real-debrid',
      providerName: 'Real-Debrid',
      relativePath: '123/episode-7-download-1.mkv',
      quality: '1080p',
      audioLabel: 'Dual audio',
      mimeType: 'video/x-matroska',
      expectedBytes: 1000,
      receivedBytes: 250,
      speedBytesPerSecond: 100,
      retryCount: 2,
      queuePosition: 4,
      createdAt: now,
      updatedAt: now.add(const Duration(minutes: 1)),
    );

    final restored = DownloadJob.fromDatabase(job.toDatabase());

    expect(restored.id, job.id);
    expect(restored.sourceUri, job.sourceUri);
    expect(restored.malMediaId, 456);
    expect(restored.status, DownloadJobStatus.downloading);
    expect(restored.progress, .25);
    expect(restored.partRelativePath, '${job.relativePath}.part');
  });

  test('request credentials stay ephemeral and plain HTTP is rejected', () {
    final request = OfflineDownloadRequest(
      anilistMediaId: 1,
      episode: 1,
      seriesTitle: 'Example',
      sourceLabel: 'Debrid',
      transport: DownloadTransport.https,
      sourceUri: Uri.parse('https://cdn.example.test/video'),
      requestHeaders: const {'Authorization': 'Bearer secret'},
    );

    expect(request.requestHeaders['Authorization'], 'Bearer secret');
    expect(
      () => request.requestHeaders['Cookie'] = 'secret',
      throwsUnsupportedError,
    );
    expect(
      () => OfflineDownloadRequest(
        anilistMediaId: 1,
        episode: 1,
        seriesTitle: 'Example',
        sourceLabel: 'Unsafe',
        transport: DownloadTransport.https,
        sourceUri: Uri.parse('http://cdn.example.test/video'),
      ),
      throwsArgumentError,
    );
  });

  test('state transitions reject impossible completed-to-downloading move', () {
    final now = DateTime.utc(2026, 8, 24);
    final completed = DownloadJob(
      id: 'complete',
      anilistMediaId: 1,
      episode: 1,
      seriesTitle: 'Example',
      sourceLabel: 'Downloaded',
      transport: DownloadTransport.https,
      status: DownloadJobStatus.completed,
      sourceUri: Uri.parse('https://cdn.example.test/video'),
      relativePath: '1/episode-1.mkv',
      expectedBytes: 10,
      receivedBytes: 10,
      queuePosition: 0,
      createdAt: now,
      updatedAt: now,
    );

    expect(
      () => completed.transition(DownloadJobStatus.downloading),
      throwsStateError,
    );
  });

  test('offline metadata is versioned, immutable, and round trips', () {
    final metadata = OfflineMediaMetadata(
      anilistMediaId: 42,
      malMediaId: 84,
      title: 'Offline show',
      metadata: const {
        'titles': {'english': 'Offline show'},
        'episodes': 12,
      },
      coverRelativePath: '42/artwork/cover.jpg',
      updatedAt: DateTime.utc(2026, 8, 24),
    );
    final restored = OfflineMediaMetadata.fromDatabase(metadata.toDatabase());

    expect(restored.schemaVersion, 1);
    expect(restored.metadata['episodes'], 12);
    expect(() => restored.metadata['episodes'] = 13, throwsUnsupportedError);
  });
}
