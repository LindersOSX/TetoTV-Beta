import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/discord/application/discord_presence_controller.dart';
import 'package:anime_tv/features/manga/application/manga_discord_presence.dart';
import 'package:anime_tv/features/manga/application/manga_hub_controller.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:anime_tv/features/manga/application/manga_series_preferences_controller.dart';
import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:anime_tv/features/manga/data/manga_local_storage.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_spread_layout.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_page_surface.dart';
import 'package:anime_tv/features/manga/presentation/manga_reader_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class MangaReaderScreen extends ConsumerStatefulWidget {
  const MangaReaderScreen({required this.request, super.key});

  static const routePath = '/manga/read';

  final MangaReaderRequest request;

  @override
  ConsumerState<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends ConsumerState<MangaReaderScreen> {
  final _spreadEngine = const MangaSpreadLayoutEngine();
  final _pageController = PageController();
  final _webtoonController = ScrollController();
  final _readerFocus = FocusNode(debugLabel: 'manga.reader');
  final _backFocus = FocusNode(debugLabel: 'manga.reader.back');
  final _settingsFocus = FocusNode(debugLabel: 'manga.reader.settings');
  final _progressFocus = FocusNode(debugLabel: 'manga.reader.progress');
  final _zoomFocus = FocusNode(debugLabel: 'manga.reader.zoom');
  final _reloadFocus = FocusNode(debugLabel: 'manga.reader.reload');
  final _reloadPages = ValueNotifier<Set<int>>({});
  final _nextChapterFocus = FocusNode(debugLabel: 'manga.reader.next');
  final _previousChapterFocus = FocusNode(debugLabel: 'manga.reader.previous');
  final _remoteZoom = MangaReaderZoomController();
  final _prefetchOwner = Object();
  late final MangaPageFetchClient _pageClient;
  int _preloadGeneration = 0;
  late MangaReaderRequest _request;
  double _pageOffset = 0;
  bool _remoteZoomMode = false;
  bool _chapterLoading = false;
  int _chapterGeneration = 0;
  late final MangaDiscordPresenceCoordinator _discordPresenceCoordinator;
  late final MangaHubController _mangaHubController;
  MangaSpreadLayout? _layout;
  String? _layoutSignature;
  MangaReadingMode? _presentedMode;
  int _pageIndex = 0;
  int _positionSyncGeneration = 0;
  bool _positionSyncPending = false;
  bool _hudVisible = true;
  bool _initialPositionApplied = false;
  bool? _keepAwakeApplied;
  final Set<String> _zoomedSurfaces = {};
  bool get _pageZoomed => _zoomedSurfaces.isNotEmpty;
  int _zoomGeneration = 0;
  String? _webtoonGeometry;
  Size _readerViewport = Size.zero;
  final Map<int, double> _pageAspectRatios = {};
  final Map<int, double> _pendingPageAspectRatios = {};
  bool _pageDimensionsFlushScheduled = false;
  Timer? _hudTimer;
  Timer? _progressTimer;

  MangaReaderSeriesKey get _seriesKey => MangaReaderSeriesKey(
    sourceId: _request.sourceId,
    publicationId: _request.publicationId,
  );

  MangaReaderPreferences get _preferences =>
      ref.read(mangaEffectiveReaderPreferencesProvider(_seriesKey));

  @override
  void initState() {
    super.initState();
    _request = widget.request;
    _pageClient = ref.read(mangaPageFetchClientProvider);
    _pageOffset = _request.initialPageOffset;
    _backFocus.onKeyEvent = _handleTopChromeFocus;
    _settingsFocus.onKeyEvent = _handleTopChromeFocus;
    _zoomFocus.onKeyEvent = _handleTopChromeFocus;
    _reloadFocus.onKeyEvent = _handleTopChromeFocus;
    _previousChapterFocus.onKeyEvent = _handleTopChromeFocus;
    _nextChapterFocus.onKeyEvent = _handleTopChromeFocus;
    _progressFocus.onKeyEvent = _handleProgressFocus;
    _discordPresenceCoordinator = ref.read(
      mangaDiscordPresenceCoordinatorProvider,
    );
    _mangaHubController = ref.read(mangaHubControllerProvider.notifier);
    _pageIndex = _request.initialPageIndex;
    _webtoonController.addListener(_observeWebtoonOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _readerFocus.requestFocus();
      _scheduleHudHide();
      _publishPresence();
      _preloadNear(_pageIndex);
    });
  }

  @override
  void dispose() {
    _chapterGeneration++;
    _preloadGeneration++;
    _pageClient.cancelPrefetches(_prefetchOwner);
    _hudTimer?.cancel();
    _progressTimer?.cancel();
    unawaited(
      _mangaHubController.saveProgress(
        _request,
        pageIndex: _pageIndex,
        pageOffset: _pageOffset,
        completed: _isChapterCompletedAtCurrentPosition(),
      ),
    );
    _pageController.dispose();
    _webtoonController
      ..removeListener(_observeWebtoonOffset)
      ..dispose();
    _readerFocus.dispose();
    _backFocus.dispose();
    _settingsFocus.dispose();
    _progressFocus.dispose();
    _zoomFocus.dispose();
    _reloadFocus.dispose();
    _reloadPages.dispose();
    _nextChapterFocus.dispose();
    _previousChapterFocus.dispose();
    _remoteZoom.dispose();
    if (_keepAwakeApplied == true) {
      unawaited(AndroidTvBridge.instance.setMangaKeepScreenAwake(false));
    }
    unawaited(_discordPresenceCoordinator.stop());
    super.dispose();
  }

  void _applyKeepAwake(bool enabled) {
    if (_keepAwakeApplied == enabled) return;
    _keepAwakeApplied = enabled;
    unawaited(AndroidTvBridge.instance.setMangaKeepScreenAwake(enabled));
  }

  void _scheduleHudHide() {
    _hudTimer?.cancel();
    if (!_hudVisible) return;
    _hudTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (_readerFocus.hasFocus && !_readerFocus.hasPrimaryFocus) {
        _scheduleHudHide();
        return;
      }
      setState(() => _hudVisible = false);
    });
  }

  void _showHud() {
    if (!_hudVisible) setState(() => _hudVisible = true);
    _scheduleHudHide();
  }

  void _toggleHud() {
    if (_hudVisible && !_readerFocus.hasPrimaryFocus) {
      _readerFocus.requestFocus();
    }
    setState(() => _hudVisible = !_hudVisible);
    _scheduleHudHide();
  }

  void _focusChrome(FocusNode node) {
    _showHud();
    node.requestFocus();
  }

  void _focusReader() {
    _readerFocus.requestFocus();
    _scheduleHudHide();
  }

  void _toggleRemoteZoom() {
    if (_remoteZoomMode) {
      _resetZoom();
      _focusReader();
      return;
    }
    setState(() {
      _remoteZoomMode = true;
      _hudVisible = false;
    });
    _readerFocus.requestFocus();
    _remoteZoom.zoomBy(2);
  }

  void _handleBack() {
    if (_chapterLoading) {
      _chapterGeneration++;
      setState(() => _chapterLoading = false);
      _focusReader();
    } else if (_remoteZoomMode || _pageZoomed) {
      _resetZoom();
      _showHud();
      _focusReader();
    } else if (!_readerFocus.hasPrimaryFocus) {
      _readerFocus.requestFocus();
      setState(() => _hudVisible = false);
    } else {
      _leaveReader();
    }
  }

  Future<void> _changeChapter(int direction) async {
    if (_chapterLoading) return;
    final resolver = direction < 0
        ? _request.resolvePreviousChapter
        : _request.resolveNextChapter;
    if (resolver == null) return;
    final generation = ++_chapterGeneration;
    _progressTimer?.cancel();
    setState(() => _chapterLoading = true);
    _showHud();
    try {
      final saved = await _mangaHubController.saveProgress(
        _request,
        pageIndex: _pageIndex,
        pageOffset: _pageOffset,
        completed: _isChapterCompletedAtCurrentPosition(),
      );
      if (!saved) throw StateError('Reading position could not be saved');
      if (!mounted || generation != _chapterGeneration) return;
      final next = await resolver();
      if (!mounted || generation != _chapterGeneration) return;
      if (next == null) throw StateError('Chapter unavailable');
      // A core source must not silently cross into the experimental Aniyomi
      // runtime through a chapter callback. Opening an Aniyomi chapter again
      // must pass through the guarded reader route so Developer Mode is
      // checked at the boundary.
      if (!_request.requiresDeveloperMode && next.requiresDeveloperMode) {
        throw StateError('Reader source boundary changed');
      }
      if (_request.ownerKey != null && next.ownerKey != _request.ownerKey) {
        throw StateError('Reader profile changed');
      }
      _cancelPositionSync();
      _preloadGeneration++;
      _pageClient.cancelPrefetches(_prefetchOwner);
      _remoteZoom.reset();
      setState(() {
        _request = next;
        _pageIndex = next.initialPageIndex;
        _pageOffset = next.initialPageOffset;
        _initialPositionApplied = false;
        _presentedMode = null;
        _layout = null;
        _layoutSignature = null;
        _webtoonGeometry = null;
        _pageAspectRatios.clear();
        _pendingPageAspectRatios.clear();
        _zoomedSurfaces.clear();
        _zoomGeneration++;
        _remoteZoomMode = false;
      });
      _readerFocus.requestFocus();
      _publishPresence();
      _preloadNear(_pageIndex);
    } catch (_) {
      if (!mounted || generation != _chapterGeneration) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'This chapter could not be opened. Your current page is unchanged. Check the source and try again.',
            ),
          ),
          action: SnackBarAction(
            label: context.tr('Retry'),
            onPressed: () => unawaited(_changeChapter(direction)),
          ),
        ),
      );
    } finally {
      if (mounted && generation == _chapterGeneration) {
        setState(() => _chapterLoading = false);
      }
    }
  }

  KeyEventResult _handleTopChromeFocus(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusChrome(_progressFocus);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focusReader();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final nodes = [
        _backFocus,
        _settingsFocus,
        _zoomFocus,
        _reloadFocus,
        if (_request.resolvePreviousChapter != null) _previousChapterFocus,
        if (_request.resolveNextChapter != null) _nextChapterFocus,
      ];
      final index = nodes.indexOf(node);
      final delta = event.logicalKey == LogicalKeyboardKey.arrowRight ? 1 : -1;
      _focusChrome(nodes[(index + delta).clamp(0, nodes.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleProgressFocus(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focusChrome(_backFocus);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusReader();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleKeys(KeyEvent event, MangaReaderPreferences prefs) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      _handleBack();
      return KeyEventResult.handled;
    }
    if (_remoteZoomMode && _readerFocus.hasPrimaryFocus) {
      final pan = switch (key) {
        LogicalKeyboardKey.arrowLeft => const Offset(.12, 0),
        LogicalKeyboardKey.arrowRight => const Offset(-.12, 0),
        LogicalKeyboardKey.arrowUp => const Offset(0, .12),
        LogicalKeyboardKey.arrowDown => const Offset(0, -.12),
        _ => null,
      };
      if (pan != null) {
        _remoteZoom.panBy(pan);
      } else if (key == LogicalKeyboardKey.pageUp ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.equal) {
        _remoteZoom.zoomBy(1.25);
      } else if (key == LogicalKeyboardKey.pageDown ||
          key == LogicalKeyboardKey.minus) {
        _remoteZoom.zoomBy(.8);
      } else if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.space) {
        _remoteZoom.zoomBy(1.25);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (!_readerFocus.hasPrimaryFocus) {
      if (key == LogicalKeyboardKey.arrowUp) {
        if (_progressFocus.hasFocus) {
          _focusChrome(_backFocus);
        } else {
          _focusReader();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        if (_progressFocus.hasFocus) {
          _focusReader();
        } else {
          _focusChrome(_progressFocus);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _focusChrome(_backFocus);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _focusChrome(_progressFocus);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space) {
      _toggleHud();
      return KeyEventResult.handled;
    }
    final forward = prefs.direction == MangaReadingDirection.rightToLeft
        ? LogicalKeyboardKey.arrowLeft
        : LogicalKeyboardKey.arrowRight;
    final backward = prefs.direction == MangaReadingDirection.rightToLeft
        ? LogicalKeyboardKey.arrowRight
        : LogicalKeyboardKey.arrowLeft;
    if (key == forward || key == LogicalKeyboardKey.pageDown) {
      _moveBy(1, prefs);
      return KeyEventResult.handled;
    }
    if (key == backward || key == LogicalKeyboardKey.pageUp) {
      _moveBy(-1, prefs);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _goToPage(0, prefs);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _goToPage(_request.pages.length - 1, prefs);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      _openReaderSettings();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyZ) {
      _toggleRemoteZoom();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveBy(int delta, MangaReaderPreferences prefs) {
    if (_chapterLoading) return;
    if (delta > 0 &&
        _isChapterCompletedAtCurrentPosition() &&
        _request.resolveNextChapter != null) {
      _focusChrome(_nextChapterFocus);
      return;
    }
    if (delta < 0 &&
        _pageIndex == 0 &&
        (prefs.mode != MangaReadingMode.webtoon || _pageOffset <= .001) &&
        _request.resolvePreviousChapter != null) {
      _focusChrome(_previousChapterFocus);
      return;
    }
    _cancelPositionSync();
    _resetZoom();
    _showHud();
    if (prefs.mode == MangaReadingMode.webtoon) {
      if (!_webtoonController.hasClients) return;
      final position = _webtoonController.position;
      final target =
          (_webtoonController.offset + delta * position.viewportDimension * .8)
              .clamp(0.0, position.maxScrollExtent);
      if (_animatePages(prefs)) {
        unawaited(
          _webtoonController.animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        _webtoonController.jumpTo(target);
      }
      return;
    }
    if (prefs.mode == MangaReadingMode.vertical) {
      final target = (_pageIndex + delta).clamp(0, _request.pages.length - 1);
      _turnToPage(target, prefs);
      return;
    }
    final layout = _layout;
    if (layout == null) return;
    final currentSpread = layout.spreadIndexForPage(_pageIndex);
    final target = (currentSpread + delta).clamp(0, layout.spreads.length - 1);
    _turnToPage(target, prefs);
  }

  bool _animatePages(MangaReaderPreferences prefs) =>
      prefs.bookAnimationEnabled && !MediaQuery.disableAnimationsOf(context);

  void _turnToPage(int target, MangaReaderPreferences prefs) {
    if (!_pageController.hasClients) return;
    if (_animatePages(prefs)) {
      unawaited(
        _pageController.animateToPage(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _pageController.jumpToPage(target);
    }
  }

  void _resetZoom() {
    if (!_pageZoomed && !_remoteZoomMode) return;
    _remoteZoom.reset();
    setState(() {
      _remoteZoomMode = false;
      _zoomedSurfaces.clear();
      _zoomGeneration++;
    });
  }

  void _goToPage(int pageIndex, MangaReaderPreferences prefs) {
    _cancelPositionSync();
    _resetZoom();
    final bounded = pageIndex.clamp(0, _request.pages.length - 1);
    _pageOffset = 0;
    if (prefs.mode == MangaReadingMode.webtoon) {
      final offsets = _webtoonOffsets(_readerViewport.width, prefs);
      if (_webtoonController.hasClients && bounded < offsets.length) {
        final offset = offsets[bounded].clamp(
          0.0,
          _webtoonController.position.maxScrollExtent,
        );
        if (_animatePages(prefs)) {
          unawaited(
            _webtoonController.animateTo(
              offset,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
            ),
          );
        } else {
          _webtoonController.jumpTo(offset);
        }
      }
      _setPageIndex(bounded);
      return;
    }
    final target = prefs.mode == MangaReadingMode.vertical
        ? bounded
        : _layout?.spreadIndexForPage(bounded) ?? bounded;
    _turnToPage(target, prefs);
    _setPageIndex(bounded);
  }

  void _setPageIndex(int value) {
    final bounded = value.clamp(0, _request.pages.length - 1);
    if (_pageIndex == bounded) return;
    setState(() {
      _pageIndex = bounded;
      _pageOffset = 0;
      _zoomedSurfaces.clear();
      _zoomGeneration++;
    });
    _scheduleProgressSave();
    _publishPresence();
    _preloadNear(bounded);
  }

  void _scheduleProgressSave() {
    // Coalesce repeated D-pad/page events so progress remains durable without
    // turning a long key hold into a burst of SQLite writes.
    _progressTimer?.cancel();
    _progressTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(
        _mangaHubController.saveProgress(
          _request,
          pageIndex: _pageIndex,
          pageOffset: _pageOffset,
          completed: _isChapterCompletedAtCurrentPosition(),
        ),
      );
    });
  }

  bool _isChapterCompletedAtCurrentPosition() {
    final lastPageIndex = _request.pages.length - 1;
    if (_presentedMode == MangaReadingMode.webtoon) {
      return _pageIndex == lastPageIndex &&
          _webtoonController.hasClients &&
          _webtoonController.offset >=
              _webtoonController.position.maxScrollExtent - 2;
    }
    if (_pageIndex == lastPageIndex) return true;
    if (_presentedMode != MangaReadingMode.paged) return false;
    final layout = _layout;
    if (layout == null) return false;
    return layout.spreadForPage(_pageIndex).containsPageIndex(lastPageIndex);
  }

  void _publishPresence() {
    if (!mounted) return;
    final discord = ref.read(discordPresenceControllerProvider);
    final prefs = ref.read(mangaReaderPreferencesProvider);
    unawaited(
      _discordPresenceCoordinator.update(
        enabled: discord.enabled,
        connected: discord.connected,
        // Secure storage loads asynchronously. Fail closed until the saved
        // privacy preference is known so a previously hidden title cannot be
        // published during the reader's first frame.
        shareTitle: prefs.loaded && prefs.showDiscordTitle,
        title: _request.seriesTitle,
        artworkUrl: _request.coverUri?.toString(),
        chapterLabel: _request.chapterTitle,
        pageIndex: _pageIndex,
        pageCount: _request.pages.length,
      ),
    );
  }

  void _preloadNear(int pageIndex) {
    if (!mounted) return;
    final generation = ++_preloadGeneration;
    final distance = ref.read(mangaReaderPreferencesProvider).preloadPages;
    final roots = ref.read(mangaStorageRootsProvider).valueOrNull;
    final desiredCacheWidth = _readerDesiredCacheWidth(context);
    final first = math.max(0, pageIndex - distance);
    final last = math.min(_request.pages.length - 1, pageIndex + distance);
    final visibleIndexes = <int>{
      if (_presentedMode == MangaReadingMode.paged && _layout != null)
        for (final page
            in _layout!.spreadForPage(pageIndex).pagesInReadingOrder)
          page.index
      else
        pageIndex,
    };
    _pageClient.cancelPrefetches(
      _prefetchOwner,
      keep: [
        for (var index = 0; index < _request.pages.length; index++)
          if ((index >= first && index <= last) ||
              visibleIndexes.contains(index))
            if (_request.pages[index].resource
                case MangaFetchablePageResource resource)
              resource,
      ],
    );
    for (var index = first; index <= last; index++) {
      if (visibleIndexes.contains(index)) continue;
      final page = _request.pages[index];
      switch (page.resource) {
        case MangaFetchablePageResource resource:
          unawaited(
            _pageClient
                .prefetch(resource, owner: _prefetchOwner)
                .then((bytes) async {
                  if (!mounted || generation != _preloadGeneration) return;
                  final image = inspectMangaImage(bytes);
                  await precacheImage(
                    ResizeImage(
                      MemoryImage(bytes),
                      width: _safeReaderCacheWidth(image, desiredCacheWidth),
                    ),
                    context,
                  );
                })
                .onError((_, _) {
                  // A neighboring page is best-effort. The visible page keeps
                  // its own retry/error surface.
                }),
          );
        case MangaTrustedLocalPageResource resource:
          if (roots == null) continue;
          final file = roots.resolvePage(resource);
          unawaited(
            inspectMangaImageFile(file)
                .then((image) async {
                  if (!mounted || generation != _preloadGeneration) return;
                  await precacheImage(
                    ResizeImage(
                      FileImage(file),
                      width: _safeReaderCacheWidth(image, desiredCacheWidth),
                    ),
                    context,
                  );
                })
                .onError((_, _) {
                  // The visible page owns its own local-file error surface.
                }),
          );
      }
    }
  }

  double _contentWidth(double width, MangaReaderPreferences prefs) =>
      math.max(1, width - math.min(prefs.sidePadding, width * .25) * 2);

  double _pageRatio(MangaReaderPage page) =>
      _pageAspectRatios[page.index] ?? page.aspectRatio ?? .7;

  List<double> _webtoonOffsets(double width, MangaReaderPreferences prefs) {
    final contentWidth = _contentWidth(width, prefs);
    final result = <double>[];
    var offset = prefs.pageGap / 2;
    for (final page in _request.pages) {
      result.add(offset);
      offset += contentWidth / _pageRatio(page) + prefs.webtoonGap;
    }
    return result;
  }

  void _observeWebtoonOffset() {
    if (_positionSyncPending || !_webtoonController.hasClients || !mounted) {
      return;
    }
    final offsets = _webtoonOffsets(_readerViewport.width, _preferences);
    final target = _webtoonController.offset;
    var index = 0;
    while (index + 1 < offsets.length && offsets[index + 1] <= target) {
      index += 1;
    }
    final height =
        _contentWidth(_readerViewport.width, _preferences) /
        _pageRatio(_request.pages[index]);
    final fraction = ((target - offsets[index]) / height).clamp(0.0, 1.0);
    final moved = index != _pageIndex || (_pageOffset - fraction).abs() > .0001;
    if (index != _pageIndex) _setPageIndex(index);
    _pageOffset = fraction;
    if (moved) _scheduleProgressSave();
  }

  void _receivePageDimensions(int index, MangaImageInfo info) {
    final ratio = info.width / info.height;
    if (_pageAspectRatios[index] == ratio) return;
    _pendingPageAspectRatios[index] = ratio;
    _schedulePageDimensionsFlush();
  }

  void _schedulePageDimensionsFlush() {
    if (_pageDimensionsFlushScheduled || _pendingPageAspectRatios.isEmpty) {
      return;
    }
    _pageDimensionsFlushScheduled = true;
    final chapter = _request;
    // Batch dimensions against one physical layout. Updating several images
    // individually would mix new page heights with the old scroll offset.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(chapter, _request)) {
        _pageDimensionsFlushScheduled = false;
        return;
      }
      final prefs = _preferences;
      final before = _webtoonOffsets(_readerViewport.width, prefs);
      final oldOffset = _webtoonController.hasClients
          ? _webtoonController.offset
          : 0.0;
      final pageAnchor = _pageIndex;
      final oldHeight =
          _contentWidth(_readerViewport.width, prefs) /
          _pageRatio(_request.pages[pageAnchor]);
      final fraction = _positionSyncPending
          ? _pageOffset
          : oldHeight > 0
          ? ((oldOffset - before[pageAnchor]) / oldHeight).clamp(0.0, 1.0)
          : 0.0;
      _pageOffset = fraction;
      setState(() {
        _pageAspectRatios.addAll(_pendingPageAspectRatios);
        _pendingPageAspectRatios.clear();
      });
      if (prefs.mode != MangaReadingMode.webtoon) {
        _pageDimensionsFlushScheduled = false;
        return;
      }
      final generation = ++_positionSyncGeneration;
      _positionSyncPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(chapter, _request)) {
          _pageDimensionsFlushScheduled = false;
          return;
        }
        if (generation == _positionSyncGeneration &&
            _webtoonController.hasClients) {
          final after = _webtoonOffsets(_readerViewport.width, _preferences);
          final newHeight =
              _contentWidth(_readerViewport.width, _preferences) /
              _pageRatio(_request.pages[pageAnchor]);
          _webtoonController.jumpTo(
            (after[pageAnchor] + fraction * newHeight).clamp(
              0.0,
              _webtoonController.position.maxScrollExtent,
            ),
          );
        }
        if (generation == _positionSyncGeneration) {
          _positionSyncPending = false;
        }
        _pageDimensionsFlushScheduled = false;
        _schedulePageDimensionsFlush();
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _leaveReader() {
    final router = GoRouter.maybeOf(context);
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      router?.go('/manga');
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(
      mangaEffectiveReaderPreferencesProvider(_seriesKey),
    );
    final roots = ref.watch(mangaStorageRootsProvider).valueOrNull;
    ref.listen<DiscordPresenceState>(discordPresenceControllerProvider, (
      previous,
      next,
    ) {
      if (previous?.enabled != next.enabled ||
          previous?.connectionStatus != next.connectionStatus) {
        _publishPresence();
      }
    });
    ref.listen<MangaReaderPreferences>(mangaReaderPreferencesProvider, (
      previous,
      next,
    ) {
      if (previous != null &&
          (previous.loaded != next.loaded ||
              previous.showDiscordTitle != next.showDiscordTitle)) {
        _publishPresence();
      }
    });
    _applyKeepAwake(prefs.keepScreenAwake);
    final background = Color(prefs.background.colorValue);

    final canPop =
        Navigator.of(context).canPop() &&
        !_remoteZoomMode &&
        !_pageZoomed &&
        !_chapterLoading;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Focus(
        focusNode: _readerFocus,
        autofocus: true,
        onKeyEvent: (_, event) => _handleKeys(event, prefs),
        child: _ReaderReloadScope(
          requests: _reloadPages,
          child: Scaffold(
            backgroundColor: background,
            body: Stack(
              fit: StackFit.expand,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) => _buildReader(
                    context,
                    prefs,
                    roots,
                    Size(constraints.maxWidth, constraints.maxHeight),
                  ),
                ),
                if (prefs.showPageNumber && !_hudVisible)
                  Positioned(
                    bottom: 12,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: SafeArea(
                        top: false,
                        child: Center(
                          child: DecoratedBox(
                            key: const ValueKey('manga-reader-page-counter'),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .65),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              child: Text(
                                '${_pageIndex + 1} / ${_request.pages.length}',
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                _ReaderChrome(
                  visible: _hudVisible,
                  title: _request.seriesTitle,
                  chapter: _request.chapterTitle,
                  page: _pageIndex + 1,
                  pageCount: _request.pages.length,
                  onBack: _leaveReader,
                  onSettings: _openReaderSettings,
                  onPageChanged: (value) => _goToPage(value, prefs),
                  backFocusNode: _backFocus,
                  settingsFocusNode: _settingsFocus,
                  progressFocusNode: _progressFocus,
                  zoomFocusNode: _zoomFocus,
                  reloadFocusNode: _reloadFocus,
                  onReload: () {
                    _reloadPages.value = {
                      if (_presentedMode == MangaReadingMode.paged &&
                          _layout != null)
                        for (final page
                            in _layout!
                                .spreadForPage(_pageIndex)
                                .pagesInReadingOrder)
                          page.index
                      else
                        _pageIndex,
                    };
                  },
                  previousChapterFocusNode: _previousChapterFocus,
                  nextChapterFocusNode: _nextChapterFocus,
                  onZoom: _toggleRemoteZoom,
                  onPreviousChapter: _request.resolvePreviousChapter == null
                      ? null
                      : () => unawaited(_changeChapter(-1)),
                  onNextChapter: _request.resolveNextChapter == null
                      ? null
                      : () => unawaited(_changeChapter(1)),
                  chapterLoading: _chapterLoading,
                  chapterCompleted: _isChapterCompletedAtCurrentPosition(),
                ),
                if (_remoteZoomMode)
                  Positioned(
                    top: 12,
                    left: 16,
                    right: 16,
                    child: SafeArea(
                      child: Center(
                        child: Material(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  context.tr(
                                    'Zoom mode • Arrows pan • OK zooms in • Page Down zooms out • Back resets',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: context.tr('Zoom out'),
                                      onPressed: () => _remoteZoom.zoomBy(.8),
                                      icon: const Icon(Icons.remove_rounded),
                                    ),
                                    IconButton(
                                      tooltip: context.tr('Zoom in'),
                                      onPressed: () => _remoteZoom.zoomBy(1.25),
                                      icon: const Icon(Icons.add_rounded),
                                    ),
                                    TextButton(
                                      onPressed: _handleBack,
                                      child: Text(context.tr('Exit zoom')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
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

  Widget _buildReader(
    BuildContext context,
    MangaReaderPreferences prefs,
    MangaStorageRoots? roots,
    Size viewport,
  ) {
    _readerViewport = viewport;
    final geometry =
        '${viewport.width}:${viewport.height}:${prefs.sidePadding}:${prefs.pageGap}:${prefs.webtoonGap}:${prefs.mode}:${prefs.pageFit}:${prefs.spreadMode}';
    if (_webtoonGeometry != geometry) {
      final hadGeometry = _webtoonGeometry != null;
      _webtoonGeometry = geometry;
      _zoomedSurfaces.clear();
      _zoomGeneration++;
      if (hadGeometry && prefs.mode == MangaReadingMode.webtoon) {
        _scheduleReaderPositionSync(prefs, _pageIndex);
      }
    }
    if (!_initialPositionApplied || _presentedMode != prefs.mode) {
      _initialPositionApplied = true;
      _presentedMode = prefs.mode;
      _scheduleReaderPositionSync(prefs, _pageIndex);
    }
    if (prefs.mode == MangaReadingMode.webtoon) {
      return _buildWebtoon(prefs, roots, viewport);
    }
    if (prefs.mode == MangaReadingMode.vertical) {
      return PageView.builder(
        key: const ValueKey('manga-reader-vertical'),
        controller: _pageController,
        scrollDirection: Axis.vertical,
        physics: _pageZoomed ? const NeverScrollableScrollPhysics() : null,
        itemCount: _request.pages.length,
        onPageChanged: (index) {
          if (!_positionSyncPending) _setPageIndex(index);
        },
        itemBuilder: (context, index) => _surface(
          identity: 'vertical-$index',
          prefs: prefs,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: math.min(prefs.sidePadding, viewport.width * .25),
              vertical: prefs.pageGap / 2,
            ),
            child: _MangaPageView(
              page: _request.pages[index],
              roots: roots,
              fit: _boxFit(prefs.pageFit),
              preferences: prefs,
            ),
          ),
        ),
      );
    }

    final fold = _foldGeometry(viewport, MediaQuery.displayFeaturesOf(context));
    final layout = _spreadEngine.build(
      pages: _request.pages,
      readingOrder: prefs.direction == MangaReadingDirection.rightToLeft
          ? MangaReadingOrder.rightToLeft
          : MangaReadingOrder.leftToRight,
      decision: MangaSpreadDecisionInput(
        viewportWidth: viewport.width,
        viewportHeight: viewport.height,
        preference: switch (prefs.spreadMode) {
          MangaSpreadMode.automatic => MangaSpreadPreference.automatic,
          MangaSpreadMode.single => MangaSpreadPreference.singlePage,
          MangaSpreadMode.double => MangaSpreadPreference.doublePage,
        },
        fold: fold,
      ),
      coverStartsAlone: prefs.coverStartsAlone,
      pageGutterExtent: prefs.pageGap,
    );
    _adoptLayout(layout, prefs, fold);
    return PageView.builder(
      key: const ValueKey('manga-reader-paged'),
      controller: _pageController,
      reverse: prefs.direction == MangaReadingDirection.rightToLeft,
      physics: _pageZoomed ? const NeverScrollableScrollPhysics() : null,
      itemCount: layout.spreads.length,
      onPageChanged: (index) {
        if (!_positionSyncPending) {
          _setPageIndex(layout.spreads[index].anchorPageIndex);
        }
      },
      itemBuilder: (context, index) {
        final spread = layout.spreads[index];
        Widget page = _SpreadView(
          spread: spread,
          roots: roots,
          fit: _boxFit(prefs.pageFit),
          gap: layout.gutterExtent,
          fold: fold,
          invert: prefs.invertDoublePages,
          preferences: prefs,
        );
        page = _surface(identity: 'spread-$index', prefs: prefs, child: page);
        return _BookPageTransform(
          index: index,
          controller: _pageController,
          enabled: _animatePages(prefs),
          child: page,
        );
      },
    );
  }

  Widget _surface({
    required String identity,
    required MangaReaderPreferences prefs,
    required Widget child,
  }) {
    final generation = _zoomGeneration;
    final activeIdentity = switch (prefs.mode) {
      MangaReadingMode.webtoon => 'webtoon-$_pageIndex',
      MangaReadingMode.vertical => 'vertical-$_pageIndex',
      MangaReadingMode.paged =>
        'spread-${_layout?.spreadIndexForPage(_pageIndex) ?? 0}',
    };
    return MangaReaderPageSurface(
      key: ValueKey('manga-surface-${_request.chapterId}-$identity'),
      remoteController: identity == activeIdentity ? _remoteZoom : null,
      remoteViewportSize: _readerViewport,
      remoteFocusFraction: prefs.mode == MangaReadingMode.webtoon
          ? Offset(
              .5,
              (_pageOffset +
                      _readerViewport.height *
                          .5 /
                          (_contentWidth(_readerViewport.width, prefs) /
                              _pageRatio(_request.pages[_pageIndex])))
                  .clamp(0, 1),
            )
          : null,
      resetToken: generation,
      preferences: prefs,
      onToggleHud: _toggleHud,
      onTurnPage: (delta) => _moveBy(delta, prefs),
      onZoomChanged: (zoomed) {
        if (!mounted ||
            generation != _zoomGeneration ||
            _zoomedSurfaces.contains(identity) == zoomed) {
          return;
        }
        setState(() {
          if (zoomed) {
            _zoomedSurfaces.add(identity);
          } else {
            _zoomedSurfaces.remove(identity);
          }
        });
      },
      child: child,
    );
  }

  void _adoptLayout(
    MangaSpreadLayout layout,
    MangaReaderPreferences prefs,
    MangaFoldGeometry? fold,
  ) {
    final signature =
        '${layout.usesDoublePages}:'
        '${layout.spreads.length}:${layout.gutterExtent}:'
        '${prefs.direction.name}:${prefs.coverStartsAlone}:'
        '${fold?.firstPaneExtent}:${fold?.secondPaneExtent}';
    if (_layoutSignature == signature) {
      _layout = layout;
      return;
    }
    _zoomedSurfaces.clear();
    _zoomGeneration++;
    final anchor = _layout?.anchorForPage(_pageIndex);
    _layout = layout;
    _layoutSignature = signature;
    final pageIndex = anchor == null
        ? _pageIndex
        : layout.resolveAnchor(anchor).pageIndex;
    _scheduleReaderPositionSync(prefs, pageIndex);
  }

  void _cancelPositionSync() {
    _positionSyncGeneration += 1;
    _positionSyncPending = false;
  }

  void _scheduleReaderPositionSync(
    MangaReaderPreferences prefs,
    int pageIndex,
  ) {
    final bounded = pageIndex.clamp(0, _request.pages.length - 1);
    final generation = ++_positionSyncGeneration;
    _positionSyncPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _positionSyncGeneration) return;
      if (prefs.mode == MangaReadingMode.webtoon) {
        final offsets = _webtoonOffsets(_readerViewport.width, prefs);
        if (_webtoonController.hasClients && bounded < offsets.length) {
          _webtoonController.jumpTo(
            (offsets[bounded] +
                    _pageOffset *
                        _contentWidth(_readerViewport.width, prefs) /
                        _pageRatio(_request.pages[bounded]))
                .clamp(0.0, _webtoonController.position.maxScrollExtent),
          );
        }
      } else if (_pageController.hasClients) {
        final target = prefs.mode == MangaReadingMode.vertical
            ? bounded
            : _layout?.spreadIndexForPage(bounded) ?? bounded;
        _pageController.jumpToPage(target);
      }
      if (_pageIndex != bounded) setState(() => _pageIndex = bounded);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _positionSyncGeneration) {
          _positionSyncPending = false;
        }
      });
    });
  }

  Widget _buildWebtoon(
    MangaReaderPreferences prefs,
    MangaStorageRoots? roots,
    Size viewport,
  ) {
    final width = _contentWidth(viewport.width, prefs);
    final extents = [
      for (final page in _request.pages)
        width / _pageRatio(page) +
            (page.index < _request.pages.length - 1 ? prefs.webtoonGap : 0),
    ];
    return ListView.custom(
      key: const ValueKey('manga-reader-webtoon'),
      controller: _webtoonController,
      physics: _pageZoomed ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.symmetric(
        horizontal: math.min(prefs.sidePadding, viewport.width * .25),
        vertical: prefs.pageGap / 2,
      ),
      // Supply every known extent so distant page jumps use the real total,
      // not an estimate based on whichever short/tall pages are visible.
      itemExtentBuilder: (index, _) =>
          index < extents.length ? extents[index] : null,
      childrenDelegate: _MangaStripChildren(
        totalExtent: extents.fold(0.0, (total, height) => total + height),
        childCount: _request.pages.length,
        builder: (context, index) {
          final chapter = _request;
          final page = _request.pages[index];
          final ratio = _pageRatio(page);
          return Padding(
            padding: EdgeInsets.only(
              bottom: index < _request.pages.length - 1 ? prefs.webtoonGap : 0,
            ),
            child: SizedBox(
              key: ValueKey('manga-webtoon-page-$index'),
              width: width,
              height: width / ratio,
              child: _surface(
                identity: 'webtoon-$index',
                prefs: prefs,
                child: _MangaPageView(
                  page: page,
                  roots: roots,
                  fit: BoxFit.fitWidth,
                  preferences: prefs,
                  onImageInfo: (info) {
                    if (identical(chapter, _request)) {
                      _receivePageDimensions(index, info);
                    }
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openReaderSettings() async {
    _showHud();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.appPalette.surface,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (context) => MangaReaderSettingsSheet(
        seriesKey: _seriesKey,
        seriesTitle: _request.seriesTitle,
      ),
    );
    if (mounted) _readerFocus.requestFocus();
  }
}

class _MangaStripChildren extends SliverChildBuilderDelegate {
  _MangaStripChildren({
    required IndexedWidgetBuilder builder,
    required int childCount,
    required this.totalExtent,
  }) : super(builder, childCount: childCount);

  final double totalExtent;

  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => totalExtent;
}

class _SpreadView extends StatelessWidget {
  const _SpreadView({
    required this.spread,
    required this.roots,
    required this.fit,
    required this.gap,
    required this.fold,
    required this.invert,
    required this.preferences,
  });

  final MangaPageSpread spread;
  final MangaStorageRoots? roots;
  final BoxFit fit;
  final double gap;
  final MangaFoldGeometry? fold;
  final bool invert;
  final MangaReaderPreferences preferences;

  @override
  Widget build(BuildContext context) {
    var left = spread.leftPage;
    var right = spread.rightPage;
    if (invert && left != null && right != null) {
      final swap = left;
      left = right;
      right = swap;
    }
    if (spread.isSingleton) {
      return Center(
        child: _withMargins(
          _MangaPageView(
            page: spread.pagesInReadingOrder.single,
            roots: roots,
            fit: fit,
            preferences: preferences,
          ),
        ),
      );
    }
    final verticalFold =
        fold?.orientation == MangaFoldOrientation.vertical && fold!.separating;
    if (verticalFold) {
      return Row(
        children: [
          SizedBox(width: fold!.firstPaneExtent, child: _optionalPage(left)),
          SizedBox(width: fold!.gutterExtent),
          SizedBox(width: fold!.secondPaneExtent, child: _optionalPage(right)),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: _optionalPage(left)),
        SizedBox(width: gap),
        Expanded(child: _optionalPage(right)),
      ],
    );
  }

  Widget _optionalPage(MangaReaderPage? page) => page == null
      ? const SizedBox.shrink()
      : _withMargins(
          _MangaPageView(
            page: page,
            roots: roots,
            fit: fit,
            preferences: preferences,
          ),
        );

  Widget _withMargins(Widget child) => LayoutBuilder(
    builder: (_, constraints) => Padding(
      padding: EdgeInsets.symmetric(
        horizontal: math.min(
          preferences.sidePadding,
          constraints.maxWidth * .25,
        ),
      ),
      child: child,
    ),
  );
}

class _ReaderReloadScope extends InheritedWidget {
  const _ReaderReloadScope({required this.requests, required super.child});
  final ValueNotifier<Set<int>> requests;
  @override
  bool updateShouldNotify(_ReaderReloadScope oldWidget) =>
      requests != oldWidget.requests;
}

class _MangaPageView extends ConsumerStatefulWidget {
  const _MangaPageView({
    required this.page,
    required this.roots,
    required this.fit,
    required this.preferences,
    this.onImageInfo,
  });

  final MangaReaderPage page;
  final MangaStorageRoots? roots;
  final BoxFit fit;
  final MangaReaderPreferences preferences;
  final ValueChanged<MangaImageInfo>? onImageInfo;

  @override
  ConsumerState<_MangaPageView> createState() => _MangaPageViewState();
}

class _MangaPageViewState extends ConsumerState<_MangaPageView> {
  Future<Uint8List>? _remoteBytes;
  ValueNotifier<Set<int>>? _reloadRequests;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final requests = context
        .dependOnInheritedWidgetOfExactType<_ReaderReloadScope>()
        ?.requests;
    if (requests == _reloadRequests) return;
    _reloadRequests?.removeListener(_reloadRequested);
    _reloadRequests = requests;
    requests?.addListener(_reloadRequested);
  }

  void _reloadRequested() {
    if (_reloadRequests?.value.contains(widget.page.index) == true &&
        widget.page.resource is MangaFetchablePageResource) {
      _retryPage();
    }
  }

  @override
  void dispose() {
    _reloadRequests?.removeListener(_reloadRequested);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  @override
  void didUpdateWidget(covariant _MangaPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.resource != widget.page.resource) _loadPage();
  }

  void _loadPage() {
    final resource = widget.page.resource;
    _remoteBytes = resource is MangaFetchablePageResource
        ? ref.read(mangaPageFetchClientProvider).fetch(resource)
        : null;
  }

  void _retryPage() => setState(_loadPage);

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final roots = widget.roots;
    final fit = widget.fit;
    return LayoutBuilder(
      builder: (context, constraints) {
        final desiredCacheWidth = _readerDesiredCacheWidth(
          context,
          constraints,
        );
        switch (page.resource) {
          case MangaFetchablePageResource():
            return FutureBuilder<Uint8List>(
              future: _remoteBytes,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  final error = snapshot.error;
                  return _PageFailure(
                    message: error is MangaPageFetchException
                        ? error.message
                        : context.tr(
                            "This manga page could not be loaded. Try again.",
                          ),
                    onRetry: _retryPage,
                    hint:
                        error is MangaPageFetchException &&
                            (error.statusCode == 401 || error.statusCode == 403)
                        ? 'If retry fails, return to the chapter list and reopen this chapter to refresh source access.'
                        : 'Check your connection and retry this page. Your reading position is unchanged.',
                  );
                }
                final bytes = snapshot.data;
                if (bytes == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final MangaImageInfo image;
                try {
                  image = inspectMangaImage(bytes);
                } on MangaImageValidationException {
                  return _PageFailure(
                    message: context.tr(
                      "This page could not be decoded safely.",
                    ),
                  );
                }
                widget.onImageInfo?.call(image);
                return Image.memory(
                  bytes,
                  key: ValueKey('manga-page-${page.id}'),
                  semanticLabel: context.tr('Manga page {page}', {
                    'page': page.index + 1,
                  }),
                  fit: fit,
                  cacheWidth: _safeReaderCacheWidth(image, desiredCacheWidth),
                  filterQuality: FilterQuality.medium,
                  frameBuilder: (context, child, frame, sync) =>
                      frame != null || sync
                      ? MangaReaderImageFilter(
                          preferences: widget.preferences,
                          child: child,
                        )
                      : const Center(child: CircularProgressIndicator()),
                  errorBuilder: (context, error, stackTrace) => _PageFailure(
                    message: context.tr("This page could not be decoded."),
                  ),
                );
              },
            );
          case MangaTrustedLocalPageResource resource:
            final localRoots = roots;
            if (localRoots == null) {
              return _PageFailure(
                message: context.tr("This downloaded page is unavailable."),
              );
            }
            return _SafeLocalMangaImage(
              key: ValueKey('manga-safe-local-${page.id}'),
              imageKey: ValueKey('manga-page-${page.id}'),
              file: localRoots.resolvePage(resource),
              semanticLabel: context.tr('Manga page {page}', {
                'page': page.index + 1,
              }),
              fit: fit,
              desiredCacheWidth: desiredCacheWidth,
              preferences: widget.preferences,
              onImageInfo: widget.onImageInfo,
            );
        }
      },
    );
  }
}

const int _maximumMangaReaderDecodedPixels = 8 * 1024 * 1024;

int _readerDesiredCacheWidth(
  BuildContext context, [
  BoxConstraints? constraints,
]) {
  final media = MediaQuery.of(context);
  final logicalWidth = constraints != null && constraints.hasBoundedWidth
      ? constraints.maxWidth
      : media.size.width;
  // Keep enough detail for high-density phones and moderate zoom without
  // decoding a malicious page at its potentially enormous source size.
  final physicalWidth = (logicalWidth * media.devicePixelRatio * 1.5).ceil();
  return physicalWidth
      .clamp(720, math.min(4096, maximumMangaImageWidth))
      .toInt();
}

int _safeReaderCacheWidth(MangaImageInfo image, int desiredWidth) {
  final pixelBound = math
      .sqrt(_maximumMangaReaderDecodedPixels * image.width / image.height)
      .floor();
  return math.max(1, math.min(image.width, math.min(desiredWidth, pixelBound)));
}

class _SafeLocalMangaImage extends StatefulWidget {
  const _SafeLocalMangaImage({
    required this.imageKey,
    required this.file,
    required this.semanticLabel,
    required this.fit,
    required this.desiredCacheWidth,
    required this.preferences,
    this.onImageInfo,
    super.key,
  });

  final Key imageKey;
  final File file;
  final String semanticLabel;
  final BoxFit fit;
  final int desiredCacheWidth;
  final MangaReaderPreferences preferences;
  final ValueChanged<MangaImageInfo>? onImageInfo;

  @override
  State<_SafeLocalMangaImage> createState() => _SafeLocalMangaImageState();
}

class _SafeLocalMangaImageState extends State<_SafeLocalMangaImage> {
  late Future<MangaImageInfo> _inspection;

  @override
  void initState() {
    super.initState();
    _inspection = inspectMangaImageFile(widget.file);
  }

  @override
  void didUpdateWidget(covariant _SafeLocalMangaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _inspection = inspectMangaImageFile(widget.file);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MangaImageInfo>(
    future: _inspection,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _PageFailure(
          message: context.tr("This downloaded page failed its safety check."),
        );
      }
      final info = snapshot.data;
      if (info == null) {
        return const Center(child: CircularProgressIndicator());
      }
      widget.onImageInfo?.call(info);
      return Image(
        key: widget.imageKey,
        image: ResizeImage(
          FileImage(widget.file),
          width: _safeReaderCacheWidth(info, widget.desiredCacheWidth),
        ),
        semanticLabel: widget.semanticLabel,
        fit: widget.fit,
        filterQuality: FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) => frame != null || sync
            ? MangaReaderImageFilter(
                preferences: widget.preferences,
                child: child,
              )
            : const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error, stackTrace) =>
            _PageFailure(message: context.tr("This page could not be loaded.")),
      );
    },
  );
}

class _PageFailure extends StatelessWidget {
  const _PageFailure({required this.message, this.onRetry, this.hint});

  final String message;
  final VoidCallback? onRetry;
  final String? hint;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 46,
            color: context.appPalette.mutedText,
          ),
          const SizedBox(height: 10),
          Text(
            context.tr(message),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              context.tr(hint!),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('manga-page-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.tr('Retry page')),
            ),
          ],
        ],
      ),
    ),
  );
}

class _BookPageTransform extends StatelessWidget {
  const _BookPageTransform({
    required this.index,
    required this.controller,
    required this.enabled,
    required this.child,
  });

  final int index;
  final PageController controller;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: child,
    builder: (context, child) {
      // During a paged/vertical rebuild the outgoing and incoming scrollables
      // briefly share this controller. Reading .page then would assert.
      final page = controller.positions.length == 1
          ? controller.page ?? controller.initialPage.toDouble()
          : controller.initialPage.toDouble();
      final delta = enabled ? (page - index).clamp(-1.0, 1.0) : 0.0;
      final transform = Matrix4.identity()
        ..setEntry(3, 2, .0012)
        ..rotateY(delta * .18);
      return Transform(
        alignment: delta < 0 ? Alignment.centerRight : Alignment.centerLeft,
        transform: transform,
        child: child,
      );
    },
  );
}

class _ReaderChrome extends StatelessWidget {
  const _ReaderChrome({
    required this.visible,
    required this.title,
    required this.chapter,
    required this.page,
    required this.pageCount,
    required this.onBack,
    required this.onSettings,
    required this.onPageChanged,
    required this.backFocusNode,
    required this.settingsFocusNode,
    required this.progressFocusNode,
    required this.zoomFocusNode,
    required this.reloadFocusNode,
    required this.onReload,
    required this.previousChapterFocusNode,
    required this.nextChapterFocusNode,
    required this.onZoom,
    required this.onPreviousChapter,
    required this.onNextChapter,
    required this.chapterLoading,
    required this.chapterCompleted,
  });

  final bool visible;
  final String title;
  final String chapter;
  final int page;
  final int pageCount;
  final VoidCallback onBack;
  final VoidCallback onSettings;
  final ValueChanged<int> onPageChanged;
  final FocusNode backFocusNode;
  final FocusNode settingsFocusNode;
  final FocusNode progressFocusNode;
  final FocusNode zoomFocusNode;
  final FocusNode reloadFocusNode;
  final VoidCallback onReload;
  final FocusNode previousChapterFocusNode;
  final FocusNode nextChapterFocusNode;
  final VoidCallback onZoom;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final bool chapterLoading;
  final bool chapterCompleted;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    key: const ValueKey('manga-reader-chrome-semantics'),
    excluding: !visible,
    child: ExcludeFocus(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: visible ? 1 : 0,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xE6000000), Color(0x00000000)],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('manga-reader-back'),
                        focusNode: backFocusNode,
                        tooltip: context.tr("Back to Manga"),
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text(
                              chapter,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('manga-reader-settings'),
                        focusNode: settingsFocusNode,
                        tooltip: context.tr("Reader settings"),
                        onPressed: onSettings,
                        icon: const Icon(Icons.tune_rounded),
                      ),
                      IconButton(
                        key: const ValueKey('manga-reader-zoom'),
                        focusNode: zoomFocusNode,
                        tooltip: context.tr('Zoom and pan'),
                        onPressed: onZoom,
                        icon: const Icon(Icons.zoom_in_rounded),
                      ),
                      IconButton(
                        key: const ValueKey('manga-reader-reload'),
                        focusNode: reloadFocusNode,
                        tooltip: context.tr('Reload page'),
                        onPressed: chapterLoading ? null : onReload,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                      if (onPreviousChapter != null)
                        IconButton(
                          key: const ValueKey('manga-reader-previous-chapter'),
                          focusNode: previousChapterFocusNode,
                          tooltip: context.tr('Previous chapter'),
                          onPressed: chapterLoading ? null : onPreviousChapter,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                      if (onNextChapter != null)
                        IconButton(
                          key: const ValueKey('manga-reader-next-chapter'),
                          focusNode: nextChapterFocusNode,
                          tooltip: context.tr('Next chapter'),
                          onPressed: chapterLoading ? null : onNextChapter,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (chapterLoading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: LinearProgressIndicator(),
                )
              else if (chapterCompleted)
                Center(
                  child: Material(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: onNextChapter != null
                          ? TextButton.icon(
                              key: const ValueKey('manga-reader-end-next'),
                              onPressed: onNextChapter,
                              icon: const Icon(Icons.skip_next_rounded),
                              label: Text(
                                context.tr('Chapter complete • Next chapter'),
                              ),
                            )
                          : Text(
                              context.tr('Chapter complete'),
                              style: const TextStyle(color: Colors.white),
                            ),
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xE6000000)],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Semantics(
                        key: const ValueKey('manga-reader-position-semantics'),
                        liveRegion: true,
                        label: context.tr("Page {value1} of {value2}", {
                          'value1': page,
                          'value2': pageCount,
                        }),
                        excludeSemantics: true,
                        child: Text('$page / $pageCount'),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('manga-reader-progress'),
                          focusNode: progressFocusNode,
                          value: (page - 1).toDouble(),
                          min: 0,
                          max: math.max(1, pageCount - 1).toDouble(),
                          divisions: pageCount > 1 ? pageCount - 1 : null,
                          label: context.tr("Page {value1}", {'value1': page}),
                          onChanged: pageCount > 1
                              ? (value) => onPageChanged(value.round())
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Icon(Icons.menu_book_rounded, size: 20),
                    ],
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

BoxFit _boxFit(MangaPageFit fit) => switch (fit) {
  MangaPageFit.contain => BoxFit.contain,
  MangaPageFit.width => BoxFit.fitWidth,
  MangaPageFit.height => BoxFit.fitHeight,
};

MangaFoldGeometry? _foldGeometry(Size viewport, List<DisplayFeature> features) {
  for (final feature in features) {
    if (feature.type != DisplayFeatureType.fold &&
        feature.type != DisplayFeatureType.hinge) {
      continue;
    }
    final bounds = feature.bounds;
    if (bounds.isEmpty && feature.type != DisplayFeatureType.fold) continue;
    final vertical = bounds.height >= viewport.height * .5;
    if (vertical) {
      final first = bounds.left.clamp(0, viewport.width).toDouble();
      final second = (viewport.width - bounds.right)
          .clamp(0, viewport.width)
          .toDouble();
      return MangaFoldGeometry(
        orientation: MangaFoldOrientation.vertical,
        separating: true,
        firstPaneExtent: first,
        secondPaneExtent: second,
        gutterExtent: bounds.width,
      );
    }
    return MangaFoldGeometry(
      orientation: MangaFoldOrientation.horizontal,
      separating: true,
      firstPaneExtent: bounds.top.clamp(0, viewport.height).toDouble(),
      secondPaneExtent: (viewport.height - bounds.bottom)
          .clamp(0, viewport.height)
          .toDouble(),
      gutterExtent: bounds.height,
    );
  }
  return null;
}
