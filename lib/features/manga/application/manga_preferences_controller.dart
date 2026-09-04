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

enum MangaTapZoneLayout { thirds, edges }

extension MangaTapZoneLayoutLabel on MangaTapZoneLayout {
  String get displayName => switch (this) {
    MangaTapZoneLayout.thirds => 'Thirds',
    MangaTapZoneLayout.edges => 'Edges',
  };
}

enum MangaReaderBackground { black, charcoal, white, sepia }

extension MangaReaderBackgroundValue on MangaReaderBackground {
  int get colorValue => switch (this) {
    MangaReaderBackground.black => 0xFF000000,
    MangaReaderBackground.charcoal => 0xFF17181B,
    MangaReaderBackground.white => 0xFFFFFFFF,
    MangaReaderBackground.sepia => 0xFFF1E7D0,
  };

  String get displayName => switch (this) {
    MangaReaderBackground.black => 'Black',
    MangaReaderBackground.charcoal => 'Charcoal',
    MangaReaderBackground.white => 'White',
    MangaReaderBackground.sepia => 'Sepia',
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
    this.sidePadding = 0,
    this.webtoonGap = 0,
    this.dimAmount = 0,
    this.warmth = 0,
    this.grayscale = false,
    this.invertColors = false,
    this.showPageNumber = true,
    this.doubleTapZoom = true,
    this.tapZoneLayout = MangaTapZoneLayout.thirds,
    this.invertTapZones = false,
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
  final double sidePadding;
  final double webtoonGap;
  final double dimAmount;
  final double warmth;
  final bool grayscale;
  final bool invertColors;
  final bool showPageNumber;
  final bool doubleTapZoom;
  final MangaTapZoneLayout tapZoneLayout;
  final bool invertTapZones;
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
    double? sidePadding,
    double? webtoonGap,
    double? dimAmount,
    double? warmth,
    bool? grayscale,
    bool? invertColors,
    bool? showPageNumber,
    bool? doubleTapZoom,
    MangaTapZoneLayout? tapZoneLayout,
    bool? invertTapZones,
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
    sidePadding: sidePadding ?? this.sidePadding,
    webtoonGap: webtoonGap ?? this.webtoonGap,
    dimAmount: dimAmount ?? this.dimAmount,
    warmth: warmth ?? this.warmth,
    grayscale: grayscale ?? this.grayscale,
    invertColors: invertColors ?? this.invertColors,
    showPageNumber: showPageNumber ?? this.showPageNumber,
    doubleTapZoom: doubleTapZoom ?? this.doubleTapZoom,
    tapZoneLayout: tapZoneLayout ?? this.tapZoneLayout,
    invertTapZones: invertTapZones ?? this.invertTapZones,
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
  static const _keys = [
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
    'side_padding',
    'webtoon_gap',
    'dim_amount',
    'warmth',
    'grayscale',
    'invert_colors',
    'page_number',
    'double_tap_zoom',
    'tap_zone_layout',
    'invert_tap_zones',
  ];
  final FlutterSecureStorage _storage;
  MangaReaderPreferences _durableState;
  final Map<String, Future<void>> _writeTails = <String, Future<void>>{};
  final Map<String, int> _writeVersions = <String, int>{};
  Future<void>? _loading;

  // Loading is intentionally idempotent. A later reload must not replace
  // optimistic edits with storage reads that began before their writes.
  Future<void> load() =>
      _loading ??= state.loaded ? Future<void>.value() : _load();

  Future<void> _load() async {
    final values = await Future.wait(_keys.map(_read));
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
      sidePadding: _boundedDouble(values[13], 0, 80, _durableState.sidePadding),
      webtoonGap: _boundedDouble(values[14], 0, 40, _durableState.webtoonGap),
      dimAmount: _boundedDouble(values[15], 0, .7, _durableState.dimAmount),
      warmth: _boundedDouble(values[16], 0, 1, _durableState.warmth),
      grayscale: _bool(values[17], _durableState.grayscale),
      invertColors: _bool(values[18], _durableState.invertColors),
      showPageNumber: _bool(values[19], _durableState.showPageNumber),
      doubleTapZoom: _bool(values[20], _durableState.doubleTapZoom),
      tapZoneLayout:
          _enumValue(MangaTapZoneLayout.values, values[21]) ??
          _durableState.tapZoneLayout,
      invertTapZones: _bool(values[22], _durableState.invertTapZones),
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
    final bounded = _finiteBound(value, 0, 40, 12);
    return _save(
      (current) => current.copyWith(pageGap: bounded),
      'gap',
      '$bounded',
    );
  }

  Future<void> setSidePadding(double value) {
    final bounded = _finiteBound(value, 0, 80, 0);
    return _save(
      (current) => current.copyWith(sidePadding: bounded),
      'side_padding',
      '$bounded',
    );
  }

  Future<void> setWebtoonGap(double value) {
    final bounded = _finiteBound(value, 0, 40, 0);
    return _save(
      (current) => current.copyWith(webtoonGap: bounded),
      'webtoon_gap',
      '$bounded',
    );
  }

  Future<void> setDimAmount(double value) {
    final bounded = _finiteBound(value, 0, .7, 0);
    return _save(
      (current) => current.copyWith(dimAmount: bounded),
      'dim_amount',
      '$bounded',
    );
  }

  Future<void> setWarmth(double value) {
    final bounded = _finiteBound(value, 0, 1, 0);
    return _save(
      (current) => current.copyWith(warmth: bounded),
      'warmth',
      '$bounded',
    );
  }

  Future<void> setGrayscale(bool value) => _save(
    (current) => current.copyWith(grayscale: value),
    'grayscale',
    '$value',
  );
  Future<void> setInvertColors(bool value) => _save(
    (current) => current.copyWith(invertColors: value),
    'invert_colors',
    '$value',
  );
  Future<void> setShowPageNumber(bool value) => _save(
    (current) => current.copyWith(showPageNumber: value),
    'page_number',
    '$value',
  );
  Future<void> setDoubleTapZoom(bool value) => _save(
    (current) => current.copyWith(doubleTapZoom: value),
    'double_tap_zoom',
    '$value',
  );
  Future<void> setTapZoneLayout(MangaTapZoneLayout value) => _save(
    (current) => current.copyWith(tapZoneLayout: value),
    'tap_zone_layout',
    value.name,
  );
  Future<void> setInvertTapZones(bool value) => _save(
    (current) => current.copyWith(invertTapZones: value),
    'invert_tap_zones',
    '$value',
  );

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

  Future<void> reset() {
    if (!mounted) return Future<void>.value();
    if (!state.loaded) return load().then((_) => reset());
    const defaults = MangaReaderPreferences(loaded: true);
    // Deletions share each setting's write queue: old saves finish before the
    // reset, and new saves finish after it. Failure restores only its own key.
    return Future.wait(
      _keys.map(
        (key) => _save(
          (current) => _restorePreferenceKey(current, defaults, key),
          key,
          null,
        ),
      ),
    ).then((_) {});
  }

  Future<void> _save(
    MangaReaderPreferences Function(MangaReaderPreferences current) update,
    String key,
    String? value,
  ) {
    if (!mounted) return Future<void>.value();
    if (!state.loaded) return load().then((_) => _save(update, key, value));
    state = update(state);
    final version = (_writeVersions[key] ?? 0) + 1;
    _writeVersions[key] = version;
    final previous = _writeTails[key] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous.then((_) async {
      try {
        if (value == null) {
          await _storage.delete(key: '$_prefix$key');
        } else {
          await _storage.write(key: '$_prefix$key', value: value);
        }
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
  'side_padding' => current.copyWith(sidePadding: durable.sidePadding),
  'webtoon_gap' => current.copyWith(webtoonGap: durable.webtoonGap),
  'dim_amount' => current.copyWith(dimAmount: durable.dimAmount),
  'warmth' => current.copyWith(warmth: durable.warmth),
  'grayscale' => current.copyWith(grayscale: durable.grayscale),
  'invert_colors' => current.copyWith(invertColors: durable.invertColors),
  'page_number' => current.copyWith(showPageNumber: durable.showPageNumber),
  'double_tap_zoom' => current.copyWith(doubleTapZoom: durable.doubleTapZoom),
  'tap_zone_layout' => current.copyWith(tapZoneLayout: durable.tapZoneLayout),
  'invert_tap_zones' => current.copyWith(
    invertTapZones: durable.invertTapZones,
  ),
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
  _ => current,
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
  return parsed == null ? fallback : _finiteBound(parsed, min, max, fallback);
}

double _finiteBound(double value, double min, double max, double fallback) =>
    value.isFinite ? value.clamp(min, max).toDouble() : fallback;

int _boundedInt(String? value, int min, int max, int fallback) {
  final parsed = int.tryParse(value ?? '');
  return parsed == null ? fallback : parsed.clamp(min, max);
}
