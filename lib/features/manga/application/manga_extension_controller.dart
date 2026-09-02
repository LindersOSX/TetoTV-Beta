import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/data/addon_store.dart';
import 'package:anime_tv/features/marketplace/data/seanime_javascript_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const int maximumMangaExtensionSearchResults = 480;
const int maximumConcurrentMangaExtensionProviders = 3;

final mangaExtensionIdentityStoreProvider =
    Provider<MangaExtensionIdentityStore>(
      (ref) => ProtectedMangaExtensionIdentityStore(
        ref.watch(secureStorageProvider),
      ),
    );

final mangaExtensionControllerProvider =
    StateNotifierProvider<MangaExtensionController, MangaExtensionState>((ref) {
      final controller = MangaExtensionController(
        addonStore: ref.watch(addonStoreProvider),
        mangaStore: ref.watch(mangaStoreProvider),
        identityStore: ref.watch(mangaExtensionIdentityStoreProvider),
        ownerKey: () => ref.read(mangaOwnerKeyProvider.future),
      );
      controller.syncInstalled(
        ref.read(marketplaceControllerProvider).installed,
      );
      ref.listen<MarketplaceState>(marketplaceControllerProvider, (_, next) {
        controller.syncInstalled(next.installed);
      });
      return controller;
    });

@immutable
class MangaExtensionState {
  MangaExtensionState({
    Iterable<InstalledStreamingAddon> providers =
        const <InstalledStreamingAddon>[],
    Iterable<MangaExtensionTitle> results = const <MangaExtensionTitle>[],
    Map<String, String> failures = const <String, String>{},
    this.query = '',
    this.selectedProviderId,
    this.searching = false,
    this.error,
  }) : providers = List<InstalledStreamingAddon>.unmodifiable(providers),
       results = List<MangaExtensionTitle>.unmodifiable(results),
       failures = Map<String, String>.unmodifiable(failures);

  final List<InstalledStreamingAddon> providers;
  final List<MangaExtensionTitle> results;
  final Map<String, String> failures;
  final String query;
  final String? selectedProviderId;
  final bool searching;
  final String? error;

  List<InstalledStreamingAddon> get enabledProviders => providers
      .where((addon) => addon.enabled && addon.manifest.isMangaProvider)
      .toList(growable: false);

  MangaExtensionState copyWith({
    Iterable<InstalledStreamingAddon>? providers,
    Iterable<MangaExtensionTitle>? results,
    Map<String, String>? failures,
    String? query,
    String? selectedProviderId,
    bool clearSelectedProvider = false,
    bool? searching,
    String? error,
    bool clearError = false,
  }) => MangaExtensionState(
    providers: providers ?? this.providers,
    results: results ?? this.results,
    failures: failures ?? this.failures,
    query: query ?? this.query,
    selectedProviderId: clearSelectedProvider
        ? null
        : selectedProviderId ?? this.selectedProviderId,
    searching: searching ?? this.searching,
    error: clearError ? null : error ?? this.error,
  );
}

abstract interface class MangaExtensionIdentityStore {
  Future<void> write({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String mangaId,
  });

  Future<String?> read({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  });

  Future<void> delete({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  });
}

