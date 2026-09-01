import 'dart:async';

import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum MangaReadingMode { paged, vertical, webtoon }

extension MangaReadingModeLabel on MangaReadingMode {
  String get displayName => switch (this) {
    MangaReadingMode.paged => 'Paged',
    MangaReadingMode.vertical => 'Vertical',
    MangaReadingMode.webtoon => 'Webtoon',
  };
}

enum MangaReadingDirection { rightToLeft, leftToRight }

extension MangaReadingDirectionLabel on MangaReadingDirection {
  String get displayName => switch (this) {
    MangaReadingDirection.rightToLeft => 'Right to left',
    MangaReadingDirection.leftToRight => 'Left to right',
  };
}

enum MangaSpreadMode { automatic, single, double }

extension MangaSpreadModeLabel on MangaSpreadMode {
  String get displayName => switch (this) {
    MangaSpreadMode.automatic => 'Automatic',
    MangaSpreadMode.single => 'Single page',
    MangaSpreadMode.double => 'Double page',
  };
}

enum MangaPageFit { contain, width, height }

extension MangaPageFitLabel on MangaPageFit {
  String get displayName => switch (this) {
    MangaPageFit.contain => 'Fit page',
    MangaPageFit.width => 'Fit width',
    MangaPageFit.height => 'Fit height',
  };
}

enum MangaReaderBackground { black, charcoal, white }

extension MangaReaderBackgroundValue on MangaReaderBackground {
  int get colorValue => switch (this) {
    MangaReaderBackground.black => 0xFF000000,
    MangaReaderBackground.charcoal => 0xFF17181B,
    MangaReaderBackground.white => 0xFFFFFFFF,
  };

  String get displayName => switch (this) {
    MangaReaderBackground.black => 'Black',
    MangaReaderBackground.charcoal => 'Charcoal',
    MangaReaderBackground.white => 'White',
  };
}

class MangaReaderPreferences {
  const MangaReaderPreferences({
    this.mode = MangaReadingMode.paged,
    this.direction = MangaReadingDirection.rightToLeft,
    this.spreadMode = MangaSpreadMode.automatic,
    this.pageFit = MangaPageFit.contain,
    this.background = MangaReaderBackground.black,
    this.pageGap = 12,
    this.preloadPages = 2,
    this.coverStartsAlone = true,
    this.invertDoublePages = false,
    this.tapZonesEnabled = true,
    this.bookAnimationEnabled = true,
    this.keepScreenAwake = true,
    this.showDiscordTitle = true,
    this.loaded = false,
  });

  final MangaReadingMode mode;
  final MangaReadingDirection direction;
  final MangaSpreadMode spreadMode;
  final MangaPageFit pageFit;
  final MangaReaderBackground background;
  final double pageGap;
  final int preloadPages;
  final bool coverStartsAlone;
  final bool invertDoublePages;
  final bool tapZonesEnabled;
  final bool bookAnimationEnabled;
  final bool keepScreenAwake;

  /// When false, Discord receives only the generic phrase "Reading manga".
  final bool showDiscordTitle;
  final bool loaded;

  MangaReaderPreferences copyWith({
    MangaReadingMode? mode,
    MangaReadingDirection? direction,
    MangaSpreadMode? spreadMode,
    MangaPageFit? pageFit,
    MangaReaderBackground? background,
    double? pageGap,
    int? preloadPages,
    bool? coverStartsAlone,
    bool? invertDoublePages,
    bool? tapZonesEnabled,
    bool? bookAnimationEnabled,
    bool? keepScreenAwake,
    bool? showDiscordTitle,
    bool? loaded,
  }) => MangaReaderPreferences(
    mode: mode ?? this.mode,
    direction: direction ?? this.direction,
    spreadMode: spreadMode ?? this.spreadMode,
    pageFit: pageFit ?? this.pageFit,
    background: background ?? this.background,
    pageGap: pageGap ?? this.pageGap,
    preloadPages: preloadPages ?? this.preloadPages,
    coverStartsAlone: coverStartsAlone ?? this.coverStartsAlone,
    invertDoublePages: invertDoublePages ?? this.invertDoublePages,
    tapZonesEnabled: tapZonesEnabled ?? this.tapZonesEnabled,
    bookAnimationEnabled: bookAnimationEnabled ?? this.bookAnimationEnabled,
    keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
    showDiscordTitle: showDiscordTitle ?? this.showDiscordTitle,
    loaded: loaded ?? this.loaded,
  );
}

