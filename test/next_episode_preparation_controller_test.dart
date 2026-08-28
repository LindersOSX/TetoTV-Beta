import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/filler_episode_lookup.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/streaming/application/next_episode_preparation_controller.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preparation begins only inside the final ten minutes', () {
    expect(
      shouldPrepareNextEpisode(
        position: const Duration(minutes: 9, seconds: 59),
        duration: const Duration(minutes: 20),
      ),
      isFalse,
    );
    expect(
      shouldPrepareNextEpisode(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 20),
      ),
      isTrue,
    );
  });

  test('downloaded next episode wins before network discovery', () async {
    var searches = 0;
    final controller = _controller(
      releases: [_release(hash: 'network-must-not-run')],
      resolver: (_) => throw StateError('resolver must not run'),
      onReleaseSearch: () => searches++,
      prepareDownloadedEpisode:
          ({required episode, required requestedAudio}) async => PlaybackLaunch(
            stream: StreamReady(
              uri: Uri.file('/offline/episode-2.mkv'),
              displayName: 'Downloaded episode 2',
              isDownloaded: true,
            ),
            episode: episode,
            selectedRelease: _release(hash: 'offline-episode-2'),
            requestedAudio: requestedAudio,
          ),
    );

    final prepared = await controller.warm(_request());

    expect(prepared?.launch.stream.isDownloaded, isTrue);
    expect(prepared?.launch.episode.episode, 2);
    expect(searches, 0);
    await controller.dispose();
  });

  test(
    'disabled offline downloads are not injected into next episode',
    () async {
      var downloadedPreparations = 0;
      var networkResolutions = 0;
      final controller = _controller(
        settings: const SettingsPreferences(
          preferredAudio: PlaybackAudioPreference.dub,
          offlineDownloadsEnabled: false,
        ),
        releases: [_release(hash: 'network-episode-2')],
        resolver: (release) {
          networkResolutions++;
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/episode-2.mkv'),
              displayName: 'Network episode 2',
              debridService: DebridService.realDebrid,
            ),
          );
        },
        prepareDownloadedEpisode:
            ({required episode, required requestedAudio}) async {
              downloadedPreparations++;
              return PlaybackLaunch(
                stream: StreamReady(
                  uri: Uri.file('/offline/episode-2.mkv'),
                  displayName: 'Downloaded episode 2',
                  isDownloaded: true,
                ),
                episode: episode,
                selectedRelease: _release(hash: 'offline-episode-2'),
                requestedAudio: requestedAudio,
              );
            },
      );

      final prepared = await controller.warm(_request());

      expect(downloadedPreparations, 0);
      expect(networkResolutions, 1);
      expect(prepared?.launch.stream.isDownloaded, isFalse);
      await prepared?.close();
      await controller.dispose();
    },
  );

  test('catalog-linked library preparation has no private source affinity', () {
    final request = NextEpisodePreparationRequest.catalogLinkedLibrary(
      episode: const EpisodeReference(
        anilistMediaId: 1887,
        malMediaId: 1887,
        title: 'Lucky☆Star',
        episode: 19,
        coverImageUrl: 'https://private-nas.home/items/poster?token=secret',
      ),
      seriesPreferences: const SeriesPlaybackPreferences(),
      debridService: DebridService.realDebrid,
    );

    expect(request.mediaId, 1887);
    expect(request.currentEpisode, 19);
    expect(request.currentLaunch.stream.uri.host, 'catalog.invalid');
    expect(request.currentLaunch.stream.headers, isEmpty);
    expect(request.currentLaunch.episode.coverImageUrl, isNull);
    expect(request.currentLaunch.stream.providerId, isNull);
    expect(request.currentLaunch.selectedRelease.provider, isNull);
    expect(request.currentLaunch.selectedRelease.sourceId, 'catalog');
    expect(
      request.currentLaunch.selectedRelease.releaseName,
      'Catalog episode',
    );
    expect(request.currentLaunch.alternatives, isEmpty);
    expect(request.currentLaunch.directAlternatives, isEmpty);
    expect(request.toString(), isNot(contains('private-nas')));
    expect(request.toString(), isNot(contains('secret')));
  });

  test(
    'private-library prewarm keeps capabilities out of public handoff state',
    () async {
      final lease = _FakeLease();
      LibraryEpisodeOrigin? observedOrigin;
      EpisodeReference? observedEpisode;
      final controller = _controller(
        releases: const [],
        resolver: (_) => throw StateError('network resolver must not run'),
        prepareLibraryEpisode:
            ({
              required episode,
              required preferredOrigin,
              required preferredSubtitleLanguage,
              required requestedAudio,
            }) async {
              observedEpisode = episode;
              observedOrigin = preferredOrigin;
              expect(preferredSubtitleLanguage, 'eng');
              expect(requestedAudio, PlaybackAudioPreference.sub);
              return LibraryPlaybackRequest(
                source: Uri.parse('https://private-nas.home/video/episode-2'),
                title: 'Private filename.mkv',
                releaseName: 'Private filename.mkv',
                streamLabel: 'Jellyfin',
                sourceProviderId: 'library-jellyfin',
                checkpointKey: 'local:private-checkpoint',
                timelineIdentity: 'private-item-id',
                headers: const {'Authorization': 'secret-token'},
                requestedAudio: requestedAudio,
                playbackLease: lease,
                watchPartyIdentity: LibraryWatchPartyIdentity(
                  anilistMediaId: episode.anilistMediaId,
                  episode: episode.episode,
                  title: episode.title,
                  episodeCount: episode.episodeCount,
                ),
              );
            },
      );
      final request = NextEpisodePreparationRequest.catalogLinkedLibrary(
        episode: const EpisodeReference(
          anilistMediaId: 7,
          title: 'Show',
          episode: 1,
          episodeCount: 12,
        ),
        seriesPreferences: const SeriesPlaybackPreferences(),
        debridService: DebridService.realDebrid,
        requestedAudio: PlaybackAudioPreference.sub,
        preferredOrigin: LibraryEpisodeOrigin.jellyfin,
      );

      final warmed = await controller.warm(request);

      expect(warmed?.isPrivateLibrary, isTrue);
      expect(observedEpisode?.episode, 2);
      expect(observedEpisode?.episodeCount, 12);
      expect(observedOrigin, LibraryEpisodeOrigin.jellyfin);
      expect(warmed?.launch.stream.uri.host, 'catalog.invalid');
      expect(warmed?.launch.stream.headers, isEmpty);
      expect(warmed?.launch.requestedAudio, PlaybackAudioPreference.sub);
      expect(
        warmed?.privateLibraryRequest?.requestedAudio,
        PlaybackAudioPreference.sub,
      );
      expect(
        warmed?.launch.selectedRelease.releaseName,
        isNot(contains('.mkv')),
      );
      expect(warmed.toString(), isNot(contains('private-nas')));
      expect(warmed.toString(), isNot(contains('secret-token')));
      expect(
        await controller.takePreparedTarget(mediaId: 7, episode: 2),
        isNull,
        reason: 'Watch Party must resolve its own private source capability',
      );
      final taken = await controller.take(7, 1, currentRequest: request);
      expect(taken, same(warmed));
      await controller.dispose();
      expect(lease.closeCount, 0);
      await taken!.close();
      expect(lease.closeCount, 1);
    },
  );

  test('timed-out private prewarm closes a lease that arrives late', () async {
    final preparation = Completer<LibraryPlaybackRequest?>();
    final lease = _FakeLease();
    final controller = _controller(
      resolutionTimeout: const Duration(milliseconds: 10),
      releases: const [],
      resolver: (_) => throw StateError('network resolver must not run'),
      prepareLibraryEpisode:
          ({
            required episode,
            required preferredOrigin,
            required preferredSubtitleLanguage,
            required requestedAudio,
          }) => preparation.future,
    );
    final request = NextEpisodePreparationRequest.catalogLinkedLibrary(
      episode: const EpisodeReference(
        anilistMediaId: 7,
        title: 'Show',
        episode: 1,
        episodeCount: 12,
      ),
      seriesPreferences: const SeriesPlaybackPreferences(),
      debridService: DebridService.realDebrid,
      preferredOrigin: LibraryEpisodeOrigin.jellyfin,
    );

    expect(await controller.warm(request), isNull);
    preparation.complete(
      LibraryPlaybackRequest(
        source: Uri.parse('https://private-nas.home/video/episode-2'),
        title: 'Private filename.mkv',
        releaseName: 'Private filename.mkv',
        streamLabel: 'Jellyfin',
        sourceProviderId: 'library-jellyfin',
        checkpointKey: 'local:private-checkpoint',
        timelineIdentity: 'private-item-id',
        headers: const {'Authorization': 'secret-token'},
        playbackLease: lease,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(lease.closeCount, 1);
    await controller.dispose();
  });

  test(
    'prepares and atomically transfers a ready next-episode launch',
    () async {
      final lease = _FakeLease();
      final nextRelease = _release(
        hash: 'next',
        provider: 'Same source',
        sourceId: 'stable-source',
        name: '[Group] Show - 02 Dual Audio',
      );
      final controller = _controller(
        releases: [nextRelease],
        resolver: (_) => Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/episode-2.mkv'),
            displayName: 'Episode 2',
            debridService: DebridService.realDebrid,
            playbackLease: lease,
          ),
        ),
      );
      final request = _request();

      final warmed = await controller.warm(request);
      expect(warmed, isNotNull);
      expect(warmed!.launch.episode.episode, 2);
      expect(warmed.launch.selectedRelease.infoHash, 'next');
      expect(lease.closeCount, 0);

      final taken = await controller.take(7, 1, currentRequest: request);
      expect(identical(taken, warmed), isTrue);
      expect(await controller.take(7, 1, currentRequest: request), isNull);

      await controller.dispose();
      expect(
        lease.closeCount,
        0,
        reason: 'ownership was transferred to player',
      );
      await taken!.launch.stream.playbackLease!.close();
      expect(lease.closeCount, 1);
    },
  );

  test(
    'exact target handoff transfers once and mismatches do not consume',
    () async {
      final lease = _FakeLease();
      final controller = _controller(
        releases: [_release(hash: 'watch-follow-next')],
        resolver: (_) => Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/watch-follow-2.mkv'),
            displayName: 'Watch follower episode 2',
            debridService: DebridService.realDebrid,
            playbackLease: lease,
          ),
        ),
      );
      await controller.warm(_request());

      expect(
        await controller.takePreparedTarget(mediaId: 8, episode: 2),
        isNull,
      );
      expect(
        await controller.takePreparedTarget(mediaId: 7, episode: 3),
        isNull,
      );
      expect(lease.closeCount, 0);

      final taken = await controller.takePreparedTarget(mediaId: 7, episode: 2);
      expect(taken?.launch.episode.anilistMediaId, 7);
      expect(taken?.launch.episode.episode, 2);
      expect(
        await controller.takePreparedTarget(mediaId: 7, episode: 2),
        isNull,
      );

      await controller.dispose();
      expect(
        lease.closeCount,
        0,
        reason: 'the exact handoff transferred lease ownership to its caller',
      );
      await taken!.launch.stream.playbackLease!.close();
      expect(lease.closeCount, 1);
    },
  );

  test(
    'target handoff leaves a settings mismatch available to its owner',
    () async {
      const preparedSettings = SettingsPreferences(
        preferredAudio: PlaybackAudioPreference.dub,
        autoPickSourceEnabled: true,
        autoPickSourceType: AutoPickSourceType.debridOnly,
        autoPickQuality: AutoPickQuality.p1080,
        autoPickAudio: AutoPickAudio.dubOnly,
      );
      var currentSettings = preparedSettings;
      final lease = _FakeLease();
      final controller = _controller(
        settingsReader: () => currentSettings,
        releases: [
          _release(hash: 'settings-bound-next', quality: '1080p', dubbed: true),
        ],
        resolver: (_) => Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/settings-bound-2.mkv'),
            displayName: 'Settings-bound episode 2',
            debridService: DebridService.realDebrid,
            playbackLease: lease,
          ),
        ),
      );
      await controller.warm(_request());

      currentSettings = const SettingsPreferences(
        preferredAudio: PlaybackAudioPreference.sub,
        autoPickSourceEnabled: true,
        autoPickSourceType: AutoPickSourceType.debridOnly,
        autoPickQuality: AutoPickQuality.p1080,
        autoPickAudio: AutoPickAudio.subOnly,
      );
      expect(
        await controller.takePreparedTarget(mediaId: 7, episode: 2),
        isNull,
      );
      expect(lease.closeCount, 0);

      currentSettings = preparedSettings;
      final taken = await controller.takePreparedTarget(mediaId: 7, episode: 2);
      expect(taken, isNotNull);
      await controller.dispose();
      expect(lease.closeCount, 0);
      await taken!.launch.stream.playbackLease!.close();
      expect(lease.closeCount, 1);
    },
  );

  test(
    'target handoff timeout observes without cancelling preparation',
    () async {
      final started = Completer<void>();
      var cancelled = false;
      final pending = StreamController<StreamResolution>(
        onListen: started.complete,
        onCancel: () => cancelled = true,
      );
      final controller = _controller(
        releases: [_release(hash: 'late-watch-follow')],
        resolver: (_) => pending.stream,
      );
      final warming = controller.warm(_request());
      await started.future;

      expect(
        await controller.takePreparedTarget(
          mediaId: 7,
          episode: 2,
          wait: const Duration(milliseconds: 10),
        ),
        isNull,
      );
      expect(cancelled, isFalse);

      pending.add(
        StreamReady(
          uri: Uri.parse('https://cdn.example/late-watch-follow-2.mkv'),
          displayName: 'Late watch follower episode 2',
          debridService: DebridService.realDebrid,
        ),
      );
      await pending.close();
      expect(await warming, isNotNull);
      expect(
        await controller.takePreparedTarget(mediaId: 7, episode: 2),
        isNotNull,
      );
      await controller.dispose();
    },
  );

  test(
    'same source and authoritative audio outrank a higher quality mismatch',
    () async {
      final attempted = <String>[];
      final sameDub = _release(
        hash: 'same-dub',
        provider: 'Same source',
        sourceId: 'stable-source',
        name: '[Group] Show - 02 Dual Audio 1080p',
        dubbed: true,
        quality: '1080p',
      );
      final otherSub = _release(
        hash: 'other-sub',
        provider: 'Other',
        sourceId: 'other-source',
        name: '[Other] Show - 02 4K',
        quality: '2160p',
      );
      final controller = _controller(
        releases: [otherSub, sameDub],
        resolver: (release) {
          attempted.add(release.infoHash);
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
              displayName: release.releaseName,
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final prepared = await controller.warm(_request());

      expect(prepared?.launch.selectedRelease.infoHash, 'same-dub');
      expect(attempted, ['same-dub']);
      await controller.dispose();
    },
  );

  test(
    'next-episode preparation keeps the current normalized quality first',
    () async {
      final attempted = <String>[];
      final sameQuality = _release(
        hash: 'same-quality',
        provider: 'Other provider',
        sourceId: 'other-source',
        name: '[Other] Show - 02 Full HD',
        quality: 'Full HD',
        seeders: 1,
      );
      final higher = _release(
        hash: 'higher',
        provider: 'Same source',
        sourceId: 'stable-source',
        name: '[Group] Show - 02 2160p',
        quality: '2160p',
        seeders: 1000,
      );
      final lower = _release(
        hash: 'lower',
        provider: 'Other lower',
        sourceId: 'lower-source',
        name: '[Lower] Show - 02 720p',
        quality: '720p',
        seeders: 2000,
      );
      final controller = _controller(
        releases: [higher, lower, sameQuality],
        resolver: (release) {
          attempted.add(release.infoHash);
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
              displayName: release.releaseName,
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final prepared = await controller.warm(_request());

      expect(prepared?.launch.selectedRelease.infoHash, 'same-quality');
      expect(attempted, ['same-quality']);
      await controller.dispose();
    },
  );

  test(
    'next-episode quality affinity fails open after the matching stream fails',
    () async {
      final attempted = <String>[];
      final sameQuality = _release(
        hash: 'failed-1080',
        provider: 'Other provider',
        sourceId: 'other-source',
        name: '[Other] Show - 02 1080p',
        quality: '1080p',
      );
      final higher = _release(
        hash: 'fallback-4k',
        provider: 'Same source',
        sourceId: 'stable-source',
        name: '[Group] Show - 02 2160p',
        quality: '2160p',
      );
      final lower = _release(
        hash: 'fallback-720',
        provider: 'Lower',
        sourceId: 'lower-source',
        name: '[Lower] Show - 02 720p',
        quality: '720p',
      );
      final controller = _controller(
        releases: [higher, lower, sameQuality],
        resolver: (release) {
          attempted.add(release.infoHash);
          if (release.infoHash == sameQuality.infoHash) {
            return Stream.error(StateError('1080p unavailable'));
          }
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
              displayName: release.releaseName,
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final prepared = await controller.warm(_request());

      expect(attempted.first, 'failed-1080');
      expect(attempted, hasLength(2));
      expect(prepared?.launch.selectedRelease.infoHash, isNot('failed-1080'));
      await controller.dispose();
    },
  );

  test(
    'Auto Pick keeps 1080p dub strict during next-episode prewarm',
    () async {
      final attempted = <String>[];
      final controller = _controller(
        settings: const SettingsPreferences(
          preferredAudio: PlaybackAudioPreference.dub,
          autoPickSourceEnabled: true,
          autoPickSourceType: AutoPickSourceType.debridOnly,
          autoPickQuality: AutoPickQuality.p1080,
          autoPickAudio: AutoPickAudio.dubOnly,
        ),
        releases: [
          _release(hash: 'wrong-quality', quality: '2160p', dubbed: true),
          _release(hash: 'wrong-audio', quality: '1080p', dubbed: false),
          _release(hash: 'allowed', quality: '1080p', dubbed: true),
        ],
        resolver: (release) {
          attempted.add(release.infoHash);
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
              displayName: release.releaseName,
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final prepared = await controller.warm(_request());

      expect(attempted, ['allowed']);
      expect(prepared?.launch.selectedRelease.infoHash, 'allowed');
      expect(prepared?.launch.alternatives, isEmpty);
      await controller.dispose();
    },
  );

  test('Auto Pick prewarm follows reordered quality priority', () async {
    final attempted = <String>[];
    final controller = _controller(
      settings: const SettingsPreferences(
        autoPickSourceEnabled: true,
        autoPickQualityPriority: [
          AutoPickQuality.p720,
          AutoPickQuality.p2160,
          AutoPickQuality.p1080,
          AutoPickQuality.p480,
        ],
        autoPickAudio: AutoPickAudio.dubOnly,
      ),
      releases: [
        _release(hash: 'quality-4k', quality: '2160p', dubbed: true),
        _release(hash: 'quality-720', quality: '720p', dubbed: true),
      ],
      resolver: (release) {
        attempted.add(release.infoHash);
        return Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
            displayName: release.releaseName,
            debridService: DebridService.realDebrid,
          ),
        );
      },
    );

    final prepared = await controller.warm(_request());

    expect(attempted, ['quality-720']);
    expect(prepared?.launch.selectedRelease.infoHash, 'quality-720');
    await controller.dispose();
  });

  test('Auto Pick prewarm follows reordered source priority', () async {
    var debridAttempts = 0;
    final controller = _controller(
      settings: const SettingsPreferences(
        autoPickSourceEnabled: true,
        autoPickSourcePriority: [
          AutoPickSourcePriority.web,
          AutoPickSourcePriority.debrid,
        ],
      ),
      releases: [_release(hash: 'source-debrid', quality: '1080p')],
      webStreams: [
        WebStreamResult(
          providerId: 'source-web',
          providerName: 'Source Web',
          title: 'Source Web 1080p',
          uri: Uri.parse('https://cdn.example/source-web.m3u8'),
          quality: '1080p',
          isDubbed: true,
        ),
      ],
      resolver: (release) {
        debridAttempts++;
        return Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
            displayName: release.releaseName,
            debridService: DebridService.realDebrid,
          ),
        );
      },
    );

    final prepared = await controller.warm(_request());

    expect(debridAttempts, 0);
    expect(prepared?.launch.stream.isWebStream, isTrue);
    expect(prepared?.launch.stream.providerId, 'source-web');
    await controller.dispose();
  });

  test('confirmed filler is skipped during preparation', () async {
    final controller = _controller(
      releases: [
        _release(hash: 'episode-3', name: '[Group] Show - 03 Dual Audio'),
      ],
      fillerRepository: _FillerRepository(
        FillerEpisodeLookup.confirmed(
          confirmedFillerEpisodes: const {2},
          source: FillerDataSource.jikanMalId,
          resolvedMalMediaId: 70,
          fetchedAt: DateTime.utc(2026),
          knownEpisodeCount: 12,
        ),
      ),
      resolver: (release) => Stream.value(
        StreamReady(
          uri: Uri.parse('https://cdn.example/episode-3.mkv'),
          displayName: release.releaseName,
          debridService: DebridService.realDebrid,
        ),
      ),
    );

    final prepared = await controller.warm(_request(skipFillerEpisodes: true));

    expect(prepared?.launch.episode.episode, 3);
    expect(prepared?.fillerDecision.skippedEpisodes, [2]);
    await controller.dispose();
  });

  test('dispose closes a prepared launch that was never transferred', () async {
    final lease = _FakeLease();
    final controller = _controller(
      releases: [_release(hash: 'next')],
      resolver: (_) => Stream.value(
        StreamReady(
          uri: Uri.parse('https://cdn.example/episode-2.mkv'),
          displayName: 'Episode 2',
          debridService: DebridService.realDebrid,
          playbackLease: lease,
        ),
      ),
    );
    await controller.warm(_request());

    await controller.dispose();

    expect(lease.closeCount, 1);
  });

  test('player exit abandons and closes a prepared launch', () async {
    final lease = _FakeLease();
    final request = _request();
    final controller = _controller(
      releases: [_release(hash: 'exit')],
      resolver: (_) => Stream.value(
        StreamReady(
          uri: Uri.parse('https://cdn.example/exit.mkv'),
          displayName: 'Exit',
          debridService: DebridService.realDebrid,
          playbackLease: lease,
        ),
      ),
    );
    await controller.warm(request);

    await controller.abandon(7, 1, currentRequest: request);

    expect(lease.closeCount, 1);
    expect(await controller.take(7, 1, currentRequest: request), isNull);
    await controller.dispose();
  });

  test('player exit cancels an in-flight resolver', () async {
    final started = Completer<void>();
    var cancelled = false;
    final blocked = StreamController<StreamResolution>(
      onListen: started.complete,
      onCancel: () => cancelled = true,
    );
    final request = _request();
    final controller = _controller(
      releases: [_release(hash: 'exit-pending')],
      resolver: (_) => blocked.stream,
    );
    final warming = controller.warm(request);
    await started.future;

    await controller.abandon(7, 1, currentRequest: request);

    expect(cancelled, isTrue);
    expect(await warming, isNull);
    await blocked.close();
    await controller.dispose();
  });

  test('a failed preparation slot can be retried', () async {
    var detailsCalls = 0;
    final controller = _controller(
      loadDetails: (_) async {
        detailsCalls++;
        if (detailsCalls == 1) throw StateError('temporary catalog failure');
        return _anime;
      },
      releases: [_release(hash: 'retry')],
      resolver: (_) => Stream.value(
        StreamReady(
          uri: Uri.parse('https://cdn.example/retry.mkv'),
          displayName: 'Retry',
          debridService: DebridService.realDebrid,
        ),
      ),
    );

    await expectLater(controller.warm(_request()), throwsStateError);
    final prepared = await controller.warm(_request());

    expect(prepared, isNotNull);
    expect(detailsCalls, 2);
    await controller.dispose();
  });

  test(
    'take timeout cancels the old resolver before fallback can race',
    () async {
      final started = Completer<void>();
      var cancelled = false;
      final blocked = StreamController<StreamResolution>(
        onListen: started.complete,
        onCancel: () => cancelled = true,
      );
      final attempted = <String>[];
      final controller = _controller(
        releases: [
          _release(hash: 'blocked'),
          _release(hash: 'must-not-run'),
        ],
        resolver: (release) {
          attempted.add(release.infoHash);
          if (release.infoHash == 'blocked') return blocked.stream;
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/unexpected.mkv'),
              displayName: 'Unexpected',
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final warming = controller.warm(_request());
      await started.future;
      final taken = await controller.take(
        7,
        1,
        currentRequest: _request(),
        wait: const Duration(milliseconds: 10),
      );

      expect(taken, isNull);
      expect(await warming, isNull);
      expect(cancelled, isTrue);
      expect(attempted, ['blocked']);
      await blocked.close();
      await controller.dispose();
    },
  );

  test('resolver timeout cancels candidate one before candidate two', () async {
    final blocked = StreamController<StreamResolution>();
    var firstCancelled = false;
    blocked.onCancel = () => firstCancelled = true;
    final attempted = <String>[];
    final controller = _controller(
      resolutionTimeout: const Duration(milliseconds: 10),
      releases: [
        _release(hash: 'first'),
        _release(hash: 'second'),
      ],
      resolver: (release) {
        attempted.add(release.infoHash);
        if (release.infoHash == 'first') return blocked.stream;
        return Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/second.mkv'),
            displayName: 'Second',
            debridService: DebridService.realDebrid,
          ),
        );
      },
    );

    final prepared = await controller.warm(_request());

    expect(firstCancelled, isTrue);
    expect(attempted, ['first', 'second']);
    expect(prepared?.launch.selectedRelease.infoHash, 'second');
    await blocked.close();
    await controller.dispose();
  });

  test(
    'prepared-next verification closes a mismatch and tries another release',
    () async {
      final wrongLease = _FakeLease();
      final correctLease = _FakeLease();
      final attempted = <String>[];
      final controller = _controller(
        releases: [
          _release(
            hash: 'wrong-episode',
            sourceId: 'stable-source',
            provider: 'Same source',
            name: '[Group] Show - 03 Dual Audio',
          ),
          _release(
            hash: 'correct-episode',
            sourceId: 'fallback-source',
            provider: 'Fallback source',
            name: '[Fallback] Show - 02 Dual Audio',
          ),
        ],
        resolver: (release) {
          attempted.add(release.infoHash);
          final wrong = release.infoHash == 'wrong-episode';
          return Stream.value(
            StreamReady(
              uri: Uri.parse(
                'https://cdn.example/${wrong ? 'episode-3' : 'episode-2'}.mkv',
              ),
              displayName: wrong ? 'Show S01E03.mkv' : 'Show S01E02.mkv',
              debridService: DebridService.realDebrid,
              playbackLease: wrong ? wrongLease : correctLease,
            ),
          );
        },
      );

      final prepared = await controller.warm(_request());

      expect(attempted, ['wrong-episode', 'correct-episode']);
      expect(prepared?.launch.selectedRelease.infoHash, 'correct-episode');
      expect(wrongLease.closeCount, 1);
      expect(correctLease.closeCount, 0);
      await controller.dispose();
      expect(correctLease.closeCount, 1);
    },
  );

  test(
    'prepared-next verification also advances past a wrong web episode',
    () async {
      final attempted = <Uri>[];
      final wrongUri = Uri.parse('https://web.example/episode-3.mp4');
      final correctUri = Uri.parse('https://web.example/episode-2.mp4');
      final controller = _controller(
        settings: const SettingsPreferences(
          preferredAudio: PlaybackAudioPreference.dub,
          streamSourcePriority: StreamSourcePriority.webFirst,
        ),
        releases: const [],
        webStreams: [
          WebStreamResult(
            providerId: 'current-web',
            providerName: 'Current Web',
            title: 'Episode 3 1080p Dub',
            uri: wrongUri,
            quality: '1080p',
            isDubbed: true,
          ),
          WebStreamResult(
            providerId: 'fallback-web',
            providerName: 'Fallback Web',
            title: 'Episode 2 1080p Dub',
            uri: correctUri,
            quality: '1080p',
            isDubbed: true,
          ),
        ],
        resolver: (_) => throw StateError('debrid must not run'),
        webPreflight: (uri, headers, {subtitleUri}) async {
          attempted.add(uri);
          return ValidatedWebStream(
            uri: uri,
            headers: headers,
            contentType: 'video/mp4',
          );
        },
      );

      final prepared = await controller.warm(
        _request(
          currentUri: 'https://web.example/episode-1.mp4',
          currentWebProviderId: 'current-web',
        ),
      );

      expect(attempted, [wrongUri, correctUri]);
      expect(prepared?.launch.stream.providerId, 'fallback-web');
      await controller.dispose();
    },
  );

  test(
    'prepared-next keeps an exact provider episode with a server ordinal label',
    () async {
      final attempted = <Uri>[];
      final uri = Uri.parse('https://web.example/episode-2.mp4');
      final controller = _controller(
        settings: const SettingsPreferences(
          preferredAudio: PlaybackAudioPreference.dub,
          streamSourcePriority: StreamSourcePriority.webFirst,
        ),
        releases: const [],
        webStreams: [
          WebStreamResult(
            providerId: 'structured-web',
            providerName: 'Structured Web',
            title: 'Server - 1',
            uri: uri,
            quality: '1080p',
            isDubbed: true,
            matchedEpisodeNumber: 2,
            matchedSeriesTitle: 'Show',
          ),
        ],
        resolver: (_) => throw StateError('debrid must not run'),
        webPreflight: (candidateUri, headers, {subtitleUri}) async {
          attempted.add(candidateUri);
          return ValidatedWebStream(
            uri: candidateUri,
            headers: headers,
            contentType: 'video/mp4',
          );
        },
      );

      final prepared = await controller.warm(
        _request(
          currentUri: 'https://web.example/episode-1.mp4',
          currentWebProviderId: 'structured-web',
        ),
      );

      expect(attempted, [uri]);
      expect(prepared?.launch.stream.providerId, 'structured-web');
      expect(prepared?.launch.stream.providerEpisodeIdentity?.episodeNumber, 2);
      await controller.dispose();
    },
  );

  test(
    'changed current stream replaces and closes stale preparation',
    () async {
      final firstLease = _FakeLease();
      final secondLease = _FakeLease();
      var calls = 0;
      final controller = _controller(
        releases: [_release(hash: 'next')],
        resolver: (_) {
          calls++;
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/next-$calls.mkv'),
              displayName: 'Next',
              debridService: DebridService.realDebrid,
              playbackLease: calls == 1 ? firstLease : secondLease,
            ),
          );
        },
      );
      await controller.warm(
        _request(currentUri: 'https://cdn.example/current-a.mkv'),
      );

      final replacement = await controller.warm(
        _request(currentUri: 'https://cdn.example/current-b.mkv'),
      );

      expect(calls, 2);
      expect(firstLease.closeCount, 1);
      expect(replacement?.launch.stream.uri.path, '/next-2.mkv');
      await controller.dispose();
      expect(secondLease.closeCount, 1);
    },
  );

  test(
    'take rejects a prepared launch after source or audio intent changes',
    () async {
      final staleLease = _FakeLease();
      final controller = _controller(
        releases: [_release(hash: 'stale-next')],
        resolver: (_) => Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/stale-next.mkv'),
            displayName: 'Stale next',
            debridService: DebridService.realDebrid,
            playbackLease: staleLease,
          ),
        ),
      );
      await controller.warm(
        _request(currentUri: 'https://cdn.example/provider-a.mkv'),
      );

      final taken = await controller.take(
        7,
        1,
        currentRequest: _request(
          currentUri: 'https://cdn.example/provider-b.mkv',
          audioLanguage: 'jpn',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(taken, isNull);
      expect(staleLease.closeCount, 1);
      await controller.dispose();
    },
  );

  test(
    'global source priority applies when the current source is absent',
    () async {
      final web = WebStreamResult(
        providerId: 'web-next',
        providerName: 'Web next',
        title: 'Episode 2',
        uri: Uri.parse('https://web.example/episode-2.mp4'),
        quality: '1080p',
        isDubbed: true,
      );
      final debrid = _release(
        hash: 'debrid-next',
        provider: 'Different provider',
        sourceId: 'different-source',
        name: 'Different release 1080p',
      );
      var debridAttempts = 0;
      NextEpisodePreparationController build(StreamSourcePriority priority) =>
          _controller(
            settings: SettingsPreferences(
              preferredAudio: PlaybackAudioPreference.dub,
              streamSourcePriority: priority,
            ),
            releases: [debrid],
            webStreams: [web],
            resolver: (_) {
              debridAttempts++;
              return Stream.value(
                StreamReady(
                  uri: Uri.parse('https://debrid.example/episode-2.mkv'),
                  displayName: 'Debrid',
                  debridService: DebridService.realDebrid,
                ),
              );
            },
          );

      final webFirst = build(StreamSourcePriority.webFirst);
      final webPrepared = await webFirst.warm(_request());
      expect(webPrepared?.launch.stream.isWebStream, isTrue);
      expect(debridAttempts, 0);
      await webFirst.dispose();

      final debridFirst = build(StreamSourcePriority.debridFirst);
      final debridPrepared = await debridFirst.warm(_request());
      expect(debridPrepared?.launch.selectedRelease.infoHash, 'debrid-next');
      expect(debridAttempts, 1);
      await debridFirst.dispose();
    },
  );

  test(
    'missing provider, source, and group do not create false affinity',
    () async {
      final attempted = <String>[];
      final controller = _controller(
        releases: [
          _release(
            hash: 'metadata-empty',
            provider: null,
            sourceId: '',
            name: 'Show Episode 2 1080p',
            quality: '1080p',
            seeders: 1,
          ),
          _release(
            hash: 'best-quality',
            provider: 'Other provider',
            sourceId: 'other-source',
            name: 'Show Episode 2 1080p',
            quality: '1080p',
            seeders: 100,
          ),
        ],
        resolver: (release) {
          attempted.add(release.infoHash);
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
              displayName: release.releaseName,
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final prepared = await controller.warm(
        _request(
          currentProvider: null,
          currentSourceId: '',
          currentReleaseName: 'Show Episode 1',
        ),
      );

      expect(prepared?.launch.selectedRelease.infoHash, 'best-quality');
      expect(attempted, ['best-quality']);
      await controller.dispose();
    },
  );

  test('Web playback uses the saved non-default debrid service', () async {
    DebridService? tokenService;
    final controller = _controller(
      settings: const SettingsPreferences(
        preferredAudio: PlaybackAudioPreference.dub,
        debridProvider: DebridService.torBox,
      ),
      readDebridToken: (service) async {
        tokenService = service;
        return 'token';
      },
      releases: [_release(hash: 'torbox-next')],
      resolver: (_) => Stream.value(
        StreamReady(
          uri: Uri.parse('https://torbox.example/episode-2.mkv'),
          displayName: 'TorBox',
          debridService: DebridService.torBox,
        ),
      ),
    );

    final prepared = await controller.warm(
      _request(
        currentUri: 'https://web.example/episode-1.mp4',
        currentWebProviderId: 'web-current',
      ),
    );

    expect(tokenService, DebridService.torBox);
    expect(prepared?.fallbackDebridService, DebridService.torBox);
    await controller.dispose();
  });

  test(
    'per-series H264 and no-batch filters lead automatic preparation',
    () async {
      final attempted = <String>[];
      final controller = _controller(
        releases: [
          _release(
            hash: 'hevc-batch',
            provider: 'Fast source',
            sourceId: 'fast-source',
            name: '[Fast] Show Batch 2160p HEVC',
            quality: '2160p',
            codec: 'HEVC',
            isBatch: true,
            seeders: 500,
          ),
          _release(
            hash: 'h264-episode',
            provider: 'Safe source',
            sourceId: 'safe-source',
            name: '[Safe] Show - 02 1080p x264',
            codec: 'H.264',
            seeders: 5,
          ),
        ],
        resolver: (release) {
          attempted.add(release.infoHash);
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
              displayName: release.releaseName,
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final prepared = await controller.warm(
        _request(
          currentProvider: 'Fast source',
          currentSourceId: 'fast-source',
          preferredCodec: 'h264',
          allowBatchStreams: false,
        ),
      );

      expect(prepared?.launch.selectedRelease.infoHash, 'h264-episode');
      expect(attempted, ['h264-episode']);
      await controller.dispose();
    },
  );

  test(
    'automatic preparation keeps device safety ahead of best quality',
    () async {
      final attempted = <String>[];
      final controller = _controller(
        settings: const SettingsPreferences(
          preferredAudio: PlaybackAudioPreference.dub,
          debridStreamSort: DebridStreamSort.bestQuality,
        ),
        readDeviceProfile: () async => const TvDeviceProfile(
          manufacturer: 'Test',
          model: 'AVC only',
          sdk: 36,
          abis: ['arm64-v8a'],
          displayModes: [],
          hdrTypes: [],
          codecs: [
            TvCodecCapability(
              name: 'AVC decoder',
              mime: 'video/avc',
              hardware: true,
            ),
          ],
          audioOutputs: [],
        ),
        readFailureCounts: (_) async => const {'unsafe-av1': 2},
        releases: [
          _release(
            hash: 'unsafe-av1',
            provider: 'Same source',
            sourceId: 'stable-source',
            name: '[Unsafe] Show - 02 2160p AV1',
            quality: '2160p',
            codec: 'AV1',
            seeders: 1000,
          ),
          _release(
            hash: 'safe-h264',
            provider: 'Safe',
            sourceId: 'safe',
            name: '[Safe] Show - 02 1080p x264',
            quality: '1080p',
            codec: 'H.264',
            seeders: 5,
          ),
        ],
        resolver: (release) {
          attempted.add(release.infoHash);
          return Stream.value(
            StreamReady(
              uri: Uri.parse('https://cdn.example/${release.infoHash}.mkv'),
              displayName: release.releaseName,
              debridService: DebridService.realDebrid,
            ),
          );
        },
      );

      final prepared = await controller.warm(_request());

      expect(prepared?.launch.selectedRelease.infoHash, 'safe-h264');
      expect(attempted, ['safe-h264']);
      await controller.dispose();
    },
  );

  test('saved 1080p Web quality leads a discovered 4K stream', () async {
    final controller = _controller(
      settings: const SettingsPreferences(
        preferredAudio: PlaybackAudioPreference.dub,
        streamSourcePriority: StreamSourcePriority.webFirst,
        webStreamQuality: WebStreamQualityPreference.bestAvailable,
      ),
      releases: const [],
      webStreams: [
        WebStreamResult(
          providerId: 'four-k',
          providerName: 'Four K',
          title: 'Episode 2 2160p',
          uri: Uri.parse('https://web.example/episode-2-4k.mp4'),
          quality: '2160p',
          isDubbed: true,
        ),
        WebStreamResult(
          providerId: 'full-hd',
          providerName: 'Full HD',
          title: 'Episode 2 1080p',
          uri: Uri.parse('https://web.example/episode-2-1080.mp4'),
          quality: '1080p',
          isDubbed: true,
        ),
      ],
      resolver: (_) => throw StateError('debrid must not run'),
    );

    final prepared = await controller.warm(
      _request(
        currentUri: 'https://web.example/episode-1.mp4',
        currentWebProviderId: 'four-k',
        preferredQuality: 'p1080',
      ),
    );

    expect(prepared?.launch.stream.providerId, 'full-hd');
    await controller.dispose();
  });

  test(
    'readiness expires with its lease even if the player flag stays set',
    () async {
      var now = DateTime.utc(2026, 8, 15, 12);
      final lease = _FakeLease();
      final request = _request();
      final controller = _controller(
        releases: [_release(hash: 'ttl-ready')],
        resolver: (_) => Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/ttl-ready.mkv'),
            displayName: 'TTL ready',
            debridService: DebridService.realDebrid,
            playbackLease: lease,
          ),
        ),
        preparedTtl: const Duration(minutes: 30),
        clock: () => now,
      );

      await controller.warm(request);
      expect(controller.hasReady(request), isTrue);

      now = now.add(const Duration(minutes: 31));
      expect(controller.hasReady(request), isFalse);
      await pumpEventQueue();
      expect(lease.closeCount, 1);

      await controller.dispose();
      expect(lease.closeCount, 1);
    },
  );

  test('changed series filters reject and close a prepared lease', () async {
    final lease = _FakeLease();
    final controller = _controller(
      releases: [
        _release(
          hash: 'filtered-next',
          name: '[Safe] Show - 02 1080p x264',
          codec: 'H.264',
        ),
      ],
      resolver: (_) => Stream.value(
        StreamReady(
          uri: Uri.parse('https://cdn.example/filtered-next.mkv'),
          displayName: 'Filtered next',
          debridService: DebridService.realDebrid,
          playbackLease: lease,
        ),
      ),
    );
    await controller.warm(_request(preferredCodec: 'h264'));

    final taken = await controller.take(
      7,
      1,
      currentRequest: _request(preferredCodec: 'hevc'),
    );

    expect(taken, isNull);
    expect(lease.closeCount, 1);
    await controller.dispose();
  });

  test('replacement waits for old resolver cancellation cleanup', () async {
    final listened = Completer<void>();
    final cleanupGate = Completer<void>();
    final blocked = StreamController<StreamResolution>(
      onListen: listened.complete,
      onCancel: () => cleanupGate.future,
    );
    var resolverCalls = 0;
    final controller = _controller(
      releases: [_release(hash: 'serialized')],
      resolver: (_) {
        resolverCalls++;
        if (resolverCalls == 1) return blocked.stream;
        return Stream.value(
          StreamReady(
            uri: Uri.parse('https://cdn.example/replacement.mkv'),
            displayName: 'Replacement',
            debridService: DebridService.realDebrid,
          ),
        );
      },
    );
    final oldWarm = controller.warm(
      _request(currentUri: 'https://cdn.example/current-a.mkv'),
    );
    await listened.future;

    final replacement = controller.warm(
      _request(currentUri: 'https://cdn.example/current-b.mkv'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(resolverCalls, 1);

    cleanupGate.complete();
    expect(await oldWarm, isNull);
    expect((await replacement)?.launch.stream.uri.path, '/replacement.mkv');
    expect(resolverCalls, 2);
    await blocked.close();
    await controller.dispose();
  });

  test(
    'take waits for cancellation cleanup before returning fallback',
    () async {
      final listened = Completer<void>();
      final cleanupGate = Completer<void>();
      final blocked = StreamController<StreamResolution>(
        onListen: listened.complete,
        onCancel: () => cleanupGate.future,
      );
      final controller = _controller(
        releases: [_release(hash: 'cleanup')],
        resolver: (_) => blocked.stream,
      );
      unawaited(controller.warm(_request()));
      await listened.future;
      var returned = false;
      final take = controller
          .take(
            7,
            1,
            currentRequest: _request(
              currentUri: 'https://cdn.example/changed.mkv',
            ),
          )
          .then((value) {
            returned = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(returned, isFalse);

      cleanupGate.complete();
      expect(await take, isNull);
      expect(returned, isTrue);
      await blocked.close();
      await controller.dispose();
    },
  );

  test(
    'one exact-source miss falls back to the globally preferred class',
    () async {
      final attempted = <String>[];
      final controller = _controller(
        settings: const SettingsPreferences(
          preferredAudio: PlaybackAudioPreference.dub,
          streamSourcePriority: StreamSourcePriority.webFirst,
        ),
        releases: [
          _release(
            hash: 'exact-miss',
            provider: 'Same source',
            sourceId: 'stable-source',
            name: '[Group] Show - 02 Dual Audio',
          ),
          _release(
            hash: 'unrelated-debrid',
            provider: 'Other',
            sourceId: 'other',
            name: '[Other] Show - 02 Dual Audio',
          ),
        ],
        webStreams: [
          WebStreamResult(
            providerId: 'ready-web',
            providerName: 'Ready Web',
            title: 'Episode 2 1080p Dub',
            uri: Uri.parse('https://web.example/episode-2.mp4'),
            quality: '1080p',
            isDubbed: true,
          ),
        ],
        resolver: (release) {
          attempted.add(release.infoHash);
          return const Stream.empty();
        },
      );

      final prepared = await controller.warm(_request());

      expect(attempted, ['exact-miss']);
      expect(prepared?.launch.stream.providerId, 'ready-web');
      await controller.dispose();
    },
  );

  test(
    'the first unaired episode is a terminal outcome without discovery',
    () async {
      var searches = 0;
      final controller = _controller(
        loadDetails: (_) async => const AnimeSummary(
          id: 7,
          idMal: 70,
          title: 'Airing Show',
          description: '',
          episodes: 12,
          score: null,
          nextAiringEpisode: 6,
        ),
        onReleaseSearch: () => searches++,
        releases: [_release(hash: 'unaired')],
        resolver: (_) => throw StateError('resolver must not run'),
      );

      final outcome = await controller.warmWithOutcome(
        _request(currentEpisode: 5),
      );

      expect(outcome.prepared, isNull);
      expect(outcome.isTerminal, isTrue);
      expect(
        outcome.terminalReason,
        NextEpisodePreparationTerminalReason.noNextEpisode,
      );
      expect(searches, 0);
      await controller.dispose();
    },
  );

  test('the last aired episode before next airing may be prepared', () async {
    final controller = _controller(
      loadDetails: (_) async => const AnimeSummary(
        id: 7,
        idMal: 70,
        title: 'Airing Show',
        description: '',
        episodes: 12,
        score: null,
        nextAiringEpisode: 6,
      ),
      releases: [_release(hash: 'aired-five')],
      resolver: (_) => Stream.value(
        StreamReady(
          uri: Uri.parse('https://cdn.example/episode-5.mkv'),
          displayName: 'Episode 5',
          debridService: DebridService.realDebrid,
        ),
      ),
    );

    final outcome = await controller.warmWithOutcome(
      _request(currentEpisode: 4),
    );

    expect(outcome.prepared?.launch.episode.episode, 5);
    expect(outcome.isTerminal, isFalse);
    await controller.dispose();
  });

  test('filler skipping never jumps into the first unaired episode', () async {
    var searches = 0;
    final controller = _controller(
      loadDetails: (_) async => const AnimeSummary(
        id: 7,
        idMal: 70,
        title: 'Airing Filler Show',
        description: '',
        episodes: 12,
        score: null,
        nextAiringEpisode: 7,
      ),
      fillerRepository: _FillerRepository(
        FillerEpisodeLookup.confirmed(
          confirmedFillerEpisodes: const {6},
          source: FillerDataSource.jikanMalId,
          resolvedMalMediaId: 70,
          fetchedAt: DateTime.utc(2026),
          knownEpisodeCount: 12,
        ),
      ),
      onReleaseSearch: () => searches++,
      releases: [_release(hash: 'must-not-search')],
      resolver: (_) => throw StateError('resolver must not run'),
    );

    final outcome = await controller.warmWithOutcome(
      _request(currentEpisode: 5, skipFillerEpisodes: true),
    );

    expect(outcome.prepared, isNull);
    expect(
      outcome.terminalReason,
      NextEpisodePreparationTerminalReason.noNextEpisode,
    );
    expect(searches, 0);
    await controller.dispose();
  });
}

NextEpisodePreparationController _controller({
  required List<ReleaseCandidate> releases,
  required Stream<StreamResolution> Function(ReleaseCandidate release) resolver,
  Future<AnimeSummary> Function(int mediaId)? loadDetails,
  List<WebStreamResult> webStreams = const [],
  SettingsPreferences settings = const SettingsPreferences(
    preferredAudio: PlaybackAudioPreference.dub,
  ),
  SettingsPreferences Function()? settingsReader,
  DebridTokenReader? readDebridToken,
  Duration resolutionTimeout = const Duration(seconds: 20),
  FillerEpisodeRepository? fillerRepository,
  void Function()? onReleaseSearch,
  DeviceProfileReader? readDeviceProfile,
  PlaybackFailureCountsReader? readFailureCounts,
  LibraryNextEpisodePreparer? prepareLibraryEpisode,
  DownloadedNextEpisodePreparer? prepareDownloadedEpisode,
  Duration preparedTtl = const Duration(minutes: 30),
  DateTime Function()? clock,
  WebStreamPreflight? webPreflight,
}) => NextEpisodePreparationController(
  loadDetails: loadDetails ?? (_) async => _anime,
  fillerRepository:
      fillerRepository ?? _FillerRepository(FillerEpisodeLookup.unavailable()),
  releaseSearch: (_) {
    onReleaseSearch?.call();
    return Stream.value(
      ReleaseSearchProgress(
        candidates: releases,
        completedSources: 1,
        totalSources: 1,
      ),
    );
  },
  webSearch: (_) => Stream.value(
    WebStreamSearchProgress(
      aggregation: WebStreamAggregation(streams: webStreams),
      completedProviders: webStreams.isEmpty ? 0 : 1,
      totalProviders: webStreams.isEmpty ? 0 : 1,
    ),
  ),
  readDebridToken: readDebridToken ?? (_) async => 'token',
  readSettings: settingsReader ?? () => settings,
  readDeviceProfile: readDeviceProfile,
  readFailureCounts: readFailureCounts,
  prepareLibraryEpisode: prepareLibraryEpisode,
  prepareDownloadedEpisode: prepareDownloadedEpisode,
  resolverFactory: ({required service, required token, required source}) {
    final selected = (source as SingleReleaseSource).release;
    return _Resolver(() => resolver(selected));
  },
  webPreflight:
      webPreflight ??
      (Uri uri, Map<String, String> headers, {Uri? subtitleUri}) async =>
          ValidatedWebStream(
            uri: uri,
            headers: headers,
            contentType: 'video/mp4',
          ),
  resolutionTimeout: resolutionTimeout,
  preparedTtl: preparedTtl,
  clock: clock,
);

NextEpisodePreparationRequest _request({
  bool skipFillerEpisodes = false,
  String currentUri = 'https://cdn.example/episode-1.mkv',
  String? currentWebProviderId,
  String audioLanguage = 'eng',
  String? currentProvider = 'Same source',
  String currentSourceId = 'stable-source',
  String currentReleaseName = '[Group] Show - 01 Dual Audio',
  String preferredQuality = 'any',
  String preferredCodec = 'any',
  String preferredHdrMode = 'any',
  bool allowBatchStreams = true,
  String streamSortMode = 'compatibility',
  String? preferredReleaseProvider,
  String? preferredReleaseGroup,
  int currentEpisode = 1,
}) {
  final current = _release(
    hash: 'current',
    provider: currentProvider,
    sourceId: currentSourceId,
    name: currentReleaseName,
    dubbed: true,
  );
  return NextEpisodePreparationRequest(
    currentLaunch: PlaybackLaunch(
      stream: StreamReady(
        uri: Uri.parse(currentUri),
        displayName: 'Episode 1',
        debridService: currentWebProviderId == null
            ? DebridService.realDebrid
            : null,
        providerId: currentWebProviderId,
        providerName: currentWebProviderId == null ? null : 'Web current',
      ),
      episode: EpisodeReference(
        anilistMediaId: 7,
        malMediaId: 70,
        title: 'Show',
        episode: currentEpisode,
      ),
      selectedRelease: current,
    ),
    seriesPreferences: SeriesPlaybackPreferences(
      audioLanguage: audioLanguage,
      audioPreferenceSet: true,
      skipFillerEpisodes: skipFillerEpisodes,
      preferredQuality: preferredQuality,
      preferredCodec: preferredCodec,
      preferredHdrMode: preferredHdrMode,
      allowBatchStreams: allowBatchStreams,
      streamSortMode: streamSortMode,
      preferredReleaseProvider: preferredReleaseProvider,
      preferredReleaseGroup: preferredReleaseGroup,
    ),
    debridService: DebridService.realDebrid,
  );
}

ReleaseCandidate _release({
  required String hash,
  String? provider = 'Provider',
  String sourceId = 'source',
  String name = '[Group] Show - 02',
  bool dubbed = true,
  String quality = '1080p',
  String? codec,
  bool isBatch = false,
  bool isHdr = false,
  int seeders = 10,
}) => ReleaseCandidate(
  infoHash: hash,
  magnetUri: 'magnet:?xt=urn:btih:$hash',
  releaseName: name,
  seeders: seeders,
  sourceId: sourceId,
  provider: provider,
  quality: quality,
  codec: codec,
  isBatch: isBatch,
  isHdr: isHdr,
  isDubbed: dubbed,
);

const _anime = AnimeSummary(
  id: 7,
  idMal: 70,
  title: 'Show',
  description: '',
  episodes: 12,
  score: null,
  synonyms: ['Alternate Show'],
  seasonYear: 2026,
);

class _Resolver implements StreamResolver {
  const _Resolver(this.create);

  final Stream<StreamResolution> Function() create;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) => create();
}

class _FillerRepository implements FillerEpisodeRepository {
  const _FillerRepository(this.result);

  final FillerEpisodeLookup result;

  @override
  Future<FillerEpisodeLookup> lookup(
    FillerSeriesIdentity identity, {
    bool forceRefresh = false,
  }) async => result;
}

class _FakeLease implements PlaybackResourceLease {
  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
  }
}
