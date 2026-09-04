import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/manga/application/manga_acquisition_controller.dart';
import 'package:anime_tv/features/manga/application/manga_dependencies.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/data/manga_uri_policy.dart';
import 'package:anime_tv/features/manga/domain/manga_acquisition_models.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';
import 'package:anime_tv/features/marketplace/domain/repository_format.dart';
import 'package:anime_tv/features/settings/application/local_profiles_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

export 'package:anime_tv/features/manga/application/manga_dependencies.dart';

// Named public constructor parameters are intentionally kept separate from
// private dependency fields so provider overrides and focused tests stay clear.
// ignore_for_file: prefer_initializing_formals

const int maximumMangaReaderPages = 1000;
const String _mangaDeviceOwnerStorageKey = 'manga_device_owner_v1';

/// Resolves library/progress ownership without writing a tracker identifier to
/// SQLite. A selected local profile wins, followed by the selected tracking
/// account slot, with an installation-random protected key as the fallback.
final mangaOwnerKeyProvider = FutureProvider<String>((ref) async {
  final localProfiles = ref.watch(localProfilesControllerProvider);
  final trackingAccounts = ref.watch(trackingAccountsControllerProvider);
  final preferences = ref.watch(settingsPreferencesProvider);
  final storage = ref.watch(secureStorageProvider);
  return resolveMangaOwnerKey(
    storage: storage,
    activeLocalProfileId: localProfiles.activeProfileId,
    preferredTrackingProvider: preferences.trackingProvider,
    activeTrackingProfileIds: trackingAccounts.activeProfileIds,
  );
});

final mangaHubControllerProvider =
    StateNotifierProvider<MangaHubController, MangaHubState>((ref) {
      final ownerKey = ref.watch(mangaOwnerKeyProvider.future);
      final controller = MangaHubController(
        client: ref.watch(mangaCatalogClientProvider),
        credentials: ref.watch(mangaSourceCredentialStoreProvider),
        store: ref.watch(mangaStoreProvider),
        ownerKey: () => ownerKey,
        cleanupDownloadsForSource: (sourceId) => ref
            .read(mangaAcquisitionControllerProvider.notifier)
            .removeDownloadsForSource(sourceId),
      );
      Future<void>.microtask(controller.initialize);
      return controller;
    });

/// Produces a stable, privacy-preserving owner key for device-local manga data.
Future<String> resolveMangaOwnerKey({
  required FlutterSecureStorage storage,
  String? activeLocalProfileId,
  TrackingProvider? preferredTrackingProvider,
  Map<TrackingProvider, String> activeTrackingProfileIds = const {},
}) async {
  final localId = _boundedIdentity(activeLocalProfileId);
  if (localId != null) return 'local.${_identityDigest(localId)}';

  final preferred = preferredTrackingProvider;
  if (preferred != null) {
    final slot = _boundedIdentity(activeTrackingProfileIds[preferred]);
    if (slot != null) {
      return 'tracking.${preferred.slug}.${_identityDigest(slot)}';
    }
  }
  for (final provider in TrackingProvider.values) {
    if (provider == preferred) continue;
    final slot = _boundedIdentity(activeTrackingProfileIds[provider]);
    if (slot != null) {
      return 'tracking.${provider.slug}.${_identityDigest(slot)}';
    }
  }

  final stored = await storage.read(key: _mangaDeviceOwnerStorageKey);
  if (stored != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(stored)) {
    return 'device.$stored';
  }
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  final generated = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  await storage.write(key: _mangaDeviceOwnerStorageKey, value: generated);
  return 'device.$generated';
}

@immutable
class MangaCatalogBreadcrumb {
  const MangaCatalogBreadcrumb({required this.feed});

  final MangaCatalogFeed feed;

  String get title => feed.title;
  Uri get uri => feed.documentUri;
}

@immutable
class MangaHubState {
  MangaHubState({
    Iterable<StoredMangaSource> sources = const <StoredMangaSource>[],
    this.selectedSource,
    this.selectedFeed,
    Iterable<MangaCatalogBreadcrumb> breadcrumbs =
        const <MangaCatalogBreadcrumb>[],
    Iterable<MangaLibraryEntry> library = const <MangaLibraryEntry>[],
    Iterable<MangaDownloadJob> downloads = const <MangaDownloadJob>[],
    this.isLoading = false,
    this.error,
    this.query = '',
  }) : sources = List<StoredMangaSource>.unmodifiable(sources),
       breadcrumbs = List<MangaCatalogBreadcrumb>.unmodifiable(breadcrumbs),
       library = List<MangaLibraryEntry>.unmodifiable(library),
       downloads = List<MangaDownloadJob>.unmodifiable(downloads);

  final List<StoredMangaSource> sources;
  final StoredMangaSource? selectedSource;
  final MangaCatalogFeed? selectedFeed;
  final List<MangaCatalogBreadcrumb> breadcrumbs;
  final List<MangaLibraryEntry> library;
  final List<MangaDownloadJob> downloads;
  final bool isLoading;
  final String? error;
  final String query;

  List<MangaPublication> get publications {
    final feed = selectedFeed;
    if (feed == null) return const <MangaPublication>[];
    final all = <MangaPublication>[
      ...feed.publications,
      for (final group in feed.groups) ...group.publications,
    ];
    final deduplicated = <String, MangaPublication>{};
    for (final publication in all) {
      deduplicated.putIfAbsent(
        mangaPublicationStableId(publication),
        () => publication,
      );
    }
    return List<MangaPublication>.unmodifiable(deduplicated.values);
  }

