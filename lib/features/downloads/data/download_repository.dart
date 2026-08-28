import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/downloads/domain/offline_media_metadata.dart';
import 'package:sqflite/sqflite.dart';

typedef DownloadDatabaseOpener = Future<Database> Function();

/// SQLite boundary for the persistent download queue and offline catalog.
class DownloadRepository {
  DownloadRepository({DownloadDatabaseOpener? openDatabase})
    : _openDatabase = openDatabase ?? (() => TetoTvDatabase.instance.database);

  DownloadRepository.forDatabase(Database database)
    : _openDatabase = (() async => database);

  final DownloadDatabaseOpener _openDatabase;

  Future<List<DownloadJob>> listJobs({Set<DownloadJobStatus>? statuses}) async {
    final database = await _openDatabase();
    final names = statuses
        ?.map((status) => status.name)
        .toList(growable: false);
    final rows = await database.query(
      'download_jobs',
      where: names == null || names.isEmpty
          ? null
          : 'status IN (${List.filled(names.length, '?').join(',')})',
      whereArgs: names == null || names.isEmpty ? null : names,
      orderBy: 'queue_position ASC, created_at ASC, id ASC',
    );
    return rows.map(DownloadJob.fromDatabase).toList(growable: false);
  }

  Future<DownloadJob?> job(String id) async {
    final database = await _openDatabase();
    final rows = await database.query(
      'download_jobs',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : DownloadJob.fromDatabase(rows.first);
  }

  Future<DownloadJob?> completedEpisode(int mediaId, int episode) async {
    final jobs = await completedEpisodeCandidates(mediaId, episode);
    return jobs.isEmpty ? null : jobs.first;
  }

  /// Returns every persisted completion for an episode, newest first.
  ///
  /// More than one row can exist after a retry or a second download. Callers
  /// that expose playable assets must verify each row's file instead of
  /// allowing a stale newest row to hide an older valid copy.
  Future<List<DownloadJob>> completedEpisodeCandidates(
    int mediaId,
    int episode,
  ) async {
    final database = await _openDatabase();
    final rows = await database.query(
      'download_jobs',
      where: 'anilist_media_id = ? AND episode = ? AND status = ?',
      whereArgs: [mediaId, episode, DownloadJobStatus.completed.name],
      orderBy: 'updated_at DESC, created_at DESC, id DESC',
    );
    return rows.map(DownloadJob.fromDatabase).toList(growable: false);
  }

  Future<List<DownloadJob>> completedEpisodesForMedia(int mediaId) async {
    final database = await _openDatabase();
    final rows = await database.query(
      'download_jobs',
      where: 'anilist_media_id = ? AND status = ?',
      whereArgs: [mediaId, DownloadJobStatus.completed.name],
      orderBy: 'episode ASC, updated_at DESC, created_at DESC, id DESC',
    );
    return rows.map(DownloadJob.fromDatabase).toList(growable: false);
  }

  Future<void> upsertJob(DownloadJob job) async {
    final database = await _openDatabase();
    await database.insert(
      'download_jobs',
      job.toDatabase(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertJobs(Iterable<DownloadJob> jobs) async {
    final values = jobs.toList(growable: false);
    if (values.isEmpty) return;
    final database = await _openDatabase();
    await database.transaction((transaction) async {
      final batch = transaction.batch();
      for (final job in values) {
        batch.insert(
          'download_jobs',
          job.toDatabase(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Atomically replaces the single resumable season request.
  ///
  /// [planJson] is produced by the public-catalog-only season plan codec. It
  /// must never contain source URLs, magnets, headers, cookies, or tokens.
  Future<void> savePendingSeasonDownload({
    required int anilistMediaId,
    required String planJson,
    required DateTime updatedAt,
  }) async {
    if (anilistMediaId <= 0 || planJson.isEmpty || planJson.length > 1048576) {
      throw ArgumentError('The pending season plan is invalid.');
    }
    final database = await _openDatabase();
    await database.insert('pending_season_download', {
      'slot': 1,
      'anilist_media_id': anilistMediaId,
      'plan_json': planJson,
      'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> pendingSeasonDownloadJson() async {
    final database = await _openDatabase();
    final rows = await database.query(
      'pending_season_download',
      columns: const ['plan_json'],
      where: 'slot = 1',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['plan_json'] as String?;
  }

  Future<void> clearPendingSeasonDownload() async {
    final database = await _openDatabase();
    await database.delete('pending_season_download', where: 'slot = 1');
  }

  Future<int> nextQueuePosition() async {
    final database = await _openDatabase();
    final result = await database.rawQuery(
      'SELECT COALESCE(MAX(queue_position), -1) + 1 AS next_position '
      'FROM download_jobs',
    );
    return (result.single['next_position']! as num).toInt();
  }

  Future<void> deleteJob(String id) async {
    final database = await _openDatabase();
    await database.delete('download_jobs', where: 'id = ?', whereArgs: [id]);
  }

  /// Deletes a job and removes its offline metadata only when no other job for
  /// that title remains. Artwork files are returned to the caller for deletion
  /// by the storage boundary after the transaction commits.
  Future<List<String>> deleteJobAndPruneMetadata(String id) async {
    final database = await _openDatabase();
    return database.transaction((transaction) async {
      final rows = await transaction.query(
        'download_jobs',
        columns: const ['anilist_media_id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return const <String>[];
      final mediaId = (rows.first['anilist_media_id']! as num).toInt();
      await transaction.delete(
        'download_jobs',
        where: 'id = ?',
        whereArgs: [id],
      );
      final remaining = Sqflite.firstIntValue(
        await transaction.rawQuery(
          'SELECT COUNT(*) FROM download_jobs '
          'WHERE anilist_media_id = ? AND status != ?',
          [mediaId, DownloadJobStatus.cancelled.name],
        ),
      );
      if ((remaining ?? 0) > 0) return const <String>[];
      final metadataRows = await transaction.query(
        'offline_media_metadata',
        columns: const ['cover_relative_path', 'banner_relative_path'],
        where: 'anilist_media_id = ?',
        whereArgs: [mediaId],
        limit: 1,
      );
      await transaction.delete(
        'offline_episode_metadata',
        where: 'anilist_media_id = ?',
        whereArgs: [mediaId],
      );
      await transaction.delete(
        'offline_media_metadata',
        where: 'anilist_media_id = ?',
        whereArgs: [mediaId],
      );
      if (metadataRows.isEmpty) return const <String>[];
      return [
        metadataRows.first['cover_relative_path'] as String?,
        metadataRows.first['banner_relative_path'] as String?,
      ].whereType<String>().toList(growable: false);
    });
  }

  Future<void> upsertMediaMetadata(OfflineMediaMetadata metadata) async {
    final database = await _openDatabase();
    await database.insert(
      'offline_media_metadata',
      metadata.toDatabase(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<OfflineMediaMetadata?> mediaMetadata(int mediaId) async {
    final database = await _openDatabase();
    final rows = await database.query(
      'offline_media_metadata',
      where: 'anilist_media_id = ?',
      whereArgs: [mediaId],
      limit: 1,
    );
    return rows.isEmpty ? null : OfflineMediaMetadata.fromDatabase(rows.first);
  }

  Future<List<OfflineMediaMetadata>> listMediaMetadata() async {
    final database = await _openDatabase();
    final rows = await database.query(
      'offline_media_metadata',
      orderBy: 'updated_at DESC, anilist_media_id ASC',
    );
    return rows.map(OfflineMediaMetadata.fromDatabase).toList(growable: false);
  }

  Future<void> upsertEpisodeMetadata(OfflineEpisodeMetadata metadata) async {
    final database = await _openDatabase();
    await database.insert(
      'offline_episode_metadata',
      metadata.toDatabase(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<OfflineEpisodeMetadata?> episodeMetadata(
    int mediaId,
    int episode,
  ) async {
    final database = await _openDatabase();
    final rows = await database.query(
      'offline_episode_metadata',
      where: 'anilist_media_id = ? AND episode = ?',
      whereArgs: [mediaId, episode],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : OfflineEpisodeMetadata.fromDatabase(rows.first);
  }

  /// Logical bytes known by the database; UI should prefer the filesystem
  /// measurement when it is available.
  Future<int> recordedStorageBytes() async {
    final database = await _openDatabase();
    final result = await database.rawQuery('''
      SELECT COALESCE(SUM(
        CASE
          WHEN status = 'completed' THEN COALESCE(expected_bytes, received_bytes)
          ELSE received_bytes
        END
      ), 0) AS bytes
      FROM download_jobs
    ''');
    return (result.single['bytes']! as num).toInt();
  }
}
