import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/tv/tv_navigation.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TvTextInputVariant { standard, headerSearch }

/// Uses TetoTV's remote keyboard or the Android device keyboard according to
/// the saved input preference.
class TvTextInput extends ConsumerStatefulWidget {
  const TvTextInput({
    required this.controller,
    required this.labelText,
    this.hintText,
    this.keyboardTitle,
    this.helperText,
    this.focusNode,
    this.autofocus = false,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.inputFormatters = const <TextInputFormatter>[],
    this.maxLength,
    this.numericOnly = false,
    this.autofillSuggestions = const [],
    this.onChanged,
    this.onSubmitted,
    this.onFocusChanged,
    this.onEditingChanged,
    this.onExitLeft,
    this.onExitRight,
    this.onExitUp,
    this.onExitDown,
    this.variant = TvTextInputVariant.standard,
    this.compactHeader = false,
    this.restoreFocusAfterSubmit = true,
    super.key,
  });

  final TextEditingController controller;
  final String labelText;
  final String? hintText;
  final String? keyboardTitle;
  final String? helperText;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool obscureText;
  final TextInputType keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final int? maxLength;
  final bool numericOnly;
  final List<String> autofillSuggestions;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<bool>? onFocusChanged;
  final ValueChanged<bool>? onEditingChanged;
  final VoidCallback? onExitLeft;
  final VoidCallback? onExitRight;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitDown;
  final TvTextInputVariant variant;
  final bool compactHeader;
  final bool restoreFocusAfterSubmit;

  @override
  ConsumerState<TvTextInput> createState() => _TvTextInputState();
}

