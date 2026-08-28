import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The four focus exits a TV text input or compact control row may expose.
///
/// A null callback deliberately leaves that direction to Flutter's traversal
/// policy. A non-null callback owns the packet at this semantic edge, including
/// key-up. Screens that support continuous held movement should share a
/// `TvDirectionalRepeatGate` at their stable ancestor.
@immutable
class TvDirectionalFocusCallbacks {
  const TvDirectionalFocusCallbacks({
    this.left,
    this.right,
    this.up,
    this.down,
  });

  final VoidCallback? left;
  final VoidCallback? right;
  final VoidCallback? up;
  final VoidCallback? down;

  VoidCallback? targetFor(LogicalKeyboardKey key) => switch (key) {
    LogicalKeyboardKey.arrowLeft => left,
    LogicalKeyboardKey.arrowRight => right,
    LogicalKeyboardKey.arrowUp => up,
    LogicalKeyboardKey.arrowDown => down,
    _ => null,
  };
}

/// Applies an explicit D-pad edge without changing Enter/Back behavior.
///
/// Use this at semantic boundaries where geometry alone is ambiguous: leaving
/// a text input, crossing from the first item in a row to the navigation rail,
/// or moving between stacked controls whose visual order must stay stable.
KeyEventResult handleTvDirectionalFocusEvent(
  KeyEvent event,
  TvDirectionalFocusCallbacks callbacks,
) {
  final target = callbacks.targetFor(event.logicalKey);
  if (target == null) return KeyEventResult.ignored;
  if (event is KeyDownEvent || event is KeyRepeatEvent) target();
  return KeyEventResult.handled;
}

/// Requests [node] and keeps its control visible in every enclosing scrollable.
///
/// Programmatic focus changes do not always receive Flutter's automatic
/// directional reveal. This helper is therefore used by shared navigation
/// chrome when it moves focus into page content. The keep-visible alignment
/// policy avoids recentering controls that are already on screen.
void requestTvFocusAndReveal(
  FocusNode node, {
  bool towardEnd = false,
  Duration duration = const Duration(milliseconds: 120),
}) {
  void focus() {
    final targetContext = node.context;
    if (targetContext == null || !node.canRequestFocus) return;
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final revealContext = node.context;
      if (revealContext == null || !node.hasFocus) return;
      unawaited(
        Scrollable.ensureVisible(
          revealContext,
          duration: duration,
          curve: Curves.easeOutCubic,
          alignmentPolicy: towardEnd
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ),
      );
    });
  }

  if (node.context != null) {
    focus();
  } else {
    WidgetsBinding.instance.addPostFrameCallback((_) => focus());
  }
}
