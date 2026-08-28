import 'dart:convert';

import 'package:anime_tv/features/watch_together/data/watch_party_client.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
              if (attempt == 1) {
                handler.resolve(
                  Response<Object?>(
                    requestOptions: options,
                    statusCode: 400,
                    data: {
                      'error': options.path.endsWith('/ready')
                          ? 'invalid_ready_state'
                          : 'invalid_payload',
                    },
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

      expect(requests, hasLength(6));
      for (var index = 0; index < requests.length; index += 2) {
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
