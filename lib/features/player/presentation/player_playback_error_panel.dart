import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A recovery surface with its own remote focus, independent of the HUD.
/// No live backdrop blur: this must stay cheap when playback is struggling.
class PlayerPlaybackErrorPanel extends StatefulWidget {
  const PlayerPlaybackErrorPanel({
    super.key,
    required this.message,
    required this.controlsLocked,
    required this.onRetry,
    required this.onChooseStream,
    required this.onDismiss,
    required this.onExit,
    this.onNextStream,
  });

  final String message;
  final bool controlsLocked;
  final VoidCallback onRetry;
  final VoidCallback? onNextStream;
  final VoidCallback onChooseStream;
  final VoidCallback onDismiss;
  final VoidCallback onExit;

  @override
  State<PlayerPlaybackErrorPanel> createState() =>
      _PlayerPlaybackErrorPanelState();
}

class _PlayerPlaybackErrorPanelState extends State<PlayerPlaybackErrorPanel> {
  final _scope = FocusScopeNode(
    debugLabel: 'player.recovery',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final _nodes = <String, FocusNode>{
    for (final name in ['retry', 'next', 'choose', 'dismiss', 'exit'])
      name: FocusNode(debugLabel: 'player.recovery.$name'),
  };

  List<String> get _actions => [
    if (!widget.controlsLocked) ...[
      'retry',
      if (widget.onNextStream != null) 'next',
      'choose',
    ],
    'dismiss',
    'exit',
  ];

  @override
  void didUpdateWidget(covariant PlayerPlaybackErrorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Watch Party can change authority while this panel is already open.
    // A removed host-only action must not strand a guest's remote focus.
    if (oldWidget.controlsLocked != widget.controlsLocked ||
        (oldWidget.onNextStream == null) != (widget.onNextStream == null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nodes[_actions.first]!.requestFocus();
      });
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape) {
      // Keep the complete remote Back press here, rather than exposing the
      // player on key down and allowing key up to reach the route below it.
      if (event is KeyUpEvent) widget.onDismiss();
      return KeyEventResult.handled;
    }
    final backwards =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp;
    final forwards =
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown;
    if (backwards || forwards) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final actions = _actions;
        final current = actions.indexWhere((id) => _nodes[id]!.hasFocus);
        final next = current < 0
            ? 0
            : (current + (backwards ? -1 : 1)).clamp(0, actions.length - 1);
        _nodes[actions[next]]!.requestFocus();
      }
      // Consume release packets too; hidden-HUD seeking must not see them.
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      return KeyEventResult.ignored;
    }
    // Media shortcuts and other HUD commands do not act behind an error.
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _scope.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    Widget action(
      String id,
      String label,
      IconData icon,
      VoidCallback callback,
    ) {
      return TvFocusable(
        key: ValueKey('player-recovery-$id'),
        focusNode: _nodes[id],
        autofocus: id == _actions.first,
        focusScale: 1,
        onPressed: callback,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: TetoBoxStyle.decoration(palette),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: palette.primaryText),
              const SizedBox(width: 8),
              Text(
                context.tr(label),
                style: TextStyle(color: palette.primaryText, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return FocusScope(
      node: _scope,
      onKeyEvent: _handleKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ModalBarrier(dismissible: false, color: Color(0xB3000000)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Container(
                  key: const ValueKey('player-recovery-panel'),
                  constraints: const BoxConstraints(maxWidth: 760),
                  padding: const EdgeInsets.all(24),
                  decoration: TetoBoxStyle.decoration(palette),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: palette.accentBright,
                            size: 26,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              widget.message,
                              style: TextStyle(
                                color: palette.primaryText,
                                fontSize: 16,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (widget.controlsLocked) ...[
                        const SizedBox(height: 12),
                        Text(
                          context.tr(
                            'The host controls playback. Open Watch Party or Exit.',
                          ),
                          style: TextStyle(color: palette.mutedText),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          if (!widget.controlsLocked) ...[
                            action(
                              'retry',
                              'Retry stream',
                              Icons.refresh_rounded,
                              widget.onRetry,
                            ),
                            if (widget.onNextStream case final callback?)
                              action(
                                'next',
                                'Next stream',
                                Icons.skip_next_rounded,
                                callback,
                              ),
                            action(
                              'choose',
                              'Choose stream',
                              Icons.list_rounded,
                              widget.onChooseStream,
                            ),
                          ],
                          action(
                            'dismiss',
                            'Dismiss',
                            Icons.close_rounded,
                            widget.onDismiss,
                          ),
                          action(
                            'exit',
                            'Exit',
                            Icons.arrow_back_rounded,
                            widget.onExit,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
