import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:anime_tv/core/widgets/teto_apply_button.dart';
import 'package:flutter/material.dart';

/// A common page introduction for the three appearance studios.
class TetoStudioHeader extends StatelessWidget {
  const TetoStudioHeader({
    required this.title,
    required this.subtitle,
    required this.onBack,
    this.backKey,
    this.backFocusNode,
    this.onBackKeyEvent,
    super.key,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final Key? backKey;
  final FocusNode? backFocusNode;
  final FocusOnKeyEventCallback? onBackKeyEvent;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TetoBackButton(
        key: backKey,
        onPressed: onBack,
        focusNode: backFocusNode,
        onKeyEvent: onBackKeyEvent,
      ),
      const SizedBox(height: TetoUiSpace.control),
      Text(
        context.tr(title),
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
      Text(context.tr(subtitle), style: Theme.of(context).textTheme.bodyLarge),
    ],
  );
}

class TetoStudioSectionTitle extends StatelessWidget {
  const TetoStudioSectionTitle(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: TetoUiSpace.compact),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    ),
  );
}

/// Draws the same rounded, theme-aware focus card around nested controls.
class TetoStudioFocusSurface extends StatefulWidget {
  const TetoStudioFocusSurface({required this.child, super.key});

  final Widget child;

  @override
  State<TetoStudioFocusSurface> createState() => _TetoStudioFocusSurfaceState();
}

class _TetoStudioFocusSurfaceState extends State<TetoStudioFocusSurface> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    skipTraversal: true,
    onFocusChange: (focused) => setState(() => _focused = focused),
    child: AnimatedContainer(
      duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
      curve: TetoUiMotion.curve,
      decoration: TetoBoxStyle.decoration(
        context.appPalette,
        focused: _focused,
      ),
      child: Material(type: MaterialType.transparency, child: widget.child),
    ),
  );
}

/// Matches a preview's frame to the option cards without styling its content.
class TetoStudioPreviewFrame extends StatelessWidget {
  const TetoStudioPreviewFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(TetoUiSpace.control),
    decoration: TetoBoxStyle.decoration(
      context.appPalette,
      color: context.appPalette.surface,
    ),
    child: child,
  );
}

/// Apply and reset have one order, spacing, and button treatment everywhere.
class TetoStudioActions extends StatelessWidget {
  const TetoStudioActions({
    required this.onApply,
    required this.onReset,
    this.applyLabel = 'Apply',
    this.applyEnabled = true,
    this.applyIcon,
    this.applyKey,
    this.resetKey,
    this.applyFocusNode,
    this.resetFocusNode,
    this.onApplyKeyEvent,
    this.onResetKeyEvent,
    super.key,
  });

  final VoidCallback? onApply;
  final VoidCallback? onReset;
  final String applyLabel;

  /// Keeps an unapplied action in the TV focus row while showing its idle state.
  final bool applyEnabled;
  final Widget? applyIcon;
  final Key? applyKey;
  final Key? resetKey;
  final FocusNode? applyFocusNode;
  final FocusNode? resetFocusNode;
  final FocusOnKeyEventCallback? onApplyKeyEvent;
  final FocusOnKeyEventCallback? onResetKeyEvent;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: TetoUiSpace.control,
    runSpacing: TetoUiSpace.compact,
    children: [
      TetoApplyButton(
        onKeyEvent: onApplyKeyEvent,
        buttonKey: applyKey,
        focusNode: applyFocusNode,
        enabled: applyEnabled,
        onPressed: onApply,
        icon: applyIcon ?? const Icon(Icons.check_rounded),
        label: applyLabel,
      ),
      _TetoStudioActionFocusFrame(
        onKeyEvent: onResetKeyEvent,
        child: OutlinedButton.icon(
          key: resetKey,
          focusNode: resetFocusNode,
          onPressed: onReset,
          style: const ButtonStyle(
            overlayColor: WidgetStatePropertyAll(Colors.transparent),
          ),
          icon: const Icon(Icons.restart_alt_rounded),
          label: Text(context.tr('Reset defaults')),
        ),
      ),
    ],
  );
}

class _TetoStudioActionFocusFrame extends StatefulWidget {
  const _TetoStudioActionFocusFrame({required this.child, this.onKeyEvent});

  final Widget child;
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<_TetoStudioActionFocusFrame> createState() =>
      _TetoStudioActionFocusFrameState();
}

class _TetoStudioActionFocusFrameState
    extends State<_TetoStudioActionFocusFrame> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: widget.onKeyEvent,
    onFocusChange: (focused) => setState(() => _focused = focused),
    child: AnimatedContainer(
      duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
      curve: TetoUiMotion.curve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: context.appPalette.focusGlow,
                  blurRadius: 11,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: widget.child,
    ),
  );
}
