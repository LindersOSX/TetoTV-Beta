import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/downloads/application/download_manager_controller.dart';
import 'package:anime_tv/features/downloads/domain/download_job.dart';
import 'package:anime_tv/features/local_media/application/library_episode_source_service.dart';
import 'package:anime_tv/features/local_media/domain/jellyfin_models.dart';
import 'package:anime_tv/features/local_media/domain/library_episode_source.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/web_stream_validator.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/player/domain/library_playback_request.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/data/composite_release_source.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/streaming/domain/stream_ranking_preferences.dart';
import 'package:anime_tv/features/streaming/presentation/resolve_episode_screen.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('download preparation keeps actionable provider failures', () {
    final rateLimited = RealDebridException.rateLimited(
      retryAfter: const Duration(seconds: 30),
    );

    expect(
      offlineDownloadPreparationMessage(rateLimited),
      contains('30 seconds'),
    );
    expect(
      offlineDownloadPreparationReasonCode(rateLimited),
      'real_debrid_rateLimited',
    );
    expect(
      offlineDownloadPreparationMessage(StateError('private URL here')),
      isNot(contains('private URL here')),
    );
  });

  test('expected debrid outcomes stay out of process-crash reports', () {
    expect(
      shouldRecordResolveCrashReport(RealDebridException.fromApi(code: 35)),
      isFalse,
    );
    expect(
      shouldRecordResolveCrashReport(
        RealDebridException.rateLimited(
          retryAfter: const Duration(seconds: 29),
        ),
      ),
      isFalse,
    );
    expect(
      shouldRecordResolveCrashReport(
        const DebridCacheMissException(DebridService.realDebrid),
      ),
      isFalse,
    );
    expect(
      shouldRecordResolveCrashReport(StateError('unexpected player bug')),
      isTrue,
    );
  });

  test('download source revision reacts only to matching completions', () {
    final now = DateTime.utc(2026, 8, 24);
    DownloadJob job({
      required String id,
      required int mediaId,
      required int episode,
      required DownloadJobStatus status,
    }) => DownloadJob(
      id: id,
      anilistMediaId: mediaId,
      episode: episode,
      seriesTitle: 'Example',
      sourceLabel: 'Download',
      transport: DownloadTransport.https,
      status: status,
      relativePath: '$mediaId/$id.mkv',
      queuePosition: 0,
      createdAt: now,
      updatedAt: now,
    );

    final empty = completedDownloadRevisionForEpisode(
      DownloadManagerState(initialized: true),
      anilistMediaId: 10,
      episode: 2,
    );
    final incompleteAndUnrelated = completedDownloadRevisionForEpisode(
      DownloadManagerState(
        initialized: true,
        jobs: [
          job(
            id: 'downloading',
            mediaId: 10,
            episode: 2,
            status: DownloadJobStatus.downloading,
          ),
          job(
            id: 'failed',
            mediaId: 10,
            episode: 2,
            status: DownloadJobStatus.failed,
          ),
          job(
            id: 'other-episode',
            mediaId: 10,
            episode: 3,
            status: DownloadJobStatus.completed,
          ),
          job(
            id: 'other-show',
            mediaId: 11,
            episode: 2,
            status: DownloadJobStatus.completed,
          ),
        ],
      ),
      anilistMediaId: 10,
      episode: 2,
    );
    final completed = completedDownloadRevisionForEpisode(
      DownloadManagerState(
        initialized: true,
        jobs: [
          job(
            id: 'matching-complete',
            mediaId: 10,
            episode: 2,
            status: DownloadJobStatus.completed,
          ),
        ],
      ),
      anilistMediaId: 10,
      episode: 2,
    );

    expect(incompleteAndUnrelated, empty);
    expect(completed, isNot(empty));
    expect(completed, contains('matching-complete'));

    final catalogFallback = completedDownloadRevisionForEpisode(
      DownloadManagerState(
        initialized: true,
        jobs: [
          DownloadJob(
            id: 'fallback-complete',
            anilistMediaId: 99,
            malMediaId: 10,
            episode: 2,
            seriesTitle: 'Lucky☆Star',
            sourceLabel: 'Download',
            transport: DownloadTransport.https,
            status: DownloadJobStatus.completed,
            relativePath: '99/fallback-complete.mkv',
            queuePosition: 0,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      ),
      anilistMediaId: 100,
      malMediaId: 10,
      episode: 2,
      seriesTitles: const ['Lucky Star'],
    );
    expect(catalogFallback, contains('fallback-complete'));
  });

  test('offline web download blocks external caption sidecars', () {
    final stream = WebStreamResult(
      providerId: 'provider',
      providerName: 'Provider',
      title: 'Episode',
      uri: Uri.parse('https://cdn.example.com/episode.m3u8'),
      subtitleUri: Uri.parse('https://cdn.example.com/episode.vtt'),
    );

    expect(webStreamRequiresExternalSubtitleDownload(stream), isTrue);
    expect(
      webStreamRequiresExternalSubtitleDownload(
        WebStreamResult(
          providerId: 'provider',
          providerName: 'Provider',
          title: 'Embedded captions',
          uri: Uri.parse('https://cdn.example.com/embedded.m3u8'),
        ),
      ),
      isFalse,
    );
  });

  test('Auto Pick advances after failed compatibility but not a user exit', () {
    const failed = LibraryPlaybackResult(
      position: Duration.zero,
      duration: Duration.zero,
      reason: LibraryPlaybackEndReason.failed,
      started: false,
    );
    const exited = LibraryPlaybackResult(
      position: Duration(seconds: 20),
      duration: Duration(minutes: 24),
      reason: LibraryPlaybackEndReason.exited,
      started: true,
    );
    const preparationFailed = LibraryPlaybackResult(
      position: Duration.zero,
      duration: Duration.zero,
      reason: LibraryPlaybackEndReason.failed,
      started: false,
      failureStage: LibraryPlaybackFailureStage.preparation,
    );

    expect(
      libraryPlaybackRecoveryAction(
        result: failed,
        supportsCompatibilityTranscode: true,
        usedCompatibilityStream: false,
      ),
      LibraryPlaybackRecoveryAction.retryCompatibility,
    );
    expect(
      libraryPlaybackRecoveryAction(
        result: failed,
        supportsCompatibilityTranscode: true,
        usedCompatibilityStream: true,
      ),
      LibraryPlaybackRecoveryAction.advanceSource,
    );
    expect(
      libraryPlaybackRecoveryAction(
        result: failed,
        supportsCompatibilityTranscode: false,
        usedCompatibilityStream: false,
      ),
      LibraryPlaybackRecoveryAction.advanceSource,
    );
    expect(
      libraryPlaybackRecoveryAction(
        result: exited,
        supportsCompatibilityTranscode: true,
        usedCompatibilityStream: false,
      ),
      LibraryPlaybackRecoveryAction.finish,
    );
    expect(
      libraryPlaybackRecoveryAction(
        result: preparationFailed,
        supportsCompatibilityTranscode: true,
        usedCompatibilityStream: false,
      ),
      LibraryPlaybackRecoveryAction.advanceSource,
      reason: 'a proxy preparation failure cannot be fixed by transcoding',
    );
  });

  test('similar releases prefer the same group, then provider', () {
    const sameGroup = ReleaseCandidate(
      infoHash: '1111111111111111111111111111111111111111',
      magnetUri: 'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
      releaseName: '[SubsPlease] Show - 02 [1080p].mkv',
      seeders: 5,
      sourceId: 'other-source',
      provider: 'Other provider',
    );
    const sameProvider = ReleaseCandidate(
      infoHash: '2222222222222222222222222222222222222222',
      magnetUri: 'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
      releaseName: '[Different] Show - 02 [1080p].mkv',
      seeders: 500,
      sourceId: 'preferred-source',
      provider: 'Preferred provider',
    );
    const unrelated = ReleaseCandidate(
      infoHash: '3333333333333333333333333333333333333333',
      magnetUri: 'magnet:?xt=urn:btih:3333333333333333333333333333333333333333',
      releaseName: '[Other] Show - 02 [1080p].mkv',
      seeders: 900,
      sourceId: 'other-source',
      provider: 'Other provider',
    );
    final releases = [unrelated, sameProvider, sameGroup]
      ..sort(
        (left, right) => compareStreamReleases(
          left,
          right,
          preferredProvider: 'Preferred provider',
          preferredReleaseGroup: 'subsplease',
        ),
      );

    expect(releases, [sameGroup, sameProvider, unrelated]);
    expect(releaseGroupKey('[SubsPlease] Show - 02'), 'subsplease');
    expect(releaseGroupKey('Show - 02'), isNull);
  });

  testWidgets(
    'Watch Together autoplay opens the host source fingerprint first',
    (tester) async {
      const hostSource = ReleaseCandidate(
        infoHash: '1111111111111111111111111111111111111111',
        magnetUri:
            'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
        releaseName: '[Host Group] Show - 02 [720p]',
        seeders: 1,
        sourceId: 'host-source',
        quality: '720p',
        isDubbed: true,
      );
      const normallyPreferred = ReleaseCandidate(
        infoHash: '2222222222222222222222222222222222222222',
        magnetUri:
            'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
        releaseName: '[Popular Group] Show - 02 [1080p]',
        seeders: 500,
        sourceId: 'popular-source',
        quality: '1080p',
        isDubbed: true,
      );
      final descriptor = WatchPartySourceDescriptor.forRelease(hostSource);

      final launch = await _pumpAutoplayLaunch(
        tester,
        mediaId: 900001,
        releases: const [normallyPreferred, hostSource],
        watchPartyFollow: true,
        watchPartySourceClass: descriptor.sourceClass.name,
        watchPartySourceFingerprint: descriptor.fingerprint,
        watchPartySourceKey: descriptor.sourceKey,
      );

      expect(launch.selectedRelease.infoHash, hostSource.infoHash);
    },
  );

  test(
    'autoplay affinity prefers provider plus author, then provider, then rank',
    () {
      const exact = ReleaseCandidate(
        infoHash: '1111111111111111111111111111111111111111',
        magnetUri:
            'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
        releaseName: '[Same Group] Show - 02 English Dub',
        seeders: 1,
        sourceId: 'exact',
        provider: 'Same Provider',
        isDubbed: true,
      );
      const providerOnly = ReleaseCandidate(
        infoHash: '2222222222222222222222222222222222222222',
        magnetUri:
            'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
        releaseName: '[Other Group] Show - 02 English Dub',
        seeders: 500,
        sourceId: 'provider',
        provider: 'Same Provider',
        isDubbed: true,
      );
      const global = ReleaseCandidate(
        infoHash: '3333333333333333333333333333333333333333',
        magnetUri:
            'magnet:?xt=urn:btih:3333333333333333333333333333333333333333',
        releaseName: '[Other Group] Show - 02 English Dub',
        seeders: 5000,
        sourceId: 'global',
        provider: 'Other Provider',
        isDubbed: true,
      );
      final releases = [global, providerOnly, exact]
        ..sort(
          (left, right) => compareAutoplayReleases(
            left,
            right,
            preferredProvider: ' same provider ',
            preferredAuthor: '[Same Group]',
            preferredAudio: PlaybackAudioPreference.dub,
          ),
        );

      expect(releases, [exact, providerOnly, global]);
    },
  );

  test('autoplay affinity never overrides the preferred audio class', () {
    const preferredProviderSub = ReleaseCandidate(
      infoHash: '1111111111111111111111111111111111111111',
      magnetUri: 'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
      releaseName: '[Same Group] Show - 02',
      seeders: 500,
      sourceId: 'sub',
      provider: 'Same Provider',
    );
    const otherProviderDub = ReleaseCandidate(
      infoHash: '2222222222222222222222222222222222222222',
      magnetUri: 'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
      releaseName: '[Other Group] Show - 02 English Dub',
      seeders: 1,
      sourceId: 'dub',
      provider: 'Other Provider',
      isDubbed: true,
    );

    expect(
      compareAutoplayReleases(
        otherProviderDub,
        preferredProviderSub,
        preferredProvider: 'Same Provider',
        preferredAuthor: 'Same Group',
        preferredAudio: PlaybackAudioPreference.dub,
      ),
      lessThan(0),
    );
  });

  test('stable source affinity survives a provider change with both hints', () {
    const sameSource = ReleaseCandidate(
      infoHash: '1111111111111111111111111111111111111111',
      magnetUri: 'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
      releaseName: '[Same Group] Same source English Dub',
      seeders: 1,
      sourceId: 'same-source',
      provider: 'Renamed Provider',
      isDubbed: true,
    );
    const providerMatch = ReleaseCandidate(
      infoHash: '2222222222222222222222222222222222222222',
      magnetUri: 'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
      releaseName: '[Other Group] Provider match English Dub',
      seeders: 2,
      sourceId: 'other-source',
      provider: 'Preferred Provider',
      isDubbed: true,
    );

    expect(
      compareAutoplayReleases(
        sameSource,
        providerMatch,
        preferredProvider: 'Preferred Provider',
        preferredSourceId: 'same-source',
        preferredAuthor: 'Same Group',
        preferredAudio: PlaybackAudioPreference.dub,
      ),
      lessThan(0),
    );
  });

  test('author-only affinity ranks above an unrelated release', () {
    const sameAuthor = ReleaseCandidate(
      infoHash: '3333333333333333333333333333333333333333',
      magnetUri: 'magnet:?xt=urn:btih:3333333333333333333333333333333333333333',
      releaseName: '[Same Group] Author-only English Dub',
      seeders: 1,
      sourceId: 'other-source',
      provider: 'Other Provider',
      isDubbed: true,
    );
    const unrelated = ReleaseCandidate(
      infoHash: '4444444444444444444444444444444444444444',
      magnetUri: 'magnet:?xt=urn:btih:4444444444444444444444444444444444444444',
      releaseName: '[Unrelated] Global English Dub',
      seeders: 5000,
      sourceId: 'global-source',
      provider: 'Global Provider',
      isDubbed: true,
    );

    expect(
      compareAutoplayReleases(
        sameAuthor,
        unrelated,
        preferredProvider: 'Preferred Provider',
        preferredSourceId: 'same-source',
        preferredAuthor: 'Same Group',
        preferredAudio: PlaybackAudioPreference.dub,
      ),
      lessThan(0),
    );
  });

  test('resolver Web ranking bridges the saved soft quality preference', () {
    final p1080 = _providerWebStream(
      providerId: '1080',
      providerName: 'Provider',
      quality: '1080p',
    );
    final p720 = _providerWebStream(
      providerId: '720',
      providerName: 'Provider',
      quality: '720p',
    );

    expect(
      compareAutoplayWebStreams(
        p720,
        p1080,
        preferredAudio: PlaybackAudioPreference.dub,
        qualityPreference: WebStreamQualityPreference.p720,
      ),
      lessThan(0),
    );
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.tetotv/android_tv'),
          (call) async =>
              call.method == 'getDeviceProfile' ? <String, Object?>{} : null,
        );
  });

  tearDown(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.tetotv/android_tv'),
          null,
        );
  });

  testWidgets('saved Web-first preference orders picker source sections', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
      'streaming_source_priority': 'webFirst',
      'streaming_web_quality_preference': 'p720',
    });
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _FakeReleaseSource(),
          ),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator([
              _providerWebStream(
                providerId: 'web-1080',
                providerName: 'Web 1080',
                quality: '1080p',
              ),
              _providerWebStream(
                providerId: 'web-720',
                providerName: 'Web 720',
                quality: '720p',
              ),
            ]),
          ),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 88001,
              title: 'Ranked Picker',
              episode: 1,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('DEBRID STREAMS'));
    expect(find.text('WEB STREAMS'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('WEB STREAMS')).dy,
      lessThan(tester.getTopLeft(find.text('DEBRID STREAMS')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Web 720 720p')).dy,
      lessThan(tester.getTopLeft(find.text('Web 1080 1080p')).dy),
    );
  });

  testWidgets('Web-first autoplay selects Web when audio ranks match', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
      'streaming_source_priority': 'webFirst',
    });
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final web = _providerWebStream(
      providerId: 'preferred-class',
      providerName: 'Preferred class',
      quality: '1080p',
    );
    PlaybackLaunch? opened;
    var debridCalls = 0;
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 88002,
              malMediaId: 1887,
              title: 'Source Priority',
              episode: 18,
              autoPlay: true,
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, state) {
            opened = state.extra! as PlaybackLaunch;
            return Scaffold(
              body: Text(
                opened!.stream.isWebStream
                    ? 'WEB PRIORITY OPENED'
                    : 'WRONG SOURCE OPENED',
              ),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _FakeReleaseSource(),
          ),
          addonStoreProvider.overrideWithValue(_NoopAddonStore()),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator([web]),
          ),
          webStreamPreflightProvider.overrideWithValue((
            uri,
            headers, {
            subtitleUri,
          }) async {
            return ValidatedWebStream(
              uri: uri,
              headers: headers,
              contentType: 'application/vnd.apple.mpegurl',
            );
          }),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            debridCalls++;
            return const _ReadyResolver();
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await _pumpUntilFound(tester, find.text('WEB PRIORITY OPENED'));
    expect(find.text('WRONG SOURCE OPENED'), findsNothing);
    expect(debridCalls, 0);
    expect(opened?.episode.anilistMediaId, 88002);
    expect(opened?.episode.malMediaId, 1887);
    expect(opened?.episode.episode, 18);
  });

  testWidgets(
    'Web launch and direct alternatives retain trusted episode identity',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
        'streaming_source_priority': 'webFirst',
      });
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final primary = WebStreamResult(
        providerId: 'structured-primary',
        providerName: 'Structured primary',
        title: 'Server - 1',
        uri: Uri.parse('https://cdn.example/episode-18-primary.m3u8'),
        quality: '1080p',
        isDubbed: true,
        matchedEpisodeNumber: 18,
        matchedSeasonNumber: 1,
        matchedSeriesTitle: 'Identity Show',
      );
      final alternative = WebStreamResult(
        providerId: 'structured-alternative',
        providerName: 'Structured alternative',
        title: 'Server - 1',
        uri: Uri.parse('https://cdn.example/episode-18-alternative.m3u8'),
        quality: '720p',
        isDubbed: true,
        matchedEpisodeNumber: 18,
        matchedSeasonNumber: 1,
        matchedSeriesTitle: 'Identity Show',
      );
      PlaybackLaunch? opened;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 88003,
                title: 'Identity Show Season 1',
                episode: 18,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('STRUCTURED WEB PLAYER OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _FakeReleaseSource(),
            ),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([primary, alternative]),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('STRUCTURED WEB PLAYER OPENED'));
      expect(opened?.stream.providerId, 'structured-primary');
      expect(opened?.stream.providerEpisodeIdentity?.episodeNumber, 18);
      expect(opened?.stream.providerEpisodeIdentity?.seasonNumber, 1);
      expect(
        opened?.stream.providerEpisodeIdentity?.seriesTitle,
        'Identity Show',
      );
      expect(opened?.directAlternatives, hasLength(1));
      expect(
        opened
            ?.directAlternatives
            .single
            .stream
            .providerEpisodeIdentity
            ?.episodeNumber,
        18,
      );
    },
  );

  testWidgets('failed Web-first candidate waits for pending Debrid discovery', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
      'streaming_source_priority': 'webFirst',
    });
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final slowDebrid = Completer<List<ReleaseCandidate>>();
    final failedWeb = _providerWebStream(
      providerId: 'broken-web',
      providerName: 'Broken Web',
      quality: '1080p',
    );
    const recoveredDebrid = ReleaseCandidate(
      infoHash: '8888888888888888888888888888888888888888',
      magnetUri: 'magnet:?xt=urn:btih:8888888888888888888888888888888888888888',
      releaseName: '[Recovered] Show - 02 1080p English Dub',
      seeders: 20,
      sourceId: 'slow-debrid',
      provider: 'Recovered Debrid',
      isDubbed: true,
      quality: '1080p',
      codec: 'H.264',
    );
    PlaybackLaunch? opened;
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 88004,
              title: 'Pending Debrid Recovery',
              episode: 2,
              autoPlay: true,
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, state) {
            opened = state.extra! as PlaybackLaunch;
            return const Scaffold(body: Text('PENDING DEBRID RECOVERY OPENED'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            CompositeReleaseSource([
              _CallbackReleaseSource('slow-debrid', () => slowDebrid.future),
            ]),
          ),
          addonStoreProvider.overrideWithValue(_NoopAddonStore()),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator([failedWeb]),
          ),
          webStreamPreflightProvider.overrideWithValue((
            uri,
            headers, {
            subtitleUri,
          }) async {
            throw const FormatException('broken web stream');
          }),
          debridStreamResolverFactoryProvider.overrideWithValue(
            ({required service, required token, required source}) =>
                const _ReadyResolver(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await _pumpUntilFound(
      tester,
      find.text('Web streams failed. Waiting for Debrid sources…'),
    );
    expect(find.text('No playable stream'), findsNothing);
    slowDebrid.complete(const [recoveredDebrid]);
    await _pumpUntilFound(tester, find.text('PENDING DEBRID RECOVERY OPENED'));
    expect(opened, isNotNull);
    expect(opened!.stream.isWebStream, isFalse);
    expect(opened!.selectedRelease, recoveredDebrid);
  });

  testWidgets('Web-first autoplay never overrides matching Dub audio', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
      'streaming_source_priority': 'webFirst',
    });
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final subOnlyWeb = _providerWebStream(
      providerId: 'sub-only',
      providerName: 'Sub only',
      quality: '1080p',
      isDubbed: false,
    );
    var debridCalls = 0;
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 88003,
              title: 'Audio Safety',
              episode: 1,
              autoPlay: true,
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, state) => Scaffold(
            body: Text(
              (state.extra! as PlaybackLaunch).stream.isWebStream
                  ? 'WRONG AUDIO SOURCE'
                  : 'MATCHING DUB OPENED',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _FakeReleaseSource(),
          ),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator([subOnlyWeb]),
          ),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            debridCalls++;
            return const _ReadyResolver();
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await _pumpUntilFound(tester, find.text('MATCHING DUB OPENED'));
    expect(find.text('WRONG AUDIO SOURCE'), findsNothing);
    expect(debridCalls, 1);
  });

  testWidgets(
    'strict H264 single episode beats an exact-source HEVC batch fallback',
    (tester) async {
      const exactFallback = ReleaseCandidate(
        infoHash: '1010101010101010101010101010101010101010',
        magnetUri:
            'magnet:?xt=urn:btih:1010101010101010101010101010101010101010',
        releaseName: '[Fast] Show Batch 2160p HEVC English Dub',
        seeders: 500,
        sourceId: 'fast-source',
        provider: 'Fast Provider',
        isDubbed: true,
        isBatch: true,
        quality: '2160p',
        codec: 'HEVC',
      );
      const strict = ReleaseCandidate(
        infoHash: '2020202020202020202020202020202020202020',
        magnetUri:
            'magnet:?xt=urn:btih:2020202020202020202020202020202020202020',
        releaseName: '[Safe] Show - 02 1080p x264 English Dub',
        seeders: 5,
        sourceId: 'safe-source',
        provider: 'Safe Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );

      final launch = await _pumpAutoplayLaunch(
        tester,
        mediaId: 88101,
        releases: const [exactFallback, strict],
        preferences: const SeriesPlaybackPreferences(
          preferredQuality: 'p1080',
          preferredCodec: 'h264',
          allowBatchStreams: false,
        ),
        secureValues: const {'streaming_web_enabled': 'false'},
        preferredProvider: 'Fast Provider',
        preferredSourceId: 'fast-source',
        deviceProfile: const TvDeviceProfile(
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
        failureCounts: const {'1010101010101010101010101010101010101010': 2},
      );

      expect(launch.selectedRelease.infoHash, strict.infoHash);
    },
  );

  testWidgets('strict 1080p Web stream beats an exact-provider 4K fallback', (
    tester,
  ) async {
    final exactFallback = _providerWebStream(
      providerId: 'same-web',
      providerName: 'Same Web',
      quality: '2160p',
    );
    final strict = _providerWebStream(
      providerId: 'strict-web',
      providerName: 'Strict Web',
      quality: '1080p',
    );

    final launch = await _pumpAutoplayLaunch(
      tester,
      mediaId: 88102,
      webStreams: [exactFallback, strict],
      preferences: const SeriesPlaybackPreferences(preferredQuality: 'p1080'),
      secureValues: const {
        'streaming_debrid_enabled': 'false',
        'streaming_web_enabled': 'true',
      },
      preferredWebProviderId: 'same-web',
    );

    expect(launch.stream.providerId, 'strict-web');
  });

  testWidgets(
    'known-incompatible exact Debrid source never overrides a safe release',
    (tester) async {
      const unsafeExact = ReleaseCandidate(
        infoHash: '5050505050505050505050505050505050505050',
        magnetUri:
            'magnet:?xt=urn:btih:5050505050505050505050505050505050505050',
        releaseName: '[Current] Show - 02 2160p AV1 English Dub',
        seeders: 2000,
        sourceId: 'current-unsafe',
        provider: 'Current Unsafe',
        isDubbed: true,
        quality: '2160p',
        codec: 'AV1',
      );
      const safe = ReleaseCandidate(
        infoHash: '6060606060606060606060606060606060606060',
        magnetUri:
            'magnet:?xt=urn:btih:6060606060606060606060606060606060606060',
        releaseName: '[Safe] Show - 02 1080p x264 English Dub',
        seeders: 3,
        sourceId: 'safe',
        provider: 'Safe',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );

      final launch = await _pumpAutoplayLaunch(
        tester,
        mediaId: 88105,
        releases: const [unsafeExact, safe],
        preferredProvider: 'Current Unsafe',
        preferredSourceId: 'current-unsafe',
        secureValues: const {'streaming_web_enabled': 'false'},
        deviceProfile: const TvDeviceProfile(
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
        failureCounts: const {'5050505050505050505050505050505050505050': 2},
      );

      expect(launch.selectedRelease.infoHash, safe.infoHash);
    },
  );

  testWidgets(
    'strict Web tier beats fallback Debrid even with Debrid-first selected',
    (tester) async {
      const fallbackDebrid = ReleaseCandidate(
        infoHash: '3030303030303030303030303030303030303030',
        magnetUri:
            'magnet:?xt=urn:btih:3030303030303030303030303030303030303030',
        releaseName: '[Fallback] Show - 02 2160p English Dub',
        seeders: 1000,
        sourceId: 'fallback-debrid',
        provider: 'Fallback Debrid',
        isDubbed: true,
        quality: '2160p',
        codec: 'H.264',
      );
      final strictWeb = _providerWebStream(
        providerId: 'strict-web-class',
        providerName: 'Strict Web class',
        quality: '1080p',
      );

      final launch = await _pumpAutoplayLaunch(
        tester,
        mediaId: 88103,
        releases: const [fallbackDebrid],
        webStreams: [strictWeb],
        preferences: const SeriesPlaybackPreferences(preferredQuality: 'p1080'),
        secureValues: const {'streaming_source_priority': 'debridFirst'},
      );

      expect(launch.stream.isWebStream, isTrue);
      expect(launch.stream.providerId, 'strict-web-class');
    },
  );

  testWidgets('exact strict Debrid source beats fallback Web under Web-first', (
    tester,
  ) async {
    const exactDebrid = ReleaseCandidate(
      infoHash: '4040404040404040404040404040404040404040',
      magnetUri: 'magnet:?xt=urn:btih:4040404040404040404040404040404040404040',
      releaseName: '[Current] Show - 02 1080p English Dub',
      seeders: 2,
      sourceId: 'current-debrid',
      provider: 'Current Debrid',
      isDubbed: true,
      quality: '1080p',
      codec: 'H.264',
    );
    final fallbackWeb = _providerWebStream(
      providerId: 'fallback-web-class',
      providerName: 'Fallback Web class',
      quality: '2160p',
    );

    final launch = await _pumpAutoplayLaunch(
      tester,
      mediaId: 88104,
      releases: const [exactDebrid],
      webStreams: [fallbackWeb],
      preferences: const SeriesPlaybackPreferences(preferredQuality: 'p1080'),
      secureValues: const {'streaming_source_priority': 'webFirst'},
      preferredProvider: 'Current Debrid',
      preferredSourceId: 'current-debrid',
    );

    expect(launch.stream.isWebStream, isFalse);
    expect(launch.selectedRelease.infoHash, exactDebrid.infoHash);
  });

  testWidgets(
    'source picker exposes every primary TV action without scrolling',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _FakeReleaseSource(),
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42,
                title: 'Example Show',
                episode: 1,
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(tester, find.text('Dubbed release'));

      expect(find.text('Choose your stream'), findsOneWidget);
      expect(find.text('ALL'), findsOneWidget);
      expect(find.text('SUB'), findsOneWidget);
      expect(find.byKey(const ValueKey('stream-picker-dub')), findsOneWidget);
      expect(find.text('MULTI'), findsNothing);
      expect(
        find.byKey(const ValueKey('stream-picker-search-input')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('stream-picker-filters')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('stream-picker-refresh')),
        findsOneWidget,
      );
      expect(find.text('Magnet'), findsNothing);
      const actionKeys = [
        'stream-picker-search-input',
        'stream-picker-all',
        'stream-picker-sub',
        'stream-picker-dub',
        'stream-picker-filters',
        'stream-picker-refresh',
      ];
      for (final key in actionKeys) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.left, greaterThanOrEqualTo(0), reason: key);
        expect(rect.right, lessThanOrEqualTo(1920), reason: key);
        expect(rect.top, greaterThanOrEqualTo(0), reason: key);
        expect(rect.bottom, lessThanOrEqualTo(1080), reason: key);
      }

      expect(find.text('Magnet'), findsNothing);

      final input = tester.widget<TvTextInput>(
        find.byKey(const ValueKey('stream-picker-search-input')),
      );
      input.controller.text = 'definitely-no-local-match';
      input.onChanged?.call(input.controller.text);
      await tester.pump();
      expect(find.text('No streams match this search.'), findsOneWidget);
      expect(find.text('Clear search'), findsOneWidget);

      await tester.tap(find.text('Clear search'));
      await tester.pump();
      expect(find.text('Dubbed release'), findsOneWidget);
      expect(find.text('No streams match this search.'), findsNothing);
    },
  );

  testWidgets(
    'Web audio controls place dual in All Sub and Dub without leaking singles',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dual = _providerWebStream(
        providerId: 'dual-provider',
        providerName: 'Synthetic dual-audio result',
        quality: '1080p',
        audioCapability: webStreamAudioCapabilityFromWire({
          'availableAudioLanguages': ['ja-JP', 'en-US'],
        }),
      );
      final sub = _providerWebStream(
        providerId: 'sub-provider',
        providerName: 'Sub only result',
        quality: '720p',
        isDubbed: false,
        audioCapability: WebStreamAudioCapability.sub,
      );
      final dub = _providerWebStream(
        providerId: 'dub-provider',
        providerName: 'Dub only result',
        quality: '720p',
        audioCapability: WebStreamAudioCapability.dub,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _ResolveSettingsController(
                const SettingsPreferences(
                  loaded: true,
                  debridStreamsEnabled: false,
                  webStreamsEnabled: true,
                  preferredAudio: PlaybackAudioPreference.dub,
                ),
              ),
            ),
            configuredReleaseSourceProvider.overrideWithValue(null),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([dual, sub, dub]),
            ),
            seriesPreferencesReaderProvider.overrideWithValue(
              (_) async => const SeriesPlaybackPreferences(),
            ),
            seriesPreferencesWriterProvider.overrideWithValue((_, _) async {}),
            resolveDeviceProfileReaderProvider.overrideWithValue(
              () async => const TvDeviceProfile.unknown(),
            ),
            resolveFailureCountsReaderProvider.overrideWithValue(
              (_) async => const {},
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42006,
                title: 'Audio filter placement fixture',
                episode: 1,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text(dual.title));
      expect(find.text(dub.title), findsOneWidget);
      expect(find.text(sub.title), findsNothing);

      await tester.tap(find.byKey(const ValueKey('stream-picker-all')));
      await tester.pump();
      expect(find.text(dual.title), findsOneWidget);
      expect(find.text(sub.title), findsOneWidget);
      expect(find.text(dub.title), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('stream-picker-sub')));
      await tester.pump();
      expect(find.text(dual.title), findsOneWidget);
      expect(find.text(sub.title), findsOneWidget);
      expect(find.text(dub.title), findsNothing);

      await tester.tap(find.byKey(const ValueKey('stream-picker-dub')));
      await tester.pump();
      expect(find.text(dual.title), findsOneWidget);
      expect(find.text(sub.title), findsNothing);
      expect(find.text(dub.title), findsOneWidget);
    },
  );

  testWidgets(
    'Direct torrent fills the source picker and plays without a Debrid account',
    (tester) async {
      final probe = await _pumpDirectTorrentScenario(tester);

      await _pumpUntilFound(tester, find.text('DIRECT TORRENT STREAMS'));
      expect(find.textContaining('1 Direct torrent'), findsOneWidget);
      expect(find.text('Dubbed release'), findsOneWidget);
      expect(probe.factoryCalls, 0);

      await tester.tap(find.text('Dubbed release'));
      await _pumpUntilFound(tester, find.text('DIRECT TORRENT PLAYER OPENED'));

      expect(probe.factoryCalls, 1);
      expect(probe.launch, isNotNull);
      expect(probe.launch!.stream.isDirectTorrent, isTrue);
      expect(probe.launch!.stream.debridService, isNull);
    },
  );

  testWidgets('long-pressing a source offers an offline download', (
    tester,
  ) async {
    await _pumpDirectTorrentScenario(tester);
    await _pumpUntilFound(tester, find.text('Dubbed release'));

    await tester.longPress(find.text('Dubbed release'));
    await tester.pumpAndSettle();

    expect(find.text('Download this episode?'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    expect(find.textContaining('Download Manager'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('disabled offline downloads remove source download actions', (
    tester,
  ) async {
    await _pumpDirectTorrentScenario(tester, offlineDownloadsEnabled: false);
    await _pumpUntilFound(tester, find.text('Dubbed release'));

    await tester.longPress(find.text('Dubbed release'));
    await tester.pumpAndSettle();

    expect(find.text('Download this episode?'), findsNothing);
    expect(find.text('Download'), findsNothing);
    expect(find.textContaining('Download Manager'), findsNothing);
  });

  testWidgets(
    'master switch updates download actions while the source picker stays open',
    (tester) async {
      final probe = await _pumpDirectTorrentScenario(tester);
      await _pumpUntilFound(tester, find.text('Dubbed release'));

      TvFocusable releaseCard() => tester.widget<TvFocusable>(
        find
            .ancestor(
              of: find.text('Dubbed release'),
              matching: find.byType(TvFocusable),
            )
            .first,
      );
      expect(releaseCard().onLongPress, isNotNull);

      await probe.settings.setOfflineDownloadsEnabled(false);
      await tester.pumpAndSettle();
      expect(releaseCard().onLongPress, isNull);

      await probe.settings.setOfflineDownloadsEnabled(true);
      await tester.pumpAndSettle();
      expect(releaseCard().onLongPress, isNotNull);
    },
  );

  testWidgets('Auto Pick can select Direct torrent without Debrid', (
    tester,
  ) async {
    final probe = await _pumpDirectTorrentScenario(tester, autoPick: true);

    await _pumpUntilFound(tester, find.text('DIRECT TORRENT PLAYER OPENED'));
    expect(probe.factoryCalls, 1);
    expect(probe.launch!.stream.isDirectTorrent, isTrue);
  });

  testWidgets('unsupported ABI explains why Direct torrent cannot start', (
    tester,
  ) async {
    final probe = await _pumpDirectTorrentScenario(
      tester,
      directTorrentSupported: false,
    );

    await _pumpUntilFound(
      tester,
      find.textContaining(
        'Direct torrent playback is unavailable on this device or CPU.',
      ),
    );
    expect(find.text('DIRECT TORRENT STREAMS'), findsNothing);
    expect(probe.factoryCalls, 0);
  });

  for (final size in const [Size(960, 540), Size(1280, 720)]) {
    testWidgets(
      'primary source actions share one TV row at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              configuredReleaseSourceProvider.overrideWithValue(
                const _FakeReleaseSource(),
              ),
            ],
            child: const MaterialApp(
              home: ResolveEpisodeScreen(
                episode: EpisodeReference(
                  anilistMediaId: 42001,
                  title: 'TV toolbar geometry',
                  episode: 1,
                ),
              ),
            ),
          ),
        );
        await _pumpUntilFound(
          tester,
          find.byKey(const ValueKey('stream-picker-header-row')),
        );

        const actionKeys = [
          'stream-picker-search-input',
          'stream-picker-all',
          'stream-picker-sub',
          'stream-picker-dub',
          'stream-picker-filters',
          'stream-picker-refresh',
        ];
        final rects = [
          for (final key in actionKeys)
            tester.getRect(find.byKey(ValueKey(key))),
        ];
        final centerY = rects.first.center.dy;
        expect(
          rects.first.width,
          greaterThanOrEqualTo(160),
          reason:
              'Search must remain usable with every action visible at $size',
        );
        for (var index = 0; index < rects.length; index++) {
          expect(
            rects[index].center.dy,
            closeTo(centerY, 0.5),
            reason: '${actionKeys[index]} wrapped onto another row at $size',
          );
          expect(rects[index].left, greaterThanOrEqualTo(0));
          expect(rects[index].right, lessThanOrEqualTo(size.width));
        }

        final allControl = find.descendant(
          of: find.byKey(const ValueKey('stream-picker-all')),
          matching: find.byType(FocusableActionDetector),
        );
        tester
            .widget<FocusableActionDetector>(allControl)
            .focusNode!
            .requestFocus();
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'stream-picker.all',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'stream-picker.search',
          reason: 'Left from ALL should return to the adjacent search field',
        );
        tester
            .widget<FocusableActionDetector>(allControl)
            .focusNode!
            .requestFocus();
        await tester.pump();
        for (final expected in [
          'stream-picker.sub',
          'stream-picker.dub',
          'stream-picker.filters',
          'stream-picker.refresh',
        ]) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(FocusManager.instance.primaryFocus?.debugLabel, expected);
        }
      },
    );
  }

  for (final useBuiltInKeyboard in const [true, false]) {
    testWidgets('source search exits by D-pad with '
        '${useBuiltInKeyboard ? 'TetoTV' : 'device'} keyboard selected', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(960, 540));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = LibraryEpisodeSource.jellyfin(
        const JellyfinMediaItem(
          id: 'focus-episode-7',
          name: 'Focus target',
          type: 'Episode',
          seriesName: 'Focus Show',
          episodeNumber: 7,
          videoHeight: 1080,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _ResolveSettingsController(
                SettingsPreferences(
                  loaded: true,
                  debridStreamsEnabled: false,
                  webStreamsEnabled: false,
                  useBuiltInKeyboard: useBuiltInKeyboard,
                ),
              ),
            ),
            configuredReleaseSourceProvider.overrideWithValue(null),
            libraryEpisodeSourceServiceProvider.overrideWithValue(
              _FixedLibraryEpisodeSourceService([source]),
            ),
            seriesPreferencesReaderProvider.overrideWithValue(
              (_) async => const SeriesPlaybackPreferences(),
            ),
            resolveDeviceProfileReaderProvider.overrideWithValue(
              () async => const TvDeviceProfile.unknown(),
            ),
            resolveFailureCountsReaderProvider.overrideWithValue(
              (_) async => const {},
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42007,
                title: 'Focus Show',
                episode: 7,
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(tester, find.text('E07 · Focus target'));

      final search = tester.widget<TvTextInput>(
        find.byKey(const ValueKey('stream-picker-search-input')),
      );
      final searchFocus = search.focusNode!;
      searchFocus.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(searchFocus));
      if (!useBuiltInKeyboard) {
        // Exercise the real EditableText mode as well as its read-only hover
        // state. Opening the OS keyboard must not turn arrows into a trap.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, same(searchFocus));
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'stream-picker.all',
        reason: 'RIGHT should leave Search sources for the filter row',
      );

      searchFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final resultControl = find
          .ancestor(
            of: find.text('E07 · Focus target'),
            matching: find.byType(FocusableActionDetector),
          )
          .first;
      final resultFocus = tester
          .widget<FocusableActionDetector>(resultControl)
          .focusNode!;
      expect(
        FocusManager.instance.primaryFocus,
        same(resultFocus),
        reason: 'DOWN should leave Search sources for the first result',
      );
    });
  }

  testWidgets(
    'provider no-match notices stay compact while discovered streams remain visible',
    (tester) async {
      const size = Size(960, 540);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final available = _providerWebStream(
        providerId: 'available-web',
        providerName: 'Available provider',
        quality: '1080p',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([]),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FailureAndStreamWebAggregator(available),
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42002,
                title: 'Provider warning geometry',
                episode: 1,
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(tester, find.text(available.title));

      expect(find.textContaining('1 notice(s)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stream-picker-provider-status')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Unavailable provider: no match'),
        findsOneWidget,
      );
      expect(find.textContaining('No matching title or episode'), findsNothing);
      final streamRect = tester.getRect(find.text(available.title));
      expect(streamRect.top, greaterThanOrEqualTo(0));
      expect(streamRect.bottom, lessThanOrEqualTo(size.height));
      final streamControl = find
          .ancestor(
            of: find.text(available.title),
            matching: find.byType(FocusableActionDetector),
          )
          .first;
      final streamFocusNode = tester
          .widget<FocusableActionDetector>(streamControl)
          .focusNode!;
      streamFocusNode.requestFocus();
      await tester.pump();
      expect(streamFocusNode.hasFocus, isTrue);
    },
  );

  testWidgets(
    'manual web stream order exposes each provider before one provider repeats',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final providerA2160 = _providerWebStream(
        providerId: 'provider-a',
        providerName: 'Provider A',
        quality: '2160p',
      );
      final providerA1080 = _providerWebStream(
        providerId: 'provider-a',
        providerName: 'Provider A',
        quality: '1080p',
      );
      final providerB720 = _providerWebStream(
        providerId: 'provider-b',
        providerName: 'Provider B',
        quality: '720p',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([]),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([providerA2160, providerA1080, providerB720]),
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42003,
                title: 'Provider fair order fixture',
                episode: 1,
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(tester, find.text(providerA1080.title));

      expect(
        tester.getTopLeft(find.text(providerA2160.title)).dy,
        lessThan(tester.getTopLeft(find.text(providerB720.title)).dy),
      );
      expect(
        tester.getTopLeft(find.text(providerB720.title)).dy,
        lessThan(tester.getTopLeft(find.text(providerA1080.title)).dy),
        reason: 'Provider B must be visible before Provider A repeats',
      );
    },
  );

  testWidgets('provider status strip prioritizes a real failure', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final available = _providerWebStream(
      providerId: 'available-web',
      providerName: 'Available provider',
      quality: '1080p',
    );
    final failures = [
      for (var index = 0; index < 5; index++)
        WebProviderFailure(
          providerName: 'Neutral $index',
          status: WebProviderFailureStatus.noMatch,
          message: 'No matching title or episode from this provider.',
        ),
      const WebProviderFailure(
        providerName: 'Z critical provider',
        status: WebProviderFailureStatus.failed,
        message: 'Provider failed.',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _ListReleaseSource([]),
          ),
          webStreamAggregatorProvider.overrideWithValue(
            _FailureAndStreamWebAggregator(available, failures: failures),
          ),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 42004,
              title: 'Provider status priority fixture',
              episode: 1,
            ),
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text(available.title));

    expect(find.textContaining('Z critical provider: error'), findsOneWidget);
    expect(find.textContaining('+2 more'), findsOneWidget);
    expect(find.textContaining('1 issue(s)'), findsOneWidget);
    expect(find.textContaining('5 notice(s)'), findsOneWidget);
  });

  testWidgets(
    'a clean provider no-match is not reported as a runtime failure',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([]),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FailureAndStreamWebAggregator(
                null,
                failures: const [
                  WebProviderFailure(
                    providerName: 'Clean no match',
                    status: WebProviderFailureStatus.noMatch,
                    message: 'No matching title or episode from this provider.',
                  ),
                ],
              ),
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42005,
                title: 'Clean no-match fixture',
                episode: 1,
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(
        tester,
        find.textContaining('No playable streams were returned'),
      );

      expect(
        find.textContaining('No enabled source completed successfully'),
        findsNothing,
      );
    },
  );

  test('local stream search covers useful Debrid and Web metadata', () {
    const release = ReleaseCandidate(
      infoHash: 'searchable-release',
      magnetUri: 'magnet:?xt=urn:btih:searchable-release',
      releaseName: '[SeaDex] Example S01E01 Dual Audio HEVC',
      seeders: 44,
      sourceId: 'nyaa-provider',
      provider: 'Nyaa Anime',
      quality: '1080p',
      codec: 'HEVC',
      sizeLabel: '1.4 GB',
      isDubbed: true,
      hasSubtitles: true,
    );
    final web = _providerWebStream(
      providerId: 'provider-a-main',
      providerName: 'Provider A',
      quality: '720p',
      isDubbed: false,
      audioCapability: WebStreamAudioCapability.sub,
    );

    expect(releaseMatchesLocalStreamSearch(release, 'seadex 1080 dub'), isTrue);
    expect(releaseMatchesLocalStreamSearch(release, '44 seeders'), isTrue);
    expect(releaseMatchesLocalStreamSearch(release, '720'), isFalse);
    expect(webStreamMatchesLocalSearch(web, 'provider a 720 sub'), isTrue);
    expect(webStreamMatchesLocalSearch(web, 'dub'), isFalse);
  });

  test(
    'local stream search covers media server, title, and codec metadata',
    () {
      final source = LibraryEpisodeSource.jellyfin(
        const JellyfinMediaItem(
          id: 'episode-id-12345678',
          name: 'Like a Fairy Tale',
          type: 'Episode',
          seriesName: 'Sousou no Frieren',
          episodeNumber: 7,
          videoCodec: 'av1',
          videoHeight: 1080,
        ),
      );

      expect(
        libraryStreamMatchesLocalSearch(source, 'jellyfin frieren 1080 av1'),
        isTrue,
      );
      expect(libraryStreamMatchesLocalSearch(source, 'plex'), isFalse);
    },
  );

  testWidgets(
    'connected local library keeps picker usable with network sources disabled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 540));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = LibraryEpisodeSource.jellyfin(
        const JellyfinMediaItem(
          id: 'episode-id-12345678',
          name: 'Like a Fairy Tale',
          type: 'Episode',
          seriesName: 'Sousou no Frieren',
          episodeNumber: 7,
          videoCodec: 'av1',
          videoHeight: 1080,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _ResolveSettingsController(
                const SettingsPreferences(
                  loaded: true,
                  debridStreamsEnabled: false,
                  webStreamsEnabled: false,
                ),
              ),
            ),
            configuredReleaseSourceProvider.overrideWithValue(null),
            libraryEpisodeSourceServiceProvider.overrideWithValue(
              _FixedLibraryEpisodeSourceService([source]),
            ),
            seriesPreferencesReaderProvider.overrideWithValue(
              (_) async => const SeriesPlaybackPreferences(),
            ),
            resolveDeviceProfileReaderProvider.overrideWithValue(
              () async => const TvDeviceProfile.unknown(),
            ),
            resolveFailureCountsReaderProvider.overrideWithValue(
              (_) async => const {},
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 154587,
                title: 'Sousou no Frieren',
                episode: 7,
              ),
            ),
          ),
        ),
      );
      await _pumpUntilFound(tester, find.text('LOCAL SOURCES'));

      expect(find.text('E07 · Like a Fairy Tale'), findsOneWidget);
      expect(find.text('Choose local video'), findsNothing);
      expect(find.textContaining('1 Local'), findsOneWidget);
      expect(find.text('Stream sources are disabled'), findsNothing);
      expect(find.text('DEBRID STREAMS'), findsNothing);
      expect(find.text('WEB STREAMS'), findsNothing);
      expect(
        find.byKey(const ValueKey('stream-picker-header-row')),
        findsOneWidget,
      );
    },
  );

  testWidgets('episode picker never offers an unmatched local-device file', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final localService = _FixedLibraryEpisodeSourceService(
      const [],
      connected: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _ResolveSettingsController(
              const SettingsPreferences(
                loaded: true,
                debridStreamsEnabled: false,
                webStreamsEnabled: false,
              ),
            ),
          ),
          configuredReleaseSourceProvider.overrideWithValue(null),
          libraryEpisodeSourceServiceProvider.overrideWithValue(localService),
          seriesPreferencesReaderProvider.overrideWithValue(
            (_) async => const SeriesPlaybackPreferences(),
          ),
          resolveDeviceProfileReaderProvider.overrideWithValue(
            () async => const TvDeviceProfile.unknown(),
          ),
          resolveFailureCountsReaderProvider.overrideWithValue(
            (_) async => const {},
          ),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 154587,
              title: 'Sousou no Frieren',
              episode: 7,
            ),
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('No stream source is ready'));

    expect(find.text('Choose local video'), findsNothing);
    expect(
      find.byKey(const ValueKey('stream-picker-local-video')),
      findsNothing,
    );
    expect(find.text('LOCAL SOURCES'), findsNothing);
    expect(
      find.byKey(const ValueKey('stream-picker-header-row')),
      findsNothing,
    );
    expect(find.text('Open accounts'), findsOneWidget);
    expect(localService.chosenIdentity, isNull);
  });

  for (final size in const [Size(360, 800), Size(800, 360)]) {
    testWidgets(
      'source-list search fits phone ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              configuredReleaseSourceProvider.overrideWithValue(
                const _FakeReleaseSource(),
              ),
              webStreamAggregatorProvider.overrideWithValue(
                _FixedWebAggregator([
                  _providerWebStream(
                    providerId: 'compact-web',
                    providerName:
                        'A deliberately long provider name that must stay inside the compact stream card',
                    quality: '1080p',
                  ),
                ]),
              ),
            ],
            child: const MaterialApp(
              home: ResolveEpisodeScreen(
                episode: EpisodeReference(
                  anilistMediaId: 42,
                  title: 'Compact Example',
                  episode: 1,
                ),
              ),
            ),
          ),
        );
        await _pumpUntilFound(
          tester,
          find.byKey(const ValueKey('stream-picker-search-input')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        if (find.text('WEB STREAMS').evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text('WEB STREAMS'),
            120,
            scrollable: find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
        }
        expect(find.text('WEB STREAMS'), findsOneWidget);

        final input = find.byKey(const ValueKey('stream-picker-search-input'));
        expect(input, findsOneWidget);
        final inputRect = tester.getRect(input);
        expect(inputRect.left, greaterThanOrEqualTo(0));
        expect(inputRect.right, lessThanOrEqualTo(size.width));
        if (size.width == 360) {
          final controlsScroll = find.byKey(
            const ValueKey('stream-picker-primary-controls-scroll'),
          );
          expect(controlsScroll, findsOneWidget);
          await tester.drag(controlsScroll, const Offset(-120, 0));
          await tester.pumpAndSettle();
          final refreshRect = tester.getRect(
            find.byKey(const ValueKey('stream-picker-refresh')),
          );
          expect(refreshRect.left, greaterThanOrEqualTo(0));
          expect(refreshRect.right, lessThanOrEqualTo(size.width));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'visible release fallback keeps the selected normalized quality first',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const selected = ReleaseCandidate(
        infoHash: 'selected-1080',
        magnetUri: 'magnet:?xt=urn:btih:selected-1080',
        releaseName: '[Group] Selected 1080p',
        seeders: 1,
        sourceId: 'stable-source',
        provider: 'Same provider',
        quality: '1080p',
        isDubbed: true,
      );
      const sameQuality = ReleaseCandidate(
        infoHash: 'same-full-hd',
        magnetUri: 'magnet:?xt=urn:btih:same-full-hd',
        releaseName: '[Other] Same Full HD',
        seeders: 1,
        sourceId: 'other-source',
        provider: 'Other provider',
        quality: 'Full HD',
        isDubbed: true,
      );
      const higher = ReleaseCandidate(
        infoHash: 'higher-4k',
        magnetUri: 'magnet:?xt=urn:btih:higher-4k',
        releaseName: '[Group] Higher 2160p',
        seeders: 1000,
        sourceId: 'stable-source',
        provider: 'Same provider',
        quality: '2160p',
        isDubbed: true,
      );
      const lower = ReleaseCandidate(
        infoHash: 'lower-720',
        magnetUri: 'magnet:?xt=urn:btih:lower-720',
        releaseName: '[Lower] Lower 720p',
        seeders: 2000,
        sourceId: 'lower-source',
        provider: 'Lower provider',
        quality: '720p',
        isDubbed: true,
      );
      final attempted = <String>[];
      PlaybackLaunch? opened;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42108,
                title: 'Quality Fallback',
                episode: 1,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('QUALITY FALLBACK OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([higher, lower, sameQuality, selected]),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              return _SourceAwareResolver(source, (candidate) {
                attempted.add(candidate.infoHash);
                return candidate.infoHash == higher.infoHash
                    ? null
                    : StateError('1080p stream unavailable');
              });
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text(selected.releaseName));
      await tester.tap(find.text(selected.releaseName));
      await _pumpUntilFound(tester, find.text('QUALITY FALLBACK OPENED'));

      expect(attempted, [
        selected.infoHash,
        sameQuality.infoHash,
        higher.infoHash,
      ]);
      expect(opened?.selectedRelease.infoHash, higher.infoHash);
    },
  );

  testWidgets('shows resolver errors and debounces repeated activation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var resolveCalls = 0;
    final failResolution = Completer<void>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _FakeReleaseSource(),
          ),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            resolveCalls++;
            return _FailingResolver(failResolution.future);
          }),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 42,
              title: 'Example Show',
              episode: 1,
            ),
          ),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('Dubbed release'));
    expect(find.text('Dubbed release'), findsOneWidget);
    expect(find.byKey(const ValueKey('stream-picker-filters')), findsOneWidget);
    expect(find.text('QUALITY'), findsNothing);
    expect(find.text('BATCHES ON'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('stream-picker-filters')));
    // Provider discovery is intentionally progressive and may keep its
    // loading indicator active while filters remain fully interactive.
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('QUALITY'), findsOneWidget);
    expect(find.text('BATCHES ON'), findsOneWidget);

    // A held/duplicated remote-select event must not add the same magnet twice.
    await tester.tap(find.text('Dubbed release'));
    await tester.tap(find.text('Dubbed release'), warnIfMissed: false);
    await tester.pump();
    expect(resolveCalls, 1);
    failResolution.complete();
    await _pumpUntilFound(tester, find.text('Retry'));

    expect(
      find.textContaining('Could not start this stream: Release unavailable'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(resolveCalls, 2);
  });

  testWidgets('keeps the picker usable while another resolver is loading', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final slow = Completer<List<ReleaseCandidate>>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            CompositeReleaseSource([
              const _FakeReleaseSource(),
              _CallbackReleaseSource('slow', () => slow.future),
            ]),
          ),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 42,
              title: 'Example Show',
              episode: 1,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('Dubbed release'));
    expect(find.text('Dubbed release'), findsOneWidget);
    expect(
      find.textContaining('Available results can be selected now'),
      findsOneWidget,
    );

    final focusedControl = find
        .ancestor(
          of: find.text('Dubbed release'),
          matching: find.byType(FocusableActionDetector),
        )
        .first;
    final focusNode = tester
        .widget<FocusableActionDetector>(focusedControl)
        .focusNode!;
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    slow.complete(const [
      ReleaseCandidate(
        infoHash: '89abcdef0123456789abcdef0123456789abcdef',
        magnetUri:
            'magnet:?xt=urn:btih:89abcdef0123456789abcdef0123456789abcdef',
        releaseName: 'Higher quality release',
        seeders: 50,
        sourceId: 'slow',
        isDubbed: true,
        quality: '2160p',
        codec: 'H.264',
      ),
    ]);
    // Do not wait for unrelated web providers to finish; this test verifies
    // that the debrid list reorders safely while discovery is still active.
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Dubbed release'), findsOneWidget);
    expect(find.text('Higher quality release'), findsOneWidget);
    expect(focusNode.hasFocus, isTrue);
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is FocusableActionDetector &&
              identical(widget.focusNode, focusNode),
        ),
        matching: find.text('Dubbed release'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'autoplay launches an immediate debrid result without waiting for web',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final never = Completer<void>();
      addTearDown(() {
        if (!never.isCompleted) never.complete();
      });
      final webAggregator = _NeverCompletingWebAggregator(never.future);
      var resolverCalls = 0;
      var playerBuilds = 0;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42,
                title: 'Example Show',
                episode: 1,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) {
              playerBuilds++;
              return const Scaffold(body: Text('PLAYER OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _FakeReleaseSource(),
            ),
            webStreamAggregatorProvider.overrideWithValue(webAggregator),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return const _ReadyResolver();
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('PLAYER OPENED'));
      expect(webAggregator.searchCalls, 1);
      expect(never.isCompleted, isFalse);
      expect(resolverCalls, 1);
      expect(playerBuilds, 1);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        resolverCalls,
        1,
        reason: 'late source progress must not relaunch',
      );
      expect(playerBuilds, 1);
    },
  );

  testWidgets(
    'autoplay persistence handoff never exposes picker or text input',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saveStarted = Completer<void>();
      final allowSave = Completer<void>();
      addTearDown(() {
        if (!allowSave.isCompleted) allowSave.complete();
      });
      var resolverCalls = 0;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 424243,
                title: 'Slow Persistence Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) =>
                const Scaffold(body: Text('PERSISTED PLAYER OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _FakeReleaseSource(),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator(const []),
            ),
            seriesPreferencesWriterProvider.overrideWithValue((_, _) async {
              if (!saveStarted.isCompleted) saveStarted.complete();
              await allowSave.future;
            }),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return const _ReadyResolver();
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('Opening the selected stream…'));
      expect(saveStarted.isCompleted, isTrue);
      expect(resolverCalls, 0);
      expect(find.text('Choose your stream'), findsNothing);
      expect(find.byType(TvTextInput), findsNothing);
      expect(find.textContaining('Paste a magnet'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Opening the selected stream…'), findsOneWidget);
      expect(find.text('Choose your stream'), findsNothing);
      expect(find.byType(TvTextInput), findsNothing);

      allowSave.complete();
      await _pumpUntilFound(tester, find.text('PERSISTED PLAYER OPENED'));
      expect(resolverCalls, 1);
    },
  );

  testWidgets(
    'autoplay ranks all concurrent repositories before checking debrid cache',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final slowSource = Completer<List<ReleaseCandidate>>();
      final neverWeb = Completer<void>();
      addTearDown(() {
        if (!slowSource.isCompleted) slowSource.complete(const []);
        if (!neverWeb.isCompleted) neverWeb.complete();
      });
      var resolverCalls = 0;
      PlaybackLaunch? opened;
      final source = CompositeReleaseSource([
        _CallbackReleaseSource(
          'fast',
          () async => const [
            ReleaseCandidate(
              infoHash: '1111111111111111111111111111111111111111',
              magnetUri:
                  'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
              releaseName: 'Fast repository result English Dub',
              seeders: 1,
              sourceId: 'fast',
              isDubbed: true,
              quality: '1080p',
              codec: 'H.264',
            ),
          ],
        ),
        _CallbackReleaseSource('slow', () => slowSource.future),
      ]);
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42,
                title: 'Example Show',
                episode: 1,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('RANKED PLAYER OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(source),
            webStreamAggregatorProvider.overrideWithValue(
              _NeverCompletingWebAggregator(neverWeb.future),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return const _ReadyResolver();
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.textContaining('Debrid 1/2'));
      expect(
        find.text('Fast repository result English Dub'),
        findsNothing,
        reason: 'autoplay discovery must not expose the manual source picker',
      );
      expect(resolverCalls, 0);
      slowSource.complete(const [
        ReleaseCandidate(
          infoHash: '2222222222222222222222222222222222222222',
          magnetUri:
              'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
          releaseName: 'Better ranked result English Dub',
          seeders: 100,
          sourceId: 'slow',
          isDubbed: true,
          quality: '1080p',
          codec: 'H.264',
        ),
      ]);
      await _pumpUntilFound(tester, find.text('RANKED PLAYER OPENED'));

      expect(resolverCalls, 1);
      expect(opened?.selectedRelease.infoHash, startsWith('2222'));
      expect(neverWeb.isCompleted, isFalse);
    },
  );

  testWidgets(
    'autoplay debrid failover keeps provider and author affinity order',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const exact = ReleaseCandidate(
        infoHash: '1111111111111111111111111111111111111111',
        magnetUri:
            'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
        releaseName: '[Same Group] Show - 02 English Dub',
        seeders: 1,
        sourceId: 'source-a',
        provider: 'Same Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const providerOnly = ReleaseCandidate(
        infoHash: '2222222222222222222222222222222222222222',
        magnetUri:
            'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
        releaseName: '[Other Group] Show - 02 English Dub',
        seeders: 500,
        sourceId: 'source-a',
        provider: 'Same Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const global = ReleaseCandidate(
        infoHash: '3333333333333333333333333333333333333333',
        magnetUri:
            'magnet:?xt=urn:btih:3333333333333333333333333333333333333333',
        releaseName: '[Other Group] Show - 02 English Dub',
        seeders: 5000,
        sourceId: 'source-b',
        provider: 'Other Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      final attempted = <String>[];
      PlaybackLaunch? opened;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredProvider: 'Same Provider',
              preferredAuthor: 'Same Group',
              episode: EpisodeReference(
                anilistMediaId: 525252,
                title: 'Affinity Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('AFFINITY PLAYER OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([global, providerOnly, exact]),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator(const []),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              return _SourceAwareResolver(source, (candidate) {
                attempted.add(candidate.infoHash);
                return attempted.length < 3
                    ? const DebridCacheMissException(DebridService.realDebrid)
                    : null;
              });
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('AFFINITY PLAYER OPENED'));
      expect(attempted, [
        exact.infoHash,
        providerOnly.infoHash,
        global.infoHash,
      ]);
      expect(opened?.selectedRelease, global);
    },
  );

  testWidgets(
    'provider-only preferred debrid release opens while another source is pending',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
        'streaming_web_enabled': 'false',
      });
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final never = Completer<List<ReleaseCandidate>>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(const []);
      });
      const exact = ReleaseCandidate(
        infoHash: 'dddddddddddddddddddddddddddddddddddddddd',
        magnetUri:
            'magnet:?xt=urn:btih:dddddddddddddddddddddddddddddddddddddddd',
        releaseName: 'Show - 02 English Dub',
        seeders: 1,
        sourceId: 'fast-source',
        provider: 'Same Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      var resolverCalls = 0;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredProvider: 'Same Provider',
              episode: EpisodeReference(
                anilistMediaId: 525254,
                title: 'Immediate Affinity Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) =>
                const Scaffold(body: Text('IMMEDIATE DEBRID OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              CompositeReleaseSource([
                const _ListReleaseSource([exact]),
                _CallbackReleaseSource('never', () => never.future),
              ]),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return const _ReadyResolver();
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('IMMEDIATE DEBRID OPENED'));
      expect(resolverCalls, 1);
      expect(never.isCompleted, isFalse);
      never.complete(const []);
      await tester.pump();
    },
  );

  testWidgets(
    'stable source affinity opens early when the provider identity changed',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
        'streaming_web_enabled': 'false',
      });
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final never = Completer<List<ReleaseCandidate>>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(const []);
      });
      const stableSource = ReleaseCandidate(
        infoHash: 'abababababababababababababababababababab',
        magnetUri:
            'magnet:?xt=urn:btih:abababababababababababababababababababab',
        releaseName: '[Same Group] Show - 02 English Dub',
        seeders: 1,
        sourceId: 'stable-source-id',
        provider: 'Renamed Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      var resolverCalls = 0;
      PlaybackLaunch? opened;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredProvider: 'Previous Provider Name',
              preferredSourceId: 'stable-source-id',
              preferredAuthor: 'Same Group',
              episode: EpisodeReference(
                anilistMediaId: 525257,
                title: 'Stable Source Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('STABLE SOURCE OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              CompositeReleaseSource([
                const _ListReleaseSource([stableSource]),
                _CallbackReleaseSource('never', () => never.future),
              ]),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return const _ReadyResolver();
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('STABLE SOURCE OPENED'));
      expect(resolverCalls, 1);
      expect(opened!.selectedRelease, stableSource);
      expect(never.isCompleted, isFalse);
      never.complete(const []);
      await tester.pump();
    },
  );

  testWidgets(
    'failed early affinity release waits and never retries before fallback',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
        'streaming_web_enabled': 'false',
      });
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final slow = Completer<List<ReleaseCandidate>>();
      const exact = ReleaseCandidate(
        infoHash: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        magnetUri:
            'magnet:?xt=urn:btih:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        releaseName: '[Same Group] Show - 02 English Dub',
        seeders: 1,
        sourceId: 'fast-source',
        provider: 'Same Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const fallback = ReleaseCandidate(
        infoHash: 'ffffffffffffffffffffffffffffffffffffffff',
        magnetUri:
            'magnet:?xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff',
        releaseName: '[Other Group] Show - 02 English Dub',
        seeders: 100,
        sourceId: 'slow-source',
        provider: 'Other Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      final attempted = <String>[];
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredProvider: 'Same Provider',
              preferredAuthor: 'Same Group',
              episode: EpisodeReference(
                anilistMediaId: 525255,
                title: 'Progressive Fallback Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) =>
                const Scaffold(body: Text('PROGRESSIVE FALLBACK OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              CompositeReleaseSource([
                const _ListReleaseSource([exact]),
                _CallbackReleaseSource('slow-source', () => slow.future),
              ]),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              return _SourceAwareResolver(source, (candidate) {
                attempted.add(candidate.infoHash);
                return candidate.infoHash == exact.infoHash
                    ? const DebridCacheMissException(DebridService.realDebrid)
                    : null;
              });
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.text('That release failed. Waiting for other sources…'),
      );
      slow.complete(const [fallback]);
      await _pumpUntilFound(tester, find.text('PROGRESSIVE FALLBACK OPENED'));
      expect(attempted, [exact.infoHash, fallback.infoHash]);
    },
  );

  testWidgets(
    'debrid launch carries deduped affinity releases and raw web alternatives',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const selected = ReleaseCandidate(
        infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        magnetUri:
            'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        releaseName: '[Current Group] Show - 02 English Dub',
        seeders: 10,
        sourceId: 'current-source',
        provider: 'Current Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const duplicate = ReleaseCandidate(
        infoHash: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        magnetUri:
            'magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        releaseName: '[Current Group] Duplicate English Dub',
        seeders: 1,
        sourceId: 'current-source',
        provider: 'Current Provider',
        isDubbed: true,
        quality: '720p',
        codec: 'H.264',
      );
      const sameProvider = ReleaseCandidate(
        infoHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        magnetUri:
            'magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        releaseName: '[Other Group] Show - 02 English Dub',
        seeders: 2,
        sourceId: 'current-source',
        provider: 'Current Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const global = ReleaseCandidate(
        infoHash: 'cccccccccccccccccccccccccccccccccccccccc',
        magnetUri:
            'magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc',
        releaseName: '[Global] Show - 02 English Dub',
        seeders: 2000,
        sourceId: 'other-source',
        provider: 'Other Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      final currentUriWeb = WebStreamResult(
        providerId: 'same-uri',
        providerName: 'Same URI Provider',
        title: 'Current URI duplicate',
        uri: Uri.parse('https://debrid.example.com/episode.mkv'),
        quality: '4K',
        isDubbed: true,
      );
      final web1080 = _providerWebStream(
        providerId: 'web-1080',
        providerName: 'Web 1080',
        quality: '1080p',
      );
      final web720 = _providerWebStream(
        providerId: 'web-720',
        providerName: 'Web 720',
        quality: '720p',
      );
      final web720Duplicate = WebStreamResult(
        providerId: web720.providerId,
        providerName: 'Duplicate Web 720',
        title: 'Duplicate Web 720',
        uri: web720.uri,
        quality: web720.quality,
        isDubbed: true,
      );
      PlaybackLaunch? opened;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredProvider: 'Current Provider',
              preferredAuthor: 'Current Group',
              episode: EpisodeReference(
                anilistMediaId: 525253,
                title: 'Alternative Order Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('ALTERNATIVES OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([
                global,
                duplicate,
                sameProvider,
                selected,
              ]),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([
                web720,
                currentUriWeb,
                web720Duplicate,
                web1080,
              ]),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(
              ({required service, required token, required source}) =>
                  const _ReadyResolver(),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('ALTERNATIVES OPENED'));
      expect(opened!.selectedRelease.infoHash, selected.infoHash);
      expect(
        opened!.alternatives.map((release) => release.infoHash.toLowerCase()),
        [sameProvider.infoHash, global.infoHash],
      );
      expect(
        opened!.directAlternatives.map((alternative) => alternative.stream.uri),
        [web1080.uri, web720.uri],
      );
      expect(
        opened!.directAlternatives.map(
          (alternative) => alternative.stream.providerId,
        ),
        ['web-1080', 'web-720'],
      );
    },
  );

  testWidgets(
    'web launch carries affinity debrid alternatives and selected service',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        DebridService.torBox.tokenStorageKey: 'valid-torbox-token',
        'settings_selected_debrid_provider': DebridService.torBox.slug,
      });
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const exact = ReleaseCandidate(
        infoHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        magnetUri:
            'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        releaseName: '[Current Group] Show - 02 English Dub',
        seeders: 1,
        sourceId: 'current-source',
        provider: 'Current Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const duplicate = ReleaseCandidate(
        infoHash: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        magnetUri:
            'magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        releaseName: '[Current Group] Duplicate English Dub',
        seeders: 500,
        sourceId: 'current-source',
        provider: 'Current Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const sameProvider = ReleaseCandidate(
        infoHash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        magnetUri:
            'magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        releaseName: '[Other Group] Show - 02 English Dub',
        seeders: 100,
        sourceId: 'current-source',
        provider: 'Current Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      const global = ReleaseCandidate(
        infoHash: 'cccccccccccccccccccccccccccccccccccccccc',
        magnetUri:
            'magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc',
        releaseName: '[Global] Show - 02 English Dub',
        seeders: 5000,
        sourceId: 'other-source',
        provider: 'Other Provider',
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      );
      final preferredWeb = _providerWebStream(
        providerId: 'preferred-web',
        providerName: 'Preferred Web',
        quality: '1080p',
      );
      final sourceSearched = Completer<void>();
      final allowPreflight = Completer<void>();
      PlaybackLaunch? opened;
      String? playerDebrid;
      var debridResolverCalls = 0;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredProvider: 'Current Provider',
              preferredAuthor: 'Current Group',
              preferredWebProviderId: 'preferred-web',
              episode: EpisodeReference(
                anilistMediaId: 525256,
                title: 'Cross Class Alternatives Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              playerDebrid = state.uri.queryParameters['debrid'];
              return const Scaffold(body: Text('WEB WITH DEBRID OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              _CallbackReleaseSource('debrid-alternatives', () async {
                if (!sourceSearched.isCompleted) sourceSearched.complete();
                return const [global, duplicate, sameProvider, exact];
              }),
            ),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([preferredWeb]),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              await allowPreflight.future;
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              debridResolverCalls++;
              return const _ReadyResolver();
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await sourceSearched.future;
      allowPreflight.complete();
      await _pumpUntilFound(tester, find.text('WEB WITH DEBRID OPENED'));
      expect(opened!.stream.isWebStream, isTrue);
      expect(playerDebrid, DebridService.torBox.slug);
      expect(debridResolverCalls, 0);
      expect(
        opened!.alternatives.map((release) => release.infoHash.toLowerCase()),
        [exact.infoHash, sameProvider.infoHash, global.infoHash],
      );
    },
  );

  testWidgets(
    'web autoplay uses highest quality when preferred language is unavailable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _NoopAddonStore();
      final webAggregator = _FixedWebAggregator([
        _webStream('480p'),
        _webStream('1080p'),
      ]);
      Uri? preflightUri;
      PlaybackLaunch? launch;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 424242,
                title: 'Sub-only Show',
                episode: 1,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              launch = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('WEB PLAYER OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(null),
            addonStoreProvider.overrideWithValue(store),
            webStreamAggregatorProvider.overrideWithValue(webAggregator),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              preflightUri = uri;
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('WEB PLAYER OPENED'));
      expect(preflightUri, Uri.parse('https://cdn.example.com/1080p.m3u8'));
      expect(launch!.stream.uri, preflightUri);
    },
  );

  testWidgets(
    'web autoplay waits for the preferred provider instead of opening an early result',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final other = _providerWebStream(
        providerId: 'other-provider',
        providerName: 'Other Provider',
        quality: '4K',
      );
      final preferred = _providerWebStream(
        providerId: 'preferred-provider',
        providerName: 'Preferred Provider',
        quality: '720p',
      );
      final sameProviderAlternative = _providerWebStream(
        providerId: 'preferred-provider',
        providerName: 'Preferred Provider',
        quality: '480p',
      );
      final preflighted = <Uri>[];
      PlaybackLaunch? opened;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredWebProviderId: 'preferred-provider',
              episode: EpisodeReference(
                anilistMediaId: 535353,
                title: 'Preferred Web Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, state) {
              opened = state.extra! as PlaybackLaunch;
              return const Scaffold(body: Text('PREFERRED WEB OPENED'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(null),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _ProgressiveWebAggregator(
                first: [other],
                completed: [other, preferred, sameProviderAlternative],
                gate: gate.future,
              ),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              preflighted.add(uri);
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.textContaining('Web 1/2'));
      expect(preflighted, isEmpty);
      expect(find.text(other.title), findsNothing);
      gate.complete();
      await _pumpUntilFound(tester, find.text('PREFERRED WEB OPENED'));
      expect(preflighted, [preferred.uri]);
      expect(
        opened!.directAlternatives.map(
          (alternative) => alternative.stream.providerId,
        ),
        ['preferred-provider', 'other-provider'],
      );
      expect(
        opened!.directAlternatives.map((alternative) => alternative.stream.uri),
        isNot(contains(preferred.uri)),
      );
    },
  );

  testWidgets(
    'preferred web discovery wait is bounded before opening another provider',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final fallback = _providerWebStream(
        providerId: 'available-provider',
        providerName: 'Available Provider',
        quality: '1080p',
      );
      final preflighted = <Uri>[];
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredWebProviderId: 'provider-that-never-responds',
              episode: EpisodeReference(
                anilistMediaId: 535356,
                title: 'Bounded Preferred Web Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) =>
                const Scaffold(body: Text('BOUNDED WEB FALLBACK OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(null),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _ManyPendingWebAggregator(available: fallback, gate: gate.future),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              preflighted.add(uri);
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.textContaining('Web 1/20'));
      await tester.pump(const Duration(seconds: 11));
      expect(preflighted, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      await _pumpUntilFound(tester, find.text('BOUNDED WEB FALLBACK OPENED'));
      expect(preflighted, [fallback.uri]);
      expect(gate.isCompleted, isFalse);
      gate.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'bounded preferred-provider fallback failure stays out of manual picker',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final fallback = _providerWebStream(
        providerId: 'rejected-provider',
        providerName: 'Rejected Provider',
        quality: '1080p',
      );
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredWebProviderId: 'provider-that-never-responds',
              episode: EpisodeReference(
                anilistMediaId: 535357,
                title: 'Bounded Failed Web Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(null),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _ManyPendingWebAggregator(available: fallback, gate: gate.future),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              throw const FormatException('fallback rejected');
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.textContaining('Web 1/20'));
      await tester.pump(const Duration(seconds: 13));
      await _pumpUntilFound(tester, find.text('No playable stream found'));
      expect(find.text('Choose your stream'), findsNothing);
      expect(find.text(fallback.title), findsNothing);
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      gate.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'exact preferred web provider opens while an unrelated debrid source is pending',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final never = Completer<List<ReleaseCandidate>>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(const []);
      });
      final preferred = _providerWebStream(
        providerId: 'preferred-provider',
        providerName: 'Preferred Provider',
        quality: '1080p',
      );
      var debridResolverCalls = 0;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredWebProviderId: 'preferred-provider',
              episode: EpisodeReference(
                anilistMediaId: 535354,
                title: 'Immediate Preferred Web Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) =>
                const Scaffold(body: Text('IMMEDIATE WEB OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              _CallbackReleaseSource('never', () => never.future),
            ),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([preferred]),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              debridResolverCalls++;
              return const _ReadyResolver();
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('IMMEDIATE WEB OPENED'));
      expect(debridResolverCalls, 0);
      expect(never.isCompleted, isFalse);
      never.complete(const []);
      await tester.pump();
    },
  );

  testWidgets(
    'preferred web provider fast path never overrides preferred audio',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final preferredSub = _providerWebStream(
        providerId: 'preferred-provider',
        providerName: 'Preferred Provider',
        quality: '1080p',
        isDubbed: false,
      );
      final otherDub = _providerWebStream(
        providerId: 'dub-provider',
        providerName: 'Dub Provider',
        quality: '720p',
      );
      final preflighted = <Uri>[];
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredWebProviderId: 'preferred-provider',
              episode: EpisodeReference(
                anilistMediaId: 535355,
                title: 'Audio Safe Web Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) =>
                const Scaffold(body: Text('AUDIO SAFE WEB OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(null),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _ProgressiveWebAggregator(
                first: [preferredSub],
                completed: [preferredSub, otherDub],
                gate: gate.future,
              ),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              preflighted.add(uri);
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.textContaining('Web 1/2'));
      expect(preflighted, isEmpty);
      gate.complete();
      await _pumpUntilFound(tester, find.text('AUDIO SAFE WEB OPENED'));
      expect(preflighted, [otherDub.uri]);
    },
  );

  testWidgets(
    'failed preferred web provider waits, then falls through without looping',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final preferred = _providerWebStream(
        providerId: 'preferred-provider',
        providerName: 'Preferred Provider',
        quality: '1080p',
      );
      final fallback = _providerWebStream(
        providerId: 'fallback-provider',
        providerName: 'Fallback Provider',
        quality: '720p',
      );
      final preflighted = <Uri>[];
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              preferredWebProviderId: 'preferred-provider',
              episode: EpisodeReference(
                anilistMediaId: 545454,
                title: 'Preferred Failure Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) =>
                const Scaffold(body: Text('WEB FALLBACK OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(null),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _ProgressiveWebAggregator(
                first: [preferred],
                completed: [preferred, fallback],
                gate: gate.future,
              ),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              preflighted.add(uri);
              if (uri == preferred.uri) {
                throw const FormatException('preferred stream rejected');
              }
              return ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'application/vnd.apple.mpegurl',
              );
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(
        tester,
        find.text('Waiting for the remaining web providers…'),
      );
      expect(preflighted, [preferred.uri]);
      gate.complete();
      await _pumpUntilFound(tester, find.text('WEB FALLBACK OPENED'));
      expect(preflighted, [preferred.uri, fallback.uri]);
    },
  );

  testWidgets('debrid autoplay exhaustion falls through to a web stream', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final web = _providerWebStream(
      providerId: 'web-fallback',
      providerName: 'Web Fallback',
      quality: '1080p',
    );
    var debridCalls = 0;
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 555555,
              title: 'Debrid Fallback Show',
              episode: 2,
              autoPlay: true,
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, state) => Scaffold(
            body: Text(
              (state.extra! as PlaybackLaunch).stream.isWebStream
                  ? 'DEBRID TO WEB OPENED'
                  : 'WRONG STREAM',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _FakeReleaseSource(),
          ),
          addonStoreProvider.overrideWithValue(_NoopAddonStore()),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator([web]),
          ),
          webStreamPreflightProvider.overrideWithValue((
            uri,
            headers, {
            subtitleUri,
          }) async {
            return ValidatedWebStream(
              uri: uri,
              headers: headers,
              contentType: 'application/vnd.apple.mpegurl',
            );
          }),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            debridCalls++;
            return const _ErrorResolver(
              DebridCacheMissException(DebridService.realDebrid),
            );
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await _pumpUntilFound(tester, find.text('DEBRID TO WEB OPENED'));
    expect(debridCalls, 1);
  });

  testWidgets('late web preflight completion never reads a disposed ref', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preflight = Completer<ValidatedWebStream>();
    final stream = _webStream('1080p');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(null),
          addonStoreProvider.overrideWithValue(_NoopAddonStore()),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator([stream]),
          ),
          webStreamPreflightProvider.overrideWithValue(
            (uri, headers, {subtitleUri}) => preflight.future,
          ),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 424243,
              title: 'Disposed Resolver',
              episode: 1,
              autoPlay: true,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.textContaining('Checking Provider'));
    // Simulate backing out while the provider preflight request is in flight.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    preflight.complete(
      ValidatedWebStream(
        uri: stream.uri,
        headers: stream.headers,
        contentType: 'application/vnd.apple.mpegurl',
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'autoplay no-result state offers Back and Retry without opening magnet input',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([]),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator(const []),
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 565656,
                title: 'No Results Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('No playable stream found'));
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Magnet URI'), findsNothing);
      expect(find.text('Send to Real-Debrid'), findsNothing);
    },
  );

  testWidgets(
    'Watch Together follow failure keeps manual source recovery available',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _ListReleaseSource([]),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator(const []),
            ),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              watchPartyFollow: true,
              episode: EpisodeReference(
                anilistMediaId: 565659,
                title: 'Host Follow Show',
                episode: 3,
                autoPlay: true,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('No playable stream found'));
      expect(find.text('Choose source'), findsOneWidget);
      expect(find.textContaining('remain in the Watch Party'), findsOneWidget);

      await tester.tap(find.text('Choose source'));
      await tester.pump();
      expect(find.text('No playable stream found'), findsNothing);
      expect(find.text('Choose source'), findsNothing);
    },
  );

  testWidgets('terminal Retry forces a fresh web-provider session', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final recovered = _providerWebStream(
      providerId: 'retry-provider',
      providerName: 'Retry Provider',
      quality: '1080p',
    );
    final aggregator = _RefreshAwareWebAggregator(recovered);
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 565657,
              title: 'Retry Show',
              episode: 2,
              autoPlay: true,
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, _) => const Scaffold(body: Text('REFRESHED WEB OPENED')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _ListReleaseSource([]),
          ),
          addonStoreProvider.overrideWithValue(_NoopAddonStore()),
          webStreamAggregatorProvider.overrideWithValue(aggregator),
          webStreamPreflightProvider.overrideWithValue((
            uri,
            headers, {
            subtitleUri,
          }) async {
            return ValidatedWebStream(
              uri: uri,
              headers: headers,
              contentType: 'application/vnd.apple.mpegurl',
            );
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await _pumpUntilFound(tester, find.text('No playable stream found'));
    await tester.tap(find.text('Retry'));
    await _pumpUntilFound(tester, find.text('REFRESHED WEB OPENED'));
    expect(aggregator.refreshValues, [false, true]);
  });

  testWidgets(
    'debrid cache miss with Web disabled never opens the manual picker',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
        'streaming_web_enabled': 'false',
      });
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _FakeReleaseSource(),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              return const _ErrorResolver(
                DebridCacheMissException(DebridService.realDebrid),
              );
            }),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 565658,
                title: 'No Web Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('No playable stream found'));
      expect(find.text('Choose your stream'), findsNothing);
      expect(find.text('Magnet URI'), findsNothing);
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'debrid exhaustion plus completed empty Web reaches terminal state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _FakeReleaseSource(),
            ),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator(const []),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              return const _ErrorResolver(
                DebridCacheMissException(DebridService.realDebrid),
              );
            }),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 565659,
                title: 'Empty Web Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('No playable stream found'));
      expect(find.text('Choose your stream'), findsNothing);
      expect(find.text('Magnet URI'), findsNothing);
      expect(find.text('Back'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'exhausted debrid and web autoplay reaches a stable terminal state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final web = _providerWebStream(
        providerId: 'only-web',
        providerName: 'Only Web',
        quality: '1080p',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _FakeReleaseSource(),
            ),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([web]),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) async {
              throw const FormatException('web stream rejected');
            }),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              return const _ErrorResolver(
                DebridCacheMissException(DebridService.realDebrid),
              );
            }),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 575757,
                title: 'Everything Failed Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('No playable stream found'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('No playable stream found'), findsOneWidget);
      expect(find.text('Trying another stream…'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Magnet URI'), findsNothing);
    },
  );

  testWidgets(
    'expired web autoplay budget reaches terminal without retry loop',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final first = _providerWebStream(
        providerId: 'slow-provider',
        providerName: 'Slow Provider',
        quality: '1080p',
      );
      final remaining = _providerWebStream(
        providerId: 'remaining-provider',
        providerName: 'Remaining Provider',
        quality: '720p',
      );
      var now = DateTime.utc(2026, 8, 13);
      final preflight = Completer<ValidatedWebStream>();
      var preflightCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(null),
            addonStoreProvider.overrideWithValue(_NoopAddonStore()),
            webStreamAggregatorProvider.overrideWithValue(
              _FixedWebAggregator([first, remaining]),
            ),
            webStreamPreflightProvider.overrideWithValue((
              uri,
              headers, {
              subtitleUri,
            }) {
              preflightCalls++;
              return preflight.future;
            }),
          ],
          child: MaterialApp(
            home: ResolveEpisodeScreen(
              clock: () => now,
              episode: EpisodeReference(
                anilistMediaId: 585858,
                title: 'Budget Show',
                episode: 2,
                autoPlay: true,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.textContaining('Checking'));
      now = now.add(const Duration(seconds: 46));
      preflight.completeError(
        const FormatException('slow stream rejected'),
        StackTrace.current,
      );
      await tester.pump();
      await _pumpUntilFound(tester, find.text('No playable stream found'));
      await tester.pump(const Duration(seconds: 2));
      expect(preflightCalls, 1);
      expect(find.text('No playable stream found'), findsOneWidget);
      expect(find.text('Trying another stream…'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets('web autoplay preflights at most eight unique candidates', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final streams = [
      for (var index = 0; index < 9; index++)
        _providerWebStream(
          providerId: 'provider-$index',
          providerName: 'Provider $index',
          quality: '${1080 - index}p',
        ),
    ];
    var preflightCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(null),
          addonStoreProvider.overrideWithValue(_NoopAddonStore()),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator(streams),
          ),
          webStreamPreflightProvider.overrideWithValue((
            uri,
            headers, {
            subtitleUri,
          }) async {
            preflightCalls++;
            throw const FormatException('stream rejected');
          }),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 585859,
              title: 'Bounded Web Show',
              episode: 2,
              autoPlay: true,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('No playable stream found'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(preflightCalls, 8);
    expect(find.text('No playable stream found'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
    'release-specific failures continue through the fifth unique candidate',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var resolverCalls = 0;
      final router = GoRouter(
        initialLocation: '/resolve',
        routes: [
          GoRoute(
            path: '/resolve',
            builder: (_, _) => const ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42,
                title: 'Example Show',
                episode: 1,
              ),
            ),
          ),
          GoRoute(
            path: '/player',
            builder: (_, _) => const Scaffold(body: Text('PLAYER OPENED')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _RankedReleaseSource(5),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return resolverCalls == 5
                  ? const _ReadyResolver()
                  : _ErrorResolver(
                      RealDebridException.fromApi(code: 35, httpStatus: 403),
                    );
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await _pumpUntilFound(tester, find.text('Release 5'));
      await tester.tap(find.text('Release 5'));
      await _pumpUntilFound(tester, find.text('PLAYER OPENED'));

      expect(resolverCalls, 5);
    },
  );

  testWidgets('cached candidate failover keeps one opening shell mounted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final firstFailure = Completer<void>();
    final secondReady = Completer<void>();
    addTearDown(() {
      if (!firstFailure.isCompleted) firstFailure.complete();
      if (!secondReady.isCompleted) secondReady.complete();
    });
    var resolverCalls = 0;
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 4242,
              title: 'Stable failover shell',
              episode: 1,
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, _) => const Scaffold(body: Text('PLAYER OPENED')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _RankedReleaseSource(2),
          ),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator(const []),
          ),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            resolverCalls++;
            return resolverCalls == 1
                ? _FailingResolver(firstFailure.future)
                : _DelayedReadyResolver(secondReady.future);
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await _pumpUntilFound(tester, find.text('Release 2'));
    await tester.tap(find.text('Release 2'));
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('resolve-opening-shell')),
    );

    firstFailure.complete();
    await tester.pump();
    await tester.pump();

    expect(resolverCalls, 2);
    expect(find.byKey(const ValueKey('resolve-opening-shell')), findsOneWidget);
    expect(find.byKey(const ValueKey('resolve-search-shell')), findsNothing);
    expect(find.text('Choose your stream'), findsNothing);

    secondReady.complete();
    await _pumpUntilFound(tester, find.text('PLAYER OPENED'));
  });

  testWidgets('disposing the source picker closes a late ready lease', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ready = Completer<void>();
    final lease = _CountingPlaybackLease();
    addTearDown(() {
      if (!ready.isCompleted) ready.complete();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _FakeReleaseSource(),
          ),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator(const []),
          ),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            return _DelayedLeasedReadyResolver(ready.future, lease);
          }),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 4243,
              title: 'Example Show',
              episode: 1,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('Dubbed release'));
    await tester.tap(find.text('Dubbed release'));
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('resolve-opening-shell')),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    ready.complete();
    await tester.pump();
    await tester.pump();

    expect(lease.closeCount, 1);
  });

  testWidgets('release exhaustion reports the aggregate failure safely', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var resolverCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _RankedReleaseSource(3),
          ),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            resolverCalls++;
            return _ErrorResolver(
              RealDebridException.fromApi(code: 35, httpStatus: 403),
            );
          }),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 42,
              title: 'Example Show',
              episode: 1,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('Release 3'));
    await tester.tap(find.text('Release 3'));
    await _pumpUntilFound(
      tester,
      find.textContaining('could not provide 3 different releases'),
    );

    expect(resolverCalls, 3);
    expect(find.textContaining('infringing_file'), findsNothing);
  });

  testWidgets(
    'uncached Real-Debrid releases report that no download was kept',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var resolverCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _RankedReleaseSource(3),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return const _ErrorResolver(
                DebridCacheMissException(DebridService.realDebrid),
              );
            }),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42,
                title: 'Example Show',
                episode: 1,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('Release 3'));
      await tester.tap(find.text('Release 3'));
      await _pumpUntilFound(
        tester,
        find.textContaining('No instantly cached Real-Debrid stream was found'),
      );

      expect(resolverCalls, 3);
      expect(find.textContaining('did not leave an uncached'), findsOneWidget);
    },
  );

  testWidgets('terminal Real-Debrid authorization failure stops failover', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var resolverCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _RankedReleaseSource(5),
          ),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            resolverCalls++;
            return _ErrorResolver(
              RealDebridException.fromApi(code: 8, httpStatus: 401),
            );
          }),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 42,
              title: 'Example Show',
              episode: 1,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('Release 5'));
    await tester.tap(find.text('Release 5'));
    await _pumpUntilFound(tester, find.textContaining('Reconnect it'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(resolverCalls, 1);
    expect(find.textContaining('infringing_file'), findsNothing);
  });

  testWidgets(
    'terminal debrid cleanup failure stops failover and names the dashboard',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 1080));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var resolverCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            configuredReleaseSourceProvider.overrideWithValue(
              const _RankedReleaseSource(5),
            ),
            debridStreamResolverFactoryProvider.overrideWithValue(({
              required service,
              required token,
              required source,
            }) {
              resolverCalls++;
              return const _ErrorResolver(
                DebridCleanupFailureException(DebridService.realDebrid),
              );
            }),
          ],
          child: const MaterialApp(
            home: ResolveEpisodeScreen(
              episode: EpisodeReference(
                anilistMediaId: 42,
                title: 'Example Show',
                episode: 1,
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('Release 5'));
      await tester.tap(find.text('Release 5'));
      await _pumpUntilFound(
        tester,
        find.textContaining('Check your Real-Debrid dashboard'),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(resolverCalls, 1);
      expect(find.textContaining('Automatic failover stopped'), findsOneWidget);
    },
  );

  testWidgets('Real-Debrid rate limiting does not fan out across releases', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var resolverCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          configuredReleaseSourceProvider.overrideWithValue(
            const _RankedReleaseSource(5),
          ),
          debridStreamResolverFactoryProvider.overrideWithValue(({
            required service,
            required token,
            required source,
          }) {
            resolverCalls++;
            return _ErrorResolver(RealDebridException.fromApi(code: 34));
          }),
        ],
        child: const MaterialApp(
          home: ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 42,
              title: 'Example Show',
              episode: 1,
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('Release 5'));
    await tester.tap(find.text('Release 5'));
    await _pumpUntilFound(tester, find.textContaining('too many requests'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(resolverCalls, 1);
  });

  for (final testCase
      in <
        ({
          DebridService service,
          DebridProviderFailure error,
          String expectedMessage,
        })
      >[
        (
          service: DebridService.realDebrid,
          error: RealDebridException.fromApi(code: 8, httpStatus: 401),
          expectedMessage: 'Reconnect it',
        ),
        (
          service: DebridService.torBox,
          error: const TorBoxException(
            'TorBox token expired',
            code: 'AUTH_ERROR',
          ),
          expectedMessage: 'TorBox token expired',
        ),
        (
          service: DebridService.premiumize,
          error: const PremiumizeException(
            'Premiumize token expired',
            code: 'authentication_failed',
          ),
          expectedMessage: 'Premiumize token expired',
        ),
        (
          service: DebridService.allDebrid,
          error: const AllDebridException(
            'AllDebrid token expired',
            code: 'AUTH_BAD_APIKEY',
          ),
          expectedMessage: 'AllDebrid token expired',
        ),
      ]) {
    testWidgets(
      '${testCase.service.displayName} terminal provider errors stop Resolve '
      'candidate fan-out',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          testCase.service.tokenStorageKey: 'provider-token',
        });
        await tester.binding.setSurfaceSize(const Size(1920, 1080));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var resolverCalls = 0;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              configuredReleaseSourceProvider.overrideWithValue(
                const _RankedReleaseSource(5),
              ),
              debridStreamResolverFactoryProvider.overrideWithValue(({
                required service,
                required token,
                required source,
              }) {
                expect(service, testCase.service);
                resolverCalls++;
                return _ErrorResolver(testCase.error);
              }),
            ],
            child: const MaterialApp(
              home: ResolveEpisodeScreen(
                episode: EpisodeReference(
                  anilistMediaId: 42,
                  title: 'Example Show',
                  episode: 1,
                ),
              ),
            ),
          ),
        );

        await _pumpUntilFound(tester, find.text('Release 5'));
        await tester.tap(find.text('Release 5'));
        await _pumpUntilFound(
          tester,
          find.textContaining(testCase.expectedMessage),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(resolverCalls, 1);
      },
    );
  }

  test(
    'stream filters distinguish language, quality, codec, HDR and batches',
    () {
      const release = ReleaseCandidate(
        infoHash: 'hash',
        magnetUri: 'magnet:?xt=urn:btih:hash',
        releaseName: 'Show S01 2160p HEVC HDR Dual Audio Batch',
        seeders: 50,
        sourceId: 'test',
        isDubbed: true,
        isBatch: true,
        isHdr: true,
        quality: '2160p',
        codec: 'HEVC',
      );

      expect(
        releaseMatchesStreamFilters(
          release,
          language: 'dub',
          quality: 'p2160',
          codec: 'hevc',
          hdr: 'hdr',
        ),
        isTrue,
      );
      expect(
        releaseMatchesStreamFilters(release, language: 'sub'),
        isTrue,
        reason: 'dual-audio files contain a usable original-language track',
      );
      expect(releaseMatchesStreamFilters(release, allowBatch: false), isFalse);
    },
  );

  test('preferred language is ranked before provider affinity on fallback', () {
    const dubbed = ReleaseCandidate(
      infoHash: 'dub',
      magnetUri: 'magnet:?xt=urn:btih:dub',
      releaseName: '[Other] Show 01 English Dub',
      seeders: 1,
      sourceId: 'other',
      isDubbed: true,
    );
    const subtitled = ReleaseCandidate(
      infoHash: 'sub',
      magnetUri: 'magnet:?xt=urn:btih:sub',
      releaseName: '[Preferred] Show 01',
      seeders: 500,
      sourceId: 'preferred',
      provider: 'Preferred provider',
    );

    expect(
      compareStreamReleases(
        dubbed,
        subtitled,
        preferredProvider: 'Preferred provider',
        preferredAudio: PlaybackAudioPreference.dub,
      ),
      lessThan(0),
    );
  });

  testWidgets(
    'Auto Pick stays off by default and leaves the picker in control',
    (tester) async {
      var resolverCalls = 0;
      final probe = await _pumpAutoPickScenario(
        tester,
        mediaId: 99001,
        settings: const SettingsPreferences(
          loaded: true,
          webStreamsEnabled: false,
        ),
        releases: const [_autoPickDub1080],
        resolverFactory: ({required service, required token, required source}) {
          resolverCalls++;
          return const _ReadyResolver();
        },
      );

      await _pumpUntilFound(tester, find.text('DEBRID STREAMS'));

      expect(resolverCalls, 0);
      expect(probe.launch, isNull);
      expect(find.text(_autoPickDub1080.releaseName), findsOneWidget);
    },
  );

  testWidgets('Auto Pick bypasses the picker on a normal resolve open', (
    tester,
  ) async {
    final attempted = <String>[];
    var webPreflightCalls = 0;
    final excludedWeb = _providerWebStream(
      providerId: 'excluded-web',
      providerName: 'Excluded Web',
      quality: '1080p',
    );
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99002,
      settings: const SettingsPreferences(
        loaded: true,
        autoPickSourceEnabled: true,
        autoPickSourcePriority: [
          AutoPickSourcePriority.debrid,
          AutoPickSourcePriority.web,
        ],
      ),
      releases: const [_autoPickDub1080],
      webStreams: [excludedWeb],
      preflight: (uri, headers, {subtitleUri}) async {
        webPreflightCalls++;
        return ValidatedWebStream(
          uri: uri,
          headers: headers,
          contentType: 'video/mp4',
        );
      },
      resolverFactory: ({required service, required token, required source}) {
        return _SourceAwareResolver(source, (candidate) {
          attempted.add(candidate.infoHash);
          return null;
        });
      },
    );

    await _pumpUntilFound(tester, find.text('AUTO PICK PLAYER OPENED'));
    await tester.pumpAndSettle();

    expect(attempted, [_autoPickDub1080.infoHash]);
    expect(webPreflightCalls, 0);
    expect(probe.launch?.selectedRelease.infoHash, _autoPickDub1080.infoHash);
    expect(find.text('DEBRID STREAMS'), findsNothing);
  });

  testWidgets(
    'default Auto Pick keeps unknown Your Media behind a matching Debrid tier',
    (tester) async {
      final libraryService = _FixedLibraryEpisodeSourceService([
        _autoPickLibrarySource('default-local'),
      ]);
      var resolverCalls = 0;
      final probe = await _pumpAutoPickScenario(
        tester,
        mediaId: 99101,
        settings: const SettingsPreferences(
          loaded: true,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
          autoPickAudio: AutoPickAudio.dubOnly,
        ),
        releases: const [_autoPickDub1080],
        libraryService: libraryService,
        resolverFactory: ({required service, required token, required source}) {
          resolverCalls++;
          return const _ReadyResolver();
        },
      );

      await _pumpUntilFound(tester, find.text('AUTO PICK PLAYER OPENED'));

      expect(probe.launch?.selectedRelease.infoHash, _autoPickDub1080.infoHash);
      expect(resolverCalls, 1);
      expect(libraryService.preparedSources, isEmpty);
    },
  );

  testWidgets(
    'Auto Pick opens one exact Your Media episode when network classes are unavailable',
    (tester) async {
      final libraryService = _FixedLibraryEpisodeSourceService([
        _autoPickLibrarySource('local-fallback'),
      ]);
      final probe = await _pumpAutoPickScenario(
        tester,
        mediaId: 99102,
        settings: const SettingsPreferences(
          loaded: true,
          debridStreamsEnabled: false,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
          autoPickAudio: AutoPickAudio.dubOnly,
        ),
        releases: const [],
        libraryService: libraryService,
      );

      await _pumpUntilCondition(
        tester,
        () => libraryService.preparedSources.isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(probe.launch, isNull);
      expect(libraryService.preparedSources, hasLength(1));
      expect(
        libraryService.preparedSources.single.stableKey,
        'jellyfin:local-fallback',
      );
      expect(find.text('DEBRID STREAMS'), findsNothing);
    },
  );

  testWidgets(
    'Auto Pick uses a unique catalog-year library match over an unknown remake',
    (tester) async {
      final exact = _autoPickLibrarySource(
        'fruits-2019',
        seriesName: 'Fruits Basket (2019)',
      );
      final unknown = _autoPickLibrarySource(
        'fruits-unknown',
        seriesName: 'Fruits Basket',
        seasonNumber: 2,
      );
      final libraryService = _FixedLibraryEpisodeSourceService([
        unknown,
        exact,
      ]);

      await _pumpAutoPickScenario(
        tester,
        mediaId: 99110,
        episodeTitle: 'Fruits Basket',
        episodeYear: 2019,
        settings: const SettingsPreferences(
          loaded: true,
          debridStreamsEnabled: false,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
        ),
        releases: const [],
        libraryService: libraryService,
      );

      await _pumpUntilCondition(
        tester,
        () => libraryService.preparedSources.isNotEmpty,
      );

      expect(libraryService.preparedSources, [same(exact)]);
    },
  );

  testWidgets(
    'Auto Pick waits for full library discovery before rejecting a late conflict',
    (tester) async {
      final releaseConflict = Completer<void>();
      final first = _autoPickLibrarySource(
        'collision-season-1',
        seasonNumber: 1,
      );
      final second = _autoPickLibrarySource(
        'collision-season-2',
        seasonNumber: 2,
      );
      final libraryService = _IncrementalLibraryEpisodeSourceService(
        first: LibraryEpisodeSearchResult(sources: [first]),
        complete: LibraryEpisodeSearchResult(sources: [first, second]),
        releaseCompleteResult: releaseConflict.future,
      );

      await _pumpAutoPickScenario(
        tester,
        mediaId: 99111,
        settings: const SettingsPreferences(
          loaded: true,
          debridStreamsEnabled: false,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
        ),
        releases: const [],
        libraryService: libraryService,
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        libraryService.preparedSources,
        isEmpty,
        reason: 'the first progressive result must wait for search completion',
      );

      releaseConflict.complete();
      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
      );

      expect(libraryService.preparedSources, isEmpty);
      expect(find.text('LOCAL SOURCES'), findsOneWidget);
      expect(
        find.textContaining('No source matched Auto Pick:'),
        findsOneWidget,
      );
      expect(find.textContaining('Episode 1'), findsAtLeastNWidgets(2));
    },
  );

  testWidgets(
    'Back from Auto Pick Your Media returns to a usable manual picker',
    (tester) async {
      final libraryService = _FixedLibraryEpisodeSourceService(
        [_autoPickLibrarySource('local-exit')],
        onPreparePlayback: (_) async =>
            _testLibraryPlaybackRequest('local-exit'),
      );
      var playerOpens = 0;
      await _pumpAutoPickScenario(
        tester,
        mediaId: 99107,
        settings: const SettingsPreferences(
          loaded: true,
          debridStreamsEnabled: false,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
        ),
        releases: const [],
        libraryService: libraryService,
        libraryPlaybackOpener: (_, _, {required bool automatic}) async {
          expect(automatic, isTrue);
          playerOpens++;
          return const LibraryPlaybackResult(
            position: Duration(seconds: 30),
            duration: Duration(minutes: 24),
            reason: LibraryPlaybackEndReason.exited,
            started: true,
          );
        },
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(playerOpens, 1);
      expect(libraryService.preparedSources, hasLength(1));
      expect(libraryService.compatibilityPrepareCount, 0);
      expect(find.byKey(const ValueKey('resolve-opening-shell')), findsNothing);
      expect(find.text('LOCAL SOURCES'), findsOneWidget);
      expect(find.textContaining('Episode 1'), findsWidgets);
      expect(
        find.textContaining('Playback closed. Choose a source below'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'completed Auto Pick Your Media playback also releases the opening shell',
    (tester) async {
      final libraryService = _FixedLibraryEpisodeSourceService(
        [_autoPickLibrarySource('local-completed')],
        onPreparePlayback: (_) async =>
            _testLibraryPlaybackRequest('local-completed'),
      );
      await _pumpAutoPickScenario(
        tester,
        mediaId: 99108,
        settings: const SettingsPreferences(
          loaded: true,
          debridStreamsEnabled: false,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
        ),
        releases: const [],
        libraryService: libraryService,
        libraryPlaybackOpener: (_, _, {required bool automatic}) async {
          expect(automatic, isTrue);
          return const LibraryPlaybackResult(
            position: Duration(minutes: 24),
            duration: Duration(minutes: 24),
            reason: LibraryPlaybackEndReason.completed,
            started: true,
          );
        },
      );

      await _pumpUntilFound(
        tester,
        find.textContaining('Playback finished. Choose another source'),
      );

      expect(find.byKey(const ValueKey('resolve-opening-shell')), findsNothing);
      expect(find.text('LOCAL SOURCES'), findsOneWidget);
      expect(libraryService.compatibilityPrepareCount, 0);
    },
  );

  testWidgets(
    'typed library preparation failure advances to the next source class',
    (tester) async {
      final libraryService = _FixedLibraryEpisodeSourceService(
        [_autoPickLibrarySource('a-preparation-fails')],
        onPreparePlayback: (source) async =>
            _testLibraryPlaybackRequest(source.stableKey),
      );
      var playerOpens = 0;
      final probe = await _pumpAutoPickScenario(
        tester,
        mediaId: 99109,
        settings: const SettingsPreferences(
          loaded: true,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
          autoPickSourcePriority: [
            AutoPickSourcePriority.yourMedia,
            AutoPickSourcePriority.debrid,
          ],
        ),
        releases: const [_autoPickDub1080],
        libraryService: libraryService,
        libraryPlaybackOpener: (_, _, {required bool automatic}) async {
          expect(automatic, isTrue);
          playerOpens++;
          return const LibraryPlaybackResult(
            position: Duration.zero,
            duration: Duration.zero,
            reason: LibraryPlaybackEndReason.failed,
            started: false,
            error: 'Private media could not be prepared safely.',
            failureStage: LibraryPlaybackFailureStage.preparation,
          );
        },
      );

      await _pumpUntilFound(tester, find.text('AUTO PICK PLAYER OPENED'));

      expect(playerOpens, 1);
      expect(libraryService.preparedSources.map((source) => source.stableKey), [
        'jellyfin:a-preparation-fails',
      ]);
      expect(libraryService.compatibilityPrepareCount, 0);
      expect(probe.launch?.selectedRelease.infoHash, _autoPickDub1080.infoHash);
    },
  );

  testWidgets(
    'promoting Your Media explicitly lets its unknown tracks win first',
    (tester) async {
      final libraryService = _FixedLibraryEpisodeSourceService([
        _autoPickLibrarySource('promoted-local'),
      ]);
      var resolverCalls = 0;
      await _pumpAutoPickScenario(
        tester,
        mediaId: 99103,
        settings: const SettingsPreferences(
          loaded: true,
          autoPickSourceEnabled: true,
          autoPickSourcePriority: [
            AutoPickSourcePriority.yourMedia,
            AutoPickSourcePriority.debrid,
            AutoPickSourcePriority.web,
          ],
          autoPickAudio: AutoPickAudio.dubOnly,
        ),
        releases: const [_autoPickDub1080],
        libraryService: libraryService,
        resolverFactory: ({required service, required token, required source}) {
          resolverCalls++;
          return const _ReadyResolver();
        },
      );

      await _pumpUntilCondition(
        tester,
        () => libraryService.preparedSources.isNotEmpty,
      );

      expect(
        libraryService.preparedSources.single.stableKey,
        'jellyfin:promoted-local',
      );
      expect(resolverCalls, 0);
      expect(find.text('AUTO PICK PLAYER OPENED'), findsNothing);
    },
  );

  testWidgets(
    'a late Your Media preparation cannot escape the 45 second fallback',
    (tester) async {
      final preparation = Completer<LibraryPlaybackRequest>();
      final libraryService = _FixedLibraryEpisodeSourceService([
        _autoPickLibrarySource('slow-local'),
      ], onPreparePlayback: (_) => preparation.future);
      await _pumpAutoPickScenario(
        tester,
        mediaId: 99106,
        settings: const SettingsPreferences(
          loaded: true,
          debridStreamsEnabled: false,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
        ),
        releases: const [],
        libraryService: libraryService,
      );
      await _pumpUntilCondition(
        tester,
        () => libraryService.preparedSources.isNotEmpty,
      );

      await tester.pump(const Duration(seconds: 46));
      expect(
        find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
        findsOneWidget,
      );

      preparation.complete(_testLibraryPlaybackRequest('slow-local'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
        findsOneWidget,
      );
    },
  );

  testWidgets('Auto Pick rejects an unverified generic library result', (
    tester,
  ) async {
    final libraryService = _FixedLibraryEpisodeSourceService([
      _autoPickLibrarySource('wrong-series', seriesName: 'Different series'),
    ]);
    await _pumpAutoPickScenario(
      tester,
      mediaId: 99104,
      settings: const SettingsPreferences(
        loaded: true,
        debridStreamsEnabled: false,
        webStreamsEnabled: false,
        autoPickSourceEnabled: true,
      ),
      releases: const [],
      libraryService: libraryService,
    );

    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
    );

    expect(libraryService.preparedSources, isEmpty);
    expect(find.textContaining('No source matched Auto Pick:'), findsOneWidget);
  });

  testWidgets(
    'ambiguous Your Media choices stay manual without spending attempts',
    (tester) async {
      final libraryService = _FixedLibraryEpisodeSourceService([
        for (var index = 0; index < 9; index++)
          _autoPickLibrarySource('bounded-local-$index'),
      ]);
      await _pumpAutoPickScenario(
        tester,
        mediaId: 99105,
        settings: const SettingsPreferences(
          loaded: true,
          debridStreamsEnabled: false,
          webStreamsEnabled: false,
          autoPickSourceEnabled: true,
        ),
        releases: const [],
        libraryService: libraryService,
      );

      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
      );

      expect(libraryService.preparedSources, isEmpty);
      expect(
        find.textContaining('No source matched Auto Pick:'),
        findsOneWidget,
      );
      expect(find.text('LOCAL SOURCES'), findsOneWidget);
    },
  );

  testWidgets('Auto Pick owns the opening shell before its first launch', (
    tester,
  ) async {
    final ready = Completer<void>();
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99014,
      settings: const SettingsPreferences(
        loaded: true,
        webStreamsEnabled: false,
        autoPickSourceEnabled: true,
      ),
      releases: const [_autoPickDub1080],
      resolverFactory: ({required service, required token, required source}) =>
          _DelayedReadyResolver(ready.future),
    );

    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('resolve-opening-shell')),
    );
    expect(find.text('DEBRID STREAMS'), findsNothing);
    expect(probe.launch, isNull);

    ready.complete();
    await _pumpUntilFound(tester, find.text('AUTO PICK PLAYER OPENED'));
    expect(probe.launch, isNotNull);
  });

  testWidgets(
    'Web-first Auto Pick opens Web before an available Debrid release',
    (tester) async {
      var debridResolverCalls = 0;
      final web = _providerWebStream(
        providerId: 'allowed-web-only',
        providerName: 'Allowed Web only',
        quality: '1080p',
      );
      final probe = await _pumpAutoPickScenario(
        tester,
        mediaId: 99008,
        settings: const SettingsPreferences(
          loaded: true,
          autoPickSourceEnabled: true,
          autoPickSourcePriority: [
            AutoPickSourcePriority.web,
            AutoPickSourcePriority.debrid,
          ],
        ),
        releases: const [_autoPickDub1080],
        webStreams: [web],
        resolverFactory: ({required service, required token, required source}) {
          debridResolverCalls++;
          return const _ReadyResolver();
        },
      );

      await _pumpUntilFound(tester, find.text('AUTO PICK PLAYER OPENED'));

      expect(debridResolverCalls, 0);
      expect(probe.launch?.stream.isWebStream, isTrue);
      expect(probe.launch?.selectedRelease.sourceId, 'web:allowed-web-only');
    },
  );

  testWidgets('Auto Pick caps mixed Debrid and Web failures at eight total', (
    tester,
  ) async {
    final releases = [
      for (var index = 0; index < 10; index++)
        ReleaseCandidate(
          infoHash: '${index + 10}'.padLeft(40, '0'),
          magnetUri: 'magnet:?xt=urn:btih:${'${index + 10}'.padLeft(40, '0')}',
          releaseName: 'Mixed Debrid ${index + 1} dub 1080p',
          seeders: 100 - index,
          sourceId: 'mixed-budget',
          quality: '1080p',
          isDubbed: true,
        ),
    ];
    final webStreams = [
      for (var index = 0; index < 5; index++)
        _providerWebStream(
          providerId: 'mixed-web-$index',
          providerName: 'Mixed Web ${index + 1}',
          quality: '1080p',
        ),
    ];
    var webAttempts = 0;
    var debridAttempts = 0;
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99009,
      settings: const SettingsPreferences(
        loaded: true,
        autoPickSourceEnabled: true,
        autoPickSourcePriority: [
          AutoPickSourcePriority.web,
          AutoPickSourcePriority.debrid,
        ],
      ),
      releases: releases,
      webStreams: webStreams,
      preflight: (uri, headers, {subtitleUri}) async {
        webAttempts++;
        throw StateError('web unavailable');
      },
      resolverFactory: ({required service, required token, required source}) {
        return _SourceAwareResolver(source, (_) {
          debridAttempts++;
          return StateError('debrid unavailable');
        });
      },
    );

    await _pumpUntilFound(tester, find.text('DEBRID STREAMS'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(probe.launch, isNull);
    expect(webAttempts, 5);
    expect(debridAttempts, 3);
    expect(webAttempts + debridAttempts, 8);
    expect(find.textContaining('Automatic selection could not'), findsNothing);
  });

  testWidgets('Auto Pick honors quality priority while keeping audio strict', (
    tester,
  ) async {
    const wrongQuality = ReleaseCandidate(
      infoHash: '2222222222222222222222222222222222222222',
      magnetUri: 'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
      releaseName: 'Wrong quality dub 2160p',
      seeders: 900,
      sourceId: 'strict-test',
      quality: '2160p',
      isDubbed: true,
    );
    const wrongAudio = ReleaseCandidate(
      infoHash: '3333333333333333333333333333333333333333',
      magnetUri: 'magnet:?xt=urn:btih:3333333333333333333333333333333333333333',
      releaseName: 'Wrong audio sub 1080p',
      seeders: 800,
      sourceId: 'strict-test',
      quality: '1080p',
    );
    final attempted = <String>[];
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99003,
      settings: const SettingsPreferences(
        loaded: true,
        webStreamsEnabled: false,
        autoPickSourceEnabled: true,
        autoPickQualityPriority: [
          AutoPickQuality.p1080,
          AutoPickQuality.p2160,
          AutoPickQuality.p720,
          AutoPickQuality.p480,
        ],
        autoPickAudio: AutoPickAudio.dubOnly,
      ),
      releases: const [wrongQuality, wrongAudio, _autoPickDub1080],
      resolverFactory: ({required service, required token, required source}) {
        return _SourceAwareResolver(source, (candidate) {
          attempted.add(candidate.infoHash);
          return null;
        });
      },
    );

    await _pumpUntilFound(tester, find.text('AUTO PICK PLAYER OPENED'));

    expect(attempted, [_autoPickDub1080.infoHash]);
    expect(probe.launch?.selectedRelease.infoHash, _autoPickDub1080.infoHash);
  });

  testWidgets('automatic next-episode opens honor Auto Pick priorities', (
    tester,
  ) async {
    const wrongQuality = ReleaseCandidate(
      infoHash: '6666666666666666666666666666666666666666',
      magnetUri: 'magnet:?xt=urn:btih:6666666666666666666666666666666666666666',
      releaseName: 'Higher ranked wrong-quality dub 2160p',
      seeders: 900,
      sourceId: 'autoplay-strict-test',
      quality: '2160p',
      isDubbed: true,
    );
    const wrongAudio = ReleaseCandidate(
      infoHash: '7777777777777777777777777777777777777777',
      magnetUri: 'magnet:?xt=urn:btih:7777777777777777777777777777777777777777',
      releaseName: 'Wrong-audio sub 1080p',
      seeders: 800,
      sourceId: 'autoplay-strict-test',
      quality: '1080p',
    );
    final attempted = <String>[];
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99011,
      autoPlay: true,
      settings: const SettingsPreferences(
        loaded: true,
        webStreamsEnabled: false,
        autoPickSourceEnabled: true,
        autoPickQualityPriority: [
          AutoPickQuality.p1080,
          AutoPickQuality.p2160,
          AutoPickQuality.p720,
          AutoPickQuality.p480,
        ],
        autoPickAudio: AutoPickAudio.dubOnly,
      ),
      releases: const [wrongQuality, wrongAudio, _autoPickDub1080],
      resolverFactory: ({required service, required token, required source}) {
        return _SourceAwareResolver(source, (candidate) {
          attempted.add(candidate.infoHash);
          return null;
        });
      },
    );

    await _pumpUntilFound(tester, find.text('AUTO PICK PLAYER OPENED'));

    expect(attempted, [_autoPickDub1080.infoHash]);
    expect(probe.launch?.selectedRelease.infoHash, _autoPickDub1080.infoHash);
  });

  testWidgets('root Watch-follow Back is safe and idempotent', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('HOME ROOT')),
        ),
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            watchPartyFollow: true,
            episode: EpisodeReference(
              anilistMediaId: 99012,
              title: 'Follower root',
              episode: 2,
              autoPlay: true,
            ),
          ),
        ),
        GoRoute(
          path: '/watch-together',
          builder: (_, _) => const Scaffold(body: Text('WATCH ROOT')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _ResolveSettingsController(
              const SettingsPreferences(
                loaded: true,
                debridStreamsEnabled: false,
              ),
            ),
          ),
          configuredReleaseSourceProvider.overrideWithValue(null),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator(const []),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _pumpUntilFound(tester, find.byIcon(Icons.arrow_back_rounded));

    await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('WATCH ROOT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('root no-result Back returns to details without GoError', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/resolve',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('HOME ROOT')),
        ),
        GoRoute(
          path: '/resolve',
          builder: (_, _) => const ResolveEpisodeScreen(
            episode: EpisodeReference(
              anilistMediaId: 99013,
              title: 'No-result root',
              episode: 2,
              autoPlay: true,
            ),
          ),
        ),
        GoRoute(
          path: '/anime/:id',
          builder: (_, state) =>
              Scaffold(body: Text('DETAILS ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _ResolveSettingsController(
              const SettingsPreferences(
                loaded: true,
                debridStreamsEnabled: false,
              ),
            ),
          ),
          configuredReleaseSourceProvider.overrideWithValue(null),
          webStreamAggregatorProvider.overrideWithValue(
            _FixedWebAggregator(const []),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _pumpUntilFound(tester, find.text('No playable stream found'));

    await tester.tap(find.text('Back'));
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();

    expect(find.text('DETAILS 99013'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed Auto Pick never retries a wrong-audio release', (
    tester,
  ) async {
    const disallowed = ReleaseCandidate(
      infoHash: '5555555555555555555555555555555555555555',
      magnetUri: 'magnet:?xt=urn:btih:5555555555555555555555555555555555555555',
      releaseName: 'Disallowed sub 720p fallback',
      seeders: 999,
      sourceId: 'strict-bypass-test',
      quality: '720p',
    );
    final attempted = <String>[];
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99010,
      settings: const SettingsPreferences(
        loaded: true,
        webStreamsEnabled: false,
        autoPickSourceEnabled: true,
        autoPickQualityPriority: [
          AutoPickQuality.p1080,
          AutoPickQuality.p2160,
          AutoPickQuality.p720,
          AutoPickQuality.p480,
        ],
        autoPickAudio: AutoPickAudio.dubOnly,
      ),
      releases: const [_autoPickDub1080, disallowed],
      resolverFactory: ({required service, required token, required source}) {
        return _SourceAwareResolver(source, (candidate) {
          attempted.add(candidate.infoHash);
          return StateError('allowed candidate failed');
        });
      },
    );

    await _pumpUntilFound(tester, find.text('DEBRID STREAMS'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(probe.launch, isNull);
    expect(attempted, [_autoPickDub1080.infoHash]);
    expect(find.text(_autoPickDub1080.releaseName), findsOneWidget);
    expect(find.textContaining('2 Debrid'), findsOneWidget);
    expect(find.textContaining('Sources matching Auto Pick ('), findsOneWidget);
    expect(
      find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
      findsOneWidget,
    );
  });

  testWidgets('no audio match reveals every manual result cleanly', (
    tester,
  ) async {
    var resolverCalls = 0;
    final disallowedWeb = _providerWebStream(
      providerId: 'manual-web-result',
      providerName: 'Manual Web result',
      quality: '1080p',
    );
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99004,
      settings: const SettingsPreferences(
        loaded: true,
        autoPickSourceEnabled: true,
        autoPickSourcePriority: [
          AutoPickSourcePriority.web,
          AutoPickSourcePriority.debrid,
        ],
        autoPickQualityPriority: [
          AutoPickQuality.p480,
          AutoPickQuality.p720,
          AutoPickQuality.p1080,
          AutoPickQuality.p2160,
        ],
        autoPickAudio: AutoPickAudio.subOnly,
      ),
      releases: const [_autoPickDub1080],
      webStreams: [disallowedWeb],
      resolverFactory: ({required service, required token, required source}) {
        resolverCalls++;
        return const _ReadyResolver();
      },
    );

    await _pumpUntilFound(tester, find.text('DEBRID STREAMS'));

    expect(probe.launch, isNull);
    expect(resolverCalls, 0);
    expect(find.text(_autoPickDub1080.releaseName), findsOneWidget);
    expect(find.text('WEB STREAMS'), findsOneWidget);
    expect(find.text('Manual Web result 1080p'), findsOneWidget);
    expect(find.textContaining('No source matched Auto Pick:'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('stream-picker-auto-pick-notice')),
      findsOneWidget,
    );
    expect(find.text('Could not resolve this episode'), findsNothing);
  });

  testWidgets('failed allowed Auto Pick candidates fall back without a loop', (
    tester,
  ) async {
    const second = ReleaseCandidate(
      infoHash: '4444444444444444444444444444444444444444',
      magnetUri: 'magnet:?xt=urn:btih:4444444444444444444444444444444444444444',
      releaseName: 'Second allowed dub 1080p',
      seeders: 1,
      sourceId: 'strict-test',
      quality: '1080p',
      isDubbed: true,
    );
    final attempted = <String>[];
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99005,
      settings: const SettingsPreferences(
        loaded: true,
        webStreamsEnabled: false,
        autoPickSourceEnabled: true,
        autoPickQualityPriority: [
          AutoPickQuality.p1080,
          AutoPickQuality.p2160,
          AutoPickQuality.p720,
          AutoPickQuality.p480,
        ],
        autoPickAudio: AutoPickAudio.dubOnly,
      ),
      releases: const [_autoPickDub1080, second],
      resolverFactory: ({required service, required token, required source}) {
        return _SourceAwareResolver(source, (candidate) {
          attempted.add(candidate.infoHash);
          return StateError('not playable');
        });
      },
    );

    await _pumpUntilFound(tester, find.text('DEBRID STREAMS'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(probe.launch, isNull);
    expect(attempted.toSet(), {_autoPickDub1080.infoHash, second.infoHash});
    expect(attempted, hasLength(2));
    expect(find.text(_autoPickDub1080.releaseName), findsOneWidget);
    expect(find.text(second.releaseName), findsOneWidget);
    expect(find.textContaining('Sources matching Auto Pick'), findsOneWidget);
  });

  testWidgets(
    'Auto Pick priority wait is bounded before using a lower source',
    (tester) async {
      final never = Completer<void>();
      final probe = await _pumpAutoPickScenario(
        tester,
        mediaId: 99006,
        settings: const SettingsPreferences(
          loaded: true,
          autoPickSourceEnabled: true,
          autoPickSourcePriority: [
            AutoPickSourcePriority.web,
            AutoPickSourcePriority.debrid,
          ],
        ),
        releases: const [_autoPickDub1080],
        webAggregator: _NeverCompletingWebAggregator(never.future),
      );

      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('DEBRID STREAMS'), findsNothing);
      await tester.pump(const Duration(seconds: 13));

      expect(probe.launch?.selectedRelease.infoHash, _autoPickDub1080.infoHash);
      await tester.pump();
      expect(find.text('AUTO PICK PLAYER OPENED'), findsOneWidget);
    },
  );

  testWidgets('late Web preflight cannot escape Auto Pick manual fallback', (
    tester,
  ) async {
    final preflightGate = Completer<void>();
    final web = _providerWebStream(
      providerId: 'slow-auto-pick',
      providerName: 'Slow provider',
      quality: '1080p',
    );
    final probe = await _pumpAutoPickScenario(
      tester,
      mediaId: 99007,
      settings: const SettingsPreferences(
        loaded: true,
        autoPickSourceEnabled: true,
        autoPickSourcePriority: [
          AutoPickSourcePriority.web,
          AutoPickSourcePriority.debrid,
        ],
        autoPickQualityPriority: [
          AutoPickQuality.p1080,
          AutoPickQuality.p2160,
          AutoPickQuality.p720,
          AutoPickQuality.p480,
        ],
        autoPickAudio: AutoPickAudio.dubOnly,
      ),
      releases: const [_autoPickDub1080],
      webStreams: [web],
      preflight: (uri, headers, {subtitleUri}) async {
        await preflightGate.future;
        return ValidatedWebStream(
          uri: uri,
          headers: headers,
          contentType: 'video/mp4',
        );
      },
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 46));
    expect(find.text('DEBRID STREAMS'), findsOneWidget);
    expect(probe.launch, isNull);

    preflightGate.complete();
    await tester.pump(const Duration(seconds: 1));

    expect(probe.launch, isNull);
    expect(find.text('AUTO PICK PLAYER OPENED'), findsNothing);
    expect(find.text('DEBRID STREAMS'), findsOneWidget);
  });

  test('web qualities are ranked from highest to lowest', () {
    final streams = [
      _webStream('Auto'),
      _webStream('720p'),
      _webStream('4K UHD'),
      _webStream('1080p'),
    ]..sort(compareWebStreamsByQuality);

    expect(streams.map((item) => item.title), [
      '4K UHD',
      '1080p',
      '720p',
      'Auto',
    ]);
  });

  test('cached-only exhaustion message covers every debrid service', () {
    for (final service in DebridService.values) {
      final message = debridCacheExhaustedMessage(service, 3);
      expect(message, contains(service.displayName));
      expect(message, contains('3 releases'));
      expect(message, contains('did not leave an uncached cloud download'));
    }
  });
}

