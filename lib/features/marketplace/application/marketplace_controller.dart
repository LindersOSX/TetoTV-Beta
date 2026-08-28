import 'dart:async';

import 'package:anime_tv/core/storage/storage_providers.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/marketplace_client.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final addonStoreProvider = Provider<AddonStore>(
  (ref) => AddonStore(ref.watch(tetoTvDatabaseProvider)),
);

final marketplaceClientProvider = Provider<MarketplaceClient>(
  (ref) => MarketplaceClient(ref.watch(addonStoreProvider)),
);

class MarketplaceState {
  const MarketplaceState({
    this.repositories = const [],
    this.catalog = const [],
    this.installed = const [],
    this.repositoryErrors = const {},
    this.providerHealth = const {},
    this.providerMessages = const {},
    this.loading = true,
    this.testingAllProviders = false,
    this.busyAddonId,
  });

  final List<AddonRepository> repositories;
  final List<MarketplaceAddon> catalog;
  final List<InstalledStreamingAddon> installed;
  final Map<String, String> repositoryErrors;
  final Map<String, ProviderHealth> providerHealth;
  final Map<String, String> providerMessages;
  final bool loading;
  final bool testingAllProviders;
  final String? busyAddonId;

  MarketplaceState copyWith({
    List<AddonRepository>? repositories,
    List<MarketplaceAddon>? catalog,
    List<InstalledStreamingAddon>? installed,
    Map<String, String>? repositoryErrors,
    Map<String, ProviderHealth>? providerHealth,
    Map<String, String>? providerMessages,
    bool? loading,
    bool? testingAllProviders,
    String? busyAddonId,
    bool clearBusyAddon = false,
  }) => MarketplaceState(
    repositories: repositories ?? this.repositories,
    catalog: catalog ?? this.catalog,
    installed: installed ?? this.installed,
    repositoryErrors: repositoryErrors ?? this.repositoryErrors,
    providerHealth: providerHealth ?? this.providerHealth,
    providerMessages: providerMessages ?? this.providerMessages,
    loading: loading ?? this.loading,
    testingAllProviders: testingAllProviders ?? this.testingAllProviders,
    busyAddonId: clearBusyAddon ? null : busyAddonId ?? this.busyAddonId,
  );

  InstalledStreamingAddon? installedById(String id) {
    for (final addon in installed) {
      if (marketplaceAddonIdsMatch(addon.manifest.id, id)) return addon;
    }
    return null;
  }

  bool updateAvailable(MarketplaceAddon addon) {
    final current = installedById(addon.id);
    return current != null &&
        addonProvenanceMatches(current, addon) &&
        _installedAddonNeedsRefresh(current, addon);
  }
}

final class MarketplaceImportSnapshot {
  const MarketplaceImportSnapshot._(this.repositories, this.state);

  final List<AddonRepository> repositories;
  final MarketplaceState state;
}

final marketplaceControllerProvider =
    StateNotifierProvider<MarketplaceController, MarketplaceState>((ref) {
      final controller = MarketplaceController(
        ref.watch(addonStoreProvider),
        ref.watch(marketplaceClientProvider),
        scheduleCompatibilityTests: true,
      );
      Future.microtask(controller.load);
      return controller;
    });

const providerCompatibilityTestInterval = Duration(hours: 24);
const _minimumCompatibilityTestDelay = Duration(seconds: 1);

bool isProviderCompatibilityTestDue(
  DateTime? lastTestedAt, {
  required DateTime now,
  Duration interval = providerCompatibilityTestInterval,
}) {
  if (interval <= Duration.zero) {
    throw ArgumentError.value(interval, 'interval', 'Must be positive.');
  }
  return lastTestedAt == null || !lastTestedAt.add(interval).isAfter(now);
}

