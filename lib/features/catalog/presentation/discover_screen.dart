import 'dart:async';

import 'package:anime_tv/core/diagnostics/anonymous_crash_reporter.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/catalog_grid.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/tracking/presentation/catalog_tracking_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({this.autofocusNavigation = false, super.key});

  final bool autofocusNavigation;

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  CatalogFilters _filters = const CatalogFilters();
  late Future<List<AnimeSummary>> _results;
  final _backFocus = FocusNode(debugLabel: 'discover.back');
  final _resetFocus = FocusNode(debugLabel: 'discover.reset');
  final _filtersFocus = FocusNode(debugLabel: 'discover.filters');
  final _firstResultFocus = FocusNode(debugLabel: 'discover.result.first');
  final _emptyFiltersFocus = FocusNode(debugLabel: 'discover.empty.filters');
  final _headerRepeatGate = TvDirectionalRepeatGate(
    repeatInterval: const Duration(milliseconds: 92),
  );

  @override
  void initState() {
    super.initState();
    _results = _discover();
  }

  Future<List<AnimeSummary>> _discover() async {
    try {
      return await ref.read(catalogClientProvider).discover(_filters);
    } catch (error, stackTrace) {
      unawaited(
        recordAnonymousHandledError(
          area: AnonymousErrorArea.catalog,
          error: error,
          stack: stackTrace,
        ),
      );
      rethrow;
    }
  }

  Future<void> _openFilters() async {
    final next = await showDialog<CatalogFilters>(
      context: context,
      barrierDismissible: true,
      builder: (context) => _DiscoverFiltersDialog(initial: _filters),
    );
    if (next == null || !mounted) return;
    setState(() {
      _filters = next;
      _results = _discover();
    });
  }

  void _reset() {
    setState(() {
      _filters = const CatalogFilters();
      _results = _discover();
    });
  }

  KeyEventResult _handleNavigation(
    FocusNode _,
    KeyEvent event, {
    TetoTopLevelLayout? layout,
  }) {
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!directional) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _headerRepeatGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_headerRepeatGate.accept(event)) return KeyEventResult.handled;
    final current = FocusManager.instance.primaryFocus;
    if (current == _backFocus && key == LogicalKeyboardKey.arrowRight) {
      (_resetFocus.context == null ? _filtersFocus : _resetFocus)
          .requestFocus();
      return KeyEventResult.handled;
    }
    if (current == _resetFocus) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (layout?.usesTvRail == true) {
          layout!.focusRail();
        } else if (_backFocus.context != null) {
          _backFocus.requestFocus();
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _filtersFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    if (current == _filtersFocus) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (_resetFocus.context != null) {
          _resetFocus.requestFocus();
        } else if (_firstResultFocus.context != null) {
          _focusAndReveal(_firstResultFocus, towardEnd: true);
        } else if (_backFocus.context != null) {
          _backFocus.requestFocus();
        } else {
          return KeyEventResult.handled;
        }
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowDown &&
        (current == _backFocus ||
            current == _resetFocus ||
            current == _filtersFocus) &&
        _firstResultFocus.context != null) {
      _focusAndReveal(_firstResultFocus, towardEnd: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && current == _firstResultFocus) {
      _filtersFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusAndReveal(FocusNode node, {required bool towardEnd}) {
    node.requestFocus();
    final target = node.context;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        alignment: towardEnd ? 1 : 0,
        alignmentPolicy: towardEnd
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    _headerRepeatGate.reset();
    _backFocus.dispose();
    _resetFocus.dispose();
    _filtersFocus.dispose();
    _firstResultFocus.dispose();
    _emptyFiltersFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final preferences = ref.watch(settingsPreferencesProvider);
    final summary = _filterSummary(_filters);
    return TetoTopLevelShell(
      preferences: preferences,
      activeDestination: TopNavigationDestination.discover,
      firstContentFocusNode: _firstResultFocus,
      fallbackContentFocusNode: _filtersFocus,
      autofocusRail: widget.autofocusNavigation,
      builder: (context, layout) => Focus(
        onKeyEvent: (node, event) =>
            _handleNavigation(node, event, layout: layout),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!layout.usesPersistentNavigation)
              MainNavigationBar(
                active: MainNavigationDestination.discover,
                preferences: preferences,
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (preferences.interfaceMode == InterfaceMode.phone) ...[
                  _HeaderButton(
                    focusNode: _backFocus,
                    icon: Icons.arrow_back_rounded,
                    label: context.isCompactWidth ? null : 'Back',
                    onPressed: () => _returnToPreviousOrHome(context),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Discover',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontSize: layout.usesTvRail ? 30 : null,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: context.appPalette.mutedText),
                      ),
                    ],
                  ),
                ),
                if (_hasFilters(_filters)) ...[
                  _HeaderButton(
                    focusNode: _resetFocus,
                    icon: Icons.filter_alt_off_rounded,
                    label: context.isCompactWidth ? null : 'Reset',
                    onPressed: _reset,
                  ),
                  const SizedBox(width: 8),
                ],
                _HeaderButton(
                  focusNode: _filtersFocus,
                  icon: Icons.tune_rounded,
                  label: context.isCompactWidth ? null : 'Filters',
                  onPressed: _openFilters,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: FutureBuilder<List<AnimeSummary>>(
                future: _results,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Center(
                      child: CircularProgressIndicator(
                        color: context.appPalette.accentBright,
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return _DiscoverError(
                      message: snapshot.error.toString(),
                      onRetry: () => setState(() => _results = _discover()),
                      onReset: _reset,
                    );
                  }
                  final items = snapshot.data ?? const <AnimeSummary>[];
                  if (items.isEmpty) {
                    return _DiscoverEmptyState(
                      resetFocusNode: _firstResultFocus,
                      filtersFocusNode: _emptyFiltersFocus,
                      onReset: _reset,
                      onFilters: _openFilters,
                      onLeft: layout.usesPersistentNavigation
                          ? layout.focusRail
                          : preferences.interfaceMode == InterfaceMode.phone
                          ? _backFocus.requestFocus
                          : null,
                    );
                  }
                  return CatalogGrid(
                    items: items,
                    titlePreference: titlePreference,
                    autofocus: true,
                    firstFocusNode: _firstResultFocus,
                    onNavigateLeftFromFirstColumn:
                        layout.usesPersistentNavigation
                        ? layout.focusRail
                        : preferences.interfaceMode == InterfaceMode.phone
                        ? _backFocus.requestFocus
                        : null,
                    onNavigateUpFromFirstRow: () =>
                        _focusAndReveal(_filtersFocus, towardEnd: false),
                    onLongPress: (anime) => unawaited(
                      manageCatalogTrackingStatus(
                        context: context,
                        ref: ref,
                        anime: anime,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverEmptyState extends StatelessWidget {
  const _DiscoverEmptyState({
    required this.resetFocusNode,
    required this.filtersFocusNode,
    required this.onReset,
    required this.onFilters,
    required this.onLeft,
  });

  final FocusNode resetFocusNode;
  final FocusNode filtersFocusNode;
  final VoidCallback onReset;
  final VoidCallback onFilters;
  final VoidCallback? onLeft;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'No anime matched these filters.',
          style: TextStyle(color: context.appPalette.mutedText),
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            TvFocusable(
              key: const ValueKey('discover-empty-reset'),
              focusNode: resetFocusNode,
              autofocus: true,
              onPressed: onReset,
              onKeyEvent: onLeft == null
                  ? null
                  : (_, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        onLeft!();
                        return KeyEventResult.handled;
                      }
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.arrowRight) {
                        filtersFocusNode.requestFocus();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
              borderRadius: BorderRadius.circular(10),
              child: _EmptyStateAction(
                icon: Icons.filter_alt_off_rounded,
                label: 'Reset filters',
              ),
            ),
            TvFocusable(
              key: const ValueKey('discover-empty-filters'),
              focusNode: filtersFocusNode,
              onPressed: onFilters,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                  resetFocusNode.requestFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              borderRadius: BorderRadius.circular(10),
              child: const _EmptyStateAction(
                icon: Icons.tune_rounded,
                label: 'Filters',
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _EmptyStateAction extends StatelessWidget {
  const _EmptyStateAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    color: context.appPalette.selectableSurface,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19),
        const SizedBox(width: 7),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    ),
  );
}

void _returnToPreviousOrHome(BuildContext context) {
  if (Navigator.of(context).canPop()) {
    context.pop();
    return;
  }
  context.go('/');
}

class _DiscoverFiltersDialog extends StatefulWidget {
  const _DiscoverFiltersDialog({required this.initial});

  final CatalogFilters initial;

  @override
  State<_DiscoverFiltersDialog> createState() => _DiscoverFiltersDialogState();
}

class _DiscoverFiltersDialogState extends State<_DiscoverFiltersDialog> {
  late final TextEditingController _titleController;
  final _closeFocus = FocusNode(debugLabel: 'discover.filters.close');
  final _titleFocus = FocusNode(debugLabel: 'discover.filters.title');
  final _sortFocus = FocusNode(debugLabel: 'discover.filters.sort');
  final _genreFocus = FocusNode(debugLabel: 'discover.filters.genre');
  final _tagFocus = FocusNode(debugLabel: 'discover.filters.tag');
  final _formatFocus = FocusNode(debugLabel: 'discover.filters.format');
  final _seasonFocus = FocusNode(debugLabel: 'discover.filters.season');
  final _yearFocus = FocusNode(debugLabel: 'discover.filters.year');
  final _statusFocus = FocusNode(debugLabel: 'discover.filters.status');
  final _scoreFocus = FocusNode(debugLabel: 'discover.filters.score');
  final _adultFocus = FocusNode(debugLabel: 'discover.filters.adult');
  final _resetFocus = FocusNode(debugLabel: 'discover.filters.reset');
  final _applyFocus = FocusNode(debugLabel: 'discover.filters.apply');
  String? _genre;
  String? _tag;
  String? _format;
  String? _season;
  String? _status;
  int? _year;
  int? _minimumScore;
  String _sort = 'POPULARITY_DESC';
  bool _includeAdult = false;
  bool _twoColumnLayout = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initial.search ?? '');
    _genre = widget.initial.genre;
    _tag = widget.initial.tag;
    _format = widget.initial.format;
    _season = widget.initial.season;
    _status = widget.initial.status;
    _year = widget.initial.year;
    _minimumScore = widget.initial.minimumScore;
    _sort = widget.initial.sort;
    _includeAdult = widget.initial.includeAdult;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _closeFocus.dispose();
    _titleFocus.dispose();
    _sortFocus.dispose();
    _genreFocus.dispose();
    _tagFocus.dispose();
    _formatFocus.dispose();
    _seasonFocus.dispose();
    _yearFocus.dispose();
    _statusFocus.dispose();
    _scoreFocus.dispose();
    _adultFocus.dispose();
    _resetFocus.dispose();
    _applyFocus.dispose();
    super.dispose();
  }

  CatalogFilters get _value => CatalogFilters(
    search: _titleController.text.trim().isEmpty
        ? null
        : _titleController.text.trim(),
    genre: _genre,
    tag: _tag,
    format: _format,
    season: _season,
    status: _status,
    year: _year,
    minimumScore: _minimumScore,
    includeAdult: _includeAdult,
    sort: _sort,
  );

  void _clear() {
    setState(() {
      _titleController.clear();
      _genre = null;
      _tag = null;
      _format = null;
      _season = null;
      _status = null;
      _year = null;
      _minimumScore = null;
      _sort = 'POPULARITY_DESC';
      _includeAdult = false;
    });
  }

  KeyEventResult _handleNavigation(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final current = FocusManager.instance.primaryFocus;
    if (current == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final next = _nextFilterFocus(current, key);
    if (next == null) return KeyEventResult.handled;
    _focusAndReveal(
      next,
      towardEnd:
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowRight,
    );
    return KeyEventResult.handled;
  }

  FocusNode? _nextFilterFocus(FocusNode current, LogicalKeyboardKey key) {
    if (!_twoColumnLayout) {
      final order = <FocusNode>[
        _closeFocus,
        _titleFocus,
        _sortFocus,
        _genreFocus,
        _tagFocus,
        _formatFocus,
        _seasonFocus,
        _yearFocus,
        _statusFocus,
        _scoreFocus,
        _adultFocus,
        _applyFocus,
      ];
      if (current == _resetFocus) {
        if (key == LogicalKeyboardKey.arrowRight) return _applyFocus;
        if (key == LogicalKeyboardKey.arrowUp) return _adultFocus;
        return null;
      }
      if (current == _applyFocus && key == LogicalKeyboardKey.arrowLeft) {
        return _resetFocus;
      }
      if (key != LogicalKeyboardKey.arrowUp &&
          key != LogicalKeyboardKey.arrowDown) {
        return null;
      }
      final index = order.indexOf(current);
      if (index < 0) return null;
      final next = key == LogicalKeyboardKey.arrowUp ? index - 1 : index + 1;
      return next < 0 || next >= order.length ? null : order[next];
    }

    final left = key == LogicalKeyboardKey.arrowLeft;
    final right = key == LogicalKeyboardKey.arrowRight;
    final up = key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (current == _closeFocus) return down ? _titleFocus : null;
    if (current == _titleFocus) {
      if (up) return _closeFocus;
      if (down) return _sortFocus;
      return null;
    }
    if (current == _sortFocus) {
      if (right) return _genreFocus;
      if (up) return _titleFocus;
      if (down) return _tagFocus;
    } else if (current == _genreFocus) {
      if (left) return _sortFocus;
      if (up) return _titleFocus;
      if (down) return _formatFocus;
    } else if (current == _tagFocus) {
      if (right) return _formatFocus;
      if (up) return _sortFocus;
      if (down) return _seasonFocus;
    } else if (current == _formatFocus) {
      if (left) return _tagFocus;
      if (up) return _genreFocus;
      if (down) return _yearFocus;
    } else if (current == _seasonFocus) {
      if (right) return _yearFocus;
      if (up) return _tagFocus;
      if (down) return _statusFocus;
    } else if (current == _yearFocus) {
      if (left) return _seasonFocus;
      if (up) return _formatFocus;
      if (down) return _scoreFocus;
    } else if (current == _statusFocus) {
      if (right) return _scoreFocus;
      if (up) return _seasonFocus;
      if (down) return _adultFocus;
    } else if (current == _scoreFocus) {
      if (left) return _statusFocus;
      if (up) return _yearFocus;
      if (down) return _adultFocus;
    } else if (current == _adultFocus) {
      if (up) return _statusFocus;
      if (down) return _applyFocus;
    } else if (current == _resetFocus) {
      if (right) return _applyFocus;
      if (up) return _adultFocus;
    } else if (current == _applyFocus) {
      if (left) return _resetFocus;
      if (up) return _adultFocus;
    }
    return null;
  }

  void _focusAndReveal(FocusNode node, {required bool towardEnd}) {
    node.requestFocus();
    final target = node.context;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        alignment: towardEnd ? 1 : 0,
        alignmentPolicy: towardEnd
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 720;
    return Focus(
      onKeyEvent: _handleNavigation,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.all(compact ? 6 : 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 1040,
            maxHeight: (viewport.height - (compact ? 12 : 48)).clamp(
              280.0,
              860.0,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(compact ? 14 : 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF090909),
                borderRadius: BorderRadius.circular(compact ? 14 : 20),
                border: Border.all(
                  color: context.appPalette.accent.withValues(alpha: .65),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 16 : 24,
                      compact ? 14 : 20,
                      compact ? 10 : 16,
                      compact ? 12 : 16,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: compact ? 38 : 44,
                          height: compact ? 38 : 44,
                          decoration: BoxDecoration(
                            color: context.appPalette.accent.withValues(
                              alpha: .14,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.tune_rounded,
                            color: context.appPalette.accentBright,
                          ),
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Find your next anime',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Choose only the filters you care about.',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.appPalette.mutedText,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          focusNode: _closeFocus,
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 14 : 24,
                        compact ? 14 : 18,
                        compact ? 14 : 24,
                        22,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _twoColumnLayout = constraints.maxWidth >= 700;
                          const gap = 12.0;
                          final fieldWidth = _twoColumnLayout
                              ? (constraints.maxWidth - gap) / 2
                              : constraints.maxWidth;
                          Widget field(Widget child) =>
                              SizedBox(width: fieldWidth, child: child);
                          Widget full(Widget child) => SizedBox(
                            width: constraints.maxWidth,
                            child: child,
                          );
                          return Wrap(
                            spacing: gap,
                            runSpacing: 10,
                            children: [
                              full(
                                const _FilterSectionTitle('Search and sort'),
                              ),
                              full(
                                TvTextInput(
                                  focusNode: _titleFocus,
                                  controller: _titleController,
                                  labelText: 'Title',
                                  hintText: 'Search by title',
                                  keyboardTitle: 'Discover title',
                                  autofocus: true,
                                ),
                              ),
                              field(
                                _FilterField(
                                  focusNode: _sortFocus,
                                  icon: Icons.sort_rounded,
                                  label: 'Sort',
                                  value: _sortLabels[_sort] ?? _sort,
                                  onPressed: () async {
                                    final value = await _choose(
                                      context,
                                      title: 'Sort results',
                                      current: _sort,
                                      options: _sortLabels,
                                      allowAny: false,
                                    );
                                    if (value != null && mounted) {
                                      setState(() => _sort = value);
                                    }
                                  },
                                ),
                              ),
                              field(
                                _FilterField(
                                  focusNode: _genreFocus,
                                  icon: Icons.category_outlined,
                                  label: 'Genre',
                                  value: _genre ?? 'All genres',
                                  onPressed: () async {
                                    final value = await _choose(
                                      context,
                                      title: 'Genre',
                                      current: _genre,
                                      options: {
                                        for (final item in _genres) item: item,
                                      },
                                    );
                                    if (mounted) setState(() => _genre = value);
                                  },
                                ),
                              ),
                              full(
                                const _FilterSectionTitle('Type and themes'),
                              ),
                              field(
                                _FilterField(
                                  focusNode: _tagFocus,
                                  icon: Icons.sell_outlined,
                                  label: 'Tag',
                                  value: _tag ?? 'All tags',
                                  onPressed: () async {
                                    final value = await _choose(
                                      context,
                                      title: 'Tag',
                                      current: _tag,
                                      options: {
                                        for (final item in _tags) item: item,
                                      },
                                    );
                                    if (mounted) setState(() => _tag = value);
                                  },
                                ),
                              ),
                              field(
                                _FilterField(
                                  focusNode: _formatFocus,
                                  icon: Icons.tv_rounded,
                                  label: 'Format',
                                  value: _format == null
                                      ? 'All formats'
                                      : _pretty(_format!),
                                  onPressed: () async {
                                    final value = await _choose(
                                      context,
                                      title: 'Format',
                                      current: _format,
                                      options: _formatLabels,
                                    );
                                    if (mounted) {
                                      setState(() => _format = value);
                                    }
                                  },
                                ),
                              ),
                              full(const _FilterSectionTitle('Release')),
                              field(
                                _FilterField(
                                  focusNode: _seasonFocus,
                                  icon: Icons.eco_outlined,
                                  label: 'Season',
                                  value: _season == null
                                      ? 'All seasons'
                                      : _pretty(_season!),
                                  onPressed: () async {
                                    final value = await _choose(
                                      context,
                                      title: 'Season',
                                      current: _season,
                                      options: _seasonLabels,
                                    );
                                    if (mounted) {
                                      setState(() => _season = value);
                                    }
                                  },
                                ),
                              ),
                              field(
                                _FilterField(
                                  focusNode: _yearFocus,
                                  icon: Icons.calendar_month_outlined,
                                  label: 'Year',
                                  value: _year?.toString() ?? 'Any year',
                                  onPressed: () async {
                                    final now = DateTime.now().year;
                                    final value = await _choose(
                                      context,
                                      title: 'Release year',
                                      current: _year?.toString(),
                                      options: {
                                        for (
                                          var year = now + 2;
                                          year >= now - 35;
                                          year--
                                        )
                                          '$year': '$year',
                                      },
                                    );
                                    if (mounted) {
                                      setState(
                                        () => _year = int.tryParse(value ?? ''),
                                      );
                                    }
                                  },
                                ),
                              ),
                              field(
                                _FilterField(
                                  focusNode: _statusFocus,
                                  icon: Icons.podcasts_rounded,
                                  label: 'Status',
                                  value: _status == null
                                      ? 'All statuses'
                                      : _statusLabels[_status]!,
                                  onPressed: () async {
                                    final value = await _choose(
                                      context,
                                      title: 'Release status',
                                      current: _status,
                                      options: _statusLabels,
                                    );
                                    if (mounted) {
                                      setState(() => _status = value);
                                    }
                                  },
                                ),
                              ),
                              field(
                                _FilterField(
                                  focusNode: _scoreFocus,
                                  icon: Icons.star_outline_rounded,
                                  label: 'Minimum score',
                                  value: _minimumScore == null
                                      ? 'All scores'
                                      : '${_minimumScore! / 10}/10 or higher',
                                  onPressed: () async {
                                    final value = await _choose(
                                      context,
                                      title: 'Minimum score',
                                      current: _minimumScore?.toString(),
                                      options: const {
                                        '90': '9/10 or higher',
                                        '80': '8/10 or higher',
                                        '70': '7/10 or higher',
                                        '60': '6/10 or higher',
                                      },
                                    );
                                    if (mounted) {
                                      setState(
                                        () => _minimumScore = int.tryParse(
                                          value ?? '',
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ),
                              full(
                                TvFocusable(
                                  focusNode: _adultFocus,
                                  onPressed: () => setState(
                                    () => _includeAdult = !_includeAdult,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      minHeight: 58,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 15,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          context.appPalette.selectableSurface,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.white12),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _includeAdult
                                              ? Icons.toggle_on_rounded
                                              : Icons.toggle_off_rounded,
                                          color: _includeAdult
                                              ? context.appPalette.accentBright
                                              : context.appPalette.mutedText,
                                          size: 36,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                'Include adult titles',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              Text(
                                                'Off by default',
                                                style: TextStyle(
                                                  color: context
                                                      .appPalette
                                                      .mutedText,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 14 : 24,
                      vertical: compact ? 10 : 14,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            focusNode: _resetFocus,
                            onPressed: _clear,
                            icon: const Icon(Icons.restart_alt_rounded),
                            label: const Text('Reset'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton.icon(
                            focusNode: _applyFocus,
                            onPressed: () => Navigator.of(context).pop(_value),
                            icon: const Icon(Icons.search_rounded),
                            label: const Text('Show results'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterSectionTitle extends StatelessWidget {
  const _FilterSectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 2),
    child: Text(
      label.toUpperCase(),
      style: TextStyle(
        color: context.appPalette.accentBright,
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.2,
      ),
    ),
  );
}

class _FilterField extends StatelessWidget {
  const _FilterField({
    required this.focusNode,
    required this.icon,
    required this.label,
    required this.value,
    required this.onPressed,
  });

  final FocusNode focusNode;
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      constraints: const BoxConstraints(minHeight: 62),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
      decoration: BoxDecoration(
        color: context.appPalette.selectableSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Icon(icon, color: context.appPalette.mutedText, size: 21),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: context.appPalette.mutedText,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            color: context.appPalette.mutedText,
          ),
        ],
      ),
    ),
  );
}

Future<String?> _choose(
  BuildContext context, {
  required String title,
  required String? current,
  required Map<String, String> options,
  bool allowAny = true,
}) async {
  const any = '__ANY__';
  final result = await showDialog<String>(
    context: context,
    builder: (context) {
      final viewport = MediaQuery.sizeOf(context);
      final compact = viewport.width < 600;
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.all(compact ? 8 : 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: (viewport.height - (compact ? 16 : 80)).clamp(
              240.0,
              660.0,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.appPalette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 15, 8, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        if (allowAny)
                          _ChoiceTile(
                            label: 'Any',
                            selected: current == null,
                            onPressed: () => Navigator.of(context).pop(any),
                          ),
                        for (final option in options.entries)
                          _ChoiceTile(
                            label: option.value,
                            selected: current == option.key,
                            onPressed: () =>
                                Navigator.of(context).pop(option.key),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  return result == any ? null : result ?? current;
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: TvFocusable(
      autofocus: selected,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        color: selected
            ? context.appPalette.accent
            : context.appPalette.surfaceRaised,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (selected) const Icon(Icons.check_rounded, size: 20),
          ],
        ),
      ),
    ),
  );
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.focusNode,
    required this.icon,
    required this.onPressed,
    this.label,
  });

  final FocusNode focusNode;
  final IconData icon;
  final String? label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    onPressed: onPressed,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.symmetric(horizontal: label == null ? 10 : 13),
      color: context.appPalette.selectableSurface,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          if (label != null) ...[
            const SizedBox(width: 7),
            Text(label!, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ],
      ),
    ),
  );
}

class _DiscoverError extends StatelessWidget {
  const _DiscoverError({
    required this.message,
    required this.onRetry,
    required this.onReset,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _friendlyDiscoverError(message),
          textAlign: TextAlign.center,
          style: TextStyle(color: context.appPalette.mutedText),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: onReset,
              icon: const Icon(Icons.filter_alt_off_rounded),
              label: const Text('Reset filters'),
            ),
            FilledButton.icon(
              autofocus: true,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ],
    ),
  );
}

String _friendlyDiscoverError(String raw) {
  final message = raw
      .replaceFirst(RegExp(r'^(?:Bad state|StateError|DioException):\s*'), '')
      .trim();
  final lower = message.toLowerCase();
  if (lower.contains('illegal operation') &&
      lower.contains('value combination')) {
    return 'AniList rejected that filter combination. Reset the filters or try again.';
  }
  if (lower.contains('timed out') || lower.contains('connection')) {
    return 'Discover could not reach AniList. Check the connection and try again.';
  }
  return 'Discover could not load right now. Try again or reset the filters.';
}

bool _hasFilters(CatalogFilters filters) =>
    filters.search != null ||
    filters.genre != null ||
    filters.tag != null ||
    filters.format != null ||
    filters.status != null ||
    filters.season != null ||
    filters.year != null ||
    filters.minimumScore != null ||
    filters.includeAdult ||
    filters.sort != 'POPULARITY_DESC';

String _filterSummary(CatalogFilters filters) {
  final values = <String>[
    if (filters.search != null) '“${filters.search}”',
    _sortLabels[filters.sort] ?? _pretty(filters.sort),
    if (filters.genre != null) filters.genre!,
    if (filters.format != null) _pretty(filters.format!),
    if (filters.status != null) _statusLabels[filters.status]!,
  ];
  return values.join(' • ');
}

String _pretty(String value) => value
    .split('_')
    .map(
      (part) => part.isEmpty
          ? part
          : '${part.substring(0, 1)}${part.substring(1).toLowerCase()}',
    )
    .join(' ');

const _sortLabels = <String, String>{
  'POPULARITY_DESC': 'Most popular',
  'TRENDING_DESC': 'Trending now',
  'SCORE_DESC': 'Highest score',
  'START_DATE_DESC': 'Newest releases',
  'FAVOURITES_DESC': 'Most favorited',
  'TITLE_ENGLISH': 'Title A–Z',
};

const _formatLabels = <String, String>{
  'TV': 'TV',
  'TV_SHORT': 'TV Short',
  'MOVIE': 'Movie',
  'SPECIAL': 'Special',
  'OVA': 'OVA',
  'ONA': 'ONA',
  'MUSIC': 'Music',
};

const _seasonLabels = <String, String>{
  'WINTER': 'Winter',
  'SPRING': 'Spring',
  'SUMMER': 'Summer',
  'FALL': 'Fall',
};

const _statusLabels = <String, String>{
  'RELEASING': 'Airing',
  'FINISHED': 'Finished',
  'NOT_YET_RELEASED': 'Unreleased',
  'CANCELLED': 'Cancelled',
  'HIATUS': 'On hiatus',
};

const _genres = <String>[
  'Action',
  'Adventure',
  'Comedy',
  'Drama',
  'Ecchi',
  'Fantasy',
  'Horror',
  'Mahou Shoujo',
  'Mecha',
  'Music',
  'Mystery',
  'Psychological',
  'Romance',
  'Sci-Fi',
  'Slice of Life',
  'Sports',
  'Supernatural',
  'Thriller',
];

const _tags = <String>[
  'Isekai',
  'School',
  'Shounen',
  'Shoujo',
  'Seinen',
  'Josei',
  'Romantic Comedy',
  'Time Manipulation',
  'Super Power',
  'Martial Arts',
  'Historical',
  'Military',
  'Demons',
  'Vampire',
  'Space',
  'Cyberpunk',
];
