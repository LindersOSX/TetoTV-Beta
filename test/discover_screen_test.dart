import 'package:anime_tv/app/app.dart';
import 'package:anime_tv/app/router.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/data/anilist_catalog_client.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/discover_screen.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final mode in [InterfaceMode.television, InterfaceMode.phone]) {
    testWidgets('${mode.displayName} opens Discover on the upper-left result', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _LayoutSettingsController(mode),
            ),
            catalogClientProvider.overrideWithValue(
              _FakeCatalog(
                results: const [
                  AnimeSummary(
                    id: 1,
                    title: 'Upper-left result',
                    description: '',
                    episodes: 12,
                    score: 8,
                  ),
                ],
              ),
            ),
          ],
          child: const MaterialApp(home: DiscoverScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'discover.result.first',
      );
      expect(
        find.byType(HomeSideNavigation),
        mode == InterfaceMode.television ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Left from Discover Filters enters the first result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _LayoutSettingsController(InterfaceMode.television),
          ),
          catalogClientProvider.overrideWithValue(
            _FakeCatalog(
              results: const [
                AnimeSummary(
                  id: 9,
                  title: 'First content result',
                  description: '',
                  episodes: 12,
                  score: 8,
                ),
              ],
            ),
          ),
        ],
        child: const MaterialApp(home: DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final filters = find.ancestor(
      of: find.byIcon(Icons.tune_rounded),
      matching: find.byType(TvFocusable),
    );
    final detector = tester.widget<FocusableActionDetector>(
      find.descendant(
        of: filters,
        matching: find.byType(FocusableActionDetector),
      ),
    );
    detector.focusNode!.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'discover.filters');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.result.first',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Classic Discover restores navigation and a noninitial Back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _LayoutSettingsController(InterfaceMode.phone),
          ),
          catalogClientProvider.overrideWithValue(
            _FakeCatalog(
              results: const [
                AnimeSummary(
                  id: 2,
                  title: 'Classic first result',
                  description: '',
                  episodes: 12,
                  score: 8,
                ),
              ],
            ),
          ),
        ],
        child: const MaterialApp(home: DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MainNavigationBar), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.result.first',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'discover.back');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'discover.filters');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Discover system Back returns Home without a header arrow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: '/discover',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Home destination')),
        ),
        GoRoute(path: '/discover', builder: (_, _) => const DiscoverScreen()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [catalogClientProvider.overrideWithValue(_FakeCatalog())],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Home destination'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty Discover results remain reachable from the TV navigation rail',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _LayoutSettingsController(InterfaceMode.television),
            ),
            catalogClientProvider.overrideWithValue(_FakeCatalog()),
          ],
          child: const MaterialApp(home: TvShortcuts(child: DiscoverScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No anime matched these filters.'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'discover.result.first',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'top-level.active-navigation',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'discover.result.first',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'discover.empty.filters',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('discover keeps advanced filters inside a compact dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [catalogClientProvider.overrideWithValue(_FakeCatalog())],
        child: const MaterialApp(home: DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'initial screen');
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('main-navigation'))).dy,
      0,
      reason: 'Primary navigation must not gain extra top padding',
    );

    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'opened dialog');

    expect(find.text('Find your next anime'), findsOneWidget);
    expect(
      find.text('Choose only the filters you care about.'),
      findsOneWidget,
    );
    expect(find.text('Genre'), findsOneWidget);
    expect(find.text('Tag'), findsOneWidget);
    expect(find.text('Format'), findsOneWidget);
    expect(find.text('Season'), findsOneWidget);
    expect(find.text('Year'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Minimum score'), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'scrolled dialog');
    expect(find.text('Include adult titles'), findsOneWidget);
  });

  testWidgets('applying a filter reloads Discover with the selected value', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = _FakeCatalog();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [catalogClientProvider.overrideWithValue(catalog)],
        child: const MaterialApp(home: DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All genres'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fantasy').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show results'));
    await tester.pumpAndSettle();

    expect(catalog.requests, hasLength(2));
    expect(catalog.requests.last.genre, 'Fantasy');
    expect(tester.takeException(), isNull);
  });

  testWidgets('illegal AniList combinations show a useful recovery state', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogClientProvider.overrideWithValue(
            _FakeCatalog(
              error: StateError('Illegal operation and value combination'),
            ),
          ),
        ],
        child: const MaterialApp(home: DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'AniList rejected that filter combination. Reset the filters or try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reset filters'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('Illegal operation'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D-pad traverses filters, applies them, and opens a result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final catalog = _FakeCatalog(
      results: const [
        AnimeSummary(
          id: 77,
          title: 'Filtered Result',
          description: '',
          episodes: 12,
          score: 8,
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: '/discover',
      routes: [
        GoRoute(path: '/discover', builder: (_, _) => const DiscoverScreen()),
        GoRoute(
          path: '/anime/:id',
          builder: (_, state) =>
              Scaffold(body: Text('Opened ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [catalogClientProvider.overrideWithValue(catalog)],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => TvShortcuts(child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.result.first',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'discover.filters');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // TvFocusable waits through a short quiet-release window so remotes that
    // emit rapid Down/Up packet pairs do not click through during a hold.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.filters.title',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.filters.sort',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.filters.genre',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fantasy').last);
    await tester.pumpAndSettle();

    for (var index = 0; index < 5; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 140));
    }
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.filters.apply',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(catalog.requests.last.genre, 'Fantasy');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.result.first',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Opened 77'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('header and first result row return predictably to Filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final results = List.generate(
      10,
      (index) => AnimeSummary(
        id: index + 1,
        title: index == 1
            ? 'A Very Long Anime Title That Must Stay Inside The Focus Ring'
            : 'Result ${index + 1}',
        description: '',
        episodes: 12,
        score: 8,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogClientProvider.overrideWithValue(
            _FakeCatalog(results: results),
          ),
        ],
        child: const MaterialApp(home: TvShortcuts(child: DiscoverScreen())),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.result.first',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'top-level.active-navigation',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'discover.result.first',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final title = find.text(
      'A Very Long Anime Title That Must Stay Inside The Focus Ring',
    );
    expect(title, findsOneWidget);
    final card = find.ancestor(of: title, matching: find.byType(TvFocusable));
    final cardRect = tester.getRect(card.first);
    final titleRect = tester.getRect(title);
    expect(titleRect.left, greaterThanOrEqualTo(cardRect.left + 7));
    expect(titleRect.right, lessThanOrEqualTo(cardRect.right - 7));
    expect(titleRect.bottom, lessThanOrEqualTo(cardRect.bottom - 7));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'discover.filters');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'production wrapper keeps focus visible across the middle Discover row',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => appRouter.go('/'));
      final results = List.generate(
        60,
        (index) => AnimeSummary(
          id: index + 1,
          title: 'Production Result ${index + 1}',
          description: '',
          episodes: 12,
          score: 8,
        ),
      );
      appRouter.go('/discover');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            catalogClientProvider.overrideWithValue(
              _FakeCatalog(results: results),
            ),
          ],
          child: const TetoTvApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'discover.result.first',
      );
      await tester.pump();
      expect(_focusedResult(tester, 'Production Result 1'), isTrue);

      // Discover uses the same canonical TV canvas at every panel resolution.
      // Read the row stride from the explicit grid focus label so this
      // navigation regression remains valid if poster geometry is tuned.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final secondRowFocusLabel =
          FocusManager.instance.primaryFocus?.debugLabel ?? '';
      final focusedIndexMatch = RegExp(
        r'^catalog\.result\.(\d+)$',
      ).firstMatch(secondRowFocusLabel);
      expect(focusedIndexMatch, isNotNull);
      final crossAxisCount = int.parse(focusedIndexMatch!.group(1)!);
      expect(crossAxisCount, greaterThan(1));
      final secondRowStart = crossAxisCount + 1;
      final secondRowEnd = crossAxisCount * 2 > results.length
          ? results.length
          : crossAxisCount * 2;
      expect(
        _focusedResult(tester, 'Production Result $secondRowStart'),
        isTrue,
      );

      for (var result = secondRowStart + 1; result <= secondRowEnd; result++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(_focusedResult(tester, 'Production Result $result'), isTrue);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        _focusedResult(tester, 'Production Result $secondRowEnd'),
        isTrue,
        reason: 'Right at the row edge must retain a visible focus ring.',
      );

      for (var result = secondRowEnd - 1; result >= secondRowStart; result--) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(_focusedResult(tester, 'Production Result $result'), isTrue);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'top-level.active-navigation',
        reason: 'Left at the first column must return to the active rail item.',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'discover.result.first',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        _focusedResult(tester, 'Production Result $secondRowStart'),
        isTrue,
      );

      // Keep moving through rows that are well beyond GridView's cache. Each
      // lazy card must be built, revealed, and focused without losing the
      // highlight that tells a TV user where the D-pad currently is.
      final laterRowStarts = <int>[
        for (
          var result = secondRowStart + crossAxisCount;
          result <= results.length;
          result += crossAxisCount
        )
          result,
      ];
      for (final result in laterRowStarts) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(_focusedResult(tester, 'Production Result $result'), isTrue);
        expect(
          find.text('Production Result $result').hitTestable(),
          findsOneWidget,
        );
      }
      final finalRowStart = laterRowStarts.isEmpty
          ? secondRowStart
          : laterRowStarts.last;
      for (var result = finalRowStart + 1; result <= results.length; result++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(_focusedResult(tester, 'Production Result $result'), isTrue);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        _focusedResult(tester, 'Production Result ${results.length}'),
        isTrue,
        reason: 'The sixtieth result must retain focus at the final row edge.',
      );
      for (var result = results.length - 1; result >= finalRowStart; result--) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(_focusedResult(tester, 'Production Result $result'), isTrue);
      }
      for (final result in [
        ...laterRowStarts.reversed.skip(1),
        secondRowStart,
      ]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(_focusedResult(tester, 'Production Result $result'), isTrue);
        expect(
          find.text('Production Result $result').hitTestable(),
          findsOneWidget,
          reason: 'Up must reveal the card at the viewport start.',
        );
      }

      // Return to a lazy row, then hold Up without allowing intermediate
      // reveal animations to finish. The last Up must cancel every pending
      // grid callback so Filters keeps focus after animations settle.
      for (var press = 0; press < laterRowStarts.length; press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(
        _focusedResult(tester, 'Production Result $finalRowStart'),
        isTrue,
      );
      for (var press = 0; press < laterRowStarts.length + 2; press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      }
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'discover.filters',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('holding a Discover result can add it to Planning', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.anilist.tokenStorageKey: 'anilist-token',
      TrackingProvider.myAnimeList.tokenStorageKey: 'mal-token',
    });
    final repositories = <TrackingProvider, _DiscoverRecordingRepository>{};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogClientProvider.overrideWithValue(
            _FakeCatalog(
              results: const [
                AnimeSummary(
                  id: 88,
                  idMal: 99,
                  title: 'Discover Planning Show',
                  description: '',
                  episodes: 12,
                  score: 8,
                ),
              ],
            ),
          ),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
          trackingRepositoryFactoryProvider.overrideWithValue((provider, _) {
            return repositories.putIfAbsent(
              provider,
              _DiscoverRecordingRepository.new,
            );
          }),
        ],
        child: const MaterialApp(home: DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Discover Planning Show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planning'));
    await tester.pumpAndSettle();

    expect(repositories[TrackingProvider.anilist]!.statusUpdates, [
      (mediaId: 88, status: TrackingListStatus.planToWatch),
    ]);
    expect(repositories[TrackingProvider.myAnimeList]!.statusUpdates, [
      (mediaId: 99, status: TrackingListStatus.planToWatch),
    ]);
  });

  testWidgets('holding a planned Discover result can remove it from lists', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      TrackingProvider.anilist.tokenStorageKey: 'anilist-token',
      TrackingProvider.myAnimeList.tokenStorageKey: 'mal-token',
    });
    final repositories = <TrackingProvider, _DiscoverRecordingRepository>{};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogClientProvider.overrideWithValue(
            _FakeCatalog(
              results: const [
                AnimeSummary(
                  id: 188,
                  idMal: 199,
                  title: 'Remove Planned Show',
                  description: '',
                  episodes: 12,
                  score: 8,
                ),
              ],
            ),
          ),
          trackingHomeProvider.overrideWith(
            (_) async => const TrackingHomeData(
              watching: [],
              planToWatch: [],
              completed: [],
            ),
          ),
          trackingListProvider(TrackingListStatus.planToWatch).overrideWith(
            (_) async => const TrackingListResult(
              items: [
                HomeTrackedAnime(
                  tracked: TrackedAnime(
                    mediaId: 188,
                    title: 'Remove Planned Show',
                    status: TrackingListStatus.planToWatch,
                    progress: 0,
                  ),
                  provider: TrackingProvider.anilist,
                  anilistId: 188,
                  coverImageUrl: null,
                ),
              ],
            ),
          ),
          trackingRepositoryFactoryProvider.overrideWithValue((provider, _) {
            return repositories.putIfAbsent(
              provider,
              _DiscoverRecordingRepository.new,
            );
          }),
        ],
        child: const MaterialApp(home: DiscoverScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Remove Planned Show'));
    await tester.pumpAndSettle();
    expect(find.text('Remove from Planning'), findsOneWidget);
    expect(
      find.textContaining('Dropped keeps the show in your list'),
      findsOneWidget,
    );
    await tester.tap(find.text('Remove from Planning'));
    await tester.pumpAndSettle();

    expect(repositories[TrackingProvider.anilist]!.removals, [188]);
    expect(repositories[TrackingProvider.myAnimeList]!.removals, [199]);
  });
}