  List<MangaPublication> get visiblePublications {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return publications;
    return List<MangaPublication>.unmodifiable(
      publications.where((publication) {
        final values = <String>[
          publication.title,
          publication.subtitle ?? '',
          ...publication.authors.map((author) => author.name),
          ...publication.subjects,
        ];
        return values.any((value) => value.toLowerCase().contains(needle));
      }),
    );
  }

  MangaHubState copyWith({
    Iterable<StoredMangaSource>? sources,
    StoredMangaSource? selectedSource,
    bool clearSelectedSource = false,
    MangaCatalogFeed? selectedFeed,
    bool clearSelectedFeed = false,
    Iterable<MangaCatalogBreadcrumb>? breadcrumbs,
    Iterable<MangaLibraryEntry>? library,
    Iterable<MangaDownloadJob>? downloads,
    bool? isLoading,
    String? error,
    bool clearError = false,
    String? query,
  }) => MangaHubState(
    sources: sources ?? this.sources,
    selectedSource: clearSelectedSource
        ? null
        : selectedSource ?? this.selectedSource,
    selectedFeed: clearSelectedFeed ? null : selectedFeed ?? this.selectedFeed,
    breadcrumbs: breadcrumbs ?? this.breadcrumbs,
    library: library ?? this.library,
    downloads: downloads ?? this.downloads,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : error ?? this.error,
    query: query ?? this.query,
  );
}

enum MangaCbzAcquisitionFailure { noSourceSelected, unavailable, unsafe }

