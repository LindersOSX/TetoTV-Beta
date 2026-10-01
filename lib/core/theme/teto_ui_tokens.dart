import 'package:flutter/material.dart';

/// Shared geometry for interactive, non-artwork surfaces.
abstract final class TetoUiSpace {
  static const compact = 8.0;
  static const control = 12.0;
  static const section = 24.0;
  static const pageCompact = 20.0;
  static const pageWide = 36.0;
  static const surfaceRadius = 16.0;
}

/// A small motion vocabulary keeps focus and page controls feeling related.
abstract final class TetoUiMotion {
  // 1.5x the previous focus speed: 120ms / 1.5 = 80ms. Keep page,
  // popup, artwork, and HUD motion independent of this faster feedback.
  static const focus = Duration(milliseconds: 80);
  static const reveal = Duration(milliseconds: 220);
  static const page = Duration(milliseconds: 180);
  static const popup = Duration(milliseconds: 160);
  static const artwork = Duration(milliseconds: 180);
  static const hud = Duration(milliseconds: 250);
  static const curve = Curves.easeOutCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  static Duration duration(BuildContext context, Duration normal) =>
      reduced(context) ? Duration.zero : normal;
}

/// Page changes keep the canvas steady and reveal the next screen quickly.
class TetoFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const TetoFadePageTransitionsBuilder();

  @override
  Duration get transitionDuration => TetoUiMotion.page;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (TetoUiMotion.reduced(context)) return child;
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: TetoUiMotion.curve)),
      child: child,
    );
  }
}
