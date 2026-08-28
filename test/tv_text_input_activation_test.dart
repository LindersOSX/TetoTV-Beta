import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('built-in keyboard opens only after explicit Select', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    });
    final controller = TextEditingController();
    final focusNode = FocusNode(debugLabel: 'test.input.navigation');
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TvTextInput(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              labelText: 'API token',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, same(focusNode));
    expect(find.byType(TvKeyboardDialog), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);

    // Re-requesting focus is what settings scrolling/ensureVisible does. It
    // must never be treated as an edit activation.
    focusNode.requestFocus();
    await tester.pump();
    expect(find.byType(TvKeyboardDialog), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvKeyboardDialog), findsOneWidget);
  });

  testWidgets('device keyboard waits for OK and returns navigation focus', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'false',
    });
    final controller = TextEditingController();
    final focusNode = FocusNode(debugLabel: 'test.input.navigation');
    String? submitted;
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TvTextInput(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              labelText: 'API token',
              onSubmitted: (value) => submitted = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, same(focusNode));
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);

    focusNode.requestFocus();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byType(TvKeyboardDialog), findsNothing);

    await tester.enterText(find.byType(TextField), 'secret');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, 'secret');
    expect(tester.testTextInput.isVisible, isFalse);
    expect(FocusManager.instance.primaryFocus, same(focusNode));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets(
    'hiding the device IME exits edit mode without trapping D-pad focus',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'input_use_built_in_keyboard': 'false',
      });
      final controller = TextEditingController();
      final focusNode = FocusNode(debugLabel: 'test.input.navigation');
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TvTextInput(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                labelText: 'Room code',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );

      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(FocusManager.instance.primaryFocus, same(focusNode));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(FocusManager.instance.primaryFocus, same(focusNode));
    },
  );
}