@immutable
class MangaCbzAcquisition implements MangaCbzAcquisitionSource {
  MangaCbzAcquisition({
    required this.sourceId,
    required this.publicationId,
    required this.uri,
    required this.mediaType,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(headers);

  @override
  final String sourceId;
  @override
  final String publicationId;
  @override
  final Uri uri;
  @override
  final String mediaType;

  /// Ephemeral capability; never persist or include in diagnostics/routes.
  @override
  final Map<String, String> headers;

  @override
  String toString() =>
      'MangaCbzAcquisition($sourceId, $mediaType, headers: <redacted>)';
}

class MangaCbzAcquisitionException implements Exception {
  const MangaCbzAcquisitionException(this.failure, this.message);

  final MangaCbzAcquisitionFailure failure;
  final String message;

  @override
  String toString() => message;
}

enum MangaReaderBuildFailure {
  noSourceSelected,
  noImagePages,
  tooManyPages,
  invalidChapter,
}

typedef MangaSourceDownloadCleanup = Future<int> Function(String sourceId);

Future<int> _noMangaDownloadCleanup(String sourceId) async => 0;

class MangaReaderBuildException implements Exception {
  const MangaReaderBuildException(this.failure, this.message);

  final MangaReaderBuildFailure failure;
  final String message;

  @override
  String toString() => message;
}

class MangaHubController extends StateNotifier<MangaHubState> {
  MangaHubController({
    required MangaCatalogClient client,
    required MangaSourceCredentialStore credentials,
    required MangaStore store,
    required Future<String> Function() ownerKey,
    MangaSourceDownloadCleanup? cleanupDownloadsForSource,
  }) : _client = client,
       _credentials = credentials,
       _store = store,
       _ownerKey = ownerKey,
       _cleanupDownloadsForSource =
           cleanupDownloadsForSource ?? _noMangaDownloadCleanup,
       super(MangaHubState());

  final MangaCatalogClient _client;
  final MangaSourceCredentialStore _credentials;
  final MangaStore _store;
  final Future<String> Function() _ownerKey;
  final MangaSourceDownloadCleanup _cleanupDownloadsForSource;
  int _generation = 0;

  Future<bool> initialize() => _run((generation) async {
    await _reloadCollections(generation);
  });

  /// Adds either a direct OPDS feed or a data-only TetoTV repository.
  ///
  /// [credential] authenticates the URL itself unless
  /// [repositoryCredentialSourceId] names one exact child descriptor. The
  /// latter form is deliberately never sent to, or copied across, the
  /// repository URL or any sibling source.
  Future<bool> addSource(
    Uri uri, {
    MangaSourceCredential? credential,
    String? repositoryCredentialSourceId,
  }) => _run((generation) async {
    if (repositoryCredentialSourceId != null && credential == null) {
      throw const FormatException(
        'Choose a credential before selecting a repository source.',
      );
    }
    final safeUri = _requireCredentialFreeCatalogUri(
      uri.toString(),
      field: 'Manga source URL',
    );
    final compatibility = inspectExtensionRepositoryUri(safeUri);
    if (compatibility.isRejected) {
      throw FormatException(compatibility.rejectionMessage!);
    }
    final rootId = mangaSourceStableId(safeUri);
    final previousRootCredential = await _credentials.read(rootId);
    final credentialTargetsChild = repositoryCredentialSourceId != null;
    var wroteRootCredential = false;
    var credentialCommitCompleted = false;
    String? childCredentialId;
    MangaSourceCredential? previousChildCredential;
    try {
      if (credential != null && !credentialTargetsChild) {
        await _credentials.write(rootId, credential);
        wroteRootCredential = true;
      }
      final existingRootCredential = await _credentials.read(rootId);
      final document = await _client.fetch(
        safeUri,
        sourceId: existingRootCredential == null ? null : rootId,
      );
      final now = DateTime.now().toUtc();
      switch (document) {
        case MangaFetchedFeed(:final feed):
          if (repositoryCredentialSourceId != null) {
            throw const FormatException(
              'That URL is a direct catalog, not a repository.',
            );
          }
          await _store.upsertSource(
            StoredMangaSource(
              id: rootId,
              uri: safeUri,
              name: feed.title,
              kind: _storedKind(feed.protocol),
              updatedAt: now,
            ),
          );
        case MangaFetchedRepository(:final repository):
          MangaSourceDescriptor? credentialDescriptor;
          if (repositoryCredentialSourceId case final target?) {
            for (final descriptor in repository.sources) {
              if (descriptor.id == target) {
                credentialDescriptor = descriptor;
                break;
              }
            }
            if (credentialDescriptor == null) {
              throw const FormatException(
                'The selected repository source no longer exists.',
              );
            }
            if (!_credentialMatches(
              credential!,
              credentialDescriptor.authentication,
            )) {
              throw const FormatException(
                'That credential does not match the selected source.',
              );
            }
          }
          await _persistRepository(rootId, safeUri, repository, now);
          if (credentialDescriptor != null) {
            childCredentialId = mangaRepositoryChildStableId(
              rootId,
              credentialDescriptor,
            );
            previousChildCredential = await _credentials.read(
              childCredentialId,
            );
            await _credentials.write(childCredentialId, credential!);
          }
      }
      credentialCommitCompleted = true;
      await _reloadCollections(generation);
    } catch (_) {
      if (!credentialCommitCompleted && wroteRootCredential) {
        await _restoreCredential(rootId, previousRootCredential);
      }
      if (!credentialCommitCompleted && childCredentialId != null) {
        await _restoreCredential(childCredentialId, previousChildCredential);
      }
      rethrow;
    }
  });

  Future<bool> removeSource(String sourceId) => _run((generation) async {
    final source = await _store.source(sourceId);
    if (source == null) return;
    final allSources = await _store.sources();
    final ids = source.kind == StoredMangaSourceKind.repository
        ? <String>[
            for (final item in allSources)
              if (item.id == source.id ||
                  _isRepositoryChild(source.id, item.id))
                item.id,
          ]
        : <String>[source.id];
    ids.sort((first, second) => second.length.compareTo(first.length));
    // Cleanup is part of the controller operation, not a UI convention. This
    // keeps every caller from leaving app-private pages behind or deleting a
    // source whose active downloads could not be cancelled safely.
    for (final id in ids) {
      await _cleanupDownloadsForSource(id);
    }
    for (final id in ids) {
      await _store.deleteSource(id);
    }
    final selectedRemoved = ids.contains(state.selectedSource?.id);
    if (selectedRemoved && _isCurrent(generation)) {
      state = state.copyWith(
        clearSelectedSource: true,
        clearSelectedFeed: true,
        breadcrumbs: const <MangaCatalogBreadcrumb>[],
        query: '',
      );
    }
    await _reloadCollections(generation);
  });

  Future<bool> setSourceEnabled(String sourceId, bool enabled) => _run((
    generation,
  ) async {
    final source = await _store.source(sourceId);
    if (source == null) {
      throw const FormatException('That manga source no longer exists.');
    }
    final allSources = await _store.sources();
    final affected = source.kind == StoredMangaSourceKind.repository
        ? allSources.where(
            (item) =>
                item.id == source.id || _isRepositoryChild(source.id, item.id),
          )
        : <StoredMangaSource>[source];
    for (final item in affected) {
      await _store.setSourceEnabled(item.id, enabled);
    }
    if (!enabled &&
        affected.any((item) => item.id == state.selectedSource?.id) &&
        _isCurrent(generation)) {
      state = state.copyWith(
        clearSelectedSource: true,
        clearSelectedFeed: true,
        breadcrumbs: const <MangaCatalogBreadcrumb>[],
        query: '',
      );
    }
    await _reloadCollections(generation);
  });

  Future<bool> selectSource(String sourceId) => _run((generation) async {
    final source = await _store.source(sourceId);
    if (source == null) {
      throw const FormatException('That manga source no longer exists.');
    }
    if (!source.enabled) {
      throw const FormatException(
        'Enable that manga source before opening it.',
      );
    }
    _requireCredentialFreeCatalogUri(
      source.uri.toString(),
      field: 'Manga source URL',
    );
    final document = await _client.fetch(
      source.uri,
      sourceId: source.id,
      protocolHint: _protocolHint(source.kind),
    );
    if (!_isCurrent(generation)) return;
    switch (document) {
      case MangaFetchedFeed(:final feed):
        state = state.copyWith(
          selectedSource: source,
          selectedFeed: feed,
          breadcrumbs: const <MangaCatalogBreadcrumb>[],
          query: '',
        );
      case MangaFetchedRepository(:final repository):
        await _persistRepository(
          source.id,
          source.uri,
          repository,
          DateTime.now().toUtc(),
        );
        if (!_isCurrent(generation)) return;
        state = state.copyWith(
          selectedSource: source,
          clearSelectedFeed: true,
          breadcrumbs: const <MangaCatalogBreadcrumb>[],
          query: '',
        );
        await _reloadCollections(generation);
    }
  });

  Future<bool> refresh() => _run((generation) async {
    final source = state.selectedSource;
    if (source == null) {
      throw const FormatException('Choose a manga source first.');
    }
    final currentFeed = state.selectedFeed;
    final target = currentFeed?.documentUri ?? source.uri;
    final sourceId = _sameOrigin(source.uri, target) ? source.id : null;
    final document = await _client.fetch(
      target,
      sourceId: sourceId,
      protocolHint: currentFeed?.protocol ?? _protocolHint(source.kind),
    );
    if (!_isCurrent(generation)) return;
    switch (document) {
      case MangaFetchedFeed(:final feed):
        state = state.copyWith(selectedFeed: feed);
      case MangaFetchedRepository(:final repository):
        await _persistRepository(
          source.id,
          source.uri,
          repository,
          DateTime.now().toUtc(),
        );
        if (!_isCurrent(generation)) return;
        state = state.copyWith(clearSelectedFeed: true);
        await _reloadCollections(generation);
    }
  });

  Future<bool> navigate(MangaCatalogLink link) {
    if (link.isAcquisition || link.isCover || _isImageLink(link)) {
      return _fail('That item is not a manga catalog.');
    }
    return navigateTo(link.uri);
  }

  Future<bool> navigateTo(Uri uri) => _run((generation) async {
    final source = state.selectedSource;
    final currentFeed = state.selectedFeed;
    if (source == null || currentFeed == null) {
      throw const FormatException('Choose a manga catalog first.');
    }
    final safeUri = requireMangaPublicHttpsUri(
      uri.toString(),
      field: 'Manga catalog URL',
    );
    final document = await _client.fetch(
      safeUri,
      sourceId: _sameOrigin(source.uri, safeUri) ? source.id : null,
    );
    if (document is! MangaFetchedFeed) {
      throw const FormatException('That link is not a manga catalog.');
    }
    if (!_isCurrent(generation)) return;
    state = state.copyWith(
      selectedFeed: document.feed,
      breadcrumbs: <MangaCatalogBreadcrumb>[
        ...state.breadcrumbs,
        MangaCatalogBreadcrumb(feed: currentFeed),
      ],
      query: '',
    );
  });

  bool back() {
    if (state.breadcrumbs.isEmpty) return false;
    final previous = state.breadcrumbs.last;
    state = state.copyWith(
      selectedFeed: previous.feed,
      breadcrumbs: state.breadcrumbs.sublist(0, state.breadcrumbs.length - 1),
      query: '',
      clearError: true,
    );
    return true;
  }

  void setQuery(String value) {
    final normalized = value
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trimLeft();
    state = state.copyWith(
      query: normalized.length > 128
          ? normalized.substring(0, 128)
          : normalized,
      clearError: true,
    );
  }

  void clearError() => state = state.copyWith(clearError: true);

  List<Uri> _currentCatalogPath(StoredMangaSource source) {
    final selectedSource = state.selectedSource;
    final selectedFeed = state.selectedFeed;
    if (selectedSource?.id != source.id || selectedFeed == null) {
      throw const FormatException(
        'Open the manga catalog before saving this item.',
      );
    }
    final candidates = <Uri>[
      source.uri,
      for (final breadcrumb in state.breadcrumbs) breadcrumb.feed.documentUri,
      selectedFeed.documentUri,
    ];
    if (candidates.length > _maximumPersistedCatalogHops) {
      throw const FormatException('That manga catalog is nested too deeply.');
    }
    final path = <Uri>[];
    for (final candidate in candidates) {
      final safe = _requireCredentialFreeCatalogUri(
        candidate.toString(),
        field: 'Saved manga catalog URL',
      );
      if (path.isEmpty || !_sameDocument(path.last, safe)) path.add(safe);
    }
    return List<Uri>.unmodifiable(path);
  }

  Future<bool> toggleLibrary(MangaPublication publication) =>
      _run((generation) async {
        final source = state.selectedSource;
        if (source == null) {
          throw const FormatException('Choose a manga source first.');
        }
        final owner = await _ownerKey();
        final entryId = mangaPublicationStableId(publication);
        final existing = await _store.libraryEntry(
          ownerKey: owner,
          sourceId: source.id,
          entryId: entryId,
        );
        if (existing != null) {
          await _store.deleteLibraryEntry(
            ownerKey: owner,
            sourceId: source.id,
            entryId: entryId,
          );
        } else {
          await _store.upsertLibraryEntry(
            MangaLibraryEntry(
              ownerKey: owner,
              sourceId: source.id,
              entryId: entryId,
              title: publication.title,
              metadata: _libraryMetadata(
                publication,
                catalogPath: _currentCatalogPath(source),
              ),
              coverUri: _coverUri(publication),
              updatedAt: DateTime.now().toUtc(),
            ),
          );
        }
        if (!_isCurrent(generation)) return;
        state = state.copyWith(library: await _store.libraryEntries(owner));
      });

  /// Removes an entry for the active profile without requiring its catalog to
  /// be selected or loaded. A library object from another profile can never be
  /// used to delete that profile's row.
  Future<bool> removeLibraryEntry(MangaLibraryEntry entry) =>
      _run((generation) async {
        final owner = await _ownerKey();
        if (entry.ownerKey != owner) {
          throw const FormatException(
            'That manga library item belongs to another profile.',
          );
        }
        await _store.deleteLibraryEntry(
          ownerKey: owner,
          sourceId: entry.sourceId,
          entryId: entry.entryId,
        );
        if (!_isCurrent(generation)) return;
        state = state.copyWith(library: await _store.libraryEntries(owner));
      });

  /// Reopens a saved publication by replaying its credential-free OPDS feed
  /// path. Each hop must still be linked by the preceding feed, and protected
  /// credentials are attached only to the saved source's exact origin.
  Future<MangaPublication?> openLibraryEntry(MangaLibraryEntry entry) async {
    final generation = ++_generation;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final owner = await _ownerKey();
      if (entry.ownerKey != owner) {
        throw const FormatException(
          'That manga library item belongs to another profile.',
        );
      }
      final source = await _store.source(entry.sourceId);
      if (source == null) {
        throw const FormatException('That manga source no longer exists.');
      }
      if (!source.enabled) {
        throw const FormatException(
          'Enable that manga source before opening it.',
        );
      }
      final path = _libraryCatalogPath(entry, source);
      final feeds = <MangaCatalogFeed>[];
      MangaCatalogFeed? current;
      for (var index = 0; index < path.length; index++) {
        final target = path[index];
        if (current != null && _sameDocument(current.documentUri, target)) {
          continue;
        }
        if (current != null && !_feedLinksToCatalog(current, target)) {
          throw const FormatException(
            'That saved manga catalog path is no longer available.',
          );
        }
        final document = await _client.fetch(
          target,
          sourceId: _sameOrigin(source.uri, target) ? source.id : null,
          protocolHint: index == 0 ? _protocolHint(source.kind) : null,
        );
        if (document is! MangaFetchedFeed) {
          throw const FormatException(
            'That saved manga item no longer points to a catalog.',
          );
        }
        if (current != null) feeds.add(current);
        current = document.feed;
      }
      if (!_isCurrent(generation)) return null;
      if (current == null) {
        throw const FormatException('That saved manga catalog is invalid.');
      }
      MangaPublication? publication;
      for (final candidate in _feedPublications(current)) {
        if (mangaPublicationStableId(candidate) == entry.entryId) {
          publication = candidate;
          break;
        }
      }
      if (publication == null) {
        throw const FormatException(
          'That saved manga item is no longer available in its catalog.',
        );
      }
      state = state.copyWith(
        selectedSource: source,
        selectedFeed: current,
        breadcrumbs: <MangaCatalogBreadcrumb>[
          for (final feed in feeds) MangaCatalogBreadcrumb(feed: feed),
        ],
        query: '',
        isLoading: false,
        clearError: true,
      );
      return publication;
    } catch (error) {
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false, error: _friendlyError(error));
      }
      return null;
    }
  }

  Future<MangaReaderRequest> buildReaderRequest(
    MangaPublication publication, {
    String? chapterId,
    String? chapterTitle,
    double? chapterNumber,
  }) async {
    final source = state.selectedSource;
    if (source == null) {
      throw const MangaReaderBuildException(
        MangaReaderBuildFailure.noSourceSelected,
        'Choose a manga source first.',
      );
    }
    var links = publication.readingOrder.where(_isImageLink).toList();
    if (links.isEmpty) {
      links = publication.resources.where(_isImageLink).toList();
    }
    if (links.isEmpty) {
      throw const MangaReaderBuildException(
        MangaReaderBuildFailure.noImagePages,
        'This item does not include readable image pages.',
      );
    }
    if (links.length > maximumMangaReaderPages) {
      throw const MangaReaderBuildException(
        MangaReaderBuildFailure.tooManyPages,
        'This chapter has more than 1,000 pages.',
      );
    }

    final publicationId = mangaPublicationStableId(publication);
    final resolvedChapterId = _boundedChapterLabel(
      chapterId ?? publicationId,
      fallbackMessage: 'This chapter has an invalid identifier.',
    );
    final resolvedChapterTitle = _boundedChapterLabel(
      chapterTitle ?? publication.subtitle ?? publication.title,
      maximum: 512,
      fallbackMessage: 'This chapter has an invalid title.',
    );
    final sourceHeaders = await _credentials.requestHeaders(source.id);
    final occurrences = <String, int>{};
    final pages = <MangaReaderPage>[];
    for (var index = 0; index < links.length; index++) {
      final link = links[index];
      final uriKey = link.uri.toString();
      final occurrence = occurrences.update(
        uriKey,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      final dimensions = _pageDimensions(link.properties);
      pages.add(
        MangaReaderPage(
          id: 'page.${_digest(uriKey).substring(0, 32)}.$occurrence',
          index: index,
          resource: MangaRemotePageResource(
            uri: link.uri,
            headers: _sameOrigin(source.uri, link.uri)
                ? sourceHeaders
                : const <String, String>{},
          ),
          pixelWidth: dimensions?.$1,
          pixelHeight: dimensions?.$2,
          isCover: link.isCover,
        ),
      );
    }
    final owner = await _ownerKey();
    final progress = await _store.progress(
      ownerKey: owner,
      sourceId: source.id,
      entryId: publicationId,
    );
    final initialPage =
        progress != null &&
            progress.chapterId == resolvedChapterId &&
            progress.pageIndex >= 0 &&
            progress.pageIndex < pages.length
        ? progress.pageIndex
        : 0;
    try {
      return MangaReaderRequest(
        sourceId: source.id,
        publicationId: publicationId,
        chapterId: resolvedChapterId,
        seriesTitle: publication.title,
        chapterTitle: resolvedChapterTitle,
        chapterNumber: chapterNumber,
        pages: pages,
        initialPageIndex: initialPage,
      );
    } on ArgumentError {
      throw const MangaReaderBuildException(
        MangaReaderBuildFailure.invalidChapter,
        'This chapter contains invalid reader information.',
      );
    }
  }

  /// Applies this profile's durable reading position to a local/offline reader
  /// request. Download metadata deliberately has no owner identifier, so this
  /// lookup stays in the profile-aware hub instead of the acquisition service.
  Future<MangaReaderRequest> applySavedProgress(
    MangaReaderRequest request,
  ) async {
    final owner = await _ownerKey();
    final progress = await _store.progress(
      ownerKey: owner,
      sourceId: request.sourceId,
      entryId: request.publicationId,
    );
    if (progress == null ||
        progress.chapterId != request.chapterId ||
        progress.pageIndex < 0 ||
        progress.pageIndex >= request.pages.length ||
        progress.pageIndex == request.initialPageIndex) {
      return request;
    }
    return MangaReaderRequest(
      sourceId: request.sourceId,
      publicationId: request.publicationId,
      chapterId: request.chapterId,
      seriesTitle: request.seriesTitle,
      chapterTitle: request.chapterTitle,
      chapterNumber: request.chapterNumber,
      initialPageIndex: progress.pageIndex,
      pages: request.pages,
    );
  }

  Future<MangaCbzAcquisition> selectCbzAcquisition(
    MangaPublication publication,
  ) async {
    final source = state.selectedSource;
    if (source == null) {
      throw const MangaCbzAcquisitionException(
        MangaCbzAcquisitionFailure.noSourceSelected,
        'Choose a manga source first.',
      );
    }
    final candidates = publication.acquisitionLinks
        .where(_looksLikeCbzAcquisition)
        .toList(growable: false);
    if (candidates.isEmpty) {
      throw const MangaCbzAcquisitionException(
        MangaCbzAcquisitionFailure.unavailable,
        'This item does not provide a CBZ download.',
      );
    }
    MangaCatalogLink? link;
    for (final candidate in candidates) {
      if (_isPublicHttpsLink(candidate)) {
        link = candidate;
        break;
      }
    }
    if (link == null) {
      throw const MangaCbzAcquisitionException(
        MangaCbzAcquisitionFailure.unsafe,
        'This item provides an unsafe CBZ download URL.',
      );
    }
    final headers = _sameOrigin(source.uri, link.uri)
        ? await _credentials.requestHeaders(source.id)
        : const <String, String>{};
    return MangaCbzAcquisition(
      sourceId: source.id,
      publicationId: mangaPublicationStableId(publication),
      uri: link.uri,
      mediaType: _normalizedMediaType(link.mediaType) ?? 'application/zip',
      headers: headers,
    );
  }

  Future<bool> saveProgress(
    MangaReaderRequest request, {
    required int pageIndex,
    double pageOffset = 0,
    bool completed = false,
  }) async {
    try {
      final owner = await _ownerKey();
      await _store.upsertProgress(
        MangaReadingProgress(
          ownerKey: owner,
          sourceId: request.sourceId,
          entryId: request.publicationId,
          chapterId: request.chapterId,
          chapterNumber: request.chapterNumber,
          pageIndex: pageIndex,
          pageOffset: pageOffset,
          pageCount: request.pages.length,
          completed: completed,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      return true;
    } catch (error) {
      state = state.copyWith(error: _friendlyError(error), isLoading: false);
      return false;
    }
  }

  Future<void> _persistRepository(
    String rootId,
    Uri repositoryUri,
    MangaRepositoryManifest repository,
    DateTime now,
  ) async {
    final existing = await _store.sources();
    final existingById = <String, StoredMangaSource>{
      for (final source in existing) source.id: source,
    };
    final childSources = <StoredMangaSource>[];
    final desiredIds = <String>{};
    for (final descriptor in repository.sources) {
      final childId = mangaRepositoryChildStableId(rootId, descriptor);
      desiredIds.add(childId);
      childSources.add(
        StoredMangaSource(
          id: childId,
          uri: _requireCredentialFreeCatalogUri(
            descriptor.entryPoint.toString(),
            field: 'Repository source URL',
          ),
          name: descriptor.name,
          kind: _storedKind(descriptor.protocol),
          enabled: existingById[childId]?.enabled ?? true,
          updatedAt: now,
        ),
      );
    }
    await _store.upsertSource(
      StoredMangaSource(
        id: rootId,
        uri: repositoryUri,
        name: repository.name,
        kind: StoredMangaSourceKind.repository,
        updatedAt: now,
      ),
    );
    for (final child in childSources) {
      await _store.upsertSource(child);
    }
    for (final source in existing) {
      if (_isRepositoryChild(rootId, source.id) &&
          !desiredIds.contains(source.id)) {
        await _cleanupDownloadsForSource(source.id);
        await _store.deleteSource(source.id);
      }
    }
  }

  Future<void> _reloadCollections(int generation) async {
    final owner = await _ownerKey();
    final sources = await _store.sources();
    final library = await _store.libraryEntries(owner);
    final downloads = await _store.downloadJobs();
    if (!_isCurrent(generation)) return;
    StoredMangaSource? selected;
    final selectedId = state.selectedSource?.id;
    if (selectedId != null) {
      for (final source in sources) {
        if (source.id == selectedId) {
          selected = source;
          break;
        }
      }
    }
    state = state.copyWith(
      sources: sources,
      selectedSource: selected,
      clearSelectedSource: selectedId != null && selected == null,
      clearSelectedFeed: selectedId != null && selected == null,
      breadcrumbs: selectedId != null && selected == null
          ? const <MangaCatalogBreadcrumb>[]
          : null,
      library: library,
      downloads: downloads,
    );
  }

  Future<bool> _run(Future<void> Function(int generation) operation) async {
    final generation = ++_generation;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await operation(generation);
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false, clearError: true);
      }
      return _isCurrent(generation);
    } catch (error) {
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false, error: _friendlyError(error));
      }
      return false;
    }
  }

  Future<bool> _fail(String message) async {
    state = state.copyWith(error: _boundedError(message), isLoading: false);
    return false;
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _restoreCredential(
    String sourceId,
    MangaSourceCredential? previous,
  ) => previous == null
      ? _credentials.delete(sourceId)
      : _credentials.write(sourceId, previous);
}

