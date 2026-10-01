import 'package:anime_tv/core/theme/app_theme_palette.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
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
    final appLabelStyle = TextStyle(
      color: palette.primaryText,
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: .2,
    );
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
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: TetoFadePageTransitionsBuilder(),
          TargetPlatform.iOS: TetoFadePageTransitionsBuilder(),
          TargetPlatform.macOS: TetoFadePageTransitionsBuilder(),
          TargetPlatform.windows: TetoFadePageTransitionsBuilder(),
          TargetPlatform.linux: TetoFadePageTransitionsBuilder(),
          TargetPlatform.fuchsia: TetoFadePageTransitionsBuilder(),
        },
      ),
      fontFamilyFallback: const ['TetoDevanagari'],
      brightness: Brightness.dark,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.background,
      cardColor: palette.surface,
      dialogTheme: DialogThemeData(
        backgroundColor: TetoBoxStyle.fill(palette),
        surfaceTintColor: Colors.transparent,
        shape: TetoBoxStyle.shape(palette),
      ),
      cardTheme: CardThemeData(
        color: TetoBoxStyle.fill(palette),
        surfaceTintColor: Colors.transparent,
        shape: TetoBoxStyle.shape(palette),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: TetoBoxStyle.fill(palette),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: .72),
        elevation: 14,
        shape: TetoBoxStyle.shape(palette),
        textStyle: TextStyle(
          color: palette.primaryText,
          fontWeight: FontWeight.w800,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: TetoBoxStyle.fill(palette),
        actionTextColor: palette.accentBright,
        disabledActionTextColor: palette.mutedText,
        elevation: 12,
        // SnackBars are TetoTV's in-app notification surface. Reuse the
        // regular app label typography so notifications do not look like a
        // separate system UI layered over the app.
        contentTextStyle: appLabelStyle,
        shape: TetoBoxStyle.shape(palette),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: TetoBoxStyle.fill(palette),
        modalBackgroundColor: TetoBoxStyle.fill(palette),
        shape: TetoBoxStyle.shape(palette),
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
        labelLarge: appLabelStyle,
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
        fillColor: TetoBoxStyle.fill(palette),
        labelStyle: TextStyle(color: palette.mutedText),
        hintStyle: TextStyle(color: palette.mutedText),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
          borderSide: BorderSide(color: TetoBoxStyle.outline(palette)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
          borderSide: BorderSide(
            color: TetoBoxStyle.outline(palette, focused: true),
            width: 2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(TetoBoxStyle.shape(palette)),
          foregroundColor: WidgetStatePropertyAll(palette.primaryText),
          backgroundColor: WidgetStatePropertyAll(TetoBoxStyle.fill(palette)),
          side: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused)
                ? BorderSide(
                    color: TetoBoxStyle.outline(palette, focused: true),
                    width: 2,
                  )
                : BorderSide(color: TetoBoxStyle.outline(palette)),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
            ),
          ),
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
              ? contrastForeground(palette.accentBright)
              : palette.mutedText,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accentBright
              : palette.surfaceRaised,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accentBright
              : palette.primaryText.withValues(alpha: .18),
        ),
        trackOutlineWidth: const WidgetStatePropertyAll(1),
      ),
    );
  }
}
