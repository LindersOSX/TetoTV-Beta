import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/marketplace/application/marketplace_controller.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/marketplace/presentation/source_pairing_dialog.dart';
import 'package:anime_tv/features/streaming/application/user_torrent_sources_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

class MarketplaceScreen extends ConsumerStatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  ConsumerState<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceFocusTarget {
  const _MarketplaceFocusTarget(this.node, this.rect);

  final FocusNode node;
  final Rect rect;
}

class _MarketplaceScreenState extends ConsumerState<MarketplaceScreen> {
  final FocusNode _backFocus = FocusNode(debugLabel: 'Marketplace: Settings');
  final FocusNode _refreshFocus = FocusNode(debugLabel: 'Marketplace: Refresh');
  final FocusNode _phoneFocus = FocusNode(
    debugLabel: 'Marketplace: Add sources with phone',
  );
  final FocusNode _addManifestFocus = FocusNode(
    debugLabel: 'Marketplace: Add Torrent source manifests',
  );
  final FocusNode _addRepositoryFocus = FocusNode(
    debugLabel: 'Marketplace: Add Marketplace repositories',
  );
  final FocusNode _testAllProvidersFocus = FocusNode(
    debugLabel: 'Marketplace: Test all installed providers',
  );
  final FocusNode _languageFilterFocus = FocusNode(
    debugLabel: 'Marketplace: Filter provider language',
  );
  final FocusNode _catalogSortFocus = FocusNode(
    debugLabel: 'Marketplace: Sort available providers',
  );
  final Map<String, FocusNode> _dynamicFocusNodes = {};
  String? _catalogLanguage;
  MarketplaceCatalogSort _catalogSort = MarketplaceCatalogSort.name;

  FocusNode _dynamicFocus(String key, String debugLabel) => _dynamicFocusNodes
      .putIfAbsent(key, () => FocusNode(debugLabel: debugLabel));

