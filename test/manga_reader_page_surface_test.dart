import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_page_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tap zones honor reading direction and inversion', (
    tester,
  ) async {
    for (final direction in MangaReadingDirection.values) {
      for (final inverted in <bool>[false, true]) {
        final turns = <int>[];
        var hudToggles = 0;
        await tester.pumpWidget(
          _harness(
            preferences: MangaReaderPreferences(
              doubleTapZoom: false,
              direction: direction,
              invertTapZones: inverted,
            ),
            onTurnPage: turns.add,
            onToggleHud: () => hudToggles += 1,
          ),
        );
        await tester.tapAt(const Offset(40, 300));
        await tester.tapAt(const Offset(400, 300));
        await tester.tapAt(const Offset(760, 300));
        var rightDelta = direction == MangaReadingDirection.leftToRight
            ? 1
            : -1;
        if (inverted) rightDelta = -rightDelta;
        expect(turns, <int>[-rightDelta, rightDelta]);
        expect(hudToggles, 1);
      }
    }
  });

  testWidgets('disabled zones keep HUD reachable over the entire page', (
    tester,
  ) async {
    final turns = <int>[];
    var hudToggles = 0;
    await tester.pumpWidget(
      _harness(
        preferences: const MangaReaderPreferences(
          doubleTapZoom: false,
          tapZonesEnabled: false,
        ),
        onTurnPage: turns.add,
        onToggleHud: () => hudToggles += 1,
      ),
    );
    for (final x in <double>[40, 400, 760]) {
      await tester.tapAt(Offset(x, 300));
    }
    expect(turns, isEmpty);
    expect(hudToggles, 3);
  });

  testWidgets('edge zones leave a wider center than thirds', (tester) async {
    final turns = <int>[];
    var hudToggles = 0;
    await tester.pumpWidget(
      _harness(
        preferences: const MangaReaderPreferences(
          doubleTapZoom: false,
          tapZoneLayout: MangaTapZoneLayout.edges,
        ),
        onTurnPage: turns.add,
        onToggleHud: () => hudToggles += 1,
      ),
    );
    await tester.tapAt(const Offset(200, 300));
    await tester.tapAt(const Offset(600, 300));
    await tester.tapAt(const Offset(40, 300));
    expect(turns, <int>[1]);
    expect(hudToggles, 2);
  });

  for (final axis in Axis.values) {
    testWidgets('1x single-finger $axis swipe reaches parent PageView', (
      tester,
    ) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      final turns = <int>[];
      var hudToggles = 0;
      await tester.pumpWidget(
        _pageViewHarness(
          controller: controller,
          axis: axis,
          onTurnPage: turns.add,
          onToggleHud: () => hudToggles += 1,
        ),
      );
      await tester.drag(
        find.byType(MangaReaderPageSurface).first,
        axis == Axis.horizontal ? const Offset(-600, 0) : const Offset(0, -450),
      );
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      expect(turns, isEmpty);
      expect(hudToggles, 0);
    });
  }

  testWidgets(
    'double tap zooms at focal point, edge tap shows HUD, reset works',
    (tester) async {
      final turns = <int>[];
      final zoomChanges = <bool>[];
      var hudToggles = 0;
      await tester.pumpWidget(
        _harness(
          preferences: const MangaReaderPreferences(),
          onTurnPage: turns.add,
          onToggleHud: () => hudToggles += 1,
          onZoomChanged: zoomChanges.add,
        ),
      );
      await _doubleTap(tester, const Offset(600, 300));
      expect(_matrix(tester).getMaxScaleOnAxis(), closeTo(2.5, 0.001));
      expect(_matrix(tester).storage[12], closeTo(-900, 0.001));
      expect(turns, isEmpty);
      expect(zoomChanges, <bool>[true]);

      await tester.tapAt(const Offset(40, 300));
      await tester.pump(const Duration(milliseconds: 350));
      expect(hudToggles, 1);
      expect(turns, isEmpty);

      await _doubleTap(tester, const Offset(600, 300));
      expect(_matrix(tester).getMaxScaleOnAxis(), 1);
      expect(_matrix(tester).storage[12], 0);
      expect(zoomChanges, <bool>[true, false]);
    },
  );

  testWidgets('pinch claims both pointers and zoomed pan does not turn pages', (
    tester,
  ) async {
    final controller = PageController();
    addTearDown(controller.dispose);
    final zoomChanges = <bool>[];
    await tester.pumpWidget(
      _pageViewHarness(controller: controller, onZoomChanged: zoomChanges.add),
    );
    final first = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(500, 300),
      pointer: 2,
    );
    expect(zoomChanges, <bool>[true]);
    await first.moveTo(const Offset(200, 300));
    await second.moveTo(const Offset(600, 300));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(_matrix(tester).getMaxScaleOnAxis(), closeTo(2, 0.001));
    expect(controller.page, 0);

    final beforePan = _matrix(tester).storage[12];
    await tester.drag(
      find.byType(MangaReaderPageSurface).first,
      const Offset(-180, 40),
    );
    await tester.pumpAndSettle();
    expect(_matrix(tester).storage[12], lessThan(beforePan));
    expect(controller.page, 0);
    expect(zoomChanges, <bool>[true]);
  });

  testWidgets('pinch scale is bounded and releases the scroll lock at 1x', (
    tester,
  ) async {
    final zoomChanges = <bool>[];
    await tester.pumpWidget(_harness(onZoomChanged: zoomChanges.add));
    final first = await tester.startGesture(const Offset(390, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(410, 300),
      pointer: 2,
    );
    await first.moveTo(const Offset(100, 300));
    await second.moveTo(const Offset(700, 300));
    await tester.pump();
    expect(_matrix(tester).getMaxScaleOnAxis(), 4);
    await first.moveTo(const Offset(399, 300));
    await second.moveTo(const Offset(401, 300));
    await tester.pump();
    expect(_matrix(tester).getMaxScaleOnAxis(), 1);
    expect(zoomChanges, <bool>[true]);
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(zoomChanges, <bool>[true, false]);
    expect(_matrix(tester).storage[12], 0);
    expect(_matrix(tester).storage[13], 0);
  });

  testWidgets('cancelled pinch releases lock and never sends a tap', (
    tester,
  ) async {
    final zoomChanges = <bool>[];
    var tapCount = 0;
    await tester.pumpWidget(
      _harness(
        onZoomChanged: zoomChanges.add,
        onTurnPage: (_) => tapCount += 1,
        onToggleHud: () => tapCount += 1,
      ),
    );
    final first = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(500, 300),
      pointer: 2,
    );
    await first.cancel();
    await second.cancel();
    await tester.pump(const Duration(milliseconds: 350));
    expect(zoomChanges, <bool>[true, false]);
    expect(tapCount, 0);
    expect(_matrix(tester).getMaxScaleOnAxis(), 1);
  });

  testWidgets('new page key starts unzoomed and disables double tap cleanly', (
    tester,
  ) async {
    final turns = <int>[];
    await tester.pumpWidget(
      _harness(surfaceKey: const ValueKey('page-1'), onTurnPage: turns.add),
    );
    await _doubleTap(tester, const Offset(400, 300));
    expect(_matrix(tester).getMaxScaleOnAxis(), 2.5);
    await tester.pumpWidget(
      _harness(
        surfaceKey: const ValueKey('page-2'),
        preferences: const MangaReaderPreferences(doubleTapZoom: false),
        onTurnPage: turns.add,
      ),
    );
    expect(_matrix(tester).getMaxScaleOnAxis(), 1);
    await tester.tapAt(const Offset(40, 300));
    expect(turns, <int>[1]);
  });

  testWidgets('disabling double tap on a mounted surface keeps single taps', (
    tester,
  ) async {
    final turns = <int>[];
    await tester.pumpWidget(_harness(onTurnPage: turns.add));
    await tester.pumpWidget(
      _harness(
        preferences: const MangaReaderPreferences(doubleTapZoom: false),
        onTurnPage: turns.add,
      ),
    );
    await tester.tapAt(const Offset(40, 300));
    expect(turns, <int>[1]);
  });

  testWidgets('reset token preserves child state and sends no build callback', (
    tester,
  ) async {
    final zoomChanges = <bool>[];
    final child = StatefulBuilder(
      builder: (context, setState) =>
          const SizedBox.expand(child: ColoredBox(color: Colors.white)),
    );
    await tester.pumpWidget(
      _harness(child: child, onZoomChanged: zoomChanges.add),
    );
    final childState = tester.state(find.byType(StatefulBuilder));
    await _doubleTap(tester, const Offset(400, 300));
    expect(_matrix(tester).getMaxScaleOnAxis(), 2.5);
    await tester.pumpWidget(
      _harness(resetToken: 1, child: child, onZoomChanged: zoomChanges.add),
    );
    expect(_matrix(tester).getMaxScaleOnAxis(), 1);
    expect(tester.state(find.byType(StatefulBuilder)), same(childState));
    expect(zoomChanges, <bool>[true]);
    expect(tester.takeException(), isNull);
    await _doubleTap(tester, const Offset(400, 300));
    expect(zoomChanges, <bool>[true, true]);
  });

  testWidgets('reset during pinch ignores the old gesture remainder', (
    tester,
  ) async {
    final zoomChanges = <bool>[];
    await tester.pumpWidget(_harness(onZoomChanged: zoomChanges.add));
    final first = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final second = await tester.startGesture(
      const Offset(500, 300),
      pointer: 2,
    );
    await first.moveTo(const Offset(200, 300));
    await tester.pump();
    expect(_matrix(tester).getMaxScaleOnAxis(), greaterThan(1));
    await tester.pumpWidget(
      _harness(resetToken: 1, onZoomChanged: zoomChanges.add),
    );
    await second.moveTo(const Offset(600, 300));
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(_matrix(tester).getMaxScaleOnAxis(), 1);
    expect(zoomChanges, <bool>[true]);
    expect(tester.takeException(), isNull);
  });

  test('neutral image preferences produce the exact identity transform', () {
    expect(mangaReaderColorMatrix(const MangaReaderPreferences()), <double>[
      1,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
  });

  test('all image color combinations preserve alpha and RGB bounds', () {
    for (final grayscale in <bool>[false, true]) {
      for (final invert in <bool>[false, true]) {
        for (final warmth in <double>[-10, 0, 0.5, 1, 10, double.nan]) {
          for (final dim in <double>[-10, 0, 0.35, 0.7, 10, double.infinity]) {
            final matrix = mangaReaderColorMatrix(
              MangaReaderPreferences(
                grayscale: grayscale,
                invertColors: invert,
                warmth: warmth,
                dimAmount: dim,
              ),
            );
            expect(matrix, hasLength(20));
            expect(matrix.every((value) => value.isFinite), isTrue);
            expect(matrix.sublist(15), <double>[0, 0, 0, 1, 0]);
            for (final r in <double>[0, 255]) {
              for (final g in <double>[0, 255]) {
                for (final b in <double>[0, 255]) {
                  for (var row = 0; row < 3; row += 1) {
                    final output =
                        matrix[row * 5] * r +
                        matrix[row * 5 + 1] * g +
                        matrix[row * 5 + 2] * b +
                        matrix[row * 5 + 4];
                    expect(output, inInclusiveRange(-0.00001, 255.00001));
                  }
                }
              }
            }
          }
        }
      }
    }
  });

  test('grayscale, inversion, warmth and dim have their intended effects', () {
    final grayscale = mangaReaderColorMatrix(
      const MangaReaderPreferences(grayscale: true),
    );
    expect(grayscale.sublist(0, 5), grayscale.sublist(5, 10));
    expect(grayscale.sublist(5, 10), grayscale.sublist(10, 15));
    final inverted = mangaReaderColorMatrix(
      const MangaReaderPreferences(invertColors: true),
    );
    expect(inverted[0], -1);
    expect(inverted[6], -1);
    expect(inverted[12], -1);
    expect(inverted[4], 255);
    expect(inverted[9], 255);
    expect(inverted[14], 255);
    final warmAndDim = mangaReaderColorMatrix(
      const MangaReaderPreferences(warmth: 1, dimAmount: 0.5),
    );
    expect(warmAndDim[0], 0.5);
    expect(warmAndDim[6], closeTo(0.46, 0.0001));
    expect(warmAndDim[12], closeTo(0.35, 0.0001));
  });

  testWidgets('image filter is absent at neutral and wraps only its child', (
    tester,
  ) async {
    const child = ColoredBox(key: ValueKey('image'), color: Colors.white);
    await tester.pumpWidget(
      const MangaReaderImageFilter(
        preferences: MangaReaderPreferences(),
        child: child,
      ),
    );
    expect(find.byType(ColorFiltered), findsNothing);
    await tester.pumpWidget(
      const MangaReaderImageFilter(
        preferences: MangaReaderPreferences(grayscale: true),
        child: child,
      ),
    );
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(
      tester.widget<ColorFiltered>(find.byType(ColorFiltered)).child,
      same(child),
    );
  });
}

Widget _harness({
  Key? surfaceKey,
  int resetToken = 0,
  Widget? child,
  MangaReaderPreferences preferences = const MangaReaderPreferences(),
  ValueChanged<int>? onTurnPage,
  VoidCallback? onToggleHud,
  ValueChanged<bool>? onZoomChanged,
}) => MaterialApp(
  home: Scaffold(
    body: MangaReaderPageSurface(
      key: surfaceKey,
      resetToken: resetToken,
      preferences: preferences,
      onTurnPage: onTurnPage ?? (_) {},
      onToggleHud: onToggleHud ?? () {},
      onZoomChanged: onZoomChanged,
      child:
          child ??
          const SizedBox.expand(child: ColoredBox(color: Colors.white)),
    ),
  ),
);

Widget _pageViewHarness({
  required PageController controller,
  Axis axis = Axis.horizontal,
  ValueChanged<int>? onTurnPage,
  VoidCallback? onToggleHud,
  ValueChanged<bool>? onZoomChanged,
}) {
  var zoomed = false;
  return MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => PageView.builder(
          controller: controller,
          scrollDirection: axis,
          physics: zoomed ? const NeverScrollableScrollPhysics() : null,
          itemCount: 3,
          itemBuilder: (context, index) => MangaReaderPageSurface(
            key: ValueKey(index),
            preferences: const MangaReaderPreferences(),
            onTurnPage: onTurnPage ?? (_) {},
            onToggleHud: onToggleHud ?? () {},
            onZoomChanged: (value) {
              setState(() => zoomed = value);
              onZoomChanged?.call(value);
            },
            child: const SizedBox.expand(
              child: ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  );
}

Matrix4 _matrix(WidgetTester tester) => tester
    .widget<Transform>(
      find
          .descendant(
            of: find.byType(MangaReaderPageSurface).first,
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform;

Future<void> _doubleTap(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 350));
}
