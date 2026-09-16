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

  test('dark accents keep chromatic focus rings and dark tinted keylines', () {
    for (final accent in [
      const Color(0xFF5000A0),
      const Color(0xFF202080),
      const Color(0xFF004040),
      const Color(0xFF603060),
    ]) {
      final palette = AppThemePalette.defaults.withRole(
        AppThemeColorRole.accent,
        accent,
      );
      final seed = HSLColor.fromColor(accent);
      final ring = HSLColor.fromColor(palette.focusRing);
      // Flutter HSL-to-RGB rounds to 8-bit channels.
      expect(ring.hue, closeTo(seed.hue, 1));
      expect(ring.saturation, closeTo(seed.saturation, .01));
      expect(ring.lightness, greaterThan(seed.lightness));
      expect(
        palette.focusRing.computeLuminance(),
        closeTo(
          Color.lerp(accent, Colors.white, .27)!.computeLuminance(),
          .005,
        ),
        reason: 'Preserve previous visibility instead of dimming dark accents.',
      );
      expect(palette.focusInnerKeyline.computeLuminance(), lessThan(.04));
      expect(
        palette.focusInnerKeyline.computeLuminance(),
        lessThan(accent.computeLuminance()),
      );
      expect(
        HSLColor.fromColor(palette.focusInnerKeyline).hue,
        closeTo(seed.hue, .01),
      );
      expect(palette.focusGlow.withValues(alpha: 1), palette.focusRing);
      expect(palette.focusGlow.a, closeTo(.6, .001));
      expect(palette.accent, accent);
    }
  });

  test('neutral and light accents remain finite and use a dark keyline', () {
    for (final accent in [Colors.black, Colors.grey, Colors.white]) {
      final palette = AppThemePalette.defaults.withRole(
        AppThemeColorRole.accent,
        accent,
      );
      final ring = HSLColor.fromColor(palette.focusRing);
      expect(ring.saturation, closeTo(0, .001));
      expect(ring.lightness.isFinite, isTrue);
      expect(palette.focusInnerKeyline.computeLuminance(), lessThan(.06));
    }
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

  test('menus and in-app notifications use themed TetoTV surfaces', () {
    const palette = AppThemePalette.defaults;
    final theme = AppTheme.darkFor(palette);
    final popupShape = theme.popupMenuTheme.shape! as RoundedRectangleBorder;
    final snackShape = theme.snackBarTheme.shape! as RoundedRectangleBorder;

    expect(theme.popupMenuTheme.color, palette.surface);
    expect(theme.popupMenuTheme.surfaceTintColor, Colors.transparent);
    expect(popupShape.borderRadius, BorderRadius.circular(14));
    expect(popupShape.side.color, palette.accent.withValues(alpha: .70));
    expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
    expect(theme.snackBarTheme.backgroundColor, palette.surfaceRaised);
    expect(theme.snackBarTheme.actionTextColor, palette.accentBright);
    final notificationText = theme.snackBarTheme.contentTextStyle!;
    final appLabelText = theme.textTheme.labelLarge!;
    expect(notificationText.color, appLabelText.color);
    expect(notificationText.fontSize, appLabelText.fontSize);
    expect(notificationText.fontWeight, appLabelText.fontWeight);
    expect(notificationText.letterSpacing, appLabelText.letterSpacing);
    expect(snackShape.borderRadius, BorderRadius.circular(12));
    expect(snackShape.side.color, palette.accent.withValues(alpha: .64));
  });
}
