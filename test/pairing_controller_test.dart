import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/data/anilist_pairing_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/failure_injecting_secure_storage.dart';

void main() {
  const storage = FlutterSecureStorage();

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('normalizes a secure broker origin', () {
    expect(
      normalizeAuthBrokerBaseUrl('  https://auth.example.com/  '),
      'https://auth.example.com',
    );
    expect(
      normalizeAuthBrokerBaseUrl('https://auth.example.com/tetotv/'),
      'https://auth.example.com/tetotv',
    );
  });

  test('rejects unsafe or ambiguous broker URLs', () {
    expect(normalizeAuthBrokerBaseUrl('http://auth.example.com'), isNull);
    expect(normalizeAuthBrokerBaseUrl('https://user@auth.example.com'), isNull);
    expect(normalizeAuthBrokerBaseUrl('https://auth.example.com/?x=1'), isNull);
    expect(normalizeAuthBrokerBaseUrl('not a URL'), isNull);
  });

  test(
    'migrates the retired production override to the Wispbyte broker',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        authBrokerUrlStorageKey: Uri(
          scheme: 'https',
          host: [
            'tetotv-auth',
            String.fromCharCodes([111, 110, 114, 101, 110, 100, 101, 114]),
            'com',
          ].join('.'),
        ).toString(),
      });

      final effective = await effectiveAuthBrokerBaseUrl(storage);

      expect(effective, 'https://tetotv-bot.wisp.uno');
      expect(
        await storage.read(key: authBrokerUrlStorageKey),
        'https://tetotv-bot.wisp.uno',
      );
    },
  );

  test('preserves an explicit non-retired HTTPS broker override', () async {
    FlutterSecureStorage.setMockInitialValues({
      authBrokerUrlStorageKey: 'https://auth.example.com/',
    });

    expect(
      await effectiveAuthBrokerBaseUrl(storage),
      'https://auth.example.com',
    );
  });

  test(
    'rate-limited creation blocks repeat sessions and records safe metadata',
    () async {
      var clock = DateTime.utc(2026, 9, 12, 12);
      final events = <Map<String, Object?>>[];
      final client =
          _FakePairingSessionClient(
              provider: TrackingProvider.anilist,
              now: clock,
              pollResult: const PairingPollResult(
                status: PairingStatus.pending,
              ),
            )
            ..createError = TrackingPairingServiceException(
              reasonCode: 'rate_limited',
              message:
                  'The pairing service is temporarily rate-limited. Wait before trying again.',
              httpStatus: 429,
              retryAfter: const Duration(seconds: 30),
            );
      final controller = PairingController(
        TrackingProvider.anilist,
        storage,
        tokenService: TrackingTokenService(storage, now: () => clock),
        clientFactory: (_, {required baseUrl}) => client,
        now: () => clock,
        diagnosticRecorder: (details) async => events.add(details),
      );
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.state.hasError, isTrue);
      expect(client.createCalls, 1);
      expect(events.single, containsPair('stage', 'session_create'));
      expect(events.single, containsPair('reason_code', 'rate_limited'));
      expect(events.single, containsPair('code', 429));
      expect(events.single, containsPair('retry_after_seconds', 30));

      await controller.start();
      expect(client.createCalls, 1);

      clock = clock.add(const Duration(seconds: 31));
      client.createError = null;
      await controller.start();
      expect(client.createCalls, 2);
      expect(controller.state.valueOrNull?.status, PairingStatus.pending);
    },
  );

  test(
    'polling rate limit stays pending and records the deferred backoff',
    () async {
      final clock = DateTime.utc(2026, 9, 12, 12);
      final events = <Map<String, Object?>>[];
      final client = _FakePairingSessionClient(
        provider: TrackingProvider.anilist,
        now: clock,
        pollResult: const PairingPollResult(
          status: PairingStatus.pending,
          retryAfter: Duration(seconds: 42),
          diagnosticReason: 'rate_limited',
        ),
      );
      final controller = PairingController(
        TrackingProvider.anilist,
        storage,
        tokenService: TrackingTokenService(storage, now: () => clock),
        clientFactory: (_, {required baseUrl}) => client,
        now: () => clock,
        diagnosticRecorder: (details) async => events.add(details),
      );
      addTearDown(controller.dispose);

      await controller.start();
      await controller.pollNow();

      expect(controller.state.hasError, isFalse);
      expect(controller.state.valueOrNull?.status, PairingStatus.pending);
      expect(events.single, containsPair('stage', 'poll'));
      expect(events.single, containsPair('reason_code', 'rate_limited'));
      expect(events.single, containsPair('retry_after_seconds', 42));
    },
  );

  final now = DateTime.utc(2026, 9, 12, 12);

  for (final invalid
      in <({String label, String? refreshToken, DateTime? expiresAt})>[
        (
          label: 'missing refresh token',
          refreshToken: null,
          expiresAt: now.add(const Duration(days: 30)),
        ),
        (
          label: 'blank refresh token',
          refreshToken: '  ',
          expiresAt: now.add(const Duration(days: 30)),
        ),
        (label: 'missing expiry', refreshToken: 'refresh', expiresAt: null),
        (label: 'non-future expiry', refreshToken: 'refresh', expiresAt: now),
        (
          label: 'unreasonably distant expiry',
          refreshToken: 'refresh',
          expiresAt: now.add(const Duration(days: 3651)),
        ),
      ]) {
    test('Kitsu pairing rejects ${invalid.label} without mutation', () async {
      final oldExpiry = now.add(const Duration(days: 5)).toIso8601String();
      final pairingStorage = FailureInjectingSecureStorage({
        authBrokerUrlStorageKey: 'https://auth.example.test',
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry,
        _activeProfileKey(TrackingProvider.kitsu): 'old-profile',
      });
      final client = _FakePairingSessionClient(
        provider: TrackingProvider.kitsu,
        now: now,
        pollResult: PairingPollResult(
          status: PairingStatus.authorized,
          accessToken: 'new-access',
          refreshToken: invalid.refreshToken,
          expiresAt: invalid.expiresAt,
        ),
      );
      final controller = _controller(
        TrackingProvider.kitsu,
        pairingStorage,
        client,
        now,
      );
      addTearDown(controller.dispose);

      await controller.start();
      pairingStorage.mutations.clear();
      await controller.pollNow();

      expect(controller.state.asData?.value?.status, PairingStatus.pending);
      expect(pairingStorage.mutations, isEmpty);
      expect(
        pairingStorage.values[TrackingProvider.kitsu.tokenStorageKey],
        'old-access',
      );
      expect(
        pairingStorage.values[TrackingProvider.kitsu.refreshTokenStorageKey],
        'old-refresh',
      );
      expect(
        pairingStorage.values[TrackingProvider.kitsu.expiresAtStorageKey],
        oldExpiry,
      );
      expect(
        pairingStorage.values[_activeProfileKey(TrackingProvider.kitsu)],
        'old-profile',
      );
    });
  }

  test(
    'Kitsu pairing stores a complete set and clears stale profile',
    () async {
      final oldExpiry = now.add(const Duration(days: 5)).toIso8601String();
      final nextExpiry = now.add(const Duration(days: 30));
      final pairingStorage = FailureInjectingSecureStorage({
        authBrokerUrlStorageKey: 'https://auth.example.test',
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry,
        _activeProfileKey(TrackingProvider.kitsu): 'old-profile',
      });
      final client = _FakePairingSessionClient(
        provider: TrackingProvider.kitsu,
        now: now,
        pollResult: PairingPollResult(
          status: PairingStatus.authorized,
          accessToken: '  new-access  ',
          refreshToken: '  new-refresh  ',
          expiresAt: nextExpiry,
        ),
      );
      final controller = _controller(
        TrackingProvider.kitsu,
        pairingStorage,
        client,
        now,
      );
      addTearDown(controller.dispose);

      await controller.start();
      await controller.pollNow();

      expect(controller.state.asData?.value?.status, PairingStatus.authorized);
      expect(
        pairingStorage.values[TrackingProvider.kitsu.tokenStorageKey],
        'new-access',
      );
      expect(
        pairingStorage.values[TrackingProvider.kitsu.refreshTokenStorageKey],
        'new-refresh',
      );
      expect(
        pairingStorage.values[TrackingProvider.kitsu.expiresAtStorageKey],
        nextExpiry.toIso8601String(),
      );
      expect(
        pairingStorage.values[_activeProfileKey(TrackingProvider.kitsu)],
        isNull,
      );
      expect(client.acknowledgeCalls, 1);
    },
  );

  test(
    'Kitsu pairing rolls back the old credential set on write failure',
    () async {
      final oldExpiry = now.add(const Duration(days: 5)).toIso8601String();
      final pairingStorage = FailureInjectingSecureStorage({
        authBrokerUrlStorageKey: 'https://auth.example.test',
        TrackingProvider.kitsu.tokenStorageKey: 'old-access',
        TrackingProvider.kitsu.refreshTokenStorageKey: 'old-refresh',
        TrackingProvider.kitsu.expiresAtStorageKey: oldExpiry,
        _activeProfileKey(TrackingProvider.kitsu): 'old-profile',
      });
      final client = _FakePairingSessionClient(
        provider: TrackingProvider.kitsu,
        now: now,
        pollResult: PairingPollResult(
          status: PairingStatus.authorized,
          accessToken: 'new-access',
          refreshToken: 'new-refresh',
          expiresAt: now.add(const Duration(days: 30)),
        ),
      );
      final controller = _controller(
        TrackingProvider.kitsu,
        pairingStorage,
        client,
        now,
      );
      addTearDown(controller.dispose);

      await controller.start();
      pairingStorage.failNextWrite(TrackingProvider.kitsu.tokenStorageKey);
      await controller.pollNow();

      expect(controller.state.asData?.value?.status, PairingStatus.pending);
      expect(
        pairingStorage.values[TrackingProvider.kitsu.tokenStorageKey],
        'old-access',
      );
      expect(
        pairingStorage.values[TrackingProvider.kitsu.refreshTokenStorageKey],
        'old-refresh',
      );
      expect(
        pairingStorage.values[TrackingProvider.kitsu.expiresAtStorageKey],
        oldExpiry,
      );
      expect(
        pairingStorage.values[_activeProfileKey(TrackingProvider.kitsu)],
        'old-profile',
      );
      expect(client.acknowledgeCalls, 0);
    },
  );

  test(
    'MAL pairing remains compatible with access-token-only responses',
    () async {
      final pairingStorage = FailureInjectingSecureStorage({
        authBrokerUrlStorageKey: 'https://auth.example.test',
        TrackingProvider.myAnimeList.refreshTokenStorageKey: 'stale-refresh',
        TrackingProvider.myAnimeList.expiresAtStorageKey: now
            .add(const Duration(days: 5))
            .toIso8601String(),
        _activeProfileKey(TrackingProvider.myAnimeList): 'stale-profile',
      });
      final client = _FakePairingSessionClient(
        provider: TrackingProvider.myAnimeList,
        now: now,
        pollResult: const PairingPollResult(
          status: PairingStatus.authorized,
          accessToken: 'manual-mal-access',
        ),
      );
      final controller = _controller(
        TrackingProvider.myAnimeList,
        pairingStorage,
        client,
        now,
      );
      addTearDown(controller.dispose);

      await controller.start();
      await controller.pollNow();

      expect(controller.state.asData?.value?.status, PairingStatus.authorized);
      expect(
        pairingStorage.values[TrackingProvider.myAnimeList.tokenStorageKey],
        'manual-mal-access',
      );
      expect(
        pairingStorage.values[TrackingProvider
            .myAnimeList
            .refreshTokenStorageKey],
        isNull,
      );
      expect(
        pairingStorage.values[TrackingProvider.myAnimeList.expiresAtStorageKey],
        isNull,
      );
      expect(
        pairingStorage.values[_activeProfileKey(TrackingProvider.myAnimeList)],
        isNull,
      );
    },
  );
}

