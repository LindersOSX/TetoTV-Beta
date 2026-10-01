import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/preferences/caption_language.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/theme/teto_color_presets.dart';
import 'package:anime_tv/core/theme/teto_ui_tokens.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_studio_components.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CaptionStudioScreen extends ConsumerStatefulWidget {
  const CaptionStudioScreen({super.key});

  static const routePath = '/settings/caption-studio';

  @override
  ConsumerState<CaptionStudioScreen> createState() =>
      _CaptionStudioScreenState();
}

class _CaptionColorOption {
  const _CaptionColorOption(this.value, this.label);

  final int value;
  final String label;
}

final _textColors = <_CaptionColorOption>[
  _CaptionColorOption(0xFFFFFFFF, 'White'),
  _CaptionColorOption(0xFFFFF1D6, 'Warm white'),
  _CaptionColorOption(0xFFFFFF66, 'Yellow'),
  _CaptionColorOption(0xFFFFC857, 'Gold'),
  _CaptionColorOption(0xFF66E7FF, 'Cyan'),
  _CaptionColorOption(0xFF98C9FF, 'Sky blue'),
  _CaptionColorOption(0xFFC9F77B, 'Lime'),
  _CaptionColorOption(0xFFFFA8CE, 'Pink'),
  for (final preset in tetoColorPresets)
    if (preset.$2 != Colors.white)
      _CaptionColorOption(preset.$2.toARGB32(), preset.$1),
];

final _backgroundColors = <_CaptionColorOption>[
  _CaptionColorOption(0x00000000, 'Off'),
  _CaptionColorOption(0x99000000, 'Dark'),
  _CaptionColorOption(0xDD000000, 'Strong'),
  _CaptionColorOption(0xFF000000, 'Black'),
  _CaptionColorOption(0xDD10233D, 'Navy'),
  _CaptionColorOption(0xDD3B1947, 'Plum'),
  _CaptionColorOption(0xDD163A32, 'Forest'),
  _CaptionColorOption(0xDD4A1E2C, 'Burgundy'),
  for (final preset in tetoColorPresets)
    if (preset.$2 != Colors.black)
      _CaptionColorOption(
        (preset.$2.toARGB32() & 0x00FFFFFF) | 0xDD000000,
        preset.$1,
      ),
];

class _CaptionStudioScreenState extends ConsumerState<CaptionStudioScreen> {
  late SettingsPreferences _draft;
  bool _edited = false;
  bool _saving = false;
  final _backFocus = FocusNode(debugLabel: 'caption-studio.back');
  final _modeFocus = <PreferredCaptionMode, FocusNode>{
    for (final mode in PreferredCaptionMode.values)
      mode: FocusNode(debugLabel: 'caption-studio.mode-${mode.name}'),
  };
  final _languageFocus = FocusNode(debugLabel: 'caption-studio.language');
  final _textColorFocus = FocusNode(debugLabel: 'caption-studio.text-color');
  final _backgroundFocus = FocusNode(debugLabel: 'caption-studio.background');
  final _sizeFocus = FocusNode(debugLabel: 'caption-studio.text-size');
  final _applyFocus = FocusNode(debugLabel: 'caption-studio.apply');
  final _resetFocus = FocusNode(debugLabel: 'caption-studio.reset');

  @override
  void initState() {
    super.initState();
    _draft = ref.read(settingsPreferencesProvider);
  }

  @override
  void dispose() {
    _backFocus.dispose();
    for (final node in _modeFocus.values) {
      node.dispose();
    }
    _languageFocus.dispose();
    _textColorFocus.dispose();
    _backgroundFocus.dispose();
    _sizeFocus.dispose();
    _applyFocus.dispose();
    _resetFocus.dispose();
    super.dispose();
  }

  bool _isArrow(KeyEvent event, LogicalKeyboardKey key) =>
      (event is KeyDownEvent || event is KeyRepeatEvent) &&
      event.logicalKey == key;

