import 'dart:convert';

import 'package:anime_tv/core/theme/app_theme_palette.dart';
import 'package:anime_tv/features/auth/application/pairing_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const themeStudioStorageKey = 'appearance_theme_palette_v1';

enum ThemeApplyResult { applied, blockedByContrast }

@immutable
class ThemeStudioState {
  const ThemeStudioState({
    this.palette = AppThemePalette.defaults,
    this.contrastGuardEnabled = true,
    this.loaded = false,
  });

  final AppThemePalette palette;
  final bool contrastGuardEnabled;
  final bool loaded;

  ThemeContrastReport get contrastReport =>
      ThemeContrastReport.forPalette(palette);

  ThemeStudioState copyWith({
    AppThemePalette? palette,
    bool? contrastGuardEnabled,
    bool? loaded,
  }) => ThemeStudioState(
    palette: palette ?? this.palette,
    contrastGuardEnabled: contrastGuardEnabled ?? this.contrastGuardEnabled,
    loaded: loaded ?? this.loaded,
  );

  @override
  int get hashCode => Object.hash(palette, contrastGuardEnabled, loaded);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThemeStudioState &&
          palette == other.palette &&
          contrastGuardEnabled == other.contrastGuardEnabled &&
          loaded == other.loaded;
}

final themeStudioControllerProvider =
    StateNotifierProvider<ThemeStudioController, ThemeStudioState>((ref) {
      final controller = ThemeStudioController(
        ref.watch(secureStorageProvider),
      );
      Future.microtask(controller.load);
      return controller;
    });

/// Restores the saved palette before Flutter builds the first app frame.
///
/// The regular provider still loads lazily for isolated widgets and tests, but
/// production startup overrides it with this already-loaded controller. That
/// prevents the default palette from being painted while secure storage is
/// still returning a custom theme.
Future<ThemeStudioController> preloadThemeStudioController({
  FlutterSecureStorage storage = const FlutterSecureStorage(),
  Future<String?> Function(String key)? readValue,
  Future<void> Function(String key, String value)? writeValue,
  Future<void> Function(String key)? deleteValue,
}) async {
  final controller = ThemeStudioController(
    storage,
    readValue: readValue,
    writeValue: writeValue,
    deleteValue: deleteValue,
  );
  await controller.load();
  return controller;
}

class ThemeStudioController extends StateNotifier<ThemeStudioState> {
  ThemeStudioController(
    this._storage, {
    this.readValue,
    this.writeValue,
    this.deleteValue,
  }) : super(const ThemeStudioState());

  final FlutterSecureStorage _storage;
  final Future<String?> Function(String key)? readValue;
  final Future<void> Function(String key, String value)? writeValue;
  final Future<void> Function(String key)? deleteValue;

  Future<void>? _loadFuture;
  Future<void> _storageTail = Future<void>.value();
  int _revision = 0;

  Future<void> load() => _loadFuture ??= _load().whenComplete(() {
    _loadFuture = null;
  });

  Future<void> _load() async {
    final revisionAtStart = _revision;
    String? encoded;
    try {
      encoded =
          await (readValue?.call(themeStudioStorageKey) ??
              _storage.read(key: themeStudioStorageKey));
    } catch (_) {
      if (revisionAtStart == _revision) {
        state = state.copyWith(loaded: true);
      }
      return;
    }

    if (revisionAtStart != _revision) {
      state = state.copyWith(loaded: true);
      return;
    }
    final restored = decodeThemeStudioState(encoded);
    state = restored.copyWith(loaded: true);
  }

  Future<ThemeApplyResult> apply({
    required AppThemePalette palette,
    required bool contrastGuardEnabled,
  }) async {
    final normalized = AppThemePalette.fromSeeds(
      background: palette.background,
      surface: palette.surface,
      accent: palette.accent,
      primaryText: palette.primaryText,
      mutedText: palette.mutedText,
    );
    if (contrastGuardEnabled &&
        ThemeContrastReport.forPalette(normalized).hasIssues) {
      return ThemeApplyResult.blockedByContrast;
    }

    _revision++;
    state = ThemeStudioState(
      palette: normalized,
      contrastGuardEnabled: contrastGuardEnabled,
      loaded: true,
    );
    await _enqueueWrite(encodeThemeStudioState(state));
    return ThemeApplyResult.applied;
  }

  Future<void> resetDefaults() async {
    _revision++;
    state = const ThemeStudioState(loaded: true);
    final previous = _storageTail;
    final request = () async {
      await previous;
      try {
        await (deleteValue?.call(themeStudioStorageKey) ??
            _storage.delete(key: themeStudioStorageKey));
      } catch (_) {
        // Defaults remain active in memory when platform storage is missing.
      }
    }();
    _storageTail = request;
    await request;
  }

  Future<void> _enqueueWrite(String encoded) {
    final previous = _storageTail;
    final request = () async {
      await previous;
      try {
        await (writeValue?.call(themeStudioStorageKey, encoded) ??
            _storage.write(key: themeStudioStorageKey, value: encoded));
      } catch (_) {
        // Theme changes are immediately useful even if persistence is down.
      }
    }();
    _storageTail = request;
    return request;
  }
}

String encodeThemeStudioState(ThemeStudioState state) => jsonEncode({
  'version': 1,
  'background': state.palette.background.toARGB32(),
  'surface': state.palette.surface.toARGB32(),
  'accent': state.palette.accent.toARGB32(),
  'primaryText': state.palette.primaryText.toARGB32(),
  'mutedText': state.palette.mutedText.toARGB32(),
  'contrastGuard': state.contrastGuardEnabled,
});

ThemeStudioState decodeThemeStudioState(String? encoded) {
  if (encoded == null || encoded.trim().isEmpty) {
    return const ThemeStudioState();
  }
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      return const ThemeStudioState();
    }
    final background = _opaqueColor(decoded['background']);
    final surface = _opaqueColor(decoded['surface']);
    final accent = _opaqueColor(decoded['accent']);
    final primaryText = _opaqueColor(decoded['primaryText']);
    final mutedText = _opaqueColor(decoded['mutedText']);
    if (background == null ||
        surface == null ||
        accent == null ||
        primaryText == null ||
        mutedText == null) {
      return const ThemeStudioState();
    }
    return ThemeStudioState(
      palette: AppThemePalette.fromSeeds(
        background: background,
        surface: surface,
        accent: accent,
        primaryText: primaryText,
        mutedText: mutedText,
      ),
      contrastGuardEnabled: decoded['contrastGuard'] is bool
          ? decoded['contrastGuard'] as bool
          : true,
    );
  } catch (_) {
    return const ThemeStudioState();
  }
}

Color? _opaqueColor(Object? raw) {
  final value = switch (raw) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };
  if (value == null || value < 0 || value > 0xFFFFFFFF) return null;
  if (value & 0xFF000000 != 0xFF000000) return null;
  return Color(value);
}
