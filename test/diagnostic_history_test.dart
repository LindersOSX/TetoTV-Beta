import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/core/diagnostics/explicit_diagnostics_reporter.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final now = DateTime.utc(2026, 8, 22, 18);

  setUpAll(sqfliteFfiInit);

  test('48-hour boundary is inclusive and older events are counted', () async {
    final database = _DiagnosticExecutor(_DiagnosticDisk());
    await persistDiagnosticEvent(
      database,
      component: 'player',
      message: 'outside',
      occurredAt: now.subtract(const Duration(hours: 48, milliseconds: 1)),
    );
    await persistDiagnosticEvent(
      database,
      component: 'player',
      message: 'boundary',
      occurredAt: now.subtract(diagnosticHistoryWindow),
    );
    await persistDiagnosticEvent(
      database,
      component: 'player',
      message: 'now',
      occurredAt: now,
    );

    final history = await loadDiagnosticEventHistory(database, now: now);
    final events = history['diagnosticEvents']! as List;
    final window = history['diagnosticWindow']! as Map;

    expect(events.map((event) => (event as Map)['message']), [
      'boundary',
      'now',
    ]);
    expect(window['hours'], 48);
    expect(window['droppedBeforeWindow'], 1);
    expect(history['diagnosticEventSchema'], diagnosticEventSchema);
  });

  test('fatal lead-up survives a simulated process restart', () async {
    final disk = _DiagnosticDisk();
    await persistDiagnosticEvent(
      _DiagnosticExecutor(disk),
      component: 'platform',
      severity: 'fatal',
      message: 'renderer stopped unexpectedly',
      context: {'frame': 'TvPlayerScreen.dispose:169'},
      occurredAt: now.subtract(const Duration(minutes: 2)),
    );

    // A new executor represents the next process opening the same SQLite file.
    final restartedProcess = _DiagnosticExecutor(disk);
    final history = await loadDiagnosticEventHistory(
      restartedProcess,
      now: now,
    );
    final event = (history['diagnosticEvents']! as List).single as Map;

    expect(event['component'], 'platform');
    expect(event['severity'], 'fatal');
    expect(event['message'], contains('renderer stopped'));
    expect(event['context'], {'frame': 'TvPlayerScreen.dispose:169'});
  });

  test('events are exported oldest first with stable tie ordering', () async {
    final database = _DiagnosticExecutor(_DiagnosticDisk());
    await persistDiagnosticEvent(
      database,
      component: 'catalog',
      message: 'third',
      occurredAt: now.subtract(const Duration(minutes: 1)),
    );
    await persistDiagnosticEvent(
      database,
      component: 'catalog',
      message: 'first',
      occurredAt: now.subtract(const Duration(minutes: 3)),
    );
    await persistDiagnosticEvent(
      database,
      component: 'catalog',
      message: 'second',
      occurredAt: now.subtract(const Duration(minutes: 2)),
    );

    final history = await loadDiagnosticEventHistory(database, now: now);
    expect(
      (history['diagnosticEvents']! as List).map(
        (event) => (event as Map)['message'],
      ),
      ['first', 'second', 'third'],
    );
  });

  test('durable ring is bounded and reports capacity truncation', () async {
    final database = _DiagnosticExecutor(_DiagnosticDisk());
    for (var index = 0; index < maximumPersistedDiagnosticEvents + 7; index++) {
      await persistDiagnosticEvent(
        database,
        component: 'provider',
        message: 'event-$index',
        occurredAt: now.subtract(
          Duration(seconds: maximumPersistedDiagnosticEvents + 7 - index),
        ),
      );
    }

    final history = await loadDiagnosticEventHistory(database, now: now);
    final events = history['diagnosticEvents']! as List;
    final window = history['diagnosticWindow']! as Map;

    expect(events, hasLength(maximumPersistedDiagnosticEvents));
    expect((events.first as Map)['message'], 'event-7');
    expect(window['capacity'], maximumPersistedDiagnosticEvents);
    expect(window['droppedForCapacity'], 7);
  });

  test('stored and exported event context strips private material', () async {
    const hash = '0123456789abcdef0123456789abcdef';
    final database = _DiagnosticExecutor(_DiagnosticDisk());
    await persistDiagnosticEvent(
      database,
      component: 'watch-together',
      severity: 'warning',
      message:
          'room_code=23456789 source=raw-source $hash '
          'https://cdn.example/video?X-Amz-Signature=secret '
          'join 23456789 //edge.example/video?X-Amz-Signature=secret '
          'Cookie: session=private-cookie',
      context: {
        'authorization': 'Basic private-auth',
        'capability': 'private-capability',
        'trackerId': 998877,
        'displayName': 'Private Viewer',
        'avatarUrl': 'https://cdn.example/avatar.png',
        'localPath': r'C:\Users\Viewer\Videos\Private.mkv',
        'magnet': 'magnet:?xt=urn:btih:$hash',
        'sourceId': 'provider-secret-source',
        'mediaBytes': [1, 2, 3, 4],
        'blob': [5, 6, 7, 8],
        'member': 'Alice',
        'episode': 'Private local title',
        'host': 'private-nas.home',
        'safe': {'attempt': 3, 'phase': 'opening'},
      },
      occurredAt: now,
    );

    final history = await loadDiagnosticEventHistory(database, now: now);
    final encoded = jsonEncode(history);
    final event = (history['diagnosticEvents']! as List).single as Map;
    final context = event['context']! as Map;

    for (final privateValue in const [
      '23456789',
      'raw-source',
      hash,
      'private-auth',
      'private-capability',
      '998877',
      'Private Viewer',
      'cdn.example',
      r'C:\Users\Viewer',
      'provider-secret-source',
      'private-cookie',
      'edge.example',
      'Alice',
      'Private local title',
      'private-nas.home',
    ]) {
      expect(encoded, isNot(contains(privateValue)), reason: privateValue);
    }
    expect(context['authorization'], '[REDACTED]');
    expect(context['mediaBytes'], '[REDACTED]');
    expect(context['blob'], isNull);
    expect(context['_redactedFieldCount'], greaterThanOrEqualTo(1));
    expect(context['member'], '[REDACTED]');
    expect(context['episode'], '[REDACTED]');
    expect(context['host'], '[REDACTED]');
    expect(context['safe'], {'attempt': 3, 'phase': 'opening'});
  });

  test('skip lookup and activation details remain useful after redaction', () {
    final sanitized =
        sanitizeDiagnosticContext({
              'status': 'markers_ready',
              'source_kind': 'web',
              'catalog_mapping_available': true,
              'embedded_marker_count': 0,
              'community_marker_count': 2,
              'community_status': 'found_nearby_runtime',
              'community_probe_count': 4,
              'duration_fallback_used': true,
              'segment_kind': 'opening',
              'automatic': true,
              'marker_start_ms': 90000,
              'marker_end_ms': 181013,
              'title': 'Private anime title',
              'url': 'https://private.example/video.m3u8',
            })!
            as Map;

    expect(sanitized['community_status'], 'found_nearby_runtime');
    expect(sanitized['community_probe_count'], 4);
    expect(sanitized['duration_fallback_used'], isTrue);
    expect(sanitized['community_marker_count'], 2);
    expect(sanitized['segment_kind'], 'opening');
    expect(sanitized['automatic'], isTrue);
    expect(sanitized['marker_start_ms'], 90000);
    expect(sanitized['marker_end_ms'], 181013);
    expect(sanitized['title'], '[REDACTED]');
    expect(sanitized['url'], '[REDACTED]');
  });

  test('local crash summaries use the same redacted 48-hour window', () {
    final summaries = [
      {
        'kind': 'native',
        'message': 'old',
        'occurred_at_ms': now
            .subtract(const Duration(hours: 49))
            .millisecondsSinceEpoch,
      },
      {
        'kind': 'native',
        'message': 'failed https://private.example/video Bearer secret',
        'stack': r'C:\Users\Viewer\Private.mkv token=private',
        'occurred_at_ms': now
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      },
    ];

    final diagnostics = attachRecentCrashSummaries(
      const {},
      summaries,
      now: now,
      sourceDroppedOutsideWindow: 4,
      sourceDroppedForCapacity: 3,
    );
    final encoded = jsonEncode(diagnostics);
    final window = diagnostics['recentCrashSummaryWindow']! as Map;

    expect(diagnostics['recentCrashSummaries'], hasLength(1));
    expect(window['hours'], 48);
    expect(window['droppedOutsideWindow'], 5);
    expect(window['droppedForCapacity'], 3);
    expect(encoded, contains('[URL]'));
    expect(encoded, isNot(contains('private.example')));
    expect(encoded, isNot(contains('Bearer secret')));
    expect(encoded, isNot(contains(r'C:\Users\Viewer')));
  });

  test(
    'real SQLite v4 to v5 migration preserves and classifies rows',
    () async {
      final directory = await Directory.systemTemp.createTemp('tetotv-db-v4-');
      final databasePath = path.join(directory.path, 'tetotv.db');
      addTearDown(() async {
        await databaseFactoryFfi.deleteDatabase(databasePath);
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });

      var database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE diagnostic_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              category TEXT NOT NULL,
              message TEXT NOT NULL,
              details_json TEXT,
              created_at INTEGER NOT NULL
            )
          ''');
            await db.insert('diagnostic_events', {
              'category': 'player-error',
              'message': 'legacy row',
              'details_json': '{"attempt":2}',
              'created_at': now.millisecondsSinceEpoch,
            });
          },
        ),
      );
      await database.close();

      database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 5,
          onUpgrade: upgradeTetoTvDatabaseSchema,
        ),
      );
      addTearDown(database.close);

      final columns = await database.rawQuery(
        'PRAGMA table_info(diagnostic_events)',
      );
      expect(columns.map((column) => column['name']), contains('severity'));
      expect(
        (await database.query('diagnostic_events')).single['severity'],
        'error',
      );
      expect(
        await database.rawQuery('SELECT * FROM diagnostic_metadata'),
        isEmpty,
      );
      final history = await loadDiagnosticEventHistory(database, now: now);
      expect(
        ((history['diagnosticEvents']! as List).single as Map)['message'],
        'legacy row',
      );
    },
  );

  test('real SQLite v5 to v6 adds provider compatibility history', () async {
    final directory = await Directory.systemTemp.createTemp('tetotv-db-v5-');
    final databasePath = path.join(directory.path, 'tetotv.db');
    addTearDown(() async {
      await databaseFactoryFfi.deleteDatabase(databasePath);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    var database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, _) async {
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
          await db.insert('provider_health', {
            'provider_id': 'fixture-provider',
            'consecutive_failures': 1,
            'total_failures': 2,
          });
        },
      ),
    );
    await database.close();

    database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onUpgrade: upgradeTetoTvDatabaseSchema,
      ),
    );
    addTearDown(database.close);

    final columns = await database.rawQuery(
      'PRAGMA table_info(provider_health)',
    );
    expect(
      columns.map((column) => column['name']),
      containsAll([
        'compatibility_tests',
        'compatibility_passes',
        'last_tested_at',
        'last_test_stage',
        'last_test_reason',
      ]),
    );
    final row = (await database.query('provider_health')).single;
    expect(row['provider_id'], 'fixture-provider');
    expect(row['compatibility_tests'], 0);
    expect(row['total_failures'], 2);
  });

  test('real SQLite v6 to v7 adds classified provider failures', () async {
    final directory = await Directory.systemTemp.createTemp('tetotv-db-v6-');
    final databasePath = path.join(directory.path, 'tetotv.db');
    addTearDown(() async {
      await databaseFactoryFfi.deleteDatabase(databasePath);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    var database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE provider_health (
              provider_id TEXT PRIMARY KEY,
              consecutive_failures INTEGER NOT NULL DEFAULT 0,
              total_failures INTEGER NOT NULL DEFAULT 0,
              last_success_at INTEGER,
              last_failure_at INTEGER,
              last_error TEXT,
              quarantined_until INTEGER,
              compatibility_tests INTEGER NOT NULL DEFAULT 0,
              compatibility_passes INTEGER NOT NULL DEFAULT 0,
              last_tested_at INTEGER,
              last_test_stage TEXT,
              last_test_reason TEXT
            )
          ''');
          await db.insert('provider_health', {
            'provider_id': 'fixture-provider',
            'consecutive_failures': 2,
            'total_failures': 3,
          });
        },
      ),
    );
    await database.close();

    database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 7,
        onUpgrade: upgradeTetoTvDatabaseSchema,
      ),
    );
    addTearDown(database.close);

    final columns = await database.rawQuery(
      'PRAGMA table_info(provider_health)',
    );
    expect(
      columns.map((column) => column['name']),
      containsAll(['last_failure_stage', 'last_failure_reason']),
    );
    final row = (await database.query('provider_health')).single;
    expect(row['provider_id'], 'fixture-provider');
    expect(row['total_failures'], 3);
  });

  test('provider failures preserve compatibility history and score', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    addTearDown(database.close);
    await database.execute('''
      CREATE TABLE provider_health (
        provider_id TEXT PRIMARY KEY,
        consecutive_failures INTEGER NOT NULL DEFAULT 0,
        total_failures INTEGER NOT NULL DEFAULT 0,
        last_success_at INTEGER,
        last_failure_at INTEGER,
        last_error TEXT,
        last_failure_stage TEXT,
        last_failure_reason TEXT,
        quarantined_until INTEGER,
        compatibility_tests INTEGER NOT NULL DEFAULT 0,
        compatibility_passes INTEGER NOT NULL DEFAULT 0,
        last_tested_at INTEGER,
        last_test_stage TEXT,
        last_test_reason TEXT
      )
    ''');
    final store = TetoTvDatabase.forTesting(database);
    final compatible = await store.recordProviderCompatibilityResult(
      'provider.example',
      passed: true,
      stage: 'stream_extraction',
      reason: 'compatible',
    );

    final failed = await store.recordProviderFailure(
      'provider.example',
      StateError('runtime failed'),
    );

    expect(failed.compatibilityTests, compatible.compatibilityTests);
    expect(failed.compatibilityPasses, compatible.compatibilityPasses);
    expect(failed.compatibilityScore, compatible.compatibilityScore! - 5);
    expect(failed.lastTestedAt, compatible.lastTestedAt);
    expect(failed.lastTestStage, 'stream_extraction');
    expect(failed.lastTestReason, 'compatible');
    expect(failed.consecutiveFailures, 1);
  });

  test('inconclusive retests preserve the last conclusive score', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    addTearDown(database.close);
    await database.execute('''
      CREATE TABLE provider_health (
        provider_id TEXT PRIMARY KEY,
        consecutive_failures INTEGER NOT NULL DEFAULT 0,
        total_failures INTEGER NOT NULL DEFAULT 0,
        last_success_at INTEGER,
        last_failure_at INTEGER,
        last_error TEXT,
        last_failure_stage TEXT,
        last_failure_reason TEXT,
        quarantined_until INTEGER,
        compatibility_tests INTEGER NOT NULL DEFAULT 0,
        compatibility_passes INTEGER NOT NULL DEFAULT 0,
        last_tested_at INTEGER,
        last_test_stage TEXT,
        last_test_reason TEXT
      )
    ''');
    final store = TetoTvDatabase.forTesting(database);

    final neverTested = await store.recordProviderCompatibilityInconclusive(
      'provider.new',
      stage: 'title_matching',
      reason: 'test_title_unavailable',
    );
    expect(neverTested.compatibilityTests, 0);
    expect(neverTested.compatibilityPasses, 0);
    expect(neverTested.compatibilityScore, isNull);
    expect(neverTested.lastTestStage, 'title_matching');
    expect(neverTested.lastTestReason, 'test_title_unavailable');

    final compatible = await store.recordProviderCompatibilityResult(
      'provider.established',
      passed: true,
      stage: 'stream_extraction',
      reason: 'compatible',
    );
    final inconclusive = await store.recordProviderCompatibilityInconclusive(
      'provider.established',
      stage: 'title_matching',
      reason: 'test_title_unavailable',
    );

    expect(inconclusive.compatibilityTests, compatible.compatibilityTests);
    expect(inconclusive.compatibilityPasses, compatible.compatibilityPasses);
    expect(inconclusive.compatibilityScore, compatible.compatibilityScore);
    expect(inconclusive.lastTestStage, compatible.lastTestStage);
    expect(inconclusive.lastTestReason, compatible.lastTestReason);
    expect(
      inconclusive.lastTestedAt!.isBefore(compatible.lastTestedAt!),
      isFalse,
    );
  });

  test(
    'real SQLite operational sections enforce exact bounds and counts',
    () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await database.execute('''
      CREATE TABLE stream_failures (
        device_key TEXT NOT NULL,
        info_hash TEXT NOT NULL,
        reason TEXT,
        failure_count INTEGER NOT NULL,
        last_failed_at INTEGER NOT NULL,
        PRIMARY KEY (device_key, info_hash)
      )
    ''');
      await database.execute('''
      CREATE TABLE performance_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        duration_us INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
      final boundary = now.subtract(diagnosticHistoryWindow);
      for (var index = 0; index < 27; index++) {
        await database.insert('stream_failures', {
          'device_key': 'example',
          'info_hash': index.toRadixString(16).padLeft(40, '0'),
          'reason': 'failure-$index',
          'failure_count': index + 10,
          'last_failed_at': index == 26
              ? boundary.millisecondsSinceEpoch
              : now.subtract(Duration(minutes: index)).millisecondsSinceEpoch,
        });
      }
      await database.insert('stream_failures', {
        'device_key': 'example',
        'info_hash': List<String>.filled(40, 'f').join(),
        'reason': 'outside',
        'failure_count': 99,
        'last_failed_at': boundary
            .subtract(const Duration(milliseconds: 1))
            .millisecondsSinceEpoch,
      });
      for (var index = 0; index < 105; index++) {
        await database.insert('performance_events', {
          'name': 'frame-$index',
          'duration_us': index,
          'created_at': index == 104
              ? boundary.millisecondsSinceEpoch
              : now.subtract(Duration(seconds: index)).millisecondsSinceEpoch,
        });
      }
      await database.insert('performance_events', {
        'name': 'future',
        'duration_us': 1,
        'created_at': now
            .add(const Duration(milliseconds: 1))
            .millisecondsSinceEpoch,
      });

      final snapshot = await loadRecentDiagnosticOperationalHistory(
        database,
        now: now,
      );
      final failures = snapshot['recentStreamFailures']! as List;
      final failureWindow = snapshot['recentStreamFailureWindow']! as Map;
      final timings = snapshot['recentFrameTimings']! as List;
      final timingWindow = snapshot['recentFrameTimingWindow']! as Map;

      expect(failures, hasLength(25));
      expect(failureWindow['retainedCount'], 25);
      expect(failureWindow['droppedForCapacity'], 2);
      expect(failures.first, contains('lifetimeFailureCount'));
      expect(failures.first, isNot(contains('failure_count')));
      expect(timings, hasLength(100));
      expect(timingWindow['retainedCount'], 100);
      expect(timingWindow['droppedForCapacity'], 5);
      expect(
        timings.whereType<Map>().where((row) => row['name'] == 'future'),
        isEmpty,
      );
    },
  );
}

class _DiagnosticDisk {
  final rows = <Map<String, Object?>>[];
  final metadata = <String, int>{};
  int nextId = 1;
}

class _DiagnosticExecutor implements DatabaseExecutor {
  _DiagnosticExecutor(this.disk);

  final _DiagnosticDisk disk;

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    expect(table, 'diagnostic_events');
    final id = disk.nextId++;
    disk.rows.add({...values, 'id': id});
    return id;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    expect(table, 'diagnostic_events');
    final before = disk.rows.length;
    if (where == 'created_at < ?') {
      final cutoff = (whereArgs!.single as num).toInt();
      disk.rows.removeWhere((row) => (row['created_at']! as int) < cutoff);
    } else if (where?.startsWith('id NOT IN') ?? false) {
      final capacity = (whereArgs!.single as num).toInt();
      final newest = [...disk.rows]
        ..sort((left, right) {
          final time = (right['created_at']! as int).compareTo(
            left['created_at']! as int,
          );
          return time != 0
              ? time
              : (right['id']! as int).compareTo(left['id']! as int);
        });
      final keep = newest.take(capacity).map((row) => row['id']).toSet();
      disk.rows.removeWhere((row) => !keep.contains(row['id']));
    } else {
      fail('Unexpected delete: $where');
    }
    return before - disk.rows.length;
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    final key = arguments![0]! as String;
    final amount = (arguments[1]! as num).toInt();
    disk.metadata.update(
      key,
      (value) => value + amount,
      ifAbsent: () => amount,
    );
    return 1;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (sql.contains('FROM diagnostic_events')) {
      final start = (arguments![0]! as num).toInt();
      final end = (arguments[1]! as num).toInt();
      final limit = (arguments[2]! as num).toInt();
      final rows =
          disk.rows.where((row) {
            final timestamp = row['created_at']! as int;
            return timestamp >= start && timestamp <= end;
          }).toList()..sort((left, right) {
            final time = (left['created_at']! as int).compareTo(
              right['created_at']! as int,
            );
            return time != 0
                ? time
                : (left['id']! as int).compareTo(right['id']! as int);
          });
      return rows.take(limit).toList(growable: false);
    }
    if (sql.contains('FROM diagnostic_metadata')) {
      return [
        for (final entry in disk.metadata.entries)
          {'key': entry.key, 'value': entry.value},
      ];
    }
    fail('Unexpected query: $sql');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
