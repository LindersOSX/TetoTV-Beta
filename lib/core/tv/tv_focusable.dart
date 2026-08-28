import 'dart:async';

import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/interaction_sound_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _TvSecondaryActivateIntent extends Intent {
  const _TvSecondaryActivateIntent();
}

class TvFocusable extends StatefulWidget {
  const TvFocusable({
    required this.child,
    required this.onPressed,
    this.autofocus = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.focusScale = 1.045,
    this.focusNode,
    this.onFocusChanged,
    this.onLongPress,
    this.onKeyEvent,
    super.key,
  });

  final Widget child;
  final VoidCallback onPressed;
  final bool autofocus;
  final BorderRadius borderRadius;
  final double focusScale;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChanged;
  final VoidCallback? onLongPress;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  static const _remoteHoldThreshold = Duration(milliseconds: 650);
  static const _remoteReleaseDebounce = Duration(milliseconds: 180);

  late final FocusNode _fallbackFocusNode;
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;
  bool _navigationSoundsEnabled = true;
  bool _clickSoundsEnabled = true;
  PhysicalKeyboardKey? _remotePressPhysicalKey;
  Timer? _holdTimer;
  Timer? _remoteReleaseTimer;
  bool _holdEligible = false;
  bool _holdEligibleAtRelease = false;

  FocusNode get _focusNode => widget.focusNode ?? _fallbackFocusNode;

  void _activate(VoidCallback? action) {
    if (action == null) return;
    if (_clickSoundsEnabled) {
      unawaited(SystemSound.play(SystemSoundType.click));
    }
    action();
  }

  @override
  void initState() {
    super.initState();
    _fallbackFocusNode = FocusNode(debugLabel: 'TV mouse/D-pad control');
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _remoteReleaseTimer?.cancel();
    _fallbackFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final soundScope = InteractionSoundScope.maybeOf(context);
    _navigationSoundsEnabled = soundScope?.navigationEnabled ?? true;
    _clickSoundsEnabled = soundScope?.clickEnabled ?? true;
  }

