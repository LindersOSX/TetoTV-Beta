import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_browse_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shared browse status keeps its action usable on TV', (
    tester,
  ) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: TetoBrowseStatus(
            icon: Icons.search_off_rounded,
            title: 'No matches found',
            message: 'Try another title, spelling, or Japanese name.',
            actions: FilledButton(
              onPressed: () => pressed = true,
              child: const Text('Try again'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('No matches found'), findsOneWidget);
    expect(
      find.text('Try another title, spelling, or Japanese name.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    expect(pressed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared browse loading exposes progress semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: TetoBrowseLoading()),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final semantics = tester.widget<Semantics>(
      find
          .descendant(
            of: find.byType(TetoBrowseLoading),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(semantics.properties.liveRegion, isTrue);
    expect(find.byKey(const ValueKey('browse-status-panel')), findsNothing);
    expect(find.byType(TetoBrowseStatus), findsNothing);
    expect(
      find.descendant(
        of: find.byType(TetoBrowseLoading),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
      reason: 'the spinner and label must not be enclosed in nested boxes',
    );
    expect(find.text('Loading'), findsOneWidget);
  });

  testWidgets('minimal loading keeps the theme and fits a small canvas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 140);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final palette = AppThemePalette.defaults.copyWith(
      accent: const Color(0xFF00B8CC),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkFor(palette),
        home: const Scaffold(
          body: TetoBrowseLoading(
            title: 'Loading',
            message: 'Preparing your stream.',
          ),
        ),
      ),
    );
    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.color, palette.accentBright);
    expect(find.text('Preparing your stream.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery panel stays usable on a small screen and by remote', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: TetoBrowseStatus(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load anime',
            message: 'The catalog could not be reached. Please try again.',
            actions: TetoRetryButton(
              autofocus: true,
              onPressed: () => retried = true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(retried, isTrue);
    expect(tester.takeException(), isNull);
  });
}
