import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/layout/poster_card_geometry.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/core/widgets/teto_top_level_shell.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/home/presentation/main_navigation_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class MyListScreen extends ConsumerStatefulWidget {
  const MyListScreen({this.autofocusNavigation = false, super.key});

  final bool autofocusNavigation;

  @override
  ConsumerState<MyListScreen> createState() => _MyListScreenState();
}

class _MyListScreenState extends ConsumerState<MyListScreen> {
  TrackingListStatus _status = TrackingListStatus.watching;
  final Map<TrackingListStatus, TrackingListResult> _lastUsableResults = {};
  final _statusFocusNodes = <TrackingListStatus, FocusNode>{
    for (final status in TrackingListStatus.values)
      status: FocusNode(debugLabel: 'my-list.status.${status.name}'),
  };
  final _statusRepeatGate = TvDirectionalRepeatGate(
    repeatInterval: const Duration(milliseconds: 92),
  );
  final _refreshFocus = FocusNode(debugLabel: 'my-list.refresh');
  final _sortFocus = FocusNode(debugLabel: 'my-list.sort');
  final _trackedShelfKey = GlobalKey<_TrackedShelfState>();
  bool _updating = false;
  bool _refreshing = false;

  @override
  void dispose() {
    _statusRepeatGate.reset();
    for (final node in _statusFocusNodes.values) {
      node.dispose();
    }
    _refreshFocus.dispose();
    _sortFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleStatusKey(
    KeyEvent event, {
    required TrackingListStatus status,
    required TetoTopLevelLayout layout,
  }) {
    final key = event.logicalKey;
    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => 0,
    };
    final directional = direction != 0 || key == LogicalKeyboardKey.arrowDown;
    if (!directional) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _statusRepeatGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_statusRepeatGate.accept(event)) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.arrowDown) {
      _trackedShelfKey.currentState?.requestFocus();
      return KeyEventResult.handled;
    }
    final index = TrackingListStatus.values.indexOf(status);
    final next = index + direction;
    if (next < 0) {
      if (layout.usesPersistentNavigation) layout.focusRail();
      return KeyEventResult.handled;
    }
    if (next >= TrackingListStatus.values.length) {
      _refreshFocus.requestFocus();
      return KeyEventResult.handled;
    }
    _statusFocusNodes[TrackingListStatus.values[next]]!.requestFocus();
    return KeyEventResult.handled;
  }

  KeyEventResult _handleHeaderActionKey(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _statusFocusNodes[TrackingListStatus.onHold]!.requestFocus();
    }
    return KeyEventResult.handled;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    for (final status in TrackingListStatus.values) {
      ref.invalidate(trackingListProvider(status));
    }
    ref.invalidate(trackingHomeProvider);
    try {
      final listFuture = ref.read(trackingListProvider(_status).future);
      final homeFuture = ref.read(trackingHomeProvider.future);
      final result = await listFuture;
      await homeFuture;
      if (!mounted) return;
      if (result.allAttemptedFailed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not refresh ${result.failedProviderNames}. '
              'No tracker data was changed.',
            ),
            backgroundColor: const Color(0xFF7D1E32),
          ),
        );
        return;
      }
      if (result.hasFailures) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Refreshed available data. ${result.failedProviderNames} '
              'could not be reached.',
            ),
            backgroundColor: const Color(0xFF7A4B00),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Refresh complete. Showing available connected tracker data.',
          ),
          backgroundColor: context.appPalette.accent,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not refresh every tracker: $error'),
          backgroundColor: const Color(0xFF7D1E32),
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _chooseSort(MyListSort current) async {
    final selected = await showDialog<MyListSort>(
      context: context,
      barrierDismissible: true,
      builder: (context) => _SortDialog(current: current),
    );
    if (selected == null || !mounted) return;
    await ref.read(myListSortProvider.notifier).setSort(selected);
  }

  void _open(HomeTrackedAnime item) {
    final route = item.anilistId == null
        ? Uri(
            path: '/search',
            queryParameters: {'q': item.tracked.title},
          ).toString()
        : '/anime/${item.anilistId}';
    context.push(route);
  }

  Future<void> _manage(
    HomeTrackedAnime item,
    TitleLanguagePreference titlePreference,
  ) async {
    final selected = await showDialog<_MyListSelection>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => _StatusDialog(
        item: item,
        titlePreference: titlePreference,
        onOpen: () {
          Navigator.of(dialogContext).pop();
          _open(item);
        },
      ),
    );
    if (selected == null || !mounted) return;
    if (!selected.remove && selected.status == item.tracked.status) return;
    setState(() => _updating = true);
    try {
      final controller = ref.read(trackingStatusControllerProvider.notifier);
      if (selected.remove) {
        await controller.remove(item);
      } else {
        await controller.update(item, selected.status!);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            selected.remove
                ? '${item.tracked.displayTitle(titlePreference)} removed from '
                      '${item.provider.displayName}.'
                : '${item.tracked.displayTitle(titlePreference)} moved to '
                      '${selected.status!.displayName}.',
          ),
          backgroundColor: context.appPalette.accent,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not update the list: $error'),
          backgroundColor: const Color(0xFF7D1E32),
        ),
      );
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(trackingListProvider(_status));
    final titlePreference = ref.watch(titleLanguagePreferenceProvider);
    final sort = ref.watch(myListSortProvider);
    final preferences = ref.watch(settingsPreferencesProvider);
    return TetoTopLevelShell(
      preferences: preferences,
      activeDestination: TopNavigationDestination.myList,
      firstContentFocusNode: _statusFocusNodes[_status]!,
      autofocusRail: widget.autofocusNavigation,
      builder: (context, layout) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!layout.usesPersistentNavigation)
            MainNavigationBar(
              active: MainNavigationDestination.myList,
              preferences: preferences,
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              final tabs = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final status in TrackingListStatus.values) ...[
                    _StatusTab(
                      status: status,
                      selected: status == _status,
                      focusNode: _statusFocusNodes[status],
                      autofocus: status == TrackingListStatus.watching,
                      onKeyEvent: (_, event) => _handleStatusKey(
                        event,
                        status: status,
                        layout: layout,
                      ),
                      onPressed: () => setState(() => _status = status),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              );
              if (constraints.maxWidth < 1400) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'My List',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  fontSize: layout.usesTvRail ? 30 : null,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                        _RefreshButton(
                          refreshing: _refreshing,
                          compact: true,
                          focusNode: _refreshFocus,
                          onKeyEvent: (_, event) =>
                              _handleHeaderActionKey(event),
                          onPressed: _refresh,
                        ),
                        const SizedBox(width: 8),
                        _SortButton(
                          sort: sort,
                          compact: true,
                          iconOnly: layout.usesPhoneBottomNavigation &&
                              constraints.maxWidth < 420,
                          focusNode: _sortFocus,
                          onKeyEvent: (_, event) =>
                              _handleHeaderActionKey(event),
                          onPressed: () => _chooseSort(sort),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: tabs,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Text(
                    'My List',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontSize: layout.usesTvRail ? 30 : null,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 22),
                  tabs,
                  const Spacer(),
                  _RefreshButton(
                    refreshing: _refreshing,
                    focusNode: _refreshFocus,
                    onKeyEvent: (_, event) => _handleHeaderActionKey(event),
                    onPressed: _refresh,
                  ),
                  const SizedBox(width: 8),
                  _SortButton(
                    sort: sort,
                    focusNode: _sortFocus,
                    onKeyEvent: (_, event) => _handleHeaderActionKey(event),
                    onPressed: () => _chooseSort(sort),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: list.when(
                    loading: () => Center(
                      child: CircularProgressIndicator(
                        color: context.appPalette.accentBright,
                      ),
                    ),
                    error: (error, _) => _ListMessage(
                      icon: Icons.cloud_off_rounded,
                      title: 'Could not load ${_status.displayName}',
                      body: error.toString(),
                    ),
                    data: (result) {
                      if (!result.allAttemptedFailed) {
                        _lastUsableResults[_status] = result;
                      }
                      final previous = _lastUsableResults[_status];
                      final visibleItems = result.allAttemptedFailed
                          ? previous?.items ?? const <HomeTrackedAnime>[]
                          : result.items;
                      if (visibleItems.isEmpty && result.allAttemptedFailed) {
                        return _ListMessage(
                          icon: Icons.cloud_off_rounded,
                          title: 'Trackers could not be refreshed',
                          body:
                              '${result.failedProviderNames} could not be '
                              'reached. Check the connection or account, '
                              'then choose Refresh.',
                        );
                      }
                      if (visibleItems.isEmpty) {
                        return _ListMessage(
                          icon: Icons.video_library_outlined,
                          title: '${_status.displayName} is empty',
                          body:
                              'Connect AniList or MAL, or change '
                              'a title to this status.',
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (result.hasFailures)
                            _TrackerWarningBanner(
                              message: result.allAttemptedFailed
                                  ? '${result.failedProviderNames} could not '
                                        'be refreshed. Showing the previous '
                                        'results.'
                                  : '${result.failedProviderNames} could not '
                                        'be refreshed. Showing data from the '
                                        'tracker that responded.',
                            ),
                          Expanded(
                            child: _TrackedShelf(
                              key: _trackedShelfKey,
                              items: sortMyListItems(visibleItems, sort),
                              titlePreference: titlePreference,
                              onPressed: _open,
                              onManage: (item) =>
                                  _manage(item, titlePreference),
                              preferences: preferences,
                              modernPosterSizing: layout.usesTvRail,
                              onLeftEdge: layout.usesPersistentNavigation
                                  ? layout.focusRail
                                  : null,
                              onMoveUp: () =>
                                  _statusFocusNodes[_status]!.requestFocus(),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                if (_updating)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x99000000),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: context.appPalette.accentBright,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Text(
              'Select to view episodes. Hold OK or press Menu for quick '
              'watchlist actions.',
              style: TextStyle(
                color: context.appPalette.mutedText,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusTab extends StatelessWidget {
  const _StatusTab({
    required this.status,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
    this.onKeyEvent,
  });

  final TrackingListStatus status;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: onKeyEvent,
      focusScale: 1.03,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? context.appPalette.accent
              : context.appPalette.surface.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: selected
                ? context.appPalette.accentBright
                : context.appPalette.primaryText.withValues(alpha: .1),
          ),
        ),
        child: Text(
          status.displayName,
          style: TextStyle(
            color: selected
                ? contrastForeground(context.appPalette.accent)
                : context.appPalette.primaryText,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.sort,
    required this.onPressed,
    this.compact = false,
    this.iconOnly = false,
    this.focusNode,
    this.onKeyEvent,
  });

  final MyListSort sort;
  final VoidCallback onPressed;
  final bool compact;
  final bool iconOnly;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    final button = TvFocusable(
      key: const ValueKey('my-list-sort'),
      onPressed: onPressed,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      focusScale: 1.03,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: iconOnly ? 13 : 14,
          vertical: 9,
        ),
        decoration: BoxDecoration(
          color: context.appPalette.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: .12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort_rounded, size: 18),
            if (!iconOnly) ...[
              const SizedBox(width: 7),
              Text(
                compact ? sort.displayName : 'Sort: ${sort.displayName}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 5),
              const Icon(Icons.expand_more_rounded, size: 18),
            ],
          ],
        ),
      ),
    );
    if (!iconOnly) return button;
    return Tooltip(message: 'Sort: ${sort.displayName}', child: button);
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({
    required this.refreshing,
    required this.onPressed,
    this.compact = false,
    this.focusNode,
    this.onKeyEvent,
  });

  final bool refreshing;
  final VoidCallback onPressed;
  final bool compact;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      key: const Key('my-list-refresh'),
      onPressed: refreshing ? () {} : onPressed,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      focusScale: 1.03,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: context.appPalette.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: .12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (refreshing)
              SizedBox.square(
                dimension: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.appPalette.accentBright,
                ),
              )
            else
              const Icon(Icons.refresh_rounded, size: 18),
            if (!compact) ...[
              const SizedBox(width: 7),
              Text(
                refreshing ? 'Refreshing' : 'Refresh',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SortDialog extends StatelessWidget {
  const _SortDialog({required this.current});

  final MyListSort current;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: context.appPalette.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: context.appPalette.accent.withValues(alpha: .7),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sort My List', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            for (final sort in MyListSort.values) ...[
              TvFocusable(
                autofocus: sort == current,
                onPressed: () => Navigator.of(context).pop(sort),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color: sort == current
                        ? context.appPalette.accent
                        : context.appPalette.surfaceRaised,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        sort == current
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_off_rounded,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        sort.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (sort != MyListSort.values.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrackedShelf extends StatefulWidget {
  const _TrackedShelf({
    required this.items,
    required this.titlePreference,
    required this.onPressed,
    required this.onManage,
    required this.preferences,
    required this.modernPosterSizing,
    required this.onMoveUp,
    this.onLeftEdge,
    super.key,
  });

  final List<HomeTrackedAnime> items;
  final TitleLanguagePreference titlePreference;
  final ValueChanged<HomeTrackedAnime> onPressed;
  final ValueChanged<HomeTrackedAnime> onManage;
  final SettingsPreferences preferences;
  final bool modernPosterSizing;
  final VoidCallback? onLeftEdge;
  final VoidCallback onMoveUp;

  @override
  State<_TrackedShelf> createState() => _TrackedShelfState();
}

class _TrackedShelfState extends State<_TrackedShelf> {
  late final TvShelfFocusController _focusController;
  double _itemExtent = 0;
  double _itemSpacing = 0;

  @override
  void initState() {
    super.initState();
    _focusController = TvShelfFocusController(
      debugLabel: 'my-list.cards',
      itemCount: widget.items.length,
    );
  }

  @override
  void didUpdateWidget(covariant _TrackedShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    _focusController.syncItemCount(widget.items.length);
  }

  bool requestFocus() {
    return _focusController.requestFocus(
      itemExtent: _itemExtent > 0 ? _itemExtent : null,
      spacing: _itemExtent > 0 ? _itemSpacing : null,
    );
  }

  @override
  void dispose() {
    _focusController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildShelf(context, availableWidth: constraints.maxWidth),
  );

  Widget _buildShelf(BuildContext context, {required double availableWidth}) {
    final metrics = _myListPosterMetrics(
      context,
      dense: widget.preferences.homeLayout == HomeLayout.compact,
      matchSearchDefault: widget.modernPosterSizing,
      availableWidth: availableWidth,
    );
    _itemExtent = metrics.width * widget.preferences.thumbnailScale;
    _itemSpacing = 10 * widget.preferences.contentDensity.spacingScale;
    return ListView.separated(
      controller: _focusController.scrollController,
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      padding: const EdgeInsets.fromLTRB(4, 5, 4, 24),
      itemCount: widget.items.length,
      separatorBuilder: (_, _) => SizedBox(width: _itemSpacing),
      itemBuilder: (context, index) {
        final item = widget.items[index];
        final totalEpisodes = item.tracked.totalEpisodes;
        final progress = totalEpisodes == null || totalEpisodes <= 0
            ? null
            : (item.tracked.progress / totalEpisodes).clamp(0.0, 1.0);
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: ValueKey('my-list-poster-card-${item.anilistId}'),
            width: metrics.width * widget.preferences.thumbnailScale,
            height: metrics.height * widget.preferences.thumbnailScale,
            child: TvFocusable(
              focusNode: _focusController.focusNodeAt(index),
              onFocusChanged: (focused) {
                if (!focused) return;
                _focusController.rememberIndex(index);
                _focusController.reveal(
                  index: index,
                  itemExtent: _itemExtent,
                  spacing: _itemSpacing,
                );
              },
              onKeyEvent: (_, event) {
                final horizontal = _focusController.handleHorizontalKey(
                  event,
                  currentIndex: index,
                  itemExtent: _itemExtent,
                  spacing: _itemSpacing,
                  onLeftEdge: widget.onLeftEdge,
                );
                if (horizontal == KeyEventResult.handled) return horizontal;
                if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
                  return KeyEventResult.ignored;
                }
                if (event is KeyDownEvent || event is KeyRepeatEvent) {
                  widget.onMoveUp();
                }
                return KeyEventResult.handled;
              },
              onPressed: () => widget.onPressed(item),
              onLongPress: () => widget.onManage(item),
              focusScale: 1.025,
              borderRadius: BorderRadius.circular(8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.appPalette.surface.withValues(alpha: .94),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: context.appPalette.primaryText.withValues(alpha: .1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          NetworkArtwork(
                            url: item.coverImageUrl,
                            cacheWidth: 210,
                          ),
                          if (animeAiringStatusLabel(
                                item.tracked.airingStatus,
                              ) !=
                              null)
                            Positioned(
                              left: 7,
                              top: 7,
                              child: PosterAiringStatusBadge(
                                status: item.tracked.airingStatus,
                              ),
                            ),
                          Align(
                            alignment: Alignment.topRight,
                            child: Container(
                              margin: const EdgeInsets.all(7),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xE6000000),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: context.appPalette.accent.withValues(
                                    alpha: .5,
                                  ),
                                ),
                              ),
                              child: Text(
                                item.provider.displayName,
                                style: TextStyle(
                                  color: context.appPalette.accentBright,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        item.tracked.displayTitle(widget.titlePreference),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.appPalette.primaryText,
                          fontSize: 11,
                          height: 1.05,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        item.tracked.totalEpisodes == null
                            ? 'Episode ${item.tracked.progress}'
                            : 'Episode ${item.tracked.progress} / '
                                  '${item.tracked.totalEpisodes}',
                        style: TextStyle(
                          color: context.appPalette.mutedText,
                          fontSize: 9,
                        ),
                      ),
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 5),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            minHeight: 3,
                            value: progress,
                            color: context.appPalette.accentBright,
                            backgroundColor: context.appPalette.primaryText
                                .withValues(alpha: .12),
                          ),
                        ),
                      ),
                    ] else
                      const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

({double height, double width}) _myListPosterMetrics(
  BuildContext context, {
  required bool dense,
  required bool matchSearchDefault,
  required double availableWidth,
}) {
  if (!dense && matchSearchDefault) {
    final geometry = defaultPosterCardGeometry(availableWidth);
    return (height: geometry.height, width: geometry.width);
  }
  final screenWidth = MediaQuery.sizeOf(context).width;
  if (screenWidth >= 1600) {
    return (height: dense ? 238 : 278, width: dense ? 144 : 166);
  }
  if (screenWidth >= 1200) {
    return (height: dense ? 205 : 240, width: dense ? 118 : 138);
  }
  final compact = context.isCompactWidth;
  return (
    height: dense ? (compact ? 198 : 170) : (compact ? 238 : 205),
    width: dense ? (compact ? 104 : 88) : (compact ? 126 : 106),
  );
}

class _StatusDialog extends StatelessWidget {
  const _StatusDialog({
    required this.item,
    required this.titlePreference,
    required this.onOpen,
  });

  final HomeTrackedAnime item;
  final TitleLanguagePreference titlePreference;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 760,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: context.appPalette.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: context.appPalette.accent.withValues(alpha: .55),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.tracked.displayTitle(titlePreference),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 7),
            Text(
              '${item.provider.displayName} • Currently '
              '${item.tracked.status.displayName}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            Text('Move to', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final status in TrackingListStatus.values)
                  _DialogChoice(
                    status: status,
                    current: status == item.tracked.status,
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(_MyListSelection.status(status)),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: _RemoveButton(
                    label: 'Remove from ${item.tracked.status.displayName}',
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(const _MyListSelection.remove()),
                  ),
                ),
                const SizedBox(width: 14),
                _OpenButton(onPressed: onOpen),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Remove deletes the tracker list entry. Dropped keeps the show '
              'in your list as something you started and stopped.',
              style: TextStyle(
                color: context.appPalette.mutedText,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MyListSelection {
  const _MyListSelection.status(this.status) : remove = false;
  const _MyListSelection.remove() : status = null, remove = true;

  final TrackingListStatus? status;
  final bool remove;
}

class _DialogChoice extends StatelessWidget {
  const _DialogChoice({
    required this.status,
    required this.current,
    required this.onPressed,
  });

  final TrackingListStatus status;
  final bool current;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: current,
      onPressed: onPressed,
      focusScale: 1.03,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 128,
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        color: current
            ? context.appPalette.accent
            : context.appPalette.surfaceRaised,
        child: Text(
          status.displayName,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        color: context.appPalette.accent,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        child: const Text(
          'View episodes',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        color: const Color(0xFF4A1420),
        child: Row(
          children: [
            const Icon(Icons.remove_circle_outline_rounded, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackerWarningBanner extends StatelessWidget {
  const _TrackerWarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF3B2600),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFB97500)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFFFC15A),
              size: 20,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Color(0xFFFFDEA3),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListMessage extends StatelessWidget {
  const _ListMessage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 58, color: context.appPalette.accentBright),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 7),
          SizedBox(
            width: 560,
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
