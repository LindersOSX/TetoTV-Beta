import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/presentation/marketplace_screen.dart';
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

class _EmptyTorrentSourcesController extends UserTorrentSourcesController {
  _EmptyTorrentSourcesController() : super(const FlutterSecureStorage()) {
    state = const UserTorrentSourcesState(loaded: true);
  }
}
