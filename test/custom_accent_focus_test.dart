import 'dart:io';
import 'dart:ui' as ui;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:anime_tv/features/settings/presentation/theme_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _accents = {
  'dark purple': Color(0xFF5311A5),
  'dark blue': Color(0xFF143EA8),
};

AppThemePalette _palette(Color accent) => AppThemePalette.fromSeeds(
  background: AppThemePalette.defaults.background,
  surface: AppThemePalette.defaults.surface,
  accent: accent,
  primaryText: AppThemePalette.defaults.primaryText,
  mutedText: AppThemePalette.defaults.mutedText,
);

void _expectSameHue(Color actual, Color seed) {
  final source = HSLColor.fromColor(seed);
  final derived = HSLColor.fromColor(actual);
  final distance = (source.hue - derived.hue).abs();
  expect(
    distance < 1 || distance > 359,
    isTrue,
    reason: 'Interaction color must retain the selected accent hue.',
  );
  expect(
    derived.saturation,
    closeTo(source.saturation, .01),
    reason: 'A visible focus shade must not wash the accent toward white.',
  );
}

AnimatedContainer _focusSurface(WidgetTester tester, Finder scope) => tester
    .widgetList<AnimatedContainer>(
      find.descendant(of: scope, matching: find.byType(AnimatedContainer)),
    )
    .singleWhere((widget) {
      final decoration = widget.foregroundDecoration;
      return decoration is BoxDecoration && decoration.border?.top.width == 3;
    });

