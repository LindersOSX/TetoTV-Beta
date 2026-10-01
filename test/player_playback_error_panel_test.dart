import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/player/presentation/player_playback_error_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _message =
    'Could not connect to TorBox. Check your internet connection '
    'and DNS, then retry. Your account is still linked.';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    bool locked = false,
    bool nextStream = true,
    double textScale = 1,
    VoidCallback? retry,
    VoidCallback? next,
    VoidCallback? choose,
    VoidCallback? dismiss,
    VoidCallback? exit,
    FocusOnKeyEventCallback? parentKey,
  }) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: TvShortcuts(
          child: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: Focus(
                onKeyEvent: parentKey,
                child: PlayerPlaybackErrorPanel(
                  message: _message,
                  controlsLocked: locked,
                  onRetry: retry ?? () {},
                  onNextStream: nextStream ? (next ?? () {}) : null,
                  onChooseStream: choose ?? () {},
                  onDismiss: dismiss ?? () {},
                  onExit: exit ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  FocusNode focus(WidgetTester tester, String id) => tester
      .widget<TvFocusable>(find.byKey(ValueKey('player-recovery-$id')))
      .focusNode!;

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(
      key,
      physicalKey: key == LogicalKeyboardKey.goBack
          ? PhysicalKeyboardKey.escape
          : null,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('remote starts on Retry and activates every recovery action', (
    tester,
  ) async {
    final calls = <String>[];
    await mount(
      tester,
      retry: () => calls.add('retry'),
      next: () => calls.add('next'),
      choose: () => calls.add('choose'),
      dismiss: () => calls.add('dismiss'),
      exit: () => calls.add('exit'),
    );
    expect(focus(tester, 'retry').hasPrimaryFocus, isTrue);
    for (final id in ['retry', 'next', 'choose', 'dismiss', 'exit']) {
      expect(focus(tester, id).hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(calls, ['retry', 'next', 'choose', 'dismiss', 'exit']);
    expect(focus(tester, 'exit').hasPrimaryFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'arrows stay inside recovery and never reach player key handler',
    (tester) async {
      var hudKeys = 0;
      await mount(
        tester,
        parentKey: (node, event) {
          if ([
            LogicalKeyboardKey.arrowLeft,
            LogicalKeyboardKey.arrowRight,
            LogicalKeyboardKey.arrowUp,
            LogicalKeyboardKey.arrowDown,
          ].contains(event.logicalKey)) {
            hudKeys++;
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
      );
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focus(tester, 'retry').hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(tester, 'next').hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focus(tester, 'retry').hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(seconds: 20));
      expect(focus(tester, 'next').hasPrimaryFocus, isTrue);
      expect(hudKeys, 0);
    },
  );

  testWidgets('Back and Escape dismiss instead of reaching player exit', (
    tester,
  ) async {
    var dismissals = 0;
    var parentBacks = 0;
    await mount(
      tester,
      dismiss: () => dismissals++,
      parentKey: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.goBack ||
            event.logicalKey == LogicalKeyboardKey.escape) {
          parentBacks++;
        }
        return KeyEventResult.ignored;
      },
    );
    await press(tester, LogicalKeyboardKey.goBack);
    await press(tester, LogicalKeyboardKey.escape);
    expect(dismissals, 2);
    expect(parentBacks, 0);
  });

  testWidgets('guest can always dismiss or exit, without host-only actions', (
    tester,
  ) async {
    var dismissals = 0;
    var exits = 0;
    await mount(
      tester,
      locked: true,
      dismiss: () => dismissals++,
      exit: () => exits++,
    );
    expect(find.text('Retry stream'), findsNothing);
    expect(find.text('Next stream'), findsNothing);
    expect(find.text('Choose stream'), findsNothing);
    expect(focus(tester, 'dismiss').hasPrimaryFocus, isTrue);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.select);
    expect(dismissals, 1);
    expect(exits, 1);
  });

  testWidgets(
    'no alternate source still allows predictable remote navigation',
    (tester) async {
      await mount(tester, nextStream: false);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(tester, 'choose').hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.tab);
      expect(focus(tester, 'dismiss').hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.tab);
      expect(focus(tester, 'retry').hasPrimaryFocus, isTrue);
    },
  );

  testWidgets(
    'TV layout reads complete message, supports pointer, avoids blur',
    (tester) async {
      var dismissals = 0;
      await mount(tester, textScale: 1.5, dismiss: () => dismissals++);
      expect(find.text(_message), findsOneWidget);
      expect(tester.widget<Text>(find.text(_message)).maxLines, isNull);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(
        find.descendant(
          of: find.byType(PlayerPlaybackErrorPanel),
          matching: find.byType(ModalBarrier),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('player-recovery-dismiss')));
      await tester.pumpAndSettle();
      expect(dismissals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dismissed overlay returns focus to the HUD', (tester) async {
    final hud = FocusNode(debugLabel: 'test.hud');
    addTearDown(hud.dispose);
    var showing = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: TvShortcuts(
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeFocus(
                      excluding: showing,
                      child: Center(
                        child: TvFocusable(
                          focusNode: hud,
                          autofocus: true,
                          onPressed: () {},
                          child: const Text('Player controls'),
                        ),
                      ),
                    ),
                    if (showing)
                      PlayerPlaybackErrorPanel(
                        message: _message,
                        controlsLocked: false,
                        onRetry: () {},
                        onChooseStream: () {},
                        onExit: () {},
                        onDismiss: () {
                          update(() => showing = false);
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => hud.requestFocus(),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(hud.hasPrimaryFocus, isTrue);
    update(() => showing = true);
    await tester.pumpAndSettle();
    expect(focus(tester, 'retry').hasPrimaryFocus, isTrue);
    await press(tester, LogicalKeyboardKey.goBack);
    expect(find.byType(PlayerPlaybackErrorPanel), findsNothing);
    expect(hud.hasPrimaryFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}
