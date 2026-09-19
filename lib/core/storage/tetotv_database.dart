import 'dart:convert';
import 'dart:io';

import 'package:anime_tv/core/diagnostics/playback_performance_diagnostics.dart';
import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

/// Explicit diagnostic exports retain only this rolling, on-device window.
/// The SQLite table survives process death; it is never uploaded unless the
/// user presses the diagnostic-report share button.
const diagnosticHistoryWindow = Duration(hours: 48);
const tetoTvDatabaseSchemaVersion = 15;
const maximumPersistedPlaybackPerformanceAttempts = 24;
// Provider searches and playback startup can each emit a burst of events.
// Retain enough history for a complete search plus the playback which follows
// it; 240 entries allowed title-artwork noise to evict the evidence needed to
// correlate a source-picker result with an intermittent player failure. Keep
// this aligned with the explicit report sanitizer's full-size list bound so a
// chronological export never drops the newest events. Five hundred entries
// cover several provider searches plus their playback fallbacks while still
// fitting inside the explicit report's hard size limit in normal operation.
const maximumPersistedDiagnosticEvents = 500;
const diagnosticEventSchema = 'tetotv-diagnostic-events-v3';

const _diagnosticDroppedAgeKey = 'dropped_age';
const _diagnosticDroppedCapacityKey = 'dropped_capacity';
const _playbackPerformanceDroppedWindowKey =
    'playback_performance_dropped_window';
