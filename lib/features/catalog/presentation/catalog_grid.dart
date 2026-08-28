import 'dart:async';

import 'package:anime_tv/core/layout/poster_card_geometry.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_shelf_focus.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/core/widgets/poster_metadata_overlay.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

class CatalogGrid extends StatefulWidget {
  const CatalogGrid({
    required this.items,
    required this.titlePreference,
    this.autofocus = true,
    this.firstFocusNode,
    this.onNavigateLeftFromFirstColumn,
    this.onNavigateUpFromFirstRow,
    this.onLongPress,
    super.key,
  });

  final List<AnimeSummary> items;
  final TitleLanguagePreference titlePreference;
  final bool autofocus;
  final FocusNode? firstFocusNode;
  final VoidCallback? onNavigateLeftFromFirstColumn;
  final VoidCallback? onNavigateUpFromFirstRow;
  final ValueChanged<AnimeSummary>? onLongPress;

  @override
  State<CatalogGrid> createState() => _CatalogGridState();
}

class _CatalogGridState extends State<CatalogGrid> {
  static const _maximumCardWidth = defaultPosterMaximumWidth;
  static const _crossAxisSpacing = defaultPosterSpacing;
  static const _mainAxisSpacing = 14.0;
  static const _gridPadding = EdgeInsets.fromLTRB(4, 8, 4, 28);

  List<FocusNode> _focusNodes = [];
  List<FocusNode> _renderedFocusNodes = [];
  List<({int mediaId, int occurrence})> _itemIdentities = [];
  final ScrollController _scrollController = ScrollController();
  final TvDirectionalRepeatGate _repeatGate = TvDirectionalRepeatGate();
  ({int mediaId, int occurrence})? _pendingFocusIdentity;
  int _focusRequestGeneration = 0;
  int _lastFocusedIndex = 0;
  ({int mediaId, int occurrence})? _lastFocusedIdentity;
  int _currentCrossAxisCount = 1;
  double _currentCardMainAxisExtent = 0;

  @override
  void initState() {
    super.initState();
    _ensureFocusNodes();
  }

  @override
  void didUpdateWidget(CatalogGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureFocusNodes();
  }

  void _ensureFocusNodes() {
    final occurrenceByMediaId = <int, int>{};
    final nextIdentities = <({int mediaId, int occurrence})>[
      for (final item in widget.items)
        (
          mediaId: item.id,
          occurrence: occurrenceByMediaId.update(
            item.id,
            (value) => value + 1,
            ifAbsent: () => 0,
          ),
        ),
    ];
    final orderChanged =
        nextIdentities.length != _itemIdentities.length ||
        Iterable<int>.generate(
          nextIdentities.length,
        ).any((index) => nextIdentities[index] != _itemIdentities[index]);
    final previousPrimaryFocus = FocusManager.instance.primaryFocus;
    int? previouslyFocusedIndex;
    for (var index = 0; index < _renderedFocusNodes.length; index++) {
      final node = _renderedFocusNodes[index];
      if (node.hasFocus || identical(previousPrimaryFocus, node)) {
        previouslyFocusedIndex = index;
        break;
      }
    }
    final previouslyFocusedIdentity = previouslyFocusedIndex == null
        ? null
        : _itemIdentities[previouslyFocusedIndex];
    final previouslyFocusedNode = previouslyFocusedIndex == null
        ? null
        : _renderedFocusNodes[previouslyFocusedIndex];

    final oldNodesByIdentity = <({int mediaId, int occurrence}), FocusNode>{
      for (var index = 0; index < _itemIdentities.length; index++)
        _itemIdentities[index]: _focusNodes[index],
    };
    final nextFocusNodes = <FocusNode>[
      for (var index = 0; index < nextIdentities.length; index++)
        oldNodesByIdentity.remove(nextIdentities[index]) ??
            FocusNode(debugLabel: 'catalog.result.$index'),
    ];
    for (var index = 0; index < nextFocusNodes.length; index++) {
      nextFocusNodes[index].debugLabel = 'catalog.result.$index';
    }
    final nextRenderedFocusNodes = <FocusNode>[
      for (var index = 0; index < nextFocusNodes.length; index++)
        if (index == 0 && widget.firstFocusNode != null)
          widget.firstFocusNode!
        else
          nextFocusNodes[index],
    ];
    final renderedNodeChanged =
        nextRenderedFocusNodes.length != _renderedFocusNodes.length ||
        Iterable<int>.generate(nextRenderedFocusNodes.length).any(
          (index) => !identical(
            nextRenderedFocusNodes[index],
            _renderedFocusNodes[index],
          ),
        );
    if (orderChanged || renderedNodeChanged) {
      _focusRequestGeneration++;
      _pendingFocusIdentity = null;
    }

    _itemIdentities = nextIdentities;
    _focusNodes = nextFocusNodes;
    _renderedFocusNodes = nextRenderedFocusNodes;
    for (final node in oldNodesByIdentity.values) {
      node.dispose();
    }

    if (widget.items.isEmpty) {
      _lastFocusedIndex = 0;
      _lastFocusedIdentity = null;
    } else {
      final rememberedIndex = _lastFocusedIdentity == null
          ? -1
          : _itemIdentities.indexOf(_lastFocusedIdentity!);
      _lastFocusedIndex = rememberedIndex >= 0
          ? rememberedIndex
          : _lastFocusedIndex.clamp(0, widget.items.length - 1);
      _lastFocusedIdentity = _itemIdentities[_lastFocusedIndex];
    }

    if (previouslyFocusedIndex != null && widget.items.isNotEmpty) {
      final survivingIndex = previouslyFocusedIdentity == null
          ? -1
          : _itemIdentities.indexOf(previouslyFocusedIdentity);
      final recoveryIndex = survivingIndex >= 0
          ? survivingIndex
          : previouslyFocusedIndex.clamp(0, widget.items.length - 1);
      final recoveryNode = _renderedFocusNodes[recoveryIndex];
      if (!identical(recoveryNode, previouslyFocusedNode)) {
        _scheduleFocusRecovery(
          index: recoveryIndex,
          towardEnd: recoveryIndex >= previouslyFocusedIndex,
          generation: _focusRequestGeneration,
          previousPrimaryFocus: previousPrimaryFocus,
        );
      }
    }
  }

