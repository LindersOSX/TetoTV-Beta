import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';

/// The single visual treatment for back navigation on phone and TV.
class TetoBackButton extends StatelessWidget {
  const TetoBackButton({
    required this.onPressed,
    this.focusNode,
    this.onKeyEvent,
    this.autofocus = false,
    this.tooltip,
    super.key,
  });

  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final bool autofocus;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final label = tooltip ?? context.tr('Back');
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        enabled: onPressed != null,
        child: TvFocusable(
          autofocus: autofocus,
          focusNode: focusNode,
          onKeyEvent: onKeyEvent,
          enabled: onPressed != null,
          onPressed: onPressed ?? () {},
          borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
          child: Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: TetoBoxStyle.decoration(palette),
            child: Icon(Icons.arrow_back_rounded, color: palette.primaryText),
          ),
        ),
      ),
    );
  }
}
