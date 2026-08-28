import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/player/presentation/player_control_overlay.dart';
import 'package:anime_tv/features/watch_together/application/watch_party_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const double _playerControlFocusGutter = 20;
const double _compactPlayerChromeReservedHeight = 136;
const double _regularPlayerChromeReservedHeight = 130;
const Color _defaultPlayerChromePanel = Color(0xD6080808);
const Color _defaultPlayerChromeShadow = Color(0xA8000000);
const Color _defaultPlayerControlSurface = Color(0x8F242429);
const Color _defaultPlayerSkipSurface = Color(0xB30B0B0D);
const Color _defaultPlayerSkipShadow = Color(0x77000000);

bool _usesDefaultPlayerPalette(AppThemePalette palette) =>
    palette == AppThemePalette.defaults;

Color _playerChromePanelColor(AppThemePalette palette) =>
    _usesDefaultPlayerPalette(palette)
    ? _defaultPlayerChromePanel
    : Color.lerp(
        palette.background,
        palette.surface,
        .62,
      )!.withValues(alpha: .84);

Color _playerChromeShadowColor(AppThemePalette palette) =>
    _usesDefaultPlayerPalette(palette)
    ? _defaultPlayerChromeShadow
    : Color.lerp(palette.background, Colors.black, .85)!.withValues(alpha: .66);

Color _playerControlSurfaceColor(AppThemePalette palette) =>
    _usesDefaultPlayerPalette(palette)
    ? _defaultPlayerControlSurface
    : palette.selectableSurface.withValues(alpha: .56);

Color _playerSkipSurfaceColor(AppThemePalette palette) =>
    _usesDefaultPlayerPalette(palette)
    ? _defaultPlayerSkipSurface
    : Color.lerp(
        palette.background,
        palette.surface,
        .55,
      )!.withValues(alpha: .70);

Color _playerSkipShadowColor(AppThemePalette palette) =>
    _usesDefaultPlayerPalette(palette)
    ? _defaultPlayerSkipShadow
    : _playerChromeShadowColor(palette).withValues(alpha: .47);

Color _playerPrimaryTextColor(AppThemePalette palette) =>
    _usesDefaultPlayerPalette(palette) ? Colors.white : palette.primaryText;

Color _playerPrimaryControlTextColor(AppThemePalette palette) =>
    _usesDefaultPlayerPalette(palette)
    ? Colors.white
    : contrastForeground(palette.accent);

Color _playerProgressTrackColor(AppThemePalette palette) =>
    (_usesDefaultPlayerPalette(palette) ? Colors.white : palette.primaryText)
        .withValues(alpha: .24);

/// Bottom inset for the floating Skip Intro/Outro action.
///
/// The reserve grows with accessible text scaling so the skip action remains
/// clear of the adaptive HUD without reducing the user's configured text size.
double playerSkipOverlayBottomInset({
  required Size viewport,
  required bool controlsVisible,
  double safeAreaBottom = 0,
  double textScaleFactor = 1,
  bool expandedHeader = false,
}) {
  if (!controlsVisible) return 26 + safeAreaBottom.clamp(0, 160);
  final compact = viewport.width < 720 || viewport.height < 480;
  final base = compact
      ? _compactPlayerChromeReservedHeight
      : _regularPlayerChromeReservedHeight;
  final scale = textScaleFactor.clamp(1, 3);
  final accessibleGrowth = (scale - 1) * 68;
  // Watch Party badges can wrap the HUD header onto another line on TV
  // viewports. Reserve that line so Skip Intro/Outro stays visibly detached
  // from the panel instead of landing on top of its badges or border.
  final expandedHeaderGrowth = expandedHeader ? 44.0 : 0.0;
  return base +
      accessibleGrowth +
      expandedHeaderGrowth +
      safeAreaBottom.clamp(0, 160);
}

/// Visual language shared by every Flutter-backed playback engine.
///
/// Engine integration remains deliberately outside this widget. MPV provides
/// its current state and callbacks so playback mechanics stay separate from
/// the player UI.
class TetoPlayerChrome extends StatelessWidget {
  const TetoPlayerChrome({
    required this.engineKey,
    required this.title,
    required this.streamLabel,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.playFocusNode,
    required this.seekBackSeconds,
    required this.seekForwardSeconds,
    required this.onSeek,
    this.onSeekPreview,
    required this.onRewind,
    required this.onPlayPause,
    required this.onForward,
    this.onPreviousEpisode,
    this.previousEpisodeEnabled = true,
    this.onNextEpisode,
    this.nextEpisodeEnabled = true,
    required this.onAudio,
    required this.onSubtitles,
    required this.onPicture,
    this.onPlaybackSpeed,
    this.playbackSpeed = 1,
    this.playbackSpeedFocusNode,
    this.playbackSpeedEnabled = true,
    this.onSources,
    this.onWatchTogether,
    this.watchTogetherFocusNode,
    this.progressFocusNode,
    this.onScrubInteractionChanged,
    this.onInteraction,
    required this.onOptions,
    required this.onDismiss,
    this.engineLabel,
    this.partyStatus,
    this.watchingCount,
    this.playbackControlsLocked = false,
    this.footerHint = 'D-pad controls  |  J/L seek  |  Menu/Y options',
    super.key,
  });

