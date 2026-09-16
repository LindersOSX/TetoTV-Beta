// Public injection parameters deliberately stay separate from private fields.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'package:anime_tv/core/preferences/playback_audio_preference.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';

import 'package:anime_tv/features/aniyomi/data/aniyomi_gateway.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_repository_client.dart';
import 'package:anime_tv/features/aniyomi/data/aniyomi_web_provider.dart';
import 'package:anime_tv/features/aniyomi/domain/aniyomi_repository_models.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/manga/application/manga_feature_availability.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final aniyomiEnabledProvider = Provider<bool>((ref) {
  final update = ref.watch(appUpdateControllerProvider);
  return update.loaded && update.developerMode;
});

/// Aniyomi Manga requires both the feature-wide Manga gate and Aniyomi's
/// existing Developer Mode runtime. The shared Manga gate also preserves the
/// viewer's explicit opt-out.
final aniyomiMangaEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(aniyomiEnabledProvider) &&
      ref.watch(mangaFeatureAvailableProvider),
);

Future<void> _recordAniyomiDiagnostic(
  String message,
  Map<String, Object?> details,
) => TetoTvDatabase.instance.recordDiagnosticEvent(
  category: 'aniyomi-runtime',
  message: message,
  details: details,
);

final aniyomiGatewayProvider = Provider<AniyomiGateway>((ref) {
  final gateway = AniyomiGateway(
    onSchedulerDiagnostic: (details) => unawaited(
      _recordAniyomiDiagnostic('Aniyomi request scheduling event', details),
    ),
  );
  ref.listen(
    appUpdateControllerProvider.select(
      (value) => (value.loaded, value.developerMode),
    ),
    (_, next) {
      unawaited(
        gateway.configure(
          next.$1 && next.$2,
          revokeApprovals: next.$1 && !next.$2,
        ),
      );
    },
    fireImmediately: true,
  );
  ref.onDispose(gateway.dispose);
  return gateway;
});

final aniyomiControllerProvider =
    StateNotifierProvider<AniyomiController, AniyomiState>((ref) {
      final enabled = ref.watch(aniyomiEnabledProvider);
      final client = AniyomiRepositoryClient();
      final controller = AniyomiController(
        gateway: ref.watch(aniyomiGatewayProvider),
        client: client,
        storage: ref.watch(secureStorageProvider),
        mangaEnabled: () => ref.read(aniyomiMangaEnabledProvider),
        diagnosticRecorder: (details) =>
            _recordAniyomiDiagnostic('Aniyomi runtime event', details),
      );
      ref.listen(
        aniyomiMangaEnabledProvider,
        (_, next) => controller.updateMangaAvailability(next),
        fireImmediately: true,
      );
      ref.onDispose(client.dispose);
      if (enabled) scheduleMicrotask(controller.initialize);
      return controller;
    });

/// Existing Seanime aggregation stays unchanged when Developer Mode is off.
/// Reading this closure at search time also prevents stale cached execution.
final aniyomiWebProvidersLoaderProvider =
    Provider<FutureOr<List<WebStreamingProvider>> Function()>((ref) {
      final enabled = ref.watch(aniyomiEnabledProvider);
      final gateway = ref.watch(aniyomiGatewayProvider);
      final preferences = ref.watch(
        settingsPreferencesProvider.select(
          (p) => (
            p.preferredCaptionLanguage,
            p.preferredAudio,
            p.preferredAudioLanguage,
          ),
        ),
      );
      return () {
        if (!enabled || !gateway.enabled) return [];
        return _loadAniyomiWebProviders(
          controller: ref.read(aniyomiControllerProvider.notifier),
          gateway: gateway,
          preferredSubtitleLanguage: preferences.$1,
          preferredAudio: preferences.$2,
          preferredAudioLanguage: preferences.$3,
        );
      };
    });

