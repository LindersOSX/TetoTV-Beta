import 'dart:io';
import 'dart:ui' as ui;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_KEYBOARD_REFRESH');
  if (capture) {
    setUpAll(() async {
      await (FontLoader(
        'Roboto',
      )..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
  }

  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  Finder key(String id) => find.byKey(ValueKey('tv-keyboard-key-$id'));
  FocusNode node(WidgetTester tester, String id) => tester
      .widget<FocusableActionDetector>(
        find.descendant(
          of: key(id),
          matching: find.byType(FocusableActionDetector),
        ),
      )
      .focusNode!;

  Future<void> mount(
    WidgetTester tester, {
    bool numeric = false,
    Size size = const Size(960, 540),
    double textScale = 1,
    String initial = '',
    int? maxLength,
    bool obscure = false,
    List<TextInputFormatter> formatters = const [],
    AppThemePalette? palette,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette ?? AppThemePalette.defaults),
        home: Scaffold(
          body: TvShortcuts(
            child: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(textScale),
              ),
              child: RepaintBoundary(
                key: const ValueKey('keyboard-capture'),
                child: TvKeyboardDialog(
                  title: numeric ? 'Episode number' : 'Search anime',
                  initialValue: initial,
                  numericOnly: numeric,
                  maxLength: maxLength,
                  obscureText: obscure,
                  inputFormatters: formatters,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('keyboard-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final output = File('build/qa/keyboard-refresh-$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  testWidgets(
    'reference rows align, space/submit are wider, focus is outer-only',
    (tester) async {
      await mount(tester);
      final q = tester.getRect(key('text-0-0'));
      final a = tester.getRect(key('text-1-0'));
      final digit = tester.getRect(key('number-1'));
      expect(q.left, closeTo(a.left, .1));
      expect(q.width, closeTo(a.width, .1));
      expect(digit.width, closeTo(q.width, .1));
      expect(digit.bottom, lessThan(q.top));
      expect(tester.getRect(key('space')).width, greaterThan(q.width * 3));
      expect(tester.getRect(key('submit')).width, greaterThan(q.width * 1.5));
      expect(node(tester, 'text-0-0').hasPrimaryFocus, isTrue);
      final focused = find.descendant(
        of: key('text-0-0'),
        matching: find.byType(AnimatedContainer),
      );
      final decoration =
          tester.widget<AnimatedContainer>(focused).foregroundDecoration!
              as BoxDecoration;
      expect(decoration.color, Colors.transparent);
      expect(decoration.border!.top.color, AppThemePalette.defaults.focusRing);
      await screenshot(tester, 'qwerty');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('D-pad travels between letters and top numbers without typing', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(node(tester, 'text-0-1').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(node(tester, 'number-2').hasPrimaryFocus, isTrue);
    expect(find.text('Start typing…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('2'), findsNWidgets(2));
  });

  for (final numeric in [false, true]) {
    testWidgets(
      '${numeric ? 'numpad' : 'keyboard'} focus paints immediately without animation',
      (tester) async {
        await mount(tester, numeric: numeric);
        for (final widget in tester.widgetList<AnimatedScale>(
          find.byType(AnimatedScale),
        )) {
          expect(widget.duration, Duration.zero);
          expect(widget.scale, 1);
        }
        for (final widget in tester.widgetList<AnimatedContainer>(
          find.byType(AnimatedContainer),
        )) {
          expect(widget.duration, Duration.zero);
        }
        for (final widget in tester.widgetList<AnimatedOpacity>(
          find.byType(AnimatedOpacity),
        )) {
          expect(widget.duration, Duration.zero);
        }

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        final focusedId = numeric ? 'number-2' : 'text-0-1';
        expect(node(tester, focusedId).hasPrimaryFocus, isTrue);
        // Check the painted decoration, not just the animation's target.
        final paintedRing = tester.widget<DecoratedBox>(
          find.descendant(
            of: key(focusedId),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.position == DecorationPosition.foreground,
            ),
          ),
        );
        final decoration = paintedRing.decoration as BoxDecoration;
        expect(
          decoration.border!.top.color,
          AppThemePalette.defaults.focusRing,
        );
        expect(decoration.color, Colors.transparent);
        await tester.pump();
        expect(tester.binding.transientCallbackCount, 0);
        expect(find.text('Start typing…'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mode switches on key down and reuses every character focus slot',
    (tester) async {
      await mount(tester);
      final ids = [
        for (var row = 0; row < 3; row++)
          for (var column = 0; column < (row == 2 ? 8 : 10); column++)
            'text-$row-$column',
      ];
      final nodes = {for (final id in ids) id: node(tester, id)};
      final rectangles = {for (final id in ids) id: tester.getRect(key(id))};
      final modeNode = node(tester, 'symbols');
      modeNode.requestFocus();
      await tester.pump();
      await tester.pump();

      for (var change = 0; change < 12; change++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
        // No elapsed time or pumpAndSettle is needed to change modes.
        await tester.pump();
        final symbols = change.isEven;
        expect(find.text(symbols ? 'ABC' : '123?'), findsOneWidget);
        expect(
          find.descendant(
            of: key('text-0-0'),
            matching: find.text(symbols ? '!' : 'q'),
          ),
          findsOneWidget,
        );
        expect(modeNode.hasPrimaryFocus, isTrue);
        for (final id in ids) {
          expect(node(tester, id), same(nodes[id]));
          expect(tester.getRect(key(id)), rectangles[id]);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
        await tester.pump();
        await tester.pump();
        expect(tester.binding.transientCallbackCount, 0);
      }

      // Reused slots must still type their current glyph, not a stale callback.
      await tester.tap(key('text-0-0'));
      await tester.pump();
      await tester.tap(key('symbols'));
      await tester.pump();
      await tester.tap(key('text-0-0'));
      await tester.pump();
      expect(find.text('q!'), findsOneWidget);
      await tester.tap(key('shift'));
      await tester.pump();
      await tester.tap(key('text-0-0'));
      await tester.pump();
      expect(find.text('q!Q'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shifted letters, number symbols, and cursor editing work', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(key('shift'));
    await tester.pump();
    await tester.tap(key('text-0-0'));
    await tester.pump();
    expect(find.text('Q'), findsOneWidget);
    await tester.tap(key('shift'));
    await tester.pump();
    await tester.tap(key('number-2'));
    await tester.pump();
    expect(find.text('Q@'), findsOneWidget);
    await tester.tap(key('cursor-left'));
    await tester.tap(key('text-0-1'));
    await tester.pump();
    expect(find.text('Qw@'), findsOneWidget);
    await tester.tap(key('backspace'));
    await tester.pump();
    expect(find.text('Q@'), findsOneWidget);
    await tester.tap(key('symbols'));
    await tester.pumpAndSettle();
    expect(find.text('ABC'), findsOneWidget);
    await tester.tap(key('text-0-0'));
    await tester.pump();
    expect(find.text('Q!@'), findsOneWidget);
  });

  testWidgets(
    'number-only pad is compact and all digit keys have equal dimensions',
    (tester) async {
      await mount(tester, numeric: true, initial: '13');
      final panel = tester.getRect(
        find.byKey(const ValueKey('tv-keyboard-panel')),
      );
      expect(panel.width, closeTo(264 * .85, .1));
      expect(panel.center.dx, closeTo(480, .1));
      final first = tester.getSize(key('number-1'));
      expect(first.height, closeTo(48 * .85, .1));
      expect(first.width / first.height, inInclusiveRange(1.3, 1.7));
      for (final id in ['2', '3', '4', '5', '6', '7', '8', '9', '0']) {
        expect(tester.getSize(key('number-$id')), first);
      }
      expect(find.text('q'), findsNothing);
      expect(node(tester, 'number-1').hasPrimaryFocus, isTrue);
      expect(
        tester.getRect(key('submit')).width,
        closeTo(tester.getRect(key('cancel')).width * 2, .1),
      );
      await screenshot(tester, 'numpad');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'number-only pad rejects physical letters and preserves length rules',
    (tester) async {
      await mount(
        tester,
        numeric: true,
        initial: '1',
        maxLength: 2,
        formatters: [FilteringTextInputFormatter.allow(RegExp('[1-8]'))],
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
      await tester.pump();
      await tester.tap(key('number-9'));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tv-keyboard-input')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      await tester.tap(key('number-2'));
      await tester.tap(key('number-3'));
      await tester.pump();
      expect(find.text('12'), findsOneWidget);
    },
  );

  testWidgets('paste, clear and password reveal remain available', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': 'secret\ntext'} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await mount(tester, obscure: true);
    await tester.tap(key('paste'));
    await tester.pumpAndSettle();
    expect(find.text('secrettext'), findsNothing);
    expect(find.text('••••••••••'), findsOneWidget);
    await tester.tap(key('reveal'));
    await tester.pump();
    expect(find.text('secrettext'), findsOneWidget);
    await tester.tap(key('clear'));
    await tester.pump();
    expect(find.text('Start typing…'), findsOneWidget);
  });

  for (final size in [
    const Size(360, 640),
    const Size(640, 360),
    const Size(960, 540),
    const Size(1280, 720),
  ]) {
    for (final numeric in [false, true]) {
      testWidgets(
        '${size.width}x${size.height} ${numeric ? 'numpad' : 'keyboard'} fits at enlarged text scale',
        (tester) async {
          await mount(tester, numeric: numeric, size: size, textScale: 1.4);
          final rect = tester.getRect(
            find.byKey(const ValueKey('tv-keyboard-panel')),
          );
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
