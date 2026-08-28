import 'dart:io';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/downloads/data/download_repository.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temporary;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tetotv-download-db-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'v7 to v8 migration preserves rows and creates download tables',
    () async {
      final databasePath = '${temporary.path}${Platform.pathSeparator}test.db';
      var database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE legacy_value (id INTEGER PRIMARY KEY, value TEXT)',
            );
            await db.insert('legacy_value', {'id': 1, 'value': 'preserved'});
          },
        ),
      );
      await database.close();

      database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 8,
          onUpgrade: upgradeTetoTvDatabaseSchema,
        ),
      );

      expect(
        (await database.query('legacy_value')).single['value'],
        'preserved',
      );
      for (final table in [
        'download_jobs',
        'offline_media_metadata',
        'offline_episode_metadata',
        'pending_season_download',
      ]) {
        final rows = await database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
          [table],
        );
        expect(rows, hasLength(1), reason: table);
      }
      await database.close();
    },
  );

  test('v8 to v9 migration adds durable season continuation', () async {
    final databasePath = '${temporary.path}${Platform.pathSeparator}v9.db';
    var database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 8,
        onCreate: (db, _) => createOfflineDownloadTables(db),
      ),
    );
    // Recreate the exact released v8 shape: the shared v9 creation helper is
    // intentionally idempotent and now includes the pending-plan table.
    await database.execute('DROP TABLE pending_season_download');
    await database.insert(
      'download_jobs',
      _job(id: 'kept', queue: 0).toDatabase(),
    );
    await database.close();

    database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 9,
        onUpgrade: upgradeTetoTvDatabaseSchema,
      ),
    );

    expect(await database.query('download_jobs'), hasLength(1));
    final tables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      ['pending_season_download'],
    );
    expect(tables, hasLength(1));
    await database.close();
  });

  test(
    'repository atomically replaces and clears the pending season',
    () async {
      final database = await _openV8(temporary);
      final repository = DownloadRepository.forDatabase(database);
      await repository.savePendingSeasonDownload(
        anilistMediaId: 100,
        planJson: '{"plan":1}',
        updatedAt: DateTime.utc(2026, 8, 24),
      );
      await repository.savePendingSeasonDownload(
        anilistMediaId: 200,
        planJson: '{"plan":2}',
        updatedAt: DateTime.utc(2026, 8, 24, 1),
      );

      expect(await repository.pendingSeasonDownloadJson(), '{"plan":2}');
      expect(await database.query('pending_season_download'), hasLength(1));
      await repository.clearPendingSeasonDownload();
      expect(await repository.pendingSeasonDownloadJson(), isNull);
      await database.close();
    },
  );

  test(
    'repository persists queue, completed lookup, and storage total',
    () async {
      final database = await _openV8(temporary);
      final repository = DownloadRepository.forDatabase(database);
      final first = _job(id: 'first', queue: 1, received: 20, expected: 100);
      final completed = _job(
        id: 'complete',
        queue: 0,
        episode: 2,
        status: DownloadJobStatus.completed,
        received: 200,
        expected: 200,
      );

      await repository.upsertJobs([first, completed]);

      expect((await repository.listJobs()).map((job) => job.id), [
        'complete',
        'first',
      ]);
      expect((await repository.completedEpisode(100, 2))?.id, 'complete');
      expect(await repository.recordedStorageBytes(), 220);
      expect(await repository.nextQueuePosition(), 2);
      await database.close();
    },
  );

  test(
    'deleting the final job prunes metadata and returns artwork paths',
    () async {
      final database = await _openV8(temporary);
      final repository = DownloadRepository.forDatabase(database);
      await repository.upsertJob(_job(id: 'only', queue: 0));
      await repository.upsertMediaMetadata(
        OfflineMediaMetadata(
          anilistMediaId: 100,
          title: 'Example',
          metadata: const {'episodes': 1},
          coverRelativePath: '100/artwork/cover.jpg',
          bannerRelativePath: '100/artwork/banner.jpg',
          updatedAt: DateTime.utc(2026, 8, 24),
        ),
      );
      await repository.upsertEpisodeMetadata(
        OfflineEpisodeMetadata(
          anilistMediaId: 100,
          episode: 1,
          metadata: const {'skip': []},
          updatedAt: DateTime.utc(2026, 8, 24),
        ),
      );

      final artwork = await repository.deleteJobAndPruneMetadata('only');

      expect(
        artwork,
        containsAll(['100/artwork/cover.jpg', '100/artwork/banner.jpg']),
      );
      expect(await repository.mediaMetadata(100), isNull);
      expect(await repository.episodeMetadata(100, 1), isNull);
      await database.close();
    },
  );
}

Future<Database> _openV8(Directory temporary) async {
  final databasePath = '${temporary.path}${Platform.pathSeparator}v8.db';
  return databaseFactoryFfi.openDatabase(
    databasePath,
    options: OpenDatabaseOptions(
      version: 8,
      onCreate: (database, _) => createOfflineDownloadTables(database),
    ),
  );
}

DownloadJob _job({
  required String id,
  required int queue,
  int episode = 1,
  DownloadJobStatus status = DownloadJobStatus.downloading,
  int received = 0,
  int? expected,
}) {
  final now = DateTime.utc(2026, 8, 24);
  return DownloadJob(
    id: id,
    anilistMediaId: 100,
    episode: episode,
    seriesTitle: 'Example',
    sourceLabel: 'Debrid',
    transport: DownloadTransport.https,
    status: status,
    sourceUri: Uri.parse('https://cdn.example.test/$id.mkv'),
    relativePath: '100/$id.mkv',
    expectedBytes: expected,
    receivedBytes: received,
    queuePosition: queue,
    createdAt: now,
    updatedAt: now,
  );
}
