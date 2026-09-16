import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/features/manga/application/manga_feature_availability.dart';
import 'package:anime_tv/features/manga/domain/manga_reader_models.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Route-level preference guard for Manga, with an experimental-only boundary.
///
/// Hiding the navigation icon is not enough because typed route extras and
/// internal links can outlive a settings change. The gate fails closed until
/// the saved preference loads and removes its child immediately when Manga is
/// disabled, without deleting data. Only Aniyomi reader requests also require
/// loaded, enabled Developer Mode.
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
    final update = requiresDeveloperMode
        ? ref.watch(appUpdateControllerProvider)
        : null;
    final preferences = ref.watch(settingsPreferencesProvider);
    if (!preferences.loaded || (update != null && !update.loaded)) {
      return const Scaffold(
        key: ValueKey('manga-feature-gate-loading'),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!ref.watch(mangaFeatureAvailableProvider) ||
        (update != null && !update.developerMode)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) GoRouter.maybeOf(context)?.go('/');
      });
      return Scaffold(
        key: const ValueKey('manga-feature-gate-closed'),
        body: Center(
          child: Text(
            context.tr(
              update != null && !update.developerMode
                  ? 'Aniyomi experiments require Developer Mode.'
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
/// Core Seanime, saved catalogs, and downloads do not require Developer Mode.
/// Aniyomi requests retain that restriction even if opened from an older link.
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
