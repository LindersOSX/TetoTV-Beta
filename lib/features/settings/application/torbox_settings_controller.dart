import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/core/storage/secure_storage_snapshot.dart';
import 'package:anime_tv/features/streaming/data/torbox_client.dart';
import 'package:anime_tv/features/streaming/data/torbox_models.dart';
import 'package:anime_tv/features/streaming/domain/debrid_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const torBoxTokenStorageKey = 'torbox_api_token';

typedef TorBoxClientFactory = TorBoxClient Function(String token);

final class TorBoxImportSnapshot {
  const TorBoxImportSnapshot._(this._storageSnapshot, this.state);

  final SecureStorageSnapshot _storageSnapshot;
  final TorBoxSettingsState state;
}

final torBoxClientFactoryProvider = Provider<TorBoxClientFactory>(
  (_) =>
      (token) => TorBoxClient(token: token),
);

final torBoxSettingsControllerProvider =
    StateNotifierProvider<TorBoxSettingsController, TorBoxSettingsState>((ref) {
      final controller = TorBoxSettingsController(
        ref.watch(secureStorageProvider),
        ref.watch(torBoxClientFactoryProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class TorBoxSettingsState {
  const TorBoxSettingsState({
    this.isLoading = false,
    this.hasSavedToken = false,
    this.account,
    this.errorMessage,
  });

  final bool isLoading;
  final bool hasSavedToken;
  final TorBoxAccount? account;
  final String? errorMessage;
}

class TorBoxSettingsController extends StateNotifier<TorBoxSettingsState> {
  TorBoxSettingsController(this._storage, this._clientFactory)
    : super(const TorBoxSettingsState());

  final FlutterSecureStorage _storage;
  final TorBoxClientFactory _clientFactory;

  Future<void> load() async {
    final token = await _storage.read(key: torBoxTokenStorageKey);
    if (token == null || token.isEmpty) {
      state = const TorBoxSettingsState();
      return;
    }
    state = const TorBoxSettingsState(isLoading: true, hasSavedToken: true);
    await _validate(token, persist: false);
  }

  Future<bool> saveAndValidate(String token) async {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      state = const TorBoxSettingsState(
        errorMessage: 'Enter your TorBox API token first.',
      );
      return false;
    }
    state = TorBoxSettingsState(
      isLoading: true,
      hasSavedToken: state.hasSavedToken,
    );
    return _validate(normalized, persist: true);
  }

  Future<bool> _validate(String token, {required bool persist}) async {
    final hadSavedToken = state.hasSavedToken;
    try {
      final account = await _clientFactory(token).account();
      if (!account.hasApiStreaming) {
        throw const TorBoxException(
          'TorBox API streaming requires an active paid plan.',
        );
      }
      if (persist) {
        await _storage.write(
          key: DebridService.torBox.tokenStorageKey,
          value: token,
        );
      }
      state = TorBoxSettingsState(hasSavedToken: true, account: account);
      return true;
    } catch (error) {
      state = TorBoxSettingsState(
        hasSavedToken: hadSavedToken,
        errorMessage: error.toString(),
      );
      return false;
    }
  }

  Future<void> disconnect() async {
    await _storage.delete(key: DebridService.torBox.tokenStorageKey);
    state = const TorBoxSettingsState();
  }

  Future<TorBoxImportSnapshot> snapshotForImport() async {
    return TorBoxImportSnapshot._(
      await SecureStorageSnapshot.capture(_storage, [torBoxTokenStorageKey]),
      state,
    );
  }

  Future<void> restoreImportSnapshot(TorBoxImportSnapshot snapshot) async {
    await snapshot._storageSnapshot.restore();
    if (mounted) state = snapshot.state;
  }
}
