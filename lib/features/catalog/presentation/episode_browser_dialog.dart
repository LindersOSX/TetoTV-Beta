import 'dart:math' as math;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/network_artwork.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/episode_airing_availability.dart';
import 'package:flutter/material.dart';

Future<int?> showEpisodeBrowserDialog(
  BuildContext context, {
  required AnimeSummary anime,
  required int selectedEpisode,
  required int totalEpisodes,
}) {
  return showDialog<int>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .72),
    builder: (_) => EpisodeBrowserDialog(
      anime: anime,
      selectedEpisode: selectedEpisode,
      totalEpisodes: totalEpisodes,
    ),
  );
}

/// A paged episode browser designed for TV remotes and compact screens.
///
/// The catalog currently exposes only series-level artwork and runtime. Cards
/// use those values as honest fallbacks and explicitly say when an episode
/// synopsis is unavailable instead of presenting the series synopsis as
/// episode-specific metadata.
class EpisodeBrowserDialog extends StatefulWidget {
  const EpisodeBrowserDialog({
    required this.anime,
    required this.selectedEpisode,
    required this.totalEpisodes,
    this.now,
    super.key,
  }) : assert(totalEpisodes > 0),
       assert(selectedEpisode > 0 && selectedEpisode <= totalEpisodes);

  final AnimeSummary anime;
  final int selectedEpisode;
  final int totalEpisodes;
  final DateTime? now;

  @override
  State<EpisodeBrowserDialog> createState() => _EpisodeBrowserDialogState();
}

class _EpisodeBrowserDialogState extends State<EpisodeBrowserDialog> {
  final Map<int, FocusNode> _episodeFocusNodes = <int, FocusNode>{};
  int _pageIndex = 0;
  int? _pageSize;

  FocusNode _focusNodeForEpisode(int episode) => _episodeFocusNodes.putIfAbsent(
    episode,
    () => FocusNode(debugLabel: 'episode-browser.$episode'),
  );

