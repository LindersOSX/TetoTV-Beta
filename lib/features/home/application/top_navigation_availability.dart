import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';

/// Returns whether [destination] is available in the current runtime.
///
/// Persisted viewer visibility still owns ordinary destinations. Manga is a
/// Developer Mode preview and therefore fails closed until that preference has
/// finished loading. Keeping this policy in one pure helper prevents the TV
/// rail, phone bar, and classic header from drifting apart.
bool isRuntimeTopNavigationDestinationVisible(
  SettingsPreferences preferences,
  TopNavigationDestination destination, {
  required bool developerStateLoaded,
  required bool developerMode,
}) {
  if (destination == TopNavigationDestination.manga) {
    return developerStateLoaded && developerMode;
  }
  return preferences.isTopNavigationDestinationVisible(destination);
}

/// Builds the shared runtime order without persisting a developer-only item.
///
/// Manga is inserted immediately before Downloads (or Settings when Downloads
/// is absent). This keeps old saved navigation orders byte-for-byte compatible
/// and prevents the existing settings organizer from exposing Manga outside
/// Developer Mode.
List<TopNavigationDestination> runtimeTopNavigationOrder(
  SettingsPreferences preferences, {
  required bool developerStateLoaded,
  required bool developerMode,
}) {
  final order = <TopNavigationDestination>[
    for (final destination in preferences.topNavigationOrder)
      if (destination != TopNavigationDestination.manga &&
          isRuntimeTopNavigationDestinationVisible(
            preferences,
            destination,
            developerStateLoaded: developerStateLoaded,
            developerMode: developerMode,
          ))
        destination,
  ];
  if (!developerStateLoaded || !developerMode) {
    return List<TopNavigationDestination>.unmodifiable(order);
  }

  final downloadsIndex = order.indexOf(TopNavigationDestination.downloads);
  final settingsIndex = order.indexOf(TopNavigationDestination.settings);
  final insertionIndex = downloadsIndex >= 0
      ? downloadsIndex
      : settingsIndex >= 0
      ? settingsIndex
      : order.length;
  order.insert(insertionIndex, TopNavigationDestination.manga);
  return List<TopNavigationDestination>.unmodifiable(order);
}