  final String engineKey;
  final String title;
  final String streamLabel;
  final String? engineLabel;
  final String? partyStatus;
  final int? watchingCount;
  final bool playbackControlsLocked;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final FocusNode playFocusNode;
  final int seekBackSeconds;
  final int seekForwardSeconds;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration>? onSeekPreview;
  final VoidCallback onRewind;
  final VoidCallback onPlayPause;
  final VoidCallback onForward;
  final VoidCallback? onPreviousEpisode;
  final bool previousEpisodeEnabled;
  final VoidCallback? onNextEpisode;
  final bool nextEpisodeEnabled;
  final VoidCallback onAudio;
  final VoidCallback onSubtitles;
  final VoidCallback onPicture;
  final VoidCallback? onPlaybackSpeed;
  final double playbackSpeed;
  final FocusNode? playbackSpeedFocusNode;
  final bool playbackSpeedEnabled;
  final VoidCallback? onSources;
  final VoidCallback? onWatchTogether;
  final FocusNode? watchTogetherFocusNode;
  final FocusNode? progressFocusNode;
  final ValueChanged<bool>? onScrubInteractionChanged;
  final VoidCallback? onInteraction;
  final VoidCallback onOptions;
  final VoidCallback onDismiss;
  final String footerHint;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final palette = context.appPalette;
    final compact = media.size.width < 720 || media.size.height < 480;
    final accessibleLayout = media.textScaler.scale(1) > 1.4;
    final horizontalInset = compact
        ? 12.0
        : (media.size.width * .025).clamp(24.0, 48.0);
    final bottomInset = compact ? 6.0 : 12.0;
    final canSeek = !playbackControlsLocked && duration > Duration.zero;
    final wideReferenceLayout =
        !compact && !accessibleLayout && media.size.width >= 900;
    final moveFromControls = canSeek && progressFocusNode != null
        ? progressFocusNode!.requestFocus
        : onDismiss;

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: EdgeInsets.fromLTRB(
          horizontalInset,
          0,
          horizontalInset,
          bottomInset,
        ),
        child: DecoratedBox(
          key: ValueKey('$engineKey-bottom-player-chrome'),
          decoration: BoxDecoration(
            color: _playerChromePanelColor(palette),
            borderRadius: BorderRadius.circular(compact ? 12 : 16),
            border: Border.all(
              color: palette.accent.withValues(alpha: .78),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: _playerChromeShadowColor(palette),
                blurRadius: 26,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 10 : 16,
              compact ? 5 : 6,
              compact ? 10 : 16,
              compact ? 4 : 5,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TetoPlayerHeader(
                  engineKey: engineKey,
                  title: title,
                  streamLabel: streamLabel,
                  engineLabel: engineLabel,
                  partyStatus: partyStatus,
                  watchingCount: watchingCount,
                  compact: compact,
                  accessibleLayout: accessibleLayout,
                  alignBadgesRight: wideReferenceLayout,
                ),
                const SizedBox(height: 4),
                _TetoPlayerControlStrip(
                  engineKey: engineKey,
                  preferScrollable: compact || accessibleLayout,
                  isPlaying: isPlaying,
                  playFocusNode: playFocusNode,
                  seekBackSeconds: seekBackSeconds,
                  seekForwardSeconds: seekForwardSeconds,
                  playbackControlsLocked: playbackControlsLocked,
                  onRewind: onRewind,
                  onPlayPause: onPlayPause,
                  onForward: onForward,
                  onPreviousEpisode: onPreviousEpisode,
                  previousEpisodeEnabled: previousEpisodeEnabled,
                  onNextEpisode: onNextEpisode,
                  nextEpisodeEnabled: nextEpisodeEnabled,
                  onPlaybackSpeed: onPlaybackSpeed,
                  playbackSpeed: playbackSpeed,
                  playbackSpeedFocusNode: playbackSpeedFocusNode,
                  playbackSpeedEnabled: playbackSpeedEnabled,
                  onAudio: onAudio,
                  onSubtitles: onSubtitles,
                  onPicture: onPicture,
                  onSources: onSources,
                  onWatchTogether: onWatchTogether,
                  watchTogetherFocusNode: watchTogetherFocusNode,
                  onOptions: onOptions,
                  onInteraction: onInteraction,
                  onMoveDown: moveFromControls,
                  onDismiss: onDismiss,
                  inlineTime: wideReferenceLayout
                      ? _PlayerProgressTime(
                          key: ValueKey('$engineKey-inline-player-time'),
                          position: position,
                          duration: duration,
                          compact: false,
                          palette: palette,
                        )
                      : null,
                ),
                const SizedBox(height: 5),
                _TetoPlayerProgressScrubber(
                  engineKey: engineKey,
                  position: position,
                  duration: duration,
                  enabled: canSeek,
                  compact: compact,
                  palette: palette,
                  focusNode: progressFocusNode,
                  returnFocusNode: playFocusNode,
                  seekBackSeconds: seekBackSeconds,
                  seekForwardSeconds: seekForwardSeconds,
                  footerHint: footerHint,
                  onSeek: onSeek,
                  onSeekPreview: onSeekPreview,
                  onInteractionChanged: onScrubInteractionChanged,
                  onDismiss: onDismiss,
                  showSupplementalRow: !wideReferenceLayout,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps playback actions visually grouped without changing their remote-control
/// traversal order. Wide TVs anchor transport and episode actions to the left
/// and utilities to the right. Smaller viewports use the same order inside a
/// horizontal scroller, so every action remains reachable without shrinking
/// the established 40dp controls.
class _TetoPlayerControlStrip extends StatefulWidget {
  const _TetoPlayerControlStrip({
    required this.engineKey,
    required this.preferScrollable,
    required this.isPlaying,
    required this.playFocusNode,
    required this.seekBackSeconds,
    required this.seekForwardSeconds,
    required this.playbackControlsLocked,
    required this.onRewind,
    required this.onPlayPause,
    required this.onForward,
    required this.onPreviousEpisode,
    required this.previousEpisodeEnabled,
    required this.onNextEpisode,
    required this.nextEpisodeEnabled,
    required this.onPlaybackSpeed,
    required this.playbackSpeed,
    required this.playbackSpeedFocusNode,
    required this.playbackSpeedEnabled,
    required this.onAudio,
    required this.onSubtitles,
    required this.onPicture,
    required this.onSources,
    required this.onWatchTogether,
    required this.watchTogetherFocusNode,
    required this.onOptions,
    required this.onInteraction,
    required this.onMoveDown,
    required this.onDismiss,
    this.inlineTime,
  });

  final String engineKey;
  final bool preferScrollable;
  final bool isPlaying;
  final FocusNode playFocusNode;
  final int seekBackSeconds;
  final int seekForwardSeconds;
  final bool playbackControlsLocked;
  final VoidCallback onRewind;
  final VoidCallback onPlayPause;
  final VoidCallback onForward;
  final VoidCallback? onPreviousEpisode;
  final bool previousEpisodeEnabled;
  final VoidCallback? onNextEpisode;
  final bool nextEpisodeEnabled;
  final VoidCallback? onPlaybackSpeed;
  final double playbackSpeed;
  final FocusNode? playbackSpeedFocusNode;
  final bool playbackSpeedEnabled;
  final VoidCallback onAudio;
  final VoidCallback onSubtitles;
  final VoidCallback onPicture;
  final VoidCallback? onSources;
  final VoidCallback? onWatchTogether;
  final FocusNode? watchTogetherFocusNode;
  final VoidCallback onOptions;
  final VoidCallback? onInteraction;
  final VoidCallback onMoveDown;
  final VoidCallback onDismiss;
  final Widget? inlineTime;

  @override
  State<_TetoPlayerControlStrip> createState() =>
      _TetoPlayerControlStripState();
}

class _TetoPlayerControlStripState extends State<_TetoPlayerControlStrip> {
  static const double _controlExtent = 40;
  static const double _controlGap = 8;
  static const double _utilityGroupGap = 28;
  static const double _inlineTimeGap = 18;
  static const double _inlineTimeWidth = 118;

  late final FocusNode _previousFocus = _controlFocus('previous-episode');
  late final FocusNode _rewindFocus = _controlFocus('rewind');
  late final FocusNode _forwardFocus = _controlFocus('fast-forward');
  late final FocusNode _nextFocus = _controlFocus('next-episode');
  late final FocusNode _speedFocus = _controlFocus('playback-speed');
  late final FocusNode _audioFocus = _controlFocus('audio');
  late final FocusNode _captionsFocus = _controlFocus('captions');
  late final FocusNode _pictureFocus = _controlFocus('picture');
  late final FocusNode _sourcesFocus = _controlFocus('sources');
  late final FocusNode _watchPartyFocus = _controlFocus('watch-party');
  late final FocusNode _optionsFocus = _controlFocus('options');

  FocusNode _controlFocus(String label) =>
      FocusNode(debugLabel: 'player.control.$label');

  @override
  void dispose() {
    _previousFocus.dispose();
    _rewindFocus.dispose();
    _forwardFocus.dispose();
    _nextFocus.dispose();
    _speedFocus.dispose();
    _audioFocus.dispose();
    _captionsFocus.dispose();
    _pictureFocus.dispose();
    _sourcesFocus.dispose();
    _watchPartyFocus.dispose();
    _optionsFocus.dispose();
    super.dispose();
  }

  FocusNode get _effectiveSpeedFocus =>
      widget.playbackSpeedFocusNode ?? _speedFocus;

  FocusNode get _effectiveWatchPartyFocus =>
      widget.watchTogetherFocusNode ?? _watchPartyFocus;

  double _groupWidth(int count) =>
      count <= 0 ? 0 : count * _controlExtent + (count - 1) * _controlGap;

  Widget _group({required String name, required List<Widget> controls}) {
    return Row(
      key: ValueKey('${widget.engineKey}-$name-controls'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < controls.length; index++) ...[
          if (index > 0) const SizedBox(width: _controlGap),
          controls[index],
        ],
      ],
    );
  }

  List<_PlayerHudControlDefinition> _definitions({required bool scrolling}) {
    final locked = widget.playbackControlsLocked;
    return [
      if (widget.onPreviousEpisode != null)
        _PlayerHudControlDefinition(
          icon: Icons.skip_previous_rounded,
          label: 'Previous Episode',
          focusNode: _previousFocus,
          enabled: !locked && widget.previousEpisodeEnabled,
          onPressed: widget.onPreviousEpisode!,
          revealScrollStart: scrolling,
          group: _PlayerHudControlGroup.transport,
        ),
      _PlayerHudControlDefinition(
        // Use the exact fast-forward glyph and mirror it so both seek arrows
        // always have identical weight, rounding, and proportions.
        icon: Icons.forward_rounded,
        mirrorIconHorizontally: true,
        label: 'Back ${widget.seekBackSeconds}s',
        focusNode: _rewindFocus,
        enabled: !locked,
        onPressed: widget.onRewind,
        revealScrollStart: scrolling && widget.onPreviousEpisode == null,
        group: _PlayerHudControlGroup.transport,
      ),
      _PlayerHudControlDefinition(
        icon: widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        label: widget.isPlaying ? 'Pause' : 'Play',
        focusNode: widget.playFocusNode,
        enabled: !locked,
        primary: true,
        onPressed: widget.onPlayPause,
        group: _PlayerHudControlGroup.transport,
      ),
      _PlayerHudControlDefinition(
        icon: Icons.forward_rounded,
        label: 'Forward ${widget.seekForwardSeconds}s',
        focusNode: _forwardFocus,
        enabled: !locked,
        onPressed: widget.onForward,
        group: _PlayerHudControlGroup.transport,
      ),
      if (widget.onNextEpisode != null)
        _PlayerHudControlDefinition(
          icon: Icons.skip_next_rounded,
          label: 'Next Episode',
          focusNode: _nextFocus,
          enabled: !locked && widget.nextEpisodeEnabled,
          onPressed: widget.onNextEpisode!,
          group: _PlayerHudControlGroup.transport,
        ),
      if (widget.onPlaybackSpeed != null)
        _PlayerHudControlDefinition(
          icon: Icons.speed_rounded,
          displayText: _playbackSpeedLabel(widget.playbackSpeed),
          label: 'Playback Speed',
          focusNode: _effectiveSpeedFocus,
          enabled: !locked && widget.playbackSpeedEnabled,
          onPressed: widget.onPlaybackSpeed!,
          group: _PlayerHudControlGroup.utility,
        ),
      _PlayerHudControlDefinition(
        icon: Icons.audiotrack_rounded,
        label: 'Audio',
        focusNode: _audioFocus,
        enabled: !locked,
        onPressed: widget.onAudio,
        group: _PlayerHudControlGroup.utility,
      ),
      _PlayerHudControlDefinition(
        icon: Icons.closed_caption_rounded,
        label: 'CC',
        focusNode: _captionsFocus,
        enabled: !locked,
        onPressed: widget.onSubtitles,
        group: _PlayerHudControlGroup.utility,
      ),
      _PlayerHudControlDefinition(
        icon: Icons.aspect_ratio_rounded,
        label: 'Picture',
        focusNode: _pictureFocus,
        enabled: !locked,
        onPressed: widget.onPicture,
        group: _PlayerHudControlGroup.utility,
      ),
      if (widget.onSources != null)
        _PlayerHudControlDefinition(
          icon: Icons.video_library_rounded,
          label: 'Sources',
          focusNode: _sourcesFocus,
          enabled: !locked,
          onPressed: widget.onSources!,
          group: _PlayerHudControlGroup.utility,
        ),
      if (widget.onWatchTogether != null)
        _PlayerHudControlDefinition(
          icon: Icons.groups_rounded,
          label: 'Watch Party',
          focusNode: _effectiveWatchPartyFocus,
          enabled: true,
          onPressed: widget.onWatchTogether!,
          group: _PlayerHudControlGroup.utility,
        ),
      _PlayerHudControlDefinition(
        icon: Icons.tune_rounded,
        label: 'Options',
        focusNode: _optionsFocus,
        enabled: !locked,
        onPressed: widget.onOptions,
        revealScrollEnd: scrolling,
        group: _PlayerHudControlGroup.utility,
      ),
    ];
  }

  List<Widget> _controlsFor(
    List<_PlayerHudControlDefinition> definitions,
    _PlayerHudControlGroup group,
  ) {
    final focusable = definitions.where((control) => control.enabled).toList();
    return [
      for (final definition in definitions.where(
        (control) => control.group == group,
      ))
        TetoPlayerControl(
          icon: definition.icon,
          mirrorIconHorizontally: definition.mirrorIconHorizontally,
          displayText: definition.displayText,
          label: definition.label,
          iconOnly: true,
          focusNode: definition.focusNode,
          primary: definition.primary,
          enabled: definition.enabled,
          revealScrollStart: definition.revealScrollStart,
          revealScrollEnd: definition.revealScrollEnd,
          onPressed: definition.onPressed,
          onInteraction: widget.onInteraction,
          moveLeftFocusNode: _neighborOf(focusable, definition, offset: -1),
          moveRightFocusNode: _neighborOf(focusable, definition, offset: 1),
          onMoveDown: widget.onMoveDown,
          onDismiss: widget.onDismiss,
        ),
    ];
  }

  FocusNode? _neighborOf(
    List<_PlayerHudControlDefinition> focusable,
    _PlayerHudControlDefinition definition, {
    required int offset,
  }) {
    if (!definition.enabled) return null;
    final index = focusable.indexOf(definition);
    final target = index + offset;
    if (index < 0 || target < 0 || target >= focusable.length) return null;
    return focusable[target].focusNode;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final definitions = _definitions(scrolling: false);
        final transport = _controlsFor(
          definitions,
          _PlayerHudControlGroup.transport,
        );
        final utility = _controlsFor(
          definitions,
          _PlayerHudControlGroup.utility,
        );
        final minimumSpacedWidth =
            (_playerControlFocusGutter * 2) +
            _groupWidth(transport.length) +
            (widget.inlineTime == null
                ? 0
                : _inlineTimeGap + _inlineTimeWidth) +
            _utilityGroupGap +
            _groupWidth(utility.length);
        final spaced =
            !widget.preferScrollable &&
            constraints.maxWidth >= minimumSpacedWidth;
        if (spaced) {
          return FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Padding(
              key: ValueKey('${widget.engineKey}-player-controls-spaced'),
              padding: const EdgeInsets.symmetric(
                horizontal: _playerControlFocusGutter,
              ),
              child: Row(
                children: [
                  _group(name: 'transport', controls: transport),
                  if (widget.inlineTime case final inlineTime?) ...[
                    const SizedBox(width: _inlineTimeGap),
                    SizedBox(width: _inlineTimeWidth, child: inlineTime),
                  ],
                  const SizedBox(width: _utilityGroupGap),
                  const Spacer(),
                  _group(name: 'utility', controls: utility),
                ],
              ),
            ),
          );
        }

        final scrollingDefinitions = _definitions(scrolling: true);
        final scrollingTransport = _controlsFor(
          scrollingDefinitions,
          _PlayerHudControlGroup.transport,
        );
        final scrollingUtility = _controlsFor(
          scrollingDefinitions,
          _PlayerHudControlGroup.utility,
        );
        return FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: SingleChildScrollView(
            key: ValueKey('${widget.engineKey}-player-controls-scroll'),
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            // TvFocusable paints a scaled focus ring and glow outside the
            // pill's layout bounds. Keep an equal reserve at both limits.
            padding: const EdgeInsets.symmetric(
              horizontal: _playerControlFocusGutter,
            ),
            child: Row(
              children: [
                _group(name: 'transport', controls: scrollingTransport),
                const SizedBox(width: _utilityGroupGap),
                _group(name: 'utility', controls: scrollingUtility),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _PlayerHudControlGroup { transport, utility }

class _PlayerHudControlDefinition {
  const _PlayerHudControlDefinition({
    required this.icon,
    required this.label,
    required this.focusNode,
    required this.enabled,
    required this.onPressed,
    required this.group,
    this.displayText,
    this.primary = false,
    this.mirrorIconHorizontally = false,
    this.revealScrollStart = false,
    this.revealScrollEnd = false,
  });

  final IconData icon;
  final String label;
  final String? displayText;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onPressed;
  final _PlayerHudControlGroup group;
  final bool primary;
  final bool mirrorIconHorizontally;
  final bool revealScrollStart;
  final bool revealScrollEnd;
}

String _playbackSpeedLabel(double speed) {
  final whole = speed == speed.roundToDouble();
  final value = whole
      ? speed.toStringAsFixed(0)
      : speed.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
  return '${value}x';
}

class _TetoPlayerHeader extends StatelessWidget {
  const _TetoPlayerHeader({
    required this.engineKey,
    required this.title,
    required this.streamLabel,
    required this.engineLabel,
    required this.partyStatus,
    required this.watchingCount,
    required this.compact,
    required this.accessibleLayout,
    required this.alignBadgesRight,
  });

  final String engineKey;
  final String title;
  final String streamLabel;
  final String? engineLabel;
  final String? partyStatus;
  final int? watchingCount;
  final bool compact;
  final bool accessibleLayout;
  final bool alignBadgesRight;

  @override
  Widget build(BuildContext context) {
    final titleWidget = Text(
      title,
      maxLines: accessibleLayout ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
    );
    final badges = <Widget>[
      if (!compact && engineLabel != null)
        _PlayerBadge(
          key: ValueKey('$engineKey-engine-badge'),
          text: engineLabel!,
        ),
      _PlayerBadge(key: ValueKey('$engineKey-source-badge'), text: streamLabel),
      if (partyStatus != null)
        _PlayerBadge(
          key: ValueKey('$engineKey-watch-party-status'),
          text: partyStatus!,
        ),
      if (watchingCount case final count?)
        _PlayerBadge(
          key: ValueKey('$engineKey-watch-party-watching'),
          icon: Icons.group_rounded,
          text: '${count.clamp(1, 21)}',
          semanticsLabel: watchPartyAudienceLabel(count.clamp(1, 21)),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (alignBadgesRight) {
          return Row(
            key: ValueKey('$engineKey-player-header-spaced'),
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: titleWidget),
              const SizedBox(width: 16),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 10,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: badges,
                  ),
                ),
              ),
            ],
          );
        }
        return Wrap(
          spacing: 12,
          runSpacing: accessibleLayout ? 8 : 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: accessibleLayout
                    ? constraints.maxWidth
                    : constraints.maxWidth * (compact ? .72 : .56),
              ),
              child: titleWidget,
            ),
            ...badges,
          ],
        );
      },
    );
  }
}

