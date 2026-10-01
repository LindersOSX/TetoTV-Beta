import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_backdrop_blur.dart';
import 'package:anime_tv/core/widgets/teto_blur_scope.dart';
import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('blur preference disables the filter, not the modal barrier', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TetoBlurScope(enabled: false, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTetoDialog<void>(
                context: context,
                builder: (_) => const Dialog(child: Text('Reader')),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BackdropFilter>(
            find.byKey(const ValueKey('teto-modal-backdrop-blur')),
          )
          .enabled,
      isFalse,
    );
    expect(find.text('Reader'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Reader'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final kind in ['dialog', 'menu', 'sheet']) {
    for (final reduced in [false, true]) {
      testWidgets(
        '$kind blur preserves results, barrier and Back, reduced $reduced',
        (tester) async {
          int? result;
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async => result = await _open(context, kind),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );

          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final blur = find.byKey(const ValueKey('teto-modal-backdrop-blur'));
          expect(blur, findsOneWidget);
          expect(tester.widget<BackdropFilter>(blur).enabled, isTrue);
          expect(tester.getSize(blur), const Size(800, 600));
          // Only the barrier is inside the filter; modal content and glow paint
          // in a separate overlay entry and keep their sharp edges.
          expect(
            find.descendant(of: blur, matching: find.text('Select')),
            findsNothing,
          );
          await tester.tap(find.text('Select'));
          await tester.pumpAndSettle();
          expect(result, 7);
          expect(blur, findsNothing);

          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
          expect(result, isNull);
          expect(blur, findsNothing);

          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(result, isNull);
          expect(blur, findsNothing);
          expect(find.text('Open'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('nested dialogs only blur the topmost barrier', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTetoDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('First'),
                  actions: [
                    TextButton(
                      onPressed: () => _open(context, 'dialog'),
                      child: const Text('Nested'),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nested'));
    await tester.pumpAndSettle();
    final filters = tester
        .widgetList<BackdropFilter>(
          find.byKey(
            const ValueKey('teto-modal-backdrop-blur'),
            skipOffstage: false,
          ),
        )
        .toList();
    expect(filters, hasLength(2));
    expect(filters.where((filter) => filter.enabled), hasLength(1));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isTrue,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'blur keeps non-dismissible barriers non-dismissible and captures the dialog theme',
    (tester) async {
      final localTheme = ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(primary: Colors.teal),
      );
      ThemeData? capturedTheme;
      await tester.pumpWidget(
        MaterialApp(
          home: Theme(
            data: localTheme,
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showTetoDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (context) {
                      capturedTheme = Theme.of(context);
                      return const AlertDialog(title: Text('Protected'));
                    },
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
      // Theme.of localizes typography; the caller's selected colors must
      // still be captured rather than replaced by the root app theme.
      expect(capturedTheme?.colorScheme, localTheme.colorScheme);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Protected'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Protected'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('blurred sheets still drag to dismiss', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => _open(context, 'sheet'),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(BottomSheet), const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(TetoBackdropBlur), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<int?> _open(BuildContext context, String kind) {
  Widget select(BuildContext context) => TextButton(
    onPressed: () => Navigator.of(context).pop(7),
    child: const Text('Select'),
  );
  switch (kind) {
    case 'menu':
      return showTetoGeneralDialog<int>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Close menu',
        pageBuilder: (context, _, _) => Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Material(child: select(context)),
          ),
        ),
        transitionBuilder: tetoPopupTransition,
      );
    case 'sheet':
      return showTetoModalBottomSheet<int>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 500),
        builder: (context) =>
            SizedBox(height: 180, child: Center(child: select(context))),
      );
    default:
      return showTetoDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose'),
          actions: [select(context)],
        ),
      );
  }
}