String mangaSourceStableId(Uri uri) =>
    'source.${_digest(_requireCredentialFreeCatalogUri(uri.toString(), field: 'Manga source URL').toString()).substring(0, 32)}';

String mangaRepositoryChildStableId(
  String repositoryId,
  MangaSourceDescriptor descriptor,
) {
  if (!RegExp(
    r'^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$',
  ).hasMatch(repositoryId)) {
    throw const FormatException('Manga repository id is invalid.');
  }
  final digest = _digest('${descriptor.id}\n${descriptor.entryPoint}');
  return '$repositoryId.child.${digest.substring(0, 32)}';
}

String mangaPublicationStableId(MangaPublication publication) {
  final identifier = publication.identifier?.trim();
  final seed = identifier != null && identifier.isNotEmpty
      ? 'id:$identifier'
      : <String>[
          publication.title,
          publication.subtitle ?? '',
          ...publication.authors.map((author) => author.name),
          if (publication.links.isNotEmpty)
            publication.links.first.uri.toString()
          else if (publication.readingOrder.isNotEmpty)
            publication.readingOrder.first.uri.toString(),
        ].join('\n');
  return 'publication.${_digest(seed).substring(0, 40)}';
}

StoredMangaSourceKind _storedKind(MangaSourceProtocol protocol) =>
    switch (protocol) {
      MangaSourceProtocol.opds1 => StoredMangaSourceKind.opds1,
      MangaSourceProtocol.opds2 => StoredMangaSourceKind.opds2,
    };

