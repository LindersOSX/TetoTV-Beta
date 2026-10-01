import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/tv_text_input.dart';
import 'episode_number_control.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/catalog_episode_metadata.dart';
import 'package:anime_tv/features/catalog/domain/episode_airing_availability.dart';
import 'localized_episode_airing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<int?> showEpisodeBrowserDialog(
  BuildContext context, {
  required AnimeSummary anime,
  required int selectedEpisode,
  required int totalEpisodes,
  bool isTelevision = false,
  Future<Map<int, CatalogEpisodeMetadata>>? episodeMetadataFuture,
}) {
  return showTetoDialog<int>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .72),
    builder: (_) => EpisodeBrowserDialog(
      anime: anime,
      selectedEpisode: selectedEpisode,
      totalEpisodes: totalEpisodes,
      isTelevision: isTelevision,
      episodeMetadataFuture: episodeMetadataFuture,
    ),
  );
}

/// A paged episode browser designed for TV remotes and compact screens.
///
/// Episode-specific metadata is optional. Cards use clearly labelled
/// series-level artwork as a fallback and explicitly say when an episode
/// synopsis is unavailable instead of presenting the series synopsis as
/// episode-specific metadata.
class EpisodeBrowserDialog extends StatefulWidget {
  const EpisodeBrowserDialog({
    required this.anime,
    required this.selectedEpisode,
    required this.totalEpisodes,
    this.isTelevision = false,
    this.episodeMetadata = const <int, CatalogEpisodeMetadata>{},
    this.episodeMetadataFuture,
    this.now,
    this.embedded = false,
    this.onClose,
    this.onEpisodeSelected,
    super.key,
  }) : assert(totalEpisodes > 0),
       assert(selectedEpisode > 0 && selectedEpisode <= totalEpisodes);

  final AnimeSummary anime;
  final int selectedEpisode;
  final int totalEpisodes;
  final bool isTelevision;
  final Map<int, CatalogEpisodeMetadata> episodeMetadata;
  final Future<Map<int, CatalogEpisodeMetadata>>? episodeMetadataFuture;
  final DateTime? now;
  final bool embedded;
  final VoidCallback? onClose;
  final ValueChanged<int>? onEpisodeSelected;

  @override
  State<EpisodeBrowserDialog> createState() => _EpisodeBrowserDialogState();
}

class _EpisodeBrowserDialogState extends State<EpisodeBrowserDialog> {
  final Map<int, FocusNode> _episodeFocusNodes = <int, FocusNode>{};
  int _pageIndex = 0;
  int _pageMotionDirection = 1;
  int? _pageSize;
  late int _selectedEpisode;
  final _numberFocus = FocusNode(debugLabel: 'episode-browser.number');
  final _previousFocus = FocusNode(debugLabel: 'episode-browser.previous');
  final _nextFocus = FocusNode(debugLabel: 'episode-browser.next');
  bool _choosingNumber = false;
  late Map<int, CatalogEpisodeMetadata> _episodeMetadata;
  int _metadataGeneration = 0;

  @override
  void initState() {
    super.initState();
    _selectedEpisode = widget.selectedEpisode;
    _episodeMetadata = widget.episodeMetadata;
    _loadEpisodeMetadata();
  }

