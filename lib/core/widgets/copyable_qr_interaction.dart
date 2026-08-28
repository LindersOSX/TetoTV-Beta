import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Makes an existing QR widget focusable and copies its encoded URL after two
/// quick pointer clicks or remote Select presses.
///
/// QR destinations can be long, so the interaction copies the exact encoded
/// value instead of a shortened display label. A single activation has no
/// side effect, which prevents an accidental remote press from replacing the
/// clipboard.
class CopyableQrInteraction extends StatefulWidget {
  const CopyableQrInteraction({
    required this.data,
    required this.child,
    required this.semanticsLabel,
    this.confirmationMessage = 'QR link copied.',
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.activationWindow = const Duration(milliseconds: 900),
    this.hintText = 'Double-click or press OK twice to copy',
    this.showHint = true,
    super.key,
  });

  final String data;
  final Widget child;
  final String semanticsLabel;
  final String confirmationMessage;
  final FocusNode? focusNode;
  final BorderRadius borderRadius;
  final Duration activationWindow;
  final String hintText;
  final bool showHint;

  @override
  State<CopyableQrInteraction> createState() => _CopyableQrInteractionState();
}

class _CopyableQrInteractionState extends State<CopyableQrInteraction> {
  Timer? _activationTimer;
  int _activationCount = 0;

  @override
  void dispose() {
    _activationTimer?.cancel();
    super.dispose();
  }

  void _activate() {
    _activationTimer?.cancel();
    _activationCount += 1;
    if (_activationCount >= 2) {
      _activationCount = 0;
      unawaited(_copy());
      return;
    }
    _activationTimer = Timer(widget.activationWindow, () {
      _activationCount = 0;
    });
  }

  Future<void> _copy() async {
    _activationTimer?.cancel();
    try {
      await Clipboard.setData(ClipboardData(text: widget.data));
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
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${widget.semanticsLabel}. Double select to copy link.',
          button: true,
          child: TvFocusable(
            focusNode: widget.focusNode,
            onPressed: _activate,
            focusScale: 1.015,
            borderRadius: widget.borderRadius,
            child: ExcludeSemantics(child: widget.child),
          ),
        ),
        if (widget.showHint) ...[
          const SizedBox(height: 7),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 230),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.content_copy_rounded,
                  size: 12,
                  color: palette.mutedText,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    widget.hintText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.mutedText,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
