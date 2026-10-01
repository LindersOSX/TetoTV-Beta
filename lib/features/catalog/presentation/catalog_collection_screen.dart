import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/widgets/teto_back_button.dart';
import 'package:anime_tv/core/widgets/teto_browse_status.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/catalog_grid.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

enum CatalogCollectionType { studio, staff }

class CatalogCollectionScreen extends ConsumerWidget {
  const CatalogCollectionScreen({
    required this.id,
    required this.name,
    required this.type,
    super.key,
  });
  final int id;
  final String name;
  final CatalogCollectionType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = type == CatalogCollectionType.studio
        ? ref.watch(studioAnimeProvider(id))
        : ref.watch(staffAnimeProvider(id));
    final preference = ref.watch(titleLanguagePreferenceProvider);
    return Scaffold(
      backgroundColor: context.appPalette == AppThemePalette.defaults
          ? Colors.black
          : context.appPalette.background,
      body: SafeArea(
        minimum: const EdgeInsets.fromLTRB(34, 24, 34, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TetoBackButton(autofocus: true, onPressed: context.pop),
                const SizedBox(width: 14),
                Text(name, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(width: 12),
                Text(
                  type == CatalogCollectionType.studio
                      ? context.tr("Studio titles")
                      : context.tr("Anime credits"),
                  style: TextStyle(color: context.appPalette.mutedText),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: results.when(
                loading: () => const TetoBrowseLoading(),
                error: (error, _) => TetoBrowseStatus(
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load anime',
                  message:
                      'The catalog could not be reached. Please try again.',
                  actions: TetoRetryButton(
                    onPressed: () {
                      if (type == CatalogCollectionType.studio) {
                        ref.invalidate(studioAnimeProvider(id));
                      } else {
                        ref.invalidate(staffAnimeProvider(id));
                      }
                    },
                  ),
                ),
                data: (List<AnimeSummary> items) => items.isEmpty
                    ? const TetoBrowseStatus(
                        icon: Icons.video_library_outlined,
                        title: 'No matches found',
                        message: 'No titles are available yet.',
                      )
                    : CatalogGrid(
                        items: items,
                        titlePreference: preference,
                        autofocus: false,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
