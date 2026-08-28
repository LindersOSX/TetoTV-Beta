import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/interaction_sound_scope.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('focus ring uses bright Teto red with dark contrast keylines', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFocusable(
            autofocus: true,
            onPressed: () {},
            child: const ColoredBox(
              color: Color(0xFFE52B50),
              child: SizedBox(width: 100, height: 60),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final animated = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    final decoration = animated.decoration! as BoxDecoration;
    final foreground = animated.foregroundDecoration! as BoxDecoration;
    expect(foreground.border!.top.color, AppColors.focusRing);
    expect(decoration.boxShadow, hasLength(2));
    expect(decoration.boxShadow!.last.color, AppColors.focusGlow);
    expect(
      decoration.boxShadow!.map((shadow) => shadow.color),
      isNot(contains(Colors.white)),
    );
  });

  testWidgets('mouse hover receives the same Teto-red focus treatment', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TvFocusable(
              onPressed: () {},
              child: const SizedBox(width: 100, height: 60),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    tester
        .widget<FocusableActionDetector>(find.byType(FocusableActionDetector))
        .onShowHoverHighlight!(true);
    await tester.pumpAndSettle();

    final animated = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    final foreground = animated.foregroundDecoration! as BoxDecoration;
    expect(foreground.border!.top.color, AppColors.focusRing);
  });

  testWidgets('touch press keeps activation and uses the shared red state', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TvFocusable(
              onPressed: () => calls++,
              child: const SizedBox(width: 100, height: 60),
            ),
          ),
        ),
      ),
    );

    final touch = await tester.startGesture(
      tester.getCenter(find.byType(TvFocusable)),
    );
    await tester.pump();
    final pressed = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    final foreground = pressed.foregroundDecoration! as BoxDecoration;
    expect(foreground.border!.top.color, AppColors.focusRing);

    await touch.up();
    await tester.pump();
    expect(calls, 1);
  });

  test('shared Material controls use dark-red idle and bright-red focus', () {
    final style = AppTheme.dark.outlinedButtonTheme.style!;
    expect(style.backgroundColor!.resolve({}), AppColors.selectableSurface);
    expect(
      style.backgroundColor!.resolve({WidgetState.hovered}),
      AppColors.selectableSurfaceHover,
    );
    expect(
      style.side!.resolve({WidgetState.focused})!.color,
      AppColors.focusRing,
    );
  });

  testWidgets('TV activation plays the platform click sound', (tester) async {
    final platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFocusable(
            autofocus: true,
            onPressed: () {},
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(
      platformCalls,
      contains(
        isA<MethodCall>()
            .having((call) => call.method, 'method', 'SystemSound.play')
            .having((call) => call.arguments, 'sound', 'SystemSoundType.click'),
      ),
    );
  });

  testWidgets('D-pad hold invokes the secondary TV action only', (
    tester,
  ) async {
    var primaryCalls = 0;
    var secondaryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFocusable(
            autofocus: true,
            onPressed: () => primaryCalls++,
            onLongPress: () => secondaryCalls++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 700));
    expect(primaryCalls, 0);
    expect(secondaryCalls, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 200));

    expect(primaryCalls, 0);
    expect(secondaryCalls, 1);
  });

  testWidgets('short D-pad select keeps the primary TV action', (tester) async {
    var primaryCalls = 0;
    var secondaryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFocusable(
            autofocus: true,
            onPressed: () => primaryCalls++,
            onLongPress: () => secondaryCalls++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 179));
    expect(primaryCalls, 0);
    expect(secondaryCalls, 0);
    await tester.pump(const Duration(milliseconds: 1));

    expect(primaryCalls, 1);
    expect(secondaryCalls, 0);
  });

  testWidgets('held Select still activates a press-only control once', (
    tester,
  ) async {
    var primaryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFocusable(
            autofocus: true,
            onPressed: () => primaryCalls++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(primaryCalls, 1);
  });

  testWidgets('gamepad A hold invokes the secondary TV action', (tester) async {
    var primaryCalls = 0;
    var secondaryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFocusable(
            autofocus: true,
            onPressed: () => primaryCalls++,
            onLongPress: () => secondaryCalls++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump(const Duration(milliseconds: 200));

    expect(primaryCalls, 0);
    expect(secondaryCalls, 1);
  });

  testWidgets('duplicate Chromecast key-down packets preserve a long press', (
    tester,
  ) async {
    var primaryCalls = 0;
    var secondaryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFocusable(
            autofocus: true,
            onPressed: () => primaryCalls++,
            onLongPress: () => secondaryCalls++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.select,
      physicalKey: PhysicalKeyboardKey.select,
    );
    await tester.pump(const Duration(milliseconds: 350));
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.select,
        logicalKey: LogicalKeyboardKey.select,
        timeStamp: Duration(milliseconds: 350),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.select,
      physicalKey: PhysicalKeyboardKey.select,
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(primaryCalls, 0);
    expect(secondaryCalls, 1);
  });

  testWidgets(
    'rapid Chromecast down-up pairs become one long press on final release',
    (tester) async {
      var primaryCalls = 0;
      var secondaryCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvFocusable(
              autofocus: true,
              onPressed: () => primaryCalls++,
              onLongPress: () => secondaryCalls++,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      await tester.pump();

      for (var packet = 0; packet < 5; packet++) {
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.select,
          physicalKey: PhysicalKeyboardKey.select,
        );
        await tester.pump(const Duration(milliseconds: 80));
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.select,
          physicalKey: PhysicalKeyboardKey.select,
        );
        expect(primaryCalls, 0);
        expect(secondaryCalls, 0);
        if (packet < 4) {
          await tester.pump(const Duration(milliseconds: 80));
          expect(primaryCalls, 0);
          expect(secondaryCalls, 0);
        }
      }

      await tester.pump(const Duration(milliseconds: 179));
      expect(primaryCalls, 0);
      expect(secondaryCalls, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(primaryCalls, 0);
      expect(secondaryCalls, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(primaryCalls, 0);
      expect(secondaryCalls, 1);
    },
  );

  testWidgets('held Select cannot activate a dialog action before release', (
    tester,
  ) async {
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TvFocusable(
              autofocus: true,
              onPressed: () {},
              onLongPress: () {
                showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Manage show'),
                    actions: [
                      TextButton(
                        autofocus: true,
                        onPressed: () {
                          confirmed = true;
                          Navigator.of(context).pop();
                        },
                        child: const Text('Confirm'),
                      ),
                    ],
                  ),
                );
              },
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Manage show'), findsNothing);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Manage show'), findsOneWidget);
    expect(confirmed, isFalse);
  });

  testWidgets('D-pad scrolls a virtualized list when focus reaches its edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TvShortcuts(
          child: Scaffold(
            body: SizedBox(
              height: 180,
              child: ListView.builder(
                itemExtent: 90,
                itemCount: 30,
                itemBuilder: (context, index) => TvFocusable(
                  autofocus: index == 0,
                  onPressed: () {},
                  child: Text('Item $index'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var index = 0; index < 8; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'focusing an already visible control does not recenter the list',
    (tester) async {
      final first = FocusNode(debugLabel: 'visible.first');
      final second = FocusNode(debugLabel: 'visible.second');
      final controller = ScrollController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                controller: controller,
                children: [
                  TvFocusable(
                    focusNode: first,
                    autofocus: true,
                    onPressed: () {},
                    child: const SizedBox(height: 50),
                  ),
                  const SizedBox(height: 155),
                  TvFocusable(
                    focusNode: second,
                    onPressed: () {},
                    child: const SizedBox(height: 50),
                  ),
                  const SizedBox(height: 300),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, 0);

      second.requestFocus();
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
      expect(FocusManager.instance.primaryFocus, second);
    },
  );

  testWidgets('click sound toggle suppresses activation audio', (tester) async {
    final platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InteractionSoundScope(
          navigationEnabled: true,
          clickEnabled: false,
          child: Scaffold(
            body: TvFocusable(
              autofocus: true,
              onPressed: () {},
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    platformCalls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(
      platformCalls.where((call) => call.method == 'SystemSound.play'),
      isEmpty,
    );
  });

  testWidgets('navigation sound follows directional focus toggle', (
    tester,
  ) async {
    final platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    Widget app({required bool navigationEnabled}) => MaterialApp(
      home: InteractionSoundScope(
        navigationEnabled: navigationEnabled,
        clickEnabled: false,
        child: TvShortcuts(
          child: Scaffold(
            body: Row(
              children: [
                TvFocusable(
                  autofocus: true,
                  onPressed: () {},
                  child: const SizedBox(width: 100, height: 100),
                ),
                TvFocusable(
                  onPressed: () {},
                  child: const SizedBox(width: 100, height: 100),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app(navigationEnabled: true));
    await tester.pumpAndSettle();
    platformCalls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      platformCalls.where((call) => call.method == 'SystemSound.play'),
      isNotEmpty,
    );

    await tester.pumpWidget(app(navigationEnabled: false));
    await tester.pumpAndSettle();
    platformCalls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      platformCalls.where((call) => call.method == 'SystemSound.play'),
      isEmpty,
    );
  });
}