PairingController _controller(
  TrackingProvider provider,
  FailureInjectingSecureStorage storage,
  TrackingPairingClient client,
  DateTime now,
) => PairingController(
  provider,
  storage,
  tokenService: TrackingTokenService(storage, now: () => now),
  clientFactory: (_, {required baseUrl}) => client,
  now: () => now,
);

String _activeProfileKey(TrackingProvider provider) =>
    'tracking_profile_${provider.slug}_active';

class _FakePairingSessionClient extends TrackingPairingClient {
  _FakePairingSessionClient({
    required TrackingProvider provider,
    required DateTime now,
    required this.pollResult,
  }) : _session = PairingSession(
         pairingId: 'pairing-id',
         deviceCode: 'device-code',
         userCode: 'USER-CODE',
         verificationUri: 'https://auth.example.test/pair',
         verificationUriComplete:
             'https://auth.example.test/pair?code=USER-CODE',
         expiresAt: now.add(const Duration(hours: 1)),
         pollInterval: const Duration(hours: 1),
       ),
       super(provider, baseUrl: 'https://auth.example.test');

  final PairingSession _session;
  PairingPollResult pollResult;
  Object? createError;
  int createCalls = 0;
  int acknowledgeCalls = 0;

  @override
  Future<void> ensureReady() async {}

  @override
  Future<PairingSession> createSession() async {
    createCalls++;
    if (createError case final error?) throw error;
    return _session;
  }

  @override
  Future<PairingPollResult> poll(PairingSession session) async => pollResult;

  @override
  Future<void> acknowledge(PairingSession session) async {
    acknowledgeCalls++;
  }
}
