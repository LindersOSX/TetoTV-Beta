import 'dart:io';

import 'package:anime_tv/features/home/application/top_navigation_availability.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('runtime order requires only the saved Manga preference', () {
    const loading = SettingsPreferences();

    expect(
      runtimeTopNavigationOrder(loading),
      isNot(contains(TopNavigationDestination.manga)),
    );

    const preferences = SettingsPreferences(loaded: true);
    expect(
      runtimeTopNavigationOrder(preferences),
      contains(TopNavigationDestination.manga),
    );

    final optedOutOrder = runtimeTopNavigationOrder(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
    );
    expect(optedOutOrder, isNot(contains(TopNavigationDestination.manga)));
    final enabledOrder = runtimeTopNavigationOrder(preferences);
    expect(enabledOrder, contains(TopNavigationDestination.manga));
    expect(
      defaultTopNavigationOrder.indexOf(TopNavigationDestination.manga),
      defaultTopNavigationOrder.indexOf(TopNavigationDestination.downloads) - 1,
    );
  });

  testWidgets(
    'all shared navigation surfaces expose core Manga without Developer Mode',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<void> pumpWith(
        AppUpdateState state,
        SettingsPreferences preferences,
      ) async {
        final controller = _FixedAppUpdateController(state);
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(
              'developer-navigation-${state.loaded}-${state.developerMode}',
            ),
            overrides: [
              appUpdateControllerProvider.overrideWith((_) => controller),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: HomeSideNavigation(
                        preferences: preferences,
                        metrics: homeNavigationRailMetrics(
                          NavigationChromeSize.medium,
                        ),
                        onExitRight: () {},
                      ),
                    ),
                    Positioned(
                      left: 100,
                      right: 0,
                      top: 0,
                      child: MainNavigationBar(
                        active: MainNavigationDestination.home,
                        preferences: preferences,
                      ),
                    ),
                    Positioned(
                      left: 100,
                      right: 0,
                      bottom: 0,
                      child: PhoneBottomNavigation(
                        preferences: preferences,
                        activeDestination: TopNavigationDestination.home,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pumpWith(
        const AppUpdateState(loaded: false, developerMode: true),
        const SettingsPreferences(),
      );
      expect(find.byKey(const ValueKey('main-nav-manga')), findsNothing);

      await pumpWith(
        const AppUpdateState(loaded: true, developerMode: false),
        const SettingsPreferences(loaded: true),
      );
      expect(find.byKey(const ValueKey('main-nav-manga')), findsNWidgets(3));

      await pumpWith(
        const AppUpdateState(loaded: false, developerMode: false),
        const SettingsPreferences(loaded: true),
      );
      expect(find.byKey(const ValueKey('main-nav-manga')), findsNWidgets(3));

      await pumpWith(
        const AppUpdateState(loaded: true, developerMode: true),
        const SettingsPreferences(loaded: true),
      );
      expect(find.byKey(const ValueKey('main-nav-manga')), findsNWidgets(3));

      await pumpWith(
        const AppUpdateState(loaded: true, developerMode: true),
        const SettingsPreferences(loaded: true, mangaReaderEnabled: false),
      );
      expect(find.byKey(const ValueKey('main-nav-manga')), findsNothing);
    },
  );
}

class _FixedAppUpdateController extends AppUpdateController {
  _FixedAppUpdateController(AppUpdateState fixedState)
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => fixedState.currentVersion,
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = fixedState;
  }
}

class _UnusedReleaseSource extends AppReleaseSource {
  @override
  Future<AppReleaseInfo> latest({required List<String> deviceAbis}) =>
      throw UnimplementedError();

  @override
  Future<void> download({
    required AppReleaseInfo release,
    required String destination,
    required void Function(int received, int total) onProgress,
  }) => throw UnimplementedError();
}
