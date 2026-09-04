import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/manga/application/manga_acquisition_controller.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_acquisition_service.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_artwork.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_screen.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/domain/repository_format.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

enum MangaHubSection { library, browse, downloads, sources }

extension on MangaHubSection {
  String get label => switch (this) {
    MangaHubSection.library => 'Library',
    MangaHubSection.browse => 'Browse',
    MangaHubSection.downloads => 'Downloads',
    MangaHubSection.sources => 'Sources',
  };

  IconData get icon => switch (this) {
    MangaHubSection.library => Icons.local_library_rounded,
    MangaHubSection.browse => Icons.explore_rounded,
    MangaHubSection.downloads => Icons.download_done_rounded,
    MangaHubSection.sources => Icons.hub_rounded,
  };
}

class MangaScreen extends ConsumerStatefulWidget {
  const MangaScreen({this.autofocusNavigation = false, super.key});

  final bool autofocusNavigation;

  @override
  ConsumerState<MangaScreen> createState() => _MangaScreenState();
}

class _MangaScreenState extends ConsumerState<MangaScreen> {
  final _queryController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'manga.search');
  final _fallbackContentFocus = FocusNode(debugLabel: 'manga.content.first');
  final _classicNavigationFocus = FocusNode(debugLabel: 'manga.navigation');
  final _sectionFocus = <MangaHubSection, FocusNode>{
    for (final section in MangaHubSection.values)
      section: FocusNode(debugLabel: 'manga.section.${section.name}'),
  };
  MangaHubSection _section = MangaHubSection.library;
  bool _searchEditing = false;

  MangaHubController get _controller =>
      ref.read(mangaHubControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller.initialize());
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    _searchFocus.dispose();
    _fallbackContentFocus.dispose();
    _classicNavigationFocus.dispose();
    for (final node in _sectionFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _setSection(MangaHubSection value) {
    if (_section == value) return;
    setState(() => _section = value);
    if (value != MangaHubSection.browse) {
      _queryController.clear();
      _controller.setQuery('');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  void _refresh() {
    final state = ref.read(mangaHubControllerProvider);
    if (_section == MangaHubSection.downloads) {
      unawaited(
        ref.read(mangaAcquisitionControllerProvider.notifier).refresh(),
      );
    }
    if (_section == MangaHubSection.sources) {
      unawaited(ref.read(marketplaceControllerProvider.notifier).refresh());
    }
    if (_section == MangaHubSection.browse && state.selectedSource != null) {
      unawaited(_controller.refresh());
    } else {
      unawaited(_controller.initialize());
    }
  }

  void _searchMangaExtensions(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    unawaited(
      ref.read(mangaExtensionControllerProvider.notifier).search(query),
    );
  }

  KeyEventResult _handleHeaderKey(KeyEvent event, TetoTopLevelLayout layout) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_searchFocus.hasFocus && _searchEditing) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        (_searchFocus.hasFocus ||
            _sectionFocus[MangaHubSection.library]!.hasFocus)) {
      layout.focusRail();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
        _searchFocus.hasFocus) {
      _sectionFocus[_section]!.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(settingsPreferencesProvider);
    final state = ref.watch(mangaHubControllerProvider);
    final extensions = ref.watch(mangaExtensionControllerProvider);
    final acquisitions = ref.watch(mangaAcquisitionControllerProvider);
    final marketplace = ref.watch(marketplaceControllerProvider);
    ref.listen<MangaHubState>(mangaHubControllerProvider, (previous, next) {
      final error = next.error;
      if (error != null && error != previous?.error) _showMessage(error);
    });
    ref.listen<MangaAcquisitionState>(mangaAcquisitionControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error != null && error != previous?.error) _showMessage(error);
    });
    ref.listen<MangaExtensionState>(mangaExtensionControllerProvider, (
      previous,
      next,
    ) {
      final error = next.error;
      if (error != null && error != previous?.error) _showMessage(error);
    });

    return TetoTopLevelShell(
      preferences: preferences,
      activeDestination: TopNavigationDestination.manga,
      firstContentFocusNode: _searchFocus,
      fallbackContentFocusNode: _fallbackContentFocus,
      autofocusRail: widget.autofocusNavigation,
      onActiveDestinationPressed: _refresh,
      builder: (context, layout) => Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) => _handleHeaderKey(event, layout),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!layout.usesPersistentNavigation)
              MainNavigationBar(
                active: MainNavigationDestination.manga,
                preferences: preferences,
                activeFocusNode: _classicNavigationFocus,
                onActivePressed: _refresh,
              ),
            Expanded(
              child: Padding(
                padding: layout.usesSideNavigation
                    ? EdgeInsets.zero
                    : const EdgeInsets.fromLTRB(18, 12, 18, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _MangaHeader(
                      state: state,
                      queryController: _queryController,
                      searchFocus: _searchFocus,
                      searchVisible: _section == MangaHubSection.browse,
                      onSearchEditingChanged: (value) => _searchEditing = value,
                      onSearchChanged: _controller.setQuery,
                      onSearchSubmitted: _searchMangaExtensions,
                      onRefresh: state.isLoading ? null : _refresh,
                    ),
                    const SizedBox(height: 12),
                    _MangaSectionBar(
                      selected: _section,
                      focusNodes: _sectionFocus,
                      onSelected: _setSection,
                      onExitLeft: layout.usesPersistentNavigation
                          ? layout.focusRail
                          : _classicNavigationFocus.requestFocus,
                    ),
                    const SizedBox(height: 14),
                    if (state.isLoading)
                      LinearProgressIndicator(
                        key: const ValueKey('manga-loading'),
                        minHeight: 2,
                        color: context.appPalette.accentBright,
                      )
                    else
                      const SizedBox(height: 2),
                    const SizedBox(height: 8),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: switch (_section) {
                          MangaHubSection.library => _MangaLibraryView(
                            key: const ValueKey('manga-library'),
                            state: state,
                            firstFocusNode: _fallbackContentFocus,
                            onBrowse: () => _setSection(MangaHubSection.browse),
                            onOpen: _openLibraryEntry,
                            onRemove: _removeLibraryEntry,
                          ),
                          MangaHubSection.browse => _MangaBrowseView(
                            key: const ValueKey('manga-browse'),
                            state: state,
                            extensions: extensions,
                            firstFocusNode: _fallbackContentFocus,
                            onAddSource: _addSource,
                            onSelectSource: (source) =>
                                unawaited(_controller.selectSource(source.id)),
                            onBack: _controller.back,
                            onNavigate: (link) =>
                                unawaited(_controller.navigate(link)),
                            onOpenPublication: _showPublication,
                            onSelectExtensionProvider: (providerId) {
                              ref
                                  .read(
                                    mangaExtensionControllerProvider.notifier,
                                  )
                                  .selectProvider(providerId);
                            },
                            onSearchExtensions: _searchMangaExtensions,
                            onOpenExtensionTitle: _showExtensionTitle,
                            onManageExtensions: () =>
                                context.push('/settings/marketplace'),
                          ),
                          MangaHubSection.downloads => _MangaDownloadsView(
                            key: const ValueKey('manga-downloads'),
                            state: acquisitions,
                            firstFocusNode: _fallbackContentFocus,
                            onBrowse: () => _setSection(MangaHubSection.browse),
                            onOpen: _openDownload,
                            onCancel: _cancelDownload,
                            onRetry: _retryDownload,
                            onDelete: _deleteDownload,
                          ),
                          MangaHubSection.sources => _MangaSourcesView(
                            key: const ValueKey('manga-sources'),
                            sources: state.sources,
                            marketplace: marketplace,
                            selectedSourceId: state.selectedSource?.id,
                            firstFocusNode: _fallbackContentFocus,
                            onAddRepository: _addMangaRepository,
                            onRefreshRepositories: () => unawaited(
                              ref
                                  .read(marketplaceControllerProvider.notifier)
                                  .refresh(),
                            ),
                            onToggleRepository: (repository) => unawaited(
                              _setMangaRepositoryEnabled(repository),
                            ),
                            onRemoveRepository: (repository) =>
                                unawaited(_removeMangaRepository(repository)),
                            onInstallExtension: (addon) =>
                                unawaited(_installMangaExtension(addon)),
                            onToggleExtension: (addon) =>
                                unawaited(_setMangaExtensionEnabled(addon)),
                            onUninstallExtension: (addon) =>
                                unawaited(_uninstallMangaExtension(addon)),
                            onBrowseExtensions: () =>
                                _setSection(MangaHubSection.browse),
                            onAddCatalog: _addSource,
                            onOpen: (source) async {
                              if (source.kind ==
                                  StoredMangaSourceKind.repository) {
                                await _controller.selectSource(source.id);
                                return;
                              }
                              if (await _controller.selectSource(source.id)) {
                                _setSection(MangaHubSection.browse);
                              }
                            },
                            onToggle: (source) => unawaited(
                              _controller.setSourceEnabled(
                                source.id,
                                !source.enabled,
                              ),
                            ),
                            onCredentials: _editCredentials,
                            onRemove: _removeSource,
                            onManageExtensions: () =>
                                context.push('/settings/marketplace'),
                          ),
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addSource() async {
    final draft = await showDialog<_MangaSourceDraft>(
      context: context,
      builder: (context) => const _MangaSourceDialog(),
    );
    if (draft == null) return;
    final added = await _controller.addSource(
      draft.uri,
      credential: draft.credential,
    );
    if (added && mounted) {
      _showMessage('Manga source added.');
      _setSection(MangaHubSection.sources);
    }
  }

  Future<void> _addMangaRepository() async {
    final input = await showDialog<String>(
      context: context,
      builder: (context) => const _MangaRepositoryDialog(),
    );
    if (input == null) return;
    final candidates = splitSourceUrlInput(input);
    final rejection = _repositoryFormatRejection(candidates);
    if (rejection != null) {
      _showMessage(rejection);
      return;
    }
    try {
      final result = await ref
          .read(marketplaceControllerProvider.notifier)
          .addRepositories(input);
      if (!mounted) return;
      final detail = result.rejected.isEmpty
          ? result.summary
          : '${result.summary} ${result.rejected.first}';
      _showMessage(detail);
    } catch (_) {
      _showMessage('TetoTV could not add that manga repository.');
    }
  }

  Future<void> _setMangaRepositoryEnabled(AddonRepository repository) async {
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .setRepositoryEnabled(repository, !repository.enabled);
    } catch (_) {
      _showMessage('TetoTV could not update that repository.');
    }
  }

  Future<void> _removeMangaRepository(AddonRepository repository) async {
    final confirmed = await _confirm(
      title: 'Remove repository?',
      message:
          'Installed extensions stay installed. Add this repository URL again later if you want to browse its catalog or receive updates.',
      action: 'Remove',
    );
    if (!confirmed) return;
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .removeRepository(repository);
      _showMessage('Manga repository removed.');
    } catch (_) {
      _showMessage('TetoTV could not remove that repository.');
    }
  }

  Future<void> _installMangaExtension(MarketplaceAddon addon) async {
    final marketplace = ref.read(marketplaceControllerProvider);
    final installed = marketplace.installedById(addon.id);
    final updating = installed != null;
    final confirmed = await _confirm(
      title: '${updating ? 'Update' : 'Install'} ${addon.name}?',
      message:
          'This third-party manga source can receive manga searches and selected title or chapter IDs and can make bounded public internet requests to validated HTTPS destinations. It runs in TetoTV’s restricted provider runtime and cannot access account tokens, device files, or native Android APIs. Only continue if you trust its repository.',
      action: updating ? 'Update' : 'Install',
    );
    if (!confirmed) return;
    try {
      await ref.read(marketplaceControllerProvider.notifier).install(addon);
      _showMessage('${addon.name} ${updating ? 'updated' : 'installed'}.');
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('TetoTV could not install ${addon.name}.');
    }
  }

  Future<void> _setMangaExtensionEnabled(InstalledStreamingAddon addon) async {
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .setAddonEnabled(addon.manifest.id, !addon.enabled);
    } catch (_) {
      _showMessage('TetoTV could not update ${addon.manifest.name}.');
    }
  }

  Future<void> _uninstallMangaExtension(InstalledStreamingAddon addon) async {
    final confirmed = await _confirm(
      title: 'Uninstall ${addon.manifest.name}?',
      message:
          'This source will stop appearing in Manga. Saved reading progress and downloaded chapters are kept.',
      action: 'Uninstall',
    );
    if (!confirmed) return;
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .uninstall(addon.manifest.id);
      _showMessage('${addon.manifest.name} uninstalled.');
    } catch (_) {
      _showMessage('TetoTV could not uninstall ${addon.manifest.name}.');
    }
  }

  Future<void> _editCredentials(StoredMangaSource source) async {
    final draft = await showDialog<_MangaCredentialDraft>(
      context: context,
      builder: (context) => _MangaCredentialDialog(sourceName: source.name),
    );
    if (draft == null) return;
    try {
      final store = ref.read(mangaSourceCredentialStoreProvider);
      if (draft.clear) {
        await store.delete(source.id);
        _showMessage('Credentials removed from protected storage.');
        return;
      }
      final credential = draft.credential;
      if (credential == null) return;
      await store.write(source.id, credential);
      _showMessage('Credentials saved in protected storage.');
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('TetoTV could not update that protected credential.');
    }
  }

  Future<void> _removeSource(StoredMangaSource source) async {
    final confirmed = await _confirm(
      title: 'Remove ${source.name}?',
      message:
          'This removes the source, its protected credential, saved library entries, reading progress, and its manga downloads from TetoTV.',
      action: 'Remove',
    );
    if (!confirmed) return;
    try {
      final removed = await _controller.removeSource(source.id);
      if (removed) _showMessage('Manga source and its local data removed.');
    } catch (_) {
      _showMessage(
        'TetoTV could not safely remove all downloaded files. The source was kept.',
      );
    }
  }

  Future<void> _removeLibraryEntry(MangaLibraryEntry entry) async {
    final extensionController = ref.read(
      mangaExtensionControllerProvider.notifier,
    );
    if (extensionController.isExtensionLibraryEntry(entry)) {
      try {
        final title = await extensionController.openLibraryEntry(entry);
        if (title == null) return;
        await extensionController.toggleLibrary(title);
        await _controller.initialize();
        _showMessage('Removed from your manga library.');
      } catch (error) {
        _showMessage(
          error is StateError
              ? error.message
              : 'TetoTV could not remove that extension title.',
        );
      }
      return;
    }
    if (await _controller.removeLibraryEntry(entry)) {
      _showMessage('Removed from your manga library.');
    }
  }

  Future<void> _openLibraryEntry(MangaLibraryEntry entry) async {
    final extensionController = ref.read(
      mangaExtensionControllerProvider.notifier,
    );
    if (extensionController.isExtensionLibraryEntry(entry)) {
      try {
        final title = await extensionController.openLibraryEntry(entry);
        if (title != null) await _showExtensionTitle(title);
      } catch (error) {
        _showMessage(
          error is StateError
              ? error.message
              : 'TetoTV could not reopen that extension title.',
        );
      }
      return;
    }
    final publication = await _controller.openLibraryEntry(entry);
    if (publication == null) {
      final message = ref.read(mangaHubControllerProvider).error;
      if (message != null) _showMessage(message);
      return;
    }
    await _showPublication(publication);
  }

  Future<void> _showPublication(MangaPublication publication) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _MangaPublicationSheet(
        publication: publication,
        source: ref.read(mangaHubControllerProvider).selectedSource,
        inLibrary: _isInLibrary(publication),
        onRead: () async {
          Navigator.of(sheetContext).pop();
          await _readPublication(publication);
        },
        onLibrary: () async {
          await _controller.toggleLibrary(publication);
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
        },
        onDownload: () {
          Navigator.of(sheetContext).pop();
          unawaited(_downloadPublication(publication));
        },
      ),
    );
  }

  Future<void> _showExtensionTitle(MangaExtensionTitle title) async {
    final extensionController = ref.read(
      mangaExtensionControllerProvider.notifier,
    );
    try {
      final inLibrary = await extensionController.isInLibrary(title);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => _MangaExtensionTitleSheet(
          title: title,
          initiallyInLibrary: inLibrary,
          loadChapters: () => extensionController.chapters(title),
          onRead: (chapter) async {
            Navigator.of(sheetContext).pop();
            await _readExtensionChapter(title, chapter);
          },
          onDownload: (chapter) {
            Navigator.of(sheetContext).pop();
            unawaited(_downloadExtensionChapter(title, chapter));
          },
          onLibrary: () async {
            final saved = await extensionController.toggleLibrary(title);
            await _controller.initialize();
            return saved;
          },
        ),
      );
    } catch (error) {
      _showMessage(
        error is StateError
            ? error.message
            : 'That manga source could not open this title.',
      );
    }
  }

  Future<void> _readExtensionChapter(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter,
  ) async {
    try {
      final request = await ref
          .read(mangaExtensionControllerProvider.notifier)
          .buildReaderRequest(title, chapter);
      if (mounted) {
        await context.push<void>(MangaReaderScreen.routePath, extra: request);
      }
    } catch (error) {
      _showMessage(
        error is StateError
            ? error.message
            : 'That manga chapter could not be opened.',
      );
    }
  }

  Future<void> _downloadExtensionChapter(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter,
  ) async {
    try {
      final reader = await ref
          .read(mangaExtensionControllerProvider.notifier)
          .buildReaderRequest(title, chapter);
      final pages = <MangaReadingOrderPage>[];
      for (final page in reader.pages) {
        final resource = page.resource;
        if (resource is! MangaRemotePageResource) {
          throw StateError('This chapter did not return remote image pages.');
        }
        pages.add(
          MangaReadingOrderPage(
            uri: resource.uri,
            headers: resource.headers,
            pixelWidth: page.pixelWidth,
            pixelHeight: page.pixelHeight,
            isCover: page.isCover,
          ),
        );
      }
      final request = MangaAcquisitionRequest(
        jobId: _mangaDownloadJobId(reader),
        sourceId: reader.sourceId,
        publicationId: reader.publicationId,
        chapterId: reader.chapterId,
        seriesTitle: reader.seriesTitle,
        chapterTitle: reader.chapterTitle,
        chapterNumber: reader.chapterNumber,
        initialPageIndex: reader.initialPageIndex,
        acquisition: MangaReadingOrderAcquisition(pages),
      );
      await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .start(request);
      if (!mounted) return;
      _setSection(MangaHubSection.downloads);
      _showMessage('Manga chapter download started.');
    } catch (error) {
      _showMessage(
        error is StateError
            ? error.message
            : error is MangaAcquisitionException
            ? error.message
            : 'TetoTV could not start that manga download.',
      );
    }
  }

  bool _isInLibrary(MangaPublication publication) {
    final state = ref.read(mangaHubControllerProvider);
    final source = state.selectedSource;
    if (source == null) return false;
    final entryId = mangaPublicationStableId(publication);
    return state.library.any(
      (entry) => entry.sourceId == source.id && entry.entryId == entryId,
    );
  }

  Future<void> _readPublication(MangaPublication publication) async {
    try {
      final request = await _controller.buildReaderRequest(publication);
      final jobId = _mangaDownloadJobId(request);
      final existing = ref.read(mangaAcquisitionControllerProvider).job(jobId);
      if (existing?.status == MangaDownloadJobStatus.completed) {
        final local = await ref
            .read(mangaAcquisitionControllerProvider.notifier)
            .openCompleted(jobId);
        if (local != null && mounted) {
          final resumed = await _controller.applySavedProgress(local);
          if (mounted) {
            await context.push<void>(
              MangaReaderScreen.routePath,
              extra: resumed,
            );
          }
          return;
        }
      }
      if (!mounted) return;
      await context.push<void>(MangaReaderScreen.routePath, extra: request);
    } on MangaReaderBuildException catch (error) {
      if (error.failure == MangaReaderBuildFailure.noImagePages) {
        try {
          final request = await _buildDownloadRequest(publication);
          final operation = await ref
              .read(mangaAcquisitionControllerProvider.notifier)
              .start(request);
          if (!mounted) return;
          final local = await showDialog<MangaReaderRequest>(
            context: context,
            barrierDismissible: false,
            builder: (context) => _MangaAcquisitionDialog(
              operation: operation,
              title: publication.title,
            ),
          );
          if (local != null && mounted) {
            final resumed = await _controller.applySavedProgress(local);
            if (mounted) {
              await context.push<void>(
                MangaReaderScreen.routePath,
                extra: resumed,
              );
            }
          }
          return;
        } on MangaCbzAcquisitionException catch (acquisitionError) {
          _showMessage(acquisitionError.message);
          return;
        } on MangaAcquisitionException catch (acquisitionError) {
          _showMessage(acquisitionError.message);
          return;
        }
      }
      _showMessage(error.message);
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('TetoTV could not open that manga.');
    }
  }

  Future<void> _downloadPublication(MangaPublication publication) async {
    try {
      final request = await _buildDownloadRequest(publication);
      await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .start(request);
      if (!mounted) return;
      _setSection(MangaHubSection.downloads);
      _showMessage('Manga download started.');
    } on MangaReaderBuildException catch (error) {
      _showMessage(error.message);
    } on MangaCbzAcquisitionException catch (error) {
      _showMessage(error.message);
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('TetoTV could not start that manga download.');
    }
  }

  Future<MangaAcquisitionRequest> _buildDownloadRequest(
    MangaPublication publication,
  ) async {
    try {
      final reader = await _controller.buildReaderRequest(publication);
      final source = ref.read(mangaHubControllerProvider).selectedSource;
      if (source == null) {
        throw const MangaReaderBuildException(
          MangaReaderBuildFailure.noSourceSelected,
          'Choose a manga source first.',
        );
      }
      final pages = <MangaReadingOrderPage>[];
      for (final page in reader.pages) {
        final resource = page.resource;
        if (resource is! MangaRemotePageResource) {
          throw const MangaAcquisitionException(
            MangaAcquisitionFailureCode.invalidRequest,
            'This manga item does not contain downloadable remote pages.',
          );
        }
        pages.add(
          MangaReadingOrderPage(
            uri: resource.uri,
            pixelWidth: page.pixelWidth,
            pixelHeight: page.pixelHeight,
            isCover: page.isCover,
          ),
        );
      }
      return MangaAcquisitionRequest(
        jobId: _mangaDownloadJobId(reader),
        sourceId: reader.sourceId,
        publicationId: reader.publicationId,
        chapterId: reader.chapterId,
        seriesTitle: reader.seriesTitle,
        chapterTitle: reader.chapterTitle,
        chapterNumber: reader.chapterNumber,
        initialPageIndex: reader.initialPageIndex,
        credentialOrigin: source.uri,
        acquisition: MangaReadingOrderAcquisition(pages),
      );
    } on MangaReaderBuildException catch (error) {
      if (error.failure != MangaReaderBuildFailure.noImagePages) rethrow;
      final selection = await _controller.selectCbzAcquisition(publication);
      final chapterTitle = publication.subtitle?.trim();
      final chapterId = mangaPublicationStableId(publication);
      return MangaAcquisitionRequest.fromCbzSelection(
        jobId: _mangaDownloadJobIdFromParts(
          selection.sourceId,
          selection.publicationId,
          chapterId,
        ),
        selection: selection,
        chapterId: chapterId,
        seriesTitle: publication.title,
        chapterTitle: chapterTitle == null || chapterTitle.isEmpty
            ? publication.title
            : chapterTitle,
      );
    }
  }

  Future<void> _openDownload(MangaDownloadJob job) async {
    try {
      final request = await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .openCompleted(job.id);
      if (request == null) {
        _showMessage('That manga download is not ready yet.');
        return;
      }
      if (mounted) {
        final resumed = await _controller.applySavedProgress(request);
        if (mounted) {
          await context.push<void>(MangaReaderScreen.routePath, extra: resumed);
        }
      }
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('TetoTV could not open that manga download.');
    }
  }

  Future<void> _cancelDownload(MangaDownloadJob job) async {
    try {
      await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .cancel(job.id);
      _showMessage('Manga download cancelled.');
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('TetoTV could not cancel that manga download.');
    }
  }

  Future<void> _retryDownload(MangaDownloadJob job) async {
    try {
      await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .retryInSession(job.id);
      _showMessage('Manga download restarted.');
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    }
  }

  Future<void> _deleteDownload(MangaDownloadJob job) async {
    final confirmed = await _confirm(
      title: 'Delete ${job.seriesTitle}?',
      message:
          'This removes the downloaded pages from this device. Your library entry and reading progress are kept.',
      action: 'Delete',
    );
    if (!confirmed) return;
    try {
      await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .delete(job.id);
      _showMessage('Downloaded manga removed.');
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('TetoTV could not remove that manga download.');
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async =>
      (await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      )) ??
      false;
}

