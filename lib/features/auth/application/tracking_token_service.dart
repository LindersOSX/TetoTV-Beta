import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/auth/application/auth_broker_config.dart';
import 'package:anime_tv/features/auth/data/anilist_pairing_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final trackingTokenServiceProvider = Provider<TrackingTokenService>(
  (ref) => TrackingTokenService(ref.watch(secureStorageProvider)),
);

const _trackingProfileIndexStorageKey = 'tracking_profile_index_v1';
const _maximumTrackingCredentialLength = 4096;
const _maximumKitsuTokenLifetime = Duration(days: 3650);

final class TrackingCredentialSnapshot {
  const TrackingCredentialSnapshot._(this.provider, this._storageSnapshot);

  final TrackingProvider provider;
  final SecureStorageSnapshot _storageSnapshot;
}

class StoredTrackingProfile {
  const StoredTrackingProfile({
    required this.id,
    required this.provider,
    required this.username,
  });

  final String id;
  final TrackingProvider provider;
  final String username;

  Map<String, String> toJson() => {
    'id': id,
    'provider': provider.slug,
    'username': username,
  };
}

typedef TrackingPairingClientFactory =
    TrackingPairingClient Function(
      TrackingProvider provider, {
      required String baseUrl,
    });

TrackingPairingClient _createPairingClient(
  TrackingProvider provider, {
  required String baseUrl,
}) => TrackingPairingClient(provider, baseUrl: baseUrl);

