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

  test('runtime order injects Manga only after Developer Mode loads', () {
    const preferences = SettingsPreferences();

    expect(
      runtimeTopNavigationOrder(
        preferences,
        developerStateLoaded: false,
        developerMode: true,
      ),
      isNot(contains(TopNavigationDestination.manga)),
    );
    expect(
      runtimeTopNavigationOrder(
        preferences,
        developerStateLoaded: true,
        developerMode: false,
      ),
      isNot(contains(TopNavigationDestination.manga)),
    );

    final developerOrder = runtimeTopNavigationOrder(
      preferences,
      developerStateLoaded: true,
      developerMode: true,
    );
    expect(developerOrder, contains(TopNavigationDestination.manga));
    expect(
      developerOrder.indexOf(TopNavigationDestination.manga),
      developerOrder.indexOf(TopNavigationDestination.downloads) - 1,
    );
    expect(
      defaultTopNavigationOrder,
      isNot(contains(TopNavigationDestination.manga)),
    );
  });

  testWidgets('all shared navigation surfaces use the Developer Mode gate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> pumpWith(AppUpdateState state) async {
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
                      preferences: const SettingsPreferences(),
                      metrics: homeNavigationRailMetrics(
                        NavigationChromeSize.medium,
                      ),
                      onExitRight: () {},
                    ),
                  ),
                  const Positioned(
                    left: 100,
                    right: 0,
                    top: 0,
                    child: MainNavigationBar(
                      active: MainNavigationDestination.home,
                      preferences: SettingsPreferences(),
                    ),
                  ),
                  const Positioned(
                    left: 100,
                    right: 0,
                    bottom: 0,
                    child: PhoneBottomNavigation(
                      preferences: SettingsPreferences(),
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

    await pumpWith(const AppUpdateState(loaded: false, developerMode: true));
    expect(find.byKey(const ValueKey('main-nav-manga')), findsNothing);

    await pumpWith(const AppUpdateState(loaded: true, developerMode: false));
    expect(find.byKey(const ValueKey('main-nav-manga')), findsNothing);

    await pumpWith(const AppUpdateState(loaded: true, developerMode: true));
    expect(find.byKey(const ValueKey('main-nav-manga')), findsNWidgets(3));
  });
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
