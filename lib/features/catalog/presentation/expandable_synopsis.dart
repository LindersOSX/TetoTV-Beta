import 'dart:math' as math;

import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/theme/teto_box_style.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:anime_tv/core/widgets/teto_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A still preview with an explicit, remote-accessible full-description reader.
class ExpandableSynopsis extends StatefulWidget {
  const ExpandableSynopsis({
    required this.text,
    required this.maxLines,
    this.style,
    super.key,
  });
  final String text;
  final int maxLines;
  final TextStyle? style;

  @override
  State<ExpandableSynopsis> createState() => _ExpandableSynopsisState();
}

class _ExpandableSynopsisState extends State<ExpandableSynopsis> {
  final _arrowFocus = FocusNode();
  bool _open = false;

  @override
  void dispose() {
    _arrowFocus.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    if (_open) return;
    _open = true;
    await showTetoDialog<void>(
      context: context,
      builder: (_) => _SynopsisReader(text: widget.text, style: widget.style),
    );
    _open = false;
    if (mounted) _arrowFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final style = DefaultTextStyle.of(context).style.merge(widget.style);
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: widget.maxLines,
      )..layout(maxWidth: constraints.maxWidth);
      final overflow =
          painter.didExceedMaxLines || painter.height > constraints.maxHeight;
      final arrowHeight = constraints.hasBoundedHeight
          ? math.min(44.0, constraints.maxHeight)
          : 44.0;
      final previewHeight = constraints.hasBoundedHeight
          ? math.max(0.0, constraints.maxHeight - (overflow ? arrowHeight : 0))
          : painter.height;
      painter.dispose();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: previewHeight),
            child: ClipRect(
              child: Text(
                widget.text,
                style: widget.style,
                maxLines: widget.maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (overflow)
            Center(
              child: Semantics(
                label: context.tr('Description'),
                child: TvFocusable(
                  key: const ValueKey('synopsis-expand'),
                  focusNode: _arrowFocus,
                  focusScale: 1,
                  onPressed: _read,
                  child: SizedBox(
                    width: 48,
                    height: arrowHeight,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: context.appPalette.primaryText,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _SynopsisReader extends StatefulWidget {
  const _SynopsisReader({required this.text, this.style});
  final String text;
  final TextStyle? style;
  @override
  State<_SynopsisReader> createState() => _SynopsisReaderState();
}

class _SynopsisReaderState extends State<_SynopsisReader> {
  final _scroll = ScrollController();
  final _readingFocus = FocusNode();
  final _closeFocus = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _scroll.dispose();
    _readingFocus.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _closeFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      if (_scroll.hasClients) {
        final delta = _scroll.position.viewportDimension * .2;
        _scroll.jumpTo(
          (_scroll.offset +
                  (key == LogicalKeyboardKey.arrowDown ? delta : -delta))
              .clamp(0.0, _scroll.position.maxScrollExtent),
        );
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Dialog(
    shape: TetoBoxStyle.shape(context.appPalette),
    backgroundColor: TetoBoxStyle.fill(context.appPalette),
    child: SizedBox(
      width: 780,
      height: MediaQuery.sizeOf(context).height * .75,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                TetoBackButton(
                  focusNode: _closeFocus,
                  onPressed: () => Navigator.of(context).pop(),
                  onKeyEvent: (node, event) {
                    if (event is! KeyUpEvent &&
                        (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                            event.logicalKey ==
                                LogicalKeyboardKey.arrowRight)) {
                      _readingFocus.requestFocus();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    context.tr('Description'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Focus(
                autofocus: true,
                focusNode: _readingFocus,
                onKeyEvent: _key,
                onFocusChange: (focused) => setState(() => _focused = focused),
                child: Container(
                  decoration: TetoBoxStyle.decoration(
                    context.appPalette,
                    focused: _focused,
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      key: const ValueKey('synopsis-reader-scroll'),
                      controller: _scroll,
                      child: Text(widget.text, style: widget.style),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
