import 'dart:async';
import 'dart:convert';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:anime_tv/features/manga/application/manga_preferences_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Identifies a publication across chapters, without persisting either ID.
class MangaReaderSeriesKey {
  const MangaReaderSeriesKey({
    required this.sourceId,
    required this.publicationId,
  });

  final String sourceId;
  final String publicationId;

  @override
  bool operator ==(Object other) =>
      other is MangaReaderSeriesKey &&
      sourceId == other.sourceId &&
      publicationId == other.publicationId;

  @override
  int get hashCode => Object.hash(sourceId, publicationId);
}

/// Only layout is series-specific; display, controls and privacy stay global.
class MangaSeriesReaderPreferences {
  const MangaSeriesReaderPreferences({
    this.enabled = false,
    this.loaded = false,
    this.mode = MangaReadingMode.paged,
    this.direction = MangaReadingDirection.rightToLeft,
    this.spreadMode = MangaSpreadMode.automatic,
    this.pageFit = MangaPageFit.contain,
  });

  final bool enabled;
  final bool loaded;
  final MangaReadingMode mode;
  final MangaReadingDirection direction;
  final MangaSpreadMode spreadMode;
  final MangaPageFit pageFit;

  MangaSeriesReaderPreferences copyWith({
    bool? enabled,
    bool? loaded,
    MangaReadingMode? mode,
    MangaReadingDirection? direction,
    MangaSpreadMode? spreadMode,
    MangaPageFit? pageFit,
  }) => MangaSeriesReaderPreferences(
    enabled: enabled ?? this.enabled,
    loaded: loaded ?? this.loaded,
    mode: mode ?? this.mode,
    direction: direction ?? this.direction,
    spreadMode: spreadMode ?? this.spreadMode,
    pageFit: pageFit ?? this.pageFit,
  );
}

final mangaSeriesReaderPreferencesProvider = StateNotifierProvider.autoDispose
    .family<
      MangaSeriesReaderPreferencesController,
      MangaSeriesReaderPreferences,
      MangaReaderSeriesKey
    >((ref, key) {
      final globalController = ref.read(
        mangaReaderPreferencesProvider.notifier,
      );
      final controller = MangaSeriesReaderPreferencesController(
        ref.watch(secureStorageProvider),
        key,
        globalPreferences: () => ref.read(mangaReaderPreferencesProvider),
        loadGlobalPreferences: globalController.load,
        onSave: (operation) {
          // Chapter navigation may temporarily remove every listener. Retain
          // the optimistic layout until its protected write has settled.
          final link = ref.keepAlive();
          unawaited(operation.whenComplete(link.close));
        },
      );
      ref.listen(mangaReaderPreferencesProvider, (_, _) {
        controller.refreshGlobalDefaults();
      });
      unawaited(controller.load());
      return controller;
    });

final mangaEffectiveReaderPreferencesProvider = Provider.autoDispose
    .family<MangaReaderPreferences, MangaReaderSeriesKey>((ref, key) {
      final global = ref.watch(mangaReaderPreferencesProvider);
      final series = ref.watch(mangaSeriesReaderPreferencesProvider(key));
      if (!series.loaded || !series.enabled) return global;
      return global.copyWith(
        mode: series.mode,
        direction: series.direction,
        spreadMode: series.spreadMode,
        pageFit: series.pageFit,
      );
    });

typedef _SeriesUpdate =
    MangaSeriesReaderPreferences Function(MangaSeriesReaderPreferences current);

