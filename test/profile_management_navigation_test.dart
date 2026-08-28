import 'package:anime_tv/app/router.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('profile menu opens the tracker profile settings entry point', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: MainNavigationBar(
              active: MainNavigationDestination.home,
              preferences: SettingsPreferences(),
            ),
          ),
        ),
        GoRoute(
          path: '/settings/accounts',
          builder: (context, state) => Scaffold(
            body: Text(
              state.uri.queryParameters['section'] ?? 'default',
              key: const ValueKey('accounts-section'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          trackingAccountsControllerProvider.overrideWith(
            (_) => _StaticTrackingAccountsController(
              const TrackingAccountsState(
                usernames: {TrackingProvider.anilist: 'TetoFan'},
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('main-nav-profile-summary')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('main-nav-manage-profiles')),
      findsOneWidget,
    );
    await tester.tap(find.text('Add or manage profiles'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accounts-section')), findsOneWidget);
    expect(find.text('tracking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('relocated Settings entry opens the main Settings route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: MainNavigationBar(
              active: MainNavigationDestination.home,
              preferences: SettingsPreferences(
                settingsEntryPlacement: SettingsEntryPlacement.profileMenu,
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/settings/accounts',
          builder: (context, state) => Scaffold(
            body: Text(
              state.uri.queryParameters['section'] ?? 'default',
              key: const ValueKey('accounts-section'),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('main-nav-settings')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('main-nav-profile-summary')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('main-nav-manage-profiles')),
      findsOneWidget,
    );
    final settings = find.byKey(const ValueKey('main-nav-profile-settings'));
    expect(settings, findsOneWidget);
    await tester.tap(settings);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accounts-section')), findsOneWidget);
    expect(find.text('default'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tracker settings route lands on profile controls', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    addTearDown(() => appRouter.go('/'));

    appRouter.go('/settings/accounts?section=tracking');
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: appRouter)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AccountsScreen), findsOneWidget);
    expect(find.text('ANIME TRACKING'), findsOneWidget);
    expect(find.text('APPEARANCE & NAVIGATION'), findsNothing);
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

class _TrackingAccountsRef extends Fake implements Ref {}
