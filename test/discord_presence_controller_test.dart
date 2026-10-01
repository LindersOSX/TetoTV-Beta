import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/discord/domain/discord_minimum_age_confirmation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/failure_injecting_secure_storage.dart';

void main() {
  const storage = FlutterSecureStorage();
  const confirmation = DiscordMinimumAgeConfirmation.current();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'fresh installs remain unlinked and never connect automatically',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);

      await _settle();

      expect(controller.state.loaded, isTrue);
      expect(controller.state.available, isTrue);
      expect(controller.state.linked, isFalse);
      expect(controller.state.enabled, isFalse);
      expect(platform.connectCalls, 0);
      expect(platform.authenticateCalls, 0);
    },
  );

  test(
    'link stores tokens securely and connects the opted-in account',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      await controller.linkAccount(confirmation);

      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.connected, isTrue);
      expect(platform.authenticateCalls, 1);
      expect(platform.connectCalls, 1);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'access-token',
      );
      expect(
        await storage.read(key: 'discord_rich_presence_refresh_token'),
        'refresh-token',
      );
      expect(
        await storage.read(
          key: 'discord_rich_presence_minimum_age_confirmation_v1',
        ),
        '{"version":1,"confirmed":true}',
      );
    },
  );

  test('new Discord links reject an unaccepted eligibility marker', () async {
    const rejected = DiscordMinimumAgeConfirmation(
      version: 1,
      confirmed: false,
    );
    final platform = _FakeDiscordPlatform();
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();

    await expectLater(
      controller.linkAccount(rejected),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      controller.acceptLinkedToken(platform.deviceToken, rejected),
      throwsA(isA<StateError>()),
    );

    expect(platform.authenticateCalls, 0);
    expect(platform.connectCalls, 0);
    expect(
      await storage.read(key: 'discord_rich_presence_access_token'),
      isNull,
    );
    expect(
      await storage.read(
        key: 'discord_rich_presence_minimum_age_confirmation_v1',
      ),
      isNull,
    );
  });

  test('concurrent link requests start authentication only once', () async {
    final platform = _FakeDiscordPlatform();
    final authentication = Completer<DiscordTokenBundle>();
    platform.authenticationCompleter = authentication;
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();

    final firstLink = controller.linkAccount(confirmation);
    final secondLink = controller.linkAccount(confirmation);

    expect(controller.state.busy, isTrue);
    expect(platform.authenticateCalls, 1);

    authentication.complete(platform.token);
    await Future.wait([firstLink, secondLink]);

    expect(platform.authenticateCalls, 1);
    expect(platform.connectCalls, 1);
    expect(controller.state.linked, isTrue);
    expect(controller.state.busy, isFalse);
  });

  test('failed authentication clears busy state and stores nothing', () async {
    final platform = _FakeDiscordPlatform()
      ..authenticationError = StateError('authorization canceled');
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();

    await controller.linkAccount(confirmation);

    expect(platform.authenticateCalls, 1);
    expect(platform.connectCalls, 0);
    expect(controller.state.busy, isFalse);
    expect(controller.state.linked, isFalse);
    expect(controller.state.enabled, isFalse);
    expect(controller.state.error, contains('authorization canceled'));
    expect(await storage.read(key: 'discord_rich_presence_enabled'), isNull);
    expect(
      await storage.read(key: 'discord_rich_presence_access_token'),
      isNull,
    );
    expect(
      await storage.read(key: 'discord_rich_presence_refresh_token'),
      isNull,
    );
    expect(
      await storage.read(
        key: 'discord_rich_presence_minimum_age_confirmation_v1',
      ),
      isNull,
    );
  });

  test(
    'stalled authentication times out, cancels native flow, and can retry',
    () async {
      final stalledAuthentication = Completer<DiscordTokenBundle>();
      final platform = _FakeDiscordPlatform()
        ..authenticationCompleter = stalledAuthentication;
      final controller = DiscordPresenceController(
        storage,
        platform,
        authenticationTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);
      await _settle();

      await controller.linkAccount(confirmation);

      expect(platform.authenticateCalls, 1);
      expect(platform.cancelAuthenticationCalls, 1);
      expect(controller.state.busy, isFalse);
      expect(controller.state.linked, isFalse);
      expect(controller.state.error, contains('timed out'));
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        isNull,
      );
      expect(await storage.read(key: 'discord_rich_presence_enabled'), isNull);

      final retryAuthentication = Completer<DiscordTokenBundle>();
      platform.authenticationCompleter = retryAuthentication;
      final retry = controller.linkAccount(confirmation);

      expect(platform.authenticateCalls, 2);
      expect(controller.state.busy, isTrue);

      stalledAuthentication.complete(platform.tokenWithAccess('stale-access'));
      await Future<void>.delayed(Duration.zero);

      expect(platform.connectCalls, 0);
      expect(controller.state.linked, isFalse);
      expect(controller.state.busy, isTrue);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        isNull,
      );
      expect(await storage.read(key: 'discord_rich_presence_enabled'), isNull);

      retryAuthentication.complete(platform.tokenWithAccess('new-access'));
      await retry;

      expect(platform.authenticateCalls, 2);
      expect(platform.cancelAuthenticationCalls, 1);
      expect(platform.connectCalls, 1);
      expect(platform.lastConnected?.accessToken, 'new-access');
      expect(controller.state.linked, isTrue);
      expect(controller.state.connected, isTrue);
      expect(controller.state.busy, isFalse);
      expect(controller.state.error, isNull);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'new-access',
      );
      expect(await storage.read(key: 'discord_rich_presence_enabled'), 'true');
    },
  );

  test(
    'disposing during authentication cancels native flow and ignores completion',
    () async {
      final authentication = Completer<DiscordTokenBundle>();
      final platform = _FakeDiscordPlatform()
        ..authenticationCompleter = authentication;
      final controller = DiscordPresenceController(
        storage,
        platform,
        authenticationTimeout: const Duration(milliseconds: 10),
      );
      await _settle();

      final linking = controller.linkAccount(confirmation);
      expect(controller.state.busy, isTrue);
      expect(platform.authenticateCalls, 1);

      controller.dispose();
      await linking;
      await _settle();

      expect(platform.cancelAuthenticationCalls, 1);

      authentication.complete(platform.token);
      await _settle();

      expect(platform.cancelAuthenticationCalls, 1);
      expect(platform.connectCalls, 0);
      expect(await storage.read(key: 'discord_rich_presence_enabled'), isNull);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        isNull,
      );

      await controller.linkAccount(confirmation);
      expect(platform.authenticateCalls, 1);
    },
  );

  test(
    'connect failure retains the linked token and retry does not reauthenticate',
    () async {
      final platform = _FakeDiscordPlatform()..connectFailuresRemaining = 1;
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      await controller.linkAccount(confirmation);

      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.busy, isFalse);
      expect(controller.state.connected, isFalse);
      expect(controller.state.error, contains('connection failed'));
      expect(platform.authenticateCalls, 1);
      expect(platform.connectCalls, 1);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'access-token',
      );

      await controller.retry();

      expect(platform.authenticateCalls, 1);
      expect(platform.refreshCalls, 1);
      expect(platform.connectCalls, 2);
      expect(controller.state.connected, isTrue);
      expect(controller.state.busy, isFalse);
    },
  );

  test(
    'disable stops presence without unlinking and enable reconnects',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();
      await controller.linkAccount(confirmation);

      await controller.setEnabled(false);
      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isFalse);
      expect(platform.disconnectCalls, 1);

      await controller.setEnabled(true);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.connected, isTrue);
      expect(platform.connectCalls, 2);
    },
  );

  test('unlink revokes and deletes every saved Discord credential', () async {
    final platform = _FakeDiscordPlatform();
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();
    await controller.linkAccount(confirmation);

    await controller.unlinkAccount();

    expect(platform.revokeCalls, 1);
    expect(controller.state.linked, isFalse);
    expect(controller.state.enabled, isFalse);
    expect(
      await storage.read(key: 'discord_rich_presence_access_token'),
      isNull,
    );
    expect(
      await storage.read(key: 'discord_rich_presence_refresh_token'),
      isNull,
    );
  });

  test('expired restored tokens refresh before connecting', () async {
    FlutterSecureStorage.setMockInitialValues({
      'discord_rich_presence_enabled': 'true',
      'discord_rich_presence_access_token': 'old-access',
      'discord_rich_presence_refresh_token': 'old-refresh',
      'discord_rich_presence_token_type': '0',
      'discord_rich_presence_expires_at': DateTime.now()
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch
          .toString(),
      'discord_rich_presence_scopes': 'presence',
    });
    final platform = _FakeDiscordPlatform();
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);

    await _settle();

    expect(platform.refreshCalls, 1);
    expect(platform.connectCalls, 1);
    expect(platform.lastConnected?.accessToken, 'access-token');
    expect(controller.state.connected, isTrue);
    expect(
      await storage.read(
        key: 'discord_rich_presence_minimum_age_confirmation_v1',
      ),
      isNull,
      reason: 'legacy linked sessions must keep reconnecting without migration',
    );

    await controller.setEnabled(false);
    await controller.setEnabled(true);
    expect(platform.authenticateCalls, 0);
    expect(controller.state.connected, isTrue);
  });

  test(
    'device flow stores a bearer token and connects without native auth',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      await controller.acceptLinkedToken(platform.deviceToken, confirmation);

      expect(platform.authenticateCalls, 0);
      expect(platform.connectCalls, 1);
      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.connected, isTrue);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        platform.deviceToken.accessToken,
      );
      expect(await storage.read(key: 'discord_rich_presence_token_type'), '1');
    },
  );

  test('secure setup imports Discord before the SDK is ready', () async {
    final platform = _FakeDiscordPlatform()..available = false;
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();

    await controller.importLinkedToken(platform.deviceToken, confirmation);

    expect(controller.state.linked, isTrue);
    expect(controller.state.enabled, isTrue);
    expect(platform.connectCalls, 0);
    expect(
      await storage.read(key: 'discord_rich_presence_access_token'),
      platform.deviceToken.accessToken,
    );
  });

  test(
    'secure setup will not snapshot an in-flight Discord operation',
    () async {
      final authentication = Completer<DiscordTokenBundle>();
      final platform = _FakeDiscordPlatform()
        ..authenticationCompleter = authentication;
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      final linking = controller.linkAccount(confirmation);
      await _settle();
      expect(controller.state.busy, isTrue);
      await expectLater(
        controller.snapshotForImport(),
        throwsA(isA<StateError>()),
      );

      authentication.complete(platform.token);
      await linking;
      expect(controller.state.busy, isFalse);
    },
  );

  test(
    'secure setup rollback restores the prior connected Discord session',
    () async {
      final oldExpiry = DateTime.now()
          .add(const Duration(days: 7))
          .millisecondsSinceEpoch
          .toString();
      FlutterSecureStorage.setMockInitialValues({
        'discord_rich_presence_enabled': 'true',
        'discord_rich_presence_access_token': 'old-access',
        'discord_rich_presence_refresh_token': 'old-refresh',
        'discord_rich_presence_token_type': '1',
        'discord_rich_presence_expires_at': oldExpiry,
        'discord_rich_presence_scopes': 'openid sdk.social_layer_presence',
      });
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();
      expect(controller.state.connected, isTrue);

      final snapshot = await controller.snapshotForImport();
      await controller.importLinkedToken(
        platform.deviceToken,
        confirmation,
        connectAfterStore: false,
      );
      await controller.restoreImportSnapshot(snapshot);

      expect(platform.disconnectCalls, 1);
      expect(platform.connectCalls, 2);
      expect(platform.lastConnected?.accessToken, 'old-access');
      expect(controller.state.connected, isTrue);
      expect(controller.state.busy, isFalse);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'old-access',
      );
    },
  );

  test(
    'secure setup rollback reports a failed native Discord reconnection',
    () async {
      final oldExpiry = DateTime.now()
          .add(const Duration(days: 7))
          .millisecondsSinceEpoch
          .toString();
      FlutterSecureStorage.setMockInitialValues({
        'discord_rich_presence_enabled': 'true',
        'discord_rich_presence_access_token': 'old-access',
        'discord_rich_presence_refresh_token': 'old-refresh',
        'discord_rich_presence_token_type': '1',
        'discord_rich_presence_expires_at': oldExpiry,
        'discord_rich_presence_scopes': 'openid sdk.social_layer_presence',
      });
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();
      final snapshot = await controller.snapshotForImport();
      await controller.importLinkedToken(
        platform.deviceToken,
        confirmation,
        connectAfterStore: false,
      );
      platform.connectFailuresRemaining = 1;

      await controller.restoreImportSnapshot(snapshot);

      expect(controller.state.connected, isFalse);
      expect(controller.state.busy, isFalse);
      expect(controller.state.error, contains('Use Retry'));
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'old-access',
      );
    },
  );

  test(
    'failed secure setup write restores the previous Discord authorization',
    () async {
      final oldExpiry = DateTime.utc(
        2026,
        9,
        1,
      ).millisecondsSinceEpoch.toString();
      final failingStorage = FailureInjectingSecureStorage({
        'discord_rich_presence_enabled': 'true',
        'discord_rich_presence_access_token': 'old-access',
        'discord_rich_presence_refresh_token': 'old-refresh',
        'discord_rich_presence_token_type': '1',
        'discord_rich_presence_expires_at': oldExpiry,
        'discord_rich_presence_scopes': 'openid sdk.social_layer_presence',
      });
      final platform = _FakeDiscordPlatform()..available = false;
      final controller = DiscordPresenceController(failingStorage, platform);
      addTearDown(controller.dispose);
      await _settle();
      failingStorage.failNextWrite(
        'discord_rich_presence_minimum_age_confirmation_v1',
      );

      await expectLater(
        controller.importLinkedToken(platform.deviceToken, confirmation),
        throwsA(isA<StateError>()),
      );

      expect(
        failingStorage.values['discord_rich_presence_access_token'],
        'old-access',
      );
      expect(
        failingStorage.values['discord_rich_presence_refresh_token'],
        'old-refresh',
      );
      expect(failingStorage.values['discord_rich_presence_token_type'], '1');
      expect(
        failingStorage.values['discord_rich_presence_expires_at'],
        oldExpiry,
      );
      expect(
        failingStorage.values['discord_rich_presence_scopes'],
        'openid sdk.social_layer_presence',
      );
      expect(failingStorage.values['discord_rich_presence_enabled'], 'true');
      expect(
        failingStorage
            .values['discord_rich_presence_minimum_age_confirmation_v1'],
        isNull,
      );
      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
    },
  );

  test(
    'device flow rejects native token type or missing required scopes',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      await expectLater(
        controller.acceptLinkedToken(platform.token, confirmation),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        controller.acceptLinkedToken(
          platform.deviceTokenWithScopes('openid identify'),
          confirmation,
        ),
        throwsA(isA<StateError>()),
      );

      expect(platform.connectCalls, 0);
      expect(controller.state.linked, isFalse);
      expect(await storage.read(key: 'discord_rich_presence_enabled'), isNull);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        isNull,
      );
    },
  );

  test(
    'device connect failure retains securely linked token for retry',
    () async {
      final platform = _FakeDiscordPlatform()..connectFailuresRemaining = 1;
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      await controller.acceptLinkedToken(platform.deviceToken, confirmation);

      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.connected, isFalse);
      expect(controller.state.busy, isFalse);
      expect(controller.state.error, contains('connection failed'));
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        platform.deviceToken.accessToken,
      );
    },
  );

  test(
    'stalled device connection times out but keeps the account linked',
    () async {
      final stalledConnection = Completer<void>();
      final platform = _FakeDiscordPlatform()
        ..connectCompleter = stalledConnection;
      final controller = DiscordPresenceController(
        storage,
        platform,
        deviceConnectionTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(controller.dispose);
      await _settle();

      await controller.acceptLinkedToken(platform.deviceToken, confirmation);

      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.busy, isFalse);
      expect(controller.state.connectionStatus, 'disconnected');
      expect(controller.state.error, contains('timed out'));
      expect(controller.state.error, contains('Retry'));
      expect(platform.disconnectCalls, 1);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        platform.deviceToken.accessToken,
      );

      // Canceling releases the native pending-connect slot, so the normal
      // Settings retry path can immediately start a second connection.
      await controller.retry();
      expect(platform.connectCalls, 2);
      expect(controller.state.connected, isTrue);
      expect(controller.state.error, isNull);
    },
  );

  test('device and native linking cannot run concurrently', () async {
    final platform = _FakeDiscordPlatform();
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();

    final accepting = controller.acceptLinkedToken(
      platform.deviceToken,
      confirmation,
    );
    await expectLater(
      controller.acceptLinkedToken(platform.deviceToken, confirmation),
      throwsA(isA<StateError>()),
    );
    await accepting;

    expect(platform.connectCalls, 1);
  });

  test('mobile connection timeout preserves the approved account', () async {
    final platform = _FakeDiscordPlatform()
      ..connectCompleter = Completer<void>();
    final controller = DiscordPresenceController(
      storage,
      platform,
      deviceConnectionTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(controller.dispose);
    await _settle();

    await controller.linkAccount(confirmation);

    expect(controller.state.linked, isTrue);
    expect(controller.state.enabled, isTrue);
    expect(controller.state.busy, isFalse);
    expect(controller.state.connectionStatus, 'disconnected');
    expect(controller.state.error, contains('Use Retry'));
    expect(platform.disconnectCalls, 1);
    expect(platform.cancelAuthenticationCalls, 0);
    expect(platform.revokeCalls, 0);
    expect(
      await storage.read(key: 'discord_rich_presence_access_token'),
      platform.token.accessToken,
    );
  });

  test('startup connection times out and allows a fresh retry', () async {
    final platform = _FakeDiscordPlatform()
      ..connectCompleter = Completer<void>();
    _seedLinkedToken(platform.token);
    final controller = DiscordPresenceController(
      storage,
      platform,
      deviceConnectionTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(controller.dispose);
    await _settle();
    expect(controller.state.busy, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(controller.state.linked, isTrue);
    expect(controller.state.enabled, isTrue);
    expect(controller.state.busy, isFalse);
    expect(controller.state.connectionStatus, 'disconnected');
    expect(controller.state.error, contains('timed out'));
    expect(platform.disconnectCalls, 1);
    await controller.retry();
    expect(platform.connectCalls, 2);
    expect(controller.state.connected, isTrue);
    expect(platform.authenticateCalls, 0);
    expect(platform.revokeCalls, 0);
  });

  test(
    'retry claims busy before storage and serializes token events',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();
      await controller.linkAccount(confirmation);
      final connection = Completer<void>();
      platform.connectCompleter = connection;

      final first = controller.retry();
      final second = controller.retry();
      platform.emit(const DiscordBridgeEvent('discordTokenExpiring', {}));
      await _settle();

      expect(controller.state.busy, isTrue);
      expect(platform.refreshCalls, 1);
      expect(platform.connectCalls, 2);
      connection.complete();
      await Future.wait([first, second]);
      expect(controller.state.busy, isFalse);
      expect(controller.state.connected, isTrue);
    },
  );

  test(
    'stale native busy latch is reset once without replacing the link',
    () async {
      final platform = _FakeDiscordPlatform()..connectBusyFailuresRemaining = 1;
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      await controller.acceptLinkedToken(platform.deviceToken, confirmation);

      expect(platform.connectCalls, 2);
      expect(platform.disconnectCalls, 1);
      expect(platform.authenticateCalls, 0);
      expect(platform.refreshCalls, 0);
      expect(platform.revokeCalls, 0);
      expect(
        platform.lastConnected?.accessToken,
        platform.deviceToken.accessToken,
      );
      expect(controller.state.connected, isTrue);
      expect(controller.state.error, isNull);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        platform.deviceToken.accessToken,
      );
    },
  );

  test('native busy recovery is bounded to one reset per request', () async {
    final platform = _FakeDiscordPlatform()..connectBusyFailuresRemaining = 3;
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();

    await controller.acceptLinkedToken(platform.deviceToken, confirmation);

    expect(platform.connectCalls, 2);
    expect(platform.disconnectCalls, 1);
    expect(controller.state.linked, isTrue);
    expect(controller.state.busy, isFalse);
    expect(controller.state.connectionStatus, 'disconnected');
    expect(controller.state.error, contains('already connecting'));
  });

  test(
    'late connection completion and ready event cannot undo timeout',
    () async {
      final lateConnection = Completer<void>();
      final platform = _FakeDiscordPlatform()
        ..connectCompleter = lateConnection
        ..disconnectCancelsConnection = false;
      final controller = DiscordPresenceController(
        storage,
        platform,
        deviceConnectionTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(controller.dispose);
      await _settle();
      await controller.acceptLinkedToken(platform.deviceToken, confirmation);

      lateConnection.complete();
      platform.emit(
        const DiscordBridgeEvent('discordConnectionState', {'status': 'ready'}),
      );
      await _settle();

      expect(controller.state.connectionStatus, 'disconnected');
      expect(controller.state.busy, isFalse);
      expect(controller.state.error, contains('timed out'));
      await controller.retry();
      expect(controller.state.connected, isTrue);
    },
  );

  test(
    'import connection timeout remains retryable with saved credentials',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(
        storage,
        platform,
        deviceConnectionTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(controller.dispose);
      await _settle();
      await controller.importLinkedToken(
        platform.deviceToken,
        confirmation,
        connectAfterStore: false,
      );
      platform.connectCompleter = Completer<void>();

      await controller.connectImportedToken();

      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.connectionStatus, 'disconnected');
      expect(controller.state.error, contains('timed out'));
      expect(platform.disconnectCalls, 1);
      expect(platform.revokeCalls, 0);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        platform.deviceToken.accessToken,
      );
    },
  );

  test(
    'import connect blocks snapshots and duplicate settings operations',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();
      await controller.importLinkedToken(
        platform.deviceToken,
        confirmation,
        connectAfterStore: false,
      );
      final connection = Completer<void>();
      platform.connectCompleter = connection;

      final importing = controller.connectImportedToken();
      await _settle();
      expect(controller.state.busy, isTrue);
      await expectLater(
        controller.snapshotForImport(),
        throwsA(isA<StateError>()),
      );
      await controller.retry();
      await controller.setEnabled(false);
      expect(platform.refreshCalls, 0);
      expect(platform.disconnectCalls, 0);
      expect(platform.connectCalls, 1);

      connection.complete();
      await importing;
      expect(controller.state.busy, isFalse);
      expect(controller.state.connected, isTrue);
    },
  );

  test(
    'startup refresh timeout preserves credentials and allows explicit retry',
    () async {
      final original = DiscordTokenBundle(
        accessToken: 'original-access',
        refreshToken: 'original-refresh',
        tokenType: 1,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        scopes: 'openid sdk.social_layer_presence',
      );
      _seedLinkedToken(original);
      final platform = _FakeDiscordPlatform()
        ..refreshCompleter = Completer<DiscordTokenBundle>();
      final controller = DiscordPresenceController(
        storage,
        platform,
        refreshTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(controller.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(controller.state.busy, isFalse);
      expect(controller.state.linked, isTrue);
      expect(controller.state.enabled, isTrue);
      expect(controller.state.error, contains('refresh timed out'));
      expect(controller.state.error, contains('Retry'));
      expect(platform.cancelRefreshCalls, 1);
      expect(platform.connectCalls, 0);
      expect(platform.disconnectCalls, 0);
      expect(platform.revokeCalls, 0);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        original.accessToken,
      );
      expect(
        await storage.read(key: 'discord_rich_presence_refresh_token'),
        original.refreshToken,
      );

      await controller.retry();
      expect(platform.refreshCalls, 2);
      expect(platform.connectCalls, 1);
      expect(platform.authenticateCalls, 0);
      expect(controller.state.connected, isTrue);
    },
  );

  test(
    'late timed-out refresh cannot store or settle a replacement refresh',
    () async {
      final platform = _FakeDiscordPlatform()
        ..cancelRefreshCompletesRequest = false;
      final controller = DiscordPresenceController(
        storage,
        platform,
        refreshTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);
      await _settle();
      await controller.linkAccount(confirmation);
      final stale = Completer<DiscordTokenBundle>();
      platform.refreshCompleter = stale;
      await controller.retry();
      expect(controller.state.busy, isFalse);
      expect(platform.cancelRefreshCalls, 1);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'access-token',
      );

      final replacement = Completer<DiscordTokenBundle>();
      platform.refreshCompleter = replacement;
      final retry = controller.retry();
      await _settle();
      stale.complete(platform.tokenWithAccess('stale-account-access'));
      await _settle();
      expect(controller.state.busy, isTrue);
      expect(platform.connectCalls, 1);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'access-token',
      );

      replacement.complete(platform.tokenWithAccess('replacement-access'));
      await retry;
      expect(controller.state.busy, isFalse);
      expect(platform.connectCalls, 2);
      expect(platform.lastConnected?.accessToken, 'replacement-access');
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'replacement-access',
      );
      expect(
        await storage.read(key: 'discord_rich_presence_refresh_token'),
        'refresh-replacement-access',
      );
    },
  );

  test(
    'refresh result cannot overwrite changed saved account credentials',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();
      await controller.linkAccount(confirmation);
      final refreshing = Completer<DiscordTokenBundle>();
      platform.refreshCompleter = refreshing;
      final retry = controller.retry();
      await _settle();

      final otherAccount = platform.tokenWithAccess('other-account-access');
      _seedLinkedToken(otherAccount);
      refreshing.complete(platform.tokenWithAccess('stale-account-access'));
      await retry;

      expect(controller.state.busy, isFalse);
      expect(controller.state.error, contains('credentials changed'));
      expect(platform.connectCalls, 1);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        otherAccount.accessToken,
      );
      expect(
        await storage.read(key: 'discord_rich_presence_refresh_token'),
        otherAccount.refreshToken,
      );
      expect(platform.revokeCalls, 0);
    },
  );

  test(
    'rollback cancels refresh and rejects its later wrong-generation token',
    () async {
      final platform = _FakeDiscordPlatform()
        ..cancelRefreshCompletesRequest = false;
      final controller = DiscordPresenceController(
        storage,
        platform,
        refreshTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);
      await _settle();
      await controller.linkAccount(confirmation);
      final snapshot = await controller.snapshotForImport();
      final refreshing = Completer<DiscordTokenBundle>();
      platform.refreshCompleter = refreshing;
      final retry = controller.retry();
      await _settle();

      await controller.restoreImportSnapshot(snapshot);
      refreshing.complete(platform.tokenWithAccess('abandoned-account-access'));
      await retry;

      expect(platform.cancelRefreshCalls, 1);
      expect(controller.state.connected, isTrue);
      expect(controller.state.busy, isFalse);
      expect(controller.state.error, isNull);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'access-token',
      );
      expect(
        await storage.read(key: 'discord_rich_presence_refresh_token'),
        'refresh-token',
      );
    },
  );

  test(
    'disposing during refresh cancels it without storing a late token',
    () async {
      final platform = _FakeDiscordPlatform()
        ..cancelRefreshCompletesRequest = false;
      final controller = DiscordPresenceController(storage, platform);
      await _settle();
      await controller.linkAccount(confirmation);
      final refreshing = Completer<DiscordTokenBundle>();
      platform.refreshCompleter = refreshing;
      final retry = controller.retry();
      await _settle();

      controller.dispose();
      refreshing.complete(platform.tokenWithAccess('disposed-account-access'));
      await retry;

      expect(platform.cancelRefreshCalls, 1);
      expect(
        await storage.read(key: 'discord_rich_presence_access_token'),
        'access-token',
      );
      expect(
        await storage.read(key: 'discord_rich_presence_refresh_token'),
        'refresh-token',
      );
      expect(platform.revokeCalls, 0);
    },
  );

  test(
    'rollback during refresh storage cannot connect the abandoned token',
    () async {
      final pausedStorage = _PausedDiscordStorage();
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(pausedStorage, platform);
      addTearDown(controller.dispose);
      await _settle();
      await controller.linkAccount(confirmation);
      final snapshot = await controller.snapshotForImport();
      final refreshed = Completer<DiscordTokenBundle>();
      platform.refreshCompleter = refreshed;
      pausedStorage.pauseNextAccessWrite = true;
      final retry = controller.retry();
      await _settle();
      refreshed.complete(platform.tokenWithAccess('abandoned-storage-access'));
      await pausedStorage.writeStarted.future;

      final rollback = controller.restoreImportSnapshot(snapshot);
      pausedStorage.resumeWrite.complete();
      await Future.wait([retry, rollback]);

      expect(platform.connectCalls, 2);
      expect(platform.lastConnected?.accessToken, 'access-token');
      expect(controller.state.connected, isTrue);
      expect(controller.state.busy, isFalse);
      expect(controller.state.error, isNull);
      expect(
        pausedStorage.values['discord_rich_presence_access_token'],
        'access-token',
      );
      expect(
        pausedStorage.values['discord_rich_presence_refresh_token'],
        'refresh-token',
      );
    },
  );

  test(
    'Android refresh cancellation sends no token or account/socket action',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('dev.tetotv/android_tv');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, 'discordCancelRefreshToken');
        expect(call.arguments, isNull);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await AndroidDiscordPresencePlatform(
        AndroidTvBridge.instance,
      ).cancelRefreshToken();

      expect(calls, 1);
    },
  );
}

