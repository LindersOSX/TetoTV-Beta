import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/auth/data/torbox_device_auth_client.dart';
import 'package:anime_tv/features/auth/presentation/torbox_pairing_screen.dart';
import 'package:anime_tv/features/settings/presentation/initial_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

final _customPalette = AppThemePalette.fromSeeds(
  background: const Color(0xFF071B2C),
  surface: const Color(0xFF12364A),
  accent: const Color(0xFF3CC8A8),
  primaryText: const Color(0xFFF4F9FF),
  mutedText: const Color(0xFF9BC0D1),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('first-run setup consumes the active Theme Studio palette', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.darkFor(_customPalette),
          home: const InitialSetupScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      _customPalette.background,
    );
    expect(_decorationColors(tester), contains(_customPalette.surface));
    expect(_decorationColors(tester), contains(_customPalette.surfaceRaised));
    expect(
      tester
          .widget<Icon>(find.byIcon(Icons.play_circle_outline_rounded).first)
          .color,
      _customPalette.accentBright,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pairing chrome is themed while QR remains black on white', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(_customPalette),
        home: TorBoxPairingScreen(client: _StaticTorBoxClient()),
      ),
    );
    await tester.pumpAndSettle();

    expect(_decorationColors(tester), contains(_customPalette.surface));
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.backgroundColor, Colors.white);
    expect(qr.eyeStyle.color, Colors.black);
    expect(qr.dataModuleStyle.color, Colors.black);
    expect(find.text('Double-click or press OK twice to copy'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shared TV keyboard consumes custom surface and accent roles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(_customPalette),
        home: const Scaffold(
          body: TvKeyboardDialog(
            title: 'Enter pairing URL',
            initialValue: '',
            autofillSuggestions: ['https://'],
          ),
        ),
      ),
    );
    await tester.pump();

    final panel = tester.widget<Container>(
      find.byKey(const ValueKey('tv-keyboard-panel')),
    );
    final panelDecoration = panel.decoration! as BoxDecoration;
    expect(
      panelDecoration.border!.top.color,
      _customPalette.accent.withValues(alpha: .32),
    );
    expect(_paintedColors(tester), contains(_customPalette.selectableSurface));
    expect(tester.takeException(), isNull);
  });
}

List<Color?> _decorationColors(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((container) => container.decoration)
    .whereType<BoxDecoration>()
    .map((decoration) => decoration.color)
    .toList(growable: false);

List<Color?> _paintedColors(WidgetTester tester) => [
  ..._decorationColors(tester),
  ...tester
      .widgetList<ColoredBox>(find.byType(ColoredBox))
      .map((box) => box.color),
];

class _StaticTorBoxClient extends TorBoxDeviceAuthClient {
  @override
  Future<TorBoxDeviceSession> start() async => TorBoxDeviceSession(
    deviceCode: 'device-code',
    userCode: 'TETO-1234',
    verificationUrl: Uri.parse('https://torbox.app/link?code=TETO-1234'),
    friendlyVerificationUrl: Uri.parse('https://torbox.app/link'),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    interval: const Duration(minutes: 10),
  );

  @override
  Future<String?> poll(TorBoxDeviceSession session) async => null;
}
