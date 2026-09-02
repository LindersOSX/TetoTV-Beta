import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/copyable_code_interaction.dart';
import 'package:anime_tv/features/auth/data/all_debrid_pin_auth_client.dart';
import 'package:anime_tv/features/auth/presentation/all_debrid_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AllDebrid PIN is exposed through the shared copy interaction', (
    tester,
  ) async {
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: AllDebridPairingScreen(client: _StaticAllDebridClient()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('TETO'), findsOneWidget);
    expect(find.byType(CopyableCodeInteraction), findsOneWidget);
    await tester.tap(find.text('TETO'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(clipboardText, isNull);
    await tester.tap(find.text('TETO'));
    await tester.pump();

    expect(clipboardText, 'TETO');
    expect(find.text('AllDebrid PIN copied.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _StaticAllDebridClient extends AllDebridPinAuthClient {
  @override
  Future<AllDebridPinSession> start() async => AllDebridPinSession(
    pin: 'TETO',
    check: 'check-secret',
    verificationUrl: Uri.parse('https://alldebrid.com/pin/?pin=TETO'),
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  @override
  Future<String?> poll(AllDebridPinSession session) async => null;
}
