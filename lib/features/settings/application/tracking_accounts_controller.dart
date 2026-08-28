import 'dart:io';

import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:anime_tv/features/tracking/application/tracking_home_provider.dart';

final trackingAccountsControllerProvider =
    StateNotifierProvider<TrackingAccountsController, TrackingAccountsState>((
      ref,
    ) {
      final controller = TrackingAccountsController(
        ref,
        ref.watch(trackingTokenServiceProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class TrackingAccountsState {
  const TrackingAccountsState({
    this.isLoading = false,
    this.usernames = const {},
    this.profiles = const {},
    this.savedProfiles = const {},
    this.activeProfileIds = const {},
    this.errors = const {},
  });

  final bool isLoading;
  final Map<TrackingProvider, String> usernames;
  final Map<TrackingProvider, TrackingAccountProfile> profiles;
  final Map<TrackingProvider, List<StoredTrackingProfile>> savedProfiles;
  final Map<TrackingProvider, String> activeProfileIds;
  final Map<TrackingProvider, String> errors;

  bool isConnected(TrackingProvider provider) =>
      usernames.containsKey(provider);
}

class TrackingAccountProfile {
  const TrackingAccountProfile({
    required this.provider,
    required this.username,
    this.avatarUrl,
    this.animeCount,
    this.episodesWatched,
    this.minutesWatched,
    this.meanScore,
    this.slotId,
  });

  final TrackingProvider provider;
  final String username;
  final String? avatarUrl;
  final int? animeCount;
  final int? episodesWatched;
  final int? minutesWatched;
  final double? meanScore;
  final String? slotId;

  TrackingAccountProfile copyWith({String? slotId}) => TrackingAccountProfile(
    provider: provider,
    username: username,
    avatarUrl: avatarUrl,
    animeCount: animeCount,
    episodesWatched: episodesWatched,
    minutesWatched: minutesWatched,
    meanScore: meanScore,
    slotId: slotId ?? this.slotId,
  );
}

final class TrackingAccountImportSnapshot {
  const TrackingAccountImportSnapshot._(this.credentials, this.state);

  final TrackingCredentialSnapshot credentials;
  final TrackingAccountsState state;
}

class TrackingAccountsController extends StateNotifier<TrackingAccountsState> {
  TrackingAccountsController(this._ref, this._tokenService, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
            ),
          ),
      super(const TrackingAccountsState());

  final Ref _ref;
  final TrackingTokenService _tokenService;
  final Dio _dio;
  int _loadGeneration = 0;

  Future<void> load() async {
    final generation = ++_loadGeneration;
    state = TrackingAccountsState(
      isLoading: true,
      usernames: state.usernames,
      profiles: state.profiles,
      savedProfiles: state.savedProfiles,
      activeProfileIds: state.activeProfileIds,
      errors: state.errors,
    );
    final usernames = <TrackingProvider, String>{};
    final profiles = <TrackingProvider, TrackingAccountProfile>{};
    final activeProfileIds = <TrackingProvider, String>{};
    final errors = <TrackingProvider, String>{};
    for (final provider in TrackingProvider.values) {
      try {
        final token = await _tokenService.accessToken(provider);
        if (token == null || token.isEmpty) continue;
        var profile = await _profile(provider, token);
        final saved = await _tokenService.rememberCurrentProfile(
          provider,
          profile.username,
        );
        if (saved != null) {
          activeProfileIds[provider] = saved.id;
          profile = profile.copyWith(slotId: saved.id);
        }
        profiles[provider] = profile;
        usernames[provider] = profile.username;
      } catch (error) {
        errors[provider] = error.toString();
      }
    }
    if (!mounted || generation != _loadGeneration) return;
    final stored = await _tokenService.savedProfiles();
    if (!mounted || generation != _loadGeneration) return;
    state = TrackingAccountsState(
      usernames: usernames,
      profiles: profiles,
      savedProfiles: {
        for (final provider in TrackingProvider.values)
          provider: [
            for (final profile in stored)
              if (profile.provider == provider) profile,
          ],
      },
      activeProfileIds: activeProfileIds,
      errors: errors,
    );
  }

  Future<void> disconnect(TrackingProvider provider) async {
    // Remove the account from the visible state before the first await. This
    // keeps a slow secure-storage write or profile refresh from leaving a
    // disconnected account visible and also invalidates any older load.
    _loadGeneration++;
    state = TrackingAccountsState(
      usernames: Map<TrackingProvider, String>.of(state.usernames)
        ..remove(provider),
      profiles: Map<TrackingProvider, TrackingAccountProfile>.of(state.profiles)
        ..remove(provider),
      savedProfiles: Map<TrackingProvider, List<StoredTrackingProfile>>.of(
        state.savedProfiles,
      )..remove(provider),
      activeProfileIds: Map<TrackingProvider, String>.of(state.activeProfileIds)
        ..remove(provider),
      errors: Map<TrackingProvider, String>.of(state.errors)..remove(provider),
    );
    await _tokenService.clear(provider);
    if (!mounted) return;
    _ref.invalidate(trackingHomeProvider);
    await load();
  }

  Future<void> save(
    TrackingProvider provider,
    String token, {
    bool refreshState = true,
  }) async {
    await _tokenService.save(provider, token);
    _ref.invalidate(trackingHomeProvider);
    if (refreshState) await load();
  }

  Future<void> saveTokenSet(
    TrackingProvider provider, {
    required String accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    bool refreshState = true,
  }) async {
    await _tokenService.saveTokenSet(
      provider,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
    _ref.invalidate(trackingHomeProvider);
    if (refreshState) await load();
  }

  Future<TrackingAccountImportSnapshot> snapshotForImport(
    TrackingProvider provider,
  ) async {
    return TrackingAccountImportSnapshot._(
      await _tokenService.snapshotCredentials(provider),
      state,
    );
  }

  Future<void> restoreImportSnapshot(
    TrackingAccountImportSnapshot snapshot,
  ) async {
    _loadGeneration++;
    await _tokenService.restoreCredentials(snapshot.credentials);
    if (!mounted) return;
    state = snapshot.state;
    _ref.invalidate(trackingHomeProvider);
  }

  Future<void> refreshAfterImport() => load();

  /// Validates an imported phone-setup token without persisting it.
  ///
  /// Phone setup validates every credential before it changes any account or
  /// appearance setting. The token is deliberately never copied into state or
  /// an error/diagnostic message.
  Future<bool> validateToken(TrackingProvider provider, String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty || normalized.length > 4096) return false;
    try {
      await _profile(provider, normalized);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> switchProfile(StoredTrackingProfile profile) async {
    final generation = ++_loadGeneration;
    state = TrackingAccountsState(
      isLoading: true,
      usernames: state.usernames,
      profiles: state.profiles,
      savedProfiles: state.savedProfiles,
      activeProfileIds: state.activeProfileIds,
      errors: state.errors,
    );
    try {
      await _tokenService.activateProfile(profile);
      if (!mounted || generation != _loadGeneration) return false;
      _ref.invalidate(trackingHomeProvider);
      await load();
      return true;
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return false;
      state = TrackingAccountsState(
        usernames: state.usernames,
        profiles: state.profiles,
        savedProfiles: state.savedProfiles,
        activeProfileIds: state.activeProfileIds,
        errors: Map<TrackingProvider, String>.of(state.errors)
          ..[profile.provider] = error.toString(),
      );
      return false;
    }
  }

  Future<TrackingAccountProfile> _profile(
    TrackingProvider provider,
    String token,
  ) async {
    return switch (provider) {
      TrackingProvider.anilist => _anilistProfile(token),
      TrackingProvider.myAnimeList => _malProfile(token),
    };
  }

  Future<TrackingAccountProfile> _anilistProfile(String token) async {
    final response = await _dio.post<Map<String, dynamic>>(
      'https://graphql.anilist.co',
      data: const {
        'query': '''
          query {
            Viewer {
              name
              avatar { large }
              statistics {
                anime { count episodesWatched minutesWatched meanScore }
              }
            }
          }
        ''',
      },
      options: Options(
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status == 200,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ),
    );
    final data = response.data?['data'] as Map<String, dynamic>?;
    final viewer = data?['Viewer'] as Map<String, dynamic>?;
    final username =
        _nonEmptyString(viewer?['name']) ??
        (throw StateError('AniList account could not be verified.'));
    final avatar = viewer?['avatar'] as Map<String, dynamic>?;
    final statistics = viewer?['statistics'] as Map<String, dynamic>?;
    final anime = statistics?['anime'] as Map<String, dynamic>?;
    return TrackingAccountProfile(
      provider: TrackingProvider.anilist,
      username: username,
      avatarUrl: _safePublicAvatarUrl(avatar?['large']),
      animeCount: _nonNegativeInt(anime?['count']),
      episodesWatched: _nonNegativeInt(anime?['episodesWatched']),
      minutesWatched: _nonNegativeInt(anime?['minutesWatched']),
      meanScore: _boundedScore(anime?['meanScore'], maximum: 100),
    );
  }

  Future<TrackingAccountProfile> _malProfile(String token) async {
    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.myanimelist.net/v2/users/@me',
      queryParameters: const {'fields': 'picture,anime_statistics'},
      options: Options(
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status == 200,
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ),
    );
    final data = response.data;
    final username =
        _nonEmptyString(data?['name']) ??
        (throw StateError('MAL account could not be verified.'));
    final statistics = data?['anime_statistics'] as Map<String, dynamic>?;
    final daysWatched = statistics?['num_days_watched'];
    final minutesWatched = daysWatched is num && daysWatched.isFinite
        ? (daysWatched * Duration.minutesPerDay).round().clamp(0, 1 << 31)
        : null;
    return TrackingAccountProfile(
      provider: TrackingProvider.myAnimeList,
      username: username,
      avatarUrl: _safePublicAvatarUrl(data?['picture']),
      animeCount: _nonNegativeInt(statistics?['num_items']),
      episodesWatched: _nonNegativeInt(statistics?['num_episodes']),
      minutesWatched: minutesWatched,
      meanScore: _boundedScore(statistics?['mean_score'], maximum: 10),
    );
  }
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

int? _nonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final result = value.toInt();
  return result < 0 ? null : result;
}

double? _boundedScore(Object? value, {required double maximum}) {
  if (value is! num || !value.isFinite) return null;
  final result = value.toDouble();
  return result < 0 || result > maximum ? null : result;
}

String? _safePublicAvatarUrl(Object? value) {
  final source = _nonEmptyString(value);
  if (source == null) return null;
  try {
    final original = Uri.tryParse(source);
    if (original == null || original.hasFragment) return null;
    final uri = safePublicHttpsUri(source);
    if (uri == null ||
        (uri.hasPort && uri.port != 443) ||
        uri.path.contains('\\')) {
      return null;
    }

    // `safePublicHttpsUri` handles non-public IP ranges. For host names, keep
    // the accepted syntax deliberately narrow so unusual authority parsing,
    // single-label LAN names, and invalid DNS labels cannot reach artwork IO.
    final host = uri.host.toLowerCase();
    if (InternetAddress.tryParse(host) == null) {
      final labels = host.split('.');
      if (labels.length < 2 ||
          labels.any(
            (label) =>
                label.isEmpty ||
                label.length > 63 ||
                !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
          )) {
        return null;
      }
    }
    return uri.toString();
  } on FormatException {
    return null;
  }
}
