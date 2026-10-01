import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// The visual part of a toggle embedded in a larger, focusable row.
///
/// The parent owns input and semantics so a TV remote encounters one focus
/// target instead of a separate switch inside the row.
class TetoSwitchIndicator extends StatelessWidget {
  const TetoSwitchIndicator({
    required this.value,
    this.compact = false,
    super.key,
  });

  final bool value;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final width = compact ? 40.0 : 48.0;
    final height = compact ? 23.0 : 28.0;
    final thumbSize = height - 6;
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        width: width,
        height: height,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? palette.accentBright : palette.surfaceRaised,
          borderRadius: BorderRadius.circular(height),
          border: Border.all(
            color: value
                ? palette.accentBright
                : palette.primaryText.withValues(alpha: .18),
          ),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: thumbSize,
            height: thumbSize,
            decoration: BoxDecoration(
              color: value
                  ? contrastForeground(palette.accentBright)
                  : palette.mutedText,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
