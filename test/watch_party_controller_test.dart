import 'dart:async';

import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_source_descriptor.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_timeline.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('room codes normalize separators but accept only digits 2-9', () {
    expect(normalizeWatchPartyCode('2345-6789'), '23456789');
    expect(normalizeWatchPartyCode(' 2345 6789 '), '23456789');
    expect(normalizeWatchPartyCode('ABCD2345'), isNull);
    expect(normalizeWatchPartyCode('12345678'), isNull);
    expect(normalizeWatchPartyCode('short'), isNull);
    expect(
      watchPartyFriendlyError(
        const WatchPartyClientException('invalid_room_code'),
      ),
      'Enter the eight-digit room code using numbers 2-9 only.',
    );
  });

  test('an invalid join code does not end the active room', () async {
    final client = _FakeWatchPartyClient();
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.create(), isTrue);
    final activeSession = controller.state.session;

    expect(await controller.join('not-a-room'), isFalse);

    expect(controller.state.session, same(activeSession));
    expect(controller.state.isActive, isTrue);
    expect(client.leaveCalls, 0);
    expect(controller.state.message, contains('eight-digit'));
  });

  test('client requires one root HTTPS origin', () {
    for (final value in const [
      'http://tetotv.example',
      'https://user:pass@tetotv.example',
      'https://tetotv.example/prefix',
      'https://tetotv.example?token=secret',
    ]) {
      expect(
        () => WatchPartyClient(baseUrl: value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test('only an attached guest yields playback authority to the host', () {
    final guestLobby = WatchPartyState(
      connection: WatchPartyConnection.connected,
      session: _session(WatchPartyRole.guest),
    );
    final attachedGuest = guestLobby.copyWith(attachedMedia: _media);
    final reconnectingGuest = attachedGuest.copyWith(
      connection: WatchPartyConnection.reconnecting,
    );
    final attachedHost = WatchPartyState(
      session: _session(WatchPartyRole.host),
      attachedMedia: _media,
    );

    expect(guestLobby.guestPlaybackControlsLocked, isFalse);
    expect(attachedGuest.guestPlaybackControlsLocked, isTrue);
    expect(reconnectingGuest.guestPlaybackControlsLocked, isFalse);
    expect(attachedHost.guestPlaybackControlsLocked, isFalse);
    expect(const WatchPartyState().guestPlaybackControlsLocked, isFalse);
  });

  test(
    'client keeps the room capability in the Authorization header',
    () async {
      RequestOptions? recorded;
      final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              recorded = options;
              handler.resolve(
                Response<Object?>(
                  requestOptions: options,
                  statusCode: 200,
                  data: _snapshotJson(role: 'guest'),
                ),
              );
            },
          ),
        );
      final client = WatchPartyClient(
        baseUrl: 'https://tetotv.example',
        dio: dio,
      );
      final session = _session(WatchPartyRole.guest);

      final snapshot = await client.snapshot(session);

      expect(snapshot.roomCode, '23456789');
      expect(recorded?.path, '/v1/watch-parties/23456789');
      expect(recorded?.uri.query, isEmpty);
      expect(recorded?.headers['Authorization'], 'Bearer ${session.token}');
      expect(recorded?.data, isNull);
    },
  );

  test('client rejects a snapshot for a different room capability', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 200,
              data: <String, Object?>{
                ..._snapshotJson(role: 'guest'),
                'room_code': '87654322',
              },
            ),
          ),
        ),
      );
    final client = WatchPartyClient(
      baseUrl: 'https://tetotv.example',
      dio: dio,
    );

    await expectLater(
      client.snapshot(_session(WatchPartyRole.guest)),
      throwsA(
        isA<WatchPartyClientException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('client strips broker query data from the public room URL', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<Object?>(
              requestOptions: options,
              statusCode: 201,
              data: {
                'room_code': '23456789',
                'host_token': List.filled(48, 'a').join(),
                'expires_at': '2030-01-01T00:00:00Z',
                'watch_url':
                    '/watch?room=23456789&host_token=must-not-be-shared',
              },
            ),
          ),
        ),
      );
    final client = WatchPartyClient(
      baseUrl: 'https://tetotv.example',
      dio: dio,
    );

    final created = await client.create();

    expect(
      created.session.watchUrl.toString(),
      'https://tetotv.example/watch?room=23456789',
    );
    expect(created.session.watchUrl.queryParameters.keys, {'room'});
  });

  test(
    'host publishes public media identity but never a playback URL',
    () async {
      final client = _FakeWatchPartyClient();
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.create(), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      const media = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        timelineFingerprint: 'abcdef0123456789',
      );
      await controller.attachPlayback(port: port, media: media);

      port.emit(
        WatchPartyPlaybackSample(
          media: media,
          position: const Duration(seconds: 31),
          duration: const Duration(minutes: 24),
          playing: true,
          ready: true,
          sampledAt: DateTime.now().toUtc(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(client.lastPublishedMedia, media);
      expect(
        client.lastPublishedMedia?.toJson(),
        isNot(contains('stream_url')),
      );
      expect(client.lastPublishedMedia?.toJson(), isNot(contains('headers')));
      expect(controller.state.snapshot?.playing, isTrue);
    },
  );

  test('unready host startup samples cannot move guests backward', () async {
    final client = _FakeWatchPartyClient();
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.create(), isTrue);
    final port = _FakePlaybackPort();
    addTearDown(port.dispose);
    await controller.attachPlayback(port: port, media: _media);

    port.emit(
      WatchPartyPlaybackSample(
        media: _media,
        position: const Duration(seconds: 3),
        duration: const Duration(minutes: 24),
        playing: true,
        ready: false,
        sampledAt: DateTime.now().toUtc(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.updateCalls, 0);

    port.emit(
      WatchPartyPlaybackSample(
        media: _media,
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 24),
        playing: true,
        ready: true,
        sampledAt: DateTime.now().toUtc(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(client.updateCalls, 1);
    expect(
      client.lastPublishedPosition,
      greaterThanOrEqualTo(const Duration(minutes: 12)),
    );
  });

  test(
    'host transfer changes authority and emits one ordered notice',
    () async {
      const originalHost = WatchPartyParticipant(
        displayName: 'Original Host',
        participantId: 'hosthosthosthost',
        role: WatchPartyRole.host,
        ready: true,
      );
      const promotedGuest = WatchPartyParticipant(
        displayName: 'New Host',
        participantId: 'guestguestguestg',
        role: WatchPartyRole.guest,
        ready: true,
      );
      final client = _FakeWatchPartyClient()
        ..hostSnapshot = _snapshot(
          role: WatchPartyRole.host,
          rosterRevision: 1,
          participants: const [originalHost, promotedGuest],
          events: const [
            WatchPartyEvent(
              sequence: 1,
              type: WatchPartyEventType.joined,
              displayName: 'New Host',
            ),
          ],
        )
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          rosterRevision: 2,
          participants: const [
            WatchPartyParticipant(
              displayName: 'New Host',
              participantId: 'guestguestguestg',
              role: WatchPartyRole.host,
              ready: true,
            ),
            WatchPartyParticipant(
              displayName: 'Original Host',
              participantId: 'hosthosthosthost',
              role: WatchPartyRole.guest,
              ready: true,
            ),
          ],
          events: const [
            WatchPartyEvent(
              sequence: 1,
              type: WatchPartyEventType.joined,
              displayName: 'New Host',
            ),
            WatchPartyEvent(
              sequence: 2,
              type: WatchPartyEventType.hostTransferred,
              displayName: 'New Host',
            ),
          ],
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.create(), isTrue);
      expect(
        controller.state.notice,
        isNull,
        reason: 'initial history is seeded',
      );

      expect(await controller.transferHost(promotedGuest), isTrue);

      expect(client.transferredParticipantId, 'guestguestguestg');
      expect(controller.state.isHost, isFalse);
      expect(controller.state.session?.role, WatchPartyRole.guest);
      expect(controller.state.notice?.sequence, 2);
      expect(
        controller.state.notice?.message,
        'Host controls transferred to New Host.',
      );
    },
  );

  test('an out-of-order poll cannot restore stale host authority', () async {
    const originalHost = WatchPartyParticipant(
      displayName: 'Original Host',
      participantId: 'hosthosthosthost',
      role: WatchPartyRole.host,
      ready: true,
    );
    const promotedGuest = WatchPartyParticipant(
      displayName: 'New Host',
      participantId: 'guestguestguestg',
      role: WatchPartyRole.guest,
      ready: true,
    );
    final client = _FakeWatchPartyClient()
      ..hostSnapshot = _snapshot(
        role: WatchPartyRole.host,
        revision: 8,
        rosterRevision: 1,
        participants: const [originalHost, promotedGuest],
      )
      ..joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 8,
        rosterRevision: 2,
        participants: const [
          WatchPartyParticipant(
            displayName: 'New Host',
            participantId: 'guestguestguestg',
            role: WatchPartyRole.host,
            ready: true,
          ),
          WatchPartyParticipant(
            displayName: 'Original Host',
            participantId: 'hosthosthosthost',
            role: WatchPartyRole.guest,
            ready: true,
          ),
        ],
      );
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.create(), isTrue);
    client.snapshotStarted = Completer<void>();
    client.snapshotGate = Completer<void>();

    await client.snapshotStarted!.future.timeout(const Duration(seconds: 2));
    expect(await controller.transferHost(promotedGuest), isTrue);
    expect(controller.state.session?.role, WatchPartyRole.guest);

    client.snapshotGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(controller.state.session?.role, WatchPartyRole.guest);
    expect(controller.state.snapshot?.rosterRevision, 2);
  });

  test(
    'host kick is roster-revision guarded and surfaces the kicked notice',
    () async {
      const guest = WatchPartyParticipant(
        displayName: 'Guest Viewer',
        participantId: 'abcdefghijklmnop',
        role: WatchPartyRole.guest,
        ready: false,
      );
      final initial = _snapshot(
        role: WatchPartyRole.host,
        rosterRevision: 4,
        participants: const [guest],
        events: const [
          WatchPartyEvent(
            sequence: 1,
            type: WatchPartyEventType.joined,
            displayName: 'Guest Viewer',
          ),
        ],
      );
      final client = _FakeWatchPartyClient()..hostSnapshot = initial;
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.create(), isTrue);
      client.hostSnapshot = _snapshot(
        role: WatchPartyRole.host,
        rosterRevision: 5,
        events: const [
          WatchPartyEvent(
            sequence: 1,
            type: WatchPartyEventType.joined,
            displayName: 'Guest Viewer',
          ),
          WatchPartyEvent(
            sequence: 2,
            type: WatchPartyEventType.kicked,
            displayName: 'Guest Viewer',
          ),
        ],
      );

      expect(await controller.kick(guest), isTrue);

      expect(client.kickedParticipantId, 'abcdefghijklmnop');
      expect(controller.state.isHost, isTrue);
      expect(controller.state.notice?.sequence, 2);
      expect(
        controller.state.notice?.message,
        'Guest Viewer was removed from the Watch Party.',
      );
    },
  );

  test('an out-of-order poll cannot restore a kicked participant', () async {
    const guest = WatchPartyParticipant(
      displayName: 'Guest Viewer',
      participantId: 'abcdefghijklmnop',
      role: WatchPartyRole.guest,
      ready: false,
    );
    final client = _FakeWatchPartyClient()
      ..hostSnapshot = _snapshot(
        role: WatchPartyRole.host,
        revision: 3,
        rosterRevision: 4,
        participants: const [guest],
        events: const [
          WatchPartyEvent(
            sequence: 1,
            type: WatchPartyEventType.joined,
            displayName: 'Guest Viewer',
          ),
        ],
      );
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.create(), isTrue);
    client.snapshotStarted = Completer<void>();
    client.snapshotGate = Completer<void>();
    await client.snapshotStarted!.future.timeout(const Duration(seconds: 2));

    client.hostSnapshot = _snapshot(
      role: WatchPartyRole.host,
      revision: 3,
      rosterRevision: 5,
      events: const [
        WatchPartyEvent(
          sequence: 1,
          type: WatchPartyEventType.joined,
          displayName: 'Guest Viewer',
        ),
        WatchPartyEvent(
          sequence: 2,
          type: WatchPartyEventType.kicked,
          displayName: 'Guest Viewer',
        ),
      ],
    );
    expect(await controller.kick(guest), isTrue);
    expect(controller.state.snapshot?.rosterRevision, 5);

    client.snapshotGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(controller.state.snapshot?.rosterRevision, 5);
    expect(controller.state.snapshot?.participants, isEmpty);
    expect(controller.state.notice?.eventType, WatchPartyEventType.kicked);
  });

  testWidgets(
    'kicked guest is notified, disconnected, and safely regains controls',
    (tester) async {
      final client = _FakeWatchPartyClient();
      final controller = WatchPartyController(client);
      final port = _FakePlaybackPort();
      try {
        expect(await controller.join('23456789'), isTrue);
        await controller.attachPlayback(port: port, media: _media);
        expect(controller.state.guestPlaybackControlsLocked, isTrue);

        client.snapshotError = const WatchPartyClientException(
          'removed_from_party',
        );
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump();

        expect(controller.state.isActive, isFalse);
        expect(controller.state.guestPlaybackControlsLocked, isFalse);
        expect(
          controller.state.notice?.message,
          'The host removed you from this Watch Party.',
        );
        expect(controller.state.message, contains('host removed you'));
      } finally {
        controller.dispose();
        port.dispose();
      }
    },
  );

  testWidgets('a room outage unlocks guest controls until polling recovers', (
    tester,
  ) async {
    final client = _FakeWatchPartyClient();
    final controller = WatchPartyController(client);
    final port = _FakePlaybackPort();
    try {
      expect(await controller.join('23456789'), isTrue);
      await controller.attachPlayback(port: port, media: _media);
      expect(controller.state.guestPlaybackControlsLocked, isTrue);

      client.snapshotError = const WatchPartyClientException(
        'network_unavailable',
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();

      expect(controller.state.isActive, isTrue);
      expect(controller.state.connection, WatchPartyConnection.reconnecting);
      expect(controller.state.guestPlaybackControlsLocked, isFalse);

      client.snapshotError = null;
      await tester.pump(const Duration(milliseconds: 2400));
      await tester.pump();

      expect(controller.state.connection, WatchPartyConnection.connected);
      expect(controller.state.guestPlaybackControlsLocked, isTrue);
    } finally {
      controller.dispose();
      port.dispose();
    }
  });

  testWidgets('reconnecting invalidates an in-flight guest follow-up command', (
    tester,
  ) async {
    final client = _FakeWatchPartyClient()
      ..joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 7,
        playing: true,
        position: const Duration(seconds: 50),
        media: _media,
      );
    final controller = WatchPartyController(client);
    final seekGate = Completer<void>();
    final port = _FakePlaybackPort()..seekGate = seekGate;
    try {
      expect(await controller.join('23456789'), isTrue);
      await controller.attachPlayback(port: port, media: _media);
      port.emit(
        WatchPartyPlaybackSample(
          media: _media,
          position: const Duration(seconds: 5),
          duration: const Duration(minutes: 24),
          playing: false,
          ready: true,
          sampledAt: DateTime.now().toUtc(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(port.seekTargets, hasLength(1));

      client.snapshotError = const WatchPartyClientException(
        'network_unavailable',
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(controller.state.connection, WatchPartyConnection.reconnecting);
      expect(controller.state.guestPlaybackControlsLocked, isFalse);

      seekGate.complete();
      await tester.pump();
      expect(port.playCalls, 0, reason: 'the stale host play is invalid');
    } finally {
      if (!seekGate.isCompleted) seekGate.complete();
      await tester.pump();
      controller.dispose();
      port.dispose();
    }
  });

  test('viewer count includes the host for hosts and guests', () {
    expect(watchPartyViewerCount(const WatchPartyState()), 0);
    for (final role in WatchPartyRole.values) {
      expect(
        watchPartyViewerCount(
          WatchPartyState(
            session: _session(role),
            snapshot: _snapshot(role: role),
          ),
        ),
        2,
      );
    }
  });

  test(
    'guest gets a nonintrusive notice when exact host source is unavailable',
    () async {
      final controller = WatchPartyController(_FakeWatchPartyClient());
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);

      controller.notifyDifferentSourceFallback();

      expect(controller.state.isActive, isTrue);
      expect(
        controller.state.notice?.message,
        contains('another local source'),
      );
    },
  );

  test(
    'protocol-v3 source descriptor fails open against a v2 broker',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              final first = requests.length == 1;
              handler.resolve(
                Response<Object?>(
                  requestOptions: options,
                  statusCode: first ? 400 : 200,
                  data: first
                      ? const <String, Object>{'error': 'invalid_media'}
                      : _snapshotJson(role: 'host'),
                ),
              );
            },
          ),
        );
      final client = WatchPartyClient(
        baseUrl: 'https://tetotv.example',
        dio: dio,
      );
      const descriptor = WatchPartySourceDescriptor(
        sourceClass: WatchPartySourceClass.torrent,
        fingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        audio: WatchPartySourceAudio.sub,
        qualityHeight: 1080,
      );
      const media = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        sourceDescriptor: descriptor,
      );

      await client.updateState(
        session: _session(WatchPartyRole.host),
        baseRevision: 0,
        media: media,
        playing: false,
        position: Duration.zero,
      );

      expect(requests, hasLength(2));
      final firstMedia = (requests.first.data as Map)['media'] as Map;
      final secondMedia = (requests.last.data as Map)['media'] as Map;
      expect(firstMedia['source_descriptor'], isNotNull);
      expect(secondMedia['source_descriptor'], isNull);
    },
  );

  test(
    'protocol-v4 timeline profile falls back without dropping source identity',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              final first = requests.length == 1;
              handler.resolve(
                Response<Object?>(
                  requestOptions: options,
                  statusCode: first ? 400 : 200,
                  data: first
                      ? const <String, Object>{'error': 'invalid_media'}
                      : _snapshotJson(role: 'host'),
                ),
              );
            },
          ),
        );
      final client = WatchPartyClient(
        baseUrl: 'https://tetotv.example',
        dio: dio,
      );
      final timeline = WatchPartyTimelineProfile.tryCreate(
        duration: const Duration(minutes: 24),
        anchors: const [
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingStart,
            position: Duration(seconds: 30),
          ),
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingEnd,
            position: Duration(minutes: 2),
          ),
        ],
      );
      const descriptor = WatchPartySourceDescriptor(
        sourceClass: WatchPartySourceClass.web,
        fingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        audio: WatchPartySourceAudio.dub,
      );
      final media = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        timelineProfile: timeline,
        sourceDescriptor: descriptor,
      );

      await client.updateState(
        session: _session(WatchPartyRole.host),
        baseRevision: 0,
        media: media,
        playing: false,
        position: Duration.zero,
      );

      expect(requests, hasLength(2));
      final firstMedia = (requests.first.data as Map)['media'] as Map;
      final secondMedia = (requests.last.data as Map)['media'] as Map;
      expect(firstMedia['timeline_profile'], isNotNull);
      expect(secondMedia['timeline_profile'], isNull);
      expect(secondMedia['source_descriptor'], isNotNull);
    },
  );

  test(
    'protocol-v4 force resync falls back to an ordinary state update',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              final first = requests.length == 1;
              handler.resolve(
                Response<Object?>(
                  requestOptions: options,
                  statusCode: first ? 400 : 200,
                  data: first
                      ? const <String, Object>{'error': 'invalid_state'}
                      : _snapshotJson(role: 'host'),
                ),
              );
            },
          ),
        );
      final client = WatchPartyClient(
        baseUrl: 'https://tetotv.example',
        dio: dio,
      );

      await client.updateState(
        session: _session(WatchPartyRole.host),
        baseRevision: 0,
        media: _media,
        playing: false,
        position: Duration.zero,
        forceResync: true,
      );

      expect(requests, hasLength(2));
      expect((requests.first.data as Map)['force_resync'], isTrue);
      expect((requests.last.data as Map).containsKey('force_resync'), isFalse);
    },
  );

  test('failed participant action never reports success', () async {
    const guest = WatchPartyParticipant(
      displayName: 'Guest Viewer',
      participantId: 'abcdefghijklmnop',
      role: WatchPartyRole.guest,
      ready: false,
    );
    final client = _FakeWatchPartyClient()
      ..hostSnapshot = _snapshot(
        role: WatchPartyRole.host,
        rosterRevision: 4,
        participants: const [guest],
      )
      ..membershipError = const WatchPartyClientException('stale_roster');
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.create(), isTrue);

    expect(await controller.kick(guest), isFalse);
    expect(controller.state.membershipActionInFlight, isFalse);
    expect(controller.state.message, contains('participant list changed'));
  });

  testWidgets(
    'membership bursts keep every active notice until its own expiry',
    (tester) async {
      final client = _FakeWatchPartyClient();
      final controller = WatchPartyController(client);
      try {
        expect(await controller.join('23456789'), isTrue);

        client.joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          events: List<WatchPartyEvent>.generate(
            maximumWatchPartyEventCount,
            (index) => WatchPartyEvent(
              sequence: index + 1,
              type: WatchPartyEventType.joined,
              displayName: 'Viewer ${index + 1}',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump();
        expect(
          controller.state.notices.map((notice) => notice.sequence),
          orderedEquals(
            List<int>.generate(
              maximumWatchPartyEventCount,
              (index) => index + 1,
            ),
          ),
        );

        client.joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          events: List<WatchPartyEvent>.generate(
            maximumWatchPartyEventCount,
            (index) => WatchPartyEvent(
              sequence: maximumWatchPartyEventCount + index + 1,
              type: WatchPartyEventType.joined,
              displayName: 'Viewer ${maximumWatchPartyEventCount + index + 1}',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump();
        expect(
          controller.state.notices.map((notice) => notice.sequence),
          orderedEquals(
            List<int>.generate(
              maximumWatchPartyEventCount * 2,
              (index) => index + 1,
            ),
          ),
          reason: 'new activity cannot shorten an older card’s five seconds',
        );
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('each membership notice owns an exact five-second lifetime', (
    tester,
  ) async {
    final client = _FakeWatchPartyClient();
    final controller = WatchPartyController(client);
    try {
      expect(await controller.join('23456789'), isTrue);
      client.joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        events: const [
          WatchPartyEvent(
            sequence: 1,
            type: WatchPartyEventType.joined,
            displayName: 'First Viewer',
          ),
        ],
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(controller.state.notices.map((notice) => notice.sequence), [1]);

      client.joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        events: const [
          WatchPartyEvent(
            sequence: 1,
            type: WatchPartyEventType.joined,
            displayName: 'First Viewer',
          ),
          WatchPartyEvent(
            sequence: 2,
            type: WatchPartyEventType.left,
            displayName: 'Second Viewer',
          ),
        ],
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(controller.state.notices.map((notice) => notice.sequence), [1, 2]);

      await tester.pump(
        watchPartyNoticeLifetime - const Duration(milliseconds: 1201),
      );
      expect(controller.state.notices.map((notice) => notice.sequence), [1, 2]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.state.notices.map((notice) => notice.sequence), [2]);

      await tester.pump(const Duration(milliseconds: 1199));
      expect(controller.state.notices.map((notice) => notice.sequence), [2]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.state.notices, isEmpty);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('participant notices use concise actions and safe avatars only', (
    tester,
  ) async {
    final client = _FakeWatchPartyClient();
    final controller = WatchPartyController(client);
    try {
      expect(await controller.join('23456789'), isTrue);
      client.joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        participants: const [
          WatchPartyParticipant(
            displayName: 'Alice',
            avatarUrl:
                'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b1.jpg',
            role: WatchPartyRole.guest,
            ready: true,
          ),
          WatchPartyParticipant(
            displayName: 'Mallory',
            avatarUrl: 'https://tracker.example/private/avatar?token=secret',
            role: WatchPartyRole.guest,
            ready: false,
          ),
          WatchPartyParticipant(
            displayName: 'Duplicate',
            avatarUrl: 'https://cdn.myanimelist.net/images/userimages/1.jpg',
            role: WatchPartyRole.guest,
            ready: false,
          ),
          WatchPartyParticipant(
            displayName: 'Duplicate',
            avatarUrl: 'https://cdn.myanimelist.net/images/userimages/2.jpg',
            role: WatchPartyRole.guest,
            ready: false,
          ),
          WatchPartyParticipant(
            displayName: 'Dana',
            avatarUrl: 'https://cdn.myanimelist.net/images/userimages/3.jpg',
            role: WatchPartyRole.host,
            ready: true,
          ),
        ],
        events: const [
          WatchPartyEvent(
            sequence: 1,
            type: WatchPartyEventType.joined,
            displayName: 'Alice',
          ),
          WatchPartyEvent(
            sequence: 2,
            type: WatchPartyEventType.left,
            displayName: 'Mallory',
          ),
          WatchPartyEvent(
            sequence: 3,
            type: WatchPartyEventType.kicked,
            displayName: 'Duplicate',
          ),
          WatchPartyEvent(
            sequence: 4,
            type: WatchPartyEventType.hostTransferred,
            displayName: 'Dana',
          ),
        ],
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();

      expect(controller.state.notices.map((notice) => notice.actionText), [
        'joined the party',
        'left the party',
        'was kicked from the party',
        'is now the host',
      ]);
      expect(
        controller.state.notices.map((notice) => notice.avatarUrl),
        [
          'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b1.jpg',
          null,
          null,
          'https://cdn.myanimelist.net/images/userimages/3.jpg',
        ],
        reason:
            'untrusted URLs and ambiguous duplicate-name avatars stay private',
      );

      client.joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        participants: const [
          WatchPartyParticipant(
            displayName: 'Alice',
            role: WatchPartyRole.guest,
            ready: true,
          ),
        ],
        events: const [
          WatchPartyEvent(
            sequence: 5,
            type: WatchPartyEventType.hostTransferred,
            displayName: 'Alice',
          ),
        ],
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(
        controller.state.notices
            .singleWhere((notice) => notice.sequence == 5)
            .avatarUrl,
        isNull,
        reason: 'a reused display name cannot inherit an earlier user’s PFP',
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets(
    'departed participants retain only their previously verified PFP',
    (tester) async {
      const leftAvatar =
          'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b11.jpg';
      const kickedAvatar =
          'https://cdn.myanimelist.net/images/userimages/22.jpg';
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          participants: const [
            WatchPartyParticipant(
              displayName: 'Leaving Viewer',
              avatarUrl: leftAvatar,
              role: WatchPartyRole.guest,
              ready: true,
            ),
            WatchPartyParticipant(
              displayName: 'Kicked Viewer',
              avatarUrl: kickedAvatar,
              role: WatchPartyRole.guest,
              ready: true,
            ),
          ],
        );
      final controller = WatchPartyController(client);
      try {
        expect(await controller.join('23456789'), isTrue);
        client.joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          events: const [
            WatchPartyEvent(
              sequence: 1,
              type: WatchPartyEventType.left,
              displayName: 'Leaving Viewer',
            ),
            WatchPartyEvent(
              sequence: 2,
              type: WatchPartyEventType.kicked,
              displayName: 'Kicked Viewer',
            ),
          ],
        );
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump();

        expect(controller.state.notices.map((notice) => notice.avatarUrl), [
          leftAvatar,
          kickedAvatar,
        ]);
      } finally {
        controller.dispose();
      }
    },
  );

  test(
    'attached guest rejects local play but applies queued host play and seek',
    () async {
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 4,
          playing: true,
          position: const Duration(seconds: 45),
          media: _media,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      await controller.attachPlayback(port: port, media: _media);
      expect(controller.state.guestPlaybackControlsLocked, isTrue);
      if (!controller.state.guestPlaybackControlsLocked) {
        await port.play();
      }
      expect(port.playCalls, 0, reason: 'guest-local Play is rejected');
      expect(client.readyValues, [false]);
      port.emit(
        WatchPartyPlaybackSample(
          media: _media,
          position: const Duration(seconds: 4),
          duration: const Duration(minutes: 24),
          playing: false,
          ready: true,
          sampledAt: DateTime.now().toUtc(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(port.seekTargets.single, greaterThan(const Duration(seconds: 40)));
      expect(
        port.playCalls,
        1,
        reason: 'the coordinator-originated host Play bypasses the local lock',
      );
      expect(client.updateCalls, 0);
      expect(client.readyValues, [false, true]);
    },
  );

  test(
    'old episode readiness cannot control or ready a new host episode',
    () async {
      const oldMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 1,
      );
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 7,
          playing: true,
          position: const Duration(seconds: 50),
          media: _media,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      await controller.attachPlayback(port: port, media: oldMedia);

      port.emit(_readySample(media: oldMedia));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(client.readyValues, [false]);
      expect(client.remoteReady, isFalse);
      expect(port.seekTargets, isEmpty);
      expect(port.playCalls, 0);
      expect(controller.state.attachedMedia, oldMedia);
    },
  );

  test(
    'source mismatch stays unready until a notified fallback attaches',
    () async {
      const hostDescriptor = WatchPartySourceDescriptor(
        sourceClass: WatchPartySourceClass.torrent,
        fingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        audio: WatchPartySourceAudio.dub,
        qualityHeight: 1080,
      );
      const fallbackDescriptor = WatchPartySourceDescriptor(
        sourceClass: WatchPartySourceClass.torrent,
        fingerprint:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        audio: WatchPartySourceAudio.dub,
        qualityHeight: 1080,
      );
      const hostMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        sourceDescriptor: hostDescriptor,
      );
      const fallbackMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        sourceDescriptor: fallbackDescriptor,
      );
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 20,
          media: hostMedia,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final oldPort = _FakePlaybackPort();
      final fallbackPort = _FakePlaybackPort();
      addTearDown(oldPort.dispose);
      addTearDown(fallbackPort.dispose);
      await controller.attachPlayback(port: oldPort, media: fallbackMedia);

      controller.notifyDifferentSourceFallback(
        targetSourceKey: hostDescriptor.sourceKey,
      );
      oldPort.emit(_readySample(media: fallbackMedia));
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(client.remoteReady, isFalse);
      expect(client.readyValues.where((value) => value), isEmpty);

      await controller.attachPlayback(port: fallbackPort, media: fallbackMedia);
      fallbackPort.emit(_readySample(media: fallbackMedia));
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(client.remoteReady, isTrue);
      expect(client.readyValues.last, isTrue);
    },
  );

  test(
    'an exact fingerprint handoff tolerates local metadata differences',
    () async {
      const descriptor = WatchPartySourceDescriptor(
        sourceClass: WatchPartySourceClass.torrent,
        fingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        audio: WatchPartySourceAudio.dub,
        qualityHeight: 1080,
      );
      const exactMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        sourceDescriptor: descriptor,
      );
      const localDescriptor = WatchPartySourceDescriptor(
        sourceClass: WatchPartySourceClass.torrent,
        fingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        audio: WatchPartySourceAudio.sub,
        qualityHeight: 720,
      );
      const localMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        sourceDescriptor: localDescriptor,
      );
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 21,
          media: exactMedia,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      controller.prepareExactSourceHandoff(
        targetSourceKey: descriptor.sourceKey,
      );
      await controller.attachPlayback(port: port, media: localMedia);

      port.emit(_readySample(media: localMedia));
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(client.remoteReady, isTrue);
    },
  );

  test(
    'different releases use shared intro boundaries to seek the same scene',
    () async {
      final hostTimeline = WatchPartyTimelineProfile.tryCreate(
        duration: const Duration(minutes: 24),
        anchors: const [
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingStart,
            position: Duration(seconds: 30),
          ),
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingEnd,
            position: Duration(minutes: 2),
          ),
        ],
      );
      final guestTimeline = WatchPartyTimelineProfile.tryCreate(
        duration: const Duration(minutes: 24, seconds: 12),
        anchors: const [
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingStart,
            position: Duration(seconds: 42),
          ),
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingEnd,
            position: Duration(minutes: 2, seconds: 12),
          ),
        ],
      );
      final hostMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        timelineFingerprint: List.filled(64, 'a').join(),
        timelineProfile: hostTimeline,
      );
      final guestMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        timelineFingerprint: List.filled(64, 'b').join(),
        timelineProfile: guestTimeline,
      );
      final now = DateTime.now().toUtc();
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 22,
          position: const Duration(seconds: 60),
          media: hostMedia,
          effectiveAt: now,
          serverTime: now,
          receivedAt: now,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      await controller.attachPlayback(port: port, media: guestMedia);

      port.emit(
        WatchPartyPlaybackSample(
          media: guestMedia,
          position: const Duration(seconds: 5),
          duration: const Duration(minutes: 24, seconds: 12),
          playing: false,
          ready: true,
          sampledAt: now,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(port.seekTargets.single, const Duration(seconds: 72));
      expect(
        controller.state.timelineCompatibility,
        WatchPartyTimelineCompatibility.adjusted,
      );
    },
  );

  test(
    'different Web variants cannot bypass timeline mapping with a coarse fingerprint',
    () async {
      final hostTimeline = WatchPartyTimelineProfile.tryCreate(
        duration: const Duration(minutes: 24),
        anchors: const [
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingStart,
            position: Duration(seconds: 30),
          ),
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingEnd,
            position: Duration(minutes: 2),
          ),
        ],
      );
      final guestTimeline = WatchPartyTimelineProfile.tryCreate(
        duration: const Duration(minutes: 24, seconds: 12),
        anchors: const [
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingStart,
            position: Duration(seconds: 42),
          ),
          WatchPartyTimelineAnchor(
            kind: WatchPartyTimelineAnchorKind.openingEnd,
            position: Duration(minutes: 2, seconds: 12),
          ),
        ],
      );
      final sharedCoarseFingerprint = List.filled(64, 'a').join();
      final hostMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        timelineFingerprint: sharedCoarseFingerprint,
        timelineProfile: hostTimeline,
        sourceDescriptor: WatchPartySourceDescriptor(
          sourceClass: WatchPartySourceClass.web,
          fingerprint: List.filled(64, 'b').join(),
          audio: WatchPartySourceAudio.dub,
        ),
      );
      final guestMedia = WatchPartyMedia(
        kind: 'anilist',
        title: 'Frieren',
        anilistId: 154587,
        episode: 2,
        timelineFingerprint: sharedCoarseFingerprint,
        timelineProfile: guestTimeline,
        sourceDescriptor: WatchPartySourceDescriptor(
          sourceClass: WatchPartySourceClass.web,
          fingerprint: List.filled(64, 'c').join(),
          audio: WatchPartySourceAudio.dub,
        ),
      );
      final now = DateTime.now().toUtc();
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 23,
          position: const Duration(seconds: 60),
          media: hostMedia,
          effectiveAt: now,
          serverTime: now,
          receivedAt: now,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      controller.notifyDifferentSourceFallback(
        targetSourceKey: hostMedia.sourceDescriptor!.sourceKey,
      );
      await controller.attachPlayback(port: port, media: guestMedia);

      port.emit(
        WatchPartyPlaybackSample(
          media: guestMedia,
          position: const Duration(seconds: 5),
          duration: const Duration(minutes: 24, seconds: 12),
          playing: false,
          ready: true,
          sampledAt: now,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(port.seekTargets.single, const Duration(seconds: 72));
      expect(
        controller.state.timelineCompatibility,
        WatchPartyTimelineCompatibility.adjusted,
      );
    },
  );

  test('host resync increments the marker sent to every guest', () async {
    final client = _FakeWatchPartyClient();
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.create(), isTrue);
    final port = _FakePlaybackPort();
    addTearDown(port.dispose);
    await controller.attachPlayback(port: port, media: _media);
    port.emit(_readySample(media: _media));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final before = controller.state.snapshot?.resyncRevision ?? 0;

    expect(await controller.resyncParty(), isTrue);

    expect(client.forceResyncValues, contains(true));
    expect(controller.state.snapshot?.resyncRevision, before + 1);
  });

  test(
    'stale host resync waits for a refreshed revision before retrying',
    () async {
      final client = _FakeWatchPartyClient();
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.create(), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      await controller.attachPlayback(port: port, media: _media);
      port.emit(_readySample(media: _media));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(client.updateCalls, 1);

      // Another accepted host update advanced the broker before this client
      // pressed Resync. The controller must poll once instead of replaying base
      // revision 1 in a tight loop.
      client
        ..minimumUpdateRevision = 2
        ..hostSnapshot = _snapshot(
          role: WatchPartyRole.host,
          revision: 2,
          media: _media,
        );

      expect(
        await controller.resyncParty().timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(client.updateCalls, 3);
      expect(client.forceResyncValues, [false, true, true]);
      expect(controller.state.snapshot?.revision, 3);
      expect(controller.state.snapshot?.resyncRevision, 1);
    },
  );

  test('a resync revision forces one precise guest correction', () async {
    final now = DateTime.now().toUtc();
    final client = _FakeWatchPartyClient()
      ..joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 23,
        resyncRevision: 1,
        position: const Duration(seconds: 30),
        media: _media,
        effectiveAt: now,
        serverTime: now,
        receivedAt: now,
      );
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.join('23456789'), isTrue);
    final port = _FakePlaybackPort();
    addTearDown(port.dispose);
    await controller.attachPlayback(port: port, media: _media);
    final nearlyAligned = WatchPartyPlaybackSample(
      media: _media,
      position: const Duration(seconds: 29, milliseconds: 600),
      duration: const Duration(minutes: 24),
      playing: false,
      ready: true,
      sampledAt: now,
    );

    port.emit(nearlyAligned);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    port.emit(nearlyAligned);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(port.seekTargets, hasLength(1));
    expect(port.seekTargets.single, const Duration(seconds: 30));
  });

  test('guest reconciliation serializes duplicate playback samples', () async {
    final client = _FakeWatchPartyClient()
      ..joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 9,
        playing: true,
        position: const Duration(seconds: 50),
        media: _media,
      );
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.join('23456789'), isTrue);
    final seekGate = Completer<void>();
    final port = _FakePlaybackPort()..seekGate = seekGate;
    addTearDown(port.dispose);
    await controller.attachPlayback(port: port, media: _media);
    final behind = WatchPartyPlaybackSample(
      media: _media,
      position: const Duration(seconds: 5),
      duration: const Duration(minutes: 24),
      playing: false,
      ready: true,
      sampledAt: DateTime.now().toUtc(),
    );

    port.emit(behind);
    port.emit(behind);
    port.emit(behind);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(port.seekTargets, hasLength(1));
    expect(port.playCalls, 0);

    seekGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(port.seekTargets, hasLength(1));
    expect(port.playCalls, 1);
    expect(client.updateCalls, 0, reason: 'guests never echo host state');
  });

  testWidgets(
    'polling survives a stuck guest command and accepts host recovery',
    (tester) async {
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 9,
          playing: true,
          position: const Duration(seconds: 50),
          media: _media,
        );
      final controller = WatchPartyController(client);
      final seekGate = Completer<void>();
      final port = _FakePlaybackPort()..seekGate = seekGate;
      try {
        await controller.attachPlayback(port: port, media: _media);
        port.emit(
          WatchPartyPlaybackSample(
            media: _media,
            position: const Duration(seconds: 5),
            duration: const Duration(minutes: 24),
            playing: false,
            ready: true,
            sampledAt: DateTime.now().toUtc(),
          ),
        );
        expect(await controller.join('23456789'), isTrue);

        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump();
        expect(port.seekTargets, hasLength(1));
        expect(controller.state.guestPlaybackControlsLocked, isTrue);

        client.joinSnapshot = _snapshot(
          role: WatchPartyRole.host,
          revision: 9,
          playing: true,
          position: const Duration(seconds: 50),
          media: _media,
        );
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump();

        expect(client.snapshotCalls, greaterThanOrEqualTo(2));
        expect(controller.state.isHost, isTrue);
        expect(controller.state.guestPlaybackControlsLocked, isFalse);
      } finally {
        if (!seekGate.isCompleted) seekGate.complete();
        await tester.pump();
        controller.dispose();
        port.dispose();
      }
    },
  );

  testWidgets('a stuck guest command stays single-flight until it settles', (
    tester,
  ) async {
    final client = _FakeWatchPartyClient()
      ..joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 11,
        playing: true,
        position: const Duration(seconds: 50),
        media: _media,
      );
    final controller = WatchPartyController(client);
    final seekGate = Completer<void>();
    final port = _FakePlaybackPort()..seekGate = seekGate;
    try {
      expect(await controller.join('23456789'), isTrue);
      await controller.attachPlayback(port: port, media: _media);
      final behind = WatchPartyPlaybackSample(
        media: _media,
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 24),
        playing: false,
        ready: true,
        sampledAt: DateTime.now().toUtc(),
      );
      port.emit(behind);
      await tester.pump(const Duration(milliseconds: 20));
      expect(port.seekTargets, hasLength(1));
      expect(port.maximumConcurrentSeeks, 1);

      client.joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 12,
        playing: true,
        position: const Duration(seconds: 55),
        media: _media,
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      port.emit(behind);
      await tester.pump();
      expect(port.seekTargets, hasLength(1));
      expect(port.maximumConcurrentSeeks, 1);
      expect(port.playCalls, 0);
      expect(controller.state.snapshot?.revision, 12);

      port.seekGate = null;
      seekGate.complete();
      await tester.pump(const Duration(milliseconds: 50));

      expect(port.seekTargets.length, greaterThanOrEqualTo(2));
      expect(port.maximumConcurrentSeeks, 1);
      expect(port.playCalls, greaterThanOrEqualTo(1));
    } finally {
      if (!seekGate.isCompleted) seekGate.complete();
      await tester.pump();
      controller.dispose();
      port.dispose();
    }
  });

  test(
    'promotion during an in-flight guest seek cannot issue stale play',
    () async {
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 10,
          playing: true,
          position: const Duration(seconds: 50),
          media: _media,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final seekGate = Completer<void>();
      final port = _FakePlaybackPort()..seekGate = seekGate;
      addTearDown(port.dispose);
      await controller.attachPlayback(port: port, media: _media);

      port.emit(
        WatchPartyPlaybackSample(
          media: _media,
          position: const Duration(seconds: 4),
          duration: const Duration(minutes: 24),
          playing: false,
          ready: true,
          sampledAt: DateTime.now().toUtc(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(port.seekTargets, hasLength(1));

      client.joinSnapshot = _snapshot(
        role: WatchPartyRole.host,
        revision: 10,
        playing: true,
        position: const Duration(seconds: 50),
        media: _media,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      expect(controller.state.isHost, isTrue);

      seekGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(port.playCalls, 0);
      expect(port.pauseCalls, 0);
    },
  );

  test(
    'guest playback command failures are nonfatal and retry later',
    () async {
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 12,
          playing: true,
          position: const Duration(seconds: 40),
          media: _media,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final port = _FakePlaybackPort()..seekError = StateError('decoder busy');
      addTearDown(port.dispose);
      await controller.attachPlayback(port: port, media: _media);
      final behind = WatchPartyPlaybackSample(
        media: _media,
        position: const Duration(seconds: 2),
        duration: const Duration(minutes: 24),
        playing: false,
        ready: true,
        sampledAt: DateTime.now().toUtc(),
      );

      port.emit(behind);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(port.seekTargets, hasLength(1));
      expect(port.playCalls, 0);
      expect(controller.state.message, contains('Retrying shortly'));

      await Future<void>.delayed(const Duration(milliseconds: 680));
      port.seekError = null;
      port.emit(behind);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(port.seekTargets, hasLength(2));
      expect(port.playCalls, 1);
      expect(client.updateCalls, 0, reason: 'a guest retry never echoes state');
    },
  );

  test(
    'website private room controls explicitly attached guest media',
    () async {
      const websiteMedia = WatchPartyMedia(
        kind: 'private',
        title: 'Private media',
      );
      final client = _FakeWatchPartyClient()
        ..joinSnapshot = _snapshot(
          role: WatchPartyRole.guest,
          revision: 14,
          playing: true,
          position: const Duration(seconds: 30),
          media: websiteMedia,
        );
      final controller = WatchPartyController(client);
      addTearDown(controller.dispose);
      expect(await controller.join('23456789'), isTrue);
      final port = _FakePlaybackPort();
      addTearDown(port.dispose);
      await controller.attachPlayback(port: port, media: _media);

      port.emit(
        WatchPartyPlaybackSample(
          media: _media,
          position: const Duration(seconds: 2),
          duration: const Duration(minutes: 24),
          playing: false,
          ready: true,
          sampledAt: DateTime.now().toUtc(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(port.seekTargets, hasLength(1));
      expect(port.playCalls, 1);
      expect(controller.state.timelineMismatch, isTrue);
      expect(controller.state.message, contains('same episode as the host'));
      expect(client.updateCalls, 0);
    },
  );

  test('late playback detach is inert after controller disposal', () async {
    final controller = WatchPartyController(_FakeWatchPartyClient());
    final port = _FakePlaybackPort();
    addTearDown(port.dispose);
    await controller.attachPlayback(port: port, media: _media);

    controller.dispose();

    await expectLater(controller.detachPlayback(port), completes);
  });

  test('leaving unlocks a guest before the broker request completes', () async {
    final client = _FakeWatchPartyClient()
      ..leaveStarted = Completer<void>()
      ..leaveGate = Completer<void>();
    final controller = WatchPartyController(client);
    final port = _FakePlaybackPort();
    addTearDown(controller.dispose);
    addTearDown(port.dispose);
    expect(await controller.join('23456789'), isTrue);
    await controller.attachPlayback(port: port, media: _media);
    expect(controller.state.guestPlaybackControlsLocked, isTrue);

    final departure = controller.leave();
    await client.leaveStarted!.future;

    expect(controller.state.isActive, isFalse);
    expect(controller.state.guestPlaybackControlsLocked, isFalse);
    expect(controller.state.message, contains('left'));

    client.leaveGate!.complete();
    await departure;
  });

  test('detach compensates for delayed guest ready attach', () async {
    final readyTrueGate = Completer<void>();
    final readyTrueStarted = Completer<void>();
    final client = _FakeWatchPartyClient()
      ..joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 1,
        media: _media,
      )
      ..readyTrueGate = readyTrueGate
      ..readyTrueStarted = readyTrueStarted;
    final controller = WatchPartyController(client);
    addTearDown(controller.dispose);
    expect(await controller.join('23456789'), isTrue);
    final port = _FakePlaybackPort();
    addTearDown(port.dispose);

    await controller.attachPlayback(port: port, media: _media);
    port.emit(_readySample(media: _media));
    await readyTrueStarted.future;
    final detach = controller.detachPlayback(port);
    await Future<void>.delayed(Duration.zero);

    expect(client.readyCompletionOrder, [false]);
    readyTrueGate.complete();
    await detach;

    expect(client.readyValues, [false, true, false]);
    expect(client.readyCompletionOrder, [false, true, false]);
    expect(client.remoteReady, isFalse);
    expect(controller.state.attachedMedia, isNull);
  });

  test('dispose compensates for delayed guest ready attach', () async {
    final readyTrueGate = Completer<void>();
    final readyTrueStarted = Completer<void>();
    final readyFalseCompleted = Completer<void>();
    final client = _FakeWatchPartyClient()
      ..joinSnapshot = _snapshot(
        role: WatchPartyRole.guest,
        revision: 1,
        media: _media,
      )
      ..readyTrueGate = readyTrueGate
      ..readyTrueStarted = readyTrueStarted;
    final controller = WatchPartyController(client);
    expect(await controller.join('23456789'), isTrue);
    final port = _FakePlaybackPort();
    addTearDown(port.dispose);

    await controller.attachPlayback(port: port, media: _media);
    port.emit(_readySample(media: _media));
    await readyTrueStarted.future;
    client.readyFalseCompleted = readyFalseCompleted;
    controller.dispose();
    readyTrueGate.complete();

    await readyFalseCompleted.future.timeout(const Duration(seconds: 1));
    expect(client.readyValues, [false, true, false]);
    expect(client.readyCompletionOrder, [false, true, false]);
    expect(client.remoteReady, isFalse);
  });

  test('detach cancels an attachment before its port is installed', () async {
    final controller = WatchPartyController(_FakeWatchPartyClient());
    addTearDown(controller.dispose);
    final cancelGate = Completer<void>();
    final previousPort = _FakePlaybackPort(cancelGate: cancelGate);
    final pendingPort = _FakePlaybackPort();
    addTearDown(previousPort.dispose);
    addTearDown(pendingPort.dispose);
    await controller.attachPlayback(port: previousPort, media: _media);

    final attach = controller.attachPlayback(port: pendingPort, media: _media);
    await Future<void>.delayed(Duration.zero);
    final detach = controller.detachPlayback(pendingPort);
    cancelGate.complete();
    await Future.wait([attach, detach]);

    expect(controller.state.attachedMedia, isNull);
  });

  test('snapshot calculates host position with server clock offset', () {
    final snapshot = _snapshot(
      role: WatchPartyRole.guest,
      playing: true,
      position: const Duration(seconds: 10),
      effectiveAt: DateTime.utc(2026, 8, 20, 12),
      serverTime: DateTime.utc(2026, 8, 20, 12, 0, 2),
      receivedAt: DateTime.utc(2026, 8, 20, 11, 59, 57),
    );
    expect(
      snapshot.expectedPositionAt(DateTime.utc(2026, 8, 20, 11, 59, 57)),
      const Duration(seconds: 12),
    );
    expect(
      snapshot.expectedPositionAt(DateTime.utc(2026, 8, 20, 11, 59, 59)),
      const Duration(seconds: 14),
      reason: 'the host timeline advances after the snapshot is received',
    );
  });
}

const _media = WatchPartyMedia(
  kind: 'anilist',
  title: 'Frieren',
  anilistId: 154587,
  episode: 2,
);

WatchPartySession _session(WatchPartyRole role) => WatchPartySession(
  roomCode: '23456789',
  token: List.filled(43, 'a').join(),
  role: role,
  expiresAt: DateTime.utc(2026, 8, 21),
  watchUrl: Uri.parse('https://tetotv.example/watch?room=23456789'),
);

WatchPartySnapshot _snapshot({
  required WatchPartyRole role,
  int revision = 0,
  int resyncRevision = 0,
  bool playing = false,
  Duration position = Duration.zero,
  WatchPartyMedia? media,
  DateTime? effectiveAt,
  DateTime? serverTime,
  DateTime? receivedAt,
  int rosterRevision = 0,
  List<WatchPartyParticipant> participants = const [],
  List<WatchPartyEvent> events = const [],
}) => WatchPartySnapshot(
  roomCode: '23456789',
  role: role,
  revision: revision,
  resyncRevision: resyncRevision,
  media: media,
  playing: playing,
  position: position,
  effectiveAt: effectiveAt ?? DateTime.now().toUtc(),
  serverTime: serverTime ?? DateTime.now().toUtc(),
  receivedAt: receivedAt,
  participantCount: 1,
  readyCount: 1,
  rosterRevision: rosterRevision,
  participants: participants,
  events: events,
  expiresAt: DateTime.now().toUtc().add(const Duration(hours: 6)),
);

WatchPartyPlaybackSample _readySample({required WatchPartyMedia media}) =>
    WatchPartyPlaybackSample(
      media: media,
      position: const Duration(seconds: 3),
      duration: const Duration(minutes: 24),
      playing: false,
      ready: true,
      sampledAt: DateTime.now().toUtc(),
    );

Map<String, Object?> _snapshotJson({required String role}) => {
  'room_code': '23456789',
  'role': role,
  'revision': 1,
  'media': null,
  'playing': false,
  'position_ms': 0,
  'effective_at_ms': 0,
  'server_time_ms': 0,
  'participant_count': 1,
  'ready_count': 0,
  'expires_at': '2026-08-21T00:00:00Z',
};

class _FakeWatchPartyClient extends WatchPartyClient {
  _FakeWatchPartyClient()
    : super(baseUrl: 'https://tetotv.example', dio: Dio());

  WatchPartySnapshot joinSnapshot = _snapshot(role: WatchPartyRole.guest);
  WatchPartySnapshot hostSnapshot = _snapshot(role: WatchPartyRole.host);
  WatchPartyMedia? lastPublishedMedia;
  Duration? lastPublishedPosition;
  int updateCalls = 0;
  int snapshotCalls = 0;
  int? minimumUpdateRevision;
  final forceResyncValues = <bool>[];
  final readyValues = <bool>[];
  final readyCompletionOrder = <bool>[];
  bool remoteReady = false;
  Completer<void>? readyTrueGate;
  Completer<void>? readyTrueStarted;
  Completer<void>? readyFalseCompleted;
  String? transferredParticipantId;
  String? kickedParticipantId;
  WatchPartyClientException? membershipError;
  WatchPartyClientException? snapshotError;
  Completer<void>? snapshotStarted;
  Completer<void>? snapshotGate;
  Completer<void>? leaveStarted;
  Completer<void>? leaveGate;
  int leaveCalls = 0;

  @override
  Future<WatchPartyCreated> create() async =>
      WatchPartyCreated(session: _session(WatchPartyRole.host));

  @override
  Future<WatchPartyJoined> join(String rawCode) async => WatchPartyJoined(
    session: _session(WatchPartyRole.guest),
    snapshot: joinSnapshot,
  );

  @override
  Future<WatchPartySnapshot> snapshot(WatchPartySession session) async {
    snapshotCalls += 1;
    if (snapshotError case final error?) throw error;
    final value = session.role == WatchPartyRole.host
        ? hostSnapshot
        : joinSnapshot;
    final started = snapshotStarted;
    if (started != null && !started.isCompleted) started.complete();
    await snapshotGate?.future;
    return value;
  }

  @override
  Future<WatchPartySnapshot> transferHost({
    required WatchPartySession session,
    required String participantId,
    required int baseRosterRevision,
  }) async {
    if (membershipError case final error?) throw error;
    transferredParticipantId = participantId;
    return joinSnapshot;
  }

  @override
  Future<WatchPartySnapshot> kick({
    required WatchPartySession session,
    required String participantId,
    required int baseRosterRevision,
  }) async {
    if (membershipError case final error?) throw error;
    kickedParticipantId = participantId;
    return hostSnapshot;
  }

  @override
  Future<WatchPartySnapshot> updateState({
    required WatchPartySession session,
    required int baseRevision,
    required WatchPartyMedia? media,
    required bool playing,
    required Duration position,
    bool forceResync = false,
  }) async {
    updateCalls += 1;
    forceResyncValues.add(forceResync);
    lastPublishedMedia = media;
    lastPublishedPosition = position;
    final minimumRevision = minimumUpdateRevision;
    if (minimumRevision != null && baseRevision < minimumRevision) {
      throw const WatchPartyClientException('stale_revision');
    }
    return _snapshot(
      role: WatchPartyRole.host,
      revision: baseRevision + 1,
      resyncRevision:
          (session.role == WatchPartyRole.host
              ? hostSnapshot.resyncRevision
              : joinSnapshot.resyncRevision) +
          (forceResync ? 1 : 0),
      playing: playing,
      position: position,
      media: media,
    );
  }

  @override
  Future<WatchPartySnapshot> setReady({
    required WatchPartySession session,
    required bool ready,
  }) async {
    readyValues.add(ready);
    if (ready) {
      final started = readyTrueStarted;
      if (started != null && !started.isCompleted) started.complete();
      await readyTrueGate?.future;
    }
    remoteReady = ready;
    readyCompletionOrder.add(ready);
    if (!ready) {
      final completed = readyFalseCompleted;
      if (completed != null && !completed.isCompleted) completed.complete();
    }
    return joinSnapshot;
  }

  @override
  Future<void> leave(WatchPartySession session) async {
    leaveCalls += 1;
    final started = leaveStarted;
    if (started != null && !started.isCompleted) started.complete();
    await leaveGate?.future;
  }
}

class _FakePlaybackPort implements WatchPartyPlaybackPort {
  _FakePlaybackPort({this.cancelGate}) {
    _controller = StreamController<WatchPartyPlaybackSample>.broadcast(
      onCancel: () => cancelGate?.future,
    );
  }

  final Completer<void>? cancelGate;
  late final StreamController<WatchPartyPlaybackSample> _controller;
  final seekTargets = <Duration>[];
  int playCalls = 0;
  int pauseCalls = 0;
  int activeSeekCommands = 0;
  int maximumConcurrentSeeks = 0;
  Completer<void>? seekGate;
  Object? seekError;

  @override
  Stream<WatchPartyPlaybackSample> get snapshots => _controller.stream;

  void emit(WatchPartyPlaybackSample sample) => _controller.add(sample);

  @override
  Future<void> pause() async => pauseCalls += 1;

  @override
  Future<void> play() async => playCalls += 1;

  @override
  Future<void> seekTo(Duration position) async {
    seekTargets.add(position);
    if (seekError case final error?) throw error;
    final gate = seekGate;
    activeSeekCommands += 1;
    if (activeSeekCommands > maximumConcurrentSeeks) {
      maximumConcurrentSeeks = activeSeekCommands;
    }
    try {
      await gate?.future;
    } finally {
      activeSeekCommands -= 1;
    }
  }

  void dispose() => unawaited(_controller.close());
}