MangaSourceProtocol? _protocolHint(StoredMangaSourceKind kind) =>
    switch (kind) {
      StoredMangaSourceKind.opds1 => MangaSourceProtocol.opds1,
      StoredMangaSourceKind.opds2 => MangaSourceProtocol.opds2,
      StoredMangaSourceKind.repository => null,
    };

bool _isRepositoryChild(String parentId, String candidateId) =>
    candidateId.startsWith('$parentId.child.');

bool _credentialMatches(
  MangaSourceCredential credential,
  MangaSourceAuthentication authentication,
) {
  if (credential.kind != authentication.kind ||
      authentication.kind == MangaSourceAuthenticationKind.none) {
    return false;
  }
  if (credential.kind != MangaSourceAuthenticationKind.apiKey) return true;
  return credential.headerName?.toLowerCase() ==
      authentication.headerName?.toLowerCase();
}

Map<String, Object?> _libraryMetadata(
  MangaPublication publication, {
  required List<Uri> catalogPath,
}) {
  final metadata = <String, Object?>{
    'authors': <String>[for (final author in publication.authors) author.name],
    'languages': List<String>.of(publication.languages),
    'subjects': List<String>.of(publication.subjects),
    // This path contains catalog documents only—never page/acquisition URLs,
    // headers, or credentials—and is revalidated before every reopen.
    'catalogPath': <String>[for (final uri in catalogPath) uri.toString()],
  };
  final identifier = publication.identifier;
  final subtitle = publication.subtitle;
  final description = publication.description;
  final modified = publication.modified;
  if (identifier != null) metadata['identifier'] = identifier;
  if (subtitle != null) metadata['subtitle'] = subtitle;
  if (description != null) metadata['description'] = description;
  if (modified != null) {
    metadata['modified'] = modified.toUtc().toIso8601String();
  }
  return metadata;
}

