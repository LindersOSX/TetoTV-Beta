import 'package:anime_tv/core/widgets/copyable_qr_interaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const encodedUrl = 'https://example.com/pair?code=ABC123';
  String? clipboardText;

  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('two pointer taps copy the exact QR URL with confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());

    await tester.tap(find.byType(CopyableQrInteraction));
    await tester.pump(const Duration(milliseconds: 100));
    expect(clipboardText, isNull);
    await tester.tap(find.byType(CopyableQrInteraction));
    await tester.pump();

    expect(clipboardText, encodedUrl);
    expect(find.text('Pairing link copied.'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Pairing QR code. Double select to copy link.'),
      findsOneWidget,
    );
    expect(find.text('Double-click or press OK twice to copy'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
  });

  testWidgets('two remote Select presses copy the QR URL', (tester) async {
    final qrFocus = FocusNode(debugLabel: 'test.qr');
    addTearDown(qrFocus.dispose);
    await tester.pumpWidget(_testApp(focusNode: qrFocus));
    qrFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 100));
    expect(clipboardText, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(clipboardText, encodedUrl);
    expect(find.text('Pairing link copied.'), findsOneWidget);
  });
}

Widget _testApp({FocusNode? focusNode}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: CopyableQrInteraction(
        data: 'https://example.com/pair?code=ABC123',
        semanticsLabel: 'Pairing QR code',
        confirmationMessage: 'Pairing link copied.',
        focusNode: focusNode,
        child: const SizedBox(width: 180, height: 180),
      ),
    ),
  ),
);
