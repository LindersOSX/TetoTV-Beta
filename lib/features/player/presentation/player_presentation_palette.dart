import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Player-specific color compatibility helpers.
///
/// The default Theme Studio palette keeps the exact colors used by the
/// established player UI. Custom palettes replace the RGB channels while
/// retaining each overlay's original opacity and semantic surface role.
extension PlayerPresentationPalette on AppThemePalette {
  bool get usesDefaultPlayerPalette => this == AppThemePalette.defaults;

  Color playerBackground({Color defaultColor = Colors.black}) =>
      _preserveDefault(defaultColor, background);

  Color playerSurface({Color defaultColor = const Color(0xFF080808)}) =>
      _preserveDefault(defaultColor, surface);

  Color playerRaisedSurface({Color defaultColor = const Color(0xFF1B1B1B)}) =>
      _preserveDefault(defaultColor, surfaceRaised);

  Color playerSelectableSurface({
    Color defaultColor = const Color(0xFF1B1B1B),
  }) => _preserveDefault(defaultColor, selectableSurface);

  Color playerPrimaryText({Color defaultColor = Colors.white}) =>
      _preserveDefault(defaultColor, primaryText);

  Color playerMutedText({Color? defaultColor}) =>
      _preserveDefault(defaultColor ?? mutedText, mutedText);

  Color playerPrimaryActionText({Color defaultColor = Colors.white}) =>
      _preserveDefault(defaultColor, contrastForeground(accent));

  Color _preserveDefault(Color defaultColor, Color themedColor) =>
      usesDefaultPlayerPalette
      ? defaultColor
      : themedColor.withValues(alpha: defaultColor.a);
}
