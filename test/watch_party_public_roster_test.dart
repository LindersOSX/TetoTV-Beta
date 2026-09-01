import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/settings/application/local_profiles_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_public_identity_provider.dart';
import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'provider keeps the Watch Party client identity current outside the lobby',
    () async {
      final identityState = StateProvider<WatchPartyPublicIdentity?>((_) {
        return WatchPartyPublicIdentity.tryCreate(
          displayName: 'AniList Host',
          avatarUrl: 'https://img.anili.st/user/123/avatar.png',
        );
      });
      final container = ProviderContainer(
        overrides: [
          watchPartyPublicIdentityProvider.overrideWith(
            (ref) => ref.watch(identityState),
          ),
        ],
      );
      addTearDown(container.dispose);

      final client = container.read(watchPartyClientProvider);
      expect(client.publicIdentityForTesting?.toJson(), {
        'display_name': 'AniList Host',
        'avatar_url': 'https://img.anili.st/user/123/avatar.png',
      });

      container
          .read(identityState.notifier)
          .state = WatchPartyPublicIdentity.tryCreate(
        displayName: 'MAL Guest',
        avatarUrl:
            'https://api-cdn.myanimelist.net/images/userimages/456.jpg?t=1725123456',
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        identical(container.read(watchPartyClientProvider), client),
        isTrue,
        reason: 'an active room must not lose its long-lived client',
      );
      expect(client.publicIdentityForTesting?.toJson(), {
        'display_name': 'MAL Guest',
        'avatar_url':
            'https://api-cdn.myanimelist.net/images/userimages/456.jpg',
      });
    },
  );

  test('public identity keeps only a bounded name and allowlisted avatar', () {
    final identity = WatchPartyPublicIdentity.tryCreate(
      displayName: '  Teto   Fan  ',
      avatarUrl:
          'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b123.jpg',
    );
    expect(identity?.toJson(), {
      'display_name': 'Teto Fan',
      'avatar_url':
          'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b123.jpg',
    });

    for (final avatar in [
      'http://s4.anilist.co/avatar.jpg',
      'https://user:password@s4.anilist.co/avatar.jpg',
      'https://s4.anilist.co/avatar.jpg?token=secret',
      'https://s4.anilist.co/avatar.jpg#tracking',
      'https://s4.anilist.co:444/avatar.jpg',
      'https://127.0.0.1/avatar.jpg',
      'https://10.0.0.1/avatar.jpg',
      'https://localhost/avatar.jpg',
      'https://avatars.example.test/avatar.jpg',
    ]) {
      expect(
        WatchPartyPublicIdentity.tryCreate(
          displayName: 'Guest',
          avatarUrl: avatar,
        )?.toJson(),
        {'display_name': 'Guest'},
        reason: avatar,
      );
    }
    expect(
      WatchPartyPublicIdentity.tryCreate(displayName: 'viewer@example.com'),
      isNull,
    );
    expect(
      WatchPartyPublicIdentity.tryCreate(
        displayName: List<String>.filled(49, 'x').join(),
      ),
      isNull,
    );
  });

  test('matching local persona keeps the preferred tracker public avatar', () {
    final identity = watchPartyPublicIdentityForProfiles(
      activeLocalProfile: const LocalProfile(
        id: 'local-profile-1',
        displayName: '  shared   VIEWER  ',
      ),
      trackerProfiles: const <TrackingProvider, TrackingAccountProfile>{
        TrackingProvider.anilist: TrackingAccountProfile(
          provider: TrackingProvider.anilist,
          username: 'Shared Viewer',
          avatarUrl: 'https://img.anili.st/user/123/avatar.png',
        ),
        TrackingProvider.myAnimeList: TrackingAccountProfile(
          provider: TrackingProvider.myAnimeList,
          username: 'shared viewer',
          avatarUrl:
              'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg',
        ),
      },
      preferredTracker: TrackingProvider.myAnimeList,
    );

    expect(identity?.toJson(), {
      'display_name': 'shared VIEWER',
      'avatar_url':
          'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg',
    });

    final deterministicFallback = watchPartyPublicIdentityForProfiles(
      activeLocalProfile: const LocalProfile(
        id: 'local-profile-2',
        displayName: 'Shared Viewer',
      ),
      trackerProfiles: const <TrackingProvider, TrackingAccountProfile>{
        TrackingProvider.anilist: TrackingAccountProfile(
          provider: TrackingProvider.anilist,
          username: 'Different AniList User',
          avatarUrl: 'https://img.anili.st/user/999/avatar.png',
        ),
        TrackingProvider.myAnimeList: TrackingAccountProfile(
          provider: TrackingProvider.myAnimeList,
          username: 'shared viewer',
          avatarUrl:
              'https://cdn.myanimelist.net/images/userimages/456/avatar.jpg',
        ),
      },
      preferredTracker: TrackingProvider.anilist,
    );
    expect(
      deterministicFallback?.avatarUrl,
      'https://cdn.myanimelist.net/images/userimages/456/avatar.jpg',
    );
  });

  test('AniList host and MAL guest exchange public avatars', () {
    final host = _trackerIdentity(
      provider: TrackingProvider.anilist,
      username: 'Ani Host',
      avatarUrl: 'https://img.anili.st/user/123/avatar.png',
    );
    final guest = _trackerIdentity(
      provider: TrackingProvider.myAnimeList,
      username: 'MAL Guest',
      avatarUrl:
          'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg?t=1725123456',
    );

    final snapshot = _crossTrackerSnapshot(host: host, guest: guest);

    expect(snapshot.participants, hasLength(2));
    expect(snapshot.participants[0].displayName, 'Ani Host');
    expect(
      snapshot.participants[0].avatarUrl,
      'https://img.anili.st/user/123/avatar.png',
    );
    expect(snapshot.participants[1].displayName, 'MAL Guest');
    expect(
      snapshot.participants[1].avatarUrl,
      'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg',
    );
  });

  test('MAL cache-buster is removed without accepting private query data', () {
    final identity = WatchPartyPublicIdentity.tryCreate(
      displayName: 'MAL Viewer',
      avatarUrl:
          'https://api-cdn.myanimelist.net/images/userimages/456.jpg?t=1619168400',
    );

    expect(identity?.toJson(), {
      'display_name': 'MAL Viewer',
      'avatar_url': 'https://api-cdn.myanimelist.net/images/userimages/456.jpg',
    });
    for (final unsafeUrl in <String>[
      'https://api-cdn.myanimelist.net/images/userimages/456.jpg?token=secret',
      'https://api-cdn.myanimelist.net/images/userimages/456.jpg?t=1&token=secret',
      'https://s4.anilist.co/avatar.jpg?t=1619168400',
    ]) {
      expect(
        WatchPartyPublicIdentity.tryCreate(
          displayName: 'MAL Viewer',
          avatarUrl: unsafeUrl,
        )?.toJson(),
        {'display_name': 'MAL Viewer'},
        reason: unsafeUrl,
      );
    }
  });

  test('MAL host and AniList guest exchange public avatars', () {
    final host = _trackerIdentity(
      provider: TrackingProvider.myAnimeList,
      username: 'MAL Host',
      avatarUrl: 'https://cdn.myanimelist.net/images/userimages/789.jpg',
    );
    final guest = _trackerIdentity(
      provider: TrackingProvider.anilist,
      username: 'Ani Guest',
      avatarUrl:
          'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b321.jpg',
    );

    final snapshot = _crossTrackerSnapshot(host: host, guest: guest);

    expect(snapshot.participants, hasLength(2));
    expect(snapshot.participants[0].displayName, 'MAL Host');
    expect(
      snapshot.participants[0].avatarUrl,
      'https://cdn.myanimelist.net/images/userimages/789.jpg',
    );
    expect(snapshot.participants[1].displayName, 'Ani Guest');
    expect(
      snapshot.participants[1].avatarUrl,
      'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b321.jpg',
    );
  });

  test('missing or untrusted tracker avatar keeps the initials fallback', () {
    final identity = _trackerIdentity(
      provider: TrackingProvider.anilist,
      username: 'Fallback Viewer',
      avatarUrl: 'https://tracker.example/private/avatar?token=secret',
    );

    expect(identity.toJson(), {'display_name': 'Fallback Viewer'});
    final snapshot = _crossTrackerSnapshot(host: identity);
    expect(snapshot.participants.single.displayName, 'Fallback Viewer');
    expect(snapshot.participants.single.avatarUrl, isNull);
  });

  test('snapshot accepts a strict bounded public roster only', () {
    final roster = <Object?>[
      {
        'display_name': 'Host Viewer',
        'avatar_url': 'https://cdn.myanimelist.net/images/userimages/123.jpg',
        'role': 'host',
        'ready': true,
      },
      {
        'display_name': 'Leaky Guest',
        'role': 'guest',
        'ready': false,
        'account_id': 'must-not-enter-model',
      },
      for (var index = 0; index < 24; index++)
        {
          'display_name': 'Guest ${index + 1}',
          'role': 'guest',
          'ready': index.isEven,
        },
    ];
    final snapshot = WatchPartySnapshot.fromJson({
      ..._snapshotJson(),
      'participant_count': 999,
      'ready_count': 999,
      'participants': roster,
    });

    expect(snapshot.participantCount, maximumWatchPartyGuestCount);
    expect(snapshot.readyCount, maximumWatchPartyGuestCount);
    expect(snapshot.participants.length, maximumWatchPartyRosterSize - 1);
    expect(snapshot.participants.first.displayName, 'Host Viewer');
    expect(snapshot.participants.first.avatarUrl, startsWith('https://cdn.'));
    expect(
      snapshot.participants.any(
        (participant) => participant.displayName == 'Leaky Guest',
      ),
      isFalse,
    );
    expect(
      jsonEncode(
        snapshot.participants.map((item) => item.displayName).toList(),
      ),
      isNot(contains('must-not-enter-model')),
    );

    for (final unsafeAvatar in [
      'https://s4.anilist.co/avatar.jpg?tracking=1',
      'https://127.0.0.1/avatar.jpg',
      'https://private.example.test/avatar.jpg',
    ]) {
      expect(
        WatchPartyParticipant.tryFromJson({
          'display_name': 'Guest',
          'avatar_url': unsafeAvatar,
          'role': 'guest',
          'ready': false,
        }),
        isNull,
      );
    }
  });

  test(
    'client sends public identity and retries old brokers without it',
    () async {
      final requests = <RequestOptions>[];
      final attempts = <String, int>{};
      final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              final attempt = (attempts[options.path] ?? 0) + 1;
              attempts[options.path] = attempt;
              if (attempt == 1 && !options.path.endsWith('/ready')) {
                handler.resolve(
                  Response<Object?>(
                    requestOptions: options,
                    statusCode: 400,
                    data: const {'error': 'invalid_payload'},
                  ),
                );
                return;
              }
              final data = switch (options.path) {
                '/v1/watch-parties' => <String, Object?>{
                  'room_code': '23456789',
                  'host_token': List<String>.filled(48, 'a').join(),
                  'expires_at': '2030-01-01T00:00:00Z',
                  'watch_url': '/watch?room=23456789',
                },
                '/v1/watch-parties/join' => <String, Object?>{
                  'participant_token': List<String>.filled(48, 'b').join(),
                  'expires_at': '2030-01-01T00:00:00Z',
                  'state': _snapshotJson(),
                },
                _ => _snapshotJson(),
              };
              handler.resolve(
                Response<Object?>(
                  requestOptions: options,
                  statusCode: options.path == '/v1/watch-parties' ? 201 : 200,
                  data: data,
                ),
              );
            },
          ),
        );
      final client = WatchPartyClient(baseUrl: 'https://tetotv.example', dio: dio)
        ..setPublicIdentity(
          WatchPartyPublicIdentity.tryCreate(
            displayName: 'Public Viewer',
            avatarUrl:
                'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b1.jpg',
          ),
        );

      await client.create();
      final joined = await client.join('23456789');
      await client.setReady(session: joined.session, ready: true);

      expect(requests, hasLength(5));
      for (var index = 0; index < 4; index += 2) {
        final first = requests[index].data as Map;
        final fallback = requests[index + 1].data as Map;
        expect(first['identity'], {
          'display_name': 'Public Viewer',
          'avatar_url':
              'https://s4.anilist.co/file/anilistcdn/user/avatar/large/b1.jpg',
        });
        expect(fallback.containsKey('identity'), isFalse);
        final serialized = jsonEncode(first);
        expect(serialized, isNot(contains('provider')));
        expect(serialized, isNot(contains('account_id')));
        expect(serialized, isNot(contains('email')));
        expect(serialized, isNot(contains('oauth')));
        expect(serialized, isNot(contains('token')));
      }
      expect(requests.last.path, endsWith('/ready'));
      expect(requests.last.data, {'ready': true});
    },
  );

  test('in-flight Ready cannot carry an identity older than refresh', () async {
    final readyStarted = Completer<void>();
    RequestInterceptorHandler? heldReadyHandler;
    RequestOptions? readyRequest;
    RequestOptions? identityRequest;
    final dio = Dio(BaseOptions(baseUrl: 'https://tetotv.example'))
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/ready')) {
              readyRequest = options;
              heldReadyHandler = handler;
              readyStarted.complete();
              return;
            }
            identityRequest = options;
            handler.resolve(
              Response<Object?>(
                requestOptions: options,
                statusCode: 200,
                data: _snapshotJson(),
              ),
            );
          },
        ),
      );
    final client = WatchPartyClient(
      baseUrl: 'https://tetotv.example',
      dio: dio,
    );
    final session = WatchPartySession(
      roomCode: '23456789',
      token: List<String>.filled(48, 'b').join(),
      role: WatchPartyRole.guest,
      expiresAt: DateTime.utc(2030),
      watchUrl: Uri.parse('https://tetotv.example/watch?room=23456789'),
    );
    client.setPublicIdentity(
      WatchPartyPublicIdentity.tryCreate(displayName: 'Identity A'),
    );

    final ready = client.setReady(session: session, ready: true);
    await readyStarted.future;
    final identityB = WatchPartyPublicIdentity.tryCreate(
      displayName: 'Identity B',
      avatarUrl: 'https://img.anili.st/user/123/avatar.png',
    )!;
    client.setPublicIdentity(identityB);
    await client.updatePublicIdentity(session: session, identity: identityB);

    expect(readyRequest?.data, {'ready': true});
    expect(identityRequest?.data, {
      'identity': {
        'display_name': 'Identity B',
        'avatar_url': 'https://img.anili.st/user/123/avatar.png',
      },
    });
    final handler = heldReadyHandler;
    expect(handler, isNotNull);
    handler!.resolve(
      Response<Object?>(
        requestOptions: readyRequest!,
        statusCode: 200,
        data: _snapshotJson(),
      ),
    );
    await ready;
  });

  test('client refreshes a late cross-tracker public avatar in the room', () async {
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
                data: {
                  ..._snapshotJson(),
                  'participants': [
                    {
                      'display_name': 'AniList Host',
                      'participant_id': 'abcdefghijklmnop',
                      'avatar_url': 'https://img.anili.st/user/123/avatar.png',
                      'role': 'host',
                      'ready': true,
                    },
                    {
                      'display_name': 'MAL Guest',
                      'participant_id': 'qrstuvwxyzABCDEF',
                      'avatar_url':
                          'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg',
                      'role': 'guest',
                      'ready': false,
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
    final client = WatchPartyClient(
      baseUrl: 'https://tetotv.example',
      dio: dio,
    );
    final identity = WatchPartyPublicIdentity.tryCreate(
      displayName: 'MAL Guest',
      avatarUrl:
          'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg?t=1725123456',
    )!;
    final snapshot = await client.updatePublicIdentity(
      session: WatchPartySession(
        roomCode: '23456789',
        token: List<String>.filled(48, 'b').join(),
        role: WatchPartyRole.guest,
        expiresAt: DateTime.utc(2030),
        watchUrl: Uri.parse('https://tetotv.example/watch?room=23456789'),
      ),
      identity: identity,
    );

    expect(recorded?.method, 'POST');
    expect(recorded?.path, '/v1/watch-parties/23456789/identity');
    expect(recorded?.headers['Authorization'], startsWith('Bearer '));
    expect(recorded?.data, {
      'identity': {
        'display_name': 'MAL Guest',
        'avatar_url':
            'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg',
      },
    });
    expect(snapshot.participants.map((item) => item.avatarUrl), [
      'https://img.anili.st/user/123/avatar.png',
      'https://api-cdn.myanimelist.net/images/userimages/456/avatar.jpg',
    ]);
  });

  test(
    'client sends an explicit null identity when tracker data is removed',
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
                  data: _snapshotJson(),
                ),
              );
            },
          ),
        );
      final client = WatchPartyClient(
        baseUrl: 'https://tetotv.example',
        dio: dio,
      );

      await client.updatePublicIdentity(
        session: WatchPartySession(
          roomCode: '23456789',
          token: List<String>.filled(48, 'b').join(),
          role: WatchPartyRole.guest,
          expiresAt: DateTime.utc(2030),
          watchUrl: Uri.parse('https://tetotv.example/watch?room=23456789'),
        ),
        identity: null,
      );

      expect(recorded?.data, {'identity': null});
    },
  );
}