class _MangaAcquisitionDialog extends StatefulWidget {
  const _MangaAcquisitionDialog({required this.operation, required this.title});

  final MangaAcquisitionOperation operation;
  final String title;

  @override
  State<_MangaAcquisitionDialog> createState() =>
      _MangaAcquisitionDialogState();
}

class _MangaAcquisitionDialogState extends State<_MangaAcquisitionDialog> {
  late MangaAcquisitionProgress _progress;
  StreamSubscription<MangaAcquisitionProgress>? _subscription;
  String? _error;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _progress = widget.operation.currentProgress;
    _subscription = widget.operation.progress.listen((progress) {
      if (mounted) setState(() => _progress = progress);
    });
    unawaited(
      widget.operation.completed.then(
        (request) {
          if (mounted) Navigator.of(context).pop(request);
        },
        onError: (Object error, StackTrace _) {
          if (!mounted) return;
          setState(() {
            _error = error is MangaAcquisitionException
                ? error.message
                : 'The manga download could not be completed.';
          });
        },
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _cancel() async {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    await widget.operation.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final fraction = _progress.fraction;
    return AlertDialog(
      title: Text('Preparing ${widget.title}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_error ?? _progressDescription(_progress)),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: fraction),
            if (_progress.pageCount case final total?) ...[
              const SizedBox(height: 8),
              Text(
                '${_progress.completedPages.clamp(0, total)} of $total pages',
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_error == null)
          TextButton(
            onPressed: _cancelling ? null : _cancel,
            child: Text(_cancelling ? 'Cancelling…' : 'Cancel'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_error == null ? 'Keep downloading' : 'Close'),
        ),
      ],
    );
  }
}

class _MangaHeader extends StatelessWidget {
  const _MangaHeader({
    required this.state,
    required this.queryController,
    required this.searchFocus,
    required this.searchVisible,
    required this.onSearchEditingChanged,
    required this.onSearchChanged,
    required this.onSearchSubmitted,
    required this.onRefresh,
  });

  final MangaHubState state;
  final TextEditingController queryController;
  final FocusNode searchFocus;
  final bool searchVisible;
  final ValueChanged<bool> onSearchEditingChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSearchSubmitted;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 720;
      final previewBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: context.appPalette.accent.withValues(alpha: .18),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: context.appPalette.accent.withValues(alpha: .52),
          ),
        ),
        child: const Text(
          'DEVELOPER PREVIEW',
          maxLines: 1,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900),
        ),
      );
      final title = Row(
        children: [
          Icon(
            Icons.menu_book_rounded,
            color: context.appPalette.accentBright,
            size: compact ? 27 : 32,
          ),
          const SizedBox(width: 10),
          Text(
            'Manga',
            style:
                (compact
                        ? Theme.of(context).textTheme.headlineSmall
                        : Theme.of(context).textTheme.headlineMedium)
                    ?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 10),
          if (compact)
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: previewBadge,
              ),
            ),
          if (!compact) previewBadge,
        ],
      );
      final refresh = _MangaIconAction(
        icon: Icons.refresh_rounded,
        tooltip: 'Refresh manga',
        onPressed: onRefresh,
      );
      if (!searchVisible) {
        return Row(
          children: [
            Expanded(child: title),
            refresh,
          ],
        );
      }
      final search = SizedBox(
        width: compact ? double.infinity : 380,
        child: TvTextInput(
          controller: queryController,
          focusNode: searchFocus,
          labelText: 'Search manga',
          hintText: 'Title, author, or tag',
          keyboardTitle: 'Search manga',
          compactHeader: true,
          variant: TvTextInputVariant.headerSearch,
          onEditingChanged: onSearchEditingChanged,
          onChanged: onSearchChanged,
          onSubmitted: onSearchSubmitted,
        ),
      );
      return compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: title),
                    refresh,
                  ],
                ),
                const SizedBox(height: 10),
                search,
              ],
            )
          : Row(
              children: [
                Expanded(child: title),
                search,
                const SizedBox(width: 10),
                refresh,
              ],
            );
    },
  );
}

