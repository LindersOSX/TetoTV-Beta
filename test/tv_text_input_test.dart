import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  testWidgets('opens an app-owned keyboard without an EditableText', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    });
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                child: TvTextInput(controller: controller, labelText: 'Search'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(find.byType(TvKeyboardDialog), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
    expect(find.text('PASTE'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    final keyboardSize = tester.getSize(
      find.byKey(const ValueKey('tv-keyboard-panel')),
    );
    expect(keyboardSize.width, inInclusiveRange(540, 560));
    expect(keyboardSize.height, lessThan(250));
    expect(find.text('7'), findsOneWidget);
    expect(find.text('#?&'), findsOneWidget);
  });

  testWidgets('physical Enter commits the TV keyboard value', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    });
    final controller = TextEditingController(text: 'Naruto');
    addTearDown(controller.dispose);
    String? submitted;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TvTextInput(
              controller: controller,
              labelText: 'Search',
              onSubmitted: (value) => submitted = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Naruto'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(TvKeyboardDialog), findsNothing);
    expect(submitted, 'Naruto');
    expect(controller.text, 'Naruto');
  });

  testWidgets('numeric TV input opens explicitly and applies room-code rules', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    });
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TvTextInput(
              controller: controller,
              labelText: 'Room code',
              numericOnly: true,
              maxLength: 8,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[2-9]')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TvKeyboardDialog), findsNothing);
    await tester.tap(find.text('Room code'));
    await tester.pumpAndSettle();
    expect(find.byType(TvKeyboardDialog), findsOneWidget);
    expect(find.text('q'), findsNothing);
    expect(find.text('#?&'), findsNothing);
    final keyboardSize = tester.getSize(
      find.byKey(const ValueKey('tv-keyboard-panel')),
    );
    expect(keyboardSize.width, lessThanOrEqualTo(320));

    for (final key in const ['2', '0', '9', '1', '8']) {
      await tester.tap(find.text(key));
      await tester.pump();
    }
    await tester.tap(find.text('BACKSPACE'));
    await tester.pump();
    await tester.tap(find.text('8'));
    await tester.pump();
    await tester.tap(find.text('DONE'));
    await tester.pumpAndSettle();
    expect(controller.text, '298');
  });

  testWidgets('can use the device keyboard preference', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'false',
    });
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TvTextInput(controller: controller, labelText: 'Search'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EditableText), findsOneWidget);
    await tester.tap(find.byType(EditableText));
    await tester.pumpAndSettle();
    expect(find.byType(TvKeyboardDialog), findsNothing);
  });
}
