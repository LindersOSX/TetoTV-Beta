import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/features/aniyomi/application/aniyomi_controller.dart';
import 'package:anime_tv/features/aniyomi/presentation/aniyomi_screen.dart';
import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_navigation.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/manga/application/manga_acquisition_controller.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/application/manga_continue_policy.dart';
import 'package:anime_tv/features/manga/data/manga_acquisition_service.dart';
import 'package:anime_tv/features/manga/data/manga_catalog_client.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/data/manga_library_service.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/manga/domain/manga_source_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_artwork.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_screen.dart';
import 'package:anime_tv/features/manga/presentation/manga_library_view.dart';
import 'package:anime_tv/features/manga/presentation/manga_tracking_dialog.dart';
import 'package:anime_tv/features/manga/presentation/manga_backup_dialog.dart';
import 'package:anime_tv/features/manga/presentation/manga_chapter_sheet.dart';
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

/// One user action keeps its original controllers and source across every
/// asynchronous hop. Global local downloads remain shareable; adoption binds
/// them to the profile that clicked, never the profile active when I/O finishes.
class _MangaActionBinding {
  _MangaActionBinding({
    required this.hub,
    required this.extension,
    required this.downloads,
    required this.store,
    required this.isCurrent,
  });
  final MangaHubController hub;
  final MangaExtensionController extension;
  final MangaAcquisitionController downloads;
  final MangaStore store;
  final bool Function() isCurrent;
  void check() {
    if (!isCurrent()) {
      throw StateError('Profile changed. Close and reopen this manga.');
    }
  }

