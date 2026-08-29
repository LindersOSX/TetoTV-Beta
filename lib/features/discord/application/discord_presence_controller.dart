import 'dart:async';

import 'package:anime_tv/core/platform/android_tv_bridge.dart';
import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/discord/domain/discord_minimum_age_confirmation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class DiscordPresencePlatform {
  Stream<DiscordBridgeEvent> get events;
  Future<Map<Object?, Object?>> sdkInfo();
  Future<DiscordTokenBundle> authenticate();
  Future<void> cancelAuthentication();
  Future<DiscordTokenBundle> refreshToken(String refreshToken);
  Future<void> connect(DiscordTokenBundle token);
  Future<bool> revoke(String token);
  Future<void> disconnect();
}

class AndroidDiscordPresencePlatform implements DiscordPresencePlatform {
  AndroidDiscordPresencePlatform(this._bridge);

  final AndroidTvBridge _bridge;

  @override
  Stream<DiscordBridgeEvent> get events => _bridge.discordEvents;

  @override
  Future<Map<Object?, Object?>> sdkInfo() => _bridge.discordSdkInfo();

  @override
  Future<DiscordTokenBundle> authenticate() => _bridge.discordAuthenticate();

  @override
  Future<void> cancelAuthentication() => _bridge.discordCancelAuthentication();

  @override
  Future<DiscordTokenBundle> refreshToken(String refreshToken) =>
      _bridge.discordRefreshToken(refreshToken);

  @override
  Future<void> connect(DiscordTokenBundle token) =>
      _bridge.discordConnect(token);

  @override
  Future<bool> revoke(String token) => _bridge.discordRevoke(token);

  @override
  Future<void> disconnect() => _bridge.discordDisconnect();
}

final discordPresencePlatformProvider = Provider<DiscordPresencePlatform>(
  (_) => AndroidDiscordPresencePlatform(AndroidTvBridge.instance),
);

class DiscordPresenceState {
  const DiscordPresenceState({
    this.loaded = false,
    this.available = false,
    this.linked = false,
    this.enabled = false,
    this.busy = false,
    this.connectionStatus = 'disconnected',
    this.sdkVersion,
    this.error,
  });

  final bool loaded;
  final bool available;
  final bool linked;
  final bool enabled;
  final bool busy;
  final String connectionStatus;
  final String? sdkVersion;
  final String? error;

  bool get connected => connectionStatus == 'ready';

