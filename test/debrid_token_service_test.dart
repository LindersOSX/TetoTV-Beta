import 'dart:async';

import 'package:anime_tv/features/auth/data/real_debrid_oauth_client.dart';
import 'package:anime_tv/features/settings/application/real_debrid_settings_controller.dart';
import 'package:anime_tv/features/streaming/application/debrid_token_service.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const storage = FlutterSecureStorage();
  final now = DateTime.utc(2026, 8, 2, 18);

  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test('returns a current Real-Debrid token without refreshing', () async {
    FlutterSecureStorage.setMockInitialValues({
      realDebridTokenStorageKey: 'current-token',
      realDebridAccessExpiryStorageKey: now
          .add(const Duration(hours: 1))
          .toIso8601String(),
    });
    final oauth = _FakeRealDebridOAuthClient();
    final service = DebridTokenService(
      storage,
      realDebridOAuthClient: oauth,
      now: () => now,
    );

    expect(
      await service.accessToken(DebridService.realDebrid),
      'current-token',
    );
    expect(oauth.refreshCalls, 0);
  });

  test('refreshes an expired Real-Debrid token only once', () async {
    FlutterSecureStorage.setMockInitialValues({
      realDebridTokenStorageKey: 'expired-token',
      realDebridRefreshTokenStorageKey: 'refresh-token',
      realDebridClientIdStorageKey: 'client-id',
      realDebridClientSecretStorageKey: 'client-secret',
      realDebridAccessExpiryStorageKey: now
          .subtract(const Duration(minutes: 1))
          .toIso8601String(),
    });
    final refreshStarted = Completer<void>();
    final finishRefresh = Completer<void>();
    final oauth = _FakeRealDebridOAuthClient(
      onRefresh: () async {
        refreshStarted.complete();
        await finishRefresh.future;
        return RealDebridTokenSet(
          accessToken: 'new-token',
          refreshToken: 'rotated-refresh-token',
          expiresAt: now.add(const Duration(hours: 1)),
        );
      },
    );
    final service = DebridTokenService(
      storage,
      realDebridOAuthClient: oauth,
      now: () => now,
    );

    final first = service.accessToken(DebridService.realDebrid);
    final second = service.accessToken(DebridService.realDebrid);
    await refreshStarted.future;
    expect(oauth.refreshCalls, 1);
    finishRefresh.complete();

    expect(await Future.wait([first, second]), ['new-token', 'new-token']);
    expect(await storage.read(key: realDebridTokenStorageKey), 'new-token');
    expect(
      await storage.read(key: realDebridRefreshTokenStorageKey),
      'rotated-refresh-token',
    );
  });

  test('reports an expired authorization that cannot be refreshed', () async {
    FlutterSecureStorage.setMockInitialValues({
      realDebridTokenStorageKey: 'expired-token',
      realDebridAccessExpiryStorageKey: now
          .subtract(const Duration(minutes: 1))
          .toIso8601String(),
    });
    final service = DebridTokenService(storage, now: () => now);

    await expectLater(
      service.accessToken(DebridService.realDebrid),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Reconnect Real-Debrid'),
        ),
      ),
    );
  });

  test('returns a TorBox API token without Real-Debrid OAuth work', () async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.torBox.tokenStorageKey: 'torbox-token',
    });
    final oauth = _FakeRealDebridOAuthClient();
    final service = DebridTokenService(
      storage,
      realDebridOAuthClient: oauth,
      now: () => now,
    );

    expect(await service.accessToken(DebridService.torBox), 'torbox-token');
    expect(oauth.refreshCalls, 0);
  });

  test('returns AllDebrid and Premiumize keys directly', () async {
    FlutterSecureStorage.setMockInitialValues({
      DebridService.allDebrid.tokenStorageKey: 'all-debrid-key',
      DebridService.premiumize.tokenStorageKey: 'premiumize-key',
    });
    final oauth = _FakeRealDebridOAuthClient();
    final service = DebridTokenService(
      storage,
      realDebridOAuthClient: oauth,
      now: () => now,
    );

    expect(
      await service.accessToken(DebridService.allDebrid),
      'all-debrid-key',
    );
    expect(
      await service.accessToken(DebridService.premiumize),
      'premiumize-key',
    );
    expect(oauth.refreshCalls, 0);
  });
}

class _FakeRealDebridOAuthClient extends RealDebridOAuthClient {
  _FakeRealDebridOAuthClient({this.onRefresh});

  final Future<RealDebridTokenSet> Function()? onRefresh;
  int refreshCalls = 0;

  @override
  Future<RealDebridTokenSet> refresh({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
  }) async {
    refreshCalls++;
    final handler = onRefresh;
    if (handler == null) {
      throw StateError('Unexpected refresh');
    }
    return handler();
  }
}