const _playbackPerformanceDroppedCapacityKey =
    'playback_performance_dropped_capacity';

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
    // v2.0.52 could persist subtitlePreferenceSet from transient player state.
    // This independent marker proves that the value came from the corrected
    // explicit-intent serializer instead of that legacy behavior.
    'subtitlePreferenceExplicit': subtitlePreferenceSet,
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

  factory SeriesPlaybackPreferences.fromJson(Map<String, dynamic> json) {
    final hasExplicitSubtitlePreference =
        json['subtitlePreferenceExplicit'] == true &&
        json['subtitlePreferenceSet'] == true;
    return SeriesPlaybackPreferences(
      audioLanguage: json['audioLanguage'] as String? ?? 'eng',
      audioPreferenceSet: json['audioPreferenceSet'] as bool? ?? false,
      subtitleLanguage: hasExplicitSubtitlePreference
          ? json['subtitleLanguage'] as String? ?? 'eng'
          : 'eng',
      subtitleEnabled: hasExplicitSubtitlePreference
          ? json['subtitleEnabled'] as bool? ?? true
          : true,
      // Rows written before the explicit marker existed must not override
      // the global Preferred CC default. New manual choices serialize both
      // fields, so their On/Off/language intent remains authoritative.
      subtitlePreferenceSet: hasExplicitSubtitlePreference,
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
  /// security incompatibilities use that path for different reasons: the
  /// former must not damage global health, while unsafe targets remain blocked
  /// until the add-on is updated or manually reset. Runtime failures observed
  /// during discovery use the ordinary repeated-failure circuit; only an
  /// explicit compatibility result may establish permanent incompatibility.
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
      version: tetoTvDatabaseSchemaVersion,
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
        await createMangaTables(db);
        await createAppNotificationsTable(db);
        await createPlaybackPerformanceTable(db);
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
    final normalizedHash = infoHash.toLowerCase();
    final safeReason = redactDiagnosticValue(reason);
    final failedAt = DateTime.now().millisecondsSinceEpoch;
    // Android 7 / SDK 25 ships SQLite older than 3.24, so it cannot parse the
    // modern UPSERT clause. Keep the increment atomic while using
    // statements supported by every Android version TetoTV accepts.
    await db.transaction((txn) async {
      final updated = await txn.rawUpdate(
        '''
        UPDATE stream_failures
        SET reason = ?, failure_count = failure_count + 1, last_failed_at = ?
        WHERE device_key = ? AND info_hash = ?
        ''',
        [safeReason, failedAt, deviceKey, normalizedHash],
      );
      if (updated != 0) return;
      await txn.insert('stream_failures', {
        'device_key': deviceKey,
        'info_hash': normalizedHash,
        'reason': safeReason,
        'failure_count': 1,
        'last_failed_at': failedAt,
      });
    });
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
    await db.transaction((txn) async {
      final values = <String, Object?>{
        'consecutive_failures': 0,
        'last_success_at': now,
        'last_error': null,
        'last_failure_stage': null,
        'last_failure_reason': null,
        'quarantined_until': null,
      };
      final existing = await txn.query(
        'provider_health',
        columns: const ['provider_id'],
        where: 'provider_id = ?',
        whereArgs: [providerId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('provider_health', {
          'provider_id': providerId,
          'total_failures': 0,
          ...values,
        });
      } else {
        await txn.update(
          'provider_health',
          values,
          where: 'provider_id = ?',
          whereArgs: [providerId],
        );
      }
    });
  }

  /// A completed discovery request is healthy even when it has no match.
  /// Clear its transient failure streak and circuit pause without updating
  /// [ProviderHealth.lastSuccessAt], which is reserved for providers that
  /// were actually validated/played and drives last-good prioritization.
  Future<void> recordProviderHealthyResponse(String providerId) async {
    final db = await database;
    await db.transaction((txn) async {
      final values = <String, Object?>{
        'consecutive_failures': 0,
        'last_error': null,
        'last_failure_stage': null,
        'last_failure_reason': null,
        'quarantined_until': null,
      };
      final existing = await txn.query(
        'provider_health',
        columns: const ['provider_id'],
        where: 'provider_id = ?',
        whereArgs: [providerId],
        limit: 1,
      );
      if (existing.isEmpty) {
        await txn.insert('provider_health', {
          'provider_id': providerId,
          'total_failures': 0,
          ...values,
        });
      } else {
        await txn.update(
          'provider_health',
          values,
          where: 'provider_id = ?',
          whereArgs: [providerId],
        );
      }
    });
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
      final values = <String, Object?>{
        'consecutive_failures': failures,
        'total_failures': previous.totalFailures + 1,
        'last_success_at': previous.lastSuccessAt?.millisecondsSinceEpoch,
        'last_failure_at': now.millisecondsSinceEpoch,
        'last_error': message,
        'last_failure_stage': safeStage,
        'last_failure_reason': safeReason,
        'quarantined_until': quarantine?.millisecondsSinceEpoch,
      };
      if (rows.isEmpty) {
        await txn.insert('provider_health', {
          'provider_id': providerId,
          ...values,
        });
      } else {
        await txn.update(
          'provider_health',
          values,
          where: 'provider_id = ?',
          whereArgs: [providerId],
        );
      }
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
    return db.transaction((txn) async {
      final passIncrement = passed ? 1 : 0;
      final updated = await txn.rawUpdate(
        '''
        UPDATE provider_health
        SET compatibility_tests = compatibility_tests + 1,
            compatibility_passes = compatibility_passes + ?,
            last_tested_at = ?,
            last_test_stage = ?,
            last_test_reason = ?
        WHERE provider_id = ?
        ''',
        [passIncrement, now, safeStage, safeReason, providerId],
      );
      if (updated == 0) {
        await txn.insert('provider_health', {
          'provider_id': providerId,
          'consecutive_failures': 0,
          'total_failures': 0,
          'compatibility_tests': 1,
          'compatibility_passes': passIncrement,
          'last_tested_at': now,
          'last_test_stage': safeStage,
          'last_test_reason': safeReason,
        });
      }
      final rows = await txn.query(
        'provider_health',
        where: 'provider_id = ?',
        whereArgs: [providerId],
        limit: 1,
      );
      return ProviderHealth.fromMap(rows.single);
    });
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
    return db.transaction((txn) async {
      final rows = await txn.query(
        'provider_health',
        where: 'provider_id = ?',
        whereArgs: [providerId],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('provider_health', {
          'provider_id': providerId,
          'consecutive_failures': 0,
          'total_failures': 0,
          'last_tested_at': now,
          'last_test_stage': safeStage,
          'last_test_reason': safeReason,
        });
      } else {
        final previous = ProviderHealth.fromMap(rows.single);
        await txn.update(
          'provider_health',
          {
            'last_tested_at': now,
            if (previous.compatibilityTests == 0) ...{
              'last_test_stage': safeStage,
              'last_test_reason': safeReason,
            },
          },
          where: 'provider_id = ?',
          whereArgs: [providerId],
        );
      }
      final updated = await txn.query(
        'provider_health',
        where: 'provider_id = ?',
        whereArgs: [providerId],
        limit: 1,
      );
      return ProviderHealth.fromMap(updated.single);
    });
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
    // This legacy table describes MPV only. A Media3 outcome must not train
    // MPV's compatibility history or silently change the selected engine.
    if (engine != 'mpv') return current;
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
    if (engine != 'mpv') return;
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

  /// Performance samples use an independent, upserted attempt history so
  /// periodic sampling can never evict startup/failure diagnostic events.
  Future<void> savePlaybackPerformanceSnapshot(
    Map<String, Object?> snapshot,
  ) async {
    try {
      final db = await database;
      await db.transaction(
        (transaction) =>
            persistPlaybackPerformanceSnapshot(transaction, snapshot),
      );
    } catch (_) {
      // Diagnostics-only storage failure must not interrupt playback.
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

  Future<void> removeCachedJson(String key) async {
    final db = await database;
    await db.delete('catalog_cache', where: 'cache_key = ?', whereArgs: [key]);
  }

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
    final playbackPerformance = await loadPlaybackPerformanceHistory(
      db,
      now: snapshotEnd,
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
      ...playbackPerformance,
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
  if (oldVersion < 10 && newVersion >= 10) {
    await createMangaTables(db);
  }
  if (oldVersion < 11 && newVersion >= 11) {
    await createAppNotificationsTable(db);
  }
  if (oldVersion >= 11 && oldVersion < 12 && newVersion >= 12) {
    await _upgradeAppNotificationsToV12(db);
  }
  if (oldVersion < 13 && newVersion >= 13) {
    await createPlaybackPerformanceTable(db);
  }
  if (oldVersion < 14 && newVersion >= 14) {
    await createMangaTables(db);
  }
  if (oldVersion >= 3 && oldVersion < 15 && newVersion >= 15) {
    await _upgradeMarketplaceCacheToV15(db);
  }
}

Future<void> _upgradeMarketplaceCacheToV15(Database db) async {
  // A few early/private schemas could be missing the cache table entirely,
  // while tests and development builds may already have the new column. Make
  // this migration idempotent across both shapes without discarding caches.
  await _createAddonTables(db);
  final columns = await db.rawQuery('PRAGMA table_info(marketplace_cache)');
  if (columns.any((column) => column['name'] == 'resource_base_url')) return;
  await db.execute(
    'ALTER TABLE marketplace_cache ADD COLUMN resource_base_url TEXT',
  );
}

/// Durable performance history is independent from the diagnostic event ring.
/// Only the strict performance allowlist is ever serialized into this table.
Future<void> createPlaybackPerformanceTable(DatabaseExecutor database) async {
  await _createDiagnosticMetadataTable(database);
  await database.execute('''
    CREATE TABLE IF NOT EXISTS playback_performance_snapshots (
      session_id TEXT NOT NULL,
      attempt INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      snapshot_json TEXT NOT NULL,
      PRIMARY KEY (session_id, attempt)
    )
  ''');
  await database.execute('''
    CREATE INDEX IF NOT EXISTS playback_performance_updated_at
    ON playback_performance_snapshots(updated_at DESC)
  ''');
}

/// Public for deterministic SQLite tests; normal callers use the failure-safe
/// [TetoTvDatabase.savePlaybackPerformanceSnapshot] transaction wrapper.
Future<void> persistPlaybackPerformanceSnapshot(
  DatabaseExecutor database,
  Map<String, Object?> snapshot, {
  DateTime? now,
}) async {
  final safe = sanitizePlaybackPerformanceSnapshot(snapshot);
  if (safe.isEmpty) return;
  final updatedAt = DateTime.parse(safe['updatedAt']! as String);
  final end = (now ?? DateTime.now()).toUtc();
  if (updatedAt.isAfter(end) ||
      updatedAt.isBefore(end.subtract(diagnosticHistoryWindow))) {
    await prunePlaybackPerformanceHistory(database, now: end);
    return;
  }
  // Conditional replacement is atomic and uses the older SQLite syntax
  // available on supported Android TVs. Late saves cannot restore old data.
  await database.rawInsert(
    '''
      INSERT OR REPLACE INTO playback_performance_snapshots
        (session_id, attempt, updated_at, snapshot_json)
      SELECT ?, ?, ?, ?
      WHERE NOT EXISTS (
        SELECT 1 FROM playback_performance_snapshots
        WHERE session_id = ? AND attempt = ? AND updated_at > ?
      )
    ''',
    [
      safe['sessionId'],
      safe['attempt'],
      updatedAt.millisecondsSinceEpoch,
      jsonEncode(safe),
      safe['sessionId'],
      safe['attempt'],
      updatedAt.millisecondsSinceEpoch,
    ],
  );
  await prunePlaybackPerformanceHistory(database, now: end);
}

Future<void> prunePlaybackPerformanceHistory(
  DatabaseExecutor database, {
  DateTime? now,
}) async {
  final end = (now ?? DateTime.now()).toUtc();
  final droppedOutsideWindow = await database.delete(
    'playback_performance_snapshots',
    where: 'updated_at < ? OR updated_at > ?',
    whereArgs: [
      end.subtract(diagnosticHistoryWindow).millisecondsSinceEpoch,
      end.millisecondsSinceEpoch,
    ],
  );
  final droppedForCapacity = await database.delete(
    'playback_performance_snapshots',
    where: '''
      rowid NOT IN (
        SELECT rowid FROM playback_performance_snapshots
        ORDER BY updated_at DESC, session_id DESC, attempt DESC LIMIT ?
      )
    ''',
    whereArgs: const [maximumPersistedPlaybackPerformanceAttempts],
  );
  if (droppedOutsideWindow > 0) {
    await _incrementDiagnosticMetadata(
      database,
      _playbackPerformanceDroppedWindowKey,
      droppedOutsideWindow,
    );
  }
  if (droppedForCapacity > 0) {
    await _incrementDiagnosticMetadata(
      database,
      _playbackPerformanceDroppedCapacityKey,
      droppedForCapacity,
    );
  }
}

/// Revalidates historical/corrupt rows at the export boundary. A damaged
/// diagnostics-only table must not prevent the rest of an explicit report.
Future<Map<String, Object?>> loadPlaybackPerformanceHistory(
  DatabaseExecutor database, {
  DateTime? now,
}) async {
  final end = (now ?? DateTime.now()).toUtc();
  final snapshots = <Map<String, Object?>>[];
  var invalidSnapshots = 0;
  var storageUnavailable = false;
  final dropped = <String, int>{};
  try {
    await prunePlaybackPerformanceHistory(database, now: end);
    final metadata = await database.query(
      'diagnostic_metadata',
      where: 'key IN (?, ?)',
      whereArgs: const [
        _playbackPerformanceDroppedWindowKey,
        _playbackPerformanceDroppedCapacityKey,
      ],
    );
    for (final row in metadata) {
      if (row['key'] is String && row['value'] is int) {
        dropped[row['key']! as String] = (row['value']! as int).clamp(
          0,
          1000000000,
        );
      }
    }
    final rows = await database.query(
      'playback_performance_snapshots',
      columns: ['session_id', 'attempt', 'updated_at', 'snapshot_json'],
      orderBy: 'updated_at DESC, session_id DESC, attempt DESC',
      limit: maximumPersistedPlaybackPerformanceAttempts,
    );
    for (final row in rows) {
      try {
        final safe = sanitizePlaybackPerformanceSnapshot(
          jsonDecode(row['snapshot_json']! as String),
        );
        if (safe.isEmpty ||
            safe['sessionId'] != row['session_id'] ||
            safe['attempt'] != row['attempt'] ||
            DateTime.parse(
                  safe['updatedAt']! as String,
                ).millisecondsSinceEpoch !=
                row['updated_at']) {
          invalidSnapshots++;
          continue;
        }
        snapshots.add(safe);
      } catch (_) {
        invalidSnapshots++;
      }
    }
  } catch (_) {
    storageUnavailable = true;
  }
  return {
    'playbackPerformanceSchema': playbackPerformanceSchema,
    'playbackPerformanceWindow': {
      'hours': diagnosticHistoryWindow.inHours,
      'startsAt': end.subtract(diagnosticHistoryWindow).toIso8601String(),
      'endsAt': end.toIso8601String(),
      'ordering': 'newest-first',
      'capacity': maximumPersistedPlaybackPerformanceAttempts,
      'retainedCount': snapshots.length,
      'droppedOutsideWindow':
          dropped[_playbackPerformanceDroppedWindowKey] ?? 0,
      'droppedForCapacity':
          dropped[_playbackPerformanceDroppedCapacityKey] ?? 0,
      'dropCountScope': 'since-diagnostics-storage-created',
      if (snapshots.isNotEmpty) ...{
        'newestRetainedAt': snapshots.first['updatedAt'],
        'oldestRetainedAt': snapshots.last['updatedAt'],
      },
      'invalidSnapshotCount': invalidSnapshots,
      if (storageUnavailable) 'storageUnavailable': true,
    },
    'playbackPerformance': snapshots,
  };
}

/// Creates the local in-app notification inbox.
///
/// Actions are an allowlisted enum rather than arbitrary URLs so a corrupted
/// database row cannot turn a notification into an unsafe deep link.
Future<void> createAppNotificationsTable(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS app_notifications (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      action TEXT NOT NULL,
      target_version TEXT,
      target_version_code INTEGER,
      target_channel TEXT,
      created_at INTEGER NOT NULL,
      read_at INTEGER,
      CHECK(length(id) BETWEEN 1 AND 192),
      CHECK(kind IN ('app_update', 'announcement')),
      CHECK(length(title) BETWEEN 1 AND 256),
      CHECK(length(body) BETWEEN 1 AND 1000),
      CHECK(action IN ('open_app_updates', 'none')),
      CHECK(target_version IS NULL OR length(target_version) BETWEEN 1 AND 64),
      CHECK(target_version_code IS NULL OR target_version_code > 0),
      CHECK(target_channel IS NULL OR target_channel IN ('public', 'beta')),
      CHECK(created_at >= 0),
      CHECK(read_at IS NULL OR read_at >= 0)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS app_notifications_unread_created
    ON app_notifications(read_at, created_at DESC)
  ''');
}

Future<void> _upgradeAppNotificationsToV12(DatabaseExecutor db) async {
  await db.execute('DROP INDEX IF EXISTS app_notifications_unread_created');
  await db.execute(
    'ALTER TABLE app_notifications RENAME TO app_notifications_v11',
  );
  await createAppNotificationsTable(db);
  await db.execute('''
    INSERT INTO app_notifications (
      id, kind, title, body, action, target_version, target_version_code,
      target_channel, created_at, read_at
    )
    SELECT id, kind, title, body, action, target_version, target_version_code,
      target_channel, created_at, read_at
    FROM app_notifications_v11
  ''');
  await db.execute('DROP TABLE app_notifications_v11');
}

/// Creates the optional manga catalog, reading-progress, and offline
/// download tables.
///
/// Page URLs and request credentials are deliberately absent. A queued manga
/// chapter must rediscover its current page list through its source before a
/// transfer starts or resumes, so expiring URLs, cookies, and tokens never
/// become durable database capabilities.
Future<void> createMangaTables(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_sources (
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      updated_at INTEGER NOT NULL,
      CHECK(length(id) BETWEEN 1 AND 128),
      CHECK(length(url) BETWEEN 9 AND 2048),
      CHECK(lower(url) LIKE 'https://%'),
      CHECK(length(name) BETWEEN 1 AND 256),
      CHECK(length(kind) BETWEEN 1 AND 64),
      CHECK(enabled IN (0, 1)),
      CHECK(updated_at >= 0)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_source_cache (
      source_id TEXT PRIMARY KEY,
      payload_json TEXT NOT NULL,
      fetched_at INTEGER NOT NULL,
      FOREIGN KEY(source_id) REFERENCES manga_sources(id) ON DELETE CASCADE,
      CHECK(length(payload_json) BETWEEN 1 AND 2097152),
      CHECK(fetched_at >= 0)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_library_entries (
      owner_key TEXT NOT NULL,
      source_id TEXT NOT NULL,
      entry_id TEXT NOT NULL,
      title TEXT NOT NULL,
      metadata_json TEXT NOT NULL,
      cover_url TEXT,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY(owner_key, source_id, entry_id),
      CHECK(length(owner_key) BETWEEN 1 AND 128),
      CHECK(length(source_id) BETWEEN 1 AND 128),
      CHECK(length(entry_id) BETWEEN 1 AND 512),
      CHECK(length(title) BETWEEN 1 AND 1024),
      CHECK(length(metadata_json) BETWEEN 1 AND 1048576),
      CHECK(
        cover_url IS NULL OR (
          length(cover_url) BETWEEN 9 AND 2048 AND
          lower(cover_url) LIKE 'https://%'
        )
      ),
      CHECK(updated_at >= 0)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS manga_library_entries_updated
    ON manga_library_entries(owner_key, updated_at DESC)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_reading_progress (
      owner_key TEXT NOT NULL,
      source_id TEXT NOT NULL,
      entry_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      chapter_number REAL,
      page_index INTEGER NOT NULL DEFAULT 0,
      page_offset REAL NOT NULL DEFAULT 0,
      page_count INTEGER,
      completed INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY(owner_key, source_id, entry_id),
      CHECK(length(owner_key) BETWEEN 1 AND 128),
      CHECK(length(source_id) BETWEEN 1 AND 128),
      CHECK(length(entry_id) BETWEEN 1 AND 512),
      CHECK(length(chapter_id) BETWEEN 1 AND 512),
      CHECK(chapter_number IS NULL OR chapter_number >= 0),
      CHECK(page_index >= 0),
      CHECK(page_offset >= 0 AND page_offset <= 1),
      CHECK(page_count IS NULL OR (page_count > 0 AND page_count <= 1000)),
      CHECK(page_count IS NULL OR page_index < page_count),
      CHECK(completed IN (0, 1)),
      CHECK(updated_at >= 0)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS manga_reading_progress_updated
    ON manga_reading_progress(owner_key, updated_at DESC)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_reader_preferences (
      owner_key TEXT NOT NULL,
      scope_key TEXT NOT NULL,
      preferences_json TEXT NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY(owner_key, scope_key),
      CHECK(length(owner_key) BETWEEN 1 AND 128),
      CHECK(length(scope_key) BETWEEN 1 AND 128),
      CHECK(length(preferences_json) BETWEEN 1 AND 65536),
      CHECK(updated_at >= 0)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_download_jobs (
      id TEXT PRIMARY KEY,
      source_id TEXT NOT NULL,
      entry_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      series_title TEXT NOT NULL,
      chapter_label TEXT NOT NULL,
      status TEXT NOT NULL,
      relative_dir TEXT NOT NULL UNIQUE,
      page_count INTEGER,
      completed_pages INTEGER NOT NULL DEFAULT 0,
      received_bytes INTEGER NOT NULL DEFAULT 0,
      manifest_fingerprint TEXT,
      queue_position INTEGER NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      error_code TEXT,
      error_message TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      CHECK(length(id) BETWEEN 1 AND 128),
      CHECK(length(source_id) BETWEEN 1 AND 128),
      CHECK(length(entry_id) BETWEEN 1 AND 512),
      CHECK(length(chapter_id) BETWEEN 1 AND 512),
      CHECK(length(series_title) BETWEEN 1 AND 1024),
      CHECK(length(chapter_label) BETWEEN 1 AND 512),
      CHECK(length(relative_dir) BETWEEN 1 AND 1024),
      CHECK(page_count IS NULL OR (page_count > 0 AND page_count <= 1000)),
      CHECK(completed_pages >= 0),
      CHECK(page_count IS NULL OR completed_pages <= page_count),
      CHECK(received_bytes >= 0),
      CHECK(
        manifest_fingerprint IS NULL OR length(manifest_fingerprint) = 64
      ),
      CHECK(queue_position >= 0),
      CHECK(retry_count >= 0),
      CHECK(error_code IS NULL OR length(error_code) <= 128),
      CHECK(error_message IS NULL OR length(error_message) <= 1024),
      CHECK(created_at >= 0),
      CHECK(updated_at >= 0),
      CHECK(status IN (
        'queued', 'resolving', 'downloading', 'paused', 'completed',
        'failed', 'cancelled', 'needs_reauthorization'
      ))
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS manga_download_jobs_queue
    ON manga_download_jobs(status, queue_position, created_at)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS manga_download_jobs_entry
    ON manga_download_jobs(source_id, entry_id, chapter_id, updated_at DESC)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_download_pages (
      job_id TEXT NOT NULL,
      page_index INTEGER NOT NULL,
      stable_key_hash TEXT,
      relative_path TEXT NOT NULL UNIQUE,
      mime_type TEXT NOT NULL,
      byte_length INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      PRIMARY KEY(job_id, page_index),
      FOREIGN KEY(job_id) REFERENCES manga_download_jobs(id) ON DELETE CASCADE,
      CHECK(page_index >= 0 AND page_index < 1000),
      CHECK(stable_key_hash IS NULL OR length(stable_key_hash) = 64),
      CHECK(length(relative_path) BETWEEN 1 AND 1024),
      CHECK(length(mime_type) BETWEEN 1 AND 128),
      CHECK(byte_length > 0),
      CHECK(length(sha256) = 64)
    )
  ''');
  await _upgradeMangaLibraryTables(db);
}

/// Additive migration: the original latest-per-title row remains intact while
/// every recoverable legacy chapter is copied into durable chapter history.
Future<void> _upgradeMangaLibraryTables(DatabaseExecutor db) async {
  final columns = (await db.rawQuery(
    'PRAGMA table_info(manga_library_entries)',
  )).map((row) => row['name']).toSet();
  const additions = <String, String>{
    'category': "TEXT NOT NULL DEFAULT '' CHECK(length(category) <= 80)",
    'reading_status':
        "TEXT NOT NULL DEFAULT 'planToRead' CHECK(reading_status IN ('planToRead','reading','completed','onHold','dropped'))",
    'chapter_checked_at':
        'INTEGER CHECK(chapter_checked_at IS NULL OR chapter_checked_at >= 0)',
    'chapter_updated_at':
        'INTEGER CHECK(chapter_updated_at IS NULL OR chapter_updated_at >= 0)',
    'new_chapter_count':
        'INTEGER NOT NULL DEFAULT 0 CHECK(new_chapter_count >= 0)',
  };
  for (final entry in additions.entries) {
    if (!columns.contains(entry.key)) {
      await db.execute(
        'ALTER TABLE manga_library_entries ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_chapter_progress (
      owner_key TEXT NOT NULL,
      source_id TEXT NOT NULL,
      entry_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      chapter_number REAL,
      page_index INTEGER NOT NULL DEFAULT 0,
      page_offset REAL NOT NULL DEFAULT 0,
      page_count INTEGER,
      completed INTEGER NOT NULL DEFAULT 0,
      bookmarked INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY(owner_key, source_id, entry_id, chapter_id),
      CHECK(length(owner_key) BETWEEN 1 AND 128),
      CHECK(length(source_id) BETWEEN 1 AND 128),
      CHECK(length(entry_id) BETWEEN 1 AND 512),
      CHECK(length(chapter_id) BETWEEN 1 AND 512),
      CHECK(chapter_number IS NULL OR chapter_number >= 0),
      CHECK(page_index BETWEEN 0 AND 999),
      CHECK(page_offset BETWEEN 0 AND 1),
      CHECK(page_count IS NULL OR (page_count BETWEEN 1 AND 1000 AND page_index < page_count)),
      CHECK(completed IN (0,1)), CHECK(bookmarked IN (0,1)),
      CHECK(updated_at >= 0)
    )
  ''');
  await db.execute('''
    INSERT OR IGNORE INTO manga_chapter_progress
      (owner_key,source_id,entry_id,chapter_id,chapter_number,page_index,page_offset,page_count,completed,updated_at)
    SELECT owner_key,source_id,entry_id,chapter_id,chapter_number,page_index,page_offset,page_count,completed,updated_at
    FROM manga_reading_progress
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS manga_chapter_progress_updated
    ON manga_chapter_progress(owner_key, updated_at DESC)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS manga_chapter_snapshots (
      owner_key TEXT NOT NULL,
      source_id TEXT NOT NULL,
      entry_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      title TEXT NOT NULL,
      chapter_number REAL,
      ordinal INTEGER NOT NULL,
      published_at INTEGER,
      first_seen_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL,
      available INTEGER NOT NULL DEFAULT 1,
      is_new INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(owner_key,source_id,entry_id,chapter_id),
      CHECK(length(owner_key) BETWEEN 1 AND 128),
      CHECK(length(source_id) BETWEEN 1 AND 128),
      CHECK(length(entry_id) BETWEEN 1 AND 512),
      CHECK(length(chapter_id) BETWEEN 1 AND 512),
      CHECK(length(title) BETWEEN 1 AND 512),
      CHECK(chapter_number IS NULL OR chapter_number >= 0),
      CHECK(ordinal BETWEEN 0 AND 99999),
      CHECK(published_at IS NULL OR published_at >= 0),
      CHECK(first_seen_at >= 0 AND last_seen_at >= 0),
      CHECK(available IN (0,1)), CHECK(is_new IN (0,1))
    )
  ''');
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
  // A direct/Web fallback frequently changes its privacy-sensitive stream
  // identity while preserving the same technical failure. Group by the safe
  // reason at export time so a run of identical failures is visible as one
  // useful counter instead of many indistinguishable `count: 1` rows.
  final failures = await database.rawQuery(
    '''
      SELECT COALESCE(reason, '') AS reason,
             SUM(failure_count) AS failure_count,
             COUNT(*) AS failure_record_count,
             MAX(last_failed_at) AS last_failed_at
      FROM stream_failures
      WHERE last_failed_at >= ? AND last_failed_at <= ?
      GROUP BY COALESCE(reason, '')
      ORDER BY last_failed_at DESC LIMIT ?
    ''',
    [...arguments, failureCapacity],
  );
  final failureCount = Sqflite.firstIntValue(
    await database.rawQuery('''
        SELECT COUNT(DISTINCT COALESCE(reason, '')) FROM stream_failures
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
          'failureRecordCount':
              (row['failure_record_count'] as num?)?.toInt() ?? 0,
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
    'recentFrameTimingMeaning': {
      'metric': 'flutter_frame_timing_total_span',
      'scope': 'flutter_ui_not_video',
      'thresholdMsExclusive': 20,
      'selection': 'slowest_pending_callback_sample',
      'minimumSampleIntervalMs': 5000,
      'includesAllFrames': false,
    },
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
      resource_base_url TEXT,
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
  final safeComponent = redactDiagnosticValue(component, maximum: 48);
  await database.insert('diagnostic_events', {
    'category': safeComponent,
    'severity': _safeDiagnosticSeverity(
      severity ?? _defaultDiagnosticSeverity(component),
    ),
    'message': redactDiagnosticValue(message.toString(), maximum: 500),
    'details_json': context == null
        ? null
        : jsonEncode(
            sanitizeDiagnosticContext(context, component: safeComponent),
          ),
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
    INSERT OR REPLACE INTO diagnostic_metadata (key, value)
    SELECT ?, ? + COALESCE(
      (SELECT value FROM diagnostic_metadata WHERE key = ?), 0
    )
  ''',
  [key, amount, key],
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
        'context': _decodeLegacyDiagnosticContext(
          encoded,
          component: row['category']?.toString(),
        ),
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

Object? _decodeLegacyDiagnosticContext(String value, {String? component}) {
  try {
    return sanitizeDiagnosticContext(jsonDecode(value), component: component);
  } catch (_) {
    return sanitizeDiagnosticContext(value, component: component);
  }
}

/// Produces small, JSON-safe context while removing identity and playback
/// material. Event context is technical metadata, never a content dump.
Object? sanitizeDiagnosticContext(
  Object? value, {
  int depth = 0,
  String? component,
}) {
  if (depth == 0 && _isAniyomiDiagnosticComponent(component)) {
    return _sanitizeAniyomiDiagnosticContext(value);
  }
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
      final normalizedKey = _normalizeDiagnosticContextKey(rawKey);
      if (_externalAudioDiagnosticCountKeys.contains(normalizedKey)) {
        final count = entry.value;
        if (count is! num ||
            !count.isFinite ||
            count < 0 ||
            count != count.toInt()) {
          redactedFields++;
          continue;
        }
        output[key] = count.toInt().clamp(0, 64);
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

bool _isAniyomiDiagnosticComponent(String? value) =>
    value?.trim().toLowerCase() == 'aniyomi-runtime';

const _aniyomiBooleanDiagnosticKeys = <String>{
  'search_http_request_limit_hit',
  'episode_http_request_limit_hit',
  'video_http_request_limit_hit',
  'available',
  'developer_mode_enabled',
  'isolated_process',
  'universal_compatibility',
  'supports_current_hoster_flow',
  'supports_lazy_video_resolution',
  'supports_lazy_hoster_deferral',
  'supports_manga_image_request_resolution',
  'supports_opaque_manga_image_fetch',
  'supports_ephemeral_cookies',
  'supports_redirects',
  'supports_source_preferences',
  'supports_javascript_evaluation',
  'supports_host_owned_hls_bridge',
  'supports_web_view',
  'supports_native_libraries',
};

const _aniyomiCapabilityKeys = <String>{
  'current_hoster_flow',
  'lazy_video_resolution',
  'lazy_hoster_deferral',
  'manga_image_request_resolution',
  'opaque_manga_image_fetch',
  'ephemeral_cookies',
  'redirects',
  'source_preferences',
  'javascript_evaluation',
  'host_owned_hls_bridge',
  'web_view',
  'native_libraries',
};

const _aniyomiResultLimitMaximums = <String, int>{
  'reply_bytes': 4 * 1024 * 1024,
  'http_body_bytes': 4 * 1024 * 1024,
  'http_metadata_bytes': 16 * 1024,
  'sources': 256,
  'search_items': 1000,
  'episodes_or_chapters': 100000,
  'targeted_episode_candidates': 4096,
  'pages': 10000,
  'image_capability_count': 4096,
  'image_capability_ttl_seconds': 86400,
  'image_bytes': 64 * 1024 * 1024,
  'image_concurrent_requests': 16,
  'videos': 512,
  'tracks_per_video': 256,
  'hosters': 1024,
  'lazy_hosters_per_request': 64,
};

const _aniyomiCountMaximums = <String, int>{
  'search_http_request_count': 16,
  'search_http_request_limit': 16,
  'search_http_failure_count': 64,
  'episode_http_request_count': 16,
  'episode_http_request_limit': 16,
  'episode_http_failure_count': 64,
  'video_http_request_count': 16,
  'video_http_request_limit': 16,
  'video_http_failure_count': 64,
  'extension_version_code': 0x7fffffff,
  'minimum_android_api': 100,
  'worker_capacity': 64,
  'queued_count': 1000,
  'active_count': 1000,
  'queue_wait_ms': 60000,
  'execution_ms': 60000,
  'total_ms': 60000,
  'elapsed_ms': 60000,
  'broker_redirect_count': 3,
  'count': 100000,
  'title_alias_count': 100000,
  'search_query_count': 100000,
  'search_result_count': 100000,
  'exact_title_match_count': 100000,
  'episode_count': 100000,
  'exact_episode_match_count': 100000,
  'episode_label_fallback_count': 100000,
  'details_metadata_mismatch_count': 100000,
  'raw_video_count': 100000,
  'playable_video_count': 100000,
  'rejected_unsupported_playback_count': 100000,
  'ignored_external_audio_count': 100000,
  'external_audio_track_count': 100000,
  'rejected_external_audio_count': 100000,
  'rejected_invalid_media_url_count': 100000,
  'rejected_unsafe_media_target_count': 100000,
  'search_original_count': 100000,
  'search_returned_count': 100000,
  'search_filtered_count': 100000,
  'search_truncated_count': 100000,
  'search_discarded_count': 100000,
  'episode_original_count': 100000,
  'episode_returned_count': 100000,
  'episode_filtered_count': 100000,
  'episode_truncated_count': 100000,
  'episode_discarded_count': 100000,
  'video_original_count': 262144,
  'video_returned_count': 100000,
  'video_filtered_count': 100000,
  'video_truncated_count': 262144,
  'video_discarded_count': 262144,
  'video_original_hoster_count': 100000,
  'video_visited_hoster_count': 100000,
  'video_lazy_hoster_count': 100000,
  'video_attempted_lazy_hoster_count': 100000,
  'video_resolved_lazy_hoster_count': 100000,
  'video_failed_lazy_hoster_count': 100000,
  'video_deferred_hoster_count': 100000,
  'video_discarded_hoster_count': 100000,
  'video_truncated_hoster_count': 100000,
  'video_discarded_track_count': 100000,
  'video_local_hls_bridge_count': 32,
};

const _aniyomiTokenDiagnosticKeys = <String>{
  'event',
  'status',
  'kind',
  'outcome',
  'code',
  'stage',
  'reason_code',
  'native_code',
  'native_stage',
  'native_reason_code',
};

final _omitAniyomiDiagnosticValue = Object();

/// Closed-schema projection for Aniyomi runtime evidence. This deliberately
/// excludes titles, search terms, URLs, headers, cookies, source IDs, and all
/// account/media values. Package names are public extension identities and
/// remain local until the user explicitly exports a diagnostic report.
Object? _sanitizeAniyomiDiagnosticContext(Object? value) {
  if (value is! Map) {
    return const <String, Object?>{'_redactedFieldCount': 1};
  }
  final output = <String, Object?>{};
  var redacted =
      _boundedAniyomiDiagnosticInteger(value['_redactedFieldCount'], 100000) ??
      0;
  var truncated =
      _boundedAniyomiDiagnosticInteger(value['_truncatedFieldCount'], 100000) ??
      0;
  var scanned = 0;
  for (final entry in value.entries) {
    if (scanned >= 100) {
      truncated += value.length - scanned;
      break;
    }
    scanned++;
    final key = _normalizeAniyomiDiagnosticKey(entry.key.toString());
    if (key == 'redacted_field_count' || key == 'truncated_field_count') {
      continue;
    }
    if (output.length >= 80) {
      truncated++;
      continue;
    }
    final safe = _sanitizeAniyomiDiagnosticField(key, entry.value);
    if (identical(safe, _omitAniyomiDiagnosticValue)) {
      redacted++;
      continue;
    }
    output[key] = safe;
  }
  if (redacted > 0) {
    output['_redactedFieldCount'] = redacted.clamp(0, 100000);
  }
  if (truncated > 0) {
    output['_truncatedFieldCount'] = truncated.clamp(0, 100000);
  }
  return output;
}

Object? _sanitizeAniyomiDiagnosticField(String key, Object? value) {
  if (key == 'extension_package') {
    if (value == 'unknown') return value;
    if (value is String &&
        value.length <= 160 &&
        RegExp(
          r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$',
        ).hasMatch(value)) {
      return value;
    }
    return _omitAniyomiDiagnosticValue;
  }
  if (key == 'api_version') {
    return const {'14', '16', '1.4', '1.5', 'unknown'}.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'extension_version') {
    return value is String &&
            (value == 'unknown' ||
                RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$').hasMatch(value))
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'source_language') {
    if (value == 'unknown') return value;
    if (value is! String) return _omitAniyomiDiagnosticValue;
    final normalized = value.trim().toLowerCase();
    return RegExp(r'^[a-z]{2,3}(?:-[a-z]{2})?$').hasMatch(normalized)
        ? normalized
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'runtime_revision') {
    return value is String &&
            (value == 'unknown' ||
                RegExp(r'^[a-z0-9._-]{1,80}$').hasMatch(value))
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'runtime') {
    return const {'experimental_http_subset', 'unknown'}.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'operation') {
    return const {
          'sources',
          'search',
          'details',
          'seasons',
          'chapters',
          'episodes',
          'pages',
          'videos',
          'unknown',
        }.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'broker_failure') {
    return const {'policy', 'network', 'unsupported', 'invalid'}.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'broker_reason') {
    return const {
          'client_configuration',
          'client_websocket',
          'client_chain',
          'client_network_interceptor',
          'client_proxy',
          'client_cache',
          'credential_header',
          'request_method',
          'request_headers',
          'request_body',
          'transport_mutation',
          'direct_network',
          'request_envelope',
          'http_method_unsupported',
          'get_body_unsupported',
          'http_request_too_large',
          'http_headers_too_large',
          'http_header_not_permitted',
          'unsupported_http_field',
          'http_request_limit',
          'invalid_http_option',
          'http_redirect_unsupported',
          'http_redirect_limit',
          'http_response_too_large',
        }.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (const {
    'search_http_last_failure',
    'episode_http_last_failure',
    'video_http_last_failure',
  }.contains(key)) {
    return const {
          'none',
          'policy',
          'network',
          'unsupported',
          'invalid',
        }.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'broker_response_size_bucket') {
    return const {
          'none',
          'lt64k',
          '64to128k',
          '128to256k',
          'over256k',
        }.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (key == 'broker_status_class') {
    return const {'none', '1xx', '2xx', '3xx', '4xx', '5xx'}.contains(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (_aniyomiTokenDiagnosticKeys.contains(key)) {
    return value is String && RegExp(r'^[a-z][a-z0-9_]{0,79}$').hasMatch(value)
        ? value
        : _omitAniyomiDiagnosticValue;
  }
  if (_aniyomiBooleanDiagnosticKeys.contains(key)) {
    return value is bool ? value : _omitAniyomiDiagnosticValue;
  }
  if (key == 'anime_api_versions' || key == 'manga_api_versions') {
    if (value is! List || value.length > 8) return _omitAniyomiDiagnosticValue;
    final allowed = key == 'anime_api_versions'
        ? const {'14', '16'}
        : const {'1.4', '1.5'};
    if (value.any((item) => item is! String || !allowed.contains(item))) {
      return _omitAniyomiDiagnosticValue;
    }
    return List<String>.unmodifiable(value.cast<String>());
  }
  if (key == 'capabilities') {
    return _sanitizeAniyomiBooleanMap(value, _aniyomiCapabilityKeys);
  }
  if (key == 'result_limits') {
    return _sanitizeAniyomiIntegerMap(value, _aniyomiResultLimitMaximums);
  }
  final maximum = _aniyomiCountMaximums[key];
  if (maximum != null) {
    return _boundedAniyomiDiagnosticInteger(value, maximum) ??
        _omitAniyomiDiagnosticValue;
  }
  return _omitAniyomiDiagnosticValue;
}

Object _sanitizeAniyomiBooleanMap(Object? value, Set<String> allowedKeys) {
  if (value is! Map) return _omitAniyomiDiagnosticValue;
  final result = <String, bool>{};
  for (final entry in value.entries.take(24)) {
    final key = _normalizeAniyomiDiagnosticKey(entry.key.toString());
    if (allowedKeys.contains(key) && entry.value is bool) {
      result[key] = entry.value as bool;
    }
  }
  return result;
}

Object _sanitizeAniyomiIntegerMap(Object? value, Map<String, int> maximums) {
  if (value is! Map) return _omitAniyomiDiagnosticValue;
  final result = <String, int>{};
  for (final entry in value.entries.take(24)) {
    final key = _normalizeAniyomiDiagnosticKey(entry.key.toString());
    final maximum = maximums[key];
    final safe = maximum == null
        ? null
        : _boundedAniyomiDiagnosticInteger(entry.value, maximum);
    if (safe != null) result[key] = safe;
  }
  return result;
}

int? _boundedAniyomiDiagnosticInteger(Object? value, int maximum) {
  if (value is! num || !value.isFinite || value < 0 || value > maximum) {
    return null;
  }
  final integer = value.toInt();
  return value == integer ? integer : null;
}

String _normalizeAniyomiDiagnosticKey(String value) => value
    .trim()
    .replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (match) => '${match[1]}_${match[2]}',
    )
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

String _normalizeDiagnosticContextKey(String key) => key
    .replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (match) => '${match[1]}_${match[2]}',
    )
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

const _externalAudioDiagnosticCountKeys = <String>{
  'requested_count',
  'attached_count',
  'failed_count',
  'stale_count',
  'preflight_rejected_count',
};

bool _isSafeDiagnosticContextKey(String key) {
  final normalized = _normalizeDiagnosticContextKey(key);
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
    'requested_count',
    'attached_count',
    'failed_count',
    'stale_count',
    'preflight_rejected_count',
    'subtitle_mode',
    'catalog_mapping_available',
    'embedded_marker_count',
    'community_marker_count',
    'community_status',
    'community_status_class',
    'community_lookup_source',
    'community_failure_reason',
    'community_transient_failure_count',
    'community_probe_count',
    'duration_fallback_used',
    'requested_duration_ms',
    'current_duration_ms',
    'segment_kind',
    'marker_source',
    'automatic',
    'seek_succeeded',
    'seek_verified',
    'seek_attempts',
    'watch_party_active',
    'guest_controls_locked',
    'controls_visible',
    'marker_count',
    'matching_marker_count',
    'marker_start_ms',
    'marker_end_ms',
    'target_ms',
    'post_seek_position_ms',
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
