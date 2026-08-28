import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/airing_calendar_screen.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('TV destinations share the cinematic rail, palette, and focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firstContentFocus = FocusNode(debugLabel: 'test.destination.first');
    addTearDown(firstContentFocus.dispose);
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF071019),
      surface: const Color(0xFF12202C),
      accent: const Color(0xFFFF2F67),
      primaryText: const Color(0xFFF8FAFF),
      mutedText: const Color(0xFFB6C1CC),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.darkFor(palette),
          home: TetoTopLevelShell(
            preferences: const SettingsPreferences(),
            activeDestination: TopNavigationDestination.discover,
            firstContentFocusNode: firstContentFocus,
            autofocusRail: true,
            builder: (context, layout) => Align(
              alignment: Alignment.topLeft,
              child: TvFocusable(
                focusNode: firstContentFocus,
                onPressed: () {},
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Destination content'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('teto-top-level-discover')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('main-navigation')), findsOneWidget);
    expect(find.byKey(const ValueKey('main-nav-discover')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('main-navigation'))).width,
      60,
    );
    expect(
      tester.getTopLeft(find.text('Destination content')).dx,
      greaterThan(60),
    );

    final backdrop = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('teto-top-level-backdrop')),
    );
    final decoration = backdrop.decoration as BoxDecoration;
    expect(decoration.color, palette.background);
    expect(
      (decoration.gradient as LinearGradient).colors,
      contains(palette.background),
    );
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'top-level.active-navigation',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(firstContentFocus));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TV rail anchors Settings at the bottom and keeps linear D-pad order',
    (tester) async {
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
                  // A saved custom position must not pull the fixed utility
                  // action back into the regular destination group.
                  topNavigationOrder: [
                    TopNavigationDestination.home,
                    TopNavigationDestination.settings,
                    TopNavigationDestination.search,
                    TopNavigationDestination.myList,
                    TopNavigationDestination.discover,
                    TopNavigationDestination.calendar,
                    TopNavigationDestination.watchTogether,
                    TopNavigationDestination.downloads,
                  ],
                ),
                metrics: homeNavigationRailMetrics(NavigationChromeSize.medium),
                onExitRight: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final railRect = tester.getRect(
        find.byKey(const ValueKey('main-navigation')),
      );
      final downloadsRect = tester.getRect(
        find.byKey(const ValueKey('main-nav-downloads')),
      );
      final settingsRect = tester.getRect(
        find.byKey(const ValueKey('main-nav-settings')),
      );
      expect(
        railRect.bottom - settingsRect.bottom,
        inInclusiveRange(10.0, 20.0),
      );
      expect(settingsRect.top - downloadsRect.bottom, greaterThan(80));
      expect(
        find.byKey(const ValueKey('home-navigation-bottom-settings')),
        findsOneWidget,
      );

      final downloadsDetector = tester.widget<FocusableActionDetector>(
        find
            .descendant(
              of: find.byKey(const ValueKey('main-nav-downloads')),
              matching: find.byType(FocusableActionDetector),
            )
            .first,
      );
      downloadsDetector.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'home.navigation.settings',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'home.navigation.downloads',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV rail active fade follows the page rather than transient D-pad focus',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Widget buildRail(TopNavigationDestination active) => ProviderScope(
        key: ValueKey('active-${active.name}'),
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: HomeSideNavigation(
              preferences: const SettingsPreferences(loaded: true),
              activeDestination: active,
              metrics: homeNavigationRailMetrics(NavigationChromeSize.medium),
              onExitRight: () {},
            ),
          ),
        ),
      );

      await tester.pumpWidget(buildRail(TopNavigationDestination.discover));
      await tester.pumpAndSettle();

      final discoverIndicator = find.byKey(
        const ValueKey('main-nav-active-discover'),
      );
      expect(discoverIndicator, findsOneWidget);
      expect(
        find.byKey(const ValueKey('main-nav-active-search')),
        findsNothing,
      );
      final activeDecoration =
          tester.widget<DecoratedBox>(discoverIndicator).decoration
              as BoxDecoration;
      expect(activeDecoration.gradient, isA<LinearGradient>());
      expect((activeDecoration.border! as Border).left.width, 3);

      final searchDetector = tester.widget<FocusableActionDetector>(
        find
            .descendant(
              of: find.byKey(const ValueKey('main-nav-search')),
              matching: find.byType(FocusableActionDetector),
            )
            .first,
      );
      searchDetector.focusNode!.requestFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'home.navigation.search',
      );
      expect(discoverIndicator, findsOneWidget);
      expect(
        find.byKey(const ValueKey('main-nav-active-search')),
        findsNothing,
      );

      await tester.pumpWidget(buildRail(TopNavigationDestination.search));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('main-nav-active-search')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('main-nav-active-discover')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submenu rail surface, divider, and content offset share chrome metrics',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final contentFocusNodes = <FocusNode>[];

      for (final viewport in const [960.0, 1280.0, 1680.0]) {
        tester.view.physicalSize = Size(viewport, 720);
        final measuredWidths = <double>[];

        for (final size in NavigationChromeSize.values) {
          final firstContentFocus = FocusNode(
            debugLabel: 'test.$viewport.${size.name}.content',
          );
          contentFocusNodes.add(firstContentFocus);
          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey('$viewport-${size.name}'),
              child: MaterialApp(
                theme: AppTheme.dark,
                home: TetoTopLevelShell(
                  preferences: SettingsPreferences(
                    navigationChromeSize: size,
                    loaded: true,
                  ),
                  activeDestination: TopNavigationDestination.discover,
                  firstContentFocusNode: firstContentFocus,
                  builder: (_, _) => const SizedBox.expand(
                    key: ValueKey('test-submenu-content'),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final expected = homeNavigationRailMetrics(size);
          final railFinder = find.byKey(const ValueKey('main-navigation'));
          final rail = tester.widget<Container>(railFinder);
          final decoration = rail.decoration! as BoxDecoration;
          final border = decoration.border! as Border;
          final contentRegion = tester.widget<Positioned>(
            find.byKey(const ValueKey('top-level-tv-content-region')),
          );

          measuredWidths.add(tester.getSize(railFinder).width);
          expect(tester.getSize(railFinder).width, expected.width);
          expect(contentRegion.left, expected.width);
          expect(
            tester
                .getTopLeft(find.byKey(const ValueKey('test-submenu-content')))
                .dx,
            expected.width + (viewport >= 1400 ? 34 : 28),
          );
          expect(border.right.style, BorderStyle.solid);
          expect(border.right.width, greaterThan(0));
          expect(
            tester
                .getCenter(find.byKey(const ValueKey('main-nav-wordmark')))
                .dx,
            (expected.width - border.right.width) / 2,
          );
          expect(
            tester
                .getCenter(find.byKey(const ValueKey('main-nav-discover')))
                .dx,
            (expected.width - border.right.width) / 2,
          );
        }

        expect(measuredWidths[0], lessThan(measuredWidths[1]));
        expect(measuredWidths[1], lessThan(measuredWidths[2]));
      }

      await tester.pumpWidget(const SizedBox());
      for (final node in contentFocusNodes) {
        node.dispose();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact destinations keep responsive insets without a TV rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firstContentFocus = FocusNode();
    addTearDown(firstContentFocus.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TetoTopLevelShell(
            preferences: const SettingsPreferences(),
            activeDestination: TopNavigationDestination.settings,
            firstContentFocusNode: firstContentFocus,
            builder: (_, layout) => Text(layout.usesTvRail ? 'TV' : 'Compact'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Compact'), findsOneWidget);
    expect(find.byType(HomeSideNavigation), findsNothing);
    expect(
      tester.widget<SafeArea>(find.byType(SafeArea).first).minimum,
      const EdgeInsets.symmetric(horizontal: 16),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Classic Layout keeps the legacy top-level content branch on TV',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final firstContentFocus = FocusNode(debugLabel: 'classic.content');
      addTearDown(firstContentFocus.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark,
            home: TetoTopLevelShell(
              preferences: const SettingsPreferences(
                interfaceMode: InterfaceMode.phone,
                loaded: true,
              ),
              activeDestination: TopNavigationDestination.discover,
              firstContentFocusNode: firstContentFocus,
              builder: (_, layout) => Text(
                layout.usesTvRail ? 'Modern content' : 'Classic content',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Classic content'), findsOneWidget);
      expect(find.byType(HomeSideNavigation), findsNothing);
      expect(
        find.byKey(const ValueKey('top-level-fixed-profile')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submenu profile is top-only and restores content focus before hiding',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final contentFocus = FocusNode(debugLabel: 'scrolling.content');
      final scrollController = ScrollController();
      addTearDown(contentFocus.dispose);
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            trackingAccountsControllerProvider.overrideWith(
              (_) => _StaticTrackingAccountsController(
                const TrackingAccountsState(
                  profiles: {
                    TrackingProvider.anilist: TrackingAccountProfile(
                      provider: TrackingProvider.anilist,
                      username: 'Top-only profile',
                    ),
                  },
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: TetoTopLevelShell(
              preferences: const SettingsPreferences(loaded: true),
              activeDestination: TopNavigationDestination.discover,
              firstContentFocusNode: contentFocus,
              builder: (_, _) => ListView.builder(
                key: const ValueKey('scrolling-submenu'),
                controller: scrollController,
                itemCount: 40,
                itemBuilder: (_, index) => index == 0
                    ? TvFocusable(
                        focusNode: contentFocus,
                        onPressed: () {},
                        child: const SizedBox(
                          height: 80,
                          child: Text('First content option'),
                        ),
                      )
                    : SizedBox(height: 80, child: Text('Option $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final profile = find.byKey(const ValueKey('top-level-fixed-profile'));
      expect(profile, findsOneWidget);
      final switcher = find.descendant(
        of: profile,
        matching: find.byType(TetoProfileSwitcher),
      );
      expect(switcher, findsOneWidget);
      expect(tester.getSize(switcher), const Size(52, 52));
      expect(
        find.descendant(of: switcher, matching: find.text('Top-only profile')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: switcher,
          matching: find.byIcon(Icons.arrow_drop_down_rounded),
        ),
        findsNothing,
      );
      final avatar = tester.widget<Container>(
        find.descendant(
          of: switcher,
          matching: find.byKey(
            const ValueKey('main-nav-profile-avatar-anilist'),
          ),
        ),
      );
      final avatarDecoration = avatar.decoration! as BoxDecoration;
      expect(avatarDecoration.shape, BoxShape.circle);
      expect(avatarDecoration.borderRadius, isNull);
      expect(avatarDecoration.border, isNotNull);
      final profileDetector = tester.widget<FocusableActionDetector>(
        find
            .descendant(
              of: profile,
              matching: find.byType(FocusableActionDetector),
            )
            .first,
      );
      profileDetector.focusNode!.requestFocus();
      await tester.pump();

      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(profile, findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'top-level.active-navigation',
      );

      scrollController.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(profile, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Classic scrolling synchronizes profile visibility before returning Modern',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harnessKey = GlobalKey<_LayoutTransitionShellHarnessState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            trackingAccountsControllerProvider.overrideWith(
              (_) => _StaticTrackingAccountsController(
                const TrackingAccountsState(
                  profiles: {
                    TrackingProvider.anilist: TrackingAccountProfile(
                      provider: TrackingProvider.anilist,
                      username: 'Layout transition profile',
                    ),
                  },
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: _LayoutTransitionShellHarness(key: harnessKey),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final profile = find.byKey(const ValueKey('top-level-fixed-profile'));
      expect(profile, findsOneWidget);

      harnessKey.currentState!.jumpToBottom();
      await tester.pump();
      await tester.pump();
      expect(profile, findsNothing);

      harnessKey.currentState!.setMode(InterfaceMode.phone);
      await tester.pumpAndSettle();
      harnessKey.currentState!.jumpToTop();
      await tester.pump();
      await tester.pump();
      harnessKey.currentState!.setMode(InterfaceMode.television);
      await tester.pump();
      await tester.pump();
      expect(profile, findsOneWidget);

      harnessKey.currentState!.setMode(InterfaceMode.phone);
      await tester.pump();
      harnessKey.currentState!.jumpToBottom();
      await tester.pump();
      await tester.pump();
      harnessKey.currentState!.setMode(InterfaceMode.television);
      await tester.pump();
      await tester.pump();
      expect(profile, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('relocated Settings stays hidden while LEFT reaches the rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final contentFocus = FocusNode(debugLabel: 'settings.test.content');
    addTearDown(contentFocus.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trackingAccountsControllerProvider.overrideWith(
            (_) => _StaticTrackingAccountsController(
              const TrackingAccountsState(
                profiles: {
                  TrackingProvider.anilist: TrackingAccountProfile(
                    provider: TrackingProvider.anilist,
                    username: 'TetoFan',
                  ),
                },
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TetoTopLevelShell(
            preferences: const SettingsPreferences(
              settingsEntryPlacement: SettingsEntryPlacement.profileMenu,
            ),
            activeDestination: TopNavigationDestination.settings,
            firstContentFocusNode: contentFocus,
            builder: (_, layout) => Align(
              alignment: Alignment.topLeft,
              child: TvFocusable(
                focusNode: contentFocus,
                autofocus: true,
                onKeyEvent: (_, event) {
                  if (event.logicalKey != LogicalKeyboardKey.arrowLeft) {
                    return KeyEventResult.ignored;
                  }
                  if (event is KeyDownEvent || event is KeyRepeatEvent) {
                    layout.focusRail();
                  }
                  return KeyEventResult.handled;
                },
                onPressed: () {},
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Settings content'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('main-nav-settings')), findsNothing);
    expect(find.byKey(const ValueKey('main-nav-calendar')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, same(contentFocus));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'top-level.active-navigation',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(contentFocus));
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar shelves move explicitly across cards and days', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const first = AnimeSummary(
      id: 10,
      title: 'First followed anime',
      description: '',
      episodes: 12,
      score: 8,
    );
    const second = AnimeSummary(
      id: 20,
      title: 'Second followed anime',
      description: '',
      episodes: 12,
      score: 8,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          airingWeekProvider.overrideWith(
            (_) async => [
              AiringScheduleEntry(
                anime: first,
                episode: 2,
                airingAt: DateTime(2026, 8, 21, 20),
              ),
              AiringScheduleEntry(
                anime: second,
                episode: 3,
                airingAt: DateTime(2026, 8, 22, 20),
              ),
            ],
          ),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [
                HomeTrackedAnime(
                  tracked: TrackedAnime(
                    mediaId: 10,
                    title: 'First followed anime',
                    status: TrackingListStatus.watching,
                    progress: 1,
                  ),
                  provider: TrackingProvider.anilist,
                  anilistId: 10,
                  coverImageUrl: null,
                ),
                HomeTrackedAnime(
                  tracked: TrackedAnime(
                    mediaId: 20,
                    title: 'Second followed anime',
                    status: TrackingListStatus.watching,
                    progress: 1,
                  ),
                  provider: TrackingProvider.anilist,
                  anilistId: 20,
                  coverImageUrl: null,
                ),
              ],
              planToWatch: [],
              completed: [],
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const AiringCalendarScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'calendar.refresh');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('.item.0'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('.item.1'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      allOf(contains('2026-08-22'), contains('.item.1')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Calendar reveals a far remembered column across days', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final firstDay = DateTime(2026, 8, 21, 20);
    final secondDay = DateTime(2026, 8, 22, 20);
    final anime = [
      for (var index = 0; index < 16; index++)
        AnimeSummary(
          id: 500 + index,
          title: 'Calendar far show $index',
          description: '',
          episodes: 12,
          score: 8,
        ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          airingWeekProvider.overrideWith(
            (_) async => [
              for (var index = 0; index < 8; index++)
                AiringScheduleEntry(
                  anime: anime[index],
                  episode: 2,
                  airingAt: firstDay.add(Duration(minutes: index)),
                ),
              for (var index = 8; index < 16; index++)
                AiringScheduleEntry(
                  anime: anime[index],
                  episode: 2,
                  airingAt: secondDay.add(Duration(minutes: index)),
                ),
            ],
          ),
          trackingHomeProvider.overrideWith(
            (_) async => TrackingHomeData(
              watching: [
                for (final item in anime)
                  HomeTrackedAnime(
                    tracked: TrackedAnime(
                      mediaId: item.id,
                      title: item.title,
                      status: TrackingListStatus.watching,
                      progress: 1,
                    ),
                    provider: TrackingProvider.anilist,
                    anilistId: item.id,
                    coverImageUrl: null,
                  ),
              ],
              planToWatch: const [],
              completed: const [],
            ),
          ),
        ],
        child: const MaterialApp(home: AiringCalendarScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      allOf(contains('2026-08-21'), contains('.item.12')),
    );
    final firstFocusedBox =
        FocusManager.instance.primaryFocus!.context!.findRenderObject()!
            as RenderBox;
    expect(
      firstFocusedBox.localToGlobal(Offset.zero).dx +
          firstFocusedBox.size.width,
      lessThanOrEqualTo(1262),
      reason: 'the complete far calendar action must be inside the viewport',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      allOf(contains('2026-08-22'), contains('.item.12')),
    );
    final secondFocusedBox =
        FocusManager.instance.primaryFocus!.context!.findRenderObject()!
            as RenderBox;
    expect(
      secondFocusedBox.localToGlobal(Offset.zero).dx +
          secondFocusedBox.size.width,
      lessThanOrEqualTo(1262),
      reason: 'the remembered far action must stay fully visible on row change',
    );
    expect(tester.takeException(), isNull);
  });
}

class _StaticTrackingAccountsController extends TrackingAccountsController {
  _StaticTrackingAccountsController(TrackingAccountsState initial)
    : super(
        _TrackingAccountsRef(),
        TrackingTokenService(const FlutterSecureStorage()),
      ) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}

class _LayoutTransitionShellHarness extends StatefulWidget {
  const _LayoutTransitionShellHarness({super.key});

  @override
  State<_LayoutTransitionShellHarness> createState() =>
      _LayoutTransitionShellHarnessState();
}

class _LayoutTransitionShellHarnessState
    extends State<_LayoutTransitionShellHarness> {
  final _contentFocus = FocusNode(debugLabel: 'layout-transition.content');
  final _scrollController = ScrollController();
  InterfaceMode _mode = InterfaceMode.television;

  void setMode(InterfaceMode mode) => setState(() => _mode = mode);

  void jumpToTop() => _scrollController.jumpTo(0);

  void jumpToBottom() =>
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);

  @override
  void dispose() {
    _contentFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TetoTopLevelShell(
    preferences: SettingsPreferences(interfaceMode: _mode, loaded: true),
    activeDestination: TopNavigationDestination.discover,
    firstContentFocusNode: _contentFocus,
    builder: (_, _) => ListView.builder(
      controller: _scrollController,
      itemCount: 40,
      itemBuilder: (_, index) => index == 0
          ? TvFocusable(
              focusNode: _contentFocus,
              onPressed: () {},
              child: const SizedBox(height: 80, child: Text('First option')),
            )
          : SizedBox(height: 80, child: Text('Option $index')),
    ),
  );
}

class _TrackingAccountsRef extends Fake implements Ref {}
