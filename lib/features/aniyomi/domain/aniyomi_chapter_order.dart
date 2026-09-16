/// Only unique, finite chapter numbers establish safe Previous/Next ordering.
/// Opaque/unrecognized numbering stays selectable without guessing adjacency.
List<Map<String, dynamic>> orderAniyomiChapters(
  List<Map<String, dynamic>> chapters,
) {
  final result = List<Map<String, dynamic>>.of(chapters);
  if (aniyomiChaptersHaveReliableOrder(result)) {
    result.sort((a, b) => (a['number'] as num).compareTo(b['number'] as num));
  }
  return result;
}

bool aniyomiChaptersHaveReliableOrder(List<Map<String, dynamic>> chapters) {
  final numbers = <num>{};
  for (final chapter in chapters) {
    final number = chapter['number'];
    if (number is! num ||
        !number.isFinite ||
        number <= 0 ||
        !numbers.add(number)) {
      return false;
    }
  }
  return chapters.isNotEmpty;
}
