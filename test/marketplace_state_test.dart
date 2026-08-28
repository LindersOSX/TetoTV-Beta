import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MarketplaceAddon manifest({
    String id = 'provider.test',
    String repositoryUrl = 'https://example.com/marketplace.json',
    String manifestUrl = 'https://example.com/manifest.json',
    String? version,
    Map<String, String> defaults = const {},
    bool? reportedWorking,
    bool reportedBroken = false,
    bool isDeprecated = false,
  }) => MarketplaceAddon(
    id: id,
    name: 'Test provider',
    description: 'Fixture',
    author: 'TetoTV tests',
    manifestUri: Uri.parse(manifestUrl),
    repositoryUrl: repositoryUrl,
    language: 'typescript',
    type: 'onlinestream-provider',
    locale: 'en',
    version: version,
    userConfigDefaults: defaults,
    reportedWorking: reportedWorking,
    reportedBroken: reportedBroken,
    isDeprecated: isDeprecated,
  );

  InstalledStreamingAddon installed({
    required MarketplaceAddon addon,
    String payload = 'export default class Provider {}',
  }) => InstalledStreamingAddon(
    manifest: addon,
    payload: payload,
    enabled: true,
    installedAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  test('marks newer provider code for an explicit update', () {
    final current = installed(addon: manifest(version: '1.0.0'));
    final state = MarketplaceState(installed: [current]);

    expect(state.updateAvailable(manifest(version: '1.1.0')), isTrue);
    expect(state.installed.single.payload, current.payload);
  });

  test('marks unresolved legacy configuration for explicit repair', () {
    final current = installed(
      addon: manifest(version: '1.0.0'),
      payload: 'const baseUrl = "{{api}}";',
    );
    final state = MarketplaceState(installed: [current]);

    expect(
      state.updateAvailable(
        manifest(version: '1.0.0', defaults: const {'api': 'https://api.test'}),
      ),
      isTrue,
    );
  });

  test('marks changed safe defaults for explicit update', () {
    final current = installed(
      addon: manifest(
        version: '1.0.0',
        defaults: const {'api': 'https://old.example'},
      ),
    );
    final state = MarketplaceState(installed: [current]);

    expect(
      state.updateAvailable(
        manifest(
          version: '1.0.0',
          defaults: const {'api': 'https://new.example'},
        ),
      ),
      isTrue,
    );
  });

  test('never treats a different repository as an installed addon update', () {
    final current = installed(addon: manifest(version: '1.0.0'));
    final spoofed = MarketplaceAddon(
      id: current.manifest.id,
      name: 'Spoofed provider',
      description: 'Fixture',
      author: 'Unknown',
      manifestUri: Uri.parse('https://untrusted.example/manifest.json'),
      repositoryUrl: 'https://untrusted.example/marketplace.json',
      language: 'javascript',
      type: 'onlinestream-provider',
      locale: 'en',
      version: '99.0.0',
    );
    final state = MarketplaceState(installed: [current]);

    expect(addonProvenanceMatches(current, spoofed), isFalse);
    expect(state.updateAvailable(spoofed), isFalse);
  });

  test('treats casing-only IDs as one same-repository identity', () {
    final current = installed(addon: manifest(version: '1.0.0'));
    final casingUpdate = MarketplaceAddon(
      id: 'PROVIDER.TEST',
      name: 'Test provider',
      description: 'Fixture',
      author: 'TetoTV tests',
      manifestUri: current.manifest.manifestUri,
      repositoryUrl: current.manifest.repositoryUrl,
      language: 'typescript',
      type: 'onlinestream-provider',
      locale: 'en',
      version: '1.1.0',
    );
    final state = MarketplaceState(installed: [current]);

    expect(state.installedById(casingUpdate.id), same(current));
    expect(addonProvenanceMatches(current, casingUpdate), isTrue);
    expect(state.updateAvailable(casingUpdate), isTrue);
  });

  test('prefers a maintained duplicate over repository URL order', () {
    final unknownOld = manifest(
      repositoryUrl: 'https://a.example/marketplace.json',
      manifestUrl: 'https://a.example/provider/manifest.json',
      version: '1.0.0',
    );
    final maintained = manifest(
      repositoryUrl: 'https://z.example/marketplace.json',
      manifestUrl: 'https://z.example/provider/manifest.json',
      version: '1.2.0',
      reportedWorking: true,
    );
    final brokenNewest = manifest(
      repositoryUrl: 'https://b.example/marketplace.json',
      manifestUrl: 'https://b.example/provider/manifest.json',
      version: '99.0.0',
      reportedBroken: true,
    );

    final selected = selectMarketplaceCatalogCandidates([
      unknownOld,
      brokenNewest,
      maintained,
    ]);

    expect(selected, hasLength(1));
    expect(selected.single.repositoryUrl, maintained.repositoryUrl);
    expect(selected.single.version, '1.2.0');
  });

  test('shares advisory status only for the identical manifest URI', () {
    final sharedManifest = manifest(
      repositoryUrl: 'https://mirror-a.example/marketplace.json',
      manifestUrl: 'https://source.example/provider/manifest.json',
      version: '1.0.0',
    );
    final brokenReport = manifest(
      repositoryUrl: 'https://mirror-b.example/marketplace.json',
      manifestUrl: 'https://source.example/provider/manifest.json',
      version: '1.0.0',
      reportedBroken: true,
    );
    final differentImplementation = manifest(
      repositoryUrl: 'https://mirror-c.example/marketplace.json',
      manifestUrl: 'https://other.example/provider/manifest.json',
      version: '0.9.0',
      reportedWorking: true,
    );

    final selected = selectMarketplaceCatalogCandidates([
      sharedManifest,
      brokenReport,
      differentImplementation,
    ]);

    expect(selected.single.manifestUri, differentImplementation.manifestUri);
    expect(selected.single.reportedWorking, isTrue);
    final sharedOnly = selectMarketplaceCatalogCandidates([
      sharedManifest,
      brokenReport,
    ]);
    expect(sharedOnly.single.reportedBroken, isTrue);
    expect(sharedOnly.single.reportedWorking, isFalse);
  });

  test('keeps installed repository provenance across duplicate catalogs', () {
    final owned = manifest(
      repositoryUrl: 'https://owned.example/marketplace.json',
      manifestUrl: 'https://owned.example/provider/manifest.json',
      version: '1.0.0',
    );
    final replacement = manifest(
      repositoryUrl: 'https://other.example/marketplace.json',
      manifestUrl: 'https://other.example/provider/manifest.json',
      version: '9.0.0',
      reportedWorking: true,
    );

    final selected = selectMarketplaceCatalogCandidates(
      [replacement, owned],
      installed: [installed(addon: owned)],
    );

    expect(selected.single.repositoryUrl, owned.repositoryUrl);
    expect(selected.single.version, '1.0.0');
  });

  test('rejects a non-public repository before persisting it', () async {
    final store = AddonStore(TetoTvDatabase.instance);
    final controller = MarketplaceController(
      store,
      MarketplaceClient(store),
      targetValidator: (_) async =>
          throw const FormatException('private target'),
    );

    final error = await controller.addRepository(
      'https://private.example/marketplace.json',
    );

    expect(error, 'The repository must resolve to a public HTTPS address.');
    expect(controller.state.repositories, isEmpty);
  });

  test(
    'blocks a cross-repository ID collision before downloading code',
    () async {
      final store = AddonStore(TetoTvDatabase.instance);
      final current = installed(addon: manifest(version: '1.0.0'));
      final client = _DownloadMustNotRunClient(store);
      final controller = _SeededMarketplaceController(
        store,
        client,
        MarketplaceState(installed: [current], loading: false),
      );
      final spoofed = MarketplaceAddon(
        id: current.manifest.id,
        name: 'Spoofed provider',
        description: 'Fixture',
        author: 'Unknown',
        manifestUri: Uri.parse('https://untrusted.example/manifest.json'),
        repositoryUrl: 'https://untrusted.example/marketplace.json',
        language: 'javascript',
        type: 'onlinestream-provider',
        locale: 'en',
      );

      await expectLater(
        controller.install(spoofed),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('already owns this provider ID'),
          ),
        ),
      );
      expect(client.downloadAttempted, isFalse);
    },
  );

  test(
    'blocks a casing-only cross-repository ID collision before download',
    () async {
      final store = AddonStore(TetoTvDatabase.instance);
      final current = installed(addon: manifest(version: '1.0.0'));
      final client = _DownloadMustNotRunClient(store);
      final controller = _SeededMarketplaceController(
        store,
        client,
        MarketplaceState(installed: [current], loading: false),
      );
      final spoofed = MarketplaceAddon(
        id: 'PROVIDER.TEST',
        name: 'Spoofed provider',
        description: 'Fixture',
        author: 'Unknown',
        manifestUri: Uri.parse('https://untrusted.example/manifest.json'),
        repositoryUrl: 'https://untrusted.example/marketplace.json',
        language: 'javascript',
        type: 'onlinestream-provider',
        locale: 'en',
      );

      await expectLater(
        controller.install(spoofed),
        throwsA(isA<FormatException>()),
      );
      expect(client.downloadAttempted, isFalse);
    },
  );

  test('compatibility checks become due at the 24 hour boundary', () {
    final lastTested = DateTime.utc(2026, 8, 22, 12);

    expect(isProviderCompatibilityTestDue(null, now: lastTested), isTrue);
    expect(
      isProviderCompatibilityTestDue(
        lastTested,
        now: lastTested.add(const Duration(hours: 23, minutes: 59)),
      ),
      isFalse,
    );
    expect(
      isProviderCompatibilityTestDue(
        lastTested,
        now: lastTested.add(providerCompatibilityTestInterval),
      ),
      isTrue,
    );
    expect(
      () => isProviderCompatibilityTestDue(
        lastTested,
        now: lastTested,
        interval: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      nextProviderCompatibilityTestDelay(const <DateTime?>[], now: lastTested),
      isNull,
    );
    expect(
      nextProviderCompatibilityTestDelay([
        lastTested,
        lastTested.add(const Duration(hours: 3)),
      ], now: lastTested.add(const Duration(hours: 23))),
      const Duration(hours: 1),
    );
    expect(
      nextProviderCompatibilityTestDelay([
        lastTested,
      ], now: lastTested.add(const Duration(hours: 25))),
      const Duration(seconds: 1),
    );
  });

  test('compatibility runner preserves a deep episode no-match', () async {
    final addon = installed(addon: manifest(id: 'provider.deep-failure'));

    final outcome = await runProviderCompatibilityTest(
      addon,
      probe: (_, episode) async {
        if (episode.anilistMediaId == 21) {
          throw StateError(
            'NO_MATCH: no episode '
            '[stage=episode_lookup; reason=empty_result]',
          );
        }
        throw StateError(
          'NO_MATCH: no title '
          '[stage=title_matching; reason=empty_result]',
        );
      },
    );

    expect(outcome.passed, isFalse);
    expect(outcome.stage, 'episode_lookup');
    expect(outcome.reason, 'empty_result');
  });

  test(
    'compatibility runner is inconclusive only for title no-matches',
    () async {
      final addon = installed(addon: manifest(id: 'provider.no-test-title'));

      final outcome = await runProviderCompatibilityTest(
        addon,
        probe: (_, _) async => throw StateError(
          'NO_MATCH: no title '
          '[stage=title_matching; reason=empty_result]',
        ),
      );

      expect(outcome.passed, isFalse);
      expect(outcome.stage, 'title_matching');
      expect(outcome.reason, 'test_title_unavailable');
    },
  );

  test('compatibility sweep tests every enabled installed provider', () async {
    final first = installed(addon: manifest(id: 'provider.one'));
    final second = installed(addon: manifest(id: 'provider.two'));
    final store = _CompatibilityStore();
    final tested = <String>[];
    final controller = _SeededMarketplaceController(
      store,
      MarketplaceClient(store),
      MarketplaceState(installed: [first, second], loading: false),
      compatibilityRunner: (addon) async {
        tested.add(addon.manifest.id);
        return const ProviderCompatibilityOutcome(
          passed: true,
          stage: 'stream_extraction',
          reason: 'compatible',
          streamCount: 2,
        );
      },
    );

    await controller.testAllInstalledProviders();

    expect(tested, ['provider.one', 'provider.two']);
    expect(store.compatibilityRecords.keys, containsAll(tested));
    expect(controller.state.testingAllProviders, isFalse);
    expect(
      controller.state.providerMessages.values,
      everyElement(contains('All 5 stages passed')),
    );
  });

  test('compatibility sweep records the exact failing stage', () async {
    final addon = installed(addon: manifest(id: 'provider.broken'));
    final store = _CompatibilityStore();
    final controller = _SeededMarketplaceController(
      store,
      MarketplaceClient(store),
      MarketplaceState(installed: [addon], loading: false),
      compatibilityRunner: (_) async => const ProviderCompatibilityOutcome(
        passed: false,
        stage: 'server_lookup',
        reason: 'http_503',
      ),
    );

    await controller.testAllInstalledProviders();

    expect(
      store.compatibilityRecords['provider.broken']?.lastTestStage,
      'server_lookup',
    );
    expect(
      controller.state.providerMessages['provider.broken'],
      contains('Server lookup failed'),
    );
  });

  test('compatibility sweep never exposes a raw runner exception', () async {
    final addon = installed(addon: manifest(id: 'provider.private-failure'));
    final store = _CompatibilityStore();
    final controller = _SeededMarketplaceController(
      store,
      MarketplaceClient(store),
      MarketplaceState(installed: [addon], loading: false),
      compatibilityRunner: (_) async => throw StateError(
        'https://private.example/episode?token=secret '
        'Private Test Query raw upstream response',
      ),
    );

    await controller.testAddon(addon);

    final status = controller.state.providerMessages[addon.manifest.id]!;
    expect(status, contains('Search failed'));
    expect(status, contains('provider reported an error'));
    expect(status, isNot(contains('private.example')));
    expect(status, isNot(contains('token')));
    expect(status, isNot(contains('Private Test Query')));
    expect(store.lastRecordedFailure, equals(status.split('• ').last));
  });

  test('unavailable test titles are recorded as inconclusive', () async {
    final addon = installed(addon: manifest(id: 'provider.inconclusive'));
    final store = _CompatibilityStore();
    final controller = _SeededMarketplaceController(
      store,
      MarketplaceClient(store),
      MarketplaceState(installed: [addon], loading: false),
      compatibilityRunner: (_) async => const ProviderCompatibilityOutcome(
        passed: false,
        stage: 'title_matching',
        reason: 'test_title_unavailable',
      ),
    );

    await controller.testAddon(addon);

    final health = controller.state.providerHealth[addon.manifest.id]!;
    expect(store.compatibilityResultCalls, 0);
    expect(store.inconclusiveCalls, 1);
    expect(health.compatibilityTests, 0);
    expect(health.compatibilityPasses, 0);
    expect(health.compatibilityScore, isNull);
    expect(health.lastTestStage, 'title_matching');
    expect(health.lastTestReason, 'test_title_unavailable');
    expect(
      controller.state.providerMessages[addon.manifest.id],
      contains('Compatibility test inconclusive'),
    );
    expect(
      controller.state.providerMessages[addon.manifest.id],
      isNot(contains('failed')),
    );
  });
}