void _expectAccentFocus(
  WidgetTester tester,
  Finder scope,
  AppThemePalette palette,
) {
  final surface = _focusSurface(tester, scope);
  final border = (surface.foregroundDecoration! as BoxDecoration).border!;
  final decoration = surface.decoration! as BoxDecoration;
  expect(border.top.color, palette.focusRing);
  expect(
    border.top.width,
    3,
    reason: 'The established focus geometry stays unchanged.',
  );
  _expectSameHue(border.top.color, palette.accent);
  final glow = decoration.boxShadow!
      .where((shadow) => shadow.blurRadius > 0)
      .single;
  expect(glow.color, palette.focusGlow);
  expect(glow.blurRadius, 11);
  expect(glow.spreadRadius, 2);
  _expectSameHue(glow.color, palette.accent);
  final keylines = decoration.boxShadow!.where(
    (shadow) => shadow.blurRadius == 0,
  );
  for (final keyline in keylines) {
    expect(keyline.color, palette.focusInnerKeyline);
    expect(
      keyline.color.computeLuminance(),
      lessThan(.05),
      reason: 'A contrast keyline must stay dark, not become a white outline.',
    );
  }
  final insetBorders = tester
      .widgetList<DecoratedBox>(
        find.descendant(of: scope, matching: find.byType(DecoratedBox)),
      )
      .map((widget) => widget.decoration)
      .whereType<BoxDecoration>()
      .map((decoration) => decoration.border)
      .whereType<Border>()
      .where((border) => border.top.color == palette.focusInnerKeyline);
  for (final inset in insetBorders) {
    expect(inset.top.color.computeLuminance(), lessThan(.05));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_ACCENT_FOCUS');

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });
  if (capture) {
    setUpAll(() async {
      await (FontLoader(
        'Roboto',
      )..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))).load();
      // Flutter's test font otherwise draws the hexadecimal swatch labels as
      // solid blocks. Use the bundled readable glyphs for this capture only.
      await (FontLoader(
        'monospace',
      )..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
  }

  for (final entry in _accents.entries) {
    final palette = _palette(entry.value);
    test('${entry.key} interaction colors stay saturated and visible', () {
      _expectSameHue(palette.focusRing, entry.value);
      _expectSameHue(palette.focusGlow, entry.value);
      _expectSameHue(palette.focusInnerKeyline, entry.value);
      expect(palette.focusInnerKeyline.computeLuminance(), lessThan(.05));
      expect(palette.focusInnerKeyline.a, closeTo(.9, .001));
      expect(palette.focusGlow.a, closeTo(.6, .001));
      final oldFocus = Color.lerp(entry.value, Colors.white, .27)!;
      expect(
        palette.focusRing.computeLuminance(),
        closeTo(oldFocus.computeLuminance(), .005),
        reason:
            'Keep the previous visible focus contrast without its white tint.',
      );
    });

    for (final hover in [false, true]) {
      testWidgets(
        '${entry.key} ${hover ? 'mouse hover' : 'keyboard focus'} keeps themed outline',
        (tester) async {
          final focus = FocusNode();
          addTearDown(focus.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkFor(palette),
              home: Scaffold(
                body: Center(
                  child: TvFocusable(
                    key: const ValueKey('accent-control'),
                    focusNode: focus,
                    onPressed: () {},
                    child: const SizedBox(width: 240, height: 64),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final control = find.byKey(const ValueKey('accent-control'));
          if (hover) {
            final mouse = await tester.createGesture(
              kind: ui.PointerDeviceKind.mouse,
            );
            addTearDown(mouse.removePointer);
            await mouse.addPointer(location: Offset.zero);
            await mouse.moveTo(tester.getCenter(control));
          } else {
            focus.requestFocus();
          }
          await tester.pumpAndSettle();
          expect(focus.hasFocus, isTrue);
          _expectAccentFocus(tester, control, palette);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final builtIn in [false, true]) {
      testWidgets(
        '${entry.key} ${builtIn ? 'built-in' : 'native'} header search uses themed focus',
        (tester) async {
          FlutterSecureStorage.setMockInitialValues({
            'input_use_built_in_keyboard': builtIn.toString(),
          });
          final controller = TextEditingController();
          final focus = FocusNode();
          addTearDown(controller.dispose);
          addTearDown(focus.dispose);
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: AppTheme.darkFor(palette),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 460,
                      height: 60,
                      child: TvTextInput(
                        controller: controller,
                        focusNode: focus,
                        labelText: 'Search',
                        hintText: 'Search',
                        variant: TvTextInputVariant.headerSearch,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byType(TextField),
            builtIn ? findsNothing : findsOneWidget,
          );
          focus.requestFocus();
          await tester.pumpAndSettle();
          expect(focus.hasFocus, isTrue);
          _expectAccentFocus(tester, find.byType(TvTextInput), palette);
          expect(
            find.byType(TvKeyboardDialog),
            findsNothing,
            reason: 'Focus styling must not activate either keyboard.',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Theme Studio Primary text row keeps custom purple focus and hover',
    (tester) async {
      final palette = _palette(_accents['dark purple']!);
      final controller = ThemeStudioController(
        const FlutterSecureStorage(),
        readValue: (_) async => encodeThemeStudioState(
          ThemeStudioState(
            palette: palette,
            contrastGuardEnabled: false,
            loaded: true,
          ),
        ),
      );
      await controller.load();
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            themeStudioControllerProvider.overrideWith((_) => controller),
          ],
          child: MaterialApp(
            theme: AppTheme.darkFor(palette),
            home: RepaintBoundary(
              key: boundaryKey,
              child: const ThemeStudioScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final primary = find.byKey(const ValueKey('theme-color-primaryText'));
      final control = find.ancestor(
        of: primary,
        matching: find.byType(TvFocusable),
      );
      final detector = find.ancestor(
        of: primary,
        matching: find.byType(FocusableActionDetector),
      );
      final focus = tester.widget<FocusableActionDetector>(detector).focusNode!;
      for (var step = 0; step < 3; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(focus.hasFocus, isTrue);
      _expectAccentFocus(tester, control, palette);
      final before = tester.getSize(primary);
      focus.unfocus();
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(primary));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(tester.getSize(primary), before);
      _expectAccentFocus(tester, control, palette);
      expect(find.byKey(const ValueKey('theme-live-preview')), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (capture) {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final directory = await Directory(
              'build/accent-visuals',
            ).create(recursive: true);
            await File(
              '${directory.path}/theme-studio-purple-primary-text.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    },
  );
}
