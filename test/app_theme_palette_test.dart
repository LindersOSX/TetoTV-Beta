import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default palette preserves every original TetoTV color', () {
    const palette = AppThemePalette.defaults;

    expect(palette.background, AppColors.ink);
    expect(palette.surface, AppColors.panel);
    expect(palette.surfaceRaised, AppColors.panelRaised);
    expect(palette.selectableSurface, AppColors.selectableSurface);
    expect(palette.selectableSurfaceHover, AppColors.selectableSurfaceHover);
    expect(palette.primaryText, AppColors.textPrimary);
    expect(palette.mutedText, AppColors.textMuted);
    expect(palette.accent, AppColors.accent);
    expect(palette.accentBright, AppColors.accentBright);
    expect(palette.focusRing, AppColors.focusRing);
    expect(palette.focusGlow, AppColors.focusGlow);
    expect(palette.focusInnerKeyline, AppColors.focusInnerKeyline);
    expect(palette.secondaryAccent, AppColors.cyan);
    expect(ThemeContrastReport.forPalette(palette).issues, isEmpty);
  });

  test('custom seeds derive coherent opaque interaction colors', () {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF001122),
      surface: const Color(0xFF102030),
      accent: const Color(0xFF4C7DFF),
      primaryText: Colors.white,
      mutedText: const Color(0xFFB8C5D6),
    );

    expect(palette.background, const Color(0xFF001122));
    expect(palette.surfaceRaised, isNot(palette.surface));
    expect(palette.selectableSurfaceHover, isNot(palette.selectableSurface));
    expect(palette.accentBright, isNot(palette.accent));
    for (final color in [
      palette.surfaceRaised,
      palette.selectableSurface,
      palette.selectableSurfaceHover,
      palette.accentBright,
      palette.focusRing,
      palette.secondaryAccent,
    ]) {
      expect(color.a, 1);
    }
  });

  test('contrast report catches unreadable text and focus colors', () {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF050505),
      surface: const Color(0xFF080808),
      accent: const Color(0xFF090909),
      primaryText: const Color(0xFF060606),
      mutedText: const Color(0xFF070707),
    );

    final report = ThemeContrastReport.forPalette(palette);

    expect(report.hasIssues, isTrue);
    expect(report.issues, hasLength(6));
    expect(report.issues.first, contains('Primary text'));
  });

  testWidgets('darkFor exposes palette through ThemeExtension', (tester) async {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF101728),
      surface: const Color(0xFF202A40),
      accent: const Color(0xFFFFC107),
      primaryText: Colors.white,
      mutedText: const Color(0xFFBAC3D7),
    );
    late AppThemePalette resolved;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: Builder(
          builder: (context) {
            resolved = context.appPalette;
            return const SizedBox();
          },
        ),
      ),
    );

    expect(resolved, palette);
    expect(
      Theme.of(tester.element(find.byType(SizedBox))).scaffoldBackgroundColor,
      palette.background,
    );
  });
}