class _PausedDiscordStorage extends FailureInjectingSecureStorage {
  bool pauseNextAccessWrite = false;
  final writeStarted = Completer<void>();
  final resumeWrite = Completer<void>();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (pauseNextAccessWrite &&
        invocation.memberName == #write &&
        invocation.namedArguments[#key] ==
            'discord_rich_presence_access_token') {
      pauseNextAccessWrite = false;
      writeStarted.complete();
      return resumeWrite.future.then<void>((_) async {
        await (super.noSuchMethod(invocation) as Future<void>);
      });
    }
    return super.noSuchMethod(invocation);
  }
}

void _seedLinkedToken(DiscordTokenBundle token) {
  FlutterSecureStorage.setMockInitialValues({
    'discord_rich_presence_enabled': 'true',
    'discord_rich_presence_access_token': token.accessToken,
    'discord_rich_presence_refresh_token': token.refreshToken,
    'discord_rich_presence_token_type': token.tokenType.toString(),
    'discord_rich_presence_expires_at': token.expiresAt.millisecondsSinceEpoch
        .toString(),
    'discord_rich_presence_scopes': token.scopes,
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

class _FakeDiscordPlatform
    implements DiscordPresencePlatform, DiscordRefreshCancellationPlatform {
  final _events = StreamController<DiscordBridgeEvent>.broadcast();
  Completer<DiscordTokenBundle>? authenticationCompleter;
  Object? authenticationError;
  Completer<DiscordTokenBundle>? refreshCompleter;
  bool cancelRefreshCompletesRequest = true;
  int cancelRefreshCalls = 0;
  Completer<void>? connectCompleter;
  int connectFailuresRemaining = 0;
  int connectBusyFailuresRemaining = 0;
  bool disconnectCancelsConnection = true;
  int authenticateCalls = 0;
  int cancelAuthenticationCalls = 0;
  int refreshCalls = 0;
  int connectCalls = 0;
  int revokeCalls = 0;
  int disconnectCalls = 0;
  DiscordTokenBundle? lastConnected;
  bool available = true;

  DiscordTokenBundle get token => DiscordTokenBundle(
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    tokenType: 0,
    expiresAt: DateTime.now().add(const Duration(days: 7)),
    scopes: 'openid sdk.social_layer_presence',
  );

  DiscordTokenBundle get deviceToken => DiscordTokenBundle(
    accessToken: 'device-access-token',
    refreshToken: 'device-refresh-token',
    tokenType: 1,
    expiresAt: DateTime.now().add(const Duration(days: 7)),
    scopes: 'openid sdk.social_layer_presence',
  );

  DiscordTokenBundle deviceTokenWithScopes(String scopes) => DiscordTokenBundle(
    accessToken: 'device-access-token',
    refreshToken: 'device-refresh-token',
    tokenType: 1,
    expiresAt: DateTime.now().add(const Duration(days: 7)),
    scopes: scopes,
  );

  DiscordTokenBundle tokenWithAccess(String accessToken) => DiscordTokenBundle(
    accessToken: accessToken,
    refreshToken: 'refresh-$accessToken',
    tokenType: 0,
    expiresAt: DateTime.now().add(const Duration(days: 7)),
    scopes: 'openid sdk.social_layer_presence',
  );

  @override
  Stream<DiscordBridgeEvent> get events => _events.stream;

  void emit(DiscordBridgeEvent event) => _events.add(event);

  @override
  Future<Map<Object?, Object?>> sdkInfo() async => {
    'available': available,
    'status': 'disconnected',
    'version': '1.10.18369',
  };

  @override
  Future<DiscordTokenBundle> authenticate() async {
    authenticateCalls++;
    if (authenticationError case final error?) throw error;
    if (authenticationCompleter case final completer?) {
      return completer.future;
    }
    return token;
  }

  @override
  Future<void> cancelAuthentication() async {
    cancelAuthenticationCalls++;
  }

  @override
  Future<DiscordTokenBundle> refreshToken(String refreshToken) async {
    refreshCalls++;
    if (refreshCompleter case final completer?) return completer.future;
    return token;
  }

  @override
  Future<void> cancelRefreshToken() async {
    cancelRefreshCalls++;
    final pending = refreshCompleter;
    refreshCompleter = null;
    if (cancelRefreshCompletesRequest &&
        pending != null &&
        !pending.isCompleted) {
      pending.completeError(
        PlatformException(code: 'DISCORD_REFRESH_CANCELED'),
      );
    }
  }

  @override
  Future<void> connect(DiscordTokenBundle token) async {
    connectCalls++;
    lastConnected = token;
    if (connectBusyFailuresRemaining > 0) {
      connectBusyFailuresRemaining--;
      throw PlatformException(
        code: 'DISCORD_CONNECT_BUSY',
        message: 'Discord is already connecting.',
      );
    }
    if (connectFailuresRemaining > 0) {
      connectFailuresRemaining--;
      throw StateError('connection failed');
    }
    if (connectCompleter case final completer?) await completer.future;
  }

  @override
  Future<bool> revoke(String token) async {
    revokeCalls++;
    return true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    final pendingConnection = connectCompleter;
    connectCompleter = null;
    if (disconnectCancelsConnection &&
        pendingConnection != null &&
        !pendingConnection.isCompleted) {
      pendingConnection.completeError(StateError('connection canceled'));
    }
  }
}