Map<String, Object?> _snapshotJson() => {
  'room_code': '23456789',
  'role': 'guest',
  'revision': 1,
  'media': null,
  'playing': false,
  'position_ms': 0,
  'effective_at_ms': 0,
  'server_time_ms': 0,
  'participant_count': 1,
  'ready_count': 0,
  'participants': const <Object?>[],
  'expires_at': '2030-01-01T00:00:00Z',
};

WatchPartyPublicIdentity _trackerIdentity({
  required TrackingProvider provider,
  required String username,
  required String avatarUrl,
}) => watchPartyPublicIdentityForProfiles(
  activeLocalProfile: null,
  trackerProfiles: <TrackingProvider, TrackingAccountProfile>{
    provider: TrackingAccountProfile(
      provider: provider,
      username: username,
      avatarUrl: avatarUrl,
    ),
  },
  preferredTracker: provider,
)!;

WatchPartySnapshot _crossTrackerSnapshot({
  required WatchPartyPublicIdentity host,
  WatchPartyPublicIdentity? guest,
}) {
  Map<String, Object?> participant(
    WatchPartyPublicIdentity identity,
    String role,
  ) => <String, Object?>{...identity.toJson(), 'role': role, 'ready': true};

  return WatchPartySnapshot.fromJson({
    ..._snapshotJson(),
    'participants': <Object?>[
      participant(host, 'host'),
      if (guest != null) participant(guest, 'guest'),
    ],
  });
}