Duration? nextProviderCompatibilityTestDelay(
  Iterable<DateTime?> lastTestedAt, {
  required DateTime now,
  Duration interval = providerCompatibilityTestInterval,
  Duration minimumDelay = _minimumCompatibilityTestDelay,
}) {
  if (interval <= Duration.zero) {
    throw ArgumentError.value(interval, 'interval', 'Must be positive.');
  }
  if (minimumDelay <= Duration.zero) {
    throw ArgumentError.value(
      minimumDelay,
      'minimumDelay',
      'Must be positive.',
    );
  }
  DateTime? earliestDueAt;
  for (final testedAt in lastTestedAt) {
    final dueAt = testedAt?.add(interval) ?? now;
    if (earliestDueAt == null || dueAt.isBefore(earliestDueAt)) {
      earliestDueAt = dueAt;
    }
  }
  if (earliestDueAt == null) return null;
  final delay = earliestDueAt.difference(now);
  return delay <= Duration.zero ? minimumDelay : delay;
}

class MarketplaceController extends StateNotifier<MarketplaceState> {
  MarketplaceController(
    this._store,
    this._client, {
    Future<void> Function(Uri uri)? targetValidator,
    ProviderCompatibilityRunner? compatibilityRunner,
    bool scheduleCompatibilityTests = false,
    Duration compatibilityTestInterval = providerCompatibilityTestInterval,
  }) : _targetValidator = targetValidator ?? validatePublicNetworkTarget,
       _compatibilityRunner =
           compatibilityRunner ?? runProviderCompatibilityTest,
       _scheduleCompatibilityTests = scheduleCompatibilityTests,
       _compatibilityTestInterval = compatibilityTestInterval,
       super(const MarketplaceState()) {
    if (scheduleCompatibilityTests &&
        compatibilityTestInterval <= Duration.zero) {
      throw ArgumentError.value(
        compatibilityTestInterval,
        'compatibilityTestInterval',
        'Must be positive.',
      );
    }
  }

  final AddonStore _store;
  final MarketplaceClient _client;
  final Future<void> Function(Uri uri) _targetValidator;
  final ProviderCompatibilityRunner _compatibilityRunner;
  final bool _scheduleCompatibilityTests;
  final Duration _compatibilityTestInterval;
  Timer? _compatibilityTestTimer;
  bool _compatibilitySweepRunning = false;

  void _rescheduleCompatibilityTests() {
    _compatibilityTestTimer?.cancel();
    _compatibilityTestTimer = null;
    if (!_scheduleCompatibilityTests || !mounted) return;
    final enabledProviders = state.installed.where((addon) => addon.enabled);
    final delay = nextProviderCompatibilityTestDelay(
      enabledProviders.map(
        (addon) => state.providerHealth[addon.manifest.id]?.lastTestedAt,
      ),
      now: DateTime.now(),
      interval: _compatibilityTestInterval,
    );
    if (delay == null) return;
    _compatibilityTestTimer = Timer(delay, () {
      _compatibilityTestTimer = null;
      if (mounted) {
        unawaited(testAllInstalledProviders(onlyDue: true));
      }
    });
  }

  @override
  void dispose() {
    _compatibilityTestTimer?.cancel();
    _compatibilityTestTimer = null;
    super.dispose();
  }

  Future<void> load() async {
    try {
      final repositories = await _store.repositories();
      final installed = await _store.installedAddons();
      final health = await _store.providerHealth();
      state = state.copyWith(
        repositories: repositories,
        installed: installed,
        providerHealth: health,
        loading: true,
      );
      await refresh(refreshNetwork: false);
      unawaited(testAllInstalledProviders(onlyDue: true));
    } catch (error) {
      state = state.copyWith(
        loading: false,
        repositoryErrors: {'local': _message(error)},
      );
      _rescheduleCompatibilityTests();
    }
  }

  Future<void> refresh({bool refreshNetwork = true}) async {
    state = state.copyWith(loading: true);
    final enabled = state.repositories.where((item) => item.enabled).toList();
    final results = await Future.wait(
      enabled.map((repository) async {
        try {
          final addons = await _client.catalog(
            repository,
            refresh: refreshNetwork,
          );
          return (
            repository: repository,
            addons: addons,
            error: null as String?,
          );
        } catch (error) {
          return (
            repository: repository,
            addons: const <MarketplaceAddon>[],
            error: _message(error),
          );
        }
      }),
    );
    final variants = <MarketplaceAddon>[];
    final errors = <String, String>{};
    for (final result in results) {
      if (result.error != null) errors[result.repository.url] = result.error!;
      variants.addAll(result.addons);
    }
    var catalog = selectMarketplaceCatalogCandidates(
      variants,
      installed: state.installed,
    )..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final installedIds = state.installed
        .map((addon) => marketplaceAddonIdentityKey(addon.manifest.id))
        .toSet();
    if (installedIds.isNotEmpty) {
      catalog = await Future.wait(
        catalog.map((addon) async {
          if (!installedIds.contains(marketplaceAddonIdentityKey(addon.id))) {
            return addon;
          }
          try {
            return await _client.manifest(addon);
          } catch (_) {
            return addon;
          }
        }),
      );
    }

    // Catalog refresh is read-only for installed executable add-ons. Replacing
    // third-party code always remains an explicit Install/Update action so a
    // compromised repository cannot silently change an enabled provider.
    state = state.copyWith(
      catalog: catalog,
      repositoryErrors: errors,
      loading: false,
    );
  }

