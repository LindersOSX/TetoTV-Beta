import 'package:anime_tv/core/preferences/title_language_preference.dart';
import 'package:anime_tv/features/catalog/domain/anime_franchise_context.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('animeFranchiseContextLabel', () {
    test('uses an explicit numbered season and optional part', () {
      expect(
        animeFranchiseContextLabel(
          anime: _anime(
            title: 'Attack on Titan Season 3 Part 2',
            english: 'Attack on Titan Season 3 Part 2',
            romaji: 'Shingeki no Kyojin Season 3 Part 2',
          ),
          titlePreference: TitleLanguagePreference.english,
        ),
        'SEASON 3 · PART 2',
      );
    });

    test('alternate title corroborates a numeric Romaji sequel', () {
      expect(
        animeFranchiseContextLabel(
          anime: _anime(
            title: 'My Hero Academia Season 4',
            english: 'My Hero Academia Season 4',
            romaji: 'Boku no Hero Academia 4',
          ),
          titlePreference: TitleLanguagePreference.romaji,
        ),
        'SEASON 4',
      );
    });

    test('preserves final season and part identity', () {
      expect(
        animeFranchiseContextLabel(
          anime: _anime(
            title: 'Attack on Titan Final Season Part 2',
            english: 'Attack on Titan Final Season Part 2',
            romaji: 'Shingeki no Kyojin: The Final Season Part 2',
          ),
          titlePreference: TitleLanguagePreference.romaji,
        ),
        'FINAL SEASON · PART 2',
      );
    });

    test('preserves a numbered final-season special', () {
      expect(
        animeFranchiseContextLabel(
          anime: _anime(
            title: 'Attack on Titan Final Season THE FINAL CHAPTERS Special 1',
            english:
                'Attack on Titan Final Season THE FINAL CHAPTERS Special 1',
            romaji:
                'Shingeki no Kyojin: The Final Season - Kanketsu-hen Zenpen',
            format: 'SPECIAL',
          ),
          titlePreference: TitleLanguagePreference.english,
        ),
        'FINAL SEASON · SPECIAL 1',
      );
    });

    test(
      'infers season one only from a matching episodic season-two sequel',
      () {
        final seasonTwo = _anime(
          id: 2,
          title: 'My Hero Academia Season 2',
          english: 'My Hero Academia Season 2',
          romaji: 'Boku no Hero Academia 2',
        );
        final seasonOne = _anime(
          title: 'My Hero Academia',
          english: 'My Hero Academia',
          romaji: 'Boku no Hero Academia',
          relations: [RelatedAnime(anime: seasonTwo, relationType: 'SEQUEL')],
        );

        expect(
          animeFranchiseContextLabel(
            anime: seasonOne,
            titlePreference: TitleLanguagePreference.english,
          ),
          'SEASON 1',
        );
      },
    );

    test('does not infer season one across a different title or a movie', () {
      for (final sequel in [
        _anime(
          id: 2,
          title: 'Different Hero Season 2',
          english: 'Different Hero Season 2',
        ),
        _anime(
          id: 3,
          title: 'Example Season 2',
          english: 'Example Season 2',
          format: 'MOVIE',
        ),
      ]) {
        expect(
          animeFranchiseContextLabel(
            anime: _anime(
              title: 'Example',
              english: 'Example',
              relations: [RelatedAnime(anime: sequel, relationType: 'SEQUEL')],
            ),
            titlePreference: TitleLanguagePreference.english,
          ),
          isNull,
        );
      }
    });

    test('does not infer season one when an episodic prequel exists', () {
      expect(
        animeFranchiseContextLabel(
          anime: _anime(
            title: 'Example',
            english: 'Example',
            relations: [
              RelatedAnime(
                anime: _anime(id: 9, title: 'Earlier Example'),
                relationType: 'PREQUEL',
              ),
              RelatedAnime(
                anime: _anime(
                  id: 10,
                  title: 'Example Season 2',
                  english: 'Example Season 2',
                ),
                relationType: 'SEQUEL',
              ),
            ],
          ),
          titlePreference: TitleLanguagePreference.english,
        ),
        'Example',
      );
    });

    test('relation-backed named arc keeps the exact preferred title', () {
      final arc = _anime(
        title: 'Demon Slayer: Entertainment District Arc',
        english: 'Demon Slayer: Entertainment District Arc',
        romaji: 'Kimetsu no Yaiba: Yuukaku-hen',
        relations: [
          RelatedAnime(
            anime: _anime(id: 20, title: 'Demon Slayer'),
            relationType: 'PREQUEL',
          ),
        ],
      );

      expect(
        animeFranchiseContextLabel(
          anime: arc,
          titlePreference: TitleLanguagePreference.english,
        ),
        'Demon Slayer: Entertainment District Arc',
      );
      expect(
        animeFranchiseContextLabel(
          anime: arc,
          titlePreference: TitleLanguagePreference.romaji,
        ),
        'Kimetsu no Yaiba: Yuukaku-hen',
      );
    });

    test('relation-backed special keeps the exact preferred title', () {
      expect(
        animeFranchiseContextLabel(
          anime: _anime(
            title: 'My Hero Academia: Training of the Dead',
            english: 'My Hero Academia: Training of the Dead',
            romaji: 'Boku no Hero Academia: Training of the Dead',
            format: 'OVA',
            relations: [
              RelatedAnime(
                anime: _anime(id: 30, title: 'My Hero Academia'),
                relationType: 'PARENT',
              ),
            ],
          ),
          titlePreference: TitleLanguagePreference.romaji,
        ),
        'Boku no Hero Academia: Training of the Dead',
      );
    });

    test('standalone shows do not receive redundant context', () {
      expect(
        animeFranchiseContextLabel(
          anime: _anime(title: 'Frieren: Beyond Journey’s End'),
          titlePreference: TitleLanguagePreference.english,
        ),
        isNull,
      );
    });

    test('numeric standalone titles are not mistaken for seasons', () {
      for (final title in const ['86', '7 Seeds']) {
        expect(
          animeFranchiseContextLabel(
            anime: _anime(title: title),
            titlePreference: TitleLanguagePreference.english,
          ),
          isNull,
        );
      }
    });
  });
}

AnimeSummary _anime({
  int id = 1,
  required String title,
  String? english,
  String? romaji,
  String format = 'TV',
  List<RelatedAnime> relations = const [],
}) => AnimeSummary(
  id: id,
  title: title,
  titleEnglish: english,
  titleRomaji: romaji,
  description: '',
  episodes: 12,
  score: 8,
  format: format,
  relatedAnime: relations,
);
