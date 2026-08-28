import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// The user-facing color roles in Theme Studio.
///
/// TetoTV intentionally exposes a small set of semantic seeds instead of
/// dozens of implementation colors. Derived colors keep focus, hover and
/// raised surfaces visually related while every screen can consume the same
/// [AppThemePalette] extension on phones and televisions.
enum AppThemeColorRole { background, surface, accent, primaryText, mutedText }

extension AppThemeColorRoleLabel on AppThemeColorRole {
  String get displayName => switch (this) {
    AppThemeColorRole.background => 'Background',
    AppThemeColorRole.surface => 'Panels & surfaces',
    AppThemeColorRole.accent => 'Accent, focus & hover',
    AppThemeColorRole.primaryText => 'Primary text',
    AppThemeColorRole.mutedText => 'Muted text',
  };

  String get description => switch (this) {
    AppThemeColorRole.background => 'App canvas and page backgrounds',
    AppThemeColorRole.surface => 'Cards, menus and dialog panels',
    AppThemeColorRole.accent => 'Selection, focus rings and primary actions',
    AppThemeColorRole.primaryText => 'Headings and important labels',
    AppThemeColorRole.mutedText => 'Descriptions and secondary labels',
  };
}

/// Semantic app colors supplied through [ThemeData.extensions].
///
/// [defaults] exactly preserves the original TetoTV red/black palette. Custom
/// themes store five opaque seed colors and derive the remaining roles so the
/// visual language stays coherent.
@immutable
class AppThemePalette extends ThemeExtension<AppThemePalette> {
  const AppThemePalette._({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.selectableSurface,
    required this.selectableSurfaceHover,
    required this.primaryText,
    required this.mutedText,
    required this.accent,
    required this.accentBright,
    required this.focusRing,
    required this.focusGlow,
    required this.focusInnerKeyline,
    required this.secondaryAccent,
  });

  factory AppThemePalette.fromSeeds({
    required Color background,
    required Color surface,
    required Color accent,
    required Color primaryText,
    required Color mutedText,
  }) {
    final normalizedBackground = _opaque(background);
    final normalizedSurface = _opaque(surface);
    final normalizedAccent = _opaque(accent);
    final normalizedPrimaryText = _opaque(primaryText);
    final normalizedMutedText = _opaque(mutedText);

    if (normalizedBackground == defaults.background &&
        normalizedSurface == defaults.surface &&
        normalizedAccent == defaults.accent &&
        normalizedPrimaryText == defaults.primaryText &&
        normalizedMutedText == defaults.mutedText) {
      return defaults;
    }

    final brightAccent = _mix(normalizedAccent, Colors.white, .16);
    final focus = _mix(normalizedAccent, Colors.white, .27);
    final foreground = contrastForeground(normalizedAccent);
    return AppThemePalette._(
      background: normalizedBackground,
      surface: normalizedSurface,
      surfaceRaised: _mix(normalizedSurface, normalizedAccent, .09),
      selectableSurface: _mix(normalizedSurface, normalizedAccent, .17),
      selectableSurfaceHover: _mix(normalizedSurface, normalizedAccent, .29),
      primaryText: normalizedPrimaryText,
      mutedText: normalizedMutedText,
      accent: normalizedAccent,
      accentBright: brightAccent,
      focusRing: focus,
      focusGlow: focus.withValues(alpha: .60),
      focusInnerKeyline: foreground.withValues(alpha: .90),
      secondaryAccent: _mix(normalizedAccent, Colors.white, .35),
    );
  }

  static const defaults = AppThemePalette._(
    background: Color(0xFF030303),
    surface: Color(0xFF101010),
    surfaceRaised: Color(0xFF1B0E12),
    selectableSurface: Color(0xFF271016),
    selectableSurfaceHover: Color(0xFF3B131D),
    primaryText: Color(0xFFF8F5F6),
    mutedText: Color(0xFFB7AEB1),
    accent: Color(0xFFE52B50),
    accentBright: Color(0xFFFF496A),
    focusRing: Color(0xFFFF5C78),
    focusGlow: Color(0x99FF365C),
    focusInnerKeyline: Color(0xE6000000),
    secondaryAccent: Color(0xFFFF7188),
  );

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color selectableSurface;
  final Color selectableSurfaceHover;
  final Color primaryText;
  final Color mutedText;
  final Color accent;
  final Color accentBright;
  final Color focusRing;
  final Color focusGlow;
  final Color focusInnerKeyline;
  final Color secondaryAccent;

