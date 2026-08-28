import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  test('configures WAL with a query before enabling foreign keys', () async {
    final database = _RecordingDatabase();

    await configureTetoTvDatabase(database);

    expect(database.calls, [
      'query:PRAGMA journal_mode=WAL',
      'execute:PRAGMA foreign_keys=ON',
    ]);
  });

  test('series playback and stream preferences survive JSON storage', () {
    const preferences = SeriesPlaybackPreferences(
      audioLanguage: 'jpn',
      audioPreferenceSet: true,
      subtitleLanguage: 'eng',
      subtitleEnabled: true,
      subtitlePreferenceSet: true,
      subtitleSize: 42,
      autoplayNextEpisode: true,
      skipFillerEpisodes: true,
      preferredStreamLanguage: 'sub',
      preferredQuality: 'p1080',
      preferredCodec: 'hevc',
      preferredHdrMode: 'sdr',
      allowBatchStreams: false,
      streamSortMode: 'seeders',
      preferredReleaseProvider: 'User source',
      preferredReleaseGroup: 'subsplease',
    );

    final restored = SeriesPlaybackPreferences.fromJson(preferences.toJson());

    expect(restored.audioLanguage, 'jpn');
    expect(restored.audioPreferenceSet, isTrue);
    expect(restored.subtitlePreferenceSet, isTrue);
    expect(restored.subtitleSize, 42);
    expect(restored.skipFillerEpisodes, isTrue);
    expect(restored.preferredStreamLanguage, 'sub');
    expect(restored.preferredQuality, 'p1080');
    expect(restored.preferredCodec, 'hevc');
    expect(restored.preferredHdrMode, 'sdr');
    expect(restored.allowBatchStreams, isFalse);
    expect(restored.streamSortMode, 'seeders');
    expect(restored.preferredReleaseProvider, 'User source');
    expect(restored.preferredReleaseGroup, 'subsplease');
  });

  test('skip filler remains off for existing per-series preferences', () {
    final restored = SeriesPlaybackPreferences.fromJson(const {
      'audioLanguage': 'jpn',
    });

    expect(restored.skipFillerEpisodes, isFalse);
    expect(const SeriesPlaybackPreferences().skipFillerEpisodes, isFalse);
  });

  test('skip filler preference is isolated in each series value', () {
    const firstSeries = SeriesPlaybackPreferences();
    const secondSeries = SeriesPlaybackPreferences();

    final updatedFirst = firstSeries.copyWith(skipFillerEpisodes: true);

    expect(updatedFirst.skipFillerEpisodes, isTrue);
    expect(secondSeries.skipFillerEpisodes, isFalse);
  });

  test('provider compatibility health exposes score and five-stage result', () {
    final testedAt = DateTime.utc(2026, 8, 23, 18, 30);
    final healthy = ProviderHealth.fromMap({
      'provider_id': 'provider.example',
      'consecutive_failures': 0,
      'total_failures': 2,
      'compatibility_tests': 4,
      'compatibility_passes': 3,
      'last_tested_at': testedAt.millisecondsSinceEpoch,
      'last_test_stage': 'stream_extraction',
      'last_test_reason': 'compatible',
    });
    final extractionFailure = ProviderHealth.fromMap({
      'provider_id': 'provider.broken',
      'consecutive_failures': 1,
      'total_failures': 1,
      'compatibility_tests': 1,
      'compatibility_passes': 0,
      'last_tested_at': testedAt.millisecondsSinceEpoch,
      'last_test_stage': 'stream_extraction',
      'last_test_reason': 'empty_sources',
    });

    expect(
      healthy.lastTestedAt?.millisecondsSinceEpoch,
      testedAt.millisecondsSinceEpoch,
    );
    expect(healthy.compatibilityScore, 93);
    expect(extractionFailure.compatibilityScore, 65);
    expect(
      const ProviderHealth(providerId: 'untested').compatibilityScore,
      isNull,
    );
  });

  test('provider circuit breaker separates misses from transient failures', () {
    for (final reason in [
      'empty_result',
      'empty_sources',
      'runtime_api',
      'unsafe_target',
      'http_404',
    ]) {
      final policy = providerFailureCircuitPolicy(
        stage: 'episode_lookup',
        reason: reason,
        consecutiveFailures: 20,
      );
      expect(policy.quarantineAfter, isNull, reason: reason);
      expect(policy.quarantineFor, isNull, reason: reason);
    }

    final expectedMinutes = {5: 5, 6: 10, 7: 20, 8: 30, 12: 30};
    for (final MapEntry(key: failures, value: minutes)
        in expectedMinutes.entries) {
      final policy = providerFailureCircuitPolicy(
        stage: 'server_lookup',
        reason: 'timeout',
        consecutiveFailures: failures,
      );
      expect(policy.quarantineAfter, 5);
      expect(policy.quarantineFor, Duration(minutes: minutes));
    }

    final malformedBeforeThreshold = providerFailureCircuitPolicy(
      stage: 'stream_extraction',
      reason: 'invalid_response',
      consecutiveFailures: 4,
    );
    expect(malformedBeforeThreshold.quarantineAfter, 5);
  });

  test('legacy player profiles always resolve to the MPV-only contract', () {
    for (final legacyEngine in ['automatic', 'media3', 'vlc', 'mpv']) {
      final profile = DevicePlaybackProfile.fromMap({
        'device_key': 'living-room-tv',
        'preferred_engine': legacyEngine,
        'mpv_failures': 2,
      });

      expect(profile.preferredEngine, 'mpv', reason: legacyEngine);
      expect(profile.mpvFailures, 2);
    }
  });

  test(
    'checkpoint transaction restores a dismissed title atomically',
    () async {
      final database = _CheckpointExecutor();
      final checkpoint = PlaybackCheckpoint(
        anilistMediaId: 42,
        malMediaId: 84,
        episode: 3,
        title: 'Test Show',
        coverImageUrl: 'https://example.test/poster.jpg',
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 24),
        updatedAt: DateTime.utc(2026, 8, 2),
        completed: false,
      );

      await saveCheckpointTransaction(database, checkpoint);

      expect(database.calls, [
        'query:playback_history:42:3',
        'delete:continue_watching_dismissals:42',
        'insert:playback_history',
      ]);
      expect(database.inserted?['anilist_media_id'], 42);
      expect(database.inserted?['episode'], 3);
      expect(database.conflictAlgorithm, ConflictAlgorithm.replace);
    },
  );

  test(
    'an older checkpoint cannot overwrite the final Exit position',
    () async {
      final newer = DateTime.utc(2026, 8, 12, 20);
      final database = _CheckpointExecutor(
        existingUpdatedAt: newer.millisecondsSinceEpoch,
      );
      final stale = PlaybackCheckpoint(
        anilistMediaId: 42,
        episode: 3,
        title: 'Test Show',
        position: const Duration(minutes: 8),
        duration: const Duration(minutes: 24),
        updatedAt: newer.subtract(const Duration(seconds: 1)),
        completed: false,
      );

      await saveCheckpointTransaction(database, stale);

      expect(database.calls, ['query:playback_history:42:3']);
      expect(database.inserted, isNull);
    },
  );

  test('diagnostic text redacts URLs, tokens, magnets, and info hashes', () {
    final redacted = redactDiagnosticValue(
      'Bearer secret https://cdn.example/video magnet:?xt=urn:btih:abc '
      '0123456789abcdef0123456789abcdef01234567 '
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef '
      'github_'
      'pat_exampleExampleExample123456 '
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature '
      '{"access_token":"oauth-secret","client_secret":"client-secret"} '
      'http://legacy.example/video',
    );
    expect(redacted, isNot(contains('secret')));
    expect(redacted, isNot(contains('cdn.example')));
    expect(redacted, isNot(contains('legacy.example')));
    expect(redacted, isNot(contains('github_pat_')));
    expect(redacted, isNot(contains('eyJhbGci')));
    expect(redacted, contains('[MAGNET]'));
    expect('[INFO_HASH]'.allMatches(redacted), hasLength(2));
  });

  test(
    'download queue diagnostics omit media identity and private locations',
    () {
      final snapshot = buildDownloadQueueDiagnostics([
        {
          'status': 'failed',
          'transport': 'https',
          'error_code': 'provider_rate_limited',
          'received_bytes': 1572864,
          'expected_bytes': 4194304,
          'updated_at': DateTime.utc(2026, 8, 24).millisecondsSinceEpoch,
          'series_title': 'Private title',
          'source_uri': 'https://private.example/video',
          'relative_path': '/private/show/video.mkv',
        },
      ]);

      expect(snapshot['statusCounts'], {'failed': 1});
      final recent = (snapshot['recent']! as List).single as Map;
      expect(recent['receivedMiB'], 2);
      expect(recent['expectedMiB'], 4);
      final encoded = snapshot.toString();
      expect(encoded, isNot(contains('Private title')));
      expect(encoded, isNot(contains('private.example')));
      expect(encoded, isNot(contains('video.mkv')));
    },
  );

  test('download diagnostics exclude rows beyond the snapshot time', () async {
    final database = _DiagnosticsDatabase();
    final snapshotEnd = DateTime.utc(2026, 8, 24, 18, 30);

    await TetoTvDatabase.forTesting(
      database,
    ).diagnosticsSnapshot(now: snapshotEnd);

    final downloadQuery = database.queries.singleWhere(
      (query) => query.sql.contains('FROM download_jobs'),
    );
    expect(
      downloadQuery.sql,
      contains('WHERE updated_at >= ? AND updated_at <= ?'),
    );
    expect(downloadQuery.arguments, [
      snapshotEnd.subtract(diagnosticHistoryWindow).millisecondsSinceEpoch,
      snapshotEnd.millisecondsSinceEpoch,
    ]);
  });

  test('diagnostic text redacts scheme-less and JSON-escaped URLs only', () {
    final redacted = redactDiagnosticValue(
      'fetch cdn.private.example:8443/user/alice/video.m3u8 '
      r'{"url":"https:\/\/edge.private.example\/signed\/video.m3u8"} '
      'keep libmpv.so version 1.2.3 dev.animetv.Player',
      maximum: 1000,
    );

    expect('[URL]'.allMatches(redacted), hasLength(2));
    expect(redacted, isNot(contains('cdn.private.example')));
    expect(redacted, isNot(contains('edge.private.example')));
    expect(redacted, contains('libmpv.so'));
    expect(redacted, contains('version 1.2.3'));
    expect(redacted, contains('dev.animetv.Player'));
  });

  test('diagnostic text redacts private URIs and absolute local paths', () {
    final redacted = redactDiagnosticValue(
      'content://com.android.providers.media.documents/document/'
      'video%3Aprivate-show.mkv\n'
      'file:///storage/emulated/0/Private%20Episode.mkv\n'
      'teto+private:document-id-episode-42\n'
      '/storage/emulated/0/Private Show Episode 7.mkv\n'
      r'C:\Users\Viewer\Videos\Private Episode 8.mkv'
      '\n'
      'at dev.animetv.anime_tv.player.TvPlayerScreen.dispose'
      '(tv_player_screen.dart:169)',
      maximum: 1000,
    );

    expect(redacted, contains('[URI]'));
    expect(redacted, contains('[PATH]'));
    expect(redacted, isNot(contains('private-show')));
    expect(redacted, isNot(contains('document-id-episode-42')));
    expect(redacted, isNot(contains('Private Show Episode 7.mkv')));
    expect(redacted, isNot(contains('Private Episode 8.mkv')));
    expect(
      redacted,
      contains(
        'dev.animetv.anime_tv.player.TvPlayerScreen.dispose'
        '(tv_player_screen.dart:169)',
      ),
    );
  });

  test('diagnostic text redacts email and IPv4/IPv6 network identity', () {
    final redacted = redactDiagnosticValue(
      'peers 2001:db8:85a3::8a2e:370:7334 and [::ffff:192.0.2.128]. '
      'Reporter user@example.com connected through 192.168.1.20. '
      'Keep timestamp 12:34:56 for troubleshooting.',
    );

    expect(redacted, isNot(contains('2001:db8:85a3::8a2e:370:7334')));
    expect(redacted, isNot(contains('::ffff:192.0.2.128')));
    expect(redacted, isNot(contains('user@example.com')));
    expect(redacted, isNot(contains('192.168.1.20')));
    expect('[NETWORK ADDRESS]'.allMatches(redacted), hasLength(3));
    expect(redacted, contains('[EMAIL]'));
    expect(redacted, contains('12:34:56'));
  });
}

class _RecordingDatabase implements Database {
  final calls = <String>[];

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    calls.add('query:$sql');
    return const [
      <String, Object?>{'journal_mode': 'wal'},
    ];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    calls.add('execute:$sql');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CheckpointExecutor implements DatabaseExecutor {
  _CheckpointExecutor({this.existingUpdatedAt});

  final int? existingUpdatedAt;
  final calls = <String>[];
  Map<String, Object?>? inserted;
  ConflictAlgorithm? conflictAlgorithm;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    calls.add('query:$table:${whereArgs?[0]}:${whereArgs?[1]}');
    return existingUpdatedAt == null
        ? const []
        : [
            <String, Object?>{'updated_at': existingUpdatedAt},
          ];
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    calls.add('delete:$table:${whereArgs?.single}');
    return 1;
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    calls.add('insert:$table');
    inserted = values;
    this.conflictAlgorithm = conflictAlgorithm;
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DiagnosticsQuery {
  const _DiagnosticsQuery(this.sql, this.arguments);

  final String sql;
  final List<Object?>? arguments;
}

class _DiagnosticsDatabase implements Database {
  final queries = <_DiagnosticsQuery>[];

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async => 0;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    queries.add(_DiagnosticsQuery(sql, arguments));
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
