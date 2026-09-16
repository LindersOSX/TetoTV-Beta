import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/manga/application/manga_feature_availability.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/data/manga_acquisition_service.dart';
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
const int maximumMangaLibraryUpdateBatch = 100;

typedef MangaLibraryUpdateSummary = ({
  int checked,
  int failed,
  int newChapters,
  int remaining,
});

/// Numeric chapter order when unambiguous; otherwise preserve source order so
/// prologues, extras and scanlator variants are not silently renumbered.
List<MangaExtensionChapter> orderedMangaChapters(
  Iterable<MangaExtensionChapter> chapters,
) {
  final result = chapters.toList(growable: false);
  if (result.every((item) => item.chapterNumber != null) &&
      result.map((item) => item.chapterNumber).toSet().length ==
          result.length) {
    result.sort((a, b) => a.chapterNumber!.compareTo(b.chapterNumber!));
  } else {
    result.sort((a, b) => a.index.compareTo(b.index));
  }
  return result;
}

String mangaExtensionDownloadJobId(
  String sourceId,
  String entryId,
  String chapterId,
) => 'manga.${_digest('$sourceId\n$entryId\n$chapterId').substring(0, 48)}';

final mangaExtensionIdentityStoreProvider =
    Provider<MangaExtensionIdentityStore>(
      (ref) => ProtectedMangaExtensionIdentityStore(
        ref.watch(secureStorageProvider),
      ),
    );