class TrackingTokenService {
  TrackingTokenService(
    this._storage, {
    this._clientFactory = _createPairingClient,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final FlutterSecureStorage _storage;
  final TrackingPairingClientFactory _clientFactory;
  final DateTime Function() _now;
  final Map<TrackingProvider, Future<String?>> _refreshRequests = {};
  Future<void> _credentialMutationTail = Future<void>.value();

  Future<String?> accessToken(TrackingProvider provider) async {
    await _recoverCredentialJournal(provider);
    await _requireConsistentActiveProfile(provider);
    if (!_usesRefreshTokens(provider)) {
      return _readToken(provider);
    }

    // Refresh tokens may rotate. Sharing one in-flight request per provider
    // prevents parallel Home, My List, and Settings requests from racing it.
    final activeRequest = _refreshRequests[provider];
    if (activeRequest != null) return activeRequest;

    final request = _refreshingAccessToken(provider);
    _refreshRequests[provider] = request;
    try {
      return await request;
    } finally {
      if (identical(_refreshRequests[provider], request)) {
        _refreshRequests.remove(provider);
      }
    }
  }

  Future<String?> _readToken(TrackingProvider provider) async {
    final accessToken = await _storage.read(key: provider.tokenStorageKey);
    if (accessToken == null || accessToken.isEmpty) return null;
    return accessToken;
  }

  Future<String?> _refreshingAccessToken(TrackingProvider provider) async {
    final storedAccessToken = await _readToken(provider);
    if (storedAccessToken == null) return null;

    final expiresAtValue = await _storage.read(
      key: provider.expiresAtStorageKey,
    );
    final expiresAt = DateTime.tryParse(expiresAtValue ?? '');
    final storedRefreshToken = await _storage.read(
      key: provider.refreshTokenStorageKey,
    );
    final now = _now().toUtc();
    final accessToken = provider == TrackingProvider.kitsu
        ? _requireKitsuStoredCredential(storedAccessToken)
        : storedAccessToken;
    final refreshToken = provider == TrackingProvider.kitsu
        ? _requireKitsuStoredCredential(storedRefreshToken)
        : storedRefreshToken;
    if (provider == TrackingProvider.kitsu &&
        (expiresAt == null ||
            expiresAt.toUtc().isAfter(now.add(_maximumKitsuTokenLifetime)))) {
      throw _incompleteKitsuSession();
    }
    if (expiresAt == null ||
        expiresAt.toUtc().isAfter(now.add(const Duration(minutes: 5)))) {
      return accessToken;
    }

    final brokerUrl = await effectiveAuthBrokerBaseUrl(_storage);
    if (refreshToken == null || refreshToken.isEmpty || brokerUrl == null) {
      if (!expiresAt.toUtc().isAfter(now)) {
        throw StateError(
          'The ${provider.displayName} session expired and cannot be '
          'refreshed. Reconnect ${provider.displayName} in Settings.',
        );
      }
      return accessToken;
    }

    // Capture the source slot before leaving the app for a rotating refresh.
    // If the user switches profiles while the request is in flight, the new
    // credential is retained in this slot without replacing the newly active
    // account's primary keys.
    final sourceProfile = await _activeProfileMatchingCredential(
      provider,
      storedAccessToken,
      storedRefreshToken!,
    );
    late final TrackingTokenSet tokens;
    try {
      final received = await _clientFactory(
        provider,
        baseUrl: brokerUrl,
      ).refresh(refreshToken);
      tokens = _validatedRefreshTokenSet(provider, received, now);
    } catch (_) {
      // A short broker outage or malformed response should not log the user
      // out while the current access token is still valid. Once expired,
      // surface the real error without changing any stored credential.
      if (expiresAt.toUtc().isAfter(now)) return accessToken;
      rethrow;
    }

    await _persistRefreshedCredentials(
      provider,
      previousAccessToken: storedAccessToken,
      previousRefreshToken: storedRefreshToken,
      previousExpiresAt: expiresAtValue,
      sourceProfile: sourceProfile,
      tokens: tokens,
    );
    return tokens.accessToken;
  }

  Future<void> _persistRefreshedCredentials(
    TrackingProvider provider, {
    required String previousAccessToken,
    required String previousRefreshToken,
    required String? previousExpiresAt,
    required StoredTrackingProfile? sourceProfile,
    required TrackingTokenSet tokens,
  }) async {
    final profileKeys = sourceProfile == null
        ? const <String>[]
        : [
            _profileCredentialKey(sourceProfile, 'access'),
            _profileCredentialKey(sourceProfile, 'refresh'),
            _profileCredentialKey(sourceProfile, 'expires'),
          ];
    final nextRefreshToken = switch (tokens.refreshToken?.trim()) {
      final String value when value.isNotEmpty => value,
      _ => previousRefreshToken,
    };
    final nextExpiry = tokens.expiresAt?.toUtc().toIso8601String();

    final activeCredentialStayedCurrent = await _serializeCredentialMutation(
      () async {
        return runSecureStorageTransaction(
          _storage,
          [
            ..._credentialKeys(provider),
            ...profileKeys,
            _credentialJournalKey(provider),
          ],
          () async {
            // A pairing import or profile switch that completed during the
            // remote refresh owns the active keys.
            final primaryUnchanged =
                await _storage.read(key: provider.tokenStorageKey) ==
                    previousAccessToken &&
                await _storage.read(key: provider.refreshTokenStorageKey) ==
                    previousRefreshToken &&
                await _storage.read(key: provider.expiresAtStorageKey) ==
                    previousExpiresAt;
            final sourceProfileUnchanged =
                sourceProfile != null &&
                await _profileStillMatchesCredential(
                  sourceProfile,
                  previousAccessToken,
                  previousRefreshToken,
                );

            if (!primaryUnchanged) {
              // The provider may already have rotated this source account's
              // refresh token. Preserve it in the original slot, but make
              // the stale caller fail so it cannot act after a switch.
              if (sourceProfileUnchanged) {
                await _writeProfileTokenSet(
                  sourceProfile,
                  accessToken: tokens.accessToken,
                  refreshToken: nextRefreshToken,
                  expiresAt: nextExpiry,
                );
              }
              return false;
            }
            if (sourceProfile != null &&
                (await _storage.read(key: _activeProfileKey(provider)) !=
                        sourceProfile.id ||
                    !sourceProfileUnchanged)) {
              throw StateError(
                '${provider.displayName} profile changed while refreshing.',
              );
            }

            await _writeCredentialJournal(
              provider,
              _CredentialJournal.refresh(sourceProfile?.id),
            );
            // Primary refresh is committed first. The journal makes every
            // process-kill prefix distinguishable from legacy cross-account
            // corruption; primary access and expiry become visible last.
            await _storage.write(
              key: provider.refreshTokenStorageKey,
              value: nextRefreshToken,
            );
            if (sourceProfile != null) {
              await _writeProfileTokenSet(
                sourceProfile,
                accessToken: tokens.accessToken,
                refreshToken: nextRefreshToken,
                expiresAt: nextExpiry,
              );
            }
            await _storage.write(
              key: provider.tokenStorageKey,
              value: tokens.accessToken,
            );
            await _writeOptional(provider.expiresAtStorageKey, nextExpiry);
            await _storage.delete(key: _credentialJournalKey(provider));
            return true;
          },
        );
      },
    );
    if (!activeCredentialStayedCurrent) {
      throw StateError(
        '${provider.displayName} credentials changed while refreshing.',
      );
    }
  }

  Future<StoredTrackingProfile?> _activeProfileMatchingCredential(
    TrackingProvider provider,
    String accessToken,
    String refreshToken,
  ) async {
    final activeId = await activeProfileId(provider);
    if (activeId == null || activeId.isEmpty) return null;
    final profile = (await savedProfiles())
        .where((item) => item.provider == provider && item.id == activeId)
        .firstOrNull;
    if (profile == null) return null;
    return await _profileCredentialMatches(profile, accessToken, refreshToken)
        ? profile
        : null;
  }

  Future<bool> _profileStillMatchesCredential(
    StoredTrackingProfile profile,
    String accessToken,
    String refreshToken,
  ) async {
    final registered = (await savedProfiles()).any(
      (item) => item.provider == profile.provider && item.id == profile.id,
    );
    return registered &&
        await _profileCredentialMatches(profile, accessToken, refreshToken);
  }

  Future<bool> _profileCredentialMatches(
    StoredTrackingProfile profile,
    String accessToken,
    String refreshToken,
  ) async {
    final storedAccess = await _storage.read(
      key: _profileCredentialKey(profile, 'access'),
    );
    final storedRefresh = await _storage.read(
      key: _profileCredentialKey(profile, 'refresh'),
    );
    return storedAccess == accessToken && storedRefresh == refreshToken;
  }

  Future<void> _writeProfileTokenSet(
    StoredTrackingProfile profile, {
    required String accessToken,
    required String refreshToken,
    required String? expiresAt,
  }) async {
    await _storage.write(
      key: _profileCredentialKey(profile, 'refresh'),
      value: refreshToken,
    );
    await _storage.write(
      key: _profileCredentialKey(profile, 'access'),
      value: accessToken,
    );
    await _writeOptional(_profileCredentialKey(profile, 'expires'), expiresAt);
  }

  Future<void> save(TrackingProvider provider, String token) async {
    await _serializeCredentialMutation(
      () => runSecureStorageTransaction(
        _storage,
        _activeCredentialKeys(provider),
        () async {
          // Hide the previous account before changing any metadata. The new
          // token becomes visible only after its old profile association is
          // cleared and the replacement metadata is complete.
          await _storage.delete(key: provider.tokenStorageKey);
          await _storage.delete(key: _activeProfileKey(provider));
          await _storage.delete(key: _credentialJournalKey(provider));
          await _storage.delete(key: provider.refreshTokenStorageKey);
          await _storage.delete(key: provider.expiresAtStorageKey);
          await _storage.write(
            key: provider.tokenStorageKey,
            value: token.trim(),
          );
        },
      ),
    );
    _refreshRequests.remove(provider);
  }

  /// Saves the complete credential set returned by the secure setup broker.
  ///
  /// Refresh and expiry metadata are written before the access token so an
  /// interrupted import cannot expose a new access token with stale session
  /// metadata. All values remain in Android encrypted storage.
  Future<void> saveTokenSet(
    TrackingProvider provider, {
    required String accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) async {
    final normalizedAccess = accessToken.trim();
    final normalizedRefresh = refreshToken?.trim();
    final normalizedExpiry = expiresAt?.toUtc();
    if (provider == TrackingProvider.kitsu) {
      _validateKitsuCredentialSet(
        accessToken: normalizedAccess,
        refreshToken: normalizedRefresh,
        expiresAt: normalizedExpiry,
        now: _now().toUtc(),
      );
    }
    await _serializeCredentialMutation(
      () => runSecureStorageTransaction(
        _storage,
        _activeCredentialKeys(provider),
        () async {
          await _storage.delete(key: provider.tokenStorageKey);
          await _storage.delete(key: _activeProfileKey(provider));
          await _storage.delete(key: _credentialJournalKey(provider));
          await _writeOptional(
            provider.refreshTokenStorageKey,
            normalizedRefresh,
          );
          await _writeOptional(
            provider.expiresAtStorageKey,
            normalizedExpiry?.toIso8601String(),
          );
          await _storage.write(
            key: provider.tokenStorageKey,
            value: normalizedAccess,
          );
        },
      ),
    );
    _refreshRequests.remove(provider);
  }

  Future<TrackingCredentialSnapshot> snapshotCredentials(
    TrackingProvider provider,
  ) async {
    return TrackingCredentialSnapshot._(
      provider,
      await SecureStorageSnapshot.capture(
        _storage,
        _activeCredentialKeys(provider),
      ),
    );
  }

  Future<void> restoreCredentials(TrackingCredentialSnapshot snapshot) async {
    await _serializeCredentialMutation(snapshot._storageSnapshot.restore);
    _refreshRequests.remove(snapshot.provider);
  }

  /// Saves the currently active legacy credentials into a named encrypted
  /// profile slot after the tracker API has verified the username. Only the
  /// non-secret slot index is returned to presentation code.
  Future<StoredTrackingProfile?> rememberCurrentProfile(
    TrackingProvider provider,
    String username, {
    String? stableAccountId,
  }) async {
    final normalizedUsername = _safeUsername(username);
    if (normalizedUsername == null) return null;
    final normalizedStableId = stableAccountId == null
        ? null
        : _safeStableAccountId(stableAccountId);
    if (stableAccountId != null && normalizedStableId == null) return null;
    final id = _profileId(
      provider,
      normalizedUsername,
      stableAccountId: normalizedStableId,
    );
    final profile = StoredTrackingProfile(
      id: id,
      provider: provider,
      username: normalizedUsername,
    );
    return _serializeCredentialMutation(() async {
      final accessToken = await _storage.read(key: provider.tokenStorageKey);
      if (accessToken == null || accessToken.isEmpty) return null;
      final refreshToken = await _storage.read(
        key: provider.refreshTokenStorageKey,
      );
      final expiresAt = await _storage.read(key: provider.expiresAtStorageKey);
      final profiles = await savedProfiles();
      final activeId = await activeProfileId(provider);

      // A stable account ID replaces the legacy display-name-derived slot
      // only when that active slot still owns this exact credential. This
      // keeps upgrades migration-compatible without merging two accounts
      // that happen to share the same display name.
      StoredTrackingProfile? legacyProfile;
      if (normalizedStableId != null && activeId != null && activeId != id) {
        final candidate = profiles
            .where((item) => item.provider == provider && item.id == activeId)
            .firstOrNull;
        if (candidate != null &&
            await _storage.read(
                  key: _profileCredentialKey(candidate, 'access'),
                ) ==
                accessToken) {
          legacyProfile = candidate;
        }
      }
      final next = [
        for (final existing in profiles)
          if (!(existing.provider == provider &&
              (existing.id == id || existing.id == legacyProfile?.id)))
            existing,
        profile,
      ]..sort(_compareStoredProfiles);
      final newProfileKeys = [
        for (final suffix in const ['access', 'refresh', 'expires'])
          _profileCredentialKey(profile, suffix),
      ];
      final legacyProfileKeys = legacyProfile == null
          ? const <String>[]
          : [
              for (final suffix in const ['access', 'refresh', 'expires'])
                _profileCredentialKey(legacyProfile, suffix),
            ];
      return runSecureStorageTransaction(
        _storage,
        [
          ...newProfileKeys,
          ...legacyProfileKeys,
          _trackingProfileIndexStorageKey,
          _activeProfileKey(provider),
        ],
        () async {
          if (await _storage.read(key: provider.tokenStorageKey) !=
              accessToken) {
            throw StateError(
              '${provider.displayName} credentials changed while saving the profile.',
            );
          }
          if (legacyProfile != null &&
              (await _storage.read(key: _activeProfileKey(provider)) !=
                      legacyProfile.id ||
                  await _storage.read(
                        key: _profileCredentialKey(legacyProfile, 'access'),
                      ) !=
                      accessToken)) {
            throw StateError(
              '${provider.displayName} profile changed while migrating it.',
            );
          }
          await _writeOptional(
            _profileCredentialKey(profile, 'refresh'),
            refreshToken,
          );
          await _writeOptional(
            _profileCredentialKey(profile, 'expires'),
            expiresAt,
          );
          await _storage.write(
            key: _profileCredentialKey(profile, 'access'),
            value: accessToken,
          );
          await _writeProfiles(next);
          await _storage.write(key: _activeProfileKey(provider), value: id);
          if (legacyProfile != null) {
            for (final key in legacyProfileKeys) {
              await _storage.delete(key: key);
            }
          }
          return profile;
        },
      );
    });
  }

  Future<List<StoredTrackingProfile>> savedProfiles() async {
    final encoded = await _storage.read(key: _trackingProfileIndexStorageKey);
    if (encoded == null || encoded.isEmpty || encoded.length > 32768) {
      return const [];
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List || decoded.length > 100) return const [];
      final profiles = <StoredTrackingProfile>[];
      final seen = <String>{};
      for (final value in decoded) {
        if (value is! Map) continue;
        final id = value['id'];
        final username = _safeUsername(value['username']);
        final providerSlug = value['provider'];
        if (id is! String ||
            !RegExp(r'^[a-z0-9_-]{1,80}$').hasMatch(id) ||
            username == null ||
            providerSlug is! String) {
          continue;
        }
        final provider = TrackingProvider.values
            .where((item) => item.slug == providerSlug)
            .firstOrNull;
        if (provider == null || !seen.add('${provider.slug}:$id')) continue;
        profiles.add(
          StoredTrackingProfile(id: id, provider: provider, username: username),
        );
      }
      profiles.sort(_compareStoredProfiles);
      return profiles;
    } on FormatException {
      return const [];
    }
  }

  Future<String?> activeProfileId(TrackingProvider provider) =>
      _storage.read(key: _activeProfileKey(provider));

  /// Returns the active non-secret profile slot only when its encrypted
  /// credential still matches [accessToken]. A newly paired credential must
  /// never inherit a previous account's persistent tracker cache.
  Future<String?> verifiedActiveProfileId(
    TrackingProvider provider,
    String accessToken,
  ) async {
    final normalizedToken = accessToken.trim();
    if (normalizedToken.isEmpty) return null;
    final activeId = await activeProfileId(provider);
    if (activeId == null || activeId.isEmpty) return null;
    final profile = (await savedProfiles())
        .where((item) => item.provider == provider && item.id == activeId)
        .firstOrNull;
    if (profile == null) return null;
    final storedToken = await _storage.read(
      key: _profileCredentialKey(profile, 'access'),
    );
    return storedToken == normalizedToken ? activeId : null;
  }

  Future<void> activateProfile(StoredTrackingProfile profile) async {
    await _serializeCredentialMutation(
      () => _activateProfileWithinMutation(profile),
    );
    _refreshRequests.remove(profile.provider);
  }

  Future<void> clear(TrackingProvider provider) async {
    await _serializeCredentialMutation(() async {
      final profiles = await savedProfiles();
      final removed = profiles
          .where((profile) => profile.provider == provider)
          .toList(growable: false);
      final keys = [
        ..._credentialKeys(provider),
        _activeProfileKey(provider),
        _credentialJournalKey(provider),
        _trackingProfileIndexStorageKey,
        for (final profile in removed)
          for (final suffix in const ['access', 'refresh', 'expires'])
            _profileCredentialKey(profile, suffix),
      ];
      await runSecureStorageTransaction(_storage, keys, () async {
        // The durable tombstone is written before access disappears. Startup
        // recovery must finish this disconnect instead of interpreting the
        // missing access as an interrupted profile activation.
        await _writeCredentialJournal(
          provider,
          const _CredentialJournal.clear(),
        );
        await _finishProviderClear(provider, profiles, removed);
      });
    });
    _refreshRequests.remove(provider);
  }

  Future<void> _finishProviderClear(
    TrackingProvider provider,
    List<StoredTrackingProfile> profiles,
    List<StoredTrackingProfile> removed,
  ) async {
    // Access disappears first, so a process interruption cannot send an
    // API request with partially cleared account metadata.
    await _storage.delete(key: provider.tokenStorageKey);
    await _storage.delete(key: provider.refreshTokenStorageKey);
    await _storage.delete(key: provider.expiresAtStorageKey);
    await _storage.delete(key: _activeProfileKey(provider));
    for (final profile in removed) {
      for (final suffix in const ['access', 'refresh', 'expires']) {
        await _storage.delete(key: _profileCredentialKey(profile, suffix));
      }
    }
    await _writeProfiles([
      for (final profile in profiles)
        if (profile.provider != provider) profile,
    ]);
    await _storage.delete(key: _credentialJournalKey(provider));
  }

  Future<void> _activateProfileWithinMutation(
    StoredTrackingProfile profile,
  ) async {
    final profiles = await savedProfiles();
    final registered = profiles.any(
      (item) => item.provider == profile.provider && item.id == profile.id,
    );
    if (!registered) throw StateError('That tracker profile is not saved.');
    final access = await _storage.read(
      key: _profileCredentialKey(profile, 'access'),
    );
    if (access == null || access.isEmpty) {
      throw StateError('That tracker profile needs to be connected again.');
    }
    final refresh = await _storage.read(
      key: _profileCredentialKey(profile, 'refresh'),
    );
    final expires = await _storage.read(
      key: _profileCredentialKey(profile, 'expires'),
    );
    _validateStoredProfileCredentialSet(
      profile.provider,
      access: access,
      refresh: refresh,
      expires: expires,
    );
    await runSecureStorageTransaction(
      _storage,
      [
        ..._credentialKeys(profile.provider),
        _activeProfileKey(profile.provider),
        _credentialJournalKey(profile.provider),
      ],
      () async {
        final stillRegistered = (await savedProfiles()).any(
          (item) => item.provider == profile.provider && item.id == profile.id,
        );
        if (!stillRegistered ||
            await _storage.read(
                  key: _profileCredentialKey(profile, 'access'),
                ) !=
                access ||
            await _storage.read(
                  key: _profileCredentialKey(profile, 'refresh'),
                ) !=
                refresh ||
            await _storage.read(
                  key: _profileCredentialKey(profile, 'expires'),
                ) !=
                expires) {
          throw StateError('That tracker profile changed while activating.');
        }
        await _writeCredentialJournal(
          profile.provider,
          _CredentialJournal.activation(profile.id),
        );
        await _writeActiveCredentialSetFailClosed(
          profile,
          access: access,
          refresh: refresh,
          expires: expires,
        );
        await _storage.delete(key: _credentialJournalKey(profile.provider));
      },
    );
  }

  Future<void> _writeActiveCredentialSetFailClosed(
    StoredTrackingProfile profile, {
    required String access,
    required String? refresh,
    required String? expires,
  }) async {
    // This sequence is deliberately process-crash-safe, not process-atomic:
    // no primary access token exists while refresh, expiry, and slot identity
    // can refer to different accounts. The access token is exposed last.
    await _storage.delete(key: profile.provider.tokenStorageKey);
    await _writeOptional(profile.provider.refreshTokenStorageKey, refresh);
    await _writeOptional(profile.provider.expiresAtStorageKey, expires);
    await _storage.write(
      key: _activeProfileKey(profile.provider),
      value: profile.id,
    );
    await _storage.write(key: profile.provider.tokenStorageKey, value: access);
  }

  Future<void> _recoverCredentialJournal(TrackingProvider provider) async {
    await _serializeCredentialMutation(() async {
      final journal = await _readCredentialJournal(provider);
      if (journal == null) return;
      switch (journal.operation) {
        case _CredentialJournalOperation.activation:
          final profileId = journal.profileId;
          if (profileId == null) throw _unrecoverableCredentialState(provider);
          final profile = (await savedProfiles())
              .where(
                (item) => item.provider == provider && item.id == profileId,
              )
              .firstOrNull;
          if (profile == null) throw _unrecoverableCredentialState(provider);
          final access = await _storage.read(
            key: _profileCredentialKey(profile, 'access'),
          );
          final refresh = await _storage.read(
            key: _profileCredentialKey(profile, 'refresh'),
          );
          final expires = await _storage.read(
            key: _profileCredentialKey(profile, 'expires'),
          );
          if (access == null || access.isEmpty) {
            throw _unrecoverableCredentialState(provider);
          }
          _validateStoredProfileCredentialSet(
            provider,
            access: access,
            refresh: refresh,
            expires: expires,
          );
          await runSecureStorageTransaction(
            _storage,
            [
              ..._activeCredentialKeys(provider),
              _credentialJournalKey(provider),
            ],
            () async {
              await _writeActiveCredentialSetFailClosed(
                profile,
                access: access,
                refresh: refresh,
                expires: expires,
              );
              await _storage.delete(key: _credentialJournalKey(provider));
            },
          );
          return;
        case _CredentialJournalOperation.refresh:
          await _recoverInterruptedRefresh(provider, journal.profileId);
          return;
        case _CredentialJournalOperation.clear:
          final profiles = await savedProfiles();
          final removed = profiles
              .where((profile) => profile.provider == provider)
              .toList(growable: false);
          await runSecureStorageTransaction(_storage, [
            ..._activeCredentialKeys(provider),
            _trackingProfileIndexStorageKey,
            for (final profile in removed)
              for (final suffix in const ['access', 'refresh', 'expires'])
                _profileCredentialKey(profile, suffix),
          ], () => _finishProviderClear(provider, profiles, removed));
          return;
      }
    });
  }

  Future<void> _recoverInterruptedRefresh(
    TrackingProvider provider,
    String? profileId,
  ) async {
    final primaryAccess = await _storage.read(key: provider.tokenStorageKey);
    final primaryRefresh = await _storage.read(
      key: provider.refreshTokenStorageKey,
    );
    final primaryExpires = await _storage.read(
      key: provider.expiresAtStorageKey,
    );
    if (primaryAccess == null ||
        primaryAccess.isEmpty ||
        primaryRefresh == null ||
        primaryRefresh.isEmpty) {
      throw _unrecoverableCredentialState(provider);
    }
    if (profileId == null) {
      if (provider == TrackingProvider.kitsu) {
        _validateStoredProfileCredentialSet(
          provider,
          access: primaryAccess,
          refresh: primaryRefresh,
          expires: primaryExpires,
        );
      }
      await _storage.delete(key: _credentialJournalKey(provider));
      return;
    }
    if (await activeProfileId(provider) != profileId) {
      throw _unrecoverableCredentialState(provider);
    }
    final profile = (await savedProfiles())
        .where((item) => item.provider == provider && item.id == profileId)
        .firstOrNull;
    if (profile == null) throw _unrecoverableCredentialState(provider);
    final profileAccess = await _storage.read(
      key: _profileCredentialKey(profile, 'access'),
    );
    final profileRefresh = await _storage.read(
      key: _profileCredentialKey(profile, 'refresh'),
    );
    final profileExpires = await _storage.read(
      key: _profileCredentialKey(profile, 'expires'),
    );
    if (profileAccess == null ||
        profileAccess.isEmpty ||
        profileRefresh == null ||
        profileRefresh.isEmpty) {
      throw _unrecoverableCredentialState(provider);
    }

    late final String recoveredAccess;
    late final String recoveredRefresh;
    late final String? recoveredExpires;
    if (primaryRefresh == profileRefresh) {
      // The profile is written before primary access/expiry. If access or
      // expiry differs, the profile is therefore the newer complete prefix.
      recoveredAccess = profileAccess;
      recoveredRefresh = profileRefresh;
      recoveredExpires = profileExpires;
    } else if (primaryAccess == profileAccess) {
      // Only the first primary-refresh write completed. Retain that rotated
      // refresh with the still-current access/expiry, then refresh again.
      recoveredAccess = primaryAccess;
      recoveredRefresh = primaryRefresh;
      recoveredExpires = primaryExpires;
    } else {
      throw _unrecoverableCredentialState(provider);
    }
    _validateStoredProfileCredentialSet(
      provider,
      access: recoveredAccess,
      refresh: recoveredRefresh,
      expires: recoveredExpires,
    );
    await runSecureStorageTransaction(
      _storage,
      [
        ..._credentialKeys(provider),
        _profileCredentialKey(profile, 'access'),
        _profileCredentialKey(profile, 'refresh'),
        _profileCredentialKey(profile, 'expires'),
        _credentialJournalKey(provider),
      ],
      () async {
        await _storage.write(
          key: provider.refreshTokenStorageKey,
          value: recoveredRefresh,
        );
        await _writeProfileTokenSet(
          profile,
          accessToken: recoveredAccess,
          refreshToken: recoveredRefresh,
          expiresAt: recoveredExpires,
        );
        await _storage.write(
          key: provider.tokenStorageKey,
          value: recoveredAccess,
        );
        await _writeOptional(provider.expiresAtStorageKey, recoveredExpires);
        await _storage.delete(key: _credentialJournalKey(provider));
      },
    );
  }

  Future<void> _requireConsistentActiveProfile(
    TrackingProvider provider,
  ) async {
    final primaryAccess = await _readToken(provider);
    if (primaryAccess == null) return;
    final activeId = await activeProfileId(provider);
    if (activeId == null || activeId.isEmpty) return;
    final profile = (await savedProfiles())
        .where((item) => item.provider == provider && item.id == activeId)
        .firstOrNull;
    if (profile == null) throw _unrecoverableCredentialState(provider);
    final profileAccess = await _storage.read(
      key: _profileCredentialKey(profile, 'access'),
    );
    if (profileAccess != primaryAccess) {
      throw _unrecoverableCredentialState(provider);
    }
    if (_usesRefreshTokens(provider)) {
      final primaryRefresh = await _storage.read(
        key: provider.refreshTokenStorageKey,
      );
      final primaryExpires = await _storage.read(
        key: provider.expiresAtStorageKey,
      );
      final profileRefresh = await _storage.read(
        key: _profileCredentialKey(profile, 'refresh'),
      );
      final profileExpires = await _storage.read(
        key: _profileCredentialKey(profile, 'expires'),
      );
      if (primaryRefresh != profileRefresh ||
          primaryExpires != profileExpires) {
        throw _unrecoverableCredentialState(provider);
      }
    }
  }

  Future<_CredentialJournal?> _readCredentialJournal(
    TrackingProvider provider,
  ) async {
    final raw = await _storage.read(key: _credentialJournalKey(provider));
    if (raw == null || raw.isEmpty) return null;
    if (raw.length > 1024) throw _unrecoverableCredentialState(provider);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return _CredentialJournal.fromJson(decoded);
    } on FormatException {
      throw _unrecoverableCredentialState(provider);
    }
  }

  Future<void> _writeCredentialJournal(
    TrackingProvider provider,
    _CredentialJournal journal,
  ) => _storage.write(
    key: _credentialJournalKey(provider),
    value: jsonEncode(journal.toJson()),
  );

  TrackingTokenSet _validatedRefreshTokenSet(
    TrackingProvider provider,
    TrackingTokenSet tokens,
    DateTime now,
  ) {
    if (provider != TrackingProvider.kitsu) return tokens;
    final accessToken = _normalizedTrackingCredential(tokens.accessToken);
    final refreshToken = tokens.refreshToken == null
        ? null
        : _normalizedTrackingCredential(tokens.refreshToken);
    final expiresAt = tokens.expiresAt?.toUtc();
    if (accessToken == null ||
        (tokens.refreshToken != null && refreshToken == null) ||
        expiresAt == null ||
        !expiresAt.isAfter(now) ||
        expiresAt.isAfter(now.add(_maximumKitsuTokenLifetime))) {
      throw const FormatException(
        'Kitsu returned an invalid refresh response.',
      );
    }
    return TrackingTokenSet(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
  }

  String _requireKitsuStoredCredential(String? value) {
    final normalized = _normalizedTrackingCredential(value);
    if (normalized == null) throw _incompleteKitsuSession();
    return normalized;
  }

  void _validateKitsuCredentialSet({
    required String accessToken,
    required String? refreshToken,
    required DateTime? expiresAt,
    required DateTime now,
  }) {
    if (_normalizedTrackingCredential(accessToken) == null ||
        _normalizedTrackingCredential(refreshToken) == null ||
        expiresAt == null ||
        !expiresAt.isAfter(now) ||
        expiresAt.isAfter(now.add(_maximumKitsuTokenLifetime))) {
      throw const FormatException(
        'Kitsu credentials require a refresh token and a valid future expiry.',
      );
    }
  }

  void _validateStoredProfileCredentialSet(
    TrackingProvider provider, {
    required String access,
    required String? refresh,
    required String? expires,
  }) {
    if (provider != TrackingProvider.kitsu) return;
    final expiresAt = DateTime.tryParse(expires ?? '')?.toUtc();
    final now = _now().toUtc();
    if (_normalizedTrackingCredential(access) == null ||
        _normalizedTrackingCredential(refresh) == null ||
        expiresAt == null ||
        expiresAt.isAfter(now.add(_maximumKitsuTokenLifetime))) {
      throw _incompleteKitsuSession();
    }
  }

  Future<T> _serializeCredentialMutation<T>(Future<T> Function() operation) {
    final previous = _credentialMutationTail;
    final release = Completer<void>();
    _credentialMutationTail = release.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        release.complete();
      }
    }();
  }

