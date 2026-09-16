import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'dart:async';

import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_navigation.dart';
import 'package:anime_tv/features/settings/application/setup_progress_controller.dart';
import 'package:anime_tv/features/settings/presentation/language_selection_screen.dart';
import 'package:anime_tv/features/settings/presentation/setup_brand_header.dart';
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
  final _backFocusNode = FocusNode(debugLabel: 'setup-method.back');
  final _televisionFocusNode = FocusNode(debugLabel: 'setup-method.tv');
  final _phoneFocusNode = FocusNode(debugLabel: 'setup-method.phone');
  _SetupMethod _methodBeforeBack = _SetupMethod.television;
  bool _ready = false;
  bool _navigating = false;
  bool _choosingLanguage = false;

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
      if (!mounted || _choosingLanguage) return;
      final node = widget.focusPhoneOnReady
          ? _phoneFocusNode
          : _televisionFocusNode;
      if (node.canRequestFocus) {
        requestTvFocusAndReveal(node, towardEnd: true);
      }
    });
  }

  @override
  void dispose() {
    _backFocusNode.dispose();
    _televisionFocusNode.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  void _choose(String route) {
    if (!_ready || _navigating) return;
    setState(() => _navigating = true);
    unawaited(GoRouter.of(context).pushReplacement<void>(route));
  }

  void _backToLanguage() {
    if (_navigating || _choosingLanguage) return;
    // Revisiting a step is local navigation, not a reset of stored preferences.
    setState(() => _choosingLanguage = true);
  }

  void _returnToMethods() {
    setState(() => _choosingLanguage = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ready && _televisionFocusNode.canRequestFocus) {
        requestTvFocusAndReveal(_televisionFocusNode, towardEnd: true);
      }
    });
  }

  KeyEventResult _handleBackKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.escape &&
        key != LogicalKeyboardKey.goBack &&
        key != LogicalKeyboardKey.browserBack) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _backToLanguage();
    return KeyEventResult.handled;
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

    if (key == LogicalKeyboardKey.arrowUp &&
        (horizontal || method == _SetupMethod.television)) {
      _methodBeforeBack = method;
      requestTvFocusAndReveal(_backFocusNode);
      return KeyEventResult.handled;
    }

    final moveForward = horizontal
        ? key == LogicalKeyboardKey.arrowRight
        : key == LogicalKeyboardKey.arrowDown;
    final moveBack = horizontal
        ? key == LogicalKeyboardKey.arrowLeft
        : key == LogicalKeyboardKey.arrowUp;
    if (method == _SetupMethod.television && moveForward) {
      requestTvFocusAndReveal(_phoneFocusNode, towardEnd: true);
    } else if (method == _SetupMethod.phone && moveBack) {
      requestTvFocusAndReveal(_televisionFocusNode);
    }

    // Back is explicitly above the choices. Other edges remain stable instead
    // of relying on geometry that varies between launchers and orientations.
    return KeyEventResult.handled;
  }

  KeyEventResult _handleBackButtonKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight) {
      if (_ready && !_navigating) {
        final target = _methodBeforeBack == _SetupMethod.phone
            ? _phoneFocusNode
            : _televisionFocusNode;
        requestTvFocusAndReveal(target, towardEnd: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (_choosingLanguage) {
      return LanguageSelectionScreen(onLanguageSelected: _returnToMethods);
    }
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToLanguage();
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _handleBackKey,
        child: _buildMethodScreen(context),
      ),
    );
  }

  Widget _buildMethodScreen(BuildContext context) {
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
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Focus(
                                canRequestFocus: false,
                                onKeyEvent: _handleBackButtonKey,
                                child: IconButton.filledTonal(
                                  key: const ValueKey('setup-method-back'),
                                  focusNode: _backFocusNode,
                                  tooltip: context.tr('Back'),
                                  onPressed: _navigating
                                      ? null
                                      : _backToLanguage,
                                  icon: const Icon(Icons.arrow_back_rounded),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: SetupBrandHeader(
                                  showStatus: horizontal && !shortLandscape,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(
                            height: shortLandscape
                                ? 14
                                : horizontal
                                ? 28
                                : 36,
                          ),
                          LocalizedText(
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
                          LocalizedText(
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
                                ? LocalizedText(
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
                                      Flexible(
                                        child: LocalizedText(
                                          'Preparing setup…',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                        ),
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
        LocalizedText(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontSize: compact ? 19 : 23,
            fontWeight: FontWeight.w900,
          ),
        ),
        SizedBox(height: compact ? 6 : 8),
        LocalizedText(
          description,
          maxLines: compact ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: palette.mutedText),
        ),
        const SizedBox(height: 8),
        LocalizedText(
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
