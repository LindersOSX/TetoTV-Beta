import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/tracking/application/my_list_controller.dart';
import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';
import 'package:anime_tv/features/tracking/domain/tracking_repository.dart';
import 'package:anime_tv/features/tracking/presentation/tracking_status_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<TrackingListStatus?> currentCatalogTrackingStatus(
  WidgetRef ref,
  AnimeSummary anime,
) async {
  TrackingHomeData? tracking = ref.read(trackingHomeProvider).valueOrNull;
  if (tracking == null) {
    try {
      tracking = await ref.read(trackingHomeProvider.future);
    } catch (_) {
      // A temporarily unavailable tracker should not prevent the status
      // picker from checking the complete lists or offering normal choices.
      tracking = null;
    }
  }
  final resolvedTracking = tracking;
  if (resolvedTracking != null) {
    final cachedStatus = _matchingStatus(anime, [
      ...resolvedTracking.watching,
      ...resolvedTracking.planToWatch,
      ...resolvedTracking.completed,
    ]);
    if (cachedStatus != null) return cachedStatus;
  }

  // Home shelves intentionally keep only the first 20 entries. Check the
  // complete Planning list so every planned title exposes a real remove
  // action, without delaying every long press behind all five tracker lists.
  try {
    final result = await ref.read(
      trackingListProvider(TrackingListStatus.planToWatch).future,
    );
    final matched = _matchingStatus(anime, result.items);
    if (matched != null) return matched;
  } catch (_) {
    // One unavailable tracker must not prevent adding the title on the other
    // connected account.
  }
  return null;
}

TrackingListStatus? _matchingStatus(
  AnimeSummary anime,
  Iterable<HomeTrackedAnime> items,
) {
  for (final item in items) {
    final matches = switch (item.provider) {
      TrackingProvider.anilist =>
        (item.anilistId ?? item.tracked.mediaId) == anime.id,
      TrackingProvider.myAnimeList =>
        anime.idMal != null && item.tracked.mediaId == anime.idMal,
    };
    if (matches) return item.tracked.status;
  }
  return null;
}

Future<void> manageCatalogTrackingStatus({
  required BuildContext context,
  required WidgetRef ref,
  required AnimeSummary anime,
}) async {
  final current = await currentCatalogTrackingStatus(ref, anime);
  if (!context.mounted) return;
  final selection = await showTrackingStatusPicker(
    context,
    title: anime.displayTitle(ref.read(titleLanguagePreferenceProvider)),
    current: current,
  );
  if (!context.mounted || selection == null) return;
  try {
    final controller = ref.read(trackingStatusControllerProvider.notifier);
    final result = selection.remove
        ? await controller.removeCatalogStatus(
            anilistId: anime.id,
            malId: anime.idMal,
          )
        : await controller.updateCatalogStatus(
            anilistId: anime.id,
            malId: anime.idMal,
            status: selection.status!,
          );
    if (!context.mounted) return;
    final action = selection.remove
        ? 'Removed from ${result.updatedProviderNames}'
        : 'Moved to ${selection.status!.displayName} on ${result.updatedProviderNames}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isPartial
              ? '$action; one linked tracker could not be updated.'
              : '$action.',
        ),
        backgroundColor: result.isPartial
            ? const Color(0xFF7D1E32)
            : context.appPalette.accent,
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    final message = error is StateError
        ? error.message.toString()
        : 'Could not update this show. Try again.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF7D1E32),
      ),
    );
  }
}
