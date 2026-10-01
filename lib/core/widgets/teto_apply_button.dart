import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:flutter/material.dart';

/// One theme-aware treatment for committing a draft, setup, or filter choice.
/// Focus adds only an outline and glow; the accent fill never changes.
class TetoApplyButton extends StatefulWidget {
  const TetoApplyButton({
    required this.onPressed,
    required this.label,
    this.icon = const Icon(Icons.check_rounded),
    this.enabled = true,
    this.buttonKey,
    this.focusNode,
    this.onKeyEvent,
    super.key,
  });

  final VoidCallback? onPressed;
  final String label;
  final Widget icon;

  /// A callback with [enabled] false keeps an idle action reachable by remote,
  /// but cannot commit changes. A null callback is fully disabled as usual.
  final bool enabled;
  final Key? buttonKey;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<TetoApplyButton> createState() => _TetoApplyButtonState();
}

class _TetoApplyButtonState extends State<TetoApplyButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final enabled = widget.enabled && widget.onPressed != null;
    final label = context.tr(widget.label);
    return Focus(
      canRequestFocus: false,
      includeSemantics: false,
      onKeyEvent: widget.onKeyEvent,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: AnimatedContainer(
        duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
        curve: TetoUiMotion.curve,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: palette.focusGlow,
                    blurRadius: 11,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Semantics(
          label: label,
          button: true,
          enabled: enabled,
          focusable: widget.onPressed != null,
          focused: widget.onPressed != null ? _focused : null,
          onTap: enabled ? widget.onPressed : null,
          child: ExcludeSemantics(
            child: FilledButton.icon(
              key: widget.buttonKey,
              focusNode: widget.focusNode,
              onPressed: enabled
                  ? widget.onPressed
                  : widget.onPressed != null
                  ? () {}
                  : null,
              style: ButtonStyle(
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
                  ),
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => !enabled || states.contains(WidgetState.disabled)
                      ? palette.surfaceRaised
                      : palette.accent,
                ),
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => !enabled || states.contains(WidgetState.disabled)
                      ? palette.mutedText
                      : contrastForeground(palette.accent),
                ),
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                side: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.focused) ||
                          states.contains(WidgetState.hovered)
                      ? BorderSide(color: palette.focusRing, width: 2)
                      : BorderSide.none,
                ),
              ),
              icon: widget.icon,
              label: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}
