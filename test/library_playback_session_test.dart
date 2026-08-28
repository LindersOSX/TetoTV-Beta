import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/player/application/library_playback_session.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/player/presentation/library_tv_player_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'startup classifier recognizes codec, TrueHD, container and no-frame failures',
    () {
      expect(
        classifyLibraryPlaybackStartupFailure(
          'Could not open codec truehd for decoding',
        ),
        LibraryPlaybackStartupFailure.decoder,
      );
      expect(
        classifyLibraryPlaybackStartupFailure('Unsupported codec from MPV'),
        LibraryPlaybackStartupFailure.decoder,
      );
      expect(
        classifyLibraryPlaybackStartupFailure('Could not open demuxer'),
        LibraryPlaybackStartupFailure.container,
      );
      expect(
        classifyLibraryPlaybackStartupFailure('No video frames were rendered.'),
        LibraryPlaybackStartupFailure.noVideoFrame,
      );
      expect(
        classifyLibraryPlaybackStartupFailure(
          'This stream is dropping too many frames on this device.',
        ),
        LibraryPlaybackStartupFailure.unstableVideo,
      );
      expect(
        classifyLibraryPlaybackStartupFailure('The remote server returned 503'),
        isNull,
      );
    },
  );

  test('library request is isolated from every anime-only side effect', () {
    final request = _request(requestedAudio: PlaybackAudioPreference.sub);

    expect(request.isolation.animeTrackingEnabled, isFalse);
    expect(request.isolation.animeCheckpointEnabled, isFalse);
    expect(request.isolation.aniSkipEnabled, isFalse);
    expect(request.isolation.fillerNavigationEnabled, isFalse);
    expect(request.isolation.nextEpisodeEnabled, isFalse);

    final launch = libraryPlaybackLaunchForRequest(request);
    expect(launch.episode.anilistMediaId, 0);
    expect(launch.episode.malMediaId, isNull);
    expect(launch.selectedRelease.magnetUri, isEmpty);
    expect(launch.alternatives, isEmpty);
    expect(launch.directAlternatives, isEmpty);
    expect(launch.requestedAudio, PlaybackAudioPreference.sub);
  });

  test('catalog-linked library playback keeps sanitized unified metadata', () {
    final request = LibraryPlaybackRequest(
      source: Uri.parse('https://media.example/video/7'),
      title: 'Private server episode title',
      releaseName: 'Private release',
      streamLabel: 'Jellyfin • Episode 7',
      sourceProviderId: 'library-jellyfin',
      sourceProviderName: 'Jellyfin',
      checkpointKey: 'local:0123456789abcdef',
      timelineIdentity: 'private-server-item-7',
      watchPartyIdentity: LibraryWatchPartyIdentity(
        anilistMediaId: 123,
        episode: 7,
        title: 'Frieren: Beyond Journey’s End',
        episodeCount: 28,
      ),
    );

    final launch = libraryPlaybackLaunchForRequest(request);

    expect(launch.episode.anilistMediaId, 123);
    expect(launch.episode.episode, 7);
    expect(launch.episode.title, 'Frieren: Beyond Journey’s End');
    expect(launch.episode.episodeCount, 28);
    expect(launch.stream.providerId, 'library-jellyfin');
    expect(launch.stream.providerName, 'Jellyfin');
    expect(launch.selectedRelease.sourceId, 'library-jellyfin');
    expect(launch.selectedRelease.provider, 'Jellyfin');
    expect(request.isolation.animeTrackingEnabled, isFalse);
    expect(request.isolation.animeCheckpointEnabled, isFalse);
    expect(request.isolation.publicCatalogEpisodeLinked, isTrue);
    expect(request.isolation.aniSkipEnabled, isTrue);
    expect(request.isolation.fillerNavigationEnabled, isTrue);
    expect(request.isolation.nextEpisodeEnabled, isTrue);
  });

  test('all validated library sources are playable by MPV', () {
    final local = _request(
      source: Uri.parse('content://media/external/video/media/7'),
    );
    final authenticatedServer = _request(
      source: Uri.parse('https://media.example/video/7'),
    );
    final publicServer = _request(
      source: Uri.parse('https://media.example/public/7'),
      headers: const {},
    );

    expect(isSupportedLibraryPlaybackUri(local.source), isTrue);
    expect(isSupportedLibraryPlaybackUri(authenticatedServer.source), isTrue);
    expect(isSupportedLibraryPlaybackUri(publicServer.source), isTrue);
    final authenticatedLaunch = libraryPlaybackLaunchForRequest(
      authenticatedServer,
    );
    expect(authenticatedLaunch.stream.uri, authenticatedServer.source);
    expect(authenticatedLaunch.stream.headers, authenticatedServer.headers);
    expect(
      authenticatedLaunch.stream.uri.toString(),
      isNot(contains('secret-token')),
    );
    expect(
      () => _request(source: Uri.parse('file:///storage/emulated/0/a.mkv')),
      throwsArgumentError,
    );
  });

  test(
    'slow progress callbacks keep only one in-flight and latest pending',
    () async {
      final firstCallbackGate = Completer<void>();
      final delivered = <Duration>[];
      LibraryPlaybackResult? finished;
      final request = _request(
        onProgress: (progress) async {
          delivered.add(progress.position);
          if (delivered.length == 1) await firstCallbackGate.future;
        },
        onFinished: (result) => finished = result,
      );
      final session = LibraryPlaybackSession(request);
      final sampledAt = DateTime.utc(2026, 8, 20, 12);

      session.report(
        position: Duration.zero,
        duration: const Duration(minutes: 20),
        playing: true,
        sampledAt: sampledAt,
        force: true,
      );
      for (var second = 1; second <= 40; second++) {
        session.report(
          position: Duration(seconds: second),
          duration: const Duration(minutes: 20),
          playing: true,
          sampledAt: sampledAt.add(Duration(seconds: second)),
          force: true,
        );
      }
      session.markCompleted(
        position: const Duration(seconds: 40),
        duration: const Duration(seconds: 40),
      );
      final finishing = session.finish();
      await Future<void>.delayed(Duration.zero);

      expect(delivered, [Duration.zero]);
      expect(finished, isNull);

      firstCallbackGate.complete();
      await finishing;

      expect(delivered, [Duration.zero, const Duration(seconds: 40)]);
      expect(finished?.completed, isTrue);
      expect(finished?.position, const Duration(seconds: 40));
      expect(finished?.started, isTrue);
    },
  );

  test('manual handoff keeps position unless completion was marked', () async {
    final exitedSession = LibraryPlaybackSession(_request());
    exitedSession.report(
      position: const Duration(minutes: 8),
      duration: const Duration(minutes: 24),
      playing: true,
      force: true,
    );
    final exited = await exitedSession.finish();
    expect(exited.reason, LibraryPlaybackEndReason.exited);
    expect(exited.position, const Duration(minutes: 8));

    final completedSession = LibraryPlaybackSession(_request());
    completedSession.markCompleted(
      position: const Duration(minutes: 22),
      duration: const Duration(minutes: 24),
      playing: true,
    );
    expect(completedSession.lastProgress?.playing, isTrue);
    final completed = await completedSession.finish();
    expect(completed.reason, LibraryPlaybackEndReason.completed);
    expect(completed.position, const Duration(minutes: 22));
  });

  test('player start is delivered once and before queued progress', () async {
    final startGate = Completer<void>();
    final events = <String>[];
    final request = _request(
      onStarted: (position) async {
        events.add('start:${position.inSeconds}');
        await startGate.future;
      },
      onProgress: (progress) {
        events.add('progress:${progress.position.inSeconds}');
      },
    );
    final session = LibraryPlaybackSession(request);

    expect(events, isEmpty, reason: 'constructing a request is not playback');
    session.report(
      position: const Duration(seconds: 12),
      duration: const Duration(minutes: 20),
      playing: true,
      force: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, ['start:0']);
    startGate.complete();
    await session.start();
    await session.finish();

    expect(events.first, 'start:0');
    expect(events.where((event) => event.startsWith('start:')), ['start:0']);
    expect(
      events.skip(1),
      isNotEmpty,
      reason: 'the final checkpoint may intentionally repeat the last sample',
    );
    expect(events.skip(1), everyElement('progress:12'));
  });

  test('finish before a playback sample skips remote lifecycle', () async {
    final events = <String>[];
    LibraryPlaybackResult? finished;
    final session = LibraryPlaybackSession(
      _request(
        onStarted: (_) => events.add('started'),
        onFinished: (result) {
          events.add('finished');
          finished = result;
        },
      ),
    );

    await session.finish();

    expect(events, ['finished']);
    expect(finished?.started, isFalse);
    expect(finished?.reason, LibraryPlaybackEndReason.exited);
  });

  test(
    'normal user exit stays exited and is propagated to the route',
    () async {
      LibraryPlaybackResult? observed;
      final session = LibraryPlaybackSession(_request());
      session.report(
        position: const Duration(seconds: 25),
        duration: const Duration(minutes: 24),
        playing: true,
        force: true,
      );

      final result = await session.finish(
        onResult: (value) => observed = value,
      );

      expect(result.reason, LibraryPlaybackEndReason.exited);
      expect(result.failed, isFalse);
      expect(result.failureStage, isNull);
      expect(result.started, isTrue);
      expect(observed, same(result));
    },
  );

  test(
    'decoder startup failure is returned without leaking MPV input',
    () async {
      const privateDecoderError =
          'Could not open codec truehd at https://private.example/item?token=x';
      final failure = classifyLibraryPlaybackStartupFailure(
        privateDecoderError,
      );
      final session = LibraryPlaybackSession(_request());
      LibraryPlaybackResult? observed;

      session.markFailed(failure!);
      final result = await session.finish(
        onResult: (value) => observed = value,
      );

      expect(result.reason, LibraryPlaybackEndReason.failed);
      expect(result.failureStage, LibraryPlaybackFailureStage.playbackStartup);
      expect(result.error, failure.safeMessage);
      expect(result.error, isNot(contains('private.example')));
      expect(result.error, isNot(contains('token')));
      expect(result.started, isFalse);
      expect(observed, same(result));
    },
  );
}

LibraryPlaybackRequest _request({
  Uri? source,
  Map<String, String> headers = const {'Authorization': 'secret-token'},
  LibraryPlaybackStartedCallback? onStarted,
  LibraryPlaybackProgressCallback? onProgress,
  LibraryPlaybackFinishedCallback? onFinished,
  PlaybackAudioPreference? requestedAudio,
}) => LibraryPlaybackRequest(
  source: source ?? Uri.parse('https://media.example/video/7'),
  title: 'Private episode',
  releaseName: 'Private episode.mkv',
  streamLabel: 'Jellyfin',
  checkpointKey: 'local:0123456789abcdef',
  timelineIdentity: 'private-server-item-7',
  headers: headers,
  requestedAudio: requestedAudio,
  onStarted: onStarted,
  onProgress: onProgress,
  onFinished: onFinished,
);
