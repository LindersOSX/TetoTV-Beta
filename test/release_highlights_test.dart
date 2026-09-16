import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/release_highlights.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [const Size(960, 540), const Size(390, 844)]) {
    testWidgets('update popup fits $size and keeps clean bullets', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const ReleaseHighlightsDialog(
                      notes:
                          "## What's new\n- Cleaner update notices.\n- Better remote navigation.\n## Verification\n- Internal tests passed.\n<!-- tetotv-native-signature: private-machine-data -->",
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Cleaner update notices.'), findsOneWidget);
      expect(find.text('Better remote navigation.'), findsOneWidget);
      expect(find.byIcon(Icons.circle), findsNWidgets(2));
      expect(find.textContaining('Internal tests'), findsNothing);
      expect(find.textContaining('private-machine-data'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(ReleaseHighlightsDialog), findsNothing);
    });
  }

  testWidgets('remote can scroll longer highlights without losing Continue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notes =
        '## Highlights\n${List.generate(6, (i) => '- Feature $i ${'long customer description ' * 8}').join('\n')}';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ReleaseHighlightsDialog(notes: notes),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll.controller!.position.maxScrollExtent, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scroll.controller!.offset, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(scroll.controller!.offset, 0);
    expect(find.text('Continue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty summary uses a localized honest fallback', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        supportedLocales: TetoLocalizations.supportedLocales,
        localizationsDelegates: const [
          TetoLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: const Scaffold(
          body: ReleaseHighlightsList(notes: '<!-- metadata only -->'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Los detalles de la actualización están disponibles en GitHub.',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.circle), findsNothing);
  });
}
