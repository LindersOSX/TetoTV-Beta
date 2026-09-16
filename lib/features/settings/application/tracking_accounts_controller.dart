import 'dart:async';
import 'dart:io';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/tetotv_database.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/data/simkl_broker_capability_client.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:anime_tv/features/settings/application/simkl_account_controller.dart';
import 'package:anime_tv/features/tracking/data/simkl_account_session.dart';
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
        diagnosticRecorder: (details) =>
            TetoTvDatabase.instance.recordDiagnosticEvent(
              category: 'tracking-account',
              severity: 'warning',
              message: 'Tracker account refresh deferred or failed',
              details: details,
            ),
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
    this.stableAccountId,
    this.slotId,
  });

  final TrackingProvider provider;
  final String username;
  final String? avatarUrl;
  final int? animeCount;
  final int? episodesWatched;
  final int? minutesWatched;
  final double? meanScore;
  final String? stableAccountId;
  final String? slotId;

  TrackingAccountProfile copyWith({String? slotId}) => TrackingAccountProfile(
    provider: provider,
    username: username,
    avatarUrl: avatarUrl,
    animeCount: animeCount,
    episodesWatched: episodesWatched,
    minutesWatched: minutesWatched,
    meanScore: meanScore,
    stableAccountId: stableAccountId,
    slotId: slotId ?? this.slotId,
  );
}

typedef TrackingAccountDiagnosticRecorder =
    Future<void> Function(Map<String, Object?> details);

final class TrackingAccountImportSnapshot {
  const TrackingAccountImportSnapshot._(this.credentials, this.state);

  final TrackingCredentialSnapshot credentials;
  final TrackingAccountsState state;
}

