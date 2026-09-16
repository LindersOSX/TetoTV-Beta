import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Single fail-closed authority for the optional core Manga feature.
///
/// The viewer's saved Manga preference must finish loading before access is
/// granted. Disabling it suspends work without deleting local Manga data.
/// Experimental Aniyomi execution has its own Developer Mode authorization.
final mangaFeatureAvailableProvider = Provider<bool>((ref) {
  final preferences = ref.watch(settingsPreferencesProvider);
  return preferences.loaded && preferences.mangaReaderEnabled;
});
