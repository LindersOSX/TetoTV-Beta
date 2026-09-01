import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Finder _keyboardText(String value) => find.descendant(
  of: find.byType(TvKeyboardDialog),
  matching: find.text(value),
);

void main() {
  testWidgets('search keyboard exposes the TV QWERTY and number-pad layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    FlutterSecureStorage.setMockInitialValues({
      'input_use_built_in_keyboard': 'true',
    });
    final controller = TextEditingController();
    String? submitted;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                child: TvTextInput(
                  controller: controller,
                  labelText: 'Search',
                  keyboardTitle: 'Search anime',
                  onSubmitted: (value) => submitted = value,
                ),
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
    expect(_keyboardText('Search anime'), findsOneWidget);
    expect(_keyboardText('REMOTE  /  CONTROLLER  /  KEYBOARD'), findsOneWidget);
    expect(_keyboardText('Start typing…'), findsOneWidget);

    for (final key in const [
      'q',
      'w',
      'e',
      'r',
      't',
      'y',
      'u',
      'i',
      'o',
      'p',
      'a',
      's',
      'd',
      'f',
      'g',
      'h',
      'j',
      'k',
      'l',
      'z',
      'x',
      'c',
      'v',
      'b',
      'n',
      'm',
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '123?',
      '-',
      '_',
      '0',
      'Search',
    ]) {
      expect(
        _keyboardText(key),
        findsOneWidget,
        reason: 'missing keyboard key $key',
      );
    }
    expect(find.bySemanticsLabel('Cursor left'), findsOneWidget);
    expect(find.bySemanticsLabel('Cursor right'), findsOneWidget);
    expect(find.bySemanticsLabel('Space'), findsOneWidget);
    expect(find.bySemanticsLabel('Backspace'), findsOneWidget);

    final keyboardPanel = find.byKey(const ValueKey('tv-keyboard-panel'));
    final keyboardRect = tester.getRect(keyboardPanel);
    expect(
      keyboardRect.height,
      lessThanOrEqualTo(210),
      reason: 'the TV keyboard must retain the original compact height',
    );
    expect(
      keyboardRect.bottom,
      greaterThan(700),
      reason: 'the compact keyboard stays anchored to the lower screen edge',
    );

    // The right-side number pad keeps conventional ascending rows and stays
    // to the right of the QWERTY keys without pinning the test to pixels.
    expect(
      tester.getCenter(_keyboardText('1')).dx,
      greaterThan(tester.getCenter(_keyboardText('p')).dx),
    );
    expect(
      tester.getCenter(_keyboardText('1')).dy,
      lessThan(tester.getCenter(_keyboardText('4')).dy),
    );
    expect(
      tester.getCenter(_keyboardText('4')).dy,
      lessThan(tester.getCenter(_keyboardText('7')).dy),
    );

    await tester.tap(_keyboardText('q'));
    await tester.tap(_keyboardText('1'));
    await tester.tap(_keyboardText('-'));
    await tester.tap(_keyboardText('_'));
    await tester.tap(_keyboardText('0'));
    await tester.tap(find.bySemanticsLabel('Backspace'));
    await tester.tap(_keyboardText('Search'));
    await tester.pumpAndSettle();

    expect(controller.text, 'q1-_');
    expect(submitted, 'q1-_');
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
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
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
    expect(_keyboardText('Room code'), findsOneWidget);
    expect(_keyboardText('REMOTE  /  CONTROLLER  /  KEYBOARD'), findsOneWidget);
    expect(_keyboardText('Start typing…'), findsOneWidget);
    expect(_keyboardText('q'), findsNothing);
    expect(_keyboardText('123?'), findsNothing);
    for (final key in const [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '0',
      'CLEAR',
      'CANCEL',
      'DONE',
    ]) {
      expect(
        _keyboardText(key),
        findsOneWidget,
        reason: 'missing numeric key $key',
      );
    }
    expect(find.bySemanticsLabel('Backspace'), findsOneWidget);

    final numericPanelRect = tester.getRect(
      find.byKey(const ValueKey('tv-keyboard-panel')),
    );
    expect(
      numericPanelRect.height,
      lessThanOrEqualTo(225),
      reason: 'the room-code keyboard must keep the compact TV footprint',
    );
    expect(
      numericPanelRect.bottom,
      greaterThan(700),
      reason: 'the room-code keyboard stays in the lower screen area',
    );

    // The room-code pad reads naturally from 1 through 9.
    expect(
      tester.getCenter(_keyboardText('1')).dx,
      lessThan(tester.getCenter(_keyboardText('2')).dx),
    );
    expect(
      tester.getCenter(_keyboardText('2')).dx,
      lessThan(tester.getCenter(_keyboardText('3')).dx),
    );
    expect(
      tester.getCenter(_keyboardText('1')).dy,
      lessThan(tester.getCenter(_keyboardText('4')).dy),
    );
    expect(
      tester.getCenter(_keyboardText('4')).dy,
      lessThan(tester.getCenter(_keyboardText('7')).dy),
    );

    for (final key in const ['2', '0', '9', '1', '8']) {
      await tester.tap(_keyboardText(key));
      await tester.pump();
    }
    await tester.tap(find.bySemanticsLabel('Backspace'));
    await tester.pump();
    await tester.tap(_keyboardText('8'));
    await tester.pump();
    await tester.tap(_keyboardText('DONE'));
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
