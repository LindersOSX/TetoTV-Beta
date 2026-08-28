import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/features/discord/application/discord_account_link_resolver.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('TV Settings opens device pairing without mobile OAuth', (
    tester,
  ) async {
    final discord = await _pumpAccounts(tester, isTelevision: true);
    await _tapConnectDiscord(tester);

    expect(find.text('TV DISCORD PAIRING'), findsOneWidget);
    expect(discord.authenticateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone Settings keeps the existing mobile OAuth flow', (
    tester,
  ) async {
    final discord = await _pumpAccounts(tester, isTelevision: false);
    await _tapConnectDiscord(tester);

    expect(find.byType(AccountsScreen), findsOneWidget);
    expect(find.text('TV DISCORD PAIRING'), findsNothing);
    expect(discord.authenticateCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late Fire TV detection repairs stale startup flag without mobile OAuth',
    (tester) async {
      final discord = await _pumpAccounts(
        tester,
        isTelevision: false,
        nativeCategory: AndroidDeviceCategory.television,
      );
      await _tapConnectDiscord(tester);

      expect(find.text('TV DISCORD PAIRING'), findsOneWidget);
      expect(discord.authenticateCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unknown native classification fails closed to TV QR', (
    tester,
  ) async {
    final discord = await _pumpAccounts(
      tester,
      isTelevision: false,
      nativeCategory: AndroidDeviceCategory.unknown,
    );
    await _tapConnectDiscord(tester);

    expect(find.text('TV DISCORD PAIRING'), findsOneWidget);
    expect(discord.authenticateCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<_SettingsDiscordPlatform> _pumpAccounts(
  WidgetTester tester, {
  required bool isTelevision,
  AndroidDeviceCategory? nativeCategory,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final discord = _SettingsDiscordPlatform();
  final router = GoRouter(
    initialLocation: '/settings/accounts',
    routes: [
      GoRoute(
        path: '/settings/accounts',
        builder: (context, state) => const AccountsScreen(),
      ),
      GoRoute(
        path: '/pair/discord',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('TV DISCORD PAIRING'))),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isTelevisionProvider.overrideWithValue(isTelevision),
        discordPresencePlatformProvider.overrideWithValue(discord),
        discordAccountLinkResolverProvider.overrideWithValue(
          DiscordAccountLinkResolver(
            () async =>
                nativeCategory ??
                (isTelevision
                    ? AndroidDeviceCategory.television
                    : AndroidDeviceCategory.mobile),
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return discord;
}

Future<void> _tapConnectDiscord(WidgetTester tester) async {
  await tester.tap(find.text('System'));
  await tester.pumpAndSettle();
  final connect = find.text('Connect Discord');
  expect(connect, findsOneWidget);
  await tester.ensureVisible(connect);
  await tester.pumpAndSettle();
  await tester.tap(connect);
  await tester.pumpAndSettle();
}

class _SettingsDiscordPlatform implements DiscordPresencePlatform {
  int authenticateCalls = 0;

  @override
  Stream<DiscordBridgeEvent> get events => const Stream.empty();

  @override
  Future<DiscordTokenBundle> authenticate() async {
    authenticateCalls++;
    return DiscordTokenBundle(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      tokenType: 1,
      expiresAt: DateTime.now().add(const Duration(days: 7)),
      scopes: 'openid sdk.social_layer_presence',
    );
  }

  @override
  Future<void> cancelAuthentication() async {}

  @override
  Future<void> connect(DiscordTokenBundle token) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<DiscordTokenBundle> refreshToken(String refreshToken) =>
      throw UnimplementedError();

  @override
  Future<bool> revoke(String token) async => true;

  @override
  Future<Map<Object?, Object?>> sdkInfo() async => {
    'available': true,
    'status': 'disconnected',
    'version': '1.10.18369',
  };
}
