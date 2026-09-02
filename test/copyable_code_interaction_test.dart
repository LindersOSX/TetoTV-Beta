import 'package:anime_tv/core/widgets/copyable_code_interaction.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  testWidgets('two pointer taps copy the exact code with confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());

    await tester.tap(find.byKey(const ValueKey('visible-code')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(clipboardText, isNull);

    await tester.tap(find.byKey(const ValueKey('visible-code')));
    await tester.pump();

    expect(clipboardText, 'TETO-1234');
    expect(find.text('Pairing code copied.'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Test one-time pairing code TETO-1234. Double select to copy code.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('two remote Select presses copy the focused code', (
    tester,
  ) async {
    final codeFocus = FocusNode(debugLabel: 'test.pairing-code');
    addTearDown(codeFocus.dispose);
    await tester.pumpWidget(_testApp(focusNode: codeFocus));
    codeFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 100));
    expect(clipboardText, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(clipboardText, 'TETO-1234');
  });

  testWidgets('activations outside the window do not copy', (tester) async {
    await tester.pumpWidget(
      _testApp(activationWindow: const Duration(milliseconds: 300)),
    );

    await tester.tap(find.byKey(const ValueKey('visible-code')));
    await tester.pump(const Duration(milliseconds: 301));
    await tester.tap(find.byKey(const ValueKey('visible-code')));
    await tester.pump();
    expect(clipboardText, isNull);

    await tester.tap(find.byKey(const ValueKey('visible-code')));
    await tester.pump();
    expect(clipboardText, 'TETO-1234');
  });

  testWidgets('a regenerated code resets a pending double activation', (
    tester,
  ) async {
    var code = 'TETO-1234';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return CopyableCodeInteraction(
                code: code,
                semanticsLabel: 'Test one-time pairing code $code',
                child: Text(code, key: const ValueKey('visible-code')),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('visible-code')));
    update(() => code = 'FRESH-5678');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('visible-code')));
    await tester.pump();
    expect(clipboardText, isNull);

    await tester.tap(find.byKey(const ValueKey('visible-code')));
    await tester.pump();
    expect(clipboardText, 'FRESH-5678');
  });
}

Widget _testApp({
  FocusNode? focusNode,
  Duration activationWindow = const Duration(milliseconds: 900),
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: CopyableCodeInteraction(
        code: 'TETO-1234',
        semanticsLabel: 'Test one-time pairing code TETO-1234',
        confirmationMessage: 'Pairing code copied.',
        focusNode: focusNode,
        activationWindow: activationWindow,
        child: const Text('TETO-1234', key: ValueKey('visible-code')),
      ),
    ),
  ),
);