  Color colorFor(AppThemeColorRole role) => switch (role) {
    AppThemeColorRole.background => background,
    AppThemeColorRole.surface => surface,
    AppThemeColorRole.accent => accent,
    AppThemeColorRole.primaryText => primaryText,
    AppThemeColorRole.mutedText => mutedText,
  };

  AppThemePalette withRole(AppThemeColorRole role, Color color) =>
      AppThemePalette.fromSeeds(
        background: role == AppThemeColorRole.background ? color : background,
        surface: role == AppThemeColorRole.surface ? color : surface,
        accent: role == AppThemeColorRole.accent ? color : accent,
        primaryText: role == AppThemeColorRole.primaryText
            ? color
            : primaryText,
        mutedText: role == AppThemeColorRole.mutedText ? color : mutedText,
      );

  @override
  AppThemePalette copyWith({
    Color? background,
    Color? surface,
    Color? accent,
    Color? primaryText,
    Color? mutedText,
  }) => AppThemePalette.fromSeeds(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    accent: accent ?? this.accent,
    primaryText: primaryText ?? this.primaryText,
    mutedText: mutedText ?? this.mutedText,
  );

  @override
  AppThemePalette lerp(covariant AppThemePalette? other, double t) {
    if (other == null) return this;
    return AppThemePalette._(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      selectableSurface: Color.lerp(
        selectableSurface,
        other.selectableSurface,
        t,
      )!,
      selectableSurfaceHover: Color.lerp(
        selectableSurfaceHover,
        other.selectableSurfaceHover,
        t,
      )!,
      primaryText: Color.lerp(primaryText, other.primaryText, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentBright: Color.lerp(accentBright, other.accentBright, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      focusGlow: Color.lerp(focusGlow, other.focusGlow, t)!,
      focusInnerKeyline: Color.lerp(
        focusInnerKeyline,
        other.focusInnerKeyline,
        t,
      )!,
      secondaryAccent: Color.lerp(secondaryAccent, other.secondaryAccent, t)!,
    );
  }

  @override
  int get hashCode =>
      Object.hash(background, surface, primaryText, mutedText, accent);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppThemePalette &&
          background == other.background &&
          surface == other.surface &&
          primaryText == other.primaryText &&
          mutedText == other.mutedText &&
          accent == other.accent;
}

extension AppThemePaletteContext on BuildContext {
  AppThemePalette get appPalette =>
      Theme.of(this).extension<AppThemePalette>() ?? AppThemePalette.defaults;
}

/// WCAG-style contrast checks used by Theme Studio's readability guard.
@immutable
class ThemeContrastReport {
  const ThemeContrastReport({required this.issues});

  factory ThemeContrastReport.forPalette(AppThemePalette palette) {
    final issues = <String>[];
    void requireRatio(
      String foregroundName,
      Color foreground,
      String backgroundName,
      Color background,
      double minimum,
    ) {
      final ratio = contrastRatio(foreground, background);
      if (ratio + .001 < minimum) {
        issues.add(
          '$foregroundName needs ${minimum.toStringAsFixed(1)}:1 contrast '
          'on $backgroundName (currently ${ratio.toStringAsFixed(1)}:1).',
        );
      }
    }

    requireRatio(
      'Primary text',
      palette.primaryText,
      'the background',
      palette.background,
      4.5,
    );
    requireRatio(
      'Primary text',
      palette.primaryText,
      'panels',
      palette.surface,
      4.5,
    );
    requireRatio(
      'Muted text',
      palette.mutedText,
      'the background',
      palette.background,
      3,
    );
    requireRatio('Muted text', palette.mutedText, 'panels', palette.surface, 3);
    requireRatio(
      'Focus color',
      palette.focusRing,
      'the background',
      palette.background,
      3,
    );
    requireRatio(
      'Focus color',
      palette.focusRing,
      'panels',
      palette.surface,
      3,
    );
    return ThemeContrastReport(issues: List.unmodifiable(issues));
  }

  final List<String> issues;
  bool get hasIssues => issues.isNotEmpty;
}

double contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + .05) / (darker + .05);
}

Color contrastForeground(Color background) =>
    contrastRatio(Colors.white, background) >=
        contrastRatio(Colors.black, background)
    ? Colors.white
    : Colors.black;

Color _opaque(Color value) => value.withValues(alpha: 1);

Color _mix(Color first, Color second, double amount) => Color.from(
  alpha: 1,
  red: lerpDouble(first.r, second.r, amount)!,
  green: lerpDouble(first.g, second.g, amount)!,
  blue: lerpDouble(first.b, second.b, amount)!,
);
