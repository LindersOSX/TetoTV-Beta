import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/application/tracking_token_service.dart';
import 'package:anime_tv/features/auth/data/simkl_broker_capability_client.dart';
import 'package:anime_tv/features/auth/data/simkl_pin_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/auth/domain/tracking_provider.dart';
import 'package:anime_tv/features/tracking/data/simkl_api_client.dart';
import 'package:anime_tv/features/tracking/data/simkl_account_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const simklAccessTokenStorageKey = 'simkl_access_token';
const simklClientIdStorageKey = 'simkl_public_client_id';

typedef SimklCapabilityProbe =
    Future<SimklBrokerCapability?> Function(String brokerUrl);
typedef SimklProfileLoader =
    Future<SimklUserProfile> Function({
      required String accessToken,
      required String clientId,
    });
typedef SimklCachePurger = Future<void> Function(String? scope);
typedef SimklPairingTimerFactory =
    Timer Function(Duration delay, void Function() callback);

Timer _simklPairingTimer(Duration delay, void Function() callback) =>
    Timer(delay, callback);

/// Computes conservative retry delays for the direct SIMKL TV PIN flow.
class SimklPairingPollPolicy {
  const SimklPairingPollPolicy();

  static const maximumTransientAttempts = 5;
  static const maximumDelay = Duration(seconds: 60);

  bool canRetry(int consecutiveFailures) =>
      consecutiveFailures < maximumTransientAttempts;

  Duration retryDelay({
    required Duration pollInterval,
    required int consecutiveFailures,
    Duration? retryAfter,
  }) {
    if (consecutiveFailures <= 0) {
      throw ArgumentError.value(
        consecutiveFailures,
        'consecutiveFailures',
        'Must be positive.',
      );
    }
    var multiplier = 1;
    for (var index = 1; index < consecutiveFailures; index++) {
      multiplier *= 2;
    }
    var delay = pollInterval * multiplier;
    if (retryAfter != null && retryAfter > delay) delay = retryAfter;
    if (delay < pollInterval) delay = pollInterval;
    return delay > maximumDelay ? maximumDelay : delay;
  }
}

Future<SimklBrokerCapability?> _probeSimklCapability(String brokerUrl) =>
    SimklBrokerCapabilityClient(baseUrl: brokerUrl).probe();

Future<SimklUserProfile> _loadSimklProfile({
  required String accessToken,
  required String clientId,
}) async {
  final version = await AndroidTvBridge.instance.getAppVersion();
  return SimklApiClient(
    accessToken: accessToken,
    clientId: clientId,
    appVersion: version.name == 'unknown' ? '2' : version.name,
  ).profile();
}

final simklAccountControllerProvider =
    StateNotifierProvider<SimklAccountController, SimklAccountState>((ref) {
      final storage = ref.watch(secureStorageProvider);
      final tokenService = ref.watch(trackingTokenServiceProvider);
      final sessions = ref.watch(simklAccountSessionRegistryProvider);
      return SimklAccountController(
        storage,
        profileLoader: ({required accessToken, required clientId}) async {
          final version = await AndroidTvBridge.instance.getAppVersion();
          return sessions
              .session(
                accessToken: accessToken,
                clientId: clientId,
                appVersion: version.name == 'unknown' ? '2' : version.name,
                cacheScopeLoader: () => tokenService.verifiedActiveProfileId(
                  TrackingProvider.simkl,
                  accessToken,
                ),
              )
              .profile();
        },
        cacheScopeLoader: () =>
            tokenService.activeProfileId(TrackingProvider.simkl),
        cachePurger: sessions.clearPersistent,
      );
    });

class SimklAccountState {
  const SimklAccountState({
    this.isLoading = false,
    this.isAvailable = false,
    this.hasSavedCredentials = false,
    this.username,
    this.avatarUrl,
    this.error,
  });

  final bool isLoading;
  final bool isAvailable;
  final bool hasSavedCredentials;
  final String? username;
  final String? avatarUrl;
  final String? error;

  bool get isConnected => username != null;
}