class TrackingAccountsController extends StateNotifier<TrackingAccountsState> {
  TrackingAccountsController(
    this._ref,
    this._tokenService, {
    Dio? dio,
    this.diagnosticRecorder,
  }) : _dio =
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
  final TrackingAccountDiagnosticRecorder? diagnosticRecorder;
  final Map<TrackingProvider, Timer> _retryTimers = {};
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
          stableAccountId: profile.stableAccountId,
        );
        if (saved != null) {
          activeProfileIds[provider] = saved.id;
          profile = profile.copyWith(slotId: saved.id);
        }
        profiles[provider] = profile;
        usernames[provider] = profile.username;
      } catch (error) {
        final failure = _safeTrackingAccountFailure(provider, error);
        errors[provider] = failure.message;
        final previousProfile = state.profiles[provider];
        final previousUsername = state.usernames[provider];
        final previousActiveProfile = state.activeProfileIds[provider];
        if (previousProfile != null && previousUsername != null) {
          profiles[provider] = previousProfile;
          usernames[provider] = previousUsername;
          if (previousActiveProfile != null) {
            activeProfileIds[provider] = previousActiveProfile;
          }
        }
        _recordFailure(provider, failure);
        if (failure.reasonCode == 'rate_limited') {
          _scheduleRetry(provider, failure.retryAfter);
        }
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
    final simklScopes = <String?>{};
    if (provider == TrackingProvider.simkl) {
      simklScopes.add(await _tokenService.activeProfileId(provider));
      simklScopes.addAll([
        for (final profile in await _tokenService.savedProfiles())
          if (profile.provider == TrackingProvider.simkl) profile.id,
      ]);
      if (state.usernames[provider] case final username?) {
        simklScopes.add(simklProfileCacheScope(username));
      }
    }
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
    if (provider == TrackingProvider.simkl) {
      await _ref
          .read(simklAccountSessionRegistryProvider)
          .clearPersistentScopes(simklScopes);
    }
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
      TrackingProvider.kitsu => _kitsuProfile(token),
      TrackingProvider.simkl => _simklProfile(token),
    };
  }

  void _scheduleRetry(TrackingProvider provider, Duration? requestedDelay) {
    _retryTimers.remove(provider)?.cancel();
    final delay = requestedDelay ?? const Duration(seconds: 60);
    _retryTimers[provider] = Timer(delay, () {
      _retryTimers.remove(provider);
      if (mounted) unawaited(load());
    });
  }

  void _recordFailure(
    TrackingProvider provider,
    _TrackingAccountFailure failure,
  ) {
    final recorder = diagnosticRecorder;
    if (recorder == null) return;
    unawaited(
      Future<void>.sync(
        () => recorder({
          'provider': provider.slug,
          'stage': 'profile_refresh',
          'reason_code': failure.reasonCode,
          'code': ?failure.httpStatus,
          if (failure.retryAfter case final retryAfter?)
            'retry_after_seconds': retryAfter.inSeconds.clamp(1, 3600),
        }),
      ).catchError((_) {}),
    );
  }

  @override
  void dispose() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    super.dispose();
  }

  Future<TrackingAccountProfile> _kitsuProfile(String token) async {
    final response = await _dio.get<Map<String, dynamic>>(
      'https://kitsu.io/api/edge/users',
      queryParameters: const {'filter[self]': 'true', 'page[limit]': 1},
      options: Options(
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (status) => status == 200,
        headers: {
          'Accept': 'application/vnd.api+json',
          'Content-Type': 'application/vnd.api+json',
          'Authorization': 'Bearer $token',
        },
      ),
    );
    final resources = response.data?['data'];
    final user = resources is List && resources.isNotEmpty
        ? resources.first
        : null;
    final attributes = user is Map
        ? user['attributes'] as Map<String, dynamic>?
        : null;
    final stableAccountId = user is Map
        ? _safeStableAccountId(user['id'])
        : null;
    if (stableAccountId == null) {
      throw StateError('Kitsu account could not be verified.');
    }
    final username =
        _nonEmptyString(attributes?['name']) ??
        _nonEmptyString(attributes?['slug']) ??
        (throw StateError('Kitsu account could not be verified.'));
    final avatar = attributes?['avatar'] as Map<String, dynamic>?;
    return TrackingAccountProfile(
      provider: TrackingProvider.kitsu,
      username: username,
      stableAccountId: stableAccountId,
      avatarUrl: _safePublicAvatarUrl(
        avatar?['large'] ?? avatar?['medium'] ?? avatar?['small'],
      ),
    );
  }

  Future<TrackingAccountProfile> _simklProfile(String token) async {
    final storage = _ref.read(secureStorageProvider);
    var clientId = (await storage.read(key: simklClientIdStorageKey))?.trim();
    if (clientId == null || clientId.isEmpty) {
      final brokerUrl = await effectiveAuthBrokerBaseUrl(storage);
      final capability = brokerUrl == null
          ? null
          : await SimklBrokerCapabilityClient(baseUrl: brokerUrl).probe();
      clientId = capability?.clientId;
      if (clientId != null && clientId.isNotEmpty) {
        await storage.write(key: simklClientIdStorageKey, value: clientId);
      }
    }
    if (clientId == null || clientId.isEmpty) {
      throw StateError(
        'SIMKL needs the public app ID from the TetoTV companion. Reconnect SIMKL.',
      );
    }
    final version = await AndroidTvBridge.instance.getAppVersion();
    final profile = await _ref
        .read(simklAccountSessionRegistryProvider)
        .session(
          accessToken: token,
          clientId: clientId,
          appVersion: version.name == 'unknown' ? '2' : version.name,
          cacheScopeLoader: () => _tokenService.verifiedActiveProfileId(
            TrackingProvider.simkl,
            token,
          ),
        )
        .profile();
    return TrackingAccountProfile(
      provider: TrackingProvider.simkl,
      username: profile.username,
      avatarUrl: profile.avatarUrl,
    );
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

class _TrackingAccountFailure {
  const _TrackingAccountFailure({
    required this.reasonCode,
    required this.message,
    this.httpStatus,
    this.retryAfter,
  });

  final String reasonCode;
  final String message;
  final int? httpStatus;
  final Duration? retryAfter;
}

_TrackingAccountFailure _safeTrackingAccountFailure(
  TrackingProvider provider,
  Object error,
) {
  if (error is StateError &&
      error.message.contains('session expired and cannot be refreshed')) {
    return _TrackingAccountFailure(
      reasonCode: 'authorization_expired',
      message:
          'The ${provider.displayName} session expired and cannot be refreshed. Reconnect ${provider.displayName} in Settings.',
    );
  }
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 429) {
      return _TrackingAccountFailure(
        reasonCode: 'rate_limited',
        message:
            '${provider.displayName} remains linked, but its profile check is temporarily rate-limited. TetoTV will retry automatically.',
        httpStatus: status,
        retryAfter: _trackingRetryDelay(error.response?.headers),
      );
    }
    if (status == 401 || status == 403) {
      return _TrackingAccountFailure(
        reasonCode: 'authorization_expired',
        message:
            '${provider.displayName} needs to be reconnected before profile syncing can continue.',
        httpStatus: status,
      );
    }
    final text = '${error.error ?? error.message ?? ''}'.toLowerCase();
    final dnsFailure =
        text.contains('failed host lookup') ||
        text.contains('no address associated with hostname') ||
        text.contains('temporary failure in name resolution');
    return _TrackingAccountFailure(
      reasonCode: dnsFailure ? 'dns_lookup_failed' : 'network_failure',
      message:
          '${provider.displayName} remains linked, but its profile could not be checked while the network is unavailable.',
      httpStatus: status,
    );
  }
  return _TrackingAccountFailure(
    reasonCode: 'profile_unavailable',
    message:
        '${provider.displayName} remains linked, but its profile could not be verified right now.',
  );
}

Duration _trackingRetryDelay(Headers? headers) {
  final value = headers?.value('retry-after')?.trim();
  var seconds = value == null ? null : int.tryParse(value);
  if (seconds == null && value != null && value.length <= 80) {
    try {
      seconds = HttpDate.parse(
        value,
      ).difference(DateTime.now().toUtc()).inSeconds;
    } catch (_) {
      // Never display or diagnose an untrusted header value.
    }
  }
  return Duration(seconds: (seconds ?? 60).clamp(1, 3600));
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String? _safeStableAccountId(Object? value) {
  final id = _nonEmptyString(value);
  if (id == null || id.length > 128) return null;
  if (id.runes.any((rune) => rune < 0x20 || rune == 0x7F)) return null;
  return id;
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
