import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/home/presentation/home_screen.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final builtInKeyboard in const [true, false]) {
    testWidgets(
      'Home header submits through the ${builtInKeyboard ? 'Teto' : 'device'} keyboard',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          initialSetupCompletedStorageKey: 'true',
          'input_use_built_in_keyboard': '$builtInKeyboard',
        });
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final destinationFocus = FocusNode(
          debugLabel: 'home-search.destination',
        );
        addTearDown(destinationFocus.dispose);
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
            GoRoute(
              path: '/search',
              builder: (_, state) => Scaffold(
                body: Focus(
                  autofocus: true,
                  focusNode: destinationFocus,
                  child: Text('query:${state.uri.queryParameters['q']}'),
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              trendingAnimeProvider.overrideWith((_) async => const []),
              seasonalAnimeProvider.overrideWith((_) async => const []),
              trackingHomeProvider.overrideWith(
                (_) async => const TrackingHomeData(
                  watching: [],
                  planToWatch: [],
                  completed: [],
                ),
              ),
              recentPlaybackProvider.overrideWith((_) async => const []),
              dismissedContinueWatchingProvider.overrideWith(
                (_) async => const <int>{},
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('home-header-search')));
        await tester.pumpAndSettle();
        if (builtInKeyboard) {
          for (final letter in const ['f', 'r', 'i', 'e', 'r', 'e', 'n']) {
            await tester.tap(find.text(letter));
          }
          await tester.tap(find.text('DONE'));
        } else {
          final field = find.byType(TextField);
          expect(field, findsOneWidget);
          await tester.enterText(field, 'Frieren & Fern');
          await tester.testTextInput.receiveAction(TextInputAction.done);
        }
        await tester.pumpAndSettle();

        expect(
          find.text(builtInKeyboard ? 'query:frieren' : 'query:Frieren & Fern'),
          findsOneWidget,
        );
        expect(FocusManager.instance.primaryFocus, same(destinationFocus));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
