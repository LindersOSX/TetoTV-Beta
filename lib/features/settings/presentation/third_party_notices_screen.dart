import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ThirdPartyNoticesScreen extends StatefulWidget {
  const ThirdPartyNoticesScreen({super.key});

  @override
  State<ThirdPartyNoticesScreen> createState() =>
      _ThirdPartyNoticesScreenState();
}

class _ThirdPartyNoticesScreenState extends State<ThirdPartyNoticesScreen> {
  final _scrollController = ScrollController();
  late final FocusNode _backFocusNode;
  late final FocusNode _licensesFocusNode;
  late final Future<String> _notices = rootBundle.loadString(
    'docs/THIRD_PARTY_NOTICES.md',
  );

  @override
  void initState() {
    super.initState();
    _backFocusNode = FocusNode(
      debugLabel: 'notices.back',
      onKeyEvent: _handleKey,
    );
    _licensesFocusNode = FocusNode(
      debugLabel: 'notices.packages',
      onKeyEvent: _handleKey,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _backFocusNode.dispose();
    _licensesFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final compact = context.isCompactWidth;
    if (compact &&
        event.logicalKey == LogicalKeyboardKey.arrowDown &&
        _backFocusNode.hasFocus) {
      _licensesFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (compact &&
        event.logicalKey == LogicalKeyboardKey.arrowUp &&
        _licensesFocusNode.hasFocus) {
      _backFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
        _backFocusNode.hasFocus) {
      _licensesFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        _licensesFocusNode.hasFocus) {
      _backFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.pageDown => 1,
      LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.pageUp => -1,
      _ => 0,
    };
    if (direction == 0 || !_scrollController.hasClients) {
      return KeyEventResult.ignored;
    }
    final position = _scrollController.position;
    final destination = (position.pixels + direction * 260).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollController.animateTo(
      destination.toDouble(),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
    return KeyEventResult.handled;
  }

  void _openPackageLicenses() {
    showLicensePage(
      context: context,
      applicationName: 'TetoTV',
      applicationLegalese:
          'TetoTV is an independent, unofficial application.\n\n'
          '重音テト © 線 / 小山乃舞世 / TWINDRILL',
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompactWidth;
    final palette = context.appPalette;
    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        minimum: context.responsiveScreenPadding,
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: _handleKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _NoticesHeader(
                compact: compact,
                backFocusNode: _backFocusNode,
                licensesFocusNode: _licensesFocusNode,
                onBack: Navigator.of(context).pop,
                onOpenLicenses: _openPackageLicenses,
              ),
              const SizedBox(height: 14),
              Expanded(
                child: FutureBuilder<String>(
                  future: _notices,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return Center(
                        child: CircularProgressIndicator(
                          color: palette.accentBright,
                        ),
                      );
                    }
                    if (snapshot.hasError || snapshot.data == null) {
                      return Center(
                        child: Text(
                          'Third-party notices could not be loaded.',
                          style: TextStyle(color: palette.mutedText),
                        ),
                      );
                    }
                    return Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(right: 20, bottom: 36),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1080),
                            child: _NoticeDocument(
                              markdown: snapshot.data!,
                              compact: compact,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticesHeader extends StatelessWidget {
  const _NoticesHeader({
    required this.compact,
    required this.backFocusNode,
    required this.licensesFocusNode,
    required this.onBack,
    required this.onOpenLicenses,
  });

  final bool compact;
  final FocusNode backFocusNode;
  final FocusNode licensesFocusNode;
  final VoidCallback onBack;
  final VoidCallback onOpenLicenses;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final back = _NoticeAction(
      autofocus: true,
      focusNode: backFocusNode,
      icon: Icons.arrow_back_rounded,
      label: 'Back',
      onPressed: onBack,
    );
    final licenses = _NoticeAction(
      focusNode: licensesFocusNode,
      icon: Icons.description_outlined,
      label: compact ? 'Package licenses' : 'Flutter package licenses',
      onPressed: onOpenLicenses,
    );
    final title = Text(
      'Third-party notices',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: palette.primaryText,
        fontSize: compact ? 22 : 26,
        fontWeight: FontWeight.w900,
      ),
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              back,
              const SizedBox(width: 14),
              Expanded(child: title),
            ],
          ),
          const SizedBox(height: 10),
          licenses,
        ],
      );
    }
    return Row(
      children: [
        back,
        const SizedBox(width: 16),
        Expanded(child: title),
        const SizedBox(width: 16),
        licenses,
      ],
    );
  }
}

class _NoticeAction extends StatelessWidget {
  const _NoticeAction({
    required this.focusNode,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  final FocusNode focusNode;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      borderRadius: BorderRadius.circular(10),
      onPressed: onPressed,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.accent.withValues(alpha: .42)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: palette.primaryText, size: 21),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: palette.primaryText,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeDocument extends StatelessWidget {
  const _NoticeDocument({required this.markdown, required this.compact});

  final String markdown;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final blocks = _NoticeBlock.parse(markdown);
    return Semantics(
      label: 'Third-party notices document',
      readOnly: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final block in blocks) ...[
            _NoticeBlockView(block: block, compact: compact),
            SizedBox(height: block.type == _NoticeBlockType.heading ? 10 : 12),
          ],
        ],
      ),
    );
  }
}

