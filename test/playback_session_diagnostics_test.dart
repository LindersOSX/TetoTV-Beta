import 'package:anime_tv/core/diagnostics/playback_diagnostic_recorder.dart';
import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/player/presentation/player_failover_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('codec and frame-drop errors map to fixed correlation codes', () {
    expect(
      playbackDiagnosticFailureReasonCode('Could not open codec.'),
      'codec_open_failed',
    );
    expect(
      playbackDiagnosticFailureReasonCode(
        'This stream is dropping too many frames on this device.',
      ),
      'frame_drops',
    );
    expect(
      playbackDiagnosticFailureReasonCode(
        'https://private.example/Private Episode.mkv?token=secret',
      ),
      'playback_error',
    );
    expect(
      playbackDiagnosticFailureReasonCode(
        const PlayerMediaReadinessException(),
      ),
      'no_video_frames',
    );
    expect(
      playbackDiagnosticFailureReasonCode(
        'This source identifies a different episode.',
      ),
      'episode_identity_mismatch',
    );
  });

  test(
    'legacy startup outcomes stay compatible and do not imply smoothness',
    () {
      final derived = derivePlaybackSessionDiagnostics([
        _playbackEvent(
          timestamp: DateTime.utc(2026, 9, 4, 12),
          sessionId: 'pbs-workingSession1234',
          sequence: 1,
          stage: 'final_outcome',
          status: 'working',
        ),
        _playbackEvent(
          timestamp: DateTime.utc(2026, 9, 4, 13),
          sessionId: 'pbs-exitedSession12345',
          sequence: 1,
          stage: 'final_outcome',
          status: 'exited_after_start',
        ),
      ]);
      final sessions = (derived['playbackSessions']! as List).cast<Map>();
      final comparison = derived['playbackSessionComparison']! as Map;
      final meanings = derived['playbackSessionOutcomeMeaning']! as Map;

      expect(sessions.map((session) => session['finalOutcome']), [
        'exited_after_start',
        'working',
      ]);
      expect(
        (comparison['working'] as Map)['finalOutcome'],
        'exited_after_start',
      );
      expect(
        meanings['working'],
        contains('does not establish smooth playback'),
      );
      expect(
        meanings['exited_after_start'],
        contains('does not establish smooth playback'),
      );
      expect(
        meanings['startupSignal'],
        contains('not a rendered-frame callback'),
      );
      expect(meanings['startupSignal'], contains('decoded_video_observed'));
      expect(meanings['startupSignal'], contains('video_parameters_available'));
      expect(
        meanings['comparisonWorking'],
        contains('not a known-smooth control'),
      );
      expect(meanings['smoothnessEvidence'], contains('sessionId and attempt'));
    },
  );

  test(
    'persisted playback stages produce working vs failed comparison',
    () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await _createDiagnosticTables(database);
      final store = TetoTvDatabase.forTesting(database);
      var now = DateTime.utc(2026, 8, 23, 12);
      final working = PlaybackDiagnosticSessionRecorder(
        database: store,
        sessionId: 'pbs-workingSession1234',
        clock: () => now,
      );
      await working.sourceSelected(
        sourceKind: PlaybackDiagnosticSourceKind.web,
        quality: '1080p',
        automatic: true,
        seekable: true,
        requestedAudio: PlaybackDiagnosticAudioIntent.dub,
        sourceAudioCapability: PlaybackDiagnosticAudioCapability.multi,
        audioPreferenceSource:
            PlaybackDiagnosticAudioPreferenceSource.pickerSelection,
      );
      now = now.add(const Duration(milliseconds: 40));
      await working.decoderSelected(
        decoder: PlaybackDiagnosticDecoder.hardwareAdaptive,
        automatic: true,
        codec: 'h264',
      );
      now = now.add(const Duration(milliseconds: 60));
      await working.streamOpened(
        sourceKind: PlaybackDiagnosticSourceKind.web,
        succeeded: true,
      );
      now = now.add(const Duration(milliseconds: 20));
      await working.audioTrackSelected(
        requestedAudio: PlaybackDiagnosticAudioIntent.dub,
        selectedAudioLanguage: PlaybackDiagnosticAudioLanguage.english,
        audioPreferenceSource:
            PlaybackDiagnosticAudioPreferenceSource.pickerSelection,
        audioTrackCount: 2,
        preferenceMatched: true,
      );
      now = now.add(const Duration(seconds: 2));
      await working.finalOutcome(
        outcome: PlaybackDiagnosticOutcome.working,
        position: const Duration(seconds: 2),
        duration: const Duration(minutes: 24),
      );

      now = now.add(const Duration(minutes: 5));
      final failed = PlaybackDiagnosticSessionRecorder(
        database: store,
        sessionId: 'pbs-failedSession12345',
        clock: () => now,
      );
      await failed.sourceSelected(
        sourceKind: PlaybackDiagnosticSourceKind.torrent,
        quality: '4k',
      );
      now = now.add(const Duration(milliseconds: 20));
      await failed.decoderSelected(
        decoder: PlaybackDiagnosticDecoder.hardwareDirect,
        automatic: false,
        codec: 'hevc',
      );
      now = now.add(const Duration(seconds: 8));
      await failed.streamOpened(
        sourceKind: PlaybackDiagnosticSourceKind.torrent,
        succeeded: false,
        reasonCode: 'codec_open_failed',
      );
      now = now.add(const Duration(milliseconds: 5));
      await failed.audioTrackSelected(
        requestedAudio: PlaybackDiagnosticAudioIntent.sub,
        selectedAudioLanguage: PlaybackDiagnosticAudioLanguage.japanese,
        audioPreferenceSource:
            PlaybackDiagnosticAudioPreferenceSource.pickerSelection,
        audioTrackCount: 2,
        preferenceMatched: true,
      );
      now = now.add(const Duration(milliseconds: 10));
      await failed.fallbackAttempted(
        fallbackKind: PlaybackDiagnosticFallbackKind.decoder,
        decoder: PlaybackDiagnosticDecoder.softwareCompatibility,
        codec: 'hevc',
        reasonCode: 'codec_open_failed',
      );
      now = now.add(const Duration(seconds: 1));
      await failed.finalOutcome(
        outcome: PlaybackDiagnosticOutcome.failed,
        reasonCode: 'all_fallbacks_failed',
      );

      final history = await loadDiagnosticEventHistory(database, now: now);
      final derived = derivePlaybackSessionDiagnostics(
        history['diagnosticEvents'],
      );
      final sessions = derived['playbackSessions']! as List;
      final comparison = derived['playbackSessionComparison']! as Map;

      expect(derived['playbackSessionSchema'], playbackSessionDiagnosticSchema);
      expect(sessions, hasLength(2));
      expect(comparison['available'], isTrue);
      expect((comparison['working'] as Map)['sourceKind'], 'web');
      expect((comparison['working'] as Map)['codec'], 'h264');
      expect((comparison['working'] as Map)['requestedAudio'], 'dub');
      expect((comparison['working'] as Map)['sourceAudioMode'], 'multi');
      expect(
        (comparison['working'] as Map)['selectedAudioLanguage'],
        'english',
      );
      expect((comparison['working'] as Map)['audioPreferenceMatched'], isTrue);
      expect((comparison['failed'] as Map)['sourceKind'], 'torrent');
      expect((comparison['failed'] as Map)['codec'], 'hevc');
      expect((comparison['failed'] as Map)['fallbackAttempts'], 1);
      expect(
        (comparison['failed'] as Map)['finalReasonCode'],
        'all_fallbacks_failed',
      );
      expect((comparison['differences'] as Map)['codecChanged'], isTrue);
      expect(
        ((sessions.first as Map)['timeline'] as List).map(
          (event) => (event as Map)['stage'],
        ),
        [
          'source_selected',
          'decoder_selected',
          'stream_opened',
          'audio_track_selected',
          'fallback_attempted',
          'final_outcome',
        ],
      );
    },
  );

  test(
    'recorder drops free-form values instead of storing media identity',
    () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(database.close);
      await _createDiagnosticTables(database);
      final store = TetoTvDatabase.forTesting(database);
      final now = DateTime.utc(2026, 8, 23, 14);
      final recorder = PlaybackDiagnosticSessionRecorder(
        database: store,
        sessionId: 'pbs-privateSafeSession',
        clock: () => now,
      );

      await recorder.sourceSelected(
        sourceKind: PlaybackDiagnosticSourceKind.plex,
        quality: 'Private Show 01.mkv',
      );
      await recorder.decoderSelected(
        decoder: PlaybackDiagnosticDecoder.hardwareAdaptive,
        automatic: true,
        codec: 'https://private.example/media/file.mkv',
        reasonCode: r'C:\Private\Show.mkv',
      );
      await recorder.finalOutcome(
        outcome: PlaybackDiagnosticOutcome.failed,
        reasonCode: 'Bearer private-token',
      );

      final history = await loadDiagnosticEventHistory(database, now: now);
      final encoded = history.toString();
      expect(encoded, isNot(contains('Private Show')));
      expect(encoded, isNot(contains('private.example')));
      expect(encoded, isNot(contains('private-token')));
      final contexts = (history['diagnosticEvents']! as List)
          .map((event) => (event as Map)['context'] as Map)
          .toList(growable: false);
      expect(contexts.first, isNot(contains('quality')));
      expect(contexts[1], isNot(contains('codec')));
      expect(contexts[1], isNot(contains('reason_code')));
      expect(contexts.last, isNot(contains('reason_code')));
    },
  );

  test('orphaned sessions are classified after supersession or a crash', () {
    final first = DateTime.utc(2026, 8, 30, 4, 34);
    final second = first.add(const Duration(minutes: 1));
    final third = second.add(const Duration(minutes: 1));
    final events = <Map<String, Object?>>[
      _playbackEvent(
        timestamp: first,
        sessionId: 'pbs-orphanedSession123',
        sequence: 1,
        stage: 'source_selected',
        status: 'selected_by_user',
      ),
      _playbackEvent(
        timestamp: second,
        sessionId: 'pbs-workingSession5678',
        sequence: 1,
        stage: 'source_selected',
        status: 'selected_by_user',
      ),
      _playbackEvent(
        timestamp: second.add(const Duration(seconds: 1)),
        sessionId: 'pbs-workingSession5678',
        sequence: 2,
        stage: 'final_outcome',
        status: 'working',
      ),
      _playbackEvent(
        timestamp: third,
        sessionId: 'pbs-crashedSession9012',
        sequence: 1,
        stage: 'fallback_attempted',
        status: 'attempted',
      ),
    ];

    final derived = derivePlaybackSessionDiagnostics(
      events,
      interruptions: [
        PlaybackDiagnosticInterruption(
          timestamp: third.add(const Duration(milliseconds: 100)),
          reasonCode: 'native_crash',
        ),
      ],
    );
    final sessions = (derived['playbackSessions']! as List).cast<Map>();
    final orphaned = sessions.singleWhere(
      (session) => session['sessionId'] == 'pbs-orphanedSession123',
    );
    final crashed = sessions.singleWhere(
      (session) => session['sessionId'] == 'pbs-crashedSession9012',
    );

    expect(orphaned['finalOutcome'], 'failed');
    expect(orphaned['finalReasonCode'], 'session_superseded');
    expect(crashed['finalOutcome'], 'failed');
    expect(crashed['finalReasonCode'], 'native_crash');
    expect((derived['playbackSessionComparison'] as Map)['available'], isTrue);
  });

  test('crash correlation preserves the platform failure kind', () {
    final startedAt = DateTime.utc(2026, 8, 30, 4, 36);
    final derived = derivePlaybackSessionDiagnostics(
      [
        _playbackEvent(
          timestamp: startedAt,
          sessionId: 'pbs-javaCrashSession12',
          sequence: 1,
          stage: 'source_selected',
          status: 'selected_by_user',
        ),
      ],
      interruptions: [
        PlaybackDiagnosticInterruption(
          timestamp: startedAt.add(const Duration(seconds: 1)),
          reasonCode: 'java_crash',
        ),
      ],
    );

    final session = ((derived['playbackSessions']! as List).single as Map);
    expect(session['finalOutcome'], 'failed');
    expect(session['finalReasonCode'], 'java_crash');
  });
}

Map<String, Object?> _playbackEvent({
  required DateTime timestamp,
  required String sessionId,
  required int sequence,
  required String stage,
  required String status,
}) => {
  'timestamp': timestamp.toUtc().toIso8601String(),
  'component': playbackSessionDiagnosticComponent,
  'severity': 'info',
  'message': 'Playback session event',
  'context': {
    'session_id': sessionId,
    'sequence': sequence,
    'stage': stage,
    'status': status,
  },
};

Future<void> _createDiagnosticTables(Database database) async {
  await database.execute('''
    CREATE TABLE diagnostic_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      category TEXT NOT NULL,
      severity TEXT NOT NULL DEFAULT 'info',
      message TEXT NOT NULL,
      details_json TEXT,
      created_at INTEGER NOT NULL
    )
  ''');
  await database.execute('''
    CREATE TABLE diagnostic_metadata (
      key TEXT PRIMARY KEY,
      value INTEGER NOT NULL DEFAULT 0
    )
  ''');
}
