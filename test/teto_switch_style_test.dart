import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_switch_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const palette = AppThemePalette.defaults;

  test(
    'material switches use the shared accent track and no white outline',
    () {
      final style = AppTheme.darkFor(palette).switchTheme;
      const selected = <WidgetState>{WidgetState.selected};
      const unselected = <WidgetState>{};

      expect(style.trackColor!.resolve(selected), palette.accentBright);
      expect(style.trackOutlineColor!.resolve(selected), palette.accentBright);
      expect(
        style.thumbColor!.resolve(selected),
        contrastForeground(palette.accentBright),
      );
      expect(style.trackColor!.resolve(unselected), palette.surfaceRaised);
      expect(
        style.trackOutlineColor!.resolve(unselected),
        palette.primaryText.withValues(alpha: .18),
      );
    },
  );

  testWidgets('embedded toggles use the same track and rounded outline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: const Scaffold(body: TetoSwitchIndicator(value: true)),
      ),
    );

    BoxDecoration track() =>
        tester
                .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration!
            as BoxDecoration;

    expect(track().color, palette.accentBright);
    expect((track().border! as Border).top.color, palette.accentBright);
    expect(track().borderRadius, BorderRadius.circular(28));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: const Scaffold(body: TetoSwitchIndicator(value: false)),
      ),
    );
    await tester.pumpAndSettle();

    expect(track().color, palette.surfaceRaised);
    expect(
      (track().border! as Border).top.color,
      palette.primaryText.withValues(alpha: .18),
    );
  });
}