  @override
  void dispose() {
    _backFocus.dispose();
    _refreshFocus.dispose();
    _phoneFocus.dispose();
    _addManifestFocus.dispose();
    _addRepositoryFocus.dispose();
    _testAllProvidersFocus.dispose();
    _languageFilterFocus.dispose();
    _catalogSortFocus.dispose();
    for (final node in _dynamicFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  _MarketplaceFocusTarget? _focusTarget(FocusNode node) {
    if (!node.canRequestFocus) return null;
    final focusContext = node.context;
    if (focusContext == null || !focusContext.mounted) return null;
    try {
      final renderObject = focusContext.findRenderObject();
      if (renderObject == null || !renderObject.attached) return null;
      final rect = node.rect;
      return rect.isFinite ? _MarketplaceFocusTarget(node, rect) : null;
    } catch (_) {
      // A lazy sliver can detach between the context, render-object, and rect
      // checks. Treat transient geometry as unavailable; the next D-pad event
      // rebuilds the graph after layout instead of crashing the application.
      return null;
    }
  }

  List<List<_MarketplaceFocusTarget>> _groupByVisualRow(
    Iterable<FocusNode> candidates,
  ) {
    final nodes = candidates.map(_focusTarget).nonNulls.toList()
      ..sort((a, b) {
        final vertical = a.rect.center.dy.compareTo(b.rect.center.dy);
        return vertical != 0
            ? vertical
            : a.rect.center.dx.compareTo(b.rect.center.dx);
      });
    final rows = <List<_MarketplaceFocusTarget>>[];
    for (final node in nodes) {
      if (rows.isEmpty ||
          (rows.last.first.rect.center.dy - node.rect.center.dy).abs() > 12) {
        rows.add(<_MarketplaceFocusTarget>[node]);
      } else {
        rows.last.add(node);
      }
    }
    for (final row in rows) {
      row.sort((a, b) => a.rect.center.dx.compareTo(b.rect.center.dx));
    }
    return rows;
  }

  List<List<_MarketplaceFocusTarget>> _navigationRows() {
    final marketplace = ref.read(marketplaceControllerProvider);
    final torrentSources = ref.read(userTorrentSourcesControllerProvider);
    final rows = <List<_MarketplaceFocusTarget>>[];

    final header = [
      _backFocus,
      _refreshFocus,
    ].map(_focusTarget).nonNulls.toList();
    if (header.isNotEmpty) rows.add(header);
    rows.addAll(
      _groupByVisualRow([_phoneFocus, _addManifestFocus, _addRepositoryFocus]),
    );

    for (final url in torrentSources.manifestUrls) {
      final row = [
        _dynamicFocus(
          'torrent:$url:remove',
          'Marketplace torrent source Remove',
        ),
      ].map(_focusTarget).nonNulls.toList();
      if (row.isNotEmpty) rows.add(row);
    }
    for (final repository in marketplace.repositories) {
      final row = [
        _dynamicFocus(
          'repository:${repository.url}:toggle',
          'Marketplace repository Enabled',
        ),
        _dynamicFocus(
          'repository:${repository.url}:remove',
          'Marketplace repository Remove',
        ),
      ].map(_focusTarget).nonNulls.toList();
      if (row.isNotEmpty) rows.add(row);
    }
    final testAll = _focusTarget(_testAllProvidersFocus);
    if (testAll != null && marketplace.installed.isNotEmpty) {
      rows.add([testAll]);
    }

    rows.addAll(
      _groupByVisualRow(
        marketplace.installed.expand((addon) {
          final id = addon.manifest.id;
          return [
            _dynamicFocus(
              'installed:$id:test',
              'Marketplace installed addon Test',
            ),
            _dynamicFocus(
              'installed:$id:toggle',
              'Marketplace installed addon Toggle',
            ),
            _dynamicFocus(
              'installed:$id:reset',
              'Marketplace installed addon Reset',
            ),
            _dynamicFocus(
              'installed:$id:uninstall',
              'Marketplace installed addon Uninstall',
            ),
          ];
        }),
      ),
    );
    final catalogControls = [
      _languageFilterFocus,
      _catalogSortFocus,
    ].map(_focusTarget).nonNulls.toList();
    if (catalogControls.isNotEmpty) rows.add(catalogControls);
    final visibleCatalog = _visibleCatalog(marketplace.catalog);
    rows.addAll(
      _groupByVisualRow(
        visibleCatalog.map(
          (addon) => _dynamicFocus(
            'catalog:${addon.id}:action',
            'Marketplace catalog addon action',
          ),
        ),
      ),
    );
    return rows;
  }

  List<MarketplaceAddon> _visibleCatalog(List<MarketplaceAddon> catalog) {
    final languages = marketplaceCatalogLanguages(catalog);
    final effectiveLanguage = languages.contains(_catalogLanguage)
        ? _catalogLanguage
        : null;
    return filterAndSortMarketplaceCatalog(
      catalog,
      languageCode: effectiveLanguage,
      sort: _catalogSort,
    );
  }

  KeyEventResult _handleNavigationKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final horizontal =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    final vertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!horizontal && !vertical) return KeyEventResult.ignored;

    final current = FocusManager.instance.primaryFocus;
    if (current == null) return KeyEventResult.ignored;
    final repositoryTarget = _focusTarget(_addRepositoryFocus);
    final manifestTarget = _focusTarget(_addManifestFocus);
    if (key == LogicalKeyboardKey.arrowUp &&
        current == _addRepositoryFocus &&
        repositoryTarget != null &&
        manifestTarget != null &&
        repositoryTarget.rect.center.dy - manifestTarget.rect.center.dy > 12) {
      _focusAndReveal(_addManifestFocus, key);
      return KeyEventResult.handled;
    }
    final rows = _navigationRows();
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      final columnIndex = row.indexWhere((target) => target.node == current);
      if (columnIndex < 0) continue;

      if (horizontal) {
        final nextColumn = key == LogicalKeyboardKey.arrowLeft
            ? columnIndex - 1
            : columnIndex + 1;
        if (nextColumn < 0 || nextColumn >= row.length) {
          return KeyEventResult.handled;
        }
        _focusAndReveal(row[nextColumn].node, key);
        return KeyEventResult.handled;
      }

      final nextRowIndex = key == LogicalKeyboardKey.arrowUp
          ? rowIndex - 1
          : rowIndex + 1;
      // Let Flutter's traversal policy scroll a lazy sliver when its next
      // semantic row has not been built yet. The following D-pad event will
      // see that mounted row and resume this explicit graph.
      if (nextRowIndex < 0 || nextRowIndex >= rows.length) {
        return KeyEventResult.ignored;
      }
      final currentX = row[columnIndex].rect.center.dx;
      final nextRow = rows[nextRowIndex];
      // Moving down from a one-action semantic row (for example a Torrent
      // source Remove control) enters the next row at its primary action.
      // Otherwise, keep the closest visual column for natural reverse/grid
      // travel.
      final target = key == LogicalKeyboardKey.arrowDown && row.length == 1
          ? nextRow.first
          : nextRow.reduce(
              (best, candidate) =>
                  (candidate.rect.center.dx - currentX).abs() <
                      (best.rect.center.dx - currentX).abs()
                  ? candidate
                  : best,
            );
      _focusAndReveal(target.node, key);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusAndReveal(FocusNode target, LogicalKeyboardKey direction) {
    target.requestFocus();
    final targetContext = target.context;
    if (targetContext == null) return;
    final towardEnd =
        direction == LogicalKeyboardKey.arrowDown ||
        direction == LogicalKeyboardKey.arrowRight;
    unawaited(
      Scrollable.ensureVisible(
        targetContext,
        alignment: towardEnd ? 1 : 0,
        alignmentPolicy: towardEnd
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(marketplaceControllerProvider);
    final controller = ref.read(marketplaceControllerProvider.notifier);
    final torrentSources = ref.watch(userTorrentSourcesControllerProvider);
    final torrentSourceController = ref.read(
      userTorrentSourcesControllerProvider.notifier,
    );
    final catalogLanguages = marketplaceCatalogLanguages(state.catalog);
    final effectiveCatalogLanguage = catalogLanguages.contains(_catalogLanguage)
        ? _catalogLanguage
        : null;
    final visibleCatalog = filterAndSortMarketplaceCatalog(
      state.catalog,
      languageCode: effectiveCatalogLanguage,
      sort: _catalogSort,
    );
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _handleNavigationKey,
      child: Scaffold(
        backgroundColor: context.appPalette == AppThemePalette.defaults
            ? Colors.black
            : context.appPalette.background,
        body: SafeArea(
          minimum: context.responsiveScreenPadding,
          child: Column(
            children: [
              Row(
                children: [
                  _MarketplaceButton(
                    icon: Icons.arrow_back_rounded,
                    label: context.isCompactWidth ? null : 'Settings',
                    autofocus: true,
                    focusNode: _backFocus,
                    onPressed: context.pop,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sources',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        if (!context.isCompactWidth)
                          Text(
                            'Add Marketplace repositories and Torrent source manifests you trust.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                      ],
                    ),
                  ),
                  _MarketplaceButton(
                    icon: Icons.refresh_rounded,
                    label: context.isCompactWidth ? null : 'Refresh',
                    focusNode: _refreshFocus,
                    onPressed: state.loading
                        ? null
                        : () => controller.refresh(),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: state.loading && state.repositories.isEmpty
                    ? Center(
                        child: CircularProgressIndicator(
                          color: context.appPalette.accentBright,
                        ),
                      )
                    : CustomScrollView(
                        slivers: [
                          _section(
                            context,
                            icon: Icons.hub_rounded,
                            title: 'Sources',
                            subtitle:
                                'Enter URLs manually or use one QR code to add both source types from your phone.',
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 24),
                              child: Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _MarketplaceButton(
                                    icon: Icons.phone_android_rounded,
                                    label: 'Add sources with phone',
                                    focusNode: _phoneFocus,
                                    onPressed: () =>
                                        showSourcePairingDialog(context),
                                  ),
                                  _MarketplaceButton(
                                    icon: Icons.add_link_rounded,
                                    label: 'Add Torrent source manifests',
                                    focusNode: _addManifestFocus,
                                    onPressed: () => _addTorrentSource(
                                      context,
                                      torrentSourceController,
                                    ),
                                  ),
                                  _MarketplaceButton(
                                    icon: Icons.playlist_add_rounded,
                                    label: 'Add Marketplace repositories',
                                    focusNode: _addRepositoryFocus,
                                    onPressed: () =>
                                        _addRepository(context, controller),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          _section(
                            context,
                            icon: Icons.cloud_download_outlined,
                            title: 'Torrent source manifests',
                            subtitle:
                                'Optional Stremio-compatible manifests you add yourself. TetoTV does not include or recommend a torrent catalog.',
                          ),
                          if (torrentSources.manifestUrls.isEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  'No torrent sources added. Debrid searches stay unavailable until you explicitly add one.',
                                  style: TextStyle(
                                    color: context.appPalette.mutedText,
                                  ),
                                ),
                              ),
                            )
                          else
                            SliverList.builder(
                              itemCount: torrentSources.manifestUrls.length,
                              itemBuilder: (context, index) {
                                final url = torrentSources.manifestUrls[index];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _TorrentSourceTile(
                                    url: url,
                                    removeFocusNode: _dynamicFocus(
                                      'torrent:$url:remove',
                                      'Marketplace torrent source Remove',
                                    ),
                                    onRemove: () =>
                                        torrentSourceController.remove(url),
                                  ),
                                );
                              },
                            ),
                          _section(
                            context,
                            icon: Icons.hub_outlined,
                            title: 'Marketplace repositories',
                            subtitle:
                                'TetoTV imports Seanime online-stream providers. Manga and UI plugins are ignored because they cannot supply playback streams. Catalogs are cached locally.',
                          ),
                          SliverList.builder(
                            itemCount: state.repositories.length,
                            itemBuilder: (context, index) {
                              final repository = state.repositories[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _RepositoryTile(
                                  repository: repository,
                                  error: state.repositoryErrors[repository.url],
                                  toggleFocusNode: _dynamicFocus(
                                    'repository:${repository.url}:toggle',
                                    'Marketplace repository Enabled',
                                  ),
                                  removeFocusNode: _dynamicFocus(
                                    'repository:${repository.url}:remove',
                                    'Marketplace repository Remove',
                                  ),
                                  onToggle: () =>
                                      controller.setRepositoryEnabled(
                                        repository,
                                        !repository.enabled,
                                      ),
                                  onRemove: () => _confirmRepositoryRemoval(
                                    context,
                                    repository,
                                    controller,
                                  ),
                                ),
                              );
                            },
                          ),
                          if (state.installed.isNotEmpty) ...[
                            _section(
                              context,
                              icon: Icons.extension_rounded,
                              title: 'Installed providers',
                              subtitle:
                                  'Enabled providers participate in Web Stream searches. Compatibility is checked automatically every 24 hours.',
                              trailing: _MarketplaceButton(
                                icon: state.testingAllProviders
                                    ? Icons.hourglass_top_rounded
                                    : Icons.fact_check_outlined,
                                label: state.testingAllProviders
                                    ? 'Testing all…'
                                    : 'Test all',
                                focusNode: _testAllProvidersFocus,
                                onPressed: state.testingAllProviders
                                    ? null
                                    : () => controller
                                          .testAllInstalledProviders(),
                              ),
                            ),
                            SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 540,
                                    mainAxisExtent: 300,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final addon = state.installed[index];
                                return _InstalledAddonCard(
                                  addon: addon,
                                  health:
                                      state.providerHealth[addon.manifest.id],
                                  message:
                                      state.providerMessages[addon.manifest.id],
                                  busy: state.busyAddonId == addon.manifest.id,
                                  testFocusNode: _dynamicFocus(
                                    'installed:${addon.manifest.id}:test',
                                    'Marketplace installed addon Test',
                                  ),
                                  toggleFocusNode: _dynamicFocus(
                                    'installed:${addon.manifest.id}:toggle',
                                    'Marketplace installed addon Toggle',
                                  ),
                                  resetFocusNode: _dynamicFocus(
                                    'installed:${addon.manifest.id}:reset',
                                    'Marketplace installed addon Reset',
                                  ),
                                  uninstallFocusNode: _dynamicFocus(
                                    'installed:${addon.manifest.id}:uninstall',
                                    'Marketplace installed addon Uninstall',
                                  ),
                                  onToggle: () => controller.setAddonEnabled(
                                    addon.manifest.id,
                                    !addon.enabled,
                                  ),
                                  onUninstall: () => _confirmUninstall(
                                    context,
                                    addon,
                                    controller,
                                  ),
                                  onTest: () => controller.testAddon(addon),
                                  onReset: () => controller.resetAddonHealth(
                                    addon.manifest.id,
                                  ),
                                );
                              }, childCount: state.installed.length),
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 28),
                            ),
                          ],
                          _section(
                            context,
                            icon: Icons.storefront_outlined,
                            title: 'Available web providers',
                            subtitle:
                                '${visibleCatalog.where((item) => item.isCompatible).length} of '
                                '${state.catalog.where((item) => item.isCompatible).length} compatible JavaScript and TypeScript providers. '
                                'TypeScript is compiled once during installation.',
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  _MarketplaceButton(
                                    icon: Icons.translate_rounded,
                                    label: effectiveCatalogLanguage == null
                                        ? 'Language: All'
                                        : 'Language: ${marketplaceCatalogLanguageLabel(effectiveCatalogLanguage)}',
                                    focusNode: _languageFilterFocus,
                                    onPressed: catalogLanguages.isEmpty
                                        ? null
                                        : () async {
                                            final selection =
                                                await _chooseCatalogLanguage(
                                                  context,
                                                  languages: catalogLanguages,
                                                  selected:
                                                      effectiveCatalogLanguage,
                                                );
                                            if (!mounted || selection == null) {
                                              return;
                                            }
                                            setState(() {
                                              _catalogLanguage =
                                                  selection.languageCode;
                                            });
                                          },
                                  ),
                                  _MarketplaceButton(
                                    icon: Icons.sort_by_alpha_rounded,
                                    label:
                                        _catalogSort ==
                                            MarketplaceCatalogSort.name
                                        ? 'Sort: Name'
                                        : 'Sort: Language',
                                    focusNode: _catalogSortFocus,
                                    onPressed: state.catalog.isEmpty
                                        ? null
                                        : () async {
                                            final selected =
                                                await _chooseCatalogSort(
                                                  context,
                                                  selected: _catalogSort,
                                                );
                                            if (!mounted || selected == null) {
                                              return;
                                            }
                                            setState(
                                              () => _catalogSort = selected,
                                            );
                                          },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (state.catalog.isEmpty)
                            SliverToBoxAdapter(
                              child: _EmptyCatalog(
                                errors: state.repositoryErrors,
                              ),
                            )
                          else if (visibleCatalog.isEmpty)
                            SliverToBoxAdapter(
                              child: _EmptyCatalog(
                                errors: const {},
                                message:
                                    'No providers declare ${marketplaceCatalogLanguageLabel(effectiveCatalogLanguage ?? 'unknown')} support.',
                              ),
                            )
                          else
                            SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 540,
                                    mainAxisExtent: 250,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final addon = visibleCatalog[index];
                                final installed = state.installedById(addon.id);
                                final busy = state.busyAddonId == addon.id;
                                return _CatalogAddonCard(
                                  addon: addon,
                                  installed: installed,
                                  updateAvailable: state.updateAvailable(addon),
                                  busy: busy,
                                  actionFocusNode: _dynamicFocus(
                                    'catalog:${addon.id}:action',
                                    'Marketplace catalog addon action',
                                  ),
                                  onInstall: addon.isCompatible && !busy
                                      ? () => _confirmInstall(
                                          context,
                                          addon,
                                          controller,
                                        )
                                      : null,
                                );
                              }, childCount: visibleCatalog.length),
                            ),
                          const SliverToBoxAdapter(child: SizedBox(height: 28)),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

SliverToBoxAdapter _section(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
  Widget? trailing,
}) => SliverToBoxAdapter(
  child: Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: context.appPalette.accentBright),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing],
      ],
    ),
  ),
);

class _RepositoryTile extends StatelessWidget {
  const _RepositoryTile({
    required this.repository,
    required this.error,
    required this.toggleFocusNode,
    required this.removeFocusNode,
    required this.onToggle,
    required this.onRemove,
  });