  Future<String?> addRepository(
    String rawUrl, {
    bool refreshAfterAdd = true,
  }) async {
    final uri = safePublicHttpsUri(rawUrl);
    if (uri == null) return 'Enter a public HTTPS repository URL.';
    final normalized = uri.removeFragment().toString();
    if (state.repositories.any((item) => item.url == normalized)) {
      return 'That repository is already added.';
    }
    if (state.repositories.length >= 32) {
      return 'Remove a repository before adding another (maximum 32).';
    }
    try {
      await _targetValidator(uri);
    } catch (_) {
      return 'The repository must resolve to a public HTTPS address.';
    }
    final repository = AddonRepository(
      url: normalized,
      updatedAt: DateTime.now(),
    );
    await _store.saveRepository(repository);
    state = state.copyWith(repositories: [...state.repositories, repository]);
    if (refreshAfterAdd) await refresh();
    return null;
  }

  Future<MarketplaceImportSnapshot> snapshotForImport() async {
    return MarketplaceImportSnapshot._(
      List<AddonRepository>.unmodifiable(await _store.repositories()),
      state,
    );
  }

  Future<void> restoreImportSnapshot(MarketplaceImportSnapshot snapshot) async {
    try {
      await _store.replaceRepositories(snapshot.repositories);
    } finally {
      if (mounted) {
        state = snapshot.state;
        _rescheduleCompatibilityTests();
      }
    }
  }

  Future<BulkSourceAddResult> addRepositories(String input) async {
    final candidates = splitSourceUrlInput(input);
    if (candidates.isEmpty) {
      return const BulkSourceAddResult(
        added: 0,
        duplicates: 0,
        rejected: ['Enter at least one public HTTPS repository URL.'],
      );
    }
    var added = 0;
    var duplicates = 0;
    final rejected = <String>[];
    for (final candidate in candidates) {
      final error = await addRepository(candidate, refreshAfterAdd: false);
      if (error == null) {
        added++;
      } else if (error.contains('already added')) {
        duplicates++;
      } else {
        rejected.add(error);
      }
    }
    if (added > 0) await refresh();
    return BulkSourceAddResult(
      added: added,
      duplicates: duplicates,
      rejected: List.unmodifiable(rejected),
    );
  }

  Future<void> setRepositoryEnabled(
    AddonRepository repository,
    bool enabled,
  ) async {
    final next = repository.copyWith(
      enabled: enabled,
      updatedAt: DateTime.now(),
    );
    await _store.saveRepository(next);
    state = state.copyWith(
      repositories: [
        for (final item in state.repositories)
          if (item.url == repository.url) next else item,
      ],
    );
    await refresh(refreshNetwork: false);
  }

  Future<void> removeRepository(AddonRepository repository) async {
    await _store.removeRepository(repository.url);
    state = state.copyWith(
      repositories: state.repositories
          .where((item) => item.url != repository.url)
          .toList(),
    );
    await refresh(refreshNetwork: false);
  }