enum _NoticeBlockType { heading, paragraph, bullet, code, table }

class _NoticeBlock {
  const _NoticeBlock(this.type, this.lines, {this.level = 0});

  final _NoticeBlockType type;
  final List<String> lines;
  final int level;

  static List<_NoticeBlock> parse(String source) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final blocks = <_NoticeBlock>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index].trimRight();
      if (line.trim().isEmpty) {
        index++;
        continue;
      }
      if (line.trim() == '```text' || line.trim() == '```') {
        final code = <String>[];
        index++;
        while (index < lines.length && lines[index].trim() != '```') {
          code.add(lines[index]);
          index++;
        }
        if (index < lines.length) index++;
        blocks.add(_NoticeBlock(_NoticeBlockType.code, code));
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.+)$').firstMatch(line);
      if (heading != null) {
        blocks.add(
          _NoticeBlock(_NoticeBlockType.heading, [
            heading.group(2)!,
          ], level: heading.group(1)!.length),
        );
        index++;
        continue;
      }
      if (line.trimLeft().startsWith('|')) {
        final table = <String>[];
        while (index < lines.length &&
            lines[index].trimLeft().startsWith('|')) {
          table.add(lines[index].trim());
          index++;
        }
        blocks.add(_NoticeBlock(_NoticeBlockType.table, table));
        continue;
      }
      if (line.trimLeft().startsWith('- ')) {
        final bullet = <String>[line.trimLeft().substring(2)];
        index++;
        while (index < lines.length &&
            lines[index].trim().isNotEmpty &&
            !lines[index].trimLeft().startsWith('- ') &&
            !RegExp(r'^(#{1,6})\s+').hasMatch(lines[index]) &&
            !lines[index].trimLeft().startsWith('|')) {
          bullet.add(lines[index].trim());
          index++;
        }
        blocks.add(_NoticeBlock(_NoticeBlockType.bullet, bullet));
        continue;
      }
      final paragraph = <String>[line.trim()];
      index++;
      while (index < lines.length &&
          lines[index].trim().isNotEmpty &&
          !lines[index].trimLeft().startsWith('- ') &&
          !lines[index].trimLeft().startsWith('|') &&
          !lines[index].trimLeft().startsWith('```') &&
          !RegExp(r'^(#{1,6})\s+').hasMatch(lines[index])) {
        paragraph.add(lines[index].trim());
        index++;
      }
      blocks.add(_NoticeBlock(_NoticeBlockType.paragraph, paragraph));
    }
    return blocks;
  }
}

class _NoticeBlockView extends StatelessWidget {
  const _NoticeBlockView({required this.block, required this.compact});