class _MangaSectionBar extends StatelessWidget {
  const _MangaSectionBar({
    required this.selected,
    required this.focusNodes,
    required this.onSelected,
    required this.onExitLeft,
  });

  final MangaHubSection selected;
  final Map<MangaHubSection, FocusNode> focusNodes;
  final ValueChanged<MangaHubSection> onSelected;
  final VoidCallback onExitLeft;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    child: Row(
      children: [
        for (final section in MangaHubSection.values) ...[
          _MangaSectionButton(
            section: section,
            selected: section == selected,
            focusNode: focusNodes[section]!,
            onPressed: () => onSelected(section),
            onExitLeft: section == MangaHubSection.library
                ? onExitLeft
                : () => focusNodes[MangaHubSection.values[section.index - 1]]!
                      .requestFocus(),
            onExitRight: section == MangaHubSection.values.last
                ? null
                : () => focusNodes[MangaHubSection.values[section.index + 1]]!
                      .requestFocus(),
          ),
          if (section != MangaHubSection.values.last) const SizedBox(width: 8),
        ],
      ],
    ),
  );
}

class _MangaSectionButton extends StatelessWidget {
  const _MangaSectionButton({
    required this.section,
    required this.selected,
    required this.focusNode,
    required this.onPressed,
    required this.onExitLeft,
    required this.onExitRight,
  });

  final MangaHubSection section;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final VoidCallback onExitLeft;
  final VoidCallback? onExitRight;