  @override
  void dispose() {
    for (final node in _episodeFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _changePage(int page, {bool focusFirstEpisode = true}) {
    final pageSize = _pageSize;
    if (pageSize == null) return;
    final pageCount = (widget.totalEpisodes / pageSize).ceil();
    final nextPage = page.clamp(0, pageCount - 1);
    if (nextPage == _pageIndex) return;
    setState(() => _pageIndex = nextPage);
    if (!focusFirstEpisode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final firstEpisode = nextPage * pageSize + 1;
      final node = _focusNodeForEpisode(firstEpisode);
      if (node.canRequestFocus && node.context != null) node.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(screen.width * .94, 1800.0);
    final height = math.min(screen.height * .88, 900.0);
    final compact = width < 700 || height < 450;
    final palette = context.appPalette;
    final gridDimension = width >= 1450 && height >= 760
        ? 4
        : width >= 1050 && height >= 590
        ? 3
        : width >= 650 && height >= 430
        ? 2
        : 1;
    final pageSize = gridDimension * gridDimension;
    final pageCount = (widget.totalEpisodes / pageSize).ceil();
    if (_pageSize != pageSize) {
      _pageSize = pageSize;
      _pageIndex = (widget.selectedEpisode - 1) ~/ pageSize;
    } else {
      _pageIndex = _pageIndex.clamp(0, pageCount - 1);
    }

    return Dialog(
      key: const ValueKey('episode-browser-dialog'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: screen.width < 600 ? 10 : 24,
        vertical: screen.height < 500 ? 10 : 22,
      ),
      backgroundColor: Colors.transparent,
      child: Container(
        width: width,
        height: height,
        padding: EdgeInsets.fromLTRB(
          compact ? 14 : 22,
          compact ? 12 : 18,
          compact ? 14 : 22,
          compact ? 12 : 16,
        ),
        decoration: BoxDecoration(
          color: palette.surface.withValues(alpha: .98),
          borderRadius: BorderRadius.circular(compact ? 16 : 22),
          border: Border.all(
            color: palette.accentBright.withValues(alpha: .70),
            width: 1.4,
          ),
          boxShadow: [
            BoxShadow(
              color: palette.focusGlow.withValues(alpha: .32),
              blurRadius: 32,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _EpisodeBrowserHeader(
              selectedEpisode: widget.selectedEpisode,
              totalEpisodes: widget.totalEpisodes,
              compact: compact,
              onClose: () => Navigator.pop(context),
            ),
            SizedBox(height: compact ? 10 : 16),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = gridDimension;
                  final rows = gridDimension;
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

                  return GridView.builder(
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
                        episode: episode,
                        selected: episode == widget.selectedEpisode,
                        availability: episodeAiringAvailability(
                          anime: widget.anime,
                          episode: episode,
                          now: widget.now,
                        ),
                        autofocus: episode == widget.selectedEpisode,
                        focusNode: _focusNodeForEpisode(episode),
                        compact: cardHeight < 175,
                        onPressed: () => Navigator.pop(context, episode),
                      );
                    },
                  );
                },
              ),
            ),
            if (pageCount > 1) ...[
              SizedBox(height: compact ? 10 : 15),
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
  }
}

class _EpisodeBrowserHeader extends StatelessWidget {
  const _EpisodeBrowserHeader({
    required this.selectedEpisode,
    required this.totalEpisodes,
    required this.compact,
    required this.onClose,
  });

  final int selectedEpisode;
  final int totalEpisodes;
  final bool compact;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Row(
      children: [
        Container(
          width: compact ? 4 : 5,
          height: compact ? 32 : 42,
          decoration: BoxDecoration(
            color: palette.accentBright,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        SizedBox(width: compact ? 10 : 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Episodes',
                style: TextStyle(
                  color: palette.primaryText,
                  fontSize: compact ? 20 : 28,
                  height: 1,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: compact ? 3 : 5),
              Text(
                '$selectedEpisode of $totalEpisodes selected',
                style: TextStyle(
                  color: palette.mutedText,
                  fontSize: compact ? 11 : 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        TvFocusable(
          onPressed: onClose,
          focusScale: 1.02,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            key: const ValueKey('episode-browser-close'),
            width: compact ? 42 : 50,
            height: compact ? 36 : 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: palette.primaryText.withValues(alpha: .14),
              ),
            ),
            child: Icon(Icons.close_rounded, size: compact ? 20 : 24),
          ),
        ),
      ],
    );
  }
}

class _EpisodeBrowserCard extends StatelessWidget {
  const _EpisodeBrowserCard({
    required this.anime,
    required this.episode,
    required this.selected,
    required this.availability,
    required this.autofocus,
    required this.focusNode,
    required this.compact,
    required this.onPressed,
    super.key,
  });

  final AnimeSummary anime;
  final int episode;
  final bool selected;
  final EpisodeAiringAvailability availability;
  final bool autofocus;
  final FocusNode focusNode;
  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final expectedAt = availability.expectedAt;
    final runtime = anime.durationMinutes;
    final artwork = anime.bannerImageUrl ?? anime.coverImageUrl;
    final statusLabel = availability.isAvailable
        ? null
        : expectedAt == null
        ? 'UNAIRED'
        : episodeAiringDateLabel(expectedAt);
    final semantics = <String>[
      'Episode $episode',
      if (runtime != null) '$runtime minutes',
      if (availability.isAvailable) 'available' else 'not aired yet',
      if (expectedAt != null) 'expected ${episodeAiringDateLabel(expectedAt)}',
    ].join(', ');

    return Semantics(
      label: semantics,
      button: true,
      selected: selected,
      excludeSemantics: true,
      child: TvFocusable(
        autofocus: autofocus,
        focusNode: focusNode,
        focusScale: 1.018,
        borderRadius: BorderRadius.circular(compact ? 11 : 14),
        onPressed: onPressed,
        child: Container(
          decoration: BoxDecoration(
            color: palette.surfaceRaised,
            borderRadius: BorderRadius.circular(compact ? 11 : 14),
            border: Border.all(
              color: selected
                  ? palette.accentBright.withValues(alpha: .82)
                  : palette.primaryText.withValues(alpha: .13),
              width: selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(compact ? 10 : 13),
            child: Row(
              children: [
                SizedBox(
                  width: compact ? 112 : 154,
                  height: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NetworkArtwork(
                        url: artwork,
                        cacheWidth: compact ? 260 : 380,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, Color(0xA6000000)],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                      Positioned(
                        left: compact ? 8 : 10,
                        bottom: compact ? 7 : 9,
                        child: Text(
                          'EP $episode',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: compact ? 11 : 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(compact ? 9 : 13),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Episode $episode',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.primaryText,
                                  fontSize: compact ? 13 : 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            if (selected)
                              _EpisodeCardBadge(
                                label: 'SELECTED',
                                compact: compact,
                                emphasized: true,
                              ),
                          ],
                        ),
                        SizedBox(height: compact ? 4 : 7),
                        Text(
                          runtime == null
                              ? 'Runtime unavailable'
                              : '$runtime min',
                          style: TextStyle(
                            color: palette.accentBright,
                            fontSize: compact ? 10 : 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: compact ? 4 : 7),
                        Text(
                          availability.isAvailable
                              ? 'Episode synopsis unavailable.'
                              : 'This episode has not aired yet.',
                          maxLines: compact ? 2 : 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.mutedText,
                            fontSize: compact ? 10 : 12,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (statusLabel != null) ...[
                          SizedBox(height: compact ? 4 : 7),
                          _EpisodeCardBadge(
                            label: statusLabel,
                            compact: compact,
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
    );
  }
}

class _EpisodeCardBadge extends StatelessWidget {
  const _EpisodeCardBadge({
    required this.label,
    required this.compact,
    this.emphasized = false,
  });

  final String label;
  final bool compact;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 7,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: emphasized
            ? palette.accent.withValues(alpha: .38)
            : palette.accent.withValues(alpha: .18),
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
    return Row(
      key: const ValueKey('episode-browser-pagination'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _EpisodePageButton(
          key: const ValueKey('episode-browser-previous-page'),
          label: 'Previous',
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
          label: 'Next',
          icon: Icons.chevron_right_rounded,
          iconAfter: true,
          enabled: pageIndex < pageCount - 1,
          compact: compact,
          onPressed: () => onPageSelected(pageIndex + 1),
        ),
      ],
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
    this.iconAfter = false,
    this.enabled = true,
    this.selected = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final bool iconAfter;
  final bool compact;
  final bool enabled;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final content = Container(
      height: compact ? 34 : 40,
      constraints: BoxConstraints(minWidth: compact ? 34 : 40),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected
            ? palette.accent.withValues(alpha: .60)
            : palette.surfaceRaised,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: selected
              ? palette.accentBright
              : palette.primaryText.withValues(alpha: .13),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null && !iconAfter) Icon(icon, size: compact ? 17 : 20),
          if (icon != null && !iconAfter) const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              color: palette.primaryText,
              fontSize: compact ? 10 : 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (icon != null && iconAfter) const SizedBox(width: 3),
          if (icon != null && iconAfter) Icon(icon, size: compact ? 17 : 20),
        ],
      ),
    );
    if (!enabled) return Opacity(opacity: .34, child: content);
    return TvFocusable(
      onPressed: onPressed,
      focusScale: 1.025,
      borderRadius: BorderRadius.circular(9),
      child: content,
    );
  }
}
