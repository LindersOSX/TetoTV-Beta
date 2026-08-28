import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/auth/data/real_debrid_oauth_client.dart';
import 'package:anime_tv/features/auth/presentation/real_debrid_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets('shows the confirmation code and official URL beside the QR', (
    tester,
  ) async {
    final client = _FakeRealDebridOAuthClient(session: _session());
    await _pumpScreen(tester, client: client, size: const Size(1280, 720));

    expect(find.text('ABCD1234EFGHI'), findsOneWidget);
    expect(
      find.textContaining('https://real-debrid.com/device'),
      findsOneWidget,
    );
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(
      qr.semanticsLabel,
      'Real-Debrid pairing link https://real-debrid.com/device',
    );

    final codeRect = tester.getRect(
      find.byKey(const ValueKey('real-debrid-user-code')),
    );
    final qrRect = tester.getRect(
      find.byKey(const ValueKey('real-debrid-qr-code')),
    );
    expect(codeRect.left, greaterThan(qrRect.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the confirmation code on-screen in short landscape', (
    tester,
  ) async {
    final client = _FakeRealDebridOAuthClient(session: _session());
    const size = Size(640, 360);
    await _pumpScreen(tester, client: client, size: size);

    final codeRect = tester.getRect(
      find.byKey(const ValueKey('real-debrid-user-code')),
    );
    final qrRect = tester.getRect(
      find.byKey(const ValueKey('real-debrid-qr-code')),
    );
    expect(codeRect.top, lessThan(qrRect.top));
    expect(codeRect.top, greaterThanOrEqualTo(0));
    expect(codeRect.bottom, lessThanOrEqualTo(size.height));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps the human code visible before the QR on a phone', (
    tester,
  ) async {
    final client = _FakeRealDebridOAuthClient(session: _session());
    const size = Size(390, 844);
    await _pumpScreen(tester, client: client, size: size);

    final codeRect = tester.getRect(
      find.byKey(const ValueKey('real-debrid-user-code')),
    );
    final qrRect = tester.getRect(
      find.byKey(const ValueKey('real-debrid-qr-code')),
    );
    expect(find.text('ABCD1234EFGHI'), findsOneWidget);
    expect(codeRect.top, lessThan(qrRect.top));
    expect(codeRect.top, greaterThanOrEqualTo(0));
    expect(codeRect.bottom, lessThanOrEqualTo(size.height));
    expect(tester.takeException(), isNull);
  });

  testWidgets('turns an expired device session into a retryable error', (
    tester,
  ) async {
    final client = _FakeRealDebridOAuthClient(
      session: _session(
        interval: const Duration(milliseconds: 1),
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    );
    await _pumpScreen(tester, client: client);

    await tester.pump(const Duration(milliseconds: 2));

    expect(find.text('Could not connect'), findsOneWidget);
    expect(find.text('The authorization code expired.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(client.polls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a clean start error and retry remains D-pad operable', (
    tester,
  ) async {
    final client = _FakeRealDebridOAuthClient(
      startError: StateError('Pairing is temporarily unavailable.'),
    );
    await _pumpScreen(tester, client: client);

    expect(find.text('Could not connect'), findsOneWidget);
    expect(find.text('Pairing is temporarily unavailable.'), findsOneWidget);
    expect(find.textContaining('StateError'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(client.starts, 2);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required RealDebridOAuthClient client,
  Size size = const Size(1280, 720),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        home: RealDebridPairingScreen(client: client),
      ),
    ),
  );
  await tester.pump();
}

RealDebridDeviceSession _session({
  Duration interval = const Duration(seconds: 30),
  DateTime? expiresAt,
}) => RealDebridDeviceSession(
  deviceCode: 'device-secret',
  userCode: 'ABCD1234EFGHI',
  verificationUrl: Uri.parse('https://real-debrid.com/device'),
  interval: interval,
  expiresAt: expiresAt ?? DateTime.now().add(const Duration(minutes: 30)),
);

class _FakeRealDebridOAuthClient extends RealDebridOAuthClient {
  _FakeRealDebridOAuthClient({this.session, this.startError});

  final RealDebridDeviceSession? session;
  final Object? startError;
  int starts = 0;
  int polls = 0;

  @override
  Future<RealDebridDeviceSession> startDeviceAuthorization() async {
    starts++;
    if (startError case final error?) throw error;
    return session!;
  }

  @override
  Future<RealDebridOAuthCredentials?> pollCredentials(
    RealDebridDeviceSession session,
  ) async {
    polls++;
    return null;
  }
}
