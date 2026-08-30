import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/features/settings/application/real_debrid_settings_controller.dart';
import 'package:anime_tv/features/settings/application/home_shelf_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_models.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  const androidChannel = MethodChannel('dev.tetotv/android_tv');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, null);
  });

  for (final layout in <(String, Size)>[
    ('expanded', const Size(1280, 720)),
    ('compact', const Size(390, 844)),
  ]) {
    testWidgets('Classic Settings restores noninitial Back on ${layout.$1}', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = layout.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _ClassicSettingsController(),
            ),
          ],
          child: const MaterialApp(home: TvShortcuts(child: AccountsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('main-navigation')), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.first',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'accounts.back');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.first',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('D-pad traverses Appearance and switches to Services', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.first',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.home-content.featured',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.home-content.poster-metadata',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.home-content.continue-watching',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.shelf.${HomeShelf.values.first.name}',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.home-content.continue-watching',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.show-title-style',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.debrid.provider',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.debrid.connect',
    );
    expect(
      find.byKey(const ValueKey('settings-debrid-stream-sort')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-stream-source-priority')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-web-stream-quality')),
      findsOneWidget,
    );
  });

  testWidgets(
    'TV Settings keep the rail and use the polished two-column tabs',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [isTelevisionProvider.overrideWithValue(true)],
          child: const MaterialApp(home: TvShortcuts(child: AccountsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('main-nav-settings')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-area-downloads')),
        findsNothing,
      );
      expect(find.text('Settings'), findsNothing);
      expect(find.text('APPEARANCE'), findsNothing);
      expect(find.text('Expand all'), findsNothing);
      expect(find.text('Collapse all'), findsNothing);
      expect(
        find.byKey(const ValueKey('customize-toggle-all-sections')),
        findsNothing,
      );

      final appearanceTab = find.byKey(
        const ValueKey('settings-area-appearance'),
      );
      expect(
        find.descendant(
          of: appearanceTab,
          matching: find.byIcon(Icons.palette_rounded),
        ),
        findsNothing,
      );
      final appearanceLabel = find.descendant(
        of: appearanceTab,
        matching: find.text('Appearance'),
      );
      expect(tester.widget<Text>(appearanceLabel).style?.fontSize, 16);
      final activeTabSurfaces = tester
          .widgetList<AnimatedContainer>(
            find.descendant(
              of: appearanceTab,
              matching: find.byType(AnimatedContainer),
            ),
          )
          .where(
            (widget) =>
                widget.decoration is BoxDecoration &&
                (widget.decoration! as BoxDecoration).gradient != null,
          );
      expect(activeTabSurfaces, isEmpty);

      expect(find.text('Theme & display'), findsOneWidget);
      expect(find.text('Navigation'), findsWidgets);
      expect(find.text('Home screen'), findsOneWidget);
      expect(find.text('Theme Studio'), findsOneWidget);
      expect(find.text('Title language'), findsOneWidget);
      expect(find.text('Show title style'), findsOneWidget);
      expect(find.text('Menu order'), findsOneWidget);
      expect(find.text('Featured hero'), findsOneWidget);
      expect(find.text('Poster metadata'), findsOneWidget);
      expect(find.text('Continue watching'), findsWidgets);

      final themeCard = tester.getRect(
        find.byKey(const ValueKey('appearance-theme-display-card')),
      );
      final navigationCard = tester.getRect(
        find.byKey(const ValueKey('appearance-navigation-card')),
      );
      final homeCard = tester.getRect(
        find.byKey(const ValueKey('appearance-home-screen-card')),
      );
      expect(homeCard.left, greaterThan(themeCard.right));
      expect((homeCard.top - themeCard.top).abs(), lessThan(3));
      expect(navigationCard.top, greaterThan(themeCard.bottom));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.first',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Settings option rows exit Left through the active Settings rail item',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const TvShortcuts(child: AccountsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.first',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'top-level.active-navigation',
      );
      final settingsAction = find.byKey(const ValueKey('main-nav-settings'));
      expect(settingsAction, findsOneWidget);
      final settingsFocusable = find.descendant(
        of: settingsAction,
        matching: find.byType(FocusableActionDetector),
      );
      expect(settingsFocusable, findsOneWidget);
      expect(
        tester
            .widget<FocusableActionDetector>(settingsFocusable)
            .focusNode
            ?.hasFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.first',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Auto Pick controls are opt-in, conditional, and D-pad ordered', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey('settings-auto-pick-source-enabled'),
      skipOffstage: false,
    );
    expect(toggle, findsOneWidget);
    expect(
      container.read(settingsPreferencesProvider).autoPickSourceEnabled,
      isFalse,
    );
    expect(
      find.byKey(const ValueKey('settings-auto-pick-source-priority')),
      findsNothing,
    );

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(
      container.read(settingsPreferencesProvider).autoPickSourceEnabled,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('settings-auto-pick-source-priority')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-auto-pick-quality-priority')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-auto-pick-audio')),
      findsOneWidget,
    );
    expect(find.text('Local library'), findsOneWidget);

    final toggleFocusable = tester.widget<TvFocusable>(
      find.descendant(of: toggle, matching: find.byType(TvFocusable)),
    );
    toggleFocusable.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.auto-pick-source',
    );
    expect(
      find.byKey(const ValueKey('inline-section-toggle-source-priority')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('inline-section-toggle-quality-priority')),
      findsOneWidget,
    );

    for (final expected in [
      'accounts.streaming.auto-pick-source.debrid',
      'accounts.streaming.auto-pick-source.web',
      'accounts.streaming.auto-pick-source.yourMedia',
      'accounts.streaming.auto-pick-quality',
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, expected);
    }

    for (final expected in [
      'accounts.streaming.auto-pick-quality.p2160',
      'accounts.streaming.auto-pick-quality.p1080',
      'accounts.streaming.auto-pick-quality.p720',
      'accounts.streaming.auto-pick-quality.p480',
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, expected);
    }

    final qualityHeader = tester.widget<TvFocusable>(
      find.byKey(const ValueKey('inline-section-toggle-quality-priority')),
    );
    qualityHeader.focusNode!.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.auto-pick-quality',
    );
    expect(
      find.byKey(const ValueKey('auto-pick-priority-p2160')),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.auto-pick-audio',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.local-media',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.watch-together',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.local-media',
    );

    await tester.tap(
      find.byKey(
        const ValueKey('auto-pick-priority-earlier-AutoPickSourcePriority.web'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(settingsPreferencesProvider).autoPickSourcePriority.first,
      AutoPickSourcePriority.web,
    );

    final promoteYourMedia = find.byKey(
      const ValueKey(
        'auto-pick-priority-earlier-AutoPickSourcePriority.yourMedia',
      ),
    );
    await tester.tap(promoteYourMedia);
    await tester.pumpAndSettle();
    await tester.tap(promoteYourMedia);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsPreferencesProvider).autoPickSourcePriority.first,
      AutoPickSourcePriority.yourMedia,
    );
    expect(
      container.read(settingsPreferencesProvider).autoPickSourceType,
      AutoPickSourceType.any,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('every source toggle moves Down to Debrid results', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();

    for (final debugLabel in const [
      'accounts.streaming.debrid',
      'accounts.streaming.web',
      'accounts.streaming.direct-torrent',
    ]) {
      final focusableFinder = find.byWidgetPredicate(
        (widget) =>
            widget is TvFocusable && widget.focusNode?.debugLabel == debugLabel,
        skipOffstage: false,
      );
      expect(focusableFinder, findsOneWidget);
      await tester.ensureVisible(focusableFinder);
      await tester.pumpAndSettle();
      final focusable = tester.widget<TvFocusable>(focusableFinder);
      focusable.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.streaming.debrid-sort',
        reason: '$debugLabel should enter the ranking controls below sources.',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'offline downloads master switch hides manager and navigation customization',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TvShortcuts(child: AccountsScreen())),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-area-downloads')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('main-nav-settings')),
        findsOneWidget,
        reason: 'Settings must keep the persistent TV navigation rail visible.',
      );
      await tester.tap(find.text('Services'));
      await tester.pumpAndSettle();

      final toggle = find.byKey(
        const ValueKey('settings-offline-downloads-toggle'),
        skipOffstage: false,
      );
      expect(toggle, findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('settings-download-manager-button'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(
        container.read(settingsPreferencesProvider).offlineDownloadsEnabled,
        isFalse,
      );
      expect(
        container
            .read(settingsPreferencesProvider)
            .isTopNavigationDestinationVisible(
              TopNavigationDestination.downloads,
            ),
        isFalse,
      );
      expect(
        find.byKey(
          const ValueKey('settings-download-manager-button'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.streaming.offline-downloads',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.streaming.offline-downloads',
        reason: 'Down must stop on the last mounted Services control.',
      );

      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      final menuOrder = find.byKey(
        const ValueKey('settings-appearance-menu-order'),
      );
      await tester.ensureVisible(menuOrder);
      await tester.tap(menuOrder);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-top-navigation-toggle-downloads')),
        findsNothing,
      );
      expect(
        container.read(settingsPreferencesProvider).showDownloads,
        isTrue,
        reason: 'the navigation preference must survive the feature opt-out',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in <(String, Size)>[
    ('TV', const Size(1280, 720)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets(
      'Media and Watch Party stay available outside Developer Mode on ${layout.$1}',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.view.physicalSize = layout.$2;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: AccountsScreen())),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Services'));
        await tester.pumpAndSettle();
        for (
          var scroll = 0;
          scroll < 16 &&
              find
                  .byKey(const ValueKey('settings-watch-party-toggle'))
                  .evaluate()
                  .isEmpty;
          scroll++
        ) {
          await tester.drag(find.byType(ListView).last, const Offset(0, -450));
          await tester.pumpAndSettle();
        }

        expect(find.text('Local, Jellyfin & Plex sources'), findsOneWidget);
        expect(find.text('Manage sources'), findsWidgets);
        expect(
          find.byKey(const ValueKey('settings-card-services-features')),
          findsOneWidget,
        );
        expect(find.text('Watch Party'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-watch-party-toggle')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-offline-downloads-toggle')),
          findsOneWidget,
          reason: 'Offline download controls belong in Services.',
        );
        expect(
          find.byKey(const ValueKey('settings-area-downloads')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Home shelves remain directly available below the dashboard', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('inline-section-toggle-home-shelves')),
      findsNothing,
      reason: 'Appearance no longer hides settings in an accordion.',
    );
    expect(find.text('Home shelves'), findsOneWidget);
    expect(find.text('Continue watching'), findsNWidgets(2));
    expect(find.text('Watch history'), findsOneWidget);
    expect(find.text('Recently released'), findsOneWidget);
    expect(find.text('Trending now'), findsOneWidget);
    expect(find.text('Plan to watch'), findsOneWidget);
    expect(find.text('Airing soon'), findsOneWidget);
    expect(find.text('Recently completed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings uses the saved Theme Studio palette', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF102030),
      surface: const Color(0xFF203040),
      accent: const Color(0xFF00CC88),
      primaryText: const Color(0xFFF0FAFF),
      mutedText: const Color(0xFFA0B8C8),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: const AccountsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      palette.background,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedContainer &&
            widget.decoration is BoxDecoration &&
            ((widget.decoration! as BoxDecoration).border as Border?)
                    ?.bottom
                    .color ==
                palette.accentBright,
      ),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).color == palette.surface,
      ),
      findsWidgets,
    );
    expect(
      tester
          .widget<Text>(
            find.text(
              'Choose what appears on Home and move favorites toward the top.',
            ),
          )
          .style
          ?.color,
      palette.mutedText,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home shelf rows toggle visibility and reorder in place', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AccountsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final trackingShelf = find.byWidgetPredicate(
      (widget) =>
          widget is TvFocusable &&
          widget.focusNode?.debugLabel == 'accounts.shelf.tracking',
    );
    await tester.ensureVisible(trackingShelf);
    tester.widget<TvFocusable>(trackingShelf).onPressed();
    await tester.pumpAndSettle();
    expect(
      container.read(homeShelfPreferencesProvider),
      isNot(contains(HomeShelf.tracking)),
    );
    expect(find.text('HIDDEN'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Move Watch history up'));
    await tester.pumpAndSettle();
    expect(
      container.read(homeShelfOrderProvider).take(2),
      orderedEquals([HomeShelf.history, HomeShelf.tracking]),
    );
    expect(find.text('Home shelves'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> selectSettingsArea(WidgetTester tester, String area) async {
    final tab = find.byKey(ValueKey('settings-area-$area'));
    for (var attempt = 0; attempt < 4 && tab.evaluate().isEmpty; attempt++) {
      final tabs = find.ancestor(
        of: find.byKey(const ValueKey('settings-area-appearance')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ListView && widget.scrollDirection == Axis.horizontal,
        ),
      );
      await tester.drag(tabs, const Offset(-260, 0));
      await tester.pumpAndSettle();
    }
    final focusable = tester.widget<TvFocusable>(tab);
    focusable.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  testWidgets('Appearance dashboard is direct and D-pad ordered', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Expand all'), findsNothing);
    expect(find.text('Collapse all'), findsNothing);
    expect(
      find.byKey(const ValueKey('customize-toggle-all-sections')),
      findsNothing,
    );
    for (final label in const [
      'Theme Studio',
      'Title language',
      'Show title style',
      'Navigation size',
      'Menu order',
      'Reset appearance and navigation',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.first',
    );
    for (final expected in const [
      'accounts.title-language',
      'accounts.show-title-style',
      'accounts.customization.navigation-size',
      'accounts.customization.menu-order',
      'accounts.customization.reset',
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, expected);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.reset',
      reason: 'Down stops on the final row in the Appearance column.',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'top-level.active-navigation',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Appearance keeps direct dashboard and advanced controls', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    for (final key in const [
      ValueKey('appearance-theme-display-card'),
      ValueKey('appearance-navigation-card'),
      ValueKey('appearance-home-screen-card'),
    ]) {
      expect(find.byKey(key), findsOneWidget);
    }
    expect(find.text('Theme Studio'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-theme-studio')), findsOneWidget);
    expect(find.textContaining('Classic Layout'), findsNothing);
    expect(find.text('Title language'), findsOneWidget);
    expect(find.text('Show title style'), findsOneWidget);
    expect(find.text('Display options'), findsOneWidget);
    expect(find.text('Input & feedback'), findsOneWidget);
    expect(find.text('Home shelves'), findsOneWidget);
    expect(find.text('Default landing page'), findsOneWidget);
    expect(find.text('On-screen keyboard'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Title language')).dy,
      greaterThan(tester.getTopLeft(find.text('Theme Studio')).dy),
    );
    expect(find.text('Expand all'), findsNothing);
    expect(find.text('Collapse all'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Playback exposes direct polished rows without nested accordions',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Playback'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('inline-section-toggle-closed-captions')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('inline-section-toggle-player-controls')),
        findsNothing,
      );
      expect(find.text('Text color'), findsOneWidget);
      expect(find.text('Default player'), findsOneWidget);

      final playbackTab = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('settings-area-playback')),
      );
      playbackTab.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.captions.text-color',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.area.playback',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'advanced Appearance controls remain mounted below the dashboard',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(960, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      final settingsList = find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.vertical,
      );
      expect(settingsList, findsOneWidget);
      final list = tester.state<ScrollableState>(
        find.descendant(of: settingsList, matching: find.byType(Scrollable)),
      );
      final before = list.position.pixels;
      final landingPage = find.text('Default landing page');
      await tester.ensureVisible(landingPage);
      await tester.pumpAndSettle();
      expect(list.position.pixels, greaterThan(before));
      expect(find.text('Display options'), findsOneWidget);
      expect(find.text('Input & feedback'), findsOneWidget);
      expect(find.text('Home shelves'), findsOneWidget);
      expect(find.text('On-screen keyboard'), findsOneWidget);
      expect(find.text('Watch history'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Reset appearance stops Down and exits Left to Settings rail', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const TvShortcuts(child: AccountsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final resetButton = find
        .ancestor(
          of: find.text('Reset appearance and navigation'),
          matching: find.byType(TvFocusable),
        )
        .first;
    await tester.ensureVisible(resetButton);
    final resetFocus = tester.widget<TvFocusable>(resetButton).focusNode!;
    resetFocus.requestFocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.reset',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(resetFocus.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'top-level.active-navigation',
    );
    final settingsAction = find.byKey(const ValueKey('main-nav-settings'));
    final settingsFocusable = find.descendant(
      of: settingsAction,
      matching: find.byType(FocusableActionDetector),
    );
    expect(
      tester
          .widget<FocusableActionDetector>(settingsFocusable)
          .focusNode
          ?.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('D-pad traverses all seven visible Home shelf rows in order', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    final firstShelf = find.byWidgetPredicate(
      (widget) =>
          widget is TvFocusable &&
          widget.focusNode?.debugLabel ==
              'accounts.shelf.${HomeShelf.values.first.name}',
    );
    await tester.ensureVisible(firstShelf);
    tester.widget<TvFocusable>(firstShelf).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.home-content.continue-watching',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    for (var index = 0; index < HomeShelf.values.length; index++) {
      final shelf = HomeShelf.values[index];
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.shelf.${shelf.name}',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.shelf.${HomeShelf.values.last.name}',
      reason: 'Down stops at the final visible shelf row.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('D-pad reaches the bottom AniList save action on a TV canvas', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Optional private-repository token'), findsNothing);
    expect(find.text('Read-only GitHub token'), findsNothing);

    await selectSettingsArea(tester, 'accounts');
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.anilist.save',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Calendar notification choices are D-pad ordered and focusable', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await selectSettingsArea(tester, 'accounts');
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.tracking.sub-notifications',
    );
    expect(
      find.byKey(const ValueKey('settings-sub-episode-notifications')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AccountsScreen)),
    );
    expect(
      container
          .read(settingsPreferencesProvider)
          .subEpisodeNotificationsEnabled,
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.tracking.dub-notifications',
    );
    expect(
      find.byKey(const ValueKey('settings-dub-episode-notifications')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.tracking.dub-notifications',
      reason: 'Down stops when the Discord action is unavailable and disabled.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Title language moves Down to Show title style', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Title language'), findsOneWidget);
    final languageControl = tester.widget<TvFocusable>(
      find.descendant(
        of: find.byKey(const ValueKey('settings-appearance-title-language')),
        matching: find.byType(TvFocusable),
      ),
    );
    final languageFocus = languageControl.focusNode!;
    languageFocus.requestFocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.title-language',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.show-title-style',
    );
    final titleStyleControl = tester.widget<TvFocusable>(
      find.descendant(
        of: find.byKey(const ValueKey('settings-appearance-show-title-style')),
        matching: find.byType(TvFocusable),
      ),
    );
    expect(titleStyleControl.focusNode?.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.title-language',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Romaji').last);
    await tester.pumpAndSettle();
    expect(find.text('Romaji'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider selector only shows the chosen debrid configuration', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Advanced: personal token'), findsNothing);
    expect(find.text('TorBox API token'), findsNothing);

    await selectSettingsArea(tester, 'services');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('Advanced: personal token'), findsNothing);
    expect(find.text('Connect by QR'), findsOneWidget);
    expect(find.text('Debrid provider'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Advanced: personal token'), findsNothing);
    expect(find.text('TorBox API token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D-pad reaches automatic and manual update controls', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    await selectSettingsArea(tester, 'system');
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.updates.automatic',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.updates.check',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.setup',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.updates.automatic',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.updates.check',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.discord-qr',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.discord',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.donation-qr',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.donate',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.clear-cache',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.reset-app',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.privacy',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.legal',
    );
    expect(find.text('Third-party notices'), findsOneWidget);
    expect(
      find.textContaining('AI-assisted development tools'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ten System activations toggle persistent developer mode', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, (call) async {
          if (call.method == 'getAppVersion') {
            return <String, Object?>{
              'versionName': '1.0.0',
              'versionCode': 10000,
            };
          }
          return null;
        });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    await selectSettingsArea(tester, 'system');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.area.system',
    );
    for (var index = 0; index < 10; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final storage = const FlutterSecureStorage();
      for (var attempt = 0; attempt < 50; attempt++) {
        if (await storage.read(key: developerModeStorageKey) == 'true') return;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AccountsScreen)),
    );
    expect(container.read(appUpdateControllerProvider).developerMode, isTrue);
    expect(find.text('Developer update tools'), findsOneWidget);
    expect(find.text('Update channel'), findsOneWidget);
    expect(find.text('Public'), findsOneWidget);
    expect(find.text('Load release history'), findsOneWidget);
    expect(
      find.textContaining(
        'Android only installs the same or a higher build code',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Developer Mode cannot bypass that rule'),
      findsOneWidget,
    );
    expect(
      find.textContaining('install an older or newer signed build'),
      findsNothing,
    );
    expect(find.textContaining('Beta key'), findsNothing);
    expect(find.textContaining('Installed version:'), findsOneWidget);
    expect(find.textContaining('Build:'), findsOneWidget);
    expect(
      await const FlutterSecureStorage().read(key: developerModeStorageKey),
      'true',
    );

    for (var index = 0; index < 10; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() async {
      final storage = const FlutterSecureStorage();
      for (var attempt = 0; attempt < 50; attempt++) {
        if (await storage.read(key: developerModeStorageKey) == null) return;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await tester.pumpAndSettle();

    expect(container.read(appUpdateControllerProvider).developerMode, isFalse);
    expect(find.text('Developer update tools'), findsNothing);
    expect(find.text('Update channel'), findsNWidgets(2));
    expect(
      await const FlutterSecureStorage().read(key: developerModeStorageKey),
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy Beta key is removed and key controls stay hidden', (
    tester,
  ) async {
    const betaKey = 'beta_test_access_key_0123456789abcdef';
    FlutterSecureStorage.setMockInitialValues({
      developerModeStorageKey: 'true',
      'beta_update_access_key': betaKey,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, (call) async {
          if (call.method == 'getAppVersion') {
            return <String, Object?>{
              'versionName': '1.0.0',
              'versionCode': 410001,
            };
          }
          return null;
        });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();
    await selectSettingsArea(tester, 'system');

    expect(find.text('Load release history'), findsOneWidget);
    expect(find.textContaining('Beta key'), findsNothing);
    expect(find.text(betaKey), findsNothing);
    expect(find.textContaining(betaKey), findsNothing);
    expect(
      await const FlutterSecureStorage().read(key: 'beta_update_access_key'),
      isNull,
    );
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.updates.channel',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.updates.release-history',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('System settings expose a remote-selectable Discord invite QR', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();
    await selectSettingsArea(tester, 'system');

    expect(find.byType(QrImageView, skipOffstage: false), findsNWidgets(2));
    expect(
      find.text('https://discord.gg/juC6k7d4WY', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text('https://ko-fi.com/lindowsosx', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text('Discord Rich Presence', skipOffstage: false),
      findsNothing,
    );
    expect(
      find.text('Double-click or press OK twice to copy', skipOffstage: false),
      findsNothing,
    );
    final discordTitle = find.text(
      'Join the TetoTV Discord',
      skipOffstage: false,
    );
    final donationTitle = find.text('Support TetoTV', skipOffstage: false);
    final discordRect = tester.getRect(discordTitle);
    final donationRect = tester.getRect(donationTitle);
    expect(donationRect.top, greaterThan(discordRect.bottom));
    final qrCodes = find.byType(QrImageView, skipOffstage: false);
    final discordQrRect = tester.getRect(qrCodes.at(0));
    final donationQrRect = tester.getRect(qrCodes.at(1));
    expect(discordRect.left, greaterThan(discordQrRect.right));
    expect(donationRect.left, greaterThan(donationQrRect.right));
    expect(donationQrRect.top, greaterThan(discordQrRect.bottom));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.discord-qr',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.discord',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.donation-qr',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.donate',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Accounts expose Discord Rich Presence actions', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();

    final discordActions = find.byKey(
      const ValueKey('discord-presence-actions'),
      skipOffstage: false,
    );
    expect(discordActions, findsOneWidget);

    await tester.ensureVisible(discordActions);
    await tester.pumpAndSettle();
    expect(tester.getSize(discordActions).width, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone System community and support keep their QR codes', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [isTelevisionProvider.overrideWithValue(false)],
        child: const MaterialApp(home: AccountsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView, skipOffstage: false), findsNWidgets(2));
    expect(
      find.text(
        'Scan the code with your phone, or select the invite below to copy it.',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Scan with your phone to open the official TetoTV Ko-fi page',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Storage actions fit phones and Clear cache preserves app data', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? method;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, (call) async {
          method = call.method;
          if (call.method == 'clearAppCache') return 1536;
          return null;
        });

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    final clear = find.byKey(
      const ValueKey('storage-clear-cache'),
      skipOffstage: false,
    );
    final reset = find.byKey(
      const ValueKey('storage-reset-app'),
      skipOffstage: false,
    );
    expect(clear, findsOneWidget);
    expect(reset, findsOneWidget);
    expect(
      tester.getTopLeft(reset).dy,
      greaterThan(tester.getTopLeft(clear).dy),
      reason: 'Storage actions stack on a narrow phone without clipping.',
    );

    await tester.scrollUntilVisible(
      clear,
      500,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(method, 'clearAppCache');
    expect(find.text('Cleared 1.5 KB of temporary files.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Reset requires two confirmations with safe cancel focus', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var resetCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, (call) async {
          if (call.method == 'resetApplicationData') {
            resetCalls++;
            return true;
          }
          return null;
        });

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    final resetAction = find.byKey(
      const ValueKey('storage-reset-app'),
      skipOffstage: false,
    );
    await tester.scrollUntilVisible(
      resetAction,
      500,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(resetAction);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-warning-dialog')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-warning-dialog')), findsNothing);
    expect(resetCalls, 0, reason: 'Enter activates the focused safe action.');
    await tester.tap(resetAction);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-warning-continue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-final-dialog')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reset-final-dialog')), findsNothing);
    expect(resetCalls, 0, reason: 'The second dialog also defaults to cancel.');
    await tester.tap(resetAction);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-warning-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-final-confirm')));
    await tester.pumpAndSettle();
    expect(resetCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connected debrid traversal only targets visible controls', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      developerModeStorageKey: 'true',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidChannel, (call) async {
          if (call.method == 'getAppVersion') {
            return <String, Object?>{
              'versionName': '1.0.1',
              'versionCode': 410002,
            };
          }
          return null;
        });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realDebridSettingsControllerProvider.overrideWith(
            (_) => _ConnectedRealDebridController(),
          ),
        ],
        child: const MaterialApp(home: AccountsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await selectSettingsArea(tester, 'services');
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.debrid.connect',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.debrid',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.debrid.connect',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.debrid.connect',
    );

    expect(find.byKey(const ValueKey('settings-area-downloads')), findsNothing);
    Finder localMediaButton() => find.byWidgetPredicate(
      (widget) =>
          widget is TvFocusable &&
          widget.focusNode?.debugLabel == 'accounts.streaming.local-media',
    );
    for (
      var scroll = 0;
      scroll < 20 && localMediaButton().evaluate().isEmpty;
      scroll++
    ) {
      await tester.drag(
        find.byKey(const ValueKey('settings-content-list')),
        const Offset(0, -450),
      );
      await tester.pumpAndSettle();
    }
    expect(localMediaButton(), findsOneWidget);
    tester.widget<TvFocusable>(localMediaButton()).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.watch-together',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.offline-downloads',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.watch-together',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.download-manager',
    );
    expect(
      find.byKey(const ValueKey('settings-download-manager-button')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.download-manager',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('organized settings sections fit a narrow mobile screen', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountsScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Appearance'), findsWidgets);
    expect(find.text('Playback'), findsOneWidget);
    expect(find.text('Services'), findsOneWidget);
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-area-downloads')), findsNothing);
    expect(find.text('Customize'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('appearance-theme-display-card')),
      findsOneWidget,
    );
    expect(find.text('10-foot layout'), findsNothing);
    expect(find.text('Denser handheld layout'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AccountsScreen)),
    );
    expect(
      container
          .read(settingsPreferencesProvider)
          .anonymousCrashReportingEnabled,
      isFalse,
    );
    final scaffold = find.byType(Scaffold).first;
    expect(tester.getTopLeft(scaffold), Offset.zero);
    expect(tester.getSize(scaffold), const Size(390, 844));
    expect(
      tester.widget<SafeArea>(find.byType(SafeArea).first).minimum,
      const EdgeInsets.symmetric(horizontal: 16),
      reason:
          'Settings controls need a responsive side inset on narrow screens.',
    );
    expect(tester.takeException(), isNull);

    await selectSettingsArea(tester, 'system');
    expect(
      find.text(
        'Manage this device, updates, diagnostics, privacy, storage, and legal information.',
      ),
      findsOneWidget,
    );
    final crashToggle = find.text(
      'Anonymous crash reports',
      skipOffstage: false,
    );
    expect(crashToggle, findsOneWidget);
    await tester.ensureVisible(crashToggle);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(crashToggle);
    await tester.pumpAndSettle();
    expect(
      container
          .read(settingsPreferencesProvider)
          .anonymousCrashReportingEnabled,
      isTrue,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('switching Settings tabs starts the new tab at the top', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [isTelevisionProvider.overrideWithValue(false)],
        child: const MaterialApp(home: AccountsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final settingsList = find.byKey(const ValueKey('settings-content-list'));
    final scrollable = find.descendant(
      of: settingsList,
      matching: find.byType(Scrollable),
    );
    final scrollState = tester.state<ScrollableState>(scrollable.first);
    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
    await tester.pump();
    expect(scrollState.position.pixels, greaterThan(0));

    await tester.tap(
      find.byKey(const ValueKey('settings-area-services')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(scrollState.position.pixels, 0);
    expect(
      find.byKey(const ValueKey('settings-card-services-debrid')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'navigation bar can be ordered and hidden without losing access',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
        ),
      );
      await tester.pumpAndSettle();

      final menuOrder = find.byKey(
        const ValueKey('settings-appearance-menu-order'),
      );
      tester
          .widget<TvFocusable>(
            find.descendant(of: menuOrder, matching: find.byType(TvFocusable)),
          )
          .onPressed();
      await tester.pumpAndSettle();
      expect(find.text('Navigation bar'), findsOneWidget);
      final homeToggle = find.byKey(
        const ValueKey('settings-top-navigation-toggle-home'),
      );
      await tester.ensureVisible(homeToggle);
      tester.widget<TvFocusable>(homeToggle).focusNode!.requestFocus();
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.menu-order.home',
      );

      final moveSearchLater = find.byKey(
        const ValueKey('settings-top-navigation-later-search'),
      );
      await tester.ensureVisible(moveSearchLater);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: moveSearchLater,
          matching: find.byType(TvFocusable),
        ),
        findsOneWidget,
      );
      await tester.tap(moveSearchLater);
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(AccountsScreen)),
      );
      expect(container.read(settingsPreferencesProvider).topNavigationOrder, [
        TopNavigationDestination.home,
        TopNavigationDestination.myList,
        TopNavigationDestination.search,
        TopNavigationDestination.discover,
        TopNavigationDestination.calendar,
        TopNavigationDestination.watchTogether,
        TopNavigationDestination.downloads,
        TopNavigationDestination.settings,
      ]);

      await tester.ensureVisible(homeToggle);
      tester.widget<TvFocusable>(homeToggle).onPressed();
      await tester.pumpAndSettle();
      expect(container.read(settingsPreferencesProvider).showHome, isFalse);

      final settingsToggle = find.byKey(
        const ValueKey('settings-top-navigation-toggle-settings'),
      );
      await tester.ensureVisible(settingsToggle);
      tester.widget<TvFocusable>(settingsToggle).onPressed();
      await tester.pump();
      expect(container.read(settingsPreferencesProvider).showSettings, isTrue);
      expect(
        container.read(settingsPreferencesProvider).settingsEntryPlacement,
        SettingsEntryPlacement.profileMenu,
      );
      expect(tester.widget(settingsToggle), isA<TvFocusable>());
      expect(find.text('PROFILE MENU'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('settings-top-navigation-earlier-settings'),
          ),
          matching: find.byType(TvFocusable),
        ),
        findsOneWidget,
        reason: 'Settings remains reorderable even though it cannot be hidden',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('filler labels setting is TV-focusable and updates globally', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: TvShortcuts(child: AccountsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Playback'));
    await tester.pumpAndSettle();

    final fillerLabel = find.text('Filler episode labels', skipOffstage: false);
    expect(fillerLabel, findsOneWidget);
    await tester.ensureVisible(fillerLabel);
    await tester.pumpAndSettle();
    expect(
      find.ancestor(of: fillerLabel, matching: find.byType(TvFocusable)),
      findsOneWidget,
    );

    await tester.tap(fillerLabel);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AccountsScreen)),
    );
    expect(
      container.read(settingsPreferencesProvider).showFillerIndicators,
      isFalse,
    );
    expect(find.text('Filler episode labels'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'device keyboard stays closed while D-pad reaches Debrid results',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'input_use_built_in_keyboard': 'false',
      });
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: AccountsScreen())),
      );
      await tester.pumpAndSettle();

      await selectSettingsArea(tester, 'services');
      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.torbox.token',
      );
      expect(tester.testTextInput.isVisible, isFalse);

      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.streaming.debrid-sort',
      );
      expect(tester.testTextInput.isVisible, isFalse);

      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowUp,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.torbox.token',
      );
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ConnectedRealDebridController extends RealDebridSettingsController {
  _ConnectedRealDebridController()
    : super(const FlutterSecureStorage(), (_) => throw UnimplementedError()) {
    state = const RealDebridSettingsState(
      hasSavedToken: true,
      account: RealDebridAccount(
        id: 1,
        username: 'connected-user',
        type: 'premium',
      ),
    );
  }

  @override
  Future<void> load() async {}
}

class _ClassicSettingsController extends SettingsPreferencesController {
  _ClassicSettingsController() : super(const FlutterSecureStorage()) {
    state = const SettingsPreferences(
      interfaceMode: InterfaceMode.phone,
      loaded: true,
    );
  }

  @override
  Future<void> load() async {}
}