  KeyEventResult _handleRemoteActivation(FocusNode node, KeyEvent event) {
    final customResult = widget.onKeyEvent?.call(node, event);
    if (customResult == KeyEventResult.handled) {
      return KeyEventResult.handled;
    }
    // Controls without a secondary/hold action use Flutter's standard
    // ActivateIntent. Keeping their Enter event unconsumed also lets parent
    // keyboard/dialog handlers observe physical Enter.
    if (widget.onLongPress == null) return KeyEventResult.ignored;
    final isActivationKey =
        event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA ||
        _remotePressPhysicalKey == event.physicalKey;
    if (!isActivationKey) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      // Chromecast/Google TV firmware can report held DPAD_CENTER packets as
      // additional KeyDownEvents or rapid Down/Up pairs instead of repeat
      // events. A Down arriving inside the quiet-release window belongs to
      // the original physical hold, so keep its original hold timer running.
      if (_remotePressPhysicalKey == event.physicalKey) {
        _remoteReleaseTimer?.cancel();
        _remoteReleaseTimer = null;
        return KeyEventResult.handled;
      }
      _clearRemotePressState();
      _remotePressPhysicalKey = event.physicalKey;
      _holdTimer = Timer(_remoteHoldThreshold, () => _holdEligible = true);
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    if (event is KeyUpEvent) {
      final pressedKey = _remotePressPhysicalKey;
      if (pressedKey != event.physicalKey) {
        return KeyEventResult.handled;
      }
      // Do not activate immediately. Some Chromecast/Google TV firmware sends
      // a synthetic Up between every held packet. A brief quiet period lets a
      // following Down rejoin the same press and prevents click-through into
      // a dialog opened by the eventual long-press action.
      _holdEligibleAtRelease = _holdEligible;
      _remoteReleaseTimer?.cancel();
      _remoteReleaseTimer = Timer(_remoteReleaseDebounce, _completeRemotePress);
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  void _completeRemotePress() {
    if (_remotePressPhysicalKey == null) return;
    final longPress = _holdEligibleAtRelease;
    _clearRemotePressState();
    if (!mounted) return;
    _activate(
      longPress && widget.onLongPress != null
          ? widget.onLongPress
          : widget.onPressed,
    );
  }

  void _clearRemotePressState() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _remoteReleaseTimer?.cancel();
    _remoteReleaseTimer = null;
    _remotePressPhysicalKey = null;
    _holdEligible = false;
    _holdEligibleAtRelease = false;
  }

  void _handleFocus(bool focused) {
    if (!focused) {
      _clearRemotePressState();
    }
    setState(() => _focused = focused);
    widget.onFocusChanged?.call(focused);
    if (focused) {
      if (_navigationSoundsEnabled && _directionalKeyIsPressed()) {
        unawaited(SystemSound.play(SystemSoundType.click));
      }
      // DirectionalFocusTraversalPolicy reveals the selected control itself.
      // Starting another animation here used to recenter already-visible
      // controls and changed the geometry beneath the next D-pad event.
    }
  }

  bool _directionalKeyIsPressed() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.arrowLeft) ||
        pressed.contains(LogicalKeyboardKey.arrowRight) ||
        pressed.contains(LogicalKeyboardKey.arrowUp) ||
        pressed.contains(LogicalKeyboardKey.arrowDown);
  }

  void _handleHover(bool hovering) {
    if (_hovered != hovering) setState(() => _hovered = hovering);
    if (hovering) _focusNode.requestFocus();
  }

  void _handlePress(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final highlighted = _focused || _hovered || _pressed;
    return Semantics(
      button: true,
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _handleRemoteActivation,
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.contextMenu):
                _TvSecondaryActivateIntent(),
          },
          child: FocusableActionDetector(
            focusNode: _focusNode,
            autofocus: widget.autofocus,
            onFocusChange: _handleFocus,
            onShowHoverHighlight: _handleHover,
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  _activate(widget.onPressed);
                  return null;
                },
              ),
              _TvSecondaryActivateIntent:
                  CallbackAction<_TvSecondaryActivateIntent>(
                    onInvoke: (_) {
                      _activate(widget.onLongPress);
                      return null;
                    },
                  ),
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => _handlePress(true),
                onTapCancel: () => _handlePress(false),
                onTapUp: (_) => _handlePress(false),
                onTap: () {
                  _focusNode.requestFocus();
                  _activate(widget.onPressed);
                },
                onLongPress: widget.onLongPress == null
                    ? null
                    : () => _activate(widget.onLongPress),
                child: AnimatedScale(
                  scale: highlighted ? widget.focusScale : 1,
                  duration: const Duration(milliseconds: 80),
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    decoration: BoxDecoration(
                      borderRadius: widget.borderRadius,
                      boxShadow: highlighted
                          ? [
                              // The dark outer keyline keeps the Teto-red ring
                              // distinct from primary red buttons; the red glow
                              // remains visible on black and pale artwork.
                              BoxShadow(
                                color: palette.focusInnerKeyline,
                                blurRadius: 0,
                                spreadRadius: 2,
                              ),
                              BoxShadow(
                                color: palette.focusGlow,
                                blurRadius: 11,
                                spreadRadius: 2,
                              ),
                            ]
                          : const [],
                    ),
                    foregroundDecoration: BoxDecoration(
                      borderRadius: widget.borderRadius,
                      border: Border.all(
                        color: highlighted
                            ? palette.focusRing
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: widget.borderRadius,
                      child: Stack(
                        fit: StackFit.passthrough,
                        children: [
                          widget.child,
                          Positioned.fill(
                            child: IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: highlighted ? 1 : 0,
                                duration: const Duration(milliseconds: 80),
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: widget.borderRadius,
                                      border: Border.all(
                                        color: palette.focusInnerKeyline,
                                        width: 1,
                                      ),
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