Future<List<WebStreamingProvider>> _loadAniyomiWebProviders({
  required AniyomiController controller,
  required AniyomiGateway gateway,
  required String preferredSubtitleLanguage,
  required PlaybackAudioPreference preferredAudio,
  required String preferredAudioLanguage,
}) async {
  // A cold process can reach the episode picker before approved-source
  // discovery publishes its first result. Wake on the first usable anime
  // source instead of waiting for every sibling extension, while leaving room
  // inside the aggregator's independent 250 ms loader ceiling.
  await controller.waitForAnimeProviderSnapshot(
    maximumWait: const Duration(milliseconds: 180),
  );
  if (!gateway.enabled) return [];
  return controller.sources
      .where((source) => source.kind == AniyomiMediaKind.anime)
      .map<WebStreamingProvider>(
        (source) => AniyomiWebProvider(
          extensionId: source.extensionId,
          sourceId: source.id,
          name: source.name,
          request: gateway.request,
          startRequest: gateway.startRequest,
          preferredSubtitleLanguage: preferredSubtitleLanguage,
          preferredAudio: preferredAudio,
          preferredAudioLanguage: preferredAudioLanguage,
          onDiagnostic: (details) => unawaited(
            _recordAniyomiDiagnostic('Aniyomi provider attempt', {
              ..._aniyomiProviderIdentityDiagnostics(source),
              ...details,
            }),
          ),
        ),
      )
      .toList(growable: false);
}

Map<String, Object?> _aniyomiProviderIdentityDiagnostics(
  AniyomiRuntimeSource source,
) {
  final package = RegExp(
    r'^aniyomi:(?:anime|manga):([A-Za-z][A-Za-z0-9_.]{0,159})$',
  ).firstMatch(source.extensionId)?.group(1);
  final apiVersion =
      RegExp(r'^[0-9]+(?:\.[0-9]+)?$').hasMatch(source.apiVersion)
      ? source.apiVersion
      : 'unknown';
  final extensionVersion =
      RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$',
      ).hasMatch(source.extensionVersion)
      ? source.extensionVersion
      : 'unknown';
  final normalizedLanguage = source.language.trim().toLowerCase();
  final language =
      RegExp(r'^[a-z]{2,3}(?:-[a-z]{2})?$').hasMatch(normalizedLanguage)
      ? normalizedLanguage
      : 'unknown';
  return {
    'extension_package': package ?? 'unknown',
    'api_version': apiVersion,
    'extension_version': extensionVersion,
    if (source.extensionVersionCode >= 0)
      'extension_version_code': source.extensionVersionCode.clamp(0, 999999999),
    'source_language': language,
  };
}

class AniyomiRepositoryEntry {
  const AniyomiRepositoryEntry(this.uri, this.kind);
  final Uri uri;
  final AniyomiMediaKind kind;
  String get key => '${kind.name}:$uri';
}

class AniyomiRuntimeSource {
  const AniyomiRuntimeSource({
    required this.extensionId,
    required this.id,
    required this.name,
    required this.kind,
    required this.language,
    this.apiVersion = 'unknown',
    this.extensionVersion = 'unknown',
    this.extensionVersionCode = -1,
  });
  final String extensionId;
  final String id;
  final String name;
  final AniyomiMediaKind kind;
  final String language;
  final String apiVersion;
  final String extensionVersion;
  final int extensionVersionCode;
  String get key => '$extensionId:$id';
  Map<String, dynamic> arguments(String operation) => {
    'operation': operation,
    'extensionId': extensionId,
    'sourceId': id,
  };
}

enum AniyomiReadinessStage { installed, checking, ready, failed }

class AniyomiReadiness {
  const AniyomiReadiness(this.stage, {this.sourceCount = 0, this.failure});
  final AniyomiReadinessStage stage;
  final int sourceCount;
  final AniyomiFailure? failure;
}