class ProtectedMangaExtensionIdentityStore
    implements MangaExtensionIdentityStore {
  const ProtectedMangaExtensionIdentityStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<void> write({
    required String ownerKey,
    required String sourceId,
    required String entryId,
    required String mangaId,
  }) async {
    final normalized = _boundedExtensionValue(mangaId, 2048);
    await _storage.write(
      key: _key(ownerKey: ownerKey, sourceId: sourceId, entryId: entryId),
      value: normalized,
    );
  }

  @override
  Future<String?> read({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) async {
    final value = await _storage.read(
      key: _key(ownerKey: ownerKey, sourceId: sourceId, entryId: entryId),
    );
    if (value == null) return null;
    try {
      return _boundedExtensionValue(value, 2048);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> delete({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) => _storage.delete(
    key: _key(ownerKey: ownerKey, sourceId: sourceId, entryId: entryId),
  );

  String _key({
    required String ownerKey,
    required String sourceId,
    required String entryId,
  }) =>
      'manga_extension_identity_v1_${_digest('$ownerKey\n$sourceId\n$entryId')}';
}

class MangaExtensionController extends StateNotifier<MangaExtensionState> {
  MangaExtensionController({
    required AddonStore addonStore,
    required MangaStore mangaStore,
    required MangaExtensionIdentityStore identityStore,
    required Future<String> Function() ownerKey,
  }) : this._(addonStore, mangaStore, identityStore, ownerKey);

  MangaExtensionController._(
    this._addonStore,
    this._mangaStore,
    this._identityStore,
    this._ownerKey,
  ) : super(MangaExtensionState());

  final AddonStore _addonStore;
  final MangaStore _mangaStore;
  final MangaExtensionIdentityStore _identityStore;
  final Future<String> Function() _ownerKey;
  WebProviderCancellation? _searchCancellation;
  int _generation = 0;

  void syncInstalled(Iterable<InstalledStreamingAddon> installed) {
    final providers =
        installed
            .where((addon) => addon.manifest.isMangaProvider)
            .toList(growable: false)
          ..sort(
            (left, right) {
              final byName = left.manifest.name.toLowerCase().compareTo(
                right.manifest.name.toLowerCase(),
              );
              return byName != 0
                  ? byName
                  : marketplaceAddonIdentityKey(left.manifest.id).compareTo(
                      marketplaceAddonIdentityKey(right.manifest.id),
                    );
            },
          );
    final inventoryChanged = !_sameMangaProviderInventory(
      state.providers,
      providers,
    );
    if (inventoryChanged) {
      _searchCancellation?.cancel();
      _searchCancellation = null;
      _generation++;
    }
    final selected = state.selectedProviderId;
    final retainsSelection =
        selected == null ||
        providers.any(
          (addon) => marketplaceAddonIdsMatch(addon.manifest.id, selected),
        );
    state = state.copyWith(
      providers: providers,
      clearSelectedProvider: !retainsSelection,
      results: inventoryChanged || !retainsSelection
          ? const <MangaExtensionTitle>[]
          : null,
      failures: inventoryChanged ? const <String, String>{} : null,
      searching: inventoryChanged ? false : null,
      clearError: inventoryChanged,
    );
  }

  void selectProvider(String? providerId) {
    final normalized = providerId?.trim();
    if (normalized != null &&
        !state.providers.any(
          (addon) =>
              addon.enabled &&
              marketplaceAddonIdsMatch(addon.manifest.id, normalized),
        )) {
      return;
    }
    _searchCancellation?.cancel();
    _searchCancellation = null;
    _generation++;
    state = state.copyWith(
      selectedProviderId: normalized,
      clearSelectedProvider: normalized == null,
      results: const <MangaExtensionTitle>[],
      failures: const <String, String>{},
      query: '',
      searching: false,
      clearError: true,
    );
  }

  Future<bool> search(String value) async {
    final query = value.trim();
    _searchCancellation?.cancel();
    _searchCancellation = null;
    final generation = ++_generation;
    if (query.length < 2 || query.length > 240) {
      state = state.copyWith(
        error: 'Enter at least 2 characters to search manga.',
        searching: false,
      );
      return false;
    }
    final cancellation = WebProviderCancellation();
    _searchCancellation = cancellation;
    final selected = state.selectedProviderId;
    var providers = state.enabledProviders
        .where((addon) {
          return selected == null ||
              marketplaceAddonIdsMatch(addon.manifest.id, selected);
        })
        .toList(growable: false);
    if (providers.isEmpty) {
      state = state.copyWith(
        query: query,
        results: const <MangaExtensionTitle>[],
        failures: const <String, String>{},
        error: 'Install and enable a manga extension first.',
        searching: false,
      );
      if (identical(_searchCancellation, cancellation)) {
        _searchCancellation = null;
      }
      return false;
    }

    Map<String, ProviderHealth> health;
    try {
      health = await _addonStore.providerHealth();
    } catch (_) {
      // Provider health is only an ordering hint. A local bookkeeping failure
      // must not escape from the UI's intentionally unawaited search action.
      health = const <String, ProviderHealth>{};
    }
    if (generation != _generation || cancellation.isCancelled) return false;
    providers = _orderMangaProviders(providers, health);
    state = state.copyWith(
      query: query,
      results: const <MangaExtensionTitle>[],
      failures: const <String, String>{},
      searching: true,
      clearError: true,
    );
    var next = 0;
    final seen = <String>{};

    Future<void> worker() async {
      while (!cancellation.isCancelled && next < providers.length) {
        final addon = providers[next++];
        final provider = SeanimeJavascriptMangaProvider(addon);
        try {
          final results = await provider.search(
            query,
            cancellation: cancellation,
          );
          if (cancellation.isCancelled || generation != _generation) return;
          await _recordHealthyResponse(_mangaHealthId(addon.manifest.id));
          if (cancellation.isCancelled || generation != _generation) return;
          final merged = List<MangaExtensionTitle>.of(state.results);
          for (final item in results) {
            if (merged.length >= maximumMangaExtensionSearchResults) break;
            final key = _digest('${item.providerId}\n${item.id}');
            if (seen.add(key)) merged.add(item);
          }
          state = state.copyWith(results: merged);
        } on WebProviderSearchCancelled {
          return;
        } catch (_) {
          if (cancellation.isCancelled || generation != _generation) return;
          await _recordFailure(addon, stage: 'search');
          if (cancellation.isCancelled || generation != _generation) return;
          state = state.copyWith(
            failures: <String, String>{
              ...state.failures,
              addon.manifest.id:
                  '${addon.manifest.name} could not complete this search.',
            },
          );
        }
      }
    }

    final workers = min(
      maximumConcurrentMangaExtensionProviders,
      providers.length,
    );
    await Future.wait(<Future<void>>[
      for (var index = 0; index < workers; index++) worker(),
    ]);
    if (generation != _generation || cancellation.isCancelled) return false;
    if (identical(_searchCancellation, cancellation)) {
      _searchCancellation = null;
    }
    state = state.copyWith(
      searching: false,
      error: state.results.isEmpty && state.failures.isNotEmpty
          ? 'No installed manga source completed that search.'
          : null,
      clearError: state.results.isNotEmpty || state.failures.isEmpty,
    );
    return state.results.isNotEmpty;
  }

  Future<List<MangaExtensionChapter>> chapters(
    MangaExtensionTitle title,
  ) async {
    final addon = _enabledProvider(title.providerId);
    if (addon == null) {
      throw StateError('That manga source is not installed or enabled.');
    }
    try {
      final chapters = await SeanimeJavascriptMangaProvider(
        addon,
      ).findChapters(title.id);
      await _recordHealthyResponse(_mangaHealthId(addon.manifest.id));
      return chapters;
    } catch (_) {
      await _recordFailure(addon, stage: 'chapter_lookup');
      throw StateError('That manga source could not load its chapters.');
    }
  }

  Future<MangaReaderRequest> buildReaderRequest(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter,
  ) async {
    final addon = _enabledProvider(title.providerId);
    if (addon == null) {
      throw StateError('That manga source is not installed or enabled.');
    }
    try {
      final pages = await SeanimeJavascriptMangaProvider(
        addon,
      ).findChapterPages(chapter.id);
      if (pages.isEmpty) {
        throw StateError('This chapter did not return any readable pages.');
      }
      final sourceId = mangaExtensionSourceId(addon.manifest.id);
      final entryId = mangaExtensionEntryId(title.providerId, title.id);
      final chapterKey = mangaExtensionChapterId(
        title.providerId,
        title.id,
        chapter.id,
      );
      final owner = await _ownerKey();
      final progress = await _mangaStore.progress(
        ownerKey: owner,
        sourceId: sourceId,
        entryId: entryId,
      );
      final initialPage =
          progress != null &&
              progress.chapterId == chapterKey &&
              progress.pageIndex >= 0 &&
              progress.pageIndex < pages.length
          ? progress.pageIndex
          : 0;
      await _recordSuccess(_mangaHealthId(addon.manifest.id));
      return MangaReaderRequest(
        sourceId: sourceId,
        publicationId: entryId,
        chapterId: chapterKey,
        seriesTitle: title.title,
        chapterTitle: chapter.title,
        chapterNumber: chapter.chapterNumber,
        initialPageIndex: initialPage,
        pages: <MangaReaderPage>[
          for (var index = 0; index < pages.length; index++)
            MangaReaderPage(
              id: 'page.${_digest('${pages[index].uri}\n$index').substring(0, 32)}',
              index: index,
              resource: MangaRemotePageResource(
                uri: pages[index].uri,
                headers: pages[index].headers,
              ),
            ),
        ],
      );
    } catch (error) {
      await _recordFailure(addon, stage: 'page_resolution');
      if (error is StateError) rethrow;
      throw StateError('That manga source could not load this chapter.');
    }
  }

  Future<bool> isInLibrary(MangaExtensionTitle title) async {
    final owner = await _ownerKey();
    return await _mangaStore.libraryEntry(
          ownerKey: owner,
          sourceId: mangaExtensionSourceId(title.providerId),
          entryId: mangaExtensionEntryId(title.providerId, title.id),
        ) !=
        null;
  }

  Future<bool> toggleLibrary(MangaExtensionTitle title) async {
    final owner = await _ownerKey();
    final sourceId = mangaExtensionSourceId(title.providerId);
    final entryId = mangaExtensionEntryId(title.providerId, title.id);
    final existing = await _mangaStore.libraryEntry(
      ownerKey: owner,
      sourceId: sourceId,
      entryId: entryId,
    );
    if (existing != null) {
      await _mangaStore.deleteLibraryEntry(
        ownerKey: owner,
        sourceId: sourceId,
        entryId: entryId,
      );
      await _identityStore.delete(
        ownerKey: owner,
        sourceId: sourceId,
        entryId: entryId,
      );
      return false;
    }
    await _identityStore.write(
      ownerKey: owner,
      sourceId: sourceId,
      entryId: entryId,
      mangaId: title.id,
    );
    try {
      await _mangaStore.upsertLibraryEntry(
        MangaLibraryEntry(
          ownerKey: owner,
          sourceId: sourceId,
          entryId: entryId,
          title: title.title,
          coverUri: _persistableExtensionCover(title),
          metadata: <String, Object?>{
            'kind': 'seanime-manga-extension',
            'providerId': title.providerId,
            'providerName': title.providerName,
            'language': title.language,
            if (title.year != null) 'year': title.year,
            if (title.synonyms.isNotEmpty)
              'synonyms': title.synonyms.take(32).toList(growable: false),
          },
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } catch (_) {
      await _identityStore.delete(
        ownerKey: owner,
        sourceId: sourceId,
        entryId: entryId,
      );
      rethrow;
    }
    return true;
  }

  bool isExtensionLibraryEntry(MangaLibraryEntry entry) =>
      entry.metadata['kind'] == 'seanime-manga-extension';

  Future<MangaExtensionTitle?> openLibraryEntry(MangaLibraryEntry entry) async {
    if (!isExtensionLibraryEntry(entry)) return null;
    final providerId = entry.metadata['providerId'];
    if (providerId is! String || _enabledProvider(providerId) == null) {
      throw StateError('Enable this manga extension to open the title.');
    }
    final owner = await _ownerKey();
    final mangaId = await _identityStore.read(
      ownerKey: owner,
      sourceId: entry.sourceId,
      entryId: entry.entryId,
    );
    if (mangaId == null) {
      throw StateError(
        'This saved manga is missing its protected source identity. Add it again.',
      );
    }
    final synonyms = entry.metadata['synonyms'];
    return MangaExtensionTitle(
      providerId: providerId,
      providerName: entry.metadata['providerName'] as String? ?? providerId,
      language: entry.metadata['language'] as String? ?? 'unknown',
      id: mangaId,
      title: entry.title,
      synonyms: synonyms is List
          ? synonyms.whereType<String>().take(32)
          : const <String>[],
      year: entry.metadata['year'] is int
          ? entry.metadata['year']! as int
          : null,
      image: entry.coverUri,
    );
  }

  InstalledStreamingAddon? _enabledProvider(String id) {
    for (final addon in state.providers) {
      if (addon.enabled && marketplaceAddonIdsMatch(addon.manifest.id, id)) {
        return addon;
      }
    }
    return null;
  }

  Future<void> _recordFailure(
    InstalledStreamingAddon addon, {
    required String stage,
  }) async {
    try {
      await _addonStore.recordProviderFailure(
        _mangaHealthId(addon.manifest.id),
        'Manga provider failed',
        stage: stage,
        reason: 'provider_error',
      );
    } catch (_) {
      // Health persistence is advisory and must not mask the bounded provider
      // error that the controller is already returning to the UI.
    }
  }

  Future<void> _recordHealthyResponse(String id) async {
    try {
      await _addonStore.recordProviderHealthyResponse(id);
    } catch (_) {
      // See [_recordFailure].
    }
  }

  Future<void> _recordSuccess(String id) async {
    try {
      await _addonStore.recordProviderSuccess(id);
    } catch (_) {
      // See [_recordFailure].
    }
  }

  @override
  void dispose() {
    _searchCancellation?.cancel();
    _searchCancellation = null;
    _generation++;
    super.dispose();
  }
}

bool _sameMangaProviderInventory(
  List<InstalledStreamingAddon> left,
  List<InstalledStreamingAddon> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final current = left[index];
    final next = right[index];
    if (!marketplaceAddonIdsMatch(current.manifest.id, next.manifest.id) ||
        current.enabled != next.enabled ||
        current.manifest.version != next.manifest.version ||
        current.manifest.language != next.manifest.language ||
        current.manifest.locale != next.manifest.locale ||
        current.payload != next.payload) {
      return false;
    }
  }
  return true;
}

List<InstalledStreamingAddon> _orderMangaProviders(
  List<InstalledStreamingAddon> providers,
  Map<String, ProviderHealth> health,
) {
  final indexed = providers.indexed
      .map((entry) => (index: entry.$1, addon: entry.$2))
      .toList();
  indexed.sort((left, right) {
    final leftHealth = health[_mangaHealthId(left.addon.manifest.id)];
    final rightHealth = health[_mangaHealthId(right.addon.manifest.id)];
    final leftGood = leftHealth?.lastSuccessAt;
    final rightGood = rightHealth?.lastSuccessAt;
    if (leftGood != null || rightGood != null) {
      if (leftGood == null) return 1;
      if (rightGood == null) return -1;
      final recent = rightGood.compareTo(leftGood);
      if (recent != 0) return recent;
    }
    final failures = (leftHealth?.consecutiveFailures ?? 0).compareTo(
      rightHealth?.consecutiveFailures ?? 0,
    );
    return failures != 0 ? failures : left.index.compareTo(right.index);
  });
  return indexed.map((entry) => entry.addon).toList(growable: false);
}

String mangaExtensionSourceId(String providerId) =>
    'extension.${_digest(marketplaceAddonIdentityKey(providerId)).substring(0, 40)}';

String mangaExtensionEntryId(String providerId, String mangaId) =>
    'publication.${_digest('${marketplaceAddonIdentityKey(providerId)}\n$mangaId').substring(0, 40)}';

String mangaExtensionChapterId(
  String providerId,
  String mangaId,
  String chapterId,
) =>
    'chapter.${_digest('${marketplaceAddonIdentityKey(providerId)}\n$mangaId\n$chapterId').substring(0, 40)}';

String _mangaHealthId(String providerId) =>
    'manga:${marketplaceAddonIdentityKey(providerId)}';

Uri? _persistableExtensionCover(MangaExtensionTitle title) {
  if (title.image == null || title.imageHeaders.isNotEmpty) return null;
  try {
    return requireMangaPersistablePublicHttpsUri(
      title.image.toString(),
      field: 'Manga extension cover URL',
    );
  } on FormatException {
    return null;
  }
}

String _boundedExtensionValue(String value, int maximum) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximum ||
      normalized.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
    throw const FormatException('Manga extension identity is invalid.');
  }
  return normalized;
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
