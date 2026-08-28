import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/presentation/marketplace_screen.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'production TV traversal follows Sources actions and the next source rows',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            marketplaceControllerProvider.overrideWith(
              (_) => _SeededMarketplaceController(),
            ),
            userTorrentSourcesControllerProvider.overrideWith(
              (_) => _SeededTorrentSourcesController(),
            ),
          ],
          child: const MaterialApp(
            home: TvShortcuts(child: MarketplaceScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_focusedControl(tester, find.text('Settings')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        _focusedControl(tester, find.text('Add sources with phone')),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        _focusedControl(tester, find.text('Add Torrent source manifests')),
        isTrue,
      );

      // The third action wraps onto the next line at TetoTV's 1280-wide TV
      // canvas. Down should enter it instead of skipping to a later section.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        _focusedControl(tester, find.text('Add Marketplace repositories')),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Remove').at(0)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Remove').at(1)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Enabled')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Remove').at(2)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Enabled')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Remove').at(1)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Remove').at(0)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        _focusedControl(tester, find.text('Add Marketplace repositories')),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        _focusedControl(tester, find.text('Add Torrent source manifests')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'catalog focus survives a repository refresh and reaches install actions',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _SeededMarketplaceController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            marketplaceControllerProvider.overrideWith((_) => controller),
            userTorrentSourcesControllerProvider.overrideWith(
              (_) => _EmptyTorrentSourcesController(),
            ),
          ],
          child: const MaterialApp(
            home: TvShortcuts(child: MarketplaceScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Provider 1'),
        260,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Install'), findsNWidgets(3));

      final firstInstall = find.text('Install').first;
      final firstDetector = find
          .ancestor(
            of: firstInstall,
            matching: find.byType(FocusableActionDetector),
          )
          .first;
      tester
          .widget<FocusableActionDetector>(firstDetector)
          .focusNode!
          .requestFocus();
      await tester.pump();
      expect(_focusedControl(tester, firstInstall), isTrue);

      // A repository refresh can attach new Focus widgets before their lazy
      // grid RenderObjects exist. A D-pad event in that build/layout gap must
      // be ignored safely rather than reading FocusNode.rect and crashing.
      controller.replaceCatalog([
        _catalogAddon(10),
        _catalogAddon(11),
        _catalogAddon(12),
      ]);
      await tester.pump(Duration.zero, EnginePhase.build);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Provider 10'),
        260,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      final refreshedInstall = find.text('Install').first;
      final refreshedDetector = find
          .ancestor(
            of: refreshedInstall,
            matching: find.byType(FocusableActionDetector),
          )
          .first;
      tester
          .widget<FocusableActionDetector>(refreshedDetector)
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(_focusedControl(tester, find.text('Install').at(1)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Install Provider 11?'), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'marketplace.confirm.action',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('catalog language filter remains D-pad reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _SeededMarketplaceController()
      ..replaceCatalog([
        _catalogAddon(1, locale: 'en'),
        _catalogAddon(2, locale: 'es'),
        _catalogAddon(3, locale: 'en-US'),
      ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          marketplaceControllerProvider.overrideWith((_) => controller),
          userTorrentSourcesControllerProvider.overrideWith(
            (_) => _EmptyTorrentSourcesController(),
          ),
        ],
        child: const MaterialApp(home: TvShortcuts(child: MarketplaceScreen())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Language: All'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    final filter = find.text('Language: All');
    final detector = find
        .ancestor(of: filter, matching: find.byType(FocusableActionDetector))
        .first;
    tester.widget<FocusableActionDetector>(detector).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_focusedControl(tester, find.text('Sort: Name')), isTrue);

    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text('Filter provider language'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Spanish'), findsOneWidget);
    await tester.tap(find.text('Spanish'));
    await tester.pumpAndSettle();
    expect(find.text('Language: Spanish'), findsOneWidget);
    expect(find.text('Provider 2'), findsOneWidget);
    expect(find.text('Provider 1'), findsNothing);
    expect(find.text('Provider 3'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

MarketplaceAddon _catalogAddon(int number, {String locale = 'en'}) =>
    MarketplaceAddon(
      id: 'provider.$number',
      name: 'Provider $number',
      description: 'Navigation fixture $number',
      author: 'TetoTV tests',
      manifestUri: Uri.parse('https://example.com/provider-$number.json'),
      repositoryUrl: 'https://example.com/marketplace.json',
      language: 'javascript',
      type: 'onlinestream-provider',
      locale: locale,
    );

bool _focusedControl(WidgetTester tester, Finder label) {
  final detector = find
      .ancestor(of: label, matching: find.byType(FocusableActionDetector))
      .first;
  return tester.widget<FocusableActionDetector>(detector).focusNode?.hasFocus ??
      false;
}

class _SeededMarketplaceController extends MarketplaceController {
  _SeededMarketplaceController()
    : super(
        AddonStore(TetoTvDatabase.instance),
        MarketplaceClient(AddonStore(TetoTvDatabase.instance)),
      ) {
    state = MarketplaceState(
      repositories: [
        AddonRepository(
          url: 'https://example.com/marketplace.json',
          updatedAt: DateTime.utc(2026),
        ),
      ],
      catalog: [_catalogAddon(1), _catalogAddon(2), _catalogAddon(3)],
      loading: false,
    );
  }

  void replaceCatalog(List<MarketplaceAddon> catalog) {
    state = state.copyWith(catalog: catalog);
  }
}

class _SeededTorrentSourcesController extends UserTorrentSourcesController {
  _SeededTorrentSourcesController() : super(const FlutterSecureStorage()) {
    state = const UserTorrentSourcesState(
      manifestUrls: [
        'https://one.example/manifest.json',
        'https://two.example/manifest.json',
      ],
      loaded: true,
    );
  }
}

class _EmptyTorrentSourcesController extends UserTorrentSourcesController {
  _EmptyTorrentSourcesController() : super(const FlutterSecureStorage()) {
    state = const UserTorrentSourcesState(loaded: true);
  }
}
