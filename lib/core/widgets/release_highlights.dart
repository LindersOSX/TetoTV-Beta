import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/updates/release_notes_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ReleaseHighlightsList extends StatelessWidget {
  const ReleaseHighlightsList({required this.notes, this.style, super.key});

  final String notes;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final items = customerReleaseHighlights(notes);
    final textStyle =
        style ?? TextStyle(color: context.appPalette.primaryText, height: 1.4);
    if (items.isEmpty) {
      return LocalizedText(
        'Update details are available on GitHub.',
        style: textStyle,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            key: ValueKey('release-highlight-$i'),
            padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 10),
                  child: Icon(
                    Icons.circle,
                    size: 5,
                    color: context.appPalette.accentBright,
                  ),
                ),
                Expanded(child: Text(items[i], style: textStyle)),
              ],
            ),
          ),
      ],
    );
  }
}

class ReleaseHighlightsDialog extends StatefulWidget {
  const ReleaseHighlightsDialog({required this.notes, super.key});

  final String notes;

  @override
  State<ReleaseHighlightsDialog> createState() =>
      _ReleaseHighlightsDialogState();
}

class _ReleaseHighlightsDialogState extends State<ReleaseHighlightsDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.pageDown => 1,
      LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.pageUp => -1,
      _ => 0,
    };
    if (direction == 0 || !_scroll.hasClients) return KeyEventResult.ignored;
    _scroll.animateTo(
      (_scroll.offset + direction * 160).clamp(
        0,
        _scroll.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: _handleKey,
    child: AlertDialog(
      backgroundColor: context.appPalette.surface,
      title: Text(context.tr("What's new in TetoTV")),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: (MediaQuery.sizeOf(context).height * .5).clamp(120, 420),
        ),
        child: SingleChildScrollView(
          controller: _scroll,
          child: ReleaseHighlightsList(notes: widget.notes),
        ),
      ),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Continue')),
        ),
      ],
    ),
  );
}
