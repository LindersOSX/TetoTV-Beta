import 'dart:convert';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/application/web_stream_aggregator.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  test('mixed marketplace catalogs retain video and manga providers only', () {
    final catalog = parseMarketplaceCatalog(
      jsonEncode(<Object?>[
        _catalogEntry(id: 'video.provider', type: 'online-stream-provider'),
        _catalogEntry(id: 'manga.provider', type: 'manga-provider'),
        _catalogEntry(id: 'ui.plugin', type: 'plugin'),
        _catalogEntry(id: 'theme.plugin', type: 'ui-plugin'),
      ]),
      repositoryUrl: 'https://catalog.example/marketplace.json',
    );

    expect(catalog.map((addon) => addon.id), <String>[
      'video.provider',
      'manga.provider',
    ]);
    expect(catalog.first.isOnlineStreamProvider, isTrue);
    expect(catalog.last.isMangaProvider, isTrue);
    expect(catalog.every((addon) => addon.isCompatible), isTrue);
  });

  test('add-on store queries isolate persisted provider kinds', () async {
    final database = await _openAddonDatabase();
    addTearDown(database.close);
    final store = AddonStore(TetoTvDatabase.forTesting(database));

    await store.install(
      _installedAddon('video.provider', 'onlinestream-provider'),
    );
    await store.install(_installedAddon('manga.provider', 'manga-provider'));
    await store.install(_installedAddon('ui.plugin', 'plugin'));

    expect(
      (await store.installedAddons()).map((addon) => addon.manifest.id),
      <String>['manga.provider', 'ui.plugin', 'video.provider'],
    );
    expect(
      (await store.installedStreamingAddons()).map(
        (addon) => addon.manifest.id,
      ),
      <String>['video.provider'],
    );
    expect(
      (await store.installedMangaAddons()).map((addon) => addon.manifest.id),
      <String>['manga.provider'],
    );
  });

  test('web discovery never loads a persisted manga provider', () async {
    final database = await _openAddonDatabase();
    addTearDown(() async {
      // Provider-search diagnostics are deliberately best effort and are
      // persisted asynchronously. Let that bounded write settle first.
      await Future<void>.delayed(Duration.zero);
      await database.close();
    });
    final databaseService = TetoTvDatabase.forTesting(database);
    final persistence = AddonStore(databaseService);
    await persistence.install(
      _installedAddon(
        'manga.must-not-run',
        'manga-provider',
        payload: "throw new Error('manga runtime entered video discovery');",
      ),
    );
    final store = _VideoDiscoveryStore(databaseService);
    final aggregator = WebStreamAggregator(store);

    final progress = await aggregator
        .searchIncrementally(
          const EpisodeReference(
            anilistMediaId: 1,
            title: 'Kind isolation fixture',
            episode: 1,
          ),
        )
        .toList();

    expect(store.streamingQueryCalls, 1);
    expect(progress, hasLength(1));
    expect(progress.single.totalProviders, 0);
    expect(progress.single.aggregation.streams, isEmpty);
    expect(progress.single.aggregation.failures, isEmpty);
  });

  test('video compatibility sweep excludes enabled manga providers', () async {
    final video = _installedAddon('video.provider', 'onlinestream-provider');
    final manga = _installedAddon('manga.provider', 'manga-provider');
    final store = _CompatibilityIsolationStore();
    final tested = <String>[];
    final controller = _SeededMarketplaceController(
      store,
      MarketplaceClient(store),
      MarketplaceState(installed: <InstalledStreamingAddon>[video, manga]),
      compatibilityRunner: (addon) async {
        tested.add(addon.manifest.id);
        return const ProviderCompatibilityOutcome(
          passed: true,
          stage: 'stream_extraction',
          reason: 'compatible',
          streamCount: 1,
        );
      },
    );
    addTearDown(controller.dispose);

    await controller.testAllInstalledProviders();

    expect(tested, <String>['video.provider']);
    expect(store.recordedCompatibilityIds, <String>['video.provider']);
    expect(controller.state.providerMessages, contains('video.provider'));
    expect(
      controller.state.providerMessages,
      isNot(contains('manga.provider')),
    );
  });
}

Map<String, Object?> _catalogEntry({
  required String id,
  required String type,
}) => <String, Object?>{
  'id': id,
  'name': id,
  'manifestURI': 'https://catalog.example/$id/manifest.json',
  'payloadURI': 'https://catalog.example/$id/provider.js',
  'type': type,
  'language': 'javascript',
  'lang': 'en',
};

InstalledStreamingAddon _installedAddon(
  String id,
  String type, {
  String payload = 'class Provider {}',
}) => InstalledStreamingAddon(
  manifest: MarketplaceAddon(
    id: id,
    name: id,
    description: 'Kind isolation fixture',
    author: 'TetoTV tests',
    manifestUri: Uri.parse('https://catalog.example/$id/manifest.json'),
    repositoryUrl: 'https://catalog.example/marketplace.json',
    language: 'javascript',
    type: type,
    locale: 'en',
    payloadUri: Uri.parse('https://catalog.example/$id/provider.js'),
  ),
  payload: payload,
  enabled: true,
  installedAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 1),
);

Future<Database> _openAddonDatabase() => databaseFactoryFfi.openDatabase(
  inMemoryDatabasePath,
  options: OpenDatabaseOptions(
    version: 1,
    onCreate: (database, _) async {
      await database.execute('''
        CREATE TABLE installed_addons (
          id TEXT PRIMARY KEY,
          manifest_json TEXT NOT NULL,
          payload TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          repository_url TEXT NOT NULL,
          installed_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
    },
  ),
);

class _VideoDiscoveryStore extends AddonStore {
  _VideoDiscoveryStore(super.database);

  int streamingQueryCalls = 0;

  @override
  Future<List<InstalledStreamingAddon>> installedAddons() =>
      Future<List<InstalledStreamingAddon>>.error(
        StateError('Video discovery used the unfiltered add-on query.'),
      );

  @override
  Future<List<InstalledStreamingAddon>> installedStreamingAddons() async {
    streamingQueryCalls++;
    return (await super.installedAddons())
        .where((addon) => addon.manifest.isOnlineStreamProvider)
        .toList(growable: false);
  }

  @override
  Future<Map<String, ProviderHealth>> providerHealth() async => const {};
}

class _CompatibilityIsolationStore extends AddonStore {
  _CompatibilityIsolationStore() : super(TetoTvDatabase.instance);

  final List<String> recordedCompatibilityIds = <String>[];

  @override
  Future<void> recordProviderHealthyResponse(String id) async {}

  @override
  Future<ProviderHealth> recordProviderCompatibilityResult(
    String id, {
    required bool passed,
    required String stage,
    required String reason,
  }) async {
    recordedCompatibilityIds.add(id);
    return ProviderHealth(
      providerId: id,
      compatibilityTests: 1,
      compatibilityPasses: passed ? 1 : 0,
      lastTestedAt: DateTime.utc(2026, 9, 1),
      lastTestStage: stage,
      lastTestReason: reason,
    );
  }
}

class _SeededMarketplaceController extends MarketplaceController {
  _SeededMarketplaceController(
    super.store,
    super.client,
    MarketplaceState initial, {
    super.compatibilityRunner,
  }) {
    state = initial;
  }
}
