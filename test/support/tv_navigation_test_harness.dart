import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sends one complete remote key press and lets focus/scroll callbacks settle.
Future<void> pressTvKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  Duration settle = const Duration(milliseconds: 140),
}) async {
  await tester.sendKeyEvent(key);
  await tester.pump(settle);
}

String? focusedTvControl() => FocusManager.instance.primaryFocus?.debugLabel;

void expectTvFocus(String debugLabel, {String? reason}) {
  expect(focusedTvControl(), debugLabel, reason: reason);
}
