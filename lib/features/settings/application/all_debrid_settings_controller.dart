import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_client.dart';
import 'package:anime_tv/features/streaming/data/all_debrid_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef AllDebridClientFactory = AllDebridClient Function(String token);

final class AllDebridImportSnapshot {
  const AllDebridImportSnapshot._(this._storageSnapshot, this.state);

  final SecureStorageSnapshot _storageSnapshot;
  final AllDebridSettingsState state;
}

final allDebridClientFactoryProvider = Provider<AllDebridClientFactory>(
  (_) =>
      (token) => AllDebridClient(token: token),
);

final allDebridSettingsControllerProvider =
    StateNotifierProvider<AllDebridSettingsController, AllDebridSettingsState>((
      ref,
    ) {
      final controller = AllDebridSettingsController(
        ref.watch(secureStorageProvider),
        ref.watch(allDebridClientFactoryProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class AllDebridSettingsState {
  const AllDebridSettingsState({
    this.isLoading = false,
    this.hasSavedToken = false,
    this.account,
    this.errorMessage,
  });

  final bool isLoading;
  final bool hasSavedToken;
  final AllDebridAccount? account;
  final String? errorMessage;
}

class AllDebridSettingsController
    extends StateNotifier<AllDebridSettingsState> {
  AllDebridSettingsController(this._storage, this._clientFactory)
    : super(const AllDebridSettingsState());

  final FlutterSecureStorage _storage;
  final AllDebridClientFactory _clientFactory;

  Future<void> load() async {
    final token = await _storage.read(
      key: DebridService.allDebrid.tokenStorageKey,
    );
    if (token == null || token.trim().isEmpty) {
      state = const AllDebridSettingsState();
      return;
    }
    state = const AllDebridSettingsState(isLoading: true, hasSavedToken: true);
    await _validate(token.trim(), persist: false);
  }

  Future<bool> saveAndValidate(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      state = const AllDebridSettingsState(
        errorMessage: 'Enter your AllDebrid API key first.',
      );
      return false;
    }
    state = AllDebridSettingsState(
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
        throw const AllDebridException(
          'AllDebrid torrent streaming requires a premium account.',
        );
      }
      if (persist) {
        await _storage.write(
          key: DebridService.allDebrid.tokenStorageKey,
          value: token,
        );
      }
      state = AllDebridSettingsState(hasSavedToken: true, account: account);
      return true;
    } catch (error) {
      state = AllDebridSettingsState(
        hasSavedToken: hadSavedToken,
        errorMessage: error.toString(),
      );
      return false;
    }
  }

  Future<void> disconnect() async {
    await _storage.delete(key: DebridService.allDebrid.tokenStorageKey);
    state = const AllDebridSettingsState();
  }

  Future<AllDebridImportSnapshot> snapshotForImport() async {
    return AllDebridImportSnapshot._(
      await SecureStorageSnapshot.capture(_storage, [
        DebridService.allDebrid.tokenStorageKey,
      ]),
      state,
    );
  }

  Future<void> restoreImportSnapshot(AllDebridImportSnapshot snapshot) async {
    await snapshot._storageSnapshot.restore();
    if (mounted) state = snapshot.state;
  }
}