  DiscordPresenceState copyWith({
    bool? loaded,
    bool? available,
    bool? linked,
    bool? enabled,
    bool? busy,
    String? connectionStatus,
    String? sdkVersion,
    String? error,
    bool clearError = false,
  }) {
    return DiscordPresenceState(
      loaded: loaded ?? this.loaded,
      available: available ?? this.available,
      linked: linked ?? this.linked,
      enabled: enabled ?? this.enabled,
      busy: busy ?? this.busy,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      sdkVersion: sdkVersion ?? this.sdkVersion,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final class DiscordImportSnapshot {
  const DiscordImportSnapshot._(
    this._storageSnapshot,
    this.state,
    this._token,
    this.wasConnected,
  );

  final SecureStorageSnapshot _storageSnapshot;
  final DiscordPresenceState state;
  final DiscordTokenBundle? _token;
  final bool wasConnected;
}

final discordPresenceControllerProvider =
    StateNotifierProvider<DiscordPresenceController, DiscordPresenceState>((
      ref,
    ) {
      return DiscordPresenceController(
        ref.watch(secureStorageProvider),
        ref.watch(discordPresencePlatformProvider),
      );
    });

class DiscordPresenceController extends StateNotifier<DiscordPresenceState> {
  DiscordPresenceController(
    this._storage,
    this._platform, {
    // TV users may need to enter credentials or approve in a second app.
    this._authenticationTimeout = const Duration(minutes: 6),
    // Device pairing has already securely stored the token before this
    // best-effort native connection. Never leave its completion UI hanging.
    this._deviceConnectionTimeout = const Duration(seconds: 20),
  }) : super(const DiscordPresenceState()) {
    _eventSubscription = _platform.events.listen(_handleEvent);
    _initialization = _initialize();
    unawaited(_initialization);
  }

  static const _enabledKey = 'discord_rich_presence_enabled';
  static const _accessTokenKey = 'discord_rich_presence_access_token';
  static const _refreshTokenKey = 'discord_rich_presence_refresh_token';
  static const _tokenTypeKey = 'discord_rich_presence_token_type';
  static const _expiresAtKey = 'discord_rich_presence_expires_at';
  static const _scopesKey = 'discord_rich_presence_scopes';
  static const _minimumAgeConfirmationKey =
      'discord_rich_presence_minimum_age_confirmation_v1';
  static const _refreshWindow = Duration(hours: 24);

  final FlutterSecureStorage _storage;
  final DiscordPresencePlatform _platform;
  final Duration _authenticationTimeout;
  final Duration _deviceConnectionTimeout;
  late final StreamSubscription<DiscordBridgeEvent> _eventSubscription;
  late final Future<void> _initialization;
  bool _refreshing = false;
  int _authenticationGeneration = 0;
  Timer? _authenticationTimer;
  Completer<DiscordTokenBundle>? _authenticationCompleter;
  int? _nativeAuthenticationGeneration;
  Future<void>? _authenticationCancellation;

  Future<void> _initialize() async {
    try {
      final info = await _platform.sdkInfo();
      final available = info['available'] == true;
      final token = await _loadToken();
      final enabled = await _storage.read(key: _enabledKey) == 'true';
      if (!mounted) return;
      state = state.copyWith(
        loaded: true,
        available: available,
        linked: token != null,
        enabled: enabled && token != null,
        connectionStatus: info['status'] as String? ?? 'disconnected',
        sdkVersion: info['version'] as String?,
        clearError: true,
      );
      if (!available || token == null || !enabled) return;
      final current = await _refreshIfNeeded(token);
      if (!mounted) return;
      await _connect(current);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        loaded: true,
        busy: false,
        error: _friendly(error),
      );
    }
  }

  Future<void> linkAccount(
    DiscordMinimumAgeConfirmation minimumAgeConfirmation,
  ) async {
    if (!mounted || state.busy || !state.available) return;
    _validateMinimumAgeConfirmation(minimumAgeConfirmation);
    final generation = ++_authenticationGeneration;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final token = await _authenticateWithTimeout(generation);
      if (!_isCurrentAuthentication(generation)) return;
      _validateToken(token);
      await _storeNewToken(token, minimumAgeConfirmation);
      if (!_isCurrentAuthentication(generation)) return;
      state = state.copyWith(linked: true, enabled: true);
      await _connect(token);
    } on TimeoutException {
      if (!_isCurrentAuthentication(generation)) return;
      await _cancelAuthenticationQuietly();
      if (!_isCurrentAuthentication(generation)) return;
      state = state.copyWith(
        error: 'Discord account linking timed out. Please try again.',
      );
    } on _DiscordAuthenticationAbandoned {
      return;
    } catch (error) {
      if (!_isCurrentAuthentication(generation)) return;
      state = state.copyWith(error: _friendly(error));
    } finally {
      if (_isCurrentAuthentication(generation)) {
        state = state.copyWith(busy: false);
      }
    }
  }

  /// Accepts a token returned by Discord's limited-input device flow.
  ///
  /// The same secure-storage and native connection path used by mobile OAuth
  /// is retained. Concurrent native or device linking attempts cannot race.
  Future<void> acceptLinkedToken(
    DiscordTokenBundle token,
    DiscordMinimumAgeConfirmation minimumAgeConfirmation,
  ) async {
    return _acceptLinkedToken(
      token,
      minimumAgeConfirmation,
      requireAvailable: true,
    );
  }

  /// Imports an end-to-end encrypted token bundle from first-time phone setup.
  /// The credentials are saved even when the native Discord SDK is not ready
  /// yet; the normal initialization/retry path connects it when available.
  Future<void> importLinkedToken(
    DiscordTokenBundle token,
    DiscordMinimumAgeConfirmation minimumAgeConfirmation, {
    bool connectAfterStore = true,
  }) {
    return _acceptLinkedToken(
      token,
      minimumAgeConfirmation,
      requireAvailable: false,
      connectAfterStore: connectAfterStore,
    );
  }

  Future<void> _acceptLinkedToken(
    DiscordTokenBundle token,
    DiscordMinimumAgeConfirmation minimumAgeConfirmation, {
    required bool requireAvailable,
    bool connectAfterStore = true,
  }) async {
    if (!mounted || state.busy || (requireAvailable && !state.available)) {
      throw StateError('Discord is already handling another request.');
    }
    final generation = ++_authenticationGeneration;
    state = state.copyWith(busy: true, clearError: true);
    try {
      _validateMinimumAgeConfirmation(minimumAgeConfirmation);
      _validateToken(token);
      final scopes = token.scopes
          .split(RegExp(r'\s+'))
          .where((scope) => scope.isNotEmpty)
          .toSet();
      if (token.tokenType != 1 ||
          !scopes.contains('openid') ||
          !scopes.contains('sdk.social_layer_presence')) {
        throw StateError('Discord returned an invalid device-linking token.');
      }
      await _storeNewToken(token, minimumAgeConfirmation);
      if (!_isCurrentAuthentication(generation)) return;
      state = state.copyWith(linked: true, enabled: true);
      if (!state.available || !connectAfterStore) return;
      try {
        await _connect(token).timeout(_deviceConnectionTimeout);
      } on TimeoutException {
        // Future.timeout continues observing the native Future, so a late
        // completion/error is handled. Disconnect also releases Android's
        // pending-connect slot so Settings Retry can start a fresh attempt.
        await _cancelTimedOutDeviceConnection();
        if (_isCurrentAuthentication(generation)) {
          state = state.copyWith(
            connectionStatus: 'disconnected',
            error:
                'Discord is linked, but the connection timed out. Use Retry to connect Rich Presence.',
          );
        }
      } catch (error) {
        // The account is securely linked at this point. Match mobile linking:
        // retain it and let Settings expose the normal connection retry.
        if (_isCurrentAuthentication(generation)) {
          state = state.copyWith(
            connectionStatus: 'disconnected',
            error: _friendly(error),
          );
        }
      }
    } catch (error) {
      if (_isCurrentAuthentication(generation)) {
        state = state.copyWith(error: _friendly(error));
      }
      rethrow;
    } finally {
      if (_isCurrentAuthentication(generation)) {
        state = state.copyWith(busy: false);
      }
    }
  }

  Future<void> _cancelTimedOutDeviceConnection() async {
    try {
      await _platform.disconnect().timeout(const Duration(seconds: 5));
    } catch (_) {
      // The account token is already secure and remains linked. Native status
      // events can still settle a cancellation that outlives this guard.
    }
  }

  Future<DiscordTokenBundle> _authenticateWithTimeout(int generation) {
    final completer = Completer<DiscordTokenBundle>();
    final timer = Timer(_authenticationTimeout, () {
      if (_isPendingAuthentication(generation, completer)) {
        completer.completeError(
          TimeoutException('Discord account linking timed out.'),
        );
      }
    });
    _authenticationCompleter = completer;
    _authenticationTimer = timer;
    _nativeAuthenticationGeneration = generation;
    unawaited(_forwardAuthentication(generation, completer));
    return completer.future.whenComplete(() {
      timer.cancel();
      if (identical(_authenticationCompleter, completer)) {
        _authenticationCompleter = null;
      }
      if (identical(_authenticationTimer, timer)) {
        _authenticationTimer = null;
      }
    });
  }

  Future<void> _forwardAuthentication(
    int generation,
    Completer<DiscordTokenBundle> completer,
  ) async {
    try {
      final token = await _platform.authenticate();
      if (_isPendingAuthentication(generation, completer)) {
        completer.complete(token);
      }
    } catch (error, stackTrace) {
      if (_isPendingAuthentication(generation, completer)) {
        completer.completeError(error, stackTrace);
      }
    } finally {
      if (_nativeAuthenticationGeneration == generation) {
        _nativeAuthenticationGeneration = null;
      }
    }
  }

  bool _isPendingAuthentication(
    int generation,
    Completer<DiscordTokenBundle> completer,
  ) {
    return _isCurrentAuthentication(generation) &&
        identical(_authenticationCompleter, completer) &&
        !completer.isCompleted;
  }

  bool _isCurrentAuthentication(int generation) {
    return mounted && generation == _authenticationGeneration;
  }

  Future<void> _cancelAuthenticationQuietly() {
    final existing = _authenticationCancellation;
    if (existing != null) return existing;
    _nativeAuthenticationGeneration = null;
    final cancellation = _runAuthenticationCancellation();
    _authenticationCancellation = cancellation;
    return cancellation.whenComplete(() {
      if (identical(_authenticationCancellation, cancellation)) {
        _authenticationCancellation = null;
      }
    });
  }

  Future<void> _runAuthenticationCancellation() async {
    try {
      await _platform.cancelAuthentication();
    } catch (_) {
      // Local lifecycle cleanup must complete even if Android is already
      // destroying Discord's authorization activity.
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (state.busy || !state.linked) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _storage.write(key: _enabledKey, value: enabled.toString());
      if (!enabled) {
        await _platform.disconnect();
        if (!mounted) return;
        state = state.copyWith(
          enabled: false,
          connectionStatus: 'disconnected',
        );
        return;
      }
      final token = await _loadToken();
      if (token == null) throw StateError('Discord needs to be linked again.');
      if (!mounted) return;
      state = state.copyWith(enabled: true);
      await _connect(await _refreshIfNeeded(token));
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(error: _friendly(error));
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> unlinkAccount() async {
    if (state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final token = await _loadToken();
      if (token != null) {
        try {
          await _platform.revoke(token.accessToken);
        } catch (_) {
          // Local unlinking must work even if Discord is temporarily offline.
        }
      } else {
        await _platform.disconnect();
      }
    } finally {
      await _clearToken();
      if (mounted) {
        state = state.copyWith(
          linked: false,
          enabled: false,
          busy: false,
          connectionStatus: 'disconnected',
          clearError: true,
        );
      }
    }
  }

  Future<void> retry() async {
    final token = await _loadToken();
    if (!state.available || !state.enabled || token == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _connect(await _refreshIfNeeded(token, force: true));
    } catch (error) {
      if (mounted) state = state.copyWith(error: _friendly(error));
    } finally {
      if (mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> _connect(DiscordTokenBundle token) async {
    state = state.copyWith(connectionStatus: 'connecting', clearError: true);
    await _platform.connect(token);
    if (mounted) state = state.copyWith(connectionStatus: 'ready');
  }

  Future<DiscordTokenBundle> _refreshIfNeeded(
    DiscordTokenBundle token, {
    bool force = false,
  }) async {
    if (!force && token.expiresAt.isAfter(DateTime.now().add(_refreshWindow))) {
      return token;
    }
    if (_refreshing) return token;
    _refreshing = true;
    try {
      final refreshed = await _platform.refreshToken(token.refreshToken);
      _validateToken(refreshed);
      await _storeToken(refreshed);
      return refreshed;
    } finally {
      _refreshing = false;
    }
  }

  void _handleEvent(DiscordBridgeEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case 'discordConnectionState':
        final status = event.data['status'] as String? ?? 'disconnected';
        final error = (event.data['error'] as String?)?.trim();
        state = state.copyWith(
          connectionStatus: status,
          error: error == null || error.isEmpty ? null : error,
          clearError: error == null || error.isEmpty,
        );
        return;
      case 'discordPresenceError':
        state = state.copyWith(
          error: event.data['error'] as String? ?? 'Discord presence failed.',
        );
        return;
      case 'discordTokenExpiring':
        unawaited(retry());
        return;
    }
  }

  Future<DiscordTokenBundle?> _loadToken() async {
    final values = await Future.wait([
      _storage.read(key: _accessTokenKey),
      _storage.read(key: _refreshTokenKey),
      _storage.read(key: _tokenTypeKey),
      _storage.read(key: _expiresAtKey),
      _storage.read(key: _scopesKey),
    ]);
    final access = values[0]?.trim() ?? '';
    final refresh = values[1]?.trim() ?? '';
    final tokenType = int.tryParse(values[2] ?? '');
    final expiresAt = int.tryParse(values[3] ?? '');
    if (access.isEmpty ||
        refresh.isEmpty ||
        tokenType == null ||
        expiresAt == null) {
      return null;
    }
    return DiscordTokenBundle(
      accessToken: access,
      refreshToken: refresh,
      tokenType: tokenType,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      scopes: values[4] ?? '',
    );
  }

  Future<void> _storeToken(DiscordTokenBundle token) async {
    await runSecureStorageTransaction(
      _storage,
      _credentialKeys.where((key) => key != _enabledKey),
      () => _storeTokenUnchecked(token),
    );
  }

  Future<void> _storeNewToken(
    DiscordTokenBundle token,
    DiscordMinimumAgeConfirmation minimumAgeConfirmation,
  ) async {
    _validateMinimumAgeConfirmation(minimumAgeConfirmation);
    await runSecureStorageTransaction(_storage, _credentialKeys, () async {
      await _storeTokenUnchecked(token);
      await _storage.write(
        key: _minimumAgeConfirmationKey,
        value: minimumAgeConfirmation.encodeForStorage(),
      );
      await _storage.write(key: _enabledKey, value: 'true');
    });
  }

  Future<void> _storeTokenUnchecked(DiscordTokenBundle token) async {
    await _storage.write(key: _accessTokenKey, value: token.accessToken);
    await _storage.write(key: _refreshTokenKey, value: token.refreshToken);
    await _storage.write(key: _tokenTypeKey, value: token.tokenType.toString());
    await _storage.write(
      key: _expiresAtKey,
      value: token.expiresAt.millisecondsSinceEpoch.toString(),
    );
    await _storage.write(key: _scopesKey, value: token.scopes);
  }

  Future<DiscordImportSnapshot> snapshotForImport() async {
    // Do not snapshot a transient authorization/refresh state that cannot be
    // faithfully recreated after rollback. Initialization is finite and safe
    // to await; user-initiated operations must finish before setup is applied.
    await _initialization;
    if (!mounted || state.busy || _refreshing) {
      throw StateError('Discord is already handling another request.');
    }
    return DiscordImportSnapshot._(
      await SecureStorageSnapshot.capture(_storage, _credentialKeys),
      state,
      await _loadToken(),
      state.connected,
    );
  }

  Future<void> restoreImportSnapshot(DiscordImportSnapshot snapshot) async {
    await _abandonAuthenticationForImport();
    await snapshot._storageSnapshot.restore();
    var restoredConnectionStatus = 'disconnected';
    var nativeRestoreFailed = false;
    try {
      await _platform.disconnect();
      final token = snapshot._token;
      if (snapshot.wasConnected &&
          snapshot.state.available &&
          snapshot.state.enabled &&
          token != null) {
        await _platform.connect(token);
        restoredConnectionStatus = 'ready';
      }
    } catch (_) {
      // Encrypted state is authoritative. Report the native mismatch honestly
      // so Settings can retry instead of claiming the old session is ready.
      restoredConnectionStatus = 'disconnected';
      nativeRestoreFailed = true;
    }
    if (mounted) {
      state = snapshot.state.copyWith(
        busy: false,
        connectionStatus: restoredConnectionStatus,
        error: nativeRestoreFailed
            ? 'Discord credentials were restored, but Rich Presence could not reconnect. Use Retry in Settings.'
            : null,
        clearError: !nativeRestoreFailed && snapshot.state.error == null,
      );
    }
  }

  Future<void> _abandonAuthenticationForImport() async {
    final hadPendingNativeAuthentication =
        _nativeAuthenticationGeneration != null;
    _authenticationGeneration++;
    _authenticationTimer?.cancel();
    _authenticationTimer = null;
    final completer = _authenticationCompleter;
    _authenticationCompleter = null;
    _nativeAuthenticationGeneration = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _DiscordAuthenticationAbandoned());
    }
    if (hadPendingNativeAuthentication) {
      await _cancelAuthenticationQuietly();
    }
  }

  Future<void> connectImportedToken() async {
    final token = await _loadToken();
    if (!mounted || !state.available || !state.enabled || token == null) return;
    try {
      await _connect(token).timeout(_deviceConnectionTimeout);
    } catch (error) {
      if (mounted) {
        state = state.copyWith(
          connectionStatus: 'disconnected',
          error: _friendly(error),
        );
      }
    }
  }

  Future<void> _clearToken() async {
    for (final key in const [
      _enabledKey,
      _accessTokenKey,
      _refreshTokenKey,
      _tokenTypeKey,
      _expiresAtKey,
      _scopesKey,
      _minimumAgeConfirmationKey,
    ]) {
      await _storage.delete(key: key);
    }
  }

  void _validateToken(DiscordTokenBundle token) {
    if (token.accessToken.isEmpty || token.refreshToken.isEmpty) {
      throw StateError('Discord did not return a usable account token.');
    }
  }

  void _validateMinimumAgeConfirmation(
    DiscordMinimumAgeConfirmation confirmation,
  ) {
    if (!confirmation.isCurrentAndAccepted) {
      throw StateError(
        'Confirm that you meet Discord\'s minimum age requirement before linking.',
      );
    }
  }

  String _friendly(Object error) {
    final value = switch (error) {
      PlatformException(:final message?) => message,
      _ => error.toString().replaceFirst(RegExp(r'^\w+(?:Exception)?:\s*'), ''),
    };
    return value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim().take(240);
  }

  @override
  void dispose() {
    final hadPendingNativeAuthentication =
        _nativeAuthenticationGeneration != null;
    _authenticationGeneration++;
    _authenticationTimer?.cancel();
    _authenticationTimer = null;
    final completer = _authenticationCompleter;
    _authenticationCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const _DiscordAuthenticationAbandoned());
    }
    if (hadPendingNativeAuthentication) {
      unawaited(_cancelAuthenticationQuietly());
    }
    unawaited(_eventSubscription.cancel());
    super.dispose();
  }
}

const _credentialKeys = [
  DiscordPresenceController._enabledKey,
  DiscordPresenceController._accessTokenKey,
  DiscordPresenceController._refreshTokenKey,
  DiscordPresenceController._tokenTypeKey,
  DiscordPresenceController._expiresAtKey,
  DiscordPresenceController._scopesKey,
  DiscordPresenceController._minimumAgeConfirmationKey,
];

class _DiscordAuthenticationAbandoned implements Exception {
  const _DiscordAuthenticationAbandoned();
}

extension on String {
  String take(int count) => length <= count ? this : substring(0, count);
}