final mangaExtensionControllerProvider =
    StateNotifierProvider<MangaExtensionController, MangaExtensionState>((ref) {
      final owner = ref.watch(mangaOwnerKeyProvider.future);
      final featureAvailable = ref.read(mangaFeatureAvailableProvider);
      final controller = MangaExtensionController(
        addonStore: ref.watch(addonStoreProvider),
        mangaStore: ref.watch(mangaStoreProvider),
        identityStore: ref.watch(mangaExtensionIdentityStoreProvider),
        ownerKey: () => owner,
        updateCursorStorage: ref.watch(secureStorageProvider),
        featureAvailable: featureAvailable,
      );
      if (featureAvailable) {
        controller.syncInstalled(
          ref.read(marketplaceControllerProvider).installed,
        );
      }
      ref.listen<MarketplaceState>(marketplaceControllerProvider, (_, next) {
        controller.syncInstalled(next.installed);
      });
      ref.listen<bool>(mangaFeatureAvailableProvider, (_, available) {
        controller.setFeatureAvailable(available);
        if (available) {
          controller.syncInstalled(
            ref.read(marketplaceControllerProvider).installed,
          );
        }
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
    FlutterSecureStorage? updateCursorStorage,
    bool featureAvailable = true,
  }) : this._(
         addonStore,
         mangaStore,
         identityStore,
         ownerKey,
         updateCursorStorage ?? const FlutterSecureStorage(),
         featureAvailable,
       );

  MangaExtensionController._(
    this._addonStore,
    this._mangaStore,
    this._identityStore,
    this._ownerKey,
    this._updateCursorStorage,
    this._featureAvailable,
  ) : super(MangaExtensionState());

  final AddonStore _addonStore;
  final MangaStore _mangaStore;
  final MangaExtensionIdentityStore _identityStore;
  final Future<String> Function() _ownerKey;
  final FlutterSecureStorage _updateCursorStorage;
  Future<MangaLibraryUpdateSummary>? _libraryUpdateInFlight;
  WebProviderCancellation? _libraryUpdateCancellation;
  WebProviderCancellation? _searchCancellation;
  final Set<WebProviderCancellation> _activeRemoteCancellations = {};
  int _generation = 0;
  int _featureGeneration = 0;
  bool _featureAvailable;

  /// Revokes every in-memory/provider capability while retaining the durable
  /// library, progress, downloads, repository configuration and preferences.
  void setFeatureAvailable(bool available) {
    if (!mounted || _featureAvailable == available) return;
    _featureAvailable = available;
    _featureGeneration++;
    _generation++;
    _searchCancellation?.cancel();
    _libraryUpdateCancellation?.cancel();
    for (final cancellation in _activeRemoteCancellations.toList()) {
      cancellation.cancel();
    }
    _searchCancellation = null;
    _libraryUpdateCancellation = null;
    _libraryUpdateInFlight = null;
    if (!available) state = MangaExtensionState();
  }

  int _beginFeatureOperation() {
    _requireFeature();
    return _featureGeneration;
  }

  void _requireFeature([int? featureGeneration]) {
    if (!mounted ||
        !_featureAvailable ||
        (featureGeneration != null &&
            featureGeneration != _featureGeneration)) {
      throw StateError('Manga reader is disabled in Settings.');
    }
  }

  bool _isCurrentFeature(int featureGeneration) =>
      mounted && _featureAvailable && featureGeneration == _featureGeneration;

  bool _isCurrentSearch(
    int generation,
    int featureGeneration,
    WebProviderCancellation cancellation,
  ) =>
      _isCurrentFeature(featureGeneration) &&
      generation == _generation &&
      !cancellation.isCancelled;

  void syncInstalled(Iterable<InstalledStreamingAddon> installed) {
    if (!_featureAvailable) return;
    final providers =
        installed
            .where((addon) => addon.manifest.isMangaProvider)
            .toList(growable: false)
          ..sort((left, right) {
            final byName = left.manifest.name.toLowerCase().compareTo(
              right.manifest.name.toLowerCase(),
            );
            return byName != 0
                ? byName
                : marketplaceAddonIdentityKey(
                    left.manifest.id,
                  ).compareTo(marketplaceAddonIdentityKey(right.manifest.id));
          });
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
    if (!_featureAvailable) return;
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
    if (!_featureAvailable) return false;
    final featureGeneration = _beginFeatureOperation();
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
    if (!_isCurrentSearch(generation, featureGeneration, cancellation)) {
      return false;
    }
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
      while (_isCurrentSearch(generation, featureGeneration, cancellation) &&
          next < providers.length) {
        final addon = providers[next++];
        final provider = SeanimeJavascriptMangaProvider(addon);
        try {
          final results = await provider.search(
            query,
            cancellation: cancellation,
          );
          if (!_isCurrentSearch(generation, featureGeneration, cancellation)) {
            return;
          }
          await _recordHealthyResponse(_mangaHealthId(addon.manifest.id));
          if (!_isCurrentSearch(generation, featureGeneration, cancellation)) {
            return;
          }
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
          if (!_isCurrentSearch(generation, featureGeneration, cancellation)) {
            return;
          }
          await _recordFailure(addon, stage: 'search');
          if (!_isCurrentSearch(generation, featureGeneration, cancellation)) {
            return;
          }
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
    if (!_isCurrentSearch(generation, featureGeneration, cancellation)) {
      return false;
    }
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
    MangaExtensionTitle title, {
    String? expectedOwnerKey,
    WebProviderCancellation? cancellation,
  }) async {
    final featureGeneration = _beginFeatureOperation();
    final operationCancellation = cancellation ?? WebProviderCancellation();
    _activeRemoteCancellations.add(operationCancellation);
    final owner = expectedOwnerKey ?? await _ownerKey();
    await _requireUpdateOwner(owner, featureGeneration: featureGeneration);
    operationCancellation.throwIfCancelled();
    final addon = _enabledProvider(title.providerId);
    if (addon == null) {
      _activeRemoteCancellations.remove(operationCancellation);
      throw StateError('That manga source is not installed or enabled.');
    }
    try {
      final chapters = orderedMangaChapters(
        await SeanimeJavascriptMangaProvider(
          addon,
        ).findChapters(title.id, cancellation: operationCancellation),
      );
      operationCancellation.throwIfCancelled();
      await _requireUpdateOwner(owner, featureGeneration: featureGeneration);
      final sourceId = mangaExtensionSourceId(title.providerId);
      final entryId = mangaExtensionEntryId(title.providerId, title.id);
      if (await _mangaStore.libraryEntry(
            ownerKey: owner,
            sourceId: sourceId,
            entryId: entryId,
          ) !=
          null) {
        operationCancellation.throwIfCancelled();
        await _requireUpdateOwner(owner, featureGeneration: featureGeneration);
        await _mangaStore.replaceChapterSnapshot(
          ownerKey: owner,
          sourceId: sourceId,
          entryId: entryId,
          checkedAt: DateTime.now().toUtc(),
          chapters: [
            for (var i = 0; i < chapters.length; i++)
              MangaChapterSnapshot(
                chapterId: mangaExtensionChapterId(
                  title.providerId,
                  title.id,
                  chapters[i].id,
                ),
                title: chapters[i].title,
                ordinal: i,
                chapterNumber: chapters[i].chapterNumber,
                publishedAt: chapters[i].updatedAt,
              ),
          ],
        );
        await _requireUpdateOwner(owner, featureGeneration: featureGeneration);
      }
      await _recordHealthyResponse(_mangaHealthId(addon.manifest.id));
      await _requireUpdateOwner(owner, featureGeneration: featureGeneration);
      return chapters;
    } on WebProviderSearchCancelled {
      _requireFeature(featureGeneration);
      rethrow;
    } catch (error) {
      _requireFeature(featureGeneration);
      await _recordFailure(addon, stage: 'chapter_lookup');
      _requireFeature(featureGeneration);
      if (error is StateError &&
          error.message == 'Manga reader is disabled in Settings.') {
        rethrow;
      }
      throw StateError('That manga source could not load its chapters.');
    } finally {
      _activeRemoteCancellations.remove(operationCancellation);
    }
  }

  Future<MangaReaderRequest> buildReaderRequest(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter, {
    List<MangaExtensionChapter>? chapterList,
  }) async {
    final featureGeneration = _beginFeatureOperation();
    final cancellation = WebProviderCancellation();
    _activeRemoteCancellations.add(cancellation);
    final addon = _enabledProvider(title.providerId);
    if (addon == null) {
      _activeRemoteCancellations.remove(cancellation);
      throw StateError('That manga source is not installed or enabled.');
    }
    try {
      final pages = await SeanimeJavascriptMangaProvider(
        addon,
      ).findChapterPages(chapter.id, cancellation: cancellation);
      cancellation.throwIfCancelled();
      _requireFeature(featureGeneration);
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
      _requireFeature(featureGeneration);
      final progress = await _mangaStore.chapterProgress(
        ownerKey: owner,
        sourceId: sourceId,
        entryId: entryId,
        chapterId: chapterKey,
      );
      _requireFeature(featureGeneration);
      final initialPage =
          progress != null &&
              progress.chapterId == chapterKey &&
              progress.pageIndex >= 0 &&
              progress.pageIndex < pages.length
          ? progress.pageIndex
          : 0;
      await _recordSuccess(_mangaHealthId(addon.manifest.id));
      _requireFeature(featureGeneration);
      final ordered = chapterList == null
          ? null
          : orderedMangaChapters(chapterList);
      final chapterIndex =
          ordered?.indexWhere((item) => item.id == chapter.id) ?? -1;
      return MangaReaderRequest(
        ownerKey: owner,
        sourceId: sourceId,
        publicationId: entryId,
        chapterId: chapterKey,
        seriesTitle: title.title,
        coverUri: _persistableExtensionCover(title),
        chapterTitle: chapter.title,
        chapterNumber: chapter.chapterNumber,
        initialPageIndex: initialPage,
        initialPageOffset: progress?.pageIndex == initialPage
            ? progress!.pageOffset
            : 0,
        resolvePreviousChapter: ordered != null && chapterIndex > 0
            ? () => buildReaderRequest(
                title,
                ordered[chapterIndex - 1],
                chapterList: ordered,
              )
            : null,
        resolveNextChapter:
            ordered != null &&
                chapterIndex >= 0 &&
                chapterIndex + 1 < ordered.length
            ? () => buildReaderRequest(
                title,
                ordered[chapterIndex + 1],
                chapterList: ordered,
              )
            : null,
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
    } on WebProviderSearchCancelled {
      _requireFeature(featureGeneration);
      rethrow;
    } catch (error) {
      _requireFeature(featureGeneration);
      await _recordFailure(addon, stage: 'page_resolution');
      _requireFeature(featureGeneration);
      if (error is StateError) rethrow;
      throw StateError('That manga source could not load this chapter.');
    } finally {
      _activeRemoteCancellations.remove(cancellation);
    }
  }

  Future<bool> isInLibrary(MangaExtensionTitle title) async {
    final featureGeneration = _beginFeatureOperation();
    final owner = await _ownerKey();
    _requireFeature(featureGeneration);
    final entry = await _mangaStore.libraryEntry(
      ownerKey: owner,
      sourceId: mangaExtensionSourceId(title.providerId),
      entryId: mangaExtensionEntryId(title.providerId, title.id),
    );
    _requireFeature(featureGeneration);
    return entry != null;
  }

  Future<bool> toggleLibrary(MangaExtensionTitle title) async {
    final featureGeneration = _beginFeatureOperation();
    final owner = await _ownerKey();
    _requireFeature(featureGeneration);
    final sourceId = mangaExtensionSourceId(title.providerId);
    final entryId = mangaExtensionEntryId(title.providerId, title.id);
    final existing = await _mangaStore.libraryEntry(
      ownerKey: owner,
      sourceId: sourceId,
      entryId: entryId,
    );
    _requireFeature(featureGeneration);
    if (existing != null) {
      await _mangaStore.deleteLibraryEntry(
        ownerKey: owner,
        sourceId: sourceId,
        entryId: entryId,
      );
      try {
        _requireFeature(featureGeneration);
        await _identityStore.delete(
          ownerKey: owner,
          sourceId: sourceId,
          entryId: entryId,
        );
        _requireFeature(featureGeneration);
        return false;
      } catch (_) {
        await _mangaStore.upsertLibraryEntry(existing);
        rethrow;
      }
    }
    await _identityStore.write(
      ownerKey: owner,
      sourceId: sourceId,
      entryId: entryId,
      mangaId: title.id,
    );
    try {
      _requireFeature(featureGeneration);
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
      _requireFeature(featureGeneration);
    } catch (_) {
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
      rethrow;
    }
    return true;
  }

  bool isExtensionLibraryEntry(MangaLibraryEntry entry) =>
      entry.metadata['kind'] == 'seanime-manga-extension';

  /// Removing a saved title never requires a working or installed source.
  Future<void> removeLibraryEntry(MangaLibraryEntry entry) async {
    final featureGeneration = _beginFeatureOperation();
    final owner = await _ownerKey();
    _requireFeature(featureGeneration);
    if (entry.ownerKey != owner) {
      throw StateError('This manga belongs to another profile.');
    }
    final mangaId = await _identityStore.read(
      ownerKey: owner,
      sourceId: entry.sourceId,
      entryId: entry.entryId,
    );
    _requireFeature(featureGeneration);
    await _mangaStore.deleteLibraryEntry(
      ownerKey: owner,
      sourceId: entry.sourceId,
      entryId: entry.entryId,
    );
    try {
      _requireFeature(featureGeneration);
      await _identityStore.delete(
        ownerKey: owner,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
      );
      _requireFeature(featureGeneration);
    } catch (_) {
      await _mangaStore.upsertLibraryEntry(entry);
      if (mangaId != null) {
        await _identityStore.write(
          ownerKey: owner,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
          mangaId: mangaId,
        );
      }
      rethrow;
    }
  }

  Future<List<MangaReadingProgress>> chapterHistory(
    MangaExtensionTitle title,
  ) async {
    final featureGeneration = _beginFeatureOperation();
    final owner = await _ownerKey();
    _requireFeature(featureGeneration);
    final history = await _mangaStore.chapterProgressForEntry(
      ownerKey: owner,
      sourceId: mangaExtensionSourceId(title.providerId),
      entryId: mangaExtensionEntryId(title.providerId, title.id),
    );
    _requireFeature(featureGeneration);
    return history;
  }

  Future<MangaReadingProgress?> lastRead(MangaExtensionTitle title) async {
    final featureGeneration = _beginFeatureOperation();
    final owner = await _ownerKey();
    _requireFeature(featureGeneration);
    final progress = await _mangaStore.progress(
      ownerKey: owner,
      sourceId: mangaExtensionSourceId(title.providerId),
      entryId: mangaExtensionEntryId(title.providerId, title.id),
    );
    _requireFeature(featureGeneration);
    return progress;
  }

  Future<void> markRead(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter, {
    required bool completed,
  }) async {
    final featureGeneration = _beginFeatureOperation();
    final owner = await _ownerKey();
    _requireFeature(featureGeneration);
    await _mangaStore.setChapterRead(
      ownerKey: owner,
      sourceId: mangaExtensionSourceId(title.providerId),
      entryId: mangaExtensionEntryId(title.providerId, title.id),
      chapterId: mangaExtensionChapterId(
        title.providerId,
        title.id,
        chapter.id,
      ),
      chapterNumber: chapter.chapterNumber,
      completed: completed,
    );
    _requireFeature(featureGeneration);
  }

  Future<void> bookmark(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter, {
    required bool bookmarked,
  }) async {
    final featureGeneration = _beginFeatureOperation();
    final owner = await _ownerKey();
    _requireFeature(featureGeneration);
    await _mangaStore.setChapterBookmark(
      ownerKey: owner,
      sourceId: mangaExtensionSourceId(title.providerId),
      entryId: mangaExtensionEntryId(title.providerId, title.id),
      chapterId: mangaExtensionChapterId(
        title.providerId,
        title.id,
        chapter.id,
      ),
      chapterNumber: chapter.chapterNumber,
      bookmarked: bookmarked,
    );
    _requireFeature(featureGeneration);
  }

  /// Explicit bounded continuation, never background fanout. A durable cursor
  /// advances even when a source fails, so unavailable head entries cannot
  /// starve later titles. The next pass includes additions before the cursor.
  Future<MangaLibraryUpdateSummary> checkLibraryUpdates() {
    final active = _libraryUpdateInFlight;
    if (active != null) return active;
    final future = _checkLibraryUpdateBatch();
    _libraryUpdateInFlight = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_libraryUpdateInFlight, future)) {
            _libraryUpdateInFlight = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_libraryUpdateInFlight, future)) {
            _libraryUpdateInFlight = null;
          }
        },
      ),
    );
    return future;
  }

  Future<MangaLibraryUpdateSummary> _checkLibraryUpdateBatch() async {
    final owner = await _ownerKey();
    await _requireUpdateOwner(owner);
    final storageKey = 'manga_extension_updates_cursor_v1_${_digest(owner)}';
    String? afterSource;
    String? afterEntry;
    final stored = await _updateCursorStorage.read(key: storageKey);
    if (stored != null) {
      try {
        if (stored.length > 1024) throw const FormatException();
        final parsed = jsonDecode(stored);
        if (parsed is! Map ||
            parsed['source'] is! String ||
            parsed['entry'] is! String ||
            !RegExp(
              r'^extension\.[a-f0-9]{40}$',
            ).hasMatch(parsed['source'] as String) ||
            !RegExp(
              r'^publication\.[a-f0-9]{40}$',
            ).hasMatch(parsed['entry'] as String)) {
          throw const FormatException();
        }
        afterSource = parsed['source'] as String;
        afterEntry = parsed['entry'] as String;
      } catch (_) {
        // Malformed local cursor is not a network capability. Start a new pass.
      }
    }
    await _requireUpdateOwner(owner);
    var page = await _mangaStore.extensionLibraryUpdatePage(
      owner,
      afterSourceId: afterSource,
      afterEntryId: afterEntry,
      limit: maximumMangaLibraryUpdateBatch,
    );
    if (page.entries.isEmpty && afterSource != null) {
      page = await _mangaStore.extensionLibraryUpdatePage(
        owner,
        limit: maximumMangaLibraryUpdateBatch,
      );
    }
    var checked = 0;
    var failed = 0;
    var newChapters = 0;
    var attempted = 0;
    final cancellation = WebProviderCancellation();
    _libraryUpdateCancellation = cancellation;
    try {
      for (final entry in page.entries) {
        await _requireUpdateOwner(owner);
        cancellation.throwIfCancelled();
        // Save only stable local IDs before dispatch; no titles, URLs or tokens.
        await _updateCursorStorage.write(
          key: storageKey,
          value: jsonEncode({'source': entry.sourceId, 'entry': entry.entryId}),
        );
        await _requireUpdateOwner(owner);
        attempted++;
        try {
          if (!isExtensionLibraryEntry(entry)) throw const FormatException();
          final title = await openLibraryEntry(entry);
          if (title == null) throw const FormatException();
          await _requireUpdateOwner(owner);
          // The provider isolate already has a total runtime deadline. Pass its
          // cancellation through instead of timing out and leaving work running.
          await chapters(
            title,
            expectedOwnerKey: owner,
            cancellation: cancellation,
          );
          await _requireUpdateOwner(owner);
          final refreshed = await _mangaStore.libraryEntry(
            ownerKey: owner,
            sourceId: entry.sourceId,
            entryId: entry.entryId,
          );
          newChapters += refreshed?.newChapterCount ?? 0;
          checked++;
        } catch (_) {
          await _requireUpdateOwner(owner);
          cancellation.throwIfCancelled();
          failed++;
        }
      }
      await _requireUpdateOwner(owner);
      final remaining = max(0, page.remaining - attempted);
      if (remaining == 0) await _updateCursorStorage.delete(key: storageKey);
      return (
        checked: checked,
        failed: failed,
        newChapters: newChapters,
        remaining: remaining,
      );
    } finally {
      if (identical(_libraryUpdateCancellation, cancellation)) {
        _libraryUpdateCancellation = null;
      }
    }
  }

  Future<void> _requireUpdateOwner(
    String owner, {
    int? featureGeneration,
  }) async {
    _requireFeature(featureGeneration);
    if (await _ownerKey() != owner) {
      throw StateError('Profile changed. Close and reopen this manga.');
    }
    _requireFeature(featureGeneration);
  }

  Future<MangaAcquisitionRequest> buildDownloadRequest(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter,
  ) async {
    // Save the protected title identity so a user-requested retry after restart
    // can obtain fresh capabilities. No page URL or headers go into SQLite.
    if (!await isInLibrary(title)) await toggleLibrary(title);
    final reader = await buildReaderRequest(title, chapter);
    return MangaAcquisitionRequest(
      jobId: mangaExtensionDownloadJobId(
        reader.sourceId,
        reader.publicationId,
        reader.chapterId,
      ),
      sourceId: reader.sourceId,
      publicationId: reader.publicationId,
      chapterId: reader.chapterId,
      seriesTitle: reader.seriesTitle,
      chapterTitle: reader.chapterTitle,
      chapterNumber: reader.chapterNumber,
      initialPageIndex: reader.initialPageIndex,
      acquisition: MangaReadingOrderAcquisition([
        for (final page in reader.pages)
          MangaReadingOrderPage(
            uri: (page.resource as MangaRemotePageResource).uri,
            headers: (page.resource as MangaRemotePageResource).headers,
            pixelWidth: page.pixelWidth,
            pixelHeight: page.pixelHeight,
            isCover: page.isCover,
          ),
      ]),
    );
  }

  Future<MangaAcquisitionRequest> resolveDownload(MangaDownloadJob job) async {
    final owner = await _ownerKey();
    final entry = await _mangaStore.libraryEntry(
      ownerKey: owner,
      sourceId: job.sourceId,
      entryId: job.entryId,
    );
    if (entry == null) {
      throw StateError(
        'Open this download from the profile that saved the manga.',
      );
    }
    final title = await openLibraryEntry(entry);
    if (title == null) {
      throw StateError(
        'Reopen this chapter from its original source to download it.',
      );
    }
    final available = await chapters(title);
    for (final chapter in available) {
      if (mangaExtensionChapterId(title.providerId, title.id, chapter.id) ==
          job.chapterId) {
        return buildDownloadRequest(title, chapter);
      }
    }
    throw StateError('This chapter is no longer available from its source.');
  }

  Future<MangaExtensionTitle?> openLibraryEntry(MangaLibraryEntry entry) async {
    if (!isExtensionLibraryEntry(entry)) return null;
    final providerId = entry.metadata['providerId'];
    if (providerId is! String || _enabledProvider(providerId) == null) {
      throw StateError('Enable this manga extension to open the title.');
    }
    final owner = await _ownerKey();
    if (entry.ownerKey != owner) {
      throw StateError('This manga belongs to another profile.');
    }
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
    _libraryUpdateCancellation?.cancel();
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