  Future<void> install(MarketplaceAddon addon) async {
    if (!addon.isCompatible) {
      throw const FormatException('This provider runtime is not supported.');
    }
    final previous = state.installedById(addon.id);
    if (previous != null && !addonProvenanceMatches(previous, addon)) {
      throw const FormatException(
        'Another repository already owns this provider ID. Uninstall it '
        'before installing code from a different repository.',
      );
    }
    state = state.copyWith(busyAddonId: addon.id);
    try {
      final downloaded = await _client.downloadAddon(addon);
      if (previous != null &&
          !addonProvenanceMatches(previous, downloaded.manifest)) {
        throw const FormatException(
          'Another repository already owns this provider ID. Uninstall it '
          'before installing code from a different repository.',
        );
      }
      final installed = InstalledStreamingAddon(
        manifest: downloaded.manifest,
        payload: downloaded.payload,
        enabled: previous?.enabled ?? true,
        installedAt: previous?.installedAt ?? downloaded.installedAt,
        updatedAt: DateTime.now(),
      );
      await _store.install(installed);
      final executableChanged =
          previous != null &&
          (previous.manifest.version != installed.manifest.version ||
              previous.payload != installed.payload);
      if (executableChanged) {
        // Runtime incompatibility and circuit-breaker state belong to the
        // exact executable version. Never leave an updated provider blocked
        // by failures recorded against its previous payload.
        await _store.clearProviderHealth(installed.manifest.id);
      }
      state = state.copyWith(
        installed: [
          ...state.installed.where(
            (item) => !marketplaceAddonIdsMatch(item.manifest.id, addon.id),
          ),
          installed,
        ]..sort((a, b) => a.manifest.name.compareTo(b.manifest.name)),
        clearBusyAddon: true,
      );
      _rescheduleCompatibilityTests();
    } catch (_) {
      state = state.copyWith(clearBusyAddon: true);
      rethrow;
    }
  }

  Future<void> setAddonEnabled(String id, bool enabled) async {
    final storedId = state.installedById(id)?.manifest.id ?? id;
    await _store.setEnabled(storedId, enabled);
    if (enabled) await _store.clearProviderHealth(storedId);
    state = state.copyWith(
      installed: [
        for (final item in state.installed)
          if (marketplaceAddonIdsMatch(item.manifest.id, id))
            item.copyWith(enabled: enabled)
          else
            item,
      ],
      providerHealth: enabled
          ? ({...state.providerHealth}..remove(storedId))
          : state.providerHealth,
    );
    _rescheduleCompatibilityTests();
  }

  Future<void> testAddon(InstalledStreamingAddon addon) async {
    _compatibilityTestTimer?.cancel();
    _compatibilityTestTimer = null;
    try {
      await _testAddon(addon);
    } finally {
      _rescheduleCompatibilityTests();
    }
  }

  Future<void> testAllInstalledProviders({bool onlyDue = false}) async {
    if (_compatibilitySweepRunning) return;
    final now = DateTime.now();
    final providers = state.installed
        .where((addon) {
          if (!addon.enabled) return false;
          if (!onlyDue) return true;
          final lastTested =
              state.providerHealth[addon.manifest.id]?.lastTestedAt;
          return isProviderCompatibilityTestDue(lastTested, now: now);
        })
        .toList(growable: false);
    if (providers.isEmpty) {
      _rescheduleCompatibilityTests();
      return;
    }
    _compatibilityTestTimer?.cancel();
    _compatibilityTestTimer = null;
    _compatibilitySweepRunning = true;
    state = state.copyWith(testingAllProviders: true);
    try {
      for (final addon in providers) {
        if (!mounted) return;
        await _testAddon(addon);
      }
    } finally {
      _compatibilitySweepRunning = false;
      if (mounted) {
        state = state.copyWith(
          testingAllProviders: false,
          clearBusyAddon: true,
        );
        _rescheduleCompatibilityTests();
      }
    }
  }