const _autoPickDub1080 = ReleaseCandidate(
  infoHash: '1111111111111111111111111111111111111111',
  magnetUri: 'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
  releaseName: 'Allowed manual dub 1080p',
  seeders: 10,
  sourceId: 'auto-pick-test',
  quality: '1080p',
  isDubbed: true,
);

LibraryEpisodeSource _autoPickLibrarySource(
  String id, {
  String seriesName = 'Auto Pick test',
  int? productionYear,
  int seasonNumber = 1,
}) => LibraryEpisodeSource.jellyfin(
  JellyfinMediaItem(
    id: id,
    name: 'Episode 1',
    type: 'Episode',
    seriesName: seriesName,
    productionYear: productionYear,
    seasonNumber: seasonNumber,
    episodeNumber: 1,
    videoHeight: 1080,
  ),
);

LibraryPlaybackRequest _testLibraryPlaybackRequest(String id) =>
    LibraryPlaybackRequest(
      source: Uri.parse('https://library.example.com/$id.mkv'),
      title: 'Episode 1',
      releaseName: 'Auto Pick test - Episode 1',
      streamLabel: 'Your Media',
      checkpointKey: 'checkpoint-$id',
      timelineIdentity: 'timeline-$id',
    );

class _AutoPickProbe {
  PlaybackLaunch? launch;
}