  Future<void> _writeProfiles(List<StoredTrackingProfile> profiles) =>
      _storage.write(
        key: _trackingProfileIndexStorageKey,
        value: jsonEncode([for (final profile in profiles) profile.toJson()]),
      );

  Future<void> _writeOptional(String key, String? value) =>
      value == null || value.isEmpty
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: value);
}

List<String> _credentialKeys(TrackingProvider provider) => [
  provider.tokenStorageKey,
  provider.refreshTokenStorageKey,
  provider.expiresAtStorageKey,
];

List<String> _activeCredentialKeys(TrackingProvider provider) => [
  ..._credentialKeys(provider),
  _activeProfileKey(provider),
  _credentialJournalKey(provider),
];

bool _usesRefreshTokens(TrackingProvider provider) =>
    provider == TrackingProvider.myAnimeList ||
    provider == TrackingProvider.kitsu;

String _activeProfileKey(TrackingProvider provider) =>
    'tracking_profile_${provider.slug}_active';

String _credentialJournalKey(TrackingProvider provider) =>
    'tracking_credentials_${provider.slug}_journal_v1';

String _profileCredentialKey(StoredTrackingProfile profile, String suffix) =>
    'tracking_profile_${profile.provider.slug}_${profile.id}_$suffix';

String _profileId(
  TrackingProvider provider,
  String username, {
  String? stableAccountId,
}) {
  final identity = stableAccountId == null
      ? 'name:${username.toLowerCase()}'
      : 'id:$stableAccountId';
  final digest = sha256.convert(utf8.encode('${provider.slug}:$identity'));
  return '${provider.slug}-${digest.toString().substring(0, 20)}';
}

