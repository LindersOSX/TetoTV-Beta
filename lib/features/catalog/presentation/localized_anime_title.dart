import 'package:flutter/material.dart';

/// Renders the title selected by the catalog's Title Language preference.
///
/// Titles are external metadata, not interface copy. The UI locale must not
/// translate or replace them, so callers pass the already-selected title and
/// this compatibility wrapper renders it verbatim.
class LocalizedAnimeTitle extends StatelessWidget {
  const LocalizedAnimeTitle(
    this.fallbackTitle, {
    required this.aniListId,
    this.style,
    this.maxLines,
    this.overflow,
    super.key,
  });

  final int? aniListId;
  final String fallbackTitle;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) =>
      Text(fallbackTitle, style: style, maxLines: maxLines, overflow: overflow);
}
