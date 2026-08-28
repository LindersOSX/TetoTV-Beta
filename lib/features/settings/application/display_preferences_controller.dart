import 'dart:async';

import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const titleLanguagePreferenceStorageKey = 'title_language_preference';

final _strictTitleLanguagePersistenceZoneKey = Object();

final class TitleLanguagePreferenceImportSnapshot {
  const TitleLanguagePreferenceImportSnapshot._(this.state, this._storedValue);

  final TitleLanguagePreference state;
  final String? _storedValue;
}

final class TitleLanguagePreferenceRollbackException implements Exception {
  const TitleLanguagePreferenceRollbackException();

  @override
  String toString() => 'Title-language preference rollback failed.';
}

final titleLanguagePreferenceProvider =
    StateNotifierProvider<
      TitleLanguagePreferenceController,
      TitleLanguagePreference
    >((ref) {
      final controller = TitleLanguagePreferenceController(
        ref.watch(secureStorageProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class TitleLanguagePreferenceController
    extends StateNotifier<TitleLanguagePreference> {
  TitleLanguagePreferenceController(this._storage)
    : super(TitleLanguagePreference.english);

  final FlutterSecureStorage _storage;

  Future<void> load() async {
    try {
      final saved = await _storage.read(key: titleLanguagePreferenceStorageKey);
      if (saved == TitleLanguagePreference.romaji.storageValue) {
        state = TitleLanguagePreference.romaji;
      }
    } catch (_) {
      // The visual preference is non-critical; English remains the default.
    }
  }

  /// Makes storage errors observable only for transactional setup imports.
  Future<T> runWithStrictPersistence<T>(Future<T> Function() operation) {
    return runZoned(
      operation,
      zoneValues: {_strictTitleLanguagePersistenceZoneKey: true},
    );
  }

  Future<TitleLanguagePreferenceImportSnapshot> snapshotForImport() async {
    return TitleLanguagePreferenceImportSnapshot._(
      state,
      await _storage.read(key: titleLanguagePreferenceStorageKey),
    );
  }

  Future<void> restoreImportSnapshot(
    TitleLanguagePreferenceImportSnapshot snapshot,
  ) async {
    try {
      final value = snapshot._storedValue;
      if (value == null) {
        await _storage.delete(key: titleLanguagePreferenceStorageKey);
      } else {
        await _storage.write(
          key: titleLanguagePreferenceStorageKey,
          value: value,
        );
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        const TitleLanguagePreferenceRollbackException(),
        stackTrace,
      );
    } finally {
      if (mounted) state = snapshot.state;
    }
  }

  Future<void> setPreference(TitleLanguagePreference preference) async {
    state = preference;
    final strict = Zone.current[_strictTitleLanguagePersistenceZoneKey] == true;
    try {
      await _storage.write(
        key: titleLanguagePreferenceStorageKey,
        value: preference.storageValue,
      );
    } catch (_) {
      if (strict) rethrow;
      // Keep the in-memory selection even if platform storage is unavailable.
    }
  }

  Future<void> toggle() => setPreference(
    state == TitleLanguagePreference.english
        ? TitleLanguagePreference.romaji
        : TitleLanguagePreference.english,
  );
}