  final _NoticeBlock block;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final bodyStyle = _bodyStyle(context);
    final text = _plainInline(block.lines.join(' '));
    return switch (block.type) {
      _NoticeBlockType.heading => Text(
        text,
        style: TextStyle(
          color: block.level == 1 ? palette.primaryText : palette.accentBright,
          fontSize: block.level == 1
              ? (compact ? 22 : 28)
              : (compact ? 18 : 21),
          fontWeight: FontWeight.w900,
          height: 1.2,
        ),
      ),
      _NoticeBlockType.paragraph => SelectableText(text, style: bodyStyle),
      _NoticeBlockType.bullet => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 10),
            child: Text('•', style: TextStyle(color: palette.accentBright)),
          ),
          Expanded(child: SelectableText(text, style: bodyStyle)),
        ],
      ),
      _NoticeBlockType.code => DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.accent.withValues(alpha: .42)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            block.lines.join('\n'),
            style: bodyStyle.copyWith(color: palette.primaryText),
          ),
        ),
      ),
      _NoticeBlockType.table => _NoticeTable(
        lines: block.lines,
        compact: compact,
      ),
    };
  }
}

TextStyle _bodyStyle(BuildContext context) => TextStyle(
  color: context.appPalette.primaryText.withValues(alpha: .86),
  fontSize: 15,
  height: 1.55,
);

class _NoticeTable extends StatelessWidget {
  const _NoticeTable({required this.lines, required this.compact});

  final List<String> lines;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final bodyStyle = _bodyStyle(context);
    final rows = lines.map(_tableCells).toList(growable: false);
    final content = rows.length > 2
        ? rows.skip(2).toList()
        : const <List<String>>[];
    if (content.isEmpty) return const SizedBox.shrink();
    if (compact) {
      return Column(
        children: [
          for (final row in content)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: palette.accent.withValues(alpha: .42),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.isEmpty ? '' : _plainInline(row[0]),
                        style: TextStyle(
                          color: palette.primaryText,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (row.length > 1) ...[
                        const SizedBox(height: 7),
                        Text(_plainInline(row[1]), style: bodyStyle),
                      ],
                      if (row.length > 2) ...[
                        const SizedBox(height: 7),
                        Text(
                          _plainInline(row[2]),
                          style: bodyStyle.copyWith(
                            color: palette.accentBright,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Table(
        border: TableBorder.all(color: palette.accent.withValues(alpha: .42)),
        columnWidths: const {
          0: FlexColumnWidth(1.15),
          1: FlexColumnWidth(1.7),
          2: FlexColumnWidth(1.25),
        },
        children: [
          if (rows.isNotEmpty) _tableRow(context, rows.first, heading: true),
          for (final row in content) _tableRow(context, row),
        ],
      ),
    );
  }

  TableRow _tableRow(
    BuildContext context,
    List<String> row, {
    bool heading = false,
  }) {
    final palette = context.appPalette;
    return TableRow(
      decoration: BoxDecoration(
        color: heading ? palette.surfaceRaised : palette.surface,
      ),
      children: [
        for (var index = 0; index < 3; index++)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              index < row.length ? _plainInline(row[index]) : '',
              style: _bodyStyle(context).copyWith(
                color: heading
                    ? palette.primaryText
                    : palette.primaryText.withValues(alpha: .86),
                fontWeight: heading ? FontWeight.w900 : FontWeight.w400,
              ),
            ),
          ),
      ],
    );
  }
}

List<String> _tableCells(String line) {
  final trimmed = line.trim();
  final withoutEdges = trimmed.substring(1, trimmed.length - 1);
  return withoutEdges.split('|').map((cell) => cell.trim()).toList();
}

String _plainInline(String value) {
  return value
      .replaceAll('`', '')
      .replaceAll('**', '')
      .replaceAllMapped(RegExp(r'<(https://[^>]+)>'), (match) => match[1]!)
      .trim();
}
