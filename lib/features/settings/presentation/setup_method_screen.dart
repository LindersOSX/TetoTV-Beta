import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

const setupMethodRoutePath = '/setup/start';

enum _SetupMethod { television, phone }

class SetupMethodScreen extends ConsumerStatefulWidget {
  const SetupMethodScreen({this.focusPhoneOnReady = false, super.key});

  static const routePath = setupMethodRoutePath;
  final bool focusPhoneOnReady;

  @override
  ConsumerState<SetupMethodScreen> createState() => _SetupMethodScreenState();
}

class _SetupMethodScreenState extends ConsumerState<SetupMethodScreen> {
  final _televisionFocusNode = FocusNode(debugLabel: 'setup-method.tv');
  final _phoneFocusNode = FocusNode(debugLabel: 'setup-method.phone');
  bool _ready = false;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    await ref.read(setupProgressProvider.notifier).start();
    if (!mounted) return;
    setState(() => _ready = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = widget.focusPhoneOnReady
          ? _phoneFocusNode
          : _televisionFocusNode;
      if (node.canRequestFocus) {
        node.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _televisionFocusNode.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  void _choose(String route) {
    if (!_ready || _navigating) return;
    setState(() => _navigating = true);
    unawaited(GoRouter.of(context).pushReplacement<void>(route));
  }

  KeyEventResult _handleChoiceKey(
    _SetupMethod method,
    KeyEvent event, {
    required bool horizontal,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final isDirectional =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!isDirectional) return KeyEventResult.ignored;

    final moveForward = horizontal
        ? key == LogicalKeyboardKey.arrowRight
        : key == LogicalKeyboardKey.arrowDown;
    final moveBack = horizontal
        ? key == LogicalKeyboardKey.arrowLeft
        : key == LogicalKeyboardKey.arrowUp;
    if (method == _SetupMethod.television && moveForward) {
      _phoneFocusNode.requestFocus();
    } else if (method == _SetupMethod.phone && moveBack) {
      _televisionFocusNode.requestFocus();
    }

    // Consume every directional key. At either edge, and on the cross axis,
    // focus deliberately stays put instead of relying on geometry-based
    // traversal that can vary between TV launchers and phone orientations.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      key: const ValueKey('setup-method-screen'),
      backgroundColor: palette.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final padding = context.responsiveScreenPadding;
            final horizontal =
                constraints.maxWidth >= 700 &&
                constraints.maxWidth > constraints.maxHeight;
            final shortLandscape = horizontal && constraints.maxHeight < 480;
            final minHeight = (constraints.maxHeight - padding.vertical).clamp(
              0.0,
              double.infinity,
            );
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(.62, -.86),
                  radius: 1.35,
                  colors: [
                    palette.accent.withValues(alpha: .16),
                    palette.background,
                    palette.background,
                  ],
                  stops: const [0, .46, 1],
                ),
              ),
              child: SingleChildScrollView(
                padding: padding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _BrandHeader(
                            showStatus: horizontal && !shortLandscape,
                          ),
                          SizedBox(
                            height: shortLandscape
                                ? 14
                                : horizontal
                                ? 28
                                : 36,
                          ),
                          Text(
                            'How would you like to set up TetoTV?',
                            textAlign: horizontal
                                ? TextAlign.left
                                : TextAlign.center,
                            style: Theme.of(context).textTheme.displaySmall
                                ?.copyWith(
                                  fontSize: shortLandscape
                                      ? 31
                                      : horizontal
                                      ? 38
                                      : 32,
                                  height: 1.08,
                                ),
                          ),
                          SizedBox(height: shortLandscape ? 6 : 10),
                          Text(
                            'Choose the setup method that works best for you.',
                            textAlign: horizontal
                                ? TextAlign.left
                                : TextAlign.center,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          SizedBox(
                            height: shortLandscape
                                ? 16
                                : horizontal
                                ? 28
                                : 26,
                          ),
                          if (horizontal)
                            SizedBox(
                              height: shortLandscape ? 170 : 226,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: _SetupMethodCard(
                                      key: const ValueKey('setup-method-tv'),
                                      focusNode: _televisionFocusNode,
                                      enabled: _ready && !_navigating,
                                      icon: Icons.tv_rounded,
                                      title: 'Setup on device',
                                      description:
                                          'Complete every setup step directly '
                                          'on this device.',
                                      detail: 'Simple D-pad setup',
                                      compact: shortLandscape,
                                      onPressed: () =>
                                          _choose('/setup?from=method-choice'),
                                      onKeyEvent: (_, event) =>
                                          _handleChoiceKey(
                                            _SetupMethod.television,
                                            event,
                                            horizontal: true,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 22),
                                  Expanded(
                                    child: _SetupMethodCard(
                                      key: const ValueKey('setup-method-phone'),
                                      focusNode: _phoneFocusNode,
                                      enabled: _ready && !_navigating,
                                      icon: Icons.phone_android_rounded,
                                      title: 'Setup on another device',
                                      description:
                                          'Use a phone, tablet, or computer while '
                                          'this device stays on the setup screen.',
                                      detail: 'Phone-friendly setup',
                                      compact: shortLandscape,
                                      onPressed: () => _choose('/setup/phone'),
                                      onKeyEvent: (_, event) =>
                                          _handleChoiceKey(
                                            _SetupMethod.phone,
                                            event,
                                            horizontal: true,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _SetupMethodCard(
                                  key: const ValueKey('setup-method-tv'),
                                  focusNode: _televisionFocusNode,
                                  enabled: _ready && !_navigating,
                                  icon: Icons.tv_rounded,
                                  title: 'Setup on device',
                                  description:
                                      'Complete every setup step directly '
                                      'on this device.',
                                  detail: 'Simple on-device setup',
                                  compact: true,
                                  onPressed: () =>
                                      _choose('/setup?from=method-choice'),
                                  onKeyEvent: (_, event) => _handleChoiceKey(
                                    _SetupMethod.television,
                                    event,
                                    horizontal: false,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _SetupMethodCard(
                                  key: const ValueKey('setup-method-phone'),
                                  focusNode: _phoneFocusNode,
                                  enabled: _ready && !_navigating,
                                  icon: Icons.phone_android_rounded,
                                  title: 'Setup on another device',
                                  description:
                                      'Use a phone, tablet, or computer while '
                                      'this device stays on the setup screen.',
                                  detail: 'Optimized for touch',
                                  compact: true,
                                  onPressed: () => _choose('/setup/phone'),
                                  onKeyEvent: (_, event) => _handleChoiceKey(
                                    _SetupMethod.phone,
                                    event,
                                    horizontal: false,
                                  ),
                                ),
                              ],
                            ),
                          SizedBox(
                            height: shortLandscape
                                ? 12
                                : horizontal
                                ? 22
                                : 18,
                          ),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 140),
                            child: _ready
                                ? Text(
                                    'You can adjust these choices later in Settings.',
                                    key: const ValueKey(
                                      'setup-method-ready-message',
                                    ),
                                    textAlign: TextAlign.center,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  )
                                : Row(
                                    key: const ValueKey(
                                      'setup-method-preparing',
                                    ),
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: palette.accentBright,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        'Preparing setup…',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
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
            );
          },
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.showStatus});

  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
          child: Image.asset(
            'assets/branding/tetotv_icon.png',
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'TetoTV',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
        ),
        if (showStatus)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: palette.surface.withValues(alpha: .78),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: palette.primaryText.withValues(alpha: .1),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune_rounded, size: 17, color: palette.accentBright),
                const SizedBox(width: 7),
                Text(
                  'FIRST-RUN SETUP',
                  style: TextStyle(
                    color: palette.primaryText,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .8,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SetupMethodCard extends StatelessWidget {
  const _SetupMethodCard({
    required this.focusNode,
    required this.enabled,
    required this.icon,
    required this.title,
    required this.description,
    required this.detail,
    required this.onPressed,
    required this.onKeyEvent,
    this.compact = false,
    super.key,
  });

  final FocusNode focusNode;
  final bool enabled;
  final IconData icon;
  final String title;
  final String description;
  final String detail;
  final VoidCallback onPressed;
  final FocusOnKeyEventCallback onKeyEvent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final radius = BorderRadius.circular(compact ? 18 : 22);
    return Semantics(
      enabled: enabled,
      label: title,
      button: true,
      child: IgnorePointer(
        ignoring: !enabled,
        child: ExcludeFocus(
          excluding: !enabled,
          child: AnimatedOpacity(
            opacity: enabled ? 1 : .58,
            duration: const Duration(milliseconds: 140),
            child: TvFocusable(
              focusNode: focusNode,
              onPressed: onPressed,
              onKeyEvent: onKeyEvent,
              focusScale: compact ? 1.015 : 1.025,
              borderRadius: radius,
              child: Container(
                constraints: BoxConstraints(minHeight: compact ? 158 : 214),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: palette.surface.withValues(alpha: .96),
                  borderRadius: radius,
                  border: Border.all(
                    color: palette.primaryText.withValues(alpha: .1),
                  ),
                ),
                child: compact
                    ? Row(
                        children: [
                          _MethodIcon(icon: icon, compact: true),
                          const SizedBox(width: 18),
                          Expanded(
                            child: _MethodCopy(
                              title: title,
                              description: description,
                              detail: detail,
                              compact: true,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: palette.accentBright,
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _MethodIcon(icon: icon),
                              const Spacer(),
                              Icon(
                                Icons.arrow_forward_rounded,
                                color: palette.accentBright,
                                size: 28,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _MethodCopy(
                            title: title,
                            description: description,
                            detail: detail,
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
}

class _MethodIcon extends StatelessWidget {
  const _MethodIcon({required this.icon, this.compact = false});

  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    const size = 54.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: palette.selectableSurface,
        borderRadius: BorderRadius.circular(compact ? 15 : 16),
        border: Border.all(color: palette.accent.withValues(alpha: .42)),
      ),
      child: Icon(icon, size: compact ? 29 : 31, color: palette.accentBright),
    );
  }
}

class _MethodCopy extends StatelessWidget {
  const _MethodCopy({
    required this.title,
    required this.description,
    required this.detail,
    this.compact = false,
  });

  final String title;
  final String description;
  final String detail;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontSize: compact ? 19 : 23,
            fontWeight: FontWeight.w900,
          ),
        ),
        SizedBox(height: compact ? 6 : 8),
        Text(
          description,
          maxLines: compact ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: palette.mutedText),
        ),
        const SizedBox(height: 8),
        Text(
          detail.toUpperCase(),
          style: TextStyle(
            color: palette.accentBright,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: .65,
          ),
        ),
      ],
    );
  }
}