  @override
  Widget build(BuildContext context) => TvFocusable(
    key: ValueKey('manga-section-${section.name}'),
    focusNode: focusNode,
    onPressed: onPressed,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        onExitLeft();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
          onExitRight != null) {
        onExitRight!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    borderRadius: BorderRadius.circular(10),
    focusScale: 1.02,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      constraints: const BoxConstraints(minHeight: 42),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
      decoration: BoxDecoration(
        color: selected
            ? context.appPalette.accent.withValues(alpha: .24)
            : context.appPalette.surface.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected
              ? context.appPalette.accentBright.withValues(alpha: .82)
              : context.appPalette.primaryText.withValues(alpha: .10),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(section.icon, size: 19),
          const SizedBox(width: 7),
          Text(
            section.label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );
}

class _MangaBrowseView extends StatelessWidget {
  const _MangaBrowseView({
    required this.state,
    required this.extensions,
    required this.firstFocusNode,
    required this.onAddSource,
    required this.onSelectSource,
    required this.onBack,
    required this.onNavigate,
    required this.onOpenPublication,
    required this.onSelectExtensionProvider,
    required this.onSearchExtensions,
    required this.onOpenExtensionTitle,
    required this.onManageExtensions,
    super.key,
  });

  final MangaHubState state;
  final MangaExtensionState extensions;
  final FocusNode firstFocusNode;
  final VoidCallback onAddSource;
  final ValueChanged<StoredMangaSource> onSelectSource;
  final bool Function() onBack;
  final ValueChanged<MangaCatalogLink> onNavigate;
  final ValueChanged<MangaPublication> onOpenPublication;
  final ValueChanged<String?> onSelectExtensionProvider;
  final ValueChanged<String> onSearchExtensions;
  final ValueChanged<MangaExtensionTitle> onOpenExtensionTitle;
  final VoidCallback onManageExtensions;

  @override
  Widget build(BuildContext context) {
    final catalogs = state.sources
        .where(
          (source) =>
              source.enabled && source.kind != StoredMangaSourceKind.repository,
        )
        .toList(growable: false);
    final enabledExtensions = extensions.enabledProviders;
    final showingExtensionSearch =
        extensions.searching ||
        extensions.query.isNotEmpty ||
        extensions.results.isNotEmpty;
    if (showingExtensionSearch) {
      return CustomScrollView(
        key: const ValueKey('manga-extension-results'),
        slivers: [
          SliverToBoxAdapter(
            child: _MangaExtensionSearchHeader(
              state: extensions,
              onSelectProvider: onSelectExtensionProvider,
              onSearchAgain: () => onSearchExtensions(extensions.query),
              onManageExtensions: onManageExtensions,
            ),
          ),
          if (extensions.searching)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
          if (extensions.results.isEmpty && !extensions.searching)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MangaEmptyState(
                icon: Icons.search_off_rounded,
                title: 'No extension results',
                message: extensions.failures.isEmpty
                    ? 'Try another title or choose Search all sources.'
                    : '${extensions.failures.length} source(s) could not complete this search.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(3, 8, 3, 30),
              sliver: SliverGrid.builder(
                itemCount: extensions.results.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 210,
                  childAspectRatio: .60,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 14,
                ),
                itemBuilder: (context, index) => _MangaExtensionTitleCard(
                  title: extensions.results[index],
                  focusNode: index == 0 ? firstFocusNode : null,
                  onPressed: () =>
                      onOpenExtensionTitle(extensions.results[index]),
                ),
              ),
            ),
        ],
      );
    }
    if (state.selectedFeed == null) {
      return ListView(
        key: const ValueKey('manga-source-picker'),
        padding: const EdgeInsets.fromLTRB(3, 3, 3, 24),
        children: [
          Text(
            'Manga extensions',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            enabledExtensions.isEmpty
                ? 'No manga extensions are enabled. TetoTV bundles and recommends no sources.'
                : 'Choose one source or Search all, then enter a title in the search bar above.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (enabledExtensions.isNotEmpty)
                _MangaActionButton(
                  key: const ValueKey('manga-search-all-extensions'),
                  icon: Icons.manage_search_rounded,
                  label: 'Search all sources',
                  focusNode: firstFocusNode,
                  prominent: extensions.selectedProviderId == null,
                  onPressed: () => onSelectExtensionProvider(null),
                ),
              for (final addon in enabledExtensions)
                _MangaActionButton(
                  key: ValueKey('manga-extension-source-${addon.manifest.id}'),
                  icon: Icons.extension_rounded,
                  label: addon.manifest.name,
                  prominent: extensions.selectedProviderId == addon.manifest.id,
                  onPressed: () => onSelectExtensionProvider(addon.manifest.id),
                ),
              _MangaActionButton(
                key: const ValueKey('manga-manage-extensions'),
                icon: Icons.extension_rounded,
                label: 'Manage extensions',
                focusNode: enabledExtensions.isEmpty && catalogs.isEmpty
                    ? firstFocusNode
                    : null,
                onPressed: onManageExtensions,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Choose a catalog',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            'Only sources you add are shown here.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var index = 0; index < catalogs.length; index++)
                _MangaActionButton(
                  key: ValueKey('manga-open-source-${catalogs[index].id}'),
                  icon: Icons.menu_book_rounded,
                  label: catalogs[index].name,
                  onPressed: () => onSelectSource(catalogs[index]),
                ),
              _MangaActionButton(
                icon: Icons.add_link_rounded,
                label: 'Add source',
                onPressed: onAddSource,
              ),
            ],
          ),
        ],
      );
    }

    final feed = state.selectedFeed!;
    final navigation = <MangaNavigationItem>[
      ...feed.navigation,
      for (final group in feed.groups) ...group.navigation,
    ];
    final publications = state.visiblePublications;
    return CustomScrollView(
      key: ValueKey('manga-feed-${feed.documentUri}'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(3, 3, 3, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (state.breadcrumbs.isNotEmpty) ...[
                      _MangaIconAction(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Previous catalog',
                        onPressed: onBack,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            feed.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (feed.subtitle case final subtitle?)
                            Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                        ],
                      ),
                    ),
                    _MangaSourceBadge(source: state.selectedSource!),
                  ],
                ),
                if (navigation.isNotEmpty) ...[
                  const SizedBox(height: 13),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    child: Row(
                      children: [
                        for (
                          var index = 0;
                          index < navigation.length;
                          index++
                        ) ...[
                          _MangaActionButton(
                            icon: Icons.folder_open_rounded,
                            label: navigation[index].title,
                            focusNode: publications.isEmpty && index == 0
                                ? firstFocusNode
                                : null,
                            onPressed: () {
                              final links = navigation[index].links.where(
                                (link) => !link.isAcquisition && !link.isCover,
                              );
                              if (links.isNotEmpty) onNavigate(links.first);
                            },
                          ),
                          if (index != navigation.length - 1)
                            const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (publications.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _MangaEmptyState(
              icon: state.query.isEmpty
                  ? Icons.auto_stories_outlined
                  : Icons.search_off_rounded,
              title: state.query.isEmpty
                  ? 'No manga on this page'
                  : 'No matches',
              message: state.query.isEmpty
                  ? 'Open one of the catalog folders above or refresh this source.'
                  : 'Try a different title, author, or tag.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(3, 2, 3, 30),
            sliver: SliverGrid.builder(
              itemCount: publications.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 210,
                childAspectRatio: .60,
                crossAxisSpacing: 12,
                mainAxisSpacing: 14,
              ),
              itemBuilder: (context, index) => _MangaPublicationCard(
                publication: publications[index],
                source: state.selectedSource,
                focusNode: index == 0 ? firstFocusNode : null,
                onPressed: () => onOpenPublication(publications[index]),
              ),
            ),
          ),
      ],
    );
  }
}

class _MangaExtensionSearchHeader extends StatelessWidget {
  const _MangaExtensionSearchHeader({
    required this.state,
    required this.onSelectProvider,
    required this.onSearchAgain,
    required this.onManageExtensions,
  });

  final MangaExtensionState state;
  final ValueChanged<String?> onSelectProvider;
  final VoidCallback onSearchAgain;
  final VoidCallback onManageExtensions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(3, 3, 3, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Results for “${state.query}”',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 5),
        Text(
          state.searching
              ? '${state.results.length} result(s) so far • searching enabled sources…'
              : '${state.results.length} result(s) from installed manga extensions',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 11),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              _MangaActionButton(
                icon: Icons.manage_search_rounded,
                label: 'Search all',
                prominent: state.selectedProviderId == null,
                onPressed: () {
                  onSelectProvider(null);
                  onSearchAgain();
                },
              ),
              for (final addon in state.enabledProviders) ...[
                const SizedBox(width: 8),
                _MangaActionButton(
                  icon: Icons.extension_rounded,
                  label: addon.manifest.name,
                  prominent: state.selectedProviderId == addon.manifest.id,
                  onPressed: () {
                    onSelectProvider(addon.manifest.id);
                    onSearchAgain();
                  },
                ),
              ],
              const SizedBox(width: 8),
              _MangaActionButton(
                icon: Icons.settings_rounded,
                label: 'Manage extensions',
                onPressed: onManageExtensions,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MangaExtensionTitleCard extends StatelessWidget {
  const _MangaExtensionTitleCard({
    required this.title,
    required this.onPressed,
    this.focusNode,
  });

  final MangaExtensionTitle title;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => TvFocusable(
    key: ValueKey(
      'manga-extension-title-${title.providerId}-${title.id.hashCode}',
    ),
    focusNode: focusNode,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(11),
    focusScale: 1.025,
    child: DecoratedBox(
      decoration: _panelDecoration(context, radius: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
              child: MangaArtwork(
                uri: title.image,
                headers: title.imageHeaders,
                icon: Icons.menu_book_rounded,
                cacheWidth: 420,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 3),
            child: Text(
              title.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, height: 1.1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Text(
              '${title.providerName} • ${title.language.toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.appPalette.mutedText,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _MangaLibraryView extends StatelessWidget {
  const _MangaLibraryView({
    required this.state,
    required this.firstFocusNode,
    required this.onBrowse,
    required this.onOpen,
    required this.onRemove,
    super.key,
  });

  final MangaHubState state;
  final FocusNode firstFocusNode;
  final VoidCallback onBrowse;
  final ValueChanged<MangaLibraryEntry> onOpen;
  final ValueChanged<MangaLibraryEntry> onRemove;

  @override
  Widget build(BuildContext context) {
    if (state.library.isEmpty) {
      return _MangaEmptyState(
        icon: Icons.bookmark_add_outlined,
        title: 'Your manga library is empty',
        message:
            'Browse a source and save titles here. Library and reading progress stay on this device and profile.',
        actionLabel: 'Browse manga',
        onAction: onBrowse,
        focusNode: firstFocusNode,
      );
    }
    return ListView.separated(
      key: const ValueKey('manga-library-list'),
      padding: const EdgeInsets.fromLTRB(3, 3, 3, 30),
      itemCount: state.library.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = state.library[index];
        StoredMangaSource? source;
        for (final candidate in state.sources) {
          if (candidate.id == entry.sourceId) {
            source = candidate;
            break;
          }
        }
        return _MangaLibraryCard(
          entry: entry,
          source: source,
          focusNode: index == 0 ? firstFocusNode : null,
          onOpen: () => onOpen(entry),
          onRemove: () => onRemove(entry),
        );
      },
    );
  }
}

class _MangaDownloadsView extends StatelessWidget {
  const _MangaDownloadsView({
    required this.state,
    required this.firstFocusNode,
    required this.onBrowse,
    required this.onOpen,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
    super.key,
  });

  final MangaAcquisitionState state;
  final FocusNode firstFocusNode;
  final VoidCallback onBrowse;
  final ValueChanged<MangaDownloadJob> onOpen;
  final ValueChanged<MangaDownloadJob> onCancel;
  final ValueChanged<MangaDownloadJob> onRetry;
  final ValueChanged<MangaDownloadJob> onDelete;

  @override
  Widget build(BuildContext context) {
    final jobs = state.jobs;
    if (state.isInitializing && jobs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (jobs.isEmpty) {
      return _MangaEmptyState(
        icon: Icons.download_for_offline_outlined,
        title: 'No downloaded manga',
        message:
            'Download a title from one of your sources to read it without a connection.',
        actionLabel: 'Browse manga',
        onAction: onBrowse,
        focusNode: firstFocusNode,
      );
    }
    return ListView.separated(
      key: const ValueKey('manga-download-list'),
      padding: const EdgeInsets.fromLTRB(3, 3, 3, 30),
      itemCount: jobs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _MangaDownloadCard(
        job: jobs[index],
        progress: state.progress[jobs[index].id],
        focusNode: index == 0 ? firstFocusNode : null,
        onOpen: () => onOpen(jobs[index]),
        onCancel: () => onCancel(jobs[index]),
        onRetry: () => onRetry(jobs[index]),
        onDelete: () => onDelete(jobs[index]),
      ),
    );
  }
}

class _MangaSourcesView extends StatefulWidget {
  const _MangaSourcesView({
    required this.sources,
    required this.marketplace,
    required this.selectedSourceId,
    required this.firstFocusNode,
    required this.onAddRepository,
    required this.onRefreshRepositories,
    required this.onToggleRepository,
    required this.onRemoveRepository,
    required this.onInstallExtension,
    required this.onToggleExtension,
    required this.onUninstallExtension,
    required this.onBrowseExtensions,
    required this.onAddCatalog,
    required this.onOpen,
    required this.onToggle,
    required this.onCredentials,
    required this.onRemove,
    required this.onManageExtensions,
    super.key,
  });

  final List<StoredMangaSource> sources;
  final MarketplaceState marketplace;
  final String? selectedSourceId;
  final FocusNode firstFocusNode;
  final VoidCallback onAddRepository;
  final VoidCallback onRefreshRepositories;
  final ValueChanged<AddonRepository> onToggleRepository;
  final ValueChanged<AddonRepository> onRemoveRepository;
  final ValueChanged<MarketplaceAddon> onInstallExtension;
  final ValueChanged<InstalledStreamingAddon> onToggleExtension;
  final ValueChanged<InstalledStreamingAddon> onUninstallExtension;
  final VoidCallback onBrowseExtensions;
  final VoidCallback onAddCatalog;
  final ValueChanged<StoredMangaSource> onOpen;
  final ValueChanged<StoredMangaSource> onToggle;
  final ValueChanged<StoredMangaSource> onCredentials;
  final ValueChanged<StoredMangaSource> onRemove;
  final VoidCallback onManageExtensions;

  @override
  State<_MangaSourcesView> createState() => _MangaSourcesViewState();
}

class _MangaSourcesViewState extends State<_MangaSourcesView> {
  final _filter = TextEditingController();
  String? _language;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final byId = <String, MarketplaceAddon>{};
    for (final addon in widget.marketplace.catalog) {
      if (addon.isMangaProvider) {
        byId[marketplaceAddonIdentityKey(addon.id)] = addon;
      }
    }
    for (final installed in widget.marketplace.installed) {
      if (installed.manifest.isMangaProvider) {
        byId.putIfAbsent(
          marketplaceAddonIdentityKey(installed.manifest.id),
          () => installed.manifest,
        );
      }
    }
    final allMangaAddons = byId.values.toList(growable: false);
    final languages = marketplaceCatalogLanguages(allMangaAddons);
    if (_language != null && !languages.contains(_language)) {
      _language = null;
    }
    final query = _filter.text.trim().toLowerCase();
    final visibleAddons = filterAndSortMarketplaceCatalog(
      allMangaAddons.where(
        (addon) =>
            query.isEmpty ||
            addon.name.toLowerCase().contains(query) ||
            addon.author.toLowerCase().contains(query) ||
            addon.description.toLowerCase().contains(query),
      ),
      languageCode: _language,
      sort: MarketplaceCatalogSort.language,
    );

    return CustomScrollView(
      key: const ValueKey('manga-sources-list'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(3, 3, 3, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _MangaPolicyBanner(
                onAddRepository: widget.onAddRepository,
                onBrowse: widget.onBrowseExtensions,
                focusNode: widget.firstFocusNode,
              ),
              const SizedBox(height: 18),
              _MangaSourceSectionHeader(
                step: '1',
                title: 'Manga repositories',
                subtitle:
                    'Add only repositories you choose. No source URL is bundled or prefilled.',
                actions: [
                  _MangaActionButton(
                    key: const ValueKey('manga-add-extension-repository'),
                    icon: Icons.add_link_rounded,
                    label: 'Add repository',
                    prominent: true,
                    onPressed: widget.onAddRepository,
                  ),
                  _MangaIconAction(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Refresh repositories',
                    onPressed: widget.marketplace.loading
                        ? null
                        : widget.onRefreshRepositories,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (widget.marketplace.loading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (widget.marketplace.repositories.isEmpty)
                const _MangaEmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'No manga repositories added',
                  message:
                      'Add a compatible Seanime/Teto manga-provider repository to see installable sources. Native Mihon/Tachiyomi .pb and APK repositories use a different runtime and are not installed.',
                )
              else
                for (
                  var index = 0;
                  index < widget.marketplace.repositories.length;
                  index++
                ) ...[
                  _MangaRepositoryCard(
                    repository: widget.marketplace.repositories[index],
                    mangaExtensionCount: widget.marketplace.catalog
                        .where(
                          (addon) =>
                              addon.isMangaProvider &&
                              addon.repositoryUrl ==
                                  widget.marketplace.repositories[index].url,
                        )
                        .length,
                    error:
                        widget.marketplace.repositoryErrors[widget
                            .marketplace
                            .repositories[index]
                            .url],
                    onToggle: () => widget.onToggleRepository(
                      widget.marketplace.repositories[index],
                    ),
                    onRemove: () => widget.onRemoveRepository(
                      widget.marketplace.repositories[index],
                    ),
                  ),
                  if (index != widget.marketplace.repositories.length - 1)
                    const SizedBox(height: 9),
                ],
              const SizedBox(height: 22),
              _MangaSourceSectionHeader(
                step: '2',
                title: 'Manga extensions',
                subtitle:
                    'Install a source explicitly, then enable or disable it whenever you want.',
                actions: [
                  _MangaActionButton(
                    icon: Icons.tune_rounded,
                    label: 'All add-ons',
                    onPressed: widget.onManageExtensions,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final search = SizedBox(
                    width: constraints.maxWidth < 640
                        ? double.infinity
                        : constraints.maxWidth * .52,
                    child: TvTextInput(
                      key: const ValueKey('manga-extension-catalog-filter'),
                      controller: _filter,
                      labelText: 'Filter extensions',
                      hintText: 'Name or author',
                      keyboardTitle: 'Filter manga extensions',
                      onChanged: (_) => setState(() {}),
                    ),
                  );
                  final language = DropdownButton<String?>(
                    key: const ValueKey('manga-extension-language-filter'),
                    value: _language,
                    borderRadius: BorderRadius.circular(12),
                    hint: const Text('All languages'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All languages'),
                      ),
                      for (final code in languages)
                        DropdownMenuItem<String?>(
                          value: code,
                          child: Text(marketplaceCatalogLanguageLabel(code)),
                        ),
                    ],
                    onChanged: (value) => setState(() => _language = value),
                  );
                  if (constraints.maxWidth < 640) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        search,
                        const SizedBox(height: 8),
                        Align(alignment: Alignment.centerLeft, child: language),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      search,
                      const SizedBox(width: 12),
                      language,
                      const Spacer(),
                      Text(
                        '${visibleAddons.length} source${visibleAddons.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              if (visibleAddons.isEmpty)
                _MangaEmptyState(
                  icon: Icons.extension_off_rounded,
                  title: allMangaAddons.isEmpty
                      ? 'No compatible manga extensions found'
                      : 'No extensions match this filter',
                  message: allMangaAddons.isEmpty
                      ? 'Add or refresh a compatible manga repository first.'
                      : 'Clear the name or language filter and try again.',
                ),
            ]),
          ),
        ),
        if (visibleAddons.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            sliver: SliverList.builder(
              itemCount: visibleAddons.length,
              itemBuilder: (context, index) => Padding(
                padding: EdgeInsets.only(
                  bottom: index == visibleAddons.length - 1 ? 0 : 9,
                ),
                child: _MangaExtensionCatalogCard(
                  addon: visibleAddons[index],
                  installed: widget.marketplace.installedById(
                    visibleAddons[index].id,
                  ),
                  updateAvailable: widget.marketplace.updateAvailable(
                    visibleAddons[index],
                  ),
                  busy: marketplaceAddonIdsMatch(
                    widget.marketplace.busyAddonId ?? '',
                    visibleAddons[index].id,
                  ),
                  onInstall: () =>
                      widget.onInstallExtension(visibleAddons[index]),
                  onToggle: widget.onToggleExtension,
                  onUninstall: widget.onUninstallExtension,
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(3, 12, 3, 30),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Align(
                alignment: Alignment.centerLeft,
                child: _MangaActionButton(
                  key: const ValueKey('manga-browse-installed-extensions'),
                  icon: Icons.explore_rounded,
                  label: 'Browse installed sources',
                  prominent: true,
                  onPressed: widget.onBrowseExtensions,
                ),
              ),
              const SizedBox(height: 24),
              _MangaSourceSectionHeader(
                step: '3',
                title: 'Optional OPDS & data catalogs',
                subtitle:
                    'Advanced: connect a public OPDS feed or declarative Teto catalog. These are separate from extension repositories.',
                actions: [
                  _MangaActionButton(
                    key: const ValueKey('manga-add-data-catalog'),
                    icon: Icons.add_rounded,
                    label: 'Add catalog',
                    onPressed: widget.onAddCatalog,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (widget.sources.isEmpty)
                const _MangaEmptyState(
                  icon: Icons.link_off_rounded,
                  title: 'No data catalogs added',
                  message:
                      'This section is optional. Nothing is bundled or recommended by TetoTV.',
                )
              else
                for (var index = 0; index < widget.sources.length; index++) ...[
                  _MangaSourceCard(
                    source: widget.sources[index],
                    selected:
                        widget.sources[index].id == widget.selectedSourceId,
                    onOpen: () => widget.onOpen(widget.sources[index]),
                    onToggle: () => widget.onToggle(widget.sources[index]),
                    onCredentials: () =>
                        widget.onCredentials(widget.sources[index]),
                    onRemove: () => widget.onRemove(widget.sources[index]),
                  ),
                  if (index != widget.sources.length - 1)
                    const SizedBox(height: 10),
                ],
            ]),
          ),
        ),
      ],
    );
  }
}

class _MangaPolicyBanner extends StatelessWidget {
  const _MangaPolicyBanner({
    required this.onAddRepository,
    required this.onBrowse,
    required this.focusNode,
  });

  final VoidCallback onAddRepository;
  final VoidCallback onBrowse;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: _panelDecoration(context),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MangaActionButton(
              icon: Icons.add_link_rounded,
              label: 'Add repository',
              focusNode: focusNode,
              prominent: true,
              onPressed: onAddRepository,
            ),
            _MangaActionButton(
              icon: Icons.explore_rounded,
              label: 'Browse manga',
              onPressed: onBrowse,
            ),
          ],
        );
        final copy = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Add a repository. Install a source. Start reading.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Manga repositories are always user-added, and installing an extension is a separate confirmation. TetoTV bundles, prefills, and recommends no source. Only use sources you trust and are authorized to access.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        );
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [copy, const SizedBox(height: 12), actions],
          );
        }
        return Row(
          children: [
            Expanded(child: copy),
            const SizedBox(width: 18),
            actions,
          ],
        );
      },
    ),
  );
}

class _MangaSourceSectionHeader extends StatelessWidget {
  const _MangaSourceSectionHeader({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final String step;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final copy = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.appPalette.accent.withValues(alpha: .20),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: context.appPalette.accentBright.withValues(alpha: .45),
              ),
            ),
            child: Text(
              step,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 3),
                Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      );
      final actionRow = Wrap(spacing: 8, runSpacing: 8, children: actions);
      if (constraints.maxWidth < 760) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [copy, const SizedBox(height: 10), actionRow],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: copy),
          const SizedBox(width: 16),
          actionRow,
        ],
      );
    },
  );
}

class _MangaRepositoryCard extends StatelessWidget {
  const _MangaRepositoryCard({
    required this.repository,
    required this.mangaExtensionCount,
    required this.error,
    required this.onToggle,
    required this.onRemove,
  });

