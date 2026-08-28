import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/settings/application/local_profiles_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/tracking_accounts_controller.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The only tracker-profile fields permitted in Watch Together room payloads.
/// Provider, account/slot IDs, email, OAuth identifiers, and tokens never
/// enter this model.
final watchPartyPublicIdentityProvider = Provider<WatchPartyPublicIdentity?>((
  ref,
) {
  final preferences = ref.watch(settingsPreferencesProvider);
  final accounts = ref.watch(trackingAccountsControllerProvider);
  final localProfiles = ref.watch(localProfilesControllerProvider);
  return watchPartyPublicIdentityForProfiles(
    activeLocalProfile: localProfiles.activeProfile,
    trackerProfiles: accounts.profiles,
    preferredTracker: preferences.trackingProvider,
  );
});

WatchPartyPublicIdentity? watchPartyPublicIdentityForProfiles({
  required LocalProfile? activeLocalProfile,
  required Map<TrackingProvider, TrackingAccountProfile> trackerProfiles,
  required TrackingProvider preferredTracker,
}) {
  if (activeLocalProfile case final local?) {
    return WatchPartyPublicIdentity.tryCreate(displayName: local.displayName);
  }
  var profile = trackerProfiles[preferredTracker];
  if (profile == null && trackerProfiles.isNotEmpty) {
    profile = trackerProfiles.values.first;
  }
  if (profile == null) return null;
  return WatchPartyPublicIdentity.tryCreate(
    displayName: profile.username,
    avatarUrl: profile.avatarUrl,
  );
}
