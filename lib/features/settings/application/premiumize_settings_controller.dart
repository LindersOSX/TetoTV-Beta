import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/streaming/data/premiumize_client.dart';
import 'package:anime_tv/features/streaming/data/premiumize_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef PremiumizeClientFactory = PremiumizeClient Function(String token);

final class PremiumizeImportSnapshot {
  const PremiumizeImportSnapshot._(this._storageSnapshot, this.state);

  final SecureStorageSnapshot _storageSnapshot;
  final PremiumizeSettingsState state;
}

final premiumizeClientFactoryProvider = Provider<PremiumizeClientFactory>(
  (_) =>
      (token) => PremiumizeClient(token: token),
);

final premiumizeSettingsControllerProvider =
    StateNotifierProvider<
      PremiumizeSettingsController,
      PremiumizeSettingsState
    >((ref) {
      final controller = PremiumizeSettingsController(
        ref.watch(secureStorageProvider),
        ref.watch(premiumizeClientFactoryProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class PremiumizeSettingsState {
  const PremiumizeSettingsState({
    this.isLoading = false,
    this.hasSavedToken = false,
    this.account,
    this.errorMessage,
  });

  final bool isLoading;
  final bool hasSavedToken;
  final PremiumizeAccount? account;
  final String? errorMessage;
}

class PremiumizeSettingsController
    extends StateNotifier<PremiumizeSettingsState> {
  PremiumizeSettingsController(this._storage, this._clientFactory)
    : super(const PremiumizeSettingsState());

  final FlutterSecureStorage _storage;
  final PremiumizeClientFactory _clientFactory;

  Future<void> load() async {
    final token = await _storage.read(
      key: DebridService.premiumize.tokenStorageKey,
    );
    if (token == null || token.trim().isEmpty) {
      state = const PremiumizeSettingsState();
      return;
    }
    state = const PremiumizeSettingsState(isLoading: true, hasSavedToken: true);
    await _validate(token.trim(), persist: false);
  }

  Future<bool> saveAndValidate(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      state = const PremiumizeSettingsState(
        errorMessage: 'Enter your Premiumize API key first.',
      );
      return false;
    }
    state = PremiumizeSettingsState(
      isLoading: true,
      hasSavedToken: state.hasSavedToken,
    );
    return _validate(normalized, persist: true);
  }

  Future<bool> _validate(String token, {required bool persist}) async {
    final hadSavedToken = state.hasSavedToken;
    try {
      final account = await _clientFactory(token).account();
      if (!account.isPremium) {
        throw const PremiumizeException(
          'Premiumize torrent streaming requires an active premium plan.',
        );
      }
      if (persist) {
        await _storage.write(
          key: DebridService.premiumize.tokenStorageKey,
          value: token,
        );
      }
      state = PremiumizeSettingsState(hasSavedToken: true, account: account);
      return true;
    } catch (error) {
      state = PremiumizeSettingsState(
        hasSavedToken: hadSavedToken,
        errorMessage: error.toString(),
      );
      return false;
    }
  }

  Future<void> disconnect() async {
    await _storage.delete(key: DebridService.premiumize.tokenStorageKey);
    state = const PremiumizeSettingsState();
  }

  Future<PremiumizeImportSnapshot> snapshotForImport() async {
    return PremiumizeImportSnapshot._(
      await SecureStorageSnapshot.capture(_storage, [
        DebridService.premiumize.tokenStorageKey,
      ]),
      state,
    );
  }

  Future<void> restoreImportSnapshot(PremiumizeImportSnapshot snapshot) async {
    await snapshot._storageSnapshot.restore();
    if (mounted) state = snapshot.state;
  }
}
