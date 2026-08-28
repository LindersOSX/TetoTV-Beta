import 'dart:async';

import 'package:anime_tv/core/theme/app_theme_palette.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('round trips a custom theme and its contrast preference', () async {
    final values = <String, String>{};
    final controller = _controller(values);
    final palette = AppThemePalette.fromSeeds(
      background: const Color(0xFF04182D),
      surface: const Color(0xFF102A43),
      accent: const Color(0xFFFFC857),
      primaryText: Colors.white,
      mutedText: const Color(0xFFB8C8DA),
    );

    final result = await controller.apply(
      palette: palette,
      contrastGuardEnabled: false,
    );
    final restored = _controller(values);
    await restored.load();

    expect(result, ThemeApplyResult.applied);
    expect(restored.state.palette, palette);
    expect(restored.state.contrastGuardEnabled, isFalse);
    expect(restored.state.loaded, isTrue);
    expect(values[themeStudioStorageKey], contains('"version":1'));
  });

  test(
    'startup preloader returns the persisted palette already loaded',
    () async {
      final palette = AppThemePalette.fromSeeds(
        background: const Color(0xFF071A2C),
        surface: const Color(0xFF102C46),
        accent: const Color(0xFF4ED8C7),
        primaryText: Colors.white,
        mutedText: const Color(0xFFB9D7D4),
      );
      final encoded = encodeThemeStudioState(
        ThemeStudioState(palette: palette, contrastGuardEnabled: false),
      );

      final storageRead = Completer<String?>();
      var preloadCompleted = false;
      final preload = preloadThemeStudioController(
        readValue: (_) => storageRead.future,
      )..then((_) => preloadCompleted = true);

      await Future<void>.delayed(Duration.zero);
      expect(preloadCompleted, isFalse);
      storageRead.complete(encoded);
      final controller = await preload;

      expect(preloadCompleted, isTrue);
      expect(controller.state.loaded, isTrue);
      expect(controller.state.palette, palette);
      expect(controller.state.contrastGuardEnabled, isFalse);
    },
  );

  test(
    'readability guard blocks an inaccessible theme without persisting',
    () async {
      final values = <String, String>{};
      final controller = _controller(values);
      final unreadable = AppThemePalette.fromSeeds(
        background: Colors.black,
        surface: const Color(0xFF030303),
        accent: const Color(0xFF080808),
        primaryText: const Color(0xFF050505),
        mutedText: const Color(0xFF060606),
      );

      final result = await controller.apply(
        palette: unreadable,
        contrastGuardEnabled: true,
      );

      expect(result, ThemeApplyResult.blockedByContrast);
      expect(controller.state.palette, AppThemePalette.defaults);
      expect(values, isEmpty);
    },
  );

  test('corrupt, partial, transparent, and future payloads fail closed', () {
    for (final encoded in [
      '{',
      '{"version":1,"background":4278190080}',
      '{"version":1,"background":66051,"surface":4278190080,'
          '"accent":4294901760,"primaryText":4294967295,'
          '"mutedText":4291611852}',
      '{"version":2}',
    ]) {
      expect(decodeThemeStudioState(encoded), const ThemeStudioState());
    }
  });

  test('a user edit made during a slow load is never overwritten', () async {
    final delayed = Completer<String?>();
    final writes = <String, String>{};
    final controller = ThemeStudioController(
      const FlutterSecureStorage(),
      readValue: (_) => delayed.future,
      writeValue: (key, value) async => writes[key] = value,
      deleteValue: (_) async {},
    );
    final saved = AppThemePalette.fromSeeds(
      background: const Color(0xFF001122),
      surface: const Color(0xFF112233),
      accent: const Color(0xFF66AAFF),
      primaryText: Colors.white,
      mutedText: const Color(0xFFCCDDEE),
    );
    final local = AppThemePalette.fromSeeds(
      background: const Color(0xFF201020),
      surface: const Color(0xFF302030),
      accent: const Color(0xFFFF70B7),
      primaryText: Colors.white,
      mutedText: const Color(0xFFD8C0D0),
    );

    final load = controller.load();
    await controller.apply(palette: local, contrastGuardEnabled: false);
    delayed.complete(
      encodeThemeStudioState(
        ThemeStudioState(palette: saved, contrastGuardEnabled: false),
      ),
    );
    await load;

    expect(controller.state.palette, local);
    expect(controller.state.loaded, isTrue);
  });

  test('reset restores exact defaults and deletes the payload', () async {
    final values = <String, String>{};
    final deleted = <String>[];
    final controller = ThemeStudioController(
      const FlutterSecureStorage(),
      readValue: (key) async => values[key],
      writeValue: (key, value) async => values[key] = value,
      deleteValue: (key) async {
        deleted.add(key);
        values.remove(key);
      },
    );
    await controller.apply(
      palette: AppThemePalette.defaults.copyWith(
        accent: const Color(0xFF3377DD),
      ),
      contrastGuardEnabled: false,
    );

    await controller.resetDefaults();

    expect(controller.state, const ThemeStudioState(loaded: true));
    expect(deleted, [themeStudioStorageKey]);
    expect(values, isEmpty);
  });
}

ThemeStudioController _controller(Map<String, String> values) =>
    ThemeStudioController(
      const FlutterSecureStorage(),
      readValue: (key) async => values[key],
      writeValue: (key, value) async => values[key] = value,
      deleteValue: (key) async => values.remove(key),
    );
