import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/auth/data/torbox_device_auth_client.dart';
import 'package:anime_tv/features/auth/presentation/torbox_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a temporary TorBox outage keeps the active code and retries', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _RetryingTorBoxClient();
    final diagnosticEvents = <Map<String, Object?>>[];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TorBoxPairingScreen(
            client: client,
            diagnosticRecorder: (details) async =>
                diagnosticEvents.add(details),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('483414'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('temporarily unreachable'), findsOneWidget);
    expect(find.text('Could not connect TorBox'), findsNothing);
    expect(find.text('483414'), findsOneWidget);
    expect(
      diagnosticEvents.map((event) => event['stage']),
      containsAllInOrder(['start', 'pending', 'transient-retry']),
    );
    expect(
      diagnosticEvents.toString(),
      isNot(anyOf(contains('483414'), contains('device-secret'))),
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(client.pollCalls, greaterThanOrEqualTo(2));
    expect(find.textContaining('temporarily unreachable'), findsNothing);
    expect(find.text('WAITING FOR APPROVAL'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('resuming the app polls a still-valid TorBox code immediately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _PendingTorBoxClient();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TorBoxPairingScreen(
            client: client,
            diagnosticRecorder: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(client.pollCalls, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(client.pollCalls, 1);
    expect(find.text('483414'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _RetryingTorBoxClient extends TorBoxDeviceAuthClient {
  int pollCalls = 0;

  @override
  Future<TorBoxDeviceSession> start() async => TorBoxDeviceSession(
    deviceCode: 'device-secret',
    userCode: '483414',
    verificationUrl: Uri.parse('https://torbox.app/oauth/device?app=TetoTV'),
    friendlyVerificationUrl: Uri.parse('https://tor.box/link'),
    expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    interval: const Duration(seconds: 1),
  );

  @override
  Future<String?> poll(TorBoxDeviceSession session) async {
    pollCalls += 1;
    if (pollCalls == 1) {
      throw const TorBoxDeviceAuthException(
        'TorBox is temporarily unreachable. TetoTV will keep retrying this code.',
        code: 'NETWORK_ERROR',
        retryable: true,
      );
    }
    return null;
  }
}

class _PendingTorBoxClient extends TorBoxDeviceAuthClient {
  int pollCalls = 0;

  @override
  Future<TorBoxDeviceSession> start() async => TorBoxDeviceSession(
    deviceCode: 'device-secret',
    userCode: '483414',
    verificationUrl: Uri.parse('https://torbox.app/oauth/device?app=TetoTV'),
    friendlyVerificationUrl: Uri.parse('https://tor.box/link'),
    expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    interval: const Duration(minutes: 5),
  );

  @override
  Future<String?> poll(TorBoxDeviceSession session) async {
    pollCalls += 1;
    return null;
  }
}