  void _focusAndReveal(FocusNode node) {
    node.requestFocus();
    if (node.context case final context?) {
      Scrollable.ensureVisible(
        context,
        alignment: .8,
        duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
      );
    }
  }

  void _focusAvailableAction() => _focusAndReveal(
    _applyFocus.canRequestFocus && _applyFocus.context != null
        ? _applyFocus
        : _resetFocus,
  );

  KeyEventResult _actionKey(FocusNode _, KeyEvent event) {
    if (_isArrow(event, LogicalKeyboardKey.arrowUp)) {
      _focusAndReveal(_sizeFocus);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _verticalKey(KeyEvent event, FocusNode up, FocusNode down) {
    if (_isArrow(event, LogicalKeyboardKey.arrowUp)) {
      _focusAndReveal(up);
      return KeyEventResult.handled;
    }
    if (_isArrow(event, LogicalKeyboardKey.arrowDown)) {
      _focusAndReveal(down);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _modeKey(PreferredCaptionMode mode, KeyEvent event) {
    final modes = PreferredCaptionMode.values;
    final index = modes.indexOf(mode);
    if (_isArrow(event, LogicalKeyboardKey.arrowLeft) ||
        _isArrow(event, LogicalKeyboardKey.arrowRight)) {
      final offset = event.logicalKey == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      _focusAndReveal(
        _modeFocus[modes[(index + offset).clamp(0, modes.length - 1)]]!,
      );
      return KeyEventResult.handled;
    }
    return _verticalKey(event, _backFocus, _languageFocus);
  }

  Future<void> _editColor({required bool background}) async {
    final result = await showTetoDialog<int>(
      context: context,
      builder: (_) => _CaptionColorPickerDialog(
        title: background ? 'Caption background' : 'Text color',
        options: background ? _backgroundColors : _textColors,
        initialColor: background
            ? _draft.captionBackgroundColor
            : _draft.captionTextColor,
        allowAlpha: background,
      ),
    );
    if (!mounted) return;
    if (result != null) {
      _change(
        background
            ? _draft.copyWith(captionBackgroundColor: result)
            : _draft.copyWith(captionTextColor: result),
      );
    }
    _focusAndReveal(background ? _backgroundFocus : _textColorFocus);
  }

  void _change(SettingsPreferences next) => setState(() {
    _draft = next;
    _edited = true;
  });

  bool _hasChanges(SettingsPreferences saved) =>
      _draft.preferredCaptionMode != saved.preferredCaptionMode ||
      _draft.preferredCaptionLanguage != saved.preferredCaptionLanguage ||
      _draft.captionTextColor != saved.captionTextColor ||
      _draft.captionBackgroundColor != saved.captionBackgroundColor ||
      _draft.captionTextSize != saved.captionTextSize;

  Future<void> _apply() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = ref.read(settingsPreferencesProvider);
      final controller = ref.read(settingsPreferencesProvider.notifier);
      if (_draft.preferredCaptionMode != saved.preferredCaptionMode) {
        await controller.setPreferredCaptionMode(_draft.preferredCaptionMode);
      }
      if (_draft.preferredCaptionLanguage != saved.preferredCaptionLanguage) {
        await controller.setPreferredCaptionLanguage(
          _draft.preferredCaptionLanguage,
        );
      }
      if (_draft.captionTextColor != saved.captionTextColor) {
        await controller.setCaptionTextColor(_draft.captionTextColor);
      }
      if (_draft.captionBackgroundColor != saved.captionBackgroundColor) {
        await controller.setCaptionBackgroundColor(
          _draft.captionBackgroundColor,
        );
      }
      if (_draft.captionTextSize != saved.captionTextSize) {
        await controller.setCaptionTextSize(_draft.captionTextSize);
      }
      if (!mounted) return;
      setState(() {
        _draft = ref.read(settingsPreferencesProvider);
        _edited = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('Caption settings applied.'))),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Caption settings could not be applied.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reset() {
    const defaults = SettingsPreferences();
    _change(
      _draft.copyWith(
        preferredCaptionMode: defaults.preferredCaptionMode,
        preferredCaptionLanguage: defaults.preferredCaptionLanguage,
        captionTextColor: defaults.captionTextColor,
        captionBackgroundColor: defaults.captionBackgroundColor,
        captionTextSize: defaults.captionTextSize,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final saved = ref.watch(settingsPreferencesProvider);
    if (saved.loaded && !_edited && !_saving) _draft = saved;
    final changed = saved.loaded && _hasChanges(saved);

    return Scaffold(
      key: const ValueKey('caption-studio-screen'),
      backgroundColor: palette.background,
      body: SafeArea(
        child: !saved.loaded
            ? const Center(child: CircularProgressIndicator())
            : Center(
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
                          backFocusNode: _backFocus,
                          onBackKeyEvent: (_, event) {
                            if (_isArrow(event, LogicalKeyboardKey.arrowDown)) {
                              _focusAndReveal(
                                _modeFocus[_draft.preferredCaptionMode]!,
                              );
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          title: 'Caption Studio',
                          subtitle:
                              'Preview caption language, colors, and size before applying.',
                          onBack: () => Navigator.maybePop(context),
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final wide = constraints.maxWidth >= 820;
                              final controls = ListView(
                                scrollCacheExtent:
                                    const ScrollCacheExtent.pixels(4000),
                                padding: EdgeInsets.only(
                                  right: wide ? 12 : 0,
                                  bottom: 96,
                                ),
                                children: [
                                  ..._buildControls(context),
                                  const SizedBox(height: TetoUiSpace.section),
                                  TetoStudioActions(
                                    key: const ValueKey(
                                      'caption-studio-actions',
                                    ),
                                    applyKey: const ValueKey(
                                      'caption-studio-apply',
                                    ),
                                    resetKey: const ValueKey(
                                      'caption-studio-reset',
                                    ),
                                    onApply: changed && !_saving
                                        ? _apply
                                        : null,
                                    onReset: _saving ? null : _reset,
                                    applyFocusNode: _applyFocus,
                                    resetFocusNode: _resetFocus,
                                    onApplyKeyEvent: _actionKey,
                                    onResetKeyEvent: (node, event) {
                                      if (_isArrow(
                                            event,
                                            LogicalKeyboardKey.arrowLeft,
                                          ) &&
                                          _applyFocus.canRequestFocus) {
                                        _focusAndReveal(_applyFocus);
                                        return KeyEventResult.handled;
                                      }
                                      return _actionKey(node, event);
                                    },
                                  ),
                                ],
                              );
                              final preview = _CaptionPreview(draft: _draft);
                              if (wide) {
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: controls),
                                    const SizedBox(width: 18),
                                    Expanded(
                                      child: SizedBox(
                                        height: 390,
                                        child: preview,
                                      ),
                                    ),
                                  ],
                                );
                              }
                              return Column(
                                children: [
                                  SizedBox(
                                    height: constraints.maxHeight
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
  }

  List<Widget> _buildControls(BuildContext context) {
    final palette = context.appPalette;
    final language = _draft.preferredCaptionLanguage;
    final languageOptions = preferredCaptionLanguageOptions;
    return [
      TetoStudioSectionTitle(context.tr('Default captions')),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final mode in PreferredCaptionMode.values)
            TvFocusable(
              key: ValueKey('caption-studio-mode-${mode.name}'),
              focusNode: _modeFocus[mode],
              autofocus: _draft.preferredCaptionMode == mode,
              focusScale: 1,
              onKeyEvent: (_, event) => _modeKey(mode, event),
              onPressed: () =>
                  _change(_draft.copyWith(preferredCaptionMode: mode)),
              child: Semantics(
                selected: _draft.preferredCaptionMode == mode,
                inMutuallyExclusiveGroup: true,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 46),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: TetoBoxStyle.decoration(palette).copyWith(
                    border: Border.all(
                      color: _draft.preferredCaptionMode == mode
                          ? palette.accentBright
                          : TetoBoxStyle.outline(palette),
                      width: _draft.preferredCaptionMode == mode ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        child: _draft.preferredCaptionMode == mode
                            ? Icon(
                                Icons.check_rounded,
                                size: 18,
                                color: palette.accentBright,
                              )
                            : null,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        context.tr(mode.displayName),
                        style: TextStyle(
                          color: palette.primaryText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) => _verticalKey(
          event,
          _modeFocus[_draft.preferredCaptionMode]!,
          _textColorFocus,
        ),
        child: DropdownButtonFormField<String>(
          focusNode: _languageFocus,
          key: ValueKey('caption-studio-language-$language'),
          initialValue: language,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.tr('Preferred subtitle language'),
            border: const OutlineInputBorder(),
          ),
          dropdownColor: palette.surface,
          items: [
            if (!languageOptions.any((option) => option.code == language))
              DropdownMenuItem(
                value: language,
                child: Text(captionLanguageDisplayName(language)),
              ),
            for (final option in languageOptions)
              DropdownMenuItem(
                value: option.code,
                child: Text(context.tr(option.label)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              _change(_draft.copyWith(preferredCaptionLanguage: value));
            }
          },
        ),
      ),
      const SizedBox(height: 18),
      TetoStudioSectionTitle(context.tr('Text color')),
      _CaptionColorTile(
        key: const ValueKey('caption-studio-text-color'),
        title: 'Text color',
        options: _textColors,
        selected: _draft.captionTextColor,
        allowAlpha: false,
        focusNode: _textColorFocus,
        onKeyEvent: (_, event) =>
            _verticalKey(event, _languageFocus, _backgroundFocus),
        onPressed: () => _editColor(background: false),
      ),
      const SizedBox(height: 18),
      TetoStudioSectionTitle(context.tr('Caption background')),
      _CaptionColorTile(
        key: const ValueKey('caption-studio-background-color'),
        title: 'Caption background',
        options: _backgroundColors,
        selected: _draft.captionBackgroundColor,
        allowAlpha: true,
        focusNode: _backgroundFocus,
        onKeyEvent: (_, event) =>
            _verticalKey(event, _textColorFocus, _sizeFocus),
        onPressed: () => _editColor(background: true),
      ),
      const SizedBox(height: 18),
      TetoStudioSectionTitle(context.tr('Text size')),
      _CaptionSizeSlider(
        key: const ValueKey('caption-studio-size-slider'),
        value: _draft.captionTextSize,
        focusNode: _sizeFocus,
        onDown: _focusAvailableAction,
        onUp: () => _focusAndReveal(_backgroundFocus),
        onChanged: (value) =>
            _change(_draft.copyWith(captionTextSize: value.roundToDouble())),
      ),
    ];
  }
}

String _captionColorHex(int value, bool allowAlpha) =>
    '#${(allowAlpha ? value : value & 0xFFFFFF).toRadixString(16).padLeft(allowAlpha ? 8 : 6, '0').toUpperCase()}';

class _CaptionColorTile extends StatelessWidget {
  const _CaptionColorTile({
    required this.title,
    required this.options,
    required this.selected,
    required this.allowAlpha,
    required this.focusNode,
    required this.onKeyEvent,
    required this.onPressed,
    super.key,
  });

  final String title;
  final List<_CaptionColorOption> options;
  final int selected;
  final bool allowAlpha;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final name =
        options
            .where((option) => option.value == selected)
            .firstOrNull
            ?.label ??
        'Current custom color';
    return TvFocusable(
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(TetoBoxStyle.radius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: TetoBoxStyle.decoration(palette),
        child: Row(
          children: [
            Container(
              key: ValueKey(
                allowAlpha
                    ? 'caption-studio-background-swatch'
                    : 'caption-studio-text-swatch',
              ),
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Color(selected),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: palette.mutedText.withValues(alpha: .5),
                ),
              ),
              child: selected == 0
                  ? Icon(
                      Icons.block_rounded,
                      color: palette.mutedText,
                      size: 22,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr(title),
                    style: TextStyle(
                      color: palette.primaryText,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    context.tr(name),
                    style: TextStyle(color: palette.mutedText, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _captionColorHex(selected, allowAlpha),
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

class _CaptionColorPickerDialog extends StatefulWidget {
  const _CaptionColorPickerDialog({
    required this.title,
    required this.options,
    required this.initialColor,
    required this.allowAlpha,
  });
  final String title;
  final List<_CaptionColorOption> options;
  final int initialColor;
  final bool allowAlpha;

  @override
  State<_CaptionColorPickerDialog> createState() =>
      _CaptionColorPickerDialogState();
}

class _CaptionColorPickerDialogState extends State<_CaptionColorPickerDialog> {
  late int _selected = widget.initialColor;
  final _pickerKey = GlobalKey<_CaptionColorChoicesState>();
  final _exactFocus = FocusNode(debugLabel: 'caption-color.exact');
  final _cancelFocus = FocusNode(debugLabel: 'caption-color.cancel');
  final _useFocus = FocusNode(debugLabel: 'caption-color.use');

  @override
  void dispose() {
    _exactFocus.dispose();
    _cancelFocus.dispose();
    _useFocus.dispose();
    super.dispose();
  }

  KeyEventResult _actionKey(KeyEvent event, FocusNode horizontal) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _exactFocus.requestFocus();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      horizontal.requestFocus();
    } else if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('caption-studio-color-picker'),
    title: Text(context.tr(widget.title)),
    content: SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _captionColorHex(_selected, widget.allowAlpha),
              key: const ValueKey('caption-studio-selected-hex'),
              style: TextStyle(
                color: context.appPalette.mutedText,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 16),
            _CaptionColorChoices(
              key: _pickerKey,
              options: widget.options,
              selected: _selected,
              initialColor: widget.initialColor,
              onChanged: (color) => setState(() => _selected = color),
              nextFocusNode: _exactFocus,
            ),
            const SizedBox(height: 16),
            Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                  _pickerKey.currentState?.focusSelected();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                  _cancelFocus.requestFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: OutlinedButton.icon(
                key: ValueKey(
                  widget.allowAlpha
                      ? 'caption-studio-background-exact-color'
                      : 'caption-studio-text-exact-color',
                ),
                focusNode: _exactFocus,
                onPressed: () async {
                  final color = await showTetoDialog<int>(
                    context: context,
                    builder: (_) => _ExactCaptionColorDialog(
                      initialColor: _selected,
                      allowAlpha: widget.allowAlpha,
                    ),
                  );
                  if (!mounted) return;
                  if (color != null) setState(() => _selected = color);
                  _exactFocus.requestFocus();
                },
                icon: const Icon(Icons.colorize_rounded),
                label: Text(context.tr('Exact hex color')),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) => _actionKey(event, _useFocus),
        child: TextButton(
          key: const ValueKey('caption-studio-cancel-color'),
          focusNode: _cancelFocus,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Cancel')),
        ),
      ),
      Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) => _actionKey(event, _cancelFocus),
        child: FilledButton(
          key: const ValueKey('caption-studio-use-color'),
          focusNode: _useFocus,
          onPressed: () => Navigator.of(context).pop(_selected),
          child: Text(context.tr('Use color')),
        ),
      ),
    ],
  );
}

class _CaptionColorChoices extends StatefulWidget {
  const _CaptionColorChoices({
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.initialColor,
    required this.nextFocusNode,
    super.key,
  });

  final List<_CaptionColorOption> options;
  final int selected;
  final ValueChanged<int> onChanged;
  final int initialColor;
  final FocusNode nextFocusNode;

  @override
  State<_CaptionColorChoices> createState() => _CaptionColorChoicesState();
}

class _CaptionColorChoicesState extends State<_CaptionColorChoices> {
  late final _options = <_CaptionColorOption>[
    if (!widget.options.any((option) => option.value == widget.initialColor))
      _CaptionColorOption(widget.initialColor, 'Current custom color'),
    ...widget.options,
  ];
  final _nodes = <int, FocusNode>{};
  FocusNode _node(int value) => _nodes.putIfAbsent(
    value,
    () => FocusNode(debugLabel: 'caption-color.preset-$value'),
  );

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _focus(FocusNode node) {
    node.requestFocus();
    if (node.context case final context?) {
      Scrollable.ensureVisible(
        context,
        alignment: .5,
        duration: TetoUiMotion.duration(context, TetoUiMotion.focus),
      );
    }
  }

  void focusSelected() => _focus(
    _node(
      _options.any((option) => option.value == widget.selected)
          ? widget.selected
          : _options.first.value,
    ),
  );

  KeyEventResult _key(int index, int columns, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final column = index % columns;
    int? next;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (column > 0) next = index - 1;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (column < columns - 1 && index + 1 < _options.length) next = index + 1;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (index >= columns) next = index - columns;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (index + columns >= _options.length) {
        _focus(widget.nextFocusNode);
      } else {
        next = index + columns;
      }
    } else {
      return KeyEventResult.ignored;
    }
    if (next != null) _focus(_node(_options[next].value));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth + 9) / 57).floor().clamp(
          1,
          _options.length,
        );
        return Semantics(
          container: true,
          label: 'Caption color picker',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 9,
                runSpacing: 9,
                children: [
                  for (var index = 0; index < _options.length; index++)
                    Tooltip(
                      message: context.tr(_options[index].label),
                      child: TvFocusable(
                        key: ValueKey(
                          'caption-studio-color-${_options[index].value}',
                        ),
                        focusNode: _node(_options[index].value),
                        autofocus: _options[index].value == widget.initialColor,
                        onKeyEvent: (_, event) => _key(index, columns, event),
                        onPressed: () =>
                            widget.onChanged(_options[index].value),
                        borderRadius: BorderRadius.circular(12),
                        focusScale: 1.08,
                        child: Semantics(
                          label: context.tr(_options[index].label),
                          selected: widget.selected == _options[index].value,
                          button: true,
                          child: Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _options[index].value == 0
                                  ? TetoBoxStyle.fill(palette)
                                  : Color(_options[index].value),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: widget.selected == _options[index].value
                                    ? palette.focusRing
                                    : _options[index].value == 0
                                    ? TetoBoxStyle.outline(palette)
                                    : contrastForeground(
                                        Color(_options[index].value),
                                      ).withValues(alpha: .32),
                                width: widget.selected == _options[index].value
                                    ? 3
                                    : 1,
                              ),
                            ),
                            child: Icon(
                              _options[index].value == 0
                                  ? Icons.block_rounded
                                  : widget.selected == _options[index].value
                                  ? Icons.check_rounded
                                  : null,
                              color: _options[index].value == 0
                                  ? palette.mutedText
                                  : contrastForeground(
                                      Color(_options[index].value),
                                    ),
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ExactCaptionColorDialog extends StatefulWidget {
  const _ExactCaptionColorDialog({
    required this.initialColor,
    required this.allowAlpha,
  });

  final int initialColor;
  final bool allowAlpha;

  @override
  State<_ExactCaptionColorDialog> createState() =>
      _ExactCaptionColorDialogState();
}

class _ExactCaptionColorDialogState extends State<_ExactCaptionColorDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    final hex = widget.allowAlpha
        ? widget.initialColor.toRadixString(16).padLeft(8, '0').toUpperCase()
        : (widget.initialColor & 0xFFFFFF)
              .toRadixString(16)
              .padLeft(6, '0')
              .toUpperCase();
    _controller = TextEditingController(text: '#$hex');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _useColor() {
    final value = _controller.text.trim().replaceFirst('#', '');
    final valid = RegExp(
      widget.allowAlpha
          ? r'^(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$'
          : r'^[0-9a-fA-F]{6}$',
    ).hasMatch(value);
    if (!valid) {
      setState(
        () => _error = widget.allowAlpha
            ? 'Use 6 or 8 hex digits.'
            : 'Use 6 hex digits.',
      );
      return;
    }
    final parsed = int.parse(value, radix: 16);
    Navigator.of(context).pop(value.length == 6 ? 0xFF000000 | parsed : parsed);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.tr('Exact hex color')),
    content: TextField(
      key: const ValueKey('caption-studio-exact-color-input'),
      controller: _controller,
      autocorrect: false,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        hintText: widget.allowAlpha ? '#AARRGGBB' : '#RRGGBB',
        errorText: _error,
      ),
      onSubmitted: (_) => _useColor(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.tr('Cancel')),
      ),
      FilledButton(
        key: const ValueKey('caption-studio-use-exact-color'),
        onPressed: _useColor,
        child: Text(context.tr('Use color')),
      ),
    ],
  );
}

class _CaptionSizeSlider extends StatefulWidget {
  const _CaptionSizeSlider({
    required this.value,
    required this.focusNode,
    required this.onDown,
    required this.onUp,
    required this.onChanged,
    super.key,
  });

  final double value;
  final FocusNode focusNode;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final ValueChanged<double> onChanged;

  @override
  State<_CaptionSizeSlider> createState() => _CaptionSizeSliderState();
}

class _CaptionSizeSliderState extends State<_CaptionSizeSlider> {
  bool _focused = false;
  bool _adjusting = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (value) => setState(() {
        _focused = value;
        if (!value) _adjusting = false;
      }),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          setState(() => _adjusting = !_adjusting);
          return KeyEventResult.handled;
        }
        if (_adjusting &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.goBack)) {
          setState(() => _adjusting = false);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (!_adjusting) return KeyEventResult.handled;
          widget.onChanged(
            (widget.value +
                    (event.logicalKey == LogicalKeyboardKey.arrowRight
                        ? 1
                        : -1))
                .clamp(18, 60),
          );
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          if (_adjusting) setState(() => _adjusting = false);
          widget.onDown();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          if (_adjusting) setState(() => _adjusting = false);
          widget.onUp();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        decoration: TetoBoxStyle.decoration(palette, focused: _focused),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${context.tr('Text size')}  ${widget.value.round()}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            ExcludeFocus(
              child: Slider(
                value: widget.value.clamp(18, 60),
                min: 18,
                max: 60,
                divisions: 42,
                label: '${widget.value.round()}',
                onChanged: widget.onChanged,
              ),
            ),
            Row(
              children: [
                Text(context.tr('Small')),
                const Spacer(),
                Text(context.tr('Large')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptionPreview extends StatelessWidget {
  const _CaptionPreview({required this.draft});

  final SettingsPreferences draft;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return TetoStudioPreviewFrame(
      key: const ValueKey('caption-studio-preview'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scale = (constraints.maxWidth / 560).clamp(.45, 1.0);
                  return Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFF385A73),
                          Color(0xFF172B3F),
                          Color(0xFF321D3C),
                        ],
                      ),
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          top: 18,
                          left: 18,
                          child: Text(
                            context.tr('Sample scene'),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: .8),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 18,
                          child: Center(
                            child: DecoratedBox(
                              key: const ValueKey('caption-preview-background'),
                              decoration: BoxDecoration(
                                color: Color(draft.captionBackgroundColor),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                child: Text(
                                  context.tr(
                                    'This is how your captions will look.',
                                  ),
                                  key: const ValueKey('caption-preview-text'),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Color(draft.captionTextColor),
                                    fontSize: draft.captionTextSize * scale,
                                    fontWeight: FontWeight.w700,
                                    shadows: const [
                                      Shadow(
                                        color: Colors.black,
                                        blurRadius: 2,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