  final AddonRepository repository;
  final String? error;
  final FocusNode toggleFocusNode;
  final FocusNode removeFocusNode;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: Row(
        children: [
          Icon(
            repository.enabled ? Icons.link_rounded : Icons.link_off_rounded,
            color: repository.enabled
                ? context.appPalette.secondaryAccent
                : Colors.white38,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'User repository',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                Text(
                  repository.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (error != null)
                  Text(
                    error!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFFF929B),
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          _MarketplaceButton(
            icon: repository.enabled
                ? Icons.toggle_on_rounded
                : Icons.toggle_off_rounded,
            label: context.isCompactWidth
                ? null
                : repository.enabled
                ? 'Enabled'
                : 'Disabled',
            focusNode: toggleFocusNode,
            onPressed: onToggle,
          ),
          const SizedBox(width: 8),
          _MarketplaceButton(
            icon: Icons.delete_outline_rounded,
            label: context.isCompactWidth ? null : 'Remove',
            focusNode: removeFocusNode,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _TorrentSourceTile extends StatelessWidget {
  const _TorrentSourceTile({
    required this.url,
    required this.removeFocusNode,
    required this.onRemove,
  });

  final String url;
  final FocusNode removeFocusNode;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    decoration: BoxDecoration(
      color: context.appPalette.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: Row(
      children: [
        Icon(
          Icons.cloud_done_outlined,
          color: context.appPalette.secondaryAccent,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'User torrent source',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        _MarketplaceButton(
          icon: Icons.delete_outline_rounded,
          label: context.isCompactWidth ? null : 'Remove',
          focusNode: removeFocusNode,
          onPressed: onRemove,
        ),
      ],
    ),
  );
}

class _InstalledAddonCard extends StatelessWidget {
  const _InstalledAddonCard({
    required this.addon,
    required this.health,
    required this.message,
    required this.busy,
    required this.testFocusNode,
    required this.toggleFocusNode,
    required this.resetFocusNode,
    required this.uninstallFocusNode,
    required this.onToggle,
    required this.onUninstall,
    required this.onTest,
    required this.onReset,
  });

  final InstalledStreamingAddon addon;
  final ProviderHealth? health;
  final String? message;
  final bool busy;
  final FocusNode testFocusNode;
  final FocusNode toggleFocusNode;
  final FocusNode resetFocusNode;
  final FocusNode uninstallFocusNode;
  final VoidCallback onToggle;
  final VoidCallback onUninstall;
  final VoidCallback onTest;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => _AddonShell(
    addon: addon.manifest,
    badge: !addon.enabled
        ? 'DISABLED'
        : health?.lastFailureReason == 'runtime_api' ||
              health?.lastTestReason == 'runtime_api'
        ? 'INCOMPATIBLE RUNTIME'
        : health?.lastFailureReason == 'unsafe_target' ||
              health?.lastTestReason == 'unsafe_target'
        ? 'BLOCKED FOR SAFETY'
        : health?.isQuarantined == true
        ? 'PAUSED AFTER FAILURES'
        : health?.lastTestReason == 'test_title_unavailable'
        ? 'TEST INCONCLUSIVE'
        : health?.compatibilityScore != null
        ? 'HEALTH ${health!.compatibilityScore}/100'
        : health?.lastSuccessAt != null
        ? 'HEALTHY • NOT TESTED'
        : 'NOT TESTED',
    footer: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (health?.lastTestedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Last tested ${_shortTestDate(health!.lastTestedAt!)}',
                  style: TextStyle(
                    color: context.appPalette.mutedText,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _providerStageSummary(health!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.appPalette.mutedText,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        if (message != null || health?.lastError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text(
              message ??
                  '${health!.consecutiveFailures} failure(s): ${health!.lastError}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: context.appPalette.mutedText,
                fontSize: 11,
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MarketplaceButton(
              icon: busy
                  ? Icons.hourglass_top_rounded
                  : Icons.health_and_safety,
              label: busy ? 'Testing…' : 'Test',
              focusNode: testFocusNode,
              onPressed: busy || !addon.enabled ? null : onTest,
            ),
            _MarketplaceButton(
              icon: addon.enabled
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              label: addon.enabled ? 'Disable' : 'Enable',
              focusNode: toggleFocusNode,
              onPressed: onToggle,
            ),
            if (health != null)
              _MarketplaceButton(
                icon: Icons.restart_alt_rounded,
                label: 'Reset',
                focusNode: resetFocusNode,
                onPressed: onReset,
              ),
            _MarketplaceButton(
              icon: Icons.delete_outline_rounded,
              label: 'Uninstall',
              focusNode: uninstallFocusNode,
              onPressed: onUninstall,
            ),
          ],
        ),
      ],
    ),
  );
}

String _shortTestDate(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _providerStageSummary(ProviderHealth health) {
  const stages = [
    ('search', 'Search'),
    ('title_matching', 'Title'),
    ('episode_lookup', 'Episode'),
    ('server_lookup', 'Server'),
    ('stream_extraction', 'Stream'),
  ];
  final current = stages.indexWhere((item) => item.$1 == health.lastTestStage);
  final passed = health.lastTestReason == 'compatible';
  final inconclusive = health.lastTestReason == 'test_title_unavailable';
  return stages.indexed
      .map((entry) {
        final (index, item) = entry;
        final marker = inconclusive
            ? index == current
                  ? '?'
                  : '—'
            : passed || index < current
            ? '✓'
            : index == current
            ? '✕'
            : '—';
        return '${item.$2} $marker';
      })
      .join(' • ');
}

class _CatalogAddonCard extends StatelessWidget {
  const _CatalogAddonCard({
    required this.addon,
    required this.installed,
    required this.updateAvailable,
    required this.busy,
    required this.actionFocusNode,
    required this.onInstall,
  });

  final MarketplaceAddon addon;
  final InstalledStreamingAddon? installed;
  final bool updateAvailable;
  final bool busy;
  final FocusNode actionFocusNode;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final unsupported = !addon.isCompatible;
    return _AddonShell(
      addon: addon,
      badge: unsupported
          ? '${addon.language.toUpperCase()} / UNSUPPORTED'
          : installed == null
          ? addon.isTypescript
                ? 'TYPESCRIPT'
                : 'AVAILABLE'
          : updateAvailable
          ? 'UPDATE AVAILABLE'
          : 'INSTALLED',
      footer: _MarketplaceButton(
        icon: busy
            ? Icons.hourglass_top_rounded
            : updateAvailable
            ? Icons.system_update_alt_rounded
            : installed == null
            ? Icons.download_rounded
            : Icons.check_rounded,
        label: busy
            ? 'Installing…'
            : updateAvailable
            ? 'Update'
            : installed == null
            ? unsupported
                  ? 'Incompatible runtime'
                  : 'Install'
            : 'Installed',
        focusNode: actionFocusNode,
        onPressed: installed != null && !updateAvailable ? null : onInstall,
      ),
    );
  }
}

class _AddonShell extends StatelessWidget {
  const _AddonShell({
    required this.addon,
    required this.badge,
    required this.footer,
  });

  final MarketplaceAddon addon;
  final String badge;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: .08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _AddonIcon(uri: addon.iconUri),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      addon.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${addon.author} • ${addon.locale.toUpperCase()}'
                      '${addon.version == null ? '' : ' • v${addon.version}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      addon.manifestUri.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appPalette.mutedText,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: context.appPalette.accent.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              badge,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Text(
              addon.description.isEmpty
                  ? 'No description provided.'
                  : addon.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Align(alignment: Alignment.centerRight, child: footer),
        ],
      ),
    );
  }
}

class _AddonIcon extends StatelessWidget {
  const _AddonIcon({required this.uri});

  final Uri? uri;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 50,
    height: 50,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: context.appPalette.accent.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        uri == null ? Icons.extension_rounded : Icons.language_rounded,
      ),
    ),
  );
}

class _MarketplaceButton extends StatelessWidget {
  const _MarketplaceButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
  });

