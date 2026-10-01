import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/widgets/teto_apply_button.dart';
import 'package:anime_tv/core/widgets/teto_studio_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

final _customPalette = AppThemePalette.fromSeeds(
  background: const Color(0xFF071B2C),
  surface: const Color(0xFF12364A),
  accent: const Color(0xFF3CC8A8),
  primaryText: const Color(0xFFF4F9FF),
  mutedText: const Color(0xFF9BC0D1),
);

void main() {
  testWidgets(
    'localized Apply semantics distinguish enabled, idle, and blocked',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final idleFocus = FocusNode();
        addTearDown(idleFocus.dispose);
        var enabledPresses = 0;
        var idlePresses = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('es'),
            supportedLocales: TetoLocalizations.supportedLocales,
            localizationsDelegates: const [
              TetoLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            theme: AppTheme.dark,
            home: Scaffold(
              body: Column(
                children: [
                  TetoApplyButton(
                    buttonKey: const ValueKey('enabled'),
                    onPressed: () => enabledPresses++,
                    label: 'Apply setup',
                  ),
                  TetoApplyButton(
                    buttonKey: const ValueKey('idle'),
                    enabled: false,
                    focusNode: idleFocus,
                    onPressed: () => idlePresses++,
                    label: 'Apply',
                  ),
                  const TetoApplyButton(
                    buttonKey: ValueKey('blocked'),
                    onPressed: null,
                    label: 'Apply theme',
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Aplicar configuración'), findsOneWidget);
        expect(find.text('Aplicar'), findsOneWidget);
        expect(find.text('Aplicar tema'), findsOneWidget);
        expect(
          tester.getSemantics(find.bySemanticsLabel('Aplicar configuración')),
          matchesSemantics(
            label: 'Aplicar configuración',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Aplicar')),
          matchesSemantics(
            label: 'Aplicar',
            isButton: true,
            hasEnabledState: true,
            isFocusable: true,
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel('Aplicar tema')),
          matchesSemantics(
            label: 'Aplicar tema',
            isButton: true,
            hasEnabledState: true,
          ),
        );
        idleFocus.requestFocus();
        await tester.pumpAndSettle();
        expect(idleFocus.hasPrimaryFocus, isTrue);
        expect(
          tester.getSemantics(find.bySemanticsLabel('Aplicar')),
          matchesSemantics(
            label: 'Aplicar',
            isButton: true,
            hasEnabledState: true,
            isFocusable: true,
            isFocused: true,
          ),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.tap(find.byKey(const ValueKey('idle')));
        expect(idlePresses, 0);
        await tester.tap(find.byKey(const ValueKey('enabled')));
        expect(enabledPresses, 1);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final palette in [AppThemePalette.defaults, _customPalette]) {
    final themeName = palette == AppThemePalette.defaults
        ? 'default'
        : 'custom';
    testWidgets('all Apply actions share $themeName colors and shape', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: Scaffold(
            body: Column(
              children: [
                TetoStudioActions(
                  applyKey: const ValueKey('studio'),
                  onApply: () {},
                  onReset: () {},
                ),
                TetoApplyButton(
                  buttonKey: const ValueKey('setup'),
                  onPressed: () {},
                  icon: const Icon(Icons.verified_user_rounded),
                  label: 'Apply setup',
                ),
                TetoApplyButton(
                  buttonKey: const ValueKey('filters'),
                  onPressed: () {},
                  icon: const Icon(Icons.search_rounded),
                  label: 'Show results',
                ),
              ],
            ),
          ),
        ),
      );

      for (final key in ['studio', 'setup', 'filters']) {
        final button = tester.widget<FilledButton>(find.byKey(ValueKey(key)));
        final style = button.style!;
        for (final states in [
          <WidgetState>{},
          {WidgetState.focused},
          {WidgetState.hovered},
          {WidgetState.pressed},
        ]) {
          expect(style.backgroundColor!.resolve(states), palette.accent);
          expect(
            style.foregroundColor!.resolve(states),
            contrastForeground(palette.accent),
          );
          expect(style.overlayColor!.resolve(states), Colors.transparent);
          expect(
            (style.shape!.resolve(states)! as RoundedRectangleBorder)
                .borderRadius,
            BorderRadius.circular(TetoBoxStyle.radius),
          );
        }
        expect(
          style.side!.resolve({WidgetState.focused}),
          BorderSide(color: palette.focusRing, width: 2),
        );
        expect(style.side!.resolve({}), BorderSide.none);
        expect(
          style.backgroundColor!.resolve({WidgetState.disabled}),
          palette.surfaceRaised,
        );
        expect(
          style.foregroundColor!.resolve({WidgetState.disabled}),
          palette.mutedText,
        );
      }
    });

    testWidgets('idle and disabled Apply share $themeName disabled styling', (
      tester,
    ) async {
      var idleApplied = false;
      final idleFocus = FocusNode();
      addTearDown(idleFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: Scaffold(
            body: Column(
              children: [
                TetoApplyButton(
                  buttonKey: const ValueKey('idle'),
                  focusNode: idleFocus,
                  enabled: false,
                  onPressed: () => idleApplied = true,
                  label: 'Apply',
                ),
                const TetoApplyButton(
                  buttonKey: ValueKey('disabled'),
                  onPressed: null,
                  label: 'Apply theme',
                ),
              ],
            ),
          ),
        ),
      );

      for (final key in ['idle', 'disabled']) {
        final style = tester
            .widget<FilledButton>(find.byKey(ValueKey(key)))
            .style!;
        for (final states in [
          <WidgetState>{},
          {WidgetState.focused},
        ]) {
          expect(style.backgroundColor!.resolve(states), palette.surfaceRaised);
          expect(style.foregroundColor!.resolve(states), palette.mutedText);
          expect(style.overlayColor!.resolve(states), Colors.transparent);
        }
      }
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('disabled')))
            .onPressed,
        isNull,
      );
      idleFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(idleFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.tap(find.byKey(const ValueKey('idle')));
      expect(idleApplied, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Apply focus adds glow without movement and preserves key handler',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var keyHandled = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkFor(_customPalette),
          home: Scaffold(
            body: TetoApplyButton(
              buttonKey: const ValueKey('apply'),
              focusNode: focus,
              onPressed: () {},
              label: 'Apply',
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  keyHandled = true;
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
            ),
          ),
        ),
      );

      final finder = find.byKey(const ValueKey('apply'));
      final before = tester.getRect(finder);
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(tester.getRect(finder), before);
      final frame = tester.widget<AnimatedContainer>(
        find
            .ancestor(of: finder, matching: find.byType(AnimatedContainer))
            .first,
      );
      expect(
        (frame.decoration! as BoxDecoration).boxShadow!.single.color,
        _customPalette.focusGlow,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(keyHandled, isTrue);
      expect(focus.hasPrimaryFocus, isTrue);
    },
  );
}
