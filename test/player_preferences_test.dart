import 'package:anime_tv/features/player/application/audio_track_selector.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:anime_tv/features/player/presentation/tv_player_screen.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/release_audio_preference.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('opens every supported stream class with MPV', () {
    final web = StreamReady(
      uri: Uri.parse('https://cdn.example.test/episode.m3u8'),
      displayName: 'Marketplace stream',
      providerId: 'fixture',
    );
    final debrid = StreamReady(
      uri: Uri.parse('https://cdn.example.test/episode.mkv'),
      displayName: 'Debrid stream',
      debridService: DebridService.realDebrid,
    );

    expect(preferMpvForInitialStream(web), isTrue);
    expect(preferMpvForInitialStream(debrid), isTrue);
  });

  test(
    'automatic decoder reopen failures route only library startup errors',
    () {
      expect(
        automaticDecoderFailureNeedsLibraryRecovery(
          automatic: true,
          hasLibrarySession: true,
          error: "Failed to initialize a decoder for codec 'truehd'.",
        ),
        isTrue,
      );
      expect(
        automaticDecoderFailureNeedsLibraryRecovery(
          automatic: false,
          hasLibrarySession: true,
          error: 'Could not open codec.',
        ),
        isFalse,
        reason: 'manual decoder changes retain their existing inline error UI',
      );
      expect(
        automaticDecoderFailureNeedsLibraryRecovery(
          automatic: true,
          hasLibrarySession: false,
          error: 'Could not open codec.',
        ),
        isFalse,
        reason: 'anime streams retain ordinary MPV failover behavior',
      );
      expect(
        automaticDecoderFailureNeedsLibraryRecovery(
          automatic: true,
          hasLibrarySession: true,
          error: 'Network request timed out.',
        ),
        isFalse,
      );
    },
  );

  test('prefers English dub audio over Japanese default audio', () {
    const tracks = [
      AudioTrack('1', 'Japanese', 'jpn', isDefault: true),
      AudioTrack('2', 'English Dub', 'eng'),
      AudioTrack('3', 'English Commentary', 'eng'),
    ];

    expect(preferredDubAudioTrack(tracks)?.id, '2');
  });

  test(
    'local dual-audio startup prefers English before late track selection',
    () {
      const tracks = [
        AudioTrack('1', 'Japanese', 'jpn', isDefault: true),
        AudioTrack('2', 'English Dub', 'eng'),
      ];

      expect(mpvPreferredAudioStartupProperties('eng'), {
        'alang': 'eng,en',
        'aid': 'auto',
      });
      expect(
        preferredAudioTrack(
          tracks,
          preference: PlaybackAudioPreference.dub,
          allowFallback: false,
        )?.id,
        '2',
      );
    },
  );

  test('Sub-labeled multi-audio stream selects Japanese, not English', () {
    const release = ReleaseCandidate(
      infoHash: 'sub-multi',
      magnetUri: '',
      releaseName: 'Provider / Multi Audio 1080p',
      seeders: 0,
      sourceId: 'web:provider',
      isDubbed: true,
      audioIntent: ReleaseAudioIntent.sub,
    );
    const tracks = [
      AudioTrack('1', 'English Dub', 'eng', isDefault: true),
      AudioTrack('2', 'Japanese', 'jpn'),
    ];
    final preference = preferredAudioPreferenceForRelease(
      release: release,
      globalPreference: PlaybackAudioPreference.dub,
    );

    expect(preference, PlaybackAudioPreference.sub);
    expect(mpvPreferredAudioStartupProperties(preference.audioLanguage), {
      'alang': 'jpn,ja',
      'aid': 'auto',
    });
    expect(
      preferredAudioTrack(
        tracks,
        preference: preference,
        allowFallback: false,
      )?.id,
      '2',
    );
  });

  test('Sub tab overrides a Dub global default for a multi-audio source', () {
    const release = ReleaseCandidate(
      infoHash: 'multi-filtered',
      magnetUri: '',
      releaseName: 'Provider / 1080p',
      seeders: 0,
      sourceId: 'web:provider',
      audioIntent: ReleaseAudioIntent.multi,
    );
    const tracks = [
      AudioTrack('1', 'English Dub', 'eng', isDefault: true),
      AudioTrack('2', 'Japanese', 'jpn'),
    ];
    final preference = preferredAudioPreferenceForRelease(
      release: release,
      globalPreference: PlaybackAudioPreference.dub,
      requestedAudio: PlaybackAudioPreference.sub,
    );

    expect(preference, PlaybackAudioPreference.sub);
    expect(
      preferredAudioTrack(
        tracks,
        preference: preference,
        allowFallback: false,
      )?.id,
      '2',
    );
  });

  test('leaves automatic audio unchanged when no dub exists', () {
    const tracks = [
      AudioTrack('1', 'Japanese', 'jpn', isDefault: true),
      AudioTrack('2', 'Japanese 5.1', 'jpn'),
    ];

    expect(preferredDubAudioTrack(tracks), isNull);
  });

  test('global sub preference consistently chooses Japanese audio', () {
    const tracks = [
      AudioTrack('1', 'English Dub', 'eng', isDefault: true),
      AudioTrack('2', 'Japanese', 'jpn'),
    ];

    expect(
      preferredAudioTrack(
        tracks,
        preference: PlaybackAudioPreference.sub,
        allowFallback: false,
      )?.id,
      '2',
    );
  });

  test('explicit series audio selects the same language next episode', () {
    const tracks = [
      AudioTrack('1', 'Japanese', 'jpn', isDefault: true),
      AudioTrack('2', 'English Dub', 'eng'),
      AudioTrack('3', 'English Commentary', 'eng'),
    ];

    expect(
      preferredAudioTrackForLanguage(
        tracks,
        language: 'eng',
        allowFallback: false,
      )?.id,
      '2',
    );
    expect(
      preferredAudioTrackForLanguage(
        tracks,
        language: 'jpn',
        allowFallback: false,
      )?.id,
      '1',
    );
  });

  test('an anime track labeled only Dub persists as English', () {
    expect(canonicalPlayerLanguage('[DUB] 5.1'), 'eng');
    expect(
      playbackAudioPreferenceForLanguage('eng'),
      PlaybackAudioPreference.dub,
    );
  });

  test('undefined container language falls back to the useful track label', () {
    for (final placeholder in const ['und', 'zxx', 'mul']) {
      expect(canonicalPlayerLanguage(placeholder), isEmpty);
      expect(
        canonicalPlayerTrackLanguage(
          language: placeholder,
          title: 'English Dub 5.1',
        ),
        'eng',
        reason: placeholder,
      );
    }
  });

  test('explicit Dub and Sub survive opposite-language player fallbacks', () {
    expect(
      persistedPlayerAudioLanguage(
        storedLanguage: 'eng',
        audioPreferenceSet: true,
        observedLanguage: 'jpn',
        observedTitle: 'Japanese fallback',
      ),
      'eng',
    );
    expect(
      persistedPlayerAudioLanguage(
        storedLanguage: 'jpn',
        audioPreferenceSet: true,
        observedLanguage: 'eng',
        observedTitle: 'English fallback',
      ),
      'jpn',
    );
  });

  test('manual audio changes replace an explicit series choice', () {
    expect(
      persistedPlayerAudioLanguage(
        storedLanguage: 'jpn',
        audioPreferenceSet: true,
        observedLanguage: 'und',
        observedTitle: 'English Dub',
        manualSelection: true,
      ),
      'eng',
    );
    expect(
      persistedPlayerAudioLanguage(
        storedLanguage: 'eng',
        audioPreferenceSet: false,
        observedLanguage: 'jpn',
      ),
      'jpn',
      reason: 'automatic observations remain persistable before manual choice',
    );
  });

  test(
    'prepared playback invalidates for any persisted manual audio intent',
    () {
      expect(
        playerAudioIntentChanged(
          previousLanguage: 'eng',
          previousPreferenceSet: false,
          nextLanguage: 'English Dub',
          nextPreferenceSet: true,
        ),
        isTrue,
        reason: 'making the global default an explicit series choice matters',
      );
      expect(
        playerAudioIntentChanged(
          previousLanguage: 'spa',
          previousPreferenceSet: true,
          nextLanguage: 'fra',
          nextPreferenceSet: true,
        ),
        isTrue,
        reason: 'exact languages may share the same Dub/Sub fallback class',
      );
      expect(
        playerAudioIntentChanged(
          previousLanguage: 'eng',
          previousPreferenceSet: true,
          nextLanguage: 'English Dub 5.1',
          nextPreferenceSet: true,
        ),
        isFalse,
        reason: 'equivalent labels normalize to the same persisted intent',
      );
    },
  );

  test('series Dub override wins over a global Sub release preference', () {
    expect(
      effectivePlaybackAudioPreference(
        globalPreference: PlaybackAudioPreference.sub,
        seriesAudioLanguage: 'eng',
        seriesOverride: true,
      ),
      PlaybackAudioPreference.dub,
    );
    expect(
      effectivePlaybackAudioPreference(
        globalPreference: PlaybackAudioPreference.sub,
      ),
      PlaybackAudioPreference.sub,
    );
  });

  test('audio preference has deterministic default-track fallback', () {
    const tracks = [
      AudioTrack('1', 'French', 'fra'),
      AudioTrack('2', 'Spanish', 'spa', isDefault: true),
    ];

    expect(
      preferredAudioTrack(tracks, preference: PlaybackAudioPreference.dub)?.id,
      '2',
    );
  });

  test(
    'waits for a late English track before opening the audio picker',
    () async {
      const japaneseOnly = [
        AudioTrack('1', 'Japanese', 'jpn', isDefault: true),
      ];
      const dualAudio = [
        ...japaneseOnly,
        AudioTrack('2', 'English Dub', 'eng', codec: 'aac'),
      ];
      var reads = 0;

      final tracks = await waitForStableTrackSnapshot<List<AudioTrack>>(
        read: () async => ++reads < 3 ? japaneseOnly : dualAudio,
        signature: mediaKitAudioTrackSignature,
        hasTracks: (tracks) => tracks.isNotEmpty,
        pollInterval: const Duration(milliseconds: 1),
        minimumWait: const Duration(milliseconds: 4),
        maximumWait: const Duration(milliseconds: 12),
      );

      expect(tracks.map((track) => track.id), ['1', '2']);
      expect(preferredDubAudioTrack(tracks)?.id, '2');
    },
  );

  test(
    'dual-audio releases wait past a stable single-track snapshot',
    () async {
      const japaneseOnly = [
        AudioTrack('1', 'Japanese', 'jpn', isDefault: true),
      ];
      const dualAudio = [
        ...japaneseOnly,
        AudioTrack('2', 'English Dub', 'eng', codec: 'aac'),
      ];
      var reads = 0;

      final tracks = await waitForStableTrackSnapshot<List<AudioTrack>>(
        read: () async => ++reads < 6 ? japaneseOnly : dualAudio,
        signature: mediaKitAudioTrackSignature,
        hasTracks: (tracks) => tracks.isNotEmpty,
        isComplete: (tracks) => tracks.length >= 2,
        pollInterval: const Duration(milliseconds: 1),
        minimumWait: const Duration(milliseconds: 3),
        maximumWait: const Duration(milliseconds: 10),
      );

      expect(reads, greaterThanOrEqualTo(6));
      expect(tracks.map((track) => track.id), ['1', '2']);
    },
  );

  test('recognizes common dual and multi-audio release labels', () {
    expect(releaseAdvertisesMultipleAudio('[Group] Show - Dual Audio'), isTrue);
    expect(releaseAdvertisesMultipleAudio('Show.Multi-Audio.1080p'), isTrue);
    expect(releaseAdvertisesMultipleAudio('Show [DUAL] 1080p'), isTrue);
    expect(releaseAdvertisesMultipleAudio('Show ENG+JPN 1080p'), isTrue);
    expect(
      releaseAdvertisesMultipleAudio('Show Japanese Audio 1080p'),
      isFalse,
    );
  });

  test('track signatures detect media-kit metadata changes', () {
    expect(
      mediaKitAudioTrackSignature(const [AudioTrack('1', 'Japanese', 'jpn')]),
      isNot(
        mediaKitAudioTrackSignature(const [
          AudioTrack('1', 'Japanese', 'jpn'),
          AudioTrack('2', 'English', 'eng'),
        ]),
      ),
    );
    expect(
      mediaKitSubtitleTrackSignature(const [
        SubtitleTrack('1', 'English CC', 'eng'),
      ]),
      isNot(
        mediaKitSubtitleTrackSignature(const [
          SubtitleTrack('1', 'English CC', 'eng'),
          SubtitleTrack('2', 'Signs and songs', 'eng'),
        ]),
      ),
    );
  });

  test(
    'waits for a late embedded caption instead of reporting unavailable',
    () async {
      const captions = [SubtitleTrack('4', 'English CC', 'eng')];
      var reads = 0;

      final tracks = await waitForStableTrackSnapshot<List<SubtitleTrack>>(
        read: () async => ++reads < 4 ? const [] : captions,
        signature: mediaKitSubtitleTrackSignature,
        hasTracks: (tracks) => tracks.isNotEmpty,
        pollInterval: const Duration(milliseconds: 1),
        minimumWait: const Duration(milliseconds: 3),
        maximumWait: const Duration(milliseconds: 10),
      );

      expect(tracks, captions);
      expect(reads, greaterThanOrEqualTo(4));
    },
  );

  test(
    'starts automatic playback on smooth MediaCodec with adaptive fallback',
    () {
      expect(
        tetoTvVideoControllerConfiguration.enableHardwareAcceleration,
        isTrue,
      );
      expect(tetoTvVideoControllerConfiguration.vo, 'gpu');
      expect(tetoTvVideoControllerConfiguration.hwdec, 'mediacodec');
      expect(
        tetoTvVideoControllerConfiguration
            .androidAttachSurfaceAfterVideoParameters,
        isTrue,
      );
    },
  );

  test('recognizes video failures that should trigger software decoding', () {
    expect(isLikelyVideoDecodeFailure('MediaCodec failed to initialize'), true);
    expect(isLikelyVideoDecodeFailure('No video output available'), true);
    expect(isLikelyVideoDecodeFailure('Could not open codec.'), true);
    expect(
      isLikelyVideoDecodeFailure(
        "Failed to initialize a decoder for codec 'truehd'.",
      ),
      true,
    );
    expect(isLikelyVideoDecodeFailure('HTTP 403 forbidden'), false);
  });

  test('automatic recovery preserves a resume seek that never took effect', () {
    const resume = Duration(minutes: 12, seconds: 30);
    expect(
      effectivePlayerResumePosition(
        position: Duration.zero,
        pendingResume: resume,
      ),
      resume,
    );
    expect(
      effectivePlayerResumePosition(
        position: const Duration(seconds: 12),
        pendingResume: resume,
      ),
      resume,
      reason:
          'failed resume attempts can outlive the old two-second startup guard',
    );
    expect(
      effectivePlayerResumePosition(
        position: const Duration(minutes: 4),
        pendingResume: resume,
      ),
      resume,
      reason: 'ordinary playback behind the checkpoint is not a confirmed seek',
    );
    expect(
      effectivePlayerResumePosition(
        position: const Duration(minutes: 13),
        pendingResume: resume,
      ),
      const Duration(minutes: 13),
      reason: 'playback which reaches or passes the checkpoint supersedes it',
    );
    expect(
      playerResumeTargetReached(
        target: resume,
        actual: const Duration(minutes: 12, seconds: 29),
      ),
      isTrue,
      reason: 'a confirmed seek clears inherited recovery state',
    );
    expect(
      effectivePlayerResumePosition(
        position: const Duration(seconds: 1),
        pendingResume: null,
      ),
      const Duration(seconds: 1),
    );
  });

  test('startup duration cannot clamp an inherited resume checkpoint', () {
    const resume = Duration(minutes: 12);
    expect(
      effectivePlayerProgressDuration(
        duration: const Duration(seconds: 3),
        effectivePosition: resume,
        pendingResume: resume,
      ),
      Duration.zero,
      reason: 'unknown is safer than allowing progress to clamp back to 3s',
    );
    expect(
      effectivePlayerProgressDuration(
        duration: const Duration(minutes: 24),
        effectivePosition: resume,
        pendingResume: resume,
      ),
      const Duration(minutes: 24),
    );
    expect(
      effectivePlayerProgressDuration(
        duration: const Duration(seconds: 3),
        effectivePosition: const Duration(seconds: 3),
      ),
      const Duration(seconds: 3),
      reason: 'explicit seeks clear the inherited target before reporting',
    );
  });

  test('offers safe hardware, direct hardware, and software decoders', () {
    expect(
      hwdecForPlaybackMode(PlaybackDecoderMode.hardwareSafe),
      'mediacodec',
    );
    expect(
      hwdecForPlaybackMode(PlaybackDecoderMode.hardwareDirect),
      'mediacodec',
    );
    expect(hwdecForPlaybackMode(PlaybackDecoderMode.software), 'no');
  });

  test('forces software decoding for H.264 Hi10P anime releases', () {
    const hi10 = ReleaseCandidate(
      infoHash: '0123456789012345678901234567890123456789',
      magnetUri: 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      releaseName: '[Group] Show - 01 [1080p Hi10P x264].mkv',
      seeders: 1,
      sourceId: 'test',
      codec: 'H.264',
    );
    const ordinary = ReleaseCandidate(
      infoHash: '0123456789012345678901234567890123456789',
      magnetUri: 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      releaseName: '[Group] Show - 01 [1080p x264].mkv',
      seeders: 1,
      sourceId: 'test',
      codec: 'H.264',
    );

    expect(releaseRequiresSoftwareDecoder(hi10), isTrue);
    expect(releaseRequiresSoftwareDecoder(ordinary), isFalse);
  });

  test('detects unlabeled 10-bit H.264 from decoded stream metadata', () {
    expect(
      isH264TenBitVideoProfile(
        codec: 'h264',
        profile: 'High 10',
        format: 'yuv420p10le',
        pixelFormat: 'mediacodec',
      ),
      isTrue,
    );
    expect(
      isH264TenBitVideoProfile(
        codec: 'h264',
        profile: 'High',
        format: 'yuv420p',
      ),
      isFalse,
    );
    expect(
      isH264TenBitVideoProfile(
        codec: 'hevc',
        profile: 'Main 10',
        format: 'yuv420p10le',
      ),
      isFalse,
    );
  });

  test('retries a resume seek only when playback remained near the start', () {
    const target = Duration(minutes: 12, seconds: 30);
    expect(resumeSeekNeedsRetry(target, Duration.zero), isTrue);
    expect(
      resumeSeekNeedsRetry(target, const Duration(minutes: 12, seconds: 28)),
      isFalse,
    );
  });

  test('D-pad arrows navigate controls instead of seeking playback', () {
    expect(playerSeekOffsetForKey(LogicalKeyboardKey.arrowLeft), isNull);
    expect(playerSeekOffsetForKey(LogicalKeyboardKey.arrowRight), isNull);
    expect(
      playerSeekOffsetForKey(LogicalKeyboardKey.mediaRewind),
      const Duration(seconds: -10),
    );
    expect(
      playerSeekOffsetForKey(LogicalKeyboardKey.mediaFastForward),
      const Duration(seconds: 10),
    );
  });

  test('seek target remains usable before stream duration is known', () {
    expect(
      playerSeekTarget(
        position: const Duration(minutes: 3),
        offset: const Duration(seconds: 10),
        duration: Duration.zero,
      ),
      const Duration(minutes: 3, seconds: 10),
    );
    expect(
      playerSeekTarget(
        position: const Duration(seconds: 4),
        offset: const Duration(seconds: -10),
        duration: const Duration(minutes: 24),
      ),
      Duration.zero,
    );
    expect(
      playerSeekTarget(
        position: const Duration(minutes: 23, seconds: 58),
        offset: const Duration(seconds: 10),
        duration: const Duration(minutes: 24),
      ),
      const Duration(minutes: 24),
    );
  });

  test('scrub targets never commit MPV exact end-of-file', () {
    const duration = Duration(minutes: 24);
    expect(
      playerScrubTarget(target: duration, duration: duration),
      const Duration(minutes: 23, seconds: 59),
    );
    expect(
      playerScrubTarget(target: const Duration(hours: 2), duration: duration),
      const Duration(minutes: 23, seconds: 59),
    );
    expect(
      playerScrubTarget(
        target: const Duration(minutes: 7),
        duration: Duration.zero,
      ),
      const Duration(minutes: 7),
    );
    expect(
      playerScrubTarget(
        target: const Duration(seconds: -1),
        duration: duration,
      ),
      Duration.zero,
    );
  });

  test('provisional seek previews stay local to the device', () {
    final web = StreamReady(
      uri: Uri.parse('https://provider.example/episode.m3u8'),
      displayName: 'Web',
    );
    final debrid = StreamReady(
      uri: Uri.parse('https://debrid.example/episode.mkv'),
      displayName: 'Debrid',
      debridService: DebridService.realDebrid,
    );
    final downloaded = StreamReady(
      uri: Uri.file('/offline_downloads/episode.mkv'),
      displayName: 'Downloaded',
      isDownloaded: true,
    );
    final deviceFile = StreamReady(
      uri: Uri.file('/media/episode.mkv'),
      displayName: 'Device file',
    );

    expect(supportsProvisionalSeekPreview(web), isFalse);
    expect(supportsProvisionalSeekPreview(debrid), isFalse);
    expect(supportsProvisionalSeekPreview(downloaded), isTrue);
    expect(supportsProvisionalSeekPreview(deviceFile), isTrue);
  });

  test('seek preview follows the thumb and stays inside the TV safe area', () {
    const duration = Duration(minutes: 24);
    expect(
      playerSeekPreviewLeft(
        viewportWidth: 1920,
        position: Duration.zero,
        duration: duration,
      ),
      253,
    );
    expect(
      playerSeekPreviewLeft(
        viewportWidth: 1920,
        position: const Duration(minutes: 12),
        duration: duration,
      ),
      855,
    );
    expect(
      playerSeekPreviewLeft(
        viewportWidth: 1920,
        position: duration,
        duration: duration,
      ),
      1457,
    );
    expect(
      playerSeekPreviewLeft(
        viewportWidth: 640,
        position: Duration.zero,
        duration: duration,
      ),
      12,
    );
    expect(
      playerSeekPreviewLeft(
        viewportWidth: 640,
        position: duration,
        duration: duration,
      ),
      418,
    );
    expect(
      playerSeekPreviewBottom(viewportWidth: 1920, viewportHeight: 1080),
      210,
    );
    expect(
      playerSeekPreviewBottom(viewportWidth: 640, viewportHeight: 360),
      162,
    );
  });

  test('skip-segment target never lands on the synchronous EOF boundary', () {
    expect(
      safeSkipSegmentTarget(
        requested: const Duration(minutes: 24),
        duration: const Duration(minutes: 24),
      ),
      const Duration(minutes: 23, seconds: 59),
    );
    expect(
      safeSkipSegmentTarget(
        requested: const Duration(minutes: 21, seconds: 30),
        duration: const Duration(minutes: 24),
      ),
      const Duration(minutes: 21, seconds: 30),
    );
    expect(
      safeSkipSegmentTarget(
        requested: const Duration(minutes: 4),
        duration: Duration.zero,
      ),
      const Duration(minutes: 4),
    );
  });

  test('terminal outro remains identifiable behind the eof guard', () {
    expect(
      skipSegmentReachesPlaybackEnd(
        requestedEnd: const Duration(minutes: 24),
        duration: const Duration(minutes: 24),
      ),
      isTrue,
    );
    expect(
      skipSegmentReachesPlaybackEnd(
        requestedEnd: const Duration(minutes: 21, seconds: 30),
        duration: const Duration(minutes: 24),
      ),
      isFalse,
    );
  });

  test('subtitle defaults follow the selected release language', () {
    const sub = ReleaseCandidate(
      infoHash: 'sub',
      magnetUri: 'magnet:?xt=urn:btih:sub',
      releaseName: 'Show 01 English Subbed',
      seeders: 1,
      sourceId: 'test',
      hasSubtitles: true,
    );
    const dub = ReleaseCandidate(
      infoHash: 'dub',
      magnetUri: 'magnet:?xt=urn:btih:dub',
      releaseName: 'Show 01 English Dub',
      seeders: 1,
      sourceId: 'test',
      isDubbed: true,
      hasSubtitles: true,
    );

    expect(subtitlesEnabledByDefault(sub), isTrue);
    expect(subtitlesEnabledByDefault(dub), isFalse);
  });

  test('MPV provisional fallback never leaves default commentary selected', () {
    const tracks = [
      AudioTrack('1', 'English Commentary', 'eng', isDefault: true),
      AudioTrack('2', 'Japanese Stereo', 'jpn'),
    ];

    expect(
      preferredAudioTrackForLanguage(
        tracks,
        language: 'fra',
        allowFallback: false,
      )?.id,
      '2',
    );
    expect(
      preferredAudioTrack(
        tracks,
        preference: PlaybackAudioPreference.dub,
        allowFallback: false,
      )?.id,
      '2',
      reason: 'commentary is not a valid Dub match',
    );
  });

  test('English track matching accepts common ISO aliases', () {
    for (final language in const ['en', 'eng', 'en-US', 'en_GB', 'English']) {
      expect(
        playerTrackMatchesLanguage(
          language: language,
          preferredLanguage: 'eng',
        ),
        isTrue,
        reason: language,
      );
    }
  });

  test('double Down requires two distinct presses inside the window', () {
    final detector = PlayerDoubleDownDetector();
    final start = DateTime(2026);

    expect(detector.register(LogicalKeyboardKey.arrowDown, at: start), isFalse);
    expect(
      detector.register(
        LogicalKeyboardKey.arrowDown,
        at: start.add(const Duration(milliseconds: 440)),
      ),
      isTrue,
    );
    expect(playerControlsIdleTimeout, const Duration(seconds: 5));
  });

  test('previous episode is unavailable until playback passes episode one', () {
    expect(playerPreviousEpisodeAvailable(null), isFalse);
    expect(playerPreviousEpisodeAvailable(0), isFalse);
    expect(playerPreviousEpisodeAvailable(1), isFalse);
    expect(playerPreviousEpisodeAvailable(2), isTrue);
    expect(playerPreviousEpisodeAvailable(24), isTrue);
  });

  test('another key or a late Down resets double-Down detection', () {
    final detector = PlayerDoubleDownDetector();
    final start = DateTime(2026);

    detector.register(LogicalKeyboardKey.arrowDown, at: start);
    detector.register(
      LogicalKeyboardKey.arrowRight,
      at: start.add(const Duration(milliseconds: 100)),
    );
    expect(
      detector.register(
        LogicalKeyboardKey.arrowDown,
        at: start.add(const Duration(milliseconds: 200)),
      ),
      isFalse,
    );
    expect(
      detector.register(
        LogicalKeyboardKey.arrowDown,
        at: start.add(const Duration(milliseconds: 800)),
      ),
      isFalse,
    );
  });

  test('a held Down cannot reopen a HUD that its key-down dismissed', () {
    expect(
      consumeHiddenPlayerHudDownRepeat(
        key: LogicalKeyboardKey.arrowDown,
        isRepeat: true,
        controlsVisible: false,
      ),
      isTrue,
    );
    expect(
      consumeHiddenPlayerHudDownRepeat(
        key: LogicalKeyboardKey.arrowDown,
        isRepeat: false,
        controlsVisible: false,
      ),
      isFalse,
      reason: 'the initial key-down must still be allowed to show the HUD',
    );
    expect(
      consumeHiddenPlayerHudDownRepeat(
        key: LogicalKeyboardKey.arrowDown,
        isRepeat: true,
        controlsVisible: true,
      ),
      isFalse,
      reason: 'visible controls keep their normal directional behavior',
    );
    expect(
      consumeHiddenPlayerHudDownRepeat(
        key: LogicalKeyboardKey.arrowRight,
        isRepeat: true,
        controlsVisible: false,
      ),
      isFalse,
      reason: 'other directions must still reveal and navigate the HUD',
    );
  });

  testWidgets('hidden HUD D-pad seeks immediately and repeats until key-up', (
    tester,
  ) async {
    final repeater = HiddenPlayerDpadSeekRepeater();
    addTearDown(repeater.dispose);
    final seeks = <({LogicalKeyboardKey key, bool repeated})>[];
    void record(LogicalKeyboardKey key, {required bool repeated}) {
      seeks.add((key: key, repeated: repeated));
    }

    expect(
      repeater.handleKeyEvent(
        event: const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration.zero,
        ),
        controlsVisible: false,
        enabled: true,
        onSeek: record,
      ),
      isTrue,
    );
    expect(seeks, [(key: LogicalKeyboardKey.arrowRight, repeated: false)]);

    await tester.pump(playerHiddenHudSeekInitialDelay);
    expect(seeks.last.repeated, isTrue);
    final afterDelay = seeks.length;
    await tester.pump(playerHiddenHudSeekRepeatInterval * 2);
    expect(seeks.length, greaterThan(afterDelay));

    expect(
      repeater.handleKeyEvent(
        event: const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration(seconds: 1),
        ),
        controlsVisible: false,
        enabled: true,
        onSeek: record,
      ),
      isTrue,
    );
    final afterRelease = seeks.length;
    await tester.pump(playerHiddenHudSeekRepeatInterval * 3);
    expect(seeks.length, afterRelease);
    expect(repeater.active, isFalse);
  });

  test('hidden HUD guest seek is consumed without starting repeats', () {
    final repeater = HiddenPlayerDpadSeekRepeater();
    addTearDown(repeater.dispose);
    var blocked = 0;
    var seeks = 0;
    expect(
      repeater.handleKeyEvent(
        event: const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowLeft,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          timeStamp: Duration.zero,
        ),
        controlsVisible: false,
        enabled: false,
        onSeek: (_, {required repeated}) => seeks += 1,
        onBlocked: () => blocked += 1,
      ),
      isTrue,
    );
    expect(blocked, 1);
    expect(seeks, 0);
    expect(repeater.active, isTrue, reason: 'key repeats remain consumed');
  });

  test(
    'native player release is joined and can retry after a failure',
    () async {
      final coordinator = PlayerReleaseCoordinator();
      var attempts = 0;
      final first = coordinator.release(() async {
        attempts += 1;
        await Future<void>.delayed(Duration.zero);
        throw StateError('decoder still owns the surface');
      });
      final joined = coordinator.release(() async {
        attempts += 100;
      });

      expect(await Future.wait([first, joined]), [isFalse, isFalse]);
      expect(
        attempts,
        1,
        reason: 'concurrent release must share one operation',
      );
      expect(coordinator.released, isFalse);

      expect(
        await coordinator.release(() async {
          attempts += 1;
        }),
        isTrue,
      );
      expect(attempts, 2);
      expect(coordinator.released, isTrue);
    },
  );
}
