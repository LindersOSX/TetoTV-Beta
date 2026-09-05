import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/core/tv/tv_shortcuts.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final isTelevision in [true, false]) {
    testWidgets(
      '${isTelevision ? 'TV' : 'phone'} default player offers built-in Media3 and keeps MPV selectable',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.view.physicalSize = isTelevision
            ? const Size(1280, 720)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [isTelevisionProvider.overrideWithValue(isTelevision)],
            child: MaterialApp(
              theme: AppTheme.dark,
              home: const TvShortcuts(child: AccountsScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-area-playback')));
        await tester.pumpAndSettle();

        final row = find.byKey(const ValueKey('settings-default-player'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();

        expect(find.text('Media3 (Built in)'), findsOneWidget);
        expect(find.text('MPV (Built in)'), findsWidgets);
        expect(find.text('Unavailable player'), findsNothing);
        await tester.tap(find.text('Media3 (Built in)'));
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(tester.element(row));
        expect(
          container.read(settingsPreferencesProvider).preferredPlayer,
          PreferredPlayer.media3,
        );
        expect(
          container.read(settingsPreferencesProvider).externalPlayerEnabled,
          isFalse,
        );
        expect(find.text('Media3 (Built in)'), findsOneWidget);
        expect(find.text('Unavailable player'), findsNothing);

        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        await tester.tap(find.text('MPV (Built in)'));
        await tester.pumpAndSettle();
        expect(
          container.read(settingsPreferencesProvider).preferredPlayer,
          PreferredPlayer.mpv,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
