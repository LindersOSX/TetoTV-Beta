import 'dart:convert';
import 'dart:math';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const localProfileMaximumCount = 20;
const localProfileMaximumDisplayNameLength = 48;
const _localProfileIndexStorageKey = 'local_profile_index_v1';
const _activeLocalProfileStorageKey = 'local_profile_active_v1';

final localProfileServiceProvider = Provider<LocalProfileService>(
  (ref) => LocalProfileService(ref.watch(secureStorageProvider)),
);

final localProfilesControllerProvider =
    StateNotifierProvider<LocalProfilesController, LocalProfilesState>((ref) {
      final controller = LocalProfilesController(
        ref.watch(localProfileServiceProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

@immutable
class LocalProfile {
  const LocalProfile({required this.id, required this.displayName});

  final String id;
  final String displayName;

  Map<String, String> toJson() => {'id': id, 'display_name': displayName};
}

@immutable
class LocalProfilesSnapshot {
  const LocalProfilesSnapshot({this.profiles = const [], this.activeProfileId});

  final List<LocalProfile> profiles;
  final String? activeProfileId;

  LocalProfile? get activeProfile =>
      profiles.where((profile) => profile.id == activeProfileId).firstOrNull;
}

class LocalProfileService {
  LocalProfileService(this._storage, {String Function()? idFactory})
    : _idFactory = idFactory ?? _newLocalProfileId;

  final FlutterSecureStorage _storage;
  final String Function() _idFactory;

  Future<LocalProfilesSnapshot> snapshot() async {
    final profiles = await _readProfiles();
    final activeId = await _storage.read(key: _activeLocalProfileStorageKey);
    final activeProfileId = profiles.any((profile) => profile.id == activeId)
        ? activeId
        : null;
    return LocalProfilesSnapshot(
      profiles: List.unmodifiable(profiles),
      activeProfileId: activeProfileId,
    );
  }

  Future<LocalProfile> create(String displayName) async {
    final safeName = normalizeLocalProfileDisplayName(displayName);
    if (safeName == null) {
      throw const FormatException(
        'Use a name from 1 to 48 characters without an email address.',
      );
    }
    final profiles = await _readProfiles();
    if (profiles.length >= localProfileMaximumCount) {
      throw StateError('This device already has 20 local profiles.');
    }
    if (profiles.any(
      (profile) => profile.displayName.toLowerCase() == safeName.toLowerCase(),
    )) {
      throw StateError('A local profile with that name already exists.');
    }
    var id = _idFactory();
    if (!_validLocalProfileId(id) ||
        profiles.any((profile) => profile.id == id)) {
      id = _newLocalProfileId();
    }
    final profile = LocalProfile(id: id, displayName: safeName);
    final updated = [...profiles, profile]..sort(_compareLocalProfiles);
    await _writeProfiles(updated);
    await _storage.write(key: _activeLocalProfileStorageKey, value: id);
    return profile;
  }

  Future<void> activate(LocalProfile profile) async {
    final profiles = await _readProfiles();
    if (!profiles.any((item) => item.id == profile.id)) {
      throw StateError('That local profile is no longer saved.');
    }
    await _storage.write(key: _activeLocalProfileStorageKey, value: profile.id);
  }

  Future<void> clearSelection() =>
      _storage.delete(key: _activeLocalProfileStorageKey);

  Future<void> delete(LocalProfile profile) async {
    final profiles = await _readProfiles();
    final updated = [
      for (final item in profiles)
        if (item.id != profile.id) item,
    ];
    await _writeProfiles(updated);
    final activeId = await _storage.read(key: _activeLocalProfileStorageKey);
    if (activeId != profile.id) return;
    if (updated.isEmpty) {
      await clearSelection();
    } else {
      await _storage.write(
        key: _activeLocalProfileStorageKey,
        value: updated.first.id,
      );
    }
  }

  Future<List<LocalProfile>> _readProfiles() async {
    final encoded = await _storage.read(key: _localProfileIndexStorageKey);
    if (encoded == null || encoded.isEmpty || encoded.length > 16384) {
      return const [];
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List || decoded.length > localProfileMaximumCount) {
        return const [];
      }
      final profiles = <LocalProfile>[];
      final ids = <String>{};
      final names = <String>{};
      for (final value in decoded) {
        if (value is! Map) continue;
        final id = value['id'];
        final displayName = normalizeLocalProfileDisplayName(
          value['display_name'],
        );
        if (id is! String ||
            !_validLocalProfileId(id) ||
            displayName == null ||
            !ids.add(id) ||
            !names.add(displayName.toLowerCase())) {
          continue;
        }
        profiles.add(LocalProfile(id: id, displayName: displayName));
      }
      profiles.sort(_compareLocalProfiles);
      return profiles;
    } on FormatException {
      return const [];
    }
  }

  Future<void> _writeProfiles(List<LocalProfile> profiles) => _storage.write(
    key: _localProfileIndexStorageKey,
    value: jsonEncode([for (final profile in profiles) profile.toJson()]),
  );
}

@immutable
class LocalProfilesState {
  const LocalProfilesState({
    this.profiles = const [],
    this.activeProfileId,
    this.isLoading = false,
    this.error,
  });

  final List<LocalProfile> profiles;
  final String? activeProfileId;
  final bool isLoading;
  final String? error;

  LocalProfile? get activeProfile =>
      profiles.where((profile) => profile.id == activeProfileId).firstOrNull;
}

class LocalProfilesController extends StateNotifier<LocalProfilesState> {
  LocalProfilesController(this._service) : super(const LocalProfilesState());

  final LocalProfileService _service;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    state = LocalProfilesState(
      profiles: state.profiles,
      activeProfileId: state.activeProfileId,
      isLoading: true,
    );
    try {
      final snapshot = await _service.snapshot();
      if (!mounted || generation != _generation) return;
      state = LocalProfilesState(
        profiles: snapshot.profiles,
        activeProfileId: snapshot.activeProfileId,
      );
    } catch (_) {
      if (!mounted || generation != _generation) return;
      state = LocalProfilesState(
        profiles: state.profiles,
        activeProfileId: state.activeProfileId,
        error: 'Local profiles could not be loaded on this device.',
      );
    }
  }

  Future<bool> create(String displayName) => _mutate(
    () => _service.create(displayName),
    fallbackMessage: 'That local profile could not be created.',
  );

  Future<bool> activate(LocalProfile profile) => _mutate(
    () => _service.activate(profile),
    fallbackMessage: 'That local profile could not be selected.',
  );

  Future<bool> clearSelection() => _mutate(
    _service.clearSelection,
    fallbackMessage: 'The tracker profile could not be selected.',
  );

  Future<bool> delete(LocalProfile profile) => _mutate(
    () => _service.delete(profile),
    fallbackMessage: 'That local profile could not be deleted.',
  );

  Future<bool> _mutate(
    Future<Object?> Function() action, {
    required String fallbackMessage,
  }) async {
    final generation = ++_generation;
    state = LocalProfilesState(
      profiles: state.profiles,
      activeProfileId: state.activeProfileId,
      isLoading: true,
    );
    try {
      await action();
      final snapshot = await _service.snapshot();
      if (!mounted || generation != _generation) return false;
      state = LocalProfilesState(
        profiles: snapshot.profiles,
        activeProfileId: snapshot.activeProfileId,
      );
      return true;
    } on FormatException catch (error) {
      if (!mounted || generation != _generation) return false;
      state = LocalProfilesState(
        profiles: state.profiles,
        activeProfileId: state.activeProfileId,
        error: error.message,
      );
      return false;
    } on StateError catch (error) {
      if (!mounted || generation != _generation) return false;
      state = LocalProfilesState(
        profiles: state.profiles,
        activeProfileId: state.activeProfileId,
        error: error.message,
      );
      return false;
    } catch (_) {
      if (!mounted || generation != _generation) return false;
      state = LocalProfilesState(
        profiles: state.profiles,
        activeProfileId: state.activeProfileId,
        error: fallbackMessage,
      );
      return false;
    }
  }
}

String? normalizeLocalProfileDisplayName(Object? value) {
  if (value is! String) return null;
  final normalized = value
      .trim()
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty ||
      normalized.length > localProfileMaximumDisplayNameLength ||
      RegExp(r'\S+@\S+\.\S+').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

bool _validLocalProfileId(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(value);

String _newLocalProfileId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

int _compareLocalProfiles(LocalProfile left, LocalProfile right) =>
    left.displayName.toLowerCase().compareTo(right.displayName.toLowerCase());
