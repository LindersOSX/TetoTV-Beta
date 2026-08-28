import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/auth/data/real_debrid_oauth_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/real_debrid_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const realDebridTokenStorageKey = 'real_debrid_access_token';
const realDebridRefreshTokenStorageKey = 'real_debrid_refresh_token';
const realDebridClientIdStorageKey = 'real_debrid_oauth_client_id';
const realDebridClientSecretStorageKey = 'real_debrid_oauth_client_secret';
const realDebridAccessExpiryStorageKey = 'real_debrid_access_expiry';

final class RealDebridImportSnapshot {
  const RealDebridImportSnapshot._(this._storageSnapshot, this.state);

  final SecureStorageSnapshot _storageSnapshot;
  final RealDebridSettingsState state;
}

typedef RealDebridClientFactory = RealDebridClient Function(String token);

final realDebridClientFactoryProvider = Provider<RealDebridClientFactory>(
  (_) =>
      (token) => RealDebridClient(token: token),
);

final realDebridSettingsControllerProvider =
    StateNotifierProvider<
      RealDebridSettingsController,
      RealDebridSettingsState
    >((ref) {
      final controller = RealDebridSettingsController(
        ref.watch(secureStorageProvider),
        ref.watch(realDebridClientFactoryProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class RealDebridSettingsState {
  const RealDebridSettingsState({
    this.isLoading = false,
    this.hasSavedToken = false,
    this.account,
    this.errorMessage,
  });

  final bool isLoading;
  final bool hasSavedToken;
  final RealDebridAccount? account;
  final String? errorMessage;

  RealDebridSettingsState copyWith({
    bool? isLoading,
    bool? hasSavedToken,
    RealDebridAccount? account,
    bool clearAccount = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return RealDebridSettingsState(
      isLoading: isLoading ?? this.isLoading,
      hasSavedToken: hasSavedToken ?? this.hasSavedToken,
      account: clearAccount ? null : account ?? this.account,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class RealDebridSettingsController
    extends StateNotifier<RealDebridSettingsState> {
  RealDebridSettingsController(
    this._storage,
    this._clientFactory, {
    RealDebridOAuthClient? oauthClient,
    DateTime Function()? now,
  }) : _oauthClient = oauthClient ?? RealDebridOAuthClient(),
       _now = now ?? DateTime.now,
       super(const RealDebridSettingsState());

  final FlutterSecureStorage _storage;
  final RealDebridClientFactory _clientFactory;
  final RealDebridOAuthClient _oauthClient;
  final DateTime Function() _now;

  Future<void> load() async {
    var token = await _storage.read(key: realDebridTokenStorageKey);
    if (token == null || token.isEmpty) {
      state = const RealDebridSettingsState();
      return;
    }
    state = state.copyWith(
      isLoading: true,
      hasSavedToken: true,
      clearError: true,
    );
    try {
      token = await _refreshIfNeeded(token);
      await _validate(token, persist: false);
    } catch (error) {
      state = RealDebridSettingsState(
        hasSavedToken: true,
        errorMessage: error.toString(),
      );
    }
  }

  Future<bool> saveAndValidate(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      state = state.copyWith(
        errorMessage: 'Enter your Real-Debrid API token first.',
      );
      return false;
    }
    state = state.copyWith(isLoading: true, clearError: true);
    return _validate(normalized, persist: true);
  }

  /// Validates and stores the complete device-OAuth session imported through
  /// encrypted phone setup. Unlike a manually entered API token, this retains
  /// the refresh credentials required for unattended playback renewal.
  Future<bool> saveOAuthAndValidate({
    required String accessToken,
    required String refreshToken,
    required String clientId,
    required String clientSecret,
    required DateTime expiresAt,
  }) async {
    final normalizedAccess = accessToken.trim();
    final normalizedRefresh = refreshToken.trim();
    final normalizedClientId = clientId.trim();
    final normalizedClientSecret = clientSecret.trim();
    if (normalizedAccess.isEmpty ||
        normalizedRefresh.isEmpty ||
        normalizedClientId.isEmpty ||
        normalizedClientSecret.isEmpty) {
      state = state.copyWith(
        errorMessage: 'Real-Debrid authorization is incomplete.',
      );
      return false;
    }
    final hadSavedToken = state.hasSavedToken;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final account = await _clientFactory(normalizedAccess).account();
      if (!account.isPremium) {
        throw const RealDebridException(
          'Real-Debrid streaming requires an active Premium plan.',
        );
      }
      await runSecureStorageTransaction(
        _storage,
        _realDebridCredentialKeys,
        () async {
          await _storage.write(
            key: realDebridRefreshTokenStorageKey,
            value: normalizedRefresh,
          );
          await _storage.write(
            key: realDebridClientIdStorageKey,
            value: normalizedClientId,
          );
          await _storage.write(
            key: realDebridClientSecretStorageKey,
            value: normalizedClientSecret,
          );
          await _storage.write(
            key: realDebridAccessExpiryStorageKey,
            value: expiresAt.toUtc().toIso8601String(),
          );
          await _storage.write(
            key: realDebridTokenStorageKey,
            value: normalizedAccess,
          );
        },
      );
      state = RealDebridSettingsState(hasSavedToken: true, account: account);
      return true;
    } catch (error) {
      state = RealDebridSettingsState(
        hasSavedToken: hadSavedToken,
        errorMessage:
            'Real-Debrid authorization could not be verified or saved securely.',
      );
      return false;
    }
  }

  Future<bool> _validate(String token, {required bool persist}) async {
    final hadSavedToken = state.hasSavedToken;
    try {
      final account = await _clientFactory(token).account();
      if (!account.isPremium) {
        throw const RealDebridException(
          'Real-Debrid streaming requires an active Premium plan.',
        );
      }
      if (persist) {
        // A token entered in Accounts is a standalone API token. Remove any
        // older device-flow metadata so a stale refresh token cannot later
        // overwrite the newly validated manual token.
        await runSecureStorageTransaction(
          _storage,
          _realDebridCredentialKeys,
          () async {
            await _storage.delete(key: realDebridRefreshTokenStorageKey);
            await _storage.delete(key: realDebridClientIdStorageKey);
            await _storage.delete(key: realDebridClientSecretStorageKey);
            await _storage.delete(key: realDebridAccessExpiryStorageKey);
            await _storage.write(key: realDebridTokenStorageKey, value: token);
          },
        );
      }
      state = RealDebridSettingsState(hasSavedToken: true, account: account);
      return true;
    } catch (error) {
      state = RealDebridSettingsState(
        hasSavedToken: hadSavedToken,
        errorMessage: error.toString(),
      );
      return false;
    }
  }

  Future<RealDebridImportSnapshot> snapshotForImport() async {
    return RealDebridImportSnapshot._(
      await SecureStorageSnapshot.capture(_storage, _realDebridCredentialKeys),
      state,
    );
  }

  Future<void> restoreImportSnapshot(RealDebridImportSnapshot snapshot) async {
    await snapshot._storageSnapshot.restore();
    if (mounted) state = snapshot.state;
  }

  Future<void> disconnect() async {
    await Future.wait([
      _storage.delete(key: realDebridTokenStorageKey),
      _storage.delete(key: realDebridRefreshTokenStorageKey),
      _storage.delete(key: realDebridClientIdStorageKey),
      _storage.delete(key: realDebridClientSecretStorageKey),
      _storage.delete(key: realDebridAccessExpiryStorageKey),
    ]);
    state = const RealDebridSettingsState();
  }

  Future<String> _refreshIfNeeded(String currentToken) async {
    final expiryValue = await _storage.read(
      key: realDebridAccessExpiryStorageKey,
    );
    final expiry = expiryValue == null
        ? null
        : DateTime.tryParse(expiryValue)?.toUtc();
    final now = _now().toUtc();
    if (expiry == null || expiry.isAfter(now.add(const Duration(minutes: 5)))) {
      return currentToken;
    }

    final values = await Future.wait([
      _storage.read(key: realDebridClientIdStorageKey),
      _storage.read(key: realDebridClientSecretStorageKey),
      _storage.read(key: realDebridRefreshTokenStorageKey),
    ]);
    if (values.any((value) => value == null || value.isEmpty)) {
      if (expiry.isAfter(now)) return currentToken;
      throw StateError(
        'Real-Debrid authorization expired. Reconnect Real-Debrid in Accounts.',
      );
    }

    late final RealDebridTokenSet tokens;
    try {
      tokens = await _oauthClient.refresh(
        clientId: values[0]!,
        clientSecret: values[1]!,
        refreshToken: values[2]!,
      );
    } catch (_) {
      // Match the playback token service: a transient OAuth outage must not
      // make a still-valid account appear disconnected in Settings.
      if (expiry.isAfter(now)) return currentToken;
      rethrow;
    }
    await _storage.write(
      key: realDebridRefreshTokenStorageKey,
      value: tokens.refreshToken,
    );
    await _storage.write(
      key: realDebridTokenStorageKey,
      value: tokens.accessToken,
    );
    await _storage.write(
      key: realDebridAccessExpiryStorageKey,
      value: tokens.expiresAt.toUtc().toIso8601String(),
    );
    return tokens.accessToken;
  }
}

const _realDebridCredentialKeys = [
  realDebridTokenStorageKey,
  realDebridRefreshTokenStorageKey,
  realDebridClientIdStorageKey,
  realDebridClientSecretStorageKey,
  realDebridAccessExpiryStorageKey,
];