  Future<void> _testAddon(InstalledStreamingAddon addon) async {
    final id = addon.manifest.id;
    state = state.copyWith(
      busyAddonId: id,
      providerMessages: {...state.providerMessages, id: 'Testing provider…'},
    );
    try {
      final outcome = await _compatibilityRunner(addon);
      if (!outcome.passed) throw _ProviderCompatibilityFailure(outcome);
      await _store.recordProviderSuccess(id);
      final health = await _store.recordProviderCompatibilityResult(
        id,
        passed: true,
        stage: 'stream_extraction',
        reason: 'compatible',
      );
      state = state.copyWith(
        providerHealth: {...state.providerHealth, id: health},
        providerMessages: {
          ...state.providerMessages,
          id:
              'All 5 stages passed • ${outcome.streamCount} playable test '
              'stream(s)',
        },
        clearBusyAddon: true,
      );
    } catch (error) {
      final outcome = error is _ProviderCompatibilityFailure
          ? error.outcome
          : _compatibilityFailureFrom(error);
      if (outcome.reason == 'test_title_unavailable') {
        final health = await _store.recordProviderCompatibilityInconclusive(
          id,
          stage: outcome.stage,
          reason: outcome.reason,
        );
        state = state.copyWith(
          providerHealth: {...state.providerHealth, id: health},
          providerMessages: {
            ...state.providerMessages,
            id:
                'Compatibility test inconclusive • '
                '${compatibilityStageLabel(outcome.stage)} could not find '
                'either built-in test title',
          },
          clearBusyAddon: true,
        );
        return;
      }
      // Never persist or display the compatibility runner's raw exception.
      // Third-party failures can contain the probe title, request URLs,
      // credentials, or response fragments. Rebuild the message exclusively
      // from the bounded stage/reason outcome produced above.
      final safeFailure = _ProviderCompatibilityFailure(outcome);
      final safeMessage = seanimeProviderFailureMessage(safeFailure);
      await _store.recordProviderFailure(
        id,
        safeMessage,
        stage: outcome.stage,
        reason: outcome.reason,
      );
      final health = await _store.recordProviderCompatibilityResult(
        id,
        passed: false,
        stage: outcome.stage,
        reason: outcome.reason,
      );
      state = state.copyWith(
        providerHealth: {...state.providerHealth, id: health},
        providerMessages: {
          ...state.providerMessages,
          id:
              '${compatibilityStageLabel(outcome.stage)} failed • '
              '$safeMessage',
        },
        clearBusyAddon: true,
      );
    }
  }

  Future<void> resetAddonHealth(String id) async {
    await _store.clearProviderHealth(id);
    final messages = {...state.providerMessages}..remove(id);
    final health = {...state.providerHealth}..remove(id);
    state = state.copyWith(providerHealth: health, providerMessages: messages);
    _rescheduleCompatibilityTests();
  }

  Future<void> uninstall(String id) async {
    final storedId = state.installedById(id)?.manifest.id ?? id;
    await _store.uninstall(storedId);
    await _store.clearProviderHealth(storedId);
    state = state.copyWith(
      installed: state.installed
          .where((item) => !marketplaceAddonIdsMatch(item.manifest.id, id))
          .toList(),
    );
    _rescheduleCompatibilityTests();
  }
}

class ProviderCompatibilityOutcome {
  const ProviderCompatibilityOutcome({
    required this.passed,
    required this.stage,
    required this.reason,
    this.streamCount = 0,
  });

  final bool passed;
  final String stage;
  final String reason;
  final int streamCount;
}

const _compatibilityEpisodes = [
  EpisodeReference(
    anilistMediaId: 21,
    malMediaId: 21,
    title: 'One Piece',
    titleEnglish: 'One Piece',
    titleRomaji: 'One Piece',
    year: 1999,
    status: 'RELEASING',
    format: 'TV',
    episode: 1,
  ),
  EpisodeReference(
    anilistMediaId: 5114,
    malMediaId: 5114,
    title: 'Fullmetal Alchemist: Brotherhood',
    titleEnglish: 'Fullmetal Alchemist: Brotherhood',
    titleRomaji: 'Hagane no Renkinjutsushi: Fullmetal Alchemist',
    alternativeTitles: ['Hagane no Renkinjutsushi Fullmetal Alchemist'],
    year: 2009,
    status: 'FINISHED',
    format: 'TV',
    episodeCount: 64,
    episode: 1,
  ),
];

typedef ProviderCompatibilityRunner =
    Future<ProviderCompatibilityOutcome> Function(
      InstalledStreamingAddon addon,
    );

typedef ProviderCompatibilityProbe =
    Future<List<WebStreamResult>> Function(
      InstalledStreamingAddon addon,
      EpisodeReference episode,
    );

