import 'dart:collection';
import 'dart:math' as math;

/// Process-local, bounded technical context. This never persists or sends data.
/// Explicit support exports may use it; automatic delivery remains gated by
/// the loaded, user-disableable anonymous-crash preference.
/// All string inputs cross exact allowlists before anything is retained.
class UiDiagnosticContext {
  UiDiagnosticContext({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final instance = UiDiagnosticContext();
  static const maximumEvents = 64;
  static const window = Duration(minutes: 5);
  static const maximumFrames = 120;
  final DateTime Function() _now;
  final _events = ListQueue<_UiEvent>();
  final _frames = ListQueue<_UiFrame>();
  final _current = <String, Object?>{'screen': 'other', 'text_entry': false};
  int _discarded = 0;
  int _coalesced = 0;
  bool _textEntry = false;

  static const screens = {
    'other',
    'home',
    'setup',
    'language_selection',
    'my_list',
    'search',
    'discover',
    'calendar',
    'anime',
    'franchise',
    'credits',
    'catalog',
    'pairing',
    'settings',
    'theme_studio',
    'diagnostics',
    'privacy',
    'notices',
    'marketplace',
    'downloads',
    'manga',
    'manga_reader',
    'local_media',
    'watch_party',
    'resolve',
    'player',
    'trailer',
  };
  static const controls = {
    'other',
    'navigation',
    'profile',
    'notifications',
    'button',
    'section',
    'settings.option',
    'settings.area',
    'settings.section',
    'settings.selection',
    'settings.search',
    'settings.toggle_all',
    'theme.option',
    'setup.option',
    'manga.search',
    'manga.content',
    'manga.navigation',
    'manga.reader',
    'manga.reader.back',
    'manga.reader.settings',
    'manga.reader.progress',
    'manga.section.library',
    'manga.section.browse',
    'manga.section.downloads',
    'manga.section.sources',
    'manga.sources.other',
    'manga.sources.policy.browse',
    'manga.sources.repository.add',
    'manga.sources.repository.refresh',
    'manga.sources.repository.toggle',
    'manga.sources.repository.remove',
    'manga.sources.extensions.manage',
    'manga.sources.extensions.filter',
    'manga.sources.extensions.language',
    'manga.sources.extensions.browse',
    'manga.sources.extension.install',
    'manga.sources.extension.toggle',
    'manga.sources.extension.remove',
    'manga.sources.catalog.add',
    'manga.sources.catalog.open',
    'manga.sources.catalog.toggle',
    'manga.sources.catalog.credentials',
    'manga.sources.catalog.remove',
    'player.control',
    'player.progress',
    'player.watch_party',
    'player.source',
    'text_entry',
  };
  static const navigationKeys = {
    'up',
    'down',
    'left',
    'right',
    'activate',
    'back',
    'tab',
  };

  /// Only route shape is inspected. No route, query, ID or fragment is saved.
  static String screenForUri(Uri uri) {
    if (uri.hasAuthority || uri.hasScheme) return 'other';
    final path = uri.path;
    const exact = {
      '/': 'home',
      '/setup': 'setup',
      '/setup/start': 'setup',
      '/setup/method': 'setup',
      '/setup/phone': 'setup',
      '/my-list': 'my_list',
      '/search': 'search',
      '/discover': 'discover',
      '/calendar': 'calendar',
      '/settings/accounts': 'settings',
      '/settings/device-setup': 'setup',
      '/settings/theme': 'theme_studio',
      '/settings/theme-studio': 'theme_studio',
      '/settings/diagnostics': 'diagnostics',
      '/settings/privacy': 'privacy',
      '/settings/notices': 'notices',
      '/settings/marketplace': 'marketplace',
      '/downloads': 'downloads',
      '/manga': 'manga',
      '/manga/read': 'manga_reader',
      '/library': 'local_media',
      '/settings/local-media': 'local_media',
      '/watch-together': 'watch_party',
      '/resolve': 'resolve',
      '/player': 'player',
      '/trailer': 'trailer',
    };
    final known = exact[path];
    if (known != null) return known;
    final parts = uri.pathSegments;
    if (parts.length == 2 && parts.first == 'pair') return 'pairing';
    if (parts.length == 2 && {'studio', 'staff'}.contains(parts.first)) {
      return 'catalog';
    }
    if (parts.length >= 2 && parts.first == 'anime') {
      if (parts.length == 2) return 'anime';
      if (parts.length == 3 && parts.last == 'franchise') return 'franchise';
      if (parts.length == 3 && parts.last == 'credits') return 'credits';
    }
    return 'other';
  }

  /// A debug label is untrusted input, never a report value. Only exact static
  /// names or known families survive; dynamic suffixes are discarded entirely.
  static String controlForLabel(String? label) {
    if (label == null || label.length > 1024) return 'other';
    if (controls.contains(label)) return label;
    const exact = {
      'top-level.active-navigation': 'navigation',
      'top-level.profile': 'profile',
      'top-level.notifications': 'notifications',
      'TV mouse/D-pad control': 'button',
      'TV text input': 'text_entry',
      'manga.content.first': 'manga.content',
      'accounts.search': 'settings.search',
      'accounts.sections.toggle-all': 'settings.toggle_all',
    };
    if (exact.containsKey(label)) return exact[label]!;
    if (label.startsWith('manga.sources.')) return 'manga.sources.other';
    if (label.startsWith('manga.section.')) return 'section';
    if (label.startsWith('accounts.area.')) return 'settings.area';
    if (label.startsWith('accounts.section.') ||
        label.startsWith('accounts.settings-section.')) {
      return 'settings.section';
    }
    if (label.startsWith('settings.selection.')) return 'settings.selection';
    if (label.startsWith('accounts.')) return 'settings.option';
    if (label.startsWith('theme-studio.')) return 'theme.option';
    if (label.startsWith('setup.') || label.startsWith('setup-method.')) {
      return 'setup.option';
    }
    if (label.startsWith('player.progress')) return 'player.progress';
    if (label.startsWith('player.watch-party.')) return 'player.watch_party';
    if (label.startsWith('player-source.')) return 'player.source';
    if (label.startsWith('player.')) return 'player.control';
    return 'other';
  }

  void configure({
    required String screen,
    String languageCode = 'en',
    String playerEngine = 'media3',
    bool media3SurfaceView = true,
  }) {
    final safeScreen = screens.contains(screen) ? screen : 'other';
    if (_current['screen'] != safeScreen) {
      _current.remove('focus');
      _current.remove('scroll');
      _current['screen'] = safeScreen;
      _add('screen', {'screen': safeScreen});
    }
    _current['language'] =
        {'en', 'es', 'pt', 'fr', 'hi', 'de'}.contains(languageCode)
        ? languageCode
        : 'other';
    _current['player_engine'] = {'mpv', 'media3'}.contains(playerEngine)
        ? playerEngine
        : 'other';
    _current['surface_view'] = media3SurfaceView;
  }

  void recordTextEntry(bool active) {
    if (_textEntry == active) return;
    _textEntry = active;
    _current['text_entry'] = active;
    _current.remove('focus');
    _current.remove('scroll');
    _add('text_entry', {'active': active});
  }

  void recordFocus({
    required String control,
    required int ordinal,
    List<double>? rect,
    double? scrollOffset,
    double? scrollMaximum,
  }) {
    if (_textEntry) return;
    final data = <String, Object?>{
      'control': controls.contains(control) && control != 'text_entry'
          ? control
          : 'other',
      'ordinal': ordinal.clamp(0, 1000000),
    };
    if (rect != null && rect.length == 4 && rect.every((n) => n.isFinite)) {
      data['rect'] = rect
          .map((n) => _number(n, minimum: -32768, maximum: 32768))
          .toList(growable: false);
    }
    if (scrollOffset != null && scrollOffset.isFinite) {
      data['scroll'] = _number(scrollOffset, maximum: 10000000);
    }
    if (scrollMaximum != null && scrollMaximum.isFinite) {
      data['scroll_max'] = _number(scrollMaximum, maximum: 10000000);
    }
    _current['focus'] = data;
    _add('focus', data);
  }

  void recordNavigation(String key, {bool repeat = false}) {
    if (_textEntry || !navigationKeys.contains(key)) return;
    _add('navigation', {'key': key, 'repeat': repeat});
  }

  void recordScroll({
    required double offset,
    required double maximum,
    required double viewport,
    bool horizontal = false,
  }) {
    if (_textEntry ||
        !offset.isFinite ||
        !maximum.isFinite ||
        !viewport.isFinite) {
      return;
    }
    final data = <String, Object?>{
      'offset': _number(offset, maximum: 10000000),
      'maximum': _number(maximum, maximum: 10000000),
      'viewport': _number(viewport, maximum: 32768),
      'axis': horizontal ? 'horizontal' : 'vertical',
    };
    _current['scroll'] = data;
    _add('scroll', data);
  }

  void recordLifecycle(String state) {
    if (!{
      'resumed',
      'inactive',
      'hidden',
      'paused',
      'detached',
    }.contains(state)) {
      return;
    }
    _current['lifecycle'] = state;
    _add('lifecycle', {'state': state});
  }

  void recordViewport({
    required double width,
    required double height,
    required double physicalWidth,
    required double physicalHeight,
    required double pixelRatio,
    required double textScale,
  }) {
    _current['viewport'] = <String, Object?>{
      'width': _number(width, maximum: 32768),
      'height': _number(height, maximum: 32768),
      'physical_width': _number(physicalWidth, maximum: 65536),
      'physical_height': _number(physicalHeight, maximum: 65536),
      'pixel_ratio': _number(pixelRatio, maximum: 16),
      'text_scale': _number(textScale, maximum: 10),
      'orientation': width > height ? 'landscape' : 'portrait',
    };
  }

  void recordFrame({required double buildMs, required double rasterMs}) {
    // Keyboard redraw counts can correlate with typing. Pause even aggregate
    // samples while text entry is active; keep only entered/exited markers.
    if (_textEntry ||
        !buildMs.isFinite ||
        !rasterMs.isFinite ||
        buildMs < 0 ||
        rasterMs < 0) {
      return;
    }
    _trim();
    _frames.add(
      _UiFrame(_now(), buildMs.clamp(0, 10000), rasterMs.clamp(0, 10000)),
    );
    while (_frames.length > maximumFrames) {
      _frames.removeFirst();
    }
  }

  /// Fully detached maps/lists: snapshots cannot be changed by later events.
  Map<String, Object?> snapshot() {
    _trim();
    final now = _now();
    return {
      'schema_version': 1,
      'current': _copyMap(_current),
      'events': _events
          .map(
            (event) => <String, Object?>{
              'age_ms': now
                  .difference(event.time)
                  .inMilliseconds
                  .clamp(0, window.inMilliseconds),
              'event': event.kind,
              ..._copyMap(event.data),
              'count': event.count,
            },
          )
          .toList(growable: false),
      'bounds': {
        'event_count': _events.length,
        'event_limit': maximumEvents,
        'window_seconds': window.inSeconds,
        'discarded': _discarded,
        'coalesced': _coalesced,
        'truncated': _discarded > 0,
      },
      'frames': _frameSummary(),
    };
  }

  /// Fits the existing crash-report stack field without adding wire fields.
  /// Only recorder-owned primitives are formatted, never caller-supplied text.
  String crashSummary({int maximum = 1100}) {
    final budget = maximum.clamp(0, 1100);
    if (budget == 0) return '';
    final data = snapshot();
    final current = data['current']! as Map<String, Object?>;
    final events = data['events']! as List<Map<String, Object?>>;
    final bounds = data['bounds']! as Map<String, Object?>;
    final lines = <String>[
      'ui_snapshot_v1 screen=${current['screen']} language=${current['language'] ?? 'other'} lifecycle=${current['lifecycle'] ?? 'other'} text_entry=${current['text_entry']}',
      'player engine=${current['player_engine'] ?? 'other'} surface_view=${current['surface_view'] ?? false}',
      if (current['viewport'] case final Map<String, Object?> viewport)
        'viewport logical=${viewport['width']}x${viewport['height']} physical=${viewport['physical_width']}x${viewport['physical_height']} dpr=${viewport['pixel_ratio']} text_scale=${viewport['text_scale']}',
      if (current['focus'] case final Map<String, Object?> focus)
        'focus ${_compact(focus)}',
      if (current['scroll'] case final Map<String, Object?> scroll)
        'scroll ${_compact(scroll)}',
      'frames ${_compact(data['frames']! as Map<String, Object?>)}',
      'trail events=${bounds['event_count']} max=64 window_s=300 discarded=${bounds['discarded']} coalesced=${bounds['coalesced']}',
      // Most recent first so a tight transport budget retains crash-adjacent context.
      ...events.reversed.take(8).map((event) => 'recent ${_compact(event)}'),
    ];
    final output = StringBuffer();
    for (final raw in lines.take(15)) {
      final line = raw.length > 240 ? raw.substring(0, 240) : raw;
      final remaining = budget - output.length - (output.isEmpty ? 0 : 1);
      if (remaining <= 0) break;
      if (output.isNotEmpty) output.writeln();
      output.write(
        line.length <= remaining ? line : line.substring(0, remaining),
      );
    }
    return output.toString();
  }

  void _add(String kind, Map<String, Object?> data) {
    _trim();
    final now = _now();
    if (_events.isNotEmpty) {
      final last = _events.last;
      if (last.kind == kind && _compact(last.data) == _compact(data)) {
        last.time = now;
        last.count = math.min(9999, last.count + 1);
        _coalesced = math.min(1000000, _coalesced + 1);
        return;
      }
    }
    _events.add(_UiEvent(now, kind, _copyMap(data)));
    while (_events.length > maximumEvents) {
      _events.removeFirst();
      _discarded = math.min(1000000, _discarded + 1);
    }
  }

  void _trim() {
    final before = _now().subtract(window);
    while (_events.isNotEmpty && _events.first.time.isBefore(before)) {
      _events.removeFirst();
      _discarded = math.min(1000000, _discarded + 1);
    }
    while (_frames.isNotEmpty && _frames.first.time.isBefore(before)) {
      _frames.removeFirst();
    }
  }

  Map<String, Object?> _frameSummary() {
    if (_frames.isEmpty) return {'samples': 0, 'limit': maximumFrames};
    final builds = _frames.map((f) => f.build).toList()..sort();
    final rasters = _frames.map((f) => f.raster).toList()..sort();
    final p95 = (builds.length * .95).ceil() - 1;
    return {
      'samples': builds.length,
      'limit': maximumFrames,
      'build_avg_ms': _number(
        builds.reduce((a, b) => a + b) / builds.length,
        maximum: 10000,
      ),
      'raster_avg_ms': _number(
        rasters.reduce((a, b) => a + b) / rasters.length,
        maximum: 10000,
      ),
      'build_p95_ms': _number(builds[p95], maximum: 10000),
      'raster_p95_ms': _number(rasters[p95], maximum: 10000),
      'build_max_ms': _number(builds.last, maximum: 10000),
      'raster_max_ms': _number(rasters.last, maximum: 10000),
    };
  }

  static double _number(
    double value, {
    double minimum = 0,
    double maximum = 32768,
  }) => value.isFinite ? (value.clamp(minimum, maximum) * 10).round() / 10 : 0;
  static String _compact(Map<String, Object?> data) => data.entries
      .map(
        (e) =>
            '${e.key}=${e.value is List ? (e.value! as List).join(',') : e.value}',
      )
      .join(' ');
  static Map<String, Object?> _copyMap(Map<String, Object?> map) => map.map(
    (key, value) => MapEntry(key, switch (value) {
      Map<String, Object?>() => _copyMap(value),
      List() => List<Object?>.of(value),
      _ => value,
    }),
  );
}

class _UiEvent {
  _UiEvent(this.time, this.kind, this.data);
  DateTime time;
  final String kind;
  final Map<String, Object?> data;
  int count = 1;
}

class _UiFrame {
  _UiFrame(this.time, this.build, this.raster);
  final DateTime time;
  final double build;
  final double raster;
}