  Future<void> checkEntry(MangaLibraryEntry entry) async {
    check();
    final owner = await hub.ownerKey;
    check();
    if (entry.ownerKey != owner) {
      throw StateError('This manga belongs to another profile.');
    }
  }
}

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
  late TetoLocalizations _ui;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ui = TetoLocalizations.of(context);
  }

  final _queryController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'manga.search');
  final _fallbackContentFocus = FocusNode(debugLabel: 'manga.content.first');
  final _classicNavigationFocus = FocusNode(debugLabel: 'manga.navigation');
  final _sourcesEntry = _MangaSourcesEntry();
  final _sectionFocus = <MangaHubSection, FocusNode>{
    for (final section in MangaHubSection.values)
      section: FocusNode(debugLabel: 'manga.section.${section.name}'),
  };
  MangaHubSection _section = MangaHubSection.library;
  bool _searchEditing = false;

  MangaHubController get _controller =>
      ref.read(mangaHubControllerProvider.notifier);

  _MangaActionBinding _bindAction({bool catalog = false}) {
    final hub = _controller;
    final extension = ref.read(mangaExtensionControllerProvider.notifier);
    final source = hub.snapshot.selectedSource;
    return _MangaActionBinding(
      hub: hub,
      extension: extension,
      downloads: ref.read(mangaAcquisitionControllerProvider.notifier),
      store: ref.read(mangaStoreProvider),
      isCurrent: () =>
          mounted &&
          hub.mounted &&
          extension.mounted &&
          identical(_controller, hub) &&
          identical(
            ref.read(mangaExtensionControllerProvider.notifier),
            extension,
          ) &&
          (!catalog ||
              (hub.snapshot.selectedSource?.id == source?.id &&
                  hub.snapshot.selectedSource?.uri == source?.uri)),
    );
  }

  Future<void> _openBoundReader(
    _MangaActionBinding binding,
    MangaReaderRequest request,
  ) async {
    binding.check();
    final resumed = await binding.hub.applySavedProgress(request);
    binding.check();
    if (!mounted) return;
    await context.push<void>(MangaReaderScreen.routePath, extra: resumed);
    if (binding.isCurrent()) await binding.hub.initialize();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.autofocusNavigation && ref.read(isTelevisionProvider)) {
        requestTvFocusAndReveal(_sectionFocus[MangaHubSection.library]!);
      }
      unawaited(_controller.initialize());
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
      SnackBar(
        content: Text(_ui.text(message)),
        duration: const Duration(seconds: 4),
      ),
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
    final aniyomiEnabled = ref.watch(aniyomiEnabledProvider);
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
      firstContentFocusNode: _sectionFocus[_section]!,
      fallbackContentFocusNode: _fallbackContentFocus,
      autofocusRail: widget.autofocusNavigation,
      onActiveDestinationPressed: () {
        _refresh();
        requestTvFocusAndReveal(_sectionFocus[_section]!);
      },
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
                      onExitDown: () {
                        if (_section == MangaHubSection.sources &&
                            _sourcesEntry.focusFirst != null) {
                          _sourcesEntry.focusFirst!();
                        } else {
                          requestTvFocusAndReveal(_fallbackContentFocus);
                        }
                      },
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
                          MangaHubSection.library => MangaLibraryView(
                            key: const ValueKey('manga-library'),
                            state: state,
                            firstFocusNode: _fallbackContentFocus,
                            onExitUp: () => requestTvFocusAndReveal(
                              _sectionFocus[MangaHubSection.library]!,
                            ),
                            onBrowse: () => _setSection(MangaHubSection.browse),
                            onOpen: _openLibraryEntry,
                            onRemove: _removeLibraryEntry,
                            onContinue: _continueLibraryEntry,
                            onMigrate: _migrateLibraryEntry,
                            onTracking: _trackLibraryEntry,
                            onAcknowledge: _acknowledgeUpdates,
                            onCheckUpdates: _checkLibraryUpdates,
                            onBackup: () async {
                              if (await showMangaBackupDialog(context, ref) &&
                                  mounted) {
                                await _controller.initialize();
                              }
                            },
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
                            onPause: _pauseDownload,
                            onRetry: _retryDownload,
                            onDelete: _deleteDownload,
                          ),
                          MangaHubSection.sources => _MangaSourcesView(
                            key: const ValueKey('manga-sources'),
                            showAniyomiExperiments: aniyomiEnabled,
                            entry: _sourcesEntry,
                            sources: state.sources,
                            marketplace: marketplace,
                            selectedSourceId: state.selectedSource?.id,
                            firstFocusNode: _fallbackContentFocus,
                            onExitUp: () => requestTvFocusAndReveal(
                              _sectionFocus[MangaHubSection.sources]!,
                            ),
                            onExitLeft: layout.usesPersistentNavigation
                                ? layout.focusRail
                                : _classicNavigationFocus.requestFocus,
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
    _setSection(MangaHubSection.sources);
    await _addMangaRepository();
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
      _showMessage(_ui.text("TetoTV could not add that manga repository."));
    }
  }

  Future<void> _setMangaRepositoryEnabled(AddonRepository repository) async {
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .setRepositoryEnabled(repository, !repository.enabled);
    } catch (_) {
      _showMessage(_ui.text("TetoTV could not update that repository."));
    }
  }

  Future<void> _removeMangaRepository(AddonRepository repository) async {
    final confirmed = await _confirm(
      title: _ui.text("Remove repository?"),
      message: _ui.text(
        "Installed extensions stay installed. Add this repository URL again later if you want to browse its catalog or receive updates.",
      ),
      action: 'Remove',
    );
    if (!confirmed) return;
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .removeRepository(repository);
      _showMessage(_ui.text("Manga repository removed."));
    } catch (_) {
      _showMessage(_ui.text("TetoTV could not remove that repository."));
    }
  }

  Future<void> _installMangaExtension(MarketplaceAddon addon) async {
    final marketplace = ref.read(marketplaceControllerProvider);
    final installed = marketplace.installedById(addon.id);
    final updating = installed != null;
    final confirmed = await _confirm(
      title: '${updating ? 'Update' : 'Install'} ${addon.name}?',
      message: _ui.text(
        "This third-party manga source can receive manga searches and selected title or chapter IDs and can make bounded public internet requests to validated HTTPS destinations. It runs in TetoTV’s restricted provider runtime and cannot access account tokens, device files, or native Android APIs. Only continue if you trust its repository.",
      ),
      action: updating ? 'Update' : 'Install',
    );
    if (!confirmed) return;
    try {
      await ref.read(marketplaceControllerProvider.notifier).install(addon);
      _showMessage('${addon.name} ${updating ? 'updated' : 'installed'}.');
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage(
        _ui.text("TetoTV could not install {value1}.", {'value1': addon.name}),
      );
    }
  }

  Future<void> _setMangaExtensionEnabled(InstalledStreamingAddon addon) async {
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .setAddonEnabled(addon.manifest.id, !addon.enabled);
    } catch (_) {
      _showMessage(
        _ui.text("TetoTV could not update {value1}.", {
          'value1': addon.manifest.name,
        }),
      );
    }
  }

  Future<void> _uninstallMangaExtension(InstalledStreamingAddon addon) async {
    final confirmed = await _confirm(
      title: _ui.text("Uninstall {value1}?", {'value1': addon.manifest.name}),
      message: _ui.text(
        "This source will stop appearing in Manga. Saved reading progress and downloaded chapters are kept.",
      ),
      action: 'Uninstall',
    );
    if (!confirmed) return;
    try {
      await ref
          .read(marketplaceControllerProvider.notifier)
          .uninstall(addon.manifest.id);
      _showMessage(
        _ui.text("{value1} uninstalled.", {'value1': addon.manifest.name}),
      );
    } catch (_) {
      _showMessage(
        _ui.text("TetoTV could not uninstall {value1}.", {
          'value1': addon.manifest.name,
        }),
      );
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
        _showMessage(_ui.text("Credentials removed from protected storage."));
        return;
      }
      final credential = draft.credential;
      if (credential == null) return;
      await store.write(source.id, credential);
      _showMessage(_ui.text("Credentials saved in protected storage."));
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage(
        _ui.text("TetoTV could not update that protected credential."),
      );
    }
  }

  Future<void> _removeSource(StoredMangaSource source) async {
    final confirmed = await _confirm(
      title: _ui.text("Remove {value1}?", {'value1': source.name}),
      message: _ui.text(
        "This removes the source, its protected credential, saved library entries, reading progress, and its manga downloads from TetoTV.",
      ),
      action: 'Remove',
    );
    if (!confirmed) return;
    try {
      final removed = await _controller.removeSource(source.id);
      if (removed) {
        _showMessage(_ui.text("Manga source and its local data removed."));
      }
    } catch (_) {
      _showMessage(
        _ui.text(
          "TetoTV could not safely remove all downloaded files. The source was kept.",
        ),
      );
    }
  }

  Future<void> _removeLibraryEntry(MangaLibraryEntry entry) async {
    if (!await _confirm(
      title: _ui.text('Remove from library?'),
      message: _ui.text(
        'Downloaded chapters and reading history will be kept.',
      ),
      action: 'Remove',
    )) {
      return;
    }
    final extensionController = ref.read(
      mangaExtensionControllerProvider.notifier,
    );
    if (extensionController.isExtensionLibraryEntry(entry)) {
      try {
        await extensionController.removeLibraryEntry(entry);
        await _controller.initialize();
        _showMessage(_ui.text("Removed from your manga library."));
      } catch (error) {
        _showMessage(
          error is StateError
              ? error.message
              : _ui.text("TetoTV could not remove that extension title."),
        );
      }
      return;
    }
    if (await _controller.removeLibraryEntry(entry)) {
      _showMessage(_ui.text("Removed from your manga library."));
    }
  }

  Future<void> _openLibraryEntry(MangaLibraryEntry entry) async {
    final binding = _bindAction(catalog: true);
    try {
      await binding.checkEntry(entry);
      if (binding.extension.isExtensionLibraryEntry(entry)) {
        final title = await binding.extension.openLibraryEntry(entry);
        binding.check();
        if (title != null) await _showExtensionTitle(title, action: binding);
        return;
      }
      final publication = await binding.hub.openLibraryEntry(entry);
      // Catalog opening intentionally selects the saved catalog. Bind again
      // only after checking that the owning controllers are still current.
      if (!mounted ||
          !binding.hub.mounted ||
          !binding.extension.mounted ||
          !identical(_controller, binding.hub) ||
          !identical(
            ref.read(mangaExtensionControllerProvider.notifier),
            binding.extension,
          )) {
        return;
      }
      if (publication == null) {
        if (binding.hub.snapshot.error case final message?) {
          _showMessage(message);
        }
        return;
      }
      await _showPublication(publication);
    } catch (_) {
      if (mounted) {
        _showMessage(_ui.text('TetoTV could not reopen that extension title.'));
      }
    }
  }

  Future<String> _checkLibraryUpdates() async {
    final result = await ref
        .read(mangaExtensionControllerProvider.notifier)
        .checkLibraryUpdates();
    if (mounted) await _controller.initialize();
    return _ui.text(
      'Checked {checked} titles • {new} new chapters • {failed} unavailable • {remaining} left to check',
      {
        'checked': result.checked,
        'new': result.newChapters,
        'failed': result.failed,
        'remaining': result.remaining,
      },
    );
  }

  Future<void> _trackLibraryEntry(MangaLibraryEntry entry) async {
    final binding = _bindAction();
    try {
      await binding.checkEntry(entry);
      binding.check();
      if (!mounted) return;
      await showMangaTrackingDialog(
        context,
        ref,
        ownerKey: entry.ownerKey,
        sourceId: entry.sourceId,
        publicationId: entry.entryId,
        title: entry.title,
      );
    } catch (_) {}
  }

  Future<void> _acknowledgeUpdates(MangaLibraryEntry entry) async {
    final binding = _bindAction();
    try {
      await binding.checkEntry(entry);
      await binding.store.acknowledgeChapterUpdates(
        ownerKey: entry.ownerKey,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
      );
      if (binding.isCurrent()) {
        await binding.hub.initialize();
        _showMessage(_ui.text('Chapter updates marked as seen.'));
      }
    } catch (_) {
      if (binding.isCurrent()) {
        _showMessage(
          _ui.text('Chapter updates could not be marked as seen. Try again.'),
        );
      }
    }
  }

  Future<void> _migrateLibraryEntry(MangaLibraryEntry source) async {
    final extension = ref.read(mangaExtensionControllerProvider.notifier);
    final alternatives = ref
        .read(mangaHubControllerProvider)
        .library
        .where(
          (e) =>
              e.ownerKey == source.ownerKey &&
              extension.isExtensionLibraryEntry(e) &&
              (e.sourceId != source.sourceId || e.entryId != source.entryId),
        )
        .toList();
    if (alternatives.isEmpty) {
      _showMessage(
        _ui.text(
          'Add this manga from your new Seanime source to the library first, then choose Change source.',
        ),
      );
      return;
    }
    final target = await showDialog<MangaLibraryEntry>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Choose the new source edition')),
        content: SizedBox(
          width: 620,
          height: 360,
          child: ListView.separated(
            itemCount: alternatives.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => ListTile(
              title: Text(alternatives[index].title),
              subtitle: Text(
                alternatives[index].metadata['providerName'] as String? ?? '',
              ),
              onTap: () => Navigator.pop(context, alternatives[index]),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('Cancel')),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    try {
      final title = await extension.openLibraryEntry(target);
      if (title == null) return;
      await extension.chapters(title);
      final store = ref.read(mangaStoreProvider);
      final snapshots = await store.chapterSnapshots(
        ownerKey: source.ownerKey,
        sourceId: target.sourceId,
        entryId: target.entryId,
        includeUnavailable: false,
      );
      final service = MangaLibraryService(store);
      final plan = await service.previewSourceMigration(
        source: source,
        target: target,
        targetChapters: snapshots,
      );
      if (!mounted) return;
      final confirmed = await _confirm(
        title: _ui.text('Copy reading history?'),
        message: _ui.text(
          'Copy {matched} matched chapters to {title} on {source}. {unmatched} chapters could not be matched. Check that these are the same edition and chapter numbering. Your original manga, history and downloads will stay untouched.',
          {
            'matched': plan.chapterMatches.length,
            'title': target.title,
            'source': title.providerName,
            'unmatched': plan.unmatchedChapterIds.length,
          },
        ),
        action: 'Copy history',
      );
      if (!confirmed || !mounted) return;
      if (await ref.read(mangaOwnerKeyProvider.future) != source.ownerKey) {
        return;
      }
      await service.confirmSourceMigration(plan, confirmed: true);
      if (mounted) await _controller.initialize();
      _showMessage(
        _ui.text(
          'Reading history copied. Your original source is still in the library.',
        ),
      );
    } catch (_) {
      _showMessage(
        _ui.text(
          'Source migration could not be completed. Your original library is unchanged.',
        ),
      );
    }
  }

  Future<void> _continueLibraryEntry(MangaLibraryEntry entry) async {
    final binding = _bindAction();
    try {
      await binding.checkEntry(entry);
      if (!binding.extension.isExtensionLibraryEntry(entry)) {
        return _openLibraryEntry(entry);
      }
      final owner = entry.ownerKey;
      final history = await binding.store.chapterProgressForEntry(
        ownerKey: owner,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
      );
      final latest = await binding.store.progress(
        ownerKey: owner,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
      );
      final cached = await binding.store.chapterSnapshots(
        ownerKey: owner,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
      );
      binding.check();
      // Resolve device-local data before consulting the provider or identity.
      final jobs = await binding.store.downloadJobs(
        status: MangaDownloadJobStatus.completed,
      );
      binding.check();
      final chapterIds = <String>{
        ...cached.map((chapter) => chapter.chapterId),
        ...history.map((row) => row.chapterId),
        ...jobs
            .where(
              (job) =>
                  job.sourceId == entry.sourceId &&
                  job.entryId == entry.entryId,
            )
            .map((job) => job.chapterId),
      }.toList();
      final localChoice = selectMangaContinueChapter(
        orderedChapterIds: chapterIds,
        history: history,
        lastRead: latest,
      );
      if (localChoice != null) {
        final local = await binding.downloads.openCompleted(
          mangaExtensionDownloadJobId(
            entry.sourceId,
            entry.entryId,
            localChoice,
          ),
        );
        binding.check();
        if (local != null) {
          await _openBoundReader(binding, local);
          return;
        }
      }
      final title = await binding.extension.openLibraryEntry(entry);
      binding.check();
      if (title == null) return;
      final chapters = await binding.extension.chapters(title);
      binding.check();
      final key = selectMangaContinueChapter(
        orderedChapterIds: [
          for (final chapter in chapters)
            mangaExtensionChapterId(title.providerId, title.id, chapter.id),
        ],
        history: history,
        lastRead: latest,
      );
      final selected = chapters
          .where(
            (chapter) =>
                mangaExtensionChapterId(
                  title.providerId,
                  title.id,
                  chapter.id,
                ) ==
                key,
          )
          .firstOrNull;
      if (selected == null) {
        _showMessage(_ui.text('You have read all available chapters.'));
        return;
      }
      final request = await _readerForExtensionChapter(
        title,
        selected,
        chapterList: chapters,
        action: binding,
      );
      await _openBoundReader(binding, request);
    } catch (_) {
      if (binding.isCurrent()) {
        _showMessage(
          _ui.text(
            'This manga could not be resumed. Open Chapters to retry, or read a saved download.',
          ),
        );
      }
    }
  }

  Future<void> _showPublication(MangaPublication publication) async {
    final binding = _bindAction(catalog: true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _MangaPublicationSheet(
        publication: publication,
        source: binding.hub.snapshot.selectedSource,
        inLibrary: _isInLibrary(publication),
        onRead: () async {
          if (!binding.isCurrent()) return;
          Navigator.of(sheetContext).pop();
          await _readPublication(publication, action: binding);
        },
        onLibrary: () async {
          if (!binding.isCurrent()) return;
          await binding.hub.toggleLibrary(publication);
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
        },
        onDownload: () {
          if (!binding.isCurrent()) return;
          Navigator.of(sheetContext).pop();
          unawaited(_downloadPublication(publication, action: binding));
        },
      ),
    );
  }

  Future<void> _showExtensionTitle(
    MangaExtensionTitle title, {
    _MangaActionBinding? action,
  }) async {
    final binding = action ?? _bindAction();
    try {
      binding.check();
      final inLibrary = await binding.extension.isInLibrary(title);
      binding.check();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => MangaChapterSheet(
          title: title,
          expectedController: binding.extension,
          initiallyInLibrary: inLibrary,
          loadChapters: () async {
            binding.check();
            final chapters = await binding.extension.chapters(title);
            binding.check();
            return chapters;
          },
          onRead: (chapter, ordered) async {
            binding.check();
            Navigator.of(sheetContext).pop();
            await _readExtensionChapter(
              title,
              chapter,
              chapterList: ordered,
              action: binding,
            );
          },
          onDownload: (chapter) async {
            binding.check();
            final request = await binding.extension.buildDownloadRequest(
              title,
              chapter,
            );
            binding.check();
            if (!sheetContext.mounted) return;
            await binding.downloads.start(
              request,
              validateAdmission: () {
                binding.check();
                if (!sheetContext.mounted) {
                  throw StateError('Manga chapter browser closed.');
                }
              },
            );
            if (sheetContext.mounted) Navigator.of(sheetContext).pop();
            if (binding.isCurrent()) _setSection(MangaHubSection.downloads);
          },
          onDownloadMany: (chapters) async {
            for (final chapter in chapters.take(10)) {
              binding.check();
              if (!sheetContext.mounted) return;
              final request = await binding.extension.buildDownloadRequest(
                title,
                chapter,
              );
              binding.check();
              if (!sheetContext.mounted) return;
              await binding.downloads.start(
                request,
                validateAdmission: () {
                  binding.check();
                  if (!sheetContext.mounted) {
                    throw StateError('Manga chapter browser closed.');
                  }
                },
              );
            }
            if (sheetContext.mounted) Navigator.of(sheetContext).pop();
            if (binding.isCurrent()) _setSection(MangaHubSection.downloads);
          },
          onLibrary: () async {
            binding.check();
            final saved = await binding.extension.toggleLibrary(title);
            binding.check();
            await binding.hub.initialize();
            return saved;
          },
        ),
      );
    } catch (_) {
      if (binding.isCurrent()) {
        _showMessage(_ui.text('That manga source could not open this title.'));
      }
    }
  }

  Future<void> _readExtensionChapter(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter, {
    List<MangaExtensionChapter>? chapterList,
    _MangaActionBinding? action,
  }) async {
    final binding = action ?? _bindAction();
    try {
      final request = await _readerForExtensionChapter(
        title,
        chapter,
        chapterList: chapterList,
        action: binding,
      );
      await _openBoundReader(binding, request);
    } catch (_) {
      if (binding.isCurrent()) {
        _showMessage(_ui.text('That manga chapter could not be opened.'));
      }
    }
  }

  Future<MangaReaderRequest> _readerForExtensionChapter(
    MangaExtensionTitle title,
    MangaExtensionChapter chapter, {
    List<MangaExtensionChapter>? chapterList,
    _MangaActionBinding? action,
  }) async {
    final binding = action ?? _bindAction();
    binding.check();
    final owner = await binding.hub.ownerKey;
    binding.check();
    final source = mangaExtensionSourceId(title.providerId);
    final entry = mangaExtensionEntryId(title.providerId, title.id);
    final chapterKey = mangaExtensionChapterId(
      title.providerId,
      title.id,
      chapter.id,
    );
    final local = await binding.downloads.openCompleted(
      mangaExtensionDownloadJobId(source, entry, chapterKey),
    );
    binding.check();
    final extension = binding.extension;
    List<MangaExtensionChapter>? ordered = chapterList;
    // A downloaded chapter remains readable when its source is unavailable.
    if (ordered == null && local == null) {
      ordered = await extension.chapters(title);
    }
    final resolved =
        local ??
        await extension.buildReaderRequest(
          title,
          chapter,
          chapterList: ordered,
        );
    binding.check();
    final index = ordered?.indexWhere((item) => item.id == chapter.id) ?? -1;
    final previous = index > 0 ? ordered![index - 1] : null;
    final next = index >= 0 && index + 1 < ordered!.length
        ? ordered[index + 1]
        : null;
    return binding.hub.applySavedProgress(
      MangaReaderRequest(
        ownerKey: owner,
        sourceId: resolved.sourceId,
        publicationId: resolved.publicationId,
        chapterId: resolved.chapterId,
        seriesTitle: resolved.seriesTitle,
        coverUri:
            resolved.coverUri ??
            (title.imageHeaders.isEmpty ? title.image : null),
        chapterTitle: resolved.chapterTitle,
        chapterNumber: resolved.chapterNumber,
        pages: resolved.pages,
        resolvePreviousChapter: previous == null
            ? null
            : () => _readerForExtensionChapter(
                title,
                previous,
                chapterList: ordered,
                action: binding,
              ),
        resolveNextChapter: next == null
            ? null
            : () => _readerForExtensionChapter(
                title,
                next,
                chapterList: ordered,
                action: binding,
              ),
      ),
    );
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

  Future<void> _readPublication(
    MangaPublication publication, {
    _MangaActionBinding? action,
  }) async {
    final binding = action ?? _bindAction(catalog: true);
    try {
      binding.check();
      final request = await binding.hub.buildReaderRequest(publication);
      binding.check();
      final jobId = _mangaDownloadJobId(request);
      final existing = ref.read(mangaAcquisitionControllerProvider).job(jobId);
      if (existing?.status == MangaDownloadJobStatus.completed) {
        final local = await binding.downloads.openCompleted(jobId);
        if (local != null && mounted) {
          await _openBoundReader(binding, local);
          return;
        }
      }
      if (!mounted) return;
      await _openBoundReader(binding, request);
    } on MangaReaderBuildException catch (error) {
      if (error.failure == MangaReaderBuildFailure.noImagePages) {
        try {
          final request = await _buildDownloadRequest(publication, binding);
          binding.check();
          final operation = await binding.downloads.start(
            request,
            validateAdmission: binding.check,
          );
          binding.check();
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
            await _openBoundReader(binding, local);
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
      _showMessage(_ui.text("TetoTV could not open that manga."));
    }
  }

  Future<void> _downloadPublication(
    MangaPublication publication, {
    _MangaActionBinding? action,
  }) async {
    final binding = action ?? _bindAction(catalog: true);
    try {
      final request = await _buildDownloadRequest(publication, binding);
      binding.check();
      await binding.downloads.start(request, validateAdmission: binding.check);
      if (!binding.isCurrent()) return;
      _setSection(MangaHubSection.downloads);
      _showMessage(_ui.text("Manga download started."));
    } on MangaReaderBuildException catch (error) {
      _showMessage(error.message);
    } on MangaCbzAcquisitionException catch (error) {
      _showMessage(error.message);
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage(_ui.text("TetoTV could not start that manga download."));
    }
  }

  Future<MangaAcquisitionRequest> _buildDownloadRequest(
    MangaPublication publication,
    _MangaActionBinding binding,
  ) async {
    binding.check();
    try {
      final reader = await binding.hub.buildReaderRequest(publication);
      binding.check();
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
            headers: resource.headers,
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
        acquisition: MangaReadingOrderAcquisition(pages),
      );
    } on MangaReaderBuildException catch (error) {
      if (error.failure != MangaReaderBuildFailure.noImagePages) rethrow;
      binding.check();
      final selection = await binding.hub.selectCbzAcquisition(publication);
      binding.check();
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
    final binding = _bindAction();
    try {
      final request = await binding.downloads.openCompleted(job.id);
      binding.check();
      if (request == null) {
        _showMessage(_ui.text('That manga download is not ready yet.'));
        return;
      }
      await _openBoundReader(binding, request);
    } catch (_) {
      if (binding.isCurrent()) {
        _showMessage(_ui.text('TetoTV could not open that manga download.'));
      }
    }
  }

  Future<void> _cancelDownload(MangaDownloadJob job) async {
    try {
      await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .cancel(job.id);
      _showMessage(_ui.text("Manga download cancelled."));
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage(_ui.text("TetoTV could not cancel that manga download."));
    }
  }

  Future<void> _retryDownload(MangaDownloadJob job) async {
    final binding = _bindAction();
    try {
      await binding.downloads.resume(job.id, validateAdmission: binding.check);
      if (binding.isCurrent()) {
        _showMessage(_ui.text("Manga download restarted."));
      }
    } on MangaAcquisitionException catch (error) {
      if (binding.isCurrent()) _showMessage(error.message);
    } catch (_) {
      if (binding.isCurrent()) {
        _showMessage(_ui.text('TetoTV could not start that manga download.'));
      }
    }
  }

  Future<void> _pauseDownload(MangaDownloadJob job) async {
    try {
      await ref.read(mangaAcquisitionControllerProvider.notifier).pause(job.id);
    } catch (_) {
      _showMessage(_ui.text('This download could not be paused. Try again.'));
    }
  }

  Future<void> _deleteDownload(MangaDownloadJob job) async {
    final confirmed = await _confirm(
      title: _ui.text("Delete {value1}?", {'value1': job.seriesTitle}),
      message: _ui.text(
        "This removes the downloaded pages from this device. Your library entry and reading progress are kept.",
      ),
      action: 'Delete',
    );
    if (!confirmed) return;
    try {
      await ref
          .read(mangaAcquisitionControllerProvider.notifier)
          .delete(job.id);
      _showMessage(_ui.text("Downloaded manga removed."));
    } on MangaAcquisitionException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage(_ui.text("TetoTV could not remove that manga download."));
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
              child: Text(_ui.text("Cancel")),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_ui.text(action)),
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
      title: Text(context.tr("Preparing {value1}", {'value1': widget.title})),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.tr(_error ?? _progressDescription(_progress))),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: fraction),
            if (_progress.pageCount case final total?) ...[
              const SizedBox(height: 8),
              Text(
                context.tr("{value1} of {value2} pages", {
                  'value1': _progress.completedPages.clamp(0, total),
                  'value2': total,
                }),
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
            child: Text(
              _cancelling ? context.tr("Cancelling…") : context.tr("Cancel"),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            _error == null
                ? context.tr("Keep downloading")
                : context.tr("Close"),
          ),
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
      final title = Row(
        children: [
          Icon(
            Icons.menu_book_rounded,
            color: context.appPalette.accentBright,
            size: compact ? 27 : 32,
          ),
          const SizedBox(width: 10),
          Text(
            context.tr("Manga"),
            style:
                (compact
                        ? Theme.of(context).textTheme.headlineSmall
                        : Theme.of(context).textTheme.headlineMedium)
                    ?.copyWith(fontWeight: FontWeight.w900),
          ),
        ],
      );
      final refresh = _MangaIconAction(
        icon: Icons.refresh_rounded,
        tooltip: context.tr("Refresh manga"),
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
          labelText: context.tr("Search manga"),
          hintText: context.tr("Title, author, or tag"),
          keyboardTitle: context.tr("Search manga"),
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
    required this.onExitDown,
  });

  final MangaHubSection selected;
  final Map<MangaHubSection, FocusNode> focusNodes;
  final ValueChanged<MangaHubSection> onSelected;
  final VoidCallback onExitLeft;
  final VoidCallback onExitDown;

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
            onExitDown: onExitDown,
            onExitLeft: section == MangaHubSection.library
                ? onExitLeft
                : () => requestTvFocusAndReveal(
                    focusNodes[MangaHubSection.values[section.index - 1]]!,
                  ),
            onExitRight: section == MangaHubSection.values.last
                ? () {}
                : () => requestTvFocusAndReveal(
                    focusNodes[MangaHubSection.values[section.index + 1]]!,
                    towardEnd: true,
                  ),
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
    required this.onExitDown,
  });

  final MangaHubSection section;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final VoidCallback onExitLeft;
  final VoidCallback? onExitRight;
  final VoidCallback onExitDown;

  @override
  Widget build(BuildContext context) => TvFocusable(
    key: ValueKey('manga-section-${section.name}'),
    focusNode: focusNode,
    onPressed: onPressed,
    onKeyEvent: (_, event) => handleTvDirectionalFocusEvent(
      event,
      TvDirectionalFocusCallbacks(
        left: onExitLeft,
        right: onExitRight,
        down: onExitDown,
      ),
    ),
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
            context.tr(section.label),
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
                title: context.tr("No extension results"),
                message: extensions.failures.isEmpty
                    ? context.tr(
                        "Try another title or choose Search all sources.",
                      )
                    : context.tr(
                        "{value1} source(s) could not complete this search.",
                        {'value1': extensions.failures.length},
                      ),
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
            context.tr("Manga extensions"),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            enabledExtensions.isEmpty
                ? context.tr(
                    "No manga extensions are enabled. TetoTV bundles and recommends no sources.",
                  )
                : context.tr(
                    "Choose one source or Search all, then enter a title in the search bar above.",
                  ),
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
                  label: context.tr("Search all sources"),
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
                label: context.tr("Manage extensions"),
                focusNode: enabledExtensions.isEmpty && catalogs.isEmpty
                    ? firstFocusNode
                    : null,
                onPressed: onManageExtensions,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            context.tr("Choose a catalog"),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            context.tr("Only sources you add are shown here."),
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
                label: context.tr("Add source"),
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
                        tooltip: context.tr("Previous catalog"),
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
                  ? context.tr("No manga on this page")
                  : context.tr("No matches"),
              message: state.query.isEmpty
                  ? context.tr(
                      "Open one of the catalog folders above or refresh this source.",
                    )
                  : context.tr("Try a different title, author, or tag."),
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
          context.tr("Results for “{value1}”", {'value1': state.query}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 5),
        Text(
          state.searching
              ? context.tr(
                  "{value1} result(s) so far • searching enabled sources…",
                  {'value1': state.results.length},
                )
              : context.tr(
                  "{value1} result(s) from installed manga extensions",
                  {'value1': state.results.length},
                ),
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
                label: context.tr("Search all"),
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
                label: context.tr("Manage extensions"),
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

class _MangaDownloadsView extends StatelessWidget {
  const _MangaDownloadsView({
    required this.state,
    required this.firstFocusNode,
    required this.onBrowse,
    required this.onOpen,
    required this.onCancel,
    required this.onPause,
    required this.onRetry,
    required this.onDelete,
    super.key,
  });

  final MangaAcquisitionState state;
  final FocusNode firstFocusNode;
  final VoidCallback onBrowse;
  final ValueChanged<MangaDownloadJob> onOpen;
  final ValueChanged<MangaDownloadJob> onCancel;
  final ValueChanged<MangaDownloadJob> onPause;
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
        title: context.tr("No downloaded manga"),
        message: context.tr(
          "Download a title from one of your sources to read it without a connection.",
        ),
        actionLabel: context.tr("Browse manga"),
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
        onPause: () => onPause(jobs[index]),
        onRetry: () => onRetry(jobs[index]),
        onDelete: () => onDelete(jobs[index]),
      ),
    );
  }
}

