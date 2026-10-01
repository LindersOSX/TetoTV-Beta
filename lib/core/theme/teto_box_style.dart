import 'package:anime_tv/core/theme/app_theme_palette.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:flutter/material.dart';

/// Shared surface treatment for non-artwork controls across the app.
///
/// Artwork, video, and hero panels intentionally keep their own framing.
abstract final class TetoBoxStyle {
  static const radius = TetoUiSpace.surfaceRadius;

  static Color fill(AppThemePalette palette) => Color.alphaBlend(
    palette.primaryText.withValues(alpha: .035),
    palette.surface,
  );

  static Color outline(AppThemePalette palette, {bool focused = false}) =>
      focused ? palette.accentBright : palette.mutedText.withValues(alpha: .25);

  static RoundedRectangleBorder shape(
    AppThemePalette palette, {
    bool focused = false,
    double cornerRadius = radius,
  }) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(cornerRadius),
    side: BorderSide(
      color: outline(palette, focused: focused),
      width: focused ? 2 : 1,
    ),
  );

  static BoxDecoration decoration(
    AppThemePalette palette, {
    bool focused = false,
    Color? color,
    double cornerRadius = radius,
  }) => BoxDecoration(
    color: color ?? fill(palette),
    borderRadius: BorderRadius.circular(cornerRadius),
    border: Border.all(
      color: outline(palette, focused: focused),
      width: focused ? 2 : 1,
    ),
    boxShadow: focused
        ? [BoxShadow(color: palette.focusGlow, blurRadius: 11, spreadRadius: 2)]
        : null,
  );

  /// Artwork-backed panels share the same quiet glass surface as details.
  /// Only the background is translucent; text and outer focus stay crisp.
  static BoxDecoration translucentPanelDecoration(AppThemePalette palette) =>
      BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.surface.withValues(alpha: .78),
            palette.background.withValues(alpha: .66),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: outline(palette)),
      );

  /// Stable control interiors; focus is painted by the shared TV wrapper.
  static BoxDecoration translucentControlDecoration(AppThemePalette palette) =>
      BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            fill(palette).withValues(alpha: .80),
            fill(palette).withValues(alpha: .62),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: palette.mutedText.withValues(alpha: .18)),
      );
}
