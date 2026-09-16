import 'package:anime_tv/core/localization/teto_localizations.dart';
import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/presentation/credits_screen.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Credits uses Title Language independently from UI language', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const anime = AnimeSummary(
      id: 77,
      title: 'Canonical credits title',
      titleEnglish: 'English credits title',
      titleRomaji: 'Romaji credits title',
      description: '',
      episodes: 12,
      score: 8,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeDetailsProvider.overrideWith((_, _) async => anime),
          titleLanguagePreferenceProvider.overrideWith(
            (_) =>
                _CreditsTitleLanguageController(TitleLanguagePreference.romaji),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('es'),
          supportedLocales: TetoLocalizations.supportedLocales,
          localizationsDelegates: const [
            TetoLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const CreditsScreen(mediaId: 77),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reparto y equipo'), findsOneWidget);
    expect(find.text('Romaji credits title'), findsOneWidget);
    expect(find.text('English credits title'), findsNothing);
    expect(find.text('Canonical credits title'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _CreditsTitleLanguageController
    extends TitleLanguagePreferenceController {
  _CreditsTitleLanguageController(TitleLanguagePreference initial)
    : super(const FlutterSecureStorage()) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}