class _MangaSourcesEntry {
  VoidCallback? focusFirst;
}

class _MangaSourcesView extends StatefulWidget {
  const _MangaSourcesView({
    required this.showAniyomiExperiments,
    required this.sources,
    required this.marketplace,
    required this.selectedSourceId,
    required this.firstFocusNode,
    required this.entry,
    required this.onExitUp,
    required this.onExitLeft,
    required this.onAddRepository,
    required this.onRefreshRepositories,
    required this.onToggleRepository,
    required this.onRemoveRepository,
    required this.onInstallExtension,
    required this.onToggleExtension,
    required this.onUninstallExtension,
    required this.onBrowseExtensions,
    required this.onOpen,
    required this.onToggle,
    required this.onCredentials,
    required this.onRemove,
    required this.onManageExtensions,
    super.key,
  });

  final bool showAniyomiExperiments;
  final List<StoredMangaSource> sources;
  final MarketplaceState marketplace;
  final String? selectedSourceId;
  final FocusNode firstFocusNode;
  final _MangaSourcesEntry entry;
  final VoidCallback onExitUp;
  final VoidCallback onExitLeft;
  final VoidCallback onAddRepository;
  final VoidCallback onRefreshRepositories;
  final ValueChanged<AddonRepository> onToggleRepository;
  final ValueChanged<AddonRepository> onRemoveRepository;
  final ValueChanged<MarketplaceAddon> onInstallExtension;
  final ValueChanged<InstalledStreamingAddon> onToggleExtension;
  final ValueChanged<InstalledStreamingAddon> onUninstallExtension;
  final VoidCallback onBrowseExtensions;
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
  final _scroll = ScrollController();
  final _focusNodes = <String, FocusNode>{};
  List<List<FocusNode>> _navigationRows = const [];
  bool _filterEditing = false;
  bool _revealingTarget = false;
  int _focusGeneration = 0;
  String? _language;
  late final VoidCallback _entryCallback;

