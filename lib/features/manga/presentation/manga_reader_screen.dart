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
import 'package:anime_tv/features/manga/data/manga_image_safety.dart';
import 'package:anime_tv/features/manga/data/manga_local_storage.dart';
import 'package:anime_tv/features/manga/data/manga_page_fetch_client.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/manga/domain/manga_spread_layout.dart';
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
  Timer? _hudTimer;
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _backFocus.onKeyEvent = _handleTopChromeFocus;
    _settingsFocus.onKeyEvent = _handleTopChromeFocus;
    _progressFocus.onKeyEvent = _handleProgressFocus;
    _discordPresenceCoordinator = ref.read(
      mangaDiscordPresenceCoordinatorProvider,
    );
    _mangaHubController = ref.read(mangaHubControllerProvider.notifier);
    _pageIndex = widget.request.initialPageIndex;
    _webtoonController.addListener(_observeWebtoonOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _readerFocus.requestFocus();
      _scheduleHudHide();
      _publishPresence();
    });
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    _progressTimer?.cancel();
    unawaited(
      _mangaHubController.saveProgress(
        widget.request,
        pageIndex: _pageIndex,
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

  void _handleTapZone(TapUpDetails details, MangaReaderPreferences prefs) {
    final width = MediaQuery.sizeOf(context).width;
    if (!width.isFinite || width <= 0) {
      _toggleHud();
      return;
    }
    final x = details.localPosition.dx;
    if (x >= width / 3 && x <= width * 2 / 3) {
      _toggleHud();
      return;
    }
    final tappedLeft = x < width / 3;
    final forward = prefs.direction == MangaReadingDirection.rightToLeft
        ? tappedLeft
        : !tappedLeft;
    _moveBy(forward ? 1 : -1, prefs);
  }

  void _focusChrome(FocusNode node) {
    _showHud();
    node.requestFocus();
  }

  void _focusReader() {
    _readerFocus.requestFocus();
    _scheduleHudHide();
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
    if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
        identical(node, _backFocus)) {
      _focusChrome(_settingsFocus);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        identical(node, _settingsFocus)) {
      _focusChrome(_backFocus);
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
      _leaveReader();
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
      _goToPage(widget.request.pages.length - 1, prefs);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      _openReaderSettings();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveBy(int delta, MangaReaderPreferences prefs) {
    _cancelPositionSync();
    _showHud();
    if (prefs.mode == MangaReadingMode.webtoon) {
      _goToPage(
        (_pageIndex + delta).clamp(0, widget.request.pages.length - 1),
        prefs,
      );
      return;
    }
    if (prefs.mode == MangaReadingMode.vertical) {
      final target = (_pageIndex + delta).clamp(
        0,
        widget.request.pages.length - 1,
      );
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final layout = _layout;
    if (layout == null) return;
    final currentSpread = layout.spreadIndexForPage(_pageIndex);
    final target = (currentSpread + delta).clamp(0, layout.spreads.length - 1);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _goToPage(int pageIndex, MangaReaderPreferences prefs) {
    _cancelPositionSync();
    final bounded = pageIndex.clamp(0, widget.request.pages.length - 1);
    if (prefs.mode == MangaReadingMode.webtoon) {
      final viewport = MediaQuery.sizeOf(context);
      final offsets = _webtoonOffsets(viewport.width);
      if (_webtoonController.hasClients && bounded < offsets.length) {
        _webtoonController.animateTo(
          offsets[bounded],
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
      _setPageIndex(bounded);
      return;
    }
    final target = prefs.mode == MangaReadingMode.vertical
        ? bounded
        : _layout?.spreadIndexForPage(bounded) ?? bounded;
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
    _setPageIndex(bounded);
  }

  void _setPageIndex(int value) {
    final bounded = value.clamp(0, widget.request.pages.length - 1);
    if (_pageIndex == bounded) return;
    setState(() => _pageIndex = bounded);
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
          widget.request,
          pageIndex: _pageIndex,
          completed: _isChapterCompletedAtCurrentPosition(),
        ),
      );
    });
  }

  bool _isChapterCompletedAtCurrentPosition() {
    final lastPageIndex = widget.request.pages.length - 1;
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
        title: widget.request.seriesTitle,
        chapterLabel: widget.request.chapterTitle,
        pageIndex: _pageIndex,
        pageCount: widget.request.pages.length,
      ),
    );
  }

  void _preloadNear(int pageIndex) {
    if (!mounted) return;
    final distance = ref.read(mangaReaderPreferencesProvider).preloadPages;
    final roots = ref.read(mangaStorageRootsProvider).valueOrNull;
    final desiredCacheWidth = _readerDesiredCacheWidth(context);
    for (
      var index = math.max(0, pageIndex - distance);
      index <= math.min(widget.request.pages.length - 1, pageIndex + distance);
      index++
    ) {
      final page = widget.request.pages[index];
      switch (page.resource) {
        case MangaRemotePageResource resource:
          unawaited(
            ref
                .read(mangaPageFetchClientProvider)
                .fetch(resource)
                .then((bytes) async {
                  if (!mounted) return;
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
                  if (!mounted) return;
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

  List<double> _webtoonOffsets(double width) {
    final contentWidth = math.max(240, width);
    final result = <double>[];
    var offset = 0.0;
    for (final page in widget.request.pages) {
      result.add(offset);
      final ratio = page.aspectRatio ?? .7;
      offset += contentWidth / ratio;
    }
    return result;
  }

  void _observeWebtoonOffset() {
    if (_positionSyncPending || !_webtoonController.hasClients || !mounted) {
      return;
    }
    final offsets = _webtoonOffsets(MediaQuery.sizeOf(context).width);
    final target = _webtoonController.offset + 40;
    var index = 0;
    while (index + 1 < offsets.length && offsets[index + 1] <= target) {
      index += 1;
    }
    if (index != _pageIndex) _setPageIndex(index);
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
    final prefs = ref.watch(mangaReaderPreferencesProvider);
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

    final canPop = Navigator.of(context).canPop();
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) GoRouter.maybeOf(context)?.go('/manga');
      },
      child: Focus(
        focusNode: _readerFocus,
        autofocus: true,
        onKeyEvent: (_, event) => _handleKeys(event, prefs),
        child: Scaffold(
          backgroundColor: background,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: prefs.tapZonesEnabled
                ? (details) => _handleTapZone(details, prefs)
                : null,
            child: Stack(
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
                _ReaderChrome(
                  visible: _hudVisible,
                  title: widget.request.seriesTitle,
                  chapter: widget.request.chapterTitle,
                  page: _pageIndex + 1,
                  pageCount: widget.request.pages.length,
                  onBack: _leaveReader,
                  onSettings: _openReaderSettings,
                  onPageChanged: (value) => _goToPage(value, prefs),
                  backFocusNode: _backFocus,
                  settingsFocusNode: _settingsFocus,
                  progressFocusNode: _progressFocus,
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
        itemCount: widget.request.pages.length,
        onPageChanged: (index) {
          if (!_positionSyncPending) _setPageIndex(index);
        },
        itemBuilder: (context, index) => Padding(
          padding: EdgeInsets.all(prefs.pageGap / 2),
          child: _MangaPageView(
            page: widget.request.pages[index],
            roots: roots,
            fit: _boxFit(prefs.pageFit),
          ),
        ),
      );
    }

    final fold = _foldGeometry(viewport, MediaQuery.displayFeaturesOf(context));
    final layout = _spreadEngine.build(
      pages: widget.request.pages,
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
        );
        if (prefs.bookAnimationEnabled) {
          page = _BookPageTransform(
            index: index,
            controller: _pageController,
            child: page,
          );
        }
        return page;
      },
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
    final bounded = pageIndex.clamp(0, widget.request.pages.length - 1);
    final generation = ++_positionSyncGeneration;
    _positionSyncPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _positionSyncGeneration) return;
      if (prefs.mode == MangaReadingMode.webtoon) {
        final offsets = _webtoonOffsets(MediaQuery.sizeOf(context).width);
        if (_webtoonController.hasClients && bounded < offsets.length) {
          _webtoonController.jumpTo(offsets[bounded]);
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
    return ListView.builder(
      key: const ValueKey('manga-reader-webtoon'),
      controller: _webtoonController,
      padding: EdgeInsets.symmetric(vertical: prefs.pageGap / 2),
      itemCount: widget.request.pages.length,
      itemBuilder: (context, index) {
        final page = widget.request.pages[index];
        final ratio = page.aspectRatio ?? .7;
        return Center(
          child: SizedBox(
            width: viewport.width,
            height: viewport.width / ratio,
            child: _MangaPageView(
              page: page,
              roots: roots,
              fit: BoxFit.fitWidth,
            ),
          ),
        );
      },
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
      builder: (context) => const _MangaReaderSettingsSheet(),
    );
    if (mounted) _readerFocus.requestFocus();
  }
}

class _SpreadView extends StatelessWidget {
  const _SpreadView({
    required this.spread,
    required this.roots,
    required this.fit,
    required this.gap,
    required this.fold,
    required this.invert,
  });

  final MangaPageSpread spread;
  final MangaStorageRoots? roots;
  final BoxFit fit;
  final double gap;
  final MangaFoldGeometry? fold;
  final bool invert;

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
        child: _MangaPageView(
          page: spread.pagesInReadingOrder.single,
          roots: roots,
          fit: fit,
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
      : _MangaPageView(page: page, roots: roots, fit: fit);
}

class _MangaPageView extends ConsumerWidget {
  const _MangaPageView({
    required this.page,
    required this.roots,
    required this.fit,
  });

  final MangaReaderPage page;
  final MangaStorageRoots? roots;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desiredCacheWidth = _readerDesiredCacheWidth(
          context,
          constraints,
        );
        switch (page.resource) {
          case MangaRemotePageResource resource:
            return FutureBuilder<Uint8List>(
              future: ref.read(mangaPageFetchClientProvider).fetch(resource),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  final error = snapshot.error;
                  return _PageFailure(
                    message: error is MangaPageFetchException
                        ? error.message
                        : 'This manga page could not be loaded. Try again.',
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
                  return const _PageFailure(
                    message: 'This page could not be decoded safely.',
                  );
                }
                return Image.memory(
                  bytes,
                  key: ValueKey('manga-page-${page.id}'),
                  semanticLabel: 'Manga page ${page.index + 1}',
                  fit: fit,
                  cacheWidth: _safeReaderCacheWidth(image, desiredCacheWidth),
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, error, stackTrace) =>
                      const _PageFailure(
                        message: 'This page could not be decoded.',
                      ),
                );
              },
            );
          case MangaTrustedLocalPageResource resource:
            final localRoots = roots;
            if (localRoots == null) {
              return const _PageFailure(
                message: 'This downloaded page is unavailable.',
              );
            }
            return _SafeLocalMangaImage(
              key: ValueKey('manga-safe-local-${page.id}'),
              imageKey: ValueKey('manga-page-${page.id}'),
              file: localRoots.resolvePage(resource),
              semanticLabel: 'Manga page ${page.index + 1}',
              fit: fit,
              desiredCacheWidth: desiredCacheWidth,
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
    super.key,
  });

  final Key imageKey;
  final File file;
  final String semanticLabel;
  final BoxFit fit;
  final int desiredCacheWidth;

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
        return const _PageFailure(
          message: 'This downloaded page failed its safety check.',
        );
      }
      final info = snapshot.data;
      if (info == null) {
        return const Center(child: CircularProgressIndicator());
      }
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
            ? child
            : const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error, stackTrace) =>
            const _PageFailure(message: 'This page could not be loaded.'),
      );
    },
  );
}