class AniyomiState {
  const AniyomiState({
    this.busy = false,
    this.available = false,
    this.repositories = const [],
    this.catalog = const [],
    this.approved = const [],
    this.sources = const [],
    this.errors = const [],
    this.discovering = false,
    this.readiness = const {},
  });
  final bool busy;
  final bool available;
  final List<AniyomiRepositoryEntry> repositories;
  final List<AniyomiRepositoryExtension> catalog;
  final List<Map<String, dynamic>> approved;
  final List<AniyomiRuntimeSource> sources;
  final List<String> errors;
  final bool discovering;
  final Map<String, AniyomiReadiness> readiness;
  AniyomiState copyWith({
    bool? busy,
    bool? available,
    List<AniyomiRepositoryEntry>? repositories,
    List<AniyomiRepositoryExtension>? catalog,
    List<Map<String, dynamic>>? approved,
    List<AniyomiRuntimeSource>? sources,
    List<String>? errors,
    bool? discovering,
    Map<String, AniyomiReadiness>? readiness,
  }) => AniyomiState(
    busy: busy ?? this.busy,
    available: available ?? this.available,
    repositories: repositories ?? this.repositories,
    catalog: catalog ?? this.catalog,
    approved: approved ?? this.approved,
    sources: sources ?? this.sources,
    errors: errors ?? this.errors,
    discovering: discovering ?? this.discovering,
    readiness: readiness ?? this.readiness,
  );
}

class AniyomiController extends StateNotifier<AniyomiState> {
  List<AniyomiRuntimeSource> get sources => state.sources
      .where((source) => _allows(source.kind))
      .toList(growable: false);
  int get animeProviderSnapshotGeneration => _animeProviderSnapshotGeneration;
  AniyomiController({
    required this.gateway,
    required AniyomiRepositoryClient client,
    required FlutterSecureStorage storage,
    bool Function()? mangaEnabled,
    this.diagnosticRecorder,
  }) : _client = client,
       _storage = storage,
       _mangaEnabled = mangaEnabled ?? _mangaEnabledByDefault,
       super(const AniyomiState());
  static const _storageKey = 'aniyomi_experimental_repositories_v1';
  final AniyomiGateway gateway;
  final AniyomiRepositoryClient _client;
  final FlutterSecureStorage _storage;
  final bool Function() _mangaEnabled;
  final Future<void> Function(Map<String, Object?>)? diagnosticRecorder;
  Future<void>? _initialization;
  Future<void>? _discovery;
  int _animeProviderSnapshotGeneration = 0;
  final Map<String, _AniyomiInspectionLease> _inspectionLeases = {};
  void _check(int access) {
    if (!mounted) throw const AniyomiFailure('developer_access_revoked');
    gateway.check(access);
  }

  bool _allows(AniyomiMediaKind kind) =>
      kind != AniyomiMediaKind.manga || _mangaEnabled();

  void _checkKind(AniyomiMediaKind kind) {
    if (!_allows(kind)) throw const AniyomiFailure('manga_disabled');
  }

  /// Revokes every in-memory Manga capability without touching Anime state.
  /// Installed APK and repository metadata remain visible for safe removal.
  void updateMangaAvailability(bool enabled) {
    if (!mounted || enabled) return;
    _inspectionLeases.removeWhere(
      (_, lease) => lease.kind == AniyomiMediaKind.manga,
    );
    final mangaExtensionIds = state.approved
        .where((extension) => extension['kind'] == AniyomiMediaKind.manga.name)
        .map((extension) => extension['extensionId'])
        .whereType<String>()
        .toSet();
    state = state.copyWith(
      catalog: state.catalog
          .where((extension) => extension.kind != AniyomiMediaKind.manga)
          .toList(growable: false),
      sources: state.sources
          .where((source) => source.kind != AniyomiMediaKind.manga)
          .toList(growable: false),
      readiness: Map.of(state.readiness)
        ..removeWhere((id, _) => mangaExtensionIds.contains(id)),
    );
  }

  Future<void> initialize() => _initialization ??= _initialize();

