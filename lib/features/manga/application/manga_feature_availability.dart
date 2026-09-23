import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/app_update_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Single fail-closed authority for the optional experimental Manga feature.
///
/// The viewer's saved Manga preference must finish loading before access is
/// granted. Disabling it suspends work without deleting local Manga data.
/// The saved experimental switch also gates the reader and its background
/// work; its storage key retains the old Developer Mode name for upgrades.
final mangaFeatureAvailableProvider = Provider<bool>((ref) {
  final preferences = ref.watch(settingsPreferencesProvider);
  final experiments = ref.watch(appUpdateControllerProvider);
  return preferences.loaded &&
      preferences.mangaReaderEnabled &&
      experiments.loaded &&
      experiments.developerMode;
});
