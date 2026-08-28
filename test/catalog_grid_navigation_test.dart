import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/catalog_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  final items = [
    for (var index = 0; index < 5; index++)
      AnimeSummary(
        id: index + 1,
        title: 'Boundary result ${index + 1}',
        description: '',
        episodes: 12,
        score: 8,
      ),
  ];

  for (final testCase in const [
    (width: 168.0, expectedIndex: 1, expectedColumns: 1),
    (width: 169.0, expectedIndex: 2, expectedColumns: 2),
  ]) {
    testWidgets('D-pad rows match the max-extent sliver at '
        '${testCase.width}px (${testCase.expectedColumns} columns)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: testCase.width,
                height: 700,
                child: CatalogGrid(
                  items: items,
                  titlePreference: TitleLanguagePreference.romaji,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'catalog.result.0',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'catalog.result.${testCase.expectedIndex}',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('held horizontal input is throttled without leaking traversal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 700,
            child: CatalogGrid(
              items: [
                ...items,
                for (var index = 5; index < 12; index++)
                  AnimeSummary(
                    id: index + 1,
                    title: 'Repeat result ${index + 1}',
                    description: '',
                    episodes: 12,
                    score: 8,
                  ),
              ],
              titlePreference: TitleLanguagePreference.romaji,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.1');

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.1');

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.2');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning from details restores the exact catalog card', (
    tester,
  ) async {
    late final GoRouter router;
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: SizedBox(
              width: 640,
              height: 700,
              child: CatalogGrid(
                items: items,
                titlePreference: TitleLanguagePreference.romaji,
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/anime/:id',
          builder: (_, state) =>
              Scaffold(body: Text('Details ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.1');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Details 2'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reordered result keeps focus on the same media identity', (
    tester,
  ) async {
    final hostKey = GlobalKey<_DynamicCatalogHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 700,
            child: _DynamicCatalogHost(key: hostKey, initialItems: items),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.2');

    hostKey.currentState!.replaceItems([
      items[2],
      items[0],
      items[1],
      items[3],
      items[4],
    ]);
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.0');
    expect(FocusManager.instance.primaryFocus?.context, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a result shrink focuses the nearest surviving card', (
    tester,
  ) async {
    final hostKey = GlobalKey<_DynamicCatalogHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 700,
            child: _DynamicCatalogHost(key: hostKey, initialItems: items),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.4');

    hostKey.currentState!.replaceItems(items.take(2).toList());
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog.result.1');
    expect(FocusManager.instance.primaryFocus?.context, isNotNull);
    expect(tester.takeException(), isNull);
  });
}

class _DynamicCatalogHost extends StatefulWidget {
  const _DynamicCatalogHost({required this.initialItems, super.key});

  final List<AnimeSummary> initialItems;

  @override
  State<_DynamicCatalogHost> createState() => _DynamicCatalogHostState();
}

class _DynamicCatalogHostState extends State<_DynamicCatalogHost> {
  late List<AnimeSummary> items = widget.initialItems;

  void replaceItems(List<AnimeSummary> value) {
    setState(() => items = value);
  }

  @override
  Widget build(BuildContext context) => CatalogGrid(
    items: items,
    titlePreference: TitleLanguagePreference.romaji,
  );
}