  @override
  void initState() {
    super.initState();
    _entryCallback = () {
      _focusGeneration++;
      _revealingTarget = false;
      // Returning from the rail can happen while the first sliver is unmounted.
      // Restore that viewport before asking its entry control for focus.
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.minScrollExtent);
      }
      requestTvFocusAndReveal(widget.firstFocusNode);
    };
    widget.entry.focusFirst = _entryCallback;
  }

  // Identity stays internal. Diagnostics see only a static control category,
  // never repository URLs, provider IDs, titles or text entered into the filter.
  FocusNode _node(String identity, [String? category]) =>
      _focusNodes.putIfAbsent(
        identity,
        () => FocusNode(debugLabel: 'manga.sources.${category ?? identity}'),
      );

  KeyEventResult _handleNavigation(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final left = key == LogicalKeyboardKey.arrowLeft;
    final right = key == LogicalKeyboardKey.arrowRight;
    final up = key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!left && !right && !up && !down) return KeyEventResult.ignored;
    if (_filterEditing) return KeyEventResult.ignored;
    final current = FocusManager.instance.primaryFocus;
    for (var rowIndex = 0; rowIndex < _navigationRows.length; rowIndex++) {
      final row = _navigationRows[rowIndex];
      final column = row.indexWhere((node) => node == current || node.hasFocus);
      if (column < 0) continue;
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.handled;
      }
      if (_revealingTarget) return KeyEventResult.handled;
      if (left || right) {
        final next = column + (left ? -1 : 1);
        if (next >= 0 && next < row.length) {
          unawaited(_focusAndReveal(row[next], towardEnd: right));
        } else if (left) {
          widget.onExitLeft();
        }
      } else {
        final next = rowIndex + (up ? -1 : 1);
        if (next < 0) {
          widget.onExitUp();
        } else if (next < _navigationRows.length) {
          // Every semantic row is entered at its primary action. Left/right
          // traverses the rest of that row; geometry never skips a short card.
          unawaited(
            _focusAndReveal(_navigationRows[next].first, towardEnd: down),
          );
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _focusAndReveal(
    FocusNode target, {
    required bool towardEnd,
  }) async {
    final generation = ++_focusGeneration;
    final origin = FocusManager.instance.primaryFocus;
    _revealingTarget = true;
    try {
      // A next lazy sliver may not be mounted yet. Reveal it in bounded steps
      // instead of silently jumping over it to another mounted control.
      for (var attempt = 0; attempt < 12; attempt++) {
        if (!mounted || generation != _focusGeneration) return;
        if (FocusManager.instance.primaryFocus != origin &&
            FocusManager.instance.primaryFocus != target) {
          return;
        }
        if (target.context?.mounted == true && target.canRequestFocus) {
          requestTvFocusAndReveal(target, towardEnd: towardEnd);
          return;
        }
        if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) {
          return;
        }
        final position = _scroll.position;
        final offset =
            (position.pixels +
                    (towardEnd ? 1 : -1) * position.viewportDimension * .65)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
        if ((offset - position.pixels).abs() < .5) return;
        await position.animateTo(
          offset,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
        );
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      if (generation == _focusGeneration) _revealingTarget = false;
    }
  }

  @override
  void dispose() {
    _focusGeneration++;
    if (identical(widget.entry.focusFirst, _entryCallback)) {
      widget.entry.focusFirst = null;
    }
    _filter.dispose();
    _scroll.dispose();
    for (final node in _focusNodes.values) {
      node.dispose();
    }
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

    _navigationRows = [
      [widget.firstFocusNode, _node('policy.browse')],
      [
        _node('repository.add'),
        if (widget.showAniyomiExperiments) _node('repository.aniyomi'),
        if (!widget.marketplace.loading) _node('repository.refresh'),
      ],
      for (final repository in widget.marketplace.repositories)
        [
          _node('repository:${repository.url}:toggle', 'repository.toggle'),
          _node('repository:${repository.url}:remove', 'repository.remove'),
        ],
      [_node('extensions.manage')],
      [_node('extensions.filter'), _node('extensions.language')],
      for (final addon in visibleAddons)
        [
          if (widget.marketplace.installedById(addon.id) == null ||
              widget.marketplace.updateAvailable(addon))
            if (addon.isCompatible &&
                !marketplaceAddonIdsMatch(
                  widget.marketplace.busyAddonId ?? '',
                  addon.id,
                ))
              _node('extension:${addon.id}:install', 'extension.install'),
          if (widget.marketplace.installedById(addon.id) != null &&
              !marketplaceAddonIdsMatch(
                widget.marketplace.busyAddonId ?? '',
                addon.id,
              )) ...[
            _node('extension:${addon.id}:toggle', 'extension.toggle'),
            _node('extension:${addon.id}:remove', 'extension.remove'),
          ],
        ],
      [_node('extensions.browse')],
      for (final source in widget.sources)
        [
          if (source.enabled)
            _node('catalog:${source.id}:open', 'catalog.open'),
          _node('catalog:${source.id}:toggle', 'catalog.toggle'),
          _node('catalog:${source.id}:credentials', 'catalog.credentials'),
          _node('catalog:${source.id}:remove', 'catalog.remove'),
        ],
    ].where((row) => row.isNotEmpty).toList(growable: false);

    return Focus(
      canRequestFocus: false,
      onKeyEvent: _handleNavigation,
      child: CustomScrollView(
        key: const ValueKey('manga-sources-list'),
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(3, 3, 3, 0),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _MangaPolicyBanner(
                  onAddRepository: widget.onAddRepository,
                  onBrowse: widget.onBrowseExtensions,
                  focusNode: widget.firstFocusNode,
                  browseFocusNode: _node('policy.browse'),
                ),
                const SizedBox(height: 18),
                _MangaSourceSectionHeader(
                  step: '1',
                  title: context.tr("Manga repositories"),
                  subtitle: context.tr(
                    "Add only repositories you choose. No source URL is bundled or prefilled.",
                  ),
                  actions: [
                    _MangaActionButton(
                      key: const ValueKey('manga-add-extension-repository'),
                      focusNode: _node('repository.add'),
                      icon: Icons.add_link_rounded,
                      label: context.tr("Add repository"),
                      prominent: true,
                      onPressed: widget.onAddRepository,
                    ),
                    if (widget.showAniyomiExperiments)
                      _MangaActionButton(
                        key: const ValueKey('manga-aniyomi-experiments'),
                        focusNode: _node('repository.aniyomi'),
                        icon: Icons.science_outlined,
                        label: context.tr('Aniyomi • Experimental'),
                        onPressed: () => context.push(AniyomiScreen.routePath),
                      ),
                    _MangaIconAction(
                      focusNode: _node('repository.refresh'),
                      icon: Icons.refresh_rounded,
                      tooltip: context.tr("Refresh repositories"),
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
                  _MangaEmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: context.tr("No manga repositories added"),
                    message: context.tr(
                      "Add a compatible Seanime/Teto manga-provider repository to see installable sources. Native Mihon/Tachiyomi .pb and APK repositories use a different runtime and are not installed.",
                    ),
                  )
                else
                  for (
                    var index = 0;
                    index < widget.marketplace.repositories.length;
                    index++
                  ) ...[
                    _MangaRepositoryCard(
                      repository: widget.marketplace.repositories[index],
                      toggleFocusNode: _node(
                        'repository:${widget.marketplace.repositories[index].url}:toggle',
                        'repository.toggle',
                      ),
                      removeFocusNode: _node(
                        'repository:${widget.marketplace.repositories[index].url}:remove',
                        'repository.remove',
                      ),
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
                  title: context.tr("Manga extensions"),
                  subtitle: context.tr(
                    "Install a source explicitly, then enable or disable it whenever you want.",
                  ),
                  actions: [
                    _MangaActionButton(
                      icon: Icons.tune_rounded,
                      focusNode: _node('extensions.manage'),
                      label: context.tr("All add-ons"),
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
                        focusNode: _node('extensions.filter'),
                        onEditingChanged: (editing) => _filterEditing = editing,
                        labelText: context.tr("Filter extensions"),
                        hintText: context.tr("Name or author"),
                        keyboardTitle: context.tr("Filter manga extensions"),
                        onChanged: (_) => setState(() {}),
                      ),
                    );
                    final language = DropdownButton<String?>(
                      key: const ValueKey('manga-extension-language-filter'),
                      value: _language,
                      focusNode: _node('extensions.language'),
                      borderRadius: BorderRadius.circular(12),
                      hint: Text(context.tr("All languages")),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text(context.tr("All languages")),
                        ),
                        for (final code in languages)
                          DropdownMenuItem<String?>(
                            value: code,
                            child: Text(
                              context.tr(marketplaceCatalogLanguageLabel(code)),
                            ),
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
                          Align(
                            alignment: Alignment.centerLeft,
                            child: language,
                          ),
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
                          context.tr('Sources: {count}', {
                            'count': visibleAddons.length,
                          }),
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
                        ? context.tr("No compatible manga extensions found")
                        : context.tr("No extensions match this filter"),
                    message: allMangaAddons.isEmpty
                        ? context.tr(
                            "Add or refresh a compatible manga repository first.",
                          )
                        : context.tr(
                            "Clear the name or language filter and try again.",
                          ),
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
                    installFocusNode: _node(
                      'extension:${visibleAddons[index].id}:install',
                      'extension.install',
                    ),
                    toggleFocusNode: _node(
                      'extension:${visibleAddons[index].id}:toggle',
                      'extension.toggle',
                    ),
                    removeFocusNode: _node(
                      'extension:${visibleAddons[index].id}:remove',
                      'extension.remove',
                    ),
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
                    focusNode: _node('extensions.browse'),
                    icon: Icons.explore_rounded,
                    label: context.tr("Browse installed sources"),
                    prominent: true,
                    onPressed: widget.onBrowseExtensions,
                  ),
                ),
                if (widget.sources.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _MangaSourceSectionHeader(
                    step: '3',
                    title: context.tr("Previously saved catalogs"),
                    subtitle: context.tr(
                      "Your existing catalogs remain available. Add new sources through Seanime extension repositories.",
                    ),
                    actions: const [],
                  ),
                  const SizedBox(height: 10),
                  if (widget.sources.isEmpty)
                    _MangaEmptyState(
                      icon: Icons.link_off_rounded,
                      title: context.tr("No data catalogs added"),
                      message: context.tr(
                        "This section is optional. Nothing is bundled or recommended by TetoTV.",
                      ),
                    )
                  else
                    for (
                      var index = 0;
                      index < widget.sources.length;
                      index++
                    ) ...[
                      _MangaSourceCard(
                        source: widget.sources[index],
                        openFocusNode: _node(
                          'catalog:${widget.sources[index].id}:open',
                          'catalog.open',
                        ),
                        toggleFocusNode: _node(
                          'catalog:${widget.sources[index].id}:toggle',
                          'catalog.toggle',
                        ),
                        credentialsFocusNode: _node(
                          'catalog:${widget.sources[index].id}:credentials',
                          'catalog.credentials',
                        ),
                        removeFocusNode: _node(
                          'catalog:${widget.sources[index].id}:remove',
                          'catalog.remove',
                        ),
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
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _MangaPolicyBanner extends StatelessWidget {
  const _MangaPolicyBanner({
    required this.onAddRepository,
    required this.onBrowse,
    required this.focusNode,
    required this.browseFocusNode,
  });

  final VoidCallback onAddRepository;
  final VoidCallback onBrowse;
  final FocusNode focusNode;
  final FocusNode browseFocusNode;

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
              label: context.tr("Add repository"),
              focusNode: focusNode,
              prominent: true,
              onPressed: onAddRepository,
            ),
            _MangaActionButton(
              icon: Icons.explore_rounded,
              focusNode: browseFocusNode,
              label: context.tr("Browse manga"),
              onPressed: onBrowse,
            ),
          ],
        );
        final copy = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr("Add a repository. Install a source. Start reading."),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              context.tr(
                "Manga repositories are always user-added, and installing an extension is a separate confirmation. TetoTV bundles, prefills, and recommends no source. Only use sources you trust and are authorized to access.",
              ),
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
    required this.toggleFocusNode,
    required this.removeFocusNode,
  });

  final AddonRepository repository;
  final int mangaExtensionCount;
  final String? error;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  final FocusNode toggleFocusNode;
  final FocusNode removeFocusNode;

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
                          : context.tr('Compatible manga extensions: {count}', {
                              'count': mangaExtensionCount,
                            }),
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
                focusNode: toggleFocusNode,
                icon: repository.enabled
                    ? Icons.pause_circle_outline_rounded
                    : Icons.play_circle_outline_rounded,
                label: repository.enabled
                    ? context.tr("Disable")
                    : context.tr("Enable"),
                onPressed: onToggle,
              ),
              _MangaIconAction(
                focusNode: removeFocusNode,
                icon: Icons.delete_outline_rounded,
                tooltip: context.tr("Remove manga repository"),
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
    required this.installFocusNode,
    required this.toggleFocusNode,
    required this.removeFocusNode,
  });

  final MarketplaceAddon addon;
  final InstalledStreamingAddon? installed;
  final bool updateAvailable;
  final bool busy;
  final VoidCallback onInstall;
  final ValueChanged<InstalledStreamingAddon> onToggle;
  final ValueChanged<InstalledStreamingAddon> onUninstall;
  final FocusNode installFocusNode;
  final FocusNode toggleFocusNode;
  final FocusNode removeFocusNode;

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
                            ? context.tr("UNSUPPORTED")
                            : current == null
                            ? context.tr("AVAILABLE")
                            : current.enabled
                            ? context.tr("ENABLED")
                            : context.tr("DISABLED"),
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
                focusNode: installFocusNode,
                icon: updateAvailable
                    ? Icons.system_update_alt_rounded
                    : Icons.download_rounded,
                label: updateAvailable
                    ? context.tr("Update")
                    : context.tr("Install"),
                prominent: true,
                onPressed: compatible && !busy ? onInstall : null,
              ),
            if (current != null) ...[
              _MangaActionButton(
                key: ValueKey('manga-extension-toggle-${addon.id}'),
                focusNode: toggleFocusNode,
                icon: current.enabled
                    ? Icons.pause_circle_outline_rounded
                    : Icons.play_circle_outline_rounded,
                label: current.enabled
                    ? context.tr("Disable")
                    : context.tr("Enable"),
                onPressed: busy ? null : () => onToggle(current),
              ),
              _MangaIconAction(
                focusNode: removeFocusNode,
                icon: Icons.delete_outline_rounded,
                tooltip: context.tr("Uninstall {value1}", {
                  'value1': addon.name,
                }),
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

class _MangaDownloadCard extends StatelessWidget {
  const _MangaDownloadCard({
    required this.job,
    required this.onOpen,
    required this.onCancel,
    required this.onPause,
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
  final VoidCallback onPause;
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
        label: context.tr("Read"),
        focusNode: focusNode,
        prominent: true,
        onPressed: onOpen,
      ),
      MangaDownloadJobStatus.queued ||
      MangaDownloadJobStatus.resolving ||
      MangaDownloadJobStatus.downloading => _MangaActionButton(
        icon: Icons.pause_rounded,
        label: context.tr("Pause"),
        focusNode: focusNode,
        onPressed: onPause,
      ),
      _ => _MangaActionButton(
        icon: Icons.refresh_rounded,
        label: job.status == MangaDownloadJobStatus.paused
            ? context.tr('Resume')
            : context.tr("Retry"),
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
                              ? context.tr(_downloadLabel(job.status))
                              : context.tr(_progressLabel(progress!)),
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
              if (active) ...[
                const SizedBox(width: 8),
                _MangaIconAction(
                  icon: Icons.close_rounded,
                  tooltip: context.tr('Cancel'),
                  onPressed: onCancel,
                ),
              ],
              const SizedBox(width: 8),
              _MangaIconAction(
                icon: Icons.delete_outline_rounded,
                tooltip: active
                    ? context.tr("Cancel and delete")
                    : context.tr("Delete download"),
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
    required this.openFocusNode,
    required this.toggleFocusNode,
    required this.credentialsFocusNode,
    required this.removeFocusNode,
  });

  final StoredMangaSource source;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onToggle;
  final VoidCallback onCredentials;
  final VoidCallback onRemove;
  final FocusNode openFocusNode;
  final FocusNode toggleFocusNode;
  final FocusNode credentialsFocusNode;
  final FocusNode removeFocusNode;

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
                        _MangaStatusBadge(label: context.tr("OPEN")),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${context.tr(_sourceKindLabel(source.kind))} · ${source.uri.host}',
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
              focusNode: openFocusNode,
              icon: source.kind == StoredMangaSourceKind.repository
                  ? Icons.sync_rounded
                  : Icons.open_in_new_rounded,
              label: source.kind == StoredMangaSourceKind.repository
                  ? context.tr("Sync")
                  : context.tr("Open"),
              onPressed: source.enabled ? onOpen : null,
            ),
            _MangaActionButton(
              focusNode: toggleFocusNode,
              icon: source.enabled
                  ? Icons.pause_circle_outline_rounded
                  : Icons.play_circle_outline_rounded,
              label: source.enabled
                  ? context.tr("Disable")
                  : context.tr("Enable"),
              onPressed: onToggle,
            ),
            _MangaIconAction(
              focusNode: credentialsFocusNode,
              icon: Icons.key_rounded,
              tooltip: context.tr("Protected credentials"),
              onPressed: onCredentials,
            ),
            _MangaIconAction(
              focusNode: removeFocusNode,
              icon: Icons.delete_outline_rounded,
              tooltip: context.tr("Remove source"),
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
                    tooltip: context.tr("Close"),
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
                    label: context.tr("Read now"),
                    autofocus: true,
                    prominent: true,
                    onPressed: onRead,
                  ),
                  _MangaActionButton(
                    icon: inLibrary
                        ? Icons.bookmark_remove_rounded
                        : Icons.bookmark_add_rounded,
                    label: inLibrary
                        ? context.tr("Remove from library")
                        : context.tr("Add to library"),
                    onPressed: onLibrary,
                  ),
                  _MangaActionButton(
                    icon: Icons.download_rounded,
                    label: context.tr("Download"),
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
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: _MangaActionButton(
      icon: icon,
      label: '',
      onPressed: onPressed,
      focusNode: focusNode,
    ),
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
    title: Text(context.tr('Add manga extension repository')),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 660),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr(
                'Paste a public HTTPS Seanime/Teto repository containing manga-provider extensions. You can separate multiple URLs with spaces.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr(
                'The field starts empty. TetoTV does not bundle, prefill, or recommend repositories.',
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.appPalette.mutedText,
              ),
            ),
            const SizedBox(height: 14),
            TvTextInput(
              key: const ValueKey('manga-extension-repository-input'),
              controller: _urls,
              labelText: context.tr('Repository URL'),
              hintText: 'https://example.org/manga-marketplace.json',
              keyboardTitle: context.tr('Manga repository URL'),
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
        label: Text(context.tr('Paste')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.tr('Cancel')),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(context.tr('Add repository')),
      ),
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
    title: Text(
      context.tr("{value1} credentials", {'value1': widget.sourceName}),
    ),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr(
                "Credentials are kept in protected device storage and are sent only to this source’s origin.",
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<_MangaCredentialKind>(
              initialValue: _kind,
              decoration: InputDecoration(
                labelText: context.tr("Authentication"),
              ),
              items: [
                DropdownMenuItem(
                  value: _MangaCredentialKind.basic,
                  child: Text(context.tr("Username and password")),
                ),
                DropdownMenuItem(
                  value: _MangaCredentialKind.bearer,
                  child: Text(context.tr("Bearer token")),
                ),
                DropdownMenuItem(
                  value: _MangaCredentialKind.apiKey,
                  child: Text(context.tr("API key header")),
                ),
              ],
              onChanged: (value) =>
                  setState(() => _kind = value ?? _MangaCredentialKind.basic),
            ),
            if (_kind == _MangaCredentialKind.basic) ...[
              const SizedBox(height: 12),
              TvTextInput(
                controller: _username,
                labelText: context.tr("Username"),
              ),
            ],
            if (_kind == _MangaCredentialKind.apiKey) ...[
              const SizedBox(height: 12),
              TvTextInput(
                controller: _header,
                labelText: context.tr("Header name"),
              ),
            ],
            const SizedBox(height: 12),
            TvTextInput(
              controller: _secret,
              labelText: _kind == _MangaCredentialKind.basic
                  ? context.tr("Password")
                  : _kind == _MangaCredentialKind.bearer
                  ? context.tr("Token")
                  : context.tr("API key"),
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
        child: Text(context.tr("Remove saved credential")),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.tr("Cancel")),
      ),
      FilledButton(onPressed: _save, child: Text(context.tr("Save securely"))),
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
      MangaAcquisitionPhase.paused => 'PAUSED',
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
      MangaAcquisitionPhase.paused =>
        'The manga download is paused. Resume it when you are ready.',
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
