import 'dart:async';

import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/manga/application/manga_extension_controller.dart';
import 'package:anime_tv/features/manga/application/manga_continue_policy.dart';
import 'package:anime_tv/features/manga/data/manga_store.dart';
import 'package:anime_tv/features/manga/domain/manga_extension_models.dart';
import 'package:anime_tv/features/manga/presentation/manga_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Source chapter browsing, with profile-local status and explicit downloads.
/// Display filters never alter the reading-order list passed to [onRead].
class MangaChapterSheet extends ConsumerStatefulWidget {
  const MangaChapterSheet({
    required this.title,
    required this.initiallyInLibrary,
    required this.loadChapters,
    required this.onRead,
    required this.onDownload,
    required this.onDownloadMany,
    required this.onLibrary,
    this.expectedController,
    super.key,
  });

  final MangaExtensionTitle title;
  final bool initiallyInLibrary;
  final Future<List<MangaExtensionChapter>> Function() loadChapters;
  final FutureOr<void> Function(
    MangaExtensionChapter chapter,
    List<MangaExtensionChapter> fullOrderedList,
  )
  onRead;
  final FutureOr<void> Function(MangaExtensionChapter chapter) onDownload;
  final FutureOr<void> Function(List<MangaExtensionChapter> chapters)
  onDownloadMany;
  final Future<bool> Function() onLibrary;
  final MangaExtensionController? expectedController;

  @override
  ConsumerState<MangaChapterSheet> createState() => _MangaChapterSheetState();
}

