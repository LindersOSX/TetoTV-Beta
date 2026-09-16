import 'package:anime_tv/features/catalog/application/localized_anime_description_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Displays translated external metadata when available, retaining the
/// catalog synopsis while the optional lookup loads or cannot provide one.
class LocalizedAnimeDescription extends ConsumerWidget {
  const LocalizedAnimeDescription({
    required this.aniListId,
    required this.language,
    required this.fallbackDescription,
    this.style,
    this.maxLines,
    this.overflow,
    super.key,
  });

  final int aniListId;
  final String language;
  final String fallbackDescription;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localized = language == 'en' || aniListId <= 0
        ? null
        : ref
              .watch(
                localizedAnimeDescriptionProvider((
                  aniListId: aniListId,
                  language: language,
                )),
              )
              .valueOrNull;
    return Text(
      localized ?? fallbackDescription,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
