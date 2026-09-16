import 'dart:io';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/presentation/marketplace_screen.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'installed provider shows score, timestamp, and all five stages',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            marketplaceControllerProvider.overrideWith(
              (_) => _ProviderHealthController(),
            ),
            userTorrentSourcesControllerProvider.overrideWith(
              (_) => _EmptyTorrentSourcesController(),
            ),
          ],
          child: const MaterialApp(home: MarketplaceScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Fixture Provider'),
        260,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();

      expect(find.text('Test all'), findsOneWidget);
      expect(find.text('HEALTH 100/100'), findsOneWidget);
      expect(find.textContaining('Last tested 2026-08-23'), findsOneWidget);
      expect(
        find.text('Search ✓ • Title ✓ • Episode ✓ • Server ✓ • Stream ✓'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inconclusive provider test uses neutral health markers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          marketplaceControllerProvider.overrideWith(
            (_) => _InconclusiveProviderHealthController(),
          ),
          userTorrentSourcesControllerProvider.overrideWith(
            (_) => _EmptyTorrentSourcesController(),
          ),
        ],
        child: const MaterialApp(home: MarketplaceScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Inconclusive Provider'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('TEST INCONCLUSIVE'), findsOneWidget);
    expect(
      find.text('Search — • Title ? • Episode — • Server — • Stream —'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Compatibility test inconclusive'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime incompatibility is distinct from a timed pause', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          marketplaceControllerProvider.overrideWith(
            (_) => _RuntimeIncompatibleProviderHealthController(),
          ),
          userTorrentSourcesControllerProvider.overrideWith(
            (_) => _EmptyTorrentSourcesController(),
          ),
        ],
        child: const MaterialApp(home: MarketplaceScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Runtime Provider'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('INCOMPATIBLE RUNTIME'), findsOneWidget);
    expect(find.text('PAUSED AFTER FAILURES'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one discovery TypeError does not show incompatible runtime', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          marketplaceControllerProvider.overrideWith(
            (_) => _RuntimeTransientProviderHealthController(),
          ),
          userTorrentSourcesControllerProvider.overrideWith(
            (_) => _EmptyTorrentSourcesController(),
          ),
        ],
        child: const MaterialApp(home: MarketplaceScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Transient Runtime Provider'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('INCOMPATIBLE RUNTIME'), findsNothing);
    expect(find.text('NOT TESTED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mixed installed providers use kind-specific sections and actions',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _FixedSettingsPreferencesController(
                const SettingsPreferences(
                  loaded: true,
                  mangaReaderEnabled: true,
                ),
              ),
            ),
            appUpdateControllerProvider.overrideWith(
              (_) => _FixedAppUpdateController(),
            ),
            marketplaceControllerProvider.overrideWith(
              (_) => _MixedProviderController(installedOnly: true),
            ),
            userTorrentSourcesControllerProvider.overrideWith(
              (_) => _EmptyTorrentSourcesController(),
            ),
          ],
          child: const MaterialApp(home: MarketplaceScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Installed anime stream providers'),
        280,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Installed anime stream providers'), findsOneWidget);
      expect(find.text('Test all'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Installed manga providers'),
        280,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();

      expect(find.text('Installed manga providers'), findsOneWidget);
      expect(find.text('MANGA SOURCE • APPEARS IN MANGA'), findsOneWidget);

      final mangaCard = find.byKey(
        const ValueKey('marketplace.addon.manga.fixture'),
      );
      expect(mangaCard, findsOneWidget);
      expect(
        find.descendant(of: mangaCard, matching: find.text('Test')),
        findsNothing,
      );
      expect(
        find.descendant(of: mangaCard, matching: find.text('Reset')),
        findsNothing,
      );
      expect(
        find.descendant(of: mangaCard, matching: find.text('Disable')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: mangaCard, matching: find.text('Uninstall')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mixed catalog separates anime and manga provider destinations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _FixedSettingsPreferencesController(
              const SettingsPreferences(loaded: true, mangaReaderEnabled: true),
            ),
          ),
          appUpdateControllerProvider.overrideWith(
            (_) => _FixedAppUpdateController(),
          ),
          marketplaceControllerProvider.overrideWith(
            (_) => _MixedProviderController(installedOnly: false),
          ),
          userTorrentSourcesControllerProvider.overrideWith(
            (_) => _EmptyTorrentSourcesController(),
          ),
        ],
        child: const MaterialApp(home: MarketplaceScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Available providers'),
      280,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('Anime stream providers'), findsOneWidget);
    expect(find.text('Manga providers'), findsOneWidget);
    expect(
      find.textContaining('2 of 2 compatible providers shown'),
      findsOneWidget,
    );
    expect(find.text('ANIME STREAM • WEB STREAMS'), findsOneWidget);
    expect(find.text('MANGA SOURCE • INSTALL FOR MANGA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disabled Manga reader hides Manga catalog and installed providers',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith(
              (_) => _FixedSettingsPreferencesController(
                const SettingsPreferences(
                  loaded: true,
                  mangaReaderEnabled: false,
                ),
              ),
            ),
            appUpdateControllerProvider.overrideWith(
              (_) => _FixedAppUpdateController(),
            ),
            marketplaceControllerProvider.overrideWith(
              (_) => _MixedProviderController(
                installedOnly: false,
                includeInstalled: true,
              ),
            ),
            userTorrentSourcesControllerProvider.overrideWith(
              (_) => _EmptyTorrentSourcesController(),
            ),
          ],
          child: const MaterialApp(home: MarketplaceScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Installed anime stream providers'), findsOneWidget);
      expect(find.text('Installed manga providers'), findsNothing);
      expect(
        find.byKey(const ValueKey('marketplace.addon.manga.fixture')),
        findsNothing,
      );

      await tester.scrollUntilVisible(
        find.text('Available providers'),
        280,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Anime stream providers'), findsOneWidget);
      expect(find.text('Manga providers'), findsNothing);
      expect(find.text('MANGA SOURCE • INSTALL FOR MANGA'), findsNothing);
      expect(
        find.textContaining('compatible anime stream providers shown'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Marketplace fails closed while Manga preference is loading', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _FixedSettingsPreferencesController(
              const SettingsPreferences(
                loaded: false,
                mangaReaderEnabled: true,
              ),
            ),
          ),
          appUpdateControllerProvider.overrideWith(
            (_) => _FixedAppUpdateController(),
          ),
          marketplaceControllerProvider.overrideWith(
            (_) => _MixedProviderController(installedOnly: false),
          ),
          userTorrentSourcesControllerProvider.overrideWith(
            (_) => _EmptyTorrentSourcesController(),
          ),
        ],
        child: const MaterialApp(home: MarketplaceScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Available providers'),
      280,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('Anime stream providers'), findsOneWidget);
    expect(find.text('Manga providers'), findsNothing);
    expect(find.text('MANGA SOURCE • INSTALL FOR MANGA'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Manga install confirmation cannot outlive a live opt-out', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = _FixedSettingsPreferencesController(
      const SettingsPreferences(loaded: true, mangaReaderEnabled: true),
    );
    final marketplace = _MixedProviderController(installedOnly: false);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith((_) => settings),
          appUpdateControllerProvider.overrideWith(
            (_) => _FixedAppUpdateController(),
          ),
          marketplaceControllerProvider.overrideWith((_) => marketplace),
          userTorrentSourcesControllerProvider.overrideWith(
            (_) => _EmptyTorrentSourcesController(),
          ),
        ],
        child: const MaterialApp(home: MarketplaceScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('MANGA SOURCE • INSTALL FOR MANGA'),
      280,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    final mangaCard = find.byKey(
      const ValueKey('marketplace.addon.manga.fixture'),
    );
    await tester.tap(
      find.descendant(of: mangaCard, matching: find.text('Install')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Install manga.fixture?'), findsOneWidget);

    await settings.setMangaReaderEnabled(false);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'INSTALL'));
    await tester.pumpAndSettle();

    expect(marketplace.installCalls, 0);
    expect(find.text('Install manga.fixture?'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _ProviderHealthController extends MarketplaceController {
  _ProviderHealthController()
    : super(
        AddonStore(TetoTvDatabase.instance),
        MarketplaceClient(AddonStore(TetoTvDatabase.instance)),
      ) {
    final manifest = MarketplaceAddon(
      id: 'fixture-provider',
      name: 'Fixture Provider',
      description: 'Provider health UI fixture',
      author: 'TetoTV tests',
      manifestUri: Uri.parse('https://example.test/provider.json'),
      repositoryUrl: 'https://example.test/marketplace.json',
      language: 'javascript',
      type: 'onlinestream-provider',
      locale: 'en',
    );
    final installed = InstalledStreamingAddon(
      manifest: manifest,
      payload: 'class Provider {}',
      enabled: true,
      installedAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final health = ProviderHealth(
      providerId: manifest.id,
      compatibilityTests: 2,
      compatibilityPasses: 2,
      lastTestedAt: DateTime(2026, 8, 23, 12),
      lastTestStage: 'stream_extraction',
      lastTestReason: 'compatible',
    );
    state = MarketplaceState(
      installed: [installed],
      providerHealth: {manifest.id: health},
      loading: false,
    );
  }
}

class _InconclusiveProviderHealthController extends MarketplaceController {
  _InconclusiveProviderHealthController()
    : super(
        AddonStore(TetoTvDatabase.instance),
        MarketplaceClient(AddonStore(TetoTvDatabase.instance)),
      ) {
    final manifest = MarketplaceAddon(
      id: 'inconclusive-provider',
      name: 'Inconclusive Provider',
      description: 'Provider health UI fixture',
      author: 'TetoTV tests',
      manifestUri: Uri.parse('https://example.test/provider.json'),
      repositoryUrl: 'https://example.test/marketplace.json',
      language: 'javascript',
      type: 'onlinestream-provider',
      locale: 'en',
    );
    final installed = InstalledStreamingAddon(
      manifest: manifest,
      payload: 'class Provider {}',
      enabled: true,
      installedAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final health = ProviderHealth(
      providerId: manifest.id,
      lastTestedAt: DateTime(2026, 8, 23, 12),
      lastTestStage: 'title_matching',
      lastTestReason: 'test_title_unavailable',
    );
    state = MarketplaceState(
      installed: [installed],
      providerHealth: {manifest.id: health},
      providerMessages: {
        manifest.id:
            'Compatibility test inconclusive • '
            'Title matching could not find either built-in test title',
      },
      loading: false,
    );
  }
}

class _RuntimeIncompatibleProviderHealthController
    extends MarketplaceController {
  _RuntimeIncompatibleProviderHealthController()
    : super(
        AddonStore(TetoTvDatabase.instance),
        MarketplaceClient(AddonStore(TetoTvDatabase.instance)),
      ) {
    final manifest = MarketplaceAddon(
      id: 'runtime-provider',
      name: 'Runtime Provider',
      description: 'Runtime compatibility UI fixture',
      author: 'TetoTV tests',
      manifestUri: Uri.parse('https://example.test/provider.json'),
      repositoryUrl: 'https://example.test/marketplace.json',
      language: 'javascript',
      type: 'onlinestream-provider',
      locale: 'en',
    );
    final installed = InstalledStreamingAddon(
      manifest: manifest,
      payload: 'class Provider {}',
      enabled: true,
      installedAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    const health = ProviderHealth(
      providerId: 'runtime-provider',
      consecutiveFailures: 4,
      lastFailureStage: 'search',
      lastFailureReason: 'runtime_api',
      lastTestStage: 'search',
      lastTestReason: 'runtime_api',
    );
    state = MarketplaceState(
      installed: [installed],
      providerHealth: {manifest.id: health},
      loading: false,
    );
  }
}

class _RuntimeTransientProviderHealthController extends MarketplaceController {
  _RuntimeTransientProviderHealthController()
    : super(
        AddonStore(TetoTvDatabase.instance),
        MarketplaceClient(AddonStore(TetoTvDatabase.instance)),
      ) {
    final manifest = MarketplaceAddon(
      id: 'runtime-transient-provider',
      name: 'Transient Runtime Provider',
      description: 'Discovery failure UI fixture',
      author: 'TetoTV tests',
      manifestUri: Uri.parse('https://example.test/provider.json'),
      repositoryUrl: 'https://example.test/marketplace.json',
      language: 'javascript',
      type: 'onlinestream-provider',
      locale: 'en',
    );
    final installed = InstalledStreamingAddon(
      manifest: manifest,
      payload: 'class Provider {}',
      enabled: true,
      installedAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    const health = ProviderHealth(
      providerId: 'runtime-transient-provider',
      consecutiveFailures: 1,
      lastFailureStage: 'search',
      lastFailureReason: 'runtime_api',
    );
    state = MarketplaceState(
      installed: [installed],
      providerHealth: {manifest.id: health},
      loading: false,
    );
  }
}

class _MixedProviderController extends MarketplaceController {
  _MixedProviderController({
    required bool installedOnly,
    bool includeInstalled = false,
  }) : super(
         AddonStore(TetoTvDatabase.instance),
         MarketplaceClient(AddonStore(TetoTvDatabase.instance)),
       ) {
    final stream = _provider('stream.fixture', 'onlinestream-provider');
    final manga = _provider('manga.fixture', 'manga-provider');
    state = MarketplaceState(
      installed: installedOnly || includeInstalled
          ? [_installed(stream), _installed(manga)]
          : const <InstalledStreamingAddon>[],
      catalog: installedOnly ? const [] : [stream, manga],
      loading: false,
    );
  }

  int installCalls = 0;

  @override
  Future<void> install(MarketplaceAddon addon) async {
    installCalls += 1;
  }

  static MarketplaceAddon _provider(String id, String type) => MarketplaceAddon(
    id: id,
    name: id,
    description: 'Mixed provider UI fixture',
    author: 'TetoTV tests',
    manifestUri: Uri.parse('https://example.test/$id.json'),
    repositoryUrl: 'https://example.test/marketplace.json',
    language: 'javascript',
    type: type,
    locale: 'en',
  );

  static InstalledStreamingAddon _installed(MarketplaceAddon manifest) =>
      InstalledStreamingAddon(
        manifest: manifest,
        payload: 'class Provider {}',
        enabled: true,
        installedAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
}

class _FixedSettingsPreferencesController
    extends SettingsPreferencesController {
  _FixedSettingsPreferencesController(SettingsPreferences initial)
    : super(
        const FlutterSecureStorage(),
        readValue: (_) async => null,
        writeValue: (_, _) async {},
        deleteValue: (_) async {},
      ) {
    state = initial;
  }
}

class _FixedAppUpdateController extends AppUpdateController {
  _FixedAppUpdateController()
    : super(
        const FlutterSecureStorage(),
        _UnusedReleaseSource(),
        () async => 'test',
        () async => const [],
        () async => Directory.systemTemp,
        (_) async => '',
      ) {
    state = const AppUpdateState(loaded: true, developerMode: true);
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

class _EmptyTorrentSourcesController extends UserTorrentSourcesController {
  _EmptyTorrentSourcesController() : super(const FlutterSecureStorage()) {
    state = const UserTorrentSourcesState(loaded: true);
  }
}
