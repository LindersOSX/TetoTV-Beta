import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_focusable.dart';
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
                TvFocusable(
                  autofocus: true,
                  onPressed: context.pop,
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(Icons.arrow_back_rounded),
                  ),
                ),
                const SizedBox(width: 14),
                Text(name, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(width: 12),
                Text(
                  type == CatalogCollectionType.studio
                      ? 'Studio titles'
                      : 'Anime credits',
                  style: TextStyle(color: context.appPalette.mutedText),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: results.when(
                loading: () => Center(
                  child: CircularProgressIndicator(
                    color: context.appPalette.accentBright,
                  ),
                ),
                error: (error, _) =>
                    Center(child: Text('Could not load titles: $error')),
                data: (List<AnimeSummary> items) => CatalogGrid(
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
