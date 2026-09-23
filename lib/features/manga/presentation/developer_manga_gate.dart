import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/features/manga/application/manga_feature_availability.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Route-level preference and experimental access guard for Manga.
///
/// Hiding the navigation icon is not enough because typed route extras and
/// internal links can outlive a settings change. The gate fails closed until
/// the saved preference loads and removes its child immediately when Manga is
/// disabled, without deleting data. The experimental switch controls the
/// reader, while Aniyomi retains its separate source authorization.
class MangaFeatureGate extends ConsumerWidget {
  const MangaFeatureGate({
    required this.child,
    this.requiresDeveloperMode = false,
    super.key,
  });

  final Widget child;
  final bool requiresDeveloperMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateControllerProvider);
    final preferences = ref.watch(settingsPreferencesProvider);
    if (!preferences.loaded || !update.loaded) {
      return const Scaffold(
        key: ValueKey('manga-feature-gate-loading'),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!ref.watch(mangaFeatureAvailableProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) GoRouter.maybeOf(context)?.go('/');
      });
      return Scaffold(
        key: const ValueKey('manga-feature-gate-closed'),
        body: Center(
          child: Text(
            context.tr(
              !update.developerMode
                  ? 'Manga reader requires Experimental options to be enabled.'
                  : 'Manga is disabled in Settings.',
            ),
          ),
        ),
      );
    }
    return child;
  }
}

/// Applies the Manga preference and preserves experimental request provenance.
///
/// Both Seanime and Aniyomi reader routes require Experimental options; the
/// Aniyomi source still retains its separate execution approval boundary.
class MangaReaderRouteGate extends StatelessWidget {
  const MangaReaderRouteGate({
    required this.request,
    required this.child,
    super.key,
  });

  final MangaReaderRequest request;
  final Widget child;

  @override
  Widget build(BuildContext context) => MangaFeatureGate(
    requiresDeveloperMode: request.requiresDeveloperMode,
    child: child,
  );
}