String? _safeUsername(Object? value) {
  if (value is! String) return null;
  final username = value.trim();
  if (username.isEmpty || username.length > 80) return null;
  if (username.runes.any((rune) => rune < 0x20 || rune == 0x7F)) return null;
  return username;
}

String? _safeStableAccountId(Object? value) {
  if (value is! String) return null;
  final id = value.trim();
  if (id.isEmpty || id.length > 128) return null;
  if (id.runes.any((rune) => rune < 0x20 || rune == 0x7F)) return null;
  return id;
}

String? _normalizedTrackingCredential(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > _maximumTrackingCredentialLength ||
      normalized.runes.any((rune) => rune < 0x20 || rune == 0x7F)) {
    return null;
  }
  return normalized;
}

StateError _incompleteKitsuSession() => StateError(
  'The Kitsu session is incomplete and cannot be used safely. '
  'Reconnect Kitsu in Settings.',
);

StateError _unrecoverableCredentialState(TrackingProvider provider) =>
    StateError(
      'The ${provider.displayName} account credentials are inconsistent and '
      'cannot be used safely. Reconnect ${provider.displayName} in Settings.',
    );

enum _CredentialJournalOperation { activation, refresh, clear }

final class _CredentialJournal {
  const _CredentialJournal._(this.operation, this.profileId);

