import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  test(
    'refresh persists same-provenance advisory without changing executable data',
    () async {
      final database = await _openDatabase();
      addTearDown(database.close);
      final store = AddonStore(TetoTvDatabase.forTesting(database));
      final original = _installed(_manifest());
      await store.install(original);
      final advisory = _manifest(
        id: 'PROVIDER.TEST',
        name: 'Untrusted replacement name',
        description: 'Untrusted replacement description',
        author: 'Different author',
        manifestUri: 'https://owner.example/replacement/manifest.json',
        language: 'typescript',
        type: 'manga-provider',
        locale: 'ja',
        version: '99.0.0',
        payloadUri: 'https://owner.example/replacement/provider.js',
        defaults: const {'endpoint': 'https://replacement.example'},
        reportedWorking: false,
        reportedBroken: true,
        isDeprecated: true,
        lastWorkingVersion: '1.8.4',
      );
      final client = _CatalogClient(store, {
        _ownerRepository: [advisory],
      });
      final controller = _controller(store, client, original, [
        _repository(_ownerRepository),
      ]);
      addTearDown(controller.dispose);

      await controller.refresh();

      final current = controller.state.installed.single;
      _expectExecutableUnchanged(current, original);
      expect(current.manifest.reportedWorking, isFalse);
      expect(current.manifest.reportedBroken, isTrue);
      expect(current.manifest.isDeprecated, isTrue);
      expect(current.manifest.lastWorkingVersion, '1.8.4');

      final persisted = (await store.installedAddons()).single;
      _expectExecutableUnchanged(persisted, original);
      expect(persisted.manifest.reportedWorking, isFalse);
      expect(persisted.manifest.reportedBroken, isTrue);
      expect(persisted.manifest.isDeprecated, isTrue);
      expect(persisted.manifest.lastWorkingVersion, '1.8.4');
    },
  );

  test('same-provenance refresh can clear obsolete advisory fields', () async {
    final database = await _openDatabase();
    addTearDown(database.close);
    final store = AddonStore(TetoTvDatabase.forTesting(database));
    final original = _installed(
      _manifest(
        reportedWorking: false,
        reportedBroken: true,
        isDeprecated: true,
        lastWorkingVersion: '0.9.0',
      ),
    );
    await store.install(original);
    final client = _CatalogClient(store, {
      _ownerRepository: [_manifest()],
    });
    final controller = _controller(store, client, original, [
      _repository(_ownerRepository),
    ]);
    addTearDown(controller.dispose);

    await controller.refresh();

    for (final current in <InstalledStreamingAddon>[
      controller.state.installed.single,
      (await store.installedAddons()).single,
    ]) {
      expect(current.manifest.reportedWorking, isNull);
      expect(current.manifest.reportedBroken, isFalse);
      expect(current.manifest.isDeprecated, isFalse);
      expect(current.manifest.lastWorkingVersion, isNull);
      _expectExecutableUnchanged(current, original);
    }
  });

  test(
    'missing owner entry retains advisory and ignores same-ID foreign fallback',
    () async {
      final database = await _openDatabase();
      addTearDown(database.close);
      final store = AddonStore(TetoTvDatabase.forTesting(database));
      final original = _installed(
        _manifest(
          reportedWorking: false,
          reportedBroken: true,
          isDeprecated: true,
          lastWorkingVersion: '0.8.0',
        ),
      );
      await store.install(original);
      final foreign = _manifest(
        repositoryUrl: _foreignRepository,
        manifestUri: 'https://foreign.example/provider/manifest.json',
        payloadUri: 'https://foreign.example/provider/provider.js',
        reportedWorking: true,
        reportedBroken: false,
        isDeprecated: false,
        lastWorkingVersion: '50.0.0',
      );
      final client = _CatalogClient(store, {
        _ownerRepository: const [],
        _foreignRepository: [foreign],
      });
      final controller = _controller(store, client, original, [
        _repository(_ownerRepository),
        _repository(_foreignRepository),
      ]);
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.state.catalog.single.repositoryUrl, _foreignRepository);
      for (final current in <InstalledStreamingAddon>[
        controller.state.installed.single,
        (await store.installedAddons()).single,
      ]) {
        expect(current.manifest.repositoryUrl, _ownerRepository);
        expect(current.manifest.reportedWorking, isFalse);
        expect(current.manifest.reportedBroken, isTrue);
        expect(current.manifest.isDeprecated, isTrue);
        expect(current.manifest.lastWorkingVersion, '0.8.0');
        _expectExecutableUnchanged(current, original);
      }
    },
  );
}

