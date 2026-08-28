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
        'accounts.area.customize',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'accounts.back');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.area.customize',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('D-pad reaches Home shelves and switches to streaming', (
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
      'accounts.area.customize',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.toggle-all',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.section.home-shelves',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.shelf.tracking',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.shelf.history',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
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

      final displayToggle = find.byKey(
        const ValueKey('inline-section-toggle-display'),
      );
      await tester.tap(displayToggle);
      await tester.pumpAndSettle();

      // This chip deliberately owns an anonymous TvFocusable node. It covers
      // Settings controls which are not part of the screen's explicit graph.
      final smallChip = find
          .ancestor(
            of: find.text('Small').first,
            matching: find.byType(TvFocusable),
          )
          .first;
      await tester.tap(smallChip);
      await tester.pumpAndSettle();
      final mediumChip = find
          .ancestor(
            of: find.text('Medium').first,
            matching: find.byType(TvFocusable),
          )
          .first;
      await tester.tap(mediumChip);
      await tester.pumpAndSettle();
      final smallFocus = tester
          .widget<FocusableActionDetector>(
            find.descendant(
              of: smallChip,
              matching: find.byType(FocusableActionDetector),
            ),
          )
          .focusNode!;
      final mediumFocus = tester
          .widget<FocusableActionDetector>(
            find.descendant(
              of: mediumChip,
              matching: find.byType(FocusableActionDetector),
            ),
          )
          .focusNode!;
      expect(mediumFocus.hasFocus, isTrue);

      // LEFT still moves normally inside a Settings option row.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(smallFocus.hasFocus, isTrue);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'TV mouse/D-pad control',
      );

      for (var press = 0; press < 8; press++) {
        if (FocusManager.instance.primaryFocus?.debugLabel ==
            'top-level.active-navigation') {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
      }

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
        'accounts.area.customize',
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
    await tester.tap(find.text('Streaming'));
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey('settings-auto-pick-source-enabled'),
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
      'accounts.streaming.offline-downloads',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.download-manager',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.local-media',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.download-manager',
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
    await tester.tap(find.text('Streaming'));
    await tester.pumpAndSettle();

    for (final prefix in const ['DEBRID', 'WEB', 'DIRECT PEER']) {
      final label = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp('^$prefix (ON|OFF)\$').hasMatch(widget.data ?? ''),
      );
      final focusable = tester.widget<TvFocusable>(
        find.ancestor(of: label, matching: find.byType(TvFocusable)).first,
      );
      focusable.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.streaming.debrid-sort',
        reason: '$prefix should enter the ranking controls below sources.',
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
      await tester.tap(find.text('Streaming'));
      await tester.pumpAndSettle();

      final toggle = find.byKey(
        const ValueKey('settings-offline-downloads-toggle'),
      );
      expect(toggle, findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-download-manager-button')),
        findsOneWidget,
      );

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
        find.byKey(const ValueKey('settings-download-manager-button')),
        findsNothing,
      );

      await tester.tap(find.text('Customize'));
      await tester.pumpAndSettle();
      final homeNavigation = find.byKey(
        const ValueKey('inline-section-toggle-home-navigation'),
      );
      await tester.ensureVisible(homeNavigation);
      await tester.tap(homeNavigation);
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
        await tester.tap(find.text('Streaming'));
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
        expect(find.text('Manage sources'), findsOneWidget);
        expect(find.text('Watch Party'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-watch-party-toggle')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Home shelves expand inline from a collapsed heading', (
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

    expect(find.text('Home section'), findsNothing);
    expect(find.text('Continue watching'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('inline-section-toggle-home-shelves')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Continue watching'), findsOneWidget);
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

    await tester.tap(
      find.byKey(const ValueKey('inline-section-toggle-home-shelves')),
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
            (widget.decoration! as BoxDecoration).color == palette.accent,
      ),
      findsOneWidget,
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

    await tester.tap(
      find.byKey(const ValueKey('inline-section-toggle-home-shelves')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue watching'));
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
    expect(find.text('Home section'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D-pad Expand all and Collapse all update all Customize groups', (
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

    final toggleAll = find.byKey(
      const ValueKey('customize-toggle-all-sections'),
    );
    expect(find.text('Expand all'), findsOneWidget);
    for (final label in const [
      'Continue watching',
      'Theme Studio',
      'Default landing page',
      'On-screen keyboard',
      'Text color',
      'Preferred audio',
    ]) {
      expect(find.text(label), findsNothing);
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.toggle-all',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Collapse all'), findsOneWidget);
    for (final label in const [
      'Continue watching',
      'Theme Studio',
      'Default landing page',
      'On-screen keyboard',
      'Text color',
      'Preferred audio',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.toggle-all',
    );

    final displayToggle = find.byKey(
      const ValueKey('inline-section-toggle-display'),
    );
    tester.widget<TvFocusable>(displayToggle).onPressed();
    await tester.pumpAndSettle();
    expect(find.text('Expand all'), findsOneWidget);
    expect(find.text('Theme Studio'), findsNothing);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Default landing page'), findsOneWidget);

    tester
        .widget<TvFocusable>(
          find.descendant(of: toggleAll, matching: find.byType(TvFocusable)),
        )
        .onPressed();
    await tester.pumpAndSettle();
    expect(find.text('Collapse all'), findsOneWidget);
    expect(find.text('Theme Studio'), findsOneWidget);
    expect(find.text('Screen layout'), findsNothing);

    tester
        .widget<TvFocusable>(
          find.descendant(of: toggleAll, matching: find.byType(TvFocusable)),
        )
        .onPressed();
    await tester.pumpAndSettle();
    expect(find.text('Expand all'), findsOneWidget);
    for (final label in const [
      'Continue watching',
      'Theme Studio',
      'Default landing page',
      'On-screen keyboard',
      'Text color',
      'Preferred audio',
    ]) {
      expect(find.text(label), findsNothing);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.area.system',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Customize groups expand and collapse independently', (
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
      ValueKey('customize-section-home-shelves'),
      ValueKey('customize-section-display'),
      ValueKey('customize-section-home-navigation'),
      ValueKey('customize-section-input-feedback'),
      ValueKey('customize-section-closed-captions'),
      ValueKey('customize-section-player-controls'),
    ]) {
      expect(find.byKey(key), findsOneWidget);
    }

    expect(find.text('Continue watching'), findsNothing);
    expect(find.text('Screen layout'), findsNothing);
    expect(find.text('Theme Studio'), findsNothing);
    expect(find.text('Title language'), findsNothing);
    expect(find.text('Show title style'), findsNothing);
    expect(find.text('Text color'), findsNothing);

    final shelvesToggle = find.byKey(
      const ValueKey('inline-section-toggle-home-shelves'),
    );
    await tester.tap(shelvesToggle);
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget);
    expect(find.text('Screen layout'), findsNothing);
    expect(find.text('Theme Studio'), findsNothing);

    await tester.tap(shelvesToggle);
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsNothing);

    final displayToggle = find.byKey(
      const ValueKey('inline-section-toggle-display'),
    );
    await tester.ensureVisible(displayToggle);
    await tester.tap(displayToggle);
    await tester.pumpAndSettle();
    expect(find.text('Screen layout'), findsNothing);
    expect(find.text('Theme Studio'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-theme-studio')), findsOneWidget);
    expect(find.textContaining('Classic Layout'), findsNothing);
    expect(find.text('Title language'), findsOneWidget);
    expect(find.text('Show title style'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('show-title-style-englishLogo')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('show-title-style-text')), findsOneWidget);
    expect(find.text('HOME & NAVIGATION'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Title language')).dy,
      greaterThan(tester.getTopLeft(find.text('Layout style')).dy),
    );

    await tester.tap(displayToggle);
    await tester.pumpAndSettle();
    expect(find.text('Screen layout'), findsNothing);
    expect(find.text('Theme Studio'), findsNothing);
    expect(find.text('Title language'), findsNothing);
    expect(find.text('Show title style'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Closed Captions expands into its first control and collapses safely',
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

      final captionsToggle = find.byKey(
        const ValueKey('inline-section-toggle-closed-captions'),
      );
      expect(captionsToggle, findsOneWidget);
      expect(find.text('Text color'), findsNothing);

      await tester.ensureVisible(captionsToggle);
      final header = tester.widget<TvFocusable>(captionsToggle);
      header.focusNode!.requestFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.section.closed-captions',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Text color'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.captions.text-color',
      );
      final whiteControl = tester.widget<TvFocusable>(
        find
            .ancestor(
              of: find.text('White'),
              matching: find.byType(TvFocusable),
            )
            .first,
      );
      final hiddenChildFocus = whiteControl.focusNode!;
      expect(hiddenChildFocus.context, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.section.closed-captions',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Text color'), findsNothing);
      expect(hiddenChildFocus.context?.mounted ?? false, isFalse);
      expect(hiddenChildFocus.hasFocus, isFalse);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.section.closed-captions',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.section.player-controls',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'D-pad scrolling continues after a Customize section is collapsed',
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

      final displayToggle = find.byKey(
        const ValueKey('inline-section-toggle-display'),
      );
      await tester.ensureVisible(displayToggle);
      final displayHeader = tester.widget<TvFocusable>(displayToggle);
      displayHeader.focusNode!.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Theme Studio'), findsOneWidget);
      expect(find.text('Screen layout'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Theme Studio'), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.section.display',
      );

      final settingsList = find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.vertical,
      );
      expect(settingsList, findsOneWidget);
      final list = tester.state<ScrollableState>(
        find.descendant(of: settingsList, matching: find.byType(Scrollable)),
      );
      final before = list.position.pixels;

      for (final expected in const [
        'accounts.section.home-navigation',
        'accounts.section.input-feedback',
        'accounts.section.closed-captions',
        'accounts.section.player-controls',
        'accounts.customization.reset',
      ]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, expected);
      }

      expect(list.position.pixels, greaterThan(before));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Reset appearance consumes Down and exits to Settings rail only on Left',
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

      final resetButton = find
          .ancestor(
            of: find.text('Reset appearance & navigation'),
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
      await tester.pump();
      expect(resetFocus.hasFocus, isTrue);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.reset',
      );

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
    },
  );

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

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.toggle-all',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.section.home-shelves',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.section.display',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.section.home-shelves',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    for (final shelf in HomeShelf.values) {
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.shelf.${shelf.name}',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.section.display',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.customization.first',
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

    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
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

    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
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
    final settingsScrollable = find.ancestor(
      of: find.byKey(const ValueKey('settings-dub-episode-notifications')),
      matching: find.byType(Scrollable),
    );
    final position = tester
        .state<ScrollableState>(settingsScrollable.first)
        .position;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, .5));
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.tracking.dub-notifications',
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

    expect(find.textContaining('Titles:'), findsNothing);
    expect(find.text('Title language'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('inline-section-toggle-display')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Title language'), findsOneWidget);
    final languageDetector = find.descendant(
      of: find.ancestor(
        of: find.text('Title language'),
        matching: find.byType(TvFocusable),
      ),
      matching: find.byType(FocusableActionDetector),
    );
    final languageFocus = tester
        .widget<FocusableActionDetector>(languageDetector)
        .focusNode!;
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
        of: find.byKey(const ValueKey('show-title-style-englishLogo')),
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

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
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

    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
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
      'accounts.system.discord-presence',
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

    for (var index = 0; index < 3; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
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
      find.textContaining(
        'Developer mode cannot bypass Android downgrade protection',
      ),
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
    for (var index = 0; index < 3; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

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
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

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
      findsOneWidget,
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
    expect(donationRect.left, greaterThan(discordRect.right));
    expect((donationRect.top - discordRect.top).abs(), lessThan(2));
    final qrCodes = find.byType(QrImageView, skipOffstage: false);
    final discordQrRect = tester.getRect(qrCodes.at(0));
    final donationQrRect = tester.getRect(qrCodes.at(1));
    expect(discordRect.left, greaterThan(discordQrRect.right));
    expect(donationRect.left, greaterThan(donationQrRect.right));
    expect(donationQrRect.left, greaterThan(discordQrRect.right));
    expect(
      (donationQrRect.top - discordQrRect.top).abs(),
      lessThanOrEqualTo(2),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.system.discord-presence',
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('Discord Rich Presence actions align with update actions', (
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
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();

    final updateActions = find.byKey(
      const ValueKey('app-update-actions'),
      skipOffstage: false,
    );
    final discordActions = find.byKey(
      const ValueKey('discord-presence-actions'),
      skipOffstage: false,
    );
    expect(updateActions, findsOneWidget);
    expect(discordActions, findsOneWidget);

    await tester.ensureVisible(discordActions);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(discordActions).right,
      closeTo(tester.getRect(updateActions).right, 0.1),
    );
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

    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
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

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.offline-downloads',
    );
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
      'accounts.streaming.local-media',
    );
    expect(find.text('Manage sources'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.watch-together',
    );
    expect(
      find.byKey(const ValueKey('settings-watch-party-toggle')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'accounts.streaming.watch-together',
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
    expect(find.text('Customize'), findsOneWidget);
    expect(find.text('Streaming'), findsOneWidget);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('APPEARANCE & NAVIGATION'), findsOneWidget);
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

    final inputFeedbackToggle = find.byKey(
      const ValueKey('inline-section-toggle-input-feedback'),
    );
    await tester.ensureVisible(inputFeedbackToggle);
    await tester.tap(inputFeedbackToggle);
    await tester.pumpAndSettle();
    final crashToggle = find.textContaining('Anonymous error reports');
    expect(crashToggle, findsOneWidget);
    await tester.ensureVisible(crashToggle);
    await tester.pumpAndSettle();
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

      final homeNavigationToggle = find.byKey(
        const ValueKey('inline-section-toggle-home-navigation'),
      );
      await tester.ensureVisible(homeNavigationToggle);
      await tester.tap(homeNavigationToggle);
      await tester.pumpAndSettle();
      final homeToggle = find.byKey(
        const ValueKey('settings-top-navigation-toggle-home'),
      );
      await tester.ensureVisible(homeToggle);
      tester.widget<TvFocusable>(homeToggle).focusNode!.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'accounts.customization.home-content.featured',
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

    final playerControlsToggle = find.byKey(
      const ValueKey('inline-section-toggle-player-controls'),
    );
    await tester.ensureVisible(playerControlsToggle);
    await tester.tap(playerControlsToggle);
    await tester.pumpAndSettle();
    final enabledLabel = find.text('Show filler episode labels ON');
    expect(enabledLabel, findsOneWidget);
    await tester.ensureVisible(enabledLabel);
    await tester.pumpAndSettle();
    expect(
      find.ancestor(of: enabledLabel, matching: find.byType(TvFocusable)),
      findsOneWidget,
    );

    await tester.tap(enabledLabel);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AccountsScreen)),
    );
    expect(
      container.read(settingsPreferencesProvider).showFillerIndicators,
      isFalse,
    );
    expect(find.text('Show filler episode labels OFF'), findsOneWidget);
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

      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.enter,
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
        LogicalKeyboardKey.arrowRight,
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
        LogicalKeyboardKey.arrowLeft,
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
