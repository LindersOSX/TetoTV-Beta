import 'package:anime_tv/core/diagnostics/playback_session_diagnostics.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/player/application/playback_audio_diagnostics.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  const unknown = ReleaseCandidate(
    infoHash: 'unknown',
    magnetUri: '',
    releaseName: 'Provider stream',
    seeders: 0,
    sourceId: 'web:provider',
  );
  const sub = ReleaseCandidate(
    infoHash: 'sub',
    magnetUri: '',
    releaseName: 'Provider stream',
    seeders: 0,
    sourceId: 'web:provider',
    audioIntent: ReleaseAudioIntent.sub,
  );
  const dub = ReleaseCandidate(
    infoHash: 'dub',
    magnetUri: '',
    releaseName: 'Provider stream',
    seeders: 0,
    sourceId: 'web:provider',
    audioIntent: ReleaseAudioIntent.dub,
  );
  const multi = ReleaseCandidate(
    infoHash: 'multi',
    magnetUri: '',
    releaseName: 'Provider stream',
    seeders: 0,
    sourceId: 'web:provider',
    audioIntent: ReleaseAudioIntent.multi,
  );

  test('maps only privacy-safe requested audio values', () {
    expect(
      playbackDiagnosticAudioIntent(PlaybackAudioPreference.sub),
      PlaybackDiagnosticAudioIntent.sub,
    );
    expect(
      playbackDiagnosticAudioIntent(PlaybackAudioPreference.dub),
      PlaybackDiagnosticAudioIntent.dub,
    );
    expect(
      playbackDiagnosticAudioIntent(null),
      PlaybackDiagnosticAudioIntent.unknown,
    );
  });

  test('reports source capability without recording its label', () {
    expect(
      playbackDiagnosticAudioCapability(sub),
      PlaybackDiagnosticAudioCapability.sub,
    );
    expect(
      playbackDiagnosticAudioCapability(dub),
      PlaybackDiagnosticAudioCapability.dub,
    );
    expect(
      playbackDiagnosticAudioCapability(multi),
      PlaybackDiagnosticAudioCapability.multi,
    );
    expect(
      playbackDiagnosticAudioCapability(unknown),
      PlaybackDiagnosticAudioCapability.unknown,
    );
    expect(
      playbackDiagnosticAudioCapability(
        const ReleaseCandidate(
          infoHash: 'legacy-multi',
          magnetUri: '',
          releaseName: 'Release [Dual-Audio]',
          seeders: 0,
          sourceId: 'manifest',
        ),
      ),
      PlaybackDiagnosticAudioCapability.multi,
    );
  });

  test('reports the same preference precedence used by playback', () {
    expect(
      playbackDiagnosticAudioPreferenceSource(
        release: dub,
        seriesOverride: true,
        requestedAudio: PlaybackAudioPreference.sub,
      ),
      PlaybackDiagnosticAudioPreferenceSource.seriesOverride,
    );
    expect(
      playbackDiagnosticAudioPreferenceSource(
        release: dub,
        seriesOverride: false,
        requestedAudio: PlaybackAudioPreference.sub,
      ),
      PlaybackDiagnosticAudioPreferenceSource.pickerSelection,
    );
    expect(
      playbackDiagnosticAudioPreferenceSource(
        release: dub,
        seriesOverride: false,
        requestedAudio: null,
      ),
      PlaybackDiagnosticAudioPreferenceSource.sourceLabel,
    );
    expect(
      playbackDiagnosticAudioPreferenceSource(
        release: unknown,
        seriesOverride: false,
        requestedAudio: null,
      ),
      PlaybackDiagnosticAudioPreferenceSource.globalPreference,
    );
  });

  test('reduces selected tracks to safe language buckets and a count', () {
    const tracks = [
      AudioTrack('auto', null, null),
      AudioTrack('1', 'English Dub', 'eng'),
      AudioTrack('2', 'Japanese', 'jpn'),
      AudioTrack('3', 'Castellano', 'spa'),
      AudioTrack('4', null, null),
      AudioTrack('no', null, null),
    ];

    expect(
      playbackDiagnosticAudioLanguage(tracks[1]),
      PlaybackDiagnosticAudioLanguage.english,
    );
    expect(
      playbackDiagnosticAudioLanguage(tracks[2]),
      PlaybackDiagnosticAudioLanguage.japanese,
    );
    expect(
      playbackDiagnosticAudioLanguage(tracks[3]),
      PlaybackDiagnosticAudioLanguage.other,
    );
    expect(
      playbackDiagnosticAudioLanguage(tracks[4]),
      PlaybackDiagnosticAudioLanguage.unknown,
    );
    expect(playbackDiagnosticAudioTrackCount(tracks), 4);
  });

  test('deduplicates one snapshot but retains meaningful changes', () {
    final gate = PlaybackAudioDiagnosticEventGate();
    const english = AudioTrack('1', 'English', 'eng');
    const japanese = AudioTrack('2', 'Japanese', 'jpn');

    expect(
      gate.shouldRecord(
        mediaRevision: 1,
        track: english,
        preferenceMatched: false,
      ),
      isTrue,
    );
    expect(
      gate.shouldRecord(
        mediaRevision: 1,
        track: english,
        preferenceMatched: false,
      ),
      isFalse,
    );
    expect(
      gate.shouldRecord(
        mediaRevision: 1,
        track: english,
        preferenceMatched: true,
      ),
      isTrue,
    );
    expect(
      gate.shouldRecord(
        mediaRevision: 1,
        track: japanese,
        preferenceMatched: true,
      ),
      isTrue,
    );
    expect(
      gate.shouldRecord(
        mediaRevision: 2,
        track: japanese,
        preferenceMatched: true,
      ),
      isTrue,
    );
  });
}
