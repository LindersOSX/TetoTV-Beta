import 'package:anime_tv/features/catalog/domain/anime_summary.dart';
import 'package:anime_tv/features/catalog/domain/franchise_watch_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orders continuation graph and labels related formats and roles', () {
    const prequel = AnimeSummary(
      id: 1,
      title: 'First story',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2018,
    );
    const sequel = AnimeSummary(
      id: 3,
      title: 'Third story',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2021,
    );
    const movie = AnimeSummary(
      id: 4,
      title: 'The movie',
      description: '',
      episodes: 1,
      score: 8,
      format: 'MOVIE',
      seasonYear: 2020,
    );
    const ova = AnimeSummary(
      id: 5,
      title: 'Bonus OVA',
      description: '',
      episodes: 1,
      score: 8,
      format: 'OVA',
      seasonYear: 2020,
    );
    const special = AnimeSummary(
      id: 6,
      title: 'Broadcast special',
      description: '',
      episodes: 1,
      score: 8,
      format: 'SPECIAL',
      seasonYear: 2020,
    );
    const spinOff = AnimeSummary(
      id: 7,
      title: 'Different heroes',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2022,
    );
    const root = AnimeSummary(
      id: 2,
      title: 'Main story',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2020,
      relatedAnime: [
        RelatedAnime(anime: prequel, relationType: 'PREQUEL'),
        RelatedAnime(anime: sequel, relationType: 'SEQUEL'),
        RelatedAnime(anime: movie, relationType: 'SEQUEL'),
        RelatedAnime(anime: ova, relationType: 'SIDE_STORY'),
        RelatedAnime(anime: special, relationType: 'SIDE_STORY'),
        RelatedAnime(anime: spinOff, relationType: 'SPIN_OFF'),
      ],
    );

    final order = buildRecommendedFranchiseWatchOrder(
      rootId: root.id,
      anime: const [sequel, root, prequel],
    );
    final ids = order.map((entry) => entry.anime.id).toList();
    final byId = {for (final entry in order) entry.anime.id: entry};

    expect(ids.indexOf(1), lessThan(ids.indexOf(2)));
    expect(ids.indexOf(2), lessThan(ids.indexOf(3)));
    expect(ids.indexOf(2), lessThan(ids.indexOf(4)));
    expect(byId[1]!.watchOrderLabel, 'TV · Prequel');
    expect(byId[2]!.watchOrderLabel, 'TV · Current');
    expect(byId[3]!.watchOrderLabel, 'TV · Sequel');
    expect(byId[4]!.watchOrderLabel, 'Movie · Sequel');
    expect(byId[5]!.watchOrderLabel, 'OVA · Side story');
    expect(byId[6]!.watchOrderLabel, 'Special · Side story');
    expect(byId[7]!.watchOrderLabel, 'TV · Spin-off');
  });

  test('classifies later continuation hops as sequels', () {
    const fourth = AnimeSummary(
      id: 4,
      title: 'Part four',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2024,
    );
    const third = AnimeSummary(
      id: 3,
      title: 'Part three',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2023,
      relatedAnime: [RelatedAnime(anime: fourth, relationType: 'SEQUEL')],
    );
    const root = AnimeSummary(
      id: 2,
      title: 'Part two',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2022,
      relatedAnime: [RelatedAnime(anime: third, relationType: 'SEQUEL')],
    );

    final order = buildRecommendedFranchiseWatchOrder(
      rootId: root.id,
      anime: const [third, root],
    );

    expect(order.map((entry) => entry.anime.id), [2, 3, 4]);
    expect(order.last.relationRole, FranchiseRelationRole.sequel);
  });

  test('malformed relationship cycles still produce a stable full order', () {
    const firstStub = AnimeSummary(
      id: 1,
      title: 'First',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2020,
    );
    const secondStub = AnimeSummary(
      id: 2,
      title: 'Second',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2021,
    );
    const first = AnimeSummary(
      id: 1,
      title: 'First',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2020,
      relatedAnime: [RelatedAnime(anime: secondStub, relationType: 'SEQUEL')],
    );
    const second = AnimeSummary(
      id: 2,
      title: 'Second',
      description: '',
      episodes: 12,
      score: 8,
      format: 'TV',
      seasonYear: 2021,
      relatedAnime: [RelatedAnime(anime: firstStub, relationType: 'SEQUEL')],
    );

    List<int> build() => buildRecommendedFranchiseWatchOrder(
      rootId: 1,
      anime: const [second, first],
    ).map((entry) => entry.anime.id).toList();

    expect(build(), [1, 2]);
    expect(build(), build());
  });
}
