import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

/// Explicit diagnostic exports retain only this rolling, on-device window.
/// The SQLite table survives process death; it is never uploaded unless the
/// user presses the diagnostic-report share button.
const diagnosticHistoryWindow = Duration(hours: 48);
const maximumPersistedDiagnosticEvents = 240;
const diagnosticEventSchema = 'tetotv-diagnostic-events-v3';

const _diagnosticDroppedAgeKey = 'dropped_age';
const _diagnosticDroppedCapacityKey = 'dropped_capacity';

Future<void> configureTetoTvDatabase(Database db) async {
  // journal_mode returns a result row on Android, so sqflite requires
  // rawQuery rather than execute.
  await db.rawQuery('PRAGMA journal_mode=WAL');
  await db.execute('PRAGMA foreign_keys=ON');
}

class PlaybackCheckpoint {
  const PlaybackCheckpoint({
    required this.anilistMediaId,
    required this.episode,
    required this.title,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.malMediaId,
    this.coverImageUrl,
    this.completed = false,
  });

  final int anilistMediaId;
  final int? malMediaId;
  final int episode;
  final String title;
  final String? coverImageUrl;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final bool completed;

  double get progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);

  Map<String, Object?> toMap() => {
    'anilist_media_id': anilistMediaId,
    'mal_media_id': malMediaId,
    'episode': episode,
    'title': title,
    'cover_image_url': coverImageUrl,
    'position_ms': position.inMilliseconds,
    'duration_ms': duration.inMilliseconds,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'completed': completed ? 1 : 0,
  };

  factory PlaybackCheckpoint.fromMap(Map<String, Object?> value) =>
      PlaybackCheckpoint(
        anilistMediaId: value['anilist_media_id']! as int,
        malMediaId: value['mal_media_id'] as int?,
        episode: value['episode']! as int,
        title: value['title']! as String,
        coverImageUrl: value['cover_image_url'] as String?,
        position: Duration(milliseconds: value['position_ms']! as int),
        duration: Duration(milliseconds: value['duration_ms']! as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          value['updated_at']! as int,
        ),
        completed: value['completed'] == 1,
      );
}

class SeriesPlaybackPreferences {
  const SeriesPlaybackPreferences({
    this.audioLanguage = 'eng',
    this.audioPreferenceSet = false,
    this.subtitleLanguage = 'eng',
    this.subtitleEnabled = true,
    this.subtitlePreferenceSet = false,
    this.subtitleSize = 34,
    this.subtitlePosition = 100,
    this.subtitleDelayMs = 0,
    this.audioDelayMs = 0,
    this.decoder = 'hardware-safe',
    this.videoFit = 'contain',
    this.highContrastSubtitles = false,
    this.autoplayNextEpisode = true,
    this.skipFillerEpisodes = false,
    this.preferredStreamLanguage = 'dub',
    this.preferredQuality = 'any',
    this.preferredCodec = 'any',
    this.preferredHdrMode = 'any',
    this.allowBatchStreams = true,
    this.streamSortMode = 'compatibility',
    this.preferredReleaseProvider,
    this.preferredReleaseGroup,
  });

  final String audioLanguage;
  final bool audioPreferenceSet;
  final String subtitleLanguage;
  final bool subtitleEnabled;
  final bool subtitlePreferenceSet;
  final double subtitleSize;
  final int subtitlePosition;
  final int subtitleDelayMs;
  final int audioDelayMs;
  final String decoder;
  final String videoFit;
  final bool highContrastSubtitles;
  final bool autoplayNextEpisode;
  final bool skipFillerEpisodes;
  final String preferredStreamLanguage;
  final String preferredQuality;
  final String preferredCodec;
  final String preferredHdrMode;
  final bool allowBatchStreams;
  final String streamSortMode;
  final String? preferredReleaseProvider;
  final String? preferredReleaseGroup;

  SeriesPlaybackPreferences copyWith({
    String? audioLanguage,
    bool? audioPreferenceSet,
    String? subtitleLanguage,
    bool? subtitleEnabled,
    bool? subtitlePreferenceSet,
    double? subtitleSize,
    int? subtitlePosition,
    int? subtitleDelayMs,
    int? audioDelayMs,
    String? decoder,
    String? videoFit,
    bool? highContrastSubtitles,
    bool? autoplayNextEpisode,
    bool? skipFillerEpisodes,
    String? preferredStreamLanguage,
    String? preferredQuality,
    String? preferredCodec,
    String? preferredHdrMode,
    bool? allowBatchStreams,
    String? streamSortMode,
    String? preferredReleaseProvider,
    bool clearPreferredReleaseProvider = false,
    String? preferredReleaseGroup,
    bool clearPreferredReleaseGroup = false,
  }) => SeriesPlaybackPreferences(
    audioLanguage: audioLanguage ?? this.audioLanguage,
    audioPreferenceSet: audioPreferenceSet ?? this.audioPreferenceSet,
    subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
    subtitleEnabled: subtitleEnabled ?? this.subtitleEnabled,
    subtitlePreferenceSet: subtitlePreferenceSet ?? this.subtitlePreferenceSet,
    subtitleSize: subtitleSize ?? this.subtitleSize,
    subtitlePosition: subtitlePosition ?? this.subtitlePosition,
    subtitleDelayMs: subtitleDelayMs ?? this.subtitleDelayMs,
    audioDelayMs: audioDelayMs ?? this.audioDelayMs,
    decoder: decoder ?? this.decoder,
    videoFit: videoFit ?? this.videoFit,
    highContrastSubtitles: highContrastSubtitles ?? this.highContrastSubtitles,
    autoplayNextEpisode: autoplayNextEpisode ?? this.autoplayNextEpisode,
    skipFillerEpisodes: skipFillerEpisodes ?? this.skipFillerEpisodes,
    preferredStreamLanguage:
        preferredStreamLanguage ?? this.preferredStreamLanguage,
    preferredQuality: preferredQuality ?? this.preferredQuality,
    preferredCodec: preferredCodec ?? this.preferredCodec,
    preferredHdrMode: preferredHdrMode ?? this.preferredHdrMode,
    allowBatchStreams: allowBatchStreams ?? this.allowBatchStreams,
    streamSortMode: streamSortMode ?? this.streamSortMode,
    preferredReleaseProvider: clearPreferredReleaseProvider
        ? null
        : preferredReleaseProvider ?? this.preferredReleaseProvider,
    preferredReleaseGroup: clearPreferredReleaseGroup
        ? null
        : preferredReleaseGroup ?? this.preferredReleaseGroup,
  );

  Map<String, Object?> toJson() => {
    'audioLanguage': audioLanguage,
    'audioPreferenceSet': audioPreferenceSet,
    'subtitleLanguage': subtitleLanguage,
    'subtitleEnabled': subtitleEnabled,
    'subtitlePreferenceSet': subtitlePreferenceSet,
    'subtitleSize': subtitleSize,
    'subtitlePosition': subtitlePosition,
    'subtitleDelayMs': subtitleDelayMs,
    'audioDelayMs': audioDelayMs,
    'decoder': decoder,
    'videoFit': videoFit,
    'highContrastSubtitles': highContrastSubtitles,
    'autoplayNextEpisode': autoplayNextEpisode,
    'skipFillerEpisodes': skipFillerEpisodes,
    'preferredStreamLanguage': preferredStreamLanguage,
    'preferredQuality': preferredQuality,
    'preferredCodec': preferredCodec,
    'preferredHdrMode': preferredHdrMode,
    'allowBatchStreams': allowBatchStreams,
    'streamSortMode': streamSortMode,
    'preferredReleaseProvider': preferredReleaseProvider,
    'preferredReleaseGroup': preferredReleaseGroup,
  };