  final AddonRepository repository;
  final int mangaExtensionCount;
  final String? error;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(repository.url);
    final label = uri == null
        ? repository.url
        : '${uri.host}${uri.path == '/' ? '' : uri.path}';
    return Container(
      key: ValueKey('manga-extension-repository-${repository.url}'),
      padding: const EdgeInsets.all(13),
      decoration: _panelDecoration(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final info = Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: repository.enabled
                      ? context.appPalette.accent.withValues(alpha: .18)
                      : context.appPalette.surfaceRaised,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  repository.enabled
                      ? Icons.inventory_2_rounded
                      : Icons.inventory_2_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      error != null
                          ? error!
                          : '$mangaExtensionCount compatible manga extension${mangaExtensionCount == 1 ? '' : 's'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: error == null
                            ? context.appPalette.mutedText
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MangaActionButton(
                icon: repository.enabled
                    ? Icons.pause_circle_outline_rounded
                    : Icons.play_circle_outline_rounded,
                label: repository.enabled ? 'Disable' : 'Enable',
                onPressed: onToggle,
              ),
              _MangaIconAction(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Remove manga repository',
                onPressed: onRemove,
              ),
            ],
          );
          if (constraints.maxWidth < 680) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [info, const SizedBox(height: 10), actions],
            );
          }
          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 16),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _MangaExtensionCatalogCard extends StatelessWidget {
  const _MangaExtensionCatalogCard({
    required this.addon,
    required this.installed,
    required this.updateAvailable,
    required this.busy,
    required this.onInstall,
    required this.onToggle,
    required this.onUninstall,
  });

  final MarketplaceAddon addon;
  final InstalledStreamingAddon? installed;
  final bool updateAvailable;
  final bool busy;
  final VoidCallback onInstall;
  final ValueChanged<InstalledStreamingAddon> onToggle;
  final ValueChanged<InstalledStreamingAddon> onUninstall;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('manga-extension-catalog-${addon.id}'),
    padding: const EdgeInsets.all(13),
    decoration: _panelDecoration(context),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final current = installed;
        final compatible = addon.isCompatible;
        final info = Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: current?.enabled == true
                    ? context.appPalette.accent.withValues(alpha: .18)
                    : context.appPalette.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.extension_rounded),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          addon.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _MangaStatusBadge(
                        label: !compatible
                            ? 'UNSUPPORTED'
                            : current == null
                            ? 'AVAILABLE'
                            : current.enabled
                            ? 'ENABLED'
                            : 'DISABLED',
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${marketplaceCatalogLanguageLabel(marketplaceCatalogLanguageCode(addon))} · ${addon.author}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (addon.description.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      addon.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.appPalette.mutedText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (current == null || updateAvailable)
              _MangaActionButton(
                key: ValueKey('manga-extension-install-${addon.id}'),
                icon: updateAvailable
                    ? Icons.system_update_alt_rounded
                    : Icons.download_rounded,
                label: updateAvailable ? 'Update' : 'Install',
                prominent: true,
                onPressed: compatible && !busy ? onInstall : null,
              ),
            if (current != null) ...[
              _MangaActionButton(
                key: ValueKey('manga-extension-toggle-${addon.id}'),
                icon: current.enabled
                    ? Icons.pause_circle_outline_rounded
                    : Icons.play_circle_outline_rounded,
                label: current.enabled ? 'Disable' : 'Enable',
                onPressed: busy ? null : () => onToggle(current),
              ),
              _MangaIconAction(
                icon: Icons.delete_outline_rounded,
                tooltip: 'Uninstall ${addon.name}',
                onPressed: busy ? null : () => onUninstall(current),
              ),
            ],
            if (busy)
              const SizedBox.square(
                dimension: 26,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        );
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [info, const SizedBox(height: 11), actions],
          );
        }
        return Row(
          children: [
            Expanded(child: info),
            const SizedBox(width: 16),
            actions,
          ],
        );
      },
    ),
  );
}

