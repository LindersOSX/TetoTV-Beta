import 'dart:async';

import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_navigation.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/presentation/manga_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum MangaLibrarySort { title, recentlyRead, recentlyAdded, updates }

String mangaLibraryStatusLabel(MangaLibraryStatus status) => switch (status) {
  MangaLibraryStatus.planToRead => 'Plan to read',
  MangaLibraryStatus.reading => 'Reading',
  MangaLibraryStatus.completed => 'Completed',
  MangaLibraryStatus.onHold => 'On hold',
  MangaLibraryStatus.dropped => 'Dropped',
};

String _entryKey(String source, String entry) => '$source\n$entry';

List<MangaLibraryEntry> filterMangaLibrary({
  required Iterable<MangaLibraryEntry> entries,
  required Iterable<MangaReadingProgress> progress,
  required Iterable<MangaDownloadJob> downloads,
  String query = '',
  String? category,
  MangaLibraryStatus? status,
  bool updatesOnly = false,
  bool downloadedOnly = false,
  MangaLibrarySort sort = MangaLibrarySort.title,
}) {
  final history = {
    for (final p in progress) _entryKey(p.sourceId, p.entryId): p,
  };
  final offline = {
    for (final d in downloads)
      if (d.status == MangaDownloadJobStatus.completed)
        _entryKey(d.sourceId, d.entryId),
  };
  final search = query.trim().toLowerCase();
  final result = entries
      .where(
        (entry) =>
            (search.isEmpty || entry.title.toLowerCase().contains(search)) &&
            (category == null || entry.category == category) &&
            (status == null || entry.status == status) &&
            (!updatesOnly || entry.newChapterCount > 0) &&
            (!downloadedOnly ||
                offline.contains(_entryKey(entry.sourceId, entry.entryId))),
      )
      .toList();
  result.sort((a, b) {
    final byValue = switch (sort) {
      MangaLibrarySort.title => 0,
      MangaLibrarySort.recentlyAdded => b.updatedAt.compareTo(a.updatedAt),
      MangaLibrarySort.updates => b.newChapterCount.compareTo(
        a.newChapterCount,
      ),
      MangaLibrarySort.recentlyRead =>
        (history[_entryKey(b.sourceId, b.entryId)]
                    ?.updatedAt
                    .millisecondsSinceEpoch ??
                0)
            .compareTo(
              history[_entryKey(a.sourceId, a.entryId)]
                      ?.updatedAt
                      .millisecondsSinceEpoch ??
                  0,
            ),
    };
    return byValue != 0
        ? byValue
        : a.title.toLowerCase().compareTo(b.title.toLowerCase());
  });
  return result;
}

class MangaLibraryView extends ConsumerStatefulWidget {
  const MangaLibraryView({
    required this.state,
    required this.firstFocusNode,
    required this.onBrowse,
    required this.onOpen,
    required this.onContinue,
    required this.onRemove,
    required this.onBackup,
    required this.onCheckUpdates,
    this.onMigrate,
    this.onTracking,
    this.onAcknowledge,
    this.onExitUp,
    super.key,
  });
  final MangaHubState state;
  final FocusNode firstFocusNode;
  final VoidCallback onBrowse;
  final ValueChanged<MangaLibraryEntry> onOpen;
  final ValueChanged<MangaLibraryEntry> onContinue;
  final ValueChanged<MangaLibraryEntry> onRemove;
  final ValueChanged<MangaLibraryEntry>? onMigrate;
  final ValueChanged<MangaLibraryEntry>? onTracking;
  final ValueChanged<MangaLibraryEntry>? onAcknowledge;
  final VoidCallback? onExitUp;
  final Future<void> Function() onBackup;
  final Future<String> Function() onCheckUpdates;
  @override
  ConsumerState<MangaLibraryView> createState() => _MangaLibraryViewState();
}

class _MangaLibraryViewState extends ConsumerState<MangaLibraryView> {
  final _query = TextEditingController();
  final _sortFocus = FocusNode(debugLabel: 'manga.library.sort');
  final _categoryFocus = FocusNode(debugLabel: 'manga.library.category');
  final _statusFocus = FocusNode(debugLabel: 'manga.library.status');
  final _updatesFocus = FocusNode(debugLabel: 'manga.library.updates');
  final _downloadedFocus = FocusNode(debugLabel: 'manga.library.downloaded');
  final _checkFocus = FocusNode(debugLabel: 'manga.library.check');
  final _backupFocus = FocusNode(debugLabel: 'manga.library.backup');
  final _retryFocus = FocusNode(debugLabel: 'manga.library.retry');
  final _firstEntryFocus = FocusNode(debugLabel: 'manga.library.first.entry');
  final _browseFocus = FocusNode(debugLabel: 'manga.library.browse');
  bool _hasVisibleEntries = false;
  bool _hasHistoryError = false;
  MangaLibrarySort _sort = MangaLibrarySort.title;
  String? _category;
  MangaLibraryStatus? _status;
  bool _updatesOnly = false;
  bool _downloadedOnly = false;
  bool _checking = false;
  bool _backingUp = false;
  String? _notice;
  late Future<List<MangaReadingProgress>> _progress;
  @override
  void initState() {
    super.initState();
    _loadProgress();
  }

