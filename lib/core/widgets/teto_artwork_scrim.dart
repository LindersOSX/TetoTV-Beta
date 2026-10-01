import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Predictable contrast over backdrop artwork, without dimming foreground
/// posters, controls or text. Hero artwork stays visible away from the copy.
class TetoArtworkScrim extends StatelessWidget {
  const TetoArtworkScrim({this.hero = false, super.key});

  final bool hero;

  @override
  Widget build(BuildContext context) {
    final canvas = hero
        ? Scaffold.maybeOf(context)?.widget.backgroundColor ??
              context.appPalette.background
        : context.appPalette.background;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: hero ? Alignment.centerLeft : Alignment.topLeft,
                end: hero ? Alignment.centerRight : Alignment.bottomRight,
                colors: hero
                    ? const [
                        Color(0xF0000000),
                        Color(0xBA000000),
                        Color(0x48000000),
                      ]
                    : const [
                        Color(0xA8000000),
                        Color(0xBA000000),
                        Color(0xDC000000),
                      ],
                stops: const [0, .52, 1],
              ),
            ),
          ),
          DecoratedBox(
            key: hero ? const ValueKey('hero-bottom-fade') : null,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // Finish at the canvas color, not translucent black over the
                // artwork, so the following shelf has no visible hard seam.
                colors: hero
                    ? [
                        canvas.withValues(alpha: 0),
                        canvas.withValues(alpha: .12),
                        canvas.withValues(alpha: .45),
                        canvas.withValues(alpha: .80),
                        canvas,
                      ]
                    : const [Colors.transparent, Color(0xB0000000)],
                stops: hero ? const [.40, .58, .75, .90, 1] : const [.45, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