class _MangaPublicationCard extends StatelessWidget {
  const _MangaPublicationCard({
    required this.publication,
    required this.source,
    required this.onPressed,
    this.focusNode,
  });

  final MangaPublication publication;
  final StoredMangaSource? source;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => TvFocusable(
    key: ValueKey('manga-publication-${mangaPublicationStableId(publication)}'),
    focusNode: focusNode,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(11),
    focusScale: 1.025,
    child: DecoratedBox(
      decoration: _panelDecoration(context, radius: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(10),
              ),
              child: MangaArtwork(
                uri: _cover(publication),
                sourceId: source?.id,
                sourceUri: source?.uri,
                icon: Icons.menu_book_rounded,
                cacheWidth: 420,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 3),
            child: Text(
              publication.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, height: 1.1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Text(
              publication.authors.isEmpty
                  ? (publication.languages.isEmpty
                        ? 'Manga'
                        : publication.languages.join(' · '))
                  : publication.authors.map((author) => author.name).join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.appPalette.mutedText,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _MangaLibraryCard extends StatelessWidget {
  const _MangaLibraryCard({
    required this.entry,
    required this.source,
    required this.onOpen,
    required this.onRemove,
    this.focusNode,
  });

  final MangaLibraryEntry entry;
  final StoredMangaSource? source;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: _panelDecoration(context),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 62,
            height: 88,
            child: MangaArtwork(
              uri: entry.coverUri,
              sourceId: source?.id,
              sourceUri: source?.uri,
              icon: Icons.menu_book_rounded,
              cacheWidth: 180,
            ),
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 5),
              Text(
                _libraryByline(entry),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _MangaActionButton(
          icon: Icons.auto_stories_rounded,
          label: 'Open',
          focusNode: focusNode,
          onPressed: onOpen,
        ),
        const SizedBox(width: 8),
        _MangaIconAction(
          icon: Icons.bookmark_remove_outlined,
          tooltip: 'Remove from library',
          onPressed: onRemove,
        ),
      ],
    ),
  );
}

class _MangaDownloadCard extends StatelessWidget {
  const _MangaDownloadCard({
    required this.job,
    required this.onOpen,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
    this.progress,
    this.focusNode,
  });

  final MangaDownloadJob job;
  final MangaAcquisitionProgress? progress;
  final FocusNode? focusNode;
  final VoidCallback onOpen;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final active = _isActiveDownload(job.status);
    final completedPages = progress?.completedPages ?? job.completedPages;
    final pageCount = progress?.pageCount ?? job.pageCount;
    final fraction = pageCount == null || pageCount == 0
        ? null
        : completedPages / pageCount;
    final primary = switch (job.status) {
      MangaDownloadJobStatus.completed => _MangaActionButton(
        icon: Icons.auto_stories_rounded,
        label: 'Read',
        focusNode: focusNode,
        prominent: true,
        onPressed: onOpen,
      ),
      MangaDownloadJobStatus.queued ||
      MangaDownloadJobStatus.resolving ||
      MangaDownloadJobStatus.downloading => _MangaActionButton(
        icon: Icons.close_rounded,
        label: 'Cancel',
        focusNode: focusNode,
        onPressed: onCancel,
      ),
      _ => _MangaActionButton(
        icon: Icons.refresh_rounded,
        label: 'Retry',
        focusNode: focusNode,
        onPressed: onRetry,
      ),
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final details = Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: context.appPalette.accent.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_downloadIcon(job.status)),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            job.seriesTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        _MangaStatusBadge(
                          label: progress == null
                              ? _downloadLabel(job.status)
                              : _progressLabel(progress!),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      job.chapterLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (active || fraction != null) ...[
                      const SizedBox(height: 9),
                      LinearProgressIndicator(value: fraction?.clamp(0, 1)),
                    ],
                    if (job.errorMessage case final error?) ...[
                      const SizedBox(height: 6),
                      Text(
                        error,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              primary,
              const SizedBox(width: 8),
              _MangaIconAction(
                icon: Icons.delete_outline_rounded,
                tooltip: active ? 'Cancel and delete' : 'Delete download',
                onPressed: onDelete,
              ),
            ],
          );
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: details),
              const SizedBox(width: 16),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _MangaSourceCard extends StatelessWidget {
  const _MangaSourceCard({
    required this.source,
    required this.selected,
    required this.onOpen,
    required this.onToggle,
    required this.onCredentials,
    required this.onRemove,
  });

  final StoredMangaSource source;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onToggle;
  final VoidCallback onCredentials;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: _panelDecoration(
      context,
      borderColor: selected
          ? context.appPalette.accentBright.withValues(alpha: .68)
          : null,
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final info = Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: source.enabled
                    ? context.appPalette.accent.withValues(alpha: .18)
                    : context.appPalette.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                source.kind == StoredMangaSourceKind.repository
                    ? Icons.hub_rounded
                    : Icons.menu_book_rounded,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 8),
                        const _MangaStatusBadge(label: 'OPEN'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${_sourceKindLabel(source.kind)} · ${source.uri.host}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MangaActionButton(
              icon: source.kind == StoredMangaSourceKind.repository
                  ? Icons.sync_rounded
                  : Icons.open_in_new_rounded,
              label: source.kind == StoredMangaSourceKind.repository
                  ? 'Sync'
                  : 'Open',
              onPressed: source.enabled ? onOpen : null,
            ),
            _MangaActionButton(
              icon: source.enabled
                  ? Icons.pause_circle_outline_rounded
                  : Icons.play_circle_outline_rounded,
              label: source.enabled ? 'Disable' : 'Enable',
              onPressed: onToggle,
            ),
            _MangaIconAction(
              icon: Icons.key_rounded,
              tooltip: 'Protected credentials',
              onPressed: onCredentials,
            ),
            _MangaIconAction(
              icon: Icons.delete_outline_rounded,
              tooltip: 'Remove source',
              onPressed: onRemove,
            ),
          ],
        );
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [info, const SizedBox(height: 12), actions],
          );
        }
        return Row(
          children: [
            Expanded(child: info),
            const SizedBox(width: 18),
            actions,
          ],
        );
      },
    ),
  );
}