List<Uri> _libraryCatalogPath(
  MangaLibraryEntry entry,
  StoredMangaSource source,
) {
  final raw = entry.metadata['catalogPath'];
  if (raw == null) return <Uri>[source.uri];
  if (raw is! List ||
      raw.isEmpty ||
      raw.length > _maximumPersistedCatalogHops) {
    throw const FormatException('That saved manga catalog path is invalid.');
  }
  final result = <Uri>[source.uri];
  for (final value in raw) {
    if (value is! String) {
      throw const FormatException('That saved manga catalog path is invalid.');
    }
    final uri = _requireCredentialFreeCatalogUri(
      value,
      field: 'Saved manga catalog URL',
    );
    if (!_sameDocument(result.last, uri)) result.add(uri);
  }
  return List<Uri>.unmodifiable(result);
}

Iterable<MangaPublication> _feedPublications(MangaCatalogFeed feed) sync* {
  yield* feed.publications;
  for (final group in feed.groups) {
    yield* group.publications;
  }
}

bool _feedLinksToCatalog(MangaCatalogFeed feed, Uri target) {
  final navigation = <MangaNavigationItem>[
    ...feed.navigation,
    for (final group in feed.groups) ...group.navigation,
  ];
  for (final item in navigation) {
    for (final link in item.links) {
      if (!link.isAcquisition &&
          !link.isCover &&
          !_isImageLink(link) &&
          _sameDocument(link.uri, target)) {
        return true;
      }
    }
  }
  return false;
}

