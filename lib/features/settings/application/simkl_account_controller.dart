import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/auth/data/simkl_broker_capability_client.dart';
import 'package:anime_tv/features/auth/domain/pairing_session.dart';
import 'package:anime_tv/features/tracking/data/simkl_api_client.dart';
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
      return SimklAccountController(ref.watch(secureStorageProvider));
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

class SimklAccountController extends StateNotifier<SimklAccountState> {
  SimklAccountController(
    this._storage, {
    this._capabilityProbe = _probeSimklCapability,
    this._profileLoader = _loadSimklProfile,
  }) : super(const SimklAccountState());

  final FlutterSecureStorage _storage;
  final SimklCapabilityProbe _capabilityProbe;
  final SimklProfileLoader _profileLoader;
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
    if (!mounted) return;
    await load(force: true);
  }
}

final simklPairingControllerProvider =
    StateNotifierProvider.autoDispose<
      SimklPairingController,
      AsyncValue<PairingSession?>
    >((ref) => SimklPairingController(ref.watch(secureStorageProvider)));

class SimklBrokerNotConfigured implements Exception {
  const SimklBrokerNotConfigured();

  @override
  String toString() =>
      'SIMKL sign-in is not configured on the TetoTV companion.';
}

class SimklPairingController
    extends StateNotifier<AsyncValue<PairingSession?>> {
  SimklPairingController(this._storage) : super(const AsyncData(null));

  final FlutterSecureStorage _storage;
  SimklBrokerCapabilityClient? _client;
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
      final session = await client.createPairing(capability);
      if (!mounted || generation != _generation) return;
      _client = client;
      _capability = capability;
      state = AsyncData(session);
      _pollTimer = Timer.periodic(
        session.pollInterval,
        (_) => _poll(generation),
      );
    } catch (error, stackTrace) {
      if (!mounted || generation != _generation) return;
      state = AsyncError(error, stackTrace);
    }
  }

  Future<void> _poll(int generation) async {
    if (!mounted || generation != _generation || _polling) return;
    final session = state.valueOrNull;
    final client = _client;
    final capability = _capability;
    if (session == null ||
        client == null ||
        capability == null ||
        session.status != PairingStatus.pending) {
      return;
    }
    if (DateTime.now().isAfter(session.expiresAt)) {
      _pollTimer?.cancel();
      state = AsyncData(session.copyWith(status: PairingStatus.expired));
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
        _pollTimer?.cancel();
      } else if (result.status == PairingStatus.expired) {
        _pollTimer?.cancel();
      }
      state = AsyncData(session.copyWith(status: result.status));
    } catch (error, stackTrace) {
      if (!mounted || generation != _generation) return;
      _failures++;
      if (_failures >= 3 || DateTime.now().isAfter(session.expiresAt)) {
        _pollTimer?.cancel();
        state = AsyncError(error, stackTrace);
      }
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    ++_generation;
    _pollTimer?.cancel();
    super.dispose();
  }
}
