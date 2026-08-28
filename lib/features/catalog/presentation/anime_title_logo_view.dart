import 'package:anime_tv/features/catalog/application/anime_title_logo_provider.dart';
import 'package:anime_tv/features/catalog/data/anime_title_logo_cache_manager.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A bounded clear-logo title for featured and show-detail experiences.
///
/// Catalog cards intentionally keep their normal text titles. A text title
/// also remains visible while artwork loads, when no safe language-matched
/// clear-logo is available, or when the user selects text titles.
class AnimeTitleLogoView extends ConsumerWidget {
  const AnimeTitleLogoView({
    required this.aniListId,
    required this.fallbackTitle,
    required this.maxWidth,
    required this.maxHeight,
    required this.textStyle,
    this.maxTextLines = 2,
    this.logoContextLabel,
    this.logoContextStyle,
    this.logoContextMaxLines = 2,
    super.key,
  });

  final int aniListId;
  final String fallbackTitle;
  final double maxWidth;
  final double maxHeight;
  final TextStyle? textStyle;
  final int maxTextLines;
  final String? logoContextLabel;
  final TextStyle? logoContextStyle;
  final int logoContextMaxLines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = _TextTitle(
      title: fallbackTitle,
      style: textStyle,
      maxLines: maxTextLines,
    );
    final titleStyle = ref.watch(
      settingsPreferencesProvider.select((value) => value.showTitleStyle),
    );
    if (titleStyle == ShowTitleStyle.text) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: fallback,
      );
    }
    final titleLanguage = ref.watch(titleLanguagePreferenceProvider);
    final logo = ref
        .watch(
          animeTitleLogoProvider((
            aniListId: aniListId,
            titleLanguage: titleLanguage,
          )),
        )
        .valueOrNull;
    final safeLogo = logo != null && isSafeAnimeTitleLogoUri(logo.url)
        ? logo
        : null;
    final contextLabel = logoContextLabel?.trim();
    final showContextLabel = contextLabel != null && contextLabel.isNotEmpty;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: safeLogo == null
          ? fallback
          : Semantics(
              image: true,
              label: fallbackTitle,
              excludeSemantics: true,
              child: SizedBox(
                width: maxWidth,
                height: maxHeight,
                child: CachedNetworkImage(
                  imageUrl: safeLogo.url.toString(),
                  cacheManager: animeTitleLogoCacheManager,
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                  imageBuilder: showContextLabel
                      ? (_, imageProvider) => SizedBox(
                          key: const ValueKey(
                            'anime-title-logo-artwork-with-context',
                          ),
                          width: maxWidth,
                          height: maxHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Image(
                                  image: imageProvider,
                                  width: maxWidth,
                                  fit: BoxFit.contain,
                                  alignment: Alignment.centerLeft,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                contextLabel,
                                key: const ValueKey(
                                  'anime-title-logo-context-label',
                                ),
                                maxLines: logoContextMaxLines,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    logoContextStyle ??
                                    Theme.of(context).textTheme.labelMedium,
                              ),
                            ],
                          ),
                        )
                      : null,
                  memCacheWidth: 800,
                  fadeInDuration: const Duration(milliseconds: 120),
                  placeholder: (_, _) => fallback,
                  errorWidget: (_, _, _) => fallback,
                ),
              ),
            ),
    );
  }
}

class _TextTitle extends StatelessWidget {
  const _TextTitle({
    required this.title,
    required this.style,
    required this.maxLines,
  });

  final String title;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
    title,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    style: style,
  );
}
