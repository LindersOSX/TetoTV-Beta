import 'dart:convert';

import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/application/anime_title_logo_provider.dart';
import 'package:anime_tv/features/catalog/domain/anime_title_logo.dart';
import 'package:anime_tv/features/catalog/presentation/anime_title_logo_view.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/settings/application/settings_preferences_controller.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('text title style does not request logo artwork', (tester) async {
    var logoLookups = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _LogoSettingsController(ShowTitleStyle.text),
          ),
          animeTitleLogoProvider.overrideWith((_, _) async {
            logoLookups++;
            return AnimeTitleLogo(
              url: Uri.parse('https://artworks.thetvdb.com/english.png'),
              source: AnimeTitleLogoSource.fanartTvHd,
              languageCode: 'en',
            );
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AnimeTitleLogoView(
              aniListId: 123,
              fallbackTitle: 'English Show Title',
              logoContextLabel: 'SEASON 2',
              maxWidth: 600,
              maxHeight: 100,
              textStyle: TextStyle(fontSize: 30),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('English Show Title'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(logoLookups, 0);
  });

  testWidgets('English logo style renders available transparent artwork', (
    tester,
  ) async {
    var logoLookups = 0;
    final requestedLanguages = <TitleLanguagePreference>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _LogoSettingsController(ShowTitleStyle.englishLogo),
          ),
          titleLanguagePreferenceProvider.overrideWith(
            (_) => _LogoLanguageController(TitleLanguagePreference.english),
          ),
          animeTitleLogoProvider.overrideWith((_, request) async {
            logoLookups++;
            requestedLanguages.add(request.titleLanguage);
            return AnimeTitleLogo(
              url: Uri.parse('https://artworks.thetvdb.com/english.png'),
              source: AnimeTitleLogoSource.fanartTvHd,
              languageCode: 'en',
            );
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AnimeTitleLogoView(
              aniListId: 123,
              fallbackTitle: 'My Hero Academia Season 7',
              logoContextLabel: 'SEASON 7',
              maxWidth: 600,
              maxHeight: 100,
              textStyle: TextStyle(fontSize: 30),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(logoLookups, 1);
    expect(requestedLanguages, [TitleLanguagePreference.english]);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, 'https://artworks.thetvdb.com/english.png');
    expect(tester.getSize(find.byType(AnimeTitleLogoView)).width, 600);
    expect(tester.getSize(find.byType(AnimeTitleLogoView)).height, 100);
    final builtLogo = image.imageBuilder!(
      tester.element(find.byType(CachedNetworkImage)),
      MemoryImage(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      ),
    );
    final logoColumn = (builtLogo as SizedBox).child! as Column;
    final contextLabel = logoColumn.children.last as Text;
    expect(contextLabel.data, 'SEASON 7');
    expect(contextLabel.key, const ValueKey('anime-title-logo-context-label'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: builtLogo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundedLogo = find.byKey(
      const ValueKey('anime-title-logo-artwork-with-context'),
    );
    final renderedImage = find.descendant(
      of: boundedLogo,
      matching: find.byType(Image),
    );
    final renderedContext = find.byKey(
      const ValueKey('anime-title-logo-context-label'),
    );
    expect(renderedImage, findsOneWidget);
    expect(renderedContext, findsOneWidget);
    final boundedRect = tester.getRect(boundedLogo);
    final imageRect = tester.getRect(renderedImage);
    final contextRect = tester.getRect(renderedContext);
    expect(boundedRect.height, 100);
    expect(
      boundedRect.contains(imageRect.topLeft),
      isTrue,
      reason: 'Logo $imageRect must start inside $boundedRect',
    );
    expect(
      boundedRect.contains(imageRect.bottomRight - const Offset(.1, .1)),
      isTrue,
      reason: 'Logo $imageRect must end inside $boundedRect',
    );
    expect(
      boundedRect.contains(contextRect.topLeft),
      isTrue,
      reason: 'Context $contextRect must start inside $boundedRect',
    );
    expect(
      boundedRect.contains(contextRect.bottomRight - const Offset(.1, .1)),
      isTrue,
      reason: 'Context $contextRect must end inside $boundedRect',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Romaji title preference requests and renders Japanese artwork', (
    tester,
  ) async {
    final requestedLanguages = <TitleLanguagePreference>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _LogoSettingsController(ShowTitleStyle.englishLogo),
          ),
          titleLanguagePreferenceProvider.overrideWith(
            (_) => _LogoLanguageController(TitleLanguagePreference.romaji),
          ),
          animeTitleLogoProvider.overrideWith((_, request) async {
            requestedLanguages.add(request.titleLanguage);
            return AnimeTitleLogo(
              url: Uri.parse('https://artworks.thetvdb.com/japanese.png'),
              source: AnimeTitleLogoSource.fanartTvHd,
              languageCode: 'ja',
            );
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AnimeTitleLogoView(
              aniListId: 456,
              fallbackTitle: 'Shoumei no Taitoru',
              maxWidth: 420,
              maxHeight: 86,
              textStyle: TextStyle(fontSize: 28),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(requestedLanguages, [TitleLanguagePreference.romaji]);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, 'https://artworks.thetvdb.com/japanese.png');
    expect(tester.getSize(find.byType(AnimeTitleLogoView)).width, 420);
    expect(tester.getSize(find.byType(AnimeTitleLogoView)).height, 86);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing Romaji artwork keeps the localized bounded text title', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsPreferencesProvider.overrideWith(
            (_) => _LogoSettingsController(ShowTitleStyle.englishLogo),
          ),
          titleLanguagePreferenceProvider.overrideWith(
            (_) => _LogoLanguageController(TitleLanguagePreference.romaji),
          ),
          animeTitleLogoProvider.overrideWith((_, request) async {
            expect(request.titleLanguage, TitleLanguagePreference.romaji);
            return null;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: AnimeTitleLogoView(
                key: ValueKey('romaji-fallback-title'),
                aniListId: 789,
                fallbackTitle: 'Koukaku Kidoutai',
                logoContextLabel: 'SEASON 2',
                maxWidth: 260,
                maxHeight: 58,
                textStyle: TextStyle(fontSize: 30),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Koukaku Kidoutai'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    final fallbackRect = tester.getRect(
      find.byKey(const ValueKey('romaji-fallback-title')),
    );
    expect(fallbackRect.width, lessThanOrEqualTo(260));
    expect(fallbackRect.height, lessThanOrEqualTo(58));
    expect(tester.takeException(), isNull);
  });
}

class _LogoSettingsController extends SettingsPreferencesController {
  _LogoSettingsController(ShowTitleStyle style)
    : super(const FlutterSecureStorage()) {
    state = SettingsPreferences(showTitleStyle: style, loaded: true);
  }

  @override
  Future<void> load() async {}
}

class _LogoLanguageController extends TitleLanguagePreferenceController {
  _LogoLanguageController(TitleLanguagePreference initial)
    : super(const FlutterSecureStorage()) {
    state = initial;
  }

  @override
  Future<void> load() async {}
}
