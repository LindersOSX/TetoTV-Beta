import 'dart:collection';

import 'package:anime_tv/app/router.dart';
import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/discord/application/discord_device_pairing_controller.dart';
import 'package:anime_tv/features/discord/data/discord_device_pairing_client.dart';
import 'package:anime_tv/features/discord/domain/discord_device_pairing.dart';
import 'package:anime_tv/features/discord/presentation/discord_device_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  test('the application router registers the Discord TV pairing route', () {
    final paths = appRouter.configuration.routes.whereType<GoRoute>().map(
      (route) => route.path,
    );

    expect(paths, contains('/pair/discord'));
  });

  testWidgets('shows a TV-readable Discord QR/code and Back cancels safely', (
    tester,
  ) async {
    final api = _FakeDiscordDevicePairingApi(
      creates: [() async => _session('back')],
    );
    await _pumpPairingRoute(tester, api: api);

    expect(find.byType(DiscordDevicePairingScreen), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    expect(find.textContaining('https://discord.com/activate'), findsOneWidget);
    expect(find.textContaining('expires in about'), findsOneWidget);
    expect(
      tester.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel,
      'Discord device authorization link',
    );
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discord-pairing.back',
    );
    expect(tester.takeException(), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(DiscordDevicePairingScreen), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);
    expect(api.cancelCalls, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('approval focuses Done and stores the Discord token once', (
    tester,
  ) async {
    final api = _FakeDiscordDevicePairingApi(
      creates: [() async => _session('success')],
      polls: [
        () async => DiscordDevicePairingPollResult(
          status: DiscordDevicePairingPollStatus.authorized,
          token: _token(),
        ),
      ],
    );
    var acceptedTokens = 0;
    final harness = await _pumpPairingRoute(
      tester,
      api: api,
      acceptToken: (_) async => acceptedTokens++,
    );

    await harness.controller.pollNow();
    await tester.pumpAndSettle();

    expect(find.text('Discord linked'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(acceptedTokens, 1);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discord-pairing.status-action',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(DiscordDevicePairingScreen), findsNothing);
    expect(acceptedTokens, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed and expired sessions expose remote-focused retries', (
    tester,
  ) async {
    final api = _FakeDiscordDevicePairingApi(
      creates: [
        () async => throw const DiscordDeviceAuthException(
          'Discord is temporarily unavailable.',
        ),
        () async => _session(
          'expired',
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
        () async => _session('retry'),
      ],
    );
    final harness = await _pumpPairingRoute(tester, api: api);

    expect(find.text('Could not connect Discord'), findsOneWidget);
    expect(find.text('Discord is temporarily unavailable.'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discord-pairing.status-action',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('ABCD-EFGH'), findsOneWidget);

    await harness.controller.pollNow();
    await tester.pumpAndSettle();
    expect(find.text('Code expired'), findsOneWidget);
    expect(find.text('New code'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discord-pairing.status-action',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('discord-pairing-qr')), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discord-pairing.back',
    );
    expect(api.createCalls, 3);
    expect(tester.takeException(), isNull);
  });
}

Future<_PairingHarness> _pumpPairingRoute(
  WidgetTester tester, {
  required _FakeDiscordDevicePairingApi api,
  DiscordDeviceTokenAcceptor? acceptToken,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final controller = DiscordDevicePairingController(
    api,
    acceptToken ?? (_) async {},
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Center(
            child: FilledButton(
              autofocus: true,
              onPressed: () => context.push('/pair/discord'),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/pair/discord',
        builder: (context, state) => const DiscordDevicePairingScreen(),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        discordDevicePairingControllerProvider.overrideWith((_) => controller),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark,
        routerConfig: router,
        builder: (context, child) => TvShortcuts(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
  return _PairingHarness(controller: controller);
}

DiscordDevicePairingSession _session(String id, {DateTime? expiresAt}) =>
    DiscordDevicePairingSession(
      pairingId: id,
      deviceCode: 'd' * 48,
      userCode: 'ABCD-EFGH',
      verificationUri: Uri.parse('https://discord.com/activate'),
      verificationUriComplete: Uri.parse(
        'https://discord.com/activate?user_code=ABCD-EFGH',
      ),
      expiresAt: expiresAt ?? DateTime.now().add(const Duration(minutes: 5)),
      pollInterval: const Duration(hours: 1),
    );

DiscordTokenBundle _token() => DiscordTokenBundle(
  accessToken: 'a' * 48,
  refreshToken: 'r' * 48,
  tokenType: 1,
  expiresAt: DateTime.now().add(const Duration(days: 7)),
  scopes: 'openid sdk.social_layer_presence',
);

class _PairingHarness {
  const _PairingHarness({required this.controller});

  final DiscordDevicePairingController controller;
}

class _FakeDiscordDevicePairingApi implements DiscordDevicePairingApi {
  _FakeDiscordDevicePairingApi({
    required List<Future<DiscordDevicePairingSession> Function()> creates,
    List<Future<DiscordDevicePairingPollResult> Function()> polls = const [],
  }) : _creates = Queue.of(creates),
       _polls = Queue.of(polls);

  final Queue<Future<DiscordDevicePairingSession> Function()> _creates;
  final Queue<Future<DiscordDevicePairingPollResult> Function()> _polls;
  int createCalls = 0;
  int cancelCalls = 0;

  @override
  Future<DiscordDevicePairingSession> createSession() {
    createCalls++;
    return _creates.removeFirst()();
  }

  @override
  Future<DiscordDevicePairingPollResult> poll(
    DiscordDevicePairingSession session,
  ) => _polls.isEmpty
      ? Future.value(
          const DiscordDevicePairingPollResult(
            status: DiscordDevicePairingPollStatus.pending,
          ),
        )
      : _polls.removeFirst()();

  @override
  Future<void> cancel(DiscordDevicePairingSession session) async {
    cancelCalls++;
  }
}
