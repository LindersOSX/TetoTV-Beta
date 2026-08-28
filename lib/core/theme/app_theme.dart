import 'package:anime_tv/core/theme/app_theme_palette.dart';
import 'package:flutter/material.dart';

export 'package:anime_tv/core/theme/app_theme_palette.dart';

/// Legacy constant aliases for code that has not yet adopted
/// `context.appPalette`. Their values remain the exact default TetoTV palette.
/// New shared widgets should read the [AppThemePalette] ThemeExtension so a
/// Theme Studio selection updates them automatically.
abstract final class AppColors {
  static const ink = Color(0xFF030303);
  static const panel = Color(0xFF101010);
  static const panelRaised = Color(0xFF1B0E12);
  static const selectableSurface = Color(0xFF271016);
  static const selectableSurfaceHover = Color(0xFF3B131D);
  static const textPrimary = Color(0xFFF8F5F6);
  static const textMuted = Color(0xFFB7AEB1);
  static const accent = Color(0xFFE52B50);
  static const accentBright = Color(0xFFFF496A);
  static const focusRing = Color(0xFFFF5C78);
  static const focusGlow = Color(0x99FF365C);
  static const focusInnerKeyline = Color(0xE6000000);
  static const cyan = Color(0xFFFF7188);
}

abstract final class AppTheme {
  /// The original palette, kept for tests and callers that do not install a
  /// Theme Studio provider.
  static final dark = darkFor(AppThemePalette.defaults);

  static ThemeData darkFor(AppThemePalette palette) {
    final accentForeground = contrastForeground(palette.accent);
    final scheme = ColorScheme.dark(
      primary: palette.accent,
      onPrimary: accentForeground,
      primaryContainer: palette.selectableSurface,
      onPrimaryContainer: palette.primaryText,
      secondary: palette.secondaryAccent,
      onSecondary: contrastForeground(palette.secondaryAccent),
      surface: palette.surface,
      onSurface: palette.primaryText,
      error: const Color(0xFFFF6B78),
      onError: Colors.black,
    );

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.background,
      cardColor: palette.surface,
      dialogTheme: DialogThemeData(backgroundColor: palette.surface),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        modalBackgroundColor: palette.surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.accent.withValues(alpha: .28),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? palette.primaryText
                : palette.mutedText,
          ),
        ),
      ),
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[palette],
      textTheme: TextTheme(
        displaySmall: TextStyle(
          color: palette.primaryText,
          fontSize: 38,
          height: 1.05,
          fontWeight: FontWeight.w800,
          letterSpacing: -1.2,
        ),
        headlineSmall: TextStyle(
          color: palette.primaryText,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: TextStyle(
          color: palette.primaryText,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: TextStyle(
          color: palette.primaryText,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: TextStyle(
          color: palette.mutedText,
          fontSize: 16,
          height: 1.45,
        ),
        bodyMedium: TextStyle(
          color: palette.mutedText,
          fontSize: 14,
          height: 1.35,
        ),
        labelLarge: TextStyle(
          color: palette.primaryText,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          letterSpacing: .2,
        ),
      ),
      iconTheme: IconThemeData(color: palette.primaryText),
      dividerColor: palette.primaryText.withValues(alpha: .08),
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      focusColor: palette.focusRing.withValues(alpha: .22),
      hoverColor: palette.accent.withValues(alpha: .18),
      highlightColor: palette.accent.withValues(alpha: .16),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accentBright,
        selectionColor: palette.accent.withValues(alpha: .40),
        selectionHandleColor: palette.accentBright,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.secondaryAccent,
        linearTrackColor: palette.surfaceRaised,
        circularTrackColor: palette.surfaceRaised,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.accent,
        inactiveTrackColor: palette.surfaceRaised,
        thumbColor: palette.accentBright,
        overlayColor: palette.focusGlow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceRaised,
        labelStyle: TextStyle(color: palette.mutedText),
        hintStyle: TextStyle(color: palette.mutedText),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: palette.primaryText.withValues(alpha: .12),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: palette.focusRing, width: 2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(palette.primaryText),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? palette.selectableSurfaceHover
                : palette.selectableSurface,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? BorderSide(color: palette.focusRing, width: 2)
                : BorderSide(color: palette.accent.withValues(alpha: .42)),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(palette.accent),
          foregroundColor: WidgetStatePropertyAll(accentForeground),
          overlayColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? palette.focusRing.withValues(alpha: .22)
                : null,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? BorderSide(color: palette.focusRing, width: 2)
                : BorderSide.none,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accentForeground
              : palette.mutedText,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.surfaceRaised,
        ),
      ),
    );
  }
}
