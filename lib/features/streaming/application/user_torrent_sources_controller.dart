import 'dart:convert';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/marketplace/domain/addon_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const userTorrentSourceManifestsStorageKey =
    'user_torrent_source_manifest_urls';

final userTorrentSourcesControllerProvider =
    StateNotifierProvider<
      UserTorrentSourcesController,
      UserTorrentSourcesState
    >((ref) {
      final controller = UserTorrentSourcesController(
        ref.watch(secureStorageProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class UserTorrentSourcesState {
  const UserTorrentSourcesState({
    this.manifestUrls = const [],
    this.loaded = false,
    this.errorMessage,
  });

  final List<String> manifestUrls;
  final bool loaded;
  final String? errorMessage;
}

final class UserTorrentSourcesImportSnapshot {
  const UserTorrentSourcesImportSnapshot._(this._storedValue, this.state);

  final String? _storedValue;
  final UserTorrentSourcesState state;
}

final class UserTorrentSourcesRollbackException implements Exception {
  const UserTorrentSourcesRollbackException();

  @override
  String toString() => 'Torrent source rollback failed.';
}

/// Stores only manifests that the user explicitly entered.
///
/// TetoTV intentionally has no source catalog, suggested URL, or automatic
/// installation path. The manifest receives episode identifiers only; debrid
/// tokens stay inside the native debrid clients.
class UserTorrentSourcesController
    extends StateNotifier<UserTorrentSourcesState> {
  UserTorrentSourcesController(
    this._storage, {
    Future<void> Function(Uri uri)? targetValidator,
  }) : _targetValidator = targetValidator ?? validatePublicNetworkTarget,
       super(const UserTorrentSourcesState());

  final FlutterSecureStorage _storage;
  final Future<void> Function(Uri uri) _targetValidator;
  Future<void>? _loadRequest;

  Future<void> load() {
    if (state.loaded) return Future.value();
    final active = _loadRequest;
    if (active != null) return active;
    final request = _performLoad();
    _loadRequest = request;
    return request.whenComplete(() {
      if (identical(_loadRequest, request)) _loadRequest = null;
    });
  }

  Future<void> _performLoad() async {
    try {
      final raw = await _storage.read(
        key: userTorrentSourceManifestsStorageKey,
      );
      final urls = _decode(raw);
      state = UserTorrentSourcesState(manifestUrls: urls, loaded: true);
    } catch (_) {
      state = const UserTorrentSourcesState(
        loaded: true,
        errorMessage: 'Saved torrent sources could not be loaded.',
      );
    }
  }

  Future<String?> add(String rawUrl) async {
    await load();
    final normalized = normalizeUserTorrentManifestUrl(rawUrl);
    if (normalized == null) {
      return 'Enter a public HTTPS Torrent source manifest URL ending in manifest.json.';
    }
    if (state.manifestUrls.contains(normalized)) {
      return 'That torrent source is already added.';
    }
    if (state.manifestUrls.length >= 32) {
      return 'Remove a torrent source before adding another (maximum 32).';
    }
    try {
      await _targetValidator(Uri.parse(normalized));
    } catch (_) {
      return 'The torrent source must resolve to a public HTTPS address.';
    }
    final next = List<String>.unmodifiable([...state.manifestUrls, normalized]);
    await _persist(next);
    return null;
  }

  Future<UserTorrentSourcesImportSnapshot> snapshotForImport() async {
    await load();
    return UserTorrentSourcesImportSnapshot._(
      await _storage.read(key: userTorrentSourceManifestsStorageKey),
      state,
    );
  }

  Future<void> restoreImportSnapshot(
    UserTorrentSourcesImportSnapshot snapshot,
  ) async {
    try {
      final value = snapshot._storedValue;
      if (value == null) {
        await _storage.delete(key: userTorrentSourceManifestsStorageKey);
      } else {
        await _storage.write(
          key: userTorrentSourceManifestsStorageKey,
          value: value,
        );
      }
    } catch (_, stackTrace) {
      Error.throwWithStackTrace(
        const UserTorrentSourcesRollbackException(),
        stackTrace,
      );
    } finally {
      if (mounted) state = snapshot.state;
    }
  }

  Future<BulkSourceAddResult> addAll(String input) async {
    final candidates = splitSourceUrlInput(input);
    if (candidates.isEmpty) {
      return const BulkSourceAddResult(
        added: 0,
        duplicates: 0,
        rejected: ['Enter at least one Torrent source manifest URL.'],
      );
    }
    var added = 0;
    var duplicates = 0;
    final rejected = <String>[];
    for (final candidate in candidates) {
      final error = await add(candidate);
      if (error == null) {
        added++;
      } else if (error.contains('already added')) {
        duplicates++;
      } else {
        rejected.add(error);
      }
    }
    return BulkSourceAddResult(
      added: added,
      duplicates: duplicates,
      rejected: List.unmodifiable(rejected),
    );
  }

  Future<void> remove(String url) async {
    await load();
    final next = List<String>.unmodifiable(
      state.manifestUrls.where((item) => item != url),
    );
    await _persist(next);
  }

  Future<void> _persist(List<String> urls) async {
    await _storage.write(
      key: userTorrentSourceManifestsStorageKey,
      value: jsonEncode(urls),
    );
    state = UserTorrentSourcesState(manifestUrls: urls, loaded: true);
  }

  static List<String> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final unique = <String>{};
    for (final value in decoded.take(32)) {
      final normalized = normalizeUserTorrentManifestUrl(value?.toString());
      if (normalized != null) unique.add(normalized);
    }
    return List<String>.unmodifiable(unique);
  }
}

String? normalizeUserTorrentManifestUrl(String? value) {
  if (value == null) return null;
  final uri = safePublicHttpsUri(value.trim());
  if (uri == null || !uri.path.toLowerCase().endsWith('/manifest.json')) {
    return null;
  }
  return uri.removeFragment().toString();
}
