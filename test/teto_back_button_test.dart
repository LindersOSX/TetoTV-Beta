import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('back navigation is icon-only with the shared card style', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: TetoBackButton(autofocus: true, onPressed: () => presses++),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.text('Back'), findsNothing);
    final surface = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(TetoBackButton),
            matching: find.byType(Container),
          ),
        )
        .firstWhere(
          (container) =>
              container.constraints?.maxWidth == 48 &&
              container.decoration is BoxDecoration,
        );
    expect(surface.constraints?.maxWidth, 48);
    expect(
      (surface.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(TetoBoxStyle.radius),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(presses, 1);
  });
}