  /// Waits only for a usable anime-provider snapshot, discovery settlement,
  /// or the caller's short budget. Native discovery itself is never cancelled
  /// by this helper and can continue publishing later sources in the
  /// background.
  Future<void> waitForAnimeProviderSnapshot({
    required Duration maximumWait,
  }) async {
    if (!gateway.enabled || !mounted || maximumWait <= Duration.zero) return;
    if (_hasAnimeProviders(state.sources)) return;

    final completed = Completer<void>();
    StreamSubscription<AniyomiState>? subscription;
    Timer? timer;
    void finish() {
      if (completed.isCompleted) return;
      timer?.cancel();
      completed.complete();
      unawaited(subscription?.cancel());
    }

    subscription = stream.listen((snapshot) {
      if (_hasAnimeProviders(snapshot.sources)) finish();
    }, onDone: finish);
    timer = Timer(maximumWait, finish);
    final initialization = initialize();
    final pending = _discovery ?? initialization;
    unawaited(
      pending.then<void>(
        (_) => finish(),
        onError: (Object _, StackTrace _) => finish(),
      ),
    );
    if (_hasAnimeProviders(state.sources)) finish();
    await completed.future;
  }

  Future<void> _initialize() async {
    if (!gateway.enabled || !mounted) return;
    final access = gateway.generation;
    try {
      final status = await gateway.call('status');
      _check(access);
      state = state.copyWith(available: status['available'] == true);
      _recordRuntimeStatus(status);
      if (!state.available) return;
      final stored = await _storage.read(key: _storageKey);
      _check(access);
      final decoded = stored == null ? [] : jsonDecode(stored);
      final repos = <AniyomiRepositoryEntry>[];
      if (decoded is List && decoded.length <= 20) {
        for (final item in decoded) {
          if (item is! Map) continue;
          final uri = safePublicHttpsUri(item['url']);
          final kind = AniyomiMediaKind.values
              .where((k) => k.name == item['kind'])
              .firstOrNull;
          if (uri != null && kind != null) {
            repos.add(AniyomiRepositoryEntry(uri, kind));
          }
        }
      }
      state = state.copyWith(repositories: repos);
      // No automatic third-party repository refresh, downloads or upgrades.
      await refreshApproved();
    } catch (_) {
      if (mounted && gateway.enabled) {
        state = state.copyWith(errors: ['initialization_failed']);
      }
    }
  }

