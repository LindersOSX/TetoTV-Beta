import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/theme/teto_color_presets.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_studio_components.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const themeStudioRoutePath = '/settings/theme-studio';

class ThemeStudioScreen extends ConsumerStatefulWidget {
  const ThemeStudioScreen({super.key});

  static const routePath = themeStudioRoutePath;

  @override
  ConsumerState<ThemeStudioScreen> createState() => _ThemeStudioScreenState();
}

class _ThemeStudioScreenState extends ConsumerState<ThemeStudioScreen> {
  late AppThemePalette _draft;
  late bool _contrastGuardEnabled;
  final _backFocusNode = FocusNode(debugLabel: 'theme-studio.back');
  final _contrastFocusNode = FocusNode(debugLabel: 'theme-studio.contrast');
  final _applyFocusNode = FocusNode(debugLabel: 'theme-studio.apply');
  final _resetFocusNode = FocusNode(debugLabel: 'theme-studio.reset');
  late final Map<AppThemeColorRole, FocusNode> _roleFocusNodes = {
    for (final role in AppThemeColorRole.values)
      role: FocusNode(debugLabel: 'theme-studio.${role.name}'),
  };
  bool _dirty = false;
  bool _editorOpen = false;
  bool _restoredSavedTheme = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(themeStudioControllerProvider);
    _draft = saved.palette;
    _contrastGuardEnabled = saved.contrastGuardEnabled;
    _restoredSavedTheme = saved.loaded;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus(_roleFocusNodes[AppThemeColorRole.background]!);
    });
  }

  @override
  void dispose() {
    _backFocusNode.dispose();
    _contrastFocusNode.dispose();
    _applyFocusNode.dispose();
    _resetFocusNode.dispose();
    for (final node in _roleFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _focus(FocusNode node) {
    if (!node.canRequestFocus) return;
    node.requestFocus();
    final targetContext = node.context;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: .5,
        duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
      );
    }
  }

  bool _isDirectionalPress(KeyEvent event) =>
      event is KeyDownEvent || event is KeyRepeatEvent;

  KeyEventResult _handleRoleKey(AppThemeColorRole role, KeyEvent event) {
    if (!_isDirectionalPress(event)) return KeyEventResult.ignored;
    final roles = AppThemeColorRole.values;
    final index = roles.indexOf(role);
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focus(index == 0 ? _backFocusNode : _roleFocusNodes[roles[index - 1]]!);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focus(
        index == roles.length - 1
            ? _contrastFocusNode
            : _roleFocusNodes[roles[index + 1]]!,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      // The preview is informational. Keep horizontal D-pad presses in the
      // editable color column instead of allowing geometry-based jumps.
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleBackKey(FocusNode _, KeyEvent event) {
    if (!_isDirectionalPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _focus(_roleFocusNodes[AppThemeColorRole.background]!);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleContrastKey(FocusNode _, KeyEvent event) {
    if (!_isDirectionalPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focus(_roleFocusNodes[AppThemeColorRole.values.last]!);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focus(
        _applyFocusNode.canRequestFocus ? _applyFocusNode : _resetFocusNode,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleApplyKey(FocusNode _, KeyEvent event) {
    if (!_isDirectionalPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focus(_contrastFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _focus(_resetFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleResetKey(FocusNode _, KeyEvent event) {
    if (!_isDirectionalPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focus(_contrastFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        _applyFocusNode.canRequestFocus) {
      _focus(_applyFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _adoptSavedTheme(ThemeStudioState next) {
    if (_dirty || _restoredSavedTheme || !next.loaded) return;
    _restoredSavedTheme = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dirty) return;
      setState(() {
        _draft = next.palette;
        _contrastGuardEnabled = next.contrastGuardEnabled;
      });
    });
  }

  Future<void> _editColor(AppThemeColorRole role) async {
    final initial = _draft.colorFor(role);
    setState(() => _editorOpen = true);
    final selected = await showTetoDialog<Color>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ColorEditorDialog(
        role: role,
        initialColor: initial,
        previewPalette: _draft,
      ),
    );
    if (!mounted) return;
    setState(() => _editorOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus(_roleFocusNodes[role]!);
    });
    if (selected == null || selected == initial) return;
    setState(() {
      _draft = _draft.withRole(role, selected);
      _dirty = true;
    });
  }

  Future<void> _apply() async {
    if (_saving || !_dirty) return;
    final report = ThemeContrastReport.forPalette(_draft);
    if (_contrastGuardEnabled && report.hasIssues) {
      _showMessage('Fix the contrast warnings or turn off the safeguard.');
      return;
    }
    setState(() => _saving = true);
    final result = await ref
        .read(themeStudioControllerProvider.notifier)
        .apply(palette: _draft, contrastGuardEnabled: _contrastGuardEnabled);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result == ThemeApplyResult.applied) _dirty = false;
    });
    _showMessage(
      result == ThemeApplyResult.applied
          ? 'Theme applied.'
          : 'The readability safeguard blocked this theme.',
    );
  }

  Future<void> _reset() async {
    await ref.read(themeStudioControllerProvider.notifier).resetDefaults();
    if (!mounted) return;
    setState(() {
      _draft = AppThemePalette.defaults;
      _contrastGuardEnabled = true;
      _dirty = false;
      _restoredSavedTheme = true;
    });
    _showMessage('TetoTV colors restored.');
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: LocalizedText(message)));
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(themeStudioControllerProvider);
    _adoptSavedTheme(saved);
    final report = ThemeContrastReport.forPalette(_draft);
    final applyBlocked = _contrastGuardEnabled && report.hasIssues;

    return PopScope(
      canPop: !_editorOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editorOpen) {
          Navigator.of(context, rootNavigator: true).maybePop();
        }
      },
      child: Theme(
        data: AppTheme.darkFor(_draft),
        child: Builder(
          builder: (context) {
            final palette = context.appPalette;
            return Scaffold(
              key: const ValueKey('theme-studio-screen'),
              backgroundColor: palette.background,
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: TetoUiSpace.pageCompact,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 12),
                          TetoStudioHeader(
                            title: 'Theme Studio',
                            subtitle: 'Make TetoTV yours',
                            onBack: () => Navigator.maybePop(context),
                            backKey: const ValueKey('theme-studio-back'),
                            backFocusNode: _backFocusNode,
                            onBackKeyEvent: _handleBackKey,
                          ),
                          const SizedBox(height: 16),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final wide =
                                    constraints.maxWidth >= 820 ||
                                    (constraints.maxWidth >= 660 &&
                                        constraints.maxHeight < 320);
                                // These few color roles keep their focus nodes
                                // mounted so the remote graph can always reach
                                // the guard and Apply/Reset below the fold.
                                final controls = SingleChildScrollView(
                                  key: const ValueKey('theme-studio-controls'),
                                  padding: EdgeInsets.only(
                                    right: wide ? 12 : 0,
                                    bottom: 96,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      LocalizedText(
                                        'Change the app canvas, panels, focus color '
                                        'and text. Your saved theme is shared by '
                                        'phone and TV layouts.',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyLarge,
                                      ),
                                      const SizedBox(height: 16),
                                      _ColorRolesPanel(
                                        palette: _draft,
                                        onEdit: _editColor,
                                        focusNodes: _roleFocusNodes,
                                        onKeyEvent: _handleRoleKey,
                                      ),
                                      const SizedBox(height: 18),
                                      Focus(
                                        canRequestFocus: false,
                                        onKeyEvent: _handleContrastKey,
                                        child: _ContrastGuardCard(
                                          enabled: _contrastGuardEnabled,
                                          report: report,
                                          focusNode: _contrastFocusNode,
                                          onChanged: (value) => setState(() {
                                            _contrastGuardEnabled = value;
                                            _dirty = true;
                                          }),
                                        ),
                                      ),
                                      const SizedBox(height: 22),
                                      TetoStudioActions(
                                        key: const ValueKey(
                                          'theme-studio-actions',
                                        ),
                                        applyKey: const ValueKey(
                                          'theme-studio-apply',
                                        ),
                                        resetKey: const ValueKey(
                                          'theme-studio-reset',
                                        ),
                                        applyFocusNode: _applyFocusNode,
                                        resetFocusNode: _resetFocusNode,
                                        onApplyKeyEvent: _handleApplyKey,
                                        onResetKeyEvent: _handleResetKey,
                                        applyEnabled:
                                            _dirty && !_saving && !applyBlocked,
                                        onApply: _saving || applyBlocked
                                            ? null
                                            : _apply,
                                        onReset: _reset,
                                        applyLabel: _saving
                                            ? 'Applying…'
                                            : 'Apply theme',
                                        applyIcon: _saving
                                            ? const SizedBox.square(
                                                dimension: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : null,
                                      ),
                                    ],
                                  ),
                                );
                                final preview = _ThemePreview(palette: _draft);
                                if (wide) {
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: controls),
                                      const SizedBox(width: 18),
                                      Expanded(
                                        child: SizedBox(
                                          height: constraints.maxHeight
                                              .clamp(0, 390)
                                              .toDouble(),
                                          child: preview,
                                        ),
                                      ),
                                    ],
                                  );
                                }
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // Keep room for options even on short,
                                    // landscape layouts or enlarged text.
                                    SizedBox(
                                      height: (constraints.maxHeight * .4)
                                          .clamp(0, 230)
                                          .toDouble(),
                                      child: preview,
                                    ),
                                    const SizedBox(height: 12),
                                    Expanded(child: controls),
                                  ],
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
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

class _ColorRolesPanel extends StatelessWidget {
  const _ColorRolesPanel({
    required this.palette,
    required this.onEdit,
    required this.focusNodes,
    required this.onKeyEvent,
  });

  final AppThemePalette palette;
  final ValueChanged<AppThemeColorRole> onEdit;
  final Map<AppThemeColorRole, FocusNode> focusNodes;
  final KeyEventResult Function(AppThemeColorRole role, KeyEvent event)
  onKeyEvent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TetoStudioSectionTitle(context.tr('App colors')),
        for (final role in AppThemeColorRole.values) ...[
          _ColorRoleTile(
            role: role,
            color: palette.colorFor(role),
            autofocus: role == AppThemeColorRole.background,
            focusNode: focusNodes[role]!,
            onKeyEvent: (_, event) => onKeyEvent(role, event),
            onPressed: () => onEdit(role),
          ),
          if (role != AppThemeColorRole.values.last) const SizedBox(height: 9),
        ],
      ],
    );
  }
}

class _ColorRoleTile extends StatelessWidget {
  const _ColorRoleTile({
    required this.role,
    required this.color,
    required this.autofocus,
    required this.focusNode,
    required this.onKeyEvent,
    required this.onPressed,
  });

  final AppThemeColorRole role;
  final Color color;
  final bool autofocus;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return TvFocusable(
      onPressed: onPressed,
      autofocus: autofocus,
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
      child: Container(
        key: ValueKey('theme-color-${role.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: TetoBoxStyle.decoration(palette),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: contrastForeground(color).withValues(alpha: .32),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LocalizedText(
                    role.displayName,
                    style: TextStyle(
                      color: palette.primaryText,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  LocalizedText(
                    role.description,
                    style: TextStyle(color: palette.mutedText, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatOpaqueHexColor(color),
              style: TextStyle(
                color: palette.mutedText,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: palette.accentBright),
          ],
        ),
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.palette});

  final AppThemePalette palette;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Live theme preview',
      child: TetoStudioPreviewFrame(
        key: const ValueKey('theme-live-preview'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr('Live preview'),
              style: TextStyle(
                color: palette.mutedText,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 9),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      // Keep a readable sample canvas before fitting it into
                      // compact previews, rather than wrapping its fixed-height
                      // demo cards into too many lines at phone widths.
                      width: constraints.maxWidth.clamp(420, 560).toDouble(),
                      child: _buildSample(context),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSample(BuildContext context) => Container(
    key: const ValueKey('theme-preview-sample'),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: palette.background,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: palette.focusRing, width: 2),
      boxShadow: [
        BoxShadow(color: palette.focusGlow, blurRadius: 16, spreadRadius: 1),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: palette.accent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: contrastForeground(palette.accent),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LocalizedText(
                    'Featured show',
                    style: TextStyle(
                      color: palette.primaryText,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  LocalizedText(
                    'Continue watching · Episode 7',
                    style: TextStyle(color: palette.mutedText, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          height: 152,
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                width: 88,
                decoration: BoxDecoration(
                  color: palette.surfaceRaised,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(14),
                  ),
                ),
                child: Icon(
                  Icons.movie_outlined,
                  size: 34,
                  color: palette.mutedText,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      LocalizedText(
                        'Your library',
                        style: TextStyle(
                          color: palette.primaryText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      LocalizedText(
                        'Panels, labels and focus states update here.',
                        style: TextStyle(
                          color: palette.mutedText,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        height: 5,
                        decoration: BoxDecoration(
                          color: palette.surfaceRaised,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: .62,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: palette.accentBright,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.accent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: LocalizedText(
                  'Play',
                  style: TextStyle(
                    color: contrastForeground(palette.accent),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.selectableSurface,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: palette.focusRing, width: 2),
                ),
                child: LocalizedText(
                  'Focused',
                  style: TextStyle(
                    color: palette.primaryText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ContrastGuardCard extends StatelessWidget {
  const _ContrastGuardCard({
    required this.enabled,
    required this.report,
    required this.focusNode,
    required this.onChanged,
  });

  final bool enabled;
  final ThemeContrastReport report;
  final FocusNode focusNode;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final warning = report.hasIssues;
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, _) => AnimatedContainer(
        key: const ValueKey('theme-contrast-guard-card'),
        duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
        curve: TetoUiMotion.curve,
        decoration:
            TetoBoxStyle.decoration(
              palette,
              focused: focusNode.hasFocus,
            ).copyWith(
              border: warning && enabled && !focusNode.hasFocus
                  ? Border.all(color: const Color(0xFFFFB74D))
                  : null,
            ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Theme(
                  data: Theme.of(context).copyWith(
                    focusColor: Colors.transparent,
                    hoverColor: Colors.transparent,
                    splashColor: Colors.transparent,
                  ),
                  child: SwitchListTile(
                    key: const ValueKey('theme-contrast-guard'),
                    focusNode: focusNode,
                    contentPadding: EdgeInsets.zero,
                    title: LocalizedText(
                      'Protect readable contrast',
                      style: TextStyle(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: LocalizedText(
                      'Prevents a theme from hiding text or TV focus rings.',
                      style: TextStyle(color: palette.mutedText),
                    ),
                    value: enabled,
                    onChanged: onChanged,
                  ),
                ),
                if (warning) ...[
                  const SizedBox(height: 4),
                  for (final issue in report.issues)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.warning_amber_rounded,
                            size: 18,
                            color: Color(0xFFFFB74D),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LocalizedText(
                              issue,
                              style: TextStyle(
                                color: palette.primaryText,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!enabled)
                    LocalizedText(
                      'Low-contrast theme allowed because the safeguard is off.',
                      style: TextStyle(color: palette.mutedText, fontSize: 12),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorEditorDialog extends StatefulWidget {
  const _ColorEditorDialog({
    required this.role,
    required this.initialColor,
    required this.previewPalette,
  });

  final AppThemeColorRole role;
  final Color initialColor;
  final AppThemePalette previewPalette;

  @override
  State<_ColorEditorDialog> createState() => _ColorEditorDialogState();
}

class _ColorEditorDialogState extends State<_ColorEditorDialog> {
  late Color _color;
  late final TextEditingController _hexController;
  late final FocusNode _hexFocusNode;
  final _pickerKey = GlobalKey<_BuiltInColorPickerState>();
  final _hexToggleFocusNode = FocusNode(debugLabel: 'theme-studio.hex-toggle');
  final _cancelFocusNode = FocusNode(debugLabel: 'theme-studio.cancel');
  final _useColorFocusNode = FocusNode(debugLabel: 'theme-studio.use-color');
  bool _showHexEntry = false;
  bool _closing = false;
  String? _hexError;

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
    _hexController = TextEditingController(text: formatOpaqueHexColor(_color));
    _hexFocusNode = FocusNode(debugLabel: 'theme-studio.hex');
  }

  @override
  void dispose() {
    _hexController.dispose();
    _hexFocusNode.dispose();
    _hexToggleFocusNode.dispose();
    _cancelFocusNode.dispose();
    _useColorFocusNode.dispose();
    super.dispose();
  }

  bool _isNavigationPress(KeyEvent event) =>
      event is KeyDownEvent || event is KeyRepeatEvent;

  void _focus(FocusNode node) {
    if (!node.canRequestFocus) return;
    node.requestFocus();
    final targetContext = node.context;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: .5,
        duration: TetoUiMotion.duration(targetContext, TetoUiMotion.focus),
      );
    }
  }

  void _close([Color? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context, rootNavigator: true).pop(result);
  }

  void _setColor(Color color) {
    setState(() {
      _color = color;
      _hexController.text = formatOpaqueHexColor(color);
      _hexError = null;
    });
  }

  void _toggleHexEntry() {
    setState(() {
      _showHexEntry = !_showHexEntry;
      _hexError = null;
    });
    if (_showHexEntry) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hexFocusNode.requestFocus();
      });
    }
  }

  void _applyHex(String value) {
    final parsed = parseOpaqueHexColor(value);
    setState(() {
      if (parsed == null) {
        _hexError = 'Use a 6-digit color such as #E52B50.';
      } else {
        _color = parsed;
        _hexController.text = formatOpaqueHexColor(parsed);
        _hexError = null;
      }
    });
  }

  KeyEventResult _handleDialogKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack)) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleHexToggleKey(FocusNode _, KeyEvent event) {
    if (!_isNavigationPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _pickerKey.currentState?.focusSelected();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focus(_showHexEntry ? _hexFocusNode : _cancelFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleHexFieldKey(FocusNode _, KeyEvent event) {
    if (!_isNavigationPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focus(_hexToggleFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focus(_cancelFocusNode);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleCancelKey(FocusNode _, KeyEvent event) {
    if (!_isNavigationPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focus(_showHexEntry ? _hexFocusNode : _hexToggleFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _focus(_useColorFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleUseColorKey(FocusNode _, KeyEvent event) {
    if (!_isNavigationPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _focus(_showHexEntry ? _hexFocusNode : _hexToggleFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _focus(_cancelFocusNode);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.previewPalette.withRole(widget.role, _color);
    return Theme(
      data: AppTheme.darkFor(preview),
      child: Builder(
        builder: (context) {
          final palette = context.appPalette;
          return Focus(
            canRequestFocus: false,
            onKeyEvent: _handleDialogKey,
            child: Dialog(
              backgroundColor: TetoBoxStyle.fill(palette),
              shape: TetoBoxStyle.shape(palette),
              insetPadding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 720,
                  maxHeight: (MediaQuery.sizeOf(context).height - 40)
                      .clamp(240, 760)
                      .toDouble(),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LocalizedText(
                        widget.role.displayName,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 6),
                      LocalizedText(
                        'Choose a built-in color with the D-pad. Exact hex '
                        'entry is available as an optional advanced choice.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Container(
                            key: const ValueKey('theme-editor-swatch'),
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              color: _color,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: contrastForeground(
                                  _color,
                                ).withValues(alpha: .36),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                LocalizedText(
                                  'Selected color',
                                  style: TextStyle(
                                    color: palette.mutedText,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  formatOpaqueHexColor(_color),
                                  key: const ValueKey(
                                    'theme-editor-selected-hex',
                                  ),
                                  style: TextStyle(
                                    color: palette.primaryText,
                                    fontFamily: 'monospace',
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      LocalizedText(
                        'Built-in colors',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      _BuiltInColorPicker(
                        key: _pickerKey,
                        color: _color,
                        nextFocusNode: _hexToggleFocusNode,
                        onChanged: _setColor,
                      ),
                      const SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Focus(
                          canRequestFocus: false,
                          onKeyEvent: _handleHexToggleKey,
                          child: OutlinedButton.icon(
                            key: const ValueKey('theme-editor-toggle-hex'),
                            focusNode: _hexToggleFocusNode,
                            onPressed: _toggleHexEntry,
                            icon: Icon(
                              _showHexEntry
                                  ? Icons.expand_less_rounded
                                  : Icons.tag_rounded,
                            ),
                            label: LocalizedText(
                              _showHexEntry
                                  ? 'Hide exact hex'
                                  : 'Enter exact hex',
                            ),
                          ),
                        ),
                      ),
                      if (_showHexEntry) ...[
                        const SizedBox(height: 10),
                        Focus(
                          canRequestFocus: false,
                          onKeyEvent: _handleHexFieldKey,
                          child: TextField(
                            key: const ValueKey('theme-editor-hex'),
                            controller: _hexController,
                            focusNode: _hexFocusNode,
                            maxLength: 7,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[#0-9a-fA-F]'),
                              ),
                            ],
                            textCapitalization: TextCapitalization.characters,
                            decoration: InputDecoration(
                              labelText: 'Exact hex color',
                              counterText: '',
                              errorText: _hexError,
                              helperText: 'Example: #E52B50',
                            ),
                            onChanged: (value) {
                              final parsed = parseOpaqueHexColor(value);
                              if (parsed != null) _setColor(parsed);
                            },
                            onSubmitted: _applyHex,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.end,
                        children: [
                          Focus(
                            canRequestFocus: false,
                            onKeyEvent: _handleCancelKey,
                            child: OutlinedButton(
                              focusNode: _cancelFocusNode,
                              onPressed: _close,
                              child: const LocalizedText('Cancel'),
                            ),
                          ),
                          Focus(
                            canRequestFocus: false,
                            onKeyEvent: _handleUseColorKey,
                            child: FilledButton(
                              key: const ValueKey('theme-editor-use-color'),
                              focusNode: _useColorFocusNode,
                              onPressed: () {
                                if (_showHexEntry) {
                                  final parsed = parseOpaqueHexColor(
                                    _hexController.text,
                                  );
                                  if (parsed == null) {
                                    _applyHex(_hexController.text);
                                    return;
                                  }
                                  _close(parsed);
                                } else {
                                  _close(_color);
                                }
                              },
                              child: const LocalizedText('Use color'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BuiltInColorPicker extends StatefulWidget {
  const _BuiltInColorPicker({
    required this.color,
    required this.nextFocusNode,
    required this.onChanged,
    super.key,
  });

  final Color color;
  final FocusNode nextFocusNode;
  final ValueChanged<Color> onChanged;

  static const colors = tetoColorPresets;

  @override
  State<_BuiltInColorPicker> createState() => _BuiltInColorPickerState();
}

class _BuiltInColorPickerState extends State<_BuiltInColorPicker> {
  final Map<int, FocusNode> _focusNodes = {};

  List<(String, Color)> get _choices {
    final hasBuiltInMatch = _BuiltInColorPicker.colors.any(
      (choice) => choice.$2 == widget.color,
    );
    return <(String, Color)>[
      if (!hasBuiltInMatch) ('Current custom color', widget.color),
      ..._BuiltInColorPicker.colors,
    ];
  }

  FocusNode _nodeFor(Color color) => _focusNodes.putIfAbsent(
    color.toARGB32(),
    () => FocusNode(
      debugLabel:
          'theme-studio.preset-${formatOpaqueHexColor(color).substring(1)}',
    ),
  );

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _focus(FocusNode node) {
    if (!node.canRequestFocus) return;
    node.requestFocus();
    final targetContext = node.context;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        alignment: .5,
        duration: TetoUiMotion.duration(targetContext, TetoUiMotion.focus),
      );
    }
  }

  void focusSelected() => _focus(_nodeFor(widget.color));

  KeyEventResult _handleKey(
    int index,
    int columns,
    List<(String, Color)> choices,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final column = index % columns;
    int? target;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      target = column == 0 ? null : index - 1;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      target = column == columns - 1 || index + 1 >= choices.length
          ? null
          : index + 1;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      target = index - columns >= 0 ? index - columns : null;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      target = index + columns < choices.length ? index + columns : -1;
    } else {
      return KeyEventResult.ignored;
    }
    if (target == -1) {
      _focus(widget.nextFocusNode);
    } else if (target != null) {
      _focus(_nodeFor(choices[target].$2));
    }
    // Edge presses deliberately stay in place instead of falling through to
    // Flutter's geometry-dependent spatial traversal.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices;
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 680.0;
        final columns = ((availableWidth + 9) / 57).floor().clamp(1, 12);
        return Semantics(
          container: true,
          label: 'Built-in remote color picker',
          child: Wrap(
            key: const ValueKey('theme-editor-built-in-colors'),
            spacing: 9,
            runSpacing: 9,
            children: [
              for (var index = 0; index < choices.length; index++)
                _BuiltInColorSwatch(
                  label: choices[index].$1,
                  color: choices[index].$2,
                  selected: choices[index].$2 == widget.color,
                  autofocus: choices[index].$2 == widget.color,
                  focusNode: _nodeFor(choices[index].$2),
                  onKeyEvent: (_, event) =>
                      _handleKey(index, columns, choices, event),
                  onPressed: () => widget.onChanged(choices[index].$2),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _BuiltInColorSwatch extends StatelessWidget {
  const _BuiltInColorSwatch({
    required this.label,
    required this.color,
    required this.selected,
    required this.autofocus,
    required this.focusNode,
    required this.onKeyEvent,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final bool selected;
  final bool autofocus;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final hex = formatOpaqueHexColor(color).substring(1);
    return Tooltip(
      message: label,
      child: TvFocusable(
        key: ValueKey('theme-editor-preset-$hex'),
        autofocus: autofocus,
        focusNode: focusNode,
        onKeyEvent: onKeyEvent,
        onPressed: onPressed,
        borderRadius: BorderRadius.circular(12),
        focusScale: 1.08,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? palette.focusRing
                  : contrastForeground(color).withValues(alpha: .32),
              width: selected ? 3 : 1,
            ),
          ),
          child: selected
              ? Icon(
                  Icons.check_rounded,
                  color: contrastForeground(color),
                  size: 22,
                )
              : null,
        ),
      ),
    );
  }
}

String formatOpaqueHexColor(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Color? parseOpaqueHexColor(String input) {
  final normalized = input.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(normalized)) return null;
  final value = int.tryParse(normalized, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}