  void _scheduleFocusRecovery({
    required int index,
    required bool towardEnd,
    required int generation,
    required FocusNode? previousPrimaryFocus,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _focusRequestGeneration) return;
      if (index < 0 || index >= _renderedFocusNodes.length) return;
      final target = _renderedFocusNodes[index];
      if (target.hasFocus) return;
      final currentPrimaryFocus = FocusManager.instance.primaryFocus;
      final focusMovedElsewhere =
          currentPrimaryFocus != null &&
          !identical(currentPrimaryFocus, previousPrimaryFocus) &&
          currentPrimaryFocus.context != null &&
          currentPrimaryFocus is! FocusScopeNode;
      if (focusMovedElsewhere) return;
      if (target.context != null) {
        target.requestFocus();
      } else if (_currentCardMainAxisExtent > 0) {
        _focusAndReveal(
          index,
          towardEnd: towardEnd,
          crossAxisCount: _currentCrossAxisCount,
          cardMainAxisExtent: _currentCardMainAxisExtent,
        );
      }
    });
  }

  FocusNode _focusNodeAt(int index) {
    return _renderedFocusNodes[index];
  }

  KeyEventResult _handleCardKey({
    required int index,
    required int crossAxisCount,
    required double cardMainAxisExtent,
    required KeyEvent event,
  }) {
    final key = event.logicalKey;
    final directional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!directional) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      _repeatGate.accept(event);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (!_repeatGate.accept(event)) {
      // Always consume throttled repeats. Falling through would let the global
      // geometric policy perform an extra move behind the explicit grid.
      return KeyEventResult.handled;
    }
    if (widget.items.isEmpty) {
      return KeyEventResult.ignored;
    }

    final pendingIndex = _pendingFocusIdentity == null
        ? -1
        : _itemIdentities.indexOf(_pendingFocusIdentity!);
    final originIndex = pendingIndex >= 0 ? pendingIndex : index;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final right = key == LogicalKeyboardKey.arrowRight;
      final visualDelta = Directionality.of(context) == TextDirection.rtl
          ? (right ? -1 : 1)
          : (right ? 1 : -1);
      final column = originIndex % crossAxisCount;
      final targetColumn = column + visualDelta;
      final targetIndex = originIndex + visualDelta;
      if (targetColumn >= 0 &&
          targetColumn < crossAxisCount &&
          targetIndex >= 0 &&
          targetIndex < widget.items.length) {
        _focusAndReveal(
          targetIndex,
          towardEnd: visualDelta > 0,
          crossAxisCount: crossAxisCount,
          cardMainAxisExtent: cardMainAxisExtent,
        );
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        // A top-level TV destination can expose its rail as the physical
        // LEFT escape target without giving up this grid's explicit row math.
        widget.onNavigateLeftFromFirstColumn?.call();
      }
      // A horizontal edge is still handled. Letting the global geometric
      // policy search beyond the row can move focus into the header (or out
      // of a lazily built grid), which makes the selected-card ring vanish.
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      if (originIndex < crossAxisCount) {
        final navigateUp = widget.onNavigateUpFromFirstRow;
        if (navigateUp == null) return KeyEventResult.ignored;
        // Cancel any lazy reveal that is still completing before handing focus
        // to the header. Otherwise its post-frame callback can steal focus
        // back into the grid after a rapid series of Up presses.
        _focusRequestGeneration++;
        _pendingFocusIdentity = null;
        navigateUp();
      } else {
        _focusAndReveal(
          originIndex - crossAxisCount,
          towardEnd: false,
          crossAxisCount: crossAxisCount,
          cardMainAxisExtent: cardMainAxisExtent,
        );
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      final targetIndex = originIndex + crossAxisCount;
      if (targetIndex < widget.items.length) {
        _focusAndReveal(
          targetIndex,
          towardEnd: true,
          crossAxisCount: crossAxisCount,
          cardMainAxisExtent: cardMainAxisExtent,
        );
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _openDetails(
    AnimeSummary anime, {
    required int index,
    required int crossAxisCount,
    required double cardMainAxisExtent,
  }) async {
    _lastFocusedIndex = index;
    _lastFocusedIdentity = _itemIdentities[index];
    await context.push('/anime/${anime.id}');
    if (!mounted || widget.items.isEmpty) return;
    final identityIndex = _lastFocusedIdentity == null
        ? -1
        : _itemIdentities.indexOf(_lastFocusedIdentity!);
    final restoreIndex = identityIndex >= 0
        ? identityIndex
        : _lastFocusedIndex.clamp(0, widget.items.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusAndReveal(
        restoreIndex,
        towardEnd: false,
        crossAxisCount: crossAxisCount,
        cardMainAxisExtent: cardMainAxisExtent,
      );
    });
  }

  void _focusAndReveal(
    int index, {
    required bool towardEnd,
    required int crossAxisCount,
    required double cardMainAxisExtent,
  }) {
    if (index < 0 || index >= _itemIdentities.length) return;
    final generation = ++_focusRequestGeneration;
    final node = _focusNodeAt(index);
    final identity = _itemIdentities[index];
    _pendingFocusIdentity = identity;
    if (!_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _focusRequestGeneration) return;
        _focusAndReveal(
          index,
          towardEnd: towardEnd,
          crossAxisCount: crossAxisCount,
          cardMainAxisExtent: cardMainAxisExtent,
        );
      });
      return;
    }

    final position = _scrollController.position;
    final row = index ~/ crossAxisCount;
    final rowTop =
        _gridPadding.top + row * (cardMainAxisExtent + _mainAxisSpacing);
    final rowBottom = rowTop + cardMainAxisExtent;
    final viewportTop = position.pixels;
    final viewportBottom = viewportTop + position.viewportDimension;
    final attached = node.context != null && node.parent != null;
    if (attached) {
      _pendingFocusIdentity = null;
      node.requestFocus();
      var attachedOffset = viewportTop;
      if (rowTop < viewportTop + 6) {
        attachedOffset = rowTop - 6;
      } else if (rowBottom > viewportBottom - 6) {
        attachedOffset = rowBottom - position.viewportDimension + 6;
      }
      attachedOffset = attachedOffset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((position.pixels - attachedOffset).abs() >= 1) {
        unawaited(
          position.animateTo(
            attachedOffset,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      return;
    }
    var requestedOffset = viewportTop;
    if (rowTop < viewportTop + 6) {
      requestedOffset = rowTop - 6;
    } else if (rowBottom > viewportBottom - 6) {
      requestedOffset = rowBottom - position.viewportDimension + 6;
    } else if (node.context == null) {
      // The row lies on a cache boundary but is not attached yet. Nudge it to
      // the directional viewport edge so GridView builds it before focus.
      requestedOffset = towardEnd
          ? rowBottom - position.viewportDimension + 6
          : rowTop - 6;
    }
    final offset = requestedOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final reveal = (position.pixels - offset).abs() < 1
        ? Future<void>.value()
        : position.animateTo(
            offset,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
          );
    unawaited(
      reveal.whenComplete(() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || generation != _focusRequestGeneration) return;
          final currentIndex = _itemIdentities.indexOf(identity);
          if (currentIndex < 0) return;
          _pendingFocusIdentity = null;
          final currentNode = _focusNodeAt(currentIndex);
          if (currentNode.context != null) currentNode.requestFocus();
        });
      }),
    );
  }

  @override
  void dispose() {
    _repeatGate.reset();
    _scrollController.dispose();
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth = (constraints.maxWidth - _gridPadding.horizontal)
            .clamp(0.0, double.infinity);
        // Keep keyboard row math byte-for-byte equivalent to Flutter's
        // SliverGridDelegateWithMaxCrossAxisExtent.getLayout formula. Adding
        // spacing to the numerator changes columns too early at boundary
        // widths (for example, 151..160 px would be treated as two columns
        // here while the sliver still lays out one), so Down/Up would target
        // a card in a different visual row.
        final calculatedCrossAxisCount =
            (gridWidth / (_maximumCardWidth + _crossAxisSpacing)).ceil();
        final crossAxisCount = calculatedCrossAxisCount < 1
            ? 1
            : calculatedCrossAxisCount;
        final cardCrossAxisExtent =
            (gridWidth - _crossAxisSpacing * (crossAxisCount - 1)) /
            crossAxisCount;
        final cardMainAxisExtent =
            cardCrossAxisExtent / defaultPosterAspectRatio;
        _currentCrossAxisCount = crossAxisCount;
        _currentCardMainAxisExtent = cardMainAxisExtent;
        return GridView.builder(
          controller: _scrollController,
          padding: _gridPadding,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _maximumCardWidth,
            childAspectRatio: defaultPosterAspectRatio,
            crossAxisSpacing: _crossAxisSpacing,
            mainAxisSpacing: _mainAxisSpacing,
          ),
          itemCount: widget.items.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<({int mediaId, int occurrence})>) {
              return null;
            }
            final index = _itemIdentities.indexOf(key.value);
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) {
            final anime = widget.items[index];
            return TvFocusable(
              key: ValueKey(_itemIdentities[index]),
              focusNode: _focusNodeAt(index),
              autofocus: widget.autofocus && index == 0,
              onFocusChanged: (focused) {
                if (focused) {
                  _lastFocusedIndex = index;
                  _lastFocusedIdentity = _itemIdentities[index];
                }
              },
              onKeyEvent: (_, event) => _handleCardKey(
                index: index,
                crossAxisCount: crossAxisCount,
                cardMainAxisExtent: cardMainAxisExtent,
                event: event,
              ),
              onPressed: () => unawaited(
                _openDetails(
                  anime,
                  index: index,
                  crossAxisCount: crossAxisCount,
                  cardMainAxisExtent: cardMainAxisExtent,
                ),
              ),
              onLongPress: widget.onLongPress == null
                  ? null
                  : () => widget.onLongPress!(anime),
              focusScale: 1.035,
              borderRadius: BorderRadius.circular(7),
              child: ColoredBox(
                color: Colors.black,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            NetworkArtwork(
                              url: anime.coverImageUrl,
                              cacheWidth: 260,
                            ),
                            if (animeAiringStatusLabel(anime.status) != null)
                              Positioned(
                                left: 5,
                                top: 5,
                                child: PosterAiringStatusBadge(
                                  status: anime.status,
                                ),
                              ),
                            Positioned(
                              left: 5,
                              right: 5,
                              bottom: 5,
                              child: PosterMetadataOverlay(
                                score: anime.score,
                                releaseYear: anime.seasonYear,
                                durationMinutes: anime.durationMinutes,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      // TvFocusable paints a 3 px focus ring plus an inner
                      // keyline over the card. Keep title glyphs clear of it
                      // on every edge instead of letting the red ring cover
                      // the first letter or second-line descenders.
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Text(
                        anime.displayTitle(widget.titlePreference),
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
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
