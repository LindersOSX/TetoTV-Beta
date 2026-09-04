import 'dart:async';
import 'dart:math' as math;

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:flutter/material.dart';

const playerPausedMetadataScrollDelay = Duration(seconds: 5);
const _playerPausedMetadataScrollPixelsPerSecond = 13.0;

/// Episode context shown above the transport controls while playback is
/// paused. The synopsis is clipped to three lines and scrolls only when its
/// full text does not fit in that viewport.
class PlayerPausedMetadataOverlay extends StatefulWidget {
  const PlayerPausedMetadataOverlay({
    required this.visible,
    required this.episodeTitle,
    required this.description,
    super.key,
  });

  final bool visible;
  final String episodeTitle;
  final String description;

  @override
  State<PlayerPausedMetadataOverlay> createState() =>
      _PlayerPausedMetadataOverlayState();
}

class _PlayerPausedMetadataOverlayState
    extends State<PlayerPausedMetadataOverlay> {
  final ScrollController _descriptionController = ScrollController();
  Timer? _descriptionScrollTimer;

  bool get _canShow =>
      widget.visible &&
      (widget.episodeTitle.isNotEmpty || widget.description.isNotEmpty);

  @override
  void initState() {
    super.initState();
    if (_canShow) _scheduleDescriptionScroll();
  }

  @override
  void didUpdateWidget(covariant PlayerPausedMetadataOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final contentChanged =
        oldWidget.episodeTitle != widget.episodeTitle ||
        oldWidget.description != widget.description;
    final visibilityChanged = oldWidget.visible != widget.visible;
    if (!contentChanged && !visibilityChanged) return;
    _cancelDescriptionScroll();
    _resetDescriptionScroll();
    if (_canShow) _scheduleDescriptionScroll();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_canShow) return;
    _cancelDescriptionScroll();
    _resetDescriptionScroll();
    _scheduleDescriptionScroll();
  }

  @override
  void dispose() {
    _cancelDescriptionScroll();
    _descriptionController.dispose();
    super.dispose();
  }

  void _scheduleDescriptionScroll() {
    if (widget.description.isEmpty) return;
    _descriptionScrollTimer = Timer(playerPausedMetadataScrollDelay, () {
      if (!mounted || !_canShow || !_descriptionController.hasClients) return;
      if (MediaQuery.disableAnimationsOf(context)) return;
      final extent = _descriptionController.position.maxScrollExtent;
      if (extent <= 0) return;
      final duration = Duration(
        milliseconds: math.max(
          1500,
          (extent / _playerPausedMetadataScrollPixelsPerSecond * 1000).round(),
        ),
      );
      unawaited(
        _descriptionController
            .animateTo(extent, duration: duration, curve: Curves.linear)
            .catchError((Object _) {
              // Hiding the HUD or leaving playback intentionally cancels it.
            }),
      );
    });
  }

  void _cancelDescriptionScroll() {
    _descriptionScrollTimer?.cancel();
    _descriptionScrollTimer = null;
  }

  void _resetDescriptionScroll() {
    if (!_descriptionController.hasClients) return;
    _descriptionController.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 720;
    final titleStyle = Theme.of(context).textTheme.headlineSmall?.copyWith(
      color: palette.primaryText,
      fontSize: compact ? 22 : 30,
      height: 1.08,
      fontWeight: FontWeight.w800,
      shadows: const [
        Shadow(color: Colors.black, blurRadius: 12),
        Shadow(color: Colors.black, blurRadius: 4, offset: Offset(1, 1)),
      ],
    );
    final descriptionStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: palette.primaryText.withValues(alpha: .9),
      fontSize: compact ? 14 : 18,
      height: 1.3,
      fontWeight: FontWeight.w600,
      shadows: const [
        Shadow(color: Colors.black, blurRadius: 10),
        Shadow(color: Colors.black, blurRadius: 3, offset: Offset(1, 1)),
      ],
    );
    final descriptionFontSize = descriptionStyle?.fontSize ?? 18;
    final descriptionLineHeight = descriptionStyle?.height ?? 1.3;
    final descriptionViewportHeight =
        MediaQuery.textScalerOf(context).scale(descriptionFontSize) *
        descriptionLineHeight *
        3;

    return ExcludeSemantics(
      excluding: !_canShow,
      child: IgnorePointer(
        child: AnimatedSlide(
          offset: _canShow ? Offset.zero : const Offset(0, -.08),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: _canShow ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Semantics(
              container: true,
              label: [
                if (widget.episodeTitle.isNotEmpty) widget.episodeTitle,
                if (widget.description.isNotEmpty) widget.description,
              ].join(', '),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.episodeTitle.isNotEmpty)
                    Text(
                      widget.episodeTitle,
                      key: const ValueKey('player-paused-episode-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  if (widget.episodeTitle.isNotEmpty &&
                      widget.description.isNotEmpty)
                    SizedBox(height: compact ? 5 : 8),
                  if (widget.description.isNotEmpty)
                    SizedBox(
                      height: descriptionViewportHeight,
                      child: ClipRect(
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false, overscroll: false),
                          child: SingleChildScrollView(
                            key: const ValueKey(
                              'player-paused-description-scroll',
                            ),
                            controller: _descriptionController,
                            physics: const NeverScrollableScrollPhysics(),
                            child: Text(
                              widget.description,
                              key: const ValueKey('player-paused-description'),
                              style: descriptionStyle,
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
      ),
    );
  }
}
