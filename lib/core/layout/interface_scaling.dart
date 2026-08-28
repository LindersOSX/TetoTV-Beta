import 'dart:ui' show DisplayFeature;

import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';

double tvCanvasWidthForPhysicalPixels(double physicalWidth) {
  if (physicalWidth >= 3200) return 1600;
  if (physicalWidth >= 2400) return 1280;
  return 960;
}

bool useTelevisionCanvas({
  required bool detectedTelevision,
  required InterfaceMode mode,
}) => switch (mode) {
  InterfaceMode.automatic => detectedTelevision,
  InterfaceMode.television => true,
  InterfaceMode.phone => false,
};

double interfaceCanvasScale({
  required double logicalWidth,
  required double physicalWidth,
  required bool detectedTelevision,
  required InterfaceMode mode,
  required double userScale,
}) {
  final televisionCanvas = useTelevisionCanvas(
    detectedTelevision: detectedTelevision,
    mode: mode,
  );
  final baseScale = televisionCanvas
      ? logicalWidth / tvCanvasWidthForPhysicalPixels(physicalWidth)
      : 1.0;
  return (baseScale * userScale).clamp(.5, 3.0).toDouble();
}

/// Scales the application's logical canvas while always painting into the
/// complete native viewport.
///
/// A root [Transform.scale] cannot make its child larger than the constraints
/// it receives. At scales below 1.0 the child was therefore constrained to the
/// native viewport *before* it was painted smaller, which left empty bands on
/// the right and bottom. [FittedBox] deliberately lays out an exact virtual
/// canvas and maps that canvas back onto the complete viewport. It also maps
/// pointer coordinates through the same transform, so touch hit testing stays
/// aligned at every supported scale.
class InterfaceScaleViewport extends StatelessWidget {
  const InterfaceScaleViewport({
    required this.mediaQuery,
    required this.scale,
    required this.child,
    super.key,
  });

  final MediaQueryData mediaQuery;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safeScale = scale.isFinite && scale > 0 ? scale : 1.0;
    if ((safeScale - 1).abs() < .001) {
      return MediaQuery(data: mediaQuery, child: child);
    }

    final viewport = mediaQuery.size;
    final virtualSize = Size(
      viewport.width / safeScale,
      viewport.height / safeScale,
    );
    final scaledMediaQuery = mediaQuery.copyWith(
      size: virtualSize,
      devicePixelRatio: mediaQuery.devicePixelRatio * safeScale,
      padding: mediaQuery.padding / safeScale,
      viewPadding: mediaQuery.viewPadding / safeScale,
      viewInsets: mediaQuery.viewInsets / safeScale,
      systemGestureInsets: mediaQuery.systemGestureInsets / safeScale,
      displayFeatures: mediaQuery.displayFeatures
          .map((feature) => _scaleDisplayFeature(feature, safeScale))
          .toList(growable: false),
    );

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        clipBehavior: Clip.hardEdge,
        child: SizedBox.fromSize(
          size: virtualSize,
          child: MediaQuery(data: scaledMediaQuery, child: child),
        ),
      ),
    );
  }
}

DisplayFeature _scaleDisplayFeature(DisplayFeature feature, double scale) {
  final bounds = feature.bounds;
  return DisplayFeature(
    bounds: Rect.fromLTRB(
      bounds.left / scale,
      bounds.top / scale,
      bounds.right / scale,
      bounds.bottom / scale,
    ),
    type: feature.type,
    state: feature.state,
  );
}
