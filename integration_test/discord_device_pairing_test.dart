import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/discord/application/discord_device_pairing_controller.dart';
import 'package:anime_tv/features/discord/data/discord_device_pairing_client.dart';
import 'package:anime_tv/features/discord/domain/discord_device_pairing.dart';
import 'package:anime_tv/features/discord/presentation/discord_device_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TV shows a live Discord device code without opening a browser',
    (tester) async {
      var acceptedTokens = 0;
      final controller = DiscordDevicePairingController(
        DiscordDeviceAuthClient(),
        (_) async => acceptedTokens++,
      );
      final router = GoRouter(
        initialLocation: '/pair/discord',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('Home')),
          ),
          GoRoute(
            path: '/pair/discord',
            builder: (_, _) => const DiscordDevicePairingScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            discordDevicePairingControllerProvider.overrideWith(
              (_) => controller,
            ),
          ],
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark,
            routerConfig: router,
            builder: (_, child) => TvShortcuts(child: child!),
          ),
        ),
      );

      await _pumpUntil(
        tester,
        () => controller.state.stage == DiscordDevicePairingStage.waiting,
      );
      final session = controller.state.session!;
      expect(
        session.verificationUri,
        Uri.parse('https://discord.com/activate'),
      );
      expect(session.verificationUriComplete.host, 'discord.com');
      expect(session.userCode, matches(RegExp(r'^[A-Z0-9-]{4,20}$')));
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text(session.userCode), findsOneWidget);
      expect(
        find.textContaining('https://discord.com/activate'),
        findsOneWidget,
      );
      expect(acceptedTokens, 0);

      await controller.pollNow();
      await tester.pump();
      expect(controller.state.stage, DiscordDevicePairingStage.waiting);
      expect(acceptedTokens, 0);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > timeout) {
      fail('Timed out waiting for Discord to issue a TV device code.');
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
}
