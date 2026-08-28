import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/data/torbox_device_auth_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/auth/presentation/anilist_pairing_screen.dart';
import 'package:anime_tv/features/auth/presentation/torbox_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _copyHint = 'Double-click or press OK twice to copy';

void main() {
  tearDown(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('TorBox pairing fits a phone and a short TV viewport', (
    tester,
  ) async {
    for (final size in [const Size(390, 844), const Size(960, 480)]) {
      await _setViewport(tester, size);
      await tester.pumpWidget(
        MaterialApp(home: TorBoxPairingScreen(client: _StaticTorBoxClient())),
      );
      await tester.pumpAndSettle();

      _expectVisiblePairingContent(tester, size);
      expect(find.text('Connect TorBox'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('AniList and MAL pairing fit phone and short TV viewports', (
    tester,
  ) async {
    final cases = <(Size, TrackingProvider)>[
      (const Size(390, 844), TrackingProvider.anilist),
      (const Size(960, 480), TrackingProvider.myAnimeList),
    ];
    for (final (size, provider) in cases) {
      FlutterSecureStorage.setMockInitialValues({
        authBrokerUrlStorageKey: 'https://auth.example.com',
      });
      await _setViewport(tester, size);
      final controller = _StaticPairingController(provider, _session());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pairingControllerProvider(provider).overrideWith((_) => controller),
          ],
          child: MaterialApp(home: TrackingPairingScreen(provider: provider)),
        ),
      );
      await tester.pumpAndSettle();

      _expectVisiblePairingContent(tester, size);
      expect(find.text('Connect ${provider.displayName}'), findsOneWidget);
      if (provider == TrackingProvider.myAnimeList) {
        expect(find.textContaining('Registered callback:'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

PairingSession _session() => PairingSession(
  pairingId: 'pairing-id',
  deviceCode: 'device-code',
  userCode: 'TETO-1234',
  verificationUri: 'https://auth.example.com/activate',
  verificationUriComplete: 'https://auth.example.com/activate?code=TETO-1234',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  pollInterval: const Duration(minutes: 10),
);

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _expectVisiblePairingContent(WidgetTester tester, Size viewport) {
  expect(find.byType(SingleChildScrollView), findsOneWidget);
  final hint = find.text(_copyHint);
  expect(hint, findsOneWidget);
  final center = tester.getCenter(hint);
  expect(center.dx, inInclusiveRange(0, viewport.width));
  expect(center.dy, inInclusiveRange(0, viewport.height));
  expect(tester.takeException(), isNull);
}

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

class _StaticPairingController extends PairingController {
  _StaticPairingController(TrackingProvider provider, PairingSession session)
    : super(provider, const FlutterSecureStorage()) {
    state = AsyncData(session);
  }

  @override
  Future<void> start() async {}
}
