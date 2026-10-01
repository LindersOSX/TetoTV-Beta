import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/theme_studio_controller.dart';
import 'package:anime_tv/features/settings/presentation/caption_studio_screen.dart';
import 'package:anime_tv/features/settings/presentation/display_studio_screen.dart';
import 'package:anime_tv/features/settings/presentation/theme_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unchanged studios share the same idle Apply colors', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final studio in [
      (const DisplayStudioScreen(), 'display-studio-apply'),
      (const CaptionStudioScreen(), 'caption-studio-apply'),
      (const ThemeStudioScreen(), 'theme-studio-apply'),
    ]) {
      final preferences = SettingsPreferencesController(
        const FlutterSecureStorage(),
        readValue: (_) async => null,
        writeValue: (_, _) async {},
        deleteValue: (_) async {},
      );
      final theme = ThemeStudioController(
        const FlutterSecureStorage(),
        readValue: (_) async => null,
        writeValue: (_, _) async {},
        deleteValue: (_) async {},
      );
      await preferences.load();
      await theme.load();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsPreferencesProvider.overrideWith((_) => preferences),
            themeStudioControllerProvider.overrideWith((_) => theme),
          ],
          child: MaterialApp(theme: AppTheme.dark, home: studio.$1),
        ),
      );
      await tester.pumpAndSettle();
      final finder = find.byKey(ValueKey(studio.$2));
      await tester.scrollUntilVisible(
        finder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final apply = tester.widget<FilledButton>(finder);
      expect(
        apply.style!.backgroundColor!.resolve({}),
        AppThemePalette.defaults.surfaceRaised,
        reason: studio.$2,
      );
      expect(
        apply.style!.foregroundColor!.resolve({}),
        AppThemePalette.defaults.mutedText,
        reason: studio.$2,
      );

      if (studio.$1 is ThemeStudioScreen) {
        // An unchanged Apply remains reachable by remote, but saves nothing.
        apply.focusNode!.requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'theme-studio.reset',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(apply.focusNode!.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('Theme applied.'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
