import 'package:anime_tv/features/aniyomi/domain/aniyomi_chapter_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'newest-first chapters become oldest-first without mutating provider output',
    () {
      final input = [
        {'number': 3},
        {'number': 1.5},
        {'number': 1},
      ];
      expect(orderAniyomiChapters(input).map((c) => c['number']), [1, 1.5, 3]);
      expect(input.first['number'], 3);
    },
  );
  test(
    'unknown, duplicate and invalid chapter numbers disable guessing adjacency',
    () {
      for (final input in <List<Map<String, dynamic>>>[
        [
          {'number': -1},
          {'number': 1},
        ],
        [
          {'number': 1},
          {'number': 1},
        ],
        [
          {'number': double.nan},
        ],
        [
          {'number': double.infinity},
        ],
        [{}],
        [],
      ]) {
        expect(aniyomiChaptersHaveReliableOrder(input), false);
        expect(orderAniyomiChapters(input), input);
      }
    },
  );
}