bool _sameDocument(Uri first, Uri second) =>
    first.toString() == second.toString();

Uri? _coverUri(MangaPublication publication) {
  Uri? candidate;
  for (final link in publication.images) {
    if (link.isCover) {
      candidate = link.uri;
      break;
    }
  }
  candidate ??= publication.images.isEmpty
      ? null
      : publication.images.first.uri;
  if (candidate == null) return null;
  try {
    return requireMangaPersistablePublicHttpsUri(
      candidate.toString(),
      field: 'Saved manga cover URL',
    );
  } on FormatException {
    // Signed/credential-bearing covers remain usable for the current catalog
    // session but are deliberately not copied into the persistent Library.
    return null;
  }
}

bool _isImageLink(MangaCatalogLink link) {
  if (!_isPublicHttpsLink(link)) return false;
  final mediaType = _normalizedMediaType(link.mediaType);
  if (mediaType != null) return _readerImageMediaTypes.contains(mediaType);
  final path = link.uri.path.toLowerCase();
  return _readerImageExtensions.any(path.endsWith);
}

bool _looksLikeCbzAcquisition(MangaCatalogLink link) {
  if (!link.isAcquisition) return false;
  final mediaType = _normalizedMediaType(link.mediaType);
  if (mediaType != null && _cbzMediaTypes.contains(mediaType)) return true;
  return link.uri.path.toLowerCase().endsWith('.cbz');
}

