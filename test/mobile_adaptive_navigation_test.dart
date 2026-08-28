import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('portrait phone uses a persistent touch-sized bottom bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firstContentFocus = FocusNode(debugLabel: 'phone.content');
    addTearDown(firstContentFocus.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [isTelevisionProvider.overrideWithValue(false)],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TetoTopLevelShell(
            preferences: const SettingsPreferences(loaded: true),
            activeDestination: TopNavigationDestination.discover,
            firstContentFocusNode: firstContentFocus,
            builder: (context, layout) => ColoredBox(
              key: const ValueKey('phone-content'),
              color: Colors.transparent,
              child: Text(
                layout.navigationPlacement.name,
                textDirection: TextDirection.ltr,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-bottom-navigation')), findsOne);
    expect(find.byKey(const ValueKey('phone-nav-active-discover')), findsOne);
    expect(
      find.byKey(const ValueKey('home-navigation-actions-scroll')),
      findsNothing,
    );
    expect(find.text('phonePortraitBottom'), findsOne);

    final navigation = tester.getRect(
      find.byKey(const ValueKey('phone-bottom-navigation')),
    );
    final content = tester.getRect(find.byKey(const ValueKey('phone-content')));
    expect(navigation.height, phoneBottomNavigationHeight);
    expect(content.bottom, lessThanOrEqualTo(navigation.top));
    expect(
      tester.getSize(find.byKey(const ValueKey('main-nav-home'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('landscape phone rotates navigation to the left rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firstContentFocus = FocusNode(debugLabel: 'phone.content');
    addTearDown(firstContentFocus.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [isTelevisionProvider.overrideWithValue(false)],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TetoTopLevelShell(
            preferences: const SettingsPreferences(loaded: true),
            activeDestination: TopNavigationDestination.discover,
            firstContentFocusNode: firstContentFocus,
            builder: (context, layout) => Align(
              alignment: Alignment.topLeft,
              child: Text(
                layout.navigationPlacement.name,
                key: const ValueKey('phone-content'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-bottom-navigation')), findsNothing);
    expect(
      find.byKey(const ValueKey('home-navigation-actions-scroll')),
      findsOne,
    );
    expect(find.byKey(const ValueKey('main-nav-active-discover')), findsOne);
    expect(find.text('phoneLandscapeRail'), findsOne);
    final expectedMetrics = phoneLandscapeNavigationRailMetrics(
      NavigationChromeSize.medium,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('main-navigation'))).width,
      expectedMetrics.width,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('phone-content'))).dx,
      greaterThan(expectedMetrics.width),
    );
  });

  testWidgets(
    'landscape rail and logo live-update from the chrome size provider',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final firstContentFocus = FocusNode(debugLabel: 'phone.live.content');
      addTearDown(firstContentFocus.dispose);
      final settings = _PhoneRailSettingsController(
        const SettingsPreferences(
          navigationChromeSize: NavigationChromeSize.small,
          loaded: true,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isTelevisionProvider.overrideWithValue(false),
            settingsPreferencesProvider.overrideWith((_) => settings),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Consumer(
              builder: (context, ref, _) {
                final preferences = ref.watch(settingsPreferencesProvider);
                return TetoTopLevelShell(
                  preferences: preferences,
                  activeDestination: TopNavigationDestination.discover,
                  firstContentFocusNode: firstContentFocus,
                  builder: (_, _) => const SizedBox.expand(
                    key: ValueKey('phone-live-content'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      void expectMetrics(HomeNavigationRailMetrics expected) {
        final rail = find.byKey(const ValueKey('main-navigation'));
        final wordmark = find.byKey(const ValueKey('main-nav-wordmark'));
        final activeAction = find.byKey(const ValueKey('main-nav-discover'));
        final contentRegion = tester.widget<Positioned>(
          find.byKey(const ValueKey('top-level-tv-content-region')),
        );
        final icon = tester.widget<Icon>(
          find.descendant(of: activeAction, matching: find.byType(Icon)),
        );

        expect(tester.getSize(rail).width, expected.width);
        expect(tester.getSize(wordmark), Size.square(expected.logoSize));
        expect(tester.getSize(activeAction).height, expected.actionHeight);
        expect(icon.size, expected.iconSize);
        expect(contentRegion.left, expected.width);
        expect(expected.actionWidth, greaterThanOrEqualTo(44));
        expect(expected.actionHeight, greaterThanOrEqualTo(44));
      }

      final small = phoneLandscapeNavigationRailMetrics(
        NavigationChromeSize.small,
      );
      expectMetrics(small);

      await settings.setNavigationChromeSize(NavigationChromeSize.large);
      await tester.pump();

      final large = phoneLandscapeNavigationRailMetrics(
        NavigationChromeSize.large,
      );
      expectMetrics(large);
      expect(large.width, greaterThan(small.width));
      expect(large.logoSize, greaterThan(small.logoSize));
      expect(large.actionHeight, greaterThan(small.actionHeight));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mounted phone swaps navigation when the device rotates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firstContentFocus = FocusNode(debugLabel: 'phone.content');
    addTearDown(firstContentFocus.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [isTelevisionProvider.overrideWithValue(false)],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TetoTopLevelShell(
            preferences: const SettingsPreferences(loaded: true),
            activeDestination: TopNavigationDestination.home,
            firstContentFocusNode: firstContentFocus,
            builder: (context, layout) => Text(
              layout.navigationPlacement.name,
              key: const ValueKey('phone-rotating-content'),
              textDirection: TextDirection.ltr,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-bottom-navigation')), findsOne);
    expect(find.text('phonePortraitBottom'), findsOne);

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-bottom-navigation')), findsNothing);
    expect(
      find.byKey(const ValueKey('home-navigation-actions-scroll')),
      findsOne,
    );
    expect(find.text('phoneLandscapeRail'), findsOne);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-bottom-navigation')), findsOne);
    expect(
      find.byKey(const ValueKey('home-navigation-actions-scroll')),
      findsNothing,
    );
    expect(find.text('phonePortraitBottom'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('physical TV keeps its compact classic navigation contract', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firstContentFocus = FocusNode(debugLabel: 'tv.content');
    addTearDown(firstContentFocus.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [isTelevisionProvider.overrideWithValue(true)],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: TetoTopLevelShell(
            preferences: const SettingsPreferences(loaded: true),
            activeDestination: TopNavigationDestination.discover,
            firstContentFocusNode: firstContentFocus,
            builder: (context, layout) => Text(
              layout.navigationPlacement.name,
              textDirection: TextDirection.ltr,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('phone-bottom-navigation')), findsNothing);
    expect(
      find.byKey(const ValueKey('home-navigation-actions-scroll')),
      findsNothing,
    );
    expect(find.text('classicTop'), findsOne);
  });

  testWidgets('phone bottom D-pad focus is separate from selected route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final activeFocus = FocusNode(debugLabel: 'phone.navigation.active');
    addTearDown(activeFocus.dispose);
    var exitedUp = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PhoneBottomNavigation(
                preferences: const SettingsPreferences(
                  loaded: true,
                  showSearch: false,
                  showMyList: false,
                  showCalendar: false,
                  showWatchTogether: false,
                  showDownloads: false,
                ),
                activeDestination: TopNavigationDestination.home,
                activeFocusNode: activeFocus,
                onExitUp: () => exitedUp = true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    activeFocus.requestFocus();
    await tester.pump();
    expect(find.byKey(const ValueKey('phone-nav-active-home')), findsOne);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'phone.navigation.discover',
    );
    // Moving focus must not move the persistent route indicator.
    expect(find.byKey(const ValueKey('phone-nav-active-home')), findsOne);
    expect(
      find.byKey(const ValueKey('phone-nav-active-discover')),
      findsNothing,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(exitedUp, isTrue);
  });

  testWidgets('portrait Home header keeps its search action touchable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final searchFocus = FocusNode(debugLabel: 'phone.header.search');
    addTearDown(searchFocus.dispose);
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);
    String? submittedQuery;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trackingAccountsControllerProvider.overrideWith(
            (_) => _StaticTrackingAccountsController(
              const TrackingAccountsState(
                profiles: {
                  TrackingProvider.anilist: TrackingAccountProfile(
                    provider: TrackingProvider.anilist,
                    username: 'LindowsOS',
                  ),
                },
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topCenter,
                child: HomeTopRightHeader(
                  preferences: const SettingsPreferences(loaded: true),
                  searchFocusNode: searchFocus,
                  searchController: searchController,
                  onSearchSubmitted: (value) => submittedQuery = value,
                  compactMobile: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home-top-right-header')), findsOne);
    expect(find.byKey(const ValueKey('home-header-search')), findsOne);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-header-search')),
        matching: find.text('Search'),
      ),
      findsOneWidget,
    );
    final switcher = find.byKey(const ValueKey('home-profile-switcher'));
    final avatar = find.byKey(
      const ValueKey('main-nav-profile-avatar-anilist'),
    );
    final chevron = find.descendant(
      of: switcher,
      matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
    );
    expect(switcher, findsOneWidget);
    expect(avatar, findsOneWidget);
    expect(find.text('LindowsOS'), findsNothing);
    expect(chevron, findsNothing);
    expect(find.byKey(const ValueKey('teto-profile-username')), findsNothing);
    expect(find.byKey(const ValueKey('teto-profile-chevron')), findsNothing);
    expect(tester.getSize(switcher).width, 52);
    final headerRect = tester.getRect(
      find.byKey(const ValueKey('home-top-right-header')),
    );
    final searchRect = tester.getRect(
      find.byKey(const ValueKey('home-header-search')),
    );
    final switcherRect = tester.getRect(switcher);
    final searchIconFrameRect = tester.getRect(
      find.byKey(const ValueKey('home-header-search-icon-frame')),
    );
    final searchIconRect = tester.getRect(
      find.byKey(const ValueKey('home-header-search-icon')),
    );
    expect(headerRect.height, 56);
    expect(searchRect.height, 56);
    expect(searchIconFrameRect.size, const Size.square(28));
    expect(searchIconRect.size, const Size.square(22));
    expect(
      (searchIconRect.center.dy - searchRect.center.dy).abs(),
      lessThan(.5),
    );
    expect(searchIconRect.top - searchRect.top, greaterThanOrEqualTo(16));
    expect(searchRect.bottom - searchIconRect.bottom, greaterThanOrEqualTo(16));
    expect((searchRect.center.dy - switcherRect.center.dy).abs(), lessThan(.5));
    final searchSurface = tester.widget<Container>(
      find.byKey(const ValueKey('tv-text-input-header-search')),
    );
    final searchDecoration = searchSurface.decoration! as BoxDecoration;
    expect(searchDecoration.borderRadius, BorderRadius.circular(10));
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('home-top-right-header'))).width,
      lessThanOrEqualTo(288),
    );

    await tester.tap(find.byKey(const ValueKey('home-header-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-keyboard-panel')), findsOneWidget);
    for (final letter in const ['f', 'r', 'i']) {
      await tester.tap(find.text(letter));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(submittedQuery, 'fri');
    expect(searchController.text, 'fri');

    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(
        find.byKey(const ValueKey('home-header-search-icon-frame')),
      ),
      const Size.square(28),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-header-search-icon'))),
      const Size.square(22),
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

class _PhoneRailSettingsController extends SettingsPreferencesController {
  _PhoneRailSettingsController(SettingsPreferences initial)
    : super(const FlutterSecureStorage()) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}

class _TrackingAccountsRef extends Fake implements Ref {}
