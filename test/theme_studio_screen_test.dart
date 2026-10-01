import 'dart:io';
import 'dart:ui' as ui;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_studio_components.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:anime_tv/features/settings/presentation/theme_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('CAPTURE_THEME_PREVIEW');
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

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!capture) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('theme-studio-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final output = File('build/qa/theme-studio-locked-$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  void viewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'TV preview is top-aligned and fixed while options and actions scroll',
    (tester) async {
      viewport(tester, const Size(1200, 800));
      final harness = await _pumpStudio(tester);
      addTearDown(harness.dispose);
      final preview = find.byKey(const ValueKey('theme-live-preview'));
      final controls = find.byKey(const ValueKey('theme-studio-controls'));
      final header = find.byType(TetoStudioHeader);
      final previewRect = tester.getRect(preview);
      final headerRect = tester.getRect(header);
      final controlsRect = tester.getRect(controls);
      expect(previewRect.top, closeTo(controlsRect.top, .1));
      expect(previewRect.width, closeTo(controlsRect.width, .1));
      expect(previewRect.height, 390);
      expect(previewRect.left - controlsRect.right, closeTo(18, .1));
      expect(
        find.ancestor(of: preview, matching: find.byType(Scrollable)),
        findsNothing,
      );
      await screenshot(tester, 'wide');

      await tester.drag(controls, const Offset(0, -400));
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: controls, matching: find.byType(Scrollable)),
      );
      expect(scroll.position.pixels, greaterThan(0));
      expect(tester.getRect(preview), previewRect);
      expect(tester.getRect(header), headerRect);
      final reset = find.byKey(const ValueKey('theme-studio-reset'));
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      expect(tester.getRect(preview), previewRect);
      expect(tester.getRect(header), headerRect);
      expect(find.ancestor(of: reset, matching: controls), findsOneWidget);
      expect(controlsRect.overlaps(tester.getRect(reset)), isTrue);
      await screenshot(tester, 'scrolled');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remote reaches guard, Apply and Reset without moving preview', (
    tester,
  ) async {
    viewport(tester, const Size(960, 540));
    final harness = await _pumpStudio(tester);
    addTearDown(harness.dispose);
    final preview = find.byKey(const ValueKey('theme-live-preview'));
    final rect = tester.getRect(preview);
    for (final role in AppThemeColorRole.values.skip(1)) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        _focusNode(
          tester,
          find.byKey(ValueKey('theme-color-${role.name}')),
        ).hasPrimaryFocus,
        isTrue,
      );
      expect(tester.getRect(preview), rect);
    }
    for (final target in ['contrast', 'apply']) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'theme-studio.$target',
      );
      expect(tester.getRect(preview), rect);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'theme-studio.reset',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'theme-studio.reset',
    );
    expect(tester.getRect(preview), rect);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 640), const Size(800, 360)]) {
    testWidgets('compact $size keeps a pinned, aligned preview and options', (
      tester,
    ) async {
      viewport(tester, size);
      final harness = await _pumpStudio(tester, textScale: 1.3);
      addTearDown(harness.dispose);
      final preview = find.byKey(const ValueKey('theme-live-preview'));
      final controls = find.byKey(const ValueKey('theme-studio-controls'));
      final rect = tester.getRect(preview);
      final options = tester.getRect(controls);
      if (size.width > size.height) {
        expect(rect.top, closeTo(options.top, .1));
        expect(rect.left - options.right, closeTo(18, .1));
        expect(rect.width, closeTo(options.width, .1));
        expect(rect.height, greaterThan(150));
      } else {
        expect(rect.bottom + 12, closeTo(options.top, .1));
        expect(rect.left, closeTo(options.left, .1));
        expect(rect.width, closeTo(options.width, .1));
      }
      expect(options.height, greaterThan(60));
      expect(rect.right, lessThanOrEqualTo(size.width));
      expect(
        find.ancestor(of: preview, matching: find.byType(Scrollable)),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('theme-studio-reset')),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(preview), rect);
      await screenshot(tester, '${size.width.toInt()}x${size.height.toInt()}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('route renders all color roles and a responsive live preview', (
    tester,
  ) async {
    final harness = await _pumpStudio(tester);
    addTearDown(harness.dispose);

    expect(ThemeStudioScreen.routePath, '/settings/theme-studio');
    expect(find.byKey(const ValueKey('theme-studio-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-live-preview')), findsOneWidget);
    for (final role in AppThemeColorRole.values) {
      expect(find.byKey(ValueKey('theme-color-${role.name}')), findsOneWidget);
      expect(find.text(role.displayName), findsOneWidget);
    }
    expect(find.text('Fine adjustments'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('contrast safeguard uses an outer TV focus glow', (tester) async {
    final harness = await _pumpStudio(tester);
    addTearDown(harness.dispose);
    final guard = find.byKey(const ValueKey('theme-contrast-guard'));
    await tester.ensureVisible(guard);
    await tester.pumpAndSettle();
    tester.widget<SwitchListTile>(guard).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    final card = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('theme-contrast-guard-card')),
    );
    expect((card.decoration! as BoxDecoration).boxShadow, isNotEmpty);
  });

  testWidgets(
    'TV focus starts on Background and follows the color role graph',
    (tester) async {
      final harness = await _pumpStudio(tester);
      addTearDown(harness.dispose);

      final background = find.byKey(const ValueKey('theme-color-background'));
      final surface = find.byKey(const ValueKey('theme-color-surface'));
      final accent = find.byKey(const ValueKey('theme-color-accent'));
      expect(_focusNode(tester, background).hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_focusNode(tester, surface).hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_focusNode(tester, accent).hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_focusNode(tester, surface).hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('theme-editor-built-in-colors')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('theme-editor-hex')), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
    },
  );

  testWidgets('built-in picker owns initial D-pad focus and Back cancels', (
    tester,
  ) async {
    final harness = await _pumpStudio(tester);
    addTearDown(harness.dispose);
    final accentTile = find.byKey(const ValueKey('theme-color-accent'));
    await tester.ensureVisible(accentTile);
    await tester.pumpAndSettle();
    await tester.tap(accentTile);
    await tester.pumpAndSettle();

    final selectedHex = tester.widget<Text>(
      find.byKey(const ValueKey('theme-editor-selected-hex')),
    );
    final selectedPreset = find.byKey(
      ValueKey(
        'theme-editor-preset-${selectedHex.data!.replaceFirst('#', '')}',
      ),
    );
    final selectedDetector = find.descendant(
      of: selectedPreset,
      matching: find.byType(FocusableActionDetector),
    );
    expect(selectedPreset, findsOneWidget);
    expect(
      tester
          .widget<FocusableActionDetector>(selectedDetector)
          .focusNode
          ?.hasFocus,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      tester
          .widget<FocusableActionDetector>(selectedDetector)
          .focusNode
          ?.hasFocus,
      isFalse,
    );
    expect(
      _focusNode(
        tester,
        find.byKey(const ValueKey('theme-editor-preset-FF1744')),
      ).hasFocus,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-editor-swatch')), findsNothing);
    expect(
      find.byKey(const ValueKey('theme-editor-built-in-colors')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('theme-studio-screen')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-customize-screen')),
      findsNothing,
    );
    expect(
      harness.router.routerDelegate.state.uri.path,
      ThemeStudioScreen.routePath,
    );
    expect(_focusNode(tester, accentTile).hasFocus, isTrue);
  });

  testWidgets('Back from exact hex returns to Theme Studio, not Settings', (
    tester,
  ) async {
    final harness = await _pumpStudio(tester);
    addTearDown(harness.dispose);
    final background = find.byKey(const ValueKey('theme-color-background'));
    await tester.tap(background);
    await tester.pumpAndSettle();

    expect(find.byType(EditableText), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    final hexToggle = find.byKey(const ValueKey('theme-editor-toggle-hex'));
    await tester.ensureVisible(hexToggle);
    await tester.tap(hexToggle);
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsOneWidget);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('theme-editor-hex')), findsNothing);
    expect(find.byKey(const ValueKey('theme-editor-swatch')), findsNothing);
    expect(find.byKey(const ValueKey('theme-studio-screen')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-customize-screen')),
      findsNothing,
    );
    expect(
      harness.router.routerDelegate.state.uri.path,
      ThemeStudioScreen.routePath,
    );
    expect(_focusNode(tester, background).hasFocus, isTrue);
  });

  testWidgets('built-in picker changes a role without opening hex entry', (
    tester,
  ) async {
    final harness = await _pumpStudio(tester);
    addTearDown(harness.dispose);
    final applyFinder = find.byKey(const ValueKey('theme-studio-apply'));
    expect(
      tester
          .widget<FilledButton>(applyFinder)
          .style!
          .backgroundColor!
          .resolve({}),
      AppThemePalette.defaults.surfaceRaised,
    );
    final accentTile = find.byKey(const ValueKey('theme-color-accent'));
    await tester.ensureVisible(accentTile);
    await tester.pumpAndSettle();
    await tester.tap(accentTile);
    await tester.pumpAndSettle();

    final blue = find.byKey(const ValueKey('theme-editor-preset-2979FF'));
    await tester.ensureVisible(blue);
    await tester.pumpAndSettle();
    await tester.tap(blue);
    await tester.pumpAndSettle();

    expect(find.text('#2979FF'), findsOneWidget);
    expect(find.byKey(const ValueKey('theme-editor-hex')), findsNothing);
    final useColor = find.byKey(const ValueKey('theme-editor-use-color'));
    await tester.ensureVisible(useColor);
    await tester.pumpAndSettle();
    await tester.tap(useColor);
    await tester.pumpAndSettle();

    expect(find.text('#2979FF'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(applyFinder)
          .style!
          .backgroundColor!
          .resolve({}),
      const Color(0xFF2979FF),
    );
    expect(tester.widget<FilledButton>(applyFinder).onPressed, isNotNull);
    expect(harness.controller.state.palette, AppThemePalette.defaults);
  });

  testWidgets('exact hex color can be previewed, applied and persisted', (
    tester,
  ) async {
    final values = <String, String>{};
    final harness = await _pumpStudio(tester, values: values);
    addTearDown(harness.dispose);

    final accentTile = find.byKey(const ValueKey('theme-color-accent'));
    await tester.ensureVisible(accentTile);
    await tester.pumpAndSettle();
    await tester.tap(accentTile);
    await tester.pumpAndSettle();
    final hexToggle = find.byKey(const ValueKey('theme-editor-toggle-hex'));
    await tester.ensureVisible(hexToggle);
    await tester.pumpAndSettle();
    await tester.tap(hexToggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('theme-editor-hex')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('theme-editor-hex')),
      '#4C7DFF',
    );
    await tester.tap(find.byKey(const ValueKey('theme-editor-use-color')));
    await tester.pumpAndSettle();
    final applyButton = find.byKey(const ValueKey('theme-studio-apply'));
    await tester.ensureVisible(applyButton);
    await tester.pumpAndSettle();
    await tester.tap(applyButton);
    await tester.pumpAndSettle();

    expect(harness.controller.state.palette.accent, const Color(0xFF4C7DFF));
    expect(values[themeStudioStorageKey], contains('4283203071'));
    expect(find.text('Theme applied.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(applyButton)
          .style!
          .backgroundColor!
          .resolve({}),
      harness.controller.state.palette.surfaceRaised,
    );
  });

  testWidgets('contrast guard disables Apply for unreadable colors', (
    tester,
  ) async {
    final harness = await _pumpStudio(tester);
    addTearDown(harness.dispose);

    final primaryTextTile = find.byKey(
      const ValueKey('theme-color-primaryText'),
    );
    await tester.ensureVisible(primaryTextTile);
    await tester.pumpAndSettle();
    await tester.tap(primaryTextTile);
    await tester.pumpAndSettle();
    final hexToggle = find.byKey(const ValueKey('theme-editor-toggle-hex'));
    await tester.ensureVisible(hexToggle);
    await tester.pumpAndSettle();
    await tester.tap(hexToggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('theme-editor-hex')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('theme-editor-hex')),
      '#030303',
    );
    await tester.tap(find.byKey(const ValueKey('theme-editor-use-color')));
    await tester.pumpAndSettle();

    final apply = tester.widget<FilledButton>(
      find.byKey(const ValueKey('theme-studio-apply')),
    );
    expect(apply.onPressed, isNull);
    expect(find.textContaining('Primary text needs'), findsWidgets);

    final contrastGuard = find.byKey(const ValueKey('theme-contrast-guard'));
    await tester.ensureVisible(contrastGuard);
    await tester.pumpAndSettle();
    await tester.tap(contrastGuard);
    await tester.pumpAndSettle();
    final unguardedApply = tester.widget<FilledButton>(
      find.byKey(const ValueKey('theme-studio-apply')),
    );
    expect(unguardedApply.onPressed, isNotNull);
  });

  testWidgets('reset immediately restores and persists the exact defaults', (
    tester,
  ) async {
    final values = <String, String>{};
    final harness = await _pumpStudio(tester, values: values);
    addTearDown(harness.dispose);
    await harness.controller.apply(
      palette: AppThemePalette.defaults.copyWith(
        accent: const Color(0xFF4C7DFF),
      ),
      contrastGuardEnabled: false,
    );
    await tester.pumpAndSettle();

    final resetButton = find.byKey(const ValueKey('theme-studio-reset'));
    await tester.ensureVisible(resetButton);
    await tester.pumpAndSettle();
    await tester.tap(resetButton);
    await tester.pumpAndSettle();

    expect(harness.controller.state.palette, AppThemePalette.defaults);
    expect(harness.controller.state.contrastGuardEnabled, isTrue);
    expect(values, isEmpty);
    expect(find.text('TetoTV colors restored.'), findsOneWidget);
  });
}

Future<_StudioHarness> _pumpStudio(
  WidgetTester tester, {
  Map<String, String>? values,
  double textScale = 1,
}) async {
  final storage = values ?? <String, String>{};
  final controller = ThemeStudioController(
    const FlutterSecureStorage(),
    readValue: (key) async => storage[key],
    writeValue: (key, value) async => storage[key] = value,
    deleteValue: (key) async => storage.remove(key),
  );
  await controller.load();
  final router = GoRouter(
    initialLocation: '/settings/customize',
    routes: [
      GoRoute(
        path: '/settings/customize',
        builder: (context, state) => Scaffold(
          key: const ValueKey('settings-customize-screen'),
          body: Center(
            child: FilledButton(
              key: const ValueKey('open-theme-studio'),
              onPressed: () => context.push(ThemeStudioScreen.routePath),
              child: const Text('Open Theme Studio'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: ThemeStudioScreen.routePath,
        builder: (context, state) => const RepaintBoundary(
          key: ValueKey('theme-studio-capture'),
          child: ThemeStudioScreen(),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeStudioControllerProvider.overrideWith((_) => controller),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          final theme = ref.watch(themeStudioControllerProvider).palette;
          return MaterialApp.router(
            theme: AppTheme.darkFor(theme),
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('open-theme-studio')));
  await tester.pumpAndSettle();
  return _StudioHarness(controller, router);
}

FocusNode _focusNode(WidgetTester tester, Finder child) {
  final descendant = find.descendant(
    of: child,
    matching: find.byType(FocusableActionDetector),
  );
  final detector = descendant.evaluate().isNotEmpty
      ? descendant
      : find.ancestor(
          of: child,
          matching: find.byType(FocusableActionDetector),
        );
  return tester.widget<FocusableActionDetector>(detector).focusNode!;
}

class _StudioHarness {
  const _StudioHarness(this.controller, this.router);

  final ThemeStudioController controller;
  final GoRouter router;

  void dispose() {
    router.dispose();
  }
}
