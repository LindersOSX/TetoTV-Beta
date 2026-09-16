import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/settings/application/display_preferences_controller.dart';
import 'package:anime_tv/features/streaming/domain/stream_resolver.dart';
import 'package:anime_tv/features/watch_together/domain/watch_party_models.dart';
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

  test('episode display title does not mutate canonical search identity', () {
    const episode = EpisodeReference(
      anilistMediaId: 1,
      title: 'Canonical provider title',
      titleEnglish: 'English display title',
      titleRomaji: 'Romaji display title',
      episode: 3,
    );

    expect(
      episode.displayTitle(TitleLanguagePreference.english),
      'English display title',
    );
    expect(
      episode.playbackDisplayTitle(TitleLanguagePreference.romaji),
      'Romaji display title • Episode 3',
    );
    expect(episode.title, 'Canonical provider title');
  });

  test('Watch Party media applies each viewer title preference locally', () {
    const media = WatchPartyMedia(
      kind: 'anilist',
      title: 'Canonical shared title',
      titleEnglish: 'English room title',
      titleRomaji: 'Romaji room title',
      anilistId: 1,
      episode: 2,
    );

    expect(
      media.displayTitle(TitleLanguagePreference.english),
      'English room title',
    );
    expect(
      media.displayTitle(TitleLanguagePreference.romaji),
      'Romaji room title',
    );
    expect(media.toJson()['title'], 'Canonical shared title');
  });
}
