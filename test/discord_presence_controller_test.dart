import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/failure_injecting_secure_storage.dart';

void main() {
  const storage = FlutterSecureStorage();

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

      await controller.linkAccount();

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
    },
  );

  test('concurrent link requests start authentication only once', () async {
    final platform = _FakeDiscordPlatform();
    final authentication = Completer<DiscordTokenBundle>();
    platform.authenticationCompleter = authentication;
    final controller = DiscordPresenceController(storage, platform);
    addTearDown(controller.dispose);
    await _settle();

    final firstLink = controller.linkAccount();
    final secondLink = controller.linkAccount();

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

    await controller.linkAccount();

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

      await controller.linkAccount();

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
      final retry = controller.linkAccount();

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

      final linking = controller.linkAccount();
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

      await controller.linkAccount();
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

      await controller.linkAccount();

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
      await controller.linkAccount();

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
    await controller.linkAccount();

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
  });

  test(
    'device flow stores a bearer token and connects without native auth',
    () async {
      final platform = _FakeDiscordPlatform();
      final controller = DiscordPresenceController(storage, platform);
      addTearDown(controller.dispose);
      await _settle();

      await controller.acceptLinkedToken(platform.deviceToken);

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

    await controller.importLinkedToken(platform.deviceToken);

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

      final linking = controller.linkAccount();
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
      failingStorage.failNextWrite('discord_rich_presence_token_type');

      await expectLater(
        controller.importLinkedToken(platform.deviceToken),
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
        controller.acceptLinkedToken(platform.token),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        controller.acceptLinkedToken(
          platform.deviceTokenWithScopes('openid identify'),
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

      await controller.acceptLinkedToken(platform.deviceToken);

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

      await controller.acceptLinkedToken(platform.deviceToken);

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

    final accepting = controller.acceptLinkedToken(platform.deviceToken);
    await expectLater(
      controller.acceptLinkedToken(platform.deviceToken),
      throwsA(isA<StateError>()),
    );
    await accepting;

    expect(platform.connectCalls, 1);
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

class _FakeDiscordPlatform implements DiscordPresencePlatform {
  final _events = StreamController<DiscordBridgeEvent>.broadcast();
  Completer<DiscordTokenBundle>? authenticationCompleter;
  Object? authenticationError;
  Completer<void>? connectCompleter;
  int connectFailuresRemaining = 0;
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
    return token;
  }

  @override
  Future<void> connect(DiscordTokenBundle token) async {
    connectCalls++;
    lastConnected = token;
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
    if (pendingConnection != null && !pendingConnection.isCompleted) {
      pendingConnection.completeError(StateError('connection canceled'));
    }
  }
}