class _DownloadMustNotRunClient extends MarketplaceClient {
  _DownloadMustNotRunClient(super.store);

  bool downloadAttempted = false;

  @override
  Future<InstalledStreamingAddon> downloadAddon(
    MarketplaceAddon summary,
  ) async {
    downloadAttempted = true;
    throw StateError('Untrusted payload was downloaded.');
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

class _CompatibilityStore extends AddonStore {
  _CompatibilityStore() : super(TetoTvDatabase.instance);

  final Map<String, ProviderHealth> compatibilityRecords = {};
  int compatibilityResultCalls = 0;
  int inconclusiveCalls = 0;
  String? lastRecordedFailure;

  @override
  Future<void> recordProviderSuccess(String id) async {}

  @override
  Future<ProviderHealth> recordProviderFailure(
    String id,
    Object error, {
    String? stage,
    String? reason,
  }) async {
    lastRecordedFailure = error.toString();
    return ProviderHealth(
      providerId: id,
      consecutiveFailures: 1,
      totalFailures: 1,
    );
  }

  @override
  Future<ProviderHealth> recordProviderCompatibilityResult(
    String id, {
    required bool passed,
    required String stage,
    required String reason,
  }) async {
    compatibilityResultCalls += 1;
    final previous = compatibilityRecords[id];
    final value = ProviderHealth(
      providerId: id,
      compatibilityTests: (previous?.compatibilityTests ?? 0) + 1,
      compatibilityPasses:
          (previous?.compatibilityPasses ?? 0) + (passed ? 1 : 0),
      lastTestedAt: DateTime.now(),
      lastTestStage: stage,
      lastTestReason: reason,
    );
    compatibilityRecords[id] = value;
    return value;
  }

  @override
  Future<ProviderHealth> recordProviderCompatibilityInconclusive(
    String id, {
    required String stage,
    required String reason,
  }) async {
    inconclusiveCalls += 1;
    final previous = compatibilityRecords[id];
    final preservesConclusiveResult = (previous?.compatibilityTests ?? 0) > 0;
    final value = ProviderHealth(
      providerId: id,
      consecutiveFailures: previous?.consecutiveFailures ?? 0,
      totalFailures: previous?.totalFailures ?? 0,
      lastSuccessAt: previous?.lastSuccessAt,
      lastFailureAt: previous?.lastFailureAt,
      lastError: previous?.lastError,
      quarantinedUntil: previous?.quarantinedUntil,
      compatibilityTests: previous?.compatibilityTests ?? 0,
      compatibilityPasses: previous?.compatibilityPasses ?? 0,
      lastTestedAt: DateTime.now(),
      lastTestStage: preservesConclusiveResult
          ? previous!.lastTestStage
          : stage,
      lastTestReason: preservesConclusiveResult
          ? previous!.lastTestReason
          : reason,
    );
    compatibilityRecords[id] = value;
    return value;
  }
}
