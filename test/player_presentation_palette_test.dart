import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/player/presentation/player_presentation_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'default player palette preserves every legacy overlay color exactly',
    () {
      final palette = AppThemePalette.defaults;

      expect(palette.playerBackground(), Colors.black);
      expect(
        palette.playerSurface(defaultColor: const Color(0xF5080808)),
        const Color(0xF5080808),
      );
      expect(
        palette.playerRaisedSurface(defaultColor: const Color(0xEE391D29)),
        const Color(0xEE391D29),
      );
      expect(
        palette.playerSelectableSurface(defaultColor: const Color(0xA629292E)),
        const Color(0xA629292E),
      );
      expect(palette.playerPrimaryText(), Colors.white);
      expect(
        palette.playerMutedText(defaultColor: const Color(0xFFF0EAEC)),
        const Color(0xFFF0EAEC),
      );
      expect(palette.playerPrimaryActionText(), Colors.white);
    },
  );

  test('custom player palette keeps semantic roles and legacy opacity', () {
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF061522),
      surface: const Color(0xFF193448),
      accent: const Color(0xFF34AA6F),
      primaryText: const Color(0xFFF2E5D2),
      mutedText: const Color(0xFF90A8BA),
    );

    expect(palette.playerBackground(), palette.background);
    expect(
      palette.playerSurface(defaultColor: const Color(0xF5080808)),
      palette.surface.withValues(alpha: const Color(0xF5080808).a),
    );
    expect(
      palette.playerRaisedSurface(defaultColor: const Color(0xEE391D29)),
      palette.surfaceRaised.withValues(alpha: const Color(0xEE391D29).a),
    );
    expect(
      palette.playerSelectableSurface(defaultColor: const Color(0xA629292E)),
      palette.selectableSurface.withValues(alpha: const Color(0xA629292E).a),
    );
    expect(palette.playerPrimaryText(), palette.primaryText);
    expect(palette.playerMutedText(), palette.mutedText);
    expect(
      palette.playerPrimaryActionText(),
      contrastForeground(palette.accent),
    );
  });
}
