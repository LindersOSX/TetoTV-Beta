import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('English is preferred by default with Romaji fallback', () {
    expect(
      preferredAnimeTitle(
        preference: TitleLanguagePreference.english,
        fallback: 'Fallback',
        english: 'English title',
        romaji: 'Romaji title',
      ),
      'English title',
    );
    expect(
      preferredAnimeTitle(
        preference: TitleLanguagePreference.english,
        fallback: 'Fallback',
        romaji: 'Romaji title',
      ),
      'Romaji title',
    );
  });

  test('saved Romaji preference is restored', () async {
    FlutterSecureStorage.setMockInitialValues({
      titleLanguagePreferenceStorageKey: 'romaji',
    });
    final controller = TitleLanguagePreferenceController(
      const FlutterSecureStorage(),
    );

    await controller.load();

    expect(controller.state, TitleLanguagePreference.romaji);
  });
}
