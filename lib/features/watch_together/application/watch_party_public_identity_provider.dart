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
  final preferredProfile = _preferredOrDeterministicTrackerProfile(
    trackerProfiles,
    preferredTracker,
  );
  if (activeLocalProfile case final local?) {
    final localNameKey = _publicIdentityNameKey(local.displayName);
    TrackingAccountProfile? matchingProfile;
    final selected = trackerProfiles[preferredTracker];
    if (selected != null &&
        _publicIdentityNameKey(selected.username) == localNameKey) {
      matchingProfile = selected;
    } else {
      for (final provider in TrackingProvider.values) {
        final candidate = trackerProfiles[provider];
        if (candidate != null &&
            _publicIdentityNameKey(candidate.username) == localNameKey) {
          matchingProfile = candidate;
          break;
        }
      }
    }
    return WatchPartyPublicIdentity.tryCreate(
      displayName: local.displayName,
      // Do not associate an unrelated shared-device persona with a tracker
      // picture. A case-insensitive normalized name match establishes that
      // the local selection represents the same public tracker persona.
      avatarUrl: matchingProfile?.avatarUrl,
    );
  }
  if (preferredProfile == null) return null;
  return WatchPartyPublicIdentity.tryCreate(
    displayName: preferredProfile.username,
    avatarUrl: preferredProfile.avatarUrl,
  );
}

TrackingAccountProfile? _preferredOrDeterministicTrackerProfile(
  Map<TrackingProvider, TrackingAccountProfile> profiles,
  TrackingProvider preferredTracker,
) {
  final preferred = profiles[preferredTracker];
  if (preferred != null) return preferred;
  for (final provider in TrackingProvider.values) {
    final candidate = profiles[provider];
    if (candidate != null) return candidate;
  }
  return null;
}

String _publicIdentityNameKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
