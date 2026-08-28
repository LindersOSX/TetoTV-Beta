import 'dart:async';

import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/features/player/application/filler_episode_navigation.dart';
import 'package:anime_tv/features/streaming/application/next_episode_preparation_controller.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_media_follower.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('route handoff joins concurrent release requests', () async {
    final controller = WatchPartyPlayerRouteHandoffController();
    final owner = Object();
    final releaseGate = Completer<bool>();
    var releaseCalls = 0;
    controller.bind(owner, () {
      releaseCalls += 1;
      return releaseGate.future;
    });

    final first = controller.releaseActivePlayer();
    final second = controller.releaseActivePlayer();
    expect(releaseCalls, 1);

    releaseGate.complete(true);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(releaseCalls, 1);
  });

  test('stale player handoff cannot authorize replacement route', () async {
    final controller = WatchPartyPlayerRouteHandoffController();
    final oldOwner = Object();
    final newOwner = Object();
    final oldReleaseGate = Completer<bool>();
    var newReleaseCalls = 0;
    controller.bind(oldOwner, () => oldReleaseGate.future);

    final staleRelease = controller.releaseActivePlayer();
    controller.bind(newOwner, () async {
      newReleaseCalls += 1;
      return true;
    });
    controller.unbind(oldOwner);
    oldReleaseGate.complete(true);

    expect(await staleRelease, isFalse);
    expect(controller.hasActivePlayer, isTrue);
    expect(await controller.releaseActivePlayer(), isTrue);
    expect(newReleaseCalls, 1);
  });

  test('failed target can retry without reopening a superseded episode', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    final episodeTwo = _guestState(
      revision: 20,
      media: _media(anilistId: 100, episode: 2),
      attachedMedia: _media(anilistId: 100, episode: 1),
    );
    final first = planner.evaluate(episodeTwo)!;

    expect(planner.releaseFailedTarget(first), isTrue);
    final retry = planner.evaluate(episodeTwo);
    expect(retry?.episode, 2);

    final episodeThree = _guestState(
      revision: 21,
      media: _media(anilistId: 100, episode: 3),
      attachedMedia: _media(anilistId: 100, episode: 1),
    );
    expect(planner.evaluate(episodeThree)?.episode, 3);
    expect(planner.releaseFailedTarget(retry!), isFalse);
    expect(planner.evaluate(episodeThree), isNull);
  });

  test('route retry budget is bounded and resets for a new target', () {
    final budget = WatchPartyMediaFollowRetryBudget();
    final episodeTwo = WatchPartyMediaFollowRequest(
      location: '/resolve?anilistId=100&episode=2',
      roomCode: '23456789',
      anilistId: 100,
      episode: 2,
      revision: 1,
      sessionGeneration: 1,
    );
    final episodeThree = WatchPartyMediaFollowRequest(
      location: '/resolve?anilistId=100&episode=3',
      roomCode: '23456789',
      anilistId: 100,
      episode: 3,
      revision: 2,
      sessionGeneration: 1,
    );

    expect(budget.nextDelay(episodeTwo), const Duration(milliseconds: 200));
    expect(budget.nextDelay(episodeTwo), const Duration(milliseconds: 400));
    expect(budget.nextDelay(episodeTwo), const Duration(milliseconds: 800));
    expect(budget.nextDelay(episodeTwo), isNull);
    expect(budget.recoveryDelay, const Duration(seconds: 5));
    expect(budget.nextDelay(episodeThree), const Duration(milliseconds: 200));
  });

  test('planner ownership rejects a late failure from a superseded target', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    final episodeTwo = planner.evaluate(
      _guestState(
        revision: 20,
        media: _media(anilistId: 100, episode: 2),
        attachedMedia: _media(anilistId: 100, episode: 1),
      ),
    )!;
    final episodeThree = planner.evaluate(
      _guestState(
        revision: 21,
        media: _media(anilistId: 100, episode: 3),
        attachedMedia: _media(anilistId: 100, episode: 1),
      ),
    )!;

    expect(planner.ownsTarget(episodeTwo), isFalse);
    expect(planner.releaseFailedTarget(episodeTwo), isFalse);
    expect(planner.ownsTarget(episodeThree), isTrue);
  });

  testWidgets(
    'async route failures retry with backoff and recover after exhaustion',
    (tester) async {
      final controller = _FollowerWatchPartyController(
        _guestState(
          revision: 20,
          media: _media(anilistId: 100, episode: 2),
          attachedMedia: _media(anilistId: 100, episode: 1),
        ),
      );
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
        ],
      );
      addTearDown(router.dispose);
      var attempts = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            watchPartyControllerProvider.overrideWith((_) => controller),
          ],
          child: MaterialApp(
            home: WatchPartyMediaFollowScope(
              router: router,
              preparedTargetReader: _noPreparedTarget,
              routeReplacement: (location, {extra}) {
                attempts += 1;
                expect(location, isNot(contains('24682468')));
                expect(location, isNot(contains('guest-token')));
                return Future<void>.error(
                  StateError('simulated route rejection'),
                );
              },
              child: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(attempts, 1);

      await tester.pump(const Duration(milliseconds: 199));
      expect(attempts, 1);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(attempts, 2);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(attempts, 3);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      expect(attempts, 4);

      await tester.pump(const Duration(milliseconds: 4999));
      expect(attempts, 4, reason: 'exhaustion must not create a tight loop');
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(attempts, 5, reason: 'the claimed target must recover later');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('late affinity cleanup is harmless after registration disposal', () {
    final owner = Object();
    final affinity = WatchPartyPlaybackAffinityController()
      ..bind(owner, const WatchPartyPlaybackAffinity())
      ..dispose();

    expect(() => affinity.unbind(owner), returnsNormally);
  });

  test('same attached episode never navigates', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    final state = _guestState(
      revision: 4,
      media: _media(anilistId: 100, episode: 2),
      attachedMedia: _media(anilistId: 100, episode: 2),
    );

    expect(planner.evaluate(state), isNull);
    expect(
      planner.evaluate(_copyState(state, revision: 5, playing: true)),
      isNull,
    );
  });

  test('same episode follows a changed host source fingerprint once', () {
    const hostDescriptor = WatchPartySourceDescriptor(
      sourceClass: WatchPartySourceClass.torrent,
      fingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      audio: WatchPartySourceAudio.dub,
      qualityHeight: 1080,
    );
    const guestDescriptor = WatchPartySourceDescriptor(
      sourceClass: WatchPartySourceClass.torrent,
      fingerprint:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      audio: WatchPartySourceAudio.dub,
      qualityHeight: 1080,
    );
    const hostMedia = WatchPartyMedia(
      kind: 'anilist',
      title: 'Show',
      anilistId: 100,
      episode: 2,
      sourceDescriptor: hostDescriptor,
    );
    const guestMedia = WatchPartyMedia(
      kind: 'anilist',
      title: 'Show',
      anilistId: 100,
      episode: 2,
      sourceDescriptor: guestDescriptor,
    );
    final planner = WatchPartyGuestMediaFollowPlanner();
    final session = _guestSession();

    final request = planner.evaluate(
      _guestState(
        revision: 5,
        media: hostMedia,
        attachedMedia: guestMedia,
        session: session,
      ),
    );

    expect(request, isNotNull);
    expect(request?.sourceFingerprint, hostDescriptor.fingerprint);
    final query = Uri.parse(request!.location).queryParameters;
    expect(query['watchPartySourceClass'], 'torrent');
    expect(query['watchPartySourceFingerprint'], hostDescriptor.fingerprint);
    expect(query['watchPartySourceKey'], hostDescriptor.sourceKey);
    expect(query['preferredQualityHeight'], '1080');
    expect(query['preferredAudio'], 'dub');
    expect(
      planner.evaluate(
        _guestState(
          revision: 6,
          media: hostMedia,
          attachedMedia: guestMedia,
          session: session,
        ),
      ),
      isNull,
      reason: 'playback revisions must not reopen the same source handoff',
    );
  });

  test('same fingerprint still follows changed host audio descriptor', () {
    const hostDescriptor = WatchPartySourceDescriptor(
      sourceClass: WatchPartySourceClass.torrent,
      fingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      audio: WatchPartySourceAudio.dub,
      qualityHeight: 1080,
    );
    const oldDescriptor = WatchPartySourceDescriptor(
      sourceClass: WatchPartySourceClass.torrent,
      fingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      audio: WatchPartySourceAudio.sub,
      qualityHeight: 1080,
    );
    final request = WatchPartyGuestMediaFollowPlanner().evaluate(
      _guestState(
        revision: 7,
        media: const WatchPartyMedia(
          kind: 'anilist',
          title: 'Show',
          anilistId: 100,
          episode: 2,
          sourceDescriptor: hostDescriptor,
        ),
        attachedMedia: const WatchPartyMedia(
          kind: 'anilist',
          title: 'Show',
          anilistId: 100,
          episode: 2,
          sourceDescriptor: oldDescriptor,
        ),
      ),
    );

    expect(request, isNotNull);
    expect(request?.sourceKey, hostDescriptor.sourceKey);
  });

  test('same-episode route matches only the current source handoff key', () {
    const descriptor = WatchPartySourceDescriptor(
      sourceClass: WatchPartySourceClass.torrent,
      fingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      audio: WatchPartySourceAudio.dub,
      qualityHeight: 1080,
    );
    final target = WatchPartyMediaFollowRequest(
      location: '/resolve',
      roomCode: '23456789',
      anilistId: 100,
      episode: 2,
      revision: 8,
      sessionGeneration: 1,
      sourceFingerprint: descriptor.fingerprint,
      sourceKey: descriptor.sourceKey,
    );

    expect(
      watchPartyRouteMatchesTarget(
        Uri.parse('/player?anilistId=100&episode=2'),
        target,
      ),
      isFalse,
    );
    expect(
      watchPartyRouteMatchesTarget(
        Uri(
          path: '/resolve',
          queryParameters: {
            'anilistId': '100',
            'episode': '2',
            'watchPartySourceKey': descriptor.sourceKey,
          },
        ),
        target,
      ),
      isTrue,
    );
    expect(
      watchPartyRouteMatchesTarget(
        Uri(
          path: '/player',
          queryParameters: {
            'anilistId': '100',
            'episode': '2',
            'watchPartyTargetSourceKey': descriptor.sourceKey,
          },
        ),
        target,
      ),
      isTrue,
    );
  });

  test('prepared handoff is accepted only for the host source descriptor', () {
    const hostRelease = ReleaseCandidate(
      infoHash: '1111111111111111111111111111111111111111',
      magnetUri: 'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
      releaseName: 'Host source',
      seeders: 1,
      sourceId: 'one',
      quality: '1080p',
      isDubbed: true,
    );
    const otherRelease = ReleaseCandidate(
      infoHash: '2222222222222222222222222222222222222222',
      magnetUri: 'magnet:?xt=urn:btih:2222222222222222222222222222222222222222',
      releaseName: 'Other source',
      seeders: 1,
      sourceId: 'two',
      quality: '1080p',
      isDubbed: true,
    );
    final descriptor = WatchPartySourceDescriptor.forRelease(hostRelease);
    final target = WatchPartyMediaFollowRequest(
      location: '/resolve',
      roomCode: '23456789',
      anilistId: 100,
      episode: 2,
      revision: 9,
      sessionGeneration: 1,
      sourceFingerprint: descriptor.fingerprint,
      sourceKey: descriptor.sourceKey,
    );
    final exact = _prepared(hostRelease);
    final mismatched = _prepared(otherRelease);

    expect(preparedWatchPartyTargetMatches(exact, target), isTrue);
    expect(preparedWatchPartyTargetMatches(mismatched, target), isFalse);
    expect(
      Uri.parse(
        preparedNextEpisodePlayerLocation(
          exact,
          watchPartyTargetSourceKey: descriptor.sourceKey,
        ),
      ).queryParameters['watchPartyTargetSourceKey'],
      descriptor.sourceKey,
    );
  });

  test('new episode navigates once despite repeated playback revisions', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    final initial = _guestState(
      revision: 10,
      media: _media(anilistId: 100, episode: 2),
      attachedMedia: _media(anilistId: 100, episode: 1),
    );

    final request = planner.evaluate(initial);
    expect(request?.anilistId, 100);
    expect(request?.episode, 2);
    expect(planner.evaluate(initial), isNull);
    expect(
      planner.evaluate(_copyState(initial, revision: 11, playing: true)),
      isNull,
    );
  });

  test('rapid E2 to E3 queue keeps only newest revision', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    final queue = WatchPartyMediaFollowQueue();
    final e2 = planner.evaluate(
      _guestState(
        revision: 20,
        media: _media(anilistId: 100, episode: 2),
        attachedMedia: _media(anilistId: 100, episode: 1),
      ),
    );
    final e3 = planner.evaluate(
      _guestState(
        revision: 21,
        media: _media(anilistId: 100, episode: 3),
        attachedMedia: _media(anilistId: 100, episode: 1),
      ),
    );

    queue.add(e2!);
    queue.add(e3!);
    expect(queue.hasPending, isTrue);
    expect(queue.takeLatest()?.episode, 3);
    expect(queue.hasPending, isFalse);
    expect(queue.takeLatest(), isNull);
  });

  test('different catalog show produces a bounded autoplay resolver route', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    final request = planner.evaluate(
      _guestState(
        revision: 30,
        media: _media(anilistId: 222, episode: 7),
        attachedMedia: _media(anilistId: 111, episode: 7),
      ),
      affinity: const WatchPartyPlaybackAffinity(
        preferredProvider: ' Provider\nName ',
        preferredAuthor: 'group',
        preferredSourceId: 'source',
        preferredWebProviderId: 'web-provider',
        preferredQualityHeight: 1080,
        preferredAudio: PlaybackAudioPreference.dub,
      ),
    );

    final uri = Uri.parse(request!.location);
    expect(uri.path, '/resolve');
    expect(uri.queryParameters['anilistId'], '222');
    expect(uri.queryParameters['episode'], '7');
    expect(uri.queryParameters['autoplay'], '1');
    expect(uri.queryParameters['watchPartyFollow'], '1');
    expect(uri.queryParameters['preferredProvider'], 'Provider Name');
    expect(uri.queryParameters['preferredQualityHeight'], '1080');
    expect(uri.queryParameters['preferredAudio'], 'dub');
  });

  test('private and local media can never trigger automatic routing', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    expect(
      planner.evaluate(
        _guestState(
          revision: 1,
          media: const WatchPartyMedia(
            kind: 'private',
            title: 'Private media',
            timelineFingerprint: 'opaque',
          ),
        ),
      ),
      isNull,
    );

    expect(
      planner.evaluate(
        _guestState(
          revision: 2,
          media: _media(anilistId: 100, episode: 2),
          attachedMedia: const WatchPartyMedia(
            kind: 'private',
            title: 'Local file',
            timelineFingerprint: 'opaque-local',
          ),
        ),
      ),
      isNull,
    );
  });

  test(
    'route contains public catalog metadata but no room capability data',
    () {
      const media = WatchPartyMedia(
        kind: 'anilist',
        title: 'Safe Show',
        anilistId: 444,
        episode: 9,
        coverUrl: 'https://images.example/cover.jpg',
        timelineFingerprint: 'must-not-leak',
      );
      final request = WatchPartyGuestMediaFollowPlanner().evaluate(
        _guestState(revision: 8, media: media),
      );

      expect(request, isNotNull);
      expect(request!.location, isNot(contains('must-not-leak')));
      expect(request.location, isNot(contains('guest-token')));
      expect(request.location, isNot(contains('24682468')));
      expect(request.location, isNot(contains('roomCode')));
      expect(
        Uri.parse(request.location).queryParameters['cover'],
        media.coverUrl,
      );
    },
  );

  test('stale media revision cannot replace a newer target', () {
    final planner = WatchPartyGuestMediaFollowPlanner();
    final session = _guestSession();
    expect(
      planner
          .evaluate(
            _guestState(
              revision: 42,
              media: _media(anilistId: 100, episode: 3),
              session: session,
            ),
          )
          ?.episode,
      3,
    );
    expect(
      planner.evaluate(
        _guestState(
          revision: 41,
          media: _media(anilistId: 100, episode: 2),
          session: session,
        ),
      ),
      isNull,
    );
  });
}