class _FakeCatalog extends AniListCatalogClient {
  _FakeCatalog({this.results = const [], this.error});

  final List<AnimeSummary> results;
  final Object? error;
  final requests = <CatalogFilters>[];

  @override
  Future<List<AnimeSummary>> discover(
    CatalogFilters filters, {
    int page = 1,
  }) async {
    requests.add(filters);
    if (error != null) throw error!;
    return results;
  }
}

class _LayoutSettingsController extends SettingsPreferencesController {
  _LayoutSettingsController(InterfaceMode mode)
    : super(const FlutterSecureStorage()) {
    state = SettingsPreferences(interfaceMode: mode, loaded: true);
  }

  @override
  Future<void> load() async {}
}

bool _focusedResult(WidgetTester tester, String title) {
  final detector = find
      .ancestor(
        of: find.text(title),
        matching: find.byType(FocusableActionDetector),
      )
      .first;
  return tester.widget<FocusableActionDetector>(detector).focusNode?.hasFocus ??
      false;
}

class _DiscoverRecordingRepository implements TrackingRepository {
  final statusUpdates = <({int mediaId, TrackingListStatus status})>[];
  final removals = <int>[];

  @override
  Future<int?> currentProgress(int mediaId) async => null;

  @override
  Future<List<TrackedAnime>> list(TrackingListStatus status) async => const [];

  @override
  Future<void> removeFromList({required int mediaId}) async {
    removals.add(mediaId);
  }

  @override
  Future<void> updateProgress({
    required int mediaId,
    required int completedEpisodes,
  }) async {}

  @override
  Future<void> updateStatus({
    required int mediaId,
    required TrackingListStatus status,
  }) async {
    statusUpdates.add((mediaId: mediaId, status: status));
  }
}