  final IconData icon;
  final String? label;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return ExcludeFocus(
      excluding: disabled,
      child: IgnorePointer(
        ignoring: disabled,
        child: Opacity(
          opacity: disabled ? .42 : 1,
          child: TvFocusable(
            autofocus: autofocus,
            focusNode: focusNode,
            onPressed: onPressed ?? () {},
            borderRadius: BorderRadius.circular(12),
            focusScale: 1.025,
            child: Container(
              constraints: const BoxConstraints(minHeight: 42),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              color: context.appPalette.selectableSurface,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20),
                  if (label != null) ...[
                    const SizedBox(width: 7),
                    Text(
                      label!,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog({required this.errors, this.message});

  final Map<String, String> errors;
  final String? message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 42),
    child: Center(
      child: Text(
        message ??
            (errors.isEmpty
                ? 'No compatible providers were found.'
                : 'Repositories could not be loaded. Select Refresh to retry.'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ),
  );
}

class _CatalogLanguageSelection {
  const _CatalogLanguageSelection(this.languageCode);

  final String? languageCode;
}

Future<_CatalogLanguageSelection?> _chooseCatalogLanguage(
  BuildContext context, {
  required List<String> languages,
  required String? selected,
}) => showDialog<_CatalogLanguageSelection>(
  context: context,
  builder: (dialogContext) => SimpleDialog(
    backgroundColor: dialogContext.appPalette.surface,
    title: const Text('Filter provider language'),
    children: [
      TextButton(
        autofocus: selected == null,
        onPressed: () =>
            Navigator.pop(dialogContext, const _CatalogLanguageSelection(null)),
        child: const Align(
          alignment: Alignment.centerLeft,
          child: Text('All languages'),
        ),
      ),
      for (final language in languages)
        TextButton(
          autofocus: selected == language,
          onPressed: () =>
              Navigator.pop(dialogContext, _CatalogLanguageSelection(language)),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(marketplaceCatalogLanguageLabel(language)),
          ),
        ),
    ],
  ),
);

Future<MarketplaceCatalogSort?> _chooseCatalogSort(
  BuildContext context, {
  required MarketplaceCatalogSort selected,
}) => showDialog<MarketplaceCatalogSort>(
  context: context,
  builder: (dialogContext) => SimpleDialog(
    backgroundColor: dialogContext.appPalette.surface,
    title: const Text('Sort available providers'),
    children: [
      TextButton(
        autofocus: selected == MarketplaceCatalogSort.name,
        onPressed: () =>
            Navigator.pop(dialogContext, MarketplaceCatalogSort.name),
        child: const Align(
          alignment: Alignment.centerLeft,
          child: Text('Name (A–Z)'),
        ),
      ),
      TextButton(
        autofocus: selected == MarketplaceCatalogSort.language,
        onPressed: () =>
            Navigator.pop(dialogContext, MarketplaceCatalogSort.language),
        child: const Align(
          alignment: Alignment.centerLeft,
          child: Text('Language, then name'),
        ),
      ),
    ],
  ),
);

Future<void> _addRepository(
  BuildContext context,
  MarketplaceController controller,
) async {
  final input = TextEditingController();
  try {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.appPalette.surface,
        title: const Text('Add Marketplace repositories'),
        content: SizedBox(
          width: 680,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste or enter up to 32 public HTTPS catalog links. Separate multiple links with spaces or put one on each line.',
              ),
              const SizedBox(height: 14),
              TvTextInput(
                controller: input,
                autofocus: true,
                labelText: 'HTTPS catalog links',
                hintText: 'https://example.com/marketplace.json',
                keyboardTitle: 'Repository links',
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _pasteSourceLinks(input),
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text('PASTE LINKS'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ADD ALL'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    final result = await controller.addRepositories(input.text);
    if (context.mounted) {
      final detail = result.rejected.isEmpty
          ? result.summary
          : '${result.summary} ${result.rejected.first}';
      _notice(context, detail);
    }
  } finally {
    input.dispose();
  }
}

Future<void> _addTorrentSource(
  BuildContext context,
  UserTorrentSourcesController controller,
) async {
  final input = TextEditingController();
  try {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.appPalette.surface,
        title: const Text('Add torrent source manifests'),
        content: SizedBox(
          width: 680,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste or enter multiple Torrent source manifests you trust. Separate links with spaces or put one on each line. Only use sources for content you are authorized to access.',
              ),
              const SizedBox(height: 14),
              TvTextInput(
                controller: input,
                autofocus: true,
                labelText: 'HTTPS manifest links',
                hintText: 'https://example.com/addon/manifest.json',
                keyboardTitle: 'Torrent manifest links',
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _pasteSourceLinks(input),
            icon: const Icon(Icons.content_paste_rounded),
            label: const Text('PASTE LINKS'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('ADD ALL'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    final result = await controller.addAll(input.text);
    if (context.mounted) {
      final detail = result.rejected.isEmpty
          ? result.summary
          : '${result.summary} ${result.rejected.first}';
      _notice(context, detail);
    }
  } finally {
    input.dispose();
  }
}

Future<void> _pasteSourceLinks(TextEditingController controller) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final value = data?.text?.trim();
  if (value == null || value.isEmpty) return;
  controller.value = TextEditingValue(
    text: value,
    selection: TextSelection.collapsed(offset: value.length),
  );
}

Future<void> _confirmInstall(
  BuildContext context,
  MarketplaceAddon addon,
  MarketplaceController controller,
) async {
  final accepted = await _confirm(
    context,
    title: 'Install ${addon.name}?',
    body:
        'This third-party provider may access public HTTPS websites. It cannot access TetoTV tokens, device files, or native Android APIs. Only install repositories you trust.',
    action: 'INSTALL',
  );
  if (!accepted) return;
  try {
    await controller.install(addon);
  } catch (error) {
    if (context.mounted) _notice(context, error.toString());
  }
}

Future<void> _confirmUninstall(
  BuildContext context,
  InstalledStreamingAddon addon,
  MarketplaceController controller,
) async {
  if (await _confirm(
    context,
    title: 'Uninstall ${addon.manifest.name}?',
    body:
        'Its web streams will no longer appear. Playback history and tracking are not changed.',
    action: 'UNINSTALL',
  )) {
    await controller.uninstall(addon.manifest.id);
  }
}

Future<void> _confirmRepositoryRemoval(
  BuildContext context,
  AddonRepository repository,
  MarketplaceController controller,
) async {
  if (await _confirm(
    context,
    title: 'Remove repository?',
    body:
        'Already installed providers remain installed. Add the repository URL again later if you want its catalog back.',
    action: 'REMOVE',
  )) {
    await controller.removeRepository(repository);
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) => showMarketplaceConfirmationDialog(
  context,
  title: title,
  body: body,
  action: action,
  autofocusAction: action == 'INSTALL' || action == 'UNINSTALL',
);

/// Shows the Marketplace confirmation used for install and removal actions.
///
/// Install and uninstall actions deliberately own initial focus so a TV remote
/// can confirm them immediately. Left and right are handled explicitly because
/// some Android TV focus engines do not enter [AlertDialog.actions] until a
/// second directional key press.
Future<bool> showMarketplaceConfirmationDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool autofocusAction = false,
}) async {
  final cancelFocus = FocusNode(debugLabel: 'marketplace.confirm.cancel');
  final actionFocus = FocusNode(debugLabel: 'marketplace.confirm.action');
  try {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: dialogContext.appPalette.surface,
            title: Text(title),
            content: SizedBox(width: 620, child: Text(body)),
            actions: [
              Focus(
                canRequestFocus: false,
                onKeyEvent: (_, event) {
                  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                    return KeyEventResult.ignored;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    cancelFocus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    actionFocus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      focusNode: cancelFocus,
                      autofocus: !autofocusAction,
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('CANCEL'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      focusNode: actionFocus,
                      autofocus: autofocusAction,
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(action),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ) ??
        false;
  } finally {
    cancelFocus.dispose();
    actionFocus.dispose();
  }
}

void _notice(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: const Color(0xFF3A1119)),
  );
}