  const _CredentialJournal.activation(String profileId)
    : this._(_CredentialJournalOperation.activation, profileId);

  const _CredentialJournal.refresh(String? profileId)
    : this._(_CredentialJournalOperation.refresh, profileId);

  const _CredentialJournal.clear()
    : this._(_CredentialJournalOperation.clear, null);

  final _CredentialJournalOperation operation;
  final String? profileId;

  factory _CredentialJournal.fromJson(Map<String, dynamic> value) {
    if (value.length != 3 ||
        value['version'] != 1 ||
        !value.containsKey('operation') ||
        !value.containsKey('profile_id')) {
      throw const FormatException();
    }
    final operation = switch (value['operation']) {
      'activation' => _CredentialJournalOperation.activation,
      'refresh' => _CredentialJournalOperation.refresh,
      'clear' => _CredentialJournalOperation.clear,
      _ => throw const FormatException(),
    };
    final rawProfileId = value['profile_id'];
    final profileId = rawProfileId == null
        ? null
        : rawProfileId is String &&
              RegExp(r'^[a-z0-9_-]{1,80}$').hasMatch(rawProfileId)
        ? rawProfileId
        : throw const FormatException();
    if ((operation == _CredentialJournalOperation.activation &&
            profileId == null) ||
        (operation == _CredentialJournalOperation.clear && profileId != null)) {
      throw const FormatException();
    }
    return _CredentialJournal._(operation, profileId);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'operation': switch (operation) {
      _CredentialJournalOperation.activation => 'activation',
      _CredentialJournalOperation.refresh => 'refresh',
      _CredentialJournalOperation.clear => 'clear',
    },
    'profile_id': profileId,
  };
}

int _compareStoredProfiles(
  StoredTrackingProfile left,
  StoredTrackingProfile right,
) {
  final provider = left.provider.index.compareTo(right.provider.index);
  if (provider != 0) return provider;
  return left.username.toLowerCase().compareTo(right.username.toLowerCase());
}