class _TetoPlayerProgressScrubber extends StatefulWidget {
  const _TetoPlayerProgressScrubber({
    required this.engineKey,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.compact,
    required this.palette,
    required this.returnFocusNode,
    required this.seekBackSeconds,
    required this.seekForwardSeconds,
    required this.footerHint,
    required this.onSeek,
    this.onSeekPreview,
    required this.onDismiss,
    this.focusNode,
    this.onInteractionChanged,
    this.showSupplementalRow = true,
  });

  final String engineKey;
  final Duration position;
  final Duration duration;
  final bool enabled;
  final bool compact;
  final AppThemePalette palette;
  final FocusNode? focusNode;
  final FocusNode returnFocusNode;
  final int seekBackSeconds;
  final int seekForwardSeconds;
  final String footerHint;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration>? onSeekPreview;
  final VoidCallback onDismiss;
  final ValueChanged<bool>? onInteractionChanged;
  final bool showSupplementalRow;

  @override
  State<_TetoPlayerProgressScrubber> createState() =>
      _TetoPlayerProgressScrubberState();
}

class _TetoPlayerProgressScrubberState
    extends State<_TetoPlayerProgressScrubber> {
  late final FocusNode _ownedFocusNode = FocusNode(
    debugLabel: 'player.progress.scrubber',
  );
  late final FocusNode _sliderGestureFocus = FocusNode(
    debugLabel: 'player.progress.pointer',
    canRequestFocus: false,
    skipTraversal: true,
  );
  Timer? _keyboardCommitTimer;
  Timer? _framePreviewTimer;
  Timer? _previewSettleTimer;
  LogicalKeyboardKey? _heldSeekKey;
  double? _previewMilliseconds;
  Duration? _interactionDuration;
  bool _focused = false;
  bool _interacting = false;

  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode;

  Duration get _scrubDuration => _interacting && _interactionDuration != null
      ? _interactionDuration!
      : widget.duration;

  double get _scrubMaximumMilliseconds =>
      _scrubDuration.inMilliseconds.clamp(0, 1 << 53).toDouble();

  double get _externalMilliseconds => widget.position.inMilliseconds
      .clamp(0, _scrubMaximumMilliseconds.round())
      .toDouble();

  double get _displayMilliseconds =>
      (_previewMilliseconds ?? _externalMilliseconds).clamp(
        0,
        _scrubMaximumMilliseconds,
      );

  @override
  void didUpdateWidget(covariant _TetoPlayerProgressScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    final preview = _previewMilliseconds;
    if (preview == null) return;
    if (!widget.enabled || _scrubMaximumMilliseconds <= 0) {
      _previewMilliseconds = null;
      return;
    }
    if (!_interacting && (preview - _externalMilliseconds).abs() <= 750) {
      _previewSettleTimer?.cancel();
      _previewMilliseconds = null;
      return;
    }
    _previewMilliseconds = playerScrubTarget(
      target: Duration(milliseconds: preview.round()),
      duration: _scrubDuration,
    ).inMilliseconds.toDouble();
  }

  @override
  void dispose() {
    _keyboardCommitTimer?.cancel();
    _framePreviewTimer?.cancel();
    _previewSettleTimer?.cancel();
    _ownedFocusNode.dispose();
    _sliderGestureFocus.dispose();
    super.dispose();
  }

  void _setInteracting(bool interacting) {
    if (_interacting == interacting) return;
    setState(() {
      if (interacting) {
        _interactionDuration = widget.duration > Duration.zero
            ? widget.duration
            : null;
      } else {
        _interactionDuration = null;
      }
      _interacting = interacting;
    });
    widget.onInteractionChanged?.call(interacting);
  }

  void _setPreview(double value) {
    if (!widget.enabled || _scrubMaximumMilliseconds <= 0) return;
    final bounded = playerScrubTarget(
      target: Duration(milliseconds: value.round()),
      duration: _scrubDuration,
    ).inMilliseconds.toDouble();
    setState(() {
      _previewMilliseconds = bounded;
    });
    _scheduleFramePreview(bounded);
  }

  void _scheduleFramePreview(double milliseconds) {
    final onSeekPreview = widget.onSeekPreview;
    if (!_interacting || onSeekPreview == null) return;
    _framePreviewTimer?.cancel();
    final target = Duration(milliseconds: milliseconds.round());
    // Seeking a network stream for every pointer or remote repeat event can
    // overwhelm both MPV and the origin. A short debounce still feels live,
    // while only the viewer's latest resting position decodes a preview frame.
    _framePreviewTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || !_interacting) return;
      onSeekPreview(target);
    });
  }

  void _commitPreview() {
    _keyboardCommitTimer?.cancel();
    _framePreviewTimer?.cancel();
    final value = _previewMilliseconds;
    if (!widget.enabled || value == null) return;
    final target = playerScrubTarget(
      target: Duration(milliseconds: value.round()),
      duration: _scrubDuration,
    );
    widget.onSeek(target);
    _previewSettleTimer?.cancel();
    _previewSettleTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _previewMilliseconds = null);
    });
  }

  void _scheduleKeyboardCommit() {
    _keyboardCommitTimer?.cancel();
    _keyboardCommitTimer = Timer(const Duration(milliseconds: 260), () {
      _heldSeekKey = null;
      _commitPreview();
      _setInteracting(false);
    });
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent && _heldSeekKey == key) {
      _heldSeekKey = null;
      _commitPreview();
      _setInteracting(false);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _commitPreview();
      _setInteracting(false);
      widget.returnFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _commitPreview();
      _setInteracting(false);
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    if (!widget.enabled) return KeyEventResult.handled;
    _setInteracting(true);
    _heldSeekKey = key;
    final seconds = key == LogicalKeyboardKey.arrowLeft
        ? -widget.seekBackSeconds
        : widget.seekForwardSeconds;
    _setPreview(
      _displayMilliseconds + Duration(seconds: seconds).inMilliseconds,
    );
    _scheduleKeyboardCommit();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final durationAvailable = _scrubMaximumMilliseconds > 0;
    final enabled = widget.enabled && durationAvailable;
    final accessibleLayout = MediaQuery.textScalerOf(context).scale(1) > 1.4;
    final displayPosition = Duration(
      milliseconds: _displayMilliseconds.round(),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          hint: widget.showSupplementalRow ? null : widget.footerHint,
          child: Focus(
            focusNode: _focusNode,
            onFocusChange: (focused) {
              if (_focused == focused) return;
              if (!focused) {
                _commitPreview();
                _setInteracting(false);
              }
              setState(() => _focused = focused);
            },
            onKeyEvent: _handleKey,
            child: AnimatedContainer(
              key: ValueKey('${widget.engineKey}-player-progress-focus'),
              duration: const Duration(milliseconds: 120),
              height: widget.compact ? 20 : 22,
              decoration: BoxDecoration(
                color: _focused
                    ? widget.palette.accent.withValues(alpha: .14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: _focused
                      ? widget.palette.focusRing
                      : Colors.transparent,
                  width: 1.4,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: widget.compact ? 3 : 4,
                      activeTrackColor: widget.palette.accentBright,
                      inactiveTrackColor: _playerProgressTrackColor(
                        widget.palette,
                      ),
                      thumbColor: widget.palette.accentBright,
                      overlayColor: widget.palette.focusGlow.withValues(
                        alpha: .28,
                      ),
                      thumbShape: RoundSliderThumbShape(
                        enabledThumbRadius: _focused ? 6 : 4.5,
                        disabledThumbRadius: 3.5,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      showValueIndicator: ShowValueIndicator.onDrag,
                    ),
                    child: Slider(
                      key: ValueKey('${widget.engineKey}-player-progress-bar'),
                      focusNode: _sliderGestureFocus,
                      value: durationAvailable ? _displayMilliseconds : 0,
                      min: 0,
                      max: durationAvailable ? _scrubMaximumMilliseconds : 1,
                      label: formatPlayerChromeDuration(displayPosition),
                      activeColor: widget.palette.accentBright,
                      inactiveColor: _playerProgressTrackColor(widget.palette),
                      onChangeStart: enabled
                          ? (_) {
                              _keyboardCommitTimer?.cancel();
                              _previewSettleTimer?.cancel();
                              _setInteracting(true);
                            }
                          : null,
                      onChanged: enabled ? _setPreview : null,
                      onChangeEnd: enabled
                          ? (value) {
                              _setPreview(value);
                              _commitPreview();
                              _setInteracting(false);
                            }
                          : null,
                    ),
                  ),
                  if (_interacting)
                    Positioned(
                      right: widget.compact ? 8 : 12,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: ValueKey(
                            '${widget.engineKey}-player-seek-target-time',
                          ),
                          decoration: BoxDecoration(
                            color: widget.palette.background.withValues(
                              alpha: .94,
                            ),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: widget.palette.accent.withValues(
                                alpha: .7,
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            child: Text(
                              'Seek ${formatPlayerChromeDuration(displayPosition)}',
                              style: TextStyle(
                                color: _playerPrimaryTextColor(widget.palette),
                                fontSize: widget.compact ? 9 : 10,
                                fontWeight: FontWeight.w700,
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
        if (widget.showSupplementalRow) const SizedBox(height: 1),
        if (widget.showSupplementalRow && accessibleLayout && !widget.compact)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PlayerProgressTime(
                position: displayPosition,
                duration: widget.duration,
                compact: widget.compact,
                palette: widget.palette,
              ),
              const SizedBox(height: 3),
              Text(
                widget.footerHint,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: widget.palette.mutedText, fontSize: 11),
              ),
            ],
          )
        else if (widget.showSupplementalRow)
          Row(
            children: [
              _PlayerProgressTime(
                position: displayPosition,
                duration: widget.duration,
                compact: widget.compact,
                palette: widget.palette,
              ),
              if (!widget.compact) ...[
                const Spacer(),
                Flexible(
                  child: Text(
                    widget.footerHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: widget.palette.mutedText,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

class _PlayerProgressTime extends StatelessWidget {
  const _PlayerProgressTime({
    required this.position,
    required this.duration,
    required this.compact,
    required this.palette,
    super.key,
  });

  final Duration position;
  final Duration duration;
  final bool compact;
  final AppThemePalette palette;

  @override
  Widget build(BuildContext context) => Text(
    '${formatPlayerChromeDuration(position)}  /  '
    '${formatPlayerChromeDuration(duration)}',
    maxLines: 1,
    overflow: TextOverflow.fade,
    softWrap: false,
    style: TextStyle(
      color: _playerPrimaryTextColor(palette),
      fontSize: compact ? 11 : 12,
      fontWeight: FontWeight.w700,
    ),
  );
}

class TetoSkipSegmentOverlay extends StatelessWidget {
  const TetoSkipSegmentOverlay({
    required this.label,
    required this.onPressed,
    this.focusNode,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final maximumWidth = (MediaQuery.sizeOf(context).width - 36).clamp(
      160.0,
      520.0,
    );
    return TvFocusable(
      key: const ValueKey('player-skip-segment-overlay'),
      focusNode: focusNode,
      onPressed: onPressed,
      focusScale: 1.025,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: BoxConstraints(minHeight: 44, maxWidth: maximumWidth),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: _playerSkipSurfaceColor(palette),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: palette.accentBright.withValues(alpha: .82),
          ),
          boxShadow: [
            BoxShadow(color: _playerSkipShadowColor(palette), blurRadius: 16),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.skip_next_rounded,
              color: palette.accentBright,
              size: 21,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _playerPrimaryTextColor(palette),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TetoPlayerControl extends StatelessWidget {
  const TetoPlayerControl({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.displayText,
    this.focusNode,
    this.moveLeftFocusNode,
    this.moveRightFocusNode,
    this.primary = false,
    this.iconOnly = false,
    this.mirrorIconHorizontally = false,
    this.revealScrollStart = false,
    this.revealScrollEnd = false,
    this.onMoveDown,
    this.onDismiss,
    this.onInteraction,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final String? displayText;
  final FocusNode? focusNode;
  final FocusNode? moveLeftFocusNode;
  final FocusNode? moveRightFocusNode;
  final bool primary;
  final bool iconOnly;
  final bool mirrorIconHorizontally;
  final bool revealScrollStart;
  final bool revealScrollEnd;
  final VoidCallback? onMoveDown;
  final VoidCallback? onDismiss;
  final VoidCallback? onInteraction;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final foreground = primary
        ? _playerPrimaryControlTextColor(palette)
        : _playerPrimaryTextColor(palette);
    final surface = Container(
      key: ValueKey('player-control-$label'),
      width: iconOnly ? 40 : null,
      height: iconOnly ? 40 : null,
      constraints: const BoxConstraints(minHeight: 40),
      padding: iconOnly
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: primary ? palette.accent : _playerControlSurfaceColor(palette),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: iconOnly
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          if (displayText case final text?)
            SizedBox(
              width: 30,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  text,
                  maxLines: 1,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            )
          else if (mirrorIconHorizontally)
            Transform.flip(
              key: ValueKey('player-control-$label-mirrored-icon'),
              flipX: true,
              child: Icon(icon, size: 18, color: foreground),
            )
          else
            Icon(icon, size: 18, color: foreground),
          if (!iconOnly) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (!enabled) {
      final disabled = Semantics(
        label: iconOnly ? label : null,
        button: true,
        enabled: false,
        child: ExcludeFocus(
          child: IgnorePointer(child: Opacity(opacity: .38, child: surface)),
        ),
      );
      return iconOnly
          ? Tooltip(message: label, excludeFromSemantics: true, child: disabled)
          : disabled;
    }
    final control = TvFocusable(
      focusNode: focusNode,
      onPressed: () {
        onInteraction?.call();
        onPressed();
      },
      onFocusChanged: (focused) {
        if (!focused) return;
        onInteraction?.call();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          if (revealScrollStart) {
            final position = Scrollable.maybeOf(context)?.position;
            if (position != null) {
              position.animateTo(
                position.minScrollExtent,
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeOutCubic,
              );
              return;
            }
          }
          if (revealScrollEnd) {
            final position = Scrollable.maybeOf(context)?.position;
            if (position != null) {
              position.animateTo(
                position.maxScrollExtent,
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeOutCubic,
              );
              return;
            }
          }
          Scrollable.ensureVisible(
            context,
            alignment: 1,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOutCubic,
          );
        });
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        onInteraction?.call();
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowLeft) {
          moveLeftFocusNode?.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          moveRightFocusNode?.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown && onDismiss != null) {
          (onMoveDown ?? onDismiss)!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      focusScale: 1.025,
      borderRadius: BorderRadius.circular(8),
      child: surface,
    );
    if (!iconOnly) return control;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(label: label, button: true, child: control),
    );
  }
}

class _PlayerBadge extends StatelessWidget {
  const _PlayerBadge({
    required this.text,
    this.icon,
    this.semanticsLabel,
    super.key,
  });

  final String text;
  final IconData? icon;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final badge = Container(
      constraints: const BoxConstraints(maxWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: .2),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.accent.withValues(alpha: .35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon case final icon?) ...[
            Icon(icon, size: 14, color: palette.accentBright),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.accentBright,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
    final label = semanticsLabel;
    return label == null ? badge : Semantics(label: label, child: badge);
  }
}

String formatPlayerChromeDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