  Future<void> addRepository(String value, AniyomiMediaKind kind) async {
    final access = gateway.generation;
    _check(access);
    _checkKind(kind);
    final uri = safePublicHttpsUri(value);
    if (uri == null || state.repositories.length >= 20) {
      throw const AniyomiFailure('invalid_repository');
    }
    if (state.repositories.any((r) => r.uri == uri && r.kind == kind)) return;
    state = state.copyWith(busy: true, errors: []);
    try {
      final catalog = await _client.catalog(
        uri,
        kind,
        check: () => _check(access),
      );
      _check(access);
      _checkKind(kind);
      final repos = [...state.repositories, AniyomiRepositoryEntry(uri, kind)];
      await _saveRepositories(repos);
      _check(access);
      _checkKind(kind);
      state = state.copyWith(
        repositories: repos,
        catalog: _uniqueCatalog([...state.catalog, ...catalog.extensions]),
      );
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> removeRepository(AniyomiRepositoryEntry repository) async {
    final access = gateway.generation;
    _check(access);
    final repos = state.repositories
        .where((r) => r.key != repository.key)
        .toList();
    await _saveRepositories(repos);
    _check(access);
    state = state.copyWith(repositories: repos, catalog: []);
  }

  Future<void> _saveRepositories(List<AniyomiRepositoryEntry> repos) =>
      _storage.write(
        key: _storageKey,
        value: jsonEncode(
          repos
              .map((r) => {'url': r.uri.toString(), 'kind': r.kind.name})
              .toList(),
        ),
      );

  List<AniyomiRepositoryExtension> _uniqueCatalog(
    List<AniyomiRepositoryExtension> catalog,
  ) {
    final seen = <String>{};
    return catalog.where((item) => seen.add(item.identityKey)).toList();
  }

  Future<void> refreshCatalog() async {
    final access = gateway.generation;
    _check(access);
    if (state.busy) return;
    state = state.copyWith(busy: true, errors: []);
    final catalog = <AniyomiRepositoryExtension>[];
    final errors = <String>[];
    try {
      for (final repo in state.repositories) {
        if (!_allows(repo.kind)) continue;
        try {
          final result = await _client.catalog(
            repo.uri,
            repo.kind,
            check: () => _check(access),
          );
          _checkKind(repo.kind);
          catalog.addAll(result.extensions);
        } catch (_) {
          if (_allows(repo.kind)) errors.add('repository_failed');
        }
        _check(access);
      }
      state = state.copyWith(
        catalog: _uniqueCatalog(
          catalog.where((extension) => _allows(extension.kind)).toList(),
        ),
        errors: errors,
      );
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  Future<Map<String, dynamic>> inspect(
    AniyomiRepositoryExtension extension,
  ) async {
    final access = gateway.generation;
    _check(access);
    _checkKind(extension.kind);
    if (state.approved.length >= 20 &&
        !state.approved.any((a) => a['extensionId'] == extension.identityKey)) {
      throw const AniyomiFailure('extension_limit_exceeded');
    }
    final inspected = await _client.inspect(extension, gateway);
    _check(access);
    _checkKind(extension.kind);
    final inspectionId = inspected['inspectionId'];
    if (inspectionId is! String ||
        _inspectionLeases.containsKey(inspectionId)) {
      throw const AniyomiFailure('inspection_expired');
    }
    _inspectionLeases[inspectionId] = _AniyomiInspectionLease(
      extensionId: extension.identityKey,
      kind: extension.kind,
    );
    return inspected;
  }

  Future<void> approve(String inspectionId) async {
    final access = gateway.generation;
    _check(access);
    final lease = _inspectionLeases.remove(inspectionId);
    if (lease == null) throw const AniyomiFailure('inspection_expired');
    _checkKind(lease.kind);
    final approved = await gateway.call('approve', {
      'inspectionId': inspectionId,
    });
    _check(access);
    _checkKind(lease.kind);
    if (approved['extensionId'] != lease.extensionId ||
        approved['kind'] != lease.kind.name) {
      throw const AniyomiFailure('identity_changed');
    }
    await refreshApproved();
  }

  Future<void> revoke(String extensionId) async {
    await gateway.call('revoke', {'extensionId': extensionId});
    await refreshApproved();
  }

  Future<void> refreshApproved() => _discover();

  /// User-requested discovery retries never download or upgrade an APK.
  Future<void> retryDiscovery(
    String extensionId, {
    required AniyomiMediaKind kind,
  }) async {
    _checkKind(kind);
    await _discover(retryId: extensionId, retryKind: kind);
  }

  Future<void> _discover({String? retryId, AniyomiMediaKind? retryKind}) {
    if (retryKind != null) _checkKind(retryKind);
    final current = _discovery;
    if (current != null) return current;
    late final Future<void> operation;
    operation = _refreshApproved(retryId: retryId, retryKind: retryKind)
        .whenComplete(() {
          if (identical(_discovery, operation)) _discovery = null;
        });
    _discovery = operation;
    return operation;
  }

  void _recordRuntimeStatus(Map<String, dynamic> status) {
    final recorder = diagnosticRecorder;
    if (recorder == null) return;
    int boundedInt(String key, {required int maximum}) {
      final value = status[key];
      return value is int && value >= 0 && value <= maximum ? value : -1;
    }

    List<String> versions(String key, Set<String> allowed) {
      final value = status[key];
      if (value is! List) return const [];
      return value.whereType<String>().where(allowed.contains).take(8).toList();
    }

    String runtimeRevision() {
      final value = status['runtimeRevision'];
      return value is String && RegExp(r'^[a-z0-9._-]{1,80}$').hasMatch(value)
          ? value
          : 'unknown';
    }

    final rawCapabilities = status['capabilities'];
    final capabilities = rawCapabilities is Map
        ? <String, bool>{
            for (final key in const [
              'currentHosterFlow',
              'lazyVideoResolution',
              'lazyHosterDeferral',
              'mangaImageRequestResolution',
              'opaqueMangaImageFetch',
              'ephemeralCookies',
              'redirects',
              'sourcePreferences',
              'javascriptEvaluation',
              'hostOwnedHlsBridge',
              'webView',
              'nativeLibraries',
            ])
              key: rawCapabilities[key] == true,
          }
        : const <String, bool>{};
    final rawResultLimits = status['resultLimits'];
    final resultLimits = rawResultLimits is Map
        ? <String, int>{
            for (final entry in const <String, int>{
              'replyBytes': 4 * 1024 * 1024,
              'httpBodyBytes': 4 * 1024 * 1024,
              'httpMetadataBytes': 16 * 1024,
              'sources': 256,
              'searchItems': 1000,
              'episodesOrChapters': 100000,
              'targetedEpisodeCandidates': 4096,
              'pages': 10000,
              'imageCapabilityCount': 4096,
              'imageCapabilityTtlSeconds': 86400,
              'imageBytes': 64 * 1024 * 1024,
              'imageConcurrentRequests': 16,
              'videos': 512,
              'tracksPerVideo': 256,
              'hosters': 1024,
              'lazyHostersPerRequest': 64,
            }.entries)
              if (rawResultLimits[entry.key] is int &&
                  (rawResultLimits[entry.key] as int) >= 0 &&
                  (rawResultLimits[entry.key] as int) <= entry.value)
                entry.key: rawResultLimits[entry.key] as int,
          }
        : const <String, int>{};

    final details = <String, Object?>{
      'event': 'runtime_status',
      'available': status['available'] == true,
      'developer_mode_enabled': status['developerModeEnabled'] == true,
      'isolated_process': status['isolatedProcess'] == true,
      'runtime': switch (status['runtime']) {
        'experimental_http_subset' => 'experimental_http_subset',
        _ => 'unknown',
      },
      'minimum_android_api': boundedInt('minimumAndroidApi', maximum: 100),
      'worker_capacity': boundedInt('maxConcurrentRequests', maximum: 8),
      'runtime_revision': runtimeRevision(),
      'anime_api_versions': versions('animeApiVersions', const {'14', '16'}),
      'manga_api_versions': versions('mangaApiVersions', const {'1.4', '1.5'}),
      'capabilities': capabilities,
      for (final entry in capabilities.entries)
        'supports_${_snakeCaseDiagnosticName(entry.key)}': entry.value,
      'result_limits': resultLimits,
      'universal_compatibility': status['universalCompatibility'] == true,
    };
    unawaited(Future<void>.sync(() => recorder(details)).catchError((_) {}));
  }

  void _recordDiscovery(
    AniyomiReadiness result, {
    required String extensionId,
    required AniyomiMediaKind kind,
    required String apiVersion,
    required String extensionVersion,
    required int extensionVersionCode,
    required int elapsedMilliseconds,
  }) {
    final recorder = diagnosticRecorder;
    if (recorder == null) return;
    final details = <String, Object?>{
      'event': 'source_discovery',
      'status': result.stage.name,
      'count': result.sourceCount,
      'kind': kind.name,
      // Package names are public extension identity metadata, not account or
      // media data. Keeping the validated package in explicit diagnostics is
      // what lets a customer report distinguish two extensions that failed at
      // the same runtime stage. Malformed/custom identities stay anonymous.
      'extension_package':
          RegExp(
            r'^aniyomi:(?:anime|manga):([A-Za-z][A-Za-z0-9_.]{0,159})$',
          ).firstMatch(extensionId)?.group(1) ??
          'unknown',
      'api_version': switch (apiVersion) {
        '14' || '16' || '1.4' || '1.5' => apiVersion,
        _ => 'unknown',
      },
      'extension_version':
          RegExp(r'^[A-Za-z0-9._+-]{1,48}$').hasMatch(extensionVersion)
          ? extensionVersion
          : 'unknown',
      'extension_version_code': extensionVersionCode.clamp(0, 0x7fffffff),
      'elapsed_ms': elapsedMilliseconds.clamp(0, 60000),
      ...?result.failure?.diagnosticFields,
    };
    unawaited(Future<void>.sync(() => recorder(details)).catchError((_) {}));
  }

  Future<void> _refreshApproved({
    String? retryId,
    AniyomiMediaKind? retryKind,
  }) async {
    final access = gateway.generation;
    _check(access);
    if (retryKind != null) _checkKind(retryKind);
    state = state.copyWith(discovering: true);
    try {
      final raw = await gateway.call('list');
      _check(access);
      final approved = aniyomiMaps(raw['extensions']).take(20).toList();
      final ids = approved
          .map((e) => e['extensionId'])
          .whereType<String>()
          .toSet();
      if (retryId != null && !ids.contains(retryId)) {
        throw const AniyomiFailure('extension_not_approved');
      }
      final sources = <AniyomiRuntimeSource>[
        if (retryId != null)
          ...state.sources.where(
            (s) =>
                s.extensionId != retryId &&
                ids.contains(s.extensionId) &&
                _allows(s.kind),
          ),
      ];
      final readiness = <String, AniyomiReadiness>{
        for (final id in ids)
          id: retryId != null && id != retryId
              ? state.readiness[id] ??
                    const AniyomiReadiness(AniyomiReadinessStage.installed)
              : const AniyomiReadiness(AniyomiReadinessStage.installed),
      };
      void publish() {
        _check(access);
        final visibleReadiness = Map.of(readiness);
        if (!_mangaEnabled()) {
          for (final extension in approved) {
            if (extension['kind'] == AniyomiMediaKind.manga.name) {
              visibleReadiness.remove(extension['extensionId']);
            }
          }
        }
        final visibleSources = sources
            .where((source) => _allows(source.kind))
            .toList(growable: false);
        if (!_sameAnimeProviderSnapshot(state.sources, visibleSources)) {
          _animeProviderSnapshotGeneration++;
        }
        state = state.copyWith(
          approved: approved,
          sources: visibleSources,
          readiness: visibleReadiness,
          errors: [
            ...state.errors.where((e) => e != 'extension_runtime_failed'),
            if (readiness.values.any(
              (r) => r.stage == AniyomiReadinessStage.failed,
            ))
              'extension_runtime_failed',
          ],
        );
      }

      publish();
      final discoverable =
          <
            ({
              String id,
              AniyomiMediaKind kind,
              String apiVersion,
              String extensionVersion,
              int extensionVersionCode,
            })
          >[];
      for (final extension in approved) {
        final id = extension['extensionId'];
        final kind = AniyomiMediaKind.values
            .where((k) => k.name == extension['kind'])
            .firstOrNull;
        if (id is! String ||
            kind == null ||
            !_allows(kind) ||
            (retryId != null && id != retryId)) {
          continue;
        }
        discoverable.add((
          id: id,
          kind: kind,
          apiVersion: extension['apiVersion'] is String
              ? extension['apiVersion'] as String
              : 'unknown',
          extensionVersion: extension['versionName'] is String
              ? extension['versionName'] as String
              : 'unknown',
          extensionVersionCode: extension['versionCode'] is int
              ? extension['versionCode'] as int
              : -1,
        ));
        readiness[id] = const AniyomiReadiness(AniyomiReadinessStage.checking);
      }
      publish();

      Future<void> discoverExtension(
        ({
          String id,
          AniyomiMediaKind kind,
          String apiVersion,
          String extensionVersion,
          int extensionVersionCode,
        })
        extension,
      ) async {
        final id = extension.id;
        final kind = extension.kind;
        final stopwatch = Stopwatch()..start();
        try {
          final data = await gateway.request({
            'operation': 'sources',
            'extensionId': id,
          });
          _check(access);
          if (!_allows(kind)) {
            readiness.remove(id);
            publish();
            return;
          }
          final discovered = <AniyomiRuntimeSource>[];
          for (final item in aniyomiMaps(data['sources']).take(64)) {
            if (item['id'] is! String || item['name'] is! String) continue;
            discovered.add(
              AniyomiRuntimeSource(
                extensionId: id,
                id: item['id'] as String,
                name: item['name'] as String,
                kind: kind,
                language: item['lang'] as String? ?? '',
                apiVersion: extension.apiVersion,
                extensionVersion: extension.extensionVersion,
                extensionVersionCode: extension.extensionVersionCode,
              ),
            );
          }
          if (discovered.isEmpty) throw const AniyomiFailure('no_sources');
          sources.addAll(discovered);
          readiness[id] = AniyomiReadiness(
            AniyomiReadinessStage.ready,
            sourceCount: discovered.length,
          );
        } catch (error) {
          _check(access);
          readiness[id] = AniyomiReadiness(
            AniyomiReadinessStage.failed,
            failure: error is AniyomiFailure
                ? error
                : const AniyomiFailure('extension_execution_failed'),
          );
        }
        _check(access);
        _recordDiscovery(
          readiness[id]!,
          extensionId: id,
          kind: kind,
          apiVersion: extension.apiVersion,
          extensionVersion: extension.extensionVersion,
          extensionVersionCode: extension.extensionVersionCode,
          elapsedMilliseconds: stopwatch.elapsedMilliseconds,
        );
        publish();
      }

      // API 29+ uses independently isolated worker instances. Run discovery
      // in small batches so one broken extension cannot hold every other
      // provider behind its deadline. The gateway retains a capacity of one
      // on Android 8/9 and safely queues these calls there.
      const discoveryBatchSize = 3;
      for (
        var start = 0;
        start < discoverable.length;
        start += discoveryBatchSize
      ) {
        final end = (start + discoveryBatchSize)
            .clamp(0, discoverable.length)
            .toInt();
        await Future.wait(
          discoverable.sublist(start, end).map(discoverExtension),
        );
      }
    } finally {
      if (mounted) {
        if (access == gateway.generation && gateway.enabled) {
          state = state.copyWith(discovering: false);
        } else {
          if (state.sources.any(
            (source) => source.kind == AniyomiMediaKind.anime,
          )) {
            _animeProviderSnapshotGeneration++;
          }
          state = state.copyWith(
            discovering: false,
            approved: [],
            sources: [],
            readiness: {},
          );
        }
      }
    }
  }
}

bool _sameAnimeProviderSnapshot(
  List<AniyomiRuntimeSource> left,
  List<AniyomiRuntimeSource> right,
) {
  final leftAnime = left
      .where((source) => source.kind == AniyomiMediaKind.anime)
      .toList(growable: false);
  final rightAnime = right
      .where((source) => source.kind == AniyomiMediaKind.anime)
      .toList(growable: false);
  if (leftAnime.length != rightAnime.length) return false;
  for (var index = 0; index < leftAnime.length; index++) {
    final oldSource = leftAnime[index];
    final newSource = rightAnime[index];
    if (oldSource.extensionId != newSource.extensionId ||
        oldSource.id != newSource.id ||
        oldSource.name != newSource.name ||
        oldSource.language != newSource.language ||
        oldSource.apiVersion != newSource.apiVersion ||
        oldSource.extensionVersion != newSource.extensionVersion ||
        oldSource.extensionVersionCode != newSource.extensionVersionCode) {
      return false;
    }
  }
  return true;
}

bool _hasAnimeProviders(List<AniyomiRuntimeSource> sources) =>
    sources.any((source) => source.kind == AniyomiMediaKind.anime);

String _snakeCaseDiagnosticName(String value) => value
    .replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (match) => '${match[1]}_${match[2]}',
    )
    .toLowerCase();

bool _mangaEnabledByDefault() => true;

class _AniyomiInspectionLease {
  const _AniyomiInspectionLease({
    required this.extensionId,
    required this.kind,
  });

  final String extensionId;
  final AniyomiMediaKind kind;
}

List<Map<String, dynamic>> aniyomiMaps(Object? raw) => raw is List
    ? raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
    : [];
