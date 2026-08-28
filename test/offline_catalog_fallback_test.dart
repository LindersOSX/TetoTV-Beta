import 'package:anime_tv/features/catalog/application/catalog_providers.dart';
import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const catalog = [
    AnimeSummary(
      id: 1,
      title: 'Serial Experiments Lain',
      titleEnglish: 'Serial Experiments Lain',
      description: '',
      episodes: 13,
      score: 8,
      synonyms: ['Lain'],
    ),
    AnimeSummary(
      id: 2,
      title: 'Steins;Gate',
      titleRomaji: 'Steins;Gate',
      description: '',
      episodes: 24,
      score: 9,
      synonyms: ['シュタインズ・ゲート'],
    ),
    AnimeSummary(
      id: 3,
      title: 'Private Adult Download',
      description: '',
      episodes: 1,
      score: 1,
      isAdult: true,
    ),
  ];

  test('offline search matches every normalized query term', () {
    expect(searchOfflineAnime(catalog, 'serial lain').single.id, 1);
    expect(searchOfflineAnime(catalog, 'STEINS gate').single.id, 2);
  });

  test('offline search includes alternate titles and rejects partial sets', () {
    expect(searchOfflineAnime(catalog, 'Lain').single.id, 1);
    expect(searchOfflineAnime(catalog, 'serial steins'), isEmpty);
  });

  test('offline search never surfaces saved adult titles', () {
    expect(searchOfflineAnime(catalog, 'Private Adult'), isEmpty);
  });
}
