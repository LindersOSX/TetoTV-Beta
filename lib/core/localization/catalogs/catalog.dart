/// Rows are English, Spanish, Portuguese, French, Hindi, German. Keeping the
/// translations together makes missing languages visible during review.
Map<String, Map<String, String>> catalogFromRows(List<List<String>> rows) {
  const locales = ['es', 'pt', 'fr', 'hi', 'de'];
  final result = {for (final locale in locales) locale: <String, String>{}};
  for (final row in rows) {
    if (row.length != 6 || row.any((value) => value.isEmpty)) {
      throw FormatException(
        'Incomplete UI translation row: ${row.firstOrNull}',
      );
    }
    for (var index = 0; index < locales.length; index++) {
      result[locales[index]]![row[0]] = row[index + 1];
    }
  }
  return result;
}
