import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/data/typescript_compiler.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _repositoryUrl =
    'https://example.com/tetotv-fixtures/lifecycle-marketplace.json';
const _manifestUrl =
    'https://example.com/tetotv-fixtures/lifecycle-provider.json';
const _payloadUrl = 'https://example.com/tetotv-fixtures/lifecycle-provider.ts';
const _addonId = 'tetotv.integration.lifecycle.typescript';

const _typescriptProvider = r'''
interface SearchInput {
  query: string;
}

interface SearchResult {
  id: string;
  title: string;
  subOrDub: string;
}

interface EpisodeResult {
  id: string;
  number: number;
  url: string;
}

class Provider {
  private readonly origin: string = 'https://example.com';

  getSettings(): {episodeServers: string[]; supportsDub: boolean} {
    return {episodeServers: ['Fixture'], supportsDub: false};
  }

  async search(input: SearchInput): Promise<SearchResult[]> {
    return [{id: 'fixture-show', title: input.query, subOrDub: 'sub'}];
  }

  async findEpisodes(_id: string): Promise<EpisodeResult[]> {
    return [{
      id: 'fixture-episode-2',
      number: 2,
      url: `${this.origin}/shows/fixture/episodes/2`,
    }];
  }

  async findEpisodeServer(
    _episode: EpisodeResult,
    server: string,
  ): Promise<object> {
    return {
      server,
      headers: {Referer: `${this.origin}/`},
      videoSources: [{
        url: `${this.origin}/videos/fixture-episode-2.m3u8`,
        quality: '720p',
      }],
    };
  }
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'compiles a TypeScript provider fixture on Android without native stack failure',
    (tester) async {
      final source = _typeScriptCompilerFixture();
      expect(source.length, greaterThan(8 * 1024));
      expect(source.length, lessThan(10 * 1024));

      final compiled = await AddonTypescriptCompiler().compile(source);

      expect(compiled, contains('class Provider'));
      expect(compiled, isNot(contains('interface SearchInput')));
      expect(compiled, isNot(contains('private resolve')));
      expect(compiled, isNot(contains(' as SearchResult')));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'repository install lifecycle survives reload and executes compiled TypeScript',
    (tester) async {
      final database = TetoTvDatabase.instance;
      await database.close();
      await _clearFixtureRows(database);
      addTearDown(() async {
        await database.close();
        await _clearFixtureRows(database);
        await database.close();
      });

      final firstStore = AddonStore(database);
      final firstClient = _FixtureMarketplaceClient(firstStore);
      final validatedTargets = <Uri>[];
      final firstController = MarketplaceController(
        firstStore,
        firstClient,
        targetValidator: (uri) async => validatedTargets.add(uri),
      );
      await firstController.load();

      expect(
        firstController.state.repositories.any(
          (repository) => repository.url == _repositoryUrl,
        ),
        isFalse,
      );
      expect(
        firstController.state.installed.any(
          (addon) => addon.manifest.id == _addonId,
        ),
        isFalse,
      );
      expect(await firstController.addRepository(_repositoryUrl), isNull);
      expect(validatedTargets, [Uri.parse(_repositoryUrl)]);
      expect(
        firstController.state.catalog
            .singleWhere((addon) => addon.id == _addonId)
            .id,
        _addonId,
      );
      firstController.dispose();

      await database.close();
      final installStore = AddonStore(database);
      final repositoriesAfterAddReload = await installStore.repositories();
      expect(
        repositoriesAfterAddReload.any(
          (repository) => repository.url == _repositoryUrl,
        ),
        isTrue,
      );
      expect(
        (await installStore.installedAddons()).any(
          (addon) => addon.manifest.id == _addonId,
        ),
        isFalse,
      );

      final installClient = _FixtureMarketplaceClient(installStore);
      final installController = _controller(installStore, installClient);
      await installController.load();
      final firstCatalogAddon = installController.state.catalog.singleWhere(
        (addon) => addon.id == _addonId,
      );

      await installController.install(firstCatalogAddon);
      expect(installClient.downloads, 1);
      expect(installClient.lastCompiledPayload, contains('class Provider'));
      expect(installClient.lastCompiledPayload, isNot(contains('interface ')));
      expect(
        installController.state.installed
            .singleWhere((addon) => addon.manifest.id == _addonId)
            .manifest
            .id,
        _addonId,
      );
      installController.dispose();

      await database.close();
      final reloadedStore = AddonStore(database);
      final persistedRepositories = await reloadedStore.repositories();
      final persistedAddons = await reloadedStore.installedAddons();
      expect(
        persistedRepositories.any(
          (repository) => repository.url == _repositoryUrl,
        ),
        isTrue,
      );
      final persistedAddon = persistedAddons.singleWhere(
        (addon) => addon.manifest.id == _addonId,
      );
      await _expectFixtureStream(persistedAddon);

      final uninstallController = _controller(
        reloadedStore,
        _FixtureMarketplaceClient(reloadedStore),
      );
      await uninstallController.load();
      await uninstallController.uninstall(_addonId);
      expect(
        uninstallController.state.installed.any(
          (addon) => addon.manifest.id == _addonId,
        ),
        isFalse,
      );
      uninstallController.dispose();

      await database.close();
      final absentAfterReload = await AddonStore(database).installedAddons();
      expect(
        absentAfterReload.any((addon) => addon.manifest.id == _addonId),
        isFalse,
      );

      final reinstallStore = AddonStore(database);
      final reinstallClient = _FixtureMarketplaceClient(reinstallStore);
      final reinstallController = _controller(reinstallStore, reinstallClient);
      await reinstallController.load();
      expect(
        reinstallController.state.repositories.any(
          (repository) => repository.url == _repositoryUrl,
        ),
        isTrue,
      );
      final reinstallCatalogAddon = reinstallController.state.catalog
          .singleWhere((addon) => addon.id == _addonId);
      await reinstallController.install(reinstallCatalogAddon);
      expect(reinstallClient.downloads, 1);
      reinstallController.dispose();

      await database.close();
      final reinstalled = await AddonStore(database).installedAddons();
      final reinstalledAddon = reinstalled.singleWhere(
        (addon) => addon.manifest.id == _addonId,
      );
      await _expectFixtureStream(reinstalledAddon);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _typeScriptCompilerFixture() {
  final resolvers = List.generate(
    18,
    (index) =>
        '''
  private resolve$index(
    data: Array<Record<string, unknown>> | null,
    fallback: string,
  ): string[] {
    if (!data?.length) return [];
    return data.map((item: Record<string, unknown>, itemIndex: number) => {
      const candidate = (item['title'] ?? item['slug'] ?? fallback) as string;
      return candidate?.trim() || `Result \${itemIndex + $index}`;
    }).filter(Boolean) as string[];
  }
