import 'dart:ui' as ui;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('brand sizing matches visible caps to the visible logo artwork', (
    tester,
  ) async {
    // A real bundled font checks painted glyphs, not Ahem's square test boxes.
    await tester.runAsync(() async {
      final font = FontLoader('TetoBrandOpticalTest')
        ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
      await font.load();
      final markData = await rootBundle.load(
        'assets/branding/tetotv_in_app_mark.png',
      );
      final codec = await ui.instantiateImageCodec(
        markData.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      final mark = frame.image;
      final markBytes = await mark.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final markBounds = _solidAlphaBounds(markBytes!, mark.width, mark.height);
      expect(markBounds.height / mark.width, closeTo(.643, .01));
      mark.dispose();
      codec.dispose();
      for (final size in NavigationChromeSize.values) {
        final metrics = homeNavigationRailMetrics(size);
        final painter = TextPainter(
          text: TextSpan(
            text: 'Teto TV',
            style: TextStyle(
              fontFamily: 'TetoBrandOpticalTest',
              color: Colors.white,
              fontSize: metrics.logoSize * .90,
              height: 1,
              fontWeight: FontWeight.w800,
            ),
          ),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
        )..layout();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        painter.paint(canvas, const Offset(3, 3));
        final picture = recorder.endRecording();
        final letters = await picture.toImage(
          painter.width.ceil() + 6,
          painter.height.ceil() + 6,
        );
        final bytes = await letters.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final glyphBounds = _solidAlphaBounds(
          bytes!,
          letters.width,
          letters.height,
        );
        expect(
          glyphBounds.height,
          closeTo(metrics.logoSize * .90 * .79, 2),
          reason: '$size must match painted caps, not just Text/Image boxes',
        );
        // Any drawer-width fit is proportional and shared by both sides.
        // Therefore this optical ratio is retained at every navigation size.
        expect(
          glyphBounds.center.dy - 3 + painter.height * .085,
          closeTo(painter.height / 2, 2),
        );
        letters.dispose();
        picture.dispose();
        painter.dispose();
      }
    });
  });
  for (final background in [Colors.black, Colors.white]) {
    for (final size in NavigationChromeSize.values) {
      testWidgets(
        'expanded brand is aligned right of the logo on $background at $size',
        (tester) async {
          final metrics = homeNavigationRailMetrics(size);
          final palette = AppThemePalette.fromSeeds(
            background: background,
            surface: background,
            accent: Colors.blue,
            primaryText: contrastForeground(background),
            mutedText: Colors.grey,
          );
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: AppTheme.darkFor(palette),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.centerLeft,
                    child: HomeSideNavigation(
                      preferences: const SettingsPreferences(
                        loaded: true,
                        expandNavigationLabelsOnFocus: true,
                      ),
                      metrics: metrics,
                      onExitRight: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final reveal = find.byKey(
            const ValueKey('main-nav-expanded-wordmark'),
          );
          expect(tester.widget<AnimatedOpacity>(reveal).opacity, 0);
          final mark = find.descendant(
            of: find.byKey(const ValueKey('main-nav-wordmark')),
            matching: find.byType(Image),
          );
          final collapsedLogoRect = tester.getRect(mark);
          expect(collapsedLogoRect.size, Size.square(metrics.logoSize));
          final teto = find.byKey(const ValueKey('main-nav-wordmark-teto'));
          final tv = find.byKey(const ValueKey('main-nav-wordmark-tv'));
          final collapsedTextRect = tester.getRect(teto);
          final action = tester.widget<FocusableActionDetector>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('main-nav-home')),
                  matching: find.byType(FocusableActionDetector),
                )
                .first,
          );
          action.focusNode!.requestFocus();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(tester.getCenter(mark), collapsedLogoRect.center);
          expect(tester.getRect(teto), collapsedTextRect);
          await tester.pumpAndSettle();
          expect(tester.widget<AnimatedOpacity>(reveal).opacity, 1);
          expect(tester.widget<Text>(teto).style?.color, palette.accentBright);
          expect(
            tester.widget<Text>(tv).style?.color,
            contrastForeground(background),
          );
          expect(tester.getCenter(mark), collapsedLogoRect.center);
          expect(
            tester.getRect(mark).width,
            lessThanOrEqualTo(metrics.logoSize),
          );
          expect(tester.getRect(teto), collapsedTextRect);
          expect(
            tester.getRect(teto).left,
            greaterThan(tester.getRect(mark).right),
          );
          expect(
            tester.getCenter(teto).dy,
            closeTo(
              tester.getCenter(mark).dy + tester.getRect(teto).height * .085,
              .01,
            ),
          );
          expect(
            tester.getCenter(tv).dy,
            closeTo(
              tester.getCenter(mark).dy + tester.getRect(teto).height * .085,
              .01,
            ),
          );
          expect(
            tester.widget<Text>(teto).style?.fontSize,
            metrics.logoSize * .90,
          );
          expect(
            tester.widget<Text>(tv).style?.fontSize,
            metrics.logoSize * .90,
          );
          final railRect = tester.getRect(
            find.byKey(const ValueKey('main-navigation')),
          );
          expect(tester.getRect(tv).right, lessThan(railRect.right));
          expect(
            tester.getRect(teto).height,
            closeTo(tester.getRect(mark).height * (988 / 1536) / .79, .3),
          );
          expect(
            tester.getRect(tv).height,
            closeTo(tester.getRect(mark).height * (988 / 1536) / .79, .3),
          );
          final labelFit = tester.widget<FittedBox>(
            find.descendant(of: reveal, matching: find.byType(FittedBox)),
          );
          expect(
            labelFit.fit,
            BoxFit.scaleDown,
            reason: 'the brand must retain natural text proportions',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('collapsed-only navigation never enables backdrop blur', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: HomeSideNavigation(
              preferences: const SettingsPreferences(
                loaded: true,
                expandNavigationLabelsOnFocus: false,
              ),
              metrics: homeNavigationRailMetrics(NavigationChromeSize.medium),
              onExitRight: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final home = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('main-nav-home')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    home.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BackdropFilter>(
            find.byKey(const ValueKey('main-navigation-backdrop-blur')),
          )
          .enabled,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV rail label expands on focus and closes on click or exit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final contentFocus = FocusNode();
    addTearDown(contentFocus.dispose);
    var homePresses = 0;
    final metrics = homeNavigationRailMetrics(NavigationChromeSize.medium);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  left: metrics.width,
                  child: Center(
                    child: TextButton(
                      key: const ValueKey('content-region'),
                      focusNode: contentFocus,
                      onPressed: () {},
                      child: const Text('Content'),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: HomeSideNavigation(
                    preferences: const SettingsPreferences(
                      loaded: true,
                      expandNavigationLabelsOnFocus: true,
                    ),
                    metrics: metrics,
                    onHomePressed: () => homePresses++,
                    onExitRight: contentFocus.requestFocus,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.byKey(const ValueKey('main-nav-expanded-label-home'));
    double labelProgress() => tester.widget<AnimatedOpacity>(label).opacity;
    expect(labelProgress(), 0);
    final blur = find.byKey(const ValueKey('main-navigation-backdrop-blur'));
    expect(tester.widget<BackdropFilter>(blur).enabled, isFalse);
    final contentLeft = tester
        .getTopLeft(find.byKey(const ValueKey('content-region')))
        .dx;

    final homeFocus = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('main-nav-home')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    homeFocus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(labelProgress(), 1);
    for (final destination in [
      'home',
      'search',
      'myList',
      'discover',
      'calendar',
      'watchTogether',
      'downloads',
      'settings',
    ]) {
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(ValueKey('main-nav-expanded-label-$destination')),
            )
            .opacity,
        1,
      );
    }
    expect(find.text('Watch Party'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('main-navigation'))).width,
      metrics.width + 108,
    );
    final rail = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('main-navigation-background')),
    );
    expect((rail.decoration! as BoxDecoration).color!.a, closeTo(.75, .001));
    expect(tester.widget<BackdropFilter>(blur).enabled, isTrue);
    expect(
      find.ancestor(of: blur, matching: find.byType(ClipRect)),
      findsOneWidget,
    );
    expect(
      tester.getSize(blur),
      Size(
        tester.getSize(find.byKey(const ValueKey('main-navigation'))).width - 1,
        tester.getSize(find.byKey(const ValueKey('main-navigation'))).height,
      ),
    );
    expect(
      find.descendant(of: blur, matching: find.byType(Icon)),
      findsNothing,
    );
    expect(find.descendant(of: blur, matching: label), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('content-region'))).dx,
      contentLeft,
    );
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('home-navigation-actions-scroll')),
    );
    expect(scroll.clipBehavior, Clip.none);

    await tester.tap(find.byKey(const ValueKey('main-nav-home')));
    await tester.pumpAndSettle();
    expect(homePresses, 1);
    expect(labelProgress(), 0);
    expect(tester.widget<BackdropFilter>(blur).enabled, isFalse);

    contentFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(labelProgress(), 0);
    homeFocus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(labelProgress(), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV rail label expands on pointer hover and closes on exit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: HomeSideNavigation(
              preferences: const SettingsPreferences(
                loaded: true,
                expandNavigationLabelsOnFocus: true,
              ),
              metrics: homeNavigationRailMetrics(NavigationChromeSize.medium),
              onExitRight: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.byKey(const ValueKey('main-nav-expanded-label-home'));
    double labelProgress() => tester.widget<AnimatedOpacity>(label).opacity;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(600, 500));
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('main-nav-home'))),
    );
    await tester.pumpAndSettle();
    expect(labelProgress(), 1);
    await mouse.moveTo(const Offset(600, 500));
    await tester.pumpAndSettle();
    expect(labelProgress(), 0);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Classic top tab animates its name and closes on selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var homePresses = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: MainNavigationBar(
                active: MainNavigationDestination.home,
                preferences: const SettingsPreferences(
                  loaded: true,
                  expandNavigationLabelsOnFocus: true,
                ),
                onHomePressed: () => homePresses++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.byKey(const ValueKey('main-nav-label-Home'));
    expect(label, findsNothing);
    final homeFocus = tester.widget<FocusableActionDetector>(
      find
          .descendant(
            of: find.byKey(const ValueKey('main-nav-home')),
            matching: find.byType(FocusableActionDetector),
          )
          .first,
    );
    homeFocus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expect(label, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('main-nav-home')));
    await tester.pumpAndSettle();
    expect(homePresses, 1);
    expect(label, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Rect _solidAlphaBounds(ByteData bytes, int width, int height) {
  var left = width;
  var top = height;
  var right = -1;
  var bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (bytes.getUint8((y * width + x) * 4 + 3) < 128) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  expect(right, greaterThanOrEqualTo(left));
  return Rect.fromLTRB(left.toDouble(), top.toDouble(), right + 1, bottom + 1);
}