  factory SeriesPlaybackPreferences.fromJson(Map<String, dynamic> json) =>
      SeriesPlaybackPreferences(
        audioLanguage: json['audioLanguage'] as String? ?? 'eng',
        audioPreferenceSet: json['audioPreferenceSet'] as bool? ?? false,
        subtitleLanguage: json['subtitleLanguage'] as String? ?? 'eng',
        subtitleEnabled: json['subtitleEnabled'] as bool? ?? true,
        subtitlePreferenceSet: json['subtitlePreferenceSet'] as bool? ?? false,
        subtitleSize: (json['subtitleSize'] as num?)?.toDouble() ?? 34,
        subtitlePosition: json['subtitlePosition'] as int? ?? 100,
        subtitleDelayMs: json['subtitleDelayMs'] as int? ?? 0,
        audioDelayMs: json['audioDelayMs'] as int? ?? 0,
        decoder: json['decoder'] as String? ?? 'hardware-safe',
        videoFit: json['videoFit'] as String? ?? 'contain',
        highContrastSubtitles: json['highContrastSubtitles'] as bool? ?? false,
        autoplayNextEpisode: json['autoplayNextEpisode'] as bool? ?? true,
        skipFillerEpisodes: json['skipFillerEpisodes'] as bool? ?? false,
        preferredStreamLanguage:
            json['preferredStreamLanguage'] as String? ?? 'dub',
        preferredQuality: json['preferredQuality'] as String? ?? 'any',
        preferredCodec: json['preferredCodec'] as String? ?? 'any',
        preferredHdrMode: json['preferredHdrMode'] as String? ?? 'any',
        allowBatchStreams: json['allowBatchStreams'] as bool? ?? true,
        streamSortMode: json['streamSortMode'] as String? ?? 'compatibility',
        preferredReleaseProvider: json['preferredReleaseProvider'] as String?,
        preferredReleaseGroup: json['preferredReleaseGroup'] as String?,
      );
}

class ProviderHealth {
  const ProviderHealth({
    required this.providerId,
    this.consecutiveFailures = 0,
    this.totalFailures = 0,
    this.lastSuccessAt,
    this.lastFailureAt,
    this.lastError,
    this.lastFailureStage,
    this.lastFailureReason,
    this.quarantinedUntil,
    this.compatibilityTests = 0,
    this.compatibilityPasses = 0,
    this.lastTestedAt,
    this.lastTestStage,
    this.lastTestReason,
  });

  final String providerId;
  final int consecutiveFailures;
  final int totalFailures;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final String? lastError;
  final String? lastFailureStage;
  final String? lastFailureReason;
  final DateTime? quarantinedUntil;
  final int compatibilityTests;
  final int compatibilityPasses;
  final DateTime? lastTestedAt;
  final String? lastTestStage;
  final String? lastTestReason;

  bool get isQuarantined => quarantinedUntil?.isAfter(DateTime.now()) ?? false;

  /// A bounded compatibility score that combines the latest end-to-end test
  /// depth with repeated real-playback failures. A missing score means the
  /// provider has not been compatibility-tested yet.
  int? get compatibilityScore {
    if (lastTestedAt == null || compatibilityTests <= 0) return null;
    final latestPassed =
        lastTestStage == 'stream_extraction' && lastTestReason == 'compatible';
    final passRate = compatibilityPasses / compatibilityTests;
    var score = latestPassed
        ? 70 + (passRate * 30).round()
        : switch (lastTestStage) {
            'search' => 10,
            'title_matching' => 25,
            'episode_lookup' => 40,
            'server_lookup' => 55,
            'stream_extraction' => 70,
            _ => 5,
          };
    score -= consecutiveFailures.clamp(0, 6) * 5;
    if (isQuarantined && score > 20) score = 20;
    return score.clamp(0, 100);
  }

  factory ProviderHealth.fromMap(Map<String, Object?> row) => ProviderHealth(
    providerId: row['provider_id']! as String,
    consecutiveFailures: row['consecutive_failures']! as int,
    totalFailures: row['total_failures']! as int,
    lastSuccessAt: _dateFromMilliseconds(row['last_success_at']),
    lastFailureAt: _dateFromMilliseconds(row['last_failure_at']),
    lastError: row['last_error'] as String?,
    lastFailureStage: row['last_failure_stage'] as String?,
    lastFailureReason: row['last_failure_reason'] as String?,
    quarantinedUntil: _dateFromMilliseconds(row['quarantined_until']),
    compatibilityTests: (row['compatibility_tests'] as num?)?.toInt() ?? 0,
    compatibilityPasses: (row['compatibility_passes'] as num?)?.toInt() ?? 0,
    lastTestedAt: _dateFromMilliseconds(row['last_tested_at']),
    lastTestStage: row['last_test_stage'] as String?,
    lastTestReason: row['last_test_reason'] as String?,
  );
}

class DevicePlaybackProfile {
  const DevicePlaybackProfile({
    required this.deviceKey,
    this.preferredEngine = 'mpv',
    this.mpvFailures = 0,
  });

  final String deviceKey;
  final String preferredEngine;
  final int mpvFailures;

  factory DevicePlaybackProfile.fromMap(Map<String, Object?> row) =>
      DevicePlaybackProfile(
        deviceKey: row['device_key']! as String,
        // Older databases may contain automatic, Media3, or VLC. MPV is now
        // the sole playback engine, so those values migrate on read.
        preferredEngine: 'mpv',
        mpvFailures: row['mpv_failures']! as int,
      );
}

DateTime? _dateFromMilliseconds(Object? value) =>
    value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;

String _providerCompatibilityStage(String value) => switch (value) {
  'search' ||
  'title_matching' ||
  'episode_lookup' ||
  'server_lookup' ||
  'stream_extraction' => value,
  _ => 'search',
};

class ProviderFailureCircuitPolicy {
  const ProviderFailureCircuitPolicy({
    required this.quarantineAfter,
    required this.quarantineFor,
  });

  /// Null means the failure remains visible and testable but never opens the
  /// transient circuit breaker. Title-specific empty results and permanent
  /// runtime/security incompatibilities use that path for different reasons:
  /// the former must not damage global health, while the latter is surfaced as
  /// incompatible until the add-on is updated or manually reset.
  final int? quarantineAfter;
  final Duration? quarantineFor;
}

ProviderFailureCircuitPolicy providerFailureCircuitPolicy({
  required String? stage,
  required String? reason,
  required int consecutiveFailures,
}) {
  final normalized = reason?.trim().toLowerCase();
  if (normalized == 'empty_result' ||
      normalized == 'empty_sources' ||
      normalized == 'runtime_api' ||
      normalized == 'unsafe_target' ||
      normalized == 'http_404') {
    return const ProviderFailureCircuitPolicy(
      quarantineAfter: null,
      quarantineFor: null,
    );
  }

  // Every retryable provider failure uses the same threshold. Keeping one
  // ladder makes the pause predictable and ensures a single malformed
  // upstream response cannot disable an otherwise healthy add-on sooner than
  // a timeout or network failure.
  const threshold = 5;
  final step = (consecutiveFailures - threshold).clamp(0, 3);
  final minutes = switch (step) {
    0 => 5,
    1 => 10,
    2 => 20,
    _ => 30,
  };
  return ProviderFailureCircuitPolicy(
    quarantineAfter: threshold,
    quarantineFor: Duration(minutes: minutes),
  );
}

String? _providerFailureStage(String? value) {
  final normalized = value?.trim().toLowerCase();
  return const {
        'search',
        'title_matching',
        'episode_lookup',
        'server_lookup',
        'stream_extraction',
        'runtime',
      }.contains(normalized)
      ? normalized
      : null;
}

String? _providerFailureReason(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  if (const {
    'timeout',
    'empty_sources',
    'unsafe_target',
    'invalid_response',
    'network',
    'runtime_api',
    'provider_error',
    'empty_result',
  }.contains(normalized)) {
    return normalized;
  }
  return RegExp(r'^http_[1-5][0-9]{2}$').hasMatch(normalized)
      ? normalized
      : null;
}

class TetoTvDatabase {
  TetoTvDatabase._();

  TetoTvDatabase.forTesting(Database database) : _database = database;

  static final instance = TetoTvDatabase._();
  Database? _database;
  Future<Database>? _opening;

