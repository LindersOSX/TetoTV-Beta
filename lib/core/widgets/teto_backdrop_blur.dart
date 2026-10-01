import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';
import 'teto_blur_scope.dart';

/// A light, bounded backdrop effect. Its child is painted afterwards and stays
/// sharp; this never filters text, focus rings, artwork cards, or captions.
class TetoBackdropBlur extends StatelessWidget {
  const TetoBackdropBlur({
    required this.child,
    this.enabled = true,
    this.sigma = 3,
    this.filterKey,
    super.key,
  });

  final Widget child;
  final bool enabled;
  final double sigma;
  final Key? filterKey;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: BackdropFilter(
      key: filterKey,
      enabled: enabled && TetoBlurScope.enabledOf(context),
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    ),
  );
}