const _ownerRepository = 'https://owner.example/marketplace.json';
const _foreignRepository = 'https://foreign.example/marketplace.json';

MarketplaceAddon _manifest({
  String id = 'provider.test',
  String name = 'Installed provider',
  String description = 'Installed description',
  String author = 'Installed author',
  String repositoryUrl = _ownerRepository,
  String manifestUri = 'https://owner.example/provider/manifest.json',
  String language = 'javascript',
  String type = 'onlinestream-provider',
  String locale = 'en',
  String version = '1.0.0',
  String payloadUri = 'https://owner.example/provider/provider.js',
  Map<String, String> defaults = const {
    'endpoint': 'https://api.owner.example',
  },
  bool? reportedWorking,
  bool reportedBroken = false,
  bool isDeprecated = false,
  String? lastWorkingVersion,
}) => MarketplaceAddon(
  id: id,
  name: name,
  description: description,
  author: author,
  manifestUri: Uri.parse(manifestUri),
  repositoryUrl: repositoryUrl,
  language: language,
  type: type,
  locale: locale,
  version: version,
  iconUri: Uri.parse('https://owner.example/provider/icon.png'),
  payloadUri: Uri.parse(payloadUri),
  userConfigDefaults: defaults,
  reportedWorking: reportedWorking,
  reportedBroken: reportedBroken,
  isDeprecated: isDeprecated,
  lastWorkingVersion: lastWorkingVersion,
);

InstalledStreamingAddon _installed(MarketplaceAddon manifest) =>
    InstalledStreamingAddon(
      manifest: manifest,
      payload: 'class Provider { final marker = "installed"; }',
      enabled: false,
      installedAt: DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 2),
    );

AddonRepository _repository(String url) =>
    AddonRepository(url: url, updatedAt: DateTime.utc(2026, 9, 7));

_SeededController _controller(
  AddonStore store,
  MarketplaceClient client,
  InstalledStreamingAddon installed,
  List<AddonRepository> repositories,
) => _SeededController(
  store,
  client,
  MarketplaceState(
    repositories: repositories,
    installed: [installed],
    loading: false,
  ),
);

void _expectExecutableUnchanged(
  InstalledStreamingAddon actual,
  InstalledStreamingAddon original,
) {
  expect(actual.payload, original.payload);
  expect(actual.enabled, original.enabled);
  expect(
    actual.installedAt.millisecondsSinceEpoch,
    original.installedAt.millisecondsSinceEpoch,
  );
  expect(
    actual.updatedAt.millisecondsSinceEpoch,
    original.updatedAt.millisecondsSinceEpoch,
  );
  expect(actual.manifest.id, original.manifest.id);
  expect(actual.manifest.name, original.manifest.name);
  expect(actual.manifest.description, original.manifest.description);
  expect(actual.manifest.author, original.manifest.author);
  expect(actual.manifest.manifestUri, original.manifest.manifestUri);
  expect(actual.manifest.repositoryUrl, original.manifest.repositoryUrl);
  expect(actual.manifest.language, original.manifest.language);
  expect(actual.manifest.type, original.manifest.type);
  expect(actual.manifest.locale, original.manifest.locale);
  expect(actual.manifest.version, original.manifest.version);
  expect(actual.manifest.iconUri, original.manifest.iconUri);
  expect(actual.manifest.payloadUri, original.manifest.payloadUri);
  expect(
    actual.manifest.userConfigDefaults,
    original.manifest.userConfigDefaults,
  );
}

Future<Database> _openDatabase() => databaseFactoryFfi.openDatabase(
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

class _CatalogClient extends MarketplaceClient {
  _CatalogClient(super.store, this.catalogs);

  final Map<String, List<MarketplaceAddon>> catalogs;

  @override
  Future<List<MarketplaceAddon>> catalog(
    AddonRepository repository, {
    bool refresh = false,
  }) async => catalogs[repository.url] ?? const [];

  @override
  Future<MarketplaceAddon> manifest(MarketplaceAddon summary) async => summary;
}

class _SeededController extends MarketplaceController {
  _SeededController(super.store, super.client, MarketplaceState initial) {
    state = initial;
  }
}