''',
  ).join();
  return '''
interface SearchInput {
  query: string;
  dub?: boolean;
}

interface SearchResult {
  id: string;
  title: string;
  subOrDub: 'sub' | 'dub';
}

class Provider {
  baseUrl: string = 'https://example.com';
$resolvers
  getSettings(): {episodeServers: string[]; supportsDub: boolean} {
    return {episodeServers: ['HLS'], supportsDub: true};
  }

  async search(input: SearchInput): Promise<SearchResult[]> {
    const records = [{title: input.query}] as Array<Record<string, unknown>>;
    const titles = this.resolve17(records, input.query);
    return titles.map((title: string, index: number) => ({
      id: JSON.stringify({slug: title.toLowerCase(), index}),
      title,
      subOrDub: input.dub ? 'dub' : 'sub',
    })) as SearchResult[];
  }

  async findEpisodes(id: string): Promise<Array<{id: string; number: number}>> {
    const parsed = JSON.parse(id) as {slug?: string};
    return [{id: parsed.slug!, number: 1}];
  }

  async findEpisodeServer(
    episode: {id: string; number: number},
    server: string,
  ): Promise<object> {
    return {
      server,
      videoSources: [{
        url: `\${this.baseUrl}/\${episode.id}/\${episode.number}.m3u8`,
        type: 'm3u8',
      }],
    };
  }
}
''';
}

MarketplaceController _controller(AddonStore store, MarketplaceClient client) =>
    MarketplaceController(store, client, targetValidator: (_) async {});

Future<void> _expectFixtureStream(InstalledStreamingAddon addon) async {
  final streams = await SeanimeJavascriptProvider(addon).streams(
    const EpisodeReference(
      anilistMediaId: 1,
      malMediaId: 1,
      title: 'Fixture Anime',
      episode: 2,
    ),
  );

  expect(streams, hasLength(1));
  expect(streams.single.providerName, 'Lifecycle TypeScript Fixture');
  expect(
    streams.single.uri,
    Uri.parse('https://example.com/videos/fixture-episode-2.m3u8'),
  );
  expect(streams.single.quality, '720p');
  expect(streams.single.headers['Referer'], 'https://example.com/');
}

Future<void> _clearFixtureRows(TetoTvDatabase database) async {
  final store = AddonStore(database);
  await store.uninstall(_addonId);
  await store.clearProviderHealth(_addonId);
  await store.removeRepository(_repositoryUrl);
}

class _FixtureMarketplaceClient extends MarketplaceClient {
  _FixtureMarketplaceClient(super.store);

  final _compiler = AddonTypescriptCompiler();
  int downloads = 0;
  String? lastCompiledPayload;

  MarketplaceAddon get _addon => MarketplaceAddon(
    id: _addonId,
    name: 'Lifecycle TypeScript Fixture',
    description: 'Hermetic Marketplace lifecycle integration fixture',
    author: 'TetoTV tests',
    manifestUri: Uri.parse(_manifestUrl),
    repositoryUrl: _repositoryUrl,
    language: 'typescript',
    type: 'onlinestream-provider',
    locale: 'en',
    version: '1.0.0',
    payloadUri: Uri.parse(_payloadUrl),
  );

  @override
  Future<List<MarketplaceAddon>> catalog(
    AddonRepository repository, {
    bool refresh = false,
  }) async {
    return repository.url == _repositoryUrl ? [_addon] : const [];
  }

  @override
  Future<MarketplaceAddon> manifest(MarketplaceAddon summary) async {
    expect(summary.id, _addonId);
    return _addon;
  }

  @override
  Future<InstalledStreamingAddon> downloadAddon(
    MarketplaceAddon summary,
  ) async {
    expect(summary.id, _addonId);
    downloads += 1;
    final payload = await _compiler.compile(_typescriptProvider);
    lastCompiledPayload = payload;
    final now = DateTime.now();
    return InstalledStreamingAddon(
      manifest: _addon,
      payload: payload,
      enabled: true,
      installedAt: now,
      updatedAt: now,
    );
  }
}
