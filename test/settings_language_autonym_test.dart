import 'package:anime_tv/core/layout/adaptive_layout.dart';
import 'package:anime_tv/core/localization/app_language.dart';
import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/theme/app_theme.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:anime_tv/features/settings/presentation/accounts_screen.dart';
import 'package:anime_tv/features/settings/presentation/language_selection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _autonyms = [
  'English',
  'Español',
  'Português',
  'Français',
  'हिन्दी',
  'Deutsch',
];

Widget _localizedApp(AppLanguage language, Widget home) => ProviderScope(
  overrides: [isTelevisionProvider.overrideWithValue(true)],
  child: MaterialApp(
    theme: AppTheme.dark,
    locale: language.locale,
    supportedLocales: TetoLocalizations.supportedLocales,
    localizationsDelegates: const [
      TetoLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('app language names are the six fixed autonyms', () {
    expect(
      AppLanguage.values.map((language) => language.nativeName),
      _autonyms,
    );
  });

  for (final language in AppLanguage.values) {
    testWidgets('${language.code} setup keeps all six language autonyms', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _localizedApp(language, const LanguageSelectionScreen()),
      );
      await tester.pumpAndSettle();
      for (final name in _autonyms) {
        expect(find.text(name), findsOneWidget);
      }
      expect(
        find.text(TetoLocalizations(language).text('Choose your language')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('${language.code} settings keeps autonyms in row and picker', (
      tester,
    ) async {
      // Intentionally keep the selected language different from this widget's
      // UI locale: changing locale must not translate the English autonym.
      FlutterSecureStorage.setMockInitialValues({
        interfaceLanguageStorageKey: 'en',
        interfaceLanguageChosenStorageKey: 'true',
        'player_preferred_audio_language': 'jpn',
        'player_preferred_caption_language': 'ita',
      });
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_localizedApp(language, const AccountsScreen()));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('settings-app-language'));
      expect(
        find.descendant(of: row, matching: find.text('English')),
        findsOneWidget,
      );
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      for (final name in _autonyms) {
        expect(
          find.descendant(of: dialog, matching: find.text(name)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(TetoLocalizations(language).text('App language')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(
            TetoLocalizations(language).text(
              'Also sets preferred audio and captions. You can change them separately in Playback.',
            ),
          ),
        ),
        findsNWidgets(6),
      );
      final preferences = ProviderScope.containerOf(
        tester.element(find.byType(AccountsScreen)),
      ).read(settingsPreferencesProvider);
      expect(preferences.preferredAudioLanguage, 'jpn');
      expect(preferences.preferredCaptionLanguage, 'ita');
      expect(tester.takeException(), isNull);
    });
  }
}