class _MangaChapterSheetState extends ConsumerState<MangaChapterSheet> {
  late final MangaExtensionController _controller;
  late bool _inLibrary;
  List<MangaExtensionChapter> _ordered = const [];
  Map<String, MangaReadingProgress> _history = const {};
  MangaReadingProgress? _lastRead;
  bool _loading = true;
  bool _loadFailed = false;
  bool _historyLoading = true;
  bool _historyFailed = false;
  bool _libraryBusy = false;
  bool _openBusy = false;
  bool _downloadBusy = false;
  bool _descending = false;
  bool _unreadOnly = false;
  bool _bookmarksOnly = false;
  String? _operationError;
  final Set<String> _statusBusy = {};
  int _loadGeneration = 0;
  int _historyGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.expectedController ??
        ref.read(mangaExtensionControllerProvider.notifier);
    _inLibrary = widget.initiallyInLibrary;
    unawaited(_loadChapters());
    unawaited(_refreshHistory());
  }

  bool get _sameProfile =>
      mounted &&
      _controller.mounted &&
      identical(
        ref.read(mangaExtensionControllerProvider.notifier),
        _controller,
      );

  bool _checkProfile() {
    if (_sameProfile) return true;
    if (mounted) {
      setState(() {
        _operationError = 'Profile changed. Close and reopen this manga.';
      });
    }
    return false;
  }

  String _chapterKey(MangaExtensionChapter chapter) => mangaExtensionChapterId(
    widget.title.providerId,
    widget.title.id,
    chapter.id,
  );

  MangaReadingProgress? _progress(MangaExtensionChapter chapter) =>
      _history[_chapterKey(chapter)];

  bool get _statusAvailable => !_historyLoading && !_historyFailed;

  Future<void> _loadChapters() async {
    if (!_checkProfile()) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final chapters = await widget.loadChapters();
      if (!_sameProfile || generation != _loadGeneration) return;
      setState(() {
        _ordered = List.unmodifiable(orderedMangaChapters(chapters));
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _refreshHistory() async {
    if (!_checkProfile()) return;
    final generation = ++_historyGeneration;
    setState(() {
      _historyLoading = true;
      _historyFailed = false;
    });
    try {
      final results = await Future.wait<Object?>([
        _controller.chapterHistory(widget.title),
        _controller.lastRead(widget.title),
      ]);
      if (!_sameProfile || generation != _historyGeneration) return;
      final rows = results[0]! as List<MangaReadingProgress>;
      setState(() {
        _history = {for (final row in rows) row.chapterId: row};
        _lastRead = results[1] as MangaReadingProgress?;
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _historyLoading = false;
        _historyFailed = true;
      });
    }
  }

  MangaExtensionChapter? get _continueChapter {
    if (!_statusAvailable) return null;
    final selected = selectMangaContinueChapter(
      orderedChapterIds: _ordered.map(_chapterKey).toList(),
      history: _history.values,
      lastRead: _lastRead,
    );
    return _ordered
        .where((chapter) => _chapterKey(chapter) == selected)
        .firstOrNull;
  }

  List<MangaExtensionChapter> _nextUnread(int maximum) {
    final next = _continueChapter;
    if (next == null) return const [];
    return List.unmodifiable(
      _ordered
          .skip(_ordered.indexOf(next))
          .where((chapter) => !(_progress(chapter)?.completed ?? false))
          .take(maximum),
    );
  }

  Future<void> _toggleLibrary() async {
    if (_libraryBusy || !_checkProfile()) return;
    setState(() {
      _libraryBusy = true;
      _operationError = null;
    });
    try {
      final saved = await widget.onLibrary();
      if (_sameProfile) setState(() => _inLibrary = saved);
    } catch (_) {
      if (mounted) {
        setState(() {
          _operationError = 'Your library could not be updated. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _libraryBusy = false);
    }
  }

  Future<void> _read(MangaExtensionChapter chapter) async {
    if (_openBusy || !_checkProfile()) return;
    setState(() {
      _openBusy = true;
      _operationError = null;
    });
    try {
      await widget.onRead(chapter, _ordered);
      if (_sameProfile) await _refreshHistory();
    } catch (_) {
      if (mounted) {
        setState(() {
          _operationError =
              'This chapter could not be opened. Check the source and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _openBusy = false);
    }
  }

  Future<void> _download(
    List<MangaExtensionChapter> chapters, {
    bool batch = false,
  }) async {
    if (_downloadBusy || chapters.isEmpty || !_checkProfile()) return;
    setState(() {
      _downloadBusy = true;
      _operationError = null;
    });
    try {
      if (batch) {
        await widget.onDownloadMany(List.unmodifiable(chapters.take(10)));
      } else {
        await widget.onDownload(chapters.first);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _operationError =
              'Downloads could not be queued. Check the source and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _downloadBusy = false);
    }
  }

  Future<void> _setStatus(
    MangaExtensionChapter chapter, {
    required bool bookmark,
  }) async {
    if (!_statusAvailable ||
        _statusBusy.contains(chapter.id) ||
        !_checkProfile()) {
      return;
    }
    final old = _progress(chapter);
    setState(() {
      _statusBusy.add(chapter.id);
      _operationError = null;
    });
    try {
      if (bookmark) {
        await _controller.bookmark(
          widget.title,
          chapter,
          bookmarked: !(old?.bookmarked ?? false),
        );
      } else {
        await _controller.markRead(
          widget.title,
          chapter,
          completed: !(old?.completed ?? false),
        );
      }
      if (_sameProfile) await _refreshHistory();
    } catch (_) {
      if (mounted) {
        setState(() {
          _operationError = 'Chapter status could not be saved. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _statusBusy.remove(chapter.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _ordered
        .where(
          (chapter) =>
              (!_unreadOnly || !(_progress(chapter)?.completed ?? false)) &&
              (!_bookmarksOnly || (_progress(chapter)?.bookmarked ?? false)),
        )
        .toList(growable: false);
    final displayed = _descending
        ? filtered.reversed.toList(growable: false)
        : filtered;
    final next = _continueChapter;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 900),
          child: Material(
            color: context.appPalette.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            clipBehavior: Clip.antiAlias,
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Focus(
                onKeyEvent: (_, event) {
                  if (event is KeyDownEvent &&
                      (event.logicalKey == LogicalKeyboardKey.escape ||
                          event.logicalKey == LogicalKeyboardKey.goBack)) {
                    Navigator.of(context).maybePop();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.tr('Chapters'),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          _ChapterAction(
                            label: context.tr('Close'),
                            icon: Icons.close_rounded,
                            autofocus:
                                _loading || _loadFailed || _ordered.isEmpty,
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: CustomScrollView(
                        key: const ValueKey('manga-chapter-scroll'),
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _header(context),
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: [
                                      _ChapterAction(
                                        key: const ValueKey(
                                          'manga-chapter-library',
                                        ),
                                        label: context.tr(
                                          _libraryBusy
                                              ? 'Updating…'
                                              : _inLibrary
                                              ? 'Remove from library'
                                              : 'Add to library',
                                        ),
                                        icon: _inLibrary
                                            ? Icons.library_add_check_rounded
                                            : Icons.library_add_rounded,
                                        onPressed: _libraryBusy
                                            ? null
                                            : _toggleLibrary,
                                      ),
                                      if (next != null)
                                        _ChapterAction(
                                          key: const ValueKey(
                                            'manga-chapter-continue',
                                          ),
                                          label: context.tr('Continue reading'),
                                          icon: Icons.auto_stories_rounded,
                                          prominent: true,
                                          autofocus: true,
                                          onPressed: _openBusy
                                              ? null
                                              : () => _read(next),
                                        ),
                                    ],
                                  ),
                                  if (next != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: Text(
                                        next.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: context.appPalette.mutedText,
                                        ),
                                      ),
                                    ),
                                  if (_operationError case final error?)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          context.tr(error),
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_historyFailed)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: _message(
                                        context,
                                        'Reading status could not be loaded. Retry before using progress filters or batch downloads.',
                                        retry: _refreshHistory,
                                        retryKey: 'manga-chapter-history-retry',
                                      ),
                                    ),
                                  if (!_loading &&
                                      !_loadFailed &&
                                      _ordered.isNotEmpty) ...[
                                    const SizedBox(height: 20),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 10,
                                      children: [
                                        _ChapterAction(
                                          key: const ValueKey(
                                            'manga-chapter-sort',
                                          ),
                                          label: context.tr(
                                            _descending
                                                ? 'Descending'
                                                : 'Ascending',
                                          ),
                                          icon: Icons.sort_rounded,
                                          onPressed: () => setState(
                                            () => _descending = !_descending,
                                          ),
                                        ),
                                        _ChapterAction(
                                          key: const ValueKey(
                                            'manga-chapter-unread-filter',
                                          ),
                                          label: context.tr('Unread only'),
                                          icon: Icons.visibility_off_outlined,
                                          selected: _unreadOnly,
                                          onPressed: _statusAvailable
                                              ? () => setState(
                                                  () => _unreadOnly =
                                                      !_unreadOnly,
                                                )
                                              : null,
                                        ),
                                        _ChapterAction(
                                          key: const ValueKey(
                                            'manga-chapter-bookmarks-filter',
                                          ),
                                          label: context.tr('Bookmarks only'),
                                          icon: Icons.bookmarks_outlined,
                                          selected: _bookmarksOnly,
                                          onPressed: _statusAvailable
                                              ? () => setState(
                                                  () => _bookmarksOnly =
                                                      !_bookmarksOnly,
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 10,
                                      children: [
                                        for (final count in [5, 10])
                                          _ChapterAction(
                                            key: ValueKey(
                                              'manga-chapter-download-$count',
                                            ),
                                            label: context.tr(
                                              count == 5
                                                  ? 'Download next 5 unread'
                                                  : 'Download next 10 unread',
                                            ),
                                            icon: Icons
                                                .download_for_offline_outlined,
                                            onPressed:
                                                _downloadBusy ||
                                                    !_statusAvailable ||
                                                    next == null
                                                ? null
                                                : () => _download(
                                                    _nextUnread(count),
                                                    batch: true,
                                                  ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      context.tr('{count} chapters', {
                                        'count': displayed.length,
                                      }),
                                    ),
                                    if (_statusAvailable && next == null)
                                      Text(context.tr('All chapters read')),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          if (_loading || _historyLoading)
                            const SliverToBoxAdapter(
                              child: LinearProgressIndicator(),
                            ),
                          if (_loadFailed)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: _message(
                                  context,
                                  'This manga source could not load its chapters.',
                                  retry: _loadChapters,
                                  retryKey: 'manga-chapter-load-retry',
                                ),
                              ),
                            ),
                          if (!_loading && !_loadFailed && displayed.isEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  context.tr(
                                    _ordered.isEmpty
                                        ? 'No chapters found'
                                        : 'No chapters match these filters.',
                                  ),
                                ),
                              ),
                            ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                            sliver: SliverList.builder(
                              itemCount: _loading || _loadFailed
                                  ? 0
                                  : displayed.length,
                              itemBuilder: (context, index) =>
                                  _chapterRow(context, displayed[index]),
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
      ),
    );
  }

  Widget _header(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 70,
          height: 100,
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
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.title.providerName} • ${widget.title.language.toUpperCase()}'
              '${widget.title.year == null ? '' : ' • ${widget.title.year}'}',
              style: TextStyle(color: context.appPalette.mutedText),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _message(
    BuildContext context,
    String message, {
    required VoidCallback retry,
    required String retryKey,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(context.tr(message)),
      const SizedBox(height: 10),
      _ChapterAction(
        key: ValueKey(retryKey),
        label: context.tr('Retry'),
        icon: Icons.refresh_rounded,
        onPressed: retry,
      ),
    ],
  );

  Widget _chapterRow(BuildContext context, MangaExtensionChapter chapter) {
    final progress = _progress(chapter);
    final read = progress?.completed ?? false;
    final bookmarked = progress?.bookmarked ?? false;
    final busy = _statusBusy.contains(chapter.id) || !_statusAvailable;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          chapter.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        if (chapter.scanlator case final group?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              group,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.appPalette.mutedText),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            if (_statusAvailable)
              _badge(
                context,
                read ? 'Already read' : 'Unread',
                read
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
              ),
            if (_statusAvailable && bookmarked)
              _badge(context, 'Bookmarked', Icons.bookmark_rounded),
            if (_statusAvailable && !read && (progress?.pageCount ?? 0) > 0)
              Text(
                context.tr('Page {page} of {total}', {
                  'page': progress!.pageIndex + 1,
                  'total': progress.pageCount!,
                }),
                style: TextStyle(color: context.appPalette.mutedText),
              ),
          ],
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _ChapterAction(
          key: ValueKey('manga-chapter-read-${chapter.id}'),
          label: context.tr('Read'),
          icon: Icons.auto_stories_rounded,
          prominent: true,
          onPressed: _openBusy ? null : () => _read(chapter),
        ),
        _ChapterAction(
          key: ValueKey('manga-chapter-download-${chapter.id}'),
          label: context.tr('Download'),
          icon: Icons.download_rounded,
          onPressed: _downloadBusy ? null : () => _download([chapter]),
        ),
        _ChapterAction(
          key: ValueKey('manga-chapter-status-${chapter.id}'),
          label: context.tr(read ? 'Mark unread' : 'Mark read'),
          icon: read ? Icons.remove_done_rounded : Icons.done_all_rounded,
          onPressed: busy ? null : () => _setStatus(chapter, bookmark: false),
        ),
        _ChapterAction(
          key: ValueKey('manga-chapter-bookmark-${chapter.id}'),
          label: context.tr(bookmarked ? 'Remove bookmark' : 'Bookmark'),
          icon: bookmarked
              ? Icons.bookmark_remove_outlined
              : Icons.bookmark_add_outlined,
          onPressed: busy ? null : () => _setStatus(chapter, bookmark: true),
        ),
      ],
    );
    return Container(
      key: ValueKey('manga-chapter-row-${chapter.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.appPalette.primaryText.withValues(alpha: .035),
        border: Border.all(
          color: context.appPalette.primaryText.withValues(alpha: .1),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 900) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [info, const SizedBox(height: 14), actions],
            );
          }
          return Row(
            children: [
              Expanded(flex: 2, child: info),
              const SizedBox(width: 20),
              Expanded(flex: 3, child: actions),
            ],
          );
        },
      ),
    );
  }

  Widget _badge(BuildContext context, String label, IconData icon) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: context.appPalette.mutedText),
      const SizedBox(width: 5),
      Text(
        context.tr(label),
        style: TextStyle(fontSize: 12, color: context.appPalette.mutedText),
      ),
    ],
  );
}

class _ChapterAction extends StatelessWidget {
  const _ChapterAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.prominent = false,
    this.selected = false,
    this.autofocus = false,
    super.key,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool prominent;
  final bool selected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final active = prominent || selected;
    final foreground = active
        ? contrastForeground(context.appPalette.accent)
        : context.appPalette.primaryText;
    return Semantics(
      selected: selected,
      child: TvFocusable(
        autofocus: autofocus,
        enabled: onPressed != null,
        focusScale: 1.015,
        onPressed: onPressed ?? () {},
        onFocusChanged: (focused) {
          if (focused) {
            unawaited(
              Scrollable.ensureVisible(
                context,
                duration: const Duration(milliseconds: 140),
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              ),
            );
          }
        },
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 100),
          opacity: onPressed == null ? .45 : 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: active
                  ? context.appPalette.accent
                  : context.appPalette.primaryText.withValues(alpha: .065),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19, color: foreground),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