final class SimklAccountImportSnapshot {
  const SimklAccountImportSnapshot._(this.credentials, this.state);

  final SecureStorageSnapshot credentials;
  final SimklAccountState state;
}

class SimklAccountController extends StateNotifier<SimklAccountState> {
  SimklAccountController(
    this._storage, {
    this._capabilityProbe = _probeSimklCapability,
    this._profileLoader = _loadSimklProfile,
    SimklProfileLoader? validationProfileLoader,
    SimklCacheScopeLoader? cacheScopeLoader,
    SimklCachePurger? cachePurger,
  }) : _validationProfileLoader = validationProfileLoader ?? _loadSimklProfile,
       _cacheScopeLoader = cacheScopeLoader ?? _noSimklCacheScope,
       _cachePurger = cachePurger ?? _ignoreSimklCache,
       super(const SimklAccountState());

  final FlutterSecureStorage _storage;
  final SimklCapabilityProbe _capabilityProbe;
  final SimklProfileLoader _profileLoader;
  final SimklProfileLoader _validationProfileLoader;
  final SimklCacheScopeLoader _cacheScopeLoader;
  final SimklCachePurger _cachePurger;
  int _generation = 0;
  bool _hasLoaded = false;

  Future<void> load({bool force = false}) async {
    if (_hasLoaded && !force) return;
    final generation = ++_generation;
    state = SimklAccountState(
      isLoading: true,
      isAvailable: state.isAvailable,
      hasSavedCredentials: state.hasSavedCredentials,
      username: state.username,
      avatarUrl: state.avatarUrl,
    );

    final values = await Future.wait([
      _storage.read(key: simklAccessTokenStorageKey),
      _storage.read(key: simklClientIdStorageKey),
      effectiveAuthBrokerBaseUrl(_storage),
    ]);
    if (!mounted || generation != _generation) return;
    final accessToken = values[0]?.trim() ?? '';
    final storedClientId = values[1]?.trim() ?? '';
    final brokerUrl = values[2];

    SimklBrokerCapability? capability;
    if (brokerUrl != null) {
      capability = await _capabilityProbe(brokerUrl);
      if (!mounted || generation != _generation) return;
      if (capability != null && storedClientId != capability.clientId) {
        await _storage.write(
          key: simklClientIdStorageKey,
          value: capability.clientId,
        );
        if (!mounted || generation != _generation) return;
      }
    }
    final clientId = capability?.clientId ?? storedClientId;
    final hasSavedCredentials = accessToken.isNotEmpty && clientId.isNotEmpty;
    if (!hasSavedCredentials) {
      _hasLoaded = true;
      state = SimklAccountState(
        isAvailable: capability != null,
        hasSavedCredentials: false,
        error: brokerUrl == null
            ? 'Configure the secure TetoTV companion before linking SIMKL.'
            : capability == null
            ? 'SIMKL sign-in is not configured on this TetoTV companion.'
            : null,
      );
      return;
    }

    try {
      final profile = await _profileLoader(
        accessToken: accessToken,
        clientId: clientId,
      );
      if (!mounted || generation != _generation) return;
      _hasLoaded = true;
      state = SimklAccountState(
        isAvailable: capability != null,
        hasSavedCredentials: true,
        username: profile.username,
        avatarUrl: profile.avatarUrl,
      );
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _hasLoaded = true;
      state = SimklAccountState(
        isAvailable: capability != null,
        hasSavedCredentials: true,
        error: 'The saved SIMKL account could not be verified. Reconnect it.',
      );
    }
  }

  Future<void> disconnect() async {
    final scope =
        (await _cacheScopeLoader()) ??
        (state.username == null
            ? null
            : simklProfileCacheScope(state.username!));
    ++_generation;
    _hasLoaded = false;
    state = const SimklAccountState(isLoading: true);
    await runSecureStorageTransaction(
      _storage,
      const [simklAccessTokenStorageKey, simklClientIdStorageKey],
      () async {
        await _storage.delete(key: simklAccessTokenStorageKey);
        await _storage.delete(key: simklClientIdStorageKey);
      },
    );
    await _cachePurger(scope);
    if (!mounted) return;
    await load(force: true);
  }

