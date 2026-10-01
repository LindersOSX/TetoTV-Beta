import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/home_shelf_preferences_controller.dart';
import 'package:anime_tv/features/settings/presentation/display_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('blur draft applies and Reset defaults restores enabled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = <String, String>{};
    final controller = SettingsPreferencesController(
      const FlutterSecureStorage(),
      readValue: (key) async => saved[key],
      writeValue: (key, value) async {
        saved[key] = value;
      },
      deleteValue: (key) async {
        saved.remove(key);
      },
    );
    await controller.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith((_) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const DisplayStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final blur = find.byKey(const ValueKey('display-studio-blur-effects'));
    await tester.scrollUntilVisible(
      blur,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    tester
        .widget<SwitchListTile>(
          find.descendant(of: blur, matching: find.byType(SwitchListTile)),
        )
        .onChanged!(false);
    await tester.pumpAndSettle();
    expect(controller.state.blurEffectsEnabled, isTrue);
    final apply = find.byKey(const ValueKey('display-studio-apply'));
    await tester.scrollUntilVisible(
      apply,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(controller.state.blurEffectsEnabled, isFalse);
    expect(saved['appearance_blur_effects'], 'false');
    await tester.tap(find.byKey(const ValueKey('display-studio-reset')));
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(controller.state.blurEffectsEnabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV Down reaches studio actions and Up returns to shelves', (
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
          home: const DisplayStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('display-studio-home-shelves')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final shelves = tester.widget<TvFocusable>(
      find
          .descendant(
            of: find.byKey(const ValueKey('display-studio-home-shelves')),
            matching: find.byType(TvFocusable),
          )
          .first,
    );
    shelves.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'display-studio.apply',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'display-studio.reset',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'display-studio.apply',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'display-studio.reset',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'display-studio.home-shelves',
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('display-studio-card-details')),
      -240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final details = find.descendant(
      of: find.byKey(const ValueKey('display-studio-card-details')),
      matching: find.byType(SwitchListTile),
    );
    tester.widget<SwitchListTile>(details).onChanged!(false);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('display-studio-home-shelves')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    shelves.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'display-studio.apply',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliders preview exact percentages before applying', (
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
          home: const DisplayStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('display-studio-preview')),
      findsOneWidget,
    );
    expect(find.byType(Slider), findsAtLeastNWidgets(2));
    SettingsPreferences settings() => ProviderScope.containerOf(
      tester.element(find.byType(DisplayStudioScreen)),
    ).read(settingsPreferencesProvider);
    expect(settings().interfaceScale, 1);
    expect(settings().thumbnailScale, 1);

    final interface = find.descendant(
      of: find.byKey(const ValueKey('display-studio-interface-slider')),
      matching: find.byType(Slider),
    );
    tester.widget<Slider>(interface).onChanged!(1.07);
    await tester.pump();
    expect(find.text('107%'), findsOneWidget);
    expect(settings().interfaceScale, 1);

    final thumbnail = find.descendant(
      of: find.byKey(const ValueKey('display-studio-thumbnail-slider')),
      matching: find.byType(Slider),
    );
    tester.widget<Slider>(thumbnail).onChanged!(1.13);
    await tester.pump();
    expect(find.text('113%'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('display-studio-apply')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('display-studio-actions')),
        matching: find.byType(ListView),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('display-studio-apply')));
    await tester.pumpAndSettle();
    expect(settings().interfaceScale, 1.07);
    expect(settings().thumbnailScale, 1.13);
    expect(stored['appearance_interface_scale'], '1.07');
    expect(stored['appearance_thumbnail_scale'], '1.13');
  });

  testWidgets('TV sliders adjust only after Select activates them', (
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
          home: const DisplayStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('100%'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('101%'), findsOneWidget);
    final focusedCard = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const ValueKey('display-studio-interface-slider')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((focusedCard.decoration as BoxDecoration).boxShadow, isNotEmpty);
    final thumbnailFocus = tester
        .widget<Focus>(
          find
              .descendant(
                of: find.byKey(
                  const ValueKey('display-studio-thumbnail-slider'),
                ),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    thumbnailFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('101%'), findsNWidgets(2));
  });

  testWidgets(
    'layout, hero, card details, and menu order preview until Apply',
    (tester) async {
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
            home: const DisplayStudioScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DisplayStudioScreen)),
      );
      expect(
        find.byKey(const ValueKey('display-preview-hero')),
        findsOneWidget,
      );

      Future<void> reveal(String key) async {
        await tester.scrollUntilVisible(
          find.byKey(ValueKey(key)),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      await reveal('display-studio-density-slider');
      tester
          .widget<Slider>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-density-slider')),
              matching: find.byType(Slider),
            ),
          )
          .onChanged!(.83);
      await tester.pump();
      expect(
        container.read(settingsPreferencesProvider).contentDensity,
        ContentDensity.standard,
      );

      await reveal('display-studio-layout-slider');
      tester
          .widget<Slider>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-layout-slider')),
              matching: find.byType(Slider),
            ),
          )
          .onChanged!(.37);
      await tester.pump();

      await reveal('display-studio-card-details');
      final detailsCard = find.byKey(
        const ValueKey('display-studio-card-details'),
      );
      tester
          .widget<SwitchListTile>(
            find.descendant(
              of: detailsCard,
              matching: find.byType(SwitchListTile),
            ),
          )
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      final detailsSurface = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: detailsCard,
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      expect(
        (detailsSurface.decoration as BoxDecoration).boxShadow,
        isNotEmpty,
      );
      tester
          .widget<SwitchListTile>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-card-details')),
              matching: find.byType(SwitchListTile),
            ),
          )
          .onChanged!(false);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('display-preview-card-detail-0')),
        findsNothing,
      );

      await reveal('display-studio-featured-hero');
      tester
          .widget<SwitchListTile>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-featured-hero')),
              matching: find.byType(SwitchListTile),
            ),
          )
          .onChanged!(false);
      await tester.pump();
      expect(find.byKey(const ValueKey('display-preview-hero')), findsNothing);

      await reveal('display-studio-poster-metadata');
      expect(
        find.byKey(const ValueKey('display-preview-poster-metadata-0')),
        findsOneWidget,
      );
      tester
          .widget<SwitchListTile>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-poster-metadata')),
              matching: find.byType(SwitchListTile),
            ),
          )
          .onChanged!(false);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('display-preview-poster-metadata-0')),
        findsNothing,
      );

      await reveal('display-studio-navigation-slider');
      tester
          .widget<Slider>(
            find.descendant(
              of: find.byKey(
                const ValueKey('display-studio-navigation-slider'),
              ),
              matching: find.byType(Slider),
            ),
          )
          .onChanged!(1.16);
      await tester.pump();

      await reveal('display-studio-landing-page');
      await tester.tap(
        find.byKey(const ValueKey('display-studio-landing-page')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('display-studio-landing-search')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('display-studio-landing-search')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(settingsPreferencesProvider).defaultLandingPage,
        LandingPage.home,
      );

      await reveal('display-studio-menu-order');
      expect(
        find.byKey(const ValueKey('display-studio-menu-home')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('display-studio-menu-order')));
      await tester.pumpAndSettle();
      await reveal('display-studio-menu-home');
      tester
          .widgetList<IconButton>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-menu-home')),
              matching: find.byType(IconButton),
            ),
          )
          .last
          .onPressed!();
      await tester.pump();
      expect(
        container.read(settingsPreferencesProvider).topNavigationOrder.first,
        TopNavigationDestination.home,
      );

      await reveal('display-studio-menu-discover');
      tester
          .widget<Switch>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-menu-discover')),
              matching: find.byType(Switch),
            ),
          )
          .onChanged!(false);
      await tester.pump();
      await reveal('display-studio-menu-settings');
      tester
          .widget<Switch>(
            find.descendant(
              of: find.byKey(const ValueKey('display-studio-menu-settings')),
              matching: find.byType(Switch),
            ),
          )
          .onChanged!(false);
      await tester.pump();
      expect(container.read(settingsPreferencesProvider).showSettings, isTrue);

      await reveal('display-studio-apply');
      await tester.tap(find.byKey(const ValueKey('display-studio-apply')));
      await tester.pumpAndSettle();
      final applied = container.read(settingsPreferencesProvider);
      expect(applied.effectiveContentDensityScale, .83);
      expect(applied.effectiveHomeLayoutCompactness, .37);
      expect(applied.effectiveNavigationChromeScale, 1.16);
      expect(applied.defaultLandingPage, LandingPage.search);
      expect(applied.showDiscover, isFalse);
      expect(applied.showSettings, isFalse);
      expect(applied.showCardSubtitles, isFalse);
      expect(applied.showHero, isFalse);
      expect(applied.showPosterMetadata, isFalse);
      expect(applied.topNavigationOrder.first, TopNavigationDestination.search);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone layout keeps preview and controls without overflow', (
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
          home: const DisplayStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('display-studio-preview')),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('display-studio-preview')),
      findsOneWidget,
    );
  });

  testWidgets('home shelves expand inline, preview, and save on Apply', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
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
          home: const DisplayStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final section = find.byKey(const ValueKey('display-studio-home-shelves'));
    await tester.scrollUntilVisible(
      section,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('display-studio-shelf-tracking')),
      findsNothing,
    );
    await tester.tap(section);
    await tester.pumpAndSettle();
    final tracking = find.byKey(
      const ValueKey('display-studio-shelf-tracking'),
    );
    await tester.scrollUntilVisible(
      tracking,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    tester
        .widget<Switch>(
          find.descendant(of: tracking, matching: find.byType(Switch)),
        )
        .onChanged!(false);
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DisplayStudioScreen)),
    );
    expect(
      container.read(homeShelfPreferencesProvider),
      contains(HomeShelf.tracking),
    );
    expect(find.text('Watch history'), findsWidgets);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('display-studio-apply')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('display-studio-apply')));
    await tester.pumpAndSettle();
    expect(
      container.read(homeShelfPreferencesProvider),
      isNot(contains(HomeShelf.tracking)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation labels and reduced motion save only on Apply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stored = <String, String>{
      'navigation_expand_labels_on_focus': 'false',
      navigationLabelExpansionMigrationKey: 'true',
    };
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
          home: const DisplayStudioScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('display-preview-expanded-label')),
      findsNothing,
    );
    final switchCard = find.byKey(
      const ValueKey('display-studio-expand-navigation-labels'),
    );
    final motionCard = find.byKey(
      const ValueKey('display-studio-reduce-motion'),
    );
    await tester.scrollUntilVisible(
      motionCard,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    tester
        .widget<SwitchListTile>(
          find.descendant(
            of: motionCard,
            matching: find.byType(SwitchListTile),
          ),
        )
        .onChanged!(true);
    await tester.pumpAndSettle();
    expect(controller.state.reduceMotion, isFalse);
    await tester.scrollUntilVisible(
      switchCard,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    tester
        .widget<SwitchListTile>(
          find.descendant(
            of: switchCard,
            matching: find.byType(SwitchListTile),
          ),
        )
        .onChanged!(true);
    await tester.pumpAndSettle();
    expect(controller.state.expandNavigationLabelsOnFocus, isFalse);
    expect(
      find.byKey(const ValueKey('display-preview-expanded-label')),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('display-studio-apply')),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('display-studio-apply')));
    await tester.pumpAndSettle();
    expect(controller.state.expandNavigationLabelsOnFocus, isTrue);
    expect(stored['navigation_expand_labels_on_focus'], 'true');
    expect(controller.state.reduceMotion, isTrue);
    expect(stored['appearance_reduce_motion'], 'true');
    expect(tester.takeException(), isNull);
  });
}
