import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'focus feedback is 50 percent faster without changing other motion',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: TvFocusable(
              focusNode: focus,
              onPressed: () {},
              child: const SizedBox(width: 100, height: 60),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      expect(TetoUiMotion.focus, const Duration(milliseconds: 80));
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
        TetoUiMotion.focus,
      );
      expect(
        tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .duration,
        TetoUiMotion.focus,
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).duration,
        TetoUiMotion.focus,
      );
      expect(TetoUiMotion.reveal, const Duration(milliseconds: 220));
      expect(TetoUiMotion.popup, const Duration(milliseconds: 160));
      expect(TetoUiMotion.page, const Duration(milliseconds: 180));
      expect(TetoUiMotion.hud, const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion keeps the focus ring and activation without zoom',
    (tester) async {
      var activated = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: TvFocusable(
              autofocus: true,
              focusScale: 1.3,
              onPressed: () => activated = true,
              child: const SizedBox(width: 100, height: 60),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      final frame = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(frame.duration, Duration.zero);
      expect((frame.decoration as BoxDecoration).boxShadow, isNotEmpty);
      await tester.tap(find.byType(TvFocusable));
      expect(activated, isTrue);
    },
  );

  testWidgets(
    'dense controls can opt out of motion without losing focus glow',
    (tester) async {
      var activated = false;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: TvFocusable(
              focusNode: focus,
              animateFocus: false,
              focusScale: 1.3,
              onPressed: () => activated = true,
              child: const SizedBox(width: 100, height: 60),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      final frame = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(frame.duration, Duration.zero);
      expect((frame.decoration as BoxDecoration).boxShadow, isNotEmpty);
      expect(
        (frame.foregroundDecoration as BoxDecoration).border!.top.color,
        AppThemePalette.defaults.focusRing,
      );
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
        Duration.zero,
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).duration,
        Duration.zero,
      );
      await tester.tap(find.byType(TvFocusable));
      await tester.pump();
      expect(activated, isTrue);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'page changes fade without moving the canvas, reduced motion $reduced',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => const Scaffold(
                        body: Center(child: Text('Next screen')),
                      ),
                    ),
                  ),
                  child: const Text('Next'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Next'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final next = find.text('Next screen');
        final midwayRect = tester.getRect(next);
        final fade = find.ancestor(
          of: next,
          matching: find.byType(FadeTransition),
        );
        if (reduced) {
          expect(fade, findsNothing);
        } else {
          expect(fade, findsOneWidget);
          final opacity = tester.widget<FadeTransition>(fade).opacity.value;
          expect(opacity, greaterThan(0));
          expect(opacity, lessThan(1));
        }
        await tester.pumpAndSettle();
        expect(tester.getRect(next), midwayRect);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Next'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'dialog returns selections and Back cancels with reduced motion $reduced',
      (tester) async {
        int? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showTetoDialog<int>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Choose'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(7),
                            child: const Text('Select'),
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final fade = tester.widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(AlertDialog),
                matching: find.byType(FadeTransition),
              )
              .first,
        );
        expect(fade.opacity.value, reduced ? 1 : lessThan(1));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        expect(result, 7);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(result, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
