import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';

/// Shared loading, error and no-content treatment for browsing and sources.
/// The surrounding screen owns actions and focus order; this only presents
/// the status consistently without changing card or artwork proportions.
class TetoBrowseStatus extends StatelessWidget {
  const TetoBrowseStatus({
    required this.icon,
    required this.title,
    required this.message,
    this.actions,
    this.indicator,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? actions;
  final Widget? indicator;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  key: const ValueKey('browse-status-panel'),
                  padding: const EdgeInsets.all(24),
                  decoration: TetoBoxStyle.decoration(palette),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 70,
                        height: 70,
                        decoration: TetoBoxStyle.decoration(
                          palette,
                          color: palette.accent.withValues(alpha: .16),
                        ),
                        child: indicator == null
                            ? Icon(icon, size: 34, color: palette.accentBright)
                            : Padding(
                                padding: const EdgeInsets.all(19),
                                child: indicator,
                              ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        context.tr(title),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (message.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          context.tr(message),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(color: palette.mutedText),
                        ),
                      ],
                      if (actions != null) ...[
                        const SizedBox(height: 18),
                        actions!,
                      ],
                    ],
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

class TetoBrowseLoading extends StatelessWidget {
  const TetoBrowseLoading({
    this.title = 'Loading',
    this.message = '',
    super.key,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.tr(title),
    liveRegion: true,
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  key: const ValueKey('browse-loading'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 42,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: context.appPalette.accentBright,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.tr(title),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (message.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        context.tr(message),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: context.appPalette.mutedText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A consistent, remote-friendly recovery action; focus only adds an outline.
class TetoRetryButton extends StatelessWidget {
  const TetoRetryButton({
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChanged,
    super.key,
  });

  final VoidCallback onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChanged;

  @override
  Widget build(BuildContext context) => TvFocusable(
    onPressed: onPressed,
    autofocus: autofocus,
    focusNode: focusNode,
    onKeyEvent: onKeyEvent,
    onFocusChanged: onFocusChanged,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: TetoBoxStyle.decoration(context.appPalette),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.refresh_rounded,
            color: context.appPalette.accentBright,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            context.tr('Retry'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
    ),
  );
}
