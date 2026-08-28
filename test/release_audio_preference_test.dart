import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dual-audio labels satisfy dub when an adapter omits isDubbed', () {
    const release = ReleaseCandidate(
      infoHash: '0123456789012345678901234567890123456789',
      magnetUri: 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      releaseName: '[Third Party] Example S01E01 Dual Audio 1080p',
      seeders: 10,
      sourceId: 'third-party',
    );

    expect(release.isDubbed, isFalse);
    expect(releaseAdvertisesDualAudio(release), isTrue);
    expect(
      releaseSupportsAudioPreference(release, PlaybackAudioPreference.dub),
      isTrue,
    );
    expect(releaseAudioPreferenceRank(release, PlaybackAudioPreference.dub), 0);
  });

  test('single-audio sub releases still do not satisfy dub', () {
    const release = ReleaseCandidate(
      infoHash: 'abcdef0123456789abcdef0123456789abcdef01',
      magnetUri: 'magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01',
      releaseName: '[Sub Group] Example S01E01 1080p',
      seeders: 10,
      sourceId: 'sub-source',
    );

    expect(
      releaseSupportsAudioPreference(release, PlaybackAudioPreference.dub),
      isFalse,
    );
    expect(releaseAudioPreferenceRank(release, PlaybackAudioPreference.dub), 2);
  });

  test('typed multi intent supports both filters without a dual label', () {
    const release = ReleaseCandidate(
      infoHash: 'typed-multi',
      magnetUri: '',
      releaseName: 'Provider stream',
      seeders: 0,
      sourceId: 'web:provider',
      isDubbed: true,
      audioIntent: ReleaseAudioIntent.multi,
    );

    expect(
      releaseSupportsAudioPreference(release, PlaybackAudioPreference.sub),
      isTrue,
    );
    expect(
      releaseSupportsAudioPreference(release, PlaybackAudioPreference.dub),
      isTrue,
    );
    expect(releaseAudioPreferenceRank(release, PlaybackAudioPreference.sub), 1);
    expect(releaseAudioPreferenceRank(release, PlaybackAudioPreference.dub), 0);
  });

  test('typed Sub intent wins even when the resolved file is multi-audio', () {
    const release = ReleaseCandidate(
      infoHash: 'sub-multi',
      magnetUri: '',
      releaseName: 'Provider / Multi Audio 1080p',
      seeders: 0,
      sourceId: 'web:provider',
      isDubbed: true,
      audioIntent: ReleaseAudioIntent.sub,
    );

    expect(
      preferredAudioPreferenceForRelease(
        release: release,
        globalPreference: PlaybackAudioPreference.dub,
      ),
      PlaybackAudioPreference.sub,
    );
  });

  test('multi and unlabeled sources preserve the global default', () {
    const multi = ReleaseCandidate(
      infoHash: 'multi',
      magnetUri: '',
      releaseName: 'Provider stream',
      seeders: 0,
      sourceId: 'web:provider',
      isDubbed: true,
      audioIntent: ReleaseAudioIntent.multi,
    );
    const unknown = ReleaseCandidate(
      infoHash: 'unknown',
      magnetUri: '',
      releaseName: 'Provider stream',
      seeders: 0,
      sourceId: 'web:provider',
    );

    for (final release in [multi, unknown]) {
      expect(
        preferredAudioPreferenceForRelease(
          release: release,
          globalPreference: PlaybackAudioPreference.sub,
        ),
        PlaybackAudioPreference.sub,
      );
    }
  });

  test('active Sub or Dub filter controls a multi-audio launch', () {
    const release = ReleaseCandidate(
      infoHash: 'multi-filtered',
      magnetUri: '',
      releaseName: 'Provider stream',
      seeders: 0,
      sourceId: 'web:provider',
      audioIntent: ReleaseAudioIntent.multi,
    );

    expect(
      preferredAudioPreferenceForRelease(
        release: release,
        globalPreference: PlaybackAudioPreference.dub,
        requestedAudio: PlaybackAudioPreference.sub,
      ),
      PlaybackAudioPreference.sub,
    );
    expect(
      preferredAudioPreferenceForRelease(
        release: release,
        globalPreference: PlaybackAudioPreference.sub,
        requestedAudio: PlaybackAudioPreference.dub,
      ),
      PlaybackAudioPreference.dub,
    );
    expect(releaseAudioPickerLabel(release), 'SUB / DUB');
  });

  test('manual per-series audio overrides a source label', () {
    const release = ReleaseCandidate(
      infoHash: 'dub',
      magnetUri: '',
      releaseName: 'English Dub',
      seeders: 0,
      sourceId: 'web:provider',
      audioIntent: ReleaseAudioIntent.dub,
    );

    expect(
      preferredAudioPreferenceForRelease(
        release: release,
        globalPreference: PlaybackAudioPreference.dub,
        requestedAudio: PlaybackAudioPreference.dub,
        seriesAudioLanguage: 'jpn',
        seriesOverride: true,
      ),
      PlaybackAudioPreference.sub,
    );
  });
}
