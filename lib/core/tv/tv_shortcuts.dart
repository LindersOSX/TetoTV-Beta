import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Maps the Android TV remote's center button to Flutter's standard activate
/// action. Arrow keys continue to use Flutter's directional focus traversal.
class TvShortcuts extends StatelessWidget {
  const TvShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
            onInvoke: _moveFocusOrScroll,
          ),
        },
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: child,
        ),
      ),
    );
  }
}

Object? _moveFocusOrScroll(DirectionalFocusIntent intent) {
  final focus = FocusManager.instance.primaryFocus;
  // Let Flutter's directional policy choose among visible controls. It
  // accounts for directional bands and avoids jumping across the screen to a
  // barely closer row. Screens with intentional cross-column movement define
  // an explicit focus graph in their own key handler.
  if (focus == null || _focusInDirectionIfMounted(focus, intent.direction)) {
    return null;
  }

  final context = focus.context;
  if (context == null) return null;
  final vertical =
      intent.direction == TraversalDirection.up ||
      intent.direction == TraversalDirection.down;
  final scrollable = Scrollable.maybeOf(
    context,
    axis: vertical ? Axis.vertical : Axis.horizontal,
  );
  if (scrollable == null || !scrollable.position.hasContentDimensions) {
    return null;
  }

  final direction = switch (intent.direction) {
    TraversalDirection.up || TraversalDirection.left => -1.0,
    TraversalDirection.down || TraversalDirection.right => 1.0,
  };
  final position = scrollable.position;
  final target = (position.pixels + direction * position.viewportDimension * .7)
      .clamp(position.minScrollExtent, position.maxScrollExtent);
  if ((target - position.pixels).abs() < 1) return null;

  unawaited(
    position
        .animateTo(
          target,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // The route, dialog, or focused control may have been replaced
            // while the scroll animation was running. FocusNode can retain a
            // context briefly during that transition even though its
            // FocusTraversalGroup has already gone away, which makes
            // focusInDirection throw from FocusTraversalGroup.of(). Only retry
            // for the same, fully mounted focus target.
            if (!identical(FocusManager.instance.primaryFocus, focus)) return;
            _focusInDirectionIfMounted(focus, intent.direction);
          });
        }),
  );
  return null;
}

bool _focusInDirectionIfMounted(FocusNode focus, TraversalDirection direction) {
  final context = focus.context;
  if (context == null || !context.mounted) return false;
  if (FocusTraversalGroup.maybeOf(context) == null) return false;
  try {
    return focus.focusInDirection(direction);
  } on FlutterError {
    // A focused route can be removed between the mounted/group checks above
    // and Flutter resolving its traversal policy. Treat that frame as having
    // no directional target; a later D-pad event will run against the new
    // focus tree instead of surfacing a framework exception.
    return false;
  }
}
