import 'dart:ui' as ui;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_artwork_scrim.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (background, scaffoldColor) in [
    (AppThemePalette.defaults.background, null),
    (const Color(0xFF132B39), null),
    (AppThemePalette.defaults.background, Colors.black),
  ]) {
    final canvas = scaffoldColor ?? background;
    testWidgets('hero blends smoothly into canvas $canvas', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkFor(
            AppThemePalette.defaults.copyWith(background: background),
          ),
          home: Scaffold(
            backgroundColor: scaffoldColor,
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('scrim-capture'),
                child: const SizedBox(
                  width: 200,
                  height: 200,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: Colors.white),
                      TetoArtworkScrim(hero: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final fade = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('hero-bottom-fade')),
      );
      final gradient =
          (fade.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      expect(gradient.colors.first.a, 0);
      expect(gradient.colors.last, canvas);
      expect(gradient.stops!.first, lessThan(.5));
      expect(gradient.stops!.last, 1);

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('scrim-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        List<int> pixel(int y) {
          final offset = (y * 200 + 190) * 4;
          return List.generate(
            3,
            (channel) => bytes!.getUint8(offset + channel),
          );
        }

        final target = [
          (canvas.r * 255).round(),
          (canvas.g * 255).round(),
          (canvas.b * 255).round(),
        ];
        final middle = pixel(100);
        final lower = pixel(170);
        final bottom = pixel(199);
        for (var channel = 0; channel < 3; channel++) {
          expect(bottom[channel], closeTo(target[channel], 2));
          expect(middle[channel], greaterThan(lower[channel]));
          expect(lower[channel], greaterThan(bottom[channel]));
        }
      });
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('non-hero artwork retains its existing contrast scrims', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: TetoArtworkScrim()),
      ),
    );
    final layers = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(TetoArtworkScrim),
            matching: find.byType(DecoratedBox),
          ),
        )
        .toList();
    final gradient =
        (layers.last.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, const [Colors.transparent, Color(0xB0000000)]);
    expect(gradient.stops, [.45, 1]);
    expect(find.byKey(const ValueKey('hero-bottom-fade')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(TetoArtworkScrim),
        matching: find.byType(IgnorePointer),
      ),
      findsOneWidget,
    );
  });
}
