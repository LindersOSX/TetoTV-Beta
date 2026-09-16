import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';

/// Returns whether [destination] is available in the current runtime.
///
/// Persisted viewer visibility owns destinations. Manga fails closed until its
/// saved enable/disable preference has loaded, independently of Developer Mode.
/// Keeping the policy here prevents the TV rail, phone bar, and classic header
/// from drifting apart.
bool isRuntimeTopNavigationDestinationVisible(
  SettingsPreferences preferences,
  TopNavigationDestination destination,
) {
  if (destination == TopNavigationDestination.manga) {
    return preferences.loaded && preferences.mangaReaderEnabled;
  }
  return preferences.isTopNavigationDestinationVisible(destination);
}

/// Builds the shared persisted runtime order.
///
/// Manga keeps its user-selected position and opt-out.
List<TopNavigationDestination> runtimeTopNavigationOrder(
  SettingsPreferences preferences,
) {
  final order = <TopNavigationDestination>[
    for (final destination in preferences.topNavigationOrder)
      if (isRuntimeTopNavigationDestinationVisible(preferences, destination))
        destination,
  ];
  return List<TopNavigationDestination>.unmodifiable(order);
}
