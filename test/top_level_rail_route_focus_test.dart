import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'rail selection opens the destination with its first content focused',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final contentFocus = FocusNode(debugLabel: 'route-target.first-content');
      Object? receivedRouteExtra;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: HomeSideNavigation(
                preferences: const SettingsPreferences(loaded: true),
                metrics: homeNavigationRailMetrics(NavigationChromeSize.medium),
                autofocusActive: true,
                onExitRight: () {},
              ),
            ),
          ),
          GoRoute(
            path: '/my-list',
            builder: (context, state) {
              receivedRouteExtra = state.extra;
              return TetoTopLevelShell(
                preferences: const SettingsPreferences(loaded: true),
                activeDestination: TopNavigationDestination.myList,
                firstContentFocusNode: contentFocus,
                builder: (_, _) => Align(
                  alignment: Alignment.topLeft,
                  child: TvFocusable(
                    focusNode: contentFocus,
                    autofocus: true,
                    onPressed: () {},
                    child: const Text('First My List option'),
                  ),
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      addTearDown(contentFocus.dispose);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('main-nav-my-list')));
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(contentFocus));
      expect(receivedRouteExtra, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
