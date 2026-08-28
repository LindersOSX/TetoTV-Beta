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
}

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