Future<ProviderCompatibilityOutcome> runProviderCompatibilityTest(
  InstalledStreamingAddon addon, {
  ProviderCompatibilityProbe? probe,
}) async {
  final provider = SeanimeJavascriptProvider(addon);
  ProviderCompatibilityOutcome? deepestNoMatch;
  var titleUnavailableCount = 0;
  for (final episode in _compatibilityEpisodes) {
    try {
      final streams = await (probe == null
          ? provider.streams(episode)
          : probe(addon, episode));
      if (streams.isNotEmpty) {
        return ProviderCompatibilityOutcome(
          passed: true,
          stage: 'stream_extraction',
          reason: 'compatible',
          streamCount: streams.length,
        );
      }
      deepestNoMatch = _deeperCompatibilityFailure(
        deepestNoMatch,
        const ProviderCompatibilityOutcome(
          passed: false,
          stage: 'stream_extraction',
          reason: 'empty_result',
        ),
      );
    } catch (error) {
      if (isSeanimeProviderNoMatch(error)) {
        final failure = _compatibilityFailureFrom(error);
        if (failure.stage == 'title_matching') {
          titleUnavailableCount += 1;
        } else {
          deepestNoMatch = _deeperCompatibilityFailure(deepestNoMatch, failure);
        }
        continue;
      }
      return _compatibilityFailureFrom(error);
    }
  }
  if (deepestNoMatch != null) return deepestNoMatch;
  if (titleUnavailableCount != _compatibilityEpisodes.length) {
    return const ProviderCompatibilityOutcome(
      passed: false,
      stage: 'search',
      reason: 'provider_error',
    );
  }
  return const ProviderCompatibilityOutcome(
    passed: false,
    stage: 'title_matching',
    reason: 'test_title_unavailable',
  );
}

ProviderCompatibilityOutcome _deeperCompatibilityFailure(
  ProviderCompatibilityOutcome? current,
  ProviderCompatibilityOutcome candidate,
) {
  const depth = {
    'search': 0,
    'title_matching': 1,
    'episode_lookup': 2,
    'server_lookup': 3,
    'stream_extraction': 4,
  };
  if (current == null ||
      (depth[candidate.stage] ?? -1) > (depth[current.stage] ?? -1)) {
    return candidate;
  }
  return current;
}

ProviderCompatibilityOutcome _compatibilityFailureFrom(Object error) {
  final details = seanimeProviderFailureDetails(error);
  final stage = switch (details?.stage) {
    'title_matching' => 'title_matching',
    'episode_lookup' || 'episodes' => 'episode_lookup',
    'server_lookup' || 'server' => 'server_lookup',
    'stream_extraction' => 'stream_extraction',
    _ => 'search',
  };
  return ProviderCompatibilityOutcome(
    passed: false,
    stage: stage,
    reason: details?.reason ?? 'provider_error',
  );
}

String compatibilityStageLabel(String? stage) => switch (stage) {
  'search' => 'Search',
  'title_matching' => 'Title matching',
  'episode_lookup' => 'Episode lookup',
  'server_lookup' => 'Server lookup',
  'stream_extraction' => 'Stream extraction',
  _ => 'Provider runtime',
};

class _ProviderCompatibilityFailure implements Exception {
  const _ProviderCompatibilityFailure(this.outcome);

  final ProviderCompatibilityOutcome outcome;

  @override
  String toString() =>
      'NO_STREAM: Compatibility test failed. '
      '[stage=${outcome.stage}; reason=${outcome.reason}]';
}

/// Selects one visible candidate for each extension ID without allowing a
/// second repository to silently replace installed executable code.
///
/// For an installed provider, its original repository always wins. For a new
/// provider, advisory catalog status and version metadata avoid an older or
/// explicitly broken duplicate shadowing a maintained entry merely because
/// its repository URL sorted first. The explicit install confirmation and
/// same-provenance update guard remain the executable trust boundary.
List<MarketplaceAddon> selectMarketplaceCatalogCandidates(
  Iterable<MarketplaceAddon> variants, {
  Iterable<InstalledStreamingAddon> installed = const [],
}) {
  final groups = <String, List<MarketplaceAddon>>{};
  for (final addon in variants) {
    groups
        .putIfAbsent(marketplaceAddonIdentityKey(addon.id), () => [])
        .add(addon);
  }
  final installedById = <String, InstalledStreamingAddon>{
    for (final addon in installed)
      marketplaceAddonIdentityKey(addon.manifest.id): addon,
  };
  final selected = <MarketplaceAddon>[];
  for (final entry in groups.entries) {
    final candidates = _mergeSharedManifestStatus(entry.value);
    final current = installedById[entry.key];
    MarketplaceAddon? sameOwner;
    if (current != null) {
      for (final candidate in candidates) {
        if (addonProvenanceMatches(current, candidate)) {
          sameOwner = candidate;
          break;
        }
      }
    }
    if (sameOwner != null) {
      selected.add(sameOwner);
      continue;
    }
    candidates.sort(_compareCatalogCandidates);
    selected.add(candidates.first);
  }
  return selected;
}