class _TvTextInputState extends ConsumerState<TvTextInput>
    with WidgetsBindingObserver {
  FocusNode? _fallbackFocusNode;
  bool _deviceKeyboardActive = false;
  double _lastViewInsetBottom = 0;

  FocusNode get _focusNode => widget.focusNode ?? _fallbackFocusNode!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.focusNode == null) {
      _fallbackFocusNode = FocusNode(debugLabel: 'TV text input');
    }
    _focusNode.addListener(_handleFocusChanged);
    widget.controller.addListener(_handleControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _lastViewInsetBottom = View.of(context).viewInsets.bottom;
    });
  }

  @override
  void didUpdateWidget(covariant TvTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _fallbackFocusNode)?.removeListener(
        _handleFocusChanged,
      );
      _fallbackFocusNode?.dispose();
      _fallbackFocusNode = widget.focusNode == null
          ? FocusNode(debugLabel: 'TV text input')
          : null;
      _focusNode.addListener(_handleFocusChanged);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_handleControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _fallbackFocusNode?.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bottom = View.of(context).viewInsets.bottom;
      final keyboardClosed = _lastViewInsetBottom > 0 && bottom <= 0;
      _lastViewInsetBottom = bottom;
      if (keyboardClosed && _deviceKeyboardActive) {
        _dismissDeviceKeyboard();
      }
    });
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  void _handleFocusChanged() {
    widget.onFocusChanged?.call(_focusNode.hasFocus);
    if (_focusNode.hasFocus || !_deviceKeyboardActive) return;
    setState(() => _deviceKeyboardActive = false);
    widget.onEditingChanged?.call(false);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void _activateDeviceKeyboard() {
    if (_deviceKeyboardActive) return;
    setState(() => _deviceKeyboardActive = true);
    widget.onEditingChanged?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    });
  }

  void _finishDeviceKeyboard(String value) {
    _dismissDeviceKeyboard(restoreFocus: widget.restoreFocusAfterSubmit);
    widget.onSubmitted?.call(value);
  }

  void _dismissDeviceKeyboard({bool restoreFocus = true}) {
    final wasActive = _deviceKeyboardActive;
    if (_deviceKeyboardActive) {
      setState(() => _deviceKeyboardActive = false);
    }
    if (wasActive) widget.onEditingChanged?.call(false);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (restoreFocus) {
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
    }
  }

  KeyEventResult _handleDeviceActivation(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (_deviceKeyboardActive &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack ||
            event.logicalKey == LogicalKeyboardKey.browserBack)) {
      _dismissDeviceKeyboard();
      return KeyEventResult.handled;
    }
    if (_deviceKeyboardActive) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _activateDeviceKeyboard();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleDirectionalExit(FocusNode _, KeyEvent event) {
    // Once the Android keyboard is open, arrow keys belong to the editable
    // field. Before activation, the same D-pad directions must always provide
    // a deterministic way out of the text control.
    if (_deviceKeyboardActive) return KeyEventResult.ignored;
    return handleTvDirectionalFocusEvent(
      event,
      TvDirectionalFocusCallbacks(
        left: widget.onExitLeft,
        right: widget.onExitRight,
        up: widget.onExitUp,
        down: widget.onExitDown,
      ),
    );
  }

  Future<void> _openKeyboard(BuildContext context) async {
    String? value;
    widget.onEditingChanged?.call(true);
    try {
      value = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black.withValues(alpha: .20),
        builder: (_) => TvKeyboardDialog(
          title: widget.keyboardTitle ?? widget.labelText,
          initialValue: widget.controller.text,
          obscureText: widget.obscureText,
          inputFormatters: widget.inputFormatters,
          maxLength: widget.maxLength,
          numericOnly: widget.numericOnly,
          autofillSuggestions: widget.autofillSuggestions,
        ),
      );
    } finally {
      widget.onEditingChanged?.call(false);
    }
    if (value == null || !context.mounted) return;
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    widget.onChanged?.call(value);
    widget.onSubmitted?.call(value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.restoreFocusAfterSubmit &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final headerSearch = widget.variant == TvTextInputVariant.headerSearch;
    final compactHeader = widget.compactHeader;
    // The Home search is intentionally a compact bar, not a capsule. Keeping
    // a modest radius also gives its focused outline the same visual language
    // as the rest of TetoTV's rectangular actions.
    final headerRadius = BorderRadius.circular(compactHeader ? 10 : 12);
    final useBuiltInKeyboard = ref.watch(
      settingsPreferencesProvider.select(
        (preferences) => preferences.useBuiltInKeyboard,
      ),
    );
    if (!useBuiltInKeyboard) {
      final field = Focus(
        canRequestFocus: false,
        onKeyEvent: _handleDirectionalExit,
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: _handleDeviceActivation,
          child: TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            autofocus: widget.autofocus,
            readOnly: !_deviceKeyboardActive,
            showCursor: _deviceKeyboardActive,
            enableInteractiveSelection: _deviceKeyboardActive,
            obscureText: widget.obscureText,
            keyboardType: widget.keyboardType,
            inputFormatters: widget.inputFormatters,
            maxLength: widget.maxLength,
            autocorrect: !widget.obscureText,
            enableSuggestions: !widget.obscureText,
            textInputAction: TextInputAction.done,
            onTap: _activateDeviceKeyboard,
            onChanged: widget.onChanged,
            onSubmitted: _finishDeviceKeyboard,
            style: TextStyle(
              color: context.appPalette.primaryText,
              fontSize: headerSearch ? (compactHeader ? 14 : 17) : 15,
              fontWeight: headerSearch ? FontWeight.w600 : null,
            ),
            cursorColor: context.appPalette.accentBright,
            decoration: headerSearch
                ? InputDecoration(
                    hintText: widget.hintText,
                    counterText: '',
                    hintStyle: TextStyle(
                      color: context.appPalette.primaryText.withValues(
                        alpha: .72,
                      ),
                      fontSize: compactHeader ? 14 : 17,
                      fontWeight: FontWeight.w600,
                    ),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: .76),
                    contentPadding: EdgeInsets.only(
                      left: compactHeader ? 13 : 17,
                      right: compactHeader ? 15 : 19,
                    ),
                    prefixIconConstraints: BoxConstraints.tightFor(
                      width: compactHeader ? 49 : 57,
                    ),
                    prefixIcon: SizedBox.square(
                      key: const ValueKey('home-header-search-icon-frame'),
                      dimension: compactHeader ? 28 : 32,
                      child: Center(
                        child: Icon(
                          Icons.search_rounded,
                          key: const ValueKey('home-header-search-icon'),
                          size: compactHeader ? 22 : 26,
                          color: context.appPalette.primaryText,
                        ),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: headerRadius,
                      borderSide: BorderSide(
                        color: context.appPalette.primaryText.withValues(
                          alpha: .28,
                        ),
                        width: 1.2,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: headerRadius,
                      borderSide: BorderSide(
                        color: context.appPalette.accentBright,
                        width: 2,
                      ),
                    ),
                  )
                : InputDecoration(
                    labelText: widget.labelText,
                    hintText: widget.hintText,
                    helperText: widget.helperText,
                    counterText: '',
                    labelStyle: TextStyle(color: context.appPalette.mutedText),
                    hintStyle: TextStyle(color: context.appPalette.mutedText),
                    filled: true,
                    fillColor: context.appPalette.background.withValues(
                      alpha: .82,
                    ),
                    suffixIcon: Icon(
                      Icons.keyboard_alt_outlined,
                      color: context.appPalette.secondaryAccent,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: .14),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: context.appPalette.accentBright,
                        width: 2,
                      ),
                    ),
                  ),
          ),
        ),
      );
      if (!headerSearch) return field;
      return Semantics(
        container: true,
        label: widget.labelText,
        hint: 'Activate to enter search text',
        child: AnimatedBuilder(
          animation: _focusNode,
          child: field,
          builder: (context, child) {
            final highlighted = _focusNode.hasFocus;
            return AnimatedScale(
              scale: highlighted ? 1.01 : 1,
              duration: const Duration(milliseconds: 80),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                decoration: BoxDecoration(
                  borderRadius: headerRadius,
                  boxShadow: highlighted
                      ? [
                          BoxShadow(
                            color: context.appPalette.focusInnerKeyline,
                            blurRadius: 0,
                            spreadRadius: 2,
                          ),
                          BoxShadow(
                            color: context.appPalette.focusGlow,
                            blurRadius: 11,
                            spreadRadius: 2,
                          ),
                        ]
                      : const [],
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: headerRadius,
                  border: Border.all(
                    color: highlighted
                        ? context.appPalette.focusRing
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: ClipRRect(borderRadius: headerRadius, child: child),
              ),
            );
          },
        ),
      );
    }
    final value = widget.controller.text;
    final visibleValue = widget.obscureText && value.isNotEmpty
        ? List.filled(value.length.clamp(1, 48), '\u2022').join()
        : value;
    if (headerSearch) {
      return Semantics(
        container: true,
        textField: true,
        label: widget.labelText,
        value: value,
        hint: 'Activate to enter search text',
        onTap: () => _openKeyboard(context),
        child: ExcludeSemantics(
          child: TvFocusable(
            autofocus: widget.autofocus,
            focusNode: _focusNode,
            focusScale: 1.01,
            borderRadius: headerRadius,
            onKeyEvent: _handleDirectionalExit,
            onPressed: () => _openKeyboard(context),
            child: Container(
              key: const ValueKey('tv-text-input-header-search'),
              padding: EdgeInsets.symmetric(
                horizontal: compactHeader ? 15 : 19,
                vertical: compactHeader ? 8 : 4,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .76),
                borderRadius: headerRadius,
                border: Border.all(
                  color: context.appPalette.primaryText.withValues(alpha: .28),
                  width: 1.2,
                ),
              ),
              child: Row(
                children: [
                  SizedBox.square(
                    key: const ValueKey('home-header-search-icon-frame'),
                    dimension: compactHeader ? 28 : 32,
                    child: Center(
                      child: Icon(
                        Icons.search_rounded,
                        key: const ValueKey('home-header-search-icon'),
                        size: compactHeader ? 22 : 26,
                        color: context.appPalette.primaryText,
                      ),
                    ),
                  ),
                  SizedBox(width: compactHeader ? 10 : 14),
                  Expanded(
                    child: Text(
                      value.isEmpty ? (widget.hintText ?? '') : value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: value.isEmpty
                            ? context.appPalette.primaryText.withValues(
                                alpha: .72,
                              )
                            : context.appPalette.primaryText,
                        fontSize: compactHeader ? 14 : 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return TvFocusable(
      autofocus: widget.autofocus,
      focusNode: _focusNode,
      focusScale: 1.015,
      borderRadius: BorderRadius.circular(8),
      onKeyEvent: _handleDirectionalExit,
      onPressed: () => _openKeyboard(context),
      child: Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.fromLTRB(13, 7, 10, 7),
        decoration: BoxDecoration(
          color: context.appPalette.background.withValues(alpha: .65),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: .12)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.labelText,
                    style: TextStyle(
                      color: context.appPalette.mutedText,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (widget.helperText case final helper?) ...[
                    const SizedBox(height: 3),
                    Text(
                      helper,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appPalette.mutedText,
                        fontSize: 10,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    visibleValue.isEmpty
                        ? (widget.hintText ?? '')
                        : visibleValue,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: visibleValue.isEmpty
                          ? context.appPalette.mutedText
                          : context.appPalette.primaryText,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.keyboard_rounded,
              color: context.appPalette.secondaryAccent,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}

class TvKeyboardDialog extends StatefulWidget {
  const TvKeyboardDialog({
    required this.title,
    required this.initialValue,
    this.obscureText = false,
    this.inputFormatters = const <TextInputFormatter>[],
    this.maxLength,
    this.numericOnly = false,
    this.autofillSuggestions = const [],
    super.key,
  });

  final String title;
  final String initialValue;
  final bool obscureText;
  final List<TextInputFormatter> inputFormatters;
  final int? maxLength;
  final bool numericOnly;
  final List<String> autofillSuggestions;

  @override
  State<TvKeyboardDialog> createState() => _TvKeyboardDialogState();
}

class _TvKeyboardDialogState extends State<TvKeyboardDialog> {
  static const _letterRows = <List<String>>[
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.'],
  ];
  static const _symbolRows = <List<String>>[
    ['!', '@', '#', r'$', '%', '^', '&', '*', '(', ')'],
    ['-', '_', '=', '+', '[', ']', '{', '}', r'\', '|'],
    ['.', ',', ':', ';', '/', '?', '"', "'", '<', '>'],
  ];
  static const _numberRows = <List<String>>[
    ['7', '8', '9'],
    ['4', '5', '6'],
    ['1', '2', '3'],
  ];

  late String _value;
  bool _shift = false;
  bool _symbols = false;
  late bool _reveal;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
    _reveal = !widget.obscureText;
  }

  void _append(String value) {
    final appended = _shift && !_symbols ? value.toUpperCase() : value;
    setState(() {
      _value = _formatValue('$_value$appended');
      if (_shift) _shift = false;
    });
  }

  void _backspace() {
    if (_value.isEmpty) return;
    setState(() => _value = _value.substring(0, _value.length - 1));
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text;
    if (value == null || value.isEmpty || !mounted) return;
    setState(
      () => _value = _formatValue(
        '$_value${value.replaceAll(RegExp(r'[\r\n]+'), '')}',
      ),
    );
  }

  void _autofill(String value) {
    setState(() => _value = _formatValue(value));
  }

  String _formatValue(String candidate) {
    var value = TextEditingValue(
      text: candidate,
      selection: TextSelection.collapsed(offset: candidate.length),
    );
    final oldValue = TextEditingValue(
      text: _value,
      selection: TextSelection.collapsed(offset: _value.length),
    );
    for (final formatter in widget.inputFormatters) {
      value = formatter.formatEditUpdate(oldValue, value);
    }
    final maximum = widget.maxLength;
    if (maximum != null && value.text.characters.length > maximum) {
      final clipped = value.text.characters.take(maximum).toString();
      value = TextEditingValue(
        text: clipped,
        selection: TextSelection.collapsed(offset: clipped.length),
      );
    }
    return value.text;
  }

  KeyEventResult _handlePhysicalKeyboard(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      Navigator.of(context).pop(_value);
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character != null &&
        character.length == 1 &&
        character.codeUnitAt(0) >= 32) {
      setState(() => _value = _formatValue('$_value$character'));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final displayValue = !_reveal && _value.isNotEmpty
        ? List.filled(_value.length, '\u2022').join()
        : _value;
    final rows = _symbols ? _symbolRows : _letterRows;
    final availableWidth = MediaQuery.sizeOf(context).width;
    final panelWidth = widget.numericOnly
        ? (availableWidth < 340 ? availableWidth - 20 : 320.0)
        : (availableWidth < 600 ? availableWidth - 20 : 560.0);
    return Dialog(
      alignment: Alignment.bottomCenter,
      insetPadding: EdgeInsets.fromLTRB(
        availableWidth < 600 ? 10 : 24,
        availableWidth < 600 ? 48 : 160,
        availableWidth < 600 ? 10 : 24,
        18,
      ),
      backgroundColor: Colors.transparent,
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _handlePhysicalKeyboard,
        child: Container(
          key: const ValueKey('tv-keyboard-panel'),
          width: panelWidth,
          padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              palette.surface.withValues(alpha: .40),
              palette.background,
            ).withValues(alpha: 247 / 255),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.accent.withValues(alpha: .32)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x88000000),
                blurRadius: 22,
                offset: Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        color: palette.primaryText,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    'REMOTE  /  CONTROLLER  /  KEYBOARD',
                    style: TextStyle(
                      color: palette.mutedText,
                      fontSize: 7,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .6,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: palette.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: palette.accentBright.withValues(alpha: .62),
                  ),
                ),
                child: Text(
                  displayValue.isEmpty ? 'Start typing…' : displayValue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: displayValue.isEmpty
                        ? palette.mutedText
                        : palette.primaryText,
                    fontSize: 12,
                    letterSpacing: widget.obscureText ? 1.4 : 0,
                  ),
                ),
              ),
              if (widget.autofillSuggestions.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      'AUTOFILL',
                      style: TextStyle(
                        color: palette.accentBright,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(width: 7),
                    for (final suggestion in widget.autofillSuggestions.take(
                      3,
                    )) ...[
                      _AutofillChip(
                        label: suggestion,
                        icon: Icons.auto_awesome_rounded,
                        onPressed: () => _autofill(suggestion),
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 5),
              FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!widget.numericOnly)
                      Expanded(
                        child: Column(
                          children: [
                            for (
                              var rowIndex = 0;
                              rowIndex < rows.length;
                              rowIndex++
                            )
                              Padding(
                                padding: EdgeInsets.only(
                                  left: rowIndex == 1 ? 12 : 0,
                                  right: rowIndex == 1 ? 12 : 0,
                                  bottom: 3,
                                ),
                                child: Row(
                                  children: [
                                    for (
                                      var keyIndex = 0;
                                      keyIndex < rows[rowIndex].length;
                                      keyIndex++
                                    ) ...[
                                      Expanded(
                                        child: _KeyboardKey(
                                          label: _shift && !_symbols
                                              ? rows[rowIndex][keyIndex]
                                                    .toUpperCase()
                                              : rows[rowIndex][keyIndex],
                                          autofocus:
                                              rowIndex == 0 && keyIndex == 0,
                                          onPressed: () =>
                                              _append(rows[rowIndex][keyIndex]),
                                        ),
                                      ),
                                      if (keyIndex != rows[rowIndex].length - 1)
                                        const SizedBox(width: 3),
                                    ],
                                  ],
                                ),
                              ),
                            Row(
                              children: [
                                _KeyboardAction(
                                  label: _shift ? 'Aa ON' : 'Aa',
                                  icon: Icons.arrow_upward_rounded,
                                  selected: _shift,
                                  onPressed: () => setState(() {
                                    if (_symbols) {
                                      _symbols = false;
                                      _shift = true;
                                    } else {
                                      _shift = !_shift;
                                    }
                                  }),
                                ),
                                const SizedBox(width: 3),
                                _KeyboardAction(
                                  label: _symbols ? 'ABC' : '#?&',
                                  icon: Icons.alternate_email_rounded,
                                  flex: 2,
                                  selected: _symbols,
                                  onPressed: () => setState(() {
                                    _symbols = !_symbols;
                                    _shift = false;
                                  }),
                                ),
                                const SizedBox(width: 3),
                                _KeyboardAction(
                                  label: 'SPACE',
                                  icon: Icons.space_bar_rounded,
                                  flex: 3,
                                  onPressed: () => _append(' '),
                                ),
                                const SizedBox(width: 3),
                                _KeyboardAction(
                                  label: 'DEL',
                                  icon: Icons.backspace_outlined,
                                  flex: 2,
                                  onPressed: _backspace,
                                ),
                                const SizedBox(width: 3),
                                _KeyboardAction(
                                  label: 'PASTE',
                                  icon: Icons.content_paste_rounded,
                                  flex: 2,
                                  onPressed: _paste,
                                ),
                                if (widget.obscureText) ...[
                                  const SizedBox(width: 3),
                                  _KeyboardAction(
                                    label: _reveal ? 'HIDE' : 'SHOW',
                                    icon: _reveal
                                        ? Icons.visibility_off_rounded
                                        : Icons.visibility_rounded,
                                    flex: 2,
                                    onPressed: () =>
                                        setState(() => _reveal = !_reveal),
                                  ),
                                ],
                                const SizedBox(width: 3),
                                _KeyboardAction(
                                  label: 'DONE',
                                  icon: Icons.search_rounded,
                                  flex: 2,
                                  primary: true,
                                  onPressed: () =>
                                      Navigator.of(context).pop(_value),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (!widget.numericOnly) const SizedBox(width: 8),
                    SizedBox(
                      width: widget.numericOnly ? panelWidth - 20 : 110,
                      child: Column(
                        children: [
                          for (final numberRow in _numberRows)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Row(
                                children: [
                                  for (
                                    var index = 0;
                                    index < numberRow.length;
                                    index++
                                  ) ...[
                                    Expanded(
                                      child: _KeyboardKey(
                                        label: numberRow[index],
                                        autofocus:
                                            widget.numericOnly &&
                                            numberRow.first == '7' &&
                                            index == 0,
                                        onPressed: () =>
                                            _append(numberRow[index]),
                                      ),
                                    ),
                                    if (index != numberRow.length - 1)
                                      const SizedBox(width: 3),
                                  ],
                                ],
                              ),
                            ),
                          Row(
                            children: [
                              Expanded(
                                child: _KeyboardKey(
                                  label: '0',
                                  onPressed: () => _append('0'),
                                ),
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: _KeyboardKey(
                                  label: 'BACKSPACE',
                                  compactLabel: true,
                                  onPressed: _backspace,
                                ),
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: _KeyboardKey(
                                  label: 'CLEAR',
                                  compactLabel: true,
                                  onPressed: () => setState(() => _value = ''),
                                ),
                              ),
                            ],
                          ),
                          if (widget.numericOnly) ...[
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Expanded(
                                  child: _KeyboardKey(
                                    label: 'CANCEL',
                                    compactLabel: true,
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                  ),
                                ),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: _KeyboardKey(
                                    label: 'DONE',
                                    compactLabel: true,
                                    onPressed: () =>
                                        Navigator.of(context).pop(_value),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyboardKey extends StatelessWidget {
  const _KeyboardKey({
    required this.label,
    required this.onPressed,
    this.autofocus = false,
    this.compactLabel = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool autofocus;
  final bool compactLabel;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      focusScale: 1.04,
      borderRadius: BorderRadius.circular(8),
      onPressed: onPressed,
      child: Container(
        height: 26,
        alignment: Alignment.center,
        color: context.appPalette.selectableSurface,
        child: Text(
          label,
          style: TextStyle(
            fontSize: compactLabel ? 6 : 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _KeyboardAction extends StatelessWidget {
  const _KeyboardAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.flex = 1,
    this.primary = false,
    this.selected = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final int flex;
  final bool primary;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      flex: flex,
      child: TvFocusable(
        focusScale: 1.025,
        borderRadius: BorderRadius.circular(8),
        onPressed: onPressed,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          color: primary
              ? context.appPalette.accent
              : selected
              ? context.appPalette.accent.withValues(alpha: .45)
              : context.appPalette.selectableSurface,
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 28) {
                return Center(
                  child: Icon(
                    icon,
                    size: constraints.maxWidth.clamp(7, 11).toDouble(),
                  ),
                );
              }
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 1),
                  Icon(icon, size: 11),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 7,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 1),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AutofillChip extends StatelessWidget {
  const _AutofillChip({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: TvFocusable(
        onPressed: onPressed,
        focusScale: 1.02,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          color: context.appPalette.selectableSurface,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: context.appPalette.accentBright),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
