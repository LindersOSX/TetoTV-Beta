import 'package:anime_tv/features/catalog/presentation/auto_scrolling_synopsis.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _longSynopsis =
    'A long synopsis that should remain readable without '
    'ellipsis or moving the surrounding controls. This paragraph continues '
    'with the rest of the story, including details after the first five lines. '
    'Every sentence should eventually be visible to people reading on a TV. '
    'This final sentence must not be truncated.';

Widget _page({
  String text = _longSynopsis,
  bool reduced = false,
  bool accessible = false,
  bool tickerEnabled = true,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: reduced,
      accessibleNavigation: accessible,
    ),
    child: TickerMode(
      enabled: tickerEnabled,
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            child: AutoScrollingSynopsis(
              text: text,
              maxLines: 3,
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
          ),
        ),
      ),
    ),
  ),
);

ScrollController _controller(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(
      find.byKey(const ValueKey('anime-details-synopsis-scroll')),
    )
    .controller!;

void main() {
  testWidgets('manual reading still works with reduced motion', (tester) async {
    await tester.pumpWidget(_page(reduced: true));
    final scroll = _controller(tester);
    await tester.drag(
      find.byKey(const ValueKey('anime-details-synopsis-scroll')),
      const Offset(0, -48),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    final offset = scroll.offset;
    await tester.pump(const Duration(seconds: 20));
    expect(scroll.offset, offset);
  });

  testWidgets(
    'long synopsis pauses, scrolls slowly, and pauses before repeating',
    (tester) async {
      await tester.pumpWidget(_page());
      await tester.pump();
      final scroll = _controller(tester);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      expect(find.text(_longSynopsis), findsOneWidget);
      expect(tester.widget<Text>(find.text(_longSynopsis)).maxLines, isNull);
      expect(scroll.offset, 0);
      await tester.pump(const Duration(seconds: 3));
      expect(scroll.offset, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, closeTo(12, 1));
      final duration = Duration(
        milliseconds: (scroll.position.maxScrollExtent / 12 * 1000).ceil(),
      );
      await tester.pump(duration);
      final end = scroll.position.maxScrollExtent;
      expect(scroll.offset, closeTo(end, 1));
      await tester.pump(const Duration(seconds: 3));
      expect(scroll.offset, closeTo(end, 1));
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short synopsis never scrolls or starts an animation', (
    tester,
  ) async {
    await tester.pumpWidget(_page(text: 'Short synopsis.'));
    await tester.pump(const Duration(seconds: 20));
    expect(_controller(tester).position.maxScrollExtent, 0);
    expect(_controller(tester).offset, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final mode in ['reduced', 'accessible', 'covered']) {
    testWidgets('$mode synopsis keeps full text but no automatic movement', (
      tester,
    ) async {
      await tester.pumpWidget(
        _page(
          reduced: mode == 'reduced',
          accessible: mode == 'accessible',
          tickerEnabled: mode != 'covered',
        ),
      );
      await tester.pump(const Duration(seconds: 20));
      expect(_controller(tester).offset, 0);
      expect(find.text(_longSynopsis), findsOneWidget);
    });
  }

  testWidgets('replacing translated text restarts at its beginning', (
    tester,
  ) async {
    await tester.pumpWidget(_page());
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 2));
    expect(_controller(tester).offset, greaterThan(0));
    await tester.pumpWidget(_page(text: 'Replacement. $_longSynopsis'));
    await tester.pump();
    expect(_controller(tester).offset, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(_controller(tester).offset, 0);
  });

  testWidgets('background playback pauses synopsis work until foreground', (
    tester,
  ) async {
    await tester.pumpWidget(_page());
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 2));
    final offset = _controller(tester).offset;
    expect(offset, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    expect(_controller(tester).offset, offset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(_controller(tester).offset, greaterThan(offset));
  });

  testWidgets('opening another route pauses reading and returning resumes', (
    tester,
  ) async {
    await tester.pumpWidget(_page());
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    final scroll = _controller(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other page')),
      ),
    );
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    await tester.pump(const Duration(seconds: 10));
    expect(scroll.offset, offset);
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(scroll.offset, greaterThan(offset));
  });
}