bool _isPublicHttpsLink(MangaCatalogLink link) {
  try {
    requireMangaPublicHttpsUri(link.uri.toString(), field: 'Manga link URL');
    return true;
  } on FormatException {
    return false;
  }
}

Uri _requireCredentialFreeCatalogUri(Object? value, {required String field}) {
  return requireMangaPersistablePublicHttpsUri(value, field: field);
}

String? _normalizedMediaType(String? value) {
  final normalized = value?.split(';').first.trim().toLowerCase();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

(int, int)? _pageDimensions(Map<String, Object?> properties) {
  final widthValue = properties['width'];
  final heightValue = properties['height'];
  final width = widthValue is num && widthValue.isFinite
      ? widthValue.toInt()
      : null;
  final height = heightValue is num && heightValue.isFinite
      ? heightValue.toInt()
      : null;
  if (width == null ||
      height == null ||
      width <= 0 ||
      height <= 0 ||
      width > 100000 ||
      height > 100000) {
    return null;
  }
  return (width, height);
}

bool _sameOrigin(Uri first, Uri second) =>
    first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
    first.host.toLowerCase() == second.host.toLowerCase() &&
    first.port == second.port;

String _boundedChapterLabel(
  String value, {
  int maximum = 256,
  required String fallbackMessage,
}) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximum ||
      normalized.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
    throw MangaReaderBuildException(
      MangaReaderBuildFailure.invalidChapter,
      fallbackMessage,
    );
  }
  return normalized;
}

String _friendlyError(Object error) {
  if (error is MangaCatalogHttpException) {
    return switch (error.statusCode) {
      401 || 403 => 'That manga source rejected its credentials.',
      404 => 'That manga source could not be found.',
      429 => 'That manga source is busy. Try again shortly.',
      _ => 'That manga source could not be reached.',
    };
  }
  if (error is TimeoutException) {
    return 'That manga source took too long to respond.';
  }
  if (error is MangaReaderBuildException) return error.message;
  if (error is MangaCbzAcquisitionException) return error.message;
  if (error is FormatException) {
    return _boundedError(error.message);
  }
  if (error is StateError) return _boundedError(error.message);
  return 'TetoTV could not complete that manga action.';
}

String _boundedError(Object? value) {
  var text = (value?.toString() ?? '')
      .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), 'source')
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty) text = 'TetoTV could not complete that manga action.';
  return text.length <= 240 ? text : '${text.substring(0, 237)}...';
}

String? _boundedIdentity(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.length > 512 ||
      normalized.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
    return null;
  }
  return normalized;
}

String _identityDigest(String value) => _digest(value).substring(0, 40);

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

const Set<String> _readerImageMediaTypes = <String>{
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
};

const Set<String> _readerImageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
};

const int _maximumPersistedCatalogHops = 32;

const Set<String> _cbzMediaTypes = <String>{
  'application/vnd.comicbook+zip',
  'application/x-cbz',
  'application/zip',
};