class _DirectTorrentProbe {
  PlaybackLaunch? launch;
  int factoryCalls = 0;
  late final _ResolveSettingsController settings;
}

const _supportedDirectTorrentCapability = DirectTorrentCapability(
  supported: true,
  engine: 'libtorrent4j-2.1.0-38',
  maximumFileBytes: 6 * 1024 * 1024 * 1024,
  supportsSeeking: true,
  temporaryStorage: true,
);

Future<_DirectTorrentProbe> _pumpDirectTorrentScenario(
  WidgetTester tester, {
  bool autoPick = false,
  bool directTorrentSupported = true,
  bool offlineDownloadsEnabled = true,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final probe = _DirectTorrentProbe();
  final router = GoRouter(
    initialLocation: '/resolve',
    routes: [
      GoRoute(
        path: '/resolve',
        builder: (_, _) => const ResolveEpisodeScreen(
          episode: EpisodeReference(
            anilistMediaId: 909001,
            title: 'Direct torrent test',
            episode: 1,
          ),
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          probe.launch = state.extra! as PlaybackLaunch;
          return const Scaffold(body: Text('DIRECT TORRENT PLAYER OPENED'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);

  probe.settings = _ResolveSettingsController(
    SettingsPreferences(
      loaded: true,
      webStreamsEnabled: false,
      directTorrentStreamingEnabled: true,
      offlineDownloadsEnabled: offlineDownloadsEnabled,
      autoPickSourceEnabled: autoPick,
      autoPickSourcePriority: const [
        AutoPickSourcePriority.debrid,
        AutoPickSourcePriority.web,
        AutoPickSourcePriority.yourMedia,
      ],
    ),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsPreferencesProvider.overrideWith((_) => probe.settings),
        configuredReleaseSourceProvider.overrideWithValue(
          const _FakeReleaseSource(),
        ),
        addonStoreProvider.overrideWithValue(_NoopAddonStore()),
        webStreamAggregatorProvider.overrideWithValue(_FixedWebAggregator([])),
        libraryEpisodeSourceServiceProvider.overrideWithValue(
          _FixedLibraryEpisodeSourceService(const [], connected: false),
        ),
        seriesPreferencesReaderProvider.overrideWithValue(
          (_) async => const SeriesPlaybackPreferences(),
        ),
        seriesPreferencesWriterProvider.overrideWithValue((_, _) async {}),
        resolveDeviceProfileReaderProvider.overrideWithValue(
          () async => const TvDeviceProfile.unknown(),
        ),
        resolveFailureCountsReaderProvider.overrideWithValue(
          (_) async => const {},
        ),
        directTorrentCapabilityReaderProvider.overrideWithValue(
          () async => directTorrentSupported
              ? _supportedDirectTorrentCapability
              : const DirectTorrentCapability.unsupported(),
        ),
        directTorrentStreamResolverFactoryProvider.overrideWithValue(({
          required source,
        }) {
          probe.factoryCalls++;
          return const _DirectReadyResolver();
        }),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  return probe;
}

class _ResolveSettingsController extends SettingsPreferencesController {
  _ResolveSettingsController(SettingsPreferences preferences)
    : super(const FlutterSecureStorage()) {
    state = preferences;
  }

  @override
  Future<void> load() async {}
}

class _FixedLibraryEpisodeSourceService implements LibraryEpisodeSourceService {
  _FixedLibraryEpisodeSourceService(
    this.sources, {
    this.connected = true,
    this.onPreparePlayback,
  });

  final List<LibraryEpisodeSource> sources;
  final bool connected;
  final Future<LibraryPlaybackRequest> Function(LibraryEpisodeSource source)?
  onPreparePlayback;
  LibraryWatchPartyIdentity? chosenIdentity;
  final List<LibraryEpisodeSource> preparedSources = [];
  int compatibilityPrepareCount = 0;

  @override
  bool get hasConnectedServer => connected;

  @override
  Future<void> loadConnections() async {}

  @override
  Stream<LibraryEpisodeSearchResult> watchSearch(EpisodeReference episode) =>
      Stream.value(LibraryEpisodeSearchResult(sources: sources));

  @override
  Future<LibraryPlaybackRequest> preparePlayback(
    LibraryEpisodeSource source, {
    LibraryWatchPartyIdentity? watchPartyIdentity,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
    bool forceCompatibility = false,
  }) {
    preparedSources.add(source);
    if (forceCompatibility) compatibilityPrepareCount++;
    chosenIdentity = watchPartyIdentity;
    final callback = onPreparePlayback;
    if (callback != null) return callback(source);
    return Completer<LibraryPlaybackRequest>().future;
  }

  @override
  Future<LibraryPlaybackRequest?> chooseLocalVideo({
    LibraryWatchPartyIdentity? watchPartyIdentity,
    PlaybackAudioPreference? requestedAudio,
  }) async {
    chosenIdentity = watchPartyIdentity;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _IncrementalLibraryEpisodeSourceService
    implements LibraryEpisodeSourceService {
  _IncrementalLibraryEpisodeSourceService({
    required this.first,
    required this.complete,
    required this.releaseCompleteResult,
  });

  final LibraryEpisodeSearchResult first;
  final LibraryEpisodeSearchResult complete;
  final Future<void> releaseCompleteResult;
  final List<LibraryEpisodeSource> preparedSources = [];

  @override
  bool get hasConnectedServer => true;

  @override
  Future<void> loadConnections() async {}

  @override
  Stream<LibraryEpisodeSearchResult> watchSearch(
    EpisodeReference episode,
  ) async* {
    yield first;
    await releaseCompleteResult;
    yield complete;
  }

  @override
  Future<LibraryPlaybackRequest> preparePlayback(
    LibraryEpisodeSource source, {
    LibraryWatchPartyIdentity? watchPartyIdentity,
    String preferredSubtitleLanguage = 'eng',
    PlaybackAudioPreference? requestedAudio,
    bool forceCompatibility = false,
  }) {
    preparedSources.add(source);
    return Completer<LibraryPlaybackRequest>().future;
  }

  @override
  Future<LibraryPlaybackRequest?> chooseLocalVideo({
    LibraryWatchPartyIdentity? watchPartyIdentity,
    PlaybackAudioPreference? requestedAudio,
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_AutoPickProbe> _pumpAutoPickScenario(
  WidgetTester tester, {
  required int mediaId,
  String episodeTitle = 'Auto Pick test',
  int? episodeYear,
  required SettingsPreferences settings,
  required List<ReleaseCandidate> releases,
  List<WebStreamResult> webStreams = const [],
  WebStreamAggregator? webAggregator,
  DebridStreamResolverFactory? resolverFactory,
  WebStreamPreflight? preflight,
  LibraryEpisodeSourceService? libraryService,
  LibraryPlaybackRouteOpener? libraryPlaybackOpener,
  bool autoPlay = false,
}) async {
  FlutterSecureStorage.setMockInitialValues({
    DebridService.realDebrid.tokenStorageKey: 'valid-auto-pick-token',
  });
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final probe = _AutoPickProbe();
  final router = GoRouter(
    initialLocation: '/resolve',
    routes: [
      GoRoute(
        path: '/resolve',
        builder: (_, _) => ResolveEpisodeScreen(
          episode: EpisodeReference(
            anilistMediaId: mediaId,
            title: episodeTitle,
            year: episodeYear,
            episode: 1,
            autoPlay: autoPlay,
          ),
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          probe.launch = state.extra! as PlaybackLaunch;
          return const Scaffold(body: Text('AUTO PICK PLAYER OPENED'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsPreferencesProvider.overrideWith(
          (_) => _ResolveSettingsController(settings),
        ),
        configuredReleaseSourceProvider.overrideWithValue(
          _ListReleaseSource(releases),
        ),
        addonStoreProvider.overrideWithValue(_NoopAddonStore()),
        seriesPreferencesReaderProvider.overrideWithValue(
          (_) async => const SeriesPlaybackPreferences(),
        ),
        seriesPreferencesWriterProvider.overrideWithValue((_, _) async {}),
        resolveDeviceProfileReaderProvider.overrideWithValue(
          () async => const TvDeviceProfile.unknown(),
        ),
        resolveFailureCountsReaderProvider.overrideWithValue(
          (_) async => const {},
        ),
        webStreamAggregatorProvider.overrideWithValue(
          webAggregator ?? _FixedWebAggregator(webStreams),
        ),
        webStreamPreflightProvider.overrideWithValue(
          preflight ??
              (uri, headers, {subtitleUri}) async => ValidatedWebStream(
                uri: uri,
                headers: headers,
                contentType: 'video/mp4',
              ),
        ),
        if (libraryService != null)
          libraryEpisodeSourceServiceProvider.overrideWithValue(libraryService),
        if (libraryPlaybackOpener != null)
          libraryPlaybackRouteOpenerProvider.overrideWithValue(
            libraryPlaybackOpener,
          ),
        debridStreamResolverFactoryProvider.overrideWithValue(
          resolverFactory ??
              ({required service, required token, required source}) =>
                  const _ReadyResolver(),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  return probe;
}

WebStreamResult _webStream(String quality) => WebStreamResult(
  providerId: quality,
  providerName: 'Provider',
  title: quality,
  uri: Uri.parse('https://cdn.example.com/$quality.m3u8'),
  quality: quality,
);

WebStreamResult _providerWebStream({
  required String providerId,
  required String providerName,
  required String quality,
  bool isDubbed = true,
  WebStreamAudioCapability? audioCapability,
}) => WebStreamResult(
  providerId: providerId,
  providerName: providerName,
  title: '$providerName $quality',
  uri: Uri.parse(
    'https://cdn.example.com/$providerId/${Uri.encodeComponent(quality)}.m3u8',
  ),
  quality: quality,
  isDubbed: isDubbed,
  audioCapability: audioCapability,
);

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40 && finder.evaluate().isEmpty; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 40 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

class _FakeReleaseSource implements ReleaseSource {
  const _FakeReleaseSource();

  @override
  String get id => 'fake';

  @override
  Future<List<ReleaseCandidate>> search(
    EpisodeReference episode,
  ) async => const [
    ReleaseCandidate(
      infoHash: '0123456789abcdef0123456789abcdef01234567',
      magnetUri: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
      releaseName: 'Dubbed release',
      seeders: 10,
      sourceId: 'fake',
      isDubbed: true,
      quality: '1080p',
      codec: 'H.264',
    ),
  ];
}

class _CallbackReleaseSource implements ReleaseSource {
  const _CallbackReleaseSource(this.id, this.callback);

  @override
  final String id;
  final Future<List<ReleaseCandidate>> Function() callback;

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) => callback();
}

Future<PlaybackLaunch> _pumpAutoplayLaunch(
  WidgetTester tester, {
  required int mediaId,
  List<ReleaseCandidate> releases = const [],
  List<WebStreamResult> webStreams = const [],
  SeriesPlaybackPreferences preferences = const SeriesPlaybackPreferences(),
  Map<String, String> secureValues = const {},
  String? preferredProvider,
  String? preferredSourceId,
  String? preferredWebProviderId,
  bool watchPartyFollow = false,
  String? watchPartySourceClass,
  String? watchPartySourceFingerprint,
  String? watchPartySourceKey,
  TvDeviceProfile deviceProfile = const TvDeviceProfile.unknown(),
  Map<String, int> failureCounts = const {},
}) async {
  FlutterSecureStorage.setMockInitialValues({
    DebridService.realDebrid.tokenStorageKey: 'valid-manual-token',
    ...secureValues,
  });
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  PlaybackLaunch? opened;
  final router = GoRouter(
    initialLocation: '/resolve',
    routes: [
      GoRoute(
        path: '/resolve',
        builder: (_, _) => ResolveEpisodeScreen(
          preferredProvider: preferredProvider,
          preferredSourceId: preferredSourceId,
          preferredWebProviderId: preferredWebProviderId,
          watchPartyFollow: watchPartyFollow,
          watchPartySourceClass: watchPartySourceClass,
          watchPartySourceFingerprint: watchPartySourceFingerprint,
          watchPartySourceKey: watchPartySourceKey,
          episode: EpisodeReference(
            anilistMediaId: mediaId,
            title: 'Strict tier show',
            episode: 2,
            autoPlay: true,
          ),
        ),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          opened = state.extra! as PlaybackLaunch;
          return const Scaffold(body: Text('STRICT TIER PLAYER OPENED'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        configuredReleaseSourceProvider.overrideWithValue(
          _ListReleaseSource(releases),
        ),
        addonStoreProvider.overrideWithValue(_NoopAddonStore()),
        seriesPreferencesReaderProvider.overrideWithValue(
          (_) async => preferences,
        ),
        resolveDeviceProfileReaderProvider.overrideWithValue(
          () async => deviceProfile,
        ),
        resolveFailureCountsReaderProvider.overrideWithValue(
          (_) async => failureCounts,
        ),
        webStreamAggregatorProvider.overrideWithValue(
          _FixedWebAggregator(webStreams),
        ),
        webStreamPreflightProvider.overrideWithValue((
          uri,
          headers, {
          subtitleUri,
        }) async {
          return ValidatedWebStream(
            uri: uri,
            headers: headers,
            contentType: 'video/mp4',
          );
        }),
        debridStreamResolverFactoryProvider.overrideWithValue(
          ({required service, required token, required source}) =>
              const _ReadyResolver(),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await _pumpUntilFound(tester, find.text('STRICT TIER PLAYER OPENED'));
  return opened!;
}

class _ListReleaseSource implements ReleaseSource {
  const _ListReleaseSource(this.releases);

  final List<ReleaseCandidate> releases;

  @override
  String get id => 'list';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async =>
      releases;
}

class _RankedReleaseSource implements ReleaseSource {
  const _RankedReleaseSource(this.count);

  final int count;

  @override
  String get id => 'ranked';

  @override
  Future<List<ReleaseCandidate>> search(EpisodeReference episode) async => [
    for (var index = 1; index <= count; index++)
      ReleaseCandidate(
        infoHash: index.toString().padLeft(40, '0'),
        magnetUri: 'magnet:?xt=urn:btih:${index.toString().padLeft(40, '0')}',
        releaseName: 'Release $index',
        seeders: index,
        sourceId: id,
        isDubbed: true,
        quality: '1080p',
        codec: 'H.264',
      ),
  ];
}

class _FailingResolver implements StreamResolver {
  const _FailingResolver(this.failWhenReleased);

  final Future<void> failWhenReleased;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    await failWhenReleased;
    throw StateError('Release unavailable');
  }
}

class _ReadyResolver implements StreamResolver {
  const _ReadyResolver();

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    yield StreamReady(
      uri: Uri.parse('https://debrid.example.com/episode.mkv'),
      displayName: 'Ready',
      debridService: DebridService.realDebrid,
    );
  }
}

class _DirectReadyResolver implements StreamResolver {
  const _DirectReadyResolver();

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    yield StreamReady(
      uri: Uri.parse(
        'http://127.0.0.1:43121/'
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      displayName: 'Direct torrent ready',
      isDirectTorrent: true,
    );
  }
}

class _DelayedReadyResolver implements StreamResolver {
  const _DelayedReadyResolver(this.ready);

  final Future<void> ready;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    await ready;
    yield StreamReady(
      uri: Uri.parse('https://debrid.example.com/delayed-episode.mkv'),
      displayName: 'Ready',
      debridService: DebridService.realDebrid,
    );
  }
}

class _DelayedLeasedReadyResolver implements StreamResolver {
  const _DelayedLeasedReadyResolver(this.ready, this.lease);

  final Future<void> ready;
  final PlaybackResourceLease lease;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    await ready;
    yield StreamReady(
      uri: Uri.parse('https://debrid.example.com/example-show-01.mkv'),
      displayName: 'Example Show - 01.mkv',
      debridService: DebridService.realDebrid,
      playbackLease: lease,
    );
  }
}

class _CountingPlaybackLease implements PlaybackResourceLease {
  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
  }
}

class _SourceAwareResolver implements StreamResolver {
  const _SourceAwareResolver(this.source, this.errorForCandidate);

  final ReleaseSource source;
  final Object? Function(ReleaseCandidate candidate) errorForCandidate;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    final candidate = (await source.search(episode)).single;
    final error = errorForCandidate(candidate);
    if (error != null) throw error;
    yield StreamReady(
      uri: Uri.parse('https://debrid.example.com/${candidate.infoHash}.mkv'),
      displayName: candidate.releaseName,
      debridService: DebridService.realDebrid,
    );
  }
}

class _ErrorResolver implements StreamResolver {
  const _ErrorResolver(this.error);

  final Object error;

  @override
  Stream<StreamResolution> resolve(EpisodeReference episode) async* {
    throw error;
  }
}

class _NeverCompletingWebAggregator extends WebStreamAggregator {
  _NeverCompletingWebAggregator(this.never)
    : super(AddonStore(TetoTvDatabase.instance));

  final Future<void> never;
  int searchCalls = 0;

  @override
  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) async* {
    searchCalls++;
    yield const WebStreamSearchProgress(
      totalProviders: 1,
      pendingProviderNames: ['Never finishes'],
    );
    await never;
  }
}

class _FixedWebAggregator extends WebStreamAggregator {
  _FixedWebAggregator(this.streams)
    : super(AddonStore(TetoTvDatabase.instance));

  final List<WebStreamResult> streams;

  @override
  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) async* {
    yield WebStreamSearchProgress(
      aggregation: WebStreamAggregation(streams: streams),
      completedProviders: 1,
      totalProviders: 1,
    );
  }
}

class _FailureAndStreamWebAggregator extends WebStreamAggregator {
  _FailureAndStreamWebAggregator(
    this.available, {
    List<WebProviderFailure>? failures,
  }) : failures =
           failures ??
           const [
             WebProviderFailure(
               providerId: 'unavailable-web',
               providerName: 'Unavailable provider',
               message: 'No matching title or episode from this provider.',
               status: WebProviderFailureStatus.noMatch,
               reason: 'no_stream',
             ),
           ],
       super(AddonStore(TetoTvDatabase.instance));

  final WebStreamResult? available;
  final List<WebProviderFailure> failures;

  @override
  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) async* {
    yield WebStreamSearchProgress(
      aggregation: WebStreamAggregation(
        streams: [?available],
        failures: failures,
      ),
      completedProviders: failures.length + (available == null ? 0 : 1),
      totalProviders: failures.length + (available == null ? 0 : 1),
    );
  }
}

class _ProgressiveWebAggregator extends WebStreamAggregator {
  _ProgressiveWebAggregator({
    required this.first,
    required this.completed,
    required this.gate,
  }) : super(AddonStore(TetoTvDatabase.instance));

  final List<WebStreamResult> first;
  final List<WebStreamResult> completed;
  final Future<void> gate;

  @override
  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) async* {
    yield WebStreamSearchProgress(
      aggregation: WebStreamAggregation(streams: first),
      completedProviders: 1,
      totalProviders: 2,
      pendingProviderNames: const ['Remaining provider'],
    );
    await gate;
    yield WebStreamSearchProgress(
      aggregation: WebStreamAggregation(streams: completed),
      completedProviders: 2,
      totalProviders: 2,
    );
  }
}

class _ManyPendingWebAggregator extends WebStreamAggregator {
  _ManyPendingWebAggregator({required this.available, required this.gate})
    : super(AddonStore(TetoTvDatabase.instance));

  final WebStreamResult available;
  final Future<void> gate;

  @override
  Stream<WebStreamSearchProgress> searchIncrementally(
    EpisodeReference episode,
  ) async* {
    yield WebStreamSearchProgress(
      aggregation: WebStreamAggregation(streams: [available]),
      completedProviders: 1,
      totalProviders: 20,
      pendingProviderNames: const [
        'Preferred provider',
        'Provider 3',
        'Provider 4',
        'Provider 5',
        'Provider 6',
        'Provider 7',
        'Provider 8',
        'Provider 9',
        'Provider 10',
        'Provider 11',
        'Provider 12',
        'Provider 13',
        'Provider 14',
        'Provider 15',
        'Provider 16',
        'Provider 17',
        'Provider 18',
        'Provider 19',
        'Provider 20',
      ],
    );
    await gate;
  }
}

class _RefreshAwareWebAggregator extends WebStreamAggregator {
  _RefreshAwareWebAggregator(this.recovered)
    : super(AddonStore(TetoTvDatabase.instance));

  final WebStreamResult recovered;
  final List<bool> refreshValues = [];

  @override
  Stream<WebStreamSearchProgress> watchSearchIncrementally(
    EpisodeReference episode, {
    bool refresh = false,
  }) async* {
    refreshValues.add(refresh);
    yield WebStreamSearchProgress(
      aggregation: WebStreamAggregation(
        streams: refresh ? [recovered] : const [],
      ),
      completedProviders: 1,
      totalProviders: 1,
    );
  }
}

class _NoopAddonStore extends AddonStore {
  _NoopAddonStore() : super(TetoTvDatabase.instance);

  @override
  Future<void> recordProviderSuccess(String id) async {}

  @override
  Future<ProviderHealth> recordProviderFailure(
    String id,
    Object error, {
    String? stage,
    String? reason,
  }) async => ProviderHealth(providerId: id);
}