  void _loadProgress() {
    final store = ref.read(mangaStoreProvider);
    _progress = ref
        .read(mangaOwnerKeyProvider.future)
        .then((owner) => store.latestProgressForOwner(owner));
  }

  @override
  void didUpdateWidget(MangaLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.library != widget.state.library) _loadProgress();
  }

  @override
  void dispose() {
    _query.dispose();
    for (final node in [
      _sortFocus,
      _categoryFocus,
      _statusFocus,
      _updatesFocus,
      _downloadedFocus,
      _checkFocus,
      _backupFocus,
      _retryFocus,
      _firstEntryFocus,
      _browseFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  List<FocusNode> get _filterFocusNodes => [
    if (_hasHistoryError) _retryFocus,
    _sortFocus,
    _categoryFocus,
    _statusFocus,
    _updatesFocus,
    _downloadedFocus,
    _checkFocus,
    _backupFocus,
  ];

  FocusNode get _firstFilterFocus =>
      _hasHistoryError ? _retryFocus : _sortFocus;

  void _focusContent() => requestTvFocusAndReveal(
    _hasVisibleEntries ? _firstEntryFocus : _browseFocus,
    towardEnd: true,
  );

  KeyEventResult _filterKey(FocusNode current, KeyEvent event) {
    final nodes = _filterFocusNodes;
    final index = nodes.indexOf(current);
    return handleTvDirectionalFocusEvent(
      event,
      TvDirectionalFocusCallbacks(
        up: () => requestTvFocusAndReveal(widget.firstFocusNode),
        down: _focusContent,
        left: () => requestTvFocusAndReveal(
          index > 0 ? nodes[index - 1] : widget.firstFocusNode,
        ),
        right: () => requestTvFocusAndReveal(
          index >= 0 && index + 1 < nodes.length
              ? nodes[index + 1]
              : _firstFilterFocus,
        ),
      ),
    );
  }

  Widget _filterControl(FocusNode node, Widget child) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) => _filterKey(node, event),
    child: child,
  );

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _notice = null;
    });
    try {
      final result = await widget.onCheckUpdates();
      if (mounted) setState(() => _notice = result);
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice = context.tr(
            'Chapter updates could not be checked. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _organize(MangaLibraryEntry entry) async {
    final hub = ref.read(mangaHubControllerProvider.notifier);
    final store = ref.read(mangaStoreProvider);
    final category = TextEditingController(text: entry.category);
    var status = entry.status;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.tr('Organize manga')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TvTextInput(
                    controller: category,
                    labelText: context.tr('Category'),
                    maxLength: 80,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<MangaLibraryStatus>(
                    initialValue: status,
                    decoration: InputDecoration(
                      labelText: context.tr('Status'),
                    ),
                    items: [
                      for (final value in MangaLibraryStatus.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(
                            context.tr(mangaLibraryStatusLabel(value)),
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => status = value ?? status),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('Save')),
            ),
          ],
        ),
      ),
    );
    final categoryValue = category.text.trim();
    // Dialog route descendants may still reference the controller during exit.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    category.dispose();
    if (confirmed != true || !mounted) return;
    try {
      final owner = await hub.ownerKey;
      if (!mounted ||
          !hub.mounted ||
          !identical(ref.read(mangaHubControllerProvider.notifier), hub) ||
          entry.ownerKey != owner) {
        return;
      }
      await store.setLibraryOrganization(
        ownerKey: owner,
        sourceId: entry.sourceId,
        entryId: entry.entryId,
        category: categoryValue,
        status: status,
      );
      if (mounted &&
          hub.mounted &&
          identical(ref.read(mangaHubControllerProvider.notifier), hub)) {
        await hub.initialize();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice = context.tr(
            'Your library changes could not be saved. Try again.',
          ),
        );
      }
    }
  }

  Future<void> _backup() async {
    if (_backingUp) return;
    setState(() {
      _backingUp = true;
      _notice = null;
    });
    try {
      await widget.onBackup();
      if (mounted) setState(_loadProgress);
    } catch (_) {
      if (mounted) {
        setState(
          () => _notice = context.tr(
            'Backup & restore could not be opened. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<MangaReadingProgress>>(
    future: _progress,
    builder: (context, snapshot) {
      final history = snapshot.connectionState == ConnectionState.done
          ? snapshot.data ?? const <MangaReadingProgress>[]
          : const <MangaReadingProgress>[];
      final entries = filterMangaLibrary(
        entries: widget.state.library,
        progress: history,
        downloads: widget.state.downloads,
        query: _query.text,
        category: _category,
        status: _status,
        updatesOnly: _updatesOnly,
        downloadedOnly: _downloadedOnly,
        sort: _sort,
      );
      _hasVisibleEntries = entries.isNotEmpty;
      _hasHistoryError = snapshot.hasError;
      final categories =
          widget.state.library
              .map((e) => e.category)
              .where((c) => c.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      return CustomScrollView(
        key: const ValueKey('manga-library-list'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TvTextInput(
                    controller: _query,
                    focusNode: widget.firstFocusNode,
                    labelText: context.tr('Search library'),
                    maxLength: 160,
                    onExitDown: () => requestTvFocusAndReveal(
                      _firstFilterFocus,
                      towardEnd: true,
                    ),
                    onExitRight: () =>
                        requestTvFocusAndReveal(_firstFilterFocus),
                    onExitUp: widget.onExitUp,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  if (snapshot.hasError) ...[
                    Text(
                      context.tr(
                        'Reading history could not be loaded. Retry before continuing.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    MangaLibraryAction(
                      label: context.tr('Retry history'),
                      focusNode: _retryFocus,
                      onKeyEvent: (_, event) => _filterKey(_retryFocus, event),
                      icon: Icons.refresh,
                      onPressed: () {
                        setState(_loadProgress);
                        requestTvFocusAndReveal(_sortFocus);
                      },
                    ),
                  ],
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _choice<MangaLibrarySort>(
                        context.tr('Sort'),
                        _sort,
                        {
                          for (final value in MangaLibrarySort.values)
                            value: context.tr(switch (value) {
                              MangaLibrarySort.title => 'Title',
                              MangaLibrarySort.recentlyRead => 'Recently read',
                              MangaLibrarySort.recentlyAdded =>
                                'Recently added',
                              MangaLibrarySort.updates => 'New chapters',
                            }),
                        },
                        (value) => setState(() => _sort = value),
                        focusNode: _sortFocus,
                      ),
                      _choice<String>(
                        context.tr('Category'),
                        _category ?? '',
                        {
                          '': context.tr('All categories'),
                          for (final c in categories) c: c,
                        },
                        (value) => setState(
                          () => _category = value.isEmpty ? null : value,
                        ),
                        focusNode: _categoryFocus,
                      ),
                      _choice<String>(
                        context.tr('Status'),
                        _status?.name ?? '',
                        {
                          '': context.tr('All statuses'),
                          for (final s in MangaLibraryStatus.values)
                            s.name: context.tr(mangaLibraryStatusLabel(s)),
                        },
                        (value) => setState(
                          () => _status = value.isEmpty
                              ? null
                              : MangaLibraryStatus.values.byName(value),
                        ),
                        focusNode: _statusFocus,
                      ),
                      _filterControl(
                        _updatesFocus,
                        FilterChip(
                          focusNode: _updatesFocus,
                          label: Text(context.tr('New chapters')),
                          selected: _updatesOnly,
                          onSelected: (value) =>
                              setState(() => _updatesOnly = value),
                        ),
                      ),
                      _filterControl(
                        _downloadedFocus,
                        FilterChip(
                          focusNode: _downloadedFocus,
                          label: Text(context.tr('Downloaded')),
                          selected: _downloadedOnly,
                          onSelected: (value) =>
                              setState(() => _downloadedOnly = value),
                        ),
                      ),
                      MangaLibraryAction(
                        label: context.tr(
                          _checking ? 'Checking…' : 'Check chapter updates',
                        ),
                        icon: Icons.refresh_rounded,
                        focusNode: _checkFocus,
                        onKeyEvent: (_, event) =>
                            _filterKey(_checkFocus, event),
                        onPressed: _checking ? null : _check,
                      ),
                      MangaLibraryAction(
                        label: context.tr('Backup & restore'),
                        icon: Icons.enhanced_encryption_outlined,
                        focusNode: _backupFocus,
                        onKeyEvent: (_, event) =>
                            _filterKey(_backupFocus, event),
                        onPressed: _backingUp ? null : _backup,
                      ),
                    ],
                  ),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_notice!),
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          if (entries.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(
                      context.tr(
                        widget.state.library.isEmpty
                            ? 'Your manga library is empty'
                            : 'No manga matches these filters',
                      ),
                    ),
                    const SizedBox(height: 16),
                    MangaLibraryAction(
                      label: context.tr('Browse manga'),
                      focusNode: _browseFocus,
                      onKeyEvent: (_, event) => handleTvDirectionalFocusEvent(
                        event,
                        TvDirectionalFocusCallbacks(
                          up: () => requestTvFocusAndReveal(_firstFilterFocus),
                        ),
                      ),
                      icon: Icons.explore_outlined,
                      onPressed: widget.onBrowse,
                    ),
                  ],
                ),
              ),
            ),
          SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final progress = history
                  .where(
                    (p) =>
                        p.sourceId == entry.sourceId &&
                        p.entryId == entry.entryId,
                  )
                  .firstOrNull;
              return Container(
                key: ValueKey(
                  'manga-library-${entry.sourceId}-${entry.entryId}',
                ),
                margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.appPalette.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: context.appPalette.primaryText.withValues(
                      alpha: .14,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 60,
                            height: 84,
                            child: MangaArtwork(
                              uri: entry.coverUri,
                              cacheWidth: 160,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                [
                                  context.tr(
                                    mangaLibraryStatusLabel(entry.status),
                                  ),
                                  if (entry.category.isNotEmpty) entry.category,
                                  if (entry.newChapterCount > 0)
                                    context.tr('{count} new chapters', {
                                      'count': entry.newChapterCount,
                                    }),
                                ].join(' • '),
                              ),
                              if (progress != null)
                                Text(
                                  context.tr(
                                    'Last read: chapter {chapter}, page {page}',
                                    {
                                      'chapter':
                                          progress.chapterNumber?.toString() ??
                                          '—',
                                      'page': progress.pageIndex + 1,
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        MangaLibraryAction(
                          focusNode: index == 0 ? _firstEntryFocus : null,
                          onKeyEvent: index == 0
                              ? (_, event) => handleTvDirectionalFocusEvent(
                                  event,
                                  TvDirectionalFocusCallbacks(
                                    up: () => requestTvFocusAndReveal(
                                      _firstFilterFocus,
                                    ),
                                  ),
                                )
                              : null,
                          label: context.tr(
                            progress == null
                                ? 'Start reading'
                                : 'Continue reading',
                          ),
                          icon: Icons.auto_stories_rounded,
                          onPressed:
                              snapshot.hasError ||
                                  snapshot.connectionState !=
                                      ConnectionState.done
                              ? null
                              : () => widget.onContinue(entry),
                        ),
                        MangaLibraryAction(
                          label: context.tr('Chapters'),
                          icon: Icons.list_rounded,
                          onPressed: () => widget.onOpen(entry),
                        ),
                        MangaLibraryAction(
                          label: context.tr('Organize'),
                          icon: Icons.folder_outlined,
                          onPressed: () => _organize(entry),
                        ),
                        if (widget.onMigrate != null)
                          MangaLibraryAction(
                            label: context.tr('Change source'),
                            icon: Icons.swap_horiz_rounded,
                            onPressed: () => widget.onMigrate!(entry),
                          ),
                        if (widget.onTracking != null)
                          MangaLibraryAction(
                            label: context.tr('Manga tracking'),
                            icon: Icons.sync,
                            onPressed: () => widget.onTracking!(entry),
                          ),
                        if (entry.newChapterCount > 0 &&
                            widget.onAcknowledge != null)
                          MangaLibraryAction(
                            label: context.tr('Mark updates seen'),
                            icon: Icons.mark_chat_read_outlined,
                            onPressed: () => widget.onAcknowledge!(entry),
                          ),
                        MangaLibraryAction(
                          label: context.tr('Remove'),
                          icon: Icons.bookmark_remove_outlined,
                          onPressed: () => widget.onRemove(entry),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      );
    },
  );

  Widget _choice<T>(
    String label,
    T value,
    Map<T, String> choices,
    ValueChanged<T> onChanged, {
    required FocusNode focusNode,
  }) => Semantics(
    label: label,
    child: _filterControl(
      focusNode,
      SizedBox(
        width: 240,
        child: DropdownButton<T>(
          focusNode: focusNode,
          isExpanded: true,
          value: choices.containsKey(value) ? value : choices.keys.first,
          items: [
            for (final entry in choices.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Tooltip(
                  message: entry.value,
                  child: Text(
                    entry.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    ),
  );
}

class MangaLibraryAction extends StatelessWidget {
  const MangaLibraryAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.focusNode,
    this.onKeyEvent,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    onKeyEvent: onKeyEvent,
    onFocusChanged: (focused) {
      if (focused) {
        unawaited(
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 120),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ),
        );
      }
    },
    focusScale: 1,
    borderRadius: BorderRadius.circular(10),
    enabled: onPressed != null,
    onPressed: onPressed ?? () {},
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.appPalette.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: onPressed == null
                    ? context.appPalette.primaryText.withValues(alpha: .5)
                    : null,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
