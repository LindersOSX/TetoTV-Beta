import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/presentation/caption_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'caption modes have readable labels and predictable remote focus',
    (tester) async {
      final controller = await _pumpStudio(tester);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.mode-automatic',
      );
      final mode = find.byKey(const ValueKey('caption-studio-mode-enabled'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.mode-enabled',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(
        find.descendant(of: mode, matching: find.text('On')),
      );
      expect(text.style?.color, AppThemePalette.defaults.primaryText);
      final surface = tester.widget<Container>(
        find.descendant(of: mode, matching: find.byType(Container)).last,
      );
      expect(
        (surface.decoration as BoxDecoration).color?.computeLuminance(),
        lessThan(.1),
      );
      expect(
        controller.state.preferredCaptionMode,
        PreferredCaptionMode.automatic,
        reason: 'preview is not persisted before Apply',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.mode-disabled',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.mode-disabled',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.language',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.text-color',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.background',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.text-size',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.apply',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(
        controller.state.preferredCaptionMode,
        PreferredCaptionMode.enabled,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'color picker is remote navigable and cancel keeps the current color',
    (tester) async {
      await _pumpStudio(tester);
      final tile = find.byKey(const ValueKey('caption-studio-text-color'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-color.preset-${0xFFFFFFFF}',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-color.preset-${0xFFFFF1D6}',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('#FFF1D6'), findsOneWidget);
      for (
        var index = 0;
        index < 6 &&
            FocusManager.instance.primaryFocus?.debugLabel !=
                'caption-color.exact';
        index++
      ) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-color.exact',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-color.cancel',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('caption-studio-color-picker')),
        findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'caption-studio.text-color',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('caption-preview-text')))
            .style
            ?.color,
        Colors.white,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background picker preserves exact transparency and shows its current swatch',
    (tester) async {
      await _pumpStudio(tester);
      final tile = find.byKey(
        const ValueKey('caption-studio-background-color'),
      );
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('caption-studio-background-exact-color')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('caption-studio-exact-color-input')),
        '#66112233',
      );
      await tester.tap(
        find.byKey(const ValueKey('caption-studio-use-exact-color')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('caption-studio-use-color')));
      await tester.pumpAndSettle();
      final swatch = tester.widget<Container>(
        find.byKey(const ValueKey('caption-studio-background-swatch')),
      );
      expect(
        (swatch.decoration as BoxDecoration).color,
        const Color(0x66112233),
      );
      expect(find.text('#66112233'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV Down from caption size reaches Apply or Reset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async => null,
      writeValue: (key, value) async {},
      deleteValue: (key) async {},
    );
    await controller.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const CaptionStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('caption-studio-size-slider')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final sizeFocus = tester
        .widget<Focus>(
          find
              .descendant(
                of: find.byKey(const ValueKey('caption-studio-size-slider')),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    sizeFocus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'caption-studio.reset',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'caption-studio.text-size',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'caption-studio.apply',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('caption colors and size preview before Apply and persist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stored = <String, String>{};
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async => stored[key],
      writeValue: (key, value) async => stored[key] = value,
      deleteValue: (key) async => stored.remove(key),
    );
    await controller.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const CaptionStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CaptionStudioScreen)),
    );
    expect(
      find.byKey(const ValueKey('caption-studio-preview')),
      findsOneWidget,
    );
    expect(container.read(settingsPreferencesProvider).captionTextSize, 34);

    Future<void> reveal(String key) async {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey(key)),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    const gold = 0xFFFFC857;
    const navy = 0xDD10233D;
    expect(
      find.byKey(const ValueKey('caption-studio-color-picker')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('caption-studio-color-$gold')),
      findsNothing,
    );
    await reveal('caption-studio-text-color');
    await tester.tap(find.byKey(const ValueKey('caption-studio-text-color')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('caption-studio-color-${0xFF2979FF}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('caption-studio-color-$gold')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('caption-studio-use-color')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('caption-preview-text')))
          .style
          ?.color,
      const Color(gold),
    );
    await reveal('caption-studio-background-color');
    await tester.tap(
      find.byKey(const ValueKey('caption-studio-background-color')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('caption-studio-color-$navy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('caption-studio-use-color')));
    await tester.pumpAndSettle();
    expect(
      (tester
                  .widget<DecoratedBox>(
                    find.byKey(const ValueKey('caption-preview-background')),
                  )
                  .decoration
              as BoxDecoration)
          .color,
      const Color(navy),
    );
    await reveal('caption-studio-size-slider');
    final slider = find.descendant(
      of: find.byKey(const ValueKey('caption-studio-size-slider')),
      matching: find.byType(Slider),
    );
    tester.widget<Slider>(slider).onChanged!(43);
    await tester.pump();
    expect(container.read(settingsPreferencesProvider).captionTextSize, 34);

    await reveal('caption-studio-apply');
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('caption-studio-actions')),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('caption-studio-apply')));
    await tester.pumpAndSettle();
    final saved = container.read(settingsPreferencesProvider);
    expect(saved.captionTextColor, gold);
    expect(saved.captionBackgroundColor, navy);
    expect(saved.captionTextSize, 43);
    expect(stored['appearance_caption_text_size'], '43.0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV arrows adjust caption font size one step', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async => null,
      writeValue: (key, value) async {},
      deleteValue: (key) async {},
    );
    await controller.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const CaptionStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('caption-studio-size-slider')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final focus = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(const ValueKey('caption-studio-size-slider')),
            matching: find.byType(Focus),
          )
          .first,
    );
    focus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('Text size  34'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('Text size  35'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('caption studio accepts an exact text color and previews it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async => null,
      writeValue: (key, value) async {},
      deleteValue: (key) async {},
    );
    await controller.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const CaptionStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(
      const ValueKey('caption-studio-text-exact-color'),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('caption-studio-text-color')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('caption-studio-text-color')));
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('caption-studio-exact-color-input')),
      '#2979FF',
    );
    await tester.tap(
      find.byKey(const ValueKey('caption-studio-use-exact-color')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('caption-studio-use-color')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('caption-preview-text')))
          .style
          ?.color,
      const Color(0xFF2979FF),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone caption studio keeps preview and controls in bounds', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async => null,
      writeValue: (key, value) async {},
      deleteValue: (key) async {},
    );
    await controller.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const CaptionStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('caption-studio-preview')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<SettingsPreferencesController> _pumpStudio(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = SettingsPreferencesController(
    const FlutterSecureStorage(),
    readValue: (_) async => null,
    writeValue: (_, _) async {},
    deleteValue: (_) async {},
  );
  await controller.load();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [settingsPreferencesProvider.overrideWith((_) => controller)],
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const CaptionStudioScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}
