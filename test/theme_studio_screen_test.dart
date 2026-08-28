import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:anime_tv/features/settings/presentation/theme_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        builder: (context, state) => const ThemeStudioScreen(),
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