class _PageFailure extends StatelessWidget {
  const _PageFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: 46,
          color: context.appPalette.mutedText,
        ),
        const SizedBox(height: 10),
        Text(message, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ),
  );
}

class _BookPageTransform extends StatelessWidget {
  const _BookPageTransform({
    required this.index,
    required this.controller,
    required this.child,
  });

  final int index;
  final PageController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: child,
    builder: (context, child) {
      final page = controller.hasClients
          ? controller.page ?? controller.initialPage.toDouble()
          : controller.initialPage.toDouble();
      final delta = (page - index).clamp(-1.0, 1.0);
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

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    key: const ValueKey('manga-reader-chrome-semantics'),
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
                      tooltip: 'Back to Manga',
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
                      tooltip: 'Reader settings',
                      onPressed: onSettings,
                      icon: const Icon(Icons.tune_rounded),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
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
                      label: 'Page $page of $pageCount',
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
                        label: 'Page $page',
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
  );
}

class _MangaReaderSettingsSheet extends ConsumerWidget {
  const _MangaReaderSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(mangaReaderPreferencesProvider);
    final controller = ref.read(mangaReaderPreferencesProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Reader settings',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _ReaderChoice<MangaReadingMode>(
            label: 'Reading mode',
            value: prefs.mode,
            values: MangaReadingMode.values,
            name: (value) => value.displayName,
            onChanged: controller.setMode,
          ),
          _ReaderChoice<MangaReadingDirection>(
            label: 'Reading direction',
            value: prefs.direction,
            values: MangaReadingDirection.values,
            name: (value) => value.displayName,
            onChanged: controller.setDirection,
          ),
          _ReaderChoice<MangaSpreadMode>(
            label: 'Page spread',
            value: prefs.spreadMode,
            values: MangaSpreadMode.values,
            name: (value) => value.displayName,
            onChanged: controller.setSpreadMode,
          ),
          _ReaderChoice<MangaPageFit>(
            label: 'Page fit',
            value: prefs.pageFit,
            values: MangaPageFit.values,
            name: (value) => value.displayName,
            onChanged: controller.setPageFit,
          ),
          _ReaderChoice<MangaReaderBackground>(
            label: 'Background',
            value: prefs.background,
            values: MangaReaderBackground.values,
            name: (value) => value.displayName,
            onChanged: controller.setBackground,
          ),
          _ReaderSlider(
            label: 'Page gap',
            value: prefs.pageGap,
            min: 0,
            max: 40,
            divisions: 8,
            valueLabel: '${prefs.pageGap.round()} px',
            onChanged: controller.setPageGap,
          ),
          _ReaderSlider(
            label: 'Pages to preload',
            value: prefs.preloadPages.toDouble(),
            min: 0,
            max: 5,
            divisions: 5,
            valueLabel: '${prefs.preloadPages}',
            onChanged: (value) => controller.setPreloadPages(value.round()),
          ),
          _ReaderSwitch(
            label: 'Keep cover by itself',
            value: prefs.coverStartsAlone,
            onChanged: controller.setCoverStartsAlone,
          ),
          _ReaderSwitch(
            label: 'Swap double-page sides',
            value: prefs.invertDoublePages,
            onChanged: controller.setInvertDoublePages,
          ),
          _ReaderSwitch(
            label: 'Book page animation',
            value: prefs.bookAnimationEnabled,
            onChanged: controller.setBookAnimationEnabled,
          ),
          _ReaderSwitch(
            label: 'Tap zones',
            value: prefs.tapZonesEnabled,
            onChanged: controller.setTapZonesEnabled,
          ),
          _ReaderSwitch(
            label: 'Keep screen awake',
            value: prefs.keepScreenAwake,
            onChanged: controller.setKeepScreenAwake,
          ),
          _ReaderSwitch(
            label: 'Show manga title on Discord',
            subtitle: 'Turn off to share only “Reading manga”.',
            value: prefs.showDiscordTitle,
            onChanged: controller.setShowDiscordTitle,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: controller.reset,
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Reset reader settings'),
          ),
        ],
      ),
    );
  }
}

class _ReaderChoice<T> extends StatelessWidget {
  const _ReaderChoice({
    required this.label,
    required this.value,
    required this.values,
    required this.name,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> values;
  final String Function(T value) name;
  final Future<void> Function(T value) onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    trailing: DropdownButton<T>(
      value: value,
      items: [
        for (final item in values)
          DropdownMenuItem(value: item, child: Text(name(item))),
      ],
      onChanged: (item) {
        if (item != null) unawaited(onChanged(item));
      },
    ),
  );
}

class _ReaderSlider extends StatelessWidget {
  const _ReaderSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final Future<void> Function(double value) onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    subtitle: Slider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      label: valueLabel,
      onChanged: (next) => unawaited(onChanged(next)),
    ),
    trailing: Text(valueLabel),
  );
}

class _ReaderSwitch extends StatelessWidget {
  const _ReaderSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final Future<void> Function(bool value) onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    title: Text(label),
    subtitle: subtitle == null ? null : Text(subtitle!),
    value: value,
    onChanged: (next) => unawaited(onChanged(next)),
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
