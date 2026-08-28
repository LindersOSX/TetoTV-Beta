import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_navigation.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tv_navigation_test_harness.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('explicit directional edges consume repeats and key-up safely', () {
    var moves = 0;
    const callbacks = TvDirectionalFocusCallbacks();
    expect(
      handleTvDirectionalFocusEvent(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        ),
        callbacks,
      ),
      KeyEventResult.ignored,
    );

    final edges = TvDirectionalFocusCallbacks(left: () => moves++);
    expect(
      handleTvDirectionalFocusEvent(
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowLeft,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          timeStamp: Duration.zero,
        ),
        edges,
      ),
      KeyEventResult.handled,
    );
    expect(moves, 1);
    expect(
      handleTvDirectionalFocusEvent(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.arrowLeft,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          timeStamp: Duration.zero,
        ),
        edges,
      ),
      KeyEventResult.handled,
    );
    expect(moves, 1, reason: 'key-up must not move focus a second time');
  });

  for (final builtInKeyboard in const [true, false]) {
    testWidgets('TV text input exposes every D-pad exit with the '
        '${builtInKeyboard ? 'Teto' : 'device'} keyboard selected', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({
        'input_use_built_in_keyboard': '$builtInKeyboard',
      });
      final controller = TextEditingController();
      final input = FocusNode(debugLabel: 'contract.input');
      final left = FocusNode(debugLabel: 'contract.left');
      final right = FocusNode(debugLabel: 'contract.right');
      final up = FocusNode(debugLabel: 'contract.up');
      final down = FocusNode(debugLabel: 'contract.down');
      addTearDown(controller.dispose);
      addTearDown(input.dispose);
      addTearDown(left.dispose);
      addTearDown(right.dispose);
      addTearDown(up.dispose);
      addTearDown(down.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: Column(
                children: [
                  _ContractButton(focusNode: up, label: 'Up'),
                  Row(
                    children: [
                      _ContractButton(focusNode: left, label: 'Left'),
                      Expanded(
                        child: TvTextInput(
                          controller: controller,
                          focusNode: input,
                          autofocus: true,
                          labelText: 'Room code',
                          onExitLeft: left.requestFocus,
                          onExitRight: right.requestFocus,
                          onExitUp: up.requestFocus,
                          onExitDown: down.requestFocus,
                        ),
                      ),
                      _ContractButton(focusNode: right, label: 'Right'),
                    ],
                  ),
                  _ContractButton(focusNode: down, label: 'Down'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final exit in <(LogicalKeyboardKey, FocusNode)>[
        (LogicalKeyboardKey.arrowLeft, left),
        (LogicalKeyboardKey.arrowRight, right),
        (LogicalKeyboardKey.arrowUp, up),
        (LogicalKeyboardKey.arrowDown, down),
      ]) {
        input.requestFocus();
        await tester.pump();
        await pressTvKey(tester, exit.$1);
        expect(FocusManager.instance.primaryFocus, same(exit.$2));
        expect(find.byType(TvKeyboardDialog), findsNothing);
      }
    });
  }

  testWidgets(
    'Right from the rail reveals the first page action after content scrolled',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = FocusNode(debugLabel: 'contract.content.first');
      final last = FocusNode(debugLabel: 'contract.content.last');
      final scroll = ScrollController();
      addTearDown(first.dispose);
      addTearDown(last.dispose);
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark,
            home: TetoTopLevelShell(
              preferences: const SettingsPreferences(loaded: true),
              activeDestination: TopNavigationDestination.myList,
              firstContentFocusNode: first,
              builder: (_, _) => SingleChildScrollView(
                controller: scroll,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ContractButton(focusNode: first, label: 'First action'),
                    const SizedBox(height: 1200),
                    _ContractButton(focusNode: last, label: 'Last action'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      last.requestFocus();
      await tester.pump();
      expect(scroll.offset, greaterThan(500));

      await tester.tap(find.byKey(const ValueKey('main-nav-my-list')));
      await tester.pump();
      expectTvFocus('top-level.active-navigation');
      await pressTvKey(tester, LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(first));
      expect(scroll.offset, lessThan(100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a pushed screen restores the last valid page focus on return', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = FocusNode(debugLabel: 'contract.return.first');
    final remembered = FocusNode(debugLabel: 'contract.return.remembered');
    addTearDown(first.dispose);
    addTearDown(remembered.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (routeContext) => TetoTopLevelShell(
              preferences: const SettingsPreferences(loaded: true),
              activeDestination: TopNavigationDestination.discover,
              firstContentFocusNode: first,
              builder: (_, _) => Row(
                children: [
                  _ContractButton(focusNode: first, label: 'First'),
                  _ContractButton(
                    focusNode: remembered,
                    label: 'Open child',
                    onPressed: () => Navigator.of(routeContext).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const Scaffold(body: Text('Child')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    remembered.requestFocus();
    await tester.pump();
    await pressTvKey(tester, LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Child'), findsOneWidget);

    Navigator.of(tester.element(find.text('Child'))).pop();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(remembered));
    expect(tester.takeException(), isNull);
  });
}

class _ContractButton extends StatelessWidget {
  const _ContractButton({
    required this.focusNode,
    required this.label,
    this.onPressed,
  });

  final FocusNode focusNode;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    onPressed: onPressed ?? () {},
    child: Padding(padding: const EdgeInsets.all(16), child: Text(label)),
  );
}
