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
    ['z', 'x', 'c', 'v', 'b', 'n', 'm', '.', ','],
  ];
  static const _symbolRows = <List<String>>[
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['-', '_', '=', '+', '[', ']', '{', '}', r'\', '|'],
    ['.', ',', ':', ';', '/', '?', '"', "'", '<', '>'],
  ];
  late String _value;
  late int _cursorOffset;
  bool _shift = false;
  bool _symbols = false;
  late bool _reveal;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
    _cursorOffset = _value.length;
    _reveal = !widget.obscureText;
  }

  void _append(String value) {
    final appended = _shift && !_symbols ? value.toUpperCase() : value;
    setState(() {
      final candidate =
          '${_value.substring(0, _cursorOffset)}$appended${_value.substring(_cursorOffset)}';
      final formatted = _formatValue(
        candidate,
        selectionOffset: _cursorOffset + appended.length,
      );
      _value = formatted.text;
      _cursorOffset = formatted.selection.baseOffset.clamp(0, _value.length);
      if (_shift) _shift = false;
    });
  }

  void _backspace() {
    if (_value.isEmpty || _cursorOffset == 0) return;
    setState(() {
      final candidate =
          '${_value.substring(0, _cursorOffset - 1)}${_value.substring(_cursorOffset)}';
      final formatted = _formatValue(
        candidate,
        selectionOffset: _cursorOffset - 1,
      );
      _value = formatted.text;
      _cursorOffset = formatted.selection.baseOffset.clamp(0, _value.length);
    });
  }

  void _moveCursor(int delta) {
    setState(() {
      _cursorOffset = (_cursorOffset + delta).clamp(0, _value.length);
    });
  }

  void _clear() {
    setState(() {
      _value = '';
      _cursorOffset = 0;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final value = data?.text;
    if (value == null || value.isEmpty || !mounted) return;
    final pasted = value.replaceAll(RegExp(r'[\r\n]+'), '');
    setState(() {
      final candidate =
          '${_value.substring(0, _cursorOffset)}$pasted${_value.substring(_cursorOffset)}';
      final formatted = _formatValue(
        candidate,
        selectionOffset: _cursorOffset + pasted.length,
      );
      _value = formatted.text;
      _cursorOffset = formatted.selection.baseOffset.clamp(0, _value.length);
    });
  }

  void _autofill(String value) {
    setState(() {
      final formatted = _formatValue(value, selectionOffset: value.length);
      _value = formatted.text;
      _cursorOffset = formatted.selection.baseOffset.clamp(0, _value.length);
    });
  }

  TextEditingValue _formatValue(
    String candidate, {
    required int selectionOffset,
  }) {
    var value = TextEditingValue(
      text: candidate,
      selection: TextSelection.collapsed(
        offset: selectionOffset.clamp(0, candidate.length),
      ),
    );
    final oldValue = TextEditingValue(
      text: _value,
      selection: TextSelection.collapsed(offset: _cursorOffset),
    );
    for (final formatter in widget.inputFormatters) {
      value = formatter.formatEditUpdate(oldValue, value);
    }
    final maximum = widget.maxLength;
    if (maximum != null && value.text.characters.length > maximum) {
      final clipped = value.text.characters.take(maximum).toString();
      value = TextEditingValue(
        text: clipped,
        selection: TextSelection.collapsed(
          offset: value.selection.baseOffset.clamp(0, clipped.length),
        ),
      );
    }
    return value;
  }

  KeyEventResult _handlePhysicalKeyboard(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.browserBack) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      Navigator.of(context).pop(_value);
      return KeyEventResult.handled;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final pasteShortcut =
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (pressed.contains(LogicalKeyboardKey.controlLeft) ||
            pressed.contains(LogicalKeyboardKey.controlRight) ||
            pressed.contains(LogicalKeyboardKey.metaLeft) ||
            pressed.contains(LogicalKeyboardKey.metaRight));
    if (pasteShortcut ||
        (event.logicalKey == LogicalKeyboardKey.insert &&
            (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
                pressed.contains(LogicalKeyboardKey.shiftRight)))) {
      _paste();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character != null &&
        character.length == 1 &&
        character.codeUnitAt(0) >= 32) {
      _append(character);
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
    final availableSize = MediaQuery.sizeOf(context);
    final availableWidth = availableSize.width;
    final availableHeight = availableSize.height;
    final narrow = availableWidth < 720;
    final horizontalInset = narrow ? 10.0 : 20.0;
    final maximumPanelWidth = (availableWidth - (horizontalInset * 2)).clamp(
      0.0,
      double.infinity,
    );
    final desiredWidth = widget.numericOnly ? 820.0 : 1160.0;
    final panelWidth = desiredWidth.clamp(0.0, maximumPanelWidth).toDouble();
    final widthScale = (panelWidth / desiredWidth).clamp(.64, 1.0);
    final heightTarget = availableHeight < 500
        ? (widget.numericOnly ? 720.0 : 620.0)
        : (widget.numericOnly ? 640.0 : 525.0);
    final heightScale = (availableHeight / heightTarget).clamp(.48, 1.0);
    final responsiveScale = widthScale < heightScale ? widthScale : heightScale;
    // Keep the controller keyboard in the same compact lower-screen footprint
    // as TetoTV's original keyboard. The refreshed layout has larger nominal
    // key metrics, so allowing a wide TV to use a 1:1 scale makes the dialog
    // consume most of a 1080p viewport. Phones still use the fully responsive
    // scale because they need the extra touch target size.
    final wideTvScaleCap = widget.numericOnly ? .36 : .40;
    final scale = !narrow && responsiveScale > wideTvScaleCap
        ? wideTvScaleCap
        : responsiveScale;
    final keyHeight = (widget.numericOnly ? 64.0 : 58.0) * scale;
    final actionHeight = (widget.numericOnly ? 68.0 : 58.0) * scale;
    final keyGap = (widget.numericOnly ? 10.0 : 8.0) * scale;
    final panelPadding = (widget.numericOnly ? 26.0 : 28.0) * scale;
    final titleSize = (widget.numericOnly ? 30.0 : 28.0) * scale;
    final inputHeight = (widget.numericOnly ? 70.0 : 62.0) * scale;
    final inputFontSize = (widget.numericOnly ? 25.0 : 23.0) * scale;
    final submitLabel = widget.title.toLowerCase().contains('search')
        ? 'Search'
        : 'Done';

    Widget keyboardKey({
      required String id,
      String? label,
      IconData? icon,
      String? semanticLabel,
      required VoidCallback onPressed,
      bool autofocus = false,
      bool primary = false,
      bool selected = false,
      double? height,
      double? fontSize,
    }) {
      return _KeyboardKey(
        key: ValueKey('tv-keyboard-key-$id'),
        label: label,
        icon: icon,
        semanticLabel: semanticLabel ?? label ?? id,
        autofocus: autofocus,
        primary: primary,
        selected: selected,
        height: height ?? keyHeight,
        fontSize: fontSize ?? (21 * scale).clamp(12, 21),
        onPressed: onPressed,
      );
    }

    Widget flexKey({
      required String id,
      String? label,
      IconData? icon,
      String? semanticLabel,
      required VoidCallback onPressed,
      int flex = 10,
      bool autofocus = false,
      bool primary = false,
      bool selected = false,
      double? height,
      double? fontSize,
    }) {
      return Expanded(
        flex: flex,
        child: keyboardKey(
          id: id,
          label: label,
          icon: icon,
          semanticLabel: semanticLabel,
          onPressed: onPressed,
          autofocus: autofocus,
          primary: primary,
          selected: selected,
          height: height,
          fontSize: fontSize,
        ),
      );
    }

    Widget textRow(
      List<String> labels, {
      double leftInset = 0,
      bool autofocusFirst = false,
    }) {
      return Padding(
        padding: EdgeInsets.only(left: leftInset),
        child: Row(
          children: [
            for (var index = 0; index < labels.length; index++) ...[
              flexKey(
                id: 'text-${labels[index]}-$index',
                label: _shift && !_symbols
                    ? labels[index].toUpperCase()
                    : labels[index],
                autofocus: autofocusFirst && index == 0,
                onPressed: () => _append(labels[index]),
              ),
              if (index != labels.length - 1) SizedBox(width: keyGap),
            ],
          ],
        ),
      );
    }

    Widget numericRow(List<String> labels, {String? autofocusLabel}) {
      return Row(
        children: [
          for (var index = 0; index < labels.length; index++) ...[
            flexKey(
              id: 'number-${labels[index]}',
              label: labels[index],
              autofocus: labels[index] == autofocusLabel,
              onPressed: () => _append(labels[index]),
              height: keyHeight,
            ),
            if (index != labels.length - 1) SizedBox(width: keyGap),
          ],
        ],
      );
    }

    Widget qwertyKeyboard() {
      final numberPadWidth = narrow ? 0.0 : panelWidth * .225;
      final thirdRow = rows[2];
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              children: [
                textRow(rows[0], autofocusFirst: true),
                SizedBox(height: keyGap),
                textRow(rows[1], leftInset: 28 * scale),
                SizedBox(height: keyGap),
                Row(
                  children: [
                    flexKey(
                      id: 'shift',
                      icon: Icons.arrow_upward_rounded,
                      semanticLabel: 'Shift',
                      flex: 14,
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
                    SizedBox(width: keyGap),
                    for (var index = 0; index < thirdRow.length; index++) ...[
                      flexKey(
                        id: 'text-${thirdRow[index]}-third-$index',
                        label: _shift && !_symbols
                            ? thirdRow[index].toUpperCase()
                            : thirdRow[index],
                        onPressed: () => _append(thirdRow[index]),
                      ),
                      if (index != thirdRow.length - 1) SizedBox(width: keyGap),
                    ],
                  ],
                ),
                SizedBox(height: keyGap),
                Row(
                  children: [
                    flexKey(
                      id: 'symbols',
                      label: _symbols ? 'ABC' : '123?',
                      semanticLabel: _symbols
                          ? 'Letters keyboard'
                          : 'Symbols keyboard',
                      flex: 14,
                      fontSize: (17 * scale).clamp(10, 17),
                      selected: _symbols,
                      onPressed: () => setState(() {
                        _symbols = !_symbols;
                        _shift = false;
                      }),
                    ),
                    SizedBox(width: keyGap),
                    flexKey(
                      id: 'cursor-left',
                      icon: Icons.arrow_left_rounded,
                      semanticLabel: 'Cursor left',
                      flex: 9,
                      onPressed: () => _moveCursor(-1),
                    ),
                    SizedBox(width: keyGap),
                    flexKey(
                      id: 'cursor-right',
                      icon: Icons.arrow_right_rounded,
                      semanticLabel: 'Cursor right',
                      flex: 9,
                      onPressed: () => _moveCursor(1),
                    ),
                    SizedBox(width: keyGap),
                    flexKey(
                      id: 'space',
                      icon: Icons.space_bar_rounded,
                      semanticLabel: 'Space',
                      flex: 44,
                      onPressed: () => _append(' '),
                    ),
                    SizedBox(width: keyGap),
                    flexKey(
                      id: 'minus',
                      label: '-',
                      flex: 9,
                      onPressed: () => _append('-'),
                    ),
                    SizedBox(width: keyGap),
                    flexKey(
                      id: 'underscore',
                      label: '_',
                      flex: 9,
                      onPressed: () => _append('_'),
                    ),
                    SizedBox(width: keyGap),
                    flexKey(
                      id: 'number-0',
                      label: '0',
                      flex: 9,
                      onPressed: () => _append('0'),
                    ),
                  ],
                ),
                if (narrow) ...[
                  SizedBox(height: keyGap),
                  Row(
                    children: [
                      flexKey(
                        id: 'backspace',
                        icon: Icons.backspace_outlined,
                        semanticLabel: 'Backspace',
                        onPressed: _backspace,
                      ),
                      SizedBox(width: keyGap),
                      flexKey(
                        id: 'submit',
                        label: submitLabel,
                        semanticLabel: submitLabel,
                        primary: true,
                        onPressed: () => Navigator.of(context).pop(_value),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (!narrow) ...[
            SizedBox(width: keyGap * 1.5),
            SizedBox(
              width: numberPadWidth,
              child: Column(
                children: [
                  numericRow(const ['1', '2', '3']),
                  SizedBox(height: keyGap),
                  numericRow(const ['4', '5', '6']),
                  SizedBox(height: keyGap),
                  numericRow(const ['7', '8', '9']),
                  SizedBox(height: keyGap),
                  Row(
                    children: [
                      flexKey(
                        id: 'backspace',
                        icon: Icons.backspace_outlined,
                        semanticLabel: 'Backspace',
                        onPressed: _backspace,
                      ),
                      SizedBox(width: keyGap),
                      flexKey(
                        id: 'submit',
                        label: submitLabel,
                        semanticLabel: submitLabel,
                        primary: true,
                        fontSize: (18 * scale).clamp(11, 18),
                        onPressed: () => Navigator.of(context).pop(_value),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }

    Widget numericKeyboard() {
      return Column(
        children: [
          numericRow(const ['1', '2', '3']),
          SizedBox(height: keyGap),
          numericRow(const ['4', '5', '6']),
          SizedBox(height: keyGap),
          numericRow(const ['7', '8', '9'], autofocusLabel: '7'),
          SizedBox(height: keyGap),
          Row(
            children: [
              flexKey(
                id: 'backspace',
                icon: Icons.backspace_outlined,
                semanticLabel: 'Backspace',
                onPressed: _backspace,
              ),
              SizedBox(width: keyGap),
              flexKey(
                id: 'number-0',
                label: '0',
                onPressed: () => _append('0'),
              ),
              SizedBox(width: keyGap),
              flexKey(
                id: 'clear',
                label: 'CLEAR',
                fontSize: (18 * scale).clamp(11, 18),
                onPressed: _clear,
              ),
            ],
          ),
          SizedBox(height: keyGap * 1.35),
          Row(
            children: [
              flexKey(
                id: 'cancel',
                label: 'CANCEL',
                height: actionHeight,
                fontSize: (19 * scale).clamp(12, 19),
                onPressed: () => Navigator.of(context).pop(),
              ),
              SizedBox(width: keyGap * 1.5),
              flexKey(
                id: 'submit',
                label: 'DONE',
                height: actionHeight,
                fontSize: (19 * scale).clamp(12, 19),
                primary: true,
                onPressed: () => Navigator.of(context).pop(_value),
              ),
            ],
          ),
        ],
      );
    }

    return Dialog(
      alignment: Alignment.bottomCenter,
      insetPadding: EdgeInsets.symmetric(
        horizontal: horizontalInset,
        vertical: narrow ? 10 : 12,
      ),
      backgroundColor: Colors.transparent,
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _handlePhysicalKeyboard,
        child: SingleChildScrollView(
          child: Container(
            key: const ValueKey('tv-keyboard-panel'),
            width: panelWidth,
            padding: EdgeInsets.all(panelPadding),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                palette.surface.withValues(alpha: .58),
                palette.background,
              ).withValues(alpha: .97),
              borderRadius: BorderRadius.circular(20 * scale),
              border: Border.all(
                color: palette.accentBright.withValues(alpha: .82),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .72),
                  blurRadius: 28,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (narrow)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.primaryText,
                          fontSize: titleSize,
                          fontWeight: FontWeight.w800,
                          height: 1.08,
                        ),
                      ),
                      SizedBox(height: 7 * scale),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'REMOTE  /  CONTROLLER  /  KEYBOARD',
                            key: const ValueKey('tv-keyboard-input-modes'),
                            style: TextStyle(
                              color: palette.primaryText.withValues(alpha: .90),
                              fontSize: (16 * scale).clamp(8, 16),
                              fontWeight: FontWeight.w800,
                              letterSpacing: .35,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: widget.numericOnly ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.primaryText,
                            fontSize: titleSize,
                            fontWeight: FontWeight.w800,
                            height: 1.08,
                          ),
                        ),
                      ),
                      SizedBox(width: 18 * scale),
                      Text(
                        'REMOTE  /  CONTROLLER  /  KEYBOARD',
                        key: const ValueKey('tv-keyboard-input-modes'),
                        style: TextStyle(
                          color: palette.primaryText.withValues(alpha: .90),
                          fontSize: (16 * scale).clamp(8, 16),
                          fontWeight: FontWeight.w800,
                          letterSpacing: .35,
                        ),
                      ),
                    ],
                  ),
                SizedBox(height: 14 * scale),
                Container(
                  key: const ValueKey('tv-keyboard-input'),
                  width: double.infinity,
                  height: inputHeight,
                  padding: EdgeInsets.symmetric(horizontal: 18 * scale),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .58),
                    borderRadius: BorderRadius.circular(18 * scale),
                    border: Border.all(
                      color: palette.accentBright.withValues(alpha: .88),
                      width: 1.8,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          displayValue.isEmpty ? 'Start typing…' : displayValue,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: displayValue.isEmpty
                                ? palette.mutedText
                                : palette.primaryText,
                            fontSize: inputFontSize,
                            letterSpacing: widget.obscureText ? 1.4 : 0,
                          ),
                        ),
                      ),
                      if (widget.obscureText) ...[
                        SizedBox(width: 8 * scale),
                        SizedBox(
                          width: inputHeight * .72,
                          child: keyboardKey(
                            id: 'reveal',
                            icon: _reveal
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            semanticLabel: _reveal
                                ? 'Hide entered text'
                                : 'Show entered text',
                            height: inputHeight * .68,
                            onPressed: () => setState(() => _reveal = !_reveal),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.autofillSuggestions.isNotEmpty) ...[
                  SizedBox(height: 8 * scale),
                  Row(
                    children: [
                      Text(
                        'AUTOFILL',
                        style: TextStyle(
                          color: palette.accentBright,
                          fontSize: (12 * scale).clamp(8, 12),
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
                SizedBox(height: 16 * scale),
                FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: widget.numericOnly
                      ? numericKeyboard()
                      : qwertyKeyboard(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyboardKey extends StatelessWidget {
  const _KeyboardKey({
    required this.onPressed,
    required this.height,
    required this.fontSize,
    required this.semanticLabel,
    this.label,
    this.icon,
    this.autofocus = false,
    this.primary = false,
    this.selected = false,
    super.key,
  });

  final String? label;
  final IconData? icon;
  final String semanticLabel;
  final VoidCallback onPressed;
  final double height;
  final double fontSize;
  final bool autofocus;
  final bool primary;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final radius = BorderRadius.circular((height * .18).clamp(7, 12));
    final keyColor = primary
        ? palette.accent
        : selected
        ? Color.alphaBlend(
            palette.accent.withValues(alpha: .42),
            palette.surfaceRaised,
          )
        : Color.alphaBlend(
            Colors.white.withValues(alpha: .075),
            palette.surface,
          );
    return Semantics(
      label: semanticLabel,
      button: true,
      excludeSemantics: true,
      child: TvFocusable(
        autofocus: autofocus,
        focusScale: 1.025,
        borderRadius: radius,
        onPressed: onPressed,
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: keyColor,
            borderRadius: radius,
            border: Border.all(
              color: primary
                  ? palette.accentBright.withValues(alpha: .34)
                  : palette.primaryText.withValues(alpha: .07),
            ),
          ),
          child: icon != null
              ? Icon(
                  icon,
                  size: (fontSize * 1.35).clamp(16, 30),
                  color: palette.primaryText,
                )
              : Text(
                  label ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.primaryText,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w700,
                  ),
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
