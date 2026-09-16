import 'dart:async';
import 'dart:convert';

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

  test('shares and persists one refreshable Kitsu session', () async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.kitsu.tokenStorageKey: 'old-kitsu-access',
      TrackingProvider.kitsu.refreshTokenStorageKey: 'old-kitsu-refresh',
      TrackingProvider.kitsu.expiresAtStorageKey: now
          .add(const Duration(minutes: 2))
          .toIso8601String(),
      authBrokerUrlStorageKey: 'https://auth.example.test',
    });
    final refresh = Completer<TrackingTokenSet>();
    final client = _FakePairingClient(
      () => refresh.future,
      provider: TrackingProvider.kitsu,
    );
    TrackingProvider? requestedProvider;
    final service = TrackingTokenService(
      storage,
      clientFactory: (provider, {required baseUrl}) {
        requestedProvider = provider;
        return client;
      },
      now: () => now,
    );

    final first = service.accessToken(TrackingProvider.kitsu);
    final second = service.accessToken(TrackingProvider.kitsu);
    await Future<void>.delayed(Duration.zero);
    expect(client.refreshCalls, 1);
    expect(requestedProvider, TrackingProvider.kitsu);

    final expiry = now.add(const Duration(days: 30));
    refresh.complete(
      TrackingTokenSet(
        accessToken: 'next-kitsu-access',
        refreshToken: 'next-kitsu-refresh',
        expiresAt: expiry,
      ),
    );
    expect(await Future.wait([first, second]), [
      'next-kitsu-access',
      'next-kitsu-access',
    ]);
    expect(
      await storage.read(key: TrackingProvider.kitsu.refreshTokenStorageKey),
      'next-kitsu-refresh',
    );
    expect(
      await storage.read(key: TrackingProvider.kitsu.expiresAtStorageKey),
      expiry.toIso8601String(),
    );
  });

  test(
    'keeps a still-valid Kitsu token on a malformed refresh response',
    () async {
      final oldExpiry = now.add(const Duration(minutes: 2));
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.kitsu.tokenStorageKey: 'still-valid-kitsu-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'kitsu-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry.toIso8601String(),
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final service = TrackingTokenService(
        storage,
        clientFactory: (_, {required baseUrl}) => _FakePairingClient(
          () async => const TrackingTokenSet(accessToken: 'replacement-access'),
          provider: TrackingProvider.kitsu,
        ),
        now: () => now,
      );

      expect(
        await service.accessToken(TrackingProvider.kitsu),
        'still-valid-kitsu-access',
      );
      expect(
        await storage.read(key: TrackingProvider.kitsu.refreshTokenStorageKey),
        'kitsu-refresh',
      );
      expect(
        await storage.read(key: TrackingProvider.kitsu.expiresAtStorageKey),
        oldExpiry.toIso8601String(),
      );
    },
  );

  for (final invalid in <({String label, TrackingTokenSet tokens})>[
    (
      label: 'missing expiry',
      tokens: const TrackingTokenSet(accessToken: 'new-access'),
    ),
    (
      label: 'past expiry',
      tokens: TrackingTokenSet(
        accessToken: 'new-access',
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ),
    ),
    (
      label: 'unreasonably distant expiry',
      tokens: TrackingTokenSet(
        accessToken: 'new-access',
        expiresAt: now.add(const Duration(days: 3651)),
      ),
    ),
    (
      label: 'blank access token',
      tokens: TrackingTokenSet(
        accessToken: '   ',
        expiresAt: now.add(const Duration(days: 30)),
      ),
    ),
    (
      label: 'oversized access token',
      tokens: TrackingTokenSet(
        accessToken: List<String>.filled(4097, 'x').join(),
        expiresAt: now.add(const Duration(days: 30)),
      ),
    ),
  ]) {
    test('expired Kitsu session rejects ${invalid.label}', () async {
      final oldExpiry = now.subtract(const Duration(minutes: 1));
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry.toIso8601String(),
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final service = TrackingTokenService(
        storage,
        clientFactory: (_, {required baseUrl}) => _FakePairingClient(
          () async => invalid.tokens,
          provider: TrackingProvider.kitsu,
        ),
        now: () => now,
      );

      await expectLater(
        service.accessToken(TrackingProvider.kitsu),
        throwsA(isA<FormatException>()),
      );
      expect(
        await storage.read(key: TrackingProvider.kitsu.tokenStorageKey),
        'old-access',
      );
      expect(
        await storage.read(key: TrackingProvider.kitsu.refreshTokenStorageKey),
        'old-refresh',
      );
      expect(
        await storage.read(key: TrackingProvider.kitsu.expiresAtStorageKey),
        oldExpiry.toIso8601String(),
      );
    });
  }

  for (final invalidStored in <({String label, Map<String, String> values})>[
    (
      label: 'missing refresh metadata',
      values: {
        TrackingProvider.kitsu.tokenStorageKey: 'kitsu-access',
        TrackingProvider.kitsu.expiresAtStorageKey: now
            .add(const Duration(days: 1))
            .toIso8601String(),
      },
    ),
    (
      label: 'missing expiry metadata',
      values: {
        TrackingProvider.kitsu.tokenStorageKey: 'kitsu-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'kitsu-refresh',
      },
    ),
    (
      label: 'unreasonably distant stored expiry',
      values: {
        TrackingProvider.kitsu.tokenStorageKey: 'kitsu-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'kitsu-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: now
            .add(const Duration(days: 3651))
            .toIso8601String(),
      },
    ),
  ]) {
    test('Kitsu fails closed for ${invalidStored.label}', () async {
      FlutterSecureStorage.setMockInitialValues(invalidStored.values);
      final service = TrackingTokenService(storage, now: () => now);

      await expectLater(
        service.accessToken(TrackingProvider.kitsu),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Reconnect Kitsu'),
          ),
        ),
      );
    });
  }

  for (final invalidSet
      in <({String label, String? refresh, DateTime? expiry})>[
        (
          label: 'missing refresh',
          refresh: null,
          expiry: now.add(const Duration(days: 1)),
        ),
        (
          label: 'blank refresh',
          refresh: '   ',
          expiry: now.add(const Duration(days: 1)),
        ),
        (label: 'missing expiry', refresh: 'new-refresh', expiry: null),
        (
          label: 'past expiry',
          refresh: 'new-refresh',
          expiry: now.subtract(const Duration(seconds: 1)),
        ),
        (
          label: 'far expiry',
          refresh: 'new-refresh',
          expiry: now.add(const Duration(days: 3651)),
        ),
      ]) {
    test(
      'saveTokenSet rejects Kitsu ${invalidSet.label} before writes',
      () async {
        final oldExpiry = now.add(const Duration(days: 1)).toIso8601String();
        final guardedStorage = FailureInjectingSecureStorage({
          TrackingProvider.kitsu.tokenStorageKey: 'old-access',
          TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
          TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry,
        });
        final service = TrackingTokenService(guardedStorage, now: () => now);

        await expectLater(
          service.saveTokenSet(
            TrackingProvider.kitsu,
            accessToken: 'new-access',
            refreshToken: invalidSet.refresh,
            expiresAt: invalidSet.expiry,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(guardedStorage.mutations, isEmpty);
        expect(
          guardedStorage.values,
          containsPair(TrackingProvider.kitsu.tokenStorageKey, 'old-access'),
        );
      },
    );
  }

  for (final provider in const [
    TrackingProvider.myAnimeList,
    TrackingProvider.kitsu,
  ]) {
    test(
      '${provider.slug} refresh keeps its saved profile slot current',
      () async {
        final oldExpiry = now.add(const Duration(minutes: 2));
        FlutterSecureStorage.setMockInitialValues({
          provider.tokenStorageKey: 'old-${provider.slug}-access',
          provider.refreshTokenStorageKey: 'old-${provider.slug}-refresh',
          provider.expiresAtStorageKey: oldExpiry.toIso8601String(),
          authBrokerUrlStorageKey: 'https://auth.example.test',
        });
        final newExpiry = now.add(const Duration(days: 30));
        final service = TrackingTokenService(
          storage,
          clientFactory: (_, {required baseUrl}) => _FakePairingClient(
            () async => TrackingTokenSet(
              accessToken: 'new-${provider.slug}-access',
              refreshToken: 'new-${provider.slug}-refresh',
              expiresAt: newExpiry,
            ),
            provider: provider,
          ),
          now: () => now,
        );
        final alice = await service.rememberCurrentProfile(provider, 'Alice');

        expect(
          await service.accessToken(provider),
          'new-${provider.slug}-access',
        );
        expect(
          await service.verifiedActiveProfileId(
            provider,
            'new-${provider.slug}-access',
          ),
          alice?.id,
        );
        expect(
          await storage.read(
            key: _profileCredentialKeyForTest(provider, alice!.id, 'access'),
          ),
          'new-${provider.slug}-access',
        );
        expect(
          await storage.read(
            key: _profileCredentialKeyForTest(provider, alice.id, 'refresh'),
          ),
          'new-${provider.slug}-refresh',
        );
        expect(
          await storage.read(
            key: _profileCredentialKeyForTest(provider, alice.id, 'expires'),
          ),
          newExpiry.toIso8601String(),
        );

        await service.saveTokenSet(
          provider,
          accessToken: 'bob-${provider.slug}-access',
          refreshToken: 'bob-${provider.slug}-refresh',
          expiresAt: now.add(const Duration(days: 10)),
        );
        await service.rememberCurrentProfile(provider, 'Bob');
        await service.activateProfile(alice);

        expect(
          await storage.read(key: provider.tokenStorageKey),
          'new-${provider.slug}-access',
        );
        expect(
          await storage.read(key: provider.refreshTokenStorageKey),
          'new-${provider.slug}-refresh',
        );
        expect(
          await storage.read(key: provider.expiresAtStorageKey),
          newExpiry.toIso8601String(),
        );
      },
    );
  }

  test(
    'failed profile-slot refresh write rolls back both Kitsu credential sets',
    () async {
      final oldExpiry = now.add(const Duration(minutes: 2)).toIso8601String();
      final failingStorage = FailureInjectingSecureStorage({
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry,
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final service = TrackingTokenService(
        failingStorage,
        clientFactory: (_, {required baseUrl}) => _FakePairingClient(
          () async => TrackingTokenSet(
            accessToken: 'new-access',
            refreshToken: 'new-refresh',
            expiresAt: now.add(const Duration(days: 30)),
          ),
          provider: TrackingProvider.kitsu,
        ),
        now: () => now,
      );
      final profile = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'Kitsu Alice',
      );
      final profileAccess = _profileCredentialKeyForTest(
        TrackingProvider.kitsu,
        profile!.id,
        'access',
      );
      failingStorage.failNextWrite(profileAccess);

      await expectLater(
        service.accessToken(TrackingProvider.kitsu),
        throwsA(isA<StateError>()),
      );

      expect(
        failingStorage.values,
        containsPair(TrackingProvider.kitsu.tokenStorageKey, 'old-access'),
      );
      expect(
        failingStorage.values,
        containsPair(
          TrackingProvider.kitsu.refreshTokenStorageKey,
          'old-refresh',
        ),
      );
      expect(
        failingStorage.values,
        containsPair(TrackingProvider.kitsu.expiresAtStorageKey, oldExpiry),
      );
      expect(failingStorage.values, containsPair(profileAccess, 'old-access'));
      expect(
        failingStorage.values,
        containsPair(
          _profileCredentialKeyForTest(
            TrackingProvider.kitsu,
            profile.id,
            'refresh',
          ),
          'old-refresh',
        ),
      );
      expect(
        failingStorage.values,
        containsPair(
          _profileCredentialKeyForTest(
            TrackingProvider.kitsu,
            profile.id,
            'expires',
          ),
          oldExpiry,
        ),
      );
    },
  );

  test(
    'Kitsu refresh commits active refresh before profile and access',
    () async {
      final oldExpiry = now.add(const Duration(minutes: 2)).toIso8601String();
      final orderedStorage = FailureInjectingSecureStorage({
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry,
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final nextExpiry = now.add(const Duration(days: 30));
      final service = TrackingTokenService(
        orderedStorage,
        clientFactory: (_, {required baseUrl}) => _FakePairingClient(
          () async => TrackingTokenSet(
            accessToken: 'new-access',
            refreshToken: 'new-refresh',
            expiresAt: nextExpiry,
          ),
          provider: TrackingProvider.kitsu,
        ),
        now: () => now,
      );
      final profile = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'Kitsu Alice',
      );
      orderedStorage.mutations.clear();

      await service.accessToken(TrackingProvider.kitsu);

      final profilePrefix = 'tracking_profile_kitsu_${profile!.id}';
      expect(orderedStorage.mutations.take(8), [
        'write:${_credentialJournalKeyForTest(TrackingProvider.kitsu)}',
        'write:${TrackingProvider.kitsu.refreshTokenStorageKey}',
        'write:${profilePrefix}_refresh',
        'write:${profilePrefix}_access',
        'write:${profilePrefix}_expires',
        'write:${TrackingProvider.kitsu.tokenStorageKey}',
        'write:${TrackingProvider.kitsu.expiresAtStorageKey}',
        'delete:${_credentialJournalKeyForTest(TrackingProvider.kitsu)}',
      ]);
    },
  );

  test(
    'Kitsu refresh recovers a crash after only primary refresh rotated',
    () async {
      final oldExpiry = now.add(const Duration(minutes: 2));
      final recoveryStorage = FailureInjectingSecureStorage({
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry.toIso8601String(),
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final client = _FakePairingClient(
        () async => TrackingTokenSet(
          accessToken: 'final-access',
          refreshToken: 'final-refresh',
          expiresAt: now.add(const Duration(days: 30)),
        ),
        provider: TrackingProvider.kitsu,
      );
      final service = TrackingTokenService(
        recoveryStorage,
        clientFactory: (_, {required baseUrl}) => client,
        now: () => now,
      );
      final profile = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'Kitsu Alice',
      );

      // State left by a process kill immediately after the first ordered
      // refresh write: primary refresh advanced, profile still has old data.
      recoveryStorage.values[TrackingProvider.kitsu.refreshTokenStorageKey] =
          'intermediate-refresh';
      recoveryStorage.values[_credentialJournalKeyForTest(
        TrackingProvider.kitsu,
      )] = _refreshJournalForTest(
        profile!.id,
      );

      expect(await service.accessToken(TrackingProvider.kitsu), 'final-access');
      expect(client.lastRefreshToken, 'intermediate-refresh');
      expect(
        recoveryStorage.values[_profileCredentialKeyForTest(
          TrackingProvider.kitsu,
          profile.id,
          'refresh',
        )],
        'final-refresh',
      );
      expect(
        await service.verifiedActiveProfileId(
          TrackingProvider.kitsu,
          'final-access',
        ),
        profile.id,
      );
    },
  );

  test(
    'Kitsu startup reconciles a completed refresh slot without retrying',
    () async {
      final oldExpiry = now.add(const Duration(minutes: 2));
      final recoveryStorage = FailureInjectingSecureStorage({
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry.toIso8601String(),
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final client = _FakePairingClient(
        () async => TrackingTokenSet(
          accessToken: 'final-access',
          refreshToken: 'final-refresh',
          expiresAt: now.add(const Duration(days: 30)),
        ),
        provider: TrackingProvider.kitsu,
      );
      final service = TrackingTokenService(
        recoveryStorage,
        clientFactory: (_, {required baseUrl}) => client,
        now: () => now,
      );
      final profile = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'Kitsu Alice',
      );
      final intermediateExpiry = now.add(const Duration(days: 20));
      recoveryStorage.values[TrackingProvider.kitsu.refreshTokenStorageKey] =
          'intermediate-refresh';
      recoveryStorage.values[_profileCredentialKeyForTest(
            TrackingProvider.kitsu,
            profile!.id,
            'refresh',
          )] =
          'intermediate-refresh';
      recoveryStorage.values[_profileCredentialKeyForTest(
            TrackingProvider.kitsu,
            profile.id,
            'access',
          )] =
          'intermediate-access';
      recoveryStorage.values[_profileCredentialKeyForTest(
        TrackingProvider.kitsu,
        profile.id,
        'expires',
      )] = intermediateExpiry
          .toIso8601String();
      recoveryStorage.values[_credentialJournalKeyForTest(
        TrackingProvider.kitsu,
      )] = _refreshJournalForTest(
        profile.id,
      );

      expect(
        await service.accessToken(TrackingProvider.kitsu),
        'intermediate-access',
      );
      expect(client.refreshCalls, 0);
      expect(
        recoveryStorage.values[TrackingProvider.kitsu.tokenStorageKey],
        'intermediate-access',
      );
      expect(
        recoveryStorage.values[_profileCredentialKeyForTest(
          TrackingProvider.kitsu,
          profile.id,
          'access',
        )],
        'intermediate-access',
      );
      expect(
        recoveryStorage.values[_credentialJournalKeyForTest(
          TrackingProvider.kitsu,
        )],
        isNull,
      );
      expect(
        await service.verifiedActiveProfileId(
          TrackingProvider.kitsu,
          'intermediate-access',
        ),
        profile.id,
      );
    },
  );

  test(
    'unjournaled mixed Kitsu credentials fail closed before refresh',
    () async {
      final mixedStorage = FailureInjectingSecureStorage({
        TrackingProvider.kitsu.tokenStorageKey: 'alice-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'alice-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: now
            .add(const Duration(minutes: 2))
            .toIso8601String(),
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final client = _FakePairingClient(
        () async => TrackingTokenSet(
          accessToken: 'wrong-account-access',
          refreshToken: 'wrong-account-refresh',
          expiresAt: now.add(const Duration(days: 30)),
        ),
        provider: TrackingProvider.kitsu,
      );
      final service = TrackingTokenService(
        mixedStorage,
        clientFactory: (_, {required baseUrl}) => client,
        now: () => now,
      );
      final alice = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'Alice',
      );
      mixedStorage.values[TrackingProvider.kitsu.refreshTokenStorageKey] =
          'bob-refresh';

      await expectLater(
        service.accessToken(TrackingProvider.kitsu),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('credentials are inconsistent'),
          ),
        ),
      );
      expect(client.refreshCalls, 0);
      expect(
        mixedStorage.values[_profileCredentialKeyForTest(
          TrackingProvider.kitsu,
          alice!.id,
          'access',
        )],
        'alice-access',
      );
    },
  );

  for (final provider in const [
    TrackingProvider.myAnimeList,
    TrackingProvider.kitsu,
  ]) {
    test(
      '${provider.slug} rotating refresh survives an in-flight profile switch',
      () async {
        final oldExpiry = now.add(const Duration(minutes: 2));
        FlutterSecureStorage.setMockInitialValues({
          provider.tokenStorageKey: 'alice-access',
          provider.refreshTokenStorageKey: 'alice-refresh',
          provider.expiresAtStorageKey: oldExpiry.toIso8601String(),
          authBrokerUrlStorageKey: 'https://auth.example.test',
        });
        final refresh = Completer<TrackingTokenSet>();
        final service = TrackingTokenService(
          storage,
          clientFactory: (_, {required baseUrl}) =>
              _FakePairingClient(() => refresh.future, provider: provider),
          now: () => now,
        );
        final alice = await service.rememberCurrentProfile(provider, 'Alice');
        final pending = service.accessToken(provider);
        await Future<void>.delayed(Duration.zero);

        await service.saveTokenSet(
          provider,
          accessToken: 'bob-access',
          refreshToken: 'bob-refresh',
          expiresAt: now.add(const Duration(days: 10)),
        );
        final bob = await service.rememberCurrentProfile(provider, 'Bob');
        refresh.complete(
          TrackingTokenSet(
            accessToken: 'alice-next-access',
            refreshToken: 'alice-next-refresh',
            expiresAt: now.add(const Duration(days: 30)),
          ),
        );

        await expectLater(pending, throwsA(isA<StateError>()));
        expect(await service.activeProfileId(provider), bob?.id);
        expect(await storage.read(key: provider.tokenStorageKey), 'bob-access');
        await service.activateProfile(alice!);
        expect(
          await storage.read(key: provider.tokenStorageKey),
          'alice-next-access',
        );
        expect(
          await storage.read(key: provider.refreshTokenStorageKey),
          'alice-next-refresh',
        );
        expect(await service.accessToken(provider), 'alice-next-access');
      },
    );
  }

  test(
    'a completed Kitsu refresh cannot overwrite replacement credentials',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: now
            .add(const Duration(minutes: 2))
            .toIso8601String(),
        authBrokerUrlStorageKey: 'https://auth.example.test',
      });
      final refresh = Completer<TrackingTokenSet>();
      final service = TrackingTokenService(
        storage,
        clientFactory: (_, {required baseUrl}) => _FakePairingClient(
          () => refresh.future,
          provider: TrackingProvider.kitsu,
        ),
        now: () => now,
      );
      final pending = service.accessToken(TrackingProvider.kitsu);
      await Future<void>.delayed(Duration.zero);
      final replacementExpiry = now.add(const Duration(days: 20));
      await service.saveTokenSet(
        TrackingProvider.kitsu,
        accessToken: 'replacement-access',
        refreshToken: 'replacement-refresh',
        expiresAt: replacementExpiry,
      );
      refresh.complete(
        TrackingTokenSet(
          accessToken: 'stale-refresh-access',
          refreshToken: 'stale-refresh-token',
          expiresAt: now.add(const Duration(days: 30)),
        ),
      );

      await expectLater(pending, throwsA(isA<StateError>()));
      expect(
        await storage.read(key: TrackingProvider.kitsu.tokenStorageKey),
        'replacement-access',
      );
      expect(
        await storage.read(key: TrackingProvider.kitsu.refreshTokenStorageKey),
        'replacement-refresh',
      );
      expect(
        await storage.read(key: TrackingProvider.kitsu.expiresAtStorageKey),
        replacementExpiry.toIso8601String(),
      );
    },
  );

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

  test(
    'a replacement SIMKL token cannot reuse the previous cache slot',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.simkl.tokenStorageKey: 'old-simkl-token',
      });
      final service = TrackingTokenService(storage);
      final oldProfile = await service.rememberCurrentProfile(
        TrackingProvider.simkl,
        'Old SIMKL User',
      );
      await storage.write(
        key: TrackingProvider.simkl.tokenStorageKey,
        value: 'replacement-simkl-token',
      );

      expect(
        await service.verifiedActiveProfileId(
          TrackingProvider.simkl,
          'replacement-simkl-token',
        ),
        isNull,
      );
      expect(
        await service.verifiedActiveProfileId(
          TrackingProvider.simkl,
          'old-simkl-token',
        ),
        oldProfile?.id,
      );
    },
  );

  test('stable Kitsu account IDs separate identical display names', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = TrackingTokenService(storage, now: () => now);
    await service.saveTokenSet(
      TrackingProvider.kitsu,
      accessToken: 'first-access',
      refreshToken: 'first-refresh',
      expiresAt: now.add(const Duration(days: 10)),
    );
    final first = await service.rememberCurrentProfile(
      TrackingProvider.kitsu,
      'Shared name',
      stableAccountId: '7',
    );
    await service.saveTokenSet(
      TrackingProvider.kitsu,
      accessToken: 'second-access',
      refreshToken: 'second-refresh',
      expiresAt: now.add(const Duration(days: 10)),
    );
    final second = await service.rememberCurrentProfile(
      TrackingProvider.kitsu,
      'Shared name',
      stableAccountId: '8',
    );

    final profiles = (await service.savedProfiles())
        .where((profile) => profile.provider == TrackingProvider.kitsu)
        .toList();
    expect(profiles, hasLength(2));
    expect(first?.id, isNot(second?.id));
    expect(
      profiles.map((profile) => profile.username),
      everyElement('Shared name'),
    );
  });

  test(
    'stable Kitsu ID survives a display-name change and migrates legacy slot',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        TrackingProvider.kitsu.tokenStorageKey: 'kitsu-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'kitsu-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: now
            .add(const Duration(days: 10))
            .toIso8601String(),
      });
      final service = TrackingTokenService(storage, now: () => now);
      final legacy = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'Old display name',
      );
      final migrated = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'Old display name',
        stableAccountId: '7',
      );
      final renamed = await service.rememberCurrentProfile(
        TrackingProvider.kitsu,
        'New display name',
        stableAccountId: '7',
      );

      final profiles = (await service.savedProfiles())
          .where((profile) => profile.provider == TrackingProvider.kitsu)
          .toList();
      expect(profiles, hasLength(1));
      expect(migrated?.id, renamed?.id);
      expect(renamed?.id, isNot(legacy?.id));
      expect(profiles.single.username, 'New display name');
      expect(
        await service.activeProfileId(TrackingProvider.kitsu),
        renamed?.id,
      );
      expect(
        await storage.read(
          key: _profileCredentialKeyForTest(
            TrackingProvider.kitsu,
            legacy!.id,
            'access',
          ),
        ),
        isNull,
      );
    },
  );

  for (final provider in const [
    TrackingProvider.myAnimeList,
    TrackingProvider.kitsu,
  ]) {
    test(
      '${provider.slug} profile activation is journaled and ordered',
      () async {
        final activationStorage = FailureInjectingSecureStorage();
        final accounts = await _seedRotatingProfiles(
          activationStorage,
          provider,
          now,
        );
        activationStorage.mutations.clear();

        await accounts.service.activateProfile(accounts.alice);

        expect(activationStorage.mutations.take(7), [
          'write:${_credentialJournalKeyForTest(provider)}',
          'delete:${provider.tokenStorageKey}',
          'write:${provider.refreshTokenStorageKey}',
          'write:${provider.expiresAtStorageKey}',
          'write:${_activeProfileKeyForTest(provider)}',
          'write:${provider.tokenStorageKey}',
          'delete:${_credentialJournalKeyForTest(provider)}',
        ]);
        expect(
          await accounts.service.verifiedActiveProfileId(
            provider,
            'alice-access',
          ),
          accounts.alice.id,
        );
      },
    );

    for (final failure in const [
      'journal-write',
      'access-delete',
      'refresh-write',
      'expiry-write',
      'active-write',
      'access-write',
    ]) {
      test('${provider.slug} activation rolls back $failure failure', () async {
        final activationStorage = FailureInjectingSecureStorage();
        final accounts = await _seedRotatingProfiles(
          activationStorage,
          provider,
          now,
        );
        switch (failure) {
          case 'journal-write':
            activationStorage.failNextWrite(
              _credentialJournalKeyForTest(provider),
            );
            break;
          case 'access-delete':
            activationStorage.failNextDelete(provider.tokenStorageKey);
            break;
          case 'refresh-write':
            activationStorage.failNextWrite(provider.refreshTokenStorageKey);
            break;
          case 'expiry-write':
            activationStorage.failNextWrite(provider.expiresAtStorageKey);
            break;
          case 'active-write':
            activationStorage.failNextWrite(_activeProfileKeyForTest(provider));
            break;
          case 'access-write':
            activationStorage.failNextWrite(provider.tokenStorageKey);
            break;
        }

        await expectLater(
          accounts.service.activateProfile(accounts.alice),
          throwsA(isA<StateError>()),
        );
        expect(
          activationStorage.values[provider.tokenStorageKey],
          'bob-access',
        );
        expect(
          activationStorage.values[provider.refreshTokenStorageKey],
          'bob-refresh',
        );
        expect(
          activationStorage.values[provider.expiresAtStorageKey],
          now.add(const Duration(days: 20)).toIso8601String(),
        );
        expect(
          activationStorage.values[_activeProfileKeyForTest(provider)],
          accounts.bob.id,
        );
        expect(
          activationStorage.values[_credentialJournalKeyForTest(provider)],
          isNull,
        );
      });
    }

    for (final prefix in const ['before marker', 'after marker']) {
      test('${provider.slug} startup recovers activation $prefix', () async {
        final activationStorage = FailureInjectingSecureStorage();
        final accounts = await _seedRotatingProfiles(
          activationStorage,
          provider,
          now,
        );
        activationStorage.values.remove(provider.tokenStorageKey);
        activationStorage.values[provider.refreshTokenStorageKey] =
            'alice-refresh';
        activationStorage.values[provider.expiresAtStorageKey] = now
            .add(const Duration(days: 10))
            .toIso8601String();
        activationStorage.values[_activeProfileKeyForTest(provider)] =
            prefix == 'after marker' ? accounts.alice.id : accounts.bob.id;
        activationStorage.values[_credentialJournalKeyForTest(provider)] =
            _activationJournalForTest(accounts.alice.id);

        expect(await accounts.service.accessToken(provider), 'alice-access');
        expect(
          await accounts.service.verifiedActiveProfileId(
            provider,
            'alice-access',
          ),
          accounts.alice.id,
        );
        expect(
          activationStorage.values[_credentialJournalKeyForTest(provider)],
          isNull,
        );
      });
    }

    test(
      '${provider.slug} startup finishes an interrupted disconnect',
      () async {
        final clearStorage = FailureInjectingSecureStorage();
        final accounts = await _seedRotatingProfiles(
          clearStorage,
          provider,
          now,
        );

        // Process-kill prefix: the disconnect tombstone and access deletion are
        // durable, while the active marker and encrypted profile slots remain.
        clearStorage.values[_credentialJournalKeyForTest(provider)] =
            _clearJournalForTest();
        clearStorage.values.remove(provider.tokenStorageKey);

        expect(await accounts.service.accessToken(provider), isNull);
        expect(await accounts.service.activeProfileId(provider), isNull);
        expect(
          (await accounts.service.savedProfiles()).where(
            (profile) => profile.provider == provider,
          ),
          isEmpty,
        );
        expect(
          clearStorage.values[_profileCredentialKeyForTest(
            provider,
            accounts.alice.id,
            'access',
          )],
          isNull,
        );
        expect(
          clearStorage.values[_profileCredentialKeyForTest(
            provider,
            accounts.bob.id,
            'access',
          )],
          isNull,
        );
        expect(
          clearStorage.values[_credentialJournalKeyForTest(provider)],
          isNull,
        );
      },
    );

    test(
      '${provider.slug} unjournaled missing access never restores a profile',
      () async {
        final legacyStorage = FailureInjectingSecureStorage();
        final accounts = await _seedRotatingProfiles(
          legacyStorage,
          provider,
          now,
        );
        legacyStorage.values.remove(provider.tokenStorageKey);

        expect(await accounts.service.accessToken(provider), isNull);
        expect(
          legacyStorage.values[_activeProfileKeyForTest(provider)],
          accounts.bob.id,
        );
        expect(
          legacyStorage.values[_profileCredentialKeyForTest(
            provider,
            accounts.bob.id,
            'access',
          )],
          'bob-access',
        );
        expect(legacyStorage.values[provider.tokenStorageKey], isNull);
      },
    );
  }

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
  _FakePairingClient(
    this._refresh, {
    TrackingProvider provider = TrackingProvider.myAnimeList,
  }) : super(provider, baseUrl: 'https://auth.example.test');

  final Future<TrackingTokenSet> Function() _refresh;
  int refreshCalls = 0;
  String? lastRefreshToken;

  @override
  Future<TrackingTokenSet> refresh(String refreshToken) {
    refreshCalls++;
    lastRefreshToken = refreshToken;
    return _refresh();
  }
}