List<MarketplaceAddon> _mergeSharedManifestStatus(
  List<MarketplaceAddon> candidates,
) {
  return [
    for (final candidate in candidates)
      () {
        final peers = candidates.where(
          (other) => other.manifestUri == candidate.manifestUri,
        );
        final broken = peers.any((other) => other.reportedBroken);
        final deprecated = peers.any((other) => other.isDeprecated);
        final reports = peers
            .map((other) => other.reportedWorking)
            .whereType<bool>()
            .toList(growable: false);
        final working = broken
            ? false
            : reports.contains(true)
            ? true
            : reports.contains(false)
            ? false
            : null;
        final lastWorking = peers
            .map((other) => other.lastWorkingVersion)
            .whereType<String>()
            .fold<String?>(
              null,
              (best, value) => best == null || _compareVersions(value, best) > 0
                  ? value
                  : best,
            );
        return candidate.withCatalogStatus(
          reportedWorking: working,
          reportedBroken: broken,
          isDeprecated: deprecated,
          lastWorkingVersion: lastWorking,
        );
      }(),
  ];
}

int _compareCatalogCandidates(MarketplaceAddon left, MarketplaceAddon right) {
  int statusRank(MarketplaceAddon addon) {
    if (addon.isDeprecated) return 4;
    if (addon.reportedBroken) return 3;
    if (addon.reportedWorking == false) return 2;
    if (addon.reportedWorking == null) return 1;
    return 0;
  }

  final status = statusRank(left).compareTo(statusRank(right));
  if (status != 0) return status;
  final version = _compareVersions(right.version ?? '0', left.version ?? '0');
  if (version != 0) return version;
  final manifest = left.manifestUri.toString().compareTo(
    right.manifestUri.toString(),
  );
  if (manifest != 0) return manifest;
  return left.repositoryUrl.compareTo(right.repositoryUrl);
}

/// An add-on ID alone is not a trusted update identity. A second repository
/// may legitimately or maliciously reuse it, so executable replacement is
/// allowed only from the repository the user originally installed.
bool addonProvenanceMatches(
  InstalledStreamingAddon installed,
  MarketplaceAddon candidate,
) =>
    marketplaceAddonIdsMatch(installed.manifest.id, candidate.id) &&
    installed.manifest.repositoryUrl == candidate.repositoryUrl;

bool _installedAddonNeedsRefresh(
  InstalledStreamingAddon installed,
  MarketplaceAddon available,
) {
  final unresolvedConfig = RegExp(
    r'\{\{[A-Za-z0-9._-]+\}\}',
  ).hasMatch(installed.payload);
  final versionChanged =
      available.version != null &&
      (installed.manifest.version == null ||
          _compareVersions(available.version!, installed.manifest.version!) >
              0);
  final defaultsChanged = !_sameStringMap(
    installed.manifest.userConfigDefaults,
    available.userConfigDefaults,
  );
  return unresolvedConfig || versionChanged || defaultsChanged;
}

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

int _compareVersions(String left, String right) {
  List<int> numbers(String value) => RegExp(r'\d+')
      .allMatches(value)
      .take(4)
      .map((match) => int.tryParse(match.group(0)!) ?? 0)
      .toList();
  final a = numbers(left);
  final b = numbers(right);
  for (var index = 0; index < 4; index++) {
    final av = index < a.length ? a[index] : 0;
    final bv = index < b.length ? b[index] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

String _message(Object error) {
  return seanimeProviderFailureMessage(error);
}
