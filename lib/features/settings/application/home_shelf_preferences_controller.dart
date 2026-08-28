import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Default order intentionally keeps Continue Watching first.
enum HomeShelf {
  tracking,
  history,
  recentlyReleased,
  trending,
  planned,
  airing,
  completed,
}

extension HomeShelfLabel on HomeShelf {
  String get displayName => switch (this) {
    HomeShelf.tracking => 'Continue watching',
    HomeShelf.history => 'Watch history',
    HomeShelf.recentlyReleased => 'Recently released',
    HomeShelf.trending => 'Trending now',
    HomeShelf.planned => 'Plan to watch',
    HomeShelf.airing => 'Airing soon',
    HomeShelf.completed => 'Recently completed',
  };
}

const _legacyEnabledStorageKey = 'home_shelves_v1';
const _enabledStorageKey = 'home_shelves_v2';
const _orderStorageKey = 'home_shelf_order_v1';

final homeShelfPreferencesProvider =
    StateNotifierProvider<HomeShelfPreferencesController, Set<HomeShelf>>((
      ref,
    ) {
      final controller = HomeShelfPreferencesController(
        ref.watch(secureStorageProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

final homeShelfOrderProvider =
    StateNotifierProvider<HomeShelfOrderController, List<HomeShelf>>((ref) {
      final controller = HomeShelfOrderController(
        ref.watch(secureStorageProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

class HomeShelfPreferencesController extends StateNotifier<Set<HomeShelf>> {
  HomeShelfPreferencesController(this._storage, {this.readValue})
    : super(Set.unmodifiable(HomeShelf.values));

  final FlutterSecureStorage _storage;
  final Future<String?> Function(String key)? readValue;
  Future<void>? _loadFuture;
  int _revision = 0;

  /// Loads once at a time and never replaces a choice made while storage is
  /// still responding. This matters on slower TV devices where the Settings
  /// screen can become interactive before encrypted storage has finished.
  Future<void> load() => _loadFuture ??= _load().whenComplete(() {
    _loadFuture = null;
  });

  Future<void> _load() async {
    final revisionAtStart = _revision;
    try {
      final current = await _read(_enabledStorageKey);
      final legacy = current == null
          ? await _read(_legacyEnabledStorageKey)
          : null;
      final saved = current ?? legacy;
      if (saved == null || saved.isEmpty) return;
      final names = saved.split(',').toSet();
      // Recently released was always visible before shelves became reorderable.
      // Keep it visible while migrating an old v1 set.
      if (current == null) names.add(HomeShelf.recentlyReleased.name);
      if (_revision != revisionAtStart) return;
      state = Set.unmodifiable(
        HomeShelf.values.where((shelf) => names.contains(shelf.name)),
      );
      if (current == null) await _persist();
    } catch (_) {
      // All shelves remain enabled when device storage is unavailable.
    }
  }

  Future<void> toggle(HomeShelf shelf) async {
    _revision++;
    final next = {...state};
    next.contains(shelf) ? next.remove(shelf) : next.add(shelf);
    state = Set.unmodifiable(next);
    await _persist();
  }

  Future<void> reset() async {
    _revision++;
    state = Set.unmodifiable(HomeShelf.values);
    try {
      await _storage.delete(key: _enabledStorageKey);
      await _storage.delete(key: _legacyEnabledStorageKey);
    } catch (_) {
      // The in-memory default remains useful for this session.
    }
  }

  Future<String?> _read(String key) =>
      readValue?.call(key) ?? _storage.read(key: key);

  Future<void> _persist() async {
    try {
      await _storage.write(
        key: _enabledStorageKey,
        value: state.map((item) => item.name).join(','),
      );
    } catch (_) {
      // The in-memory choice is still useful for this session.
    }
  }
}

class HomeShelfOrderController extends StateNotifier<List<HomeShelf>> {
  HomeShelfOrderController(this._storage, {this.readValue})
    : super(List.unmodifiable(HomeShelf.values));

  final FlutterSecureStorage _storage;
  final Future<String?> Function(String key)? readValue;
  Future<void>? _loadFuture;
  int _revision = 0;

  Future<void> load() => _loadFuture ??= _load().whenComplete(() {
    _loadFuture = null;
  });

  Future<void> _load() async {
    final revisionAtStart = _revision;
    try {
      final saved = await _read(_orderStorageKey);
      if (saved == null || saved.isEmpty) return;
      final names = saved.split(',');
      final restored = <HomeShelf>[];
      for (final name in names) {
        HomeShelf? shelf;
        for (final candidate in HomeShelf.values) {
          if (candidate.name == name) {
            shelf = candidate;
            break;
          }
        }
        if (shelf != null && !restored.contains(shelf)) restored.add(shelf);
      }
      for (final shelf in HomeShelf.values) {
        if (!restored.contains(shelf)) restored.add(shelf);
      }
      if (_revision != revisionAtStart) return;
      state = List.unmodifiable(restored);
    } catch (_) {
      // Default order remains usable when device storage is unavailable.
    }
  }

  Future<void> move(HomeShelf shelf, int offset) async {
    final currentIndex = state.indexOf(shelf);
    if (currentIndex < 0) return;
    final nextIndex = (currentIndex + offset).clamp(0, state.length - 1);
    if (nextIndex == currentIndex) return;
    final next = [...state]..removeAt(currentIndex);
    next.insert(nextIndex, shelf);
    _revision++;
    state = List.unmodifiable(next);
    await _persist();
  }

  Future<void> reset() async {
    _revision++;
    state = List.unmodifiable(HomeShelf.values);
    try {
      await _storage.delete(key: _orderStorageKey);
    } catch (_) {
      // The in-memory default remains useful for this session.
    }
  }

  Future<String?> _read(String key) =>
      readValue?.call(key) ?? _storage.read(key: key);

  Future<void> _persist() async {
    try {
      await _storage.write(
        key: _orderStorageKey,
        value: state.map((item) => item.name).join(','),
      );
    } catch (_) {
      // The in-memory order is still useful for this session.
    }
  }
}