final mangaReaderPreferencesProvider =
    StateNotifierProvider<
      MangaReaderPreferencesController,
      MangaReaderPreferences
    >((ref) {
      final controller = MangaReaderPreferencesController(
        ref.watch(secureStorageProvider),
      );
      unawaited(controller.load());
      return controller;
    });

class MangaReaderPreferencesController
    extends StateNotifier<MangaReaderPreferences> {
  MangaReaderPreferencesController(this._storage)
    : _durableState = const MangaReaderPreferences(),
      super(const MangaReaderPreferences());

  static const _prefix = 'manga_reader_v1_';
  final FlutterSecureStorage _storage;
  MangaReaderPreferences _durableState;
  final Map<String, Future<void>> _writeTails = <String, Future<void>>{};
  final Map<String, int> _writeVersions = <String, int>{};
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load().whenComplete(() {
    _loading = null;
  });

  Future<void> _load() async {
    final values = await Future.wait([
      _read('mode'),
      _read('direction'),
      _read('spread'),
      _read('fit'),
      _read('background'),
      _read('gap'),
      _read('preload'),
      _read('cover_alone'),
      _read('invert_spread'),
      _read('tap_zones'),
      _read('book_animation'),
      _read('keep_awake'),
      _read('discord_title'),
    ]);
    if (!mounted) return;
    final loaded = MangaReaderPreferences(
      mode:
          _enumValue(MangaReadingMode.values, values[0]) ?? _durableState.mode,
      direction:
          _enumValue(MangaReadingDirection.values, values[1]) ??
          _durableState.direction,
      spreadMode:
          _enumValue(MangaSpreadMode.values, values[2]) ??
          _durableState.spreadMode,
      pageFit:
          _enumValue(MangaPageFit.values, values[3]) ?? _durableState.pageFit,
      background:
          _enumValue(MangaReaderBackground.values, values[4]) ??
          _durableState.background,
      pageGap: _boundedDouble(values[5], 0, 40, _durableState.pageGap),
      preloadPages: _boundedInt(values[6], 0, 5, _durableState.preloadPages),
      coverStartsAlone: _bool(values[7], _durableState.coverStartsAlone),
      invertDoublePages: _bool(values[8], _durableState.invertDoublePages),
      tapZonesEnabled: _bool(values[9], _durableState.tapZonesEnabled),
      bookAnimationEnabled: _bool(
        values[10],
        _durableState.bookAnimationEnabled,
      ),
      keepScreenAwake: _bool(values[11], _durableState.keepScreenAwake),
      showDiscordTitle: _bool(values[12], _durableState.showDiscordTitle),
      loaded: true,
    );
    _durableState = loaded;
    state = loaded;
  }

  Future<void> setMode(MangaReadingMode value) =>
      _save((current) => current.copyWith(mode: value), 'mode', value.name);
  Future<void> setDirection(MangaReadingDirection value) => _save(
    (current) => current.copyWith(direction: value),
    'direction',
    value.name,
  );
  Future<void> setSpreadMode(MangaSpreadMode value) => _save(
    (current) => current.copyWith(spreadMode: value),
    'spread',
    value.name,
  );
  Future<void> setPageFit(MangaPageFit value) =>
      _save((current) => current.copyWith(pageFit: value), 'fit', value.name);
  Future<void> setBackground(MangaReaderBackground value) => _save(
    (current) => current.copyWith(background: value),
    'background',
    value.name,
  );
  Future<void> setPageGap(double value) {
    final bounded = value.clamp(0, 40).toDouble();
    return _save(
      (current) => current.copyWith(pageGap: bounded),
      'gap',
      '$bounded',
    );
  }

  Future<void> setPreloadPages(int value) {
    final bounded = value.clamp(0, 5);
    return _save(
      (current) => current.copyWith(preloadPages: bounded),
      'preload',
      '$bounded',
    );
  }

  Future<void> setCoverStartsAlone(bool value) => _save(
    (current) => current.copyWith(coverStartsAlone: value),
    'cover_alone',
    '$value',
  );
  Future<void> setInvertDoublePages(bool value) => _save(
    (current) => current.copyWith(invertDoublePages: value),
    'invert_spread',
    '$value',
  );
  Future<void> setTapZonesEnabled(bool value) => _save(
    (current) => current.copyWith(tapZonesEnabled: value),
    'tap_zones',
    '$value',
  );
  Future<void> setBookAnimationEnabled(bool value) => _save(
    (current) => current.copyWith(bookAnimationEnabled: value),
    'book_animation',
    '$value',
  );
  Future<void> setKeepScreenAwake(bool value) => _save(
    (current) => current.copyWith(keepScreenAwake: value),
    'keep_awake',
    '$value',
  );
  Future<void> setShowDiscordTitle(bool value) => _save(
    (current) => current.copyWith(showDiscordTitle: value),
    'discord_title',
    '$value',
  );

  Future<void> reset() async {
    for (final key in const [
      'mode',
      'direction',
      'spread',
      'fit',
      'background',
      'gap',
      'preload',
      'cover_alone',
      'invert_spread',
      'tap_zones',
      'book_animation',
      'keep_awake',
      'discord_title',
    ]) {
      await _storage.delete(key: '$_prefix$key');
    }
    if (mounted) {
      _durableState = const MangaReaderPreferences(loaded: true);
      state = _durableState;
    }
  }

  Future<void> _save(
    MangaReaderPreferences Function(MangaReaderPreferences current) update,
    String key,
    String value,
  ) {
    final loading = _loading;
    if (loading != null) {
      return loading.then((_) => _save(update, key, value));
    }
    state = update(state);
    final version = (_writeVersions[key] ?? 0) + 1;
    _writeVersions[key] = version;
    final previous = _writeTails[key] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous.then((_) async {
      try {
        await _storage.write(key: '$_prefix$key', value: value);
        _durableState = update(_durableState);
      } catch (_) {
        // Reader controls are optimistic so they remain responsive. If the
        // protected write fails, restore only this setting from the last
        // confirmed state. A newer queued value for the same setting owns the
        // UI until its own write succeeds or rolls back.
        if (mounted && _writeVersions[key] == version) {
          state = _restorePreferenceKey(state, _durableState, key);
        }
      }
    });
    _writeTails[key] = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_writeTails[key], operation)) {
          _writeTails.remove(key);
        }
      }),
    );
    return operation;
  }

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: '$_prefix$key');
    } catch (_) {
      return null;
    }
  }
}

