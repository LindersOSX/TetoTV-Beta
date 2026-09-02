import 'dart:async';

import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Makes a visible one-time code focusable and copies it after two quick
/// pointer taps or remote Select presses.
///
/// Requiring two activations keeps a single navigation click from replacing
/// the clipboard. The child owns the code's visual styling, so adding this
/// interaction does not change its layout.
class CopyableCodeInteraction extends StatefulWidget {
  const CopyableCodeInteraction({
    required this.code,
    required this.child,
    required this.semanticsLabel,
    this.confirmationMessage = 'One-time code copied.',
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.activationWindow = const Duration(milliseconds: 900),
    super.key,
  });

  final String code;
  final Widget child;
  final String semanticsLabel;
  final String confirmationMessage;
  final FocusNode? focusNode;
  final BorderRadius borderRadius;
  final Duration activationWindow;

  @override
  State<CopyableCodeInteraction> createState() =>
      _CopyableCodeInteractionState();
}

class _CopyableCodeInteractionState extends State<CopyableCodeInteraction> {
  Timer? _activationTimer;
  int _activationCount = 0;

  @override
  void didUpdateWidget(CopyableCodeInteraction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.code != oldWidget.code) _resetActivation();
  }

  @override
  void dispose() {
    _activationTimer?.cancel();
    super.dispose();
  }

  void _activate() {
    _activationTimer?.cancel();
    _activationCount += 1;
    if (_activationCount >= 2) {
      _resetActivation();
      unawaited(_copy());
      return;
    }
    _activationTimer = Timer(widget.activationWindow, _resetActivation);
  }

  void _resetActivation() {
    _activationTimer?.cancel();
    _activationTimer = null;
    _activationCount = 0;
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Clipboard is unavailable on this device.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(widget.confirmationMessage)));
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${widget.semanticsLabel}. Double select to copy code.',
    hint: 'Double-click, double-tap, or press OK twice to copy.',
    button: true,
    child: TvFocusable(
      focusNode: widget.focusNode,
      onPressed: _activate,
      focusScale: 1.015,
      borderRadius: widget.borderRadius,
      child: ExcludeSemantics(child: widget.child),
    ),
  );
}
