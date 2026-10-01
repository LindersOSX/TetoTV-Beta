import 'package:anime_tv/features/catalog/presentation/expandable_synopsis.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget page(String text) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 350,
          height: 180,
          child: ExpandableSynopsis(text: text, maxLines: 3),
        ),
      ),
    ),
  );

  testWidgets('short descriptions have no expand arrow', (tester) async {
    await tester.pumpWidget(page('A short synopsis.'));
    expect(find.byKey(const ValueKey('synopsis-expand')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long descriptions stay still and open a manual reader', (
    tester,
  ) async {
    final text = List.filled(
      100,
      'A longer story to read at your own pace.',
    ).join(' ');
    await tester.pumpWidget(page(text));
    final arrow = find.byKey(const ValueKey('synopsis-expand'));
    expect(arrow, findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
    await tester.pump(const Duration(seconds: 15));
    expect(find.byType(SingleChildScrollView), findsNothing);
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    final reader = find.byKey(const ValueKey('synopsis-reader-scroll'));
    final scroll = tester.widget<SingleChildScrollView>(reader).controller!;
    expect(scroll.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    for (var i = 0; i < 100; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    expect(scroll.offset, scroll.position.maxScrollExtent);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(scroll.offset, lessThan(scroll.position.maxScrollExtent));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(reader, findsNothing);
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