Future<
  ({
    TrackingTokenService service,
    StoredTrackingProfile alice,
    StoredTrackingProfile bob,
  })
>
_seedRotatingProfiles(
  FailureInjectingSecureStorage storage,
  TrackingProvider provider,
  DateTime now,
) async {
  final service = TrackingTokenService(storage, now: () => now);
  await service.saveTokenSet(
    provider,
    accessToken: 'alice-access',
    refreshToken: 'alice-refresh',
    expiresAt: now.add(const Duration(days: 10)),
  );
  final alice = (await service.rememberCurrentProfile(provider, 'Alice'))!;
  await service.saveTokenSet(
    provider,
    accessToken: 'bob-access',
    refreshToken: 'bob-refresh',
    expiresAt: now.add(const Duration(days: 20)),
  );
  final bob = (await service.rememberCurrentProfile(provider, 'Bob'))!;
  return (service: service, alice: alice, bob: bob);
}

String _profileCredentialKeyForTest(
  TrackingProvider provider,
  String profileId,
  String suffix,
) => 'tracking_profile_${provider.slug}_${profileId}_$suffix';

String _activeProfileKeyForTest(TrackingProvider provider) =>
    'tracking_profile_${provider.slug}_active';

String _credentialJournalKeyForTest(TrackingProvider provider) =>
    'tracking_credentials_${provider.slug}_journal_v1';

String _refreshJournalForTest(String profileId) =>
    jsonEncode({'version': 1, 'operation': 'refresh', 'profile_id': profileId});

String _activationJournalForTest(String profileId) => jsonEncode({
  'version': 1,
  'operation': 'activation',
  'profile_id': profileId,
});

String _clearJournalForTest() =>
    jsonEncode({'version': 1, 'operation': 'clear', 'profile_id': null});
