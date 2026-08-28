import 'dart:convert';

import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
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
  Future<String?>? _myAnimeListRequest;

  Future<String?> accessToken(TrackingProvider provider) async {
    if (provider != TrackingProvider.myAnimeList) {
      return _readToken(provider);
    }

    // MAL refresh tokens rotate. Sharing the same in-flight refresh prevents
    // parallel Home, My List, and Settings requests from invalidating it.
    final activeRequest = _myAnimeListRequest;
    if (activeRequest != null) return activeRequest;

    final request = _myAnimeListAccessToken();
    _myAnimeListRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_myAnimeListRequest, request)) {
        _myAnimeListRequest = null;
      }
    }
  }

  Future<String?> _readToken(TrackingProvider provider) async {
    final accessToken = await _storage.read(key: provider.tokenStorageKey);
    if (accessToken == null || accessToken.isEmpty) return null;
    return accessToken;
  }

  Future<String?> _myAnimeListAccessToken() async {
    const provider = TrackingProvider.myAnimeList;
    final accessToken = await _readToken(provider);
    if (accessToken == null) return null;

    final expiresAtValue = await _storage.read(
      key: provider.expiresAtStorageKey,
    );
    final expiresAt = DateTime.tryParse(expiresAtValue ?? '');
    final now = _now().toUtc();
    if (expiresAt == null ||
        expiresAt.toUtc().isAfter(now.add(const Duration(minutes: 5)))) {
      return accessToken;
    }

    final refreshToken = await _storage.read(
      key: provider.refreshTokenStorageKey,
    );
    final brokerUrl = await effectiveAuthBrokerBaseUrl(_storage);
    if (refreshToken == null || refreshToken.isEmpty || brokerUrl == null) {
      if (!expiresAt.toUtc().isAfter(now)) {
        throw StateError(
          'The MAL session expired and cannot be refreshed. '
          'Reconnect MAL in Settings.',
        );
      }
      return accessToken;
    }

    late final TrackingTokenSet tokens;
    try {
      tokens = await _clientFactory(
        provider,
        baseUrl: brokerUrl,
      ).refresh(refreshToken);
    } catch (_) {
      // A short broker outage should not log the user out while the current
      // access token is still valid. Once expired, surface the real error.
      if (expiresAt.toUtc().isAfter(now)) return accessToken;
      rethrow;
    }

    if (tokens.refreshToken case final rotated? when rotated.isNotEmpty) {
      // Rotating refresh tokens must be committed before the new access
      // token. A process interruption can then retry with the new refresh
      // token instead of stranding a new access token with an invalidated one.
      await _storage.write(
        key: provider.refreshTokenStorageKey,
        value: rotated,
      );
    }
    await _storage.write(
      key: provider.tokenStorageKey,
      value: tokens.accessToken,
    );
    if (tokens.expiresAt case final newExpiry?) {
      await _storage.write(
        key: provider.expiresAtStorageKey,
        value: newExpiry.toUtc().toIso8601String(),
      );
    } else {
      await _storage.delete(key: provider.expiresAtStorageKey);
    }
    return tokens.accessToken;
  }

  Future<void> save(TrackingProvider provider, String token) async {
    await runSecureStorageTransaction(
      _storage,
      _credentialKeys(provider),
      () async {
        // Clear rotated-session metadata first. If the app is interrupted,
        // the transaction restores the complete previous credential set.
        await _storage.delete(key: provider.refreshTokenStorageKey);
        await _storage.delete(key: provider.expiresAtStorageKey);
        await _storage.write(
          key: provider.tokenStorageKey,
          value: token.trim(),
        );
      },
    );
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
    await runSecureStorageTransaction(
      _storage,
      _credentialKeys(provider),
      () async {
        await _writeOptional(
          provider.refreshTokenStorageKey,
          refreshToken?.trim(),
        );
        await _writeOptional(
          provider.expiresAtStorageKey,
          expiresAt?.toUtc().toIso8601String(),
        );
        await _storage.write(
          key: provider.tokenStorageKey,
          value: accessToken.trim(),
        );
      },
    );
    if (provider == TrackingProvider.myAnimeList) {
      _myAnimeListRequest = null;
    }
  }

  Future<TrackingCredentialSnapshot> snapshotCredentials(
    TrackingProvider provider,
  ) async {
    return TrackingCredentialSnapshot._(
      provider,
      await SecureStorageSnapshot.capture(_storage, _credentialKeys(provider)),
    );
  }

  Future<void> restoreCredentials(TrackingCredentialSnapshot snapshot) async {
    await snapshot._storageSnapshot.restore();
    if (snapshot.provider == TrackingProvider.myAnimeList) {
      _myAnimeListRequest = null;
    }
  }

  /// Saves the currently active legacy credentials into a named encrypted
  /// profile slot after the tracker API has verified the username. Only the
  /// non-secret slot index is returned to presentation code.
  Future<StoredTrackingProfile?> rememberCurrentProfile(
    TrackingProvider provider,
    String username,
  ) async {
    final normalizedUsername = _safeUsername(username);
    if (normalizedUsername == null) return null;
    final accessToken = await _storage.read(key: provider.tokenStorageKey);
    if (accessToken == null || accessToken.isEmpty) return null;

    final id = _profileId(provider, normalizedUsername);
    final profile = StoredTrackingProfile(
      id: id,
      provider: provider,
      username: normalizedUsername,
    );
    final refreshToken = await _storage.read(
      key: provider.refreshTokenStorageKey,
    );
    final expiresAt = await _storage.read(key: provider.expiresAtStorageKey);
    await _writeOptional(
      _profileCredentialKey(profile, 'refresh'),
      refreshToken,
    );
    await _writeOptional(_profileCredentialKey(profile, 'expires'), expiresAt);
    await _storage.write(
      key: _profileCredentialKey(profile, 'access'),
      value: accessToken,
    );

    final profiles = await savedProfiles();
    final next = [
      for (final existing in profiles)
        if (!(existing.provider == provider && existing.id == id)) existing,
      profile,
    ]..sort(_compareStoredProfiles);
    await _writeProfiles(next);
    await _storage.write(key: _activeProfileKey(provider), value: id);
    return profile;
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

  Future<void> activateProfile(StoredTrackingProfile profile) async {
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
    await _writeOptional(profile.provider.refreshTokenStorageKey, refresh);
    await _writeOptional(profile.provider.expiresAtStorageKey, expires);
    await _storage.write(key: profile.provider.tokenStorageKey, value: access);
    await _storage.write(
      key: _activeProfileKey(profile.provider),
      value: profile.id,
    );
    if (profile.provider == TrackingProvider.myAnimeList) {
      _myAnimeListRequest = null;
    }
  }

  Future<void> clear(TrackingProvider provider) async {
    final profiles = await savedProfiles();
    final removed = profiles.where((profile) => profile.provider == provider);
    await Future.wait([
      _storage.delete(key: provider.tokenStorageKey),
      _storage.delete(key: provider.refreshTokenStorageKey),
      _storage.delete(key: provider.expiresAtStorageKey),
      _storage.delete(key: _activeProfileKey(provider)),
      for (final profile in removed)
        for (final suffix in const ['access', 'refresh', 'expires'])
          _storage.delete(key: _profileCredentialKey(profile, suffix)),
    ]);
    await _writeProfiles([
      for (final profile in profiles)
        if (profile.provider != provider) profile,
    ]);
    if (provider == TrackingProvider.myAnimeList) {
      _myAnimeListRequest = null;
    }
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

String _activeProfileKey(TrackingProvider provider) =>
    'tracking_profile_${provider.slug}_active';

String _profileCredentialKey(StoredTrackingProfile profile, String suffix) =>
    'tracking_profile_${profile.provider.slug}_${profile.id}_$suffix';

String _profileId(TrackingProvider provider, String username) {
  final digest = sha256.convert(
    utf8.encode('${provider.slug}:${username.toLowerCase()}'),
  );
  return '${provider.slug}-${digest.toString().substring(0, 20)}';
}

String? _safeUsername(Object? value) {
  if (value is! String) return null;
  final username = value.trim();
  if (username.isEmpty || username.length > 80) return null;
  if (username.runes.any((rune) => rune < 0x20 || rune == 0x7F)) return null;
  return username;
}

int _compareStoredProfiles(
  StoredTrackingProfile left,
  StoredTrackingProfile right,
) {
  final provider = left.provider.index.compareTo(right.provider.index);
  if (provider != 0) return provider;
  return left.username.toLowerCase().compareTo(right.username.toLowerCase());
}