class _MangaExtensionTitleSheet extends StatefulWidget {
  const _MangaExtensionTitleSheet({
    required this.title,
    required this.initiallyInLibrary,
    required this.loadChapters,
    required this.onRead,
    required this.onDownload,
    required this.onLibrary,
  });

  final MangaExtensionTitle title;
  final bool initiallyInLibrary;
  final Future<List<MangaExtensionChapter>> Function() loadChapters;
  final ValueChanged<MangaExtensionChapter> onRead;
  final ValueChanged<MangaExtensionChapter> onDownload;
  final Future<bool> Function() onLibrary;

  @override
  State<_MangaExtensionTitleSheet> createState() =>
      _MangaExtensionTitleSheetState();
}

class _MangaExtensionTitleSheetState extends State<_MangaExtensionTitleSheet> {
  late final Future<List<MangaExtensionChapter>> _chapters;
  late bool _inLibrary;
  bool _libraryBusy = false;

  @override
  void initState() {
    super.initState();
    _chapters = widget.loadChapters();
    _inLibrary = widget.initiallyInLibrary;
  }

  Future<void> _toggleLibrary() async {
    if (_libraryBusy) return;
    setState(() => _libraryBusy = true);
    try {
      final saved = await widget.onLibrary();
      if (mounted) setState(() => _inLibrary = saved);
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 940, maxHeight: 760),
      child: Material(
        color: context.appPalette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 14, 14),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: SizedBox(
                      width: 72,
                      height: 102,
                      child: MangaArtwork(
                        uri: widget.title.image,
                        headers: widget.title.imageHeaders,
                        cacheWidth: 220,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${widget.title.providerName} • ${widget.title.language.toUpperCase()}'
                          '${widget.title.year == null ? '' : ' • ${widget.title.year}'}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 10),
                        _MangaActionButton(
                          icon: _inLibrary
                              ? Icons.bookmark_remove_rounded
                              : Icons.bookmark_add_rounded,
                          label: _libraryBusy
                              ? 'Updating…'
                              : _inLibrary
                              ? 'Remove from library'
                              : 'Add to library',
                          onPressed: _libraryBusy ? null : _toggleLibrary,
                        ),
                      ],
                    ),
                  ),
                  _MangaIconAction(
                    icon: Icons.close_rounded,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(
              color: context.appPalette.primaryText.withValues(alpha: .1),
            ),
            Expanded(
              child: FutureBuilder<List<MangaExtensionChapter>>(
                future: _chapters,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const _MangaEmptyState(
                      icon: Icons.error_outline_rounded,
                      title: 'Chapters unavailable',
                      message: 'This manga source could not load its chapters.',
                    );
                  }
                  final chapters = snapshot.data ?? const [];
                  if (chapters.isEmpty) {
                    return const _MangaEmptyState(
                      icon: Icons.menu_book_outlined,
                      title: 'No chapters found',
                      message: 'This source did not return any chapters.',
                    );
                  }
                  return ListView.separated(
                    key: const ValueKey('manga-extension-chapters'),
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
                    itemCount: chapters.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final chapter = chapters[index];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: _panelDecoration(context, radius: 11),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    chapter.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (chapter.scanlator case final group?)
                                    Text(
                                      group,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            _MangaActionButton(
                              icon: Icons.auto_stories_rounded,
                              label: 'Read',
                              prominent: true,
                              onPressed: () => widget.onRead(chapter),
                            ),
                            const SizedBox(width: 8),
                            _MangaIconAction(
                              icon: Icons.download_rounded,
                              tooltip: 'Download chapter',
                              onPressed: () => widget.onDownload(chapter),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MangaPublicationSheet extends StatelessWidget {
  const _MangaPublicationSheet({
    required this.publication,
    required this.source,
    required this.inLibrary,
    required this.onRead,
    required this.onLibrary,
    required this.onDownload,
  });

  final MangaPublication publication;
  final StoredMangaSource? source;
  final bool inLibrary;
  final VoidCallback onRead;
  final VoidCallback onLibrary;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 880, maxHeight: 680),
      child: Material(
        color: context.appPalette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 116,
                      height: 164,
                      child: MangaArtwork(
                        uri: _cover(publication),
                        sourceId: source?.id,
                        sourceUri: source?.uri,
                        icon: Icons.menu_book_rounded,
                        cacheWidth: 300,
                      ),
                    ),
                  ),
                  const SizedBox(width: 17),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          publication.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        if (publication.subtitle case final subtitle?) ...[
                          const SizedBox(height: 4),
                          Text(subtitle),
                        ],
                        if (publication.authors.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            publication.authors
                                .map((author) => author.name)
                                .join(', '),
                            style: TextStyle(
                              color: context.appPalette.accentBright,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                        if (publication.languages.isNotEmpty) ...[
                          const SizedBox(height: 9),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final language in publication.languages)
                                _MangaStatusBadge(
                                  label: language.toUpperCase(),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              if (publication.description case final description?) ...[
                const SizedBox(height: 16),
                Text(description, style: Theme.of(context).textTheme.bodyLarge),
              ],
              if (publication.subjects.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final subject in publication.subjects.take(12))
                      Chip(label: Text(subject)),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _MangaActionButton(
                    icon: Icons.auto_stories_rounded,
                    label: 'Read now',
                    autofocus: true,
                    prominent: true,
                    onPressed: onRead,
                  ),
                  _MangaActionButton(
                    icon: inLibrary
                        ? Icons.bookmark_remove_rounded
                        : Icons.bookmark_add_rounded,
                    label: inLibrary ? 'Remove from library' : 'Add to library',
                    onPressed: onLibrary,
                  ),
                  _MangaActionButton(
                    icon: Icons.download_rounded,
                    label: 'Download',
                    onPressed: onDownload,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MangaEmptyState extends StatelessWidget {
  const _MangaEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.focusNode,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: context.appPalette.accent.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: context.appPalette.accent.withValues(alpha: .44),
                ),
              ),
              child: Icon(
                icon,
                size: 34,
                color: context.appPalette.accentBright,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              _MangaActionButton(
                icon: Icons.arrow_forward_rounded,
                label: actionLabel!,
                focusNode: focusNode,
                onPressed: onAction,
                prominent: true,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _MangaActionButton extends StatelessWidget {
  const _MangaActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
    this.prominent = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return ExcludeFocus(
      excluding: !enabled,
      child: Opacity(
        opacity: enabled ? 1 : .42,
        child: TvFocusable(
          focusNode: focusNode,
          autofocus: autofocus,
          enabled: enabled,
          onPressed: onPressed ?? () {},
          borderRadius: BorderRadius.circular(10),
          focusScale: 1.025,
          child: Container(
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: prominent
                  ? context.appPalette.accent
                  : context.appPalette.selectableSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: prominent
                    ? context.appPalette.accentBright.withValues(alpha: .76)
                    : context.appPalette.primaryText.withValues(alpha: .12),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 19),
                if (label.isNotEmpty) ...[
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MangaIconAction extends StatelessWidget {
  const _MangaIconAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: _MangaActionButton(icon: icon, label: '', onPressed: onPressed),
  );
}

class _MangaStatusBadge extends StatelessWidget {
  const _MangaStatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: context.appPalette.accent.withValues(alpha: .18),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(
        color: context.appPalette.accent.withValues(alpha: .46),
      ),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: context.appPalette.accentBright,
        fontSize: 9,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _MangaSourceBadge extends StatelessWidget {
  const _MangaSourceBadge({required this.source});

  final StoredMangaSource source;

  @override
  Widget build(BuildContext context) => _MangaStatusBadge(label: source.name);
}

class _MangaSourceDraft {
  const _MangaSourceDraft(this.uri, this.credential);

  final Uri uri;
  final MangaSourceCredential? credential;
}

class _MangaRepositoryDialog extends StatefulWidget {
  const _MangaRepositoryDialog();

  @override
  State<_MangaRepositoryDialog> createState() => _MangaRepositoryDialogState();
}

class _MangaRepositoryDialogState extends State<_MangaRepositoryDialog> {
  final _urls = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _urls.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final value = data?.text?.trim();
    if (value == null || value.isEmpty) return;
    setState(() {
      _urls.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      _error = null;
    });
  }

  void _submit() {
    final values = splitSourceUrlInput(_urls.text);
    if (values.isEmpty) {
      setState(() => _error = 'Enter a public HTTPS repository URL.');
      return;
    }
    final rejection = _repositoryFormatRejection(values);
    if (rejection != null) {
      setState(() => _error = rejection);
      return;
    }
    Navigator.of(context).pop(_urls.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add manga extension repository'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste a public HTTPS Seanime/Teto repository containing manga-provider extensions. You can separate multiple URLs with spaces.',
            ),
            const SizedBox(height: 8),
            Text(
              'The field starts empty. TetoTV does not bundle, prefill, or recommend repositories.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.appPalette.mutedText,
              ),
            ),
            const SizedBox(height: 14),
            TvTextInput(
              key: const ValueKey('manga-extension-repository-input'),
              controller: _urls,
              labelText: 'Repository URL',
              hintText: 'https://example.org/manga-marketplace.json',
              keyboardTitle: 'Manga repository URL',
              keyboardType: TextInputType.url,
              autofocus: true,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton.icon(
        onPressed: _paste,
        icon: const Icon(Icons.content_paste_rounded),
        label: const Text('Paste'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Add repository')),
    ],
  );
}

String? _repositoryFormatRejection(Iterable<String> values) {
  for (final value in values) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) continue;
    final inspection = inspectExtensionRepositoryUri(uri);
    if (inspection.rejectionMessage case final message?) return message;
  }
  return null;
}

class _MangaCredentialDraft {
  const _MangaCredentialDraft.save(this.credential) : clear = false;
  const _MangaCredentialDraft.clear() : credential = null, clear = true;

  final MangaSourceCredential? credential;
  final bool clear;
}

enum _MangaCredentialKind { none, basic, bearer, apiKey }

class _MangaSourceDialog extends StatefulWidget {
  const _MangaSourceDialog();

  @override
  State<_MangaSourceDialog> createState() => _MangaSourceDialogState();
}

class _MangaSourceDialogState extends State<_MangaSourceDialog> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _header = TextEditingController(text: 'X-API-Key');
  _MangaCredentialKind _kind = _MangaCredentialKind.none;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _secret.dispose();
    _header.dispose();
    super.dispose();
  }

  void _submit() {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      setState(
        () => _error = 'Enter a public HTTPS catalog or repository URL.',
      );
      return;
    }
    try {
      final credential = _credentialFromFields(
        kind: _kind,
        username: _username.text,
        secret: _secret.text,
        header: _header.text,
      );
      Navigator.of(context).pop(_MangaSourceDraft(uri, credential));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add OPDS or data catalog'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Add an OPDS 1, OPDS 2, or declarative Teto data catalog. Extension repositories belong in the Manga repositories section. TetoTV does not provide a source list.',
            ),
            const SizedBox(height: 14),
            TvTextInput(
              controller: _url,
              labelText: 'Catalog URL',
              hintText: 'https://example.org/opds',
              keyboardTitle: 'Manga catalog URL',
              keyboardType: TextInputType.url,
              autofocus: true,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<_MangaCredentialKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Authentication'),
              items: const [
                DropdownMenuItem(
                  value: _MangaCredentialKind.none,
                  child: Text('None'),
                ),
                DropdownMenuItem(
                  value: _MangaCredentialKind.basic,
                  child: Text('Username and password'),
                ),
                DropdownMenuItem(
                  value: _MangaCredentialKind.bearer,
                  child: Text('Bearer token'),
                ),
                DropdownMenuItem(
                  value: _MangaCredentialKind.apiKey,
                  child: Text('API key header'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _kind = value ?? _MangaCredentialKind.none),
            ),
            if (_kind == _MangaCredentialKind.basic) ...[
              const SizedBox(height: 12),
              TvTextInput(controller: _username, labelText: 'Username'),
            ],
            if (_kind != _MangaCredentialKind.none) ...[
              if (_kind == _MangaCredentialKind.apiKey) ...[
                const SizedBox(height: 12),
                TvTextInput(controller: _header, labelText: 'Header name'),
              ],
              const SizedBox(height: 12),
              TvTextInput(
                controller: _secret,
                labelText: _kind == _MangaCredentialKind.basic
                    ? 'Password'
                    : _kind == _MangaCredentialKind.bearer
                    ? 'Token'
                    : 'API key',
                obscureText: true,
              ),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Add catalog')),
    ],
  );
}

class _MangaCredentialDialog extends StatefulWidget {
  const _MangaCredentialDialog({required this.sourceName});

  final String sourceName;

  @override
  State<_MangaCredentialDialog> createState() => _MangaCredentialDialogState();
}

class _MangaCredentialDialogState extends State<_MangaCredentialDialog> {
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _header = TextEditingController(text: 'X-API-Key');
  _MangaCredentialKind _kind = _MangaCredentialKind.basic;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _secret.dispose();
    _header.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final credential = _credentialFromFields(
        kind: _kind,
        username: _username.text,
        secret: _secret.text,
        header: _header.text,
      );
      if (credential == null) {
        throw const FormatException('Choose a credential.');
      }
      Navigator.of(context).pop(_MangaCredentialDraft.save(credential));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.sourceName} credentials'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Credentials are kept in protected device storage and are sent only to this source’s origin.',
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<_MangaCredentialKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Authentication'),
              items: const [
                DropdownMenuItem(
                  value: _MangaCredentialKind.basic,
                  child: Text('Username and password'),
                ),
                DropdownMenuItem(
                  value: _MangaCredentialKind.bearer,
                  child: Text('Bearer token'),
                ),
                DropdownMenuItem(
                  value: _MangaCredentialKind.apiKey,
                  child: Text('API key header'),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _kind = value ?? _MangaCredentialKind.basic),
            ),
            if (_kind == _MangaCredentialKind.basic) ...[
              const SizedBox(height: 12),
              TvTextInput(controller: _username, labelText: 'Username'),
            ],
            if (_kind == _MangaCredentialKind.apiKey) ...[
              const SizedBox(height: 12),
              TvTextInput(controller: _header, labelText: 'Header name'),
            ],
            const SizedBox(height: 12),
            TvTextInput(
              controller: _secret,
              labelText: _kind == _MangaCredentialKind.basic
                  ? 'Password'
                  : _kind == _MangaCredentialKind.bearer
                  ? 'Token'
                  : 'API key',
              obscureText: true,
              autofocus: true,
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () =>
            Navigator.pop(context, const _MangaCredentialDraft.clear()),
        child: const Text('Remove saved credential'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save securely')),
    ],
  );
}

MangaSourceCredential? _credentialFromFields({
  required _MangaCredentialKind kind,
  required String username,
  required String secret,
  required String header,
}) {
  final safeSecret = secret.trim();
  if (kind == _MangaCredentialKind.none) return null;
  if (safeSecret.isEmpty) throw const FormatException('Enter the credential.');
  return switch (kind) {
    _MangaCredentialKind.none => null,
    _MangaCredentialKind.basic =>
      username.trim().isEmpty
          ? throw const FormatException('Enter the username.')
          : MangaSourceCredential.basic(
              username: username.trim(),
              password: secret,
            ),
    _MangaCredentialKind.bearer => MangaSourceCredential.bearer(safeSecret),
    _MangaCredentialKind.apiKey =>
      header.trim().isEmpty
          ? throw const FormatException('Enter the API key header name.')
          : MangaSourceCredential.apiKey(
              headerName: header.trim(),
              value: safeSecret,
            ),
  };
}

BoxDecoration _panelDecoration(
  BuildContext context, {
  double radius = 12,
  Color? borderColor,
}) => BoxDecoration(
  color: context.appPalette.surface.withValues(alpha: .90),
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(
    color: borderColor ?? context.appPalette.primaryText.withValues(alpha: .10),
  ),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: .22),
      blurRadius: 18,
      offset: const Offset(0, 8),
    ),
  ],
);

Uri? _cover(MangaPublication publication) {
  for (final image in publication.images) {
    if (image.isCover) return image.uri;
  }
  return publication.images.isEmpty ? null : publication.images.first.uri;
}

String _libraryByline(MangaLibraryEntry entry) {
  final authors = entry.metadata['authors'];
  if (authors is List) {
    final values = authors.whereType<String>().where(
      (value) => value.isNotEmpty,
    );
    if (values.isNotEmpty) return values.join(', ');
  }
  final subtitle = entry.metadata['subtitle'];
  return subtitle is String && subtitle.isNotEmpty ? subtitle : 'Saved manga';
}

String _sourceKindLabel(StoredMangaSourceKind kind) => switch (kind) {
  StoredMangaSourceKind.repository => 'Teto repository',
  StoredMangaSourceKind.opds1 => 'OPDS 1',
  StoredMangaSourceKind.opds2 => 'OPDS 2',
};

String _downloadLabel(MangaDownloadJobStatus status) => switch (status) {
  MangaDownloadJobStatus.queued => 'QUEUED',
  MangaDownloadJobStatus.resolving => 'PREPARING',
  MangaDownloadJobStatus.downloading => 'DOWNLOADING',
  MangaDownloadJobStatus.paused => 'PAUSED',
  MangaDownloadJobStatus.completed => 'READY',
  MangaDownloadJobStatus.failed => 'FAILED',
  MangaDownloadJobStatus.cancelled => 'CANCELLED',
  MangaDownloadJobStatus.needsReauthorization => 'RECONNECT',
};

String _progressLabel(MangaAcquisitionProgress progress) =>
    switch (progress.phase) {
      MangaAcquisitionPhase.queued => 'QUEUED',
      MangaAcquisitionPhase.resolving => 'PREPARING',
      MangaAcquisitionPhase.downloading => 'DOWNLOADING',
      MangaAcquisitionPhase.extracting => 'EXTRACTING',
      MangaAcquisitionPhase.completed => 'READY',
      MangaAcquisitionPhase.failed => 'FAILED',
      MangaAcquisitionPhase.cancelled => 'CANCELLED',
    };

String _progressDescription(MangaAcquisitionProgress progress) =>
    switch (progress.phase) {
      MangaAcquisitionPhase.queued => 'Waiting to start…',
      MangaAcquisitionPhase.resolving => 'Checking the source securely…',
      MangaAcquisitionPhase.downloading => 'Downloading manga pages…',
      MangaAcquisitionPhase.extracting => 'Checking and preparing the CBZ…',
      MangaAcquisitionPhase.completed => 'Ready to read.',
      MangaAcquisitionPhase.failed => 'The manga download failed.',
      MangaAcquisitionPhase.cancelled => 'The manga download was cancelled.',
    };

bool _isActiveDownload(MangaDownloadJobStatus status) => switch (status) {
  MangaDownloadJobStatus.queued ||
  MangaDownloadJobStatus.resolving ||
  MangaDownloadJobStatus.downloading => true,
  _ => false,
};

String _mangaDownloadJobId(MangaReaderRequest request) =>
    _mangaDownloadJobIdFromParts(
      request.sourceId,
      request.publicationId,
      request.chapterId,
    );

String _mangaDownloadJobIdFromParts(
  String sourceId,
  String publicationId,
  String chapterId,
) =>
    'manga.${sha256.convert(utf8.encode('$sourceId\n$publicationId\n$chapterId')).toString().substring(0, 48)}';

IconData _downloadIcon(MangaDownloadJobStatus status) => switch (status) {
  MangaDownloadJobStatus.queued => Icons.schedule_rounded,
  MangaDownloadJobStatus.resolving => Icons.manage_search_rounded,
  MangaDownloadJobStatus.downloading => Icons.downloading_rounded,
  MangaDownloadJobStatus.paused => Icons.pause_circle_outline_rounded,
  MangaDownloadJobStatus.completed => Icons.download_done_rounded,
  MangaDownloadJobStatus.failed => Icons.error_outline_rounded,
  MangaDownloadJobStatus.cancelled => Icons.cancel_outlined,
  MangaDownloadJobStatus.needsReauthorization => Icons.key_off_rounded,
};