  Future<Database> get database async {
    final openDatabase = _database;
    if (openDatabase != null) return openDatabase;

    // Several providers can request the database during the same frame. Keep
    // one shared open operation so Android never races multiple connections to
    // the same file.
    final opening = _opening ??= _open();
    try {
      final database = await opening;
      _database = database;
      return database;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  Future<Database> _open() async {
    final root = await getDatabasesPath();
    return openDatabase(
      path.join(root, 'tetotv.db'),
      version: 9,
      onConfigure: configureTetoTvDatabase,
      onCreate: (db, _) async {
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
        await db.execute('''
          CREATE INDEX playback_history_updated
          ON playback_history(updated_at DESC)
        ''');
        await db.execute('''
          CREATE TABLE series_preferences (
            anilist_media_id INTEGER PRIMARY KEY,
            preferences_json TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE stream_failures (
            device_key TEXT NOT NULL,
            info_hash TEXT NOT NULL,
            reason TEXT,
            failure_count INTEGER NOT NULL DEFAULT 1,
            last_failed_at INTEGER NOT NULL,
            PRIMARY KEY (device_key, info_hash)
          )
        ''');
        await db.execute('''
          CREATE TABLE catalog_cache (
            cache_key TEXT PRIMARY KEY,
            payload_json TEXT NOT NULL,
            expires_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE performance_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            duration_us INTEGER NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await _createContinueDismissalsTable(db);
        await _createAddonTables(db);
        await _createReliabilityTables(db);
        await createOfflineDownloadTables(db);
      },
      onUpgrade: upgradeTetoTvDatabaseSchema,
    );
  }

  Future<void> saveCheckpoint(PlaybackCheckpoint checkpoint) async {
    final db = await database;
    await db.transaction((txn) => saveCheckpointTransaction(txn, checkpoint));
  }

  Future<PlaybackCheckpoint?> checkpoint(int mediaId, int episode) async {
    final db = await database;
    final rows = await db.query(
      'playback_history',
      where: 'anilist_media_id = ? AND episode = ?',
      whereArgs: [mediaId, episode],
      limit: 1,
    );
    return rows.isEmpty ? null : PlaybackCheckpoint.fromMap(rows.first);
  }

  Future<PlaybackCheckpoint?> latestCheckpoint(int mediaId) async {
    final db = await database;
    final rows = await db.query(
      'playback_history',
      where: 'anilist_media_id = ?',
      whereArgs: [mediaId],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : PlaybackCheckpoint.fromMap(rows.first);
  }

  Future<List<PlaybackCheckpoint>> recentHistory({int limit = 20}) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT h.* FROM playback_history h
      INNER JOIN (
        SELECT anilist_media_id, MAX(updated_at) AS latest
        FROM playback_history
        GROUP BY anilist_media_id
      ) grouped
      ON h.anilist_media_id = grouped.anilist_media_id
      AND h.updated_at = grouped.latest
      ORDER BY h.updated_at DESC
      LIMIT ?
      ''',
      [limit],
    );
    return rows.map(PlaybackCheckpoint.fromMap).toList(growable: false);
  }

  Future<void> removeLocalHistory(int mediaId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'playback_history',
        where: 'anilist_media_id = ?',
        whereArgs: [mediaId],
      );
      await txn.insert(
        'continue_watching_dismissals',
        {
          'anilist_media_id': mediaId,
          'dismissed_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<Set<int>> dismissedContinueWatchingIds() async {
    final db = await database;
    final rows = await db.query(
      'continue_watching_dismissals',
      columns: ['anilist_media_id'],
    );
    return rows.map((row) => row['anilist_media_id']! as int).toSet();
  }

  Future<SeriesPlaybackPreferences> seriesPreferences(int mediaId) async {
    final db = await database;
    final rows = await db.query(
      'series_preferences',
      columns: ['preferences_json'],
      where: 'anilist_media_id = ?',
      whereArgs: [mediaId],
      limit: 1,
    );
    if (rows.isEmpty) return const SeriesPlaybackPreferences();
    return SeriesPlaybackPreferences.fromJson(
      jsonDecode(rows.first['preferences_json']! as String)
          as Map<String, dynamic>,
    );
  }

  Future<void> saveSeriesPreferences(
    int mediaId,
    SeriesPlaybackPreferences preferences,
  ) async {
    final db = await database;
    await db.insert('series_preferences', {
      'anilist_media_id': mediaId,
      'preferences_json': jsonEncode(preferences.toJson()),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> recordStreamFailure({
    required String deviceKey,
    required String infoHash,
    required String reason,
  }) async {
    final db = await database;
    await db.rawInsert(
      '''
      INSERT INTO stream_failures
        (device_key, info_hash, reason, failure_count, last_failed_at)
      VALUES (?, ?, ?, 1, ?)
      ON CONFLICT(device_key, info_hash) DO UPDATE SET
        reason = excluded.reason,
        failure_count = failure_count + 1,
        last_failed_at = excluded.last_failed_at
      ''',
      [
        deviceKey,
        infoHash.toLowerCase(),
        redactDiagnosticValue(reason),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  Future<Map<String, int>> failureCounts(String deviceKey) async {
    final db = await database;
    final rows = await db.query(
      'stream_failures',
      columns: ['info_hash', 'failure_count'],
      where: 'device_key = ?',
      whereArgs: [deviceKey],
    );
    return {
      for (final row in rows)
        row['info_hash']! as String: row['failure_count']! as int,
    };
  }

  Future<void> recordPerformance(String name, Duration duration) async {
    final db = await database;
    await db.insert('performance_events', {
      'name': name,
      'duration_us': duration.inMicroseconds,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await db.delete(
      'performance_events',
      where:
          'id NOT IN (SELECT id FROM performance_events ORDER BY id DESC LIMIT 500)',
    );
  }

  Future<Map<String, ProviderHealth>> providerHealth() async {
    final db = await database;
    final rows = await db.query('provider_health');
    return {
      for (final row in rows)
        row['provider_id']! as String: ProviderHealth.fromMap(row),
    };
  }

  Future<void> recordProviderSuccess(String providerId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawInsert(
      '''
      INSERT INTO provider_health
        (provider_id, consecutive_failures, total_failures, last_success_at,
         last_error, last_failure_stage, last_failure_reason,
         quarantined_until)
      VALUES (?, 0, 0, ?, NULL, NULL, NULL, NULL)
      ON CONFLICT(provider_id) DO UPDATE SET
        consecutive_failures = 0,
        last_success_at = excluded.last_success_at,
        last_error = NULL,
        last_failure_stage = NULL,
        last_failure_reason = NULL,
        quarantined_until = NULL
      ''',
      [providerId, now],
    );
  }

  Future<ProviderHealth> recordProviderFailure(
    String providerId,
    Object error, {
    int? quarantineAfter,
    Duration? quarantineFor,
    String? stage,
    String? reason,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'provider_health',
        where: 'provider_id = ?',
        whereArgs: [providerId],
        limit: 1,
      );
      final previous = rows.isEmpty
          ? ProviderHealth(providerId: providerId)
          : ProviderHealth.fromMap(rows.first);
      final failures = previous.consecutiveFailures + 1;
      final now = DateTime.now();
      final safeStage = _providerFailureStage(stage);
      final safeReason = _providerFailureReason(reason);
      final policy = providerFailureCircuitPolicy(
        stage: safeStage,
        reason: safeReason,
        consecutiveFailures: failures,
      );
      final threshold = quarantineAfter ?? policy.quarantineAfter;
      final duration = quarantineFor ?? policy.quarantineFor;
      final quarantine =
          threshold != null && duration != null && failures >= threshold
          ? now.add(duration)
          : null;
      final message = redactDiagnosticValue(error.toString(), maximum: 300);
      await txn.rawInsert(
        '''
        INSERT INTO provider_health
          (provider_id, consecutive_failures, total_failures, last_success_at,
           last_failure_at, last_error, last_failure_stage,
           last_failure_reason, quarantined_until)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(provider_id) DO UPDATE SET
          consecutive_failures = excluded.consecutive_failures,
          total_failures = excluded.total_failures,
          last_success_at = excluded.last_success_at,
          last_failure_at = excluded.last_failure_at,
          last_error = excluded.last_error,
          last_failure_stage = excluded.last_failure_stage,
          last_failure_reason = excluded.last_failure_reason,
          quarantined_until = excluded.quarantined_until
        ''',
        [
          providerId,
          failures,
          previous.totalFailures + 1,
          previous.lastSuccessAt?.millisecondsSinceEpoch,
          now.millisecondsSinceEpoch,
          message,
          safeStage,
          safeReason,
          quarantine?.millisecondsSinceEpoch,
        ],
      );
      final updated = await txn.query(
        'provider_health',
        where: 'provider_id = ?',
        whereArgs: [providerId],
        limit: 1,
      );
      return ProviderHealth.fromMap(updated.single);
    });
  }

  Future<void> clearProviderHealth(String providerId) async {
    final db = await database;
    await db.delete(
      'provider_health',
      where: 'provider_id = ?',
      whereArgs: [providerId],
    );
  }

  Future<ProviderHealth> recordProviderCompatibilityResult(
    String providerId, {
    required bool passed,
    required String stage,
    required String reason,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final safeStage = _providerCompatibilityStage(stage);
    final safeReason = redactDiagnosticValue(
      reason,
      maximum: 80,
    ).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    await db.rawInsert(
      '''
      INSERT INTO provider_health
        (provider_id, consecutive_failures, total_failures,
         compatibility_tests, compatibility_passes, last_tested_at,
         last_test_stage, last_test_reason)
      VALUES (?, 0, 0, 1, ?, ?, ?, ?)
      ON CONFLICT(provider_id) DO UPDATE SET
        compatibility_tests = compatibility_tests + 1,
        compatibility_passes = compatibility_passes + excluded.compatibility_passes,
        last_tested_at = excluded.last_tested_at,
        last_test_stage = excluded.last_test_stage,
        last_test_reason = excluded.last_test_reason
      ''',
      [providerId, passed ? 1 : 0, now, safeStage, safeReason],
    );
    return (await providerHealth())[providerId]!;
  }

  Future<ProviderHealth> recordProviderCompatibilityInconclusive(
    String providerId, {
    required String stage,
    required String reason,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final safeStage = _providerCompatibilityStage(stage);
    final safeReason = redactDiagnosticValue(
      reason,
      maximum: 80,
    ).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    await db.rawInsert(
      '''
      INSERT INTO provider_health
        (provider_id, consecutive_failures, total_failures,
         last_tested_at, last_test_stage, last_test_reason)
      VALUES (?, 0, 0, ?, ?, ?)
      ON CONFLICT(provider_id) DO UPDATE SET
        last_tested_at = excluded.last_tested_at,
        last_test_stage = CASE
          WHEN provider_health.compatibility_tests > 0
            THEN provider_health.last_test_stage
          ELSE excluded.last_test_stage
        END,
        last_test_reason = CASE
          WHEN provider_health.compatibility_tests > 0
            THEN provider_health.last_test_reason
          ELSE excluded.last_test_reason
        END
      ''',
      [providerId, now, safeStage, safeReason],
    );
    return (await providerHealth())[providerId]!;
  }

  Future<DevicePlaybackProfile> devicePlaybackProfile(String deviceKey) async {
    final db = await database;
    final rows = await db.query(
      'device_player_profiles',
      where: 'device_key = ?',
      whereArgs: [deviceKey],
      limit: 1,
    );
    return rows.isEmpty
        ? DevicePlaybackProfile(deviceKey: deviceKey)
        : DevicePlaybackProfile.fromMap(rows.first);
  }

  Future<DevicePlaybackProfile> recordPlayerFailure(
    String deviceKey,
    String engine,
  ) async {
    final current = await devicePlaybackProfile(deviceKey);
    final mpv = current.mpvFailures + 1;
    final next = DevicePlaybackProfile(
      deviceKey: deviceKey,
      preferredEngine: 'mpv',
      mpvFailures: mpv,
    );
    await _saveDevicePlaybackProfile(next);
    return next;
  }

  Future<void> recordPlayerSuccess(String deviceKey, String engine) async {
    await _saveDevicePlaybackProfile(
      DevicePlaybackProfile(
        deviceKey: deviceKey,
        preferredEngine: 'mpv',
        mpvFailures: 0,
      ),
    );
  }

  Future<void> setPreferredPlayer(String deviceKey, String engine) async {
    final current = await devicePlaybackProfile(deviceKey);
    await _saveDevicePlaybackProfile(
      DevicePlaybackProfile(
        deviceKey: deviceKey,
        preferredEngine: 'mpv',
        mpvFailures: current.mpvFailures,
      ),
    );
  }

  Future<void> _saveDevicePlaybackProfile(DevicePlaybackProfile profile) async {
    final db = await database;
    await db.insert('device_player_profiles', {
      'device_key': profile.deviceKey,
      'preferred_engine': 'mpv',
      // Legacy columns stay populated for schema compatibility only.
      'media3_failures': 0,
      'mpv_failures': profile.mpvFailures,
      'vlc_failures': 0,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> recordDiagnosticEvent({
    required String category,
    required Object message,
    Object? details,
    String? severity,
    DateTime? occurredAt,
  }) async {
    try {
      final db = await database;
      await db.transaction(
        (transaction) => persistDiagnosticEvent(
          transaction,
          component: category,
          severity: severity,
          message: message,
          context: details,
          occurredAt: occurredAt,
        ),
      );
    } catch (_) {
      // Diagnostics must never become another app failure.
    }
  }

  Future<void> cacheJson(
    String key,
    Map<String, dynamic> payload, {
    Duration maxAge = const Duration(minutes: 30),
  }) async {
    final db = await database;
    final now = DateTime.now();
    await db.insert('catalog_cache', {
      'cache_key': key,
      'payload_json': jsonEncode(payload),
      'expires_at': now.add(maxAge).millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> cachedJson(
    String key, {
    bool allowExpired = false,
    Duration? maxStaleAge,
  }) async => loadCachedJson(
    await database,
    key,
    allowExpired: allowExpired,
    maxStaleAge: maxStaleAge,
  );

  Future<Map<String, Object?>> diagnosticsSnapshot({DateTime? now}) async {
    final db = await database;
    final snapshotEnd = (now ?? DateTime.now()).toUtc();
    final playback = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM playback_history'),
    );
    final operationalHistory = await loadRecentDiagnosticOperationalHistory(
      db,
      now: snapshotEnd,
    );
    final diagnosticHistory = await loadDiagnosticEventHistory(
      db,
      now: snapshotEnd,
    );
    final playbackSessionDiagnostics = derivePlaybackSessionDiagnostics(
      diagnosticHistory['diagnosticEvents'],
    );
    final providers = await db.rawQuery('''
      SELECT provider_id, consecutive_failures, total_failures,
             last_success_at, last_failure_at, last_error, quarantined_until,
             last_failure_stage, last_failure_reason,
             compatibility_tests, compatibility_passes, last_tested_at,
             last_test_stage, last_test_reason
      FROM provider_health ORDER BY provider_id
    ''');
    final playerProfiles = await db.rawQuery('''
      SELECT device_key, 'mpv' AS preferred_engine, mpv_failures, updated_at
      FROM device_player_profiles
    ''');
    final downloadRows = await db.rawQuery(
      '''
      SELECT status, transport, error_code, received_bytes,
             expected_bytes, updated_at
      FROM download_jobs
      WHERE updated_at >= ? AND updated_at <= ?
      ORDER BY updated_at DESC
      LIMIT 24
      ''',
      [
        snapshotEnd.subtract(diagnosticHistoryWindow).millisecondsSinceEpoch,
        snapshotEnd.millisecondsSinceEpoch,
      ],
    );
    return {
      'generatedAt': snapshotEnd.toIso8601String(),
      'playbackEntryCount': playback ?? 0,
      ...operationalHistory,
      ...diagnosticHistory,
      ...playbackSessionDiagnostics,
      'providerHealth': [
        for (final row in providers)
          {
            ...row,
            if (row['provider_id'] case final String value)
              'provider_id': redactDiagnosticValue(value, maximum: 120),
            if (row['last_error'] case final String value)
              'last_error': redactDiagnosticValue(value, maximum: 300),
          },
      ],
      'devicePlayerProfiles': playerProfiles,
      'downloadQueue': buildDownloadQueueDiagnostics(downloadRows),
    };
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
    _opening = null;
  }
}

/// Produces a troubleshooting-only queue summary without media identity,
/// titles, file names, paths, source URLs, provider credentials, or job IDs.
Map<String, Object?> buildDownloadQueueDiagnostics(
  Iterable<Map<String, Object?>> rows,
) {
  final statuses = <String, int>{};
  final recent = <Map<String, Object?>>[];
  for (final row in rows) {
    final status = _safeDownloadDiagnosticToken(
      row['status'],
      fallback: 'unknown',
    );
    final transport = _safeDownloadDiagnosticToken(
      row['transport'],
      fallback: 'unknown',
    );
    statuses[status] = (statuses[status] ?? 0) + 1;
    final updatedAt = row['updated_at'] is num
        ? (row['updated_at'] as num).toInt()
        : null;
    recent.add({
      'status': status,
      'transport': transport,
      if (row['error_code'] case final Object code)
        'reason': _safeDownloadDiagnosticToken(code, fallback: 'unknown'),
      'receivedMiB': _roundedDiagnosticMiB(row['received_bytes']),
      if (row['expected_bytes'] != null)
        'expectedMiB': _roundedDiagnosticMiB(row['expected_bytes']),
      if (updatedAt != null && updatedAt > 0)
        'updatedAt': DateTime.fromMillisecondsSinceEpoch(
          updatedAt,
          isUtc: true,
        ).toIso8601String(),
    });
  }
  return {
    'schema': 'tetotv-download-queue-v1',
    'windowHours': diagnosticHistoryWindow.inHours,
    'retainedCount': recent.length,
    'statusCounts': statuses,
    'recent': recent,
  };
}

String _safeDownloadDiagnosticToken(Object? value, {required String fallback}) {
  final normalized = value?.toString().trim().toLowerCase() ?? '';
  if (normalized.isEmpty ||
      normalized.length > 80 ||
      !RegExp(r'^[a-z0-9_-]+$').hasMatch(normalized)) {
    return fallback;
  }
  return normalized;
}

int _roundedDiagnosticMiB(Object? value) {
  final bytes = value is num ? value.toInt().clamp(0, 1 << 50) : 0;
  return (bytes / (1024 * 1024)).round();
}

/// Centralized schema upgrade path used by the application and real-SQLite
/// migration tests. Version 4 rows are preserved while diagnostics gain their
/// classification and truncation metadata.
Future<void> upgradeTetoTvDatabaseSchema(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  if (oldVersion < 2) await _createContinueDismissalsTable(db);
  if (oldVersion < 3) await _createAddonTables(db);
  if (oldVersion < 4) await _createReliabilityTables(db);
  if (oldVersion == 4 && newVersion >= 5) {
    await _upgradeDiagnosticHistory(db);
  }
  if (oldVersion >= 4 && oldVersion < 6 && newVersion >= 6) {
    await db.execute(
      'ALTER TABLE provider_health ADD COLUMN compatibility_tests '
      'INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE provider_health ADD COLUMN compatibility_passes '
      'INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE provider_health ADD COLUMN last_tested_at INTEGER',
    );
    await db.execute(
      'ALTER TABLE provider_health ADD COLUMN last_test_stage TEXT',
    );
    await db.execute(
      'ALTER TABLE provider_health ADD COLUMN last_test_reason TEXT',
    );
  }
  if (oldVersion >= 4 && oldVersion < 7 && newVersion >= 7) {
    await db.execute(
      'ALTER TABLE provider_health ADD COLUMN last_failure_stage TEXT',
    );
    await db.execute(
      'ALTER TABLE provider_health ADD COLUMN last_failure_reason TEXT',
    );
  }
  if (oldVersion < 8 && newVersion >= 8) {
    await createOfflineDownloadTables(db);
  }
  if (oldVersion < 9 && newVersion >= 9) {
    await createPendingSeasonDownloadTable(db);
  }
}

/// Creates the durable offline-download queue and catalog snapshot tables.
///
/// Source URIs are app-private resumable capabilities and are intentionally
/// omitted from every diagnostic query/export. Authentication headers and
/// cookies are never persisted here.
Future<void> createOfflineDownloadTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS download_jobs (
      id TEXT PRIMARY KEY,
      anilist_media_id INTEGER NOT NULL,
      mal_media_id INTEGER,
      episode INTEGER NOT NULL,
      series_title TEXT NOT NULL,
      episode_title TEXT,
      source_label TEXT NOT NULL,
      transport TEXT NOT NULL,
      status TEXT NOT NULL,
      source_uri TEXT,
      provider_id TEXT,
      provider_name TEXT,
      relative_path TEXT NOT NULL UNIQUE,
      quality TEXT,
      audio_label TEXT,
      mime_type TEXT,
      expected_bytes INTEGER,
      received_bytes INTEGER NOT NULL DEFAULT 0,
      speed_bps INTEGER NOT NULL DEFAULT 0,
      retry_count INTEGER NOT NULL DEFAULT 0,
      error_code TEXT,
      error_message TEXT,
      remote_transfer_id TEXT,
      queue_position INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      CHECK(anilist_media_id > 0),
      CHECK(episode > 0),
      CHECK(received_bytes >= 0),
      CHECK(speed_bps >= 0),
      CHECK(retry_count >= 0),
      CHECK(queue_position >= 0),
      CHECK(expected_bytes IS NULL OR expected_bytes > 0),
      CHECK(transport IN ('https', 'directPeer')),
      CHECK(status IN (
        'queued', 'resolving', 'downloading', 'paused', 'completed',
        'failed', 'cancelled', 'unsupported'
      ))
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS download_jobs_queue
    ON download_jobs(status, queue_position, created_at)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS download_jobs_episode
    ON download_jobs(anilist_media_id, episode, updated_at DESC)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS offline_media_metadata (
      anilist_media_id INTEGER PRIMARY KEY,
      mal_media_id INTEGER,
      title TEXT NOT NULL,
      schema_version INTEGER NOT NULL DEFAULT 1,
      metadata_json TEXT NOT NULL,
      cover_relative_path TEXT,
      banner_relative_path TEXT,
      updated_at INTEGER NOT NULL,
      CHECK(anilist_media_id > 0),
      CHECK(schema_version > 0)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS offline_episode_metadata (
      anilist_media_id INTEGER NOT NULL,
      episode INTEGER NOT NULL,
      schema_version INTEGER NOT NULL DEFAULT 1,
      duration_ms INTEGER,
      metadata_json TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY(anilist_media_id, episode),
      CHECK(anilist_media_id > 0),
      CHECK(episode > 0),
      CHECK(schema_version > 0),
      CHECK(duration_ms IS NULL OR duration_ms > 0)
    )
  ''');
  await createPendingSeasonDownloadTable(db);
}

/// Stores only the resumable season request, never resolved source links,
/// magnets, request headers, account tokens, or local filesystem paths.
///
/// TetoTV intentionally supports one season preparation at a time, so a
/// fixed slot keeps restoration atomic and prevents duplicate background
/// plans after process death.
Future<void> createPendingSeasonDownloadTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS pending_season_download (
      slot INTEGER PRIMARY KEY CHECK(slot = 1),
      anilist_media_id INTEGER NOT NULL,
      plan_json TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      CHECK(anilist_media_id > 0),
      CHECK(length(plan_json) > 0 AND length(plan_json) <= 1048576)
    )
  ''');
}

/// Loads the operational sections that are genuinely inside the diagnostic
/// time window. Counts make every SQL LIMIT explicit, and the historical
/// stream failure counter is named as such so it cannot be mistaken for a
/// 48-hour occurrence count.
Future<Map<String, Object?>> loadRecentDiagnosticOperationalHistory(
  DatabaseExecutor database, {
  DateTime? now,
}) async {
  const failureCapacity = 25;
  const timingCapacity = 100;
  final end = (now ?? DateTime.now()).toUtc();
  final start = end.subtract(diagnosticHistoryWindow);
  final arguments = [start.millisecondsSinceEpoch, end.millisecondsSinceEpoch];
  final failures = await database.rawQuery(
    '''
      SELECT reason, failure_count, last_failed_at
      FROM stream_failures
      WHERE last_failed_at >= ? AND last_failed_at <= ?
      ORDER BY last_failed_at DESC LIMIT ?
    ''',
    [...arguments, failureCapacity],
  );
  final failureCount = Sqflite.firstIntValue(
    await database.rawQuery('''
        SELECT COUNT(*) FROM stream_failures
        WHERE last_failed_at >= ? AND last_failed_at <= ?
      ''', arguments),
  );
  final timings = await database.rawQuery(
    '''
      SELECT name, duration_us, created_at
      FROM performance_events
      WHERE created_at >= ? AND created_at <= ?
      ORDER BY created_at DESC LIMIT ?
    ''',
    [...arguments, timingCapacity],
  );
  final timingCount = Sqflite.firstIntValue(
    await database.rawQuery('''
        SELECT COUNT(*) FROM performance_events
        WHERE created_at >= ? AND created_at <= ?
      ''', arguments),
  );
  final totalFailures = failureCount ?? 0;
  final totalTimings = timingCount ?? 0;
  return {
    'recentStreamFailureWindow': {
      'hours': diagnosticHistoryWindow.inHours,
      'startsAt': start.toIso8601String(),
      'endsAt': end.toIso8601String(),
      'capacity': failureCapacity,
      'retainedCount': failures.length,
      'droppedForCapacity': (totalFailures - failures.length).clamp(
        0,
        0x7fffffff,
      ),
    },
    'recentStreamFailures': [
      for (final row in failures)
        {
          if (row['reason'] case final String reason)
            'reason': redactDiagnosticValue(reason),
          'lifetimeFailureCount': (row['failure_count'] as num?)?.toInt() ?? 0,
          'lastFailedAt': row['last_failed_at'],
        },
    ],
    'recentFrameTimingWindow': {
      'hours': diagnosticHistoryWindow.inHours,
      'startsAt': start.toIso8601String(),
      'endsAt': end.toIso8601String(),
      'capacity': timingCapacity,
      'retainedCount': timings.length,
      'droppedForCapacity': (totalTimings - timings.length).clamp(
        0,
        0x7fffffff,
      ),
    },
    'recentFrameTimings': timings,
  };
}

Future<void> _createAddonTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS addon_repositories (
      url TEXT PRIMARY KEY,
      enabled INTEGER NOT NULL DEFAULT 1,
      is_default INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS installed_addons (
      id TEXT PRIMARY KEY,
      manifest_json TEXT NOT NULL,
      payload TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      repository_url TEXT NOT NULL,
      installed_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS marketplace_cache (
      repository_url TEXT PRIMARY KEY,
      payload_json TEXT NOT NULL,
      fetched_at INTEGER NOT NULL
    )
  ''');
}

/// Reads a catalog cache entry with an optional hard age limit for stale
/// outage fallback. Exposed separately so the SQL boundary can be covered by
/// deterministic tests without opening an Android database.
Future<Map<String, dynamic>?> loadCachedJson(
  DatabaseExecutor database,
  String key, {
  bool allowExpired = false,
  Duration? maxStaleAge,
  DateTime? now,
}) async {
  if (maxStaleAge?.isNegative == true) return null;
  final referenceTime = now ?? DateTime.now();
  final staleCutoff = maxStaleAge == null
      ? null
      : referenceTime.subtract(maxStaleAge).millisecondsSinceEpoch;
  final rows = await database.query(
    'catalog_cache',
    where: !allowExpired
        ? 'cache_key = ? AND expires_at > ?'
        : staleCutoff == null
        ? 'cache_key = ?'
        : 'cache_key = ? AND updated_at >= ?',
    whereArgs: !allowExpired
        ? [key, referenceTime.millisecondsSinceEpoch]
        : staleCutoff == null
        ? [key]
        : [key, staleCutoff],
    limit: 1,
  );
  if (rows.isEmpty) return null;
  return jsonDecode(rows.first['payload_json']! as String)
      as Map<String, dynamic>;
}

Future<void> _createReliabilityTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS provider_health (
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
  await db.execute('''
    CREATE TABLE IF NOT EXISTS device_player_profiles (
      device_key TEXT PRIMARY KEY,
      preferred_engine TEXT NOT NULL DEFAULT 'mpv',
      media3_failures INTEGER NOT NULL DEFAULT 0,
      mpv_failures INTEGER NOT NULL DEFAULT 0,
      vlc_failures INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS diagnostic_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category TEXT NOT NULL,
      severity TEXT NOT NULL DEFAULT 'info',
      message TEXT NOT NULL,
      details_json TEXT,
      created_at INTEGER NOT NULL
    )
  ''');
  await _createDiagnosticMetadataTable(db);
}

Future<void> _upgradeDiagnosticHistory(DatabaseExecutor db) async {
  // Version 4 already has diagnostic_events. Keep those persisted rows and
  // add only the classification required by the richer 48-hour export.
  await db.execute(
    "ALTER TABLE diagnostic_events ADD COLUMN severity TEXT NOT NULL DEFAULT 'info'",
  );
  await db.execute('''
    UPDATE diagnostic_events
    SET severity = CASE
      WHEN lower(category) IN ('flutter', 'platform')
        OR lower(category) LIKE '%crash%' THEN 'fatal'
      WHEN lower(category) LIKE '%failure%'
        OR lower(category) LIKE '%error%' THEN 'error'
      WHEN lower(category) LIKE '%fallback%'
        OR lower(category) LIKE '%provider%' THEN 'warning'
      ELSE 'info'
    END
  ''');
  await _createDiagnosticMetadataTable(db);
}

Future<void> _createDiagnosticMetadataTable(DatabaseExecutor db) =>
    db.execute('''
      CREATE TABLE IF NOT EXISTS diagnostic_metadata (
        key TEXT PRIMARY KEY,
        value INTEGER NOT NULL DEFAULT 0
      )
    ''');

/// Writes one already-redacted event to durable SQLite storage and prunes the
/// ring atomically. Public for deterministic database tests; callers normally
/// use [TetoTvDatabase.recordDiagnosticEvent].
Future<void> persistDiagnosticEvent(
  DatabaseExecutor database, {
  required String component,
  required Object message,
  Object? context,
  String? severity,
  DateTime? occurredAt,
}) async {
  final now = (occurredAt ?? DateTime.now()).toUtc();
  await database.insert('diagnostic_events', {
    'category': redactDiagnosticValue(component, maximum: 48),
    'severity': _safeDiagnosticSeverity(
      severity ?? _defaultDiagnosticSeverity(component),
    ),
    'message': redactDiagnosticValue(message.toString(), maximum: 500),
    'details_json': context == null
        ? null
        : jsonEncode(sanitizeDiagnosticContext(context)),
    'created_at': now.millisecondsSinceEpoch,
  });
  await pruneDiagnosticEventHistory(database, now: now);
}

/// Enforces the rolling 48-hour window and the hard row cap, retaining counts
/// that tell support when older or unusually noisy data was truncated.
Future<void> pruneDiagnosticEventHistory(
  DatabaseExecutor database, {
  DateTime? now,
}) async {
  final end = (now ?? DateTime.now()).toUtc();
  final cutoff = end.subtract(diagnosticHistoryWindow).millisecondsSinceEpoch;
  final droppedForAge = await database.delete(
    'diagnostic_events',
    where: 'created_at < ?',
    whereArgs: [cutoff],
  );
  final droppedForCapacity = await database.delete(
    'diagnostic_events',
    where:
        'id NOT IN (SELECT id FROM diagnostic_events ORDER BY created_at DESC, id DESC LIMIT ?)',
    whereArgs: const [maximumPersistedDiagnosticEvents],
  );
  if (droppedForAge > 0) {
    await _incrementDiagnosticMetadata(
      database,
      _diagnosticDroppedAgeKey,
      droppedForAge,
    );
  }
  if (droppedForCapacity > 0) {
    await _incrementDiagnosticMetadata(
      database,
      _diagnosticDroppedCapacityKey,
      droppedForCapacity,
    );
  }
}

Future<void> _incrementDiagnosticMetadata(
  DatabaseExecutor database,
  String key,
  int amount,
) => database.rawInsert(
  '''
    INSERT INTO diagnostic_metadata (key, value) VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = value + excluded.value
  ''',
  [key, amount],
);

/// Loads a redacted, chronological diagnostic window. This reads rows written
/// by previous processes/builds, so it deliberately sanitizes every value a
/// second time at the export boundary.
Future<Map<String, Object?>> loadDiagnosticEventHistory(
  DatabaseExecutor database, {
  DateTime? now,
}) async {
  final end = (now ?? DateTime.now()).toUtc();
  await pruneDiagnosticEventHistory(database, now: end);
  final start = end.subtract(diagnosticHistoryWindow);
  final rows = await database.rawQuery(
    '''
      SELECT id, category, severity, message, details_json, created_at
      FROM diagnostic_events
      WHERE created_at >= ? AND created_at <= ?
      ORDER BY created_at ASC, id ASC
      LIMIT ?
    ''',
    [
      start.millisecondsSinceEpoch,
      end.millisecondsSinceEpoch,
      maximumPersistedDiagnosticEvents,
    ],
  );
  final metadataRows = await database.rawQuery(
    'SELECT key, value FROM diagnostic_metadata',
  );
  final metadata = <String, int>{
    for (final row in metadataRows)
      if (row['key'] case final String key)
        key: (row['value'] as num?)?.toInt() ?? 0,
  };
  final events = <Map<String, Object?>>[];
  for (final row in rows) {
    final milliseconds = (row['created_at'] as num?)?.toInt();
    if (milliseconds == null) continue;
    events.add({
      'timestamp': DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      ).toIso8601String(),
      'component': redactDiagnosticValue(
        row['category']?.toString() ?? 'application',
        maximum: 48,
      ),
      'severity': _safeDiagnosticSeverity(row['severity']?.toString()),
      'message': redactDiagnosticValue(
        row['message']?.toString() ?? '',
        maximum: 500,
      ),
      if (row['details_json'] case final String encoded)
        'context': _decodeLegacyDiagnosticContext(encoded),
    });
  }
  return {
    'diagnosticEventSchema': diagnosticEventSchema,
    'diagnosticWindow': {
      'hours': diagnosticHistoryWindow.inHours,
      'startsAt': start.toIso8601String(),
      'endsAt': end.toIso8601String(),
      'ordering': 'oldest-first',
      'capacity': maximumPersistedDiagnosticEvents,
      'retainedCount': events.length,
      'droppedBeforeWindow': metadata[_diagnosticDroppedAgeKey] ?? 0,
      'droppedForCapacity': metadata[_diagnosticDroppedCapacityKey] ?? 0,
    },
    'diagnosticEvents': events,
  };
}

String _safeDiagnosticSeverity(String? value) =>
    switch (value?.trim().toLowerCase()) {
      'debug' => 'debug',
      'info' => 'info',
      'warning' || 'warn' => 'warning',
      'error' => 'error',
      'fatal' => 'fatal',
      _ => 'info',
    };

String _defaultDiagnosticSeverity(String component) {
  final normalized = component.toLowerCase();
  if (normalized == 'flutter' ||
      normalized == 'platform' ||
      normalized.contains('crash')) {
    return 'fatal';
  }
  if (normalized.contains('failure') || normalized.contains('error')) {
    return 'error';
  }
  if (normalized.contains('fallback') || normalized.contains('provider')) {
    return 'warning';
  }
  return 'info';
}

Object? _decodeLegacyDiagnosticContext(String value) {
  try {
    return sanitizeDiagnosticContext(jsonDecode(value));
  } catch (_) {
    return sanitizeDiagnosticContext(value);
  }
}

/// Produces small, JSON-safe context while removing identity and playback
/// material. Event context is technical metadata, never a content dump.
Object? sanitizeDiagnosticContext(Object? value, {int depth = 0}) {
  if (depth > 5) return '[DEPTH LIMITED]';
  if (value == null || value is bool || value is num) return value;
  if (value is String) {
    return redactDiagnosticValue(value, maximum: 1200);
  }
  if (value is List<int>) return '[BINARY DATA REDACTED]';
  if (value is Map) {
    final output = <String, Object?>{};
    var omitted = 0;
    var redactedFields = 0;
    var scanned = 0;
    for (final entry in value.entries) {
      if (scanned >= 100) {
        omitted += value.length - scanned;
        break;
      }
      scanned++;
      final rawKey = entry.key.toString();
      final key = redactDiagnosticValue(rawKey, maximum: 80);
      if (_isSensitiveDiagnosticContextKey(rawKey)) {
        if (output.length < 50) {
          output[key] = '[REDACTED]';
        } else {
          omitted++;
        }
        continue;
      }
      if (!_isSafeDiagnosticContextKey(rawKey)) {
        redactedFields++;
        continue;
      }
      if (output.length >= 50) {
        omitted++;
        continue;
      }
      output[key] = sanitizeDiagnosticContext(entry.value, depth: depth + 1);
    }
    if (omitted > 0) output['_truncatedFieldCount'] = omitted;
    if (redactedFields > 0) output['_redactedFieldCount'] = redactedFields;
    return output;
  }
  if (value is Iterable) {
    final items = value.toList(growable: false);
    return <Object?>[
      for (final item in items.take(30))
        sanitizeDiagnosticContext(item, depth: depth + 1),
      if (items.length > 30) {'_truncatedItemCount': items.length - 30},
    ];
  }
  return redactDiagnosticValue(value.toString(), maximum: 500);
}

bool _isSafeDiagnosticContextKey(String key) {
  final normalized = key
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]}_${match[2]}',
      )
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return const {
    'safe',
    'component',
    'category',
    'severity',
    'operation',
    'phase',
    'state',
    'status',
    'step',
    'stage',
    'sequence',
    'session_id',
    'attempt',
    'retry',
    'retry_count',
    'count',
    'total',
    'retained_count',
    'dropped_count',
    'duration_ms',
    'duration_us',
    'elapsed_ms',
    'position_ms',
    'timeout_ms',
    'service',
    'kind',
    'code',
    'mode',
    'engine',
    'source_kind',
    'decoder',
    'decoder_name',
    'codec',
    'fallback_kind',
    'reason_code',
    'outcome',
    'quality',
    'resolution',
    'audio_mode',
    'requested_audio',
    'source_audio_mode',
    'selected_audio_language',
    'audio_preference_source',
    'audio_track_count',
    'audio_preference_matched',
    'subtitle_mode',
    'catalog_mapping_available',
    'embedded_marker_count',
    'community_marker_count',
    'community_status',
    'community_probe_count',
    'duration_fallback_used',
    'requested_duration_ms',
    'current_duration_ms',
    'segment_kind',
    'marker_source',
    'automatic',
    'seek_succeeded',
    'watch_party_active',
    'guest_controls_locked',
    'controls_visible',
    'marker_count',
    'matching_marker_count',
    'marker_start_ms',
    'marker_end_ms',
    'target_ms',
    'cached',
    'seekable',
    'frame',
    'stack',
    'exception',
    'error',
    'error_type',
    'message',
    'reason',
  }.contains(normalized);
}

bool _isSensitiveDiagnosticContextKey(String key) {
  final normalized = key
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]}_${match[2]}',
      )
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final compact = normalized.replaceAll('_', '');
  return RegExp(
        r'(?:^|_)(?:authorization|cookie|credential|password|passcode|secret|token|api_key|client_secret|headers?|http_headers?|request_headers?|response_headers?|query|query_parameters?|endpoint|origin|base_url|room_code|capability|tracker_id|anilist_(?:media_)?id|mal_(?:media_)?id|account_id|user_id|username|display_name|member|guest|host|participant|owner|email|avatar|file_name|filename|path|uri|url|hostname|server_name|server_id|library_id|item_id|media_id|magnet|info_hash|torrent_hash|source_id|stream_id|media_bytes|payload_bytes|media_title|anime_title|episode_title|title|episode)(?:$|_)',
      ).hasMatch(normalized) ||
      const {
        'authorization',
        'cookie',
        'header',
        'headers',
        'httpheader',
        'httpheaders',
        'requestheader',
        'requestheaders',
        'responseheader',
        'responseheaders',
        'query',
        'queryparameters',
        'endpoint',
        'origin',
        'baseurl',
        'credentials',
        'password',
        'passcode',
        'apikey',
        'clientsecret',
        'roomcode',
        'capability',
        'trackerid',
        'anilistid',
        'anilistmediaid',
        'malid',
        'malmediaid',
        'accountid',
        'userid',
        'username',
        'displayname',
        'member',
        'guest',
        'host',
        'participant',
        'owner',
        'email',
        'avatar',
        'hostname',
        'servername',
        'serverid',
        'libraryid',
        'itemid',
        'mediaid',
        'filename',
        'magnet',
        'infohash',
        'torrenthash',
        'sourceid',
        'streamid',
        'mediabytes',
        'payloadbytes',
        'bytes',
        'binary',
        'buffer',
        'body',
        'payload',
        'source',
        'rawsource',
        'stream',
        'rawstream',
        'torrent',
        'release',
        'mediatitle',
        'animetitle',
        'episodetitle',
        'title',
        'episode',
      }.contains(compact) ||
      compact.contains('accesstoken') ||
      compact.contains('refreshtoken') ||
      compact.contains('bearertoken') ||
      compact.endsWith('secret') ||
      compact.endsWith('url') ||
      compact.endsWith('uri') ||
      compact.endsWith('path') ||
      compact.endsWith('avatar');
}

String redactDiagnosticValue(String value, {int maximum = 500}) {
  var redacted = value
      .replaceAll(
        RegExp(r'''https?%3a%2f%2f[^\s"']+''', caseSensitive: false),
        '[URL]',
      )
      .replaceAll(
        RegExp(r'''https?://[^\s"']+''', caseSensitive: false),
        '[URL]',
      )
      .replaceAll(
        // JSON-encoded exception text can escape each slash while leaving the
        // URL otherwise intact. Handle that representation explicitly before
        // the generic URI rule so reports consistently describe it as a URL.
        RegExp(r'''https?:\\/\\/[^\s"']+''', caseSensitive: false),
        '[URL]',
      )
      .replaceAll(
        RegExp(r'''(?<![A-Za-z0-9:])//[^\s"']+''', caseSensitive: false),
        '[URL]',
      )
      .replaceAll(
        // Some socket, proxy, and provider errors omit the scheme but retain a
        // DNS host plus path. Requiring a path and an alphabetic DNS suffix
        // avoids treating dotted versions, shared-library names, or ordinary
        // Dart/Java class names as URLs.
        RegExp(
          r'''\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})\.)+[A-Za-z]{2,63}(?::\d{1,5})?/(?!/)[^\s"']*''',
          caseSensitive: false,
        ),
        '[URL]',
      )
      .replaceAll(
        RegExp(
          r'''\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d{1,5})?(?:/[^\s"']*)?[?&](?:x-amz-signature|x-amz-credential|x-amz-security-token|signature|sig|token)=[^\s"']+''',
          caseSensitive: false,
        ),
        '[URL]',
      )
      .replaceAll(
        RegExp(r'''magnet:\?[^\s"']+''', caseSensitive: false),
        '[MAGNET]',
      )
      .replaceAll(
        RegExp(
          r'''\b(?![A-Za-z]:[\\/])[A-Za-z][A-Za-z0-9+.-]{0,31}:(?![0-9\s])[^\s"'<>]+''',
          caseSensitive: false,
        ),
        '[URI]',
      )
      .replaceAllMapped(
        RegExp(
          r'''(^|[\s"'(=\[])(?:[A-Za-z]:[\\/]|\\\\[^\\/\s"'<>]+[\\/])[^\r\n"'<>]*''',
          multiLine: true,
        ),
        (match) => '${match.group(1)}[PATH]',
      )
      .replaceAllMapped(
        RegExp(r'''(^|[\s"'(=\[])/(?!/)[^\r\n"'<>]*''', multiLine: true),
        (match) => '${match.group(1)}[PATH]',
      )
      .replaceAll(
        RegExp(
          r'''["'][^"'\r\n]{1,240}\.(?:mkv|mp4|m4v|avi|mov|wmv|webm|ts|m2ts|flv|ogv|mp3|m4a|aac|flac|wav|ogg|opus|ass|ssa|srt|vtt)["']''',
          caseSensitive: false,
        ),
        '[FILENAME]',
      )
      .replaceAll(
        RegExp(
          r'''\b[A-Za-z0-9_()\[\].+ -]{1,120}\.(?:mkv|mp4|m4v|avi|mov|wmv|webm|ts|m2ts|flv|ogv|mp3|m4a|aac|flac|wav|ogg|opus|ass|ssa|srt|vtt)\b''',
          caseSensitive: false,
        ),
        '[FILENAME]',
      )
      .replaceAll(
        RegExp(r'\bgithub_pat_[A-Za-z0-9_]+\b', caseSensitive: false),
        '[REDACTED]',
      )
      .replaceAll(
        RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b', caseSensitive: false),
        '[REDACTED]',
      )
      .replaceAll(
        RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
        '[REDACTED]',
      )
      .replaceAll(
        RegExp(r'\bbearer\s+[^\s,;"\x27]+', caseSensitive: false),
        'Bearer [REDACTED]',
      )
      .replaceAll(
        RegExp(r'\bbasic\s+[^\s,;"\x27]+', caseSensitive: false),
        'Basic [REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(?<![A-Za-z0-9_-])["']?(?:set-cookie|cookie)["']?\s*[:=]\s*["']?[^\r\n]+''',
          caseSensitive: false,
        ),
        '[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(["']?(?:authorization|access[_ -]?token|refresh[_ -]?token|auth[_ -]?token|token|api[_ -]?key|client[_ -]?secret|password|session|x-plex-token|x-emby-token|x-mediabrowser-token|x-auth-token|x-amz-signature|x-amz-credential|x-amz-security-token|signature|sig)["']?\s*[:=]\s*["']?)[^\s,;&"']+''',
          caseSensitive: false,
        ),
        '[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(?<![A-Za-z0-9_])["']?(?:headers?|http[_ -]?headers?|request[_ -]?headers?|response[_ -]?headers?|query[_ -]?parameters?|endpoint|origin|base[_ -]?url|server[_ -]?id|library[_ -]?id|item[_ -]?id|media[_ -]?id)["']?\s*[:=]\s*["']?[^\r\n,;]+''',
          caseSensitive: false,
        ),
        '[PRIVATE CONTEXT REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(?<![A-Za-z0-9_])["']?(?:room[_ -]?code|capability|tracker[_ -]?id|anilist[_ -]?(?:id|media[_ -]?id)|mal[_ -]?(?:id|media[_ -]?id)|account[_ -]?id|user[_ -]?id|user[_ -]?name|display[_ -]?name|avatar|(?:raw[_ -]?)?source(?:[_ -]?id)?|(?:raw[_ -]?)?stream(?:[_ -]?id)?|torrent[_ -]?hash|info[_ -]?hash)["']?\s*[:=]\s*["']?[^\s,;"']+''',
          caseSensitive: false,
        ),
        '[PRIVATE CONTEXT REDACTED]',
      )
      .replaceAll(RegExp(r'(?<!\d)[2-9]{8}(?!\d)'), '[ROOM CODE]')
      .replaceAll(RegExp(r'\b[a-fA-F0-9]{32,}\b'), '[INFO_HASH]')
      .replaceAll(
        RegExp(r'\b[A-Z2-7]{32,52}\b', caseSensitive: false),
        '[INFO_HASH]',
      )
      .replaceAll(RegExp(r'[\r\n]+'), ' ')
      .trim();
  redacted = _redactIpv6Addresses(redacted)
      .replaceAll(
        RegExp(
          r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
          caseSensitive: false,
        ),
        '[EMAIL]',
      )
      .replaceAll(
        RegExp(
          r'''\b(?:localhost|[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})\.(?:local|home|lan|internal))(?::\d{1,5})?\b''',
          caseSensitive: false,
        ),
        '[PRIVATE SERVER]',
      )
      .replaceAll(
        RegExp(
          r'''(?<![A-Za-z0-9_])(?:server|host|peer|address)\s*[:=]\s*(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})\.)+[A-Za-z]{2,63}(?::\d{1,5})?\b''',
          caseSensitive: false,
        ),
        '[NETWORK HOST]',
      )
      .replaceAll(
        RegExp(r'\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b', caseSensitive: false),
        '[NETWORK ADDRESS]',
      )
      .replaceAll(
        RegExp(r'(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9])'),
        '[NETWORK ADDRESS]',
      );
  if (redacted.length > maximum) redacted = redacted.substring(0, maximum);
  return redacted;
}

String _redactIpv6Addresses(String value) => value.replaceAllMapped(
  // Keep the candidate deliberately broad and let InternetAddress perform the
  // actual IPv6 validation. This covers compressed, bracketed, numeric-leading,
  // and IPv4-mapped forms without treating timestamps or ordinary colon text
  // as network addresses.
  RegExp(
    r'(?<![A-Za-z0-9])\[?[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]+(?:%[A-Za-z0-9_.-]+)?\]?(?![A-Za-z0-9])',
  ),
  (match) {
    final original = match.group(0)!;
    var candidate = original;
    var trailingDots = '';
    while (candidate.endsWith('.')) {
      candidate = candidate.substring(0, candidate.length - 1);
      trailingDots += '.';
    }
    if (candidate.startsWith('[') && candidate.endsWith(']')) {
      candidate = candidate.substring(1, candidate.length - 1);
    }
    final zoneIndex = candidate.lastIndexOf('%');
    final address = InternetAddress.tryParse(
      zoneIndex < 0 ? candidate : candidate.substring(0, zoneIndex),
    );
    return address?.type == InternetAddressType.IPv6
        ? '[NETWORK ADDRESS]$trailingDots'
        : original;
  },
);

Future<void> saveCheckpointTransaction(
  DatabaseExecutor database,
  PlaybackCheckpoint checkpoint,
) async {
  final existing = await database.query(
    'playback_history',
    columns: const ['updated_at'],
    where: 'anilist_media_id = ? AND episode = ?',
    whereArgs: [checkpoint.anilistMediaId, checkpoint.episode],
    limit: 1,
  );
  final existingUpdatedAt = existing.isEmpty
      ? null
      : existing.first['updated_at'] as int?;
  // Position callbacks and route disposal can enqueue overlapping writes.
  // Never let an older, slower write overwrite the final Exit checkpoint.
  if (existingUpdatedAt != null &&
      existingUpdatedAt > checkpoint.updatedAt.millisecondsSinceEpoch) {
    return;
  }
  await database.delete(
    'continue_watching_dismissals',
    where: 'anilist_media_id = ?',
    whereArgs: [checkpoint.anilistMediaId],
  );
  await database.insert(
    'playback_history',
    checkpoint.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

Future<void> _createContinueDismissalsTable(DatabaseExecutor db) =>
    db.execute('''
  CREATE TABLE IF NOT EXISTS continue_watching_dismissals (
    anilist_media_id INTEGER PRIMARY KEY,
    dismissed_at INTEGER NOT NULL
  )
''');