WatchPartyState _guestState({
  required int revision,
  required WatchPartyMedia media,
  WatchPartyMedia? attachedMedia,
  bool playing = false,
  WatchPartySession? session,
}) {
  final now = DateTime.utc(2026, 8, 20);
  return WatchPartyState(
    connection: WatchPartyConnection.connected,
    session: session ?? _guestSession(),
    snapshot: WatchPartySnapshot(
      roomCode: '24682468',
      role: WatchPartyRole.guest,
      revision: revision,
      playing: playing,
      position: const Duration(seconds: 15),
      effectiveAt: now,
      serverTime: now,
      receivedAt: now,
      participantCount: 2,
      readyCount: 1,
      expiresAt: now.add(const Duration(hours: 1)),
      media: media,
    ),
    attachedMedia: attachedMedia,
  );
}

WatchPartySession _guestSession() {
  final now = DateTime.utc(2026, 8, 20);
  return WatchPartySession(
    roomCode: '24682468',
    token: 'guest-token',
    role: WatchPartyRole.guest,
    expiresAt: now.add(const Duration(hours: 1)),
    watchUrl: Uri.parse('https://watch.example/watch?room=24682468'),
  );
}

WatchPartyState _copyState(
  WatchPartyState value, {
  required int revision,
  bool? playing,
}) {
  final snapshot = value.snapshot!;
  return value.copyWith(
    snapshot: WatchPartySnapshot(
      roomCode: snapshot.roomCode,
      role: snapshot.role,
      revision: revision,
      playing: playing ?? snapshot.playing,
      position: snapshot.position,
      effectiveAt: snapshot.effectiveAt,
      serverTime: snapshot.serverTime,
      receivedAt: snapshot.receivedAt,
      participantCount: snapshot.participantCount,
      readyCount: snapshot.readyCount,
      expiresAt: snapshot.expiresAt,
      media: snapshot.media,
    ),
  );
}

WatchPartyMedia _media({required int anilistId, required int episode}) =>
    WatchPartyMedia(
      kind: 'anilist',
      title: 'Show $anilistId',
      anilistId: anilistId,
      episode: episode,
      year: 2026,
    );

PreparedNextEpisode _prepared(ReleaseCandidate release) => PreparedNextEpisode(
  launch: PlaybackLaunch(
    stream: StreamReady(
      uri: Uri.parse('https://stream.example/video.mkv'),
      displayName: release.releaseName,
      debridService: DebridService.realDebrid,
    ),
    episode: const EpisodeReference(
      anilistMediaId: 100,
      title: 'Show',
      episode: 2,
    ),
    selectedRelease: release,
  ),
  fillerDecision: const FillerEpisodeNavigationDecision(episode: 2),
  fallbackDebridService: DebridService.realDebrid,
  preparedAt: DateTime.utc(2026, 8, 20),
);

Future<PreparedNextEpisode?> _noPreparedTarget({
  required int mediaId,
  required int episode,
}) async => null;

class _FollowerWatchPartyController extends WatchPartyController {
  _FollowerWatchPartyController(WatchPartyState initial)
    : super(WatchPartyClient(baseUrl: 'https://watch.example')) {
    state = initial;
  }
}