MangaReaderPreferences _restorePreferenceKey(
  MangaReaderPreferences current,
  MangaReaderPreferences durable,
  String key,
) => switch (key) {
  'mode' => current.copyWith(mode: durable.mode),
  'direction' => current.copyWith(direction: durable.direction),
  'spread' => current.copyWith(spreadMode: durable.spreadMode),
  'fit' => current.copyWith(pageFit: durable.pageFit),
  'background' => current.copyWith(background: durable.background),
  'gap' => current.copyWith(pageGap: durable.pageGap),
  'preload' => current.copyWith(preloadPages: durable.preloadPages),
  'cover_alone' => current.copyWith(coverStartsAlone: durable.coverStartsAlone),
  'invert_spread' => current.copyWith(
    invertDoublePages: durable.invertDoublePages,
  ),
  'tap_zones' => current.copyWith(tapZonesEnabled: durable.tapZonesEnabled),
  'book_animation' => current.copyWith(
    bookAnimationEnabled: durable.bookAnimationEnabled,
  ),
  'keep_awake' => current.copyWith(keepScreenAwake: durable.keepScreenAwake),
  'discord_title' => current.copyWith(
    showDiscordTitle: durable.showDiscordTitle,
  ),
  _ => durable,
};

T? _enumValue<T extends Enum>(Iterable<T> values, String? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

bool _bool(String? value, bool fallback) => switch (value) {
  'true' => true,
  'false' => false,
  _ => fallback,
};

double _boundedDouble(String? value, double min, double max, double fallback) {
  final parsed = double.tryParse(value ?? '');
  return parsed == null ? fallback : parsed.clamp(min, max).toDouble();
}

int _boundedInt(String? value, int min, int max, int fallback) {
  final parsed = int.tryParse(value ?? '');
  return parsed == null ? fallback : parsed.clamp(min, max);
}