  @override
  void didUpdateWidget(covariant EpisodeBrowserDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedEpisode != widget.selectedEpisode) {
      _selectedEpisode = widget.selectedEpisode;
    }
    if (!identical(oldWidget.episodeMetadata, widget.episodeMetadata) ||
        !identical(
          oldWidget.episodeMetadataFuture,
          widget.episodeMetadataFuture,
        )) {
      _episodeMetadata = widget.episodeMetadata;
      _loadEpisodeMetadata();
    }
  }

  void _loadEpisodeMetadata() {
    final generation = ++_metadataGeneration;
    final future = widget.episodeMetadataFuture;
    if (future == null) return;
    unawaited(
      future
          .then((metadata) {
            if (!mounted || generation != _metadataGeneration) return;
            setState(() {
              _episodeMetadata = <int, CatalogEpisodeMetadata>{
                ...widget.episodeMetadata,
                ...metadata,
              };
            });
          })
          .catchError((Object _) {
            // Episode metadata is optional; retain the honest generic cards.
          }),
    );
  }

  FocusNode _focusNodeForEpisode(int episode) => _episodeFocusNodes.putIfAbsent(
    episode,
    () => FocusNode(debugLabel: 'episode-browser.$episode'),
  );

  @override
  void dispose() {
    _metadataGeneration++;
    _numberFocus.dispose();
    _previousFocus.dispose();
    _nextFocus.dispose();
    for (final node in _episodeFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _changePage(int page, {int? focusEpisode, bool focusGrid = true}) {
    final pageSize = _pageSize;
    if (pageSize == null) return;
    final pageCount = (widget.totalEpisodes / pageSize).ceil();
    final nextPage = page.clamp(0, pageCount - 1);
    if (nextPage == _pageIndex) return;
    setState(() {
      _pageMotionDirection = nextPage > _pageIndex ? 1 : -1;
      _pageIndex = nextPage;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pageIndex != nextPage || _pageSize != pageSize) return;
      final firstEpisode = nextPage * pageSize + 1;
      final lastEpisode = math.min(
        firstEpisode + pageSize - 1,
        widget.totalEpisodes,
      );
      final targetEpisode = math.max(
        firstEpisode,
        math.min(focusEpisode ?? firstEpisode, lastEpisode),
      );
      final node = _focusNodeForEpisode(targetEpisode);
      if (focusGrid && node.canRequestFocus && node.context != null) {
        node.requestFocus();
      }
      // Only the current grid remains mounted. Release old page nodes after
      // that grid has detached instead of accumulating one per episode.
      final obsoleteEpisodes = _episodeFocusNodes.keys
          .where((episode) => episode < firstEpisode || episode > lastEpisode)
          .toList();
      for (final episode in obsoleteEpisodes) {
        _episodeFocusNodes.remove(episode)?.dispose();
      }
    });
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    Navigator.pop(context);
  }

  void _selectEpisode(int episode) {
    final onEpisodeSelected = widget.onEpisodeSelected;
    if (onEpisodeSelected != null) {
      onEpisodeSelected(episode);
      return;
    }
    Navigator.pop(context, episode);
  }

  void _jumpTo(int episode) {
    final pageSize = _pageSize!;
    setState(() => _selectedEpisode = episode);
    _changePage(
      (episode - 1) ~/ pageSize,
      focusEpisode: episode,
      focusGrid: false,
    );
    // A boundary step can become disabled after this change. Keep focus on
    // a live header target rather than an unmounted arrow.
    if ((episode == 1 && _previousFocus.hasFocus) ||
        (episode == widget.totalEpisodes && _nextFocus.hasFocus)) {
      _numberFocus.requestFocus();
    }
  }

  void _focusSelectedCard() {
    final first = _pageIndex * _pageSize! + 1;
    final last = math.min(first + _pageSize! - 1, widget.totalEpisodes);
    _focusNodeForEpisode(_selectedEpisode.clamp(first, last)).requestFocus();
  }

  Future<void> _chooseNumber() async {
    if (_choosingNumber) return;
    _choosingNumber = true;
    final value = await showTetoDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TvKeyboardDialog(
        title: 'Choose episode (1–${widget.totalEpisodes})',
        initialValue: '$_selectedEpisode',
        numericOnly: true,
        maxLength: widget.totalEpisodes.toString().length,
        reduceWidthForTelevision: widget.isTelevision,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        validator: (input) {
          final number = int.tryParse(input.trim());
          return number == null || number < 1 || number > widget.totalEpisodes
              ? 'Enter an episode from 1 to ${widget.totalEpisodes}.'
              : null;
        },
      ),
    );
    _choosingNumber = false;
    if (!mounted) return;
    final number = value == null ? null : int.tryParse(value.trim());
    if (number != null && number >= 1 && number <= widget.totalEpisodes) {
      _jumpTo(number);
    }
    _numberFocus.requestFocus();
  }

  KeyEventResult _handleEpisodeNavigation({
    required int episode,
    required int firstEpisode,
    required int lastEpisode,
    required int columns,
    required int pageSize,
    required int pageCount,
    required KeyEvent event,
  }) {
    final isUp = event.logicalKey == LogicalKeyboardKey.arrowUp;
    final isDown = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final isLeft = event.logicalKey == LogicalKeyboardKey.arrowLeft;
    final isRight = event.logicalKey == LogicalKeyboardKey.arrowRight;
    if (!isUp && !isDown && !isLeft && !isRight) {
      return KeyEventResult.ignored;
    }

    final localIndex = episode - firstEpisode;
    final row = localIndex ~/ columns;
    final column = localIndex % columns;
    if (isUp && row == 0) {
      if (event is KeyDownEvent) _numberFocus.requestFocus();
      return KeyEventResult.handled;
    }
    final adjacentEpisode = isUp
        ? episode - columns
        : isDown
        ? episode + columns
        : isLeft && column > 0
        ? episode - 1
        : isRight && column < columns - 1
        ? episode + 1
        : null;
    if (adjacentEpisode != null &&
        adjacentEpisode >= firstEpisode &&
        adjacentEpisode <= lastEpisode) {
      // Resolve the grid target directly. Animated focus scales must not
      // change the geometry used to decide where a rapid D-pad press goes.
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _focusNodeForEpisode(adjacentEpisode).requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (isUp || isDown) return KeyEventResult.ignored;
    final crossesPreviousPage = isLeft && column == 0 && _pageIndex > 0;
    final crossesNextPage =
        isRight &&
        (column == columns - 1 || episode == lastEpisode) &&
        _pageIndex < pageCount - 1;
    if (!crossesPreviousPage && !crossesNextPage) {
      return KeyEventResult.ignored;
    }
    // Consume repeats and key-up packets at the boundary so one physical
    // press changes exactly one page on remotes with noisy repeat behavior.
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    if (crossesNextPage) {
      final nextPage = _pageIndex + 1;
      final target = nextPage * pageSize + row * columns + 1;
      _changePage(nextPage, focusEpisode: target);
    } else {
      final previousPage = _pageIndex - 1;
      final previousFirst = previousPage * pageSize + 1;
      final previousLast = math.min(
        previousFirst + pageSize - 1,
        widget.totalEpisodes,
      );
      final target = math.min(
        previousFirst + row * columns + columns - 1,
        previousLast,
      );
      _changePage(previousPage, focusEpisode: target);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = widget.embedded
        ? screen.width
        : math.min(screen.width * .94, 1800.0);
    final height = widget.embedded
        ? screen.height
        : math.min(screen.height * .96, 900.0);
    final compact = width < 700 || height < 450;
    final palette = context.appPalette;
    final columns = width < 600 ? 1 : 2;
    const rows = 3;
    final pageSize = columns * rows;
    final pageCount = (widget.totalEpisodes / pageSize).ceil();
    if (_pageSize != pageSize) {
      _pageSize = pageSize;
      _pageIndex = (_selectedEpisode - 1) ~/ pageSize;
    } else {
      _pageIndex = _pageIndex.clamp(0, pageCount - 1);
    }

    final dialog = Dialog(
      key: ValueKey(
        widget.embedded ? 'episode-browser-page' : 'episode-browser-dialog',
      ),
      insetPadding: widget.embedded
          ? EdgeInsets.zero
          : EdgeInsets.symmetric(
              horizontal: screen.width < 600 ? 10 : 24,
              vertical: screen.height < 500 ? 10 : 22,
            ),
      backgroundColor: Colors.transparent,
      child: Container(
        key: const ValueKey('episode-browser-surface'),
        width: width,
        height: height,
        padding: EdgeInsets.fromLTRB(
          compact ? 12 : 18,
          compact ? 10 : 12,
          compact ? 12 : 18,
          compact ? 10 : 12,
        ),
        decoration: widget.embedded
            ? const BoxDecoration(color: Colors.transparent)
            : TetoBoxStyle.translucentPanelDecoration(palette),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _EpisodeBrowserHeader(
              anime: widget.anime,
              selectedEpisode: _selectedEpisode,
              totalEpisodes: widget.totalEpisodes,
              compact: compact,
              now: widget.now,
              onClose: _close,
              numberControl: EpisodeNumberControl(
                episode: _selectedEpisode,
                total: widget.totalEpisodes,
                focusNode: _numberFocus,
                previousFocusNode: _previousFocus,
                nextFocusNode: _nextFocus,
                onChoose: _chooseNumber,
                onPrevious: _selectedEpisode > 1
                    ? () => _jumpTo(_selectedEpisode - 1)
                    : null,
                onNext: _selectedEpisode < widget.totalEpisodes
                    ? () => _jumpTo(_selectedEpisode + 1)
                    : null,
                onExitDown: _focusSelectedCard,
              ),
            ),
            SizedBox(height: compact ? 8 : 10),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final firstEpisode = _pageIndex * pageSize + 1;
                  final lastEpisode = math.min(
                    firstEpisode + pageSize - 1,
                    widget.totalEpisodes,
                  );
                  final horizontalGap = compact ? 8.0 : 12.0;
                  final verticalGap = compact ? 8.0 : 12.0;
                  final cardWidth =
                      (constraints.maxWidth - horizontalGap * (columns - 1)) /
                      columns;
                  final cardHeight =
                      (constraints.maxHeight - verticalGap * (rows - 1)) / rows;

                  return AnimatedSwitcher(
                    key: const ValueKey('episode-browser-page-transition'),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 120),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    // Keep the short entrance, but never paint two image-rich
                    // grids or expose outgoing focus targets at the same time.
                    layoutBuilder: (currentChild, _) =>
                        currentChild ?? const SizedBox.expand(),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: Offset(_pageMotionDirection * .035, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: GridView.builder(
                      key: ValueKey('episode-browser-page-$_pageIndex'),
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.zero,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: horizontalGap,
                        mainAxisSpacing: verticalGap,
                        childAspectRatio: cardWidth / cardHeight,
                      ),
                      itemCount: lastEpisode - firstEpisode + 1,
                      itemBuilder: (context, index) {
                        final episode = firstEpisode + index;
                        return _EpisodeBrowserCard(
                          key: ValueKey('episode-browser-card-$episode'),
                          anime: widget.anime,
                          metadata: _episodeMetadata[episode],
                          episode: episode,
                          selected: episode == _selectedEpisode,
                          availability: episodeAiringAvailability(
                            anime: widget.anime,
                            episode: episode,
                            now: widget.now,
                          ),
                          autofocus: episode == _selectedEpisode,
                          focusNode: _focusNodeForEpisode(episode),
                          compact: cardWidth < 300 || cardHeight < 175,
                          dense: cardHeight < 115,
                          artworkWidth: math.min(
                            cardWidth * .46,
                            cardHeight * 16 / 9,
                          ),
                          onKeyEvent: (_, event) => _handleEpisodeNavigation(
                            episode: episode,
                            firstEpisode: firstEpisode,
                            lastEpisode: lastEpisode,
                            columns: columns,
                            pageSize: pageSize,
                            pageCount: pageCount,
                            event: event,
                          ),
                          onPressed: () => _selectEpisode(episode),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (pageCount > 1) ...[
              SizedBox(height: compact ? 8 : 10),
              _EpisodeBrowserPagination(
                pageIndex: _pageIndex,
                pageCount: pageCount,
                compact: compact,
                onPageSelected: _changePage,
              ),
            ],
          ],
        ),
      ),
    );

    // The details screen owns the entrance/exit of the entire full-screen
    // browser, including its scrim. Avoid animating this child a second time.
    return dialog;
  }
}

class _EpisodeBrowserHeader extends StatelessWidget {
  const _EpisodeBrowserHeader({
    required this.anime,
    required this.selectedEpisode,
    required this.totalEpisodes,
    required this.compact,
    required this.now,
    required this.onClose,
    required this.numberControl,
  });

  final AnimeSummary anime;
  final int selectedEpisode;
  final int totalEpisodes;
  final bool compact;
  final DateTime? now;
  final VoidCallback onClose;
  final Widget numberControl;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final countdown = localizedNextEpisodeCountdown(context, anime, now: now);
    final nextAirDate = anime.nextAiringAt;
    return Container(
      key: const ValueKey('episode-browser-header'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 7 : 10,
      ),
      decoration: TetoBoxStyle.translucentPanelDecoration(palette),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 570;
          final heading = Row(
            children: [
              TetoBackButton(
                key: const ValueKey('episode-browser-close'),
                onPressed: onClose,
              ),
              SizedBox(width: compact ? 10 : 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.tr('Episodes'),
                      style: TextStyle(
                        color: palette.primaryText,
                        fontSize: compact ? 19 : 25,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: compact ? 3 : 4),
                    Text(
                      context.tr('{value1} of {value2} selected', {
                        'value1': selectedEpisode,
                        'value2': totalEpisodes,
                      }),
                      style: TextStyle(
                        color: palette.mutedText,
                        fontSize: compact ? 11 : 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (countdown != null) ...[
                      SizedBox(height: compact ? 2 : 4),
                      Text(
                        '${countdown[0].toUpperCase()}${countdown.substring(1)}'
                        '${nextAirDate == null ? '' : ' · ${TetoLocalizations.of(context).date(nextAirDate)}'}',
                        key: const ValueKey('episode-browser-next-airing'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.accentBright,
                          fontSize: compact ? 10 : 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!narrow) ...[
                const SizedBox(width: 16),
                SizedBox(
                  width: math.min(330, constraints.maxWidth * .45),
                  child: numberControl,
                ),
              ],
            ],
          );
          return narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [heading, const SizedBox(height: 8), numberControl],
                )
              : heading;
        },
      ),
    );
  }
}

class _EpisodeBrowserCard extends StatefulWidget {
  const _EpisodeBrowserCard({
    required this.anime,
    required this.metadata,
    required this.episode,
    required this.selected,
    required this.availability,
    required this.autofocus,
    required this.focusNode,
    required this.compact,
    required this.dense,
    required this.artworkWidth,
    required this.onKeyEvent,
    required this.onPressed,
    super.key,
  });

  final AnimeSummary anime;
  final CatalogEpisodeMetadata? metadata;
  final int episode;
  final bool selected;
  final EpisodeAiringAvailability availability;
  final bool autofocus;
  final FocusNode focusNode;
  final bool compact;
  final bool dense;
  final double artworkWidth;
  final FocusOnKeyEventCallback onKeyEvent;
  final VoidCallback onPressed;

  @override
  State<_EpisodeBrowserCard> createState() => _EpisodeBrowserCardState();
}

class _EpisodeBrowserCardState extends State<_EpisodeBrowserCard> {
  static const _descriptionScrollDelay = Duration(seconds: 3);
  static const _descriptionScrollPixelsPerSecond = 12.0;

  final ScrollController _descriptionScrollController = ScrollController();
  Timer? _descriptionScrollTimer;
  bool _focused = false;

  String get _description => widget.availability.isAvailable
      ? widget.metadata?.synopsis ?? 'Episode details unavailable.'
      : 'This episode has not aired yet.';

  @override
  void didUpdateWidget(covariant _EpisodeBrowserCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDescription = oldWidget.availability.isAvailable
        ? oldWidget.metadata?.synopsis ?? 'Episode details unavailable.'
        : 'This episode has not aired yet.';
    if (oldDescription != _description) {
      _cancelDescriptionScroll();
      _resetDescriptionScroll();
      if (_focused) _scheduleDescriptionScroll();
    }
  }

  @override
  void dispose() {
    _cancelDescriptionScroll();
    _descriptionScrollController.dispose();
    super.dispose();
  }

  void _handleFocusChanged(bool focused) {
    if (_focused == focused) return;
    _focused = focused;
    _cancelDescriptionScroll();
    _resetDescriptionScroll();
    if (focused) _scheduleDescriptionScroll();
  }

  void _scheduleDescriptionScroll() {
    _descriptionScrollTimer = Timer(_descriptionScrollDelay, () {
      if (!mounted || !_focused || !_descriptionScrollController.hasClients) {
        return;
      }
      // Respect the platform accessibility preference. The full synopsis is
      // still exposed through semantics, without forcing continuous motion.
      if (MediaQuery.disableAnimationsOf(context)) return;
      final extent = _descriptionScrollController.position.maxScrollExtent;
      if (extent <= 0) return;
      final duration = Duration(
        milliseconds: math.max(
          1500,
          (extent / _descriptionScrollPixelsPerSecond * 1000).round(),
        ),
      );
      unawaited(
        _descriptionScrollController
            .animateTo(extent, duration: duration, curve: Curves.linear)
            .catchError((Object _) {
              // A focus change or disposal intentionally cancels the scroll.
            }),
      );
    });
  }

  void _cancelDescriptionScroll() {
    _descriptionScrollTimer?.cancel();
    _descriptionScrollTimer = null;
  }

  void _resetDescriptionScroll() {
    if (_descriptionScrollController.hasClients) {
      final position = _descriptionScrollController.position;
      if (position.pixels == 0 && !position.isScrollingNotifier.value) return;
      // jumpTo also cancels an in-flight animateTo, including the brief frame
      // where the animation is active but has not moved away from zero yet.
      _descriptionScrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final expectedAt = widget.availability.expectedAt;
    final runtime =
        widget.metadata?.durationMinutes ?? widget.anime.durationMinutes;
    final episodeArtwork = widget.metadata?.thumbnailUrl;
    final artwork =
        episodeArtwork ??
        widget.anime.bannerImageUrl ??
        widget.anime.coverImageUrl;
    final usesSeriesArtwork = episodeArtwork == null && artwork != null;
    final title = widget.metadata?.title ?? context.tr('Title unavailable');
    final statusLabel = widget.availability.isAvailable
        ? null
        : expectedAt == null
        ? context.tr('UNAIRED')
        : TetoLocalizations.of(context).date(expectedAt);
    final semantics = <String>[
      'Episode ${widget.episode}, $title',
      if (runtime != null) '$runtime minutes',
      if (widget.availability.isAvailable) 'available' else 'not aired yet',
      if (expectedAt != null) 'expected ${episodeAiringDateLabel(expectedAt)}',
      if (_description.isNotEmpty) _description,
    ].join(', ');
    final descriptionMaxLines = widget.dense
        ? 1
        : widget.compact && statusLabel != null
        ? 1
        : widget.compact
        ? 2
        : 3;
    final descriptionStyle = TextStyle(
      color: palette.mutedText,
      fontSize: widget.compact ? 11 : 13,
      height: 1.25,
      fontWeight: FontWeight.w600,
    );
    final descriptionViewportHeight =
        MediaQuery.textScalerOf(context).scale(descriptionStyle.fontSize!) *
        descriptionStyle.height! *
        descriptionMaxLines;

    return Semantics(
      label: semantics,
      button: true,
      selected: widget.selected,
      excludeSemantics: true,
      child: TvFocusable(
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        focusScale: 1.018,
        borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
        onPressed: widget.onPressed,
        onKeyEvent: widget.onKeyEvent,
        onFocusChanged: _handleFocusChanged,
        child: RepaintBoundary(
          key: ValueKey('episode-browser-card-content-${widget.episode}'),
          child: Container(
            key: ValueKey('episode-browser-card-surface-${widget.episode}'),
            decoration: TetoBoxStyle.translucentControlDecoration(palette),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(TetoBoxStyle.radius - 1),
              child: Row(
                children: [
                  SizedBox(
                    width: widget.artworkWidth,
                    height: double.infinity,
                    child: ColoredBox(
                      color: palette.background,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(3),
                            child: RepaintBoundary(
                              key: ValueKey(
                                'episode-browser-artwork-${widget.episode}',
                              ),
                              child: NetworkArtwork(
                                url: artwork,
                                fit: BoxFit.contain,
                                cacheWidth:
                                    ((widget.artworkWidth *
                                                    MediaQuery.devicePixelRatioOf(
                                                      context,
                                                    ) /
                                                    64)
                                                .ceil() *
                                            64)
                                        .clamp(128, 640),
                                icon: Icons.video_library_outlined,
                              ),
                            ),
                          ),
                          if (usesSeriesArtwork)
                            Positioned(
                              left: widget.compact ? 6 : 8,
                              top: widget.compact ? 6 : 8,
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: widget.compact ? 4 : 6,
                                  vertical: widget.compact ? 2 : 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .72),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  context.tr("SERIES ART"),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: .9),
                                    fontSize: widget.compact ? 6 : 8,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: .35,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: 1,
                    height: double.infinity,
                    color: TetoBoxStyle.outline(palette),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(
                        widget.dense ? 6 : (widget.compact ? 8 : 14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  context.tr("Episode {value1}{value2}", {
                                    'value1': widget.episode,
                                    'value2': runtime == null
                                        ? ''
                                        : ' · $runtime min',
                                  }),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: palette.accentBright,
                                    fontSize: widget.compact ? 11 : 13,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: .5,
                                  ),
                                ),
                              ),
                              if (widget.selected) ...[
                                const SizedBox(width: 6),
                                Container(
                                  key: ValueKey(
                                    'episode-browser-selected-${widget.episode}',
                                  ),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: widget.compact ? 3 : 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.background.withValues(
                                      alpha: .66,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: palette.accentBright.withValues(
                                        alpha: .55,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.check_rounded,
                                        color: palette.accentBright,
                                        size: widget.compact ? 12 : 14,
                                      ),
                                      if (!widget.compact) ...[
                                        const SizedBox(width: 3),
                                        Text(
                                          context.tr('Selected'),
                                          style: TextStyle(
                                            color: palette.primaryText,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                          SizedBox(
                            height: widget.dense ? 2 : (widget.compact ? 3 : 6),
                          ),
                          Text(
                            title,
                            key: ValueKey(
                              'episode-browser-title-${widget.episode}',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.primaryText,
                              fontSize: widget.compact ? 13 : 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          SizedBox(
                            height: widget.dense ? 2 : (widget.compact ? 4 : 7),
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: descriptionViewportHeight,
                            ),
                            child: ClipRect(
                              child: ScrollConfiguration(
                                behavior: ScrollConfiguration.of(context)
                                    .copyWith(
                                      scrollbars: false,
                                      overscroll: false,
                                    ),
                                child: SingleChildScrollView(
                                  key: ValueKey(
                                    'episode-browser-description-scroll-${widget.episode}',
                                  ),
                                  controller: _descriptionScrollController,
                                  physics: const NeverScrollableScrollPhysics(),
                                  child: Text(
                                    _description,
                                    key: ValueKey(
                                      'episode-browser-description-${widget.episode}',
                                    ),
                                    style: descriptionStyle,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (statusLabel != null) ...[
                            SizedBox(
                              height: widget.dense
                                  ? 2
                                  : (widget.compact ? 4 : 7),
                            ),
                            _EpisodeCardBadge(
                              label: statusLabel,
                              compact: widget.compact,
                            ),
                          ],
                        ],
                      ),
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

class _EpisodeCardBadge extends StatelessWidget {
  const _EpisodeCardBadge({required this.label, required this.compact});

  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 7,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: palette.accentBright.withValues(alpha: .56)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: palette.accentBright,
          fontSize: compact ? 8 : 9,
          height: 1,
          fontWeight: FontWeight.w900,
          letterSpacing: .5,
        ),
      ),
    );
  }
}

class _EpisodeBrowserPagination extends StatelessWidget {
  const _EpisodeBrowserPagination({
    required this.pageIndex,
    required this.pageCount,
    required this.compact,
    required this.onPageSelected,
  });

  final int pageIndex;
  final int pageCount;
  final bool compact;
  final ValueChanged<int> onPageSelected;

  @override
  Widget build(BuildContext context) {
    final visiblePages = _visibleEpisodeBrowserPages(
      pageIndex: pageIndex,
      pageCount: pageCount,
      compact: compact,
    );
    return Container(
      key: const ValueKey('episode-browser-pagination'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 16,
        vertical: compact ? 4 : 5,
      ),
      decoration: TetoBoxStyle.translucentPanelDecoration(context.appPalette),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _EpisodePageButton(
            key: const ValueKey('episode-browser-previous-page'),
            label: compact ? '' : 'Previous',
            semanticLabel: 'Previous page',
            icon: Icons.chevron_left_rounded,
            enabled: pageIndex > 0,
            compact: compact,
            onPressed: () => onPageSelected(pageIndex - 1),
          ),
          SizedBox(width: compact ? 6 : 10),
          for (var index = 0; index < visiblePages.length; index++) ...[
            if (index > 0) SizedBox(width: compact ? 5 : 7),
            if (visiblePages[index] case final page?)
              _EpisodePageButton(
                key: ValueKey('episode-browser-page-button-$page'),
                label: '${page + 1}',
                selected: page == pageIndex,
                compact: compact,
                onPressed: () => onPageSelected(page),
              )
            else
              Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 1 : 3),
                child: Text(
                  '…',
                  key: ValueKey('episode-browser-page-ellipsis-$index'),
                  style: TextStyle(
                    color: context.appPalette.mutedText,
                    fontSize: compact ? 14 : 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
          ],
          SizedBox(width: compact ? 6 : 10),
          _EpisodePageButton(
            key: const ValueKey('episode-browser-next-page'),
            label: compact ? '' : 'Next',
            semanticLabel: 'Next page',
            icon: Icons.chevron_right_rounded,
            iconAfter: true,
            enabled: pageIndex < pageCount - 1,
            compact: compact,
            onPressed: () => onPageSelected(pageIndex + 1),
          ),
        ],
      ),
    );
  }
}

List<int?> _visibleEpisodeBrowserPages({
  required int pageIndex,
  required int pageCount,
  required bool compact,
}) {
  if (pageCount <= (compact ? 5 : 7)) {
    return <int?>[for (var page = 0; page < pageCount; page++) page];
  }

  final pages = <int>{0, pageCount - 1};
  final radius = compact ? 1 : 2;
  for (var page = pageIndex - radius; page <= pageIndex + radius; page++) {
    if (page >= 0 && page < pageCount) pages.add(page);
  }
  final leadingFill = compact ? 1 : 3;
  if (pageIndex <= leadingFill) {
    for (var page = 0; page <= leadingFill; page++) {
      pages.add(page);
    }
  }
  if (pageIndex >= pageCount - leadingFill - 1) {
    for (var page = pageCount - leadingFill - 1; page < pageCount; page++) {
      pages.add(page);
    }
  }

  final sorted = pages.toList()..sort();
  final result = <int?>[];
  for (final page in sorted) {
    if (result.isNotEmpty && page - result.last! > 1) result.add(null);
    result.add(page);
  }
  return result;
}

class _EpisodePageButton extends StatelessWidget {
  const _EpisodePageButton({
    required this.label,
    required this.compact,
    required this.onPressed,
    this.icon,
    this.semanticLabel,
    this.iconAfter = false,
    this.enabled = true,
    this.selected = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final String? semanticLabel;
  final bool iconAfter;
  final bool compact;
  final bool enabled;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final content = Container(
      key: ValueKey('episode-page-surface-$label'),
      height: compact ? 34 : 36,
      constraints: BoxConstraints(minWidth: compact ? 34 : 40),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
      alignment: Alignment.center,
      decoration: TetoBoxStyle.translucentControlDecoration(palette).copyWith(
        border: selected
            ? Border.all(color: palette.accentBright, width: 1.4)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null && !iconAfter) Icon(icon, size: compact ? 17 : 20),
          if (icon != null && !iconAfter) const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: selected ? palette.accentBright : palette.primaryText,
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (icon != null && iconAfter) const SizedBox(width: 3),
          if (icon != null && iconAfter) Icon(icon, size: compact ? 17 : 20),
        ],
      ),
    );
    final control = !enabled
        ? Opacity(opacity: .34, child: content)
        : TvFocusable(
            onPressed: onPressed,
            focusScale: 1.025,
            borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
            child: content,
          );
    if (semanticLabel == null) return control;
    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      child: control,
    );
  }
}
