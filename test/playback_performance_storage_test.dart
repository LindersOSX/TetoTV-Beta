import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/core/diagnostics/playback_performance_diagnostics.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/playback_performance_fixture.dart';

void main() {
  final now = DateTime.utc(2026, 9, 4, 18);
  setUpAll(sqfliteFfiInit);

  for (final oldVersion in [1, 4, 12]) {
    test('real SQLite v$oldVersion to v13 preserves existing data', () async {
      final databasePath = await _temporaryDatabasePath();
      var database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: oldVersion,
          onCreate: (db, _) async {
            await _createPlaybackHistoryFixture(db, now);
            if (oldVersion == 4) {
              await db.execute('''
                CREATE TABLE diagnostic_events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  category TEXT NOT NULL,
                  message TEXT NOT NULL,
                  details_json TEXT,
                  created_at INTEGER NOT NULL
                )
              ''');
              await db.execute('''
                CREATE TABLE provider_health (
                  provider_id TEXT PRIMARY KEY,
                  consecutive_failures INTEGER NOT NULL DEFAULT 0,
                  total_failures INTEGER NOT NULL DEFAULT 0,
                  last_success_at INTEGER,
                  last_failure_at INTEGER,
                  last_error TEXT,
                  quarantined_until INTEGER
                )
              ''');
            } else if (oldVersion > 1) {
              await upgradeTetoTvDatabaseSchema(db, 1, oldVersion);
            }
            if (oldVersion > 1) {
              await db.insert('diagnostic_events', {
                'category': 'player-error',
                'message': 'legacy diagnostic evidence',
                'details_json': '{"attempt":2}',
                'created_at': now.millisecondsSinceEpoch,
              });
              await db.insert('provider_health', {
                'provider_id': 'fixture-provider',
                'total_failures': 7,
              });
            }
          },
        ),
      );
      await database.close();
      database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: tetoTvDatabaseSchemaVersion,
          onUpgrade: upgradeTetoTvDatabaseSchema,
        ),
      );
      addTearDown(database.close);

      expect(await database.getVersion(), 13);
      final history = (await database.query('playback_history')).single;
      expect(history['title'], 'Existing local title');
      expect(history['position_ms'], 120000);
      if (oldVersion > 1) {
        final events = await database.query('diagnostic_events');
        expect(events.single['message'], 'legacy diagnostic evidence');
        expect(events.single['details_json'], '{"attempt":2}');
        expect(
          (await database.query('provider_health')).single['total_failures'],
          7,
        );
      }
      await persistPlaybackPerformanceSnapshot(
        database,
        playbackPerformanceFixture(updatedAt: now),
        now: now,
      );
      expect(
        await database.query('playback_performance_snapshots'),
        hasLength(1),
      );
      expect(await database.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'},
      ]);
    });
  }

  test('real SQLite snapshots survive close and reopen', () async {
    final databasePath = await _temporaryDatabasePath();
    var database = await databaseFactoryFfi.openDatabase(databasePath);
    await createPlaybackPerformanceTable(database);
    final snapshot = playbackPerformanceFixture(updatedAt: now);
    await persistPlaybackPerformanceSnapshot(database, snapshot, now: now);
    await database.close();

    database = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(database.close);
    final history = await loadPlaybackPerformanceHistory(database, now: now);
    expect(history['playbackPerformance'], [snapshot]);
    expect(history['playbackPerformanceSchema'], playbackPerformanceSchema);
  });

  test(
    'upserts session plus attempt and ignores delayed older writes',
    () async {
      final database = await _memoryDatabase();
      final earlier = now.subtract(const Duration(minutes: 1));
      await persistPlaybackPerformanceSnapshot(
        database,
        playbackPerformanceFixture(updatedAt: earlier),
        now: now,
      );
      final latest = playbackPerformanceFixture(
        updatedAt: now,
        sampleCount: 18,
      );
      await persistPlaybackPerformanceSnapshot(database, latest, now: now);
      await persistPlaybackPerformanceSnapshot(
        database,
        playbackPerformanceFixture(updatedAt: earlier),
        now: now,
      );
      await persistPlaybackPerformanceSnapshot(
        database,
        playbackPerformanceFixture(updatedAt: now, attempt: 2),
        now: now,
      );
      await persistPlaybackPerformanceSnapshot(
        database,
        playbackPerformanceFixture(
          updatedAt: now,
          sessionId: 'pbs-zyxwvutsrqponmlkjihgfedc',
        ),
        now: now,
      );
      final rows = await database.query('playback_performance_snapshots');
      expect(rows, hasLength(3));
      final row = rows.singleWhere(
        (row) =>
            row['session_id'] == latest['sessionId'] && row['attempt'] == 1,
      );
      expect(jsonDecode(row['snapshot_json']! as String), latest);
    },
  );

  test(
    '48-hour boundary is inclusive; expired and future rows are pruned',
    () async {
      final database = await _memoryDatabase();
      final boundary = now.subtract(diagnosticHistoryWindow);
      for (final (attempt, updated) in [
        (1, boundary.subtract(const Duration(milliseconds: 1))),
        (2, boundary),
        (3, now),
        (4, now.add(const Duration(milliseconds: 1))),
      ]) {
        await _insertRaw(
          database,
          playbackPerformanceFixture(updatedAt: updated, attempt: attempt),
        );
      }
      final history = await loadPlaybackPerformanceHistory(database, now: now);
      final snapshots = history['playbackPerformance']! as List;
      final window = history['playbackPerformanceWindow']! as Map;
      expect(snapshots.map((value) => (value as Map)['attempt']), [3, 2]);
      expect(window['droppedOutsideWindow'], 2);
      expect(window['newestRetainedAt'], now.toIso8601String());
      expect(window['oldestRetainedAt'], boundary.toIso8601String());
      expect(
        await database.query('playback_performance_snapshots'),
        hasLength(2),
      );
      final repeated = await loadPlaybackPerformanceHistory(database, now: now);
      expect(
        (repeated['playbackPerformanceWindow'] as Map)['droppedOutsideWindow'],
        2,
      );
    },
  );

  test(
    '24-attempt cap is independent of generic events and reports drops',
    () async {
      final database = await _memoryDatabase();
      await database.execute('''
      CREATE TABLE diagnostic_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        severity TEXT NOT NULL,
        message TEXT NOT NULL,
        details_json TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
      await persistDiagnosticEvent(
        database,
        component: 'player',
        message: 'startup evidence',
        occurredAt: now,
      );
      for (var attempt = 1; attempt <= 29; attempt++) {
        await persistPlaybackPerformanceSnapshot(
          database,
          playbackPerformanceFixture(updatedAt: now, attempt: attempt),
          now: now,
        );
      }
      final history = await loadPlaybackPerformanceHistory(database, now: now);
      final snapshots = history['playbackPerformance']! as List;
      final window = history['playbackPerformanceWindow']! as Map;
      expect(snapshots, hasLength(maximumPersistedPlaybackPerformanceAttempts));
      expect((snapshots.first as Map)['attempt'], 29);
      expect((snapshots.last as Map)['attempt'], 6);
      expect(window['droppedForCapacity'], 5);
      expect(
        (await database.query('diagnostic_events')).single['message'],
        'startup evidence',
      );
      final events = await loadDiagnosticEventHistory(database, now: now);
      expect((events['diagnosticWindow'] as Map)['droppedForCapacity'], 0);
    },
  );

  test(
    'sanitizes before persistence and again when loading tampered rows',
    () async {
      final database = await _memoryDatabase();
      final snapshot = playbackPerformanceFixture(updatedAt: now);
      final samples = snapshot['samples']! as List;
      (samples.last as Map<String, Object?>).addAll({
        'decoderName': 'Private Viewer decoder https://private.example',
        'authorization': 'private-token',
        'path': r'C:\Users\Private\video.mkv',
        'availableMetrics': ['private-identity'],
      });
      snapshot['sourceUrl'] = 'https://private.example/stream';
      snapshot['metadata'] = {'title': 'Private title'};
      (snapshot['summary']! as Map)['displayName'] = 'Private Viewer';
      await persistPlaybackPerformanceSnapshot(database, snapshot, now: now);
      final stored = (await database.query(
        'playback_performance_snapshots',
      )).single;
      final storedText = stored['snapshot_json']! as String;
      expect(storedText.toLowerCase(), isNot(contains('private')));
      expect(storedText, contains('mediacodec-copy'));
      expect(storedText, contains('h264'));

      // Simulate a legacy/corrupt row bypassing the normal write sanitizer.
      await _insertRaw(database, {...snapshot, 'attempt': 2});
      await _insertRaw(database, {
        ...snapshot,
        'attempt': 3,
      }, encoded: '{broken');
      await _insertRaw(database, {...snapshot, 'attempt': 4}, storedAttempt: 5);
      await _insertRaw(database, {
        ...snapshot,
        'attempt': 6,
      }, storedUpdatedAt: now.millisecondsSinceEpoch - 1);
      final history = await loadPlaybackPerformanceHistory(database, now: now);
      expect(history['playbackPerformance'], hasLength(2));
      expect(
        (history['playbackPerformanceWindow'] as Map)['invalidSnapshotCount'],
        3,
      );
      expect(jsonEncode(history).toLowerCase(), isNot(contains('private')));
      expect(
        await database.query('playback_performance_snapshots'),
        hasLength(5),
      );
    },
  );

  test(
    'invalid, expired and future input snapshots do not enter storage',
    () async {
      final database = await _memoryDatabase();
      for (final snapshot in [
        <String, Object?>{},
        {
          ...playbackPerformanceFixture(updatedAt: now),
          'sessionId': 'private-id',
        },
        playbackPerformanceFixture(
          updatedAt: now.subtract(const Duration(hours: 49)),
        ),
        playbackPerformanceFixture(
          updatedAt: now.add(const Duration(seconds: 1)),
        ),
      ]) {
        await persistPlaybackPerformanceSnapshot(database, snapshot, now: now);
      }
      expect(await database.query('playback_performance_snapshots'), isEmpty);
    },
  );

  test(
    'missing or closed SQLite is failure-safe for playback and reports',
    () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      final store = TetoTvDatabase.forTesting(database);
      final snapshot = playbackPerformanceFixture(
        updatedAt: DateTime.now().toUtc(),
      );
      await expectLater(
        store.savePlaybackPerformanceSnapshot(snapshot),
        completes,
      );
      var history = await loadPlaybackPerformanceHistory(database, now: now);
      expect(history['playbackPerformance'], isEmpty);
      expect(
        (history['playbackPerformanceWindow'] as Map)['storageUnavailable'],
        true,
      );
      await database.close();
      await expectLater(
        store.savePlaybackPerformanceSnapshot(snapshot),
        completes,
      );
      history = await loadPlaybackPerformanceHistory(database, now: now);
      expect(
        (history['playbackPerformanceWindow'] as Map)['storageUnavailable'],
        true,
      );
    },
  );

  test(
    'failed write transaction cannot partially replace the last snapshot',
    () async {
      final database = await _memoryDatabase();
      final updated = DateTime.now().toUtc().subtract(
        const Duration(seconds: 1),
      );
      final snapshot = playbackPerformanceFixture(updatedAt: updated);
      await persistPlaybackPerformanceSnapshot(database, snapshot);
      await database.execute('''
      CREATE TRIGGER refuse_performance_write
      BEFORE INSERT ON playback_performance_snapshots
      BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END
    ''');
      final store = TetoTvDatabase.forTesting(database);
      await expectLater(
        store.savePlaybackPerformanceSnapshot(
          playbackPerformanceFixture(
            updatedAt: DateTime.now().toUtc(),
            sampleCount: 20,
          ),
        ),
        completes,
      );
      final row = (await database.query(
        'playback_performance_snapshots',
      )).single;
      expect(jsonDecode(row['snapshot_json']! as String), snapshot);
    },
  );

  test(
    'prune failure rolls back a replacement already written in the transaction',
    () async {
      final database = await _memoryDatabase();
      final now = DateTime.now().toUtc();
      final previous = playbackPerformanceFixture(
        updatedAt: now.subtract(const Duration(minutes: 1)),
      );
      await persistPlaybackPerformanceSnapshot(database, previous, now: now);
      await _insertRaw(
        database,
        playbackPerformanceFixture(
          updatedAt: now.subtract(const Duration(hours: 49)),
          attempt: 2,
        ),
      );
      await database.execute('''
      CREATE TRIGGER refuse_performance_prune
      BEFORE DELETE ON playback_performance_snapshots
      WHEN OLD.attempt = 2
      BEGIN SELECT RAISE(ABORT, 'fixture prune failure'); END
    ''');
      await expectLater(
        TetoTvDatabase.forTesting(database).savePlaybackPerformanceSnapshot(
          playbackPerformanceFixture(updatedAt: now, sampleCount: 24),
        ),
        completes,
      );
      final rows = await database.query('playback_performance_snapshots');
      expect(rows, hasLength(2));
      final row = rows.singleWhere((row) => row['attempt'] == 1);
      expect(jsonDecode(row['snapshot_json']! as String), previous);
    },
  );
}

Future<Database> _memoryDatabase() async {
  final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  addTearDown(database.close);
  await createPlaybackPerformanceTable(database);
  return database;
}

Future<String> _temporaryDatabasePath() async {
  final directory = await Directory.systemTemp.createTemp(
    'tetotv-performance-test-',
  );
  final databasePath = path.join(directory.path, 'tetotv.db');
  addTearDown(() async {
    await databaseFactoryFfi.deleteDatabase(databasePath);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return databasePath;
}

Future<void> _insertRaw(
  Database database,
  Map<String, Object?> snapshot, {
  String? encoded,
  int? storedAttempt,
  int? storedUpdatedAt,
}) async {
  await database.insert('playback_performance_snapshots', {
    'session_id': snapshot['sessionId'],
    'attempt': storedAttempt ?? snapshot['attempt'],
    'updated_at':
        storedUpdatedAt ??
        DateTime.parse(snapshot['updatedAt']! as String).millisecondsSinceEpoch,
    'snapshot_json': encoded ?? jsonEncode(snapshot),
  });
}

Future<void> _createPlaybackHistoryFixture(Database db, DateTime now) async {
  await db.execute('''
    CREATE TABLE playback_history (
      anilist_media_id INTEGER NOT NULL,
      mal_media_id INTEGER,
      episode INTEGER NOT NULL,
      title TEXT NOT NULL,
      cover_image_url TEXT,
      position_ms INTEGER NOT NULL,
      duration_ms INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      completed INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (anilist_media_id, episode)
    )
  ''');
  await db.insert('playback_history', {
    'anilist_media_id': 123,
    'episode': 2,
    'title': 'Existing local title',
    'position_ms': 120000,
    'duration_ms': 1440000,
    'updated_at': now.millisecondsSinceEpoch,
  });
}
