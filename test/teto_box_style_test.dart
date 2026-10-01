import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('glass controls keep shared geometry without permanent focus glow', () {
    final palette = AppThemePalette.defaults;
    final panel = TetoBoxStyle.translucentPanelDecoration(palette);
    final control = TetoBoxStyle.translucentControlDecoration(palette);
    expect(panel.borderRadius, BorderRadius.circular(TetoBoxStyle.radius));
    expect(control.borderRadius, panel.borderRadius);
    expect(panel.boxShadow, isNull);
    expect(control.boxShadow, isNull);
    for (final decoration in [panel, control]) {
      expect(decoration.color, isNull);
      final gradient = decoration.gradient! as LinearGradient;
      expect(gradient.colors.every((color) => color.a < 1), isTrue);
    }
  });
  test('cards, inputs and outlined buttons share the Studio box treatment', () {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF080A11),
      surface: const Color(0xFF202332),
      accent: const Color(0xFF6942B5),
      primaryText: Colors.white,
      mutedText: const Color(0xFFADB2C6),
    );
    final theme = AppTheme.darkFor(palette);
    final expectedOutline = TetoBoxStyle.outline(palette);
    final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
    final inputBorder =
        theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
    final focusedInputBorder =
        theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
    final buttonShape =
        theme.outlinedButtonTheme.style!.shape!.resolve({})!
            as RoundedRectangleBorder;

    expect(cardShape.borderRadius, BorderRadius.circular(TetoBoxStyle.radius));
    expect(cardShape.side.color, expectedOutline);
    expect(inputBorder.borderRadius, cardShape.borderRadius);
    expect(inputBorder.borderSide.color, expectedOutline);
    expect(focusedInputBorder.borderSide.color, palette.accentBright);
    expect(buttonShape.borderRadius, cardShape.borderRadius);
    expect(buttonShape.side.color, expectedOutline);
    expect(
      TetoBoxStyle.decoration(palette, focused: true).border!.top.color,
      palette.accentBright,
    );
  });
}
