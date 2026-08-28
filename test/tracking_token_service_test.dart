import 'dart:async';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/data/anilist_pairing_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/failure_injecting_secure_storage.dart';

void main() {
  const storage = FlutterSecureStorage();
  final now = DateTime.utc(2026, 8, 2, 12);

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('shares one rotating MAL refresh across concurrent callers', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.myAnimeList.tokenStorageKey: 'old-access',
      TrackingProvider.myAnimeList.refreshTokenStorageKey: 'old-refresh',
      TrackingProvider.myAnimeList.expiresAtStorageKey: now
          .add(const Duration(minutes: 2))
          .toIso8601String(),
      authBrokerUrlStorageKey: 'https://auth.example.test',
    });
    final refresh = Completer<TrackingTokenSet>();
    final client = _FakePairingClient(() => refresh.future);
    final service = TrackingTokenService(
      storage,
      clientFactory: (_, {required baseUrl}) => client,
      now: () => now,
    );

    final first = service.accessToken(TrackingProvider.myAnimeList);
    final second = service.accessToken(TrackingProvider.myAnimeList);
    await Future<void>.delayed(Duration.zero);
    expect(client.refreshCalls, 1);

    refresh.complete(
      TrackingTokenSet(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
        expiresAt: now.add(const Duration(hours: 1)),
      ),
    );
    expect(await Future.wait([first, second]), ['new-access', 'new-access']);
    expect(
      await storage.read(
        key: TrackingProvider.myAnimeList.refreshTokenStorageKey,
      ),
      'new-refresh',
    );
  });

  test('keeps a still-valid MAL token during a broker outage', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.myAnimeList.tokenStorageKey: 'still-valid',
      TrackingProvider.myAnimeList.refreshTokenStorageKey: 'refresh',
      TrackingProvider.myAnimeList.expiresAtStorageKey: now
          .add(const Duration(minutes: 2))
          .toIso8601String(),
      authBrokerUrlStorageKey: 'https://auth.example.test',
    });
    final service = TrackingTokenService(
      storage,
      clientFactory: (_, {required baseUrl}) =>
          _FakePairingClient(() async => throw StateError('broker sleeping')),
      now: () => now,
    );

    expect(
      await service.accessToken(TrackingProvider.myAnimeList),
      'still-valid',
    );
  });

  test('requires reconnect when an expired MAL token cannot refresh', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.myAnimeList.tokenStorageKey: 'expired',
      TrackingProvider.myAnimeList.expiresAtStorageKey: now
          .subtract(const Duration(minutes: 1))
          .toIso8601String(),
    });
    final service = TrackingTokenService(storage, now: () => now);

    await expectLater(
      service.accessToken(TrackingProvider.myAnimeList),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Reconnect MAL'),
        ),
      ),
    );
  });

  test('manual token entry clears stale QR refresh metadata', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.myAnimeList.tokenStorageKey: 'old-access',
      TrackingProvider.myAnimeList.refreshTokenStorageKey: 'old-refresh',
      TrackingProvider.myAnimeList.expiresAtStorageKey: now.toIso8601String(),
    });
    final service = TrackingTokenService(storage, now: () => now);

    await service.save(TrackingProvider.myAnimeList, '  manual-access  ');

    expect(
      await storage.read(key: TrackingProvider.myAnimeList.tokenStorageKey),
      'manual-access',
    );
    expect(
      await storage.read(
        key: TrackingProvider.myAnimeList.refreshTokenStorageKey,
      ),
      isNull,
    );
    expect(
      await storage.read(key: TrackingProvider.myAnimeList.expiresAtStorageKey),
      isNull,
    );
  });

  test('secure setup retains complete rotating MAL metadata', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = TrackingTokenService(storage, now: () => now);
    final expiry = now.add(const Duration(days: 30));

    await service.saveTokenSet(
      TrackingProvider.myAnimeList,
      accessToken: '  setup-access  ',
      refreshToken: '  setup-refresh  ',
      expiresAt: expiry,
    );

    expect(
      await storage.read(key: TrackingProvider.myAnimeList.tokenStorageKey),
      'setup-access',
    );
    expect(
      await storage.read(
        key: TrackingProvider.myAnimeList.refreshTokenStorageKey,
      ),
      'setup-refresh',
    );
    expect(
      await storage.read(key: TrackingProvider.myAnimeList.expiresAtStorageKey),
      expiry.toIso8601String(),
    );
  });

  test(
    'failed secure setup write restores the previous complete MAL session',
    () async {
      final oldExpiry = now.add(const Duration(days: 2)).toIso8601String();
      final failingStorage = FailureInjectingSecureStorage({
        TrackingProvider.myAnimeList.tokenStorageKey: 'old-access',
        TrackingProvider.myAnimeList.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.myAnimeList.expiresAtStorageKey: oldExpiry,
      });
      final service = TrackingTokenService(failingStorage, now: () => now);
      failingStorage.failNextWrite(
        TrackingProvider.myAnimeList.tokenStorageKey,
      );

      await expectLater(
        service.saveTokenSet(
          TrackingProvider.myAnimeList,
          accessToken: 'new-access',
          refreshToken: 'new-refresh',
          expiresAt: now.add(const Duration(days: 30)),
        ),
        throwsA(isA<StateError>()),
      );

      expect(
        failingStorage.values,
        containsPair(
          TrackingProvider.myAnimeList.tokenStorageKey,
          'old-access',
        ),
      );
      expect(
        failingStorage.values,
        containsPair(
          TrackingProvider.myAnimeList.refreshTokenStorageKey,
          'old-refresh',
        ),
      );
      expect(
        failingStorage.values,
        containsPair(
          TrackingProvider.myAnimeList.expiresAtStorageKey,
          oldExpiry,
        ),
      );
    },
  );

  test(
    'encrypted profile slots switch accounts without exposing tokens',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.anilist.tokenStorageKey: 'alice-secret-token',
      });
      final service = TrackingTokenService(storage);

      final alice = await service.rememberCurrentProfile(
        TrackingProvider.anilist,
        'Alice',
      );
      expect(alice, isNotNull);
      await storage.write(
        key: TrackingProvider.anilist.tokenStorageKey,
        value: 'bob-secret-token',
      );
      final bob = await service.rememberCurrentProfile(
        TrackingProvider.anilist,
        'Bob',
      );

      final saved = await service.savedProfiles();
      expect(saved.map((profile) => profile.username), ['Alice', 'Bob']);
      expect(alice!.id, isNot(bob!.id));
      final index = await storage.read(key: 'tracking_profile_index_v1');
      expect(index, isNot(contains('alice-secret-token')));
      expect(index, isNot(contains('bob-secret-token')));

      await service.activateProfile(alice);
      expect(
        await storage.read(key: TrackingProvider.anilist.tokenStorageKey),
        'alice-secret-token',
      );
      expect(await service.activeProfileId(TrackingProvider.anilist), alice.id);

      await service.clear(TrackingProvider.anilist);
      expect(await service.savedProfiles(), isEmpty);
      expect(
        await storage.read(key: TrackingProvider.anilist.tokenStorageKey),
        isNull,
      );
    },
  );

  test('profile activation restores rotating MAL session metadata', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.myAnimeList.tokenStorageKey: 'mal-access-a',
      TrackingProvider.myAnimeList.refreshTokenStorageKey: 'mal-refresh-a',
      TrackingProvider.myAnimeList.expiresAtStorageKey: now
          .add(const Duration(days: 1))
          .toIso8601String(),
    });
    final service = TrackingTokenService(storage, now: () => now);
    final profile = await service.rememberCurrentProfile(
      TrackingProvider.myAnimeList,
      'MAL Alice',
    );
    await service.save(TrackingProvider.myAnimeList, 'mal-access-b');

    await service.activateProfile(profile!);

    expect(
      await storage.read(
        key: TrackingProvider.myAnimeList.refreshTokenStorageKey,
      ),
      'mal-refresh-a',
    );
    expect(
      await storage.read(key: TrackingProvider.myAnimeList.expiresAtStorageKey),
      now.add(const Duration(days: 1)).toIso8601String(),
    );
  });
}

class _FakePairingClient extends TrackingPairingClient {
  _FakePairingClient(this._refresh)
    : super(TrackingProvider.myAnimeList, baseUrl: 'https://auth.example.test');

  final Future<TrackingTokenSet> Function() _refresh;
  int refreshCalls = 0;

  @override
  Future<TrackingTokenSet> refresh(String refreshToken) {
    refreshCalls++;
    return _refresh();
  }
}
