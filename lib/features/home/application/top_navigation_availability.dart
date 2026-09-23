import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';

/// Returns whether [destination] is available in the current runtime.
///
/// Persisted viewer visibility owns destinations. Manga additionally requires
/// the loaded Experimental options switch.
/// Keeping the policy here prevents the TV rail, phone bar, and classic header
/// from drifting apart.
bool isRuntimeTopNavigationDestinationVisible(
  SettingsPreferences preferences,
  TopNavigationDestination destination, {
  bool experimentalOptionsEnabled = false,
}) {
  if (destination == TopNavigationDestination.manga) {
    return preferences.loaded &&
        preferences.mangaReaderEnabled &&
        experimentalOptionsEnabled;
  }
  return preferences.isTopNavigationDestinationVisible(destination);
}

/// Builds the shared persisted runtime order.
///
/// Manga keeps its user-selected position and opt-out.
List<TopNavigationDestination> runtimeTopNavigationOrder(
  SettingsPreferences preferences, {
  bool experimentalOptionsEnabled = false,
}) {
  final order = <TopNavigationDestination>[
    for (final destination in preferences.topNavigationOrder)
      if (isRuntimeTopNavigationDestinationVisible(
        preferences,
        destination,
        experimentalOptionsEnabled: experimentalOptionsEnabled,
      ))
        destination,
  ];
  return List<TopNavigationDestination>.unmodifiable(order);
}