  /// Validates a setup token against SIMKL without persisting the secret.
  Future<bool> validateToken(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty || normalized.length > 4096) return false;
    try {
      final capability = await _requireCapability();
      // Setup validation must stay independent from the shared account
      // session. The account is not committed yet, so a persistent profile or
      // list cache would outlive a later setup failure or rollback.
      await _validationProfileLoader(
        accessToken: normalized,
        clientId: capability.clientId,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<SimklAccountImportSnapshot> snapshotForImport() async {
    return SimklAccountImportSnapshot._(
      await SecureStorageSnapshot.capture(_storage, const [
        simklAccessTokenStorageKey,
        simklClientIdStorageKey,
      ]),
      state,
    );
  }

  Future<void> restoreImportSnapshot(
    SimklAccountImportSnapshot snapshot,
  ) async {
    ++_generation;
    _hasLoaded = false;
    await snapshot.credentials.restore();
    if (!mounted) return;
    state = snapshot.state;
  }

  /// Stores an imported SIMKL token and its public application ID together.
  Future<void> saveImportedToken(
    String token, {
    bool refreshState = true,
  }) async {
    final normalized = token.trim();
    if (normalized.isEmpty || normalized.length > 4096) {
      throw const FormatException('The SIMKL access token is invalid.');
    }
    final capability = await _requireCapability();
    final profile = await _profileLoader(
      accessToken: normalized,
      clientId: capability.clientId,
    );
    await runSecureStorageTransaction(
      _storage,
      const [simklAccessTokenStorageKey, simklClientIdStorageKey],
      () async {
        await _storage.write(
          key: simklClientIdStorageKey,
          value: capability.clientId,
        );
        await _storage.write(
          key: simklAccessTokenStorageKey,
          value: normalized,
        );
      },
    );
    if (!mounted) return;
    _hasLoaded = true;
    state = SimklAccountState(
      isAvailable: true,
      hasSavedCredentials: true,
      username: profile.username,
      avatarUrl: profile.avatarUrl,
    );
    if (refreshState) await load(force: true);
  }

  Future<void> refreshAfterImport() => load(force: true);

  Future<SimklBrokerCapability> _requireCapability() async {
    final brokerUrl = await effectiveAuthBrokerBaseUrl(_storage);
    if (brokerUrl == null) throw const AuthBrokerNotConfigured();
    final capability = await _capabilityProbe(brokerUrl);
    if (capability == null) throw const SimklBrokerNotConfigured();
    return capability;
  }
}

Future<String?> _noSimklCacheScope() async => null;

Future<void> _ignoreSimklCache(String? _) async {}

final simklPairingControllerProvider =
    StateNotifierProvider.autoDispose<
      SimklPairingController,
      AsyncValue<PairingSession?>
    >((ref) => SimklPairingController(ref.watch(secureStorageProvider)));

class SimklBrokerNotConfigured implements Exception {
  const SimklBrokerNotConfigured();

  @override
  String toString() =>
      'SIMKL sign-in needs a public client ID on the TetoTV companion.';
}

class SimklPairingController
    extends StateNotifier<AsyncValue<PairingSession?>> {
  SimklPairingController(
    this._storage, {
    DateTime Function()? now,
    SimklPairingTimerFactory? timerFactory,
    this._pollPolicy = const SimklPairingPollPolicy(),
  }) : _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? _simklPairingTimer,
       super(const AsyncData(null));

  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  final SimklPairingTimerFactory _timerFactory;
  final SimklPairingPollPolicy _pollPolicy;
  SimklPinClient? _client;
  SimklBrokerCapability? _capability;
  Timer? _pollTimer;
  bool _polling = false;
  int _generation = 0;
  int _failures = 0;

  Future<void> start() async {
    final generation = ++_generation;
    _pollTimer?.cancel();
    _client = null;
    _capability = null;
    _failures = 0;
    state = const AsyncLoading();
    try {
      final brokerUrl = await effectiveAuthBrokerBaseUrl(_storage);
      if (brokerUrl == null) throw const AuthBrokerNotConfigured();
      final client = SimklBrokerCapabilityClient(baseUrl: brokerUrl);
      final capability = await client.probe();
      if (capability == null) throw const SimklBrokerNotConfigured();
      final version = await AndroidTvBridge.instance.getAppVersion();
      final pinClient = SimklPinClient(
        clientId: capability.clientId,
        appVersion: version.name == 'unknown' ? '2' : version.name,
      );
      final session = await pinClient.createPairing();
      if (!mounted || generation != _generation) return;
      _client = pinClient;
      _capability = capability;
      state = AsyncData(session);
      _schedulePoll(generation, session, session.pollInterval);
    } catch (error, stackTrace) {
      if (!mounted || generation != _generation) return;
      state = AsyncError(error, stackTrace);
    }
  }

  Future<void> _poll(int generation) async {
    _pollTimer = null;
    if (!mounted || generation != _generation) return;
    final session = state.valueOrNull;
    final client = _client;
    final capability = _capability;
    if (session == null ||
        client == null ||
        capability == null ||
        session.status != PairingStatus.pending) {
      return;
    }
    if (_polling) {
      _schedulePoll(generation, session, session.pollInterval);
      return;
    }
    if (!_now().toUtc().isBefore(session.expiresAt.toUtc())) {
      _expire(generation, session);
      return;
    }

    _polling = true;
    try {
      final result = await client.pollPairing(session);
      if (!mounted || generation != _generation) return;
      _failures = 0;
      if (result.status == PairingStatus.authorized) {
        final token = result.accessToken;
        if (token == null || token.isEmpty) {
          throw const FormatException(
            'SIMKL pairing completed without an access token.',
          );
        }
        await runSecureStorageTransaction(
          _storage,
          const [simklAccessTokenStorageKey, simklClientIdStorageKey],
          () async {
            await _storage.write(key: simklAccessTokenStorageKey, value: token);
            await _storage.write(
              key: simklClientIdStorageKey,
              value: capability.clientId,
            );
          },
        );
        if (!mounted || generation != _generation) return;
        state = AsyncData(session.copyWith(status: result.status));
        return;
      }
      state = AsyncData(session.copyWith(status: result.status));
      if (result.status == PairingStatus.pending) {
        _schedulePoll(generation, session, session.pollInterval);
      }
    } catch (error, stackTrace) {
      if (!mounted || generation != _generation) return;
      if (error is! SimklPinTransientException) {
        state = AsyncError(error, stackTrace);
        return;
      }
      _failures++;
      if (!_now().toUtc().isBefore(session.expiresAt.toUtc())) {
        _expire(generation, session);
        return;
      }
      if (!_pollPolicy.canRetry(_failures)) {
        state = AsyncError(error, stackTrace);
        return;
      }
      final delay = _pollPolicy.retryDelay(
        pollInterval: session.pollInterval,
        consecutiveFailures: _failures,
        retryAfter: error.retryAfter,
      );
      _schedulePoll(generation, session, delay);
    } finally {
      _polling = false;
    }
  }

  void _schedulePoll(
    int generation,
    PairingSession session,
    Duration requestedDelay,
  ) {
    if (!mounted || generation != _generation) return;
    _pollTimer?.cancel();
    final now = _now().toUtc();
    final remaining = session.expiresAt.toUtc().difference(now);
    if (remaining <= Duration.zero) {
      _expire(generation, session);
      return;
    }
    if (requestedDelay >= remaining) {
      _pollTimer = _timerFactory(remaining, () => _expire(generation, session));
      return;
    }
    _pollTimer = _timerFactory(
      requestedDelay,
      () => unawaited(_poll(generation)),
    );
  }

  void _expire(int generation, PairingSession session) {
    if (!mounted || generation != _generation) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    final current = state.valueOrNull ?? session;
    if (current.status == PairingStatus.pending) {
      state = AsyncData(current.copyWith(status: PairingStatus.expired));
    }
  }

  @override
  void dispose() {
    ++_generation;
    _pollTimer?.cancel();
    super.dispose();
  }
}
