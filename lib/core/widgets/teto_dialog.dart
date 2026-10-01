import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:anime_tv/core/widgets/teto_backdrop_blur.dart';
import 'package:flutter/material.dart';

/// Uses Material's barrier, focus, theme capture, and Back behavior, with the
/// same short entrance/exit on every TetoTV dialog.
Future<T?> showTetoDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(
    _TetoDialogRoute<T>(
      context: context,
      builder: (context) => _TetoDialogRise(child: builder(context)),
      barrierDismissible: barrierDismissible,
      barrierColor:
          barrierColor ??
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          Colors.black54,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      settings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior:
          traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
      fullscreenDialog: fullscreenDialog,
      requestFocus: requestFocus,
      animationStyle: AnimationStyle(
        duration: TetoUiMotion.duration(context, TetoUiMotion.popup),
        reverseDuration: TetoUiMotion.duration(context, TetoUiMotion.popup),
        curve: TetoUiMotion.curve,
        reverseCurve: Curves.easeInCubic,
      ),
    ),
  );
}

// Blur the actual modal barrier, not a full-screen gesture-catching widget in
// the dialog body. Material still owns dismissal, focus, safe areas, and Back.
// Covered popups disable their filter so nested menus do not stack blurs.
mixin _TetoBlurredBarrier<T> on ModalRoute<T> {
  @override
  Widget buildModalBarrier() => TetoBackdropBlur(
    filterKey: const ValueKey('teto-modal-backdrop-blur'),
    enabled: isCurrent && !offstage,
    child: super.buildModalBarrier(),
  );
}

class _TetoDialogRoute<T> extends DialogRoute<T> with _TetoBlurredBarrier<T> {
  _TetoDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior,
    super.fullscreenDialog,
    super.requestFocus,
    super.animationStyle,
  });
}

/// Anchored menus share the same backdrop as ordinary TetoTV dialogs.
Future<T?> showTetoGeneralDialog<T>({
  required BuildContext context,
  required RoutePageBuilder pageBuilder,
  bool barrierDismissible = false,
  String? barrierLabel,
  Color barrierColor = const Color(0x80000000),
  Duration transitionDuration = const Duration(milliseconds: 200),
  RouteTransitionsBuilder? transitionBuilder,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  bool? requestFocus,
}) {
  assert(!barrierDismissible || barrierLabel != null);
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _TetoGeneralDialogRoute<T>(
      pageBuilder: pageBuilder,
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      barrierColor: barrierColor,
      transitionDuration: transitionDuration,
      transitionBuilder: transitionBuilder,
      settings: routeSettings,
      requestFocus: requestFocus,
    ),
  );
}

class _TetoGeneralDialogRoute<T> extends RawDialogRoute<T>
    with _TetoBlurredBarrier<T> {
  _TetoGeneralDialogRoute({
    required super.pageBuilder,
    super.barrierDismissible,
    super.barrierLabel,
    super.barrierColor,
    super.transitionDuration,
    super.transitionBuilder,
    super.settings,
    super.requestFocus,
  });
}

/// Mobile sheets keep their usual sizing, scrolling, dragging, and results.
Future<T?> showTetoModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  Color? backgroundColor,
  Color? barrierColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
}) {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final localizations = MaterialLocalizations.of(context);
  return navigator.push<T>(
    _TetoBottomSheetRoute<T>(
      builder: builder,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      backgroundColor: backgroundColor,
      modalBarrierColor:
          barrierColor ?? Theme.of(context).bottomSheetTheme.modalBarrierColor,
      barrierLabel: localizations.scrimLabel,
      barrierOnTapHint: localizations.scrimOnTapHint(
        localizations.bottomSheetLabel,
      ),
      shape: shape,
      constraints: constraints,
      sheetAnimationStyle: TetoUiMotion.reduced(context)
          ? AnimationStyle.noAnimation
          : null,
    ),
  );
}

class _TetoBottomSheetRoute<T> extends ModalBottomSheetRoute<T>
    with _TetoBlurredBarrier<T> {
  _TetoBottomSheetRoute({
    required super.builder,
    required super.isScrollControlled,
    super.capturedThemes,
    super.useSafeArea,
    super.isDismissible,
    super.enableDrag,
    super.backgroundColor,
    super.modalBarrierColor,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.shape,
    super.constraints,
    super.sheetAnimationStyle,
  });
}

class _TetoDialogRise extends StatelessWidget {
  const _TetoDialogRise({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (TetoUiMotion.reduced(context)) return child;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          0,
          4 * (1 - TetoUiMotion.curve.transform(animation.value)),
        ),
        child: child,
      ),
    );
  }
}

/// Matches the two anchored profile/notification menus to ordinary dialogs.
Widget tetoPopupTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (TetoUiMotion.reduced(context)) return child;
  final progress = animation.drive(CurveTween(curve: TetoUiMotion.curve));
  return FadeTransition(
    opacity: progress,
    child: AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 4 * (1 - progress.value)),
        child: child,
      ),
    ),
  );
}