class MangaSeriesReaderPreferencesController
    extends StateNotifier<MangaSeriesReaderPreferences> {
  MangaSeriesReaderPreferencesController(
    this._storage,
    MangaReaderSeriesKey key, {
    required MangaReaderPreferences Function() globalPreferences,
    this.loadGlobalPreferences,
    this.onSave,
  }) : _globalPreferences = globalPreferences,
       _storageKey =
           'manga_reader_series_v1_${sha256.convert(utf8.encode(jsonEncode([key.sourceId, key.publicationId])))}',
       super(_defaults(globalPreferences(), loaded: false)) {
    _durableState = state;
  }

  final FlutterSecureStorage _storage;
  final String _storageKey;
  final MangaReaderPreferences Function() _globalPreferences;
  final Future<void> Function()? loadGlobalPreferences;
  final void Function(Future<void>)? onSave;
  late MangaSeriesReaderPreferences _durableState;
  Future<void>? _loading;
  Future<void> _tail = Future<void>.value();
  final Map<int, _SeriesUpdate> _pending = {};
  int _nextOperation = 0;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    await loadGlobalPreferences?.call();
    if (!mounted) return;
    var loaded = _defaults(_globalPreferences());
    try {
      final value = await _storage.read(key: _storageKey);
      if (!mounted) return;
      loaded = _defaults(_globalPreferences());
      if (value != null) {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic> && decoded['enabled'] == true) {
          loaded = loaded.copyWith(
            enabled: true,
            mode: _enumValue(MangaReadingMode.values, decoded['mode']),
            direction: _enumValue(
              MangaReadingDirection.values,
              decoded['direction'],
            ),
            spreadMode: _enumValue(MangaSpreadMode.values, decoded['spread']),
            pageFit: _enumValue(MangaPageFit.values, decoded['fit']),
          );
        }
      }
    } catch (_) {
      // Unavailable or malformed local storage must leave global defaults usable.
    }
    if (!mounted) return;
    _durableState = loaded;
    state = loaded;
  }

  Future<void> setEnabled(bool value) {
    if (!mounted) return Future<void>.value();
    if (!state.loaded) return load().then((_) => setEnabled(value));
    if (value == state.enabled) return Future<void>.value();
    final snapshot = _defaults(_globalPreferences()).copyWith(enabled: value);
    return _save((_) => snapshot);
  }

  /// Selecting a series layout explicitly opts this series into overrides.
  Future<void> setMode(MangaReadingMode value) =>
      _edit((current) => current.copyWith(mode: value));
  Future<void> setDirection(MangaReadingDirection value) =>
      _edit((current) => current.copyWith(direction: value));
  Future<void> setSpreadMode(MangaSpreadMode value) =>
      _edit((current) => current.copyWith(spreadMode: value));
  Future<void> setPageFit(MangaPageFit value) =>
      _edit((current) => current.copyWith(pageFit: value));

  Future<void> reset() => setEnabled(false);

  Future<void> _edit(_SeriesUpdate update) {
    if (!mounted) return Future<void>.value();
    if (!state.loaded) return load().then((_) => _edit(update));
    final defaults = _defaults(_globalPreferences()).copyWith(enabled: true);
    return _save((current) => update(current.enabled ? current : defaults));
  }

  /// Keeps disabled series visibly aligned with changing global preferences.
  void refreshGlobalDefaults() {
    if (!mounted) return;
    if (!_durableState.enabled) {
      _durableState = _defaults(
        _globalPreferences(),
        loaded: _durableState.loaded,
      );
    }
    _publish();
  }

  Future<void> _save(_SeriesUpdate update) {
    final operationId = _nextOperation++;
    _pending[operationId] = update;
    _publish();
    // The single layout record is serialized and rebuilt from confirmed state.
    // Failed writes cannot accidentally persist through a later full snapshot,
    // or erase a different edit that is still pending in the optimistic UI.
    final operation = _tail.then((_) async {
      final next = update(_durableState);
      try {
        if (next.enabled) {
          await _storage.write(
            key: _storageKey,
            value: jsonEncode({
              'enabled': true,
              'mode': next.mode.name,
              'direction': next.direction.name,
              'spread': next.spreadMode.name,
              'fit': next.pageFit.name,
            }),
          );
        } else {
          await _storage.delete(key: _storageKey);
        }
        _durableState = next;
      } catch (_) {
        // Keep the last confirmed layout, then replay only still-pending edits.
      }
      _pending.remove(operationId);
      if (mounted) _publish();
    });
    _tail = operation;
    onSave?.call(operation);
    return operation;
  }

  void _publish() {
    var next = _durableState;
    for (final update in _pending.values) {
      next = update(next);
    }
    state = next.enabled
        ? next
        : _defaults(_globalPreferences(), loaded: next.loaded);
  }
}

MangaSeriesReaderPreferences _defaults(
  MangaReaderPreferences global, {
  bool loaded = true,
}) => MangaSeriesReaderPreferences(
  loaded: loaded,
  mode: global.mode,
  direction: global.direction,
  spreadMode: global.spreadMode,
  pageFit: global.pageFit,
);

T? _enumValue<T extends Enum>(Iterable<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
